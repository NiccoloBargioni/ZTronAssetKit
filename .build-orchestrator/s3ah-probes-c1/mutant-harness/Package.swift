// swift-tools-version: 6.0
// Scratch mutant harness for the s3ah verifier (copy of the worktree's Model, Storage and TestSupport).
import PackageDescription
let sc: [SwiftSetting] = [.enableExperimentalFeature("StrictConcurrency=complete")]
let package = Package(
    name: "S3AHMutant",
    platforms: [.iOS(.v15), .macOS(.v12)],
    targets: [
        .target(name: "ZTronAssetModel", swiftSettings: sc),
        .target(name: "ZTronAssetStorage", dependencies: ["ZTronAssetModel"], swiftSettings: sc),
        .target(name: "ZTronAssetTestSupport", dependencies: ["ZTronAssetModel", "ZTronAssetStorage"], swiftSettings: sc),
        .testTarget(name: "ZTronAssetModelTests", dependencies: ["ZTronAssetModel", "ZTronAssetTestSupport"], swiftSettings: sc),
        .testTarget(name: "MTSTests", dependencies: ["ZTronAssetModel", "ZTronAssetTestSupport"], swiftSettings: sc),
    ],
    swiftLanguageModes: [.v6]
)
