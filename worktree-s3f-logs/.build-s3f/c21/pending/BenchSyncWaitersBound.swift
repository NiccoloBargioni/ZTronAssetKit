import Testing

/// The pin of a commit that binds every one of 10,000 user waiters (Stage 3 close-out cycle 21, `integrate-rr21.md`
/// ruling 6): item C's Phase 2 trigger, run by `commitRerouteTurns` (`BenchSyncReroutes.swift`).
extension ZTronAssetKitBenchmarks.SyncBenchmarks {
    /// C2 of a commit that binds and answers 10,000 user waiters after an apply that kept them on the content: it owes
    /// nothing (ruling 6 of `integrate-rr21.md`). A miss after item C's Phase 1 is Phase 2's trigger.
    @Test("R-SYN-11: a commit that binds 10,000 user waiters after an apply owes nothing and holds the engine's actor at most C2's 10 ms", .timeLimit(.minutes(10)))
    @available(macOS 15.0, iOS 18.0, *)
    func commitWaitersBoundTurns() async throws {
        try await Self.commitRerouteTurns(.waitersBound, label: "10,000 user waiters all bound")
    }
}
