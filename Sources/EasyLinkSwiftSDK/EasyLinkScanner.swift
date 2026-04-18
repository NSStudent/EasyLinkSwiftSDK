import Foundation
@preconcurrency import CoreBluetooth

/// Discovers Chessnut boards over Bluetooth.
public enum EasyLinkScanner {
  /// Scans for boards matching a profile.
  ///
  /// The stream yields ``EasyLinkDevice`` values that include the real
  /// CoreBluetooth peripheral identifier and advertised name. Keep the
  /// consuming task alive while the UI is discovering devices and cancel it
  /// when scanning should stop.
  public static func scan(profile: BoardProfile) -> AsyncStream<EasyLinkDevice> {
    AsyncStream { continuation in
      let scanner = CoreBluetoothEasyLinkScanner(
        profile: profile,
        continuation: continuation
      )
      continuation.onTermination = { @Sendable _ in
        scanner.stop()
      }
      scanner.start()
    }
  }
}

// CoreBluetooth scanner callbacks are delivered on `queue`; all mutable scanner state is accessed from that queue.
private final class CoreBluetoothEasyLinkScanner: NSObject, @unchecked Sendable {
  private let profile: BoardProfile
  private let queue = DispatchQueue(label: "EasyLinkSwiftSDK.CoreBluetoothScanner")
  private let continuation: AsyncStream<EasyLinkDevice>.Continuation

  private var centralManager: CBCentralManager?
  private var seenPeripheralIDs: Set<UUID> = []
  private var isStopped = false

  init(
    profile: BoardProfile,
    continuation: AsyncStream<EasyLinkDevice>.Continuation
  ) {
    self.profile = profile
    self.continuation = continuation
    super.init()
  }

  func start() {
    queue.async {
      guard !self.isStopped else {
        return
      }
      self.centralManager = CBCentralManager(delegate: self, queue: self.queue)
    }
  }

  func stop() {
    queue.async {
      self.isStopped = true
      self.centralManager?.stopScan()
      self.centralManager = nil
    }
  }

  private func startScanIfReady() {
    guard !isStopped, centralManager?.state == .poweredOn else {
      return
    }

    centralManager?.scanForPeripherals(
      withServices: nil,
      options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
    )
  }
}

extension CoreBluetoothEasyLinkScanner: CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    switch central.state {
    case .poweredOn:
      startScanIfReady()

    case .poweredOff, .resetting, .unauthorized, .unsupported:
      continuation.finish()

    case .unknown:
      break

    @unknown default:
      continuation.finish()
    }
  }

  func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    guard !isStopped,
          let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String,
          profile.matchesPeripheralName(name),
          seenPeripheralIDs.insert(peripheral.identifier).inserted
    else {
      return
    }

    continuation.yield(
      EasyLinkDevice(
        id: peripheral.identifier,
        name: name,
        profile: profile
      )
    )
  }
}
