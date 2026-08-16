import CoreBluetooth
import Foundation

enum ExchangeError: Error, Equatable, Sendable {
  case unsupported
  case unavailable(CBManagerState)
  case timedOut
  case cancelledByPeer
  case failedOnPeer
  case advertisingFailed(String)
  case connectionFailed(String)
  case disconnected
  case incompatiblePeer
  case discoveryFailed(String)
  case handshakeFailed(String)
  case rangingFailed(String)
  case transferFailed(String)
  case unknown(String)

  init(_ error: any Error) {
    self = error as? ExchangeError ?? .unknown(error.localizedDescription)
  }
}

extension ExchangeError: LocalizedError {
  var errorDescription: String? {
    message
  }

  var message: String {
    switch self {
    case .unsupported:
      "This device can't measure the distance to another device."

    case .unavailable(.poweredOff):
      "Bluetooth is turned off."

    case .unavailable(.unauthorized):
      "Bluetooth access isn't allowed."

    case .unavailable(.unsupported):
      "This device doesn't support Bluetooth."

    case .unavailable:
      "Bluetooth isn't available right now."

    case .timedOut:
      "No other device showed up."

    case .cancelledByPeer:
      "The other device cancelled the exchange."

    case .failedOnPeer:
      "The exchange failed on the other device."

    case .advertisingFailed:
      "This device couldn't be made discoverable."

    case .connectionFailed:
      "The connection couldn't be established."

    case .disconnected:
      "The other device disconnected."

    case .incompatiblePeer:
      "The other device isn't compatible."

    case .discoveryFailed:
      "The other device couldn't be inspected."

    case .handshakeFailed:
      "The devices couldn't agree on a connection."

    case .rangingFailed:
      "The distance between the devices couldn't be measured."

    case .transferFailed:
      "The transfer was interrupted."

    case .unknown:
      "Something went wrong."
    }
  }
}
