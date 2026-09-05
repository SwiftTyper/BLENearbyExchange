@testable import BLENearbyExchangeCore
import Foundation

@BLEActor
final class MockRanger: ProximityRanger {
  var localToken: Data? = Data("local-token".utf8)
  var rangingError: Error?

  private(set) var peerToken: Data?
  private(set) var isStopped = false

  override func localDiscoveryToken() -> Data? {
    localToken
  }

  override func startRanging(peerToken: Data) throws {
    if let rangingError {
      throw rangingError
    }
    self.peerToken = peerToken
  }

  override func stop() {
    isStopped = true
  }
}

extension MockRanger {
  enum Failure: Error {
    case rangingUnavailable
  }
}
