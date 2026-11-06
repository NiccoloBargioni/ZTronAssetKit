// swift-tools-version: 6.0
// Scratch copy for the cycle-22 correctness verifier's probes (never committed): HEAD's sources and Sync tests, with
// the Sync test target only.
import PackageDescription

let strictConcurrency: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency=complete"),
]

let package = Package(
    name: "ZTronAssetKitProbesC22Sync",
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
        .testTarget(
            name: "ZTronAssetSyncTests",
            dependencies: ["ZTronAssetSync", "ZTronAssetTransport", "ZTronAssetAppleHosted", "ZTronAssetTestSupport"],
            swiftSettings: strictConcurrency
        ),
    ],
    swiftLanguageModes: [.v6]
)
