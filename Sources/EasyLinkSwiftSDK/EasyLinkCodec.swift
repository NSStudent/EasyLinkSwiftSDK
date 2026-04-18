import Foundation

/// Encoder and decoder for Chessnut BLE protocol packets.
public enum EasyLinkCodec {
  private static let pieceByCode: [Character?] = [
    nil, "q", "k", "b", "p", "n", "R", "P", "r", "B", "N", "Q", "K"
  ]

  private static let codeByPiece: [Character: UInt8] = [
    "q": 1, "k": 2, "b": 3, "p": 4, "n": 5,
    "R": 6, "P": 7, "r": 8, "B": 9, "N": 10, "Q": 11, "K": 12
  ]

  private static let movePieceOrder: [Character] = [
    "P", "P", "P", "P", "P", "P", "P", "P", "R", "R", "N", "N", "B", "B", "Q", "Q", "K",
    "p", "p", "p", "p", "p", "p", "p", "p", "r", "r", "n", "n", "b", "b", "q", "q", "k"
  ]

  /// Decodes a FEN placement string from a raw FEN notification packet.
  public static func decodePlacement(from packet: [UInt8]) throws -> String {
    guard packet.count >= 34 else {
      throw EasyLinkError.invalidPacket("FEN packets must contain at least 34 bytes.")
    }

    var fen = ""
    var emptySquares = 0

    for row in 0..<8 {
      for column in stride(from: 7, through: 0, by: -1) {
        let packetIndex = ((row * 8 + column) / 2) + 2
        let pieceCode = column.isMultiple(of: 2)
          ? packet[packetIndex] & 0x0F
          : packet[packetIndex] >> 4

        guard pieceCode < pieceByCode.count else {
          throw EasyLinkError.invalidPacket("Unknown piece code \(pieceCode).")
        }

        if let piece = pieceByCode[Int(pieceCode)] {
          if emptySquares > 0 {
            fen += String(emptySquares)
            emptySquares = 0
          }
          fen.append(piece)
        } else {
          emptySquares += 1
        }
      }

      if emptySquares > 0 {
        fen += String(emptySquares)
      }
      if row < 7 {
        fen += "/"
      }
      emptySquares = 0
    }

    return fen
  }

  /// Encodes a FEN placement string into the 32-byte board payload used by the protocol.
  public static func encodePlacement(_ fen: String) throws -> [UInt8] {
    let placement = fen.split(separator: " ").first.map(String.init) ?? fen
    let ranks = placement.split(separator: "/", omittingEmptySubsequences: false)

    guard ranks.count == 8 else {
      throw EasyLinkError.invalidFEN("FEN placement must contain 8 ranks.")
    }

    var boardData = Array(repeating: UInt8(0), count: 32)

    for (row, rank) in ranks.enumerated() {
      var file = 0
      for character in rank {
        if let digit = character.wholeNumberValue {
          guard (1...8).contains(digit), file + digit <= 8 else {
            throw EasyLinkError.invalidFEN("Invalid empty-square count in rank \(row + 1).")
          }
          file += digit
        } else {
          guard file < 8 else {
            throw EasyLinkError.invalidFEN("Too many files in rank \(row + 1).")
          }
          guard let code = codeByPiece[character] else {
            throw EasyLinkError.invalidFEN("Unsupported piece '\(character)'.")
          }
          writeNibble(code, row: row, protocolColumn: 7 - file, into: &boardData)
          file += 1
        }
      }

      guard file == 8 else {
        throw EasyLinkError.invalidFEN("Rank \(row + 1) contains \(file) files.")
      }
    }

    return boardData
  }

  /// Encodes the classic board LED command.
  public static func classicLEDCommand(_ board: LEDBoard) -> [UInt8] {
    var command: [UInt8] = [0x0A, 0x08]
    for row in 0..<8 {
      var byte: UInt8 = 0
      for file in 0..<8 where board.colors[row][file] != .off {
        byte |= UInt8(1 << (7 - file))
      }
      command.append(byte)
    }
    return command
  }

  /// Encodes the Chessnut Move color LED command.
  public static func moveLEDCommand(_ board: LEDBoard) -> [UInt8] {
    var ledData = Array(repeating: UInt8(0), count: 32)
    for row in 0..<8 {
      for file in 0..<8 {
        writeNibble(
          board.colors[row][file].rawValue,
          row: row,
          protocolColumn: 7 - file,
          into: &ledData
        )
      }
    }
    return [0x43, 0x20] + ledData
  }

  /// Encodes a Chessnut Move auto-move command.
  public static func moveAutoMoveCommand(fen: String, force: Bool) throws -> [UInt8] {
    [0x42, 0x21] + (try encodePlacement(fen)) + [force ? 0 : 1]
  }

  /// Encodes a Chessnut Move stop auto-move command.
  public static func moveStopAutoMoveCommand() -> [UInt8] {
    [0x42, 0x21] + Array(repeating: UInt8(0), count: 33)
  }

  /// Parses a battery response for the selected board profile.
  public static func parseBatteryStatus(profile: BoardProfile, response: [UInt8]) throws -> BatteryStatus {
    switch profile {
    case .classic:
      guard response.count >= 4, response[0] == 0x2A, response[1] == 0x02 else {
        throw EasyLinkError.invalidPacket("Invalid classic battery response.")
      }
      let raw = response[2]
      return BatteryStatus(percentage: Int(raw & 0x7F), isCharging: (raw & 0x80) != 0)

    case .move:
      guard response.count >= 5, response[0] == 0x41, response[1] == 0x03, response[2] == 0x0C else {
        throw EasyLinkError.invalidPacket("Invalid Chessnut Move battery response.")
      }
      return BatteryStatus(percentage: Int(response[4]), isCharging: response[3] == 1)
    }
  }

  /// Parses Chessnut Move piece status records.
  public static func parseMovePieceStatus(response: [UInt8]) throws -> [PieceStatus] {
    guard response.count >= 3, response[0] == 0x41, response[1] == 0x89, response[2] == 0x0B else {
      throw EasyLinkError.invalidPacket("Invalid Chessnut Move piece-status response.")
    }

    let payload = response.dropFirst(3)
    guard payload.count >= movePieceOrder.count * 4 else {
      throw EasyLinkError.invalidPacket("Piece-status payload must contain 34 four-byte records.")
    }

    return (0..<movePieceOrder.count).map { index in
      let offset = payload.startIndex + index * 4
      return PieceStatus(
        index: index,
        piece: movePieceOrder[index],
        identityCode: payload[offset],
        x: payload[offset + 1],
        y: payload[offset + 2],
        batteryPercentage: Int(payload[offset + 3])
      )
    }
  }

  private static func writeNibble(_ value: UInt8, row: Int, protocolColumn: Int, into bytes: inout [UInt8]) {
    let index = (row * 8 + protocolColumn) / 2
    if protocolColumn.isMultiple(of: 2) {
      bytes[index] = (bytes[index] & 0xF0) | (value & 0x0F)
    } else {
      bytes[index] = (bytes[index] & 0x0F) | ((value & 0x0F) << 4)
    }
  }
}
