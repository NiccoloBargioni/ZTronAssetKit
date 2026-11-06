import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport
@testable import ZTronAssetTransport

@Suite("TMP weak ETag probe")
struct TmpWeakETagProbeTests {
    @available(macOS 15.0, iOS 18.0, *)
    @Test("TMP: R-NET-8 a weak ETag is never the resume validator; Last-Modified is kept instead", .timeLimit(.minutes(1)))
    func weakETagFallsBackToLastModified() async throws {
        let rig = try await LoopbackRig.make { _ in
            LoopbackResponse(
                headers: ["ETag": "W/\"v1\"", "Last-Modified": "Wed, 21 Oct 2026 07:28:00 GMT"],
                body: TransportFixtures.payload(1 << 20),
                ending: .stallAfter(bodyBytes: 512 * 1_024)
            )
        }
        let request = rig.request(TransportFixtures.contentID(1), path: "a.bin", expected: 1 << 20)
        let handle = await rig.source.transfer(request)
        var iterator = handle.updates.makeAsyncIterator()
        #expect(await awaitProgress(&iterator, reaching: 512 * 1_024))
        handle.pause()
        #expect(await iterator.next() == .paused(resumable: true))
        let sidecar = try #require(rig.staging.sidecars[request.partialName])
        #expect(sidecar.validator == .lastModified("Wed, 21 Oct 2026 07:28:00 GMT"))
        await rig.stop()
    }
}
