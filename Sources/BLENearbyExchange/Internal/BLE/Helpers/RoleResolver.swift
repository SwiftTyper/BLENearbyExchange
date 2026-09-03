import Foundation

/// Decides central vs. peripheral symmetrically: each device advertises a random
/// nonce, both learn both nonces from the scan, and both apply the same rule so
/// they can never disagree without exchanging a single extra message.
enum RoleResolver {
  static func resolve(myNonce: UInt64, peerNonce: UInt64) -> ConnectionRole? {
    if myNonce == peerNonce {
      return nil
    }
    return myNonce > peerNonce ? .central : .peripheral
  }

  static func makeNonce() -> UInt64 {
    UInt64.random(in: .min ... .max)
  }

  static func encode(_ nonce: UInt64) -> Data {
    withUnsafeBytes(of: nonce.bigEndian) { Data($0) }
  }

  static func decode(_ data: Data) -> UInt64? {
    guard data.count >= MemoryLayout<UInt64>.size
    else { return nil }

    return data
      .prefix(MemoryLayout<UInt64>.size)
      .reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
  }
}
