@testable import EasyLinkSwiftSDK
import XCTest

final class ResponseRouterTests: XCTestCase {
  func testBufferedResponsesAreBoundedToMostRecentValues() async throws {
    let router = ResponseRouter(maximumBufferedResponses: 2)

    await router.receive([1])
    await router.receive([2])
    await router.receive([3])

    do {
      _ = try await router.wait(matching: { $0 == [1] }, timeout: .milliseconds(10))
      XCTFail("Expected the oldest unmatched response to be evicted.")
    } catch EasyLinkError.timeout {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    let response = try await router.wait(matching: { $0 == [2] }, timeout: .milliseconds(10))
    XCTAssertEqual(response, [2])
  }
}
