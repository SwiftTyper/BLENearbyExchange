@testable import BLENearbyExchangeCore
import CoreBluetooth
import CoreBluetoothMock
import Foundation
import Synchronization
import XCTest

final class MockCentralSpy: @unchecked Sendable {
  private(set) var spec: CBMCentralSpec!
  private let state = Mutex<[Update]>([])

  enum Update: Equatable {
    case payload(Data)
    case control(GATT.Control)
  }

  init() {
    self.spec = CBMCentralSpec(delegate: self)
  }

  var onControl: ((GATT.Control) -> Void)?

  var updates: [Update] { state.withLock { $0 } }

  func subscribe(to characteristics: [CBMMutableCharacteristic]) {
    for characteristic in characteristics {
      spec.simulateSubscription(to: characteristic)
    }
  }
}

extension MockCentralSpy: CBMCentralSpecDelegate {
  func central(
    _: CBMCentralSpec,
    didReceiveUpdate value: Data,
    for characteristic: CBMMutableCharacteristic
  ) {
    switch characteristic.uuid {
    case GATT.payload.cbuuid:
      state.withLock { $0.append(.payload(value)) }

    case GATT.control.cbuuid:
      guard
        let raw = value.first,
        let control = GATT.Control(rawValue: raw)
      else { return }

      state.withLock { $0.append(.control(control)) }
      onControl?(control)

    default:
      return
    }
  }
}

@BLEActor
final class BLEPeripheralManagerTests: XCTestCase {
  func test_terminationDuringPayloadTransfer_terminateControlTakesPrecence() async throws {
    let peripheral = await makeSUT()
    let peer = MockCentralSpy()

    try await connect(peer, to: peripheral)

    let payload = Data(repeating: 0x00, count: 4000)
    let frameCount = Chunker.chunk(payload, mtu: peer.spec.maximumUpdateValueLength).count

    let terminateReceived = expectation(description: "the peer received the terminate control")

    peer.onControl = { control in
      XCTAssertEqual(control, .cancelled)
      terminateReceived.fulfill()
    }

    let terminateSent = expectation(description: "the terminate control was sent")

    peripheral.send(payload: payload)

    peripheral.sendTerminate(.cancelled) {
      terminateSent.fulfill()
    }

    await fulfillment(of: [terminateSent, terminateReceived], timeout: 1.0)

    let payloadFrames = peer.updates.filter {
      if case .payload = $0 { true } else { false }
    }
    
    XCTAssertLessThan(payloadFrames.count, frameCount)
    XCTAssertEqual(peer.updates.last, .control(.cancelled))
  }

  func test_centralDisconnection_propagatesError() async {

  }

  func test_send_transfersFullPayload() async {

  }

  func test_periphalReceivesPeersToken_startsRanging() async {

  }

  func test_centralSendsPayload_peripheralRebuildsPayload() async {

  }

  func test_centralSendsControl_peripheralPropagesError() async {

  }

  func test_centralReceivedFullPayloadSendsDone_peripheralReceivesConfirmation() async {

  }

  func test_peripheralOnSubscription_callsConnectionCallbacks() async {

  }
}

extension BLEPeripheralManagerTests {
  private func makeSUT() async -> BLEPeripheralManager {
    CBMCentralManagerMock.tearDownSimulation()
    CBMCentralManagerMock.simulateInitialState(.poweredOn)

    let peripheral = BLEPeripheralManager(
      configuration: .init(),
      ranger: MockRanger(),
      forceMock: true
    )

    let poweredOn = expectation(description: "the manager powered on")

    peripheral.onStateChange = { state in
      XCTAssertEqual(state, .poweredOn)
      poweredOn.fulfill()
    }

    await fulfillment(of: [poweredOn], timeout: 0.2)

    return peripheral
  }

  private func connect(
    _ peer: MockCentralSpy,
    to peripheral: BLEPeripheralManager
  ) async throws {
    try await peripheral.startAdvertising(nonce: 1)

    let subscribed = expectation(description: "the peer subscribed")
    let roleConfirmed = expectation(description: "role confirmed")

    peripheral.onConnected = { subscribed.fulfill() }
    peripheral.onRoleConfirmed = { roleConfirmed.fulfill() }
    
    peer.spec.simulateConnection()

    let characteristics = peer.spec.simulateCharacteristicDiscovery(
      [GATT.payload.cbuuid, GATT.control.cbuuid, GATT.handshake.cbuuid],
      forService: NearbyExchange.Configuration.defaultServiceUUID.cbuuid
    )

    peer.subscribe(to: characteristics)
    
    await fulfillment(of: [subscribed, roleConfirmed], timeout: 0.2)
  }
}
