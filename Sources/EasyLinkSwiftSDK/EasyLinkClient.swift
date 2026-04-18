import Foundation

public actor EasyLinkClient {
  public nonisolated let profile: BoardProfile
  public nonisolated let fenUpdates: AsyncStream<String>

  private let transport: EasyLinkTransport
  private let responseRouter = ResponseRouter()
  private nonisolated let fenContinuation: AsyncStream<String>.Continuation
  private var notificationTask: Task<Void, Never>?

  public init(profile: BoardProfile) {
    self.init(
      profile: profile,
      transport: CoreBluetoothEasyLinkTransport(profile: profile)
    )
  }

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

  public func connect() async throws {
    try await transport.connect()
    startNotificationTask()
  }

  public func disconnect() async {
    stopNotificationTask()
    await transport.disconnect()
  }

  public func enableRealtimeUpdates() async throws {
    try await transport.write(ProtocolConstants.enableRealtimeMode)
  }

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

  public func setAutoMove(fen: String, force: Bool = true) async throws {
    guard profile == .move else {
      throw EasyLinkError.unsupportedCommand(profile)
    }
    try await transport.write(EasyLinkCodec.moveAutoMoveCommand(fen: fen, force: force))
  }

  public func stopAutoMove() async throws {
    guard profile == .move else {
      throw EasyLinkError.unsupportedCommand(profile)
    }
    try await transport.write(EasyLinkCodec.moveStopAutoMoveCommand())
  }

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
