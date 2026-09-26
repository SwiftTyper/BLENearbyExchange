@testable import BLENearbyExchangeCore
import CoreBluetooth
import CoreBluetoothMock
import CryptoKit
import Foundation
import XCTest

@BLEActor
final class BLEPeripheralManagerTests: XCTestCase {
  func test_terminationDuringPayloadTransfer_terminateControlTakesPrecence() async throws {
    let peripheral = await makeSUT()
    peripheral.onSendProgress = { _ in }

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

    await fulfillment(of: [terminateSent, terminateReceived], timeout: 2.0)

    let payloadFrames = peer.updates.filter {
      if case .payload = $0 {
        true
      } else {
        false
      }
    }

    XCTAssertLessThan(payloadFrames.count, frameCount)
    XCTAssertEqual(peer.updates.last, .control(.cancelled))
  }

  func test_send_transfersFullPayloadToPeer() async throws {
    let peripheral = await makeSUT()
    peripheral.onSendProgress = { _ in }

    let peer = MockCentralSpy()

    try await connect(peer, to: peripheral)

    let payload = Data(repeating: 0x00, count: 4000)
    let frameCount = Chunker.chunk(payload, mtu: peer.spec.maximumUpdateValueLength).count

    peripheral.send(payload: payload)

    let fullyEnqueued = expectation(description: "the full payload was enqueued")

    peripheral.onSendProgress = { progress in
      guard progress.bytes == payload.count else { return }
      fullyEnqueued.fulfill()
    }

    let fullyReceivedPayload = expectation(description: "the full payload was received by the peer")
    fullyReceivedPayload.expectedFulfillmentCount = frameCount

    peer.onPayload = { _ in
      fullyReceivedPayload.fulfill()
    }

    await fulfillment(of: [fullyEnqueued, fullyReceivedPayload], timeout: 2.0)

    let peerReceivedFrameCount = peer.updates.filter {
      if case .payload = $0 {
        true
      } else {
        false
      }
    }.count

    XCTAssertEqual(frameCount, peerReceivedFrameCount)
  }

  func test_centralSends_peripheralReceivesFullPayload() async throws {
    let peripheral = await makeSUT()
    peripheral.onReceiveProgress = { _ in }

    let peer = MockCentralSpy()

    let characterisitcs = try await connect(peer, to: peripheral)
    let payloadChar = try characterisitcs.find(by: GATT.payload.cbuuid)

    let payload = Data(repeating: 0x00, count: 4000)
    let chunks = Chunker.chunk(payload, mtu: peer.spec.maximumUpdateValueLength)

    for chunk in chunks {
      peer.spec.simulateWriteRequest(chunk, for: payloadChar, withResponse: false) { result in
        switch result {
        case .success:
          break

        case .failure:
          XCTFail("Failed to queue write request")
        }
      }
    }

    let payloadReceived = expectation(description: "full payload received")

    peripheral.onPayloadReceived = { receivedPayload in
      XCTAssertEqual(payload, receivedPayload)
      payloadReceived.fulfill()
    }

    await fulfillment(of: [payloadReceived], timeout: 2.0)
  }

  func test_centralSendsDone_peripheralReceivesConfirmation() async throws {
    let peripheral = await makeSUT()
    let peer = MockCentralSpy()

    let characterisitcs = try await connect(peer, to: peripheral)
    let controlChar = try characterisitcs.find(by: GATT.control.cbuuid)

    let doneCommendSent = expectation(description: "done command sent")

    let doneCommend = Data([GATT.Control.done.rawValue])

    peer.spec.simulateWriteRequest(doneCommend, for: controlChar, withResponse: true) { result in
      switch result {
      case .success:
        doneCommendSent.fulfill()

      case let .failure(failure):
        XCTFail("\(failure.localizedDescription)")
      }
    }

    let receivedDoneCommend = expectation(description: "received done command")

    peripheral.onPeerReceivedDataConfirmation = {
      receivedDoneCommend.fulfill()
    }

    await fulfillment(of: [doneCommendSent, receivedDoneCommend], timeout: 2.0)
  }

  func test_peripheralsPayloadOutgoingQueueFull_doesntDropOtherOutgoingCommands() async throws {
    let peripheral = await makeSUT()

    peripheral.onReceiveProgress = { _ in }

    let peer = MockCentralSpy()

    let characterisitcs = try await connect(peer, to: peripheral)
    let payloadChar = try characterisitcs.find(by: GATT.payload.cbuuid)

    let outgoingPayload = Data(repeating: 0x00, count: 4000)
    let outgoingFrameCount = Chunker.chunk(outgoingPayload, mtu: peer.spec.maximumUpdateValueLength).count

    let transferStarted = expectation(description: "the peripheral's update queue is full")

    peripheral.onSendProgress = { [weak peripheral] progress in
      guard progress.bytes > 0, progress.bytes < outgoingPayload.count else { return }
      peripheral?.onSendProgress = nil
      transferStarted.fulfill()
    }

    peripheral.send(payload: outgoingPayload)

    await fulfillment(of: [transferStarted], timeout: 2.0)

    // this is significatly smaller than the outgoing payload so
    // that it finished way earlier and so the peripheral tries to send done during the outgoing payload transfer
    let incomingPayload = Data(repeating: 0x01, count: 100)

    for chunk in Chunker.chunk(incomingPayload, mtu: peer.spec.maximumUpdateValueLength) {
      peer.spec.simulateWriteRequest(chunk, for: payloadChar, withResponse: false) { result in
        if case let .failure(failure) = result {
          XCTFail("\(failure.localizedDescription)")
        }
      }
    }

    let payloadReceived = expectation(description: "the peripheral received the incoming payload")

    peripheral.onPayloadReceived = { receivedPayload in
      XCTAssertEqual(incomingPayload, receivedPayload)
      payloadReceived.fulfill()
    }

    let doneReceived = expectation(description: "the peer received the done control")

    peer.onControl = { control in
      XCTAssertEqual(control, .done)
      doneReceived.fulfill()
    }

    let outgoingPayloadReceived = expectation(description: "the peer received the full outgoing payload")
    outgoingPayloadReceived.expectedFulfillmentCount = outgoingFrameCount

    peer.onPayload = { _ in
      outgoingPayloadReceived.fulfill()
    }

    await fulfillment(of: [payloadReceived, doneReceived, outgoingPayloadReceived], timeout: 2.0)

    XCTAssertTrue(peer.updates.contains(.control(.done)))
  }

  func test_doneDuringOutgoingPayloadTransfer_doneControlTakesPrecedence() async throws {
    let peripheral = await makeSUT()

    peripheral.onReceiveProgress = { _ in }

    let peer = MockCentralSpy()

    let characterisitcs = try await connect(peer, to: peripheral)
    let payloadChar = try characterisitcs.find(by: GATT.payload.cbuuid)

    let outgoingPayload = Data(repeating: 0x00, count: 4000)
    let outgoingFrameCount = Chunker.chunk(outgoingPayload, mtu: peer.spec.maximumUpdateValueLength).count

    let transferStarted = expectation(description: "the peripheral's update queue is full")

    peripheral.onSendProgress = { [weak peripheral] progress in
      guard progress.bytes > 0, progress.bytes < outgoingPayload.count else { return }
      peripheral?.onSendProgress = { _ in }
      transferStarted.fulfill()
    }

    peripheral.send(payload: outgoingPayload)

    await fulfillment(of: [transferStarted], timeout: 2.0)

    let incomingPayload = Data(repeating: 0x01, count: 100)

    for chunk in Chunker.chunk(incomingPayload, mtu: peer.spec.maximumUpdateValueLength) {
      peer.spec.simulateWriteRequest(chunk, for: payloadChar, withResponse: false) { result in
        if case let .failure(failure) = result {
          XCTFail("\(failure.localizedDescription)")
        }
      }
    }

    let payloadReceived = expectation(description: "the peripheral received the incoming payload")

    peripheral.onPayloadReceived = { receivedPayload in
      XCTAssertEqual(incomingPayload, receivedPayload)
      payloadReceived.fulfill()
    }

    let doneReceived = expectation(description: "the peer received the done control")

    peer.onControl = { control in
      XCTAssertEqual(control, .done)
      doneReceived.fulfill()
    }

    let outgoingPayloadReceived = expectation(description: "the peer received the full outgoing payload")
    outgoingPayloadReceived.expectedFulfillmentCount = outgoingFrameCount

    peer.onPayload = { _ in
      outgoingPayloadReceived.fulfill()
    }

    await fulfillment(of: [payloadReceived, doneReceived, outgoingPayloadReceived], timeout: 2.0)

    let updates = peer.updates
    let doneIndex = try XCTUnwrap(updates.firstIndex(of: .control(.done)))
    let payloadFramesBeforeDone = updates[..<doneIndex].filter {
      if case .payload = $0 {
        true
      } else {
        false
      }
    }

    XCTAssertLessThan(payloadFramesBeforeDone.count, outgoingFrameCount)
  }

  func test_centralDisconnection_propagatesError() async throws {
    let peripheral = await makeSUT()
    let peer = MockCentralSpy()

    try await connect(peer, to: peripheral)

    let errorExpectation = expectation(description: "error")

    peripheral.onError = { error in
      errorExpectation.fulfill()
      XCTAssertEqual(error, .disconnected)
    }

    peer.spec.simulateDisconnection()

    await fulfillment(of: [errorExpectation], timeout: 2.0)
  }

  func test_centralSendsFailure_peripheralPropagesError() async throws {
    let peripheral = await makeSUT()
    let peer = MockCentralSpy()

    let characterisitcs = try await connect(peer, to: peripheral)
    let controlCharacteristic = try characterisitcs.find(by: GATT.control.cbuuid)

    let errorExpectation = expectation(description: "error")

    peripheral.onError = { error in
      errorExpectation.fulfill()
      XCTAssertEqual(error, .failedOnPeer)
    }

    let failCommendSent = expectation(description: "sent failure")

    peer.spec.simulateWriteRequest(
      Data([GATT.Control.failed.rawValue]),
      for: controlCharacteristic,
      withResponse: true,
    ) { result in
      switch result {
      case .success:
        failCommendSent.fulfill()

      case let .failure(error):
        XCTFail("\(error.localizedDescription)")
      }
    }

    await fulfillment(of: [failCommendSent, errorExpectation], timeout: 2.0)
  }

  func test_periphalReceivesPeersToken_startsRangingAndSendsItsTokenToCentral() async throws {
    let peripheralTokenData = Data("peripheral-token".utf8)
    let mockRanger = MockRanger(localToken: peripheralTokenData)
    let peripheral = await makeSUT(ranger: mockRanger)
    let peer = MockCentralSpy()

    let characterisitcs = try await connect(peer, to: peripheral)
    let handshakeChar = try characterisitcs.find(by: GATT.handshake.cbuuid)

    let peerTokenData = Data("peer-token".utf8)
    let publicKey = P384.KeyAgreement.PrivateKey().publicKey
    let handshake = HandshakePayload(
      publicKey: publicKey.rawRepresentation,
      token: peerTokenData,
    )
    let peerHandshakeData = try JSONEncoder().encode(handshake)
    let lessThanMaxFrameSize = 20

    for chunk in Chunker.chunk(peerHandshakeData, mtu: lessThanMaxFrameSize) {
      peer.spec.simulateWriteRequest(
        chunk,
        for: handshakeChar,
        withResponse: false,
      ) { result in
        switch result {
        case .success:
          break

        case let .failure(error):
          XCTFail("\(error.localizedDescription)")
        }
      }
    }

    let centralReceivedToken = expectation(description: "central received token")

    peer.onHandshake = { receivedPeripheralHandshakeData in
      let payload = try? JSONDecoder().decode(HandshakePayload.self, from: receivedPeripheralHandshakeData)
      XCTAssertNotNil(payload)
      centralReceivedToken.fulfill()
      XCTAssertEqual(peripheralTokenData, payload?.token)
    }

    let peerTokenReceived = expectation(description: "peer token received")

    mockRanger.onStartRanging = { receivedTokenData in
      peerTokenReceived.fulfill()
      XCTAssertEqual(receivedTokenData, peerTokenData)
    }

    await fulfillment(of: [centralReceivedToken, peerTokenReceived], timeout: 1.0)
  }
}

extension BLEPeripheralManagerTests {
  private func makeSUT(
    ranger: ProximityRanger = MockRanger(),
    file: StaticString = #filePath,
    line: UInt = #line,
  ) async -> BLEPeripheralManager {
    CBMCentralManagerMock.tearDownSimulation()
    CBMCentralManagerMock.simulateInitialState(.poweredOn)

    let peripheral = BLEPeripheralManager(
      configuration: .init(),
      ranger: ranger,
      makeCipher: { PlainTextCipher() },
      forceMock: true,
    )

    trackForMemoryLeaks(instance: peripheral, file: file, line: line)
    peripheral.failOnUnexpectedUse(file: file, line: line)

    let poweredOn = expectation(description: "the manager powered on")

    peripheral.onStateChange = { state in
      XCTAssertEqual(state, .poweredOn)
      poweredOn.fulfill()
    }

    await fulfillment(of: [poweredOn], timeout: 2.0)

    return peripheral
  }

  @discardableResult
  private func connect(
    _ peer: MockCentralSpy,
    to peripheral: BLEPeripheralManager,
  ) async throws -> [CBMMutableCharacteristic] {
    try await peripheral.startAdvertising(nonce: 1)

    let subscribed = expectation(description: "the peer subscribed")
    let roleConfirmed = expectation(description: "role confirmed")

    peripheral.onConnected = { subscribed.fulfill() }
    peripheral.onRoleConfirmed = { roleConfirmed.fulfill() }

    peer.spec.simulateConnection()

    let characteristics = peer.spec.simulateCharacteristicDiscovery(
      [GATT.payload.cbuuid, GATT.control.cbuuid, GATT.handshake.cbuuid],
      forService: NearbyExchange.Configuration.defaultServiceUUID.cbuuid,
    )

    peer.subscribe(to: characteristics)

    await fulfillment(of: [subscribed, roleConfirmed], timeout: 2.0)

    return characteristics
  }
}

private extension [CBMMutableCharacteristic] {
  func find(
    by uuid: CBUUID,
    file: StaticString = #filePath,
    line: UInt = #line,
  ) throws -> CBMMutableCharacteristic {
    guard let characteristic = self.first(where: { $0.uuid == uuid })
    else {
      XCTFail("missing charactersitic", file: file, line: line)
      throw MissingCharacteristic()
    }

    return characteristic
  }

  struct MissingCharacteristic: Error {}
}
