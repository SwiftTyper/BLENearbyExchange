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

    central.onRoleReceived = { role in
      XCTAssertEqual(role, .central)
      roleReceived.fulfill()
    }

    central.startScanning(nonce: 2)

    await fulfillment(of: [roleReceived], timeout: 2)
  }

  func test_higherPeerNonceMakesUsThePeripheral() async {
    let peer = MockPeripheralSpy(nonce: 3)

    let central = await makeSUT(peer: peer)

    let roleReceived = expectation(description: "a role was resolved")

    central.onRoleReceived = { role in
      XCTAssertEqual(role, .peripheral)
      roleReceived.fulfill()
    }

    central.startScanning(nonce: 2)

    await fulfillment(of: [roleReceived], timeout: 2)
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
    handshakeFailed.assertForOverFulfill = false
    
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
    rangingFailed.assertForOverFulfill = false

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
