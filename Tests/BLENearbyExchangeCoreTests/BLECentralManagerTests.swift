@testable import BLENearbyExchangeCore
import CoreBluetooth
import CoreBluetoothMock
import Foundation
import XCTest

@BLEActor
final class BLECentralManagerTests: XCTestCase {
  private func makeSUT(peer: MockPeripheralSpy) -> BLECentralManager {
    CBMCentralManagerMock.tearDownSimulation()
    CBMCentralManagerMock.simulateRSSIDeviation(.none)
    CBMCentralManagerMock.simulatePeripherals([peer.spec])
    CBMCentralManagerMock.simulateInitialState(.poweredOn)

    let central = BLECentralManager(
      configuration: .init(),
      ranger: MockRanger(),
      forceMock: true
    )
    
    return central
  }

  func testLowerPeerNonceMakesUsTheCentral() async {
    let peer = MockPeripheralSpy(nonce: 1)

    let central = makeSUT(peer: peer)

    let poweredOn = expectation(description: "the manager powered on")

    central.onStateChange = { state in
      XCTAssertEqual(state, .poweredOn)
      poweredOn.fulfill()
    }

    await fulfillment(of: [poweredOn], timeout: 2)

    let roleReceived = expectation(description: "a role was resolved")

    central.onRoleReceived = { role in
      XCTAssertEqual(role, .central)
      roleReceived.fulfill()
    }

    central.startScanning(nonce: 2)

    await fulfillment(of: [roleReceived], timeout: 2)
  }

  func testHigherPeerNonceMakesUsThePeripheral() async {
    let peer = MockPeripheralSpy(nonce: 3)

    let central = makeSUT(peer: peer)

    let poweredOn = expectation(description: "the manager powered on")

    central.onStateChange = { state in
      XCTAssertEqual(state, .poweredOn)
      poweredOn.fulfill()
    }

    await fulfillment(of: [poweredOn], timeout: 2)

    let roleReceived = expectation(description: "a role was resolved")

    central.onRoleReceived = { role in
      XCTAssertEqual(role, .peripheral)
      roleReceived.fulfill()
    }

    central.startScanning(nonce: 2)

    await fulfillment(of: [roleReceived], timeout: 2)
  }

  func testIdenticalNonceIsReportedAsACollision() async {
    let peer = MockPeripheralSpy(nonce: 2)

    let central = makeSUT(peer: peer)

    let poweredOn = expectation(description: "the manager powered on")

    central.onStateChange = { state in
      XCTAssertEqual(state, .poweredOn)
      poweredOn.fulfill()
    }

    await fulfillment(of: [poweredOn], timeout: 2)

    let roleReceived = expectation(description: "a role was resolved")

    central.onRoleReceived = { role in
      XCTAssertNil(role)
      roleReceived.fulfill()
    }

    central.startScanning(nonce: 2)

    await fulfillment(of: [roleReceived], timeout: 2)
  }

  func testAdvertisementWithoutANonceIsIgnored() async {
    let peer = MockPeripheralSpy(advertisedName: "not a nonce")

    let central = makeSUT(peer: peer)

    let poweredOn = expectation(description: "the manager powered on")

    central.onStateChange = { state in
      XCTAssertEqual(state, .poweredOn)
      poweredOn.fulfill()
    }

    await fulfillment(of: [poweredOn], timeout: 2)

    let roleReceived = expectation(description: "a role was resolved")
    roleReceived.isInverted = true

    central.onRoleReceived = { _ in
      roleReceived.fulfill()
    }

    central.startScanning(nonce: 2)

    await fulfillment(of: [roleReceived], timeout: 0.5)
  }
}
