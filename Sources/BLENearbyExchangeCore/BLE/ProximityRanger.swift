import Foundation

#if canImport(NearbyInteraction)
  import NearbyInteraction
#endif

@BLEActor
public class ProximityRanger: NSObject {
  var onDistance: ((Float) -> Void)?
  var onError: ((Error) -> Void)?
  
  var isSupported: Bool {
    #if !os(macOS)
      return NISession.deviceCapabilities.supportsPreciseDistanceMeasurement
    #else
      return false
    #endif
  }

  #if !os(macOS)
    private var session: NISession?
  #endif

  func localDiscoveryToken() -> Data? {
    #if !os(macOS)
      session = .init()
      session?.delegateQueue = BLEActor.queue
      session?.delegate = self

      guard let token = session?.discoveryToken
      else { return nil }

      return try? NSKeyedArchiver.archivedData(
        withRootObject: token,
        requiringSecureCoding: true
      )
    #else
      return nil
    #endif
  }

  func startRanging(peerToken: Data) throws {
    #if !os(macOS)
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
    #else
      throw Failure.unsupported
    #endif
  }

  func stop() {
    #if !os(macOS)
      session?.invalidate()
      session = nil
    #endif
  }
}

#if !os(macOS)
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
#endif

extension ProximityRanger {
  enum Failure: Error {
    case unarchive
    case missingSession
    case unsupported
  }
}
