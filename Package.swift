// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "rufus4mac",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DiskEvents", targets: ["DiskEvents"]),
        .library(name: "Localization", targets: ["Localization"]),
        .library(name: "RufusCore", targets: ["RufusCore"]),
        .library(name: "DiskDiscovery", targets: ["DiskDiscovery"]),
        .library(name: "SystemTools", targets: ["SystemTools"]),
        .library(name: "WindowsMedia", targets: ["WindowsMedia"]),
        .library(name: "DiskFormat", targets: ["DiskFormat"]),
        .library(name: "WimSplit", targets: ["WimSplit"]),
    ],
    targets: [
        .target(name: "DiskEvents", linkerSettings: [.linkedFramework("DiskArbitration")]),
        .target(name: "Localization", resources: [.process("Resources")]),
        .testTarget(name: "LocalizationTests", dependencies: ["Localization"]),
        .target(name: "RufusCore"),
        .target(name: "DiskDiscovery"),
        .target(name: "TestSupport"),
        .target(name: "SystemTools"),
        .target(name: "WindowsMedia", dependencies: ["SystemTools", "WimSplit"],
                resources: [.process("Resources")]),
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
