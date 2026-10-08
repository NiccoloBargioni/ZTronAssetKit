import Testing
import ZTronAssetAppleHosted

/// R-SEC-2 (defence in depth): a pack location is validated component by component exactly where a file system
/// would split it, at every `/` scalar, and rebuilds its remote path scalar for scalar (the release survey relies on
/// that one-to-one correspondence).
@Suite("Apple tier: pack locations")
struct PackLocationTests {
    @Test("R-SEC-2: a dot or dot-dot segment whose following slash carries a combining mark is rejected")
    func dotSegmentsBehindACombiningMarkAreRejected() {
        #expect(PackLocation(remotePath: "ZTronMedia/../\u{301}escape.png") == nil)
        #expect(PackLocation(remotePath: "ZTronMedia/a/../\u{301}b.png") == nil)
        #expect(PackLocation(remotePath: "ZTronMedia/./\u{301}b.png") == nil)
    }

    @Test("R-SEC-2: pack locations rebuild their remote path exactly and reject control characters anywhere")
    func locationsRoundTripAndRejectControls() {
        let valid = ["ZTronMedia/a.png", "ZTronMedia/\u{301}accent/e\u{301}.png", "ZTronMedia/dir/sub/file.bin", "ZTron.Media_1-x/ü/ß"]
        for path in valid {
            #expect(PackLocation(remotePath: path)?.description == path, "\(path)")
        }
        #expect(PackLocation(remotePath: "ZTronMedia/\u{301}accent.png")?.path == "\u{301}accent.png")
        for control in ["\u{0}", "\u{1F}", "\u{7F}", "\u{85}", "\u{9F}"] {
            #expect(PackLocation(remotePath: "ZTronMedia/a\(control)b.png") == nil, "U+\(String(control.unicodeScalars.first!.value, radix: 16))")
        }
    }
}
