@testable import EasyLinkSwiftSDK
import XCTest

final class OTBImportTests: XCTestCase {

  // MARK: - Helpers

  private func fenPacket(placement: String) throws -> [UInt8] {
    [0x01, 0x20] + (try EasyLinkCodec.encodePlacement(placement))
  }

  private func makeClient(
    queuedResponses: [[UInt8]: [[UInt8]]] = [:],
    responseHandler: (@Sendable ([UInt8]) -> [UInt8]?)? = nil
  ) async throws -> (EasyLinkClient, FakeTransport) {
    let transport = FakeTransport(responseHandler: responseHandler, queuedResponses: queuedResponses)
    let client = EasyLinkClient(profile: .classic, transport: transport)
    try await client.connect()
    return (client, transport)
  }

  private func queuedCountResponses(_ counts: UInt8...) -> [[UInt8]: [[UInt8]]] {
    [
      ProtocolConstants.queryFilesCount: counts.map { [0x32, 0x01, $0] }
    ]
  }

  // MARK: - Tests

  func testImportOTBGamesReturnsEmptyWhenBoardHasNoGames() async throws {
    let (client, _) = try await makeClient { command in
      command == ProtocolConstants.queryFilesCount ? [0x32, 0x01, 0x00] : nil
    }
    let games = try await client.importOTBGames(timeout: .seconds(1))
    XCTAssertTrue(games.isEmpty)
  }

  func testImportOTBGamesSendsCorrectCommandSequenceForZeroGames() async throws {
    let (client, transport) = try await makeClient { command in
      command == ProtocolConstants.queryFilesCount ? [0x32, 0x01, 0x00] : nil
    }
    _ = try await client.importOTBGames(timeout: .seconds(1))
    let writes = await transport.writes
    XCTAssertEqual(writes, [
      ProtocolConstants.enableUploadMode,
      ProtocolConstants.queryFilesCount,
    ])
  }

  func testImportOTBGamesSendsCorrectCommandSequenceForOneGame() async throws {
    let placement = "8/8/8/8/8/8/8/8"
    let (client, transport) = try await makeClient(queuedResponses: queuedCountResponses(1, 0)) { command in
      switch command {
      case ProtocolConstants.startImport:     [0x37, 0x01, 0xBE]
      default:                                nil
      }
    }
    let importTask = Task { try await client.importOTBGames(timeout: .seconds(2)) }
    try await Task.sleep(for: .milliseconds(50))
    transport.send(.fen(try fenPacket(placement: placement)))
    transport.send(.response([0x37, 0x01, 0xED]))
    _ = try await importTask.value
    let writes = await transport.writes
    XCTAssertEqual(writes, [
      ProtocolConstants.enableUploadMode,
      ProtocolConstants.queryFilesCount,
      ProtocolConstants.readyForImport,
      ProtocolConstants.startImport,
      ProtocolConstants.fileImportDone,
      ProtocolConstants.enableUploadMode,
      ProtocolConstants.queryFilesCount,
    ])
  }

  func testImportOTBGamesSingleGameWithOnePosition() async throws {
    let placement = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR"
    let (client, transport) = try await makeClient(queuedResponses: queuedCountResponses(1, 0)) { command in
      switch command {
      case ProtocolConstants.startImport:     [0x37, 0x01, 0xBE]
      default:                                nil
      }
    }
    let importTask = Task { try await client.importOTBGames(timeout: .seconds(2)) }
    try await Task.sleep(for: .milliseconds(50))
    transport.send(.fen(try fenPacket(placement: placement)))
    transport.send(.response([0x37, 0x01, 0xED]))
    let games = try await importTask.value
    XCTAssertEqual(games.count, 1)
    XCTAssertEqual(games[0].positions, [placement])
  }

  func testImportOTBGamesAcceptsPlacementPacketsOnResponseChannel() async throws {
    let placement = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR"
    let (client, transport) = try await makeClient(queuedResponses: queuedCountResponses(1, 0)) { command in
      switch command {
      case ProtocolConstants.startImport:     [0x37, 0x01, 0xBE]
      default:                                nil
      }
    }
    let importTask = Task { try await client.importOTBGames(timeout: .seconds(2)) }
    try await Task.sleep(for: .milliseconds(50))
    transport.send(.response(try fenPacket(placement: placement)))
    transport.send(.response([0x37, 0x01, 0xED]))
    let games = try await importTask.value
    XCTAssertEqual(games.count, 1)
    XCTAssertEqual(games[0].positions, [placement])
  }

  func testImportOTBGamesIgnoresFileMetadataResponse() async throws {
    let placement = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR"
    let metadata: [UInt8] = [0x36, 0x08, 0x60, 0x02, 0x00, 0x00, 0x29, 0x85, 0x35, 0x13]
    let (client, transport) = try await makeClient(queuedResponses: queuedCountResponses(1, 0)) { command in
      switch command {
      case ProtocolConstants.startImport:     metadata
      default:                                nil
      }
    }
    let importTask = Task { try await client.importOTBGames(timeout: .seconds(2)) }
    try await Task.sleep(for: .milliseconds(50))
    transport.send(.response([0x37, 0x01, 0xBE]))
    transport.send(.response(try fenPacket(placement: placement)))
    transport.send(.response([0x37, 0x01, 0xED]))
    let games = try await importTask.value
    XCTAssertEqual(games.count, 1)
    XCTAssertEqual(games[0].positions, [placement])
  }

  func testImportOTBGamesIgnoresDuplicateStartFlagAfterCollectionStarted() async throws {
    let placement = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR"
    let (client, transport) = try await makeClient(queuedResponses: queuedCountResponses(1, 0)) { command in
      switch command {
      case ProtocolConstants.startImport:     [0x37, 0x01, 0xBE]
      default:                                nil
      }
    }
    let importTask = Task { try await client.importOTBGames(timeout: .seconds(2)) }
    try await Task.sleep(for: .milliseconds(50))
    transport.send(.response(try fenPacket(placement: placement)))
    transport.send(.response([0x37, 0x01, 0xBE]))
    transport.send(.response([0x37, 0x01, 0xED]))
    let games = try await importTask.value
    XCTAssertEqual(games.count, 1)
    XCTAssertEqual(games[0].positions, [placement])
  }

  func testImportOTBGamesStartsCollectionWhenPlacementArrivesBeforeStartFlag() async throws {
    let placement = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR"
    let (client, transport) = try await makeClient(queuedResponses: queuedCountResponses(1, 0))
    let importTask = Task { try await client.importOTBGames(timeout: .seconds(2)) }
    try await Task.sleep(for: .milliseconds(50))
    transport.send(.response(try fenPacket(placement: placement)))
    transport.send(.response([0x37, 0x01, 0xED]))
    let games = try await importTask.value
    XCTAssertEqual(games.count, 1)
    XCTAssertEqual(games[0].positions, [placement])
  }

  func testImportOTBGamesSingleGameWithMultiplePositions() async throws {
    let positions = [
      "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR",
      "rnbqkbnr/pppp1ppp/4p3/8/4P3/8/PPPP1PPP/RNBQKBNR",
    ]
    let (client, transport) = try await makeClient(queuedResponses: queuedCountResponses(1, 0)) { command in
      switch command {
      case ProtocolConstants.startImport:     [0x37, 0x01, 0xBE]
      default:                                nil
      }
    }
    let importTask = Task { try await client.importOTBGames(timeout: .seconds(2)) }
    try await Task.sleep(for: .milliseconds(50))
    for p in positions { transport.send(.fen(try fenPacket(placement: p))) }
    transport.send(.response([0x37, 0x01, 0xED]))
    let games = try await importTask.value
    XCTAssertEqual(games.count, 1)
    XCTAssertEqual(games[0].positions, positions)
  }

  func testImportOTBGamesMultipleGames() async throws {
    let placement1 = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR"
    let placement2 = "8/8/8/3k4/4K3/8/8/8"
    let (client, transport) = try await makeClient(queuedResponses: queuedCountResponses(2, 1, 0)) { command in
      switch command {
      case ProtocolConstants.startImport:     [0x37, 0x01, 0xBE]
      default:                                nil
      }
    }
    let importTask = Task { try await client.importOTBGames(timeout: .seconds(2)) }
    try await Task.sleep(for: .milliseconds(50))
    transport.send(.fen(try fenPacket(placement: placement1)))
    transport.send(.response([0x37, 0x01, 0xED]))
    try await Task.sleep(for: .milliseconds(50))
    transport.send(.fen(try fenPacket(placement: placement2)))
    transport.send(.response([0x37, 0x01, 0xED]))
    let games = try await importTask.value
    XCTAssertEqual(games.count, 2)
    XCTAssertEqual(games[0].positions, [placement1])
    XCTAssertEqual(games[1].positions, [placement2])
  }

  func testImportOTBGamesThrowsOnDisconnectDuringCollection() async throws {
    let (client, transport) = try await makeClient(queuedResponses: queuedCountResponses(1)) { command in
      switch command {
      case ProtocolConstants.startImport:     [0x37, 0x01, 0xBE]
      default:                                nil
      }
    }
    let importTask = Task { try await client.importOTBGames(timeout: .seconds(2)) }
    try await Task.sleep(for: .milliseconds(50))
    transport.send(.disconnected)
    do {
      _ = try await importTask.value
      XCTFail("Expected disconnected error")
    } catch EasyLinkError.disconnected {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testImportOTBGamesThrowsTimeoutWhenNoResponse() async throws {
    let (client, _) = try await makeClient()
    do {
      _ = try await client.importOTBGames(timeout: .milliseconds(100))
      XCTFail("Expected timeout error")
    } catch EasyLinkError.timeout {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testFenUpdatesResumeRoutingAfterOTBImport() async throws {
    let placement = "8/8/8/3k4/4K3/8/8/8"
    let (client, transport) = try await makeClient { command in
      command == ProtocolConstants.queryFilesCount ? [0x32, 0x01, 0x00] : nil
    }
    var fenIterator = client.fenUpdates.makeAsyncIterator()
    _ = try await client.importOTBGames(timeout: .seconds(1))
    transport.send(.fen(try fenPacket(placement: placement)))
    let received = await fenIterator.next()
    XCTAssertEqual(received, placement)
  }
}
