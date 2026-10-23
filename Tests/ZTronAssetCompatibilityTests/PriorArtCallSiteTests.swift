import Foundation
import Testing
import ZTronAssetKit

/// `BasicVideoPage.init?`'s fallback (ZTronCarouselCore `VideoPage/BasicVideoPage.swift:55-57`, read-only), copied
/// with its isolation (a `UIViewController` initialiser is main-actor isolated): the bundle, then the local store.
@MainActor
enum BasicVideoPageCallSite {
    static func localURL(assetName: String, fileExtension: String) -> URL? {
        Bundle.main.url(forResource: assetName, withExtension: fileExtension)
            ?? CDNLocalStore.shared.existingLocalURL(identifier: assetName, candidateExtensions: [fileExtension])
    }
}

/// `ZTronSVGView`'s use of the CDN (ZTronCarousel `Components/Internals/ZTronSVGView.swift:117-183` and its `deinit`,
/// `:357-362`, read-only), copied with its isolation (a `UIView` is main-actor isolated, its `deinit` is not); the layer
/// parsing is replaced by keeping the URL.
@MainActor
final class SVGViewCallSite {
    private let outlineAssetName: String
    private var pendingConnectivityRetryToken: UUID?
    private(set) var resolvedURL: URL?

    init(outlineAssetName: String) {
        self.outlineAssetName = outlineAssetName
    }

    /// The first two steps of the chain: the bundle, then the local store.
    static func resolveSVGURL(assetName: String) -> URL? {
        if let bundleURL = Bundle.main.url(forResource: assetName, withExtension: "svg") {
            return bundleURL
        }
        return CDNLocalStore.shared.existingLocalURL(identifier: assetName, candidateExtensions: ["svg"])
    }

    /// The third step: a no-op unless a resolver is installed.
    func resolveSVGViaCDN() {
        guard let resolver = CDNAssetResolver.installed else {
            return
        }
        self.attemptNetworkResolve(resolver: resolver)
    }

    /// Whether a connectivity retry is pending.
    var hasPendingRetry: Bool {
        self.pendingConnectivityRetryToken != nil
    }

    private func attemptNetworkResolve(resolver: CDNAssetResolver) {
        let assetName = self.outlineAssetName
        Task { [weak self] in
            guard let url = await resolver.resolveViaNetwork(identifier: assetName, candidateExtensions: ["svg"]) else {
                guard let self else {
                    return
                }
                await MainActor.run {
                    self.registerConnectivityRetry(resolver: resolver)
                }
                return
            }
            guard let self else {
                return
            }
            await MainActor.run {
                self.resolvedURL = url
            }
        }
    }

    private func registerConnectivityRetry(resolver: CDNAssetResolver) {
        guard self.pendingConnectivityRetryToken == nil else {
            return
        }
        self.pendingConnectivityRetryToken = NetworkAvailabilityMonitor.shared.retryWhenAvailable { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                self.pendingConnectivityRetryToken = nil
                guard self.resolvedURL == nil else {
                    return
                }
                self.attemptNetworkResolve(resolver: resolver)
            }
        }
    }

    deinit {
        if let token = self.pendingConnectivityRetryToken {
            NetworkAvailabilityMonitor.shared.cancelRetry(token)
        }
    }
}

/// R-CAR-6: the carousel's call sites, copied with their isolation, compile against the shims unchanged (a shim change
/// that breaks one fails this target's build) and, like the prior art before a resolver was installed, cost nothing.
/// They read the process-wide install point, which no test fills (K-2), so they never reach the live monitor.
@Suite("Compatibility shims: the carousel's call sites")
struct PriorArtCallSiteTests {
    @MainActor
    @Test("R-CAR-6: the carousel's call sites compile unchanged and find nothing and start nothing while no client is installed")
    func callSitesBeforeInstallation() {
        #expect(BasicVideoPageCallSite.localURL(assetName: "bo7.ri.easter.egg.intro", fileExtension: "mp4") == nil)
        #expect(SVGViewCallSite.resolveSVGURL(assetName: "bo7.ri.easter.egg.temple.outline") == nil)

        let view = SVGViewCallSite(outlineAssetName: "bo7.ri.easter.egg.temple.outline")
        view.resolveSVGViaCDN()

        #expect(!view.hasPendingRetry, "no resolver installed: the network step is a no-op")
        #expect(view.resolvedURL == nil)
    }
}
