import Foundation

@BLEActor
public class TimeoutController {
  private var clock: any Clock<Duration>
  private var task: Task<Void, Never>?

  nonisolated init(
    clock: any Clock<Duration>
  ) {
    self.clock = clock
  }

  func startTimer(with timeout: Int) {
    guard task == nil else { return }
    
    self.task = Task {
      try? await clock.sleep(for: .seconds(timeout), tolerance: .milliseconds(10))
      guard !Task.isCancelled else { return }
      timeoutDidFire()
    }
  }

  func cancelTimer() {
    task?.cancel()
    task = nil
  }

  open func timeoutDidFire() {}
}
