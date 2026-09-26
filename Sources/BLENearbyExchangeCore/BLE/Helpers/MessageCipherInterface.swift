import CryptoKit
import Foundation

protocol MessageCipherInterface {
  var localPublicKey: P384.KeyAgreement.PublicKey { get }
  mutating func establish(with peerPublicKeyData: Data) throws
  func encrypt(data: Data) throws -> Data?
  func decrypt(data: Data) throws -> Data?
}
