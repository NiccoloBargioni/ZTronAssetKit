import subprocess, sys, os, json
W = '/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f'
SRC = W + '/.build-s3f/mutsrc'
LOG = W + '/.build-s3f/c16/mut'
BUILD = W + '/.build-s3f/mutbuild'
F = 'Sources/ZTronAssetSync/Engine/EngineFollow.swift'
X = 'Sources/ZTronAssetSync/Engine/EngineFailures.swift'
D = 'Sources/ZTronAssetSync/Engine/EngineDispatch.swift'
LANE = 'barrierDecidesA429OnTheLaneAWaitingVerdictLeaves'
M = [
 ('consumeDrop', F, '        let reroute = self.rerouteOnVisit(job)\n        if reroute != nil {\n            self.state.jobs[transfer]?.rerouteOnPass = []\n        }\n', '        let reroute = self.rerouteOnVisit(job)\n', 'barrierSpendsTheRerouteForTheSameFollowsLaterVisits'),
 ('followGenerationDrop', F, 'let reroute = job.rerouteFor == self.state.followsEnded ? job.rerouteOnPass ?? [] : []', 'let reroute = job.rerouteOnPass ?? []', 'barrierSpendsTheRerouteOfAVisitThatFindsNothingMoved'),
 ('failedNeverPasses', F, '            guard let end = job.attemptEnd else {', '            guard let end = job.attemptEnd, Bool(\"false\") == true else {', 'barrierAnswersAnIdALaterApplyMoved|barrierPassesAPublicationFailingInItsBookkeeping|barrierLeavesAPassedIdToAPublicationsSpaceRetry'),
 ('inWindowCheckDrop', F, '            if end.deferredAfter == nil, self.state.appliesFollowed != end.failedAfter {\n                return nil\n            }\n', '', 'barrierMovesTheIdsOfAnApplyInsideAPublicationFailure'),
 ('verdictRerouteAlways', F, '        if job.attemptEnd?.failedAfter != applies {', '        if Bool(\"true\") == true {', 'barrierPassesAPublicationFailingInItsBookkeeping|barrierLeavesAPassedIdToAPublicationsSpaceRetry'),
 ('verdictRerouteNever', F, '        if job.attemptEnd?.failedAfter != applies {', '        if Bool(\"false\") == true {', 'barrierVisitsARetryThatFailsBeforeItsVisitAsADownload|barrierSupersedesAFailedJob'),
 ('publicationEndDrop', D, '        self.recordPublicationEnd(transfer)\n', '', 'barrierPassesAPublicationFailingInItsBookkeeping|barrierLeavesAPassedIdToAPublicationsSpaceRetry'),
 ('spaceDeferralRecordDrop', X, '            self.recordDeferredVerdict(transfer)\n            self.deferToFollow(.spaceFailure', '            self.deferToFollow(.spaceFailure', 'barrierAnswersAnIdALaterApplyMovedWithAWaitingSpaceVerdict'),
 ('followAfterVerdictDrop', F, '        guard moves, self.state.jobs[transfer]?.epoch == epoch else {', '        guard Bool(\"false\") == true, moves, self.state.jobs[transfer]?.epoch == epoch else {', 'barrierMovesALaterApplysIdFromAJobItsWaitingRetryLeft'),
 ('movesAfterVerdictInclusive', F, '{ self.state.appliesFollowed > $0 }', '{ self.state.appliesFollowed >= $0 }', 'barrierLeavesAPassedIdToAPublicationsSpaceRetry|barrierAnswersAPassedJobsRetry|barrierVisitsARetryThatFailsBeforeItsVisitAsADownload|barrierDecidesA429OnTheLaneAWaitingVerdictLeaves'),
 ('supersedeFailedDrop', F, '        if moved.count == job.assets.count, job.state != .verifying, job.state != .committing {', '        if reroute == nil, moved.count == job.assets.count {', 'barrierSupersedesAFailedJob'),
 ('laneAfterVerdictDrop', X, '                        return after.map { !self.verdictAnswers($0, interest, of: other) } ?? false', '                        return false', LANE),
 ('answersResolveFalse', X, '        case .attempt(.resolve):\n            return true', '        case .attempt(.resolve):\n            return false', LANE),
 ('answersThrottleFalse', X, '            return facts.decision == .exhausted', '            return false', LANE),
 ('answersRetryFalse', X, '            return job.attempts + 1 >= max(1, policy.maxAttemptsPerRun)', '            return false', LANE),
 ('answersRetryOwnPolicy', X, '            let policy = interest.lane == .userInitiated ? self.tuning.interactiveRetry : self.tuning.retry', '            let policy = self.tuning.retry', LANE),
 ('laneVisitOwedDrop', X, '                let visit = self.followOwed ? self.rerouteOnVisit(other) : []', '                let visit = self.rerouteOnVisit(other)', 'barrierDecidesA429BetweenDrainTurns'),
 ('laneJobsWalkAlways', X, '        if lane != .userInitiated, self.followOwed || !verdicts.isEmpty {', '        if lane != .userInitiated {', 'barrierDecidesA429'),
 ('spaceFailureEpochDropped', F, '            guard let job = self.state.jobs[transfer], job.epoch == epoch else {\n                return\n            }\n            let movesAfter', '            guard let job = self.state.jobs[transfer] else {\n                return\n            }\n            let movesAfter', 'barrierGivesASpaceVerdictOnlyToTheJobThatFailed'),
]
only = set(sys.argv[1:])
env = dict(os.environ, TMPDIR=W + '/.build-s3f/tmp', CLANG_MODULE_CACHE_PATH=W + '/.build-s3f/tmp/mc', LLVM_PROFILE_FILE=W + '/.build-s3f/tmp/%p.profraw')
for name, path, old, new, flt in M:
    if only and name not in only:
        continue
    p = os.path.join(SRC, path)
    text = open(p).read()
    c = text.count(old)
    if c != 1:
        print(f'{name}: count {c} != 1', flush=True)
        continue
    open(p, 'w').write(text.replace(old, new))
    try:
        log = f'{LOG}/{name}-build.log'
        b = subprocess.run(['swift', 'build', '--build-tests', '--scratch-path', BUILD], cwd=SRC, env=env, stdout=open(log, 'w'), stderr=subprocess.STDOUT)
        if b.returncode != 0:
            print(f'{name}: BUILD FAILED', flush=True)
            continue
        for run in (1, 2):
            log = f'{LOG}/{name}-run{run}.log'
            subprocess.run(['swift', 'test', '--skip-build', '--scratch-path', BUILD, '--filter', flt], cwd=SRC, env=env, stdout=open(log, 'w'), stderr=subprocess.STDOUT)
            lines = open(log, errors='replace').read().splitlines()
            summ = [l for l in lines if 'Test run with' in l]
            fails = [l for l in lines if l.startswith('✘ Test') and 'recorded an issue' in l]
            where = sorted(set(l.split(' at ')[-1].split(': ')[0] for l in fails))
            print(f'{name} run{run}: ' + (summ[-1].strip() if summ else 'NO SUMMARY') + (' | ' + ', '.join(where[:4]) if where else ''), flush=True)
    finally:
        open(p, 'w').write(text)
d = subprocess.run(['diff', '-r', SRC + '/Sources', W + '/Sources'], capture_output=True, text=True)
print('revert diff: ' + ('none' if not d.stdout.strip() else d.stdout[:300]), flush=True)
