@testable import BLENearbyExchangeCore
import CryptoKit
import Foundation

struct PlainTextCipher: MessageCipherInterface {
  var localPublicKey: P384.KeyAgreement.PublicKey {
    P384.KeyAgreement.PrivateKey().publicKey
  }

  func establish(with _: Data) throws {}

  func encrypt(data: Data) throws -> Data? {
    data
  }

  func decrypt(data: Data) throws -> Data? {
    data
  }
}
