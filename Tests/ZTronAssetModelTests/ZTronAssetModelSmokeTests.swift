import Testing
@testable import ZTronAssetModel

@Test("smoke: ZTronAssetModel links and reports its name")
func ZTronAssetModelLinksAndReportsName() {
    #expect(ZTronAssetModelModule.describe(true) == "ZTronAssetModel")
}
