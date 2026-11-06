// swift-tools-version: 6.0
// Scratch probe harness for the s3ah verifier: the worktree's Model, Storage and Transport, unmodified.
import PackageDescription
let sc: [SwiftSetting] = [.enableExperimentalFeature("StrictConcurrency=complete")]
let package = Package(
    name: "S3AHProbe",
    platforms: [.iOS(.v15), .macOS(.v12)],
    targets: [
        .target(name: "ZTronAssetModel", swiftSettings: sc),
        .target(name: "ZTronAssetStorage", dependencies: ["ZTronAssetModel"], swiftSettings: sc),
        .target(name: "ZTronAssetTransport", dependencies: ["ZTronAssetModel"], swiftSettings: sc),
        .testTarget(name: "S3AHVerifierProbes", dependencies: ["ZTronAssetModel", "ZTronAssetStorage", "ZTronAssetTransport"], swiftSettings: sc),
    ],
    swiftLanguageModes: [.v6]
)
