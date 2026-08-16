import CoreBluetooth
import Foundation

@BLEActor
final class BLECentralManager: NSObject {
  private let configuration: NearbyExchange.Configuration

  private var nonce: UInt64?
  private var manager: CBCentralManager!
  private var ranger: ProximityRanger

  private var handshakeChar: CBCharacteristic?
  private var payloadChar: CBCharacteristic?
  private var controlChar: CBCharacteristic?
  private var peripheral: CBPeripheral?

  var onStateChange: ((CBManagerState) -> Void)?

  var payload = Data()
  var onPayloadReceived: ((Data) -> Void)?
  var onRoleReceived: ((_ role: ConnectionRole?) -> Void)?
  var onPeerReceivedDataConfirmation: (() -> Void)?
  var onError: ((ExchangeError) -> Void)?
  var onConnected: (() -> Void)?
  var onSendProgress: ((TransferProgress) -> Void)?
  var onReceiveProgress: ((TransferProgress) -> Void)?

  private var onTerminateSent: (() -> Void)?
  private var isTerminating = false
  private var outbox: [Data] = []
  private var sentBytes = 0
  private var payloadBytes = 0
  private var reassembler = Reassembler()

  init(
    configuration: NearbyExchange.Configuration,
    ranger: ProximityRanger
  ) {
    self.configuration = configuration
    self.ranger = ranger

    super.init()

    manager = CBCentralManager(
      delegate: self,
      queue: BLEActor.queue,
      options: nil
    )
  }

  func startScanning(nonce: UInt64) {
    self.nonce = nonce

    manager.scanForPeripherals(
      withServices: [configuration.serviceUUID.cbuuid],
      options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
    )
  }

  func sendTerminate(
    _ control: GATT.Control,
    completion: @escaping () -> Void
  ) {
    guard let peripheral, let controlChar
    else { return completion() }

    isTerminating = true
    outbox.removeAll()
    onTerminateSent = completion

    peripheral.writeValue(
      Data([control.rawValue]),
      for: controlChar,
      type: .withResponse
    )
  }

  private func flushTerminate() {
    guard let completion = onTerminateSent
    else { return }

    onTerminateSent = nil
    completion()
  }

  func stop() {
    peripheral?.delegate = nil

    if manager.state == .poweredOn {
      manager.stopScan()

      if let peripheral {
        manager.cancelPeripheralConnection(peripheral)
      }
    }

    peripheral = nil
    handshakeChar = nil
    payloadChar = nil
    controlChar = nil
    nonce = nil

    outbox.removeAll()
    sentBytes = 0
    payloadBytes = 0
    reassembler = Reassembler()
    payload = Data()

    onTerminateSent = nil
    isTerminating = false
    onPayloadReceived = nil
    onRoleReceived = nil
    onPeerReceivedDataConfirmation = nil
    onError = nil
    onConnected = nil
    onSendProgress = nil
    onReceiveProgress = nil
  }

  func send(payload: Data) {
    guard !isTerminating, let peripheral else { return }
    let mtu = peripheral.maximumWriteValueLength(for: .withoutResponse)
    outbox = Chunker.chunk(payload, mtu: mtu)
    sentBytes = 0
    payloadBytes = payload.count
    onSendProgress?(sendProgress)
    drainOutbox()
  }

  func confirmSent() {
    sentBytes = payloadBytes
    onSendProgress?(sendProgress)
  }

  private func drainOutbox() {
    guard !isTerminating, let peripheral, let payloadChar, !outbox.isEmpty
    else { return }

    while !outbox.isEmpty, peripheral.canSendWriteWithoutResponse {
      let frame = outbox.removeFirst()
      peripheral.writeValue(frame, for: payloadChar, type: .withoutResponse)
      sentBytes += frame.count - Chunker.headerSize
    }

    onSendProgress?(sendProgress)
  }

  private var sendProgress: TransferProgress {
    TransferProgress(bytes: sentBytes, total: payloadBytes)
  }
}

extension BLECentralManager: @BLEActor CBCentralManagerDelegate {
  func centralManagerDidUpdateState(
    _ central: CBCentralManager
  ) {
    onStateChange?(central.state)
  }

  func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi _: NSNumber
  ) {
    guard
      let peerNonceString = advertisementData[CBAdvertisementDataLocalNameKey] as? String,
      let peerNonceData = Data(base64Encoded: peerNonceString),
      let peerNonce = RoleResolver.decode(peerNonceData),
      let nonce
    else { return }

    let role = RoleResolver.resolve(
      myNonce: nonce,
      peerNonce: peerNonce
    )

    manager.stopScan()

    if role == .central {
      central.connect(peripheral)
      peripheral.delegate = self
      self.peripheral = peripheral
    }

    onRoleReceived?(role)
  }

  func centralManager(
    _: CBCentralManager,
    didConnect peripheral: CBPeripheral
  ) {
    peripheral.discoverServices([configuration.serviceUUID.cbuuid])
  }

  func centralManager(
    _: CBCentralManager,
    didFailToConnect _: CBPeripheral,
    error: Error?
  ) {
    flushTerminate()
    onError?(.connectionFailed(error?.localizedDescription ?? "The peer is unreachable."))
  }

  func centralManager(
    _: CBCentralManager,
    didDisconnectPeripheral _: CBPeripheral,
    error _: Error?
  ) {
    flushTerminate()
    onError?(.disconnected)
  }

  func centralManager(
    _: CBCentralManager,
    didDisconnectPeripheral _: CBPeripheral,
    timestamp _: CFAbsoluteTime,
    isReconnecting: Bool,
    error _: Error?
  ) {
    guard !isReconnecting else { return }

    flushTerminate()
    onError?(.disconnected)
  }

  func centralManager(
    _: CBCentralManager,
    connectionEventDidOccur _: CBConnectionEvent,
    for _: CBPeripheral
  ) {}

  func centralManager(
    _: CBCentralManager,
    didUpdateANCSAuthorizationFor _: CBPeripheral
  ) {}
}

extension BLECentralManager: @BLEActor CBPeripheralDelegate {
  func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverServices error: (any Error)?
  ) {
    if let error {
      onError?(.discoveryFailed(error.localizedDescription))
      return
    }

    guard
      let service = peripheral.services?.first(where: { $0.uuid == configuration.serviceUUID.cbuuid })
    else {
      onError?(.incompatiblePeer)
      return
    }

    peripheral.discoverCharacteristics(
      [GATT.handshake.cbuuid, GATT.payload.cbuuid, GATT.control.cbuuid],
      for: service
    )
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverCharacteristicsFor service: CBService,
    error: (any Error)?
  ) {
    if let error {
      onError?(.discoveryFailed(error.localizedDescription))
      return
    }

    for characteristic in service.characteristics ?? [] {
      switch characteristic.uuid {
      case GATT.handshake.cbuuid:
        handshakeChar = characteristic

      case GATT.payload.cbuuid:
        payloadChar = characteristic

      case GATT.control.cbuuid:
        controlChar = characteristic

      default:
        break
      }
    }

    guard
      let handshakeChar, let payloadChar, let controlChar
    else {
      onError?(.incompatiblePeer)
      return
    }

    peripheral.setNotifyValue(true, for: payloadChar)
    peripheral.setNotifyValue(true, for: controlChar)
    peripheral.setNotifyValue(true, for: handshakeChar)
  }

  func peripheral(
    _: CBPeripheral,
    didWriteValueFor characteristic: CBCharacteristic,
    error: (any Error)?
  ) {
    if characteristic.uuid == GATT.control.cbuuid {
      flushTerminate()
    }

    if let error {
      onError?(.transferFailed(error.localizedDescription))
    }
  }

  func peripheralIsReady(toSendWriteWithoutResponse _: CBPeripheral) {
    drainOutbox()
  }

  func peripheral(
    _: CBPeripheral,
    didModifyServices invalidatedServices: [CBService]
  ) {
    guard
      invalidatedServices.contains(where: { $0.uuid == configuration.serviceUUID.cbuuid })
    else { return }

    onError?(.disconnected)
  }

  func peripheral(
    _: CBPeripheral,
    didUpdateNotificationStateFor _: CBCharacteristic,
    error: (any Error)?
  ) {
    if let error {
      onError?(.handshakeFailed(error.localizedDescription))
      return
    }

    guard
      payloadChar?.isNotifying == true,
      controlChar?.isNotifying == true,
      handshakeChar?.isNotifying == true,
      let handshakeChar
    else { return }

    guard let token = ranger.localDiscoveryToken()
    else {
      onError?(.rangingFailed("No local discovery token."))
      return
    }

    peripheral?.writeValue(
      token,
      for: handshakeChar,
      type: .withResponse
    )

    onConnected?()
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateValueFor characteristic: CBCharacteristic,
    error: (any Error)?
  ) {
    if let error {
      onError?(.transferFailed(error.localizedDescription))
      return
    }

    guard let value = characteristic.value
    else { return }

    switch characteristic.uuid {
    case GATT.handshake.cbuuid:
      do {
        try ranger.startRanging(peerToken: value)
      } catch {
        onError?(.rangingFailed(error.localizedDescription))
      }

    case GATT.payload.cbuuid:
      let full = reassembler.add(frame: value)
      onReceiveProgress?(reassembler.progress)

      guard let full, let controlChar
      else { return }

      onPayloadReceived?(full)

      peripheral.writeValue(
        Data([GATT.Control.done.rawValue]),
        for: controlChar,
        type: .withResponse
      )

    case GATT.control.cbuuid:
      guard
        let raw = value.first,
        let control = GATT.Control(rawValue: raw)
      else { return }

      switch control {
      case .done:
        onPeerReceivedDataConfirmation?()

      case .cancelled:
        onError?(.cancelledByPeer)

      case .failed:
        onError?(.failedOnPeer)
      }

    default:
      return
    }
  }
}
