import Foundation

public enum BoardProfile: Sendable, Equatable {
  case classic
  case move
}

public enum LEDColor: UInt8, Sendable, Equatable {
  case off = 0
  case red = 1
  case green = 2
  case blue = 3
}

public struct LEDBoard: Sendable, Equatable {
  public private(set) var colors: [[LEDColor]]

  public init(colors: [[LEDColor]]) throws {
    guard colors.count == 8, colors.allSatisfy({ $0.count == 8 }) else {
      throw EasyLinkError.invalidLEDBoard("LED boards must contain 8 ranks of 8 files.")
    }
    self.colors = colors
  }

  public static var allOff: LEDBoard {
    try! LEDBoard(colors: Array(repeating: Array(repeating: .off, count: 8), count: 8))
  }

  public subscript(rankIndex rankIndex: Int, fileIndex fileIndex: Int) -> LEDColor {
    get { colors[rankIndex][fileIndex] }
    set { colors[rankIndex][fileIndex] = newValue }
  }
}

public struct BatteryStatus: Sendable, Equatable {
  public var percentage: Int
  public var isCharging: Bool?

  public init(percentage: Int, isCharging: Bool?) {
    self.percentage = percentage
    self.isCharging = isCharging
  }
}

public struct PieceStatus: Sendable, Equatable {
  public var index: Int
  public var piece: Character
  public var identityCode: UInt8
  public var x: UInt8
  public var y: UInt8
  public var batteryPercentage: Int

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
