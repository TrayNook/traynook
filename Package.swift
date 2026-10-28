// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TrayNook",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "TrayNook", targets: ["TrayNook"])],
    targets: [
        .target(
            name: "InventoryIdentityCore",
            path: "Prototypes/InventoryIdentitySpike/Sources/InventoryIdentityCore"
        ),
        .executableTarget(
            name: "TrayNook",
            dependencies: ["InventoryIdentityCore"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "TrayNookTests",
            dependencies: ["TrayNook", "InventoryIdentityCore"]
        ),
        .testTarget(
            name: "InventoryIdentityCoreTests",
            dependencies: ["InventoryIdentityCore"],
            path: "Prototypes/InventoryIdentitySpike/Tests/InventoryIdentityCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
