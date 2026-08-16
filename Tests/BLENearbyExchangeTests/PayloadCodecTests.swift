import Foundation
@testable import NearbyExchange
import Testing

struct PayloadCodecTests {
  @Test func singleChunkRoundTrip() throws {
    let payload = Data("hello".utf8)
    let frames = PayloadCodec.encode(payload, mtu: 180)
    #expect(frames.count == 1)

    let reassembler = PayloadCodec.Reassembler()
    let result = try reassembler.add(frame: frames[0])
    #expect(result == payload)
  }

  @Test func multiChunkRoundTrip() throws {
    let payload = Data((0 ..< 1000).map { UInt8($0 % 256) })
    let frames = PayloadCodec.encode(payload, mtu: 64)
    #expect(frames.count > 1)

    let reassembler = PayloadCodec.Reassembler()
    var result: Data?
    for frame in frames {
      result = try reassembler.add(frame: frame)
    }
    #expect(result == payload)
  }

  @Test func framesReassembleOutOfOrder() throws {
    let payload = Data((0 ..< 500).map { UInt8($0 % 256) })
    let frames = PayloadCodec.encode(payload, mtu: 64).shuffled()

    let reassembler = PayloadCodec.Reassembler()
    var result: Data?
    for frame in frames {
      if let full = try reassembler.add(frame: frame) {
        result = full
      }
    }
    #expect(result == payload)
  }

  @Test func malformedFrameThrows() {
    let reassembler = PayloadCodec.Reassembler()
    #expect(throws: ExchangeError.self) {
      _ = try reassembler.add(frame: Data([0x00]))
    }
  }
}
