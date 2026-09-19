import CoreBluetoothMock
import Foundation

@BLEActor
protocol BLECentralInterface {
  var onStateChange: ((CBMManagerState) -> Void)? { get set }
  var onPayloadReceived: ((Data) -> Void)? { get set }
  var onRoleReceived: ((_ role: ConnectionRole?) -> Void)? { get set }
  var onPeerReceivedDataConfirmation: (() -> Void)? { get set }
  var onError: ((ExchangeError) -> Void)? { get set }
  var onConnected: (() -> Void)? { get set }
  var onSendProgress: ((TransferProgress) -> Void)? { get set }
  var onReceiveProgress: ((TransferProgress) -> Void)? { get set }

  func startScanning(nonce: UInt32)
  func send(payload: Data)
  func confirmSent()
  func sendTerminate(_ control: GATT.Control, completion: @escaping () -> Void)
  func stop()
}
