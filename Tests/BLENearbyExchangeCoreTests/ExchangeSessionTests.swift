@testable import BLENearbyExchangeCore
import CoreBluetooth
import CoreBluetoothMock
import Foundation
import Synchronization
import XCTest

@BLEActor
final class ExchangeSessionTests: XCTestCase {
  func test_nonceCollisionRestartsTheHandshakeWithAFreshNonce() async throws {
    let peer = MockPeripheralSpy(nonce: 1)
    let log = Log()

    let session = makeSUT(nonces: [1, 2], peer: peer, log: log)

    let connected = expectation(description: "the peer connected")

    let events = session.events.receive()
    let observer = Task {
      for await event in events {
        guard case .connected = event else { continue }
        log.withLock { $0.append(.connected) }
        connected.fulfill()
      }
    }
    defer { observer.cancel() }

    try await session.start(payload: Data())

    await fulfillment(of: [connected], timeout: 5)

    XCTAssertEqual(log.withLock { $0 }, [.nonce(1), .nonce(2), .connected])
    XCTAssertTrue(peer.isConnected)
  }

  func test_unresolvedNonceCollisionKeepsRestartingWithoutConnecting() async throws {
    let peer = MockPeripheralSpy(nonce: 1)
    let log = Log()

    let session = makeSUT(nonces: [1], peer: peer, log: log)

    let connected = expectation(description: "the peer didn't connect")
    connected.isInverted = true

    let events = session.events.receive()
    let observer = Task {
      for await event in events {
        guard case .connected = event else { continue }
        log.withLock { $0.append(.connected) }
        connected.fulfill()
      }
    }
    defer { observer.cancel() }

    try await session.start(payload: Data())

    await fulfillment(of: [connected], timeout: 2)

    XCTAssertGreaterThan(log.withLock { $0 }.count, 1)
    XCTAssertFalse(peer.isConnected)
  }

  func test_distinctNoncesResolveARoleWithoutARestart() async throws {
    let peer = MockPeripheralSpy(nonce: 1)
    let log = Log()

    let session = makeSUT(nonces: [2], peer: peer, log: log)

    let connected = expectation(description: "the peer connected")

    let events = session.events.receive()
    let observer = Task {
      for await event in events {
        guard case .connected = event else { continue }
        log.withLock { $0.append(.connected) }
        connected.fulfill()
      }
    }
    defer { observer.cancel() }

    try await session.start(payload: Data())

    await fulfillment(of: [connected], timeout: 5)

    XCTAssertEqual(log.withLock { $0 }, [.nonce(2), .connected])
    XCTAssertTrue(peer.isConnected)
  }
}

extension ExchangeSessionTests {
  enum Step: Equatable {
    case nonce(UInt64)
    case connected
  }

  final class Log: Sendable {
    private let storage = Mutex<[Step]>([])

    func withLock<R>(
      _ body: (inout sending [Step]) throws -> sending R
    ) rethrows -> sending R {
      try storage.withLock(body)
    }
  }

  private func makeSUT(
    nonces: [UInt64],
    peer: MockPeripheralSpy,
    log: Log,
    ranger: MockRanger = MockRanger()
  ) -> ExchangeSession {
    CBMCentralManagerMock.tearDownSimulation()
    CBMCentralManagerMock.simulateRSSIDeviation(.none)
    CBMCentralManagerMock.simulatePeripherals([peer.spec])
    CBMCentralManagerMock.simulateInitialState(.poweredOn)

    let remaining = Mutex(nonces)

    return ExchangeSession(
      configuration: .init(),
      ranger: ranger,
      roleResolver: RoleResolver(
        makeNonce: {
          let nonce = remaining.withLock { values -> UInt64 in
            guard values.count > 1 else { return values.first ?? 0 }
            return values.removeFirst()
          }
          log.withLock { $0.append(.nonce(nonce)) }
          return nonce
        }
      ),
      forceMock: true
    )
  }
}
