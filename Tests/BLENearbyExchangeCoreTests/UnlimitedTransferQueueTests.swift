@testable import BLENearbyExchangeCore
import Foundation
import Testing

@BLEActor
struct UnlimitedTransferQueueTests {
  @Test func addingToAnEmptyQueueTransfersImmediately() {
    let queue = UnlimitedTransferQueue()
    let link = LinkSpy()

    queue.add(value: link.transfer("first"))

    #expect(link.delivered == ["first"])
  }

  @Test func transfersAddedWhileLinkIsReadyAreDeliveredInOrder() {
    let queue = UnlimitedTransferQueue()
    let link = LinkSpy()

    queue.add(value: link.transfer("first"))
    queue.add(value: link.transfer("second"))
    queue.add(value: link.transfer("third"))

    #expect(link.delivered == ["first", "second", "third"])
  }

  @Test func failedTransferIsRetriedOnResume() {
    let queue = UnlimitedTransferQueue()
    let link = LinkSpy(onReady: queue.resume)
    link.isReady = false

    queue.add(value: link.transfer("first"))
    #expect(link.delivered.isEmpty)

    link.isReady = true

    #expect(link.delivered == ["first"])
  }

  @Test func resumeAfterBackpressureDeliversInOrder() {
    let queue = UnlimitedTransferQueue()
    let link = LinkSpy(onReady: queue.resume)
    link.isReady = false

    queue.add(value: link.transfer("first"))
    queue.add(value: link.transfer("second"))
    queue.add(value: link.transfer("third"))

    link.isReady = true

    #expect(link.delivered == ["first", "second", "third"])
  }

  @Test func highestPriorityWorkGetsExecutedFirst() {
    let queue = UnlimitedTransferQueue()
    let link = LinkSpy(onReady: queue.resume)
    link.isReady = false

    queue.add(value: link.transfer("second"))
    queue.add(priority: .high, value: link.transfer("first"))
    queue.add(value: link.transfer("third"))

    link.isReady = true

    #expect(link.delivered == ["first", "second", "third"])
  }

  @Test func clearDropsPendingTransfers() {
    let queue = UnlimitedTransferQueue()
    let link = LinkSpy()
    link.isReady = false

    queue.add(value: link.transfer("first"))
    queue.add(value: link.transfer("second"))
    queue.clear()

    link.isReady = true

    #expect(link.delivered.isEmpty)
  }

  @Test func addingAfterClearTransfersImmediately() {
    let queue = UnlimitedTransferQueue()
    let link = LinkSpy()
    link.isReady = false

    queue.add(value: link.transfer("dropped"))
    queue.clear()

    link.isReady = true
    queue.add(value: link.transfer("fresh"))

    #expect(link.delivered == ["fresh"])
  }

  @Test func addingAfterDrainTransfersImmediately() {
    let queue = UnlimitedTransferQueue()
    let link = LinkSpy(onReady: queue.resume)
    link.isReady = false

    queue.add(value: link.transfer("first"))
    link.isReady = true

    queue.add(value: link.transfer("second"))

    #expect(link.delivered == ["first", "second"])
  }
}

@BLEActor
private final class LinkSpy {
  var isReady = true {
    didSet {
      if isReady {
        onReady()
      }
    }
  }

  private(set) var delivered: [String] = []
  private var onReady: () -> Void

  init(onReady: @escaping () -> Void = {}) {
    self.onReady = onReady
  }

  func transfer(_ id: String) -> UnlimitedTransferQueue.Transfer {
    {
      guard self.isReady else { return false }

      self.delivered.append(id)
      return true
    }
  }
}
