@testable import EasyLinkSwiftSDK
import XCTest

final class ProtocolConstantsTests: XCTestCase {
  func testClassicBatteryCommand() {
    XCTAssertEqual(BoardProfile.classic.batteryCommand, [0x29, 0x01, 0x00])
  }

  func testMoveBatteryCommand() {
    XCTAssertEqual(BoardProfile.move.batteryCommand, [0x41, 0x01, 0x0C])
  }

  func testEnableRealtimeModeCommand() {
    XCTAssertEqual(ProtocolConstants.enableRealtimeMode, [0x21, 0x01, 0x00])
  }

  func testClassicMatchesChessnutBoardNames() {
    XCTAssertTrue(BoardProfile.classic.matchesPeripheralName("Chessnut Air"))
    XCTAssertTrue(BoardProfile.classic.matchesPeripheralName("Chessnut Air+"))
    XCTAssertTrue(BoardProfile.classic.matchesPeripheralName("Chessnut Pro"))
    XCTAssertTrue(BoardProfile.classic.matchesPeripheralName("Chessnut Go"))
  }

  func testClassicDoesNotMatchChessnutMove() {
    XCTAssertFalse(BoardProfile.classic.matchesPeripheralName("Chessnut Move"))
  }

  func testClassicDoesNotMatchUnrelatedNames() {
    XCTAssertFalse(BoardProfile.classic.matchesPeripheralName("Unknown Device"))
    XCTAssertFalse(BoardProfile.classic.matchesPeripheralName(""))
  }

  func testMoveMatchesExactName() {
    XCTAssertTrue(BoardProfile.move.matchesPeripheralName("Chessnut Move"))
  }

  func testMoveDoesNotMatchOtherBoardNames() {
    XCTAssertFalse(BoardProfile.move.matchesPeripheralName("Chessnut Air"))
    XCTAssertFalse(BoardProfile.move.matchesPeripheralName("Chessnut Pro"))
    XCTAssertFalse(BoardProfile.move.matchesPeripheralName("Chessnut"))
    XCTAssertFalse(BoardProfile.move.matchesPeripheralName(""))
  }
}
