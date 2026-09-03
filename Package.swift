// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "BLENearbyExchange",
  platforms: [
    .iOS(.v17),
  ],
  products: [
    .library(name: "BLENearbyExchange", targets: ["BLENearbyExchange"]),
  ],
  dependencies: [
    .package(url: "https://github.com/SwiftTyper/IOS-CoreBluetooth-Mock", branch: "main"),
  ],
  targets: [
    .target(
      name: "BLENearbyExchange",
      dependencies: [
        .product(name: "CoreBluetoothMock", package: "iOS-CoreBluetooth-Mock"),
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6),
      ]
    ),
    .testTarget(
      name: "BLENearbyExchangeTests",
      dependencies: [
        "BLENearbyExchange",
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6),
      ]
    ),
  ]
)
