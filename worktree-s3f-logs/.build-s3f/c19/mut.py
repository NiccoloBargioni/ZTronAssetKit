import subprocess, sys, os
W = '/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f'
SRC = W + '/.build-s3f/mutsrc'
LOG = W + '/.build-s3f/c19/mut'
BUILD = W + '/.build-s3f/mutbuild'
E = 'Sources/ZTronAssetSync/Engine/'
FA, FO, MV, SH = (E + n for n in ('EngineFailures.swift', 'EngineFollow.swift', 'EngineMoves.swift', 'EngineShutdown.swift'))
SHARED = 'barrierMovesASharedContentsIDsOverBoundedTurns'
SHUT = 'barrierShutsDownWhileAPublicationWaitsForOwedMoves'
DRAIN = 'barrierDrainsTheEventsAfterAVisitsRest'
STALE2 = 'barrierSpendsTheRerouteOfAVisitMadeOverTurns'
TWO = 'barrierMovesOneHoldersIDsOntoTwoPublications'
KEEPBACK = 'barrierBindsTheIDAPublicationKeepsOnceTheMoveOffItsJobIsMade'
PL = 'barrierDecidesA429OnTheLaneAnOwedMoveLeavesAfterALaterApply|barrierDecidesA429WithoutAnInterestTheOwedMovesVerdictAnswers'
HOPS = 'barrierGivesAnInterestMovedOntoAPublicationItsOutcome|barrierGivesAnInterestMappedBackOffAPublicationItsOutcome|' + KEEPBACK
FULL = 'ZTronAssetSyncTests'
M = [
 ('startChunkDrop', MV, 'guard moved.count > budget else {', 'guard moved.count > Int.max, budget >= 0 else {', SHARED),
 ('inboundIDsNowFull', MV, 'max(1, self.state.followIDsPerTurn / 2)', 'max(1, self.state.followIDsPerTurn * 4)', SHARED),
 ('remainderDrop', FO, 'self.state.followMoving = VisitRemainder(holder: transfer, moves: rest, stamp: stamp, afterVerdict: afterVerdict, spends: reroute != nil)', '_ = (rest, stamp)', SHARED),
 ('inboundBlocksRestDrop', FO, '        if self.state.followMoving?.holder == transfer {\n            return true\n        }\n', '', SHARED + '|' + SHUT),
 ('restEndResumeDrop', FO, '        if !self.inboundBlocks(rest.holder) {\n            self.state.inboundWaits.removeValue(forKey: rest.holder)?.resume()\n        }\n', '', SHARED),
 ('drainRestBreakDrop', FO, '            if self.state.followMoving != nil {\n                // A visit after a verdict', '            if Bool("false") == true, self.state.followMoving != nil {\n                // A visit after a verdict', DRAIN),
 ('drainRestReinsertDrop', FO, '                self.state.eventsAfterFollow.insert(contentsOf: rest.map(\\.0), at: 0)\n                self.state.eventStamps.insert(contentsOf: rest.map(\\.1), at: 0)\n', '                _ = rest\n', DRAIN),
 ('drainRestReturnDrop', FO, '        if self.state.followMoving != nil {\n            self.scheduleFollowFollowUp()\n            return\n        }\n        guard self.state.eventsAfterFollow.isEmpty else {', '        guard self.state.eventsAfterFollow.isEmpty else {', DRAIN),
 ('drainVisitIDsFull', FO, 'self.follow(transfer, ids: self.state.followIDsPerTurn, afterVerdict: true)', 'self.follow(transfer, ids: Int.max, afterVerdict: true)', DRAIN),
 ('progressStoreDrop', FO, '                self.state.inboundMoves[self.state.inboundNext].progress = rest\n', '                _ = rest\n', SHARED),
 ('restSpendDrop', FO, '        if rest.spends {\n            self.state.jobs[rest.holder]?.rerouteOnPass = []\n        }\n', '', STALE2),
 ('keepDrop', MV, 'keeps = follows && (copy.entry(for: asset).map { SyncEngine.sameTransfer($0, job.entry) } ?? false)', 'keeps = follows && copy.count < 0', STALE2 + '|' + SHARED),
 ('visitIDsBudgetDrop', FO, 'budget.holders > 0, budget.ids > 0, skipped < Self.followSkipsPerTurn', 'budget.holders > 0, skipped < Self.followSkipsPerTurn', SHARED),
 ('restAfterInboundDrop', FO, 'if !self.inboundOwed, self.continueVisitRemainder(&budget) {', 'if self.continueVisitRemainder(&budget) {', SHARED),
 ('supersedesDrop', MV, 'let supersedes = moved.count == job.assets.count && job.state', 'let supersedes = moved.count < 0 && job.state', SHARED),
 ('chunkAbandonDrop', MV, '        if supersedes, job.state == .downloading {\n', '        if Bool("false") == true, supersedes, job.state == .downloading {\n', SHARED),
 ('chunkEndRemoveDrop', MV, '                self.removeJob(holder)\n', '                _ = holder\n', SHARED),
 ('laneCarriedDrop', FA, 'guard !pending.isEmpty, let index = pending[asset] else {', 'guard pending.isEmpty && !pending.isEmpty, let index = pending[asset] else {', PL),
 ('laneTargetVerdictDrop', FA, 'var targetRule = targets[target.transfer] ?? rule(of: target)', 'var targetRule = targets[target.transfer] ?? LaneMoveRule(job: target, visit: [], movedBefore: [], after: nil)', PL),
 ('laneHolderRule', FA, '                        if let viaTarget = movesViaTarget(asset, interest, &targets) {\n                            reaches = viaTarget\n                        } else {\n                            reaches = moves(asset, interest, under: &own)\n                        }\n', '                        reaches = moves(asset, interest, under: &own)\n', PL),
 ('laneOwnViaTargetDrop', FA, 'if movesViaTarget(asset, interest, &targets) ?? true {', 'if true {', PL),
 ('findInboundPendingDrop', FO, 'guard pending.isEmpty || pending[asset] == nil, let listed = copy.entry(for: asset) else {', 'guard let listed = copy.entry(for: asset) else {', HOPS + '|' + TWO + '|' + SHARED),
 ('shutdownReleaseInboundWaitsDrop', SH, '        self.releaseInboundWaits()\n        self.state.eventsAfterFollow = []', '        self.state.eventsAfterFollow = []', SHUT),
 ('inboundMadeHolderResumeDrop', FO, 'for transfer in [move.target, move.holder] where', 'for transfer in [move.target] where', KEEPBACK),
 ('firstInsertDrop', FO, '                    first?.ids.insert(asset)\n', '                    _ = asset\n', TWO),
 ('othersSlotInsertDrop', FO, '                    others[slot].ids.insert(asset)\n', '                    _ = (slot, asset)\n', TWO),
 ('othersAppendDrop', FO, '                    others.append((index, [asset]))\n', '                    _ = (index, asset)\n', TWO),
]
only = [a for a in sys.argv[1:] if not a.startswith('-')]
dry = '--dry' in sys.argv
env = dict(os.environ, TMPDIR=W + '/.build-s3f/tmp', CLANG_MODULE_CACHE_PATH=W + '/.build-s3f/tmp/mc', LLVM_PROFILE_FILE=W + '/.build-s3f/tmp/%p.profraw')
if dry:
    for name, path, old, new, flt in M:
        c = open(os.path.join(W, path)).read().count(old)
        print(f'{name}: count {c}')
    sys.exit(0)
os.makedirs(LOG, exist_ok=True)
for sub in ('Sources', 'Tests'):
    subprocess.run(['rsync', '-a', '--delete', f'{W}/{sub}/', f'{SRC}/{sub}/'], check=True)
subprocess.run(['cp', f'{W}/Package.swift', f'{SRC}/Package.swift'], check=True)
d = subprocess.run(['diff', '-r', SRC + '/Sources', W + '/Sources'], capture_output=True, text=True)
print('sync diff: ' + ('none' if not d.stdout.strip() else d.stdout[:300]), flush=True)


def loads():
    return subprocess.run(['sysctl', '-n', 'vm.loadavg'], capture_output=True, text=True).stdout.strip()


def run(name, tag, flt):
    log = f'{LOG}/{name}-{tag}.log'
    subprocess.run(['swift', 'test', '--skip-build', '--scratch-path', BUILD, '--skip', 'Benchmarks', '--filter', flt], cwd=SRC, env=env, stdout=open(log, 'w'), stderr=subprocess.STDOUT)
    lines = open(log, errors='replace').read().splitlines()
    summ = [l for l in lines if 'Test run with' in l]
    fails = [l for l in lines if l.startswith('✘ Test') and 'recorded an issue' in l]
    where = sorted(set(l.split(' at ')[-1].split(': ')[0] for l in fails))
    killed = bool(summ) and 'passed' not in summ[-1]
    print(f'{name} {tag}: ' + (summ[-1].strip() if summ else 'NO SUMMARY') + (' | ' + ', '.join(where[:4]) if where else '') + f' | load {loads()}', flush=True)
    return killed, where


byname = {m[0]: m for m in M}
order = [byname[n] for n in only] if only else M
for name, path, old, new, flt in order:
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
