import ZTronAssetModel

/// The live tier resolution (R-APL-5): the module's **only** `#available` lives in `resolve` (a source scan test
/// enforces it). The decision itself is `TierSelection.select`, pure and exhaustively tested; this function only
/// feeds it the OS fact and builds the selected source. Constructing the Apple source calls no pack API.
public enum AppleHostedTier {
    /// Selects and builds the remote source. `makeAWS` is called only when AWS is selected, so a URLSession is
    /// never created for a tier that is not used. `log` is the environment's route, handed to the Apple source
    /// (ADR-047).
    public static func resolve(
        configuration: RemoteConfiguration,
        staging: any StagingSink,
        packBackend: (any PackBackend)?,
        log: LogRoute,
        makeAWS: (HTTPSourceConfiguration) -> any RemoteSource
    ) -> Result<any RemoteSource, TierUnavailable> {
        var osSupportsAppleTier = false
        var appleSource: (any RemoteSource)? = nil
        #if canImport(BackgroundAssets)
        if #available(iOS 26.0, macOS 26.0, *) {
            osSupportsAppleTier = true
            if let apple = configuration.appleHosted, !configuration.awsOnly {
                appleSource = AppleHostedRemoteSource(
                    configuration: apple,
                    backend: packBackend ?? LiveAssetPackBackend(),
                    staging: staging,
                    log: log
                )
            }
        }
        #endif
        let inputs = TierInputs(
            osSupportsAppleTier: osSupportsAppleTier,
            appleConfigured: configuration.appleHosted != nil,
            awsConfigured: configuration.http != nil,
            awsOnly: configuration.awsOnly
        )
        switch TierSelection.select(inputs) {
        case .success(.appleHosted):
            if let appleSource {
                return .success(appleSource)
            }
            return .failure(.noSourceConfigured)
        case .success(.aws):
            if let http = configuration.http {
                return .success(makeAWS(http))
            }
            return .failure(.noSourceConfigured)
        case .failure(let error):
            return .failure(error)
        }
    }
}
