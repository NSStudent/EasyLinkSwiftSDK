import Foundation

/// High-level async client for a Chessnut board.
public actor EasyLinkClient {
  /// The board profile used to encode commands and parse responses.
  public nonisolated let profile: BoardProfile

  /// Realtime FEN placement updates emitted by the board.
  public nonisolated let fenUpdates: AsyncStream<String>

  private let transport: EasyLinkTransport
  private let responseRouter = ResponseRouter()
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
    try await transport.write(ProtocolConstants.enableRealtimeMode)
  }

  /// Sets LEDs using the command format for the active profile.
  public func setLEDs(_ board: LEDBoard) async throws {
    let command: [UInt8]
    switch profile {
    case .classic:
      command = EasyLinkCodec.classicLEDCommand(board)
    case .move:
      command = EasyLinkCodec.moveLEDCommand(board)
    }
    try await transport.write(command)
  }

  /// Requests the board battery status.
  public func batteryStatus(timeout: Duration = .seconds(3)) async throws -> BatteryStatus {
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

  /// Starts a Chessnut Move auto-move operation from a FEN placement.
  public func setAutoMove(fen: String, force: Bool = true) async throws {
    guard profile == .move else {
      throw EasyLinkError.unsupportedCommand(profile)
    }
    try await transport.write(EasyLinkCodec.moveAutoMoveCommand(fen: fen, force: force))
  }

  /// Stops the current Chessnut Move auto-move operation.
  public func stopAutoMove() async throws {
    guard profile == .move else {
      throw EasyLinkError.unsupportedCommand(profile)
    }
    try await transport.write(EasyLinkCodec.moveStopAutoMoveCommand())
  }

  /// Requests Chessnut Move piece status records.
  public func pieceStatus(timeout: Duration = .seconds(3)) async throws -> [PieceStatus] {
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

  /// Retrieves games recorded by the board during OTB (over-the-board) play.
  ///
  /// Switches the board to upload mode, downloads all stored games, and returns them.
  /// Upload mode stops realtime FEN notifications — call ``enableRealtimeUpdates()``
  /// afterwards to resume the FEN stream.
  public func importOTBGames(timeout: Duration = .seconds(5)) async throws -> [OTBGame] {
    let channel = OTBChannel()
    uploadChannel = channel
    defer { uploadChannel = nil }

    try await transport.write(ProtocolConstants.enableUploadMode)
    try await transport.write(ProtocolConstants.queryFilesCount)

    var fileCount = 0
    fileCountLoop: while true {
      switch try await channel.next(timeout: timeout) {
      case let .response(bytes) where bytes.count >= 3 && bytes[0] == 0x32 && bytes[1] == 0x01:
        fileCount = Int(bytes[2])
        break fileCountLoop
      default:
        break
      }
    }

    guard fileCount > 0 else { return [] }

    var games: [OTBGame] = []

    for _ in 0..<fileCount {
      try await transport.write(ProtocolConstants.readyForImport)
      try await transport.write(ProtocolConstants.startImport)

      startFlagLoop: while true {
        let notification = try await channel.next(timeout: timeout)
        if case let .response(bytes) = notification, isOTBFlag(bytes, marker: 0xBE) {
          break startFlagLoop
        }
      }

      var positions: [String] = []
      collectLoop: while true {
        switch try await channel.next(timeout: timeout) {
        case let .fen(packet):
          if let placement = try? EasyLinkCodec.decodePlacement(from: packet) {
            positions.append(placement)
          }
        case let .response(bytes) where isOTBFlag(bytes, marker: 0xED):
          break collectLoop
        case .disconnected:
          throw EasyLinkError.disconnected
        default:
          break
        }
      }

      games.append(OTBGame(positions: positions))
      try await transport.write(ProtocolConstants.fileImportDone)
    }

    return games
  }

  private nonisolated func isOTBFlag(_ bytes: [UInt8], marker: UInt8) -> Bool {
    bytes.count >= 3 && bytes[0] == 0x37 && bytes[1] == 0x01 && bytes[2] == marker
  }

  private func tryForwardToUploadChannel(_ notification: EasyLinkNotification) async -> Bool {
    guard let channel = uploadChannel else { return false }
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
          if let placement = try? EasyLinkCodec.decodePlacement(from: packet) {
            fenContinuation.yield(placement)
          }

        case let .response(response):
          await responseRouter.receive(response)

        case .disconnected:
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
    if let (id, waiter) = waiters.first {
      waiters.removeValue(forKey: id)
      waiter.resume(returning: notification)
    } else {
      buffer.append(notification)
      if buffer.count > 512 { buffer.removeFirst() }
    }
  }

  func next(timeout: Duration) async throws -> EasyLinkNotification {
    try await withThrowingTaskGroup(of: EasyLinkNotification.self) { group in
      group.addTask { try await self.nextWaiting() }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw EasyLinkError.timeout
      }
      guard let result = try await group.next() else {
        throw EasyLinkError.timeout
      }
      group.cancelAll()
      return result
    }
  }

  private func nextWaiting() async throws -> EasyLinkNotification {
    if !buffer.isEmpty { return buffer.removeFirst() }

    let id = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        waiters[id] = continuation
      }
    } onCancel: {
      Task { await self.cancelWaiter(id: id) }
    }
  }

  private func cancelWaiter(id: UUID) {
    waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
  }
}
