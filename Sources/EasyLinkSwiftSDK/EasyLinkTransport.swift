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

protocol EasyLinkResponsePollingTransport: EasyLinkTransport {
  /// Requests a best-effort read of the response characteristic.
  ///
  /// Some Chessnut Air firmware revisions appear to advance OTB upload data
  /// after ATT read attempts even though the characteristic advertises notify
  /// only. CoreBluetooth may report "read not permitted" while still exposing
  /// the latest characteristic value.
  func pollResponseCharacteristic() async
}

protocol EasyLinkNotificationRearmingTransport: EasyLinkTransport {
  /// Rewrites notification subscriptions after board mode changes.
  func rearmNotificationCharacteristics() async

  /// Rewrites only the FEN notification subscription.
  func rearmFENNotificationCharacteristic() async
}
