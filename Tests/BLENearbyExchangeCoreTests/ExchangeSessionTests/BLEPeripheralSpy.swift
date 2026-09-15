@testable import BLENearbyExchangeCore
import CoreBluetoothMock
import Foundation

@BLEActor
final class BLEPeripheralSpy: BLEPeripheralInterface {
  enum Call: Equatable {
    case startAdvertising(nonce: UInt64)
    case send(payload: Data)
    case confirmSent
    case sendTerminate(GATT.Control)
    case stop
  }

  private(set) var calls: [Call] = []

  var onStateChange: ((CBMManagerState) -> Void)?
  var onPayloadReceived: ((Data) -> Void)?
  var onRoleConfirmed: (() -> Void)?
  var onPeerReceivedDataConfirmation: (() -> Void)?
  var onError: ((ExchangeError) -> Void)?
  var onConnected: (() -> Void)?
  var onSendProgress: ((TransferProgress) -> Void)?
  var onReceiveProgress: ((TransferProgress) -> Void)?

  func startAdvertising(nonce: UInt64) async throws {
    calls.append(.startAdvertising(nonce: nonce))
  }

  func send(payload: Data) {
    calls.append(.send(payload: payload))
  }

  func confirmSent() {
    calls.append(.confirmSent)
  }

  func sendTerminate(
    _ control: GATT.Control,
    completion: @escaping () -> Void,
  ) {
    calls.append(.sendTerminate(control))
    completion()
  }

  func stop() {
    calls.append(.stop)
  }
}
