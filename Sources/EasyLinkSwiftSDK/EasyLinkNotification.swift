import Foundation

public enum EasyLinkNotification: Sendable, Equatable {
  case fen([UInt8])
  case response([UInt8])
  case disconnected
}
