// swift-tools-version: 6.0
// Tools version 6.0 is the lowest that gives Swift 6 language mode, so downstream packages on
// tools 6.0 (ZTronCarouselCore) can depend on this one. Building and testing here needs Swift 6.3+.
// Warnings-as-errors is passed by Scripts/verify.sh on the command line, never set here.
import PackageDescription

/// Swift 6 mode already implies complete strict concurrency; it is also spelled out explicitly so
/// the intent survives a future language-mode change.
let strictConcurrency: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency=complete"),
]

let package = Package(
    name: "ZTronAssetKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "ZTronAssetKit", targets: ["ZTronAssetKit"]),
    ],
    targets: [
        .target(name: "ZTronAssetModel", swiftSettings: strictConcurrency),
        .target(name: "ZTronAssetStorage", dependencies: ["ZTronAssetModel"], swiftSettings: strictConcurrency),
        .target(name: "ZTronAssetTransport", dependencies: ["ZTronAssetModel"], swiftSettings: strictConcurrency),
        .target(name: "ZTronAssetAppleHosted", dependencies: ["ZTronAssetModel"], swiftSettings: strictConcurrency),
        .target(name: "ZTronAssetSync", dependencies: ["ZTronAssetModel", "ZTronAssetStorage"], swiftSettings: strictConcurrency),
        .target(
            name: "ZTronAssetKit",
            dependencies: [
                "ZTronAssetModel",
                "ZTronAssetStorage",
                "ZTronAssetTransport",
                "ZTronAssetAppleHosted",
                "ZTronAssetSync",
            ],
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "ZTronAssetTestSupport",
            dependencies: ["ZTronAssetModel", "ZTronAssetStorage"],
            swiftSettings: strictConcurrency
        ),

        .testTarget(
            name: "ZTronAssetModelTests",
            dependencies: ["ZTronAssetModel", "ZTronAssetTestSupport"],
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "ZTronAssetStorageTests",
            dependencies: ["ZTronAssetStorage", "ZTronAssetTestSupport"],
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "ZTronAssetTransportTests",
            dependencies: ["ZTronAssetTransport", "ZTronAssetTestSupport"],
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "ZTronAssetAppleHostedTests",
            dependencies: ["ZTronAssetAppleHosted", "ZTronAssetTestSupport"],
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "ZTronAssetSyncTests",
            dependencies: ["ZTronAssetSync", "ZTronAssetTestSupport"],
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "ZTronAssetKitTests",
            dependencies: ["ZTronAssetKit", "ZTronAssetTestSupport"],
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "ZTronAssetKitBenchmarks",
            dependencies: ["ZTronAssetKit", "ZTronAssetTestSupport"],
            swiftSettings: strictConcurrency
        ),
        // R-CAR-6 (ADR-006, ADR-033): the prior art's public CDN symbols as compatibility shims over AssetClient,
        // compiled and exercised here because this package never writes into ZTronCarouselCore. A test target, so
        // the shims never ship in the product and Combine (CDNSyncCoordinator is an ObservableObject) stays out of
        // every production target (R-CAR-9).
        .testTarget(
            name: "ZTronAssetCompatibilityTests",
            dependencies: ["ZTronAssetKit", "ZTronAssetTestSupport"],
            swiftSettings: strictConcurrency
        ),
    ],
    swiftLanguageModes: [.v6]
)
