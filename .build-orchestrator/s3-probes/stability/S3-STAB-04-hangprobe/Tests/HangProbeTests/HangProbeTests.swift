import Testing
import HangProbe

/// S3-STAB-02 probe: does `.timeLimit` end a test that joins an unstructured task whose product wait lost its resume?
@Test("join of an unstructured task after a lost resume", .timeLimit(.minutes(1)))
func joinAfterLostResume() async throws {
    let gate = LostResume()
    let call = Task { await gate.wait() }
    await call.value
}

@Test("a sibling test that ends at once")
func sibling() {
    #expect(1 + 1 == 2)
}
