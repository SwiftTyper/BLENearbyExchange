import BLENearbyExchange
import SwiftUI

@main
struct NearbyExchangeDemoApp: App {
  var body: some Scene {
    WindowGroup {
      ContentView()
        .nearbyExchangeHost()
    }
  }
}
