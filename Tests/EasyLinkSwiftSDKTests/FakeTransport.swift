import EasyLinkSwiftSDK
import Foundation

final class FakeTransport: EasyLinkTransport, @unchecked Sendable {
  let notifications: AsyncStream<EasyLinkNotification>

  private let continuation: AsyncStream<EasyLinkNotification>.Continuation
  private let lock = NSLock()
  private var responseHandler: (([UInt8]) -> [UInt8]?)?
  private(set) var writes: [[UInt8]] = []
  private(set) var didConnect = false
  private(set) var didDisconnect = false

  init(responseHandler: (([UInt8]) -> [UInt8]?)? = nil) {
    self.responseHandler = responseHandler

    var continuation: AsyncStream<EasyLinkNotification>.Continuation!
    self.notifications = AsyncStream<EasyLinkNotification> { streamContinuation in
      continuation = streamContinuation
    }
    self.continuation = continuation
  }

  func connect() async throws {
    lock.withLock {
      didConnect = true
    }
  }

  func disconnect() async {
    lock.withLock {
      didDisconnect = true
    }
    continuation.yield(.disconnected)
  }

  func write(_ command: [UInt8]) async throws {
    let response = lock.withLock {
      writes.append(command)
      return responseHandler?(command)
    }
    if let response {
      continuation.yield(.response(response))
    }
  }

  func send(_ notification: EasyLinkNotification) {
    continuation.yield(notification)
  }
}

private extension NSLock {
  func withLock<T>(_ operation: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try operation()
  }
}
