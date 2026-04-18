import EasyLinkSwiftSDK
import XCTest

final class EasyLinkClientTests: XCTestCase {
  func testClientCanBeCreatedForDiscoveredDevice() {
    let device = EasyLinkDevice(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      name: "Chessnut Move",
      profile: .move
    )

    let client = EasyLinkClient(device: device)

    XCTAssertEqual(client.profile, .move)
  }

  func testConnectStartsRealtimeAndYieldsFenUpdates() async throws {
    let transport = FakeTransport()
    let client = EasyLinkClient(profile: .move, transport: transport)
    var iterator = client.fenUpdates.makeAsyncIterator()

    try await client.connect()
    try await client.enableRealtimeUpdates()

    let placement = "8/8/8/3k4/4K3/8/8/8"
    transport.send(.fen(try fenPacket(placement: placement)))

    let fen = await iterator.next()
    let writes = await transport.writes
    XCTAssertEqual(fen, placement)
    XCTAssertEqual(writes, [[0x21, 0x01, 0x00]])
  }

  func testBatteryStatusWritesProfileCommandAndAwaitsResponse() async throws {
    let transport = FakeTransport { command in
      command == [0x41, 0x01, 0x0C] ? [0x41, 0x03, 0x0C, 0, 44] : nil
    }
    let client = EasyLinkClient(profile: .move, transport: transport)

    try await client.connect()
    let status = try await client.batteryStatus()
    let writes = await transport.writes

    XCTAssertEqual(status, BatteryStatus(percentage: 44, isCharging: false))
    XCTAssertEqual(writes, [[0x41, 0x01, 0x0C]])
  }

  func testSetLEDsUsesSelectedProfileEncoding() async throws {
    var board = LEDBoard.allOff
    board[rankIndex: 0, fileIndex: 7] = .blue

    let classicTransport = FakeTransport()
    let classic = EasyLinkClient(profile: .classic, transport: classicTransport)
    try await classic.connect()
    try await classic.setLEDs(board)
    let classicWrites = await classicTransport.writes
    XCTAssertEqual(classicWrites, [[0x0A, 0x08, 0x01, 0, 0, 0, 0, 0, 0, 0]])

    let moveTransport = FakeTransport()
    let move = EasyLinkClient(profile: .move, transport: moveTransport)
    try await move.connect()
    try await move.setLEDs(board)
    let moveWrites = await moveTransport.writes
    XCTAssertEqual(moveWrites.first?.count, 34)
    XCTAssertEqual(moveWrites.first?[2], 0x03)
  }

  func testClassicProfileRejectsMoveOnlyCommands() async throws {
    let client = EasyLinkClient(profile: .classic, transport: FakeTransport())

    do {
      try await client.setAutoMove(fen: "8/8/8/8/8/8/8/8")
      XCTFail("Expected unsupportedCommand")
    } catch EasyLinkError.unsupportedCommand(.classic) {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testPieceStatusWritesMoveCommandAndParsesResponse() async throws {
    var payload: [UInt8] = []
    for index in 0..<34 {
      payload += [UInt8(index), 1, 2, 3]
    }

    let transport = FakeTransport { command in
      command == [0x41, 0x01, 0x0B] ? [0x41, 0x89, 0x0B] + payload : nil
    }
    let client = EasyLinkClient(profile: .move, transport: transport)

    try await client.connect()
    let statuses = try await client.pieceStatus()

    XCTAssertEqual(statuses.count, 34)
    XCTAssertEqual(statuses[0].piece, "P")
    XCTAssertEqual(statuses[33].piece, "k")
    let writes = await transport.writes
    XCTAssertEqual(writes, [[0x41, 0x01, 0x0B]])
  }

  private func fenPacket(placement: String) throws -> [UInt8] {
    [0x01, 0x20] + (try EasyLinkCodec.encodePlacement(placement))
  }
}
