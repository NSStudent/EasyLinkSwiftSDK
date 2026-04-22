import Foundation
@preconcurrency import CoreBluetooth
#if DEBUG
import OSLog

private let easyLinkTransportLogger = Logger(subsystem: "EasyLinkSwiftSDK", category: "CoreBluetoothTransport")

private func transportDebugHex(_ bytes: [UInt8]) -> String {
  bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

private func transportDebugProperties(_ properties: CBCharacteristicProperties) -> String {
  var names: [String] = []
  if properties.contains(.broadcast) { names.append("broadcast") }
  if properties.contains(.read) { names.append("read") }
  if properties.contains(.writeWithoutResponse) { names.append("writeWithoutResponse") }
  if properties.contains(.write) { names.append("write") }
  if properties.contains(.notify) { names.append("notify") }
  if properties.contains(.indicate) { names.append("indicate") }
  if properties.contains(.authenticatedSignedWrites) { names.append("authenticatedSignedWrites") }
  if properties.contains(.extendedProperties) { names.append("extendedProperties") }
  if properties.contains(.notifyEncryptionRequired) { names.append("notifyEncryptionRequired") }
  if properties.contains(.indicateEncryptionRequired) { names.append("indicateEncryptionRequired") }
  return names.isEmpty ? "none" : names.joined(separator: "|")
}
#endif

// CoreBluetooth delegate callbacks are delivered on `queue`; all mutable BLE state below is accessed by scheduling onto that queue.
public final class CoreBluetoothEasyLinkTransport: NSObject, EasyLinkTransport, EasyLinkResponsePollingTransport, EasyLinkNotificationRearmingTransport, @unchecked Sendable {
  private static let minimumWriteInterval: TimeInterval = 0.2

  public let notifications: AsyncStream<EasyLinkNotification>

  private let profile: BoardProfile
  private let deviceID: UUID?
  private let queue = DispatchQueue(label: "EasyLinkSwiftSDK.CoreBluetooth")
  private let notificationContinuation: AsyncStream<EasyLinkNotification>.Continuation

  private var centralManager: CBCentralManager?
  private var peripheral: CBPeripheral?
  private var commandCharacteristic: CBCharacteristic?
  private var fenNotificationCharacteristic: CBCharacteristic?
  private var responseNotificationCharacteristic: CBCharacteristic?
  private var fileNotificationCharacteristic: CBCharacteristic?
  private var connectContinuations: [UUID: CheckedContinuation<Void, Error>] = [:]
  private var pendingWriteContinuations: [CheckedContinuation<Void, Error>] = []
  private var nextWriteDate = Date.distantPast
  private var responsePollCount = 0
  private var lastErroredResponseValue: [UInt8]?

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
    #if DEBUG
    easyLinkTransportLogger.debug("connect requested id=\(id.uuidString, privacy: .public)")
    #endif
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        queue.async {
          if self.isConnectionReady {
            #if DEBUG
            easyLinkTransportLogger.debug("connect completed immediately; connection already ready")
            #endif
            continuation.resume()
            return
          }

          self.connectContinuations[id] = continuation

          if self.centralManager == nil {
            #if DEBUG
            easyLinkTransportLogger.debug("creating CBCentralManager")
            #endif
            self.centralManager = CBCentralManager(delegate: self, queue: self.queue)
          } else {
            #if DEBUG
            easyLinkTransportLogger.debug("central manager exists; start scan if ready")
            #endif
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
    #if DEBUG
    easyLinkTransportLogger.debug("disconnect requested")
    #endif
    await withCheckedContinuation { continuation in
      queue.async {
        if let peripheral = self.peripheral {
          #if DEBUG
          easyLinkTransportLogger.debug("cancel peripheral connection id=\(peripheral.identifier.uuidString, privacy: .public)")
          #endif
          self.centralManager?.cancelPeripheralConnection(peripheral)
        }
        self.commandCharacteristic = nil
        self.fenNotificationCharacteristic = nil
        self.responseNotificationCharacteristic = nil
        self.responsePollCount = 0
        self.lastErroredResponseValue = nil
        self.nextWriteDate = .distantPast
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
        self.scheduleWrite(command, continuation: continuation)
      }
    }
  }

  func pollResponseCharacteristic() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      queue.async {
        defer { continuation.resume() }
        guard let peripheral = self.peripheral,
              peripheral.state == .connected,
              let characteristic = self.responseNotificationCharacteristic
        else {
          #if DEBUG
          easyLinkTransportLogger.debug("poll response skipped; response characteristic not ready")
          #endif
          return
        }

        self.responsePollCount += 1
        #if DEBUG
        if self.responsePollCount == 1 || self.responsePollCount.isMultiple(of: 20) {
          easyLinkTransportLogger.debug("poll response readValue count=\(self.responsePollCount, privacy: .public) properties=\(transportDebugProperties(characteristic.properties), privacy: .public)")
        }
        #endif
        peripheral.readValue(for: characteristic)
      }
    }
  }

  func rearmNotificationCharacteristics() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      queue.async {
        let characteristics = [
          self.fenNotificationCharacteristic,
          self.responseNotificationCharacteristic,
        ].compactMap { $0 }

        guard let peripheral = self.peripheral,
              peripheral.state == .connected,
              !characteristics.isEmpty
        else {
          #if DEBUG
          easyLinkTransportLogger.debug("rearm notifications skipped; characteristics not ready")
          #endif
          continuation.resume()
          return
        }

        #if DEBUG
        easyLinkTransportLogger.debug("rearm notifications disabling count=\(characteristics.count, privacy: .public)")
        #endif
        for characteristic in characteristics where characteristic.isNotifying {
          peripheral.setNotifyValue(false, for: characteristic)
        }

        self.queue.asyncAfter(deadline: .now() + 0.15) {
          #if DEBUG
          easyLinkTransportLogger.debug("rearm notifications enabling count=\(characteristics.count, privacy: .public)")
          #endif
          for characteristic in characteristics {
            peripheral.setNotifyValue(true, for: characteristic)
          }

          self.queue.asyncAfter(deadline: .now() + 0.25) {
            continuation.resume()
          }
        }
      }
    }
  }

  func rearmFENNotificationCharacteristic() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      queue.async {
        guard let peripheral = self.peripheral,
              peripheral.state == .connected,
              let characteristic = self.fenNotificationCharacteristic
        else {
          #if DEBUG
          easyLinkTransportLogger.debug("rearm FEN notification skipped; characteristic not ready")
          #endif
          continuation.resume()
          return
        }

        #if DEBUG
        easyLinkTransportLogger.debug("rearm FEN notification disabling")
        #endif
        if characteristic.isNotifying {
          peripheral.setNotifyValue(false, for: characteristic)
        }

        self.queue.asyncAfter(deadline: .now() + 0.15) {
          #if DEBUG
          easyLinkTransportLogger.debug("rearm FEN notification enabling")
          #endif
          peripheral.setNotifyValue(true, for: characteristic)

          self.queue.asyncAfter(deadline: .now() + 0.25) {
            continuation.resume()
          }
        }
      }
    }
  }

  private func scheduleWrite(_ command: [UInt8], continuation: CheckedContinuation<Void, Error>) {
    let now = Date()
    let writeDate = max(now, nextWriteDate)
    nextWriteDate = writeDate.addingTimeInterval(Self.minimumWriteInterval)
    let delay = writeDate.timeIntervalSince(now)

    #if DEBUG
    easyLinkTransportLogger.debug("schedule write delay=\(delay, privacy: .public) len=\(command.count, privacy: .public) bytes=\(transportDebugHex(command), privacy: .public)")
    #endif

    queue.asyncAfter(deadline: .now() + delay) {
      self.performWrite(command, continuation: continuation)
    }
  }

  private func performWrite(_ command: [UInt8], continuation: CheckedContinuation<Void, Error>) {
    guard let peripheral,
          peripheral.state == .connected,
          let commandCharacteristic
    else {
      #if DEBUG
      easyLinkTransportLogger.error("write failed disconnected len=\(command.count, privacy: .public) bytes=\(transportDebugHex(command), privacy: .public)")
      #endif
      continuation.resume(throwing: EasyLinkError.disconnected)
      return
    }

    let writeType: CBCharacteristicWriteType = commandCharacteristic.properties.contains(.writeWithoutResponse)
      ? .withoutResponse
      : .withResponse

    #if DEBUG
    let writeTypeDescription = writeType == .withoutResponse ? "withoutResponse" : "withResponse"
    easyLinkTransportLogger.debug("perform write characteristic=\(commandCharacteristic.uuid.uuidString, privacy: .public) type=\(writeTypeDescription, privacy: .public) len=\(command.count, privacy: .public) bytes=\(transportDebugHex(command), privacy: .public)")
    #endif

    if writeType == .withResponse {
      pendingWriteContinuations.append(continuation)
      peripheral.writeValue(
        Data(command),
        for: commandCharacteristic,
        type: writeType
      )
    } else {
      peripheral.writeValue(
        Data(command),
        for: commandCharacteristic,
        type: writeType
      )
      continuation.resume()
    }
  }

  private func startScanIfReady() {
    guard centralManager?.state == .poweredOn else {
      #if DEBUG
      easyLinkTransportLogger.debug("scan deferred centralState=\(String(describing: self.centralManager?.state.rawValue), privacy: .public)")
      #endif
      return
    }
    #if DEBUG
    easyLinkTransportLogger.debug("start scan profile=\(String(describing: self.profile), privacy: .public)")
    #endif
    centralManager?.scanForPeripherals(
      withServices: nil,
      options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
    )
  }

  private func connect(_ peripheral: CBPeripheral, using central: CBCentralManager) {
    #if DEBUG
    easyLinkTransportLogger.debug("connecting peripheral id=\(peripheral.identifier.uuidString, privacy: .public) name=\((peripheral.name ?? "<nil>"), privacy: .public)")
    #endif
    central.stopScan()
    self.peripheral = peripheral
    peripheral.delegate = self
    central.connect(peripheral)
  }

  private func finishConnect(_ result: Result<Void, Error>) {
    guard !connectContinuations.isEmpty else {
      #if DEBUG
      easyLinkTransportLogger.debug("finishConnect ignored; no pending continuations result=\(String(describing: result), privacy: .public)")
      #endif
      return
    }

    let continuations = connectContinuations.values
    connectContinuations.removeAll()

    switch result {
    case .success:
      #if DEBUG
      easyLinkTransportLogger.debug("finishConnect success continuations=\(continuations.count, privacy: .public)")
      #endif
      continuations.forEach { $0.resume() }
    case let .failure(error):
      #if DEBUG
      easyLinkTransportLogger.error("finishConnect failure continuations=\(continuations.count, privacy: .public) error=\(String(describing: error), privacy: .public)")
      #endif
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
    #if DEBUG
    easyLinkTransportLogger.debug("validate readiness command=\(self.commandCharacteristic != nil, privacy: .public) fenNotify=\((self.fenNotificationCharacteristic?.isNotifying == true), privacy: .public) responseNotify=\((self.responseNotificationCharacteristic?.isNotifying == true), privacy: .public) peripheralState=\(String(describing: self.peripheral?.state.rawValue), privacy: .public)")
    #endif
    if isConnectionReady {
      finishConnect(.success(()))
    }
  }

  private var isConnectionReady: Bool {
    commandCharacteristic != nil &&
      fenNotificationCharacteristic?.isNotifying == true &&
      responseNotificationCharacteristic?.isNotifying == true &&
      peripheral?.state == .connected
  }
}

extension CoreBluetoothEasyLinkTransport: CBCentralManagerDelegate {
  public func centralManagerDidUpdateState(_ central: CBCentralManager) {
    #if DEBUG
    easyLinkTransportLogger.debug("central state updated raw=\(central.state.rawValue, privacy: .public)")
    #endif
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
    #if DEBUG
    easyLinkTransportLogger.debug("didDiscover peripheral id=\(peripheral.identifier.uuidString, privacy: .public) name=\((peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "<nil>"), privacy: .public) rssi=\(RSSI.intValue, privacy: .public)")
    #endif
    guard let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String,
          profile.matchesPeripheralName(name),
          deviceID == nil || peripheral.identifier == deviceID
    else {
      return
    }

    connect(peripheral, using: central)
  }

  public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    #if DEBUG
    easyLinkTransportLogger.debug("didConnect peripheral id=\(peripheral.identifier.uuidString, privacy: .public)")
    #endif
    peripheral.discoverServices([
      CBUUID(nsuuid: ProtocolConstants.fenService),
      CBUUID(nsuuid: ProtocolConstants.operationService),
      CBUUID(nsuuid: ProtocolConstants.fileService)
    ])
  }

  public func centralManager(
    _ central: CBCentralManager,
    didFailToConnect peripheral: CBPeripheral,
    error: Error?
  ) {
    #if DEBUG
    easyLinkTransportLogger.error("didFailToConnect peripheral id=\(peripheral.identifier.uuidString, privacy: .public) error=\(String(describing: error), privacy: .public)")
    #endif
    self.peripheral = nil
    finishConnect(.failure(error ?? EasyLinkError.connectionFailed("CoreBluetooth failed to connect.")))
  }

  public func centralManager(
    _ central: CBCentralManager,
    didDisconnectPeripheral peripheral: CBPeripheral,
    error: Error?
  ) {
    #if DEBUG
    easyLinkTransportLogger.debug("didDisconnect peripheral id=\(peripheral.identifier.uuidString, privacy: .public) error=\(String(describing: error), privacy: .public)")
    #endif
    commandCharacteristic = nil
    fenNotificationCharacteristic = nil
    responseNotificationCharacteristic = nil
    fileNotificationCharacteristic = nil
    responsePollCount = 0
    lastErroredResponseValue = nil
    nextWriteDate = .distantPast
    self.peripheral = nil
    finishConnect(.failure(error ?? EasyLinkError.disconnected))
    finishPendingWrites(.failure(error ?? EasyLinkError.disconnected))
    notificationContinuation.yield(.disconnected)
  }
}

extension CoreBluetoothEasyLinkTransport: CBPeripheralDelegate {
  public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    if let error {
      #if DEBUG
      easyLinkTransportLogger.error("didDiscoverServices error=\(String(describing: error), privacy: .public)")
      #endif
      finishConnect(.failure(error))
      return
    }

    #if DEBUG
    let serviceIDs = peripheral.services?.map { $0.uuid.uuidString }.joined(separator: ",") ?? "<none>"
    easyLinkTransportLogger.debug("didDiscoverServices services=\(serviceIDs, privacy: .public)")
    #endif
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

      case CBUUID(nsuuid: ProtocolConstants.fileService):
        peripheral.discoverCharacteristics(
          [CBUUID(nsuuid: ProtocolConstants.fileNotificationCharacteristic)],
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
      #if DEBUG
      easyLinkTransportLogger.error("didDiscoverCharacteristics service=\(service.uuid.uuidString, privacy: .public) error=\(String(describing: error), privacy: .public)")
      #endif
      finishConnect(.failure(error))
      return
    }

    #if DEBUG
    let characteristicIDs = service.characteristics?.map {
      "\($0.uuid.uuidString)[\(transportDebugProperties($0.properties))]"
    }.joined(separator: ",") ?? "<none>"
    easyLinkTransportLogger.debug("didDiscoverCharacteristics service=\(service.uuid.uuidString, privacy: .public) characteristics=\(characteristicIDs, privacy: .public)")
    #endif
    service.characteristics?.forEach { characteristic in
      switch characteristic.uuid {
      case CBUUID(nsuuid: ProtocolConstants.commandCharacteristic):
        #if DEBUG
        easyLinkTransportLogger.debug("command characteristic discovered")
        #endif
        commandCharacteristic = characteristic

      case CBUUID(nsuuid: ProtocolConstants.fenNotificationCharacteristic):
        #if DEBUG
        easyLinkTransportLogger.debug("fen notification characteristic discovered; enabling notify")
        #endif
        fenNotificationCharacteristic = characteristic
        peripheral.setNotifyValue(true, for: characteristic)

      case CBUUID(nsuuid: ProtocolConstants.responseCharacteristic):
        #if DEBUG
        easyLinkTransportLogger.debug("response notification characteristic discovered; enabling notify")
        #endif
        responseNotificationCharacteristic = characteristic
        responsePollCount = 0
        lastErroredResponseValue = nil
        peripheral.setNotifyValue(true, for: characteristic)

      case CBUUID(nsuuid: ProtocolConstants.fileNotificationCharacteristic):
        #if DEBUG
        easyLinkTransportLogger.debug("file notification characteristic discovered; enabling notify")
        #endif
        fileNotificationCharacteristic = characteristic
        peripheral.setNotifyValue(true, for: characteristic)

      default:
        break
      }
    }

    validateConnectionReadiness()
  }

  public func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateNotificationStateFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    if let error {
      #if DEBUG
      easyLinkTransportLogger.error("didUpdateNotificationState characteristic=\(characteristic.uuid.uuidString, privacy: .public) error=\(String(describing: error), privacy: .public)")
      #endif
      finishConnect(.failure(error))
      return
    }

    #if DEBUG
    easyLinkTransportLogger.debug("didUpdateNotificationState characteristic=\(characteristic.uuid.uuidString, privacy: .public) isNotifying=\(characteristic.isNotifying, privacy: .public)")
    #endif
    switch characteristic.uuid {
    case CBUUID(nsuuid: ProtocolConstants.fenNotificationCharacteristic):
      fenNotificationCharacteristic = characteristic

    case CBUUID(nsuuid: ProtocolConstants.responseCharacteristic):
      responseNotificationCharacteristic = characteristic

    case CBUUID(nsuuid: ProtocolConstants.fileNotificationCharacteristic):
      fileNotificationCharacteristic = characteristic

    default:
      break
    }

    validateConnectionReadiness()
  }

  public func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    if let error {
      guard let value = characteristic.value,
            characteristic.uuid == CBUUID(nsuuid: ProtocolConstants.responseCharacteristic)
      else {
        #if DEBUG
        easyLinkTransportLogger.error("didUpdateValue ignored characteristic=\(characteristic.uuid.uuidString, privacy: .public) error=\(String(describing: error), privacy: .public) hasValue=\((characteristic.value != nil), privacy: .public)")
        #endif
        return
      }

      let bytes = Array(value)
      guard bytes != lastErroredResponseValue else {
        return
      }
      lastErroredResponseValue = bytes
      #if DEBUG
      easyLinkTransportLogger.debug("didUpdateValue response with error len=\(bytes.count, privacy: .public) bytes=\(transportDebugHex(bytes), privacy: .public) error=\(String(describing: error), privacy: .public)")
      #endif
      notificationContinuation.yield(.response(bytes))
      return
    }

    guard let value = characteristic.value else {
      return
    }

    let bytes = Array(value)
    if characteristic.uuid == CBUUID(nsuuid: ProtocolConstants.responseCharacteristic) {
      lastErroredResponseValue = nil
    }
    switch characteristic.uuid {
    case CBUUID(nsuuid: ProtocolConstants.fenNotificationCharacteristic):
      #if DEBUG
      easyLinkTransportLogger.debug("didUpdateValue FEN len=\(bytes.count, privacy: .public) bytes=\(transportDebugHex(bytes), privacy: .public)")
      #endif
      notificationContinuation.yield(.fen(bytes))

    case CBUUID(nsuuid: ProtocolConstants.responseCharacteristic):
      #if DEBUG
      easyLinkTransportLogger.debug("didUpdateValue response len=\(bytes.count, privacy: .public) bytes=\(transportDebugHex(bytes), privacy: .public)")
      #endif
      notificationContinuation.yield(.response(bytes))

    case CBUUID(nsuuid: ProtocolConstants.fileNotificationCharacteristic):
      #if DEBUG
      easyLinkTransportLogger.debug("didUpdateValue file len=\(bytes.count, privacy: .public) bytes=\(transportDebugHex(bytes), privacy: .public)")
      #endif
      notificationContinuation.yield(.response(bytes))

    default:
      #if DEBUG
      easyLinkTransportLogger.debug("didUpdateValue unknown characteristic=\(characteristic.uuid.uuidString, privacy: .public) len=\(bytes.count, privacy: .public) bytes=\(transportDebugHex(bytes), privacy: .public)")
      #endif
      break
    }
  }

  public func peripheral(
    _ peripheral: CBPeripheral,
    didWriteValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    guard !pendingWriteContinuations.isEmpty else {
      #if DEBUG
      easyLinkTransportLogger.error("didWriteValue with no pending continuation characteristic=\(characteristic.uuid.uuidString, privacy: .public) error=\(String(describing: error), privacy: .public)")
      #endif
      return
    }

    let continuation = pendingWriteContinuations.removeFirst()
    if let error {
      #if DEBUG
      easyLinkTransportLogger.error("didWriteValue failed characteristic=\(characteristic.uuid.uuidString, privacy: .public) error=\(String(describing: error), privacy: .public)")
      #endif
      continuation.resume(throwing: error)
    } else {
      #if DEBUG
      easyLinkTransportLogger.debug("didWriteValue success characteristic=\(characteristic.uuid.uuidString, privacy: .public) pendingRemaining=\(self.pendingWriteContinuations.count, privacy: .public)")
      #endif
      continuation.resume()
    }
  }
}
