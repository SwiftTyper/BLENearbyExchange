import Foundation
import CryptoKit

struct MessageCipher: MessageCipherInterface {
  private var sharedKey: SymmetricKey?
  private let localPrivateKey: P384.KeyAgreement.PrivateKey
  
  init() {
    self.localPrivateKey = .init()
  }
  
  var localPublicKey: P384.KeyAgreement.PublicKey {
    self.localPrivateKey.publicKey
  }
  
  mutating func establish(with peerPublicKeyData: Data) throws {
    let publicKey = try P384.KeyAgreement.PublicKey(rawRepresentation: peerPublicKeyData)
    let sharedSecret = try localPrivateKey.sharedSecretFromKeyAgreement(with: publicKey)
    
    let key = sharedSecret.hkdfDerivedSymmetricKey(
      using: SHA256.self,
      salt: Data(),
      sharedInfo: Data("BLECommunication".utf8),
      outputByteCount: 48
    )
    
    self.sharedKey = key
  }
  
  func encrypt(data: Data) throws -> Data? {
    guard let sharedKey else { throw Failure.setupIncomplete }
    let box = try AES.GCM.seal(data, using: sharedKey)
    return box.combined
  }
  
  func decrypt(data: Data) throws -> Data? {
    guard let sharedKey else { throw Failure.setupIncomplete }
    return try AES.GCM.open(.init(combined: data), using: sharedKey)
  }
  
  private enum Failure: Error {
    case setupIncomplete
  }
}
