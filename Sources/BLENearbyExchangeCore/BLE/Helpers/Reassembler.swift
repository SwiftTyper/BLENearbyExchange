import Foundation

struct Reassembler {
  private var chunks: [UInt32: Data] = [:]
  private var total: UInt32?
  private var receivedBytes = 0
  private var chunkSize = 0

  /// an overestimate only by the shortfall of the final chunk.
  var progress: TransferProgress {
    TransferProgress(
      bytes: receivedBytes,
      total: total.map { Int($0) * chunkSize } ?? 0,
    )
  }

  mutating func add(frame: Data) throws -> Data? {
    guard frame.count >= Chunker.headerSize
    else { throw Failure.malformedFrame }

    let index = frame.readBigEndianUInt32(at: 0)
    let count = frame.readBigEndianUInt32(at: 4)
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

  enum Failure: Error {
    case malformedFrame
  }
}
