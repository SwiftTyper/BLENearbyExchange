@testable import BLENearbyExchangeCore
import CoreBluetooth
import CoreBluetoothMock
import Foundation
import XCTest

@BLEActor
final class BLECentralManagerTests: XCTestCase {
  func test_lowerPeerNonceMakesUsTheCentral() async {
    let peer = MockPeripheralSpy(nonce: 1)

    let central = await makeSUT(peer: peer)

    let roleReceived = expectation(description: "a role was resolved")
    let connected = expectation(description: "the peer connected")
    
    central.onRoleReceived = { role in
      XCTAssertEqual(role, .central)
      roleReceived.fulfill()
    }
    
    central.onConnected = { connected.fulfill() }

    central.startScanning(nonce: 2)
    
    await fulfillment(of: [roleReceived, connected], timeout: 2)
    
    XCTAssertTrue(peer.isConnected)
  }

  func test_higherPeerNonceMakesUsThePeripheral() async {
    let peer = MockPeripheralSpy(nonce: 3)

    let central = await makeSUT(peer: peer)

    let roleReceived = expectation(description: "a role was resolved")
    let notConnected = expectation(description: "the peer didn't connect")
    notConnected.isInverted = true

    central.onRoleReceived = { role in
      XCTAssertEqual(role, .peripheral)
      roleReceived.fulfill()
    }
    
    central.onConnected = { notConnected.fulfill() }

    central.startScanning(nonce: 2)
    
    await fulfillment(of: [roleReceived, notConnected], timeout: 2)
  }

  func test_identicalNonceIsReportedAsACollision() async {
    let peer = MockPeripheralSpy(nonce: 2)

    let central = await makeSUT(peer: peer)

    let roleReceived = expectation(description: "a role was resolved")

    central.onRoleReceived = { role in
      XCTAssertNil(role)
      roleReceived.fulfill()
    }

    central.startScanning(nonce: 2)

    await fulfillment(of: [roleReceived], timeout: 2)
  }

  func test_advertisementWithoutANonceIsIgnored() async {
    let peer = MockPeripheralSpy(advertisedName: "not a nonce")

    let central = await makeSUT(peer: peer)

    let roleReceived = expectation(description: "a role was resolved")
    roleReceived.isInverted = true

    central.onRoleReceived = { _ in
      roleReceived.fulfill()
    }

    central.startScanning(nonce: 2)

    await fulfillment(of: [roleReceived], timeout: 0.5)
  }
}

extension BLECentralManagerTests {
  func test_receivingPeersTokenStartsNIRanging() async {
    let peer = MockPeripheralSpy(nonce: 1)
    
    let localToken = Data("local-token".utf8)
    let ranger = MockRanger(localToken: localToken)

    let central = await makeSUT(peer: peer, ranger: ranger)

    await connect(central, nonce: 2)
    
    XCTAssertEqual(peer.handshakeToken, localToken)
    
    let peerToken = Data("peer-token".utf8)
    let rangingStarted = expectation(description: "ranging started")

    ranger.onStartRanging = { token in
      XCTAssertEqual(token, peerToken)
      rangingStarted.fulfill()
    }

    peer.notify(peerToken, on: GATT.handshake)

    await fulfillment(of: [rangingStarted], timeout: 2)

    XCTAssertEqual(ranger.peerToken, peerToken)
  }
  
  func test_failureToCreateNITokenFailsHandshake() async {
    let peer = MockPeripheralSpy(nonce: 1)
    let ranger = MockRanger()
    ranger.localToken = nil
    
    let central = await makeSUT(peer: peer, ranger: ranger)
    
    let handshakeFailed = expectation(description: "the handshake failed")
    
    central.onError = { error in
      XCTAssertEqual(error, .rangingFailed("No local discovery token."))
      handshakeFailed.fulfill()
    }
    
    central.startScanning(nonce: 2)
    
    await fulfillment(of: [handshakeFailed], timeout: 2)
    
    XCTAssertNil(peer.handshakeToken)
  }

  func test_localRangingFailureIsReported() async {
    let peer = MockPeripheralSpy(nonce: 1)
    let ranger = MockRanger()
    ranger.rangingError = MockRanger.Failure.rangingUnavailable

    let central = await makeSUT(peer: peer, ranger: ranger)

    await connect(central, nonce: 2)

    let rangingFailed = expectation(description: "ranging failed")

    central.onError = { error in
      guard case .rangingFailed = error else {
        return XCTFail("Expected a ranging failure, got \(error).")
      }

      rangingFailed.fulfill()
    }

    peer.notify(Data("peer-token".utf8), on: GATT.handshake)

    await fulfillment(of: [rangingFailed], timeout: 2)

    XCTAssertNil(ranger.peerToken)
  }
}

extension BLECentralManagerTests {
  func test_sendingAPayloadDeliversItToThePeer() async {
    let peer = MockPeripheralSpy(nonce: 1)

    let central = await makeSUT(peer: peer)

    await connect(central, nonce: 2)

    let payload = Data((0 ..< 500).map { UInt8($0 % 251) })

    let payloadDelivered = expectation(description: "the peer received the payload")

    peer.onPayload = { received in
      XCTAssertEqual(received, payload)
      payloadDelivered.fulfill()
    }

    let sendCompleted = expectation(description: "the send progress completed")

    central.onSendProgress = { progress in
      guard progress.bytes == payload.count
      else { return }

      XCTAssertEqual(progress, TransferProgress(bytes: payload.count, total: payload.count))
      sendCompleted.fulfill()
    }

    central.send(payload: payload)

    await fulfillment(of: [payloadDelivered, sendCompleted], timeout: 2)
  }
  
  func test_payloadIsDeliveredAndConfirmed() async {
    let peer = MockPeripheralSpy(nonce: 1)
    
    let central = await makeSUT(peer: peer)
    
    await connect(central, nonce: 2)
    
    let payload = Data((0 ..< 500).map { UInt8($0 % 251) })
    
    let payloadReceived = expectation(description: "the payload was received")
    
    central.onPayloadReceived = { received in
      XCTAssertEqual(received, payload)
      payloadReceived.fulfill()
    }
    
    let receiveCompleted = expectation(description: "the receive progress completed")
    
    central.onReceiveProgress = { progress in
      guard progress.bytes == payload.count
      else { return }
      
      receiveCompleted.fulfill()
    }
    
    let receiptConfirmed = expectation(description: "receipt was confirmed to the peer")
    
    peer.onControl = { control in
      XCTAssertEqual(control, .done)
      receiptConfirmed.fulfill()
    }
    
    peer.send(payload: payload)
    
    await fulfillment(
      of: [payloadReceived, receiveCompleted, receiptConfirmed],
      timeout: 2
    )
  }
  
  func test_doneControlConfirmsThePeerReceivedThePayload() async {
    let peer = MockPeripheralSpy(nonce: 1)
    
    let central = await makeSUT(peer: peer)
    
    await connect(central, nonce: 2)
    
    let receiptConfirmed = expectation(description: "the peer confirmed receipt")
    
    central.onPeerReceivedDataConfirmation = {
      receiptConfirmed.fulfill()
    }
    
    peer.send(.done)
    
    await fulfillment(of: [receiptConfirmed], timeout: 2)
  }
}
  
extension BLECentralManagerTests {
  func test_cancelledControlFailsTheExchange() async {
    let peer = MockPeripheralSpy(nonce: 1)

    let central = await makeSUT(peer: peer)

    await connect(central, nonce: 2)

    let exchangeFailed = expectation(description: "the exchange failed")

    central.onError = { error in
      XCTAssertEqual(error, .cancelledByPeer)
      exchangeFailed.fulfill()
    }

    peer.send(.cancelled)

    await fulfillment(of: [exchangeFailed], timeout: 2)
  }

  func test_failedControlFailsTheExchange() async {
    let peer = MockPeripheralSpy(nonce: 1)

    let central = await makeSUT(peer: peer)

    await connect(central, nonce: 2)

    let exchangeFailed = expectation(description: "the exchange failed")

    central.onError = { error in
      XCTAssertEqual(error, .failedOnPeer)
      exchangeFailed.fulfill()
    }

    peer.send(.failed)

    await fulfillment(of: [exchangeFailed], timeout: 2)
  }
  
  func test_terminatingWritesTheControlAndCallsBack() async {
    let peer = MockPeripheralSpy(nonce: 1)

    let central = await makeSUT(peer: peer)

    await connect(central, nonce: 2)

    let terminateSent = expectation(description: "the terminate control was written")

    central.sendTerminate(.cancelled) {
      terminateSent.fulfill()
    }

    await fulfillment(of: [terminateSent], timeout: 2)

    XCTAssertEqual(peer.controls, [.cancelled])
  }

  func test_disconnectionIsReportedAsAnError() async {
    let peer = MockPeripheralSpy(nonce: 1)

    let central = await makeSUT(peer: peer)

    await connect(central, nonce: 2)

    let disconnectionReported = expectation(description: "the disconnection was reported")

    central.onError = { error in
      XCTAssertEqual(error, .disconnected)
      disconnectionReported.fulfill()
    }

    peer.disconnect()

    await fulfillment(of: [disconnectionReported], timeout: 2)
  }

  func test_stoppingCancelsTheConnection() async {
    let peer = MockPeripheralSpy(nonce: 1)

    let central = await makeSUT(peer: peer)

    await connect(central, nonce: 2)

    let peerDisconnected = expectation(description: "the peer disconnected")

    peer.onDisconnect = { _ in
      peerDisconnected.fulfill()
    }

    central.stop()

    await fulfillment(of: [peerDisconnected], timeout: 2)

    XCTAssertFalse(peer.isConnected)
  }
}

extension BLECentralManagerTests {
  private func makeSUT(
    peer: MockPeripheralSpy,
    ranger: MockRanger = MockRanger()
  ) async -> BLECentralManager {
    CBMCentralManagerMock.tearDownSimulation()
    CBMCentralManagerMock.simulateRSSIDeviation(.none)
    CBMCentralManagerMock.simulatePeripherals([peer.spec])
    CBMCentralManagerMock.simulateInitialState(.poweredOn)
    
    let central = BLECentralManager(
      configuration: .init(),
      ranger: ranger,
      forceMock: true
    )
    
    let poweredOn = expectation(description: "the manager powered on")
    
    central.onStateChange = { state in
      XCTAssertEqual(state, .poweredOn)
      poweredOn.fulfill()
    }
    
    await fulfillment(of: [poweredOn], timeout: 2)
    
    return central
  }
  
  private func connect(
    _ central: BLECentralManager,
    nonce: UInt64,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    let connected = expectation(description: "the peer connected")
    
    central.onConnected = {
      connected.fulfill()
    }
    
    central.onError = {
      XCTFail(
        "Unexpected error while connecting: \($0).",
        file: file,
        line: line
      )
    }
    
    central.startScanning(nonce: nonce)
    
    await fulfillment(of: [connected], timeout: 2)
    
    central.onError = nil
  }
}
