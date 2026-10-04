import Testing
@testable import ZTronAssetSync

@Test("smoke: ZTronAssetSync links and reports its name")
func ZTronAssetSyncLinksAndReportsName() {
    #expect(ZTronAssetSyncModule.describe(true) == "ZTronAssetSync")
}
