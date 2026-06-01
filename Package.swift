// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "rufus4mac",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "RufusCore", targets: ["RufusCore"]),
        .library(name: "DiskDiscovery", targets: ["DiskDiscovery"]),
    ],
    targets: [
        .target(name: "RufusCore"),
        .target(name: "DiskDiscovery"),
        .target(name: "TestSupport"),
        .testTarget(name: "RufusCoreTests", dependencies: ["RufusCore", "TestSupport", "DiskDiscovery"]),
        .testTarget(name: "DiskDiscoveryTests", dependencies: ["DiskDiscovery"]),
    ]
)
