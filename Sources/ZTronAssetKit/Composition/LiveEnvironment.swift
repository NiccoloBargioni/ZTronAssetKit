import Foundation
import ZTronAssetAppleHosted
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTransport

extension AssetEnvironment {
    /// The real world (C4): the only place that names live conformers. Building it performs no I/O (P-12); each
    /// call builds fresh conformers, so two clients never share executors or observers. A function, not a
    /// `static var` (SPEC §4.2, ADR-038). The legacy `UserDefaults` stamp is read from `legacyDefaultsSuiteName`,
    /// `.standard` when `nil` (R-STO-11); `AssetClient(configuration:)` passes
    /// `configuration.legacy.defaultsSuiteName` (ADR-048). Lines go to the unified log (`OSLogSink`, ADR-047).
    public static func live(legacyDefaultsSuiteName: String? = nil) -> AssetEnvironment {
        let metadataExecutor = DispatchBlockingExecutor(label: "com.ztron.assetkit.metadata")
        return AssetEnvironment(
            fileSystem: LiveFileSystem(),
            metadataExecutor: metadataExecutor,
            bulkExecutor: DispatchBlockingExecutor(label: "com.ztron.assetkit.bulk"),
            time: LiveTimeSource(),
            random: SystemRandomSource(),
            conditions: LiveDeviceConditionsSource(),
            remoteSources: LiveRemoteSourceFactory(),
            appVersion: LiveAppVersionSource(executor: metadataExecutor),
            legacyDefaults: LiveLegacyDefaults(suiteName: legacyDefaultsSuiteName),
            logSink: OSLogSink()
        )
    }
}

/// The live tier selection and source construction (R-APL-5), called inside `start()` (P-12).
public struct LiveRemoteSourceFactory: RemoteSourceFactory {
    /// Creates the factory (stateless).
    public init() {}

    /// Selects the tier through the package's single `#available` and builds its source, logging through `log`.
    public func makeRemoteSource(
        configuration: RemoteConfiguration,
        staging: any StagingSink,
        log: LogRoute
    ) async throws(AssetError) -> any RemoteSource {
        let resolved = AppleHostedTier.resolve(
            configuration: configuration,
            staging: staging,
            packBackend: nil,
            log: log,
            makeAWS: { http in HTTPRemoteSource(configuration: http, staging: staging, log: log) }
        )
        switch resolved {
        case .success(let source):
            return source
        case .failure:
            // No tier is configured: a programming error the closed R-CAR-7 taxonomy can only report as an
            // unusable remote side; the composition root logs it as a fault.
            throw .serverUnavailable(retryAfter: nil)
        }
    }
}

/// The app version from `Bundle.main` in the prior art's format `"<short>+<build>"` (RECON §5), read inside
/// `start()` in one unit on a `BlockingExecutor`: the first `infoDictionary` access may read `Info.plist`, which
/// belongs neither on main nor on the cooperative pool (C2).
public struct LiveAppVersionSource: AppVersionSource {
    private let executor: any BlockingExecutor

    /// Creates the source (no I/O); `executor` runs the `Info.plist` read.
    public init(executor: any BlockingExecutor) {
        self.executor = executor
    }

    /// `"<CFBundleShortVersionString>+<CFBundleVersion>"`, with `"0"` for missing values.
    public func currentAppVersion() async -> String {
        await self.executor.run {
            let info = Bundle.main.infoDictionary
            let short = info?["CFBundleShortVersionString"] as? String ?? "0"
            let build = info?["CFBundleVersion"] as? String ?? "0"
            return "\(short)+\(build)"
        }
    }
}
