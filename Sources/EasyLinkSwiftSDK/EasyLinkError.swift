import Foundation

/// Errors thrown by EasyLinkSwiftSDK.
public enum EasyLinkError: Error, Equatable, Sendable {
  /// Bluetooth is unavailable, unauthorized, unsupported, or powered off.
  case bluetoothUnavailable

  /// CoreBluetooth failed to connect.
  case connectionFailed(String)

  /// A command was attempted while disconnected.
  case disconnected

  /// A packet did not match the expected protocol shape.
  case invalidPacket(String)

  /// FEN input could not be encoded for the board protocol.
  case invalidFEN(String)

  /// LED board data is not an 8x8 matrix.
  case invalidLEDBoard(String)

  /// The selected board profile does not support the requested command.
  case unsupportedCommand(BoardProfile)

  /// A command response did not arrive within the requested timeout.
  case timeout
}
