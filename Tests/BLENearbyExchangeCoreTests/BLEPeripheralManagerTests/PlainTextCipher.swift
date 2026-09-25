import Foundation
@testable import BLENearbyExchangeCore
import CryptoKit

struct PlainTextCipher: MessageCipher {
  var localPublicKey: P384.KeyAgreement.PublicKey { P384.KeyAgreement.PrivateKey().publicKey }
  func establish(with peerPublicKeyData: Data) throws {}
  func encrypt(data: Data) throws -> Data? { data }
  func decrypt(data: Data) throws -> Data? { data }
}
