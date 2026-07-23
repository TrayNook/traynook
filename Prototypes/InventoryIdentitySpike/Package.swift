// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "TrayNookInventoryIdentitySpike",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(
      name: "InventoryIdentityCore",
      targets: ["InventoryIdentityCore"]
    ),
    .executable(
      name: "traynook-inventory-spike",
      targets: ["InventoryIdentitySpike"]
    ),
    .executable(
      name: "traynook-boundary-spike",
      targets: ["BoundarySpike"]
    ),
  ],
  targets: [
    .target(
      name: "InventoryIdentityCore"
    ),
    .executableTarget(
      name: "InventoryIdentitySpike",
      dependencies: ["InventoryIdentityCore"]
    ),
    .executableTarget(
      name: "BoundarySpike",
      dependencies: ["InventoryIdentityCore"]
    ),
    .testTarget(
      name: "InventoryIdentityCoreTests",
      dependencies: ["InventoryIdentityCore"],
      resources: [
        .copy("Fixtures")
      ]
    ),
  ]
)
