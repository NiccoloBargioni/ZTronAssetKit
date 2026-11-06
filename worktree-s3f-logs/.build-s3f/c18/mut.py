import subprocess, sys, os
W = '/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f'
SRC = W + '/.build-s3f/mutsrc'
LOG = W + '/.build-s3f/c18/mut'
BUILD = W + '/.build-s3f/mutbuild'
E = 'Sources/ZTronAssetSync/Engine/'
FA, FO, DI, JO, RU, CU = (E + n for n in ('EngineFailures.swift', 'EngineFollow.swift', 'EngineDispatch.swift', 'EngineJobs.swift', 'EngineRuns.swift', 'EngineCatchUp.swift'))
CONV = 'barrierMovesConvergingIDsOverTheFollowsTurns'
NARROW = 'barrierAnswersAnIDMovedBackAndAwayAgainWithThePublicationsOutcome'
VL = 'barrierDecidesA429OnTheLaneAWaitingVerdictLeaves'
MB = 'barrierJoinsAnIDMappedBackAfterTheVerdictThatWaits'
PHOP = 'barrierGivesAnInterestMovedOntoAPublicationItsOutcome'
HOP = 'barrierGivesAMovedInterestTheOutcomeOfTheAttemptThatEndsOnItsContent'
RAD = 'barrierReadsARetryAfterDateAtItsArrival'
BAR = 'EngineFollowBarrierTests'
FULL = 'ZTronAssetSyncTests'
STAMP = ('        guard let stamp else {\n'
         '            return self.verdictAnswers(verdict, interest, of: job)\n'
         '        }\n'
         '        return self.withReading(stamp) {\n'
         '            self.verdictAnswers(verdict, interest, of: job)\n'
         '        }\n')
RECORD = ('            movedBefore = away\n'
          '            let follow = self.state.followsEnded\n'
          '            self.state.jobs[transfer]?.rerouteFor = follow\n'
          '        } else {\n'
          '            movedBefore = job.rerouteOnPass?.intersection(away) ?? []\n'
          '        }\n'
          '        self.state.jobs[transfer]?.rerouteOnPass = movedBefore\n')
RECORD_OLD = ('            movedBefore = away\n'
              '            let follow = self.state.followsEnded\n'
              '            self.state.jobs[transfer]?.rerouteFor = follow\n'
              '            self.state.jobs[transfer]?.rerouteOnPass = movedBefore\n'
              '        } else {\n'
              '            movedBefore = job.rerouteOnPass?.intersection(away) ?? []\n'
              '        }\n')
BUDGET = '        var (visited, moved) = self.continueInbound(budget: Self.followsPerTurn)\n'
M = [
 ('rerouteOnPassKeepWhole', FO, RECORD, RECORD_OLD, NARROW),
 ('vaStampDrop', FA, STAMP, '        _ = stamp\n        return self.verdictAnswers(verdict, interest, of: job)\n', VL),
 ('takeOffAssetsKeep', FO, '        self.state.jobs[job.transfer]?.assets.subtract(held)\n', '', MB),
 ('inboundSharedBudgetDrop', FO, BUDGET, BUDGET + '        visited = 0\n', CONV),
 ('inboundListingDrop', FO, 'self.move(ids, of: holder, listing: move.copy)', 'self.move(ids, of: holder, listing: nil)', CONV),
 ('inboundTargetWaitsDrop', FO, 'if self.inboundTargetWaits(move), let holder', 'if let holder', CONV),
 ('publishInboundWaitDrop', DI, '        if self.inboundBlocks(transfer) {\n', '        if Bool("false") == true, self.inboundBlocks(transfer) {\n', CONV),
 ('inboundHolderWaitDrop', FO, 'return self.state.inboundOnto[transfer] != nil || self.state.inboundMoves[self.state.inboundNext...].contains { $0.holder == transfer }', 'return self.state.inboundOnto[transfer] != nil', BAR),
 ('applyWalkDrop', RU, '        self.bringInboundOntoPublications()\n', '', PHOP),
 ('catchUpWalkDrop', CU, '        self.bringInboundOntoPublications()\n', '', BAR),
 ('retryAfterWallDrop', FO, '            self.retryLater(transfer, error: error, answer: answer, wall: wall)\n', '            _ = wall\n            self.retryLater(transfer, error: error, answer: answer)\n', RAD),
 ('vaWallDrop', FA, 'lane: kept, wall: wall) == nil', 'lane: kept, wall: self.environment.time.now()) == nil && wall == wall', VL + '|' + RAD),
 ('bringInboundVisitFilterDrop', FO, 'for asset in job.assets where visit?.contains(asset) ?? true {', 'for asset in job.assets where visit != nil || true {', HOP + '|' + CONV),
 ('publishBringInboundDrop', DI, '        self.bringInbound(transfer)\n', '', HOP + '|' + CONV),
 ('spaceBringInboundDrop', FA, '            self.bringInbound(transfer)\n', '', HOP),
 ('deferBringInboundDrop', FO, '        self.deferToFollow(.attemptFailed(transfer, epoch: job.epoch, verdict: verdict))\n        self.bringInbound(transfer)\n', '        self.deferToFollow(.attemptFailed(transfer, epoch: job.epoch, verdict: verdict))\n', HOP + '|' + CONV),
 ('rule3BringingDrop', JO, 'if self.state.inFollowVisit, !self.state.bringingInbound, let waiting', 'if self.state.inFollowVisit, let waiting', HOP + '|' + CONV),
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
