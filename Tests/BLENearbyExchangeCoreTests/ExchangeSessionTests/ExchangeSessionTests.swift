@testable import BLENearbyExchangeCore
import Clocks
import CoreBluetooth
import CoreBluetoothMock
import Foundation
import Synchronization
import XCTest

@BLEActor
final class ExchangeSessionTests: XCTestCase {
  func test_nonceCollisionRestartsTheHandshakeWithAFreshNonce() async throws {
    let peerNonce: UInt32 = 1
    let collidingLocalNonce: UInt32 = 1
    let freshLocalNonce: UInt32 = 2

    let (session, central, peripheral) = makeSUT(
      localNonces: [collidingLocalNonce, freshLocalNonce],
    )

    let restarted = expectation(description: "the handshake restarted")
    central.onStartScanning = { nonce in
      guard nonce == freshLocalNonce else { return }
      restarted.fulfill()
    }

    let connected = expectation(description: "the peer connected")

    let events = session.events.receive()
    let observer = Task {
      for await event in events {
        guard case .connected = event else { continue }
        connected.fulfill()
      }
    }
    defer { observer.cancel() }

    try await session.start(payload: Data())

    simulatePeerDiscovery(advertising: peerNonce, on: central)

    await fulfillment(of: [restarted], timeout: 1)

    simulatePeerDiscovery(advertising: peerNonce, on: central)
    central.onConnected?()

    await fulfillment(of: [connected], timeout: 1)

    XCTAssertEqual(
      central.calls,
      [
        .startScanning(nonce: collidingLocalNonce),
        .stop,
        .startScanning(nonce: freshLocalNonce),
      ],
    )
    XCTAssertEqual(
      peripheral.calls,
      [
        .startAdvertising(nonce: collidingLocalNonce),
        .stop,
        .startAdvertising(nonce: freshLocalNonce),
        .stop,
      ],
    )
  }

  func test_unresolvedNonceCollisionKeepsRestartingTheHandshake() async throws {
    let peerNonce: UInt32 = 1
    let collidingLocalNonce: UInt32 = 1

    let (session, central, peripheral) = makeSUT(
      localNonces: [collidingLocalNonce],
    )

    try await session.start(payload: Data())

    for _ in 0 ..< 2 {
      let restarted = expectation(description: "the handshake restarted")
      central.onStartScanning = { _ in
        restarted.fulfill()
      }

      simulatePeerDiscovery(advertising: peerNonce, on: central)

      await fulfillment(of: [restarted], timeout: 1)
    }

    XCTAssertEqual(
      central.calls,
      [
        .startScanning(nonce: collidingLocalNonce),
        .stop,
        .startScanning(nonce: collidingLocalNonce),
        .stop,
        .startScanning(nonce: collidingLocalNonce),
      ],
    )
    XCTAssertEqual(
      peripheral.calls,
      [
        .startAdvertising(nonce: collidingLocalNonce),
        .stop,
        .startAdvertising(nonce: collidingLocalNonce),
        .stop,
        .startAdvertising(nonce: collidingLocalNonce),
      ],
    )
  }

  func test_distinctNoncesSucessfullyResolveARole() async throws {
    let peerNonce: UInt32 = 1
    let localNonce: UInt32 = 2

    let (session, central, peripheral) = makeSUT(
      localNonces: [localNonce],
    )

    let connected = expectation(description: "the peer connected")

    let events = session.events.receive()
    let observer = Task {
      for await event in events {
        guard case .connected = event else { continue }
        connected.fulfill()
      }
    }
    defer { observer.cancel() }

    try await session.start(payload: Data())

    simulatePeerDiscovery(advertising: peerNonce, on: central)
    central.onConnected?()

    await fulfillment(of: [connected], timeout: 1)

    XCTAssertEqual(
      central.calls,
      [
        .startScanning(nonce: localNonce),
      ],
    )
    XCTAssertEqual(
      peripheral.calls,
      [
        .startAdvertising(nonce: localNonce),
        .stop,
      ],
    )
  }
}

extension ExchangeSessionTests {
  func test_timesOut_whenItDoesntConnectWithPeerInTime() async throws {
    let clock = TestClock()
    let (session, _, _) = makeSUT(clock: clock)

    try await session.start(payload: Data())

    let timeoutEvent = expectation(description: "session did timeout")

    let events = session.events.receive()

    let observer = Task {
      for await event in events {
        XCTAssertEqual(event, .failed(.timedOut))
        timeoutEvent.fulfill()
      }
    }

    defer { observer.cancel() }

    await clock.advance(by: .seconds(60))

    await fulfillment(of: [timeoutEvent], timeout: 1.0)
  }

  func test_cancelsTimer_afterConnectingWithPeer() async throws {
    let localNonce: UInt32 = 2

    let clock = TestClock()
    let (session, central, _) = makeSUT(localNonces: [localNonce], clock: clock)

    let sessionNeverTimesOut = expectation(description: "session doesn't timeout")
    sessionNeverTimesOut.isInverted = true

    let events = session.events.receive()

    let observer = Task {
      for await event in events {
        switch event {
        case .failed(.timedOut): sessionNeverTimesOut.fulfill()
        default: break
        }
      }
    }

    defer { observer.cancel() }

    try await session.start(payload: Data())

    central.onConnected?()

    await clock.advance(by: .seconds(60))

    await fulfillment(of: [sessionNeverTimesOut], timeout: 0.2)
  }
}

extension ExchangeSessionTests {
  func test_desiredRangeNotReached_centralSide_doesntSendPayload() async throws {
    let payload = Data("payload".utf8)

    let (central, _) = try await rangeTestSetup(
      localDeviceType: .central,
      distanceThreshold: 0.5,
      mockedDistance: 1.5,
      payload: payload,
    )

    XCTAssertFalse(
      central.calls.contains(.send(payload: payload)),
      "The central sent the payload out of range.",
    )
  }

  func test_desiredRangeNotReached_peripheralSide_doesntSendPayload() async throws {
    let payload = Data("payload".utf8)

    let (_, peripheral) = try await rangeTestSetup(
      localDeviceType: .peripheral,
      distanceThreshold: 0.5,
      mockedDistance: 1.5,
      payload: payload,
    )

    XCTAssertFalse(
      peripheral.calls.contains(.send(payload: payload)),
      "The peripheral sent the payload out of range.",
    )
  }

  func test_reachesDesiredRange_centralSide_sendsPayload() async throws {
    let payload = Data("payload".utf8)

    let (central, _) = try await rangeTestSetup(
      localDeviceType: .central,
      distanceThreshold: 0.5,
      mockedDistance: 0.5,
      payload: payload,
    )

    XCTAssertTrue(
      central.calls.contains(.send(payload: payload)),
      "The central didn't send the payload when in range.",
    )
  }

  func test_reachesDesiredRange_peripheralSide_sendsPayload() async throws {
    let payload = Data("payload".utf8)

    let (_, peripheral) = try await rangeTestSetup(
      localDeviceType: .peripheral,
      distanceThreshold: 0.5,
      mockedDistance: 0.5,
      payload: payload,
    )

    XCTAssertTrue(
      peripheral.calls.contains(.send(payload: payload)),
      "The peripheral didn't send the payload when in range.",
    )
  }

  func test_belowDesiredRange_centralSide_sendsPayload() async throws {
    let payload = Data("payload".utf8)

    let (central, _) = try await rangeTestSetup(
      localDeviceType: .central,
      distanceThreshold: 0.5,
      mockedDistance: 0.4,
      payload: payload,
    )

    XCTAssertTrue(
      central.calls.contains(.send(payload: payload)),
      "The central didn't send the payload when in range.",
    )
  }

  func test_belowDesiredRange_peripheralSide_sendsPayload() async throws {
    let payload = Data("payload".utf8)

    let (_, peripheral) = try await rangeTestSetup(
      localDeviceType: .peripheral,
      distanceThreshold: 0.5,
      mockedDistance: 0.4,
      payload: payload,
    )

    XCTAssertTrue(
      peripheral.calls.contains(.send(payload: payload)),
      "The peripheral didn't send the payload when in range.",
    )
  }

  private func rangeTestSetup(
    localDeviceType: ConnectionRole,
    distanceThreshold: Float,
    mockedDistance: Float,
    payload: Data,
  ) async throws -> (BLECentralSpy, BLEPeripheralSpy) {
    let localNonce: UInt32 = localDeviceType == .central ? 2 : 1
    let peerNonce: UInt32 = localDeviceType == .central ? 1 : 2

    let ranger = MockRanger()

    let (session, central, peripheral) = makeSUT(
      localNonces: [localNonce],
      ranger: ranger,
      configuration: .init(distanceThreshold: distanceThreshold),
    )

    let ranged = expectation(description: "the session observed the distance")

    let events = session.events.receive()
    let observer = Task {
      for await event in events {
        guard case let .distance(distance) = event else { continue }
        XCTAssertEqual(distance, mockedDistance)
        ranged.fulfill()
      }
    }
    defer { observer.cancel() }

    try await session.start(payload: payload)

    simulatePeerDiscovery(advertising: peerNonce, on: central)
    central.onConnected?()

    ranger.onDistance?(mockedDistance)

    await fulfillment(of: [ranged], timeout: 1)

    return (central, peripheral)
  }
}

extension ExchangeSessionTests {
  func test_centralReceivesError_propagesError() async throws {
    let (session, central, _) = makeSUT()

    let errorReceived = expectation(description: "expected errors received")
    let mockError: ExchangeError = .incompatiblePeer

    let observer = Task {
      for await event in session.events.receive() {
        switch event {
        case let .failed(error):
          XCTAssertEqual(error, mockError)
          errorReceived.fulfill()
        default: break
        }
      }
    }

    defer { observer.cancel() }

    try await session.start(payload: .init())

    central.onError?(mockError)

    await fulfillment(of: [errorReceived], timeout: 1)
  }

  func test_peripheralReceivesError_propagesError() async throws {
    let (session, _, peripheral) = makeSUT()

    let errorReceived = expectation(description: "expected errors received")
    let mockError: ExchangeError = .incompatiblePeer

    let observer = Task {
      for await event in session.events.receive() {
        switch event {
        case let .failed(error):
          XCTAssertEqual(error, mockError)
          errorReceived.fulfill()
        default: break
        }
      }
    }

    defer { observer.cancel() }

    try await session.start(payload: .init())

    peripheral.onError?(mockError)

    await fulfillment(of: [errorReceived], timeout: 1)
  }
}

extension ExchangeSessionTests {
  func test_dataExchange_happyPath() async throws {
    let localNonce: UInt32 = 2
    let peerNonce: UInt32 = 1
    let localPayload = Data(Array(repeating: UInt8(ascii: "L"), count: 10))
    let peerPayload = Data(Array(repeating: UInt8(ascii: "P"), count: 10))
    let distance: Float = 0.1

    let ranger = MockRanger()
    let (session, central, peripheral) = makeSUT(
      localNonces: [localNonce],
      ranger: ranger,
      configuration: .init(distanceThreshold: 0.5),
    )

    let completed = expectation(description: "the exchange completed")
    let receivedEvents = Mutex<[ExchangeSession.Event]>([])

    let events = session.events.receive()
    let observer = Task {
      for await event in events {
        receivedEvents.withLock { $0.append(event) }
        guard case .completed = event else { continue }
        completed.fulfill()
      }
    }
    defer { observer.cancel() }

    try await session.start(payload: localPayload)

    simulatePeerDiscovery(advertising: peerNonce, on: central)
    central.onConnected?()

    ranger.onDistance?(distance)

    central.onSendProgress?(
      TransferProgress(bytes: 0, total: localPayload.count),
    )
    central.onReceiveProgress?(
      TransferProgress(bytes: 0, total: peerPayload.count),
    )
    central.onSendProgress?(
      TransferProgress(bytes: localPayload.count, total: localPayload.count),
    )
    central.onReceiveProgress?(
      TransferProgress(bytes: peerPayload.count, total: peerPayload.count),
    )

    central.onPayloadReceived?(peerPayload)
    central.onPeerReceivedDataConfirmation?()

    await fulfillment(of: [completed], timeout: 2)

    XCTAssertEqual(
      receivedEvents.withLock { $0 },
      [
        .connected,
        .distance(distance),
        .progress(0),
        .progress(0),
        .progress(0.5),
        .progress(1),
        .received(peerPayload),
        .completed,
      ],
    )
    XCTAssertEqual(
      central.calls,
      [
        .startScanning(nonce: localNonce),
        .send(payload: localPayload),
        .confirmSent,
        .stop
      ],
    )
    XCTAssertEqual(
      peripheral.calls,
      [
        .startAdvertising(nonce: localNonce),
        .stop,
        //second stop is from the end of transaction which stops everything including this even tho it stopped earlier
        .stop
      ],
    )
  }
}

extension ExchangeSessionTests {
  private func makeSUT(
    localNonces: [UInt32] = [1],
    ranger: MockRanger = MockRanger(),
    file: StaticString = #filePath,
    line: UInt = #line,
    clock: any Clock<Duration> = .continuous,
    configuration: NearbyExchange.Configuration = .init(),
  ) -> (session: ExchangeSession, central: BLECentralSpy, peripheral: BLEPeripheralSpy) {
    let central = BLECentralSpy()
    let peripheral = BLEPeripheralSpy()
    let remaining = Mutex(localNonces)

    let session = ExchangeSession(
      configuration: configuration,
      ranger: ranger,
      roleResolver: RoleResolver(
        makeNonce: {
          remaining.withLock { values -> UInt32 in
            guard values.count > 1 else { return values.first ?? 0 }
            return values.removeFirst()
          }
        },
      ),
      central: central,
      peripheral: peripheral,
      clock: clock,
    )

    central.onStateChange?(.poweredOn)
    peripheral.onStateChange?(.poweredOn)

    trackForMemoryLeaks(instance: session, file: file, line: line)
    trackForMemoryLeaks(instance: central, file: file, line: line)
    trackForMemoryLeaks(instance: peripheral, file: file, line: line)

    return (session, central, peripheral)
  }

  private func simulatePeerDiscovery(
    advertising peerNonce: UInt32,
    on central: BLECentralSpy,
    file: StaticString = #filePath,
    line: UInt = #line,
  ) {
    guard let localNonce = central.scanningNonce
    else {
      return XCTFail(
        "The central isn't scanning.",
        file: file,
        line: line,
      )
    }

    central.onRoleReceived?(
      RoleResolver.resolve(myNonce: localNonce, peerNonce: peerNonce),
    )
  }
}
