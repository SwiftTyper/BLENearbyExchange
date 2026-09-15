@testable import BLENearbyExchangeCore
import CoreBluetoothMock
import Foundation

@BLEActor
final class BLECentralSpy: BLECentralInterface {
  enum Call: Equatable {
    case startScanning(nonce: UInt64)
    case send(payload: Data)
    case confirmSent
    case sendTerminate(GATT.Control)
    case stop
  }

  private(set) var calls: [Call] = []
  private(set) var scanningNonce: UInt64?
  var onStartScanning: ((UInt64) -> Void)?

  var onStateChange: ((CBMManagerState) -> Void)?
  var onPayloadReceived: ((Data) -> Void)?
  var onRoleReceived: ((_ role: ConnectionRole?) -> Void)?
  var onPeerReceivedDataConfirmation: (() -> Void)?
  var onError: ((ExchangeError) -> Void)?
  var onConnected: (() -> Void)?
  var onSendProgress: ((TransferProgress) -> Void)?
  var onReceiveProgress: ((TransferProgress) -> Void)?

  func startScanning(nonce: UInt64) {
    calls.append(.startScanning(nonce: nonce))
    scanningNonce = nonce
    onStartScanning?(nonce)
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
    scanningNonce = nil
  }
}
