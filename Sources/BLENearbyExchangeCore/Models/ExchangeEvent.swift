import Foundation

public extension ExchangeSession {
  enum Event: Sendable, Equatable {
    case connected(_ deviceId: UUID)
    case distance(_ deviceId: UUID, _ distance: Float)
    case choosen(_ deviceId: UUID)
    case progress(Double)
    case received(_ payload: Data)
    case completed
    case failed(ExchangeError)
  }
}
