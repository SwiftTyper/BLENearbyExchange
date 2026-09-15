import Foundation
import CoreBluetoothMock

@BLEActor
protocol BLEPeripheralInterface {
  var onStateChange: ((CBMManagerState) -> Void)? { get set }
  var onPayloadReceived: ((Data) -> Void)? { get set }
  var onRoleConfirmed: (() -> Void)? { get set }
  var onPeerReceivedDataConfirmation: (() -> Void)? { get set }
  var onError: ((ExchangeError) -> Void)? { get set }
  var onConnected: (() -> Void)? { get set }
  var onSendProgress: ((TransferProgress) -> Void)? { get set }
  var onReceiveProgress: ((TransferProgress) -> Void)? { get set }

  func startAdvertising(nonce: UInt64) async throws
  func send(payload: Data)
  func confirmSent()
  func sendTerminate(_ control: GATT.Control, completion: @escaping () -> Void)
  func stop()
}
