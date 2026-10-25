import CoreBluetooth
import CoreBluetoothMock
import CryptoKit
import Foundation

extension BLECentralManager {
  @BLEActor
  private struct PeerSession {
    let peripheral: CBMPeripheral
    let ranger: ProximityRanger
    var communicationCipher: any MessageCipherInterface
    var reassembler: Reassembler
    var characterisitcs: [CBMCharacteristic]? = nil
    
    func invalidate() {
      peripheral.delegate = nil
      ranger.stop()
    }
  }
}

@BLEActor
final class BLECentralManager: NSObject, BLECentralInterface {
  private let configuration: NearbyExchange.Configuration

  private var nonce: UInt32?
  private var manager: CBMCentralManager!

  private var peripherals: [UUID : PeerSession] = [:]
  private var activeSessionId: UUID? = nil

  var onStateChange: ((CBMManagerState) -> Void)?
  var onPayloadReceived: ((Data) -> Void)?
  var onPeerReceivedDataConfirmation: (() -> Void)?
  var onError: ((ExchangeError) -> Void)?
  var onConnected: ((_ peer: UUID) -> Void)?
  var onSendProgress: ((TransferProgress) -> Void)?
  var onReceiveProgress: ((TransferProgress) -> Void)?
  var onDistance: ((_ distance: Float, _ peer: UUID) -> Void)?
  var onNonceConflict: (() -> Void)?

  private var terminationCompletion: (() -> Void)?
  private var sentBytes = 0
  private var payloadBytes = 0
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
    manager.scanForPeripherals(withServices: [configuration.serviceUUID.cbuuid])
  }

  func sendTerminate(
    _ control: GATT.Control,
    completion: @escaping () -> Void,
  ) {
    guard
      let activeSessionId,
      let peripheral = peripherals[activeSessionId]?.peripheral,
      let controlChar = peripherals[activeSessionId]?.characterisitcs?.first(where: { $0.uuid == GATT.control.cbuuid })
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
      peripherals.forEach { manager.cancelPeripheralConnection($0.value.peripheral) }
    }

    peripherals.forEach { $0.value.invalidate() }
    peripherals = [:]
    activeSessionId = nil
    nonce = nil

    transferQueue.clear()
    terminationCompletion = nil

    sentBytes = 0
    payloadBytes = 0

    onPayloadReceived = nil
    onPeerReceivedDataConfirmation = nil
    onError = nil
    onConnected = nil
    onSendProgress = nil
    onReceiveProgress = nil
    onNonceConflict = nil
  }

  func send(payload: Data, to peerId: UUID) {
    activeSessionId = peerId
    manager.stopScan()
    
    self.peripherals[peerId]?.ranger.stop()

    let ids = self.peripherals.map(\.key)
    
    for id in ids where id != peerId {
      self.peripherals[id]?.invalidate()
      self.peripherals[id] = nil
    }
    
    guard
      let peripheral = self.peripherals[peerId]?.peripheral,
      let payloadChar = self.peripherals[peerId]?.characterisitcs?.first(where: { $0.uuid == GATT.payload.cbuuid }),
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

    if role == nil {
      onNonceConflict?()
      return
    }

    if role == .central {
      central.connect(peripheral)
      peripheral.delegate = self
      
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
        ranger: ranger,
        communicationCipher: makeCipher(),
        reassembler: Reassembler()
      )
    }
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
    
    self.peripherals[peripheral.identifier]?.characterisitcs = characteristics
    
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
      let characterisitcs = peerSession.characterisitcs,
      characterisitcs.allSatisfy({ GATT.allCasesUUIDs.map(\.cbuuid).contains($0.uuid) && $0.isNotifying }),
      let handshakeChar = characterisitcs.first(where: { $0.uuid == GATT.handshake.cbuuid })
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

    onConnected?(peripheral.identifier)
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
      guard
        let full = try? self.peripherals[peripheral.identifier]?.reassembler.add(frame: value)
      else { return }

      self.peripherals[peripheral.identifier]?.reassembler.reset()

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

      let full = try? self.peripherals[peripheral.identifier]?.reassembler.add(frame: value)
      
      guard let progress = self.peripherals[peripheral.identifier]?.reassembler.progress else { return }
      onReceiveProgress?(progress)

      guard
        let full,
        let controlChar = self.peripherals[peripheral.identifier]?.characterisitcs?.first(where: { $0.uuid == GATT.control.cbuuid })
      else { return }

      guard let decryptedPayload = try? self.peripherals[peripheral.identifier]?.communicationCipher.decrypt(data: full)
      else {
        onError?(.transferFailed("Couldn't decrypt the payload."))
        return
      }

      self.peripherals[peripheral.identifier]?.reassembler.reset()

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
