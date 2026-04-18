import Foundation
#if DEBUG
import OSLog

private let easyLinkClientLogger = Logger(subsystem: "EasyLinkSwiftSDK", category: "EasyLinkClient")

private func debugHex(_ bytes: [UInt8]) -> String {
  bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

private func debugDescription(_ notification: EasyLinkNotification) -> String {
  switch notification {
  case let .fen(packet):
    "fen len=\(packet.count) bytes=\(debugHex(packet))"
  case let .response(bytes):
    "response len=\(bytes.count) bytes=\(debugHex(bytes))"
  case .disconnected:
    "disconnected"
  }
}
#endif

private actor CommandGate {
  private var isLocked = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func acquire(operationName: String) async {
    guard isLocked else {
      isLocked = true
      #if DEBUG
      easyLinkClientLogger.debug("CommandGate immediate acquire operation=\(operationName, privacy: .public)")
      #endif
      return
    }

    #if DEBUG
    easyLinkClientLogger.debug("CommandGate queued operation=\(operationName, privacy: .public) waiters=\(self.waiters.count, privacy: .public)")
    #endif
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func release(operationName: String) {
    guard !waiters.isEmpty else {
      isLocked = false
      #if DEBUG
      easyLinkClientLogger.debug("CommandGate unlocked operation=\(operationName, privacy: .public)")
      #endif
      return
    }

    #if DEBUG
    easyLinkClientLogger.debug("CommandGate resuming next operation=\(operationName, privacy: .public) remainingAfterResume=\(self.waiters.count - 1, privacy: .public)")
    #endif
    waiters.removeFirst().resume()
  }
}

/// High-level async client for a Chessnut board.
public actor EasyLinkClient {
  /// The board profile used to encode commands and parse responses.
  public nonisolated let profile: BoardProfile

  /// Realtime FEN placement updates emitted by the board.
  public nonisolated let fenUpdates: AsyncStream<String>

  private let transport: EasyLinkTransport
  private let responseRouter = ResponseRouter()
  private let commandGate = CommandGate()
  private var uploadChannel: OTBChannel?
  private nonisolated let fenContinuation: AsyncStream<String>.Continuation
  private var notificationTask: Task<Void, Never>?

  /// Creates a client that connects to the first discovered board matching a profile.
  public init(profile: BoardProfile) {
    self.init(
      profile: profile,
      transport: CoreBluetoothEasyLinkTransport(profile: profile)
    )
  }

  /// Creates a client for a specific discovered device.
  public init(device: EasyLinkDevice) {
    self.init(profile: device.profile, deviceID: device.id)
  }

  /// Creates a client that connects to a specific CoreBluetooth peripheral identifier.
  public init(profile: BoardProfile, deviceID: UUID) {
    self.init(
      profile: profile,
      transport: CoreBluetoothEasyLinkTransport(profile: profile, deviceID: deviceID)
    )
  }

  /// Creates a client with an injected transport.
  public init(profile: BoardProfile, transport: EasyLinkTransport) {
    self.profile = profile
    self.transport = transport

    var continuation: AsyncStream<String>.Continuation!
    self.fenUpdates = AsyncStream<String> { streamContinuation in
      continuation = streamContinuation
    }
    self.fenContinuation = continuation
  }

  deinit {
    notificationTask?.cancel()
    fenContinuation.finish()
  }

  /// Connects to the board and starts processing notifications.
  public func connect() async throws {
    try await transport.connect()
    startNotificationTask()
  }

  /// Disconnects from the board and stops processing notifications.
  public func disconnect() async {
    stopNotificationTask()
    await transport.disconnect()
  }

  /// Enables realtime FEN notifications on the board.
  public func enableRealtimeUpdates() async throws {
    try await withCommandGate("enableRealtimeUpdates") {
      try await transport.write(ProtocolConstants.enableRealtimeMode)
    }
  }

  /// Sets LEDs using the command format for the active profile.
  public func setLEDs(_ board: LEDBoard) async throws {
    try await withCommandGate("setLEDs") {
      let command: [UInt8]
      switch profile {
      case .classic:
        command = EasyLinkCodec.classicLEDCommand(board)
      case .move:
        command = EasyLinkCodec.moveLEDCommand(board)
      }
      try await transport.write(command)
    }
  }

  /// Requests the board battery status.
  public func batteryStatus(timeout: Duration = .seconds(3)) async throws -> BatteryStatus {
    try await withCommandGate("batteryStatus") {
      try await transport.write(profile.batteryCommand)
      let profile = self.profile
      let response = try await responseRouter.wait(
        matching: { response in
          switch profile {
          case .classic:
            response.count >= 4 && response[0] == 0x2A && response[1] == 0x02
          case .move:
            response.count >= 5 && response[0] == 0x41 && response[1] == 0x03 && response[2] == 0x0C
          }
        },
        timeout: timeout
      )
      return try EasyLinkCodec.parseBatteryStatus(profile: profile, response: response)
    }
  }

  /// Starts a Chessnut Move auto-move operation from a FEN placement.
  public func setAutoMove(fen: String, force: Bool = true) async throws {
    try await withCommandGate("setAutoMove") {
      guard profile == .move else {
        throw EasyLinkError.unsupportedCommand(profile)
      }
      try await transport.write(EasyLinkCodec.moveAutoMoveCommand(fen: fen, force: force))
    }
  }

  /// Stops the current Chessnut Move auto-move operation.
  public func stopAutoMove() async throws {
    try await withCommandGate("stopAutoMove") {
      guard profile == .move else {
        throw EasyLinkError.unsupportedCommand(profile)
      }
      try await transport.write(EasyLinkCodec.moveStopAutoMoveCommand())
    }
  }

  /// Requests Chessnut Move piece status records.
  public func pieceStatus(timeout: Duration = .seconds(3)) async throws -> [PieceStatus] {
    try await withCommandGate("pieceStatus") {
      guard profile == .move else {
        throw EasyLinkError.unsupportedCommand(profile)
      }

      try await transport.write([0x41, 0x01, 0x0B])
      let response = try await responseRouter.wait(
        matching: { response in
          response.count >= 3 && response[0] == 0x41 && response[1] == 0x89 && response[2] == 0x0B
        },
        timeout: timeout
      )
      return try EasyLinkCodec.parseMovePieceStatus(response: response)
    }
  }

  /// Retrieves games recorded by the board during OTB (over-the-board) play.
  ///
  /// Switches the board to upload mode, downloads all stored games, and returns them.
  /// Upload mode stops realtime FEN notifications — call ``enableRealtimeUpdates()``
  /// afterwards to resume the FEN stream.
  public func importOTBGames(timeout: Duration = .seconds(120)) async throws -> [OTBGame] {
    try await withCommandGate("importOTBGames") {
      try await importOTBGamesLocked(timeout: timeout)
    }
  }

  private func importOTBGamesLocked(timeout: Duration) async throws -> [OTBGame] {
    defer { uploadChannel = nil }

    #if DEBUG
    easyLinkClientLogger.debug("OTB import started timeout=\(String(describing: timeout), privacy: .public)")
    #endif

    var games: [OTBGame] = []

    while true {
      #if DEBUG
      easyLinkClientLogger.debug("OTB enable upload mode")
      #endif
      try await transport.write(ProtocolConstants.enableUploadMode)
      #if DEBUG
      easyLinkClientLogger.debug("OTB query file count command")
      #endif
      try await transport.write(ProtocolConstants.queryFilesCount)
      let fileCount = try await nextFileCount(timeout: timeout)
      #if DEBUG
      easyLinkClientLogger.debug("OTB file count received count=\(fileCount, privacy: .public)")
      #endif
      guard fileCount > 0 else {
        #if DEBUG
        easyLinkClientLogger.debug("OTB import finished totalGames=\(games.count, privacy: .public)")
        #endif
        return games
      }

      let channel = OTBChannel()
      uploadChannel = channel
      #if DEBUG
      easyLinkClientLogger.debug("OTB upload channel installed")
      #endif
      let game = try await importNextOTBGame(from: channel, timeout: timeout)
      games.append(game)
      #if DEBUG
      easyLinkClientLogger.debug("OTB game imported index=\(games.count, privacy: .public) positions=\(game.positions.count, privacy: .public)")
      #endif
      uploadChannel = nil
      #if DEBUG
      easyLinkClientLogger.debug("OTB upload channel cleared; marking imported file done")
      #endif
      try await transport.write(ProtocolConstants.fileImportDone)
    }
  }

  private func withCommandGate<T>(
    _ operationName: String,
    operation: () async throws -> T
  ) async throws -> T {
    #if DEBUG
    easyLinkClientLogger.debug("Command gate acquire requested operation=\(operationName, privacy: .public)")
    #endif
    await commandGate.acquire(operationName: operationName)
    #if DEBUG
    easyLinkClientLogger.debug("Command gate acquired operation=\(operationName, privacy: .public)")
    #endif
    do {
      let value = try await operation()
      await commandGate.release(operationName: operationName)
      #if DEBUG
      easyLinkClientLogger.debug("Command gate released operation=\(operationName, privacy: .public)")
      #endif
      return value
    } catch {
      await commandGate.release(operationName: operationName)
      #if DEBUG
      easyLinkClientLogger.debug("Command gate released after error operation=\(operationName, privacy: .public) error=\(String(describing: error), privacy: .public)")
      #endif
      throw error
    }
  }

  private func nextFileCount(timeout: Duration) async throws -> Int {
    #if DEBUG
    easyLinkClientLogger.debug("OTB waiting for file count response")
    #endif
    let response = try await responseRouter.wait(
      matching: { bytes in
        bytes.count >= 3 && bytes[0] == 0x32 && bytes[1] == 0x01
      },
      timeout: timeout
    )
    #if DEBUG
    easyLinkClientLogger.debug("OTB raw file count response len=\(response.count, privacy: .public) bytes=\(debugHex(response), privacy: .public)")
    #endif
    return Int(response[2])
  }

  private func importNextOTBGame(from channel: OTBChannel, timeout: Duration) async throws -> OTBGame {
    #if DEBUG
    easyLinkClientLogger.debug("OTB readyForImport command")
    #endif
    try await transport.write(ProtocolConstants.readyForImport)
    #if DEBUG
    easyLinkClientLogger.debug("OTB startImport command")
    #endif
    try await transport.write(ProtocolConstants.startImport)

    var positions: [String] = []
    var didReceiveStartFlag = false
    var latestMetadataDescription: String?
    collectLoop: while true {
      let notification: EasyLinkNotification
      do {
        notification = try await nextOTBNotification(
          from: channel,
          timeout: timeout,
          pollResponseCharacteristic: didReceiveStartFlag
        )
      } catch {
        #if DEBUG
        easyLinkClientLogger.error("OTB wait failed started=\(didReceiveStartFlag, privacy: .public) positions=\(positions.count, privacy: .public) metadata=\((latestMetadataDescription ?? "<none>"), privacy: .public) error=\(String(describing: error), privacy: .public)")
        #endif
        throw error
      }
      #if DEBUG
      easyLinkClientLogger.debug("OTB collect notification \(debugDescription(notification), privacy: .public)")
      #endif

      switch notification {
      case let .response(bytes) where isOTBFlag(bytes, marker: 0xBE):
        #if DEBUG
        easyLinkClientLogger.debug("OTB start flag received startedBefore=\(didReceiveStartFlag, privacy: .public) positionsBefore=\(positions.count, privacy: .public)")
        #endif
        if !didReceiveStartFlag {
          positions.removeAll()
          didReceiveStartFlag = true
        }

      case let .response(bytes) where isOTBFlag(bytes, marker: 0xED):
        #if DEBUG
        easyLinkClientLogger.debug("OTB end flag received positions=\(positions.count, privacy: .public)")
        #endif
        break collectLoop

      case let .response(bytes) where isOTBFileMetadata(bytes):
        latestMetadataDescription = otbFileMetadataDescription(bytes)
        #if DEBUG
        easyLinkClientLogger.debug("OTB file metadata received \(latestMetadataDescription ?? "<unparsed>", privacy: .public)")
        #endif

      case .disconnected:
        #if DEBUG
        easyLinkClientLogger.error("OTB disconnected while collecting game")
        #endif
        throw EasyLinkError.disconnected

      default:
        if let placement = placement(from: notification) {
          positions.append(placement)
          #if DEBUG
          easyLinkClientLogger.debug("OTB placement appended count=\(positions.count, privacy: .public) placement=\(placement, privacy: .public)")
          #endif
        } else {
          #if DEBUG
          easyLinkClientLogger.debug("OTB ignored notification \(debugDescription(notification), privacy: .public)")
          #endif
        }
      }
    }

    return OTBGame(positions: positions)
  }

  private func nextOTBNotification(
    from channel: OTBChannel,
    timeout: Duration,
    pollResponseCharacteristic: Bool
  ) async throws -> EasyLinkNotification {
    guard pollResponseCharacteristic else {
      return try await channel.next(timeout: timeout)
    }

    let pollTask = Task { [transport] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        guard let pollingTransport = transport as? EasyLinkResponsePollingTransport else { return }
        await pollingTransport.pollResponseCharacteristic()
      }
    }
    defer { pollTask.cancel() }

    return try await channel.next(timeout: timeout)
  }

  private nonisolated func isOTBFlag(_ bytes: [UInt8], marker: UInt8) -> Bool {
    bytes.count >= 3 && bytes[0] == 0x37 && bytes[1] == 0x01 && bytes[2] == marker
  }

  private nonisolated func isOTBFileMetadata(_ bytes: [UInt8]) -> Bool {
    bytes.count >= 10 && bytes[0] == 0x36 && bytes[1] == 0x08
  }

  private nonisolated func otbFileMetadataDescription(_ bytes: [UInt8]) -> String? {
    guard isOTBFileMetadata(bytes) else { return nil }
    let byteCount = UInt32(bytes[2]) |
      (UInt32(bytes[3]) << 8) |
      (UInt32(bytes[4]) << 16) |
      (UInt32(bytes[5]) << 24)
    let token = UInt32(bytes[6]) |
      (UInt32(bytes[7]) << 8) |
      (UInt32(bytes[8]) << 16) |
      (UInt32(bytes[9]) << 24)
    #if DEBUG
    return "bytes=\(byteCount) token=0x\(String(format: "%08X", token)) raw=\(debugHex(bytes))"
    #else
    return "bytes=\(byteCount) token=\(token)"
    #endif
  }

  private nonisolated func isPlacementPacket(_ bytes: [UInt8]) -> Bool {
    bytes.count >= 34 && bytes[0] == 0x01
  }

  private nonisolated func placement(from notification: EasyLinkNotification) -> String? {
    switch notification {
    case let .fen(packet):
      try? EasyLinkCodec.decodePlacement(from: packet)
    case let .response(bytes) where isPlacementPacket(bytes):
      try? EasyLinkCodec.decodePlacement(from: bytes)
    default:
      nil
    }
  }

  private func tryForwardToUploadChannel(_ notification: EasyLinkNotification) async -> Bool {
    guard let channel = uploadChannel else { return false }
    #if DEBUG
    easyLinkClientLogger.debug("OTB forwarding notification to upload channel \(debugDescription(notification), privacy: .public)")
    #endif
    await channel.receive(notification)
    return true
  }

  private func startNotificationTask() {
    guard notificationTask == nil else {
      return
    }

    notificationTask = Task { [weak self, transport, responseRouter, fenContinuation] in
      for await notification in transport.notifications {
        guard !Task.isCancelled else {
          return
        }

        if let self, await self.tryForwardToUploadChannel(notification) {
          if case .disconnected = notification { return }
          continue
        }

        switch notification {
        case let .fen(packet):
          #if DEBUG
          easyLinkClientLogger.debug("Realtime FEN notification outside OTB len=\(packet.count, privacy: .public) bytes=\(debugHex(packet), privacy: .public)")
          #endif
          if let placement = try? EasyLinkCodec.decodePlacement(from: packet) {
            fenContinuation.yield(placement)
          } else {
            #if DEBUG
            easyLinkClientLogger.debug("Realtime FEN decode failed outside OTB")
            #endif
          }

        case let .response(response):
          #if DEBUG
          easyLinkClientLogger.debug("Routing response outside OTB len=\(response.count, privacy: .public) bytes=\(debugHex(response), privacy: .public)")
          #endif
          await responseRouter.receive(response)

        case .disconnected:
          #if DEBUG
          easyLinkClientLogger.debug("Notification task received disconnect")
          #endif
          return
        }
      }
    }
  }

  private func stopNotificationTask() {
    notificationTask?.cancel()
    notificationTask = nil
  }
}

private actor OTBChannel {
  private var buffer: [EasyLinkNotification] = []
  private var waiters: [UUID: CheckedContinuation<EasyLinkNotification, Error>] = [:]

  func receive(_ notification: EasyLinkNotification) {
    #if DEBUG
    easyLinkClientLogger.debug("OTBChannel receive waiters=\(self.waiters.count, privacy: .public) buffer=\(self.buffer.count, privacy: .public) notification=\(debugDescription(notification), privacy: .public)")
    #endif
    if let (id, waiter) = waiters.first {
      waiters.removeValue(forKey: id)
      waiter.resume(returning: notification)
    } else {
      buffer.append(notification)
      if buffer.count > 512 { buffer.removeFirst() }
    }
  }

  func next(timeout: Duration) async throws -> EasyLinkNotification {
    do {
      return try await withThrowingTaskGroup(of: EasyLinkNotification.self) { group in
        group.addTask { try await self.nextWaiting() }
        group.addTask {
          try await Task.sleep(for: timeout)
          throw EasyLinkError.timeout
        }
        guard let result = try await group.next() else {
          throw EasyLinkError.timeout
        }
        group.cancelAll()
        #if DEBUG
        easyLinkClientLogger.debug("OTBChannel next returning \(debugDescription(result), privacy: .public)")
        #endif
        return result
      }
    } catch {
      #if DEBUG
      easyLinkClientLogger.error("OTBChannel next failed error=\(String(describing: error), privacy: .public) waiters=\(self.waiters.count, privacy: .public) buffer=\(self.buffer.count, privacy: .public)")
      #endif
      throw error
    }
  }

  private func nextWaiting() async throws -> EasyLinkNotification {
    if !buffer.isEmpty {
      #if DEBUG
      easyLinkClientLogger.debug("OTBChannel nextWaiting using buffered notification bufferBefore=\(self.buffer.count, privacy: .public)")
      #endif
      return buffer.removeFirst()
    }

    let id = UUID()
    #if DEBUG
    easyLinkClientLogger.debug("OTBChannel nextWaiting parking waiter id=\(id.uuidString, privacy: .public)")
    #endif
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        waiters[id] = continuation
      }
    } onCancel: {
      Task { await self.cancelWaiter(id: id) }
    }
  }

  private func cancelWaiter(id: UUID) {
    #if DEBUG
    easyLinkClientLogger.debug("OTBChannel cancel waiter id=\(id.uuidString, privacy: .public)")
    #endif
    waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
  }
}
