@testable import BLENearbyExchangeCore
import Foundation
import Testing

struct PayloadProcessingTests {
  @Test func singleChunkRoundTrip() throws {
    let payload = Data("hello".utf8)
    let frames = Chunker.chunk(payload, mtu: 180)
    #expect(frames.count == 1)

    var reassembler = Reassembler()
    let result = try reassembler.add(frame: frames[0])
    #expect(result == payload)
  }

  @Test func multiChunkRoundTrip() throws {
    let payload = Data((0 ..< 1000).map { UInt8($0 % 256) })
    let frames = Chunker.chunk(payload, mtu: 64)
    #expect(frames.count > 1)

    var reassembler = Reassembler()
    var result: Data?
    for frame in frames {
      result = try reassembler.add(frame: frame)
    }
    #expect(result == payload)
  }

  @Test func framesReassembleOutOfOrder() throws {
    let payload = Data((0 ..< 500).map { UInt8($0 % 256) })
    let frames = Chunker.chunk(payload, mtu: 64).shuffled()

    var reassembler = Reassembler()
    var result: Data?
    for frame in frames {
      if let full = try reassembler.add(frame: frame) {
        result = full
      }
    }
    #expect(result == payload)
  }

  @Test func malformedFrameThrows() {
    var reassembler = Reassembler()
    #expect(throws: Reassembler.Failure.malformedFrame.self) {
      _ = try reassembler.add(frame: Data([0x00]))
    }
  }

  @Test func noFrameExceedsTheMTU() {
    let frames = Chunker.chunk(Data(repeating: 0xAB, count: 1000), mtu: 64)

    #expect(frames.count > 1)
    #expect(frames.allSatisfy { $0.count <= 64 })
  }

  @Test func payloadThatFitsTheMTUIsNotSplit() {
    let mtuSize = 64
    let payload = Data(repeating: 0xAB, count: mtuSize - Chunker.headerSize)
    let frames = Chunker.chunk(payload, mtu: mtuSize)

    #expect(frames.count == 1)
  }

  @Test func payloadOneByteOverTheMTUIsSplitInTwo() {
    let mtuSize = 64
    let payload = Data(repeating: 0xAB, count: mtuSize - Chunker.headerSize + 1)
    let frames = Chunker.chunk(payload, mtu: mtuSize)

    #expect(frames.count == 2)
  }

  @Test func framesAreNumberedInOrderAndAgreeOnTheTotal() {
    let payload = Data((0 ..< 500).map { UInt8($0 % 256) })
    let frames = Chunker.chunk(payload, mtu: 64).map(Frame.init)

    #expect(frames.map(\.index) == Array(0 ..< frames.count))
    #expect(frames.allSatisfy { $0.total == frames.count })
  }

  @Test func frameBodiesConcatenateBackToThePayload() {
    let payload = Data((0 ..< 500).map { UInt8($0 % 256) })
    let frames = Chunker.chunk(payload, mtu: 64).map(Frame.init)

    #expect(frames.map(\.body).reduce(Data(), +) == payload)
  }
}

private struct Frame {
  let index: Int
  let total: Int
  let body: Data

  init(_ data: Data) {
    let bytes = [UInt8](data)
    index = Int(bytes[0]) << 8 | Int(bytes[1])
    total = Int(bytes[2]) << 8 | Int(bytes[3])
    body = Data(bytes.dropFirst(Chunker.headerSize))
  }
}
