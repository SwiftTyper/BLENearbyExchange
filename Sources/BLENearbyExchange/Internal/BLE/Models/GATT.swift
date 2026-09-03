import Foundation

enum GATT {
  static let handshake = UUID(uuidString: "B1E0E4CE-1234-4E45-8A52-4259455843B0")!
  static let payload = UUID(uuidString: "B1E0E4CE-1234-4E45-8A52-4259455843B1")!
  static let control = UUID(uuidString: "B1E0E4CE-1234-4E45-8A52-4259455843B2")!

  enum Control: UInt8 {
    case done = 0x03
    case cancelled = 0xFE
    case failed = 0xFF
  }
}
