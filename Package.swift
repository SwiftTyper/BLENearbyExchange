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
  targets: [
    .target(
      name: "BLENearbyExchange",
      swiftSettings: [
        .swiftLanguageMode(.v6),
      ]
    ),
    .testTarget(
      name: "BLENearbyExchangeTests",
      dependencies: ["BLENearbyExchange"],
      swiftSettings: [
        .swiftLanguageMode(.v6),
      ]
    ),
  ]
)
