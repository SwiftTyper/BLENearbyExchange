import CoreBluetoothMock
import Foundation
import CryptoKit

@BLEActor
final class BLEPeripheralManager: NSObject, BLEPeripheralInterface {
  private let configuration: NearbyExchange.Configuration

  private var manager: CBMPeripheralManager!
  private var handshakeChar: CBMMutableCharacteristic!
  private var payloadChar: CBMMutableCharacteristic!
  private var controlChar: CBMMutableCharacteristic!

  private var advertisingContinuation: CheckedContinuation<Void, Error>?
  private var serviceContinuation: CheckedContinuation<Void, Error>?
  private var ranger: ProximityRanger
  private var subscribedCentral: CBMCentral?

  var onStateChange: ((CBMManagerState) -> Void)?
  var onPayloadReceived: ((Data) -> Void)?
  var onRoleConfirmed: (() -> Void)?
  var onPeerReceivedDataConfirmation: (() -> Void)?
  var onError: ((ExchangeError) -> Void)?
  var onConnected: (() -> Void)?
  var onSendProgress: ((TransferProgress) -> Void)?
  var onReceiveProgress: ((TransferProgress) -> Void)?

  private var sentBytes = 0
  private var payloadBytes = 0
  private var reassembler = Reassembler()
  private var communicationCipher: CommunicationCipher? = nil

  private var centralSubscribedCharacteristics: Set<String> = []
  private var terminationCompletion: (() -> Void)?
  private let transferQueue: UnlimitedTransferQueue = .init()

  init(
    configuration: NearbyExchange.Configuration,
    ranger: ProximityRanger,
    forceMock: Bool,
  ) {
    self.configuration = configuration
    self.ranger = ranger

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
      properties: [.notify, .write],
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
    terminationCompletion = completion

    transferQueue.clear()

    transferQueue.add { [weak self] in
      guard let self else { return false }

      let result = manager.updateValue(
        Data([control.rawValue]),
        for: controlChar,
        onSubscribedCentrals: nil,
      )

      if result, terminationCompletion != nil {
        completion()
      }

      return result
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
    subscribedCentral = nil
    centralSubscribedCharacteristics = []

    transferQueue.clear()
    terminationCompletion = nil

    sentBytes = 0
    payloadBytes = 0
    reassembler = Reassembler()

    onPayloadReceived = nil
    onRoleConfirmed = nil
    onPeerReceivedDataConfirmation = nil
    onError = nil
    onConnected = nil
    onSendProgress = nil
    onReceiveProgress = nil
  }

  func send(payload: Data) {
    guard
      let mtu = subscribedCentral?.maximumUpdateValueLength,
      let encryptedPayload = try? self.communicationCipher?.encrypt(data: payload)
    else { return }

    sentBytes = 0
    payloadBytes = encryptedPayload.count

    for chunk in Chunker.chunk(encryptedPayload, mtu: mtu) {
      transferQueue.add { [weak self] in
        guard let self else { return false }

        let result = manager.updateValue(
          chunk,
          for: payloadChar,
          onSubscribedCentrals: nil,
        )

        if result {
          sentBytes += chunk.count - Chunker.headerSize
        }

        onSendProgress?(sendProgress)

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
    let requiredGATTIds = [GATT.handshake.cbuuid, GATT.payload.cbuuid, GATT.control.cbuuid]
      .map(\.uuidString)

    centralSubscribedCharacteristics.insert(characteristic.uuid.uuidString)

    if centralSubscribedCharacteristics.isSuperset(of: requiredGATTIds) {
      subscribedCentral = central
      onRoleConfirmed?()
      onConnected?()
    }
  }

  func peripheralManager(
    _: CBMPeripheralManager,
    central _: CBMCentral,
    didUnsubscribeFrom characterisitc: CBMCharacteristic,
  ) {
    centralSubscribedCharacteristics.remove(characterisitc.uuid.uuidString)

    if centralSubscribedCharacteristics.isEmpty {
      subscribedCentral = nil

      if let terminationCompletion {
        terminationCompletion()
        self.terminationCompletion = nil
      }

      onError?(.disconnected)
    }
  }

  func peripheralManager(
    _ peripheral: CBMPeripheralManager,
    didReceiveWrite requests: [CBMATTRequest],
  ) {
    for request in requests {
      switch request.characteristic.uuid {
      case GATT.handshake.cbuuid:
        guard
          let peerHandshakeData = request.value,
          let peerHandshakePayload = try? JSONDecoder().decode(HandshakePayload.self, from: peerHandshakeData)
        else {
          peripheral.respond(to: request, withResult: .invalidAttributeValueLength)
          onError?(.handshakeFailed("No peer discovery token."))
          continue
        }

        guard let localToken = ranger.localDiscoveryToken()
        else {
          peripheral.respond(to: request, withResult: .unlikelyError)
          onError?(.rangingFailed("No local discovery token."))
          continue
        }

        peripheral.respond(to: request, withResult: .success)
        
        let communicationCipher = CommunicationCipher()
        
        let handshakePayload = HandshakePayload(
          publicKey: communicationCipher.localPublicKey.rawRepresentation,
          token: localToken
        )
        
        self.communicationCipher = communicationCipher
        
        guard let handshakePayloadData = try? JSONEncoder().encode(handshakePayload) else {
          onError?(.handshakeFailed("Encoding handshake payload failed"))
          return
        }
         
        transferQueue.add { [weak self] in
          guard let self else { return false }

          return peripheral.updateValue(
            handshakePayloadData,
            for: handshakeChar,
            onSubscribedCentrals: nil,
          )
        }

        do {
          try ranger.startRanging(peerToken: peerHandshakePayload.token)
        } catch {
          onError?(.rangingFailed(error.localizedDescription))
        }
        
        try? self.communicationCipher?.establish(with: peerHandshakePayload.publicKey)

      case GATT.payload.cbuuid:
        guard let value = request.value
        else { continue }

        let full = try? reassembler.add(frame: value)
        onReceiveProgress?(reassembler.progress)

        guard
          let full,
          let decryptedPayload = try? self.communicationCipher?.decrypt(data: full)
        else { continue }

        transferQueue.add { [weak self] in
          guard let self else { return false }

          return peripheral.updateValue(
            Data([GATT.Control.done.rawValue]),
            for: controlChar,
            onSubscribedCentrals: nil,
          )
        }

        onPayloadReceived?(decryptedPayload)

      case GATT.control.cbuuid:
        guard
          let raw = request.value?.first,
          let control = GATT.Control(rawValue: raw)
        else {
          peripheral.respond(to: request, withResult: .invalidAttributeValueLength)
          continue
        }

        peripheral.respond(to: request, withResult: .success)

        switch control {
        case .done:
          onPeerReceivedDataConfirmation?()

        case .cancelled:
          onError?(.cancelledByPeer)

        case .failed:
          onError?(.failedOnPeer)
        }

      default:
        continue
      }
    }
  }

  func peripheralManagerIsReady(
    toUpdateSubscribers _: CBMPeripheralManager,
  ) {
    transferQueue.resume()
  }
}
