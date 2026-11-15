import Foundation

extension AssetLibrary {
    /// One stage of the chain that describes a library before it exists (ADR-058).
    ///
    /// The chain is the facade's whole configuration surface: every knob of the package is one call, and no options
    /// value is ever built or passed. A stage has no public initialiser and no public property. It comes from
    /// `AssetLibrary.origin(_:)` or `AssetLibrary.appleHosted()`, each step returns a new stage, and `library()` ends
    /// the chain:
    ///
    /// ```swift
    /// AssetLibrary
    ///     .origin(distribution)
    ///     .appKey(key)
    ///     .retain(.tags(["free"]))
    ///     .storage(\.deletionGrace, 30)
    ///     .library()
    /// ```
    ///
    /// The steps are independent of their order, and a later step for the same knob wins. The frequent knobs have a
    /// step of their own; every other one is reached through the step of its group and a key path, the way
    /// `environment(_:_:)` sets one environment value of a view. Such a step takes one knob's value
    /// (`AssetLibrarySetting`), never a policy as a whole. A step left out keeps the package's default.
    ///
    /// The steps of the HTTP tier (`appKey(_:)`, `manifest(at:)`, `http(_:_:)`, `backgroundTransfers()`) describe
    /// the origin's tier: on a chain that names no origin there is no such tier, and they have no effect.
    public struct Setup: Sendable {
        /// Everything but the HTTP tier, which is built from `origin` and `http` when the chain ends.
        var configuration: AssetClientConfiguration
        /// The HTTP tier's base URL; `nil` for a chain that names no origin, which then has no HTTP tier.
        var origin: URL?
        /// The HTTP tier's knobs, kept apart from `origin` so `appKey(_:)` before `origin(_:)` is not lost. Its base
        /// URL is a stand-in that never leaves the stage: `clientConfiguration` replaces it with `origin`.
        var http: HTTPSourceConfiguration
        /// The bundle step of the fallback chain.
        var bundle: any BundleLookup
        /// The kinds indexed from the bundle by `start()`.
        var bundledKinds: [AssetKind]
        /// The app's memory-pressure events, set on the environment the client runs in.
        var memoryPressure: (any MemoryPressureSource)?
        /// The environment of fakes a test runs the library in; `nil` means the live one.
        var environment: AssetEnvironment?

        /// An empty stage: no tier, every default. Passing `isDirectory` keeps `URL` from asking the file system.
        init() {
            self.configuration = AssetClientConfiguration(remote: RemoteConfiguration())
            self.origin = nil
            self.http = HTTPSourceConfiguration(baseURL: URL(fileURLWithPath: "/", isDirectory: true))
            self.bundle = MainBundleLookup()
            self.bundledKinds = []
            self.memoryPressure = nil
            self.environment = nil
        }

        /// A copy with one change: the chain never mutates a stage a caller still holds.
        private func with(_ change: (inout Setup) -> Void) -> Setup {
            var copy = self
            change(&copy)
            return copy
        }
    }

    /// Starts a chain at the AWS (CloudFront) tier: `baseURL` is the distribution, `https://<distribution>/`. Its
    /// host is the one the app key may be sent to.
    nonisolated public static func origin(_ baseURL: URL) -> Setup {
        Setup().origin(baseURL)
    }

    /// Starts a chain at the Apple-hosted tier alone, for an app whose every supported system has it (iOS 26 or
    /// macOS 26 and later). An app that also runs on older systems starts at `origin(_:)` and adds `appleHosted()`.
    nonisolated public static func appleHosted() -> Setup {
        Setup().appleHosted()
    }
}

// MARK: - The remote tiers

extension AssetLibrary.Setup {
    /// Names the AWS (CloudFront) tier's base URL, `https://<distribution>/`.
    public func origin(_ baseURL: URL) -> AssetLibrary.Setup {
        self.with { $0.origin = baseURL }
    }

    /// The app key the origin requires (SPEC §2.3). It is wrapped at once in `AppKey`, which prints as
    /// `AppKey(<redacted>)` and cannot be read back, and it is sent only to allow-listed HTTPS origins (R-NET-4,
    /// R-SEC-1). Default: no key. Without an origin in the chain it has no effect.
    public func appKey(_ secret: String) -> AssetLibrary.Setup {
        self.with { $0.http.appKey = AppKey(secret) }
    }

    /// The manifest's path relative to the origin. Default: `manifest.json`. Without an origin in the chain it has
    /// no effect.
    public func manifest(at path: String) -> AssetLibrary.Setup {
        self.with { $0.http.manifestPath = path }
    }

    /// Sets one knob of the HTTP tier, for example `.http(\.requestTimeout, 20)`. The base URL is `origin(_:)`'s,
    /// whatever this sets, and without an origin in the chain the step has no effect.
    public func http<Value: AssetLibrarySetting>(_ keyPath: WritableKeyPath<HTTPSourceConfiguration, Value>, _ value: Value) -> AssetLibrary.Setup {
        self.with { $0.http[keyPath: keyPath] = value }
    }

    /// Lets bulk transfers use a background `URLSession` (R-NET-3, ADR-026). Calling it is the app's attestation
    /// that its app delegate forwards `application(_:handleEventsForBackgroundURLSession:completionHandler:)` to
    /// `AssetLibrary.handleBackgroundEvents(identifier:completionHandler:)`; nothing detects at run time an app that
    /// attests the hook without wiring it. Default: every transfer runs in the foreground session. Without an origin
    /// in the chain it has no effect.
    public func backgroundTransfers() -> AssetLibrary.Setup {
        self.with { $0.http.background = .enabled($0.backgroundOptions) }
    }

    /// Enables background transfers, as `backgroundTransfers()` does, and sets one of their options, for example
    /// `.backgroundTransfers(\.maxTasks, 16)`.
    public func backgroundTransfers<Value: AssetLibrarySetting>(
        _ keyPath: WritableKeyPath<BackgroundTransferOptions, Value>,
        _ value: Value
    ) -> AssetLibrary.Setup {
        self.with {
            var options = $0.backgroundOptions
            options[keyPath: keyPath] = value
            $0.http.background = .enabled(options)
        }
    }

    /// The background options chained so far, or the defaults.
    private var backgroundOptions: BackgroundTransferOptions {
        if case .enabled(let options) = self.http.background {
            return options
        }
        return BackgroundTransferOptions()
    }

    /// Adds the Apple-hosted tier (R-APL-5): iOS 26 or macOS 26 and later then use BackgroundAssets packs instead of
    /// the origin. It has no fallback, so call it only in a build that ships the downloader extension and the packs
    /// (SPEC §1.3). Default: the origin serves every system.
    public func appleHosted() -> AssetLibrary.Setup {
        self.with { $0.configuration.remote.appleHosted = $0.appleTier }
    }

    /// Adds the Apple-hosted tier, as `appleHosted()` does, and sets one of its knobs, for example
    /// `.appleHosted(\.retention, .keepPacks)`.
    public func appleHosted<Value: AssetLibrarySetting>(
        _ keyPath: WritableKeyPath<AppleTierConfiguration, Value>,
        _ value: Value
    ) -> AssetLibrary.Setup {
        self.with {
            var tier = $0.appleTier
            tier[keyPath: keyPath] = value
            $0.configuration.remote.appleHosted = tier
        }
    }

    /// The Apple tier chained so far, or the defaults.
    private var appleTier: AppleTierConfiguration {
        self.configuration.remote.appleHosted ?? AppleTierConfiguration()
    }

    /// The kill switch (R-APL-5): never select the Apple-hosted tier, whatever the chain added. Default: off.
    public func awsOnly(_ enabled: Bool = true) -> AssetLibrary.Setup {
        self.with { $0.configuration.remote.awsOnly = enabled }
    }
}

// MARK: - Storage

extension AssetLibrary.Setup {
    /// Where the store root lives (ADR-001). Default: `Application Support`, excluded from backup, which the system
    /// never purges; `.caches` suits a catalog that is fully regenerable.
    public func store(in location: StorageLocation) -> AssetLibrary.Setup {
        self.with { $0.configuration.location = location }
    }

    /// The store's byte budget (R-CLN-4). Default: half of the store's usage plus the free space.
    public func budget(_ budget: StorageBudget) -> AssetLibrary.Setup {
        self.with { $0.configuration.storage.budget = budget }
    }

    /// Sets one knob of the storage lifecycle (ADR-035), for example `.storage(\.deletionGrace, 30)`.
    public func storage<Value: AssetLibrarySetting>(_ keyPath: WritableKeyPath<StoragePolicy, Value>, _ value: Value) -> AssetLibrary.Setup {
        self.with { $0.configuration.storage[keyPath: keyPath] = value }
    }

    /// Sets one knob of the migration from the prior art's cache (R-STO-11), for example `.legacy(\.enabled, false)`.
    public func legacy<Value: AssetLibrarySetting>(_ keyPath: WritableKeyPath<LegacyMigrationPolicy, Value>, _ value: Value) -> AssetLibrary.Setup {
        self.with { $0.configuration.legacy[keyPath: keyPath] = value }
    }
}

// MARK: - Sync

extension AssetLibrary.Setup {
    /// When a launch sync is due (R-SYN-9). Default: once per app version.
    public func refresh(_ policy: RefreshPolicy) -> AssetLibrary.Setup {
        self.with { $0.configuration.refresh = policy }
    }

    /// What the app wants kept at launch (R-CAR-5): the scope of every bulk sync, and what eviction spares.
    /// `AssetLibrary.setRetentionScope(_:)` replaces it while the app runs. Default: everything.
    public func retain(_ scope: AssetScope) -> AssetLibrary.Setup {
        self.with { $0.configuration.retentionScope = scope }
    }

    /// Sets one knob of which lanes may use which networks (ADR-036), for example `.network(\.bulkOnExpensive, false)`.
    public func network<Value: AssetLibrarySetting>(_ keyPath: WritableKeyPath<NetworkPolicy, Value>, _ value: Value) -> AssetLibrary.Setup {
        self.with { $0.configuration.network[keyPath: keyPath] = value }
    }

    /// Sets one knob of the Low Power Mode and thermal behaviour (ADR-036), for example
    /// `.power(\.bulkInLowPowerMode, true)`.
    public func power<Value: AssetLibrarySetting>(_ keyPath: WritableKeyPath<PowerPolicy, Value>, _ value: Value) -> AssetLibrary.Setup {
        self.with { $0.configuration.power[keyPath: keyPath] = value }
    }

    /// Sets one knob of concurrency, retries, the circuit breaker and rate limits, for example
    /// `.tuning(\.maxConcurrentTransfers, 4)` or `.tuning(\.retry.maxDelay, 60)`. Out-of-range values are clamped by
    /// the client, and `diagnosticReport()` shows the clamped ones.
    public func tuning<Value: AssetLibrarySetting>(_ keyPath: WritableKeyPath<SyncTuning, Value>, _ value: Value) -> AssetLibrary.Setup {
        self.with { $0.configuration.tuning[keyPath: keyPath] = value }
    }

    /// Sets one of the limits a manifest is held to (R-MAN-2), for example `.limits(\.maxEntries, 20_000)`.
    public func limits<Value: AssetLibrarySetting>(_ keyPath: WritableKeyPath<ManifestLimits, Value>, _ value: Value) -> AssetLibrary.Setup {
        self.with { $0.configuration.limits[keyPath: keyPath] = value }
    }
}

// MARK: - The carousel

extension AssetLibrary.Setup {
    /// How many neighbours on each side `AssetLibrary.updatePrefetchWindow(ids:current:)` keeps warm (R-CAR-3).
    /// Default: 2.
    public func prefetchRadius(_ radius: Int) -> AssetLibrary.Setup {
        self.with { $0.configuration.prefetchRadius = radius }
    }

    /// The kinds of media the app ships in its bundle. `start()` indexes them off the main thread, so
    /// `AssetLibrary.locate(_:kind:)` finds a bundled asset from the first frame after it. Default: none; a kind is
    /// then indexed the first time `AssetLibrary.url(for:kind:)` is asked for it.
    public func bundled(_ kinds: AssetKind...) -> AssetLibrary.Setup {
        self.with { $0.bundledKinds = kinds }
    }

    /// The bundle step of the fallback chain (R-CAR-2). Default: `MainBundleLookup`, over `Bundle.main`.
    public func bundle(_ lookup: any BundleLookup) -> AssetLibrary.Setup {
        self.with { $0.bundle = lookup }
    }

    /// The app's memory-pressure events (R-CLN-11), for example a source built on UIKit's memory warning, which
    /// stays outside this package (R-CAR-9). Default: none, so a cache registered with
    /// `AssetLibrary.register(_:)` is never purged.
    public func memoryPressure(from source: any MemoryPressureSource) -> AssetLibrary.Setup {
        self.with { $0.memoryPressure = source }
    }
}

// MARK: - The end of the chain

extension AssetLibrary.Setup {
    /// Ends the chain: creates the client and the library around it. No I/O and nothing started (P-12); the library
    /// starts with `AssetLibrary.start()` or with its first asynchronous call.
    @MainActor
    public func library() -> AssetLibrary {
        let configuration = self.clientConfiguration
        var environment = AssetClient.resolvedEnvironment(self.environment, for: configuration)
        if let memoryPressure = self.memoryPressure {
            environment.memoryPressure = memoryPressure
        }
        return AssetLibrary(
            client: AssetClient(configuration: configuration, environment: environment),
            bundle: self.bundle,
            bundledKinds: self.bundledKinds
        )
    }

    /// The client configuration the chain describes: the HTTP tier exists only when an origin was named. Pure.
    var clientConfiguration: AssetClientConfiguration {
        var configuration = self.configuration
        if let origin = self.origin {
            var http = self.http
            http.baseURL = origin
            configuration.remote.http = http
        }
        return configuration
    }

    /// Runs the library in `environment` instead of the live one: the seam of this package's tests, which run a
    /// real client over fakes (C4). Not public: an app that needs its own environment builds the client and wraps
    /// it with `AssetLibrary.init(client:)`.
    package func environment(_ environment: AssetEnvironment) -> AssetLibrary.Setup {
        self.with { $0.environment = environment }
    }
}
