// swift-tools-version: 6.0
import PackageDescription
let sc: [SwiftSetting] = [.enableExperimentalFeature("StrictConcurrency=complete")]
let package = Package(
    name: "ProbePkg",
    platforms: [.iOS(.v15), .macOS(.v12)],
    targets: [
        .target(name: "ZTronAssetModel", swiftSettings: sc),
        .target(name: "ZTronAssetStorage", dependencies: ["ZTronAssetModel"], swiftSettings: sc),
        .target(name: "ZTronAssetTransport", dependencies: ["ZTronAssetModel"], swiftSettings: sc),
        .target(name: "ZTronAssetTestSupport", dependencies: ["ZTronAssetModel", "ZTronAssetStorage"], swiftSettings: sc),
        .testTarget(name: "ProbeTests", dependencies: ["ZTronAssetModel", "ZTronAssetStorage", "ZTronAssetTransport", "ZTronAssetTestSupport"], swiftSettings: sc),
    ]
)
