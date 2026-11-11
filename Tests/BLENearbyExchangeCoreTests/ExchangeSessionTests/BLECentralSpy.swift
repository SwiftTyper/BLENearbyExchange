@testable import BLENearbyExchangeCore
import CoreBluetoothMock
import Foundation

@BLEActor
final class BLECentralSpy: BLECentralInterface {
  enum Call: Equatable {
    case startScanning(nonce: UInt32)
    case send(payload: Data, to: UUID)
    case confirmSent
    case sendTerminate(GATT.Control)
    case stop
  }

  private(set) var calls: [Call] = []
  private(set) var scanningNonce: UInt32?
  var onStartScanning: ((UInt32) -> Void)?

  var onStateChange: ((CBMManagerState) -> Void)?
  var onPayloadReceived: ((Data) -> Void)?
  var onPeerReceivedDataConfirmation: (() -> Void)?
  var onError: ((ExchangeError) -> Void)?
  var onConnected: ((_ peerId: UUID) -> Void)?
  var onSendProgress: ((TransferProgress) -> Void)?
  var onReceiveProgress: ((TransferProgress) -> Void)?
  var onDistance: ((Float, UUID) -> Void)?
  var onNonceConflict: (() -> Void)?

  func startScanning(nonce: UInt32) {
    calls.append(.startScanning(nonce: nonce))
    scanningNonce = nonce
    onStartScanning?(nonce)
  }
  
  func send(payload: Data, to peerId: UUID) {
    calls.append(.send(payload: payload, to: peerId))
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
