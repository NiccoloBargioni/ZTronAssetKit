import Foundation
import Testing
@testable import ZTronAssetAppleHosted
import ZTronAssetModel
import ZTronAssetTestSupport

/// R-APL-5: `AppleHostedTier.resolve` fails closed with `.noSourceConfigured` whenever the selected tier has no
/// source to build, and never builds a source the client did not configure.
@Suite("Apple tier: resolution")
struct AppleTierResolutionTests {
    private static let http = HTTPSourceConfiguration(baseURL: URL(string: "https://cdn.example.com/")!)

    @available(macOS 26.0, iOS 26.0, *)
    @Test("R-APL-5: no usable configuration resolves to noSourceConfigured without building any source")
    func noUsableConfiguration() {
        let configurations = [
            RemoteConfiguration(http: nil, appleHosted: nil, awsOnly: false),
            RemoteConfiguration(http: nil, appleHosted: nil, awsOnly: true),
            RemoteConfiguration(http: nil, appleHosted: AppleTierConfiguration(), awsOnly: true),
        ]
        for configuration in configurations {
            let backend = FakePackBackend()
            var awsBuilds = 0
            let resolved = AppleHostedTier.resolve(
                configuration: configuration,
                staging: FakeStagingSink(),
                packBackend: backend,
                log: .tapOnly(nil),
                makeAWS: { _ in
                    awsBuilds += 1
                    return FakeRemoteSource(originID: "https://cdn.example.com:443")
                }
            )
            #expect(throws: TierUnavailable.noSourceConfigured, "\(configuration)") { try resolved.get() }
            #expect(awsBuilds == 0, "\(configuration)")
            #expect(backend.calls.isEmpty, "\(configuration)")
        }
    }

    @available(macOS 26.0, iOS 26.0, *)
    @Test("R-APL-5: a decision naming a tier the configuration cannot build fails closed with noSourceConfigured")
    func decisionWithoutASourceFailsClosed() {
        let cases: [(RemoteConfiguration, AssetTier, TierInputs)] = [
            // Apple selected, but no Apple configuration exists (only AWS).
            (
                RemoteConfiguration(http: Self.http, appleHosted: nil, awsOnly: false),
                .appleHosted,
                TierInputs(osSupportsAppleTier: true, appleConfigured: false, awsConfigured: true, awsOnly: false)
            ),
            // Apple selected, but the kill switch kept the Apple source from being built.
            (
                RemoteConfiguration(http: Self.http, appleHosted: AppleTierConfiguration(), awsOnly: true),
                .appleHosted,
                TierInputs(osSupportsAppleTier: true, appleConfigured: true, awsConfigured: true, awsOnly: true)
            ),
            // AWS selected, but no HTTP configuration exists (only Apple).
            (
                RemoteConfiguration(http: nil, appleHosted: AppleTierConfiguration(), awsOnly: false),
                .aws,
                TierInputs(osSupportsAppleTier: true, appleConfigured: true, awsConfigured: false, awsOnly: false)
            ),
        ]
        for (configuration, tier, inputs) in cases {
            let backend = FakePackBackend()
            var awsBuilds = 0
            var decided: [TierInputs] = []
            let resolved = AppleHostedTier.resolve(
                configuration: configuration,
                staging: FakeStagingSink(),
                packBackend: backend,
                log: .tapOnly(nil),
                makeAWS: { _ in
                    awsBuilds += 1
                    return FakeRemoteSource(originID: "https://cdn.example.com:443")
                },
                select: { inputs in
                    decided.append(inputs)
                    return .success(tier)
                }
            )
            #expect(throws: TierUnavailable.noSourceConfigured, "\(tier), \(configuration)") { try resolved.get() }
            #expect(decided == [inputs], "the decision sees the OS fact and the configuration")
            #expect(awsBuilds == 0)
            #expect(backend.calls.isEmpty)
        }
    }

    @available(macOS 26.0, iOS 26.0, *)
    @Test("R-APL-5: the injected decision is the one resolve follows")
    func resolveFollowsTheDecision() throws {
        let configuration = RemoteConfiguration(http: Self.http, appleHosted: AppleTierConfiguration(), awsOnly: false)
        for tier in AssetTier.allCases {
            var awsBuilds = 0
            let resolved = AppleHostedTier.resolve(
                configuration: configuration,
                staging: FakeStagingSink(),
                packBackend: FakePackBackend(),
                log: .tapOnly(nil),
                makeAWS: { _ in
                    awsBuilds += 1
                    return FakeRemoteSource(originID: "https://cdn.example.com:443")
                },
                select: { _ in .success(tier) }
            )
            let source = try resolved.get()
            #expect(source.capabilities.tier == tier)
            #expect(awsBuilds == (tier == .aws ? 1 : 0))
        }
        let refused = AppleHostedTier.resolve(
            configuration: configuration,
            staging: FakeStagingSink(),
            packBackend: FakePackBackend(),
            log: .tapOnly(nil),
            makeAWS: { _ in FakeRemoteSource(originID: "https://cdn.example.com:443") },
            select: { _ in .failure(.noSourceConfigured) }
        )
        #expect(throws: TierUnavailable.noSourceConfigured) { try refused.get() }
    }
}
