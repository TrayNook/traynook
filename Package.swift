// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TrayNook",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "TrayNook", targets: ["TrayNook"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(
            name: "InventoryIdentityCore",
            path: "Prototypes/InventoryIdentitySpike/Sources/InventoryIdentityCore"
        ),
        .executableTarget(
            name: "TrayNook",
            dependencies: ["InventoryIdentityCore", .product(name: "Sparkle", package: "Sparkle")],
            resources: [.process("Resources")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
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
