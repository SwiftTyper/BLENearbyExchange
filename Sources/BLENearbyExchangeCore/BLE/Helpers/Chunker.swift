import Foundation

/// Each frame is `[ UInt16 index ][ UInt16 total ][ chunk bytes... ]` (big-endian
/// header). `index`/`total` let the receiver order pieces and know when it has
/// the whole payload, since GATT delivers discrete packets with no message
/// framing of its own.
enum Chunker {
  static let headerSize = 4

  static func chunk(_ payload: Data, mtu: Int) -> [Data] {
    let chunkSize = max(1, mtu - headerSize)
    let chunks = stride(from: 0, to: max(payload.count, 1), by: chunkSize).map {
      payload.subdata(in: $0 ..< min($0 + chunkSize, payload.count))
    }
    let total = UInt16(chunks.count)
    return chunks.enumerated().map { index, chunk in
      var frame = Data()
      frame.append(bigEndian: UInt16(index))
      frame.append(bigEndian: total)
      frame.append(chunk)
      return frame
    }
  }
}

private extension Data {
  mutating func append(bigEndian value: UInt16) {
    Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
  }
}
