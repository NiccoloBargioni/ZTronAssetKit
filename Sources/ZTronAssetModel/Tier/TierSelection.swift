/// The two remote tiers (SPEC §2.2): AWS on iOS 15–25, Apple-hosted on iOS 26+.
public enum AssetTier: String, Sendable, Hashable, CaseIterable, Codable {
    /// CloudFront in front of S3 (`HTTPRemoteSource`).
    case aws
    /// BackgroundAssets packs (`AppleHostedRemoteSource`).
    case appleHosted
}

/// Every input of the tier decision (R-APL-5). `osSupportsAppleTier` is the result of the package's single
/// `#available(iOS 26.0, macOS 26.0, *)` check, evaluated by `ZTronAssetAppleHosted` and passed in as data, so the
/// decision itself is pure and exhaustively testable on a macOS 27 host where the check is always true
/// (APPLE-API-VERIFICATION §2).
public struct TierInputs: Sendable, Hashable, CaseIterable {
    /// The OS can run the Apple tier (iOS ≥ 26 / macOS ≥ 26, and BackgroundAssets is importable).
    public var osSupportsAppleTier: Bool
    /// An `AppleTierConfiguration` is present.
    public var appleConfigured: Bool
    /// An `HTTPSourceConfiguration` is present.
    public var awsConfigured: Bool
    /// The kill switch.
    public var awsOnly: Bool

    /// Creates inputs.
    public init(osSupportsAppleTier: Bool, appleConfigured: Bool, awsConfigured: Bool, awsOnly: Bool) {
        self.osSupportsAppleTier = osSupportsAppleTier
        self.appleConfigured = appleConfigured
        self.awsConfigured = awsConfigured
        self.awsOnly = awsOnly
    }

    /// All 16 combinations, in a fixed order (exhaustive tests).
    public static let allCases: [TierInputs] = {
        var result: [TierInputs] = []
        for os in [false, true] {
            for apple in [false, true] {
                for aws in [false, true] {
                    for killSwitch in [false, true] {
                        result.append(
                            TierInputs(osSupportsAppleTier: os, appleConfigured: apple, awsConfigured: aws, awsOnly: killSwitch)
                        )
                    }
                }
            }
        }
        return result
    }()
}

/// Why no tier can serve.
public enum TierUnavailable: Error, Sendable, Hashable {
    /// Neither an eligible Apple configuration nor an AWS configuration exists.
    case noSourceConfigured
}

/// The pure tier decision of R-APL-5.
public enum TierSelection {
    /// Apple when the OS supports it, it is configured and the kill switch is off; otherwise AWS when configured;
    /// otherwise `.noSourceConfigured`.
    public static func select(_ inputs: TierInputs) -> Result<AssetTier, TierUnavailable> {
        if inputs.osSupportsAppleTier && inputs.appleConfigured && !inputs.awsOnly {
            return .success(.appleHosted)
        }
        if inputs.awsConfigured {
            return .success(.aws)
        }
        return .failure(.noSourceConfigured)
    }
}
