@testable import BLENearbyExchangeCore
import CoreBluetooth
import CoreBluetoothMock
import Foundation
import Synchronization
import XCTest
import Clocks

@BLEActor
final class ExchangeSessionTests: XCTestCase {
  func test_nonceCollisionRestartsTheHandshakeWithAFreshNonce() async throws {
    let peerNonce: UInt64 = 1
    let collidingLocalNonce: UInt64 = 1
    let freshLocalNonce: UInt64 = 2
    
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
    let peerNonce: UInt64 = 1
    let collidingLocalNonce: UInt64 = 1
    
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
    let peerNonce: UInt64 = 1
    let localNonce: UInt64 = 2
    
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
    let localNonce: UInt64 = 2
    
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
  func test_desiredRangeNotReached_doesntSendPayload() async throws {
    
  }
  
  func test_reachesDesiredRanger_sendsPayload() async throws {
    
  }
  
  func test_receivesError_failsSessionAndPropagesError() async throws {
    
  }
  
  func test_successfullyExchangesData() async throws {
    
  }
}

extension ExchangeSessionTests {
  private func makeSUT(
    localNonces: [UInt64] = [1],
    ranger: MockRanger = MockRanger(),
    file: StaticString = #filePath,
    line: UInt = #line,
    clock: any Clock<Duration> = .continuous
  ) -> (session: ExchangeSession, central: BLECentralSpy, peripheral: BLEPeripheralSpy) {
    let central = BLECentralSpy()
    let peripheral = BLEPeripheralSpy()
    let remaining = Mutex(localNonces)

    let session = ExchangeSession(
      configuration: .init(),
      ranger: ranger,
      roleResolver: RoleResolver(
        makeNonce: {
          remaining.withLock { values -> UInt64 in
            guard values.count > 1 else { return values.first ?? 0 }
            return values.removeFirst()
          }
        },
      ),
      central: central,
      peripheral: peripheral,
      clock: clock
    )

    central.onStateChange?(.poweredOn)
    peripheral.onStateChange?(.poweredOn)

    trackForMemoryLeaks(instance: session, file: file, line: line)
    trackForMemoryLeaks(instance: central, file: file, line: line)
    trackForMemoryLeaks(instance: peripheral, file: file, line: line)

    return (session, central, peripheral)
  }

  private func simulatePeerDiscovery(
    advertising peerNonce: UInt64,
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
