import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport
import ZTronAssetTransport

/// R-NET-4 through the real delegate (SPEC §7.3 "redirect to another host strips the key"): `127.0.0.1` and
/// `localhost` are two hosts of one loopback server, so a hop between them is cross-origin.
@Suite("Redirects and the app key")
struct RedirectLoopbackTests {
    /// `host:port` of a request's `Host` header, swapped between the two loopback names.
    static func otherHost(of request: LoopbackRequest) -> String {
        let host = request.header("host") ?? ""
        if host.hasPrefix("127.0.0.1:") {
            return "localhost:" + host.dropFirst("127.0.0.1:".count)
        }
        return "127.0.0.1:" + host.dropFirst("localhost:".count)
    }

    @available(macOS 15.0, *)
    @Test("R-NET-4: a cross-host redirect to an allow-listed host is followed without the app key", .timeLimit(.minutes(1)))
    func crossHostRedirectStripsTheKey() async throws {
        let body = TransportFixtures.payload(5_000)
        let rig = try await LoopbackRig.make(allowedHosts: ["127.0.0.1", "localhost"]) { request in
            if request.target == "/a.bin" {
                return LoopbackResponse(status: 302, headers: ["Location": "http://\(Self.otherHost(of: request))/b.bin"])
            }
            return LoopbackResponse(body: body)
        }
        let request = rig.request(TransportFixtures.contentID(1), path: "a.bin", expected: 5_000)
        guard case .staged(let file)? = await run(await rig.source.transfer(request)).terminal else {
            Issue.record("not staged")
            await rig.stop()
            return
        }
        #expect(rig.staging.contents[file.name] == body)
        let first = try #require(await rig.requests(to: "/a.bin").first)
        let second = try #require(await rig.requests(to: "/b.bin").first)
        #expect(first.header("x-zombietron-app-key") == TransportFixtures.canaryValue)
        #expect(second.header("host")?.hasPrefix("localhost:") == true)
        #expect(second.header("x-zombietron-app-key") == nil)
        await rig.stop()
    }

    @available(macOS 15.0, *)
    @Test("R-NET-4: a redirect to a host outside the allow-list is refused and that host receives no request", .timeLimit(.minutes(1)))
    func foreignRedirectIsRefused() async throws {
        let foreign = LoopbackHTTPServer { _ in LoopbackResponse(body: Data("stolen".utf8)) }
        let foreignPort = try await foreign.start()
        let rig = try await LoopbackRig.make(allowedHosts: ["127.0.0.1"]) { _ in
            LoopbackResponse(status: 302, headers: ["Location": "http://localhost:\(foreignPort)/x"])
        }
        let handle = await rig.source.transfer(rig.request(TransportFixtures.contentID(1), path: "a.bin", expected: 6))
        #expect(await run(handle).terminal == .failed(.rejected(.redirectRefused(.hostNotAllowed))))
        #expect(await foreign.requests.isEmpty)
        #expect(rig.staging.contents.isEmpty)
        await foreign.stop()
        await rig.stop()
    }

    @available(macOS 15.0, *)
    @Test("R-NET-4: same-origin redirects keep the key and the sixth hop is refused", .timeLimit(.minutes(1)))
    func hopLimit() async throws {
        let rig = try await LoopbackRig.make { request in
            let hop = Int(request.target.dropFirst("/hop/".count)) ?? 0
            return LoopbackResponse(status: 302, headers: ["Location": "/hop/\(hop + 1)"])
        }
        let handle = await rig.source.transfer(rig.request(TransportFixtures.contentID(1), path: "hop/0", expected: 1))
        #expect(await run(handle).terminal == .failed(.rejected(.redirectRefused(.tooManyRedirects))))
        let requests = await rig.server.requests
        // The original plus five followed hops; every one carried the key.
        #expect(requests.map(\.target) == (0...5).map { "/hop/\($0)" })
        #expect(requests.allSatisfy { $0.header("x-zombietron-app-key") == TransportFixtures.canaryValue })
        await rig.stop()
    }

    @available(macOS 15.0, *)
    @Test("R-NET-4: once stripped, the key never returns on a redirect back to the original origin", .timeLimit(.minutes(1)))
    func keyNeverReturns() async throws {
        let rig = try await LoopbackRig.make(allowedHosts: ["127.0.0.1", "localhost"]) { request in
            switch request.target {
            case "/a.bin", "/b.bin":
                let next = request.target == "/a.bin" ? "/b.bin" : "/c.bin"
                return LoopbackResponse(status: 307, headers: ["Location": "http://\(Self.otherHost(of: request))\(next)"])
            default:
                return LoopbackResponse(body: Data("done".utf8))
            }
        }
        let handle = await rig.source.transfer(rig.request(TransportFixtures.contentID(1), path: "a.bin", expected: 4))
        guard case .staged? = await run(handle).terminal else {
            Issue.record("not staged")
            await rig.stop()
            return
        }
        let keys = await ["/a.bin", "/b.bin", "/c.bin"].asyncMap { await rig.requests(to: $0).first?.header("x-zombietron-app-key") }
        #expect(keys == [TransportFixtures.canaryValue, nil, nil])
        #expect(await rig.requests(to: "/c.bin").first?.header("host")?.hasPrefix("127.0.0.1:") == true)
        await rig.stop()
    }

    @available(macOS 15.0, *)
    @Test("R-NET-6: a 403 after the key was withheld on a cross-origin redirect is reported as keyWithheldOnRedirect", .timeLimit(.minutes(1)))
    func forbiddenAfterWithholding() async throws {
        let rig = try await LoopbackRig.make(allowedHosts: ["127.0.0.1", "localhost"]) { request in
            if request.target == "/a.bin" {
                return LoopbackResponse(status: 302, headers: ["Location": "http://\(Self.otherHost(of: request))/b.bin"])
            }
            return LoopbackResponse(status: 403)
        }
        let handle = await rig.source.transfer(rig.request(TransportFixtures.contentID(1), path: "a.bin", expected: 4))
        #expect(await run(handle).terminal == .failed(.rejected(.keyWithheldOnRedirect)))
        await rig.stop()
    }

    @available(macOS 15.0, *)
    @Test("R-NET-4: a redirect without a usable Location is delivered as a refused redirect", .timeLimit(.minutes(1)))
    func missingLocation() async throws {
        let rig = try await LoopbackRig.make { _ in LoopbackResponse(status: 302) }
        let handle = await rig.source.transfer(rig.request(TransportFixtures.contentID(1), path: "a.bin", expected: 4))
        #expect(await run(handle).terminal == .failed(.rejected(.redirectRefused(.invalidLocation))))
        await rig.stop()
    }
}

extension Array where Element: Sendable {
    /// Maps sequentially with an async transform.
    func asyncMap<T: Sendable>(_ transform: (Element) async -> T) async -> [T] {
        var mapped: [T] = []
        for element in self {
            mapped.append(await transform(element))
        }
        return mapped
    }
}
