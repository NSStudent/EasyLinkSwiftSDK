import Foundation

public enum EasyLinkError: Error, Equatable, Sendable {
  case bluetoothUnavailable
  case connectionFailed(String)
  case disconnected
  case invalidPacket(String)
  case invalidFEN(String)
  case invalidLEDBoard(String)
  case unsupportedCommand(BoardProfile)
  case timeout
}
