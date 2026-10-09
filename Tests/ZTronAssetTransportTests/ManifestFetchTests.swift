import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport
import ZTronAssetTransport

/// R-NET-5: the conditional manifest fetch through the real delegate (SPEC §7.3 "manifest 304").
@Suite("Manifest fetch")
struct ManifestFetchTests {
    static func request(_ tag: ETag?, maxBytes: Int64 = ManifestLimits().maxPayloadBytes, sequence: UInt32 = 1) -> ManifestRequest {
        ManifestRequest(ifNoneMatch: tag, maxBytes: maxBytes, attempt: TransportFixtures.attempt(sequence))
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-5: a manifest fetch sends If-None-Match with the stored ETag and maps 304 to notModified", .timeLimit(.minutes(1)))
    func conditionalFetch() async throws {
        let manifest = Data(#"{"schemaVersion":1,"assets":[]}"#.utf8)
        let rig = try await LoopbackRig.make { request in
            if request.header("if-none-match") == "\"m-1\"" {
                return LoopbackResponse(status: 304, headers: ["ETag": "\"m-1\""])
            }
            return LoopbackResponse(headers: ["ETag": "\"m-1\"", "Content-Type": "application/json"], body: manifest)
        }
        let first = try await rig.source.fetchManifest(Self.request(nil))
        let tag = try #require(ETag(rawValue: "\"m-1\""))
        #expect(first == .fetched(ManifestPayload(bytes: manifest, etag: tag, origin: .network)))
        let second = try await rig.source.fetchManifest(Self.request(tag, sequence: 2))
        #expect(second == .notModified(removedSources: []))
        let requests = await rig.requests(to: "/manifest.json")
        #expect(requests.map { $0.header("if-none-match") } == [nil, "\"m-1\""])
        #expect(requests.allSatisfy { $0.header("x-zombietron-app-key") == TransportFixtures.canaryValue })
        // The staged manifest was read back and discarded: nothing is left in staging.
        #expect(rig.staging.contents.isEmpty)
        await rig.stop()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-5: URLSession never answers a manifest fetch from its own cache, even within max-age", .timeLimit(.minutes(1)))
    func neverFromCache() async throws {
        let rig = try await LoopbackRig.make { request in
            LoopbackResponse(
                headers: ["Cache-Control": "public, max-age=600", "ETag": "\"m-\(request.pathSequence)\""],
                body: Data("manifest \(request.pathSequence)".utf8)
            )
        }
        let first = try await rig.source.fetchManifest(Self.request(nil))
        let second = try await rig.source.fetchManifest(Self.request(nil, sequence: 2))
        #expect(first == .fetched(ManifestPayload(bytes: Data("manifest 1".utf8), etag: ETag(rawValue: "\"m-1\""), origin: .network)))
        #expect(second == .fetched(ManifestPayload(bytes: Data("manifest 2".utf8), etag: ETag(rawValue: "\"m-2\""), origin: .network)))
        #expect(await rig.requests(to: "/manifest.json").count == 2)
        await rig.stop()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-5: a 304 without a conditional request is rejected", .timeLimit(.minutes(1)))
    func unconditionalNotModified() async throws {
        let rig = try await LoopbackRig.make { _ in LoopbackResponse(status: 304) }
        await #expect(throws: TransferError.rejected(.unexpectedNotModified)) {
            try await rig.source.fetchManifest(Self.request(nil))
        }
        await rig.stop()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-5: a manifest over 32 MiB is aborted while streaming", .timeLimit(.minutes(1)))
    func streamingCap() async throws {
        let limit = ManifestLimits().maxPayloadBytes
        // Close-delimited and stalled with the connection open after cap + 256 KiB: only an abort while streaming ends
        // the fetch before the request timeout (an explicit Content-Type, so nothing is held back for MIME sniffing).
        let rig = try await LoopbackRig.make { _ in
            LoopbackResponse(
                headers: ["Content-Type": "application/json"],
                body: Data(repeating: 0x20, count: Int(limit) + (1 << 20)),
                ending: .stallAfter(bodyBytes: Int(limit) + 256 * 1_024),
                omitContentLength: true
            )
        }
        await #expect(throws: TransferError.integrity(.oversize(announced: nil, limit: limit))) {
            try await rig.source.fetchManifest(Self.request(nil))
        }
        #expect(rig.staging.contents.isEmpty)
        await rig.stop()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-5: an announced manifest length over the cap is aborted before any byte is staged", .timeLimit(.minutes(1)))
    func announcedCap() async throws {
        let rig = try await LoopbackRig.make { _ in LoopbackResponse(body: Data(repeating: 0x20, count: 2 << 20)) }
        await #expect(throws: TransferError.integrity(.oversize(announced: 2 << 20, limit: 1 << 20))) {
            try await rig.source.fetchManifest(Self.request(nil, maxBytes: 1 << 20))
        }
        #expect(rig.staging.contents.isEmpty)
        await rig.stop()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-6: an XML 403 on the manifest is reported with its evidence through the delegate", .timeLimit(.minutes(1)))
    func xmlForbiddenManifest() async throws {
        let xml = Data("<Error><Code>AccessDenied</Code></Error>".utf8)
        let rig = try await LoopbackRig.make { _ in
            LoopbackResponse(status: 403, headers: ["Content-Type": "application/xml"], body: xml)
        }
        let evidence = ForbiddenEvidence(purpose: .manifest, bodyBytes: Int64(xml.count), contentTypeIsXML: true, keyPresented: true, resumed: false)
        await #expect(throws: TransferError.authentication(.forbiddenAmbiguous(evidence))) {
            try await rig.source.fetchManifest(Self.request(nil))
        }
        #expect(evidence.hint == .objectMissingLikely)
        await rig.stop()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-5: a manifest path that is not a plain relative path is refused before any request", .timeLimit(.minutes(1)))
    func invalidManifestPath() async throws {
        let rig = try await LoopbackRig.make(manifestPath: "../manifest.json") { _ in LoopbackResponse(body: Data("{}".utf8)) }
        await #expect(throws: TransferError.rejected(.invalidURL)) {
            try await rig.source.fetchManifest(Self.request(nil))
        }
        #expect(await rig.server.requests.isEmpty)
        await rig.stop()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-5: a staged manifest that cannot be read back fails as a local error and is discarded", .timeLimit(.minutes(1)))
    func unreadableStagedManifest() async throws {
        let rig = try await LoopbackRig.make { _ in LoopbackResponse(body: Data("{}".utf8)) }
        rig.staging.failNext(.readStaged, with: .io(posixCode: EIO))
        await #expect(throws: TransferError.transient(.localIO(posixCode: EIO), retryAfter: nil)) {
            try await rig.source.fetchManifest(Self.request(nil))
        }
        #expect(rig.staging.contents.isEmpty)
        await rig.stop()
    }
}
