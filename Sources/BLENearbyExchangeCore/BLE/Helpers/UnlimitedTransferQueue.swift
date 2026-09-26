import Foundation

@BLEActor
class UnlimitedTransferQueue {
  typealias Transfer = () -> Bool

  enum Priority {
    case regular
    case high
  }

  private var fifo: [(Transfer, Priority)] = []

  init() {}

  func clear() {
    fifo = []
  }

  func add(priority: Priority = .regular, value: @escaping Transfer) {
    fifo.append((value, priority))

    if fifo.count == 1 {
      resume()
    }
  }

  func resume() {
    while let index = fifo.firstIndex(where: { $0.1 == .high }) ?? fifo.firstIndex(where: { _ in true }) {
      guard fifo[index].0() else { return }
      fifo.remove(at: index)
    }
  }
}
