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

struct Reassembler {
  private var chunks: [UInt16: Data] = [:]
  private var total: UInt16?
  private var receivedBytes = 0
  private var chunkSize = 0

  /// an overestimate only by the shortfall of the final chunk.
  var progress: TransferProgress {
    TransferProgress(
      bytes: receivedBytes,
      total: total.map { Int($0) * chunkSize } ?? 0
    )
  }

  mutating func add(frame: Data) -> Data? {
    guard frame.count >= Chunker.headerSize else { return nil }
    let index = frame.readBigEndianUInt16(at: 0)
    let count = frame.readBigEndianUInt16(at: 2)
    let body = frame.subdata(in: Chunker.headerSize ..< frame.count)

    total = count
    chunkSize = max(chunkSize, body.count)

    if chunks.updateValue(body, forKey: index) == nil {
      receivedBytes += body.count
    }

    guard chunks.count == Int(count) else { return nil }
    return (0 ..< count).reduce(into: Data()) { $0.append(chunks[$1] ?? Data()) }
  }

  mutating func reset() {
    chunks.removeAll()
    total = nil
    receivedBytes = 0
    chunkSize = 0
  }
}

private extension Data {
  mutating func append(bigEndian value: UInt16) {
    Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
  }

  func readBigEndianUInt16(at offset: Int) -> UInt16 {
    (UInt16(self[startIndex + offset]) << 8) | UInt16(self[startIndex + offset + 1])
  }
}
