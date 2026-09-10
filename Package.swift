// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "BLENearbyExchange",
  platforms: [
    .iOS(.v17),
    .macOS(.v15),
  ],
  products: [
    .library(name: "BLENearbyExchange", targets: ["BLENearbyExchange"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/SwiftTyper/IOS-CoreBluetooth-Mock",
      branch: "feature/peripheral-manager-support"
    ),
  ],
  targets: [
    .target(
      name: "BLENearbyExchange",
      dependencies: [
        "BLENearbyExchangeCore"
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6),
      ]
    ),
    .target(
      name: "BLENearbyExchangeCore",
      dependencies: [
        .product(name: "CoreBluetoothMock", package: "iOS-CoreBluetooth-Mock"),
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6),
      ]
    ),
    .testTarget(
      name: "BLENearbyExchangeCoreTests",
      dependencies: [
        "BLENearbyExchangeCore",
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6),
      ]
    ),
  ]
)
