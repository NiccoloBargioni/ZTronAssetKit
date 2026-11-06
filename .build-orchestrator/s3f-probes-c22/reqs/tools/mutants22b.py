# The cycle-22 reqs verifier's second batch: S3-R27 item 12.2's e1-R1 kill table, which the fixer did not run.
E = 'Sources/ZTronAssetSync/Engine/'
DI, FO = (E + n for n in ('EngineDispatch.swift', 'EngineFollow.swift'))
TE = 'owedReroutePinnedToARequeuedJob'
PINEND = 'owedRerouteWhosePinCommittedJoinsTheNextPublishingJob|owedRerouteWhosePinCommittedFollowsTheCopyAtThatCommit|owedRerouteWhosePinCommittedFollowsTheAppliesAfterThatCommit|owedRerouteWhosePinCommittedEndsUnderTheCopyAtThatCommit|secondOwedBatchFollowsTheCommitOfItsPinAfterTheFirstBatch|invariantsReportCommitsKeptForOwedReroutes|shutdownForgetsTheCommitsKeptForOwedReroutes|owedReroutePinnedToACommittedJobFollowsTheCopy'
GUARD = """                    guard after < layers.count else {
                        return layer.outgoing
                    }
                    index = after + 1"""
ENOENT_COND = """                if !self.state.eventsAfterFollow.isEmpty, let epoch = self.state.jobs[transfer]?.epoch {
                    self.state.reroutePinCommits[VerdictKey(transfer: transfer, epoch: epoch)] = PinEnd(serial: self.state.copySerial, keepsEntry: true)"""
COMMIT_WRITE = """        // An owed re-route or a waiting join a layer pinned to this attempt follows the copy now (`followLayers`).
        if !self.state.eventsAfterFollow.isEmpty, let epoch = self.state.jobs[transfer]?.epoch {
            self.state.reroutePinCommits[VerdictKey(transfer: transfer, epoch: epoch)] = PinEnd(serial: self.state.copySerial, keepsEntry: false)"""
FOLD = """            return job.attemptEnd != nil ? job : nil
        case .queued, .blocked, .downloading:
            return nil"""
M = [
 ('v-e1r1-jump-always', FO, GUARD, GUARD.replace('guard after < layers.count else {', 'guard after < layers.count || true else {'), TE),
 ('v-e1r1-keep-always', FO, GUARD, GUARD.replace('guard after < layers.count else {', 'guard after < layers.count, after < 0 else {'), TE),
 ('v-e1r1-index-next', FO, GUARD, GUARD.replace('index = after + 1', 'index = after'), TE),
 ('v-e1r1-keepsentry-dropped', FO, '                if end.keepsEntry {', '                if end.keepsEntry && false {', TE),
 ('v-e1r1-no-walk-on', FO, GUARD, GUARD + '\n                    return index < layers.count ? layers[index].outgoing : self.state.applied', TE),
 ('v-e1r1-enoent-write-always', DI, ENOENT_COND, ENOENT_COND.replace('if !self.state.eventsAfterFollow.isEmpty, let epoch', 'if let epoch'), 'enoentAfterCancelIsTheCancellation'),
 ('v-e1r1-commit-literal-requeue', DI, COMMIT_WRITE, COMMIT_WRITE.replace('keepsEntry: false', 'keepsEntry: true'), PINEND + '|' + TE),
 ('v-i5-pin-fold', FO, FOLD, """            return job.attemptEnd != nil ? job : nil
        case .queued:
            return job
        case .blocked, .downloading:
            return nil""", TE),
]
