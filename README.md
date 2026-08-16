# BLENearbyExchange

a simple BLE exchange where each device sends and receives a data payload (originally inspired by Apple's tap to exchange contact info functionality)

## Showcase 

[showcase.webm](https://github.com/user-attachments/assets/e1b75aec-c173-4913-a7bd-5c49d4e267a6)

[showcase_atoms.webm](https://github.com/user-attachments/assets/46390f53-4397-4eac-bd0d-365c911c3733)

(sorry for the shitty video quality)

## Usage 

Access the nearbyExchange API from the environment of a SwiftUI view
```swift
@Environment(\.nearbyExchange) private var nearbyExchange

let peer = try await nearbyExchange.run(payload: Data(name.utf8))
```

within the `run(payload:)` include whatever you want to send to the other device during the exchange 

Apply it to an *ancestor* of the view that reads `\.nearbyExchange`
```swift
WindowGroup {
  ContentView()
   .nearbyExchangeHost()
}
```

## To Do
- [ ] Play around with Bluetooth Channel Sounding
- [ ] Encrypt Traffic
- [ ] Mock BLE for units
