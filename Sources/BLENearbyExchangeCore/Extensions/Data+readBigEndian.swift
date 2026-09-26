import Foundation

extension Data {
  func readBigEndianUInt32(at offset: Int) -> UInt32 {
    withUnsafeBytes {
      UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }
  }
}
