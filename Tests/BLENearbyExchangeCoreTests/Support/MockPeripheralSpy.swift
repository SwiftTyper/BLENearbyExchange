@testable import BLENearbyExchangeCore
import CoreBluetooth
import CoreBluetoothMock
import Foundation

final class MockPeripheralSpy: @unchecked Sendable {
  let mtu: Int
  
  private(set) var spec: CBMPeripheralSpec!
  private let characteristics: [CBMCharacteristicMock]
  private let lock = NSLock()
  private var state = State()
  
  convenience init(
    configuration: NearbyExchange.Configuration = .init(),
    nonce: UInt64,
    servesExchange: Bool = true,
    mtu: Int = 64
  ) {
    let name = RoleResolver.encode(nonce).base64EncodedString()
    
    self.init(
      configuration: configuration,
      advertisedName: name,
      servesExchange: servesExchange,
      mtu: mtu
    )
  }

  init(
    configuration: NearbyExchange.Configuration = .init(),
    advertisedName: String,
    servesExchange: Bool = true,
    mtu: Int = 64
  ) {
    self.mtu = mtu
    
    self.characteristics = [
      CBMCharacteristicMock(type: GATT.handshake.cbuuid, properties: [.notify, .write]),
      CBMCharacteristicMock(type: GATT.payload.cbuuid, properties: [.writeWithoutResponse, .notify]),
      CBMCharacteristicMock(type: GATT.control.cbuuid, properties: [.write, .notify])
    ]
    
    let service = CBMServiceMock(
      type: servesExchange ? configuration.serviceUUID.cbuuid : UUID().cbuuid,
      primary: true,
      characteristics: self.characteristics
    )

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
        services: [service],
        delegate: self,
        connectionInterval: 0.01,
        mtu: mtu
      )
      .build()
  }

  var handshakeToken: Data? { read(\.handshakeToken) }
  var controls: [GATT.Control] { read(\.controls) }
  var payload: Data? { read(\.payload) }
  var receivedFrames: [Data] { read(\.receivedFrames) }
  var notifying: Set<CBUUID> { read(\.notifying) }
  var isConnected: Bool { spec.isConnected }

  var serviceDiscoveryError: Error? {
    get { read(\.serviceDiscoveryError) }
    set { mutate { $0.serviceDiscoveryError = newValue } }
  }

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

  private struct State {
    var handshakeToken: Data?
    var controls: [GATT.Control] = []
    var payload: Data?
    var receivedFrames: [Data] = []
    var notifying: Set<CBUUID> = []
    var reassembler = Reassembler()
    var serviceDiscoveryError: Error?
  }

  private func read<T>(_ keyPath: KeyPath<State, T>) -> T {
    lock.withLock { state[keyPath: keyPath] }
  }

  @discardableResult
  private func mutate<T>(_ body: (inout State) -> T) -> T {
    lock.withLock { body(&state) }
  }
}

extension MockPeripheralSpy: CBMPeripheralSpecDelegate {
  func reset() {
    mutate { $0 = State() }
  }

  func peripheral(
    _: CBMPeripheralSpec,
    didReceiveServiceDiscoveryRequest _: [CBMUUID]?
  ) -> Result<Void, Error> {
    if let error = serviceDiscoveryError {
      return .failure(error)
    }
    return .success(())
  }

  func peripheral(
    _: CBMPeripheralSpec,
    didReceiveWriteRequestFor characteristic: CBMCharacteristicMock,
    data: Data
  ) -> Result<Void, Error> {
    switch characteristic.uuid {
    case GATT.handshake.cbuuid:
      mutate { $0.handshakeToken = data }
      return .success(())

    case GATT.control.cbuuid:
      guard
        let raw = data.first,
        let control = GATT.Control(rawValue: raw)
      else { return .failure(CBMATTError(.invalidAttributeValueLength)) }

      mutate { $0.controls.append(control) }
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

    mutate {
      $0.receivedFrames.append(data)
      if let full = try? $0.reassembler.add(frame: data) {
        $0.payload = full
      }
    }
  }

  func peripheral(
    _: CBMPeripheralSpec,
    didReceiveSetNotifyRequest _: Bool,
    for _: CBMCharacteristicMock
  ) -> Result<Void, Error> {
    .success(())
  }

  func peripheral(
    _: CBMPeripheralSpec,
    didUpdateNotificationStateFor characteristic: CBMCharacteristicMock,
    error _: Error?
  ) {
    mutate {
      if characteristic.isNotifying {
        $0.notifying.insert(characteristic.uuid)
      } else {
        $0.notifying.remove(characteristic.uuid)
      }
    }
  }
}
