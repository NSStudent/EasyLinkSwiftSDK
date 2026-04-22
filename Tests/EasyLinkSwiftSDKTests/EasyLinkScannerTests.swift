import EasyLinkSwiftSDK
import Foundation
import XCTest

final class EasyLinkScannerTests: XCTestCase {
  func testScanImmediateCancellationDoesNotCrash() async throws {
    try skipUnlessCoreBluetoothIntegrationTestsAreEnabled()

    let task = Task {
      for await _ in EasyLinkScanner.scan(profile: .classic) {}
    }
    task.cancel()
    await task.value
  }

  func testScanCancellationForMoveProfileDoesNotCrash() async throws {
    try skipUnlessCoreBluetoothIntegrationTestsAreEnabled()

    let task = Task {
      for await _ in EasyLinkScanner.scan(profile: .move) {}
    }
    task.cancel()
    await task.value
  }

  private func skipUnlessCoreBluetoothIntegrationTestsAreEnabled() throws {
    guard ProcessInfo.processInfo.environment["EASYLINK_RUN_COREBLUETOOTH_TESTS"] == "1" else {
      throw XCTSkip("Set EASYLINK_RUN_COREBLUETOOTH_TESTS=1 from an app/test host with NSBluetoothAlwaysUsageDescription to run CoreBluetooth integration tests.")
    }
  }
}
