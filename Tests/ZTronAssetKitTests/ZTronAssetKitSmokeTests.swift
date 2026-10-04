import Testing
@testable import ZTronAssetKit

@Test("smoke: ZTronAssetKit links and reports its name")
func ZTronAssetKitLinksAndReportsName() {
    #expect(ZTronAssetKitModule.describe(true) == "ZTronAssetKit")
}
