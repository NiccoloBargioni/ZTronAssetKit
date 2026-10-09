/// Why a request is made: the manifest document or one asset (transport.md §3.3, R-NET-6).
///
/// The 403 hint (`ForbiddenEvidence.hint`) and the size cap depend on it: a manifest is capped at
/// `ManifestLimits.maxPayloadBytes`, an asset at `maxAssetBytes` (R-NET-7). The raw value is written into transfer
/// tags and logs, so it never changes.
public enum TransferPurpose: String, Sendable, Hashable, CaseIterable {
    /// The manifest document (`TransferID.manifest`).
    case manifest
    /// One asset's bytes.
    case asset
}

/// Which `URLSession` may carry a transfer (R-NET-3, ADR-026).
public enum TransferRoute: Sendable, Hashable {
    /// Always the foreground session.
    case foreground
    /// May use the background session if it is enabled and safe for this request (ADR-026); else foreground.
    case backgroundEligible
}

/// Per-request, OS-enforced network permissions derived from `NetworkPolicy` (R-SYN-7, R-NET-9).
///
/// The engine's admission decides first; these flags make the OS fail fast (−1009 with a reason) when the path
/// changes under a running request, so the engine never pays for a request its policy refuses.
///
/// The HTTP tier sets them on every request it builds. The Apple tier cannot honour them: BackgroundAssets has no
/// per-call network constraint for making a pack available or for an update check, so it ignores
/// `TransferRequest.access` and `ManifestRequest.access` by necessity, and the engine must gate Apple-tier transfers
/// and update-checking manifest fetches on its own `DeviceConditions` (ADR-050, E-17; ARCHITECTURE §11, R-SYN-7).
public struct NetworkAccess: Sendable, Hashable {
    /// `URLRequest.allowsCellularAccess`.
    public var allowsCellular: Bool
    /// `URLRequest.allowsExpensiveNetworkAccess`.
    public var allowsExpensive: Bool
    /// `URLRequest.allowsConstrainedNetworkAccess` (Low Data Mode).
    public var allowsConstrained: Bool

    /// Creates permissions; everything is allowed by default.
    public init(allowsCellular: Bool = true, allowsExpensive: Bool = true, allowsConstrained: Bool = true) {
        self.allowsCellular = allowsCellular
        self.allowsExpensive = allowsExpensive
        self.allowsConstrained = allowsConstrained
    }

    /// Every network allowed (explicit user requests when `userInitiatedOverridesPolicy`).
    public static let unrestricted = NetworkAccess()
}
