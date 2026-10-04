import Testing
@testable import ZTronAssetTransport

@Test("smoke: ZTronAssetTransport links and reports its name")
func ZTronAssetTransportLinksAndReportsName() {
    #expect(ZTronAssetTransportModule.describe(true) == "ZTronAssetTransport")
}
