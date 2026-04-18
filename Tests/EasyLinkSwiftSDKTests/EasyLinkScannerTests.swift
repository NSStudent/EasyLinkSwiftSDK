import EasyLinkSwiftSDK
import XCTest

final class EasyLinkScannerTests: XCTestCase {
  func testScanImmediateCancellationDoesNotCrash() async {
    let task = Task {
      for await _ in EasyLinkScanner.scan(profile: .classic) {}
    }
    task.cancel()
    await task.value
  }

  func testScanCancellationForMoveProfileDoesNotCrash() async {
    let task = Task {
      for await _ in EasyLinkScanner.scan(profile: .move) {}
    }
    task.cancel()
    await task.value
  }
}
