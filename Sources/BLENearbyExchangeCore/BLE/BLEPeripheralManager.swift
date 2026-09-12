import CoreBluetoothMock
import Foundation

@BLEActor
final class BLEPeripheralManager: NSObject {
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

  var payload = Data()

  private var sentBytes = 0
  private var payloadBytes = 0
  private var reassembler = Reassembler()
  
  private var centralSubscribedCharacteristics: Set<String> = []
  private var terminationCompletion: (() -> Void)? = nil
  private let workQueue: BLEUnlimitedWorkQueue = .init()

  init(
    configuration: NearbyExchange.Configuration,
    ranger: ProximityRanger,
    forceMock: Bool
  ) {
    self.configuration = configuration
    self.ranger = ranger
    
    super.init()

    manager = CBMPeripheralManagerFactory.instance(
      delegate: self,
      queue: BLEActor.queue,
      options: nil,
      forceMock: forceMock
    )
  }

  func startAdvertising(nonce: UInt64) async throws {
    manager.removeAllServices()

    handshakeChar = CBMMutableCharacteristic(
      type: GATT.handshake.cbuuid,
      properties: [.notify, .write],
      value: nil,
      permissions: [.writeable]
    )
    payloadChar = CBMMutableCharacteristic(
      type: GATT.payload.cbuuid,
      properties: [.writeWithoutResponse, .notify],
      value: nil,
      permissions: [.writeable]
    )
    controlChar = CBMMutableCharacteristic(
      type: GATT.control.cbuuid,
      properties: [.write, .notify],
      value: nil,
      permissions: [.writeable]
    )

    let service = CBMMutableService(
      type: configuration.serviceUUID.cbuuid,
      primary: true
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
    completion: @escaping () -> Void
  ) {
    self.terminationCompletion = completion
    
    workQueue.clear()

    workQueue.add { [weak self] in
      guard let self else { return false }
      
      let result = manager.updateValue(
        Data([control.rawValue]),
        for: self.controlChar,
        onSubscribedCentrals: nil
      )
      
      if result && self.terminationCompletion != nil {
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

    workQueue.clear()
    
    sentBytes = 0
    payloadBytes = 0
    reassembler = Reassembler()
    payload = Data()

    onPayloadReceived = nil
    onRoleConfirmed = nil
    onPeerReceivedDataConfirmation = nil
    onError = nil
    onConnected = nil
    onSendProgress = nil
    onReceiveProgress = nil
  }

  func send(payload: Data) {
    guard let mtu = subscribedCentral?.maximumUpdateValueLength
    else { return }
    
    sentBytes = 0
    payloadBytes = payload.count
    
    for chunk in Chunker.chunk(payload, mtu: mtu) {
      workQueue.add { [weak self] in
        guard let self else { return true }
        
        let result = self.manager.updateValue(
          chunk,
          for: self.payloadChar,
          onSubscribedCentrals: nil
        )
        
        if result {
          sentBytes += chunk.count - Chunker.headerSize
        }
        
        self.onSendProgress?(sendProgress)
        
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
    _ peripheral: CBMPeripheralManager
  ) {
    onStateChange?(peripheral.state)
  }

  func peripheralManagerDidStartAdvertising(
    _: CBMPeripheralManager,
    error: Error?
  ) {
    if let error {
      advertisingContinuation?.resume(
        throwing: ExchangeError.advertisingFailed(error.localizedDescription)
      )
    } else {
      advertisingContinuation?.resume()
    }
    advertisingContinuation = nil
  }
  
  func peripheralManager(
    _: CBMPeripheralManager,
    didAdd _: CBMService,
    error: Error?
  ) {
    if let error {
      serviceContinuation?.resume(
        throwing: ExchangeError.advertisingFailed(error.localizedDescription)
      )
    } else {
      serviceContinuation?.resume()
    }
    serviceContinuation = nil
  }

  func peripheralManager(
    _: CBMPeripheralManager,
    central: CBMCentral,
    didSubscribeTo characteristic: CBMCharacteristic
  ) {
    let requiredGATTIds = [GATT.handshake.cbuuid, GATT.payload.cbuuid, GATT.control.cbuuid]
      .map(\.uuidString)
    
    self.centralSubscribedCharacteristics.insert(characteristic.uuid.uuidString)
    
    if self.centralSubscribedCharacteristics.isSuperset(of: requiredGATTIds) {
      subscribedCentral = central
      onRoleConfirmed?()
      onConnected?()
    }
  }

  func peripheralManager(
    _: CBMPeripheralManager,
    central _: CBMCentral,
    didUnsubscribeFrom characterisitc: CBMCharacteristic
  ) {
    self.centralSubscribedCharacteristics.remove(characterisitc.uuid.uuidString)
    
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
    didReceiveWrite requests: [CBMATTRequest]
  ) {
    for request in requests {
      switch request.characteristic.uuid {
      case GATT.handshake.cbuuid:
        guard let peerToken = request.value
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
        
        workQueue.add { [weak self] in
          guard let self else { return true }
          
          return peripheral.updateValue(
            localToken,
            for: self.handshakeChar,
            onSubscribedCentrals: nil
          )
        }

        do {
          try ranger.startRanging(peerToken: peerToken)
        } catch {
          onError?(.rangingFailed(error.localizedDescription))
        }

      case GATT.payload.cbuuid:
        guard let value = request.value
        else { continue }

        let full = try? reassembler.add(frame: value)
        onReceiveProgress?(reassembler.progress)

        guard let full
        else { continue }

        workQueue.add { [weak self] in
          guard let self else { return true }
          
          return peripheral.updateValue(
            Data([GATT.Control.done.rawValue]),
            for: self.controlChar,
            onSubscribedCentrals: nil
          )
        }
        
        onPayloadReceived?(full)

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
    toUpdateSubscribers _: CBMPeripheralManager
  ) {
    workQueue.resume()
  }
}

@BLEActor
class BLEUnlimitedWorkQueue {
  typealias WorkItem = () -> Bool
  
  private var stack: [WorkItem] = []
  
  init() {}
  
  func clear() {
    stack = []
  }
  
  func add(value: @escaping WorkItem) {
    stack.append(value)
    
    if stack.count == 1 {
      resume()
    }
  }
  
  func resume() {
    while !stack.isEmpty {
      guard let workItem = stack.popLast() else { return }
      
      if !workItem() {
        stack.append(workItem)
        return
      }
    }
  }
}
