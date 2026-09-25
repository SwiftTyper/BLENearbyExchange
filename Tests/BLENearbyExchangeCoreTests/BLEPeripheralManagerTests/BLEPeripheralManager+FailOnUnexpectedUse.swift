@testable import BLENearbyExchangeCore
import Foundation
import XCTest

extension BLEPeripheralManager {
  func failOnUnexpectedUse(
    file: StaticString = #filePath,
    line: UInt = #line,
  ) {
    let fail = { (name: String) in
      XCTFail("unexpected use of \(name)", file: file, line: line)
    }

    onStateChange = { _ in fail("onStateChange") }
    onPayloadReceived = { _ in fail("onPayloadReceived") }
    onRoleConfirmed = { fail("onRoleConfirmed") }
    onPeerReceivedDataConfirmation = { fail("onPeerReceivedDataConfirmation") }
    onError = { fail("onError(\($0))") }
    onConnected = { fail("onConnected") }
    onSendProgress = { _ in fail("onSendProgress") }
    onReceiveProgress = { _ in fail("onReceiveProgress") }
  }
}
