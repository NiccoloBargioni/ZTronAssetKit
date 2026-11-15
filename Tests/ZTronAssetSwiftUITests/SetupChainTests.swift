import Foundation
import Testing
@testable import ZTronAssetSwiftUI
import ZTronAssetTestSupport

/// The chain is the facade's configuration surface (ADR-058): every step must reach the client's configuration, a
/// step left out must keep the package's default, and the order of the steps must not matter.
@Suite("Library setup chain")
struct SetupChainTests {
    private static let distribution = URL(fileURLWithPath: "/distribution", isDirectory: true)

    /// The package's own configuration for an origin: what a chain that only names the origin must equal.
    private static func defaults(_ baseURL: URL = SetupChainTests.distribution) -> AssetClientConfiguration {
        AssetClientConfiguration(remote: RemoteConfiguration(http: HTTPSourceConfiguration(baseURL: baseURL)))
    }

    @Test("a chain that names only the origin describes the package's default configuration")
    func originAloneKeepsEveryDefault() {
        let configuration = AssetLibrary.origin(SetupChainTests.distribution).clientConfiguration
        #expect(configuration == SetupChainTests.defaults())
    }

    @Test("each remote step reaches the HTTP tier, and a later step for the same knob wins")
    func remoteSteps() {
        let configuration = AssetLibrary
            .origin(URL(fileURLWithPath: "/replaced", isDirectory: true))
            .origin(SetupChainTests.distribution)
            .appKey("first")
            .appKey("canary-key")
            .manifest(at: "catalog/v2.json")
            .http(\.requestTimeout, 12)
            .http(\.maxConnectionsPerHost, 3)
            .http(\.additionalAllowedHosts, ["media.example.com"])
            .clientConfiguration

        var expected = HTTPSourceConfiguration(baseURL: SetupChainTests.distribution)
        expected.appKey = AppKey("canary-key")
        expected.manifestPath = "catalog/v2.json"
        expected.requestTimeout = 12
        expected.maxConnectionsPerHost = 3
        expected.additionalAllowedHosts = ["media.example.com"]
        #expect(configuration.remote.http == expected)
        #expect(configuration.remote.appleHosted == nil)
        #expect(configuration.remote.awsOnly == false)
    }

    @Test("the steps are independent of their order: a key chained before the origin is kept")
    func orderDoesNotMatter() {
        let keyFirst = AssetLibrary.appleHosted()
            .appKey("canary-key")
            .http(\.requestTimeout, 9)
            .refresh(.everyLaunch)
            .origin(SetupChainTests.distribution)
            .clientConfiguration
        let originFirst = AssetLibrary.origin(SetupChainTests.distribution)
            .refresh(.everyLaunch)
            .http(\.requestTimeout, 9)
            .appKey("canary-key")
            .appleHosted()
            .clientConfiguration
        #expect(keyFirst == originFirst)
        #expect(keyFirst.remote.http?.appKey == AppKey("canary-key"))
    }

    @Test("the base URL is the origin's, whatever a key-path step sets")
    func originOwnsTheBaseURL() {
        let configuration = AssetLibrary.origin(SetupChainTests.distribution)
            .http(\.baseURL, URL(fileURLWithPath: "/elsewhere", isDirectory: true))
            .clientConfiguration
        #expect(configuration.remote.http?.baseURL == SetupChainTests.distribution)
    }

    @Test("a chain that starts at the Apple-hosted tier has no HTTP tier, even when HTTP steps follow")
    func appleHostedAlone() {
        let configuration = AssetLibrary.appleHosted()
            .appKey("canary-key")
            .manifest(at: "ignored.json")
            .clientConfiguration
        #expect(configuration.remote.http == nil)
        #expect(configuration.remote.appleHosted == AppleTierConfiguration())
    }

    @Test("the Apple-tier steps add the tier, keep what was chained before, and awsOnly is the kill switch")
    func appleTierSteps() {
        let configuration = AssetLibrary.origin(SetupChainTests.distribution)
            .appleHosted(\.retention, .keepPacks)
            .appleHosted(\.catalogPath, "catalog-v2.json")
            .appleHosted()
            .awsOnly()
            .clientConfiguration
        var tier = AppleTierConfiguration()
        tier.retention = .keepPacks
        tier.catalogPath = "catalog-v2.json"
        #expect(configuration.remote.appleHosted == tier)
        #expect(configuration.remote.awsOnly)
        #expect(AssetLibrary.origin(SetupChainTests.distribution).awsOnly().awsOnly(false).clientConfiguration.remote.awsOnly == false)
    }

    @Test("background transfers are off until a step enables them, and option steps keep earlier options")
    func backgroundTransferSteps() {
        let plain = AssetLibrary.origin(SetupChainTests.distribution)
        #expect(plain.clientConfiguration.remote.http?.background == .disabled)
        #expect(plain.backgroundTransfers().clientConfiguration.remote.http?.background == .enabled(BackgroundTransferOptions()))

        let configured = plain
            .backgroundTransfers(\.maxTasks, 8)
            .backgroundTransfers(\.namespace, "carousel")
            .backgroundTransfers()
            .clientConfiguration
        var options = BackgroundTransferOptions()
        options.maxTasks = 8
        options.namespace = "carousel"
        #expect(configured.remote.http?.background == .enabled(options))
        #expect(options.keyRedirectExposure == .refuse, "the key never rides a background redirect unless a step says so")
    }

    @Test("each storage, sync and carousel step reaches its field and leaves every other default alone")
    func policySteps() {
        let custom = URL(fileURLWithPath: "/volumes/assets", isDirectory: true)
        let configuration = AssetLibrary.origin(SetupChainTests.distribution)
            .store(in: .custom(custom))
            .budget(.bytes(2_000_000_000))
            .storage(\.deletionGrace, 30)
            .legacy(\.enabled, false)
            .legacy(\.defaultsSuiteName, "group.example")
            .refresh(.atMostEvery(86_400))
            .retain(.tags(["free"]))
            .network(\.bulkOnExpensive, false)
            .power(\.bulkInLowPowerMode, true)
            .tuning(\.maxConcurrentTransfers, 4)
            .tuning(\.retry.maxDelay, 60)
            .limits(\.maxEntries, 20_000)
            .prefetchRadius(4)
            .clientConfiguration

        var expected = SetupChainTests.defaults()
        expected.location = .custom(custom)
        expected.storage.budget = .bytes(2_000_000_000)
        expected.storage.deletionGrace = 30
        expected.legacy.enabled = false
        expected.legacy.defaultsSuiteName = "group.example"
        expected.refresh = .atMostEvery(86_400)
        expected.retentionScope = .tags(["free"])
        expected.network.bulkOnExpensive = false
        expected.power.bulkInLowPowerMode = true
        expected.tuning.maxConcurrentTransfers = 4
        expected.tuning.retry.maxDelay = 60
        expected.limits.maxEntries = 20_000
        expected.prefetchRadius = 4
        #expect(configuration == expected)
    }

    @Test("a key-path step takes one knob's value: no policy or configuration type is a setting")
    func policiesAreNotSettings() {
        // A step such as `.storage(\.self, StoragePolicy())` or `.tuning(\.retry, …)` must not compile, which holds
        // for as long as none of these conforms.
        let policies: [Any] = [
            StoragePolicy(), LegacyMigrationPolicy(), NetworkPolicy(), PowerPolicy(), SyncTuning(), SyncTuning().retry,
            SyncTuning().breaker, ManifestLimits(), HTTPSourceConfiguration(baseURL: SetupChainTests.distribution),
            BackgroundTransferOptions(), BackgroundTransferPolicy.disabled, AppleTierConfiguration(), RemoteConfiguration(),
            SetupChainTests.defaults(), AssetLibrary.origin(SetupChainTests.distribution),
        ]
        for policy in policies {
            #expect(!(policy is any AssetLibrarySetting), "\(type(of: policy)) can be passed whole through a key-path step")
        }
        let knobs: [Any] = [
            true, 4, Int64(4), 0.5, "manifest.json", SetupChainTests.distribution, Set(["media.example.com"]),
            AppKey("canary-key"), StorageBudget.unlimited, ThermalLevel.fair, PackRetention.keepPacks, KeyRedirectExposure.refuse,
        ]
        for knob in knobs {
            #expect(knob is any AssetLibrarySetting, "\(type(of: knob)) is a knob's value")
        }
    }

    @Test("a step returns a new stage and leaves the stage it was called on unchanged")
    func stagesAreValues() {
        let base = AssetLibrary.origin(SetupChainTests.distribution)
        let free = base.retain(.tags(["free"]))
        let paid = base.retain(.tags(["paid"]))
        #expect(base.clientConfiguration.retentionScope == .all)
        #expect(free.clientConfiguration.retentionScope == .tags(["free"]))
        #expect(paid.clientConfiguration.retentionScope == .tags(["paid"]))
    }

    @Test("R-SEC-1: a stage never prints, dumps or reflects the app key")
    func stageNeverRevealsTheKey() {
        let canary = "CANARY-7f3a91-APP-KEY"
        let setup = AssetLibrary.origin(SetupChainTests.distribution).appKey(canary)
        var dumped = ""
        dump(setup, to: &dumped)
        #expect(!String(describing: setup).contains(canary))
        #expect(!String(reflecting: setup).contains(canary))
        #expect(!dumped.contains(canary))
        #expect(dumped.contains("AppKey(<redacted>)"), "the dump did reach the key's place: \(dumped)")
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("library() hands the chain's configuration to its client and performs no file-system call", .timeLimit(.minutes(1)))
    func libraryCarriesTheConfiguration() async {
        let harness = LibraryHarness.make { $0.retain(.prefix("bo7.")).prefetchRadius(3).appKey("canary-key") }
        let configuration = harness.library.client.configuration
        #expect(configuration.retentionScope == .prefix("bo7."))
        #expect(configuration.prefetchRadius == 3)
        #expect(configuration.remote.http?.baseURL == LibraryFixture.origin)
        #expect(configuration.remote.http?.appKey == AppKey("canary-key"))
        #expect(harness.library.phase == .idle)
        #expect(harness.fileSystem.operations.isEmpty, "creating a library opens nothing")
        #expect(await harness.source.manifestRequests.isEmpty, "and asks the origin nothing")
        await harness.library.shutdown()
    }
}
