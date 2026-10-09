# Legacy layout fixture `legacy-v0` (R-STO-11, WP-C)

The prior art's on-disk layout (`Library/Caches/CDNAssets`, store.md §7, RECON §5) **as the prior-art code itself wrote it**:
`CDNAssets/` holds the files, `manifest.json` (the cached manifest, a bare JSON array of `CDNAsset`) and
`local-checksums.json` (identifier → lowercase hex SHA-256 of the stored file). Legacy-migration tests copy this tree into
the fake file system's legacy root (`<Caches>/CDNAssets`) together with a `UserDefaults` stamp in `FakeLegacyDefaults`.
Nothing here is a SwiftPM resource; tests find it through `#filePath`. Do not edit by hand: regenerate as below.

## How it was produced (WP-C, Stage 2 L3, 2026-10-09)

1. The two prior-art sources were copied **read-only** from the sibling repository into a throwaway SwiftPM package
   under the git-ignored `.build-c-legacy/` of this repository (nothing was written into `../ZTronCarouselCore`; its
   working tree had no local changes in `CDN/`, last commit touching them `b4a5f4c6e513676e7d34aa8e1a0db54740d3e737`):
   - `Sources/ZTronCarouselCore/CDN/CDNAsset.swift`, SHA-256 `336022602c52276cb957521d53995247ce6f00c8a568e704a76f0ff53d801831`
   - `Sources/ZTronCarouselCore/CDN/CDNLocalStore.swift`, SHA-256 `929cb5a74893d0eb53a0a9cae3e288a4429e846ea4fa60b00127a1843b48ad4d`

   Both import only `Foundation` (and `CryptoKit` for the second), checked with `grep '^import'` before the copy.
2. A driver (`main.swift` below) ran the real `CDNLocalStore` against `Tests/Fixtures/manifests/aws/v1.json`, then
   `v2-checksum-change.json`, the way the prior art's `CDNSyncCoordinator.syncIfNeeded` does: `reconcile(newManifest:)`
   first, then `store(temporaryURL:for:)` for every asset `hasAsset(_:)` reports missing or stale. Each "download" is a
   copy of the payload in `Tests/Fixtures/payloads/` whose SHA-256 equals the asset's checksum. Output of the run:
   `v1.json: 13 assets, migrated 0, pruned 0, stored 13`, `v2-checksum-change.json: 13 assets, migrated 0, pruned 0,
   stored 2` (the two v2 content changes).
3. The resulting `CDNAssets/` directory was copied here unchanged.

Commands, from the repository root (`TMPDIR` inside the throwaway package, so nothing is written outside the repository):

```
mkdir -p .build-c-legacy/Sources/LegacyProbe .build-c-legacy/tmp .build-c-legacy/out
cp ../ZTronCarouselCore/Sources/ZTronCarouselCore/CDN/CDNAsset.swift \
   ../ZTronCarouselCore/Sources/ZTronCarouselCore/CDN/CDNLocalStore.swift .build-c-legacy/Sources/LegacyProbe/
# write .build-c-legacy/Package.swift and .build-c-legacy/Sources/LegacyProbe/main.swift as below
TMPDIR=$PWD/.build-c-legacy/tmp swift build --package-path .build-c-legacy --scratch-path .build-c-legacy/.build
.build-c-legacy/.build/debug/LegacyProbe "$PWD/Tests/Fixtures" "$PWD/.build-c-legacy/out" "$PWD/.build-c-legacy/tmp"
cp -R .build-c-legacy/out/CDNAssets Tests/Fixtures/legacy-v0/
```

`Package.swift` of the throwaway package:

```swift
// swift-tools-version: 6.0
// Throwaway driver (WP-C, never committed): runs the prior art's CDNAsset.swift and CDNLocalStore.swift, copied
// read-only from ../ZTronCarouselCore, to produce Tests/Fixtures/legacy-v0/.
import PackageDescription

let package = Package(
    name: "LegacyProbe",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(name: "LegacyProbe", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
```

`Sources/LegacyProbe/main.swift`:

```swift
import CryptoKit
import Foundation

// Usage: LegacyProbe <fixtures dir> <output base> <scratch dir>
// Syncs the prior-art CDNLocalStore at <output base>/CDNAssets through manifests/aws/v1.json, then
// manifests/aws/v2-checksum-change.json, the way CDNSyncCoordinator.syncIfNeeded does: reconcile(newManifest:)
// first, then store(temporaryURL:for:) for every asset hasAsset(_:) reports missing or stale, each "download" being a
// copy of the payload whose SHA-256 is the asset's checksum.
let arguments = CommandLine.arguments
let fixtures = URL(fileURLWithPath: arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
let scratch = URL(fileURLWithPath: arguments[3], isDirectory: true)

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

let payloadDirectory = fixtures.appendingPathComponent("payloads", isDirectory: true)
var payloads: [String: Data] = [:]
for name in try FileManager.default.contentsOfDirectory(atPath: payloadDirectory.path) {
    let data = try Data(contentsOf: payloadDirectory.appendingPathComponent(name))
    payloads[sha256Hex(data)] = data
}

let store = CDNLocalStore(baseDirectory: output.appendingPathComponent("CDNAssets", isDirectory: true))
var downloads = 0
for manifestName in ["v1.json", "v2-checksum-change.json"] {
    let url = fixtures.appendingPathComponent("manifests/aws/\(manifestName)")
    let manifest = try JSONDecoder().decode([CDNAsset].self, from: Data(contentsOf: url))
    let summary = store.reconcile(newManifest: manifest)
    var stored = 0
    for asset in manifest where !store.hasAsset(asset) {
        guard let checksum = asset.checksum, let bytes = payloads[checksum] else {
            fatalError("no payload for \(asset.identifier)")
        }
        let temporary = scratch.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: temporary)
        try store.store(temporaryURL: temporary, for: asset)
        stored += 1
    }
    downloads += stored
    print("\(manifestName): \(manifest.count) assets, migrated \(summary.migratedCount), pruned \(summary.prunedCount), stored \(stored)")
}
print("total stored: \(downloads)")
```

## Contents

Every file below is the v2 content of its entry (the state after the second sync): the 13 entries of
`manifests/aws/v2-checksum-change.json`, including the dedupe pair `bo7.ri.character.keeper.portrait` /
`bo7.ri.character.keeper.card` (two files, identical bytes). `manifest.json` and `local-checksums.json` are
`JSONEncoder` output, so their key order is whatever Foundation chose in that run; a regeneration may order keys
differently but decodes to the same values.

| file | bytes | sha256 |
|---|---|---|
| `CDNAssets/Black Ops 6/Terminus/Control Room/icon.jpg` | 686 | `418dc9bd76572bc23b33451eff6ee53abda29ff3e64b943f91ba751f40f9af68` |
| `CDNAssets/Black Ops 6/Terminus/Control Room/outline.svg` | 367 | `50a4c45e1bd4061e1317b20b42ab60d34103a8edef6db0fd8ad7f2dbac98252e` |
| `CDNAssets/Black Ops 7/Menus/background.heic` | 64 | `fe155aac5fc5f0e2e797a0a5004d7107f30c60f0107892ca926593f47c0d2a3b` |
| `CDNAssets/Black Ops 7/Rex Infernus/Audio/Crypt Ambience.wav` | 2044 | `40590444e1c6dc95f5ac111e4b690c243866ce802d9bdaa8014e0ea89e042fc7` |
| `CDNAssets/Black Ops 7/Rex Infernus/Audio/theme.mp3` | 1312 | `47a1445158b1da873e408818d5382015dd37cb53b8342af6ca770a8facf31a24` |
| `CDNAssets/Black Ops 7/Rex Infernus/Characters/Keeper Card.jpg` | 963 | `34daebb47a6eb1d6e10e5720c90f01527455d5d497cd1385818c5970f38ff245` |
| `CDNAssets/Black Ops 7/Rex Infernus/Characters/Keeper Portrait.jpg` | 963 | `34daebb47a6eb1d6e10e5720c90f01527455d5d497cd1385818c5970f38ff245` |
| `CDNAssets/Black Ops 7/Rex Infernus/Cinematics/Intro.mp4` | 4096 | `088e1013639dbbcfe47fbe70681ba30579bbbd64a712d5dc7b15e29591193381` |
| `CDNAssets/Black Ops 7/Rex Infernus/Vehytherion Temple/Temple Map.png` | 1236 | `9221834f012ace4d8c4b2972bb29df92c42ee4693c5707c661e17cd6285645bc` |
| `CDNAssets/Black Ops 7/Rex Infernus/Vehytherion Temple/icon.heic` | 1792 | `d2faa4403b6aa24620dc1fb62423766831cf8030b400d0a264c624bea55360eb` |
| `CDNAssets/Black Ops 7/Rex Infernus/Vehytherion Temple/outline.svg` | 375 | `a5ff10c44f45daf204b2981b68c20e593337dfeb78a755d38f9cce3e925ec2ed` |
| `CDNAssets/World at War/Nacht der Untoten/Audio/sting.wav` | 644 | `4854c15ea5afeb8fd86edb5bc9f25d5a3b8932bd8272d66596eafee389359933` |
| `CDNAssets/World at War/Nacht der Untoten/Title Card.png` | 460 | `ae029dcf3d58c2bc200e889211cc595ae40315edfc3910b8a1c5c0f5f3612a25` |
| `CDNAssets/local-checksums.json` | 1297 | `3130a05d335e4db578e37a2b22ba920232ebc0c8adacc50548270829f7580602` |
| `CDNAssets/manifest.json` | 4162 | `ce3424b55849288a6f5bf5823599ea78084362d2abb768766f2d0690c744f003` |
