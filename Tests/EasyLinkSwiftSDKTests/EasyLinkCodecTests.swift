import EasyLinkSwiftSDK
import XCTest

final class EasyLinkCodecTests: XCTestCase {
  func testDecodesStartingPositionFromNotificationPacket() throws {
    let placement = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR"
    let packet = try fenPacket(placement: placement, headerLength: 36)

    XCTAssertEqual(try EasyLinkCodec.decodePlacement(from: packet), placement)
  }

  func testDecodesMoveThirtyEightByteNotificationPacket() throws {
    let placement = "8/8/8/3k4/4K3/8/8/8"
    let packet = try fenPacket(placement: placement, headerLength: 38)

    XCTAssertEqual(try EasyLinkCodec.decodePlacement(from: packet), placement)
  }

  func testEncodePlacementRoundTripsEveryPieceCode() throws {
    let placement = "qkbpnRP1/rBNQK3/8/8/8/8/8/8"
    let packet = [0x01, 0x20] + (try EasyLinkCodec.encodePlacement(placement))

    XCTAssertEqual(try EasyLinkCodec.decodePlacement(from: packet), placement)
  }

  func testRejectsInvalidFen() {
    XCTAssertThrowsError(try EasyLinkCodec.encodePlacement("8/8/8/8/8/8/8"))
    XCTAssertThrowsError(try EasyLinkCodec.encodePlacement("8/8/8/8/8/8/8/X7"))
    XCTAssertThrowsError(try EasyLinkCodec.encodePlacement("8/8/8/8/8/8/8/9"))
  }

  func testClassicLEDCommandUsesEightBitRows() throws {
    var board = LEDBoard.allOff
    board[rankIndex: 4, fileIndex: 2] = .red

    XCTAssertEqual(
      EasyLinkCodec.classicLEDCommand(board),
      [0x0A, 0x08, 0, 0, 0, 0, 0x20, 0, 0, 0]
    )
  }

  func testMoveLEDCommandUsesFenNibbleOrder() throws {
    var board = LEDBoard.allOff
    board[rankIndex: 0, fileIndex: 7] = .red
    board[rankIndex: 0, fileIndex: 6] = .green

    let command = EasyLinkCodec.moveLEDCommand(board)

    XCTAssertEqual(command.count, 34)
    XCTAssertEqual(command[0], 0x43)
    XCTAssertEqual(command[1], 0x20)
    XCTAssertEqual(command[2], 0x21)
  }

  func testMoveAutoMoveCommand() throws {
    let command = try EasyLinkCodec.moveAutoMoveCommand(
      fen: "8/8/8/8/8/8/8/8",
      force: false
    )

    XCTAssertEqual(command.count, 35)
    XCTAssertEqual(command[0], 0x42)
    XCTAssertEqual(command[1], 0x21)
    XCTAssertEqual(command[34], 1)
  }

  func testMoveStopAutoMoveCommand() {
    let command = EasyLinkCodec.moveStopAutoMoveCommand()

    XCTAssertEqual(command.count, 35)
    XCTAssertEqual(command[0], 0x42)
    XCTAssertEqual(command[1], 0x21)
    XCTAssertEqual(command.dropFirst(2), Array(repeating: UInt8(0), count: 33)[...])
  }

  func testParsesClassicBattery() throws {
    let status = try EasyLinkCodec.parseBatteryStatus(
      profile: .classic,
      response: [0x2A, 0x02, UInt8(0x80 | 67), 0x00]
    )

    XCTAssertEqual(status, BatteryStatus(percentage: 67, isCharging: true))
  }

  func testParsesMoveBattery() throws {
    let status = try EasyLinkCodec.parseBatteryStatus(
      profile: .move,
      response: [0x41, 0x03, 0x0C, 1, 91]
    )

    XCTAssertEqual(status, BatteryStatus(percentage: 91, isCharging: true))
  }

  func testParsesMovePieceStatus() throws {
    var payload: [UInt8] = []
    for index in 0..<34 {
      payload += [UInt8(index + 1), UInt8(index), UInt8(255 - index), UInt8(50 + index)]
    }

    let statuses = try EasyLinkCodec.parseMovePieceStatus(response: [0x41, 0x89, 0x0B] + payload)

    XCTAssertEqual(statuses.count, 34)
    XCTAssertEqual(statuses[0], PieceStatus(index: 0, piece: "P", identityCode: 1, x: 0, y: 255, batteryPercentage: 50))
    XCTAssertEqual(statuses[33].piece, "k")
    XCTAssertEqual(statuses[33].batteryPercentage, 83)
  }

  private func fenPacket(placement: String, headerLength: Int) throws -> [UInt8] {
    var packet = [UInt8(0x01), UInt8(headerLength - 2)]
    packet += try EasyLinkCodec.encodePlacement(placement)
    packet += Array(repeating: UInt8(0), count: max(0, headerLength - packet.count))
    return packet
  }
}
