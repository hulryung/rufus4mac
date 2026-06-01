// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "rufus4mac",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "RufusCore", targets: ["RufusCore"]),
        .library(name: "DiskDiscovery", targets: ["DiskDiscovery"]),
        .library(name: "SystemTools", targets: ["SystemTools"]),
        .library(name: "WindowsMedia", targets: ["WindowsMedia"]),
    ],
    targets: [
        .target(name: "RufusCore"),
        .target(name: "DiskDiscovery"),
        .target(name: "TestSupport"),
        .target(name: "SystemTools"),
        .target(name: "WindowsMedia", dependencies: ["SystemTools"]),
        .testTarget(name: "RufusCoreTests", dependencies: ["RufusCore", "TestSupport", "DiskDiscovery"]),
        .testTarget(name: "DiskDiscoveryTests", dependencies: ["DiskDiscovery"]),
        .testTarget(name: "SystemToolsTests", dependencies: ["SystemTools"]),
        .testTarget(name: "WindowsMediaTests", dependencies: ["WindowsMedia", "SystemTools"]),
    ]
)
