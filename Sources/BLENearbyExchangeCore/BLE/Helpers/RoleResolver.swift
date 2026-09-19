import Foundation

/// Decides central vs. peripheral symmetrically: each device advertises a random
/// nonce, both learn both nonces from the scan, and both apply the same rule so
/// they can never disagree without exchanging a single extra message.
struct RoleResolver {
  init(
    makeNonce: @escaping @Sendable () -> UInt32 = { RoleResolver.makeNonceImpl() },
  ) {
    self.makeNonce = makeNonce
  }

  let makeNonce: @Sendable () -> UInt32
}

extension RoleResolver {
  static func resolve(myNonce: UInt32, peerNonce: UInt32) -> ConnectionRole? {
    if myNonce == peerNonce {
      return nil
    }
    return myNonce > peerNonce ? .central : .peripheral
  }

  private static func makeNonceImpl() -> UInt32 {
    UInt32.random(in: .min ... .max)
  }

  static func encode(_ nonce: UInt32) -> Data {
    withUnsafeBytes(of: nonce.bigEndian) { Data($0) }
  }

  static func decode(_ data: Data) -> UInt32? {
    guard data.count >= MemoryLayout<UInt32>.size
    else { return nil }

    return data
      .prefix(MemoryLayout<UInt64>.size)
      .reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
  }
}
