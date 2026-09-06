import Foundation

@BLEActor
final class AsyncCurrentValue<T: Sendable> {
  private(set) var value: T
  private var continuations: [UUID: AsyncStream<T>.Continuation] = [:]

  nonisolated init(_ value: T) {
    self.value = value
  }

  func receive() -> AsyncStream<T> {
    AsyncStream { continuation in
      let id = UUID()
      continuations[id] = continuation
      continuation.yield(value)

      continuation.onTermination = { _ in
        Task { await self.removeStream(id: id) }
      }
    }
  }

  func send(_ value: T) {
    self.value = value
    for continuation in continuations.values {
      continuation.yield(value)
    }
  }

  private func removeStream(id: UUID) {
    continuations.removeValue(forKey: id)
  }
}
