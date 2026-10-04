/// Everything the module needs from the real world, in one value (SPEC §4.2, C4, R-ENV-1).
///
/// The protocols live in the Model so this value can be declared below every target (ADR-038). `.live()` is
/// assembled by the composition root (`ZTronAssetKit`), which is the only place that names live conformers;
/// tests build an environment from `ZTronAssetTestSupport` fakes. Constructing an environment performs no I/O
/// (P-12): every conformer defers its work to the first call.
public struct AssetEnvironment: Sendable {
    /// Every file-system effect (R-STO-6).
    public var fileSystem: any FileSystem
    /// Commits, renames, unlinks, listings (ADR-003).
    public var metadataExecutor: any BlockingExecutor
    /// Hash and copy reads, manifest decoding: a long hash never delays a commit.
    public var bulkExecutor: any BlockingExecutor
    /// Wall, monotonic and awake clocks; sleeping (H-8).
    public var time: any TimeSource
    /// The single seed every random draw derives from (ADR-024).
    public var random: any RandomSource
    /// Reachability and power, event-driven (R-NET-9, R-SYN-7).
    public var conditions: any DeviceConditionsSource
    /// Builds the remote source lazily in `start()` (R-APL-5, P-12).
    public var remoteSources: any RemoteSourceFactory
    /// The app version for refresh decisions (R-SYN-9).
    public var appVersion: any AppVersionSource
    /// The legacy `UserDefaults` stamp (R-STO-11).
    public var legacyDefaults: any LegacyDefaults
    /// Optional memory-pressure events (R-CLN-11, MAY).
    public var memoryPressure: (any MemoryPressureSource)?
    /// Optional log sink for tests (R-OBS-1); `nil` in `.live()`.
    public var logTap: (any LogTap)?

    /// Creates an environment from explicit conformers.
    public init(
        fileSystem: any FileSystem,
        metadataExecutor: any BlockingExecutor,
        bulkExecutor: any BlockingExecutor,
        time: any TimeSource,
        random: any RandomSource,
        conditions: any DeviceConditionsSource,
        remoteSources: any RemoteSourceFactory,
        appVersion: any AppVersionSource,
        legacyDefaults: any LegacyDefaults,
        memoryPressure: (any MemoryPressureSource)? = nil,
        logTap: (any LogTap)? = nil
    ) {
        self.fileSystem = fileSystem
        self.metadataExecutor = metadataExecutor
        self.bulkExecutor = bulkExecutor
        self.time = time
        self.random = random
        self.conditions = conditions
        self.remoteSources = remoteSources
        self.appVersion = appVersion
        self.legacyDefaults = legacyDefaults
        self.memoryPressure = memoryPressure
        self.logTap = logTap
    }
}
