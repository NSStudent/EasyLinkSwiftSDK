import Foundation

/// Notifications emitted by an ``EasyLinkTransport``.
public enum EasyLinkNotification: Sendable, Equatable {
  /// Raw FEN notification packet.
  case fen([UInt8])

  /// Raw command response packet.
  case response([UInt8])

  /// Transport disconnection event.
  case disconnected
}
