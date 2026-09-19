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
  private var ranger: ProximityRanger?
  private var peripheral: BLEPeripheralInterface?
  private var central: BLECentralInterface?

  private var payload = Data()
  private var sent = TransferProgress()
  private var received = TransferProgress()
  private var role: ConnectionRole?

  private var didPeerReceive = false
  private var didReceive = false
  private var didComplete = false
  private var distanceAquired = false

  public convenience init(
    configuration: NearbyExchange.Configuration,
  ) {
    let ranger = ProximityRanger()

    let peripheral = BLEPeripheralManager(
      configuration: configuration,
      ranger: ranger,
      forceMock: false,
    )

    let central = BLECentralManager(
      configuration: configuration,
      ranger: ranger,
      forceMock: false,
    )

    self.init(
      configuration: configuration,
      ranger: ranger,
      roleResolver: RoleResolver(),
      central: central,
      peripheral: peripheral,
      clock: .continuous,
    )
  }

  init(
    configuration: NearbyExchange.Configuration,
    ranger: ProximityRanger,
    roleResolver: RoleResolver,
    central: any BLECentralInterface,
    peripheral: any BLEPeripheralInterface,
    clock: any Clock<Duration>,
  ) {
    self.configuration = configuration
    self.roleResolver = roleResolver
    self.ranger = ranger
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
    guard ranger?.isSupported == true
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
    distanceAquired = false

    try await beginHandshake()
  }

  override public func timeoutDidFire() {
    fail(.timedOut)
  }

  private func fail(_ error: ExchangeError) {
    guard !didComplete
    else { return }

    didComplete = true

    cancelTimer()
    ranger?.stop()

    switch error {
    case .cancelledByPeer, .failedOnPeer, .disconnected:
      break

    default:
      notifyPeer(.failed)
    }

    events.send(.failed(error))
  }

  private func notifyPeer(_ control: GATT.Control) {
    switch role {
    case .central: central?.sendTerminate(control) {}
    case .peripheral: peripheral?.sendTerminate(control) {}
    case nil: break
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
    // TODO:
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
    ranger?.stop()
    peripheral?.stop()
    central?.stop()

    role = nil
    payload = Data()
    didPeerReceive = false
    didReceive = false
    didComplete = false
    distanceAquired = false
    sent = TransferProgress()
    received = TransferProgress()
  }

  private func wireCallbacks() {
    peripheral?.onRoleConfirmed = { [weak self] in
      self?.central?.stop()
      self?.role = .peripheral
    }
    central?.onRoleReceived = { [weak self] role in
      switch role {
      case .central:
        self?.peripheral?.stop()

      case .peripheral:
        break

      case nil:
        Task {
          do {
            try await self?.restartHandshake()
          } catch {
            self?.fail(ExchangeError(error))
          }
        }
      }
      self?.role = role
    }
    ranger?.onDistance = { [weak self] distance in
      guard let self else { return }

      events.send(.distance(distance))

      guard
        let role,
        distance <= configuration.distanceThreshold,
        !distanceAquired
      else { return }

      distanceAquired = true

      switch role {
      case .central:
        central?.send(payload: payload)

      case .peripheral:
        peripheral?.send(payload: payload)
      }
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
    ranger?.onError = { [weak self] error in
      self?.fail(.rangingFailed(error.localizedDescription))
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
    ranger?.stop()
    events.send(.completed)
  }
}
