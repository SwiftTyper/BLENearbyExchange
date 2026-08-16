import SwiftUI

public extension View {
  func nearbyExchangeHost(
    configuration: NearbyExchange.Configuration = .init()
  ) -> some View {
    modifier(NearbyExchangeHostModifier(configuration: configuration))
  }
}

private struct NearbyExchangeHostModifier: ViewModifier {
  @State private var presenter: NearbyExchangePresenter

  init(configuration: NearbyExchange.Configuration) {
    _presenter = State(
      wrappedValue: NearbyExchangePresenter(configuration: configuration)
    )
  }

  func body(content: Content) -> some View {
    content
      .environment(\.nearbyExchange, NearbyExchangeAction(presenter: presenter))
      .sheet(isPresented: $presenter.isPresented) {
        presenter.cancel()
      } content: {
        NearbyExchangeSheet(presenter: presenter)
      }
  }
}
