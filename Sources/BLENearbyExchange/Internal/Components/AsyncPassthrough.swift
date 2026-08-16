import Foundation

@BLEActor
final class AsyncPassthrough<T: Sendable> {
  private var continuations: [UUID: AsyncStream<T>.Continuation] = [:]

  func receive() -> AsyncStream<T> {
    AsyncStream { continuation in
      let id = UUID()
      continuations[id] = continuation

      continuation.onTermination = { _ in
        Task { await self.removeStream(id: id) }
      }
    }
  }

  func send(_ event: T) {
    for continuation in continuations.values {
      continuation.yield(event)
    }
  }

  private func removeStream(id: UUID) {
    continuations.removeValue(forKey: id)
  }
}
