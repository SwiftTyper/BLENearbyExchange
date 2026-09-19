import Foundation

@BLEActor
public class TimeoutController {
  private let clock: any Clock<Duration>
  private var task: Task<Void, Never>?

  nonisolated init(
    clock: any Clock<Duration>
  ) {
    self.clock = clock
  }

  func startTimer(with timeout: Int) {
    guard task == nil else { return }
    
    self.task = Task { [weak self] in
      try? await self?.clock.sleep(for: .seconds(timeout), tolerance: .milliseconds(10))
      
      guard !Task.isCancelled else { return }
      
      self?.timeoutDidFire()
    }
  }

  func cancelTimer() {
    task?.cancel()
    task = nil
  }

  open func timeoutDidFire() {}
}
