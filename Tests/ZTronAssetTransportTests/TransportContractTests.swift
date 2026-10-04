import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport
import ZTronAssetTransport

@Suite("Transport contracts")
struct TransportContractTests {
    @Test("R-NET-10: AssetPriority maps to URLSessionTask priorities 0.75, 0.5 and 0.25")
    func priorityTable() {
        #expect(AssetPriority.userInitiated.urlSessionTaskPriority == 0.75)
        #expect(AssetPriority.prefetch.urlSessionTaskPriority == 0.5)
        #expect(AssetPriority.bulk.urlSessionTaskPriority == 0.25)
        let ordered = AssetPriority.allCases.sorted().map(\.urlSessionTaskPriority)
        #expect(ordered == ordered.sorted())
    }

    @Test("R-NET-7: the size guard aborts when the written or announced size exceeds the cap or byteSize is exceeded")
    func sizeGuard() {
        let limit: Int64 = 1_048_576
        #expect(SizeGuard.verdict(written: limit, announced: limit, expected: nil, limit: limit) == .proceed)
        #expect(SizeGuard.verdict(written: limit + 1, announced: nil, expected: nil, limit: limit) == .abortOversize)
        #expect(SizeGuard.verdict(written: 10, announced: 10_485_760, expected: nil, limit: limit) == .abortOversize)
        // The announced size gets a small slack for an encoded length; −1 means unknown (any Content-Encoding).
        #expect(SizeGuard.verdict(written: 10, announced: limit + limit / 1024 + 64, expected: nil, limit: limit) == .proceed)
        #expect(SizeGuard.verdict(written: 10, announced: -1, expected: nil, limit: limit) == .proceed)
        // byteSize aborts early even when the length is unknown (transport-1 TR1-8).
        #expect(SizeGuard.verdict(written: 315_001, announced: nil, expected: 315_000, limit: limit) == .abortExceedsExpected)
        #expect(SizeGuard.verdict(written: 315_000, announced: nil, expected: 315_000, limit: limit) == .proceed)
    }

    @Test("R-NET-9: path mapping exposes satisfied, expensive and constrained exactly, and thermal maps to four levels")
    func conditionsMapping() {
        for satisfied in [false, true] {
            for expensive in [false, true] {
                for constrained in [false, true] {
                    let network = ConditionsMapping.network(satisfied: satisfied, expensive: expensive, constrained: constrained)
                    #expect(network == NetworkConditions(satisfied: satisfied, expensive: expensive, constrained: constrained))
                }
            }
        }
        #expect(ConditionsMapping.thermal(.nominal) == .nominal)
        #expect(ConditionsMapping.thermal(.fair) == .fair)
        #expect(ConditionsMapping.thermal(.serious) == .serious)
        #expect(ConditionsMapping.thermal(.critical) == .critical)
    }

    @Test("R-NET-3: the background identifier is stable, namespaced and recognised by the hook")
    func backgroundIdentifier() {
        #expect(BackgroundSessionIdentifier(namespace: "default")?.rawValue == "com.ztron.assetkit.bg.default.v1")
        #expect(BackgroundSessionIdentifier(namespace: "Default") == nil)
        #expect(BackgroundSessionIdentifier(namespace: "") == nil)
        #expect(BackgroundSessionIdentifier(namespace: String(repeating: "a", count: 33)) == nil)
        #expect(BackgroundSessionIdentifier.isOurs("com.ztron.assetkit.bg.media-2.v1"))
        #expect(!BackgroundSessionIdentifier.isOurs("com.ztron.assetkit.bg..v1"))
        #expect(!BackgroundSessionIdentifier.isOurs("com.other.app.bg.default.v1"))
    }

    @available(macOS 15.0, *)
    @Test("R-NET-3: the production source builds a background coordinator only when background transfers are enabled with a valid namespace")
    func productionBackgroundBackend() throws {
        let staging = FakeStagingSink()
        let policy = TransportSecurityPolicy.production(allowedHosts: ["cdn.example.com"])
        #expect(HTTPRemoteSource.makeBackgroundBackend(.disabled, staging: staging, policy: policy) == nil)
        let invalid = BackgroundTransferPolicy.enabled(BackgroundTransferOptions(namespace: "Not Valid"))
        #expect(HTTPRemoteSource.makeBackgroundBackend(invalid, staging: staging, policy: policy) == nil)

        let options = BackgroundTransferOptions(namespace: "media", discretionary: false, maxTasks: 8)
        let backend = try #require(HTTPRemoteSource.makeBackgroundBackend(.enabled(options), staging: staging, policy: policy))
        #expect(backend.kind == .background)
        let coordinator = try #require(backend as? BackgroundTransferCoordinator)
        #expect(coordinator.options == options)
        let driver = try #require(coordinator.driver as? LiveBackgroundSessionDriver)
        #expect(driver.identifier.rawValue == "com.ztron.assetkit.bg.media.v1")
        #expect(!driver.discretionary)
        #expect(driver.delegate.mode == .background)
        #expect(driver.delegate.policy == policy)
        #expect((driver.delegate.staging as? FakeStagingSink) === staging)
    }

    @Test("R-NET-4: plain HTTP is refused by the production policy even for loopback hosts")
    func productionPolicyIsHTTPSOnly() throws {
        let policy = TransportSecurityPolicy.production(allowedHosts: ["cdn.example.com.", "127.0.0.1"])
        let https = try #require(URL(string: "https://CDN.example.com./media/a.png"))
        let loopback = try #require(URL(string: "http://127.0.0.1:8080/manifest.json"))
        let foreign = try #require(URL(string: "https://evil.example.net/a"))
        #expect(policy.check(Origin(url: https)) == nil)
        #expect(policy.check(Origin(url: loopback)) == .insecureScheme)
        #expect(policy.check(Origin(url: foreign)) == .hostNotAllowed)
        let testing = TransportSecurityPolicy.loopbackTesting(allowedHosts: ["127.0.0.1"])
        #expect(testing.check(Origin(url: loopback)) == nil)
        #expect(Origin(url: https)?.description == "https://cdn.example.com:443")
    }

    @Test("R-NET-4: the foreground session configuration has no httpAdditionalHeaders and no URLCache")
    func foregroundConfiguration() {
        let configuration = ForegroundTransferBackend.makeConfiguration(maxConnectionsPerHost: 40, requestTimeout: 12)
        #expect(configuration.httpAdditionalHeaders?.isEmpty ?? true)
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.httpMaximumConnectionsPerHost == 8)
        #expect(configuration.timeoutIntervalForRequest == 12)
        #expect(configuration.waitsForConnectivity == false)
        #expect(configuration.httpCookieStorage == nil)
    }
}
