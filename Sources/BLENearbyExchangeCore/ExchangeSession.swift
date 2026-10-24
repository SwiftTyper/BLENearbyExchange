import CoreBluetooth
import CoreBluetoothMock
import Foundation

@BLEActor
public final class ExchangeSession: TimeoutController {
  public let events = AsyncPassthrough<Event>()
  private let centralState = AsyncCurrentValue<CBMManagerState>(.unknown)
  private let peripheralState = AsyncCurrentValue<CBMManagerState>(.unknown)

  private let configuration: NearbyExchange.Configuration
  private let roleResolver: RoleResolver
  private var peripheral: BLEPeripheralInterface?
  private var central: BLECentralInterface?

  private var payload = Data()
  private var sent = TransferProgress()
  private var received = TransferProgress()
  private var role: ConnectionRole?

  private var didPeerReceive = false
  private var didReceive = false
  private var didComplete = false

  public convenience init(
    configuration: NearbyExchange.Configuration,
  ) {
    let peripheral = BLEPeripheralManager(
      configuration: configuration,
      makeRanger: ProximityRanger(),
      forceMock: false,
    )

    let central = BLECentralManager(
      configuration: configuration,
      makeRanger: ProximityRanger(),
      forceMock: false,
    )

    self.init(
      configuration: configuration,
      roleResolver: RoleResolver(),
      central: central,
      peripheral: peripheral,
      clock: .continuous,
    )
  }

  init(
    configuration: NearbyExchange.Configuration,
    roleResolver: RoleResolver,
    central: any BLECentralInterface,
    peripheral: any BLEPeripheralInterface,
    clock: any Clock<Duration>,
  ) {
    self.configuration = configuration
    self.roleResolver = roleResolver
    self.peripheral = peripheral
    self.central = central

    super.init(clock: clock)

    self.peripheral?.onStateChange = { [weak self] in
      self?.peripheralState.send($0)
    }

    self.central?.onStateChange = { [weak self] in
      self?.centralState.send($0)
    }
  }

  public func start(payload: Data) async throws {
    guard ProximityRanger.isSupported
    else { throw ExchangeError.unsupported }

    try await waitForPoweredOn(peripheralState)
    try await waitForPoweredOn(centralState)

    didComplete = false

    self.payload = payload

    try await beginHandshake()
  }

  private func beginHandshake() async throws {
    wireCallbacks()
    let nonce = roleResolver.makeNonce()
    try await peripheral?.startAdvertising(nonce: nonce)
    central?.startScanning(nonce: nonce)

    startTimer(with: configuration.timeout)
  }

  private func restartHandshake() async throws {
    peripheral?.stop()
    central?.stop()

    role = nil

    try await beginHandshake()
  }

  private func restart() {
    Task { [weak self] in
      do {
        try await self?.restartHandshake()
      } catch {
        self?.fail(ExchangeError(error))
      }
    }
  }

  override public func timeoutDidFire() {
    fail(.timedOut)
  }

  private func fail(_ error: ExchangeError) {
    guard !didComplete
    else { return }

    didComplete = true

    cancelTimer()
    // HANDLE
//    ranger?.stop()

    switch error {
    case .cancelledByPeer, .failedOnPeer, .disconnected:
      stop()

    default:
      notifyPeer(.failed) { [weak self] in self?.stop() }
    }

    events.send(.failed(error))
  }

  private func notifyPeer(_ control: GATT.Control, completion: @escaping () -> Void) {
    switch role {
    case .central: central?.sendTerminate(control, completion: completion)
    case .peripheral: peripheral?.sendTerminate(control, completion: completion)
    case nil: completion()
    }
  }

  private func waitForPoweredOn(
    _ state: AsyncCurrentValue<CBMManagerState>,
  ) async throws {
    for await value in state.receive() {
      switch value {
      case .unknown:
        continue

      case .poweredOn:
        return

      default:
        throw ExchangeError.unavailable(value)
      }
    }
  }

  public func terminate(_ control: GATT.Control) async {
    switch role {
    case .central:
      await withCheckedContinuation { continuation in
        guard let central else { return continuation.resume() }
        central.sendTerminate(control) { continuation.resume() }
      }

    case .peripheral:
      await withCheckedContinuation { continuation in
        guard let peripheral else { return continuation.resume() }
        peripheral.sendTerminate(control) { continuation.resume() }
      }

    case nil:
      break
    }
  }

  public func stop() {
    peripheral?.stop()
    central?.stop()

    cancelTimer()

    role = nil
    payload = Data()
    didPeerReceive = false
    didReceive = false
    didComplete = false
    sent = TransferProgress()
    received = TransferProgress()
  }

  private func wireCallbacks() {
    central?.onNonceConflict = { [weak self] in
      self?.restart()
    }
    central?.onDeclined = { [weak self] in
      self?.restart()
    }
    peripheral?.onDeclined = { [weak self] in
      self?.restart()
    }
    central?.onDistance = { [weak self] distance, uuid in
      self?.onDistance(distance: distance, peerId: uuid, role: .central)
    }
    peripheral?.onDistance = { [weak self] distance, uuid in
      self?.onDistance(distance: distance, peerId: uuid, role: .peripheral)
    }
    central?.onPayloadReceived = { [weak self] data in
      self?.markReceived(data)
    }
    peripheral?.onPayloadReceived = { [weak self] data in
      self?.markReceived(data)
    }
    central?.onPeerReceivedDataConfirmation = { [weak self] in
      self?.markPeerReceived()
    }
    peripheral?.onPeerReceivedDataConfirmation = { [weak self] in
      self?.markPeerReceived()
    }
    central?.onError = { [weak self] error in
      self?.fail(error)
    }
    peripheral?.onError = { [weak self] error in
      self?.fail(error)
    }
    central?.onConnected = { [weak self] in
      self?.markConnected()
    }
    peripheral?.onConnected = { [weak self] in
      self?.markConnected()
    }
    central?.onSendProgress = { [weak self] in
      self?.sent = $0
      self?.emitProgress()
    }
    peripheral?.onSendProgress = { [weak self] in
      self?.sent = $0
      self?.emitProgress()
    }
    central?.onReceiveProgress = { [weak self] in
      self?.received = $0
      self?.emitProgress()
    }
    peripheral?.onReceiveProgress = { [weak self] in
      self?.received = $0
      self?.emitProgress()
    }
  }
  
  private func onDistance(distance: Float, peerId: UUID, role: ConnectionRole) {
    events.send(.distance(distance))

    guard
      self.role == nil,
      distance <= configuration.distanceThreshold
    else { return }

    self.role = role

    switch role {
    case .central:
      peripheral?.declineAll()
      central?.send(payload: self.payload, to: peerId)

    case .peripheral:
      central?.declineAll()
      peripheral?.send(payload: self.payload, to: peerId)
    }
  }

  private func emitProgress() {
    let total = sent.total + received.total
    guard total > 0 else { return }

    let value = Double(sent.bytes + received.bytes) / Double(total)
    let progress = max(0, min(1, value))

    events.send(.progress(progress))
  }

  private func markConnected() {
    cancelTimer()
    events.send(.connected)
  }

  private func markPeerReceived() {
    didPeerReceive = true

    switch role {
    case .central: central?.confirmSent()
    case .peripheral: peripheral?.confirmSent()
    case nil: break
    }

    checkDone()
  }

  private func markReceived(_ data: Data) {
    didReceive = true
    events.send(.received(data))
    checkDone()
  }

  private func checkDone() {
    guard didPeerReceive, didReceive, !didComplete else { return }
    didComplete = true
    events.send(.completed)
    stop()
  }
}
