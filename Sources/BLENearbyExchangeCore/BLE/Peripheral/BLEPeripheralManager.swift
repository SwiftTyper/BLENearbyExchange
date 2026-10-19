import CoreBluetoothMock
import CryptoKit
import Foundation

@BLEActor
final class BLEPeripheralManager: NSObject, BLEPeripheralInterface {
  private let configuration: NearbyExchange.Configuration

  private var manager: CBMPeripheralManager!
  private var handshakeChar: CBMMutableCharacteristic!
  private var payloadChar: CBMMutableCharacteristic!
  private var controlChar: CBMMutableCharacteristic!

  private var advertisingContinuation: CheckedContinuation<Void, Error>?
  private var serviceContinuation: CheckedContinuation<Void, Error>?

  @BLEActor
  struct PeerSession {
    let central: CBMCentral
    let ranger: ProximityRanger
    var communicationCipher: any MessageCipherInterface
    var reassembler: Reassembler
    var subscribedCharacteristics: Set<String> = []

    func invalidate() {
      ranger.stop()
    }
  }

  private var centrals: [UUID: PeerSession] = [:]
  private var activeSessionId: UUID? = nil

  var onStateChange: ((CBMManagerState) -> Void)?
  var onPayloadReceived: ((Data) -> Void)?
  var onRoleConfirmed: (() -> Void)?
  var onPeerReceivedDataConfirmation: (() -> Void)?
  var onError: ((ExchangeError) -> Void)?
  var onConnected: (() -> Void)?
  var onSendProgress: ((TransferProgress) -> Void)?
  var onReceiveProgress: ((TransferProgress) -> Void)?
  var onDistance: ((_ distance: Float, _ peer: UUID) -> Void)?

  private var sentBytes = 0
  private var payloadBytes = 0
  private var makeCipher: () -> any MessageCipherInterface
  private let makeRanger: () -> ProximityRanger

  private var terminationCompletion: (() -> Void)?
  private let transferQueue: UnlimitedTransferQueue = .init()

  init(
    configuration: NearbyExchange.Configuration,
    makeRanger: @autoclosure @escaping () -> ProximityRanger,
    makeCipher: @escaping () -> any MessageCipherInterface = { MessageCipher() },
    forceMock: Bool,
  ) {
    self.configuration = configuration
    self.makeRanger = makeRanger
    self.makeCipher = makeCipher

    super.init()

    manager = CBMPeripheralManagerFactory.instance(
      delegate: self,
      queue: BLEActor.queue,
      options: nil,
      forceMock: forceMock,
    )
  }

  func startAdvertising(nonce: UInt32) async throws {
    manager.removeAllServices()

    handshakeChar = CBMMutableCharacteristic(
      type: GATT.handshake.cbuuid,
      properties: [.writeWithoutResponse, .notify],
      value: nil,
      permissions: [.writeable],
    )
    payloadChar = CBMMutableCharacteristic(
      type: GATT.payload.cbuuid,
      properties: [.writeWithoutResponse, .notify],
      value: nil,
      permissions: [.writeable],
    )
    controlChar = CBMMutableCharacteristic(
      type: GATT.control.cbuuid,
      properties: [.write, .notify],
      value: nil,
      permissions: [.writeable],
    )

    let service = CBMMutableService(
      type: configuration.serviceUUID.cbuuid,
      primary: true,
    )
    service.characteristics = [handshakeChar, payloadChar, controlChar]

    try await withCheckedThrowingContinuation { continuation in
      serviceContinuation = continuation
      manager.add(service)
    }

    try await withCheckedThrowingContinuation { continuation in
      advertisingContinuation = continuation
      manager.startAdvertising([
        CBMAdvertisementDataServiceUUIDsKey: [configuration.serviceUUID.cbuuid],
        CBMAdvertisementDataLocalNameKey: RoleResolver.encode(nonce).base64EncodedString(),
      ])
    }
  }

  func sendTerminate(
    _ control: GATT.Control,
    completion: @escaping () -> Void,
  ) {
    guard
      let activeSessionId,
      let central = centrals[activeSessionId]?.central
    else { return completion() }

    terminationCompletion = completion

    transferQueue.clear()

    transferQueue.add(priority: .high) { [weak self] in
      guard let self else { return false }

      return manager.updateValue(
        Data([control.rawValue]),
        for: controlChar,
        onSubscribedCentrals: [central],
      )
    }
  }

  func stop() {
    if manager.state == .poweredOn {
      manager.stopAdvertising()
      manager.removeAllServices()
    }

    advertisingContinuation?.resume(throwing: CancellationError())
    advertisingContinuation = nil
    serviceContinuation?.resume(throwing: CancellationError())
    serviceContinuation = nil

    handshakeChar = nil
    payloadChar = nil
    controlChar = nil

    centrals.forEach { $0.value.invalidate() }
    centrals = [:]
    activeSessionId = nil

    transferQueue.clear()
    terminationCompletion = nil

    sentBytes = 0
    payloadBytes = 0

    onPayloadReceived = nil
    onRoleConfirmed = nil
    onPeerReceivedDataConfirmation = nil
    onError = nil
    onConnected = nil
    onSendProgress = nil
    onReceiveProgress = nil
  }

  func send(payload: Data, to peerId: UUID) {
    activeSessionId = peerId
    manager.stopAdvertising()

    let ids = centrals.map(\.key)

    for id in ids where id != peerId {
      centrals[id]?.invalidate()
      centrals[id] = nil
    }

    guard
      let central = centrals[peerId]?.central,
      let encryptedPayload = try? centrals[peerId]?.communicationCipher.encrypt(data: payload)
    else {
      onError?(.transferFailed("Couldn't encrypt the payload."))
      return
    }

    let mtu = central.maximumUpdateValueLength

    sentBytes = 0
    payloadBytes = encryptedPayload.count

    for chunk in Chunker.chunk(encryptedPayload, mtu: mtu) {
      transferQueue.add { [weak self] in
        guard let self else { return false }

        let result = manager.updateValue(
          chunk,
          for: payloadChar,
          onSubscribedCentrals: [central],
        )

        if result {
          sentBytes += chunk.count - Chunker.headerSize
          onSendProgress?(sendProgress)
        }

        return result
      }
    }
  }

  func confirmSent() {
    sentBytes = payloadBytes
    onSendProgress?(sendProgress)
  }

  private var sendProgress: TransferProgress {
    TransferProgress(bytes: sentBytes, total: payloadBytes)
  }

  private func makePeerSession(for central: CBMCentral) -> PeerSession {
    let ranger = makeRanger()

    ranger.onDistance = { [weak self] distance in
      self?.onDistance?(distance, central.identifier)
    }

    ranger.onError = { [weak self] error in
      self?.onError?(.rangingFailed(error.localizedDescription))
    }

    return PeerSession(
      central: central,
      ranger: ranger,
      communicationCipher: makeCipher(),
      reassembler: Reassembler(),
    )
  }
}

extension BLEPeripheralManager: @BLEActor CBMPeripheralManagerDelegate {
  func peripheralManagerDidUpdateState(
    _ peripheral: CBMPeripheralManager,
  ) {
    onStateChange?(peripheral.state)
  }

  func peripheralManagerDidStartAdvertising(
    _: CBMPeripheralManager,
    error: Error?,
  ) {
    if let error {
      advertisingContinuation?.resume(
        throwing: ExchangeError.advertisingFailed(error.localizedDescription),
      )
    } else {
      advertisingContinuation?.resume()
    }
    advertisingContinuation = nil
  }

  func peripheralManager(
    _: CBMPeripheralManager,
    didAdd _: CBMService,
    error: Error?,
  ) {
    if let error {
      serviceContinuation?.resume(
        throwing: ExchangeError.advertisingFailed(error.localizedDescription),
      )
    } else {
      serviceContinuation?.resume()
    }
    serviceContinuation = nil
  }

  func peripheralManager(
    _: CBMPeripheralManager,
    central: CBMCentral,
    didSubscribeTo characteristic: CBMCharacteristic,
  ) {
    let requiredGATTIds = GATT.allCasesUUIDs.map(\.cbuuid.uuidString)

    if centrals[central.identifier] == nil {
      guard activeSessionId == nil
      else { return }

      centrals[central.identifier] = makePeerSession(for: central)
    }

    centrals[central.identifier]?.subscribedCharacteristics.insert(characteristic.uuid.uuidString)

    guard
      centrals[central.identifier]?.subscribedCharacteristics.isSuperset(of: requiredGATTIds) == true
    else { return }

    onRoleConfirmed?()
    onConnected?()
  }

  func peripheralManager(
    _: CBMPeripheralManager,
    central: CBMCentral,
    didUnsubscribeFrom characterisitc: CBMCharacteristic,
  ) {
    centrals[central.identifier]?.subscribedCharacteristics.remove(characterisitc.uuid.uuidString)

    guard
      centrals[central.identifier]?.subscribedCharacteristics.isEmpty == true
    else { return }

    centrals[central.identifier]?.invalidate()
    centrals[central.identifier] = nil

    guard activeSessionId == central.identifier
    else { return }

    if let terminationCompletion {
      terminationCompletion()
      self.terminationCompletion = nil
    }

    onError?(.disconnected)
  }

  func peripheralManager(
    _ peripheral: CBMPeripheralManager,
    didReceiveWrite requests: [CBMATTRequest],
  ) {
    for request in requests {
      let peerId = request.central.identifier

      switch request.characteristic.uuid {
      case GATT.handshake.cbuuid:
        guard
          let value = request.value,
          let full = try? centrals[peerId]?.reassembler.add(frame: value)
        else { return }

        centrals[peerId]?.reassembler.reset()

        guard
          let peerHandshakePayload = try? JSONDecoder().decode(HandshakePayload.self, from: full)
        else {
          onError?(.handshakeFailed("No peer discovery token."))
          return
        }

        guard
          let peerSession = centrals[peerId],
          let localToken = peerSession.ranger.localDiscoveryToken()
        else {
          onError?(.rangingFailed("No local discovery token."))
          return
        }

        let handshakePayload = HandshakePayload(
          publicKey: peerSession.communicationCipher.localPublicKey.rawRepresentation,
          token: localToken,
        )

        guard
          let handshakePayloadData = try? JSONEncoder().encode(handshakePayload)
        else {
          onError?(.handshakeFailed("Encoding handshake payload failed"))
          return
        }

        let mtu = peerSession.central.maximumUpdateValueLength

        for chunk in Chunker.chunk(handshakePayloadData, mtu: mtu) {
          transferQueue.add { [weak self] in
            guard let self else { return false }

            return peripheral.updateValue(
              chunk,
              for: handshakeChar,
              onSubscribedCentrals: [peerSession.central],
            )
          }
        }

        do {
          try peerSession.ranger.startRanging(peerToken: peerHandshakePayload.token)
        } catch {
          onError?(.rangingFailed(error.localizedDescription))
        }

        do {
          try centrals[peerId]?.communicationCipher.establish(with: peerHandshakePayload.publicKey)
        } catch {
          onError?(.handshakeFailed("Couldn't establish the shared key."))
          continue
        }

      case GATT.payload.cbuuid:
        // TODO: the peer may hit the distance threshold before we do, its payload is dropped here
        guard
          activeSessionId == peerId,
          let value = request.value
        else { return }

        let full = try? centrals[peerId]?.reassembler.add(frame: value)

        guard let progress = centrals[peerId]?.reassembler.progress else { return }
        onReceiveProgress?(progress)

        guard let full
        else { return }

        guard let decryptedPayload = try? centrals[peerId]?.communicationCipher.decrypt(data: full)
        else {
          onError?(.transferFailed("Couldn't decrypt the payload."))
          return
        }

        centrals[peerId]?.reassembler.reset()

        transferQueue.add(priority: .high) { [weak self] in
          guard let self else { return false }

          return peripheral.updateValue(
            Data([GATT.Control.done.rawValue]),
            for: controlChar,
            onSubscribedCentrals: [request.central],
          )
        }

        onPayloadReceived?(decryptedPayload)

      case GATT.control.cbuuid:
        guard
          let raw = request.value?.first,
          let control = GATT.Control(rawValue: raw)
        else {
          peripheral.respond(to: request, withResult: .invalidAttributeValueLength)
          return
        }

        peripheral.respond(to: request, withResult: .success)

        guard activeSessionId == peerId
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

  func peripheralManagerIsReady(
    toUpdateSubscribers _: CBMPeripheralManager,
  ) {
    transferQueue.resume()
  }
}
