import Testing
@testable import ZTronAssetStorage

@Test("smoke: ZTronAssetStorage links and reports its name")
func ZTronAssetStorageLinksAndReportsName() {
    #expect(ZTronAssetStorageModule.describe(true) == "ZTronAssetStorage")
}
