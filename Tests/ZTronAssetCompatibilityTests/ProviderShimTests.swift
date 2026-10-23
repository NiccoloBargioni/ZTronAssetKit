import Foundation
import Testing
import ZTronAssetKit
import ZTronAssetTestSupport

/// R-CAR-6: the prior art's two providers as manifest sources and tier descriptions (the client downloads).
@Suite("Compatibility shims: providers")
struct ProviderShimTests {
    /// A loopback origin for `handler` and an ephemeral session (no disk cache, nothing written outside the repository).
    static func origin(_ handler: @escaping LoopbackHandler) async throws -> (LoopbackHTTPServer, URL, URLSession) {
        let server = LoopbackHTTPServer(handler: handler)
        let port = try await server.start()
        let base = try #require(URL(string: "http://127.0.0.1:\(port)/"))
        return (server, base, URLSession(configuration: .ephemeral))
    }

    @Test("R-CAR-6: StaticManifestCDNProvider fetches its manifest anew on every call and decodes the prior-art wire format", .timeLimit(.minutes(1)))
    func staticProviderFetchesTheManifest() async throws {
        let icon = CompatFixture.asset("bo7.ri.easter.egg.icon", CompatFixture.bytes(60))
        let card = CompatFixture.asset("waw.ndu.title.card", CompatFixture.bytes(61), directories: [], fileName: "title")
        let first = CompatFixture.manifestData([icon])
        let second = CompatFixture.manifestData([icon, card])
        let (server, base, session) = try await ProviderShimTests.origin { request in
            guard request.target == "/catalog/manifest.json" else {
                return LoopbackResponse(status: 404)
            }
            // A cacheable first answer: the second call still reaches the origin (R-NET-5: never a local HTTP cache).
            return request.pathSequence == 1
                ? LoopbackResponse(headers: ["Cache-Control": "max-age=3600"], body: first)
                : LoopbackResponse(body: second)
        }
        let provider = StaticManifestCDNProvider(
            baseURL: base,
            manifestPath: "catalog/manifest.json",
            urlSession: session,
            executor: InlineBlockingExecutor()
        )

        let fetched = try await provider.fetchManifest()
        let refetched = try await provider.fetchManifest()

        session.invalidateAndCancel()
        let requests = await server.requests
        await server.stop()
        #expect(fetched == [icon])
        #expect(refetched == [icon, card])
        #expect(requests.map(\.method) == ["GET", "GET"])
        #expect(requests.map(\.target) == ["/catalog/manifest.json", "/catalog/manifest.json"])
    }

    @Test("R-CAR-6: StaticManifestCDNProvider answers the validated manifest: checksums in lowercase hex, quarantined entries left out", .timeLimit(.minutes(1)))
    func staticProviderAnswersTheValidatedManifest() async throws {
        let icon = CompatFixture.asset("bo7.ri.easter.egg.icon", CompatFixture.bytes(62))
        let shouted = CDNAsset(
            identifier: icon.identifier,
            fileExtension: icon.fileExtension,
            remotePath: icon.remotePath,
            localPathComponents: icon.localPathComponents,
            byteSize: icon.byteSize,
            checksum: icon.checksum?.uppercased()
        )
        // R-MAN-2: a checksum must be 64 hex characters when present (an ETag-style MD5 is not), an extension
        // `[A-Za-z0-9]{1,8}`; the prior art returned both entries as decoded.
        let etagged = CDNAsset(identifier: "bo7.ri.easter.egg.card", fileExtension: "png", remotePath: "media/ab/card.png", checksum: "d41d8cd98f00b204e9800998ecf8427e")
        let slashed = CDNAsset(identifier: "bo7.ri.easter.egg.poster", fileExtension: "p/ng", remotePath: "media/cd/poster.png")
        let body = CompatFixture.manifestData([shouted, etagged, slashed])
        let (server, base, session) = try await ProviderShimTests.origin { _ in
            LoopbackResponse(body: body)
        }
        let provider = StaticManifestCDNProvider(baseURL: base, manifestPath: "manifest.json", urlSession: session, executor: InlineBlockingExecutor())

        let fetched = try await provider.fetchManifest()

        session.invalidateAndCancel()
        await server.stop()
        #expect(fetched == [icon], "the checksum normalised to lowercase, the two invalid entries quarantined")
    }

    @Test("R-CAR-6: StaticManifestCDNProvider rejects a non-2xx answer with badResponse and an invalid manifest with a ManifestError", .timeLimit(.minutes(1)))
    func staticProviderRejectsBadAnswers() async throws {
        let (server, base, session) = try await ProviderShimTests.origin { request in
            request.pathSequence == 1 ? LoopbackResponse(status: 404) : LoopbackResponse(body: Data("{\"not\": \"a manifest\"".utf8))
        }
        let provider = StaticManifestCDNProvider(baseURL: base, manifestPath: "manifest.json", urlSession: session, executor: InlineBlockingExecutor())

        var status: Int?
        do {
            _ = try await provider.fetchManifest()
            Issue.record("a 404 must throw")
        } catch StaticManifestCDNProviderError.badResponse(let response) {
            status = (response as? HTTPURLResponse)?.statusCode
        }
        await #expect(throws: ManifestError.self, "D-9: the manifest is validated, not decoded blindly") {
            try await provider.fetchManifest()
        }

        session.invalidateAndCancel()
        await server.stop()
        #expect(status == 404)
    }

    @available(macOS 26.0, iOS 26.0, *)
    @Test("R-CAR-6: BackgroundAssetsCDNProvider serves its app-supplied catalog as the manifest", .timeLimit(.minutes(1)))
    func backgroundAssetsProviderServesItsCatalog() async throws {
        let catalog = [
            CDNAsset(identifier: "bo7.ri.icon", fileExtension: "heic", remotePath: "MediaPack/icons/icon.heic"),
            CDNAsset(identifier: "bo7.ri.intro", fileExtension: "mp4", remotePath: "VideoPack/intro.mp4", byteSize: 1_024),
        ]
        let provider = BackgroundAssetsCDNProvider(catalog: catalog)
        #expect(try await provider.fetchManifest() == catalog)
    }

    @Test("R-CAR-6: StaticManifestCDNProvider no longer downloads: downloadAsset throws downloadsGoThroughTheClient", .timeLimit(.minutes(1)))
    func staticProviderNoLongerDownloads() async throws {
        let base = try #require(URL(string: "https://cdn.example.com/"))
        let asset = CompatFixture.asset("bo7.ri.icon", CompatFixture.bytes(62))
        // Through the protocol, as the prior art's coordinator and resolver called it (the concrete method is deprecated).
        let provider: any CDNProviding = StaticManifestCDNProvider(baseURL: base)
        await #expect(throws: CDNShimError.downloadsGoThroughTheClient) {
            try await provider.downloadAsset(asset) { _ in }
        }
    }

    @available(macOS 26.0, iOS 26.0, *)
    @Test("R-CAR-6: BackgroundAssetsCDNProvider still rejects a malformed remote path and otherwise refuses to download", .timeLimit(.minutes(1)))
    func backgroundAssetsProviderNoLongerDownloads() async {
        let provider: any CDNProviding = BackgroundAssetsCDNProvider(catalog: [])
        for malformed in ["no-separator", "/icons/icon.heic", "MediaPack/"] {
            let asset = CDNAsset(identifier: "bo7.ri.icon", fileExtension: "heic", remotePath: malformed)
            await #expect(throws: BackgroundAssetsCDNProviderError.malformedRemotePath(malformed)) {
                try await provider.downloadAsset(asset) { _ in }
            }
        }
        let wellFormed = CDNAsset(identifier: "bo7.ri.icon", fileExtension: "heic", remotePath: "MediaPack/icons/icon.heic")
        await #expect(throws: CDNShimError.downloadsGoThroughTheClient) {
            try await provider.downloadAsset(wellFormed) { _ in }
        }
    }
}
