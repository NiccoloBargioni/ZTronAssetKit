# Step 0's scratch seams (cycle 22; never committed as such): applied to a scratch copy given as argv[1].
#  - the 404 resolution's turn and the purge's first turn call EngineState.commitTurnMarksForTests, as the commit does;
#  - PROBE-C22-PUBLISH's SubscriberQueue variants (d1's a1, a2's guarded reservation, a3's publishAll);
#  - PROBE-C21-PURGE-PARTS's walk timer and the internal withdrawPurgedJoins (copied from .build-s3f/c21/purge).
import sys
root = sys.argv[1]
def edit(path, old, new):
    p = root + '/' + path
    s = open(p).read()
    assert s.count(old) == 1, (path, s.count(old), old[:80])
    open(p, 'w').write(s.replace(old, new))
E = 'Sources/ZTronAssetSync/Engine/'
edit(E + 'EngineFailures.swift',
"""                // An id bound during the await is left present: the store's guard skips a record bound to a live blob
                // at this identity (L4-R16). The binding is forgotten so that the next resolve reads the store. This
                // job's waiters for such an id are still answered `notFound` below (the residual of F-22 and F-31).
                self.forgetBound(ids)""",
"""                // An id bound during the await is left present: the store's guard skips a record bound to a live blob
                // at this identity (L4-R16). The binding is forgotten so that the next resolve reads the store. This
                // job's waiters for such an id are still answered `notFound` below (the residual of F-22 and F-31).
                self.state.commitTurnMarksForTests?(false)
                self.forgetBound(ids)""")
edit(E + 'EngineFailures.swift',
"""            self.resolveAll(transfer, with: .failed(.notFound))
            // REENTRANCY: RE-S40 — the lifecycle; the store entry of the heap is replaced.
            await self.refreshStoreDeadline()
        case .authentication:""",
"""            self.resolveAll(transfer, with: .failed(.notFound))
            self.state.commitTurnMarksForTests?(true)
            // REENTRANCY: RE-S40 — the lifecycle; the store entry of the heap is replaced.
            await self.refreshStoreDeadline()
        case .authentication:""")
edit(E + 'EngineCommands.swift',
"""        self.state.purgeEpoch += 1
        // The store clears the stamp before its first await of the purge (R-CLN-6).""",
"""        self.state.commitTurnMarksForTests?(false)
        self.state.purgeEpoch += 1
        // The store clears the stamp before its first await of the purge (R-CLN-6).""")
edit(E + 'EngineCommands.swift',
"""        self.withdrawPurged(request)
        // REENTRANCY: RE-S25 — nothing: the join registers synchronously; the result arrives by value.""",
"""        self.withdrawPurged(request)
        self.state.commitTurnMarksForTests?(true)
        // REENTRANCY: RE-S25 — nothing: the join registers synchronously; the result arrives by value.""")
edit(E + 'EngineCommands.swift',
"""        self.withdrawPurgedJoins(isPurged)
        for transfer in self.state.jobs.keys.sorted() {""",
"""        let probeStart = DispatchTime.now().uptimeNanoseconds
        self.withdrawPurgedJoins(isPurged)
        self.state.probeWalkNanos = DispatchTime.now().uptimeNanoseconds - probeStart
        for transfer in self.state.jobs.keys.sorted() {""")
edit(E + 'EngineCommands.swift', "    private func withdrawPurgedJoins(_ isPurged: (AssetID) -> Bool) {", "    func withdrawPurgedJoins(_ isPurged: (AssetID) -> Bool) {")
edit(E + 'EngineState.swift', "    var answersPerTurn = SyncEngine.answersPerTurn\n",
     "    var answersPerTurn = SyncEngine.answersPerTurn\n    /// PROBE-C21-PURGE-PARTS2: the last purge's walk of the waiting events, in nanoseconds.\n    var probeWalkNanos: UInt64 = 0\n")
edit(E + 'SubscriberQueue.swift',
"""    /// Stored order entries, stale ones included (the 2 × live + 16 bound).""",
"""    /// PROBE-C22-PUBLISH (scratch): d1's a1, one hash per terminal publish.
    mutating func probePublishA1(_ event: AssetEvent, sequence: UInt64) -> (handOff: CheckedContinuation<AssetEvent?, Never>?, coalesced: Bool) {
        guard !self.finished else {
            return (nil, false)
        }
        if case .clientShutDown = event {
            self.finished = true
        }
        if self.slots.isEmpty, let pending = self.pending {
            self.pending = nil
            return (pending, false)
        }
        let slot = EventSlot(event)
        if slot.isProgress, var live = self.slots[slot], !self.finished, !SubscriberQueue.isAnotherRun(event, than: live.event) {
            live.event = event
            self.slots[slot] = live
            return (nil, true)
        }
        let replaced = self.slots.updateValue(Live(sequence: sequence, event: event), forKey: slot) != nil
        self.peakLiveCount = max(self.peakLiveCount, self.slots.count)
        self.order.append((sequence, slot))
        self.compactIfNeeded()
        return (nil, replaced)
    }

    /// PROBE-C22-PUBLISH (scratch): a2's guarded reservation for `n` more slots.
    mutating func probeReserve(_ n: Int) {
        if self.slots.count + n > 2 * self.slots.capacity {
            self.slots.reserveCapacity(self.slots.count + n)
        }
    }

    /// PROBE-C22-PUBLISH (scratch): a3's publishAll (a2's reservation, then a1 per event).
    mutating func probePublishAll(_ events: some Collection<AssetEvent>, from first: UInt64) -> (handOff: (CheckedContinuation<AssetEvent?, Never>, AssetEvent)?, coalesced: Int) {
        self.probeReserve(events.count)
        var handOff: (CheckedContinuation<AssetEvent?, Never>, AssetEvent)?
        var coalesced = 0
        var sequence = first
        for event in events {
            let published = self.probePublishA1(event, sequence: sequence)
            sequence += 1
            coalesced += published.coalesced ? 1 : 0
            if let continuation = published.handOff {
                handOff = (continuation, event)
            }
        }
        return (handOff, coalesced)
    }

    /// Stored order entries, stale ones included (the 2 × live + 16 bound).""")
print('seams applied to', root)
