/// Where an interrupted transfer may continue from (R-NET-8, ADR-019).
///
/// Foreground transfers are data tasks that append into `staging/<name>.part`; a later attempt continues the
/// earlier attempt's partial with `Range: bytes=<offset>-` plus `If-Range: <validator>`. Resumed bytes are never
/// trusted: the store hashes every staged file before publication (R-INT-2).
public struct ResumePoint: Sendable, Hashable, Codable {
    /// The earlier attempt's partial file (renamed to this attempt's name before the request starts).
    public var previous: StagingFileName
    /// Bytes already in the partial.
    public var offset: Int64
    /// The validator sent as `If-Range`.
    public var validator: ResumeValidator

    /// Creates a resume point.
    public init(previous: StagingFileName, offset: Int64, validator: ResumeValidator) {
        self.previous = previous
        self.offset = offset
        self.validator = validator
    }
}

/// The `If-Range` validator of a resumable response (RFC 9110 §13.1.5). A weak ETag is never a valid `If-Range`.
public enum ResumeValidator: Sendable, Hashable, Codable {
    /// A strong entity tag.
    case strongETag(ETag)
    /// A `Last-Modified` HTTP-date, verbatim.
    case lastModified(String)
}

/// Our own resume sidecar, written atomically as JSON to `staging/<name>.resume` (StagingFileName.Kind.sidecar).
///
/// It never contains URLSession resume data, a URL, a header or the app key (R-SEC-1); the request is rebuilt from
/// the manifest entry. A sidecar that does not decode is garbage for staging GC (R-CLN-3).
public struct ResumeSidecar: Sendable, Hashable, Codable {
    /// The partial file this sidecar describes.
    public var name: StagingFileName
    /// How to validate a continuation.
    public var validator: ResumeValidator
    /// Bytes in the partial when the sidecar was written.
    public var receivedBytes: Int64
    /// The decoded size the origin announced, when it announced one.
    public var expectedBytes: Int64?

    /// Creates a sidecar.
    public init(name: StagingFileName, validator: ResumeValidator, receivedBytes: Int64, expectedBytes: Int64?) {
        self.name = name
        self.validator = validator
        self.receivedBytes = receivedBytes
        self.expectedBytes = expectedBytes
    }
}

/// One engine-level request for content (R-NET-1). It carries no secret: the source attaches the key (R-NET-4).
public struct TransferRequest: Sendable, Hashable {
    /// The content identity being fetched (single-flight key, ADR-020).
    public var id: TransferID
    /// The start this request belongs to; with `id` it names every staging file (ADR-013).
    public var attempt: TransferAttempt
    /// Manifest or asset.
    public var purpose: TransferPurpose
    /// Validated relative path on the origin (R-MAN-2); `<packID>/<path>` on the Apple tier.
    public var remotePath: String
    /// The manifest's decoded size, when published (R-NET-7): staged bytes are compared with it, and a transfer
    /// that writes more than this is aborted early (transport-1 TR1-8).
    public var expectedBytes: Int64?
    /// The hard cap (`maxAssetBytes`, or the 32 MiB manifest cap).
    public var maxBytes: Int64
    /// The engine lane, mapped to `URLSessionTask.priority` (R-NET-10, ARCHITECTURE §7.5).
    public var priority: AssetPriority
    /// OS-enforced network permissions.
    public var access: NetworkAccess
    /// Which session may carry it.
    public var route: TransferRoute
    /// An earlier attempt's partial to continue, if the engine found a valid sidecar for it.
    public var resume: ResumePoint?

    /// Creates a request.
    public init(
        id: TransferID,
        attempt: TransferAttempt,
        purpose: TransferPurpose = .asset,
        remotePath: String,
        expectedBytes: Int64?,
        maxBytes: Int64,
        priority: AssetPriority,
        access: NetworkAccess = .unrestricted,
        route: TransferRoute = .foreground,
        resume: ResumePoint? = nil
    ) {
        self.id = id
        self.attempt = attempt
        self.purpose = purpose
        self.remotePath = remotePath
        self.expectedBytes = expectedBytes
        self.maxBytes = maxBytes
        self.priority = priority
        self.access = access
        self.route = route
        self.resume = resume
    }

    /// The partial file this attempt writes: `staging/<id>.<attempt>.part` (ADR-013).
    public var partialName: StagingFileName {
        StagingFileName(transfer: self.id, attempt: self.attempt, kind: .partial)
    }
}
