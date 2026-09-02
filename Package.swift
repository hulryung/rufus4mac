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
        .library(name: "DiskFormat", targets: ["DiskFormat"]),
        .library(name: "WimSplit", targets: ["WimSplit"]),
    ],
    targets: [
        .target(name: "RufusCore"),
        .target(name: "DiskDiscovery"),
        .target(name: "TestSupport"),
        .target(name: "SystemTools"),
        .target(name: "WindowsMedia", dependencies: ["SystemTools", "WimSplit"]),
        .target(name: "DiskFormat", dependencies: ["SystemTools"]),
        // MIT-licensed; see Sources/WimSplit/LICENSE. Deliberately dependency-free.
        .target(name: "WimSplit", exclude: ["LICENSE", "README.md"]),
        .testTarget(name: "DiskFormatTests", dependencies: ["DiskFormat"]),
        .testTarget(name: "RufusCoreTests", dependencies: ["RufusCore", "TestSupport", "DiskDiscovery"]),
        .testTarget(name: "DiskDiscoveryTests", dependencies: ["DiskDiscovery"]),
        .testTarget(name: "SystemToolsTests", dependencies: ["SystemTools"]),
        .testTarget(name: "WindowsMediaTests", dependencies: ["WindowsMedia", "SystemTools"]),
        .testTarget(name: "WimSplitTests", dependencies: ["WimSplit"]),
    ]
)
