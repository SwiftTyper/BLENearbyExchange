import CoreBluetooth
import CoreBluetoothMock
import CryptoKit
import Foundation

@BLEActor
final class BLECentralManager: NSObject, BLECentralInterface {
  private let configuration: NearbyExchange.Configuration

  private var nonce: UInt32?
  private var manager: CBMCentralManager!
  private var ranger: ProximityRanger

  private var handshakeChar: CBMCharacteristic?
  private var payloadChar: CBMCharacteristic?
  private var controlChar: CBMCharacteristic?
  private var peripheral: CBMPeripheral?

  var onStateChange: ((CBMManagerState) -> Void)?
  var onPayloadReceived: ((Data) -> Void)?
  var onRoleReceived: ((_ role: ConnectionRole?) -> Void)?
  var onPeerReceivedDataConfirmation: (() -> Void)?
  var onError: ((ExchangeError) -> Void)?
  var onConnected: (() -> Void)?
  var onSendProgress: ((TransferProgress) -> Void)?
  var onReceiveProgress: ((TransferProgress) -> Void)?

  private var terminationCompletion: (() -> Void)?
  private var sentBytes = 0
  private var payloadBytes = 0
  private var reassembler = Reassembler()
  private let transferQueue: UnlimitedTransferQueue = .init()
  private var communicationCipher: MessageCipherInterface?
  private var makeCipher: () -> any MessageCipherInterface

  init(
    configuration: NearbyExchange.Configuration,
    ranger: ProximityRanger,
    makeCipher: @escaping () -> any MessageCipherInterface = { MessageCipher() },
    forceMock: Bool = false,
  ) {
    self.configuration = configuration
    self.ranger = ranger
    self.makeCipher = makeCipher
    communicationCipher = makeCipher()

    super.init()

    manager = CBMCentralManagerFactory.instance(
      delegate: self,
      queue: BLEActor.queue,
      forceMock: forceMock,
    )
  }

  func startScanning(nonce: UInt32) {
    self.nonce = nonce

    manager.scanForPeripherals(
      withServices: [configuration.serviceUUID.cbuuid],
      options: [CBCentralManagerScanOptionAllowDuplicatesKey: true], // TODO:
    )
  }

  func sendTerminate(
    _ control: GATT.Control,
    completion: @escaping () -> Void,
  ) {
    guard let peripheral, let controlChar
    else { return completion() }

    terminationCompletion = completion

    transferQueue.clear()

    transferQueue.add(priority: .high) { [weak self] in
      guard
        let self,
        peripheral.canSendWriteWithoutResponse
      else { return false }

      peripheral.writeValue(
        Data([control.rawValue]),
        for: controlChar,
        type: .withResponse,
      )

      if terminationCompletion != nil {
        completion()
      }

      return true
    }
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

    transferQueue.clear()
    terminationCompletion = nil

    sentBytes = 0
    payloadBytes = 0
    reassembler = Reassembler()
    communicationCipher = makeCipher()

    onPayloadReceived = nil
    onRoleReceived = nil
    onPeerReceivedDataConfirmation = nil
    onError = nil
    onConnected = nil
    onSendProgress = nil
    onReceiveProgress = nil
  }

  func send(payload: Data) {
    guard
      let peripheral,
      let payloadChar,
      let encryptedPayload = try? communicationCipher?.encrypt(data: payload)
    else { return }

    let mtu = peripheral.maximumWriteValueLength(for: .withoutResponse)

    sentBytes = 0
    payloadBytes = encryptedPayload.count

    for chunk in Chunker.chunk(encryptedPayload, mtu: mtu) {
      transferQueue.add { [weak self] in
        guard
          let self,
          peripheral.canSendWriteWithoutResponse
        else { return false }

        peripheral.writeValue(chunk, for: payloadChar, type: .withoutResponse)

        sentBytes += chunk.count - Chunker.headerSize

        onSendProgress?(sendProgress)

        return true
      }
    }
  }

  /// TODO:
  func confirmSent() {
    sentBytes = payloadBytes
    onSendProgress?(sendProgress)
  }

  private var sendProgress: TransferProgress {
    TransferProgress(bytes: sentBytes, total: payloadBytes)
  }
}

extension BLECentralManager: @BLEActor CBMCentralManagerDelegate {
  func centralManagerDidUpdateState(
    _ central: CBMCentralManager,
  ) {
    onStateChange?(central.state)
  }

  func centralManager(
    _ central: CBMCentralManager,
    didDiscover peripheral: CBMPeripheral,
    advertisementData: [String: Any],
    rssi _: NSNumber,
  ) {
    guard
      let peerNonceString = advertisementData[CBAdvertisementDataLocalNameKey] as? String,
      let peerNonceData = Data(base64Encoded: peerNonceString),
      let peerNonce = RoleResolver.decode(peerNonceData),
      let nonce
    else { return }

    let role = RoleResolver.resolve(
      myNonce: nonce,
      peerNonce: peerNonce,
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
    _: CBMCentralManager,
    didConnect peripheral: CBMPeripheral,
  ) {
    peripheral.discoverServices([configuration.serviceUUID.cbuuid])
  }

  func centralManager(
    _: CBMCentralManager,
    didFailToConnect _: CBMPeripheral,
    error: Error?,
  ) {
    onError?(.connectionFailed(error?.localizedDescription ?? "The peer is unreachable."))
  }

  func centralManager(
    _: CBMCentralManager,
    didDisconnectPeripheral _: CBMPeripheral,
    error _: Error?,
  ) {
    if let terminationCompletion {
      terminationCompletion()
      self.terminationCompletion = nil
    }

    onError?(.disconnected)
  }

  func centralManager(
    _: CBMCentralManager,
    didDisconnectPeripheral _: CBMPeripheral,
    timestamp _: CFAbsoluteTime,
    isReconnecting: Bool,
    error _: Error?,
  ) {
    guard !isReconnecting else { return }

    if let terminationCompletion {
      terminationCompletion()
      self.terminationCompletion = nil
    }

    onError?(.disconnected)
  }
}

extension BLECentralManager: @BLEActor CBMPeripheralDelegate {
  func peripheral(
    _ peripheral: CBMPeripheral,
    didDiscoverServices error: (any Error)?,
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
      for: service,
    )
  }

  func peripheral(
    _ peripheral: CBMPeripheral,
    didDiscoverCharacteristicsFor service: CBMService,
    error: (any Error)?,
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

  func peripheralIsReady(toSendWriteWithoutResponse _: CBMPeripheral) {
    transferQueue.resume()
  }

  func peripheral(
    _: CBMPeripheral,
    didModifyServices invalidatedServices: [CBMService],
  ) {
    guard
      invalidatedServices.contains(where: { $0.uuid == configuration.serviceUUID.cbuuid })
    else { return }

    onError?(.disconnected)
  }

  func peripheral(
    _: CBMPeripheral,
    didUpdateNotificationStateFor _: CBMCharacteristic,
    error: (any Error)?,
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

    guard
      let token = ranger.localDiscoveryToken(),
      let communicationCipher
    else {
      onError?(.rangingFailed("No local discovery token."))
      return
    }

    let handshakePayload = HandshakePayload(
      publicKey: communicationCipher.localPublicKey.rawRepresentation,
      token: token,
    )

    guard
      let handshakePayloadData = try? JSONEncoder().encode(handshakePayload),
      let mtu = peripheral?.maximumWriteValueLength(for: .withoutResponse)
    else {
      // TODO:
      onError?(.disconnected)
      return
    }

    for chunk in Chunker.chunk(handshakePayloadData, mtu: mtu) {
      transferQueue.add { [weak self] in
        guard
          let self,
          peripheral?.canSendWriteWithoutResponse == true
        else { return false }

        peripheral?.writeValue(
          chunk,
          for: handshakeChar,
          type: .withoutResponse,
        )

        return true
      }
    }

    onConnected?()
  }

  func peripheral(
    _ peripheral: CBMPeripheral,
    didUpdateValueFor characteristic: CBMCharacteristic,
    error: (any Error)?,
  ) {
    if let error {
      onError?(.transferFailed(error.localizedDescription))
      return
    }

    guard let value = characteristic.value
    else { return }

    switch characteristic.uuid {
    case GATT.handshake.cbuuid:
      guard let full = try? reassembler.add(frame: value)
      else { return }
      
      reassembler.reset()

      guard
        let peerHandshakePayload = try? JSONDecoder().decode(HandshakePayload.self, from: full)
      else {
        onError?(.handshakeFailed("couldn't decode handshake payload"))
        return
      }

      try? communicationCipher?.establish(with: peerHandshakePayload.publicKey)

      do {
        try ranger.startRanging(peerToken: peerHandshakePayload.token)
      } catch {
        onError?(.rangingFailed(error.localizedDescription))
      }

    case GATT.payload.cbuuid:
      let full = try? reassembler.add(frame: value)

      onReceiveProgress?(reassembler.progress)

      guard
        let full,
        let controlChar,
        let decryptedPayload = try? communicationCipher?.decrypt(data: full)
      else { return }
      
      reassembler.reset()

      onPayloadReceived?(decryptedPayload)

      transferQueue.add(priority: .high) {
        guard peripheral.canSendWriteWithoutResponse
        else { return false }

        peripheral.writeValue(
          Data([GATT.Control.done.rawValue]),
          for: controlChar,
          type: .withResponse,
        )

        return true
      }

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
