import Foundation

@BLEActor
class TimeoutController {
  private var timer: DispatchSourceTimer?

  nonisolated init() {}

  func startTimer(with timeout: TimeInterval) {
    timer?.cancel()

    let source = DispatchSource.makeTimerSource(queue: BLEActor.queue)
    source.schedule(deadline: .now() + timeout, leeway: .milliseconds(10))
    source.setEventHandler { [weak self] in
      guard let self else { return }
      self.timer = nil
      self.timeoutDidFire()
    }

    timer = source
    source.resume()
  }

  func cancelTimer() {
    timer?.cancel()
    timer = nil
  }

  open func timeoutDidFire() {}
}
