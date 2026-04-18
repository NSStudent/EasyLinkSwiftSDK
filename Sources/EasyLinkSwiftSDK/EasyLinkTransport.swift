import Foundation

/// Transport abstraction used by ``EasyLinkClient``.
public protocol EasyLinkTransport: AnyObject, Sendable {
  /// Notifications emitted by the transport.
  var notifications: AsyncStream<EasyLinkNotification> { get }

  /// Connects the transport.
  func connect() async throws

  /// Disconnects the transport.
  func disconnect() async

  /// Writes a raw command packet.
  func write(_ command: [UInt8]) async throws
}
