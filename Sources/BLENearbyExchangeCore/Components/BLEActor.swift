import Foundation

@globalActor
public actor BLEActor {
  public static let queue = DispatchSerialQueue(label: "ble-actor")
  public static let shared = BLEActor()
  
  private init() {}

  public nonisolated var unownedExecutor: UnownedSerialExecutor {
    Self.queue.asUnownedSerialExecutor()
  }
}
