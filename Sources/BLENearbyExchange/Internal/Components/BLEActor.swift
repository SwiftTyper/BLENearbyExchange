import Foundation

@globalActor
actor BLEActor {
  static let queue = DispatchSerialQueue(label: "ble-actor")
  static let shared = BLEActor()

  nonisolated var unownedExecutor: UnownedSerialExecutor {
    Self.queue.asUnownedSerialExecutor()
  }

  /// based on https://github.com/swiftlang/swift/blob/53280d730e9946c98f349727eed9865482ab8c71/stdlib/public/Concurrency/MainActor.swift#L128
  static func assumeIsolated<T: Sendable>(
    _ operation: @BLEActor () throws -> T
  ) rethrows -> T {
    typealias YesActor = @BLEActor () throws -> T
    typealias NoActor = () throws -> T

    shared.preconditionIsolated()

    // To do the unsafe cast, we have to pretend it's @escaping.
    return try withoutActuallyEscaping(operation) { (_ isolatedFn: @escaping YesActor) throws -> T in
      let rawFn = unsafeBitCast(isolatedFn, to: NoActor.self)
      return try rawFn()
    }
  }
}
