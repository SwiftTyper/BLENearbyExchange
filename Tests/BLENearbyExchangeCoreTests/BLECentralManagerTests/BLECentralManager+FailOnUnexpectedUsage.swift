import Foundation
@testable import BLENearbyExchangeCore
import XCTest

extension BLECentralManager {
  func failOnUnexpectedUse(
    file: StaticString = #filePath,
    line: UInt = #line,
  ) {
    let fail = { (name: String) in
      XCTFail("unexpected use of \(name)", file: file, line: line)
    }
    
    onStateChange = { _ in fail("onStateChange") }
    onPayloadReceived = { _ in fail("onPayloadReceived") }
    onRoleReceived = { _ in fail("onRoleReceived") }
    onPeerReceivedDataConfirmation = { fail("onPeerReceivedDataConfirmation") }
    onError = { fail("onError(\($0))") }
    onConnected = { fail("onConnected") }
    onSendProgress = { _ in fail("onSendProgress") }
    onReceiveProgress = { _ in fail("onReceiveProgress") }
  }
}
