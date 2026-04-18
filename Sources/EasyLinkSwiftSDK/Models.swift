import Foundation

/// Selects the Chessnut BLE command profile used by the SDK.
public enum BoardProfile: Sendable, Equatable {
  /// Classic Chessnut boards such as Air, Air+, Go, and Pro.
  case classic

  /// Chessnut Move boards.
  case move
}

/// A real Bluetooth peripheral discovered by ``EasyLinkScanner``.
public struct EasyLinkDevice: Sendable, Identifiable, Equatable {
  /// The CoreBluetooth peripheral identifier.
  public let id: UUID

  /// The advertised Bluetooth name.
  public let name: String

  /// The profile matched from the advertised name.
  public let profile: BoardProfile

  /// Creates a discovered device value.
  public init(id: UUID, name: String, profile: BoardProfile) {
    self.id = id
    self.name = name
    self.profile = profile
  }
}

/// LED colors supported by the high-level LED API.
public enum LEDColor: UInt8, Sendable, Equatable {
  /// Turns the square LED off.
  case off = 0

  /// Red LED value.
  case red = 1

  /// Green LED value.
  case green = 2

  /// Blue LED value.
  case blue = 3
}

/// An 8x8 matrix of LED colors.
public struct LEDBoard: Sendable, Equatable {
  /// LED colors indexed by rank and file.
  public private(set) var colors: [[LEDColor]]

  /// Creates an LED board from an 8x8 matrix.
  public init(colors: [[LEDColor]]) throws {
    guard colors.count == 8, colors.allSatisfy({ $0.count == 8 }) else {
      throw EasyLinkError.invalidLEDBoard("LED boards must contain 8 ranks of 8 files.")
    }
    self.colors = colors
  }

  /// An LED board with every square turned off.
  public static var allOff: LEDBoard {
    try! LEDBoard(colors: Array(repeating: Array(repeating: .off, count: 8), count: 8))
  }

  /// Accesses one LED color by zero-based rank and file indexes.
  public subscript(rankIndex rankIndex: Int, fileIndex fileIndex: Int) -> LEDColor {
    get { colors[rankIndex][fileIndex] }
    set { colors[rankIndex][fileIndex] = newValue }
  }
}

/// Battery state reported by a board.
public struct BatteryStatus: Sendable, Equatable {
  /// Battery percentage reported by the device.
  public var percentage: Int

  /// Charging state when the profile reports it.
  public var isCharging: Bool?

  /// Creates a battery status value.
  public init(percentage: Int, isCharging: Bool?) {
    self.percentage = percentage
    self.isCharging = isCharging
  }
}

/// Status for one Chessnut Move physical piece.
public struct PieceStatus: Sendable, Equatable {
  /// Record index in the piece-status payload.
  public var index: Int

  /// Expected piece symbol for the record.
  public var piece: Character

  /// Physical identity code reported by the board.
  public var identityCode: UInt8

  /// X coordinate reported by the board.
  public var x: UInt8

  /// Y coordinate reported by the board.
  public var y: UInt8

  /// Battery percentage for the piece.
  public var batteryPercentage: Int

  /// Creates a piece status value.
  public init(
    index: Int,
    piece: Character,
    identityCode: UInt8,
    x: UInt8,
    y: UInt8,
    batteryPercentage: Int
  ) {
    self.index = index
    self.piece = piece
    self.identityCode = identityCode
    self.x = x
    self.y = y
    self.batteryPercentage = batteryPercentage
  }
}
