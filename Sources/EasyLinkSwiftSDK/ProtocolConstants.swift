import Foundation

enum ProtocolConstants {
  static let fenService = UUID(uuidString: "1b7e8261-2877-41c3-b46e-cf057c562023")!
  static let fenNotificationCharacteristic = UUID(uuidString: "1b7e8262-2877-41c3-b46e-cf057c562023")!
  static let operationService = UUID(uuidString: "1b7e8271-2877-41c3-b46e-cf057c562023")!
  static let commandCharacteristic = UUID(uuidString: "1b7e8272-2877-41c3-b46e-cf057c562023")!
  static let responseCharacteristic = UUID(uuidString: "1b7e8273-2877-41c3-b46e-cf057c562023")!
  static let fileService = UUID(uuidString: "1b7e8281-2877-41c3-b46e-cf057c562023")!
  static let fileNotificationCharacteristic = UUID(uuidString: "1b7e8283-2877-41c3-b46e-cf057c562023")!

  static let enableRealtimeMode: [UInt8] = [0x21, 0x01, 0x00]
  static let enableUploadMode: [UInt8] = [0x21, 0x01, 0x01]
  static let queryFilesCount: [UInt8] = [0x31, 0x01, 0x00]
  static let readyForImport: [UInt8] = [0x33, 0x01, 0x00]
  static let startImport: [UInt8] = [0x34, 0x01, 0x01]
  static let fileImportDone: [UInt8] = [0x39, 0x01, 0x00]
}

extension BoardProfile {
  var batteryCommand: [UInt8] {
    switch self {
    case .classic:
      [0x29, 0x01, 0x00]
    case .move:
      [0x41, 0x01, 0x0C]
    }
  }

  func matchesPeripheralName(_ name: String) -> Bool {
    switch self {
    case .classic:
      name.hasPrefix("Chessnut") && name != "Chessnut Move"
    case .move:
      name == "Chessnut Move"
    }
  }
}
