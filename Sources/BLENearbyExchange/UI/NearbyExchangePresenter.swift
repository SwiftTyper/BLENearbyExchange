import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class NearbyExchangePresenter {
  enum Phase: Sendable, Equatable {
    case searching
    case approaching(distance: Float?)
    case exchanging(progress: Double)
    case completed
    case failed(ExchangeError)
  }

  private(set) var phase: Phase = .searching
  var isPresented = false

  private let configuration: NearbyExchange.Configuration
  private var session: ExchangeSession?
  private var continuation: CheckedContinuation<Data, any Error>?
  private var eventsTask: Task<Void, Never>?
  private var startTask: Task<Void, Never>?
  private var received: Data?
  private var smoothedDistance: Float?

  init(configuration: NearbyExchange.Configuration) {
    self.configuration = configuration
  }

  func run(payload: Data) async throws -> Data {
    let session = self.session ?? ExchangeSession(configuration: configuration)
    self.session = session

    guard continuation == nil, await !session.isRunning
    else { throw NearbyExchangeAction.Failure.busy }

    received = nil
    smoothedDistance = nil
    phase = .searching

    let events = await session.events.receive()

    isPresented = true

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation

        eventsTask = Task {
          for await event in events {
            await handle(event)
          }
        }

        startTask = Task {
          do {
            try await session.start(payload: payload)
          } catch {
            await handle(.failed(ExchangeError(error)))
          }
        }
      }
    } onCancel: { self.cancel() }
  }

  nonisolated func cancel() {
    Task {
      guard await !isFinished else { return }
      await finish(.failure(CancellationError()))
    }
  }

  private func handle(_ event: ExchangeSession.Event) async {
    guard !isFinished else { return }

    switch event {
    case .connected:
      guard phase == .searching else { return }
      phase = .approaching(distance: nil)

    case let .distance(distance):
      guard case .approaching = phase else { return }
      phase = .approaching(distance: distance)

    case let .progress(value):
      if case .approaching = phase {
        try? await Task.sleep(for: .seconds(0.5))
      }
      phase = .exchanging(progress: value)

    case let .received(data):
      received = data

    case .completed:
      guard let received else { return }
      phase = .completed
      try? await Task.sleep(for: .seconds(2))
      await finish(.success(received))

    case let .failed(error):
      phase = .failed(error)
      try? await Task.sleep(for: .seconds(2))
      await finish(.failure(error))
    }
  }

  private func finish(_ result: Result<Data, any Error>) async {
    guard let continuation else { return }

    eventsTask?.cancel()
    eventsTask = nil
    startTask?.cancel()
    startTask = nil
    self.continuation = nil

    if case let .failure(error) = result, !(error is ExchangeError) {
      await session?.terminate(.cancelled)
    }

    await session?.stop()

    isPresented = false

    continuation.resume(with: result)
  }
}

extension NearbyExchangePresenter {
  var isFinished: Bool {
    switch phase {
    case .completed, .failed: true
    default: false
    }
  }

  var progress: Double {
    switch phase {
    case .searching:
      0

    case let .approaching(distance):
      distance.map {
        $0 > 0 ? Self.clamped(Double(configuration.distanceThreshold / $0)) : 1
      } ?? 0

    case let .exchanging(progress):
      progress

    case .completed, .failed:
      1
    }
  }

  private static func clamped(_ progress: Double) -> Double {
    min(1, max(0, progress))
  }
}
