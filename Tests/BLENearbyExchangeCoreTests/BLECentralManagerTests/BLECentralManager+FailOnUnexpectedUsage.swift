@testable import BLENearbyExchangeCore
import Foundation
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
    onPeerReceivedDataConfirmation = { fail("onPeerReceivedDataConfirmation") }
    onError = { fail("onError(\($0))") }
    onConnected = { _ in fail("onConnected") }
    onSendProgress = { _ in fail("onSendProgress") }
    onReceiveProgress = { _ in fail("onReceiveProgress") }
    onDistance = { _,_  in fail("onDistance") }
    onNonceConflict = { fail("onNonceConflict") }
  }
}
