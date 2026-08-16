import Foundation

extension ExchangeSession {
  enum Event {
    case connected
    case distance(Float)
    case progress(Double)
    case received(Data)
    case completed
    case failed(ExchangeError)
  }
}
