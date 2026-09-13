import Foundation
import SwiftUI

public struct NearbyExchangeAction: Sendable, Equatable {
  private let presenter: NearbyExchangePresenter?

  init(presenter: NearbyExchangePresenter?) {
    self.presenter = presenter
  }

  public func run(payload: Data) async throws -> Data {
    guard let presenter else { throw Failure.hostMissing }
    return try await presenter.run(payload: payload)
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.presenter === rhs.presenter
  }
}

extension NearbyExchangeAction {
  enum Failure: Error {
    case hostMissing
    case busy
  }
}

public extension EnvironmentValues {
  @Entry var nearbyExchange: NearbyExchangeAction = .init(presenter: nil)
}
