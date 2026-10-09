import Foundation
import ZTronAssetModel

/// Whether plain HTTP is ever allowed (R-NET-4, R-SEC-3).
public enum PlaintextPermission: Sendable, Hashable {
    /// HTTPS only: the only value an app can reach.
    case never
    /// Plain HTTP for `127.0.0.1`, `::1` and `localhost` only: the package's loopback tests and benchmarks.
    case loopbackOnly
}

/// A request origin: scheme, lowercased host without a trailing dot, effective port (transport.md §5.2).
public struct Origin: Sendable, Hashable, CustomStringConvertible {
    /// `https` or `http`.
    public let scheme: String
    /// Lowercased, trailing dot stripped (transport-1 TR1-13).
    public let host: String
    /// The explicit port, or 443/80 by default.
    public let port: Int

    /// The origin of `url`; `nil` without a scheme or host, or for a scheme other than http/https.
    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
            var host = url.host?.lowercased(), !host.isEmpty
        else {
            return nil
        }
        while host.hasSuffix(".") {
            host.removeLast()
        }
        guard !host.isEmpty else {
            return nil
        }
        self.scheme = scheme
        self.host = host
        self.port = url.port ?? (scheme == "https" ? 443 : 80)
    }

    /// `scheme://host:port`: also the circuit-breaker key (`RemoteSource.originID`).
    public var description: String {
        "\(self.scheme)://\(self.host):\(self.port)"
    }
}

/// Which origins may be contacted, and how (R-NET-4).
public struct TransportSecurityPolicy: Sendable, Hashable {
    /// Lowercased hosts without trailing dots.
    public let allowedHosts: Set<String>
    /// Plain-HTTP permission.
    public let plaintext: PlaintextPermission
    /// Redirect hops allowed, 0…5.
    public let maxRedirects: Int
    /// The header carrying the app key.
    public let keyHeaderName: String

    private init(allowedHosts: Set<String>, plaintext: PlaintextPermission, maxRedirects: Int, keyHeaderName: String) {
        self.allowedHosts = Set(allowedHosts.map { host in
            var normalized = host.lowercased()
            while normalized.hasSuffix(".") {
                normalized.removeLast()
            }
            return normalized
        })
        self.plaintext = plaintext
        self.maxRedirects = min(max(maxRedirects, 0), 5)
        self.keyHeaderName = keyHeaderName
    }

    /// The only policy an app can build: HTTPS only, at most 5 redirects.
    public static func production(allowedHosts: Set<String>, keyHeaderName: String = "x-zombietron-app-key") -> TransportSecurityPolicy {
        TransportSecurityPolicy(allowedHosts: allowedHosts, plaintext: .never, maxRedirects: 5, keyHeaderName: keyHeaderName)
    }

    /// Package only (tests and benchmarks): plain HTTP for loopback hosts.
    package static func loopbackTesting(
        allowedHosts: Set<String>,
        maxRedirects: Int = 5,
        keyHeaderName: String = "x-zombietron-app-key"
    ) -> TransportSecurityPolicy {
        TransportSecurityPolicy(
            allowedHosts: allowedHosts,
            plaintext: .loopbackOnly,
            maxRedirects: maxRedirects,
            keyHeaderName: keyHeaderName
        )
    }

    /// `nil` when the origin may be contacted; otherwise why not.
    public func check(_ origin: Origin?) -> PolicyViolation? {
        guard let origin else {
            return .invalidURL
        }
        if origin.scheme != "https" {
            let loopback = origin.host == "127.0.0.1" || origin.host == "::1" || origin.host == "localhost"
            guard self.plaintext == .loopbackOnly, loopback else {
                return .insecureScheme
            }
        }
        guard self.allowedHosts.contains(origin.host) else {
            return .hostNotAllowed
        }
        return nil
    }
}

/// The pure redirect decision (R-NET-4, transport.md §5.2): hop count, scheme, allow-list, then whether the key
/// survives. The key survives only while every hop stays on the original origin, and never returns once stripped.
public enum RedirectPolicy {
    /// The outcome for one proposed hop.
    public enum Decision: Sendable, Hashable {
        /// Follow; `keepKey` tells the delegate whether the app-key header stays on the new request.
        case follow(keepKey: Bool)
        /// Refuse: the 3xx is delivered as the final response.
        case refuse(RedirectRefusal)
    }

    /// Decides one hop. `hop` is 1 for the first redirect.
    public static func decide(
        original: Origin,
        previous: Origin,
        proposed: Origin?,
        hop: Int,
        keyStillPresent: Bool,
        policy: TransportSecurityPolicy
    ) -> Decision {
        guard hop <= policy.maxRedirects else {
            return .refuse(.tooManyRedirects)
        }
        guard let proposed else {
            return .refuse(.invalidLocation)
        }
        if let violation = policy.check(proposed) {
            // `check` of a non-nil origin reports only these two.
            return .refuse(violation == .insecureScheme ? .insecureScheme : .hostNotAllowed)
        }
        // Monotone: once a hop left the original origin the key is gone for good, even back at the origin.
        return .follow(keepKey: keyStillPresent && previous == original && proposed == original)
    }
}
