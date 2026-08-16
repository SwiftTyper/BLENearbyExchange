import CoreBluetooth
import Foundation

public enum NearbyExchange {
  public struct Configuration: Sendable {
    var serviceUUID: UUID
    var distanceThreshold: Float
    var timeout: TimeInterval

    public init(
      serviceUUID: UUID = Configuration.defaultServiceUUID,
      distanceThreshold: Float = 0.15,
      timeout: TimeInterval = 60
    ) {
      self.serviceUUID = serviceUUID
      self.distanceThreshold = distanceThreshold
      self.timeout = timeout
    }

    public static let defaultServiceUUID = UUID(
      uuidString: "B1E0E4CE-1234-4E45-8A52-4259455843AB"
    )!
  }
}
