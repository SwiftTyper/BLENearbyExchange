import Foundation

extension ExchangeSession {
  public enum Event: Sendable {
    case connected
    case distance(Float)
    case progress(Double)
    case received(Data)
    case completed
    case failed(ExchangeError)
  }
}
