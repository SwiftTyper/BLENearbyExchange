@testable import BLENearbyExchangeCore
import Foundation

@BLEActor
final class MockRanger: ProximityRanger {
  var localToken: Data?
  var rangingError: Error?
  var onStartRanging: ((Data) -> Void)?

  init(
    localToken: Data? = Data("local-token".utf8)
  ) {
    self.localToken = localToken
  }

  override func localDiscoveryToken() -> Data? {
    localToken
  }

  override func startRanging(peerToken: Data) throws {
    if let rangingError { throw rangingError }
    onStartRanging?(peerToken)
  }
}

extension MockRanger {
  enum Failure: Error {
    case rangingUnavailable
  }
}
