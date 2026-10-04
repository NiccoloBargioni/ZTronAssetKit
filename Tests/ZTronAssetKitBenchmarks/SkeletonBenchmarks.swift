import Testing
import ZTronAssetTestSupport

@Suite("SkeletonBenchmarks")
struct SkeletonBenchmarks {
    @Test("smoke: benchmark target links")
    func benchmarkTargetLinks() {
        #expect(ZTronAssetTestSupportModule.name == "ZTronAssetTestSupport")
    }
}
