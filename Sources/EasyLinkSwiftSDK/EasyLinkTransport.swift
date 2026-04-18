import Foundation

public protocol EasyLinkTransport: AnyObject {
  var notifications: AsyncStream<EasyLinkNotification> { get }

  func connect() async throws
  func disconnect() async
  func write(_ command: [UInt8]) async throws
}
