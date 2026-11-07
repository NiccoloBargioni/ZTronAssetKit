# Cycle 23, step 6 (S3-R28 item 4; run 12's order, first part): the kills of e1-PS's, e1-P1's and e1-P2's fixes (S3-R27
# 12.5.4) and e1-R1's kill table (12.2), on the code as it stands (item 1c freezes it). MUT_EXTRA for mut23s.py, which runs
# each on a snapshot of the commit named by MUT_SNAP. Specs from the cycle-22 verifier's mutants22.py and mutants22b.py
# where they exist (reqs #3), the rest written here.
DI, FO, JO, CO = (E + n for n in ('EngineDispatch.swift', 'EngineFollow.swift', 'EngineJobs.swift', 'EngineCommands.swift'))
TE = 'owedReroutePinnedToARequeuedJob'
PS = 'owedReroutePinnedToASupersededJob'
P1 = 'owedReroutePinnedToAJobInItsSpaceReadGetsItsVerdict|userJoinFromJustBeforeAnENOSPCReplayedInItsReadGetsItsVerdict|userJoinFromInsideAnENOSPCsReadSkipsItsVerdict'
P2 = 'afterVerdictVisitInsideAnENOSPCsReadGetsItsVerdict|afterVerdictVisitForAnApplyInsideAnENOSPCsReadSkipsItsVerdict'
PIN = 'owedRerouteWhosePinCommitted|secondOwedBatchFollowsTheCommitOfItsPin|CommitsKeptForOwedReroutes'
SUPERSEDE_IF = """            if !self.state.eventsAfterFollow.isEmpty {
                self.state.reroutePinCommits[VerdictKey(transfer: transfer, epoch: epoch)] = PinEnd(serial: self.state.copySerial, keepsEntry: false)
            }
            self.transition(transfer, to: .queued)
            self.supersede(transfer, bound: self.inboundIDsNow)"""
ENOENT_WRITE = """                if !self.state.eventsAfterFollow.isEmpty, let epoch = self.state.jobs[transfer]?.epoch {
                    self.state.reroutePinCommits[VerdictKey(transfer: transfer, epoch: epoch)] = PinEnd(serial: self.state.copySerial, keepsEntry: true)
                }
"""
COMMIT_WRITE = """        if !self.state.eventsAfterFollow.isEmpty, let epoch = self.state.jobs[transfer]?.epoch {
            self.state.reroutePinCommits[VerdictKey(transfer: transfer, epoch: epoch)] = PinEnd(serial: self.state.copySerial, keepsEntry: false)"""
P1_RULE = """        guard let reading = self.state.reading, let stamped = job.attemptEnd?.stamped else {
            return false
        }
        return reading.serial <= stamped"""
VISIT = '        if self.state.inFollowVisit || self.state.visitingAfterVerdict {\n'
GUARD = """                    guard after < layers.count else {
                        return layer.outgoing
                    }
                    index = after + 1"""
FOLD = """            return job.attemptEnd != nil ? job : nil
        case .queued, .blocked, .downloading:
            return nil"""
M = [
 # e1-PS (b4eebb1): the commit-shaped record at the .superseded arm.
 ('ps-write-dropped', DI, SUPERSEDE_IF, """            self.transition(transfer, to: .queued)
            self.supersede(transfer, bound: self.inboundIDsNow)""", PS),
 ('ps-write-always', DI, SUPERSEDE_IF, SUPERSEDE_IF.replace('            if !self.state.eventsAfterFollow.isEmpty {', '            if true {'), PS + '|Supersed|supersed'),
 ('ps-literal-requeue', DI, SUPERSEDE_IF, SUPERSEDE_IF.replace('keepsEntry: false', 'keepsEntry: true'), PS),
 # e1-P1 (b83112c, 58e2c1c): the replay branch of metInItsAttempt and the end's count.
 ('p1-rule-false', JO, P1_RULE, '        return false', P1),
 ('p1-rule-true', JO, P1_RULE, '        return self.state.reading != nil', P1),
 ('p1-le-as-lt', JO, 'return reading.serial <= stamped', 'return reading.serial < stamped', P1),
 ('p1-count-not-kept', FO, 'let end = AttemptEnd(failedAfter: self.state.appliesFollowed, deferredAfter: nil, stamped: self.state.stampsMinted)', 'let end = AttemptEnd(failedAfter: self.state.appliesFollowed, deferredAfter: nil, stamped: nil)', P1),
 # e1-P2 (75b9e45): the drain's visit after a verdict, dated by the applies.
 ('p2-after-verdict-never', JO, VISIT, '        if self.state.visitingAfterVerdict {\n            return false\n        }\n        if self.state.inFollowVisit {\n', P2),
 ('p2-after-verdict-replay-rule', JO, VISIT, '        if self.state.inFollowVisit {\n', P2),
 ('p2-after-verdict-true', JO, VISIT, '        if self.state.visitingAfterVerdict {\n            return true\n        }\n        if self.state.inFollowVisit {\n', P2),
 # e1-R1's kill table (S3-R27 item 12.2; `next` is the code's `after`).
 ('r1-enoent-write-dropped', DI, ENOENT_WRITE, '', TE),
 ('r1-enoent-write-always', DI, ENOENT_WRITE, ENOENT_WRITE.replace('if !self.state.eventsAfterFollow.isEmpty, let epoch', 'if let epoch'), 'enoentAfterCancelIsTheCancellation'),
 ('r1-keepsentry-dropped', FO, '                if end.keepsEntry {', '                if end.keepsEntry && false {', TE),
 ('r1-jump-always', FO, GUARD, GUARD.replace('guard after < layers.count else {', 'guard after < layers.count || true else {'), TE),
 ('r1-keep-always', FO, GUARD, GUARD.replace('guard after < layers.count else {', 'guard after < layers.count, after < 0 else {'), TE),
 ('r1-index-next', FO, GUARD, GUARD.replace('index = after + 1', 'index = after'), TE),
 ('r1-kept-returns-nil', FO, GUARD, GUARD.replace('index = after + 1', 'return nil'), TE),
 ('r1-no-walk-on', FO, GUARD, GUARD + '\n                    return index < layers.count ? layers[index].outgoing : self.state.applied', TE),
 ('r1-keyed-on-state', FO, '                if end.keepsEntry {', '                if self.state.jobs[entry.transferID]?.state == .queued {', TE),
 ('r1-commit-literal-requeue', DI, COMMIT_WRITE, COMMIT_WRITE.replace('keepsEntry: false', 'keepsEntry: true'), PIN + '|' + TE),
 ('i5-pin-fold', FO, FOLD, FOLD.replace('        case .queued, .blocked, .downloading:\n            return nil', '        case .queued:\n            return job\n        case .blocked, .downloading:\n            return nil'), TE),
]
