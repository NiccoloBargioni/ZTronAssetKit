# rr21-C3's mutants (MUT_EXTRA for mut21s.py, MUT_SNAP=.build-s3f/c21/snap-c3): one per branch of integrate-rr21.md's
# table that rr21-C3 lands (rr21-B1 to B4, B10 to B31), each with the tests that should kill it.
DI, PRE, CND, SDN, RUNS, FAI, JOBS = (E + n for n in ('EngineDispatch.swift', 'EnginePresence.swift', 'EngineConditions.swift', 'EngineShutdown.swift', 'EngineRuns.swift', 'EngineFailures.swift', 'EngineJobs.swift'))
T1 = 'commitOwesItsReroutesAndTheDrainMakesThemBounded|owedBatchEndingAtTheTurnsLastIDEndsInThatTurn|twoCommitsOweABatchEach|commitOwesWhenItsAnswersAndReroutesPassTheBound|commitReroutesAtOnceWhenItFits|commitWithNothingToRerouteOwesNothing|drainReroutesAnOwedIDWithAllItsTokensInOneTurn'
CAP = 'commitHoldsTheFreshJobOfARefusedIDOnTheFitPath|commitHoldsTheFreshJobOfRefusedIDsOnTheOwingPath|commitHoldsNothingForIDsMovedAway|commitHoldsNothingForAnIDTheBindingDidNotCapture|commitKeepsATokensBoundIDAndReroutesItsUnboundOne'
HOLD = 'publicationWaitsForOwedReroutesAndBindsTheirIDs|publicationHeldByTwoBatchesWaitsForTheLast|owedBatchesReplayInTheirOrderAroundAVerdict|publicationDuringTheWindowBindsTheOwedIDsBehindAClosedGate'
INV = 'invariantsReportOwedReroutesOutOfPlace'
LAYER = 'owedRerouteOfADroppedIDEndsItsInterest|owedReroutePinnedToAPublishingJobGetsItsIntegrityFailure|owedReroutePinnedToAPublishingJobGetsItsStorageFailure|owedReroutePinnedToAWaitingVerdictGetsIt|verdictAheadOfAnOwedBatchPinsNothing|owedReroutePinnedToACommittedJobFollowsTheCopy|owedRerouteFollowsTwoHopsToAPublishingJob|owedRerouteEndsAtALaterDrop|verdictBeforeTheMoveOntoItsJobPinsNothingAtTheNextApply|owedReroutePinnedToARequeuedJobFollowsTheCopy'
OWNER = 'owedReroutesDecideA429sLane|purgeWithdrawsOwedNonUserReroutesOfPurgedIDs|cancelAndReleaseWhileReroutesAreOwed|shutdownMidwayThroughAnOwedBatch'
RUNT = 'owedRunClaimsSettleTheRunAfterTheReplay|runSettlesOnlyAfterTheOwedBatchItsVerdictDrainsWith'
PRES = 'owedReroutesOntoAPresentContentAreServedFromTheStore|watcherKeepsTheConditionsWhileReroutesAreOwed'
HEAL = 'healOfAnOwedT21SystemInterest'
ALL = '|'.join((T1, CAP, HOLD, INV, LAYER, OWNER, RUNT, PRES, HEAL))
M = [
 # Site 1 (`committed`): rr21-B1 to B4.
 ('b1-owe-empty', DI, 'if rerouted > 0, locations.count + rerouted > self.inboundIDsNow {', 'if locations.count + rerouted > self.inboundIDsNow {', T1),
 ('b2-drop-locations', DI, 'if rerouted > 0, locations.count + rerouted > self.inboundIDsNow {', 'if rerouted > 0, rerouted > self.inboundIDsNow {', T1),
 ('b2-ge', DI, 'if rerouted > 0, locations.count + rerouted > self.inboundIDsNow {', 'if rerouted > 0, locations.count + rerouted >= self.inboundIDsNow {', T1),
 ('b2-always-owe', DI, 'if rerouted > 0, locations.count + rerouted > self.inboundIDsNow {', 'if rerouted > 0 {', T1),
 ('b2-never-owe', DI, 'if rerouted > 0, locations.count + rerouted > self.inboundIDsNow {', 'if rerouted > 0, rerouted < 0 {', T1),
 ('b3-never-refused', DI, 'if !refused, captured.contains(asset) {', 'if !refused, captured.contains(asset), captured.isEmpty {', CAP),
 ('b4-owing-no-hold', DI, '''                if refused {
                    self.holdForManifest(transfer)
                }
                self.deferReroutes(moved + deferred, from: transfer)''', '''                self.deferReroutes(moved + deferred, from: transfer)''', CAP),
 # The replay (`continueReroutes`, `releaseRerouteHolds`, the arm, the put-back): rr21-B10 to B15.
 ('b10-per-item', FO, '            if item.asset != current {\n                guard spent < self.state.drainIDsLeft else {', '            if item.asset != current || true {\n                guard spent < self.state.drainIDsLeft else {', T1),
 ('b11-no-bound', FO, '''                guard spent < self.state.drainIDsLeft else {
                    break
                }
                spent += 1''', '''                spent += 1''', T1),
 ('b12-no-countdown', FO, '''        if batch.items.isEmpty {
            self.state.reroutesWaiting -= 1''', '''        if batch.items.isEmpty, batch.items.count < 0 {
            self.state.reroutesWaiting -= 1''', T1 + '|' + HOLD + '|shutdownMidwayThroughAnOwedBatch'),
 ('b12-no-release', FO, '''            self.state.reroutesWaiting -= 1
            self.releaseRerouteHolds()''', '''            self.state.reroutesWaiting -= 1''', HOLD),
 ('b13-no-guard', FO, '''    private func releaseRerouteHolds() {
        guard self.state.reroutesWaiting == 0 else {
            return
        }''', '''    private func releaseRerouteHolds() {''', HOLD),
 ('b14-always-nil', FO, 'return batch.items.isEmpty ? nil : .reroutes(batch)', 'return nil', T1),
 ('b14-always-returned', FO, 'return batch.items.isEmpty ? nil : .reroutes(batch)', 'return .reroutes(batch)', T1),
 ('b15-no-owed-prefix', FO, 'let rest: [(EventAfterFollow, WorldStamp)] = (owed.map { [($0, stamp)] } ?? []) + batch[(offset + 1)...]', 'let rest: [(EventAfterFollow, WorldStamp)] = Array(batch[(offset + 1)...])', T1),
 # `rerouteListing`: rr21-B16 to B19.
 ('b16-t21-follows-now', FO, '''        guard var entry = batch.copy.entry(for: asset) else {
            return batch.copy
        }''', '''        guard var entry = batch.copy.entry(for: asset) else {
            return nil
        }''', LAYER),
 ('b17-pin-always', FO, 'return self.waitingTarget(entry.transferID, epoch: epoch) != nil ? layer.outgoing : nil', 'return layer.outgoing', LAYER),
 ('b17-pin-never', FO, 'return self.waitingTarget(entry.transferID, epoch: epoch) != nil ? layer.outgoing : nil', 'return nil', LAYER),
 ('b17-no-ends', FO, 'if let epoch = layer.ends[entry.transferID] {', 'if let epoch = layer.ends[entry.transferID], epoch == UInt64.max {', LAYER),
 ('b18-dropped-follows-now', FO, '''            guard let next = incoming.entry(for: asset) else {
                return incoming
            }''', '''            guard let next = incoming.entry(for: asset) else {
                return nil
            }''', LAYER),
 ('b19-incoming-applied', FO, 'let incoming = index + 1 < batch.layers.count ? batch.layers[index + 1].outgoing : self.state.applied', 'let incoming = self.state.applied', LAYER),
 # The layer append (`layerOwedReroutes`, its call in `adoptApplied`): rr21-B20.
 ('b20-no-publishing', FO, 'let inFlight = publishing ?? self.publishingEnds()', 'let inFlight = publishing ?? [:]', LAYER),
 ('b20-no-verdicts', FO, 'for verdict in verdicts where previous.map({ verdict.deferredAfter > $0 }) ?? true {', 'for verdict in verdicts where verdicts.isEmpty {', LAYER),
 ('b20-ge', FO, 'for verdict in verdicts where previous.map({ verdict.deferredAfter > $0 }) ?? true {', 'for verdict in verdicts where previous.map({ verdict.deferredAfter >= $0 }) ?? true {', LAYER),
 ('b20-every-layer', FO, 'for verdict in verdicts where previous.map({ verdict.deferredAfter > $0 }) ?? true {', 'for verdict in verdicts {', LAYER),
 ('b20-verdicts-ahead', FO, 'for index in self.state.eventsAfterFollow.indices.reversed() {\n            let event = self.state.eventsAfterFollow[index]\n            if let key = event.verdictKey {', 'for index in self.state.eventsAfterFollow.indices {\n            let event = self.state.eventsAfterFollow[index]\n            if let key = event.verdictKey {', LAYER),
 ('b20-no-layer-call', JOBS, '        self.layerOwedReroutes()\n', '', LAYER + '|' + INV),
 # The idle guards and the hold: rr21-B21, B24, B25, B26.
 ('b21-no-hold-term', FO, 'if self.state.followMoving?.holder == transfer || self.state.reroutesWaiting > 0 {', 'if self.state.followMoving?.holder == transfer {', HOLD),
 ('b24-no-prune-guard', PRE, 'self.state.presenceReaders == 0, self.state.eventsAfterFollow.isEmpty else {', 'self.state.presenceReaders == 0 else {', PRES),
 ('b25-no-work-disjunct', CND, '!self.state.conditionWaiters.isEmpty || !self.state.eventsAfterFollow.isEmpty', '!self.state.conditionWaiters.isEmpty', PRES),
 ('b26-no-run-guard', RUNS, '!self.state.runClaimTakenOff, self.state.reroutesWaiting == 0 else {', '!self.state.runClaimTakenOff else {', RUNT),
 # `oweReroutes`, `deferReroutes`, `drainEverything`: rr21-B27 to B29.
 ('b27-no-run-release', FO, 'self.state.run?.outstanding[transfer]?.subtract(items.lazy.filter { $0.kind == .run && $0.token == run }.map(\\.asset))', '_ = run', RUNT),
 ('b27-no-nil-write', FO, '''        if self.state.run?.outstanding[transfer]?.isEmpty == true {
            self.state.run?.outstanding[transfer] = nil
        }''', '', RUNT),
 ('b28-no-schedule', FO, '''        self.deferToFollow(.reroutes(self.oweReroutes(items, from: transfer)))
        self.scheduleDrainFollowUp()''', '''        self.deferToFollow(.reroutes(self.oweReroutes(items, from: transfer)))''', T1),
 ('b29-no-zeroing', SDN, '        self.state.reroutesWaiting = 0\n', '', 'shutdownMidwayThroughAnOwedBatch'),
 # `waitingTarget`'s `.queued` arm (rr21-B30, the pin caller).
 ('b30-queued-pins', FO, '''            return job.attemptEnd != nil ? job : nil
        case .queued, .blocked, .downloading:
            return nil''', '''            return job.attemptEnd != nil ? job : nil
        case .queued:
            return job
        case .blocked, .downloading:
            return nil''', LAYER),
 # `followedLane`'s arm (rr21-B22).
 ('b22-no-withdrawn', FAI, '''            guard !withdrawn.contains(item.token) else {
                return false
            }''', '', OWNER),
 ('b22-no-waiter-owner', FAI, 'guard let waiter = self.state.waiters[item.token], !waiter.fromStore, waiter.asset == item.asset, waiter.transfer == batch.from else {', 'guard self.state.waiters[item.token] != nil || true else {', OWNER),
 ('b22-no-group-owner', FAI, 'guard self.state.groups[item.token]?.pending[item.asset] == batch.from else {', 'guard self.state.groups[item.token] != nil || true else {', OWNER),
 ('b22-no-run-owner', FAI, '''            case .run:
                guard self.state.run?.token == item.token else {
                    return false
                }''', '''            case .run:
                break''', OWNER + '|' + RUNT),
 ('b22-no-bound-skip', FAI, 'guard let entry = (self.rerouteListing(item.asset, batch) ?? copy).entry(for: item.asset), !self.isBound(item.asset, to: entry.transferID) else {', 'guard let entry = (self.rerouteListing(item.asset, batch) ?? copy).entry(for: item.asset) else {', OWNER),
 ('b22-no-listing', FAI, 'guard let entry = (self.rerouteListing(item.asset, batch) ?? copy).entry(for: item.asset), !self.isBound', 'guard let entry = copy.entry(for: item.asset), !self.isBound', OWNER),
 ('b22-no-arm', FAI, 'for item in batch.items.elements where reaches(item, batch) {', 'for item in batch.items.elements where reaches(item, batch) && batch.items.isEmpty {', OWNER),
 ('b22-arm-no-early-return', FAI, '''                        raise(item.lane)
                        if lane == .userInitiated {
                            return .userInitiated
                        }''', '''                        raise(item.lane)''', OWNER),
 # The purge arm (`withdrawPurgedJoins`, rr21-B23).
 ('b23-no-lane', CO, 'batch.items.removeAll { $0.lane < .userInitiated && $0.kind != .waiter && isPurged($0.asset) }', 'batch.items.removeAll { $0.kind != .waiter && isPurged($0.asset) }', OWNER),
 ('b23-no-kind', CO, 'batch.items.removeAll { $0.lane < .userInitiated && $0.kind != .waiter && isPurged($0.asset) }', 'batch.items.removeAll { $0.lane < .userInitiated && isPurged($0.asset) }', OWNER),
 ('b23-no-purged', CO, 'batch.items.removeAll { $0.lane < .userInitiated && $0.kind != .waiter && isPurged($0.asset) }', 'batch.items.removeAll { $0.lane < .userInitiated && $0.kind != .waiter }', OWNER),
 ('b23-no-group-drop', CO, '                        self.dropGroupMember(item.token, asset: item.asset, from: batch.from)\n', '                        _ = item\n', OWNER),
 ('b23-no-heal-forget', CO, '                        self.state.heals[item.asset] = nil\n', '                        _ = item\n', OWNER),
 ('b23-no-writeback', CO, '''                self.state.eventsAfterFollow[index] = .reroutes(batch)
                continue''', '''                continue''', OWNER),
 # The invariant's acceptances and clauses (rr21-B31).
 ('b31-no-waiter-acceptance', CO, 'if self.state.joinsAfterFollow[token]?[waiter.asset] != waiter.transfer, owed[MoveItem(asset: waiter.asset, token: token)] != waiter.transfer {', 'if self.state.joinsAfterFollow[token]?[waiter.asset] != waiter.transfer {', T1 + '|' + INV),
 ('b31-no-group-acceptance', CO, 'if self.state.joinsAfterFollow[token]?[asset] != transfer, owed[MoveItem(asset: asset, token: token)] != transfer {', 'if self.state.joinsAfterFollow[token]?[asset] != transfer {', 'drainReroutesAnOwedIDWithAllItsTokensInOneTurn|' + INV + '|' + OWNER),
 ('b31-no-waiter-clause', CO, 'if let waiter = self.state.waiters[item.token], waiter.fromStore || waiter.asset != item.asset || waiter.transfer != transfer {', 'if let waiter = self.state.waiters[item.token], waiter.fromStore, !waiter.fromStore {', INV),
 ('b31-no-group-clause', CO, 'if let group = self.state.groups[item.token], group.pending[item.asset] != transfer {', 'if let group = self.state.groups[item.token], group.pending[item.asset] != transfer, group.pending.isEmpty, !group.pending.isEmpty {', INV),
 ('b31-no-run-clause', CO, 'if self.state.run?.token == item.token, self.state.run?.outstanding[transfer]?.contains(item.asset) == true {', 'if self.state.run?.token == item.token, self.state.run?.outstanding[transfer]?.contains(item.asset) == true, item.asset.rawValue.isEmpty {', INV + '|' + RUNT),
 ('b31-no-held-clause', CO, 'if self.state.jobs[transfer]?.interests[item.token]?.assets.contains(item.asset) == true {', 'if self.state.jobs[transfer]?.interests[item.token]?.assets.contains(item.asset) == true, item.asset.rawValue.isEmpty {', INV),
 ('b31-no-join-clause', CO, 'if let join = self.state.joinsAfterFollow[item.token]?[item.asset] {', 'if let join = self.state.joinsAfterFollow[item.token]?[item.asset], item.asset.rawValue.isEmpty {', INV),
 ('b31-no-layers-clause', CO, 'if UInt64(batch.layers.count) != self.state.copySerial &- batch.serial {', 'if UInt64(batch.layers.count) != self.state.copySerial &- batch.serial, batch.layers.count < 0 {', INV),
 ('b31-no-twice-clause', CO, 'for (pair, count) in owedCounts.sorted(by: { $0.key < $1.key }) where count > 1 {', 'for (pair, count) in owedCounts.sorted(by: { $0.key < $1.key }) where count > 1 && count < 0 {', INV),
 ('b31-no-counter-clause', CO, 'if self.state.reroutesWaiting != batches {', 'if self.state.reroutesWaiting != batches, batches < 0 {', INV),
]
