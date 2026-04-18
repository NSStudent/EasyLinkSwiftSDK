import Foundation

/// High-level async client for a Chessnut board.
public actor EasyLinkClient {
  /// The board profile used to encode commands and parse responses.
  public nonisolated let profile: BoardProfile

  /// Realtime FEN placement updates emitted by the board.
  public nonisolated let fenUpdates: AsyncStream<String>

  private let transport: EasyLinkTransport
  private let responseRouter = ResponseRouter()
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

  private func startNotificationTask() {
    guard notificationTask == nil else {
      return
    }

    notificationTask = Task { [transport, responseRouter, fenContinuation] in
      for await notification in transport.notifications {
        guard !Task.isCancelled else {
          return
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
