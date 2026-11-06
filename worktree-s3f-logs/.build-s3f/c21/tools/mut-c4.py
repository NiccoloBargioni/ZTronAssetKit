# Candidate 4's and K4's mutants (MUT_EXTRA for mut21.py): replaces M.
C4 = 'EngineFollowBarrierTests/barrierJoinsTheVisitAfterAVerdictAsVisitedFirst'
K4T = 'EngineFollowBarrierTests/invariantsReportAnEventWaitingOnceShutDown'
SPACE = 'EngineFollowBarrierTests/barrierJoinsTheJoinsBehindASpaceVerdictToItsRetry'
M = [
 ('c4-drop-flag', FO, '        self.state.visitingAfterVerdict = true\n        defer {', '        self.state.visitingAfterVerdict = false\n        defer {', C4),
 ('c4-guard-drop', JO, 'if self.state.inFollowVisit || self.state.visitingAfterVerdict, let waiting', 'if self.state.inFollowVisit, let waiting', C4),
 ('c4-copy-always-waits', JO, '            return !(end.copy?.entry(for: asset).map { SyncEngine.sameTransfer($0, entry) } ?? false)', '            return true', C4),
 ('c4-copy-never-waits', JO, '            return !(end.copy?.entry(for: asset).map { SyncEngine.sameTransfer($0, entry) } ?? false)', '            return false', C4),
 ('c4-copy-record-drop', FO, 'movedBefore: movedBefore, copy: self.state.applied)', 'movedBefore: movedBefore)', C4),
 ('c4-remainder-flag-drop', FO, '        self.state.visitingAfterVerdict = rest.afterVerdict', '        self.state.visitingAfterVerdict = false', C4),
 ('c4-drop-post-replay', FO, '                batch.insert(contentsOf: behind.reversed().map { (EventAfterFollow.join($0.join), $0.stamp) }, at: offset + 1)', '                _ = behind', C4),
 ('c4-post-replay-arrival-order', FO, '                batch.insert(contentsOf: behind.reversed().map { (EventAfterFollow.join($0.join), $0.stamp) }, at: offset + 1)', '                batch.insert(contentsOf: behind.map { (EventAfterFollow.join($0.join), $0.stamp) }, at: offset + 1)', C4),
 ('a-drop-space-arm-t1space', FO, """        case .spaceFailure(let transfer, let epoch, _):
            return VerdictKey(transfer: transfer, epoch: epoch)""", """        case .spaceFailure:
            return nil""", SPACE),
 ('k4-drop', CO, '        if !self.isRunning, !events.isEmpty {', '        if !self.isRunning, !events.isEmpty, events.isEmpty {', K4T),
]
