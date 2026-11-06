import subprocess, sys, os
W = '/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f'
SRC = W + '/.build-s3f/mutsrc'
LOG = W + '/.build-s3f/c17/mut'
BUILD = W + '/.build-s3f/mutbuild'
FA = 'Sources/ZTronAssetSync/Engine/EngineFailures.swift'
FO = 'Sources/ZTronAssetSync/Engine/EngineFollow.swift'
DI = 'Sources/ZTronAssetSync/Engine/EngineDispatch.swift'
JO = 'Sources/ZTronAssetSync/Engine/EngineJobs.swift'
VL = 'barrierDecidesA429OnTheLaneAWaitingVerdictLeaves'
MB = 'barrierJoinsAnIDMappedBackAfterTheVerdictThatWaits'
HOP = 'barrierGivesAMovedInterestTheOutcomeOfTheAttemptThatEndsOnItsContent'
FULL = 'ZTronAssetSyncTests'
OFF = 'let off: [(token: InterestToken, interest: JobInterest, asset: AssetID)] = []'
M = [
 ('vaRetryAfterDrop', FA, 'return self.retryDelay(job.transfer, error: error, attempts: attempts, lane: kept, wall: self.environment.time.now()) == nil', 'return false', VL),
 ('vaKeptLane', FA, 'lane: kept, wall: self.environment.time.now()) == nil', 'lane: interest.lane, wall: self.environment.time.now()) == nil', VL),
 ('vaThrottleUntilDrop', FA, 'return self.failFastError(.throttled(until: end), for: interest, of: job, at: now) != nil', 'return false', VL),
 ('vaOfflineDrop', FA, 'return !requeue && self.failFastError(.offline, for: interest, of: job, at: now) != nil', 'return false', VL),
 ('vaOfflineRequeueDrop', FA, 'return !requeue && self.failFastError(.offline, for: interest, of: job, at: now) != nil', 'return self.failFastError(.offline, for: interest, of: job, at: now) != nil', VL),
 ('vaPauseDrop', FA, 'return self.failFastError(block, for: interest, of: job, at: now) != nil', 'return false', VL),
 ('vaPausePolicyDrop', FA, 'guard policy, job.lane < .userInitiated, let block', 'guard job.lane < .userInitiated, let block', VL),
 ('vaPauseLaneDrop', FA, 'guard policy, job.lane < .userInitiated, let block', 'guard policy, let block', VL),
 ('vaSpaceCapDrop', FA, '                return self.reachesCap(interest.lane, attempts: attempts)\n            case .insufficient:', '                return false\n            case .insufficient:', VL),
 ('vaSpaceInsufficientDrop', FA, 'return self.failFastError(.insufficientSpace, for: interest, of: measured, at: now) != nil', 'return false', VL),
 ('javWithdrawnDrop', FA, '!withdrawn.contains(token) && !interest.assets.isSubset(of: leaving)', '!interest.assets.isSubset(of: leaving)', VL),
 ('javMovedBeforeDrop', FA, '!withdrawn.contains(token) && !interest.assets.isSubset(of: leaving)', '!withdrawn.contains(token)', VL),
 ('flMovedBeforeDrop', FA, 'if visit?.contains(asset) ?? true || movedBefore.contains(asset) {', 'if visit?.contains(asset) ?? true {', VL),
 ('spaceBringInboundDrop', FA, '            self.deferToFollow(.spaceFailure(transfer, epoch: epoch, required: required))\n            self.bringInbound(transfer)\n', '            self.deferToFollow(.spaceFailure(transfer, epoch: epoch, required: required))\n', HOP),
 ('takeOffSpaceDrop', FO, '            let off = self.takeOffMovedBefore(job)\n            let movesAfter = self.endDeferral(job)\n            self.decideSpaceFailure', '            ' + OFF + '\n            let movesAfter = self.endDeferral(job)\n            self.decideSpaceFailure', MB),
 ('takeOffVerdictDrop', FO, '        let off = self.takeOffMovedBefore(job)\n        let movesAfter = self.endDeferral(job)\n        self.giveVerdict', '        ' + OFF + '\n        let movesAfter = self.endDeferral(job)\n        self.giveVerdict', MB),
 ('deferBringInboundDrop', FO, '        self.deferToFollow(.attemptFailed(transfer, epoch: job.epoch, verdict: verdict))\n        self.bringInbound(transfer)\n', '        self.deferToFollow(.attemptFailed(transfer, epoch: job.epoch, verdict: verdict))\n', HOP),
 ('movedBeforeRecomputeDrop', FO, '            movedBefore = away\n', '            movedBefore = []\n', MB),
 ('movedBeforeKeptDrop', FO, '            movedBefore = job.rerouteOnPass?.intersection(away) ?? []', '            movedBefore = []', MB),
 ('movedBeforeKeptNoIntersect', FO, '            movedBefore = job.rerouteOnPass?.intersection(away) ?? []', '            movedBefore = job.rerouteOnPass ?? []', MB),
 ('bringInboundVisitFilterDrop', FO, 'for asset in job.assets where visit?.contains(asset) ?? true {', 'for asset in job.assets where visit != nil || true {', HOP),
 ('deferBehindJoinSkipDrop', FO, 'while index < events.count, case .join = events[index] {', 'while index < -1, case .join = events[index] {', MB),
 ('bringInboundOrderDrop', FO, 'for holder in self.state.followOrder[self.state.followNext...] where inbound[holder] != nil && placed.insert(holder).inserted {', 'for holder in [TransferID]() where inbound[holder] != nil && placed.insert(holder).inserted {', HOP),
 ('publishBringInboundDrop', DI, '        self.bringInbound(transfer)\n', '', HOP),
 ('rule3Drop', JO, 'if self.state.inFollowVisit, !self.state.bringingInbound, let waiting', 'if Bool("false") == true, self.state.inFollowVisit, !self.state.bringingInbound, let waiting', MB),
 ('rule3BringingDrop', JO, 'if self.state.inFollowVisit, !self.state.bringingInbound, let waiting', 'if self.state.inFollowVisit, let waiting', HOP),
 ('rule3InFollowVisitDrop', JO, 'if self.state.inFollowVisit, !self.state.bringingInbound, let waiting', 'if !self.state.bringingInbound, let waiting', MB),
 ('relaneGuardRevert', JO, '            if job.attemptEnd?.deferredAfter != nil {', '            if self.state.verdictsAfterFollow[transfer] != nil {', HOP),
]
only = [a for a in sys.argv[1:] if not a.startswith('-')]
env = dict(os.environ, TMPDIR=W + '/.build-s3f/tmp', CLANG_MODULE_CACHE_PATH=W + '/.build-s3f/tmp/mc', LLVM_PROFILE_FILE=W + '/.build-s3f/tmp/%p.profraw')
for sub in ('Sources', 'Tests'):
    subprocess.run(['rsync', '-a', '--delete', f'{W}/{sub}/', f'{SRC}/{sub}/'], check=True)
subprocess.run(['cp', f'{W}/Package.swift', f'{SRC}/Package.swift'], check=True)
d = subprocess.run(['diff', '-r', SRC + '/Sources', W + '/Sources'], capture_output=True, text=True)
print('sync diff: ' + ('none' if not d.stdout.strip() else d.stdout[:300]), flush=True)

def run(name, tag, flt):
    log = f'{LOG}/{name}-{tag}.log'
    subprocess.run(['swift', 'test', '--skip-build', '--scratch-path', BUILD, '--filter', flt], cwd=SRC, env=env, stdout=open(log, 'w'), stderr=subprocess.STDOUT)
    lines = open(log, errors='replace').read().splitlines()
    summ = [l for l in lines if 'Test run with' in l]
    fails = [l for l in lines if l.startswith('✘ Test') and 'recorded an issue' in l]
    where = sorted(set(l.split(' at ')[-1].split(': ')[0] for l in fails))
    killed = bool(summ) and 'passed' not in summ[-1]
    print(f'{name} {tag}: ' + (summ[-1].strip() if summ else 'NO SUMMARY') + (' | ' + ', '.join(where[:4]) if where else ''), flush=True)
    return killed, where

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
        killed, _ = run(name, 'run1', flt)
        if killed:
            run(name, 'run2', flt)
        else:
            killed, where = run(name, 'full1', FULL)
            if killed:
                run(name, 'full2', FULL)
            else:
                print(f'{name}: SURVIVED', flush=True)
    finally:
        open(p, 'w').write(text)
d = subprocess.run(['diff', '-r', SRC + '/Sources', W + '/Sources'], capture_output=True, text=True)
print('revert diff: ' + ('none' if not d.stdout.strip() else d.stdout[:300]), flush=True)
