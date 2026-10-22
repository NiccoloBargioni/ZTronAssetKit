import Foundation
import Testing
@testable import ZTronAssetKit
import ZTronAssetStorage
import ZTronAssetSync
import ZTronAssetTestSupport

/// The fallback chain's parity with the prior art's `BasicImagePage` (R-CAR-2, SPEC §7.3 "facade parity"; RECON §5:
/// bundle → local → network, the local step offline over the cached manifest, candidate extensions in order).
@Suite("Fallback chain")
struct FallbackChainTests {
    private static let bundleURL = URL(fileURLWithPath: "/fake-bundle/a.png")

    /// A started client that holds `entries` present.
    @available(macOS 15.0, iOS 18.0, *)
    private static func clientHolding(_ entries: [(ManifestEntry, Data)], bulk: (any BlockingExecutor)? = nil) async throws -> KitHarness {
        let harness = KitHarness.make(bulk: bulk)
        await harness.serve(entries)
        try await harness.startAndSettle()
        try await harness.drive(until: { $0.isIdleSilent })
        return harness
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-2: a bundle hit wins over a local copy", .timeLimit(.minutes(1)))
    func bundleWinsOverLocal() async throws {
        let bytes = KitFixture.bytes(81)
        let entry = KitFixture.entry("a", bytes)
        let harness = try await FallbackChainTests.clientHolding([(entry, bytes)])
        let bundle = FakeBundleLookup([BundleResourceKey(name: "a", fileExtension: "PNG"): FallbackChainTests.bundleURL])
        let chain = AssetFallbackChain(client: harness.client, bundle: bundle)
        await chain.prepare(kinds: [.image])
        let (hit, local) = await MainActor.run { (chain.locate("a", kind: .image), harness.client.lookup("a")) }
        #expect(local != nil, "setup: the store holds a local copy")
        #expect(hit == .bundle(FallbackChainTests.bundleURL))
        await harness.client.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-2: image candidates are tried in heic, png, jpg, jpeg order", .timeLimit(.minutes(1)))
    func imageCandidateOrder() async throws {
        let harness = KitHarness.make()
        let jpg = URL(fileURLWithPath: "/fake-bundle/x.jpg")
        let png = URL(fileURLWithPath: "/fake-bundle/x.png")
        let jpeg = URL(fileURLWithPath: "/fake-bundle/y.jpeg")
        let bundle = FakeBundleLookup([
            BundleResourceKey(name: "x", fileExtension: "jpg"): jpg,
            BundleResourceKey(name: "x", fileExtension: "png"): png,
            BundleResourceKey(name: "y", fileExtension: "jpeg"): jpeg,
            BundleResourceKey(name: "z", fileExtension: "svg"): URL(fileURLWithPath: "/fake-bundle/z.svg"),
        ])
        let chain = AssetFallbackChain(client: harness.client, bundle: bundle)
        await chain.prepare(kinds: [.image])
        let (x, y, z) = await MainActor.run { (chain.locate("x", kind: .image), chain.locate("y", kind: .image), chain.locate("z", kind: .image)) }
        #expect(x == .bundle(png), "png precedes jpg")
        #expect(y == .bundle(jpeg))
        #expect(z == nil, "an svg is no image candidate, and the image index holds no svg")
        await harness.client.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-2: svg, video and audio kinds find bundled resources by their candidate extensions", .timeLimit(.minutes(1)))
    func otherKindsUseTheirExtensions() async throws {
        let harness = KitHarness.make()
        let svg = URL(fileURLWithPath: "/fake-bundle/icon.svg")
        let video = URL(fileURLWithPath: "/fake-bundle/intro.mov")
        let audio = URL(fileURLWithPath: "/fake-bundle/beep.mp3")
        let bundle = FakeBundleLookup([
            BundleResourceKey(name: "icon", fileExtension: "svg"): svg,
            BundleResourceKey(name: "intro", fileExtension: "mov"): video,
            BundleResourceKey(name: "beep", fileExtension: "mp3"): audio,
        ])
        let chain = AssetFallbackChain(client: harness.client, bundle: bundle)
        await chain.prepare(kinds: [.svg, .video(fileExtension: "MOV"), .audio])
        let hits = await MainActor.run {
            [
                chain.locate("icon", kind: .svg),
                chain.locate("intro", kind: .video(fileExtension: "mov")),
                chain.locate("beep", kind: .audio),
                chain.locate("intro", kind: .video(fileExtension: "mp4")),
            ]
        }
        #expect(hits == [.bundle(svg), .bundle(video), .bundle(audio), nil])
        await harness.client.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-2: a local asset is found synchronously with zero file-system calls when the bundle misses", .timeLimit(.minutes(1)))
    func localStepWithoutIO() async throws {
        let bytes = KitFixture.bytes(82)
        let entry = KitFixture.entry("a", bytes)
        let harness = try await FallbackChainTests.clientHolding([(entry, bytes)])
        let chain = AssetFallbackChain(client: harness.client, bundle: FakeBundleLookup([:]))
        await chain.prepare(kinds: [.image])
        let before = harness.fileSystem.operations.count
        let hit = await MainActor.run { chain.locate("a", kind: .image) }
        #expect(harness.fileSystem.operations.count == before, "locate touched the file system")
        guard case .local(let location)? = hit else {
            Issue.record("the local step finds the stored copy: \(String(describing: hit))")
            return
        }
        #expect(location.fileExtension == AssetFileExtension("png"))
        await harness.client.shutdown()
    }

    /// ADR-037's deviation, documented by this parity case: the prior art's local step returned a manifest-known file
    /// whatever its extension; the chain filters candidates at the local step too.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-2: a local asset whose extension is not a candidate is not returned", .timeLimit(.minutes(1)))
    func localStepFiltersExtensions() async throws {
        let bytes = KitFixture.bytes(83)
        let entry = KitFixture.entry("clip", bytes, ext: "mp4")
        let harness = try await FallbackChainTests.clientHolding([(entry, bytes)])
        let chain = AssetFallbackChain(client: harness.client, bundle: FakeBundleLookup([:]))
        let (asImage, asVideo) = await MainActor.run { (chain.locate("clip", kind: .image), chain.locate("clip", kind: .video(fileExtension: "mp4"))) }
        #expect(asImage == nil)
        guard case .local? = asVideo else {
            Issue.record("the same asset is found as a video: \(String(describing: asVideo))")
            return
        }
        await harness.client.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-2: when bundle and local both miss, fetch downloads at userInitiated and the next locate hits local", .timeLimit(.minutes(1)))
    func fetchThenLocal() async throws {
        let bytes = KitFixture.bytes(84)
        let entry = KitFixture.entry("od", bytes, policy: .onDemand)
        let harness = KitHarness.make()
        await harness.serveManifest([entry])
        try await harness.startAndSettle()
        await harness.source.script(entry.transferID, [.stage(bytes)])
        let chain = AssetFallbackChain(client: harness.client, bundle: FakeBundleLookup([:]))
        #expect(await MainActor.run { chain.locate("od", kind: .image) } == nil)
        let url = try await harness.withClock { () throws(AssetError) -> URL in
            try await chain.fetch("od", kind: .image)
        }
        #expect(url.pathExtension == "png")
        let started = await harness.source.starts.filter { $0.id == entry.transferID }
        #expect(started.map(\.priority) == [.userInitiated])
        let hit = await MainActor.run { chain.locate("od", kind: .image) }
        guard case .local(let location)? = hit else {
            Issue.record("the next locate hits local: \(String(describing: hit))")
            return
        }
        #expect(location.url == url)
        await harness.client.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-2: fetch fails with notFound for an identifier unknown to a fresh manifest and for an asset whose extension is not a candidate", .timeLimit(.minutes(1)))
    func fetchNotFound() async throws {
        let bytes = KitFixture.bytes(85)
        let entry = KitFixture.entry("clip", bytes, ext: "mp4")
        let harness = try await FallbackChainTests.clientHolding([(entry, bytes)])
        await harness.serveManifest([entry], etag: "v2")
        let chain = AssetFallbackChain(client: harness.client, bundle: FakeBundleLookup([:]))
        await #expect(throws: AssetError.notFound) {
            try await harness.withClock { () throws(AssetError) -> URL in
                try await chain.fetch("never-listed", kind: .image)
            }
        }
        // Prior art `CDNAssetResolver.swift:46`: a resolved file of another kind is not found.
        await #expect(throws: AssetError.notFound) {
            try await harness.withClock { () throws(AssetError) -> URL in
                try await chain.fetch("clip", kind: .image)
            }
        }
        await harness.client.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-2: prepare enumerates the bundle in one unit on the client's bulk executor, never on the main thread", .timeLimit(.minutes(1)))
    func prepareRunsOnBulkExecutor() async throws {
        let bulk = SteppedBlockingExecutor(holding: true)
        let harness = KitHarness.make(bulk: bulk)
        let bundle = FakeBundleLookup([BundleResourceKey(name: "a", fileExtension: "png"): FallbackChainTests.bundleURL])
        let chain = AssetFallbackChain(client: harness.client, bundle: bundle)
        let preparing = Task { @MainActor in
            await chain.prepare(kinds: [.image, .image])
        }
        try await bulk.requireHeldUnits(atLeast: 1)
        #expect(bundle.enumerations.isEmpty, "the enumeration waits for its unit")
        #expect(await MainActor.run { chain.locate("a", kind: .image) } == nil, "nothing is installed before the unit ran")
        await bulk.releaseAll()
        await preparing.value
        #expect(bundle.enumerations == [false], "one enumeration, off the main thread")
        #expect(await bulk.completedUnits.count == 1)
        #expect(await MainActor.run { chain.locate("a", kind: .image) } == .bundle(FallbackChainTests.bundleURL))
        await harness.client.shutdown()
    }

    @Test("R-CAR-2: the live bundle lookup lists only resources with the requested extensions, keyed by name")
    func liveBundleLookup() {
        let resources = MainBundleLookup().resources(withExtensions: ["plist", "json"])
        for (key, url) in resources {
            #expect(["plist", "json"].contains(key.fileExtension))
            #expect(url.pathExtension.lowercased() == key.fileExtension)
            #expect(url.deletingPathExtension().lastPathComponent == key.name)
        }
    }
}
