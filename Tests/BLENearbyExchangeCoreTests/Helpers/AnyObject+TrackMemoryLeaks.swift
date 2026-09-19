import Foundation
import XCTest

extension XCTestCase {
  func trackForMemoryLeaks(
    instance: some Sendable & AnyObject,
    file: StaticString = #filePath,
    line: UInt = #line,
  ) {
    addTeardownBlock { [weak instance] in
      XCTAssertNil(
        instance,
        "Instance should have been deallocated. Potential memory leak.",
        file: file,
        line: line,
      )
    }
  }
}
