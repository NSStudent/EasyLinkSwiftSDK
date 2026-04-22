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

  func testEnableUploadModeCommand() {
    XCTAssertEqual(ProtocolConstants.enableUploadMode, [0x21, 0x01, 0x01])
  }

  func testQueryFilesCountCommand() {
    XCTAssertEqual(ProtocolConstants.queryFilesCount, [0x31, 0x01, 0x00])
  }

  func testReadyForImportCommand() {
    XCTAssertEqual(ProtocolConstants.readyForImport, [0x33, 0x01, 0x00])
  }

  func testStartImportCommand() {
    XCTAssertEqual(ProtocolConstants.startImport, [0x34, 0x01, 0x01])
  }

  func testFileImportDoneCommand() {
    XCTAssertEqual(ProtocolConstants.fileImportDone, [0x39, 0x01, 0x00])
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
