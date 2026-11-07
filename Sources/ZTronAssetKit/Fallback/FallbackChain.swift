import Foundation
import ZTronAssetModel

/// What kind of media a page shows, which fixes its candidate extensions (R-CAR-2, prior-art parity).
public enum AssetKind: Sendable, Hashable {
    /// `BasicImagePage`: `heic, png, jpg, jpeg`, in that order.
    case image
    /// `ZTronSVGView`: `svg`.
    case svg
    /// `BasicVideoPage`: the descriptor's own extension.
    case video(fileExtension: String)
    /// Audio: `wav, mp3`.
    case audio

    /// The extensions tried, in order.
    public var candidateExtensions: [String] {
        switch self {
        case .image:
            return ["heic", "png", "jpg", "jpeg"]
        case .svg:
            return ["svg"]
        case .video(let fileExtension):
            return [fileExtension]
        case .audio:
            return ["wav", "mp3"]
        }
    }
}

/// A bundled resource's name and lowercased extension.
public struct BundleResourceKey: Hashable, Sendable {
    /// The resource name without extension.
    public var name: String
    /// The lowercased extension.
    public var fileExtension: String

    /// Creates a key; the extension is lowercased.
    public init(name: String, fileExtension: String) {
        self.name = name
        self.fileExtension = fileExtension.lowercased()
    }
}

/// The bundle step of the fallback chain, behind a seam (R-CAR-2). `resources(withExtensions:)` is called inside one
/// `BlockingExecutor` unit by `AssetFallbackChain.prepare()`, never on main or the cooperative pool, so `locate` does
/// no file-system work on main (sync-2 S2-13, P-8, ADR-037, C2). Asset catalogs (`UIImage(named:)`) stay in the
/// carousel's UIKit adapter (R-CAR-9).
public protocol BundleLookup: Sendable {
    /// Every bundled resource with one of `extensions` (lowercased), by name and extension.
    func resources(withExtensions extensions: Set<String>) -> [BundleResourceKey: URL]
}

/// The live bundle step over `Bundle.main` (WP-G).
public struct MainBundleLookup: BundleLookup {
    /// Creates the live lookup (no I/O).
    public init() {}

    /// `Bundle.main.urls(forResourcesWithExtension:subdirectory:)` per extension.
    public func resources(withExtensions extensions: Set<String>) -> [BundleResourceKey: URL] {
        var result: [BundleResourceKey: URL] = [:]
        for fileExtension in extensions.sorted() {
            for url in Bundle.main.urls(forResourcesWithExtension: fileExtension, subdirectory: nil) ?? [] {
                let key = BundleResourceKey(name: url.deletingPathExtension().lastPathComponent, fileExtension: fileExtension)
                result[key] = url
            }
        }
        return result
    }
}

/// Where the chain found an asset.
public enum ChainHit: Sendable, Hashable {
    /// Step 1: shipped in the app bundle.
    case bundle(URL)
    /// Step 2: in the local store (snapshot; no I/O).
    case local(AssetLocation)
}

/// The prepared bundle index, read on the main actor.
@MainActor
final class BundleIndexHolder {
    var resources: [BundleResourceKey: URL] = [:]

    nonisolated init() {}
}

/// The three-step chain of the prior art (R-CAR-2): bundle → local, both synchronous, then network.
///
/// Deviations recorded in ADR-037 (NEEDS-HUMAN-REVIEW): the extension filter applies at the local step too, and
/// `lookup` finds local assets only after `start()` installed the first snapshot. `fetch` checks the extension after
/// the download, where the prior art checked the manifest entry first (K-11, accepted by ADR-055).
public struct AssetFallbackChain: Sendable {
    /// The client.
    public let client: AssetClient
    /// The bundle seam.
    public let bundle: any BundleLookup
    private let index: BundleIndexHolder

    /// Creates a chain (no I/O).
    public init(client: AssetClient, bundle: any BundleLookup = MainBundleLookup()) {
        self.client = client
        self.bundle = bundle
        self.index = BundleIndexHolder()
    }

    /// Builds the bundle index for `kinds` in one unit on the client's bulk `BlockingExecutor` (the enumeration
    /// took 14–18 ms in sync-2's measurement, so it may run neither on main nor on the cooperative pool, C2), then
    /// installs it on the main actor.
    public func prepare(kinds: [AssetKind]) async {
        let extensions = Set(kinds.flatMap { $0.candidateExtensions.map { $0.lowercased() } })
        let bundle = self.bundle
        let resources = await self.client.bulkExecutor.run {
            bundle.resources(withExtensions: extensions)
        }
        let index = self.index
        await MainActor.run {
            index.resources = resources
        }
    }

    /// Steps 1–2, synchronous: the bundle (each candidate in order), then the local snapshot (no I/O).
    @MainActor
    public func locate(_ id: AssetID, kind: AssetKind) -> ChainHit? {
        for candidate in kind.candidateExtensions {
            if let url = self.index.resources[BundleResourceKey(name: id.rawValue, fileExtension: candidate)] {
                return .bundle(url)
            }
        }
        if let location = self.client.lookup(id, extensions: kind.candidateExtensions) {
            return .local(location)
        }
        return nil
    }

    /// Step 3, asynchronous, user-initiated: `resolve`, then the extension check; an asset whose extension is not a
    /// candidate is `notFound`. The check runs once `resolve` has returned, so an entry of another kind is downloaded
    /// at `.userInitiated` before it is refused; the prior art (`CDNAssetResolver.swift:46`) checked before
    /// downloading (K-11, ADR-055).
    public func fetch(_ id: AssetID, kind: AssetKind) async throws(AssetError) -> URL {
        let url = try await self.client.resolve(id, priority: .userInitiated)
        let candidates = Set(kind.candidateExtensions.map { $0.lowercased() })
        guard candidates.contains(url.pathExtension.lowercased()) else {
            throw .notFound
        }
        return url
    }
}
