@testable import BLENearbyExchangeCore
import Foundation

@BLEActor
final class MockRanger: ProximityRanger {
  var localToken: Data?
  var rangingError: Error?
  var onStartRanging: ((Data) -> Void)?

  private(set) var peerToken: Data?

  init(
    localToken: Data? = Data("local-token".utf8)
  ) {
    self.localToken = localToken
  }

  override func localDiscoveryToken() -> Data? {
    localToken
  }

  override func startRanging(peerToken: Data) throws {
    if let rangingError {
      throw rangingError
    }
    self.peerToken = peerToken
    onStartRanging?(peerToken)
  }
}

extension MockRanger {
  enum Failure: Error {
    case rangingUnavailable
  }
}
