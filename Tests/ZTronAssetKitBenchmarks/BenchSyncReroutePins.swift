import Testing

/// The commit turn's and `followedLane`'s pins of the owed re-routes at site 1 (Stage 3 close-out cycle 21, ruling S3-R26
/// item 1; `integrate-rr21.md`'s pins), run by `commitRerouteTurns` (`BenchSyncReroutes.swift`).
extension ZTronAssetKitBenchmarks.SyncBenchmarks {
    /// C2 of a commit whose 10,000 moved-away ids each have a user waiter and converge on D's content (ruling 6 of
    /// `integrate-rr21.md`, "Commit with user waiters"): the commit owes them as one batch, 511 more user requests for
    /// moved ids join behind it, and the drain makes the batch 512 ids a turn, then the joins. The commit's own turn
    /// re-routes nothing (the fit charge owes every pair): it classifies the 10,000 pairs, answers its bound ids and
    /// retires the job.
    @Test("R-SYN-11: a commit that owes 10,000 user waiters' re-routes onto one content, with 511 joins behind them, holds the engine's actor at most C2's 10 ms per turn", .timeLimit(.minutes(10)))
    @available(macOS 15.0, iOS 18.0, *)
    func commitRerouteWaitersTurns() async throws {
        try await Self.commitRerouteTurns(.waiters, label: "10,000 user waiters moved onto one content, 511 joins behind the batch")
    }

    /// C2 of a superseded exit whose 10,000 moved-away ids each have a user waiter and converge on D's content
    /// (`design-minimal.md`'s supersededUserTurns; ruling S3-R26 item 9's inventory, site 3): v4 maps K, H's own id, to a
    /// content of its own as well, so the store refuses H's publication, and the exit owes the 10,001 pairs as one batch,
    /// which the drain makes 512 ids a turn. The exit's own turn has no seam of its own: the heartbeat covers it.
    @Test("R-SYN-11: a superseded exit that owes 10,000 user waiters' re-routes onto one content holds the engine's actor at most C2's 10 ms per turn", .timeLimit(.minutes(10)))
    @available(macOS 15.0, iOS 18.0, *)
    func supersededUserTurns() async throws {
        try await Self.commitRerouteTurns(.supersededWaiters, label: "10,000 user waiters of a superseded publication moved onto one content")
    }

    /// C2 of a run's 10,000 claims that converge on one content and move away (`integrate-rr21.md`'s runSuperseded): at a
    /// commit that binds K alone (site 1), at the exit of a publication the store refuses (site 3), and at a commit whose
    /// moved claims land on a content the store holds, so that the drain answers each owed run item present, its claim
    /// released and the asset counted fetched, with the run's progress offered (`countRunFetched`, `offerRunProgress`),
    /// at most 512 a drain turn. Once the drain is over, the run claims nothing on H and, but where the store holds D's
    /// content, the 10,000 ids on D's job.
    @Test("R-SYN-11: a run's 10,000 claims moved away at a commit, at a superseded exit and onto a present content hold the engine's actor at most C2's 10 ms per turn", .timeLimit(.minutes(20)))
    @available(macOS 15.0, iOS 18.0, *)
    func runSuperseded() async throws {
        try await Self.commitRerouteTurns(.runMovedAway, label: "a run's 10,000 claims moved away at a commit")
        try await Self.commitRerouteTurns(.runSuperseded, label: "a run's 10,000 claims at a superseded exit")
        try await Self.commitRerouteTurns(.runToBound, label: "a run's 10,000 claims moved onto a present content")
    }

    /// C2 of a commit whose 10,000 moved-away ids are each wanted by two prefetch groups: the drain makes every id whole
    /// with both its tokens in one turn (T-two-tokens), so a turn re-routes 1,024 interests of 512 ids.
    @Test("R-SYN-11: a commit that owes 10,000 ids with two tokens each holds the engine's actor at most C2's 10 ms per turn", .timeLimit(.minutes(10)))
    @available(macOS 15.0, iOS 18.0, *)
    func commitTwoTokensTurns() async throws {
        try await Self.commitRerouteTurns(.twoTokens, label: "10,000 ids with two tokens each")
    }

    /// C2 of owed re-routes onto a content the store holds (RR21-PRESENT-PRUNE's figure): each of 10,000 user waiters
    /// is answered from the store, an owned task each, at most 512 spawned a drain turn, and D's content gets no job. The
    /// window ends at the last answer, not at the barrier's fall.
    @Test("R-SYN-11: owed re-routes of 10,000 user waiters onto a present content are answered from the store holding the engine's actor at most C2's 10 ms per turn", .timeLimit(.minutes(10)))
    @available(macOS 15.0, iOS 18.0, *)
    func userMovedToBound() async throws {
        try await Self.commitRerouteTurns(.userToBound, label: "10,000 user waiters moved onto a present content")
    }

    /// C2 of two applies while a 10,000-pair batch waits, with a publication in flight (`layerOwedReroutes`: one pass
    /// over the waiting events and the jobs in flight, O(E + in flight)), then of the replay through the two layers
    /// (`rerouteListing`, O(layers) an id).
    @Test("R-SYN-11: two applies while 10,000 re-routes are owed, and their replay through two layers, hold the engine's actor at most C2's 10 ms per turn", .timeLimit(.minutes(10)))
    @available(macOS 15.0, iOS 18.0, *)
    func applyWhileOwedLayers() async throws {
        try await Self.commitRerouteTurns(.appliesWhileOwed, label: "two applies while 10,000 re-routes are owed")
    }

    /// C2 of a 429 on the content of a 10,000-pair batch of prefetch re-routes owed through two layers: the 429's lane
    /// (`followedLane`) reads every owed item, none of them user work, so nothing stops the walk early (O(items x
    /// layers)). `followedLane` is also timed alone, inside the actor (the median of 21 calls).
    @Test("R-SYN-11: a 429 on the content of 10,000 owed prefetch re-routes holds the engine's actor at most C2's 10 ms", .timeLimit(.minutes(10)))
    @available(macOS 15.0, iOS 18.0, *)
    func lane429WhileOwed() async throws {
        try await Self.commitRerouteTurns(.rateLimitWhileOwed, label: "a 429 on the owed re-routes' content")
    }
}
