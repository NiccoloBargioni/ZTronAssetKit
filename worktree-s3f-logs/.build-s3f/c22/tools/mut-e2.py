# Cycle 22 step 4's kills (S3-R27 item 12.3's e2-A1 and e2-A2.5; MUT_EXTRA for .build-s3f/c22/tools/mut22s.py, MUT_SNAP a
# snapshot of the step's last commit): the job method's order, arms and moved conditions, the fast path, the walk's
# settle, the moved join and re-route conditions (b23's at their new lines), and A2.5's one pass.
PURGES = 'barrierPurge|purgeDropsGroupMembers|purgeDuringApply|purgeEndsRun|purgeWithdrawsOwedNonUserReroutesOfPurgedIDs|EnginePurgeWithdrawalTests|purgeMakesSyncDue|leaseSurvivesPurge'
OWNER = 'owedReroutesDecideA429sLane|purgeWithdrawsOwedNonUserReroutesOfPurgedIDs|cancelAndReleaseWhileReroutesAreOwed|shutdownMidwayThroughAnOwedBatch'
JOBS = '        for (token, interest) in self.interests.sorted(by: { $0.key < $1.key }) where interest.lane < .userInitiated && interest.kind != .waiter {'
JOIN = '            !join.withdrawn && join.lane < .userInitiated && join.kind != .waiter && isPurged(join.asset)'
ITEM = '            item.lane < .userInitiated && item.kind != .waiter && isPurged(item.asset)'
M = [
 ('e2-order-reversed', ST, JOBS, JOBS.replace('$0.key < $1.key', '$0.key > $1.key'), 'purgeRemovesInAscendingTokenOrder'),
 ('e2-fast-always', CO, '        let all = request == .all\n', '        let all = true\n', 'scopePurgeWithdrawsOnlyItsIDs'),
 ('e2-whole-never', ST, '            if withdrawn.count == interest.assets.count {', '            if withdrawn.count == interest.assets.count, withdrawn.count < 0 {', 'purgeDropsGroupMembers|' + PURGES),
 ('e2-partial-whole', ST, '            if withdrawn.count == interest.assets.count {', '            if withdrawn.count >= 0 {', 'scopePurgeWithdrawsOnlyItsIDs'),
 ('e2-prerelane-never', CO, '            if off.emptied, before != last {', '            if off.emptied, before != last, before == last {', 'purgeThatEmptiesAJobKeepsItsEarlierRelane'),
 ('e2-prerelane-no-emptied', CO, '            if off.emptied, before != last {', '            if before != last {', 'purgeThatLeavesInterestsRelanesOnce'),
 ('e2-prerelane-no-lanes', CO, '            if off.emptied, before != last {', '            if off.emptied {', PURGES),
 ('e2-run-held-kept', CO, """            if let run = self.state.run?.token, off.removed.contains(run) {
                self.state.run?.held.remove(transfer)
            }""", """            if let run = self.state.run?.token, off.removed.contains(run) {
                _ = run
            }""", PURGES),
 ('e2-job-no-lane', ST, JOBS, JOBS.replace('interest.lane < .userInitiated && ', ''), PURGES),
 ('e2-job-no-kind', ST, JOBS, JOBS.replace(' && interest.kind != .waiter', ''), PURGES),
 ('e2-join-no-withdrawn', CO, JOIN, JOIN.replace('!join.withdrawn && ', ''), PURGES),
 ('e2-join-no-lane', CO, JOIN, JOIN.replace('join.lane < .userInitiated && ', ''), PURGES),
 ('e2-join-no-kind', CO, JOIN, JOIN.replace('join.kind != .waiter && ', ''), PURGES),
 ('b23-no-lane-moved', CO, ITEM, ITEM.replace('item.lane < .userInitiated && ', ''), OWNER),
 ('b23-no-kind-moved', CO, ITEM, ITEM.replace('item.kind != .waiter && ', ''), OWNER),
 ('a25-no-pass', CO, '        self.state.heap.removeAll { retired.contains($0) }\n', '', 'purgeTakesItsRetiredJobsRetryDeadlinesOut'),
 ('a25-defer-outside', JO, '        if self.state.retiredRetries?.insert(retry) == nil {', '        if self.state.retiredRetries?.insert(retry) != nil {', 'purgeTakesItsRetiredJobsRetryDeadlinesOut'),
 ('a25-set-left', CO, '        self.state.retiredRetries = nil\n', '', 'purgeTakesItsRetiredJobsRetryDeadlinesOut'),
 ('a25-no-set', CO, '        self.state.retiredRetries = []\n', '', 'purgeTakesItsRetiredJobsRetryDeadlinesOut'),
]
