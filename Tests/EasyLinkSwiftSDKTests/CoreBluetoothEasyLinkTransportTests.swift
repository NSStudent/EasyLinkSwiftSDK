import EasyLinkSwiftSDK
import Foundation
import XCTest

final class CoreBluetoothEasyLinkTransportTests: XCTestCase {
  func testWriteThrowsDisconnectedWhenNotConnected() async throws {
    let transport = CoreBluetoothEasyLinkTransport(profile: .classic)

    do {
      try await transport.write([0x01, 0x02])
      XCTFail("Expected disconnected error")
    } catch EasyLinkError.disconnected {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testDisconnectYieldsDisconnectedNotification() async {
    let transport = CoreBluetoothEasyLinkTransport(profile: .move)
    var iterator = transport.notifications.makeAsyncIterator()

    await transport.disconnect()

    let notification = await iterator.next()
    XCTAssertEqual(notification, .disconnected)
  }

  func testDisconnectWhenNeverConnectedCompletes() async {
    let transport = CoreBluetoothEasyLinkTransport(profile: .classic)
    await transport.disconnect()
  }

  func testWriteAfterDisconnectThrowsDisconnected() async throws {
    let transport = CoreBluetoothEasyLinkTransport(profile: .move)
    await transport.disconnect()

    do {
      try await transport.write([0x21, 0x01, 0x00])
      XCTFail("Expected disconnected error")
    } catch EasyLinkError.disconnected {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testInitWithDeviceID() {
    let id = UUID()
    let transport = CoreBluetoothEasyLinkTransport(profile: .move, deviceID: id)
    XCTAssertNotNil(transport)
  }

  func testInitWithoutDeviceID() {
    let transport = CoreBluetoothEasyLinkTransport(profile: .classic)
    XCTAssertNotNil(transport)
  }

  func testConnectCancellationDoesNotHang() async throws {
    try skipUnlessCoreBluetoothIntegrationTestsAreEnabled()

    let transport = CoreBluetoothEasyLinkTransport(profile: .classic)

    let task = Task<Void, Error> {
      try await transport.connect()
    }

    try? await Task.sleep(nanoseconds: 50_000_000)
    task.cancel()

    do {
      try await task.value
    } catch is CancellationError {
    } catch is EasyLinkError {
    } catch {
      XCTFail("Unexpected error type: \(error)")
    }
  }

  func testMultipleDisconnectsDoNotCrash() async {
    let transport = CoreBluetoothEasyLinkTransport(profile: .classic)
    await transport.disconnect()
    await transport.disconnect()
  }

  private func skipUnlessCoreBluetoothIntegrationTestsAreEnabled() throws {
    guard ProcessInfo.processInfo.environment["EASYLINK_RUN_COREBLUETOOTH_TESTS"] == "1" else {
      throw XCTSkip("Set EASYLINK_RUN_COREBLUETOOTH_TESTS=1 from an app/test host with NSBluetoothAlwaysUsageDescription to run CoreBluetooth integration tests.")
    }
  }
}
