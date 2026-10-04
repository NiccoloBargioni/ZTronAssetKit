import Testing
@testable import ZTronAssetAppleHosted

@Test("smoke: ZTronAssetAppleHosted links and reports its name")
func ZTronAssetAppleHostedLinksAndReportsName() {
    #expect(ZTronAssetAppleHostedModule.describe(true) == "ZTronAssetAppleHosted")
}
