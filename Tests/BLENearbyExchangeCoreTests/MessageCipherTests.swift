@testable import BLENearbyExchangeCore
import Foundation
import Testing

struct MessageCipherTests {
  @Test func peersDecryptEachOthersMessages() throws {
    var centralCipher = MessageCipher()
    var peripheralCipher = MessageCipher()
    let centralPublicKey = centralCipher.localPublicKey.rawRepresentation
    let peripheralPublicKey = peripheralCipher.localPublicKey.rawRepresentation

    try centralCipher.establish(with: peripheralPublicKey)
    try peripheralCipher.establish(with: centralPublicKey)

    let centralMessage = Data("from central".utf8)
    let peripheralMessage = Data("from peripheral".utf8)

    let encryptedCentralMessage = try #require(try centralCipher.encrypt(data: centralMessage))
    let encryptedPeripheralMessage = try #require(try peripheralCipher.encrypt(data: peripheralMessage))

    #expect(try peripheralCipher.decrypt(data: encryptedCentralMessage) == centralMessage)
    #expect(try centralCipher.decrypt(data: encryptedPeripheralMessage) == peripheralMessage)
  }
}
