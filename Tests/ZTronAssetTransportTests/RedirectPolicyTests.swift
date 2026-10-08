import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTransport

/// R-NET-4: the pure redirect decision (transport.md §5.2): hop limit, scheme, allow-list, then whether the key
/// survives.
@Suite("Redirect policy")
struct RedirectPolicyTests {
    static let policy = TransportSecurityPolicy.production(allowedHosts: ["cdn.example.com", "media.example.com"])

    static func origin(_ text: String) -> Origin? {
        URL(string: text).flatMap(Origin.init(url:))
    }

    /// One origin triple and the key's fate.
    struct Triple: Sendable, CustomTestStringConvertible {
        var original: String
        var previous: String
        var proposed: String
        var keyStillPresent: Bool
        var keepKey: Bool

        var testDescription: String {
            "\(self.original) → \(self.previous) → \(self.proposed) key=\(self.keyStillPresent)"
        }
    }

    static let triples: [Triple] = [
        Triple(original: "https://cdn.example.com/a", previous: "https://cdn.example.com/a", proposed: "https://cdn.example.com/b", keyStillPresent: true, keepKey: true),
        Triple(original: "https://cdn.example.com/a", previous: "https://cdn.example.com/a", proposed: "https://CDN.example.com./b", keyStillPresent: true, keepKey: true),
        Triple(original: "https://cdn.example.com/a", previous: "https://cdn.example.com/a", proposed: "https://media.example.com/b", keyStillPresent: true, keepKey: false),
        Triple(original: "https://cdn.example.com/a", previous: "https://cdn.example.com/a", proposed: "https://cdn.example.com:8443/b", keyStillPresent: true, keepKey: false),
        // Monotone: back at the original origin after a foreign hop, the key stays gone.
        Triple(original: "https://cdn.example.com/a", previous: "https://media.example.com/b", proposed: "https://cdn.example.com/c", keyStillPresent: false, keepKey: false),
        Triple(original: "https://cdn.example.com/a", previous: "https://media.example.com/b", proposed: "https://cdn.example.com/c", keyStillPresent: true, keepKey: false),
        // Never re-added: a same-origin hop of a request that has no key keeps none.
        Triple(original: "https://cdn.example.com/a", previous: "https://cdn.example.com/a", proposed: "https://cdn.example.com/b", keyStillPresent: false, keepKey: false),
    ]

    @Test("R-NET-4: the redirect decision keeps the key only while every hop stays on the original origin", arguments: RedirectPolicyTests.triples)
    func keyFollowsOnlyTheOriginalOrigin(_ triple: Triple) throws {
        let decision = RedirectPolicy.decide(
            original: try #require(Self.origin(triple.original)),
            previous: try #require(Self.origin(triple.previous)),
            proposed: Self.origin(triple.proposed),
            hop: 1,
            keyStillPresent: triple.keyStillPresent,
            policy: Self.policy
        )
        #expect(decision == .follow(keepKey: triple.keepKey))
    }

    @Test("R-NET-4: an HTTPS to HTTP downgrade is refused")
    func downgradeIsRefused() throws {
        let original = try #require(Self.origin("https://cdn.example.com/a"))
        let decision = RedirectPolicy.decide(
            original: original, previous: original, proposed: Self.origin("http://cdn.example.com/a"), hop: 1, keyStillPresent: true,
            policy: Self.policy)
        #expect(decision == .refuse(.insecureScheme))
        // The loopback test policy allows plain HTTP to loopback hosts only.
        let loopback = TransportSecurityPolicy.loopbackTesting(allowedHosts: ["127.0.0.1", "cdn.example.com"])
        let local = try #require(Self.origin("http://127.0.0.1:8080/a"))
        #expect(RedirectPolicy.decide(original: local, previous: local, proposed: Self.origin("http://cdn.example.com/b"), hop: 1, keyStillPresent: true, policy: loopback) == .refuse(.insecureScheme))
        #expect(RedirectPolicy.decide(original: local, previous: local, proposed: Self.origin("http://127.0.0.1:8080/b"), hop: 1, keyStillPresent: true, policy: loopback) == .follow(keepKey: true))
    }

    @Test("R-NET-4: a redirect outside the allow-list, past the hop limit or without a usable Location is refused")
    func refusals() throws {
        let original = try #require(Self.origin("https://cdn.example.com/a"))
        #expect(RedirectPolicy.decide(original: original, previous: original, proposed: Self.origin("https://evil.example.net/x"), hop: 1, keyStillPresent: true, policy: Self.policy) == .refuse(.hostNotAllowed))
        #expect(RedirectPolicy.decide(original: original, previous: original, proposed: Self.origin("https://cdn.example.com/b"), hop: 5, keyStillPresent: true, policy: Self.policy) == .follow(keepKey: true))
        #expect(RedirectPolicy.decide(original: original, previous: original, proposed: Self.origin("https://cdn.example.com/b"), hop: 6, keyStillPresent: true, policy: Self.policy) == .refuse(.tooManyRedirects))
        #expect(RedirectPolicy.decide(original: original, previous: original, proposed: nil, hop: 1, keyStillPresent: true, policy: Self.policy) == .refuse(.invalidLocation))
        // The hop limit is the policy's (clamped to 0…5): a policy of 0 refuses the first redirect.
        let none = TransportSecurityPolicy.loopbackTesting(allowedHosts: ["cdn.example.com"], maxRedirects: 0)
        #expect(RedirectPolicy.decide(original: original, previous: original, proposed: Self.origin("https://cdn.example.com/b"), hop: 1, keyStillPresent: true, policy: none) == .refuse(.tooManyRedirects))
    }
}
