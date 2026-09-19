import Foundation

public extension ExchangeSession {
  enum Event: Sendable, Equatable {
    case connected
    case distance(Float)
    case progress(Double)
    case received(Data)
    case completed
    case failed(ExchangeError)
  }
}
