// swift-tools-version: 6.0
// Scratch copy for the cycle-21 correctness verifier's probes (never committed): the worktree's Sync sources and
// tests, with the Sync test target only.
import PackageDescription

let strictConcurrency: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency=complete"),
]

let package = Package(
    name: "ZTronAssetKitProbes",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    targets: [
        .target(name: "ZTronAssetModel", swiftSettings: strictConcurrency),
        .target(name: "ZTronAssetStorage", dependencies: ["ZTronAssetModel"], swiftSettings: strictConcurrency),
        .target(name: "ZTronAssetTransport", dependencies: ["ZTronAssetModel"], swiftSettings: strictConcurrency),
        .target(name: "ZTronAssetAppleHosted", dependencies: ["ZTronAssetModel"], swiftSettings: strictConcurrency),
        .target(name: "ZTronAssetSync", dependencies: ["ZTronAssetModel", "ZTronAssetStorage"], swiftSettings: strictConcurrency),
        .target(
            name: "ZTronAssetTestSupport",
            dependencies: ["ZTronAssetModel", "ZTronAssetStorage"],
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "ZTronAssetKit",
            dependencies: ["ZTronAssetModel", "ZTronAssetStorage", "ZTronAssetTransport", "ZTronAssetAppleHosted", "ZTronAssetSync"],
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "ZTronAssetKitBenchmarks",
            dependencies: ["ZTronAssetKit", "ZTronAssetTestSupport"],
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "ZTronAssetSyncTests",
            dependencies: ["ZTronAssetSync", "ZTronAssetTransport", "ZTronAssetAppleHosted", "ZTronAssetTestSupport"],
            swiftSettings: strictConcurrency
        ),
    ],
    swiftLanguageModes: [.v6]
)
