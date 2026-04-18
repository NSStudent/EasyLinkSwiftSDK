import Foundation
@preconcurrency import CoreBluetooth

// CoreBluetooth delegate callbacks are delivered on `queue`; all mutable BLE state below is accessed by scheduling onto that queue.
public final class CoreBluetoothEasyLinkTransport: NSObject, EasyLinkTransport, @unchecked Sendable {
  public let notifications: AsyncStream<EasyLinkNotification>

  private let profile: BoardProfile
  private let deviceID: UUID?
  private let queue = DispatchQueue(label: "EasyLinkSwiftSDK.CoreBluetooth")
  private let notificationContinuation: AsyncStream<EasyLinkNotification>.Continuation

  private var centralManager: CBCentralManager?
  private var peripheral: CBPeripheral?
  private var commandCharacteristic: CBCharacteristic?
  private var connectContinuations: [UUID: CheckedContinuation<Void, Error>] = [:]
  private var pendingWriteContinuations: [CheckedContinuation<Void, Error>] = []

  public init(profile: BoardProfile, deviceID: UUID? = nil) {
    self.profile = profile
    self.deviceID = deviceID

    var continuation: AsyncStream<EasyLinkNotification>.Continuation!
    self.notifications = AsyncStream<EasyLinkNotification> { streamContinuation in
      continuation = streamContinuation
    }
    self.notificationContinuation = continuation

    super.init()
  }

  deinit {
    notificationContinuation.finish()
  }

  public func connect() async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        queue.async {
          if self.peripheral?.state == .connected, self.commandCharacteristic != nil {
            continuation.resume()
            return
          }

          self.connectContinuations[id] = continuation

          if self.centralManager == nil {
            self.centralManager = CBCentralManager(delegate: self, queue: self.queue)
          } else {
            self.startScanIfReady()
          }
        }
      }
    } onCancel: {
      self.queue.async {
        self.cancelConnect(id)
      }
    }
  }

  public func disconnect() async {
    await withCheckedContinuation { continuation in
      queue.async {
        if let peripheral = self.peripheral {
          self.centralManager?.cancelPeripheralConnection(peripheral)
        }
        self.commandCharacteristic = nil
        self.peripheral = nil
        self.finishConnect(.failure(EasyLinkError.disconnected))
        self.finishPendingWrites(.failure(EasyLinkError.disconnected))
        self.notificationContinuation.yield(.disconnected)
        continuation.resume()
      }
    }
  }

  public func write(_ command: [UInt8]) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      queue.async {
        guard let peripheral = self.peripheral,
              peripheral.state == .connected,
              let commandCharacteristic = self.commandCharacteristic
        else {
          continuation.resume(throwing: EasyLinkError.disconnected)
          return
        }

        self.pendingWriteContinuations.append(continuation)
        peripheral.writeValue(
          Data(command),
          for: commandCharacteristic,
          type: .withResponse
        )
      }
    }
  }

  private func startScanIfReady() {
    guard centralManager?.state == .poweredOn else {
      return
    }
    centralManager?.scanForPeripherals(
      withServices: nil,
      options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
    )
  }

  private func connect(_ peripheral: CBPeripheral, using central: CBCentralManager) {
    central.stopScan()
    self.peripheral = peripheral
    peripheral.delegate = self
    central.connect(peripheral)
  }

  private func finishConnect(_ result: Result<Void, Error>) {
    guard !connectContinuations.isEmpty else {
      return
    }

    let continuations = connectContinuations.values
    connectContinuations.removeAll()

    switch result {
    case .success:
      continuations.forEach { $0.resume() }
    case let .failure(error):
      continuations.forEach { $0.resume(throwing: error) }
    }
  }

  private func cancelConnect(_ id: UUID) {
    guard let continuation = connectContinuations.removeValue(forKey: id) else {
      return
    }
    continuation.resume(throwing: CancellationError())
  }

  private func finishPendingWrites(_ result: Result<Void, Error>) {
    guard !pendingWriteContinuations.isEmpty else {
      return
    }

    let continuations = pendingWriteContinuations
    pendingWriteContinuations.removeAll()

    switch result {
    case .success:
      continuations.forEach { $0.resume() }
    case let .failure(error):
      continuations.forEach { $0.resume(throwing: error) }
    }
  }

  private func validateConnectionReadiness() {
    guard let peripheral else {
      return
    }

    let requiredUUIDs = Set([
      CBUUID(nsuuid: ProtocolConstants.commandCharacteristic),
      CBUUID(nsuuid: ProtocolConstants.fenNotificationCharacteristic),
      CBUUID(nsuuid: ProtocolConstants.responseCharacteristic)
    ])

    let discoveredUUIDs = Set(
      peripheral.services?
        .flatMap { $0.characteristics ?? [] }
        .map(\.uuid) ?? []
    )

    if commandCharacteristic != nil && requiredUUIDs.isSubset(of: discoveredUUIDs) {
      finishConnect(.success(()))
    }
  }
}

extension CoreBluetoothEasyLinkTransport: CBCentralManagerDelegate {
  public func centralManagerDidUpdateState(_ central: CBCentralManager) {
    switch central.state {
    case .poweredOn:
      startScanIfReady()

    case .poweredOff, .resetting, .unauthorized, .unsupported:
      finishConnect(.failure(EasyLinkError.bluetoothUnavailable))

    case .unknown:
      break

    @unknown default:
      finishConnect(.failure(EasyLinkError.bluetoothUnavailable))
    }
  }

  public func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    guard let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String,
          profile.matchesPeripheralName(name),
          deviceID == nil || peripheral.identifier == deviceID
    else {
      return
    }

    connect(peripheral, using: central)
  }

  public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    peripheral.discoverServices([
      CBUUID(nsuuid: ProtocolConstants.fenService),
      CBUUID(nsuuid: ProtocolConstants.operationService)
    ])
  }

  public func centralManager(
    _ central: CBCentralManager,
    didFailToConnect peripheral: CBPeripheral,
    error: Error?
  ) {
    self.peripheral = nil
    finishConnect(.failure(error ?? EasyLinkError.connectionFailed("CoreBluetooth failed to connect.")))
  }

  public func centralManager(
    _ central: CBCentralManager,
    didDisconnectPeripheral peripheral: CBPeripheral,
    error: Error?
  ) {
    commandCharacteristic = nil
    self.peripheral = nil
    finishConnect(.failure(error ?? EasyLinkError.disconnected))
    finishPendingWrites(.failure(error ?? EasyLinkError.disconnected))
    notificationContinuation.yield(.disconnected)
  }
}

extension CoreBluetoothEasyLinkTransport: CBPeripheralDelegate {
  public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    if let error {
      finishConnect(.failure(error))
      return
    }

    peripheral.services?.forEach { service in
      switch service.uuid {
      case CBUUID(nsuuid: ProtocolConstants.fenService):
        peripheral.discoverCharacteristics(
          [CBUUID(nsuuid: ProtocolConstants.fenNotificationCharacteristic)],
          for: service
        )

      case CBUUID(nsuuid: ProtocolConstants.operationService):
        peripheral.discoverCharacteristics(
          [
            CBUUID(nsuuid: ProtocolConstants.commandCharacteristic),
            CBUUID(nsuuid: ProtocolConstants.responseCharacteristic)
          ],
          for: service
        )

      default:
        break
      }
    }
  }

  public func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverCharacteristicsFor service: CBService,
    error: Error?
  ) {
    if let error {
      finishConnect(.failure(error))
      return
    }

    service.characteristics?.forEach { characteristic in
      switch characteristic.uuid {
      case CBUUID(nsuuid: ProtocolConstants.commandCharacteristic):
        commandCharacteristic = characteristic

      case CBUUID(nsuuid: ProtocolConstants.fenNotificationCharacteristic),
           CBUUID(nsuuid: ProtocolConstants.responseCharacteristic):
        peripheral.setNotifyValue(true, for: characteristic)

      default:
        break
      }
    }

    validateConnectionReadiness()
  }

  public func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    guard error == nil, let value = characteristic.value else {
      return
    }

    let bytes = Array(value)
    switch characteristic.uuid {
    case CBUUID(nsuuid: ProtocolConstants.fenNotificationCharacteristic):
      notificationContinuation.yield(.fen(bytes))

    case CBUUID(nsuuid: ProtocolConstants.responseCharacteristic):
      notificationContinuation.yield(.response(bytes))

    default:
      break
    }
  }

  public func peripheral(
    _ peripheral: CBPeripheral,
    didWriteValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    guard !pendingWriteContinuations.isEmpty else {
      return
    }

    let continuation = pendingWriteContinuations.removeFirst()
    if let error {
      continuation.resume(throwing: error)
    } else {
      continuation.resume()
    }
  }
}
