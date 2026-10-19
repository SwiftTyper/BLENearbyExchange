import CoreBluetooth
import CoreBluetoothMock
import CryptoKit
import Foundation

extension BLECentralManager {
  private var activePeripheral: CBMPeripheral? {
    guard let activeSessionId else { return nil }
    return peripherals[activeSessionId]?.peripheral
  }
  
  var activeControlChar: CBMCharacteristic? {
    guard let activeSessionId else { return nil }
    return peripherals[activeSessionId]?.characterisitcs.first(where: { $0.uuid == GATT.control.cbuuid })
  }
}

@BLEActor
final class BLECentralManager: NSObject, BLECentralInterface {
  private let configuration: NearbyExchange.Configuration

  private var nonce: UInt32?
  private var manager: CBMCentralManager!
  
  @BLEActor
  struct PeerSession {
    let peripheral: CBMPeripheral
    let characterisitcs: [CBMCharacteristic]
    let ranger: ProximityRanger
    var communicationCipher: any MessageCipherInterface
    
    func invalidate() {
      peripheral.delegate = nil
      ranger.stop()
    }
  }

  private var peripherals: [UUID : PeerSession] = [:]
  private var activeSessionId: UUID? = nil

  var onStateChange: ((CBMManagerState) -> Void)?
  var onPayloadReceived: ((Data) -> Void)?
  var onRoleReceived: ((_ role: ConnectionRole?) -> Void)?
  var onPeerReceivedDataConfirmation: (() -> Void)?
  var onError: ((ExchangeError) -> Void)?
  var onConnected: (() -> Void)?
  var onSendProgress: ((TransferProgress) -> Void)?
  var onReceiveProgress: ((TransferProgress) -> Void)?
  var onDistance: ((_ distance: Float, _ peer: UUID) -> Void)?

  private var terminationCompletion: (() -> Void)?
  private var sentBytes = 0
  private var payloadBytes = 0
  private var reassembler = Reassembler()
  private let transferQueue: UnlimitedTransferQueue = .init()
  private var makeCipher: () -> any MessageCipherInterface
  private let makeRanger: () -> ProximityRanger

  init(
    configuration: NearbyExchange.Configuration,
    makeRanger: @autoclosure @escaping () -> ProximityRanger,
    makeCipher: @escaping () -> any MessageCipherInterface = { MessageCipher() },
    forceMock: Bool = false,
  ) {
    self.configuration = configuration
    self.makeCipher = makeCipher
    self.makeRanger = makeRanger

    super.init()

    self.manager = CBMCentralManagerFactory.instance(
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
    guard let peripheral = activePeripheral, let controlChar = activeControlChar
    else { return completion() }

    terminationCompletion = completion

    transferQueue.clear()

    peripheral.writeValue(
      Data([control.rawValue]),
      for: controlChar,
      type: .withResponse,
    )
  }

  func stop() {
    if manager.state == .poweredOn {
      manager.stopScan()

//      if let peripheral {
//        manager.cancelPeripheralConnection(peripheral)
//      }
    }

    peripherals.forEach { $0.value.invalidate() }
    peripherals = [:]
    activeSessionId = nil
    nonce = nil

    transferQueue.clear()
    terminationCompletion = nil

    sentBytes = 0
    payloadBytes = 0
    reassembler = Reassembler()

    onPayloadReceived = nil
    onRoleReceived = nil
    onPeerReceivedDataConfirmation = nil
    onError = nil
    onConnected = nil
    onSendProgress = nil
    onReceiveProgress = nil
  }

  func send(payload: Data, to peerId: UUID) {
    activeSessionId = peerId

    let ids = self.peripherals.map(\.key)
    
    for id in ids where id != peerId {
      self.peripherals[id]?.invalidate()
      self.peripherals[id] = nil
    }
    
    guard
      let peripheral = self.peripherals[peerId]?.peripheral,
      let payloadChar = self.peripherals[peerId]?.characterisitcs.first(where: { $0.uuid == GATT.payload.cbuuid }),
      let encryptedPayload = try? self.peripherals[peerId]?.communicationCipher.encrypt(data: payload)
    else {
      onError?(.transferFailed("Couldn't encrypt the payload."))
      return
    }

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
      // do i have to keep a reference to the peripheral at this stage?
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
    _: any CBMPeripheral,
    didWriteValueFor characteristic: CBMCharacteristic,
    error _: (any Error)?,
  ) {
    guard
      characteristic.uuid == GATT.control.cbuuid
    else { return }

    if let terminationCompletion {
      terminationCompletion()
      self.terminationCompletion = nil
    }
  }

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
    
    guard
      let characteristics = service.characteristics,
      characteristics.allSatisfy({ GATT.allCasesUUIDs.map(\.cbuuid).contains($0.uuid) })
    else {
      onError?(.incompatiblePeer)
      return
    }
    
    let ranger = makeRanger()
    
    ranger.onDistance = { distance in
      self.onDistance?(distance, peripheral.identifier)
    }
    
    ranger.onError = { error in
      // TODO: think about what to do if one session fails to start
      self.onError?(.rangingFailed(error.localizedDescription))
    }
    
    self.peripherals[peripheral.identifier] = .init(
      peripheral: peripheral,
      characterisitcs: characteristics,
      ranger: ranger,
      communicationCipher: makeCipher()
    )
    
    // maybe i won't have to subscribe to every characterstic just the handshake at this point
    characteristics.forEach { peripheral.setNotifyValue(true, for: $0) }
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
    _ peripheral: CBMPeripheral,
    didUpdateNotificationStateFor _: CBMCharacteristic,
    error: (any Error)?,
  ) {
    if let error {
      onError?(.handshakeFailed(error.localizedDescription))
      return
    }

    guard
      let peerSession = self.peripherals[peripheral.identifier],
      peerSession.characterisitcs.allSatisfy({ GATT.allCasesUUIDs.map(\.cbuuid).contains($0.uuid) && $0.isNotifying }),
      let handshakeChar = peerSession.characterisitcs.first(where: { $0.uuid == GATT.handshake.cbuuid })
    else { return }

    guard
      let token = peerSession.ranger.localDiscoveryToken()
    else {
      onError?(.rangingFailed("No local discovery token."))
      return
    }

    let handshakePayload = HandshakePayload(
      publicKey: peerSession.communicationCipher.localPublicKey.rawRepresentation,
      token: token,
    )

    guard
      let handshakePayloadData = try? JSONEncoder().encode(handshakePayload)
    else {
      onError?(.disconnected)
      return
    }
    
    let mtu = peripheral.maximumWriteValueLength(for: .withoutResponse)

    for chunk in Chunker.chunk(handshakePayloadData, mtu: mtu) {
      transferQueue.add {
        guard
          peripheral.canSendWriteWithoutResponse == true
        else { return false }

        peripheral.writeValue(
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

      do {
        try self.peripherals[peripheral.identifier]?.communicationCipher.establish(with: peerHandshakePayload.publicKey)
      } catch {
        onError?(.handshakeFailed("Couldn't establish the shared key."))
        return
      }

      do {
        try self.peripherals[peripheral.identifier]?.ranger.startRanging(peerToken: peerHandshakePayload.token)
      } catch {
        onError?(.rangingFailed(error.localizedDescription))
      }

    case GATT.payload.cbuuid:
      // TODO: the peer may hit the distance threshold before we do, its payload is dropped here
      guard activeSessionId == peripheral.identifier
      else { return }

      let full = try? reassembler.add(frame: value)

      onReceiveProgress?(reassembler.progress)

      guard
        let full,
        let controlChar = self.peripherals[peripheral.identifier]?.characterisitcs.first(where: { $0.uuid == GATT.control.cbuuid })
      else { return }

      guard let decryptedPayload = try? self.peripherals[peripheral.identifier]?.communicationCipher.decrypt(data: full)
      else {
        onError?(.transferFailed("Couldn't decrypt the payload."))
        return
      }

      reassembler.reset()

      peripheral.writeValue(
        Data([GATT.Control.done.rawValue]),
        for: controlChar,
        type: .withResponse,
      )

      onPayloadReceived?(decryptedPayload)

    case GATT.control.cbuuid:
      guard
        activeSessionId == peripheral.identifier,
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
