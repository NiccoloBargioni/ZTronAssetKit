// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "HangProbe",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "HangProbe"),
        .testTarget(name: "HangProbeTests", dependencies: ["HangProbe"]),
    ]
)
