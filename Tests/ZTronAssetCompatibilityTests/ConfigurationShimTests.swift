import Foundation
import Testing
import ZTronAssetKit
import ZTronAssetTestSupport

/// R-CAR-6: `CDNConfiguration`, `CDNProviderFactory` and the install point behind the prior art's process-wide entry
/// points (WP-K).
@Suite("Compatibility shims: configuration and install point")
struct ConfigurationShimTests {
    @Test("R-CAR-6: CDNConfiguration maps the prior-art settings onto the client configuration")
    func configurationMapsOntoTheClient() throws {
        let base = try #require(URL(string: "https://d111111abcdef8.cloudfront.net/"))
        let legacyRoot = URL(fileURLWithPath: "/legacy/CDNAssets", isDirectory: true)
        let configuration = CDNConfiguration(
            baseURL: base,
            manifestPath: "catalog/manifest.json",
            appKey: AppKey("canary-key"),
            appleHosted: AppleTierConfiguration(catalogPackID: "Catalog"),
            awsOnly: true,
            refreshPolicy: .atMostEvery(600),
            location: .caches,
            legacy: LegacyMigrationPolicy(root: legacyRoot)
        )
        let client = configuration.clientConfiguration
        #expect(client.remote.http?.baseURL == base)
        #expect(client.remote.http?.manifestPath == "catalog/manifest.json")
        #expect(client.remote.http?.appKey == AppKey("canary-key"))
        #expect(client.remote.appleHosted == AppleTierConfiguration(catalogPackID: "Catalog"))
        #expect(client.remote.awsOnly)
        #expect(client.refresh == .atMostEvery(600))
        #expect(client.location == .caches)
        #expect(client.legacy == LegacyMigrationPolicy(root: legacyRoot))

        let defaults = CDNConfiguration().clientConfiguration
        #expect(defaults.remote == RemoteConfiguration())
        #expect(defaults.refresh == .oncePerAppVersion)
        #expect(defaults.location == .applicationSupport)
        #expect(defaults.legacy.enabled, "an app adopting the shims ran the prior art: its layout is migrated")
    }

    @Test("R-CAR-6: the prior-art providers name the client tier that replaces them, and a custom provider names none")
    func providersNameTheirTier() throws {
        let base = try #require(URL(string: "https://cdn.example.com/assets/"))
        let staticProvider = StaticManifestCDNProvider(baseURL: base, manifestPath: "v2/manifest.json")
        #expect(
            CDNProviderFactory.remoteConfiguration(for: staticProvider)
                == RemoteConfiguration(http: HTTPSourceConfiguration(baseURL: base, manifestPath: "v2/manifest.json"))
        )
        #expect(CDNProviderFactory.remoteConfiguration(for: ScriptedCDNProvider(manifest: .success([]))) == nil)
    }

    @available(macOS 26.0, iOS 26.0, *)
    @Test("R-CAR-6: BackgroundAssetsCDNProvider is replaced by the client's Apple-hosted tier")
    func backgroundAssetsProviderNamesTheAppleTier() {
        let provider = BackgroundAssetsCDNProvider(catalog: [])
        #expect(CDNProviderFactory.remoteConfiguration(for: provider) == RemoteConfiguration(appleHosted: AppleTierConfiguration()))
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-6: CDNProviderFactory builds the client a configuration describes, and a provider's client uses its tier")
    func factoryBuildsClients() throws {
        let harness = CompatHarness.make()
        let base = try #require(URL(string: "https://cdn.example.com/"))
        let configuration = CDNConfiguration(baseURL: base, refreshPolicy: .everyLaunch, location: .caches)
        let client = CDNProviderFactory.makeClient(configuration, environment: harness.environment)
        #expect(client.configuration == configuration.clientConfiguration)

        let template = CDNConfiguration(refreshPolicy: .atMostEvery(60), location: .caches)
        let provided = CDNProviderFactory.makeClient(
            for: StaticManifestCDNProvider(baseURL: base),
            base: template,
            environment: harness.environment
        )
        #expect(provided.configuration.remote == RemoteConfiguration(http: HTTPSourceConfiguration(baseURL: base)))
        #expect(provided.configuration.refresh == .atMostEvery(60))
        #expect(provided.configuration.location == .caches)

        var custom = template
        custom.remote = RemoteConfiguration(http: HTTPSourceConfiguration(baseURL: base, manifestPath: "custom.json"))
        let customClient = CDNProviderFactory.makeClient(
            for: ScriptedCDNProvider(manifest: .success([])),
            base: custom,
            environment: harness.environment
        )
        #expect(customClient.configuration.remote == custom.remote, "a custom provider keeps the template's tiers")
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-6: an install point keeps the first client installed and answers every later installation with it")
    func installPointKeepsTheFirstClient() {
        let harness = CompatHarness.make()
        let point = CDNInstallPoint()
        #expect(point.client == nil)
        let first = AssetClient(configuration: harness.configuration, environment: harness.environment)
        let second = AssetClient(configuration: harness.configuration, environment: harness.environment)
        let firstAnswer = point.install(first).identity
        let secondAnswer = point.install(second).identity
        let kept = point.client?.identity
        #expect(firstAnswer == first.identity)
        #expect(secondAnswer == first.identity)
        #expect(kept == first.identity)

        let preinstalled = CDNInstallPoint(client: second)
        let preinstalledClient = preinstalled.client?.identity
        #expect(preinstalledClient == second.identity)
        #expect(preinstalled.configuration.clientConfiguration == second.configuration)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-6: CDNProviderFactory installs a client only into an empty install point")
    func factoryInstallsIntoAnEmptyPointOnly() throws {
        let harness = CompatHarness.make()
        let point = CDNInstallPoint()
        let base = try #require(URL(string: "https://cdn.example.com/"))
        let installed = CDNProviderFactory.install(CDNConfiguration(baseURL: base), into: point, environment: harness.environment)
        let kept = point.client?.identity
        #expect(kept == installed.identity)
        #expect(installed.configuration.remote.http?.baseURL == base)
        let again = CDNProviderFactory.install(CDNConfiguration(), into: point, environment: harness.environment).identity
        #expect(again == installed.identity)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-6: an install point builds one client, from the first provider that needs one")
    func installPointBuildsFromTheFirstProvider() throws {
        let harness = CompatHarness.make()
        let first = try #require(URL(string: "https://first.example.com/"))
        let second = try #require(URL(string: "https://second.example.com/"))
        let point = CDNInstallPoint(configuration: CDNConfiguration(refreshPolicy: .everyLaunch), environment: harness.environment)
        let client = point.installClient(for: StaticManifestCDNProvider(baseURL: first))
        let kept = point.client?.identity
        #expect(kept == client.identity)
        #expect(client.configuration.remote.http?.baseURL == first)
        #expect(client.configuration.refresh == .everyLaunch)
        let later = point.installClient(for: StaticManifestCDNProvider(baseURL: second)).identity
        #expect(later == client.identity)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-6: a task waiting on an install point resumes with the client installed later", .timeLimit(.minutes(1)))
    func waiterResumesWithTheInstalledClient() async throws {
        let harness = CompatHarness.make()
        let point = CDNInstallPoint()
        let (waiting, signal) = AsyncStream<Void>.makeStream()
        let waiter = Task { @MainActor in
            signal.yield()
            return await point.waitForClient()
        }
        for await _ in waiting {
            break
        }
        let client = AssetClient(configuration: harness.configuration, environment: harness.environment)
        point.install(client)
        let resumed = await waiter.value?.identity
        #expect(resumed == client.identity)
        let atOnce = await point.waitForClient()?.identity
        #expect(atOnce == client.identity, "an installed point answers at once")
    }

    @MainActor
    @Test("R-CAR-6: a cancelled wait on an install point resumes with nil", .timeLimit(.minutes(1)))
    func cancelledWaiterResumesWithNil() async {
        let point = CDNInstallPoint()
        let waiter = Task { @MainActor in
            await point.waitForClient()
        }
        waiter.cancel()
        let resumed = await waiter.value
        #expect(resumed == nil)
        #expect(point.client == nil)
    }
}
