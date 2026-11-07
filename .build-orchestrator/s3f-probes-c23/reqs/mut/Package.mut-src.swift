// swift-tools-version: 6.0
// Scratch copy for the cycle-23 reqs verifier's mutant runs (never committed): d88bdb1's sources and Sync tests, with
// the Sync test target only (targets and dependencies as in the repository's Package.swift).
import PackageDescription

let strictConcurrency: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency=complete"),
]

let package = Package(
    name: "ZTronAssetKitVerifyC23ReqsMut",
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
