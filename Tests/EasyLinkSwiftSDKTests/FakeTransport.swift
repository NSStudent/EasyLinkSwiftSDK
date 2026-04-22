@testable import EasyLinkSwiftSDK
import Foundation

actor FakeTransport: EasyLinkTransport, EasyLinkResponsePollingTransport {
  nonisolated let notifications: AsyncStream<EasyLinkNotification>

  private nonisolated let continuation: AsyncStream<EasyLinkNotification>.Continuation
  private var responseHandler: (@Sendable ([UInt8]) -> [UInt8]?)?
  private var queuedResponses: [[UInt8]: [[UInt8]]]
  private var polledNotifications: [EasyLinkNotification]
  private(set) var writes: [[UInt8]] = []
  private(set) var pollCount = 0
  private(set) var didConnect = false
  private(set) var didDisconnect = false

  init(
    responseHandler: (@Sendable ([UInt8]) -> [UInt8]?)? = nil,
    queuedResponses: [[UInt8]: [[UInt8]]] = [:],
    polledNotifications: [EasyLinkNotification] = []
  ) {
    self.responseHandler = responseHandler
    self.queuedResponses = queuedResponses
    self.polledNotifications = polledNotifications

    var continuation: AsyncStream<EasyLinkNotification>.Continuation!
    self.notifications = AsyncStream<EasyLinkNotification> { streamContinuation in
      continuation = streamContinuation
    }
    self.continuation = continuation
  }

  func connect() async throws {
    didConnect = true
  }

  func disconnect() async {
    didDisconnect = true
    continuation.yield(.disconnected)
  }

  func write(_ command: [UInt8]) async throws {
    writes.append(command)
    let response = responseHandler?(command) ?? nextQueuedResponse(for: command)
    if let response {
      continuation.yield(.response(response))
    }
  }

  func pollResponseCharacteristic() async {
    pollCount += 1
    guard !polledNotifications.isEmpty else {
      return
    }

    continuation.yield(polledNotifications.removeFirst())
  }

  private func nextQueuedResponse(for command: [UInt8]) -> [UInt8]? {
    guard var responses = queuedResponses[command], !responses.isEmpty else {
      return nil
    }

    let response = responses.removeFirst()
    queuedResponses[command] = responses
    return response
  }

  nonisolated func send(_ notification: EasyLinkNotification) {
    continuation.yield(notification)
  }
}
