import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport
import ZTronAssetTransport

/// R-NET-6 through the real delegate (SPEC §7.3: 403, 429 with `Retry-After`, 5xx): the statuses the loopback
/// server answers reach the engine as the classifier's verdicts, with the evidence the delegate measured.
@Suite("Status mapping through the delegate")
struct StatusLoopbackTests {
    /// One scripted answer and the verdict it must produce.
    struct Route: Sendable, CustomTestStringConvertible {
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()
        var expected: TransferError

        var testDescription: String {
            "\(self.status) \(self.headers)"
        }
    }

    static let routes: [Route] = [
        Route(
            status: 403,
            expected: .authentication(.forbiddenAmbiguous(ForbiddenEvidence(
                purpose: .asset, bodyBytes: 0, contentTypeIsXML: false, keyPresented: true, resumed: false)))
        ),
        Route(
            status: 403,
            headers: ["Content-Type": "application/xml"],
            body: Data("<Error><Code>AccessDenied</Code></Error>".utf8),
            expected: .authentication(.forbiddenAmbiguous(ForbiddenEvidence(
                purpose: .asset, bodyBytes: 40, contentTypeIsXML: true, keyPresented: true, resumed: false)))
        ),
        Route(status: 429, headers: ["Retry-After": "7"], expected: .transient(.throttled, retryAfter: .seconds(7))),
        Route(
            status: 503,
            headers: ["Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"],
            expected: .transient(.serverError(httpStatus: 503), retryAfter: .date(Date(timeIntervalSince1970: 1_792_567_680)))
        ),
        Route(status: 500, body: Data("oops".utf8), expected: .transient(.serverError(httpStatus: 500), retryAfter: nil)),
        Route(status: 404, expected: .permanentMissing(httpStatus: 404)),
        Route(status: 410, expected: .permanentMissing(httpStatus: 410)),
        Route(status: 401, expected: .transient(.authenticationChallenge(httpStatus: 401), retryAfter: nil)),
        Route(status: 400, expected: .rejected(.unexpectedStatus(400))),
    ]

    @available(macOS 15.0, *)
    @Test("R-NET-6: status mapping through the real delegate matches the pure table", .timeLimit(.minutes(1)), arguments: StatusLoopbackTests.routes)
    func statusThroughDelegate(_ route: Route) async throws {
        let rig = try await LoopbackRig.make { _ in
            LoopbackResponse(status: route.status, headers: route.headers, body: route.body)
        }
        let request = rig.request(TransportFixtures.contentID(1), path: "a.bin", expected: 10)
        #expect(await run(await rig.source.transfer(request)).terminal == .failed(route.expected))
        // An error body is evidence, never staged.
        #expect(rig.staging.contents[request.partialName] == nil)
        await rig.stop()
    }

    @available(macOS 15.0, *)
    @Test("R-NET-6: an error body past the evidence cap stops the transfer and is still classified by its status", .timeLimit(.minutes(1)))
    func longErrorBody() async throws {
        let rig = try await LoopbackRig.make { _ in
            LoopbackResponse(status: 503, body: Data(repeating: 0x2e, count: 1 << 20))
        }
        let request = rig.request(TransportFixtures.contentID(1), path: "a.bin", expected: 10)
        #expect(await run(await rig.source.transfer(request)).terminal == .failed(.transient(.serverError(httpStatus: 503), retryAfter: nil)))
        await rig.stop()
    }

    @available(macOS 15.0, *)
    @Test("R-SEC-1: the canary key appears in no transport update, error or log line", .timeLimit(.minutes(1)))
    func canaryNeverLeaks() async throws {
        let rig = try await LoopbackRig.make(allowedHosts: ["127.0.0.1", "localhost"]) { request in
            switch request.target {
            case "/redirect":
                return LoopbackResponse(status: 302, headers: ["Location": "http://localhost:\(request.header("host")?.split(separator: ":").last ?? "")/forbidden"])
            case "/forbidden":
                return LoopbackResponse(status: 403)
            case "/manifest.json":
                return LoopbackResponse(status: 429, headers: ["Retry-After": "3"])
            default:
                return LoopbackResponse(body: Data("ok".utf8))
            }
        }
        var outputs: [String] = []
        for path in ["redirect", "forbidden", "ok"] {
            let handle = await rig.source.transfer(rig.request(TransportFixtures.contentID(1), path: path, expected: 2))
            let result = await run(handle)
            outputs.append(String(describing: result.terminal))
            outputs.append(String(reflecting: result.terminal))
            var dumped = ""
            dump(result.terminal, to: &dumped)
            outputs.append(dumped)
        }
        do {
            _ = try await rig.source.fetchManifest(ManifestRequest(ifNoneMatch: nil, maxBytes: 1 << 20, attempt: TransportFixtures.attempt(1)))
            Issue.record("a 429 manifest fetch succeeded")
        } catch {
            outputs.append(String(describing: error))
        }
        outputs.append(contentsOf: rig.tap.lines.map(\.message))
        outputs.append(String(describing: rig.source.configuration))
        outputs.append(String(reflecting: rig.source.configuration))
        #expect(!outputs.isEmpty)
        #expect(outputs.allSatisfy { !$0.contains(TransportFixtures.canaryValue) })
        // The key was really sent, so the scan above is not vacuous.
        #expect(await rig.requests(to: "/redirect").first?.header("x-zombietron-app-key") == TransportFixtures.canaryValue)
        await rig.stop()
    }
}
