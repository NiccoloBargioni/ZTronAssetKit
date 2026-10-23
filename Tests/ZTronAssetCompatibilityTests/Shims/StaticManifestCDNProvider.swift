import Foundation
import ZTronAssetKit

/// R-CAR-6 shim of the prior art's HTTP provider (`StaticManifestCDNProvider.swift`, read-only): the same initialiser,
/// now a description of the client's HTTP tier (`remoteConfiguration`) and a manifest source.
///
/// The client fetches and downloads through its own transport (one cache-less session, size caps, resume, the app
/// key, redirect rules; R-NET-*), so the prior art's per-download `URLSession` (D-1, D-3, D-7) is gone and
/// `downloadAsset` is deprecated. `fetchManifest()` still answers, because `CDNSyncCoordinator.verifyFullyAvailable()`
/// compares a fresh manifest with the store: one GET that bypasses the URL cache, then the module's validating decoder
/// (D-9) on a blocking executor, never on the main thread or the cooperative pool (C2).
public struct StaticManifestCDNProvider: CDNProviding {
    private let baseURL: URL
    private let manifestPath: String
    private let urlSession: URLSession
    private let executor: any BlockingExecutor

    /// The prior art's initialiser. `urlSession` is used for `fetchManifest()` only.
    public init(baseURL: URL, manifestPath: String = "manifest.json", urlSession: URLSession = .shared) {
        self.init(
            baseURL: baseURL,
            manifestPath: manifestPath,
            urlSession: urlSession,
            executor: DispatchBlockingExecutor(label: "com.ztron.assetkit.compat.manifest")
        )
    }

    /// The initialiser with the decoding executor injected (tests pass `InlineBlockingExecutor`).
    init(baseURL: URL, manifestPath: String, urlSession: URLSession, executor: any BlockingExecutor) {
        self.baseURL = baseURL
        self.manifestPath = manifestPath
        self.urlSession = urlSession
        self.executor = executor
    }

    /// Everything the origin advertises, validated (unknown fields ignored, invalid entries quarantined, structural
    /// violations rejected with a `ManifestError`); a non-2xx answer throws `StaticManifestCDNProviderError.badResponse`.
    public func fetchManifest() async throws -> [CDNAsset] {
        // WP-K skeleton: nothing is fetched yet.
        []
    }

    /// Gone: the client downloads, verifies and stores (`AssetClient.resolve`). Throws `CDNShimError.downloadsGoThroughTheClient`.
    @available(*, deprecated, message: "The AssetClient downloads, verifies and stores assets; use AssetClient.resolve(_:priority:) or CDNAssetResolver.resolveViaNetwork")
    public func downloadAsset(_ asset: CDNAsset, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        // WP-K skeleton: the refusal is not written yet.
        self.baseURL
    }
}

extension StaticManifestCDNProvider: CDNRemoteConfigurable {
    /// The HTTP tier at this provider's base URL and manifest path (no app key: the prior art sent none).
    var remoteConfiguration: RemoteConfiguration {
        RemoteConfiguration(http: HTTPSourceConfiguration(baseURL: self.baseURL, manifestPath: self.manifestPath))
    }
}

/// The prior art's provider error (now also `Equatable`, by the response's identity).
public enum StaticManifestCDNProviderError: Error, Equatable {
    /// A non-2xx answer (or a response that is not HTTP).
    case badResponse(URLResponse)
}
