import Foundation

struct TransferProgress: Equatable {
  init(
    bytes: Int = 0,
    total: Int = 0
  ) {
    self.bytes = bytes
    self.total = total
  }

  let bytes: Int
  let total: Int
}
