import CoreBluetoothMock
import Foundation
import Synchronization
@testable import BLENearbyExchangeCore

@BLEActor
final class MockCentralSpy {
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
  var onPayload: ((Data) -> Void)?
  var onHandshake: ((Data) -> Void)?
  var updates: [Update] { state.withLock { $0 } }
  
  func subscribe(to characteristics: [CBMMutableCharacteristic]) {
    for characteristic in characteristics {
      spec.simulateSubscription(to: characteristic)
    }
  }
}

extension MockCentralSpy: @BLEActor CBMCentralSpecDelegate {
  func central(
    _: CBMCentralSpec,
    didReceiveUpdate value: Data,
    for characteristic: CBMMutableCharacteristic
  ) {
    switch characteristic.uuid {
    case GATT.payload.cbuuid:
      state.withLock { $0.append(.payload(value)) }
      onPayload?(value)
      
    case GATT.control.cbuuid:
      guard
        let raw = value.first,
        let control = GATT.Control(rawValue: raw)
      else { return }
      
      state.withLock { $0.append(.control(control)) }
      onControl?(control)
      
    case GATT.handshake.cbuuid:
      onHandshake?(value)
      
    default:
      break
    }
  }
}
