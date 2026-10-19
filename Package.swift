// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "BLENearbyExchange",
  platforms: [
    .iOS(.v18),
    .macOS(.v15),
  ],
  products: [
    .library(name: "BLENearbyExchange", targets: ["BLENearbyExchange"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/nordicsemi/IOS-CoreBluetooth-Mock",
      branch: "main",
    ),
    .package(
      url: "https://github.com/pointfreeco/swift-clocks",
      from: "1.1.1",
    ),
  ],
  targets: [
    .target(
      name: "BLENearbyExchange",
      dependencies: [
        "BLENearbyExchangeCore",
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6),
      ],
    ),
    .target(
      name: "BLENearbyExchangeCore",
      dependencies: [
        .product(name: "CoreBluetoothMock", package: "iOS-CoreBluetooth-Mock"),
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6),
      ],
    ),
    .testTarget(
      name: "BLENearbyExchangeCoreTests",
      dependencies: [
        "BLENearbyExchangeCore",
        .product(name: "CoreBluetoothMock", package: "iOS-CoreBluetooth-Mock"),
        .product(name: "Clocks", package: "swift-clocks"),
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6),
      ],
    ),
  ],
)
