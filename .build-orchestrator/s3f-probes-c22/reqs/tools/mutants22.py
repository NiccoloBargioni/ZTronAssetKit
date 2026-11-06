# The cycle-22 reqs verifier's mutants: each re-applies an original defect or a fix's drop at HEAD 9aa337c.
E = 'Sources/ZTronAssetSync/Engine/'
DI, FO, CO, JO, ST, SD, SQ = (E + n for n in ('EngineDispatch.swift', 'EngineFollow.swift', 'EngineCommands.swift', 'EngineJobs.swift', 'EngineState.swift', 'EngineShutdown.swift', 'SubscriberQueue.swift'))
TE = 'owedReroutePinnedToARequeuedJob'
PS = 'owedReroutePinnedToASupersededJob'
P1 = 'owedReroutePinnedToAJobInItsSpaceReadGetsItsVerdict|userJoinFromJustBeforeAnENOSPCReplayedInItsReadGetsItsVerdict|userJoinFromInsideAnENOSPCsReadSkipsItsVerdict'
P2 = 'afterVerdictVisitInsideAnENOSPCsReadGetsItsVerdict|afterVerdictVisitForAnApplyInsideAnENOSPCsReadSkipsItsVerdict'
OWNER = 'owedReroutesDecideA429sLane|purgeWithdrawsOwedNonUserReroutesOfPurgedIDs|cancelAndReleaseWhileReroutesAreOwed|shutdownMidwayThroughAnOwedBatch'
ENOENT_WRITE = """                if !self.state.eventsAfterFollow.isEmpty, let epoch = self.state.jobs[transfer]?.epoch {
                    self.state.reroutePinCommits[VerdictKey(transfer: transfer, epoch: epoch)] = PinEnd(serial: self.state.copySerial, keepsEntry: true)
                }
"""
SUPERSEDE_WRITE = """            if !self.state.eventsAfterFollow.isEmpty {
                self.state.reroutePinCommits[VerdictKey(transfer: transfer, epoch: epoch)] = PinEnd(serial: self.state.copySerial, keepsEntry: false)
            }
            self.transition(transfer, to: .queued)
            self.supersede(transfer, bound: self.inboundIDsNow)"""
P1_RULE = """        guard let reading = self.state.reading, let stamped = job.attemptEnd?.stamped else {
            return false
        }
        return reading.serial <= stamped"""
SLICE = """        for answer in owed {
            answer.resume()
            steps += 1
            if steps == SyncEngine.shutdownStepsPerTurn {"""
ITEM = 'item.lane < .userInitiated && item.kind != .waiter && isPurged(item.asset)'
JOBS = 'for (token, interest) in self.interests.sorted(by: { $0.key < $1.key }) where interest.lane < .userInitiated && interest.kind != .waiter {'
JOIN = '!join.withdrawn && join.lane < .userInitiated && join.kind != .waiter && isPurged(join.asset)'
CLASSIFY = 'if !(self.state.applied.entry(for: asset).map({ SyncEngine.sameTransfer($0, jobEntry) }) ?? false) {'
M = [
 # correct #1 (e1-R1): the ENOENT arm keeps no record, as on d5b2ab9
 ('v-e1r1-no-enoent-record', DI, ENOENT_WRITE, '', TE),
 # e1-R1's jump replaced by d5b2ab9's answer
 ('v-e1r1-kept-returns-nil', FO, 'index = after + 1', 'return nil', TE),
 # e1-PS: the superseded arm keeps no record (b4eebb1 reverted)
 ('v-e1ps-no-supersede-record', DI, SUPERSEDE_WRITE, """            self.transition(transfer, to: .queued)
            self.supersede(transfer, bound: self.inboundIDsNow)""", PS),
 # e1-P1: outside a visit the rule is false again (58e2c1c reverted in effect)
 ('v-e1p1-rule-false', JO, P1_RULE, '        return false', P1),
 # e1-P2: the visit after a verdict is dated by the replay's instant (75b9e45 reverted in effect)
 ('v-e1p2-no-after-verdict', JO, 'if self.state.inFollowVisit || self.state.visitingAfterVerdict {', 'if self.state.inFollowVisit {', P2),
 # b23 at its HEAD line (after e2-A1.2)
 ('v-b23-no-lane', CO, ITEM, ITEM.replace('item.lane < .userInitiated && ', ''), OWNER),
 ('v-b23-no-kind', CO, ITEM, ITEM.replace('item.kind != .waiter && ', ''), OWNER),
 # f7
 ('v-f7-delisted-stays', DI, CLASSIFY, CLASSIFY.replace('?? false) {', '?? true) {'), 'commitHoldsNothingForADelistedIDWhileAnApplyIsInFlight'),
 # settle's owed-answer slice (item 6)
 ('v-settle-slice-off', SD, SLICE, SLICE.replace('if steps == SyncEngine.shutdownStepsPerTurn {', 'if steps == SyncEngine.shutdownStepsPerTurn, steps < 0 {'), 'shutdownAnswersTheOwedCallersWithTheCommitsAnswers'),
 # replayVerdict's removal: the epoch clause dropped
 ('v-vr-epoch-off', CO, '        if !elsewhere.isEmpty {', '        if !elsewhere.isEmpty, elsewhere.count < 0 {', 'invariantsReportAWaitingVerdictsJobOutOfStateOrEpoch'),
 # item 1
 ('v-a1-replaced-false', SQ, '        return (nil, replaced)\n', '        return (nil, false)\n', 'terminalPublishReportsAMoveAndMovesToTheTail'),
 ('v-a3-coalesced-never', SQ, 'coalesced += published.coalesced ? 1 : 0', 'coalesced += published.coalesced ? 0 : 0', 'commitBatchReachesAWaitingAndAStalledSubscriber'),
 ('v-c3-allbound-true', JO, 'let allBound = locations.count == ascending.count', 'let allBound = true', 'commitAnnouncesItsBoundIDsInAscendingOrder'),
 # e2 (12.3)
 ('v-e2-order-reversed', ST, JOBS, JOBS.replace('$0.key < $1.key', '$0.key > $1.key'), 'purgeRemovesInAscendingTokenOrder'),
 ('v-e2-job-no-lane', ST, JOBS, JOBS.replace('interest.lane < .userInitiated && ', ''), 'purgeKeepsUserLaneAndWaiterInterests'),
 ('v-e2-join-no-kind', CO, JOIN, JOIN.replace('join.kind != .waiter && ', ''), 'purgeKeepsUserLaneAndWaiterInterests'),
 ('v-e2-fast-always', CO, '        let all = request == .all\n', '        let all = true\n', 'scopePurgeWithdrawsOnlyItsIDs'),
]
