import Foundation
import NearbyInteraction

@BLEActor
final class ProximityRanger: NSObject {
  var onDistance: ((Float) -> Void)?
  var onError: ((Error) -> Void)?

  static var isSupported: Bool {
    return NISession.deviceCapabilities.supportsPreciseDistanceMeasurement
  }

  private var session: NISession?

  func localDiscoveryToken() -> Data? {
    session = .init()
    session?.delegateQueue = BLEActor.queue
    session?.delegate = self

    guard let token = session?.discoveryToken
    else { return nil }

    return try? NSKeyedArchiver.archivedData(
      withRootObject: token,
      requiringSecureCoding: true
    )
  }

  func startRanging(peerToken: Data) throws {
    guard
      let token = try NSKeyedUnarchiver.unarchivedObject(
        ofClass: NIDiscoveryToken.self,
        from: peerToken
      )
    else { throw Failure.unarchive }

    let config = NINearbyPeerConfiguration(peerToken: token)

    guard let session
    else { throw Failure.missingSession }

    session.run(config)
  }

  func stop() {
    session?.invalidate()
    session = nil
  }
}

extension ProximityRanger: @BLEActor NISessionDelegate {
  func session(
    _: NISession,
    didUpdate nearbyObjects: [NINearbyObject]
  ) {
    guard let distance = nearbyObjects.first?.distance
    else { return }

    onDistance?(distance)
  }

  func session(_: NISession, didInvalidateWith error: Error) {
    onError?(error)
  }
}

extension ProximityRanger {
  enum Failure: Error {
    case unarchive
    case missingSession
  }
}
