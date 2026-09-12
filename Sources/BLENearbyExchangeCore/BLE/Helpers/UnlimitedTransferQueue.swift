import Foundation

@BLEActor
class UnlimitedTransferQueue {
  typealias Transfer = () -> Bool
  
  private var stack: [Transfer] = []
  
  init() {}
  
  func clear() {
    stack = []
  }
  
  func add(value: @escaping Transfer) {
    stack.append(value)
    
    if stack.count == 1 {
      resume()
    }
  }
  
  func resume() {
    while !stack.isEmpty {
      guard let workItem = stack.popLast() else { return }
      
      if !workItem() {
        stack.append(workItem)
        return
      }
    }
  }
}
