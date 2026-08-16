import Foundation
@testable import NearbyExchange
import Testing

struct RoleResolverTests {
  @Test func higherNonceBecomesCentral() {
    #expect(RoleResolver.resolve(myNonce: 100, peerNonce: 50) == .central)
  }

  @Test func lowerNonceBecomesPeripheral() {
    #expect(RoleResolver.resolve(myNonce: 50, peerNonce: 100) == .peripheral)
  }

  @Test func equalNonceIsCollision() {
    #expect(RoleResolver.resolve(myNonce: 42, peerNonce: 42) == nil)
  }

  @Test func bothSidesAgreeOnOppositeRoles() {
    let a = RoleResolver.makeNonce()
    var b = RoleResolver.makeNonce()
    while a == b {
      b = RoleResolver.makeNonce()
    }

    let roleA = RoleResolver.resolve(myNonce: a, peerNonce: b)
    let roleB = RoleResolver.resolve(myNonce: b, peerNonce: a)
    #expect(roleA != roleB)
    #expect(roleA != nil && roleB != nil)
  }

  @Test func nonceRoundTripsThroughEncoding() {
    let nonce = RoleResolver.makeNonce()
    let decoded = RoleResolver.decode(RoleResolver.encode(nonce))
    #expect(decoded == nonce)
  }

  @Test func decodeRejectsShortData() {
    #expect(RoleResolver.decode(Data([1, 2, 3])) == nil)
  }
}
