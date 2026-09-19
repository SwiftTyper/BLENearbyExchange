import Testing
@testable import BLENearbyExchangeCore

struct AdvertisementBudgetTests {
  var localNameBudgetData: Int {
    let advertisingDataLength: Int = 31
    let serviceUUID: Int = 16 + 2 ///  header (Length + AD Type) + 128bit uuid
    let flagByte: Int = 1 + 2 /// header(Length + AD Type) + flag byte
    let localNameHeader: Int = 2 /// header(Length + AD Type)
    return advertisingDataLength - serviceUUID - flagByte - localNameHeader
  }
  
  @Test(arguments: [UInt32.min, 1, UInt32.max])
  func advertisedNonceFitsAdvertisingPacket(localNonce: UInt32) {
    let name = RoleResolver.encode(localNonce).base64EncodedString()
    #expect(name.utf8.count <= localNameBudgetData)
  }
  
  @Test
  func largeNonceExceedsAdvertisingPacket() {
    let largeNonce: UInt64 = .init()
    let name = RoleResolver.encode(largeNonce).base64EncodedString()
    #expect(name.utf8.count > localNameBudgetData)
  }
}
