@testable import BLENearbyExchangeCore
import CoreBluetooth
import CoreBluetoothMock
import Foundation
import Synchronization

final class MockPeripheralSpy: @unchecked Sendable {
  private(set) var spec: CBMPeripheralSpec!
  private let mtu: Int
  private let characteristics: [CBMCharacteristicMock]
  private let state = Mutex<State>(.init())
  
  struct State {
    var handshakeToken: Data?
    var controls: [GATT.Control] = []
    var reassembler = Reassembler()
  }
  
  convenience init(
    configuration: NearbyExchange.Configuration = .init(),
    nonce: UInt64,
    mtu: Int = 64
  ) {
    let name = RoleResolver.encode(nonce).base64EncodedString()
    
    self.init(
      configuration: configuration,
      advertisedName: name,
      mtu: mtu
    )
  }

  init(
    configuration: NearbyExchange.Configuration = .init(),
    advertisedName: String,
    mtu: Int = 64
  ) {
    self.mtu = mtu
    
    self.characteristics = [
      CBMCharacteristicMock(type: GATT.handshake.cbuuid, properties: [.notify, .write]),
      CBMCharacteristicMock(type: GATT.payload.cbuuid, properties: [.writeWithoutResponse, .notify]),
      CBMCharacteristicMock(type: GATT.control.cbuuid, properties: [.write, .notify])
    ]
    
    self.spec = CBMPeripheralSpec
      .simulatePeripheral(proximity: .immediate)
      .advertising(
        advertisementData: [
          CBMAdvertisementDataIsConnectable: true as NSNumber,
          CBMAdvertisementDataLocalNameKey: advertisedName,
          CBMAdvertisementDataServiceUUIDsKey: [configuration.serviceUUID.cbuuid],
        ],
        withInterval: 0.05
      )
      .connectable(
        name: "peer",
        services: [
          CBMServiceMock(
            type: configuration.serviceUUID.cbuuid,
            primary: true,
            characteristics: self.characteristics
          )
        ],
        delegate: self,
        connectionInterval: 0.01,
        mtu: mtu
      )
      .build()
  }
  
  var onPayload: ((Data) -> Void)?
  var onControl: ((GATT.Control) -> Void)?
  var onDisconnect: ((Error?) -> Void)?

  var handshakeToken: Data? { state.withLock(\.handshakeToken) }
  var controls: [GATT.Control] { state.withLock(\.controls) }
  var isConnected: Bool { spec.isConnected }

  func notify(_ data: Data, on uuid: UUID) {
    guard let characteristic = characteristics.first(where: { $0.uuid.uuidString == uuid.uuidString })
    else { return }

    spec.simulateValueUpdate(data, for: characteristic)
  }

  func send(payload: Data) {
    for frame in Chunker.chunk(payload, mtu: mtu) {
      notify(frame, on: GATT.payload)
    }
  }

  func send(_ control: GATT.Control) {
    notify(Data([control.rawValue]), on: GATT.control)
  }

  func disconnect() {
    spec.simulateDisconnection()
  }
}

extension MockPeripheralSpy: CBMPeripheralSpecDelegate {
  func reset() {
    state.withLock { $0 = State() }
  }

  func peripheral(
    _: CBMPeripheralSpec,
    didReceiveWriteRequestFor characteristic: CBMCharacteristicMock,
    data: Data
  ) -> Result<Void, Error> {
    switch characteristic.uuid {
    case GATT.handshake.cbuuid:
      state.withLock { $0.handshakeToken = data }
      return .success(())

    case GATT.control.cbuuid:
      guard
        let raw = data.first,
        let control = GATT.Control(rawValue: raw)
      else { return .failure(CBMATTError(.invalidAttributeValueLength)) }

      state.withLock {
        $0.controls.append(control)
      }
      onControl?(control)
      return .success(())

    default:
      return .failure(CBMATTError(.writeNotPermitted))
    }
  }

  func peripheral(
    _: CBMPeripheralSpec,
    didReceiveWriteCommandFor characteristic: CBMCharacteristicMock,
    data: Data
  ) {
    guard characteristic.uuid == GATT.payload.cbuuid
    else { return }

    let full = state.withLock { state in
      try? state.reassembler.add(frame: data)
    }

    if let full {
      onPayload?(full)
    }
  }

  func peripheral(
    _: CBMPeripheralSpec,
    didDisconnect error: Error?
  ) {
    onDisconnect?(error)
  }
}
