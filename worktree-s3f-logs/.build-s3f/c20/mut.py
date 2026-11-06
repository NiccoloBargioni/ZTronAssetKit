import subprocess, sys, os
W = '/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f'
SRC = W + '/.build-s3f/mutsrc'
LOG = W + '/.build-s3f/c20/mut'
BUILD = W + '/.build-s3f/mutbuild'
E = 'Sources/ZTronAssetSync/Engine/'
FA, FO, MV, ST, CO, JO = (E + n for n in ('EngineFailures.swift', 'EngineFollow.swift', 'EngineMoves.swift', 'EngineState.swift', 'EngineCommands.swift', 'EngineJobs.swift'))
DRAIN = 'barrierBoundsTheDrainsVisitsAfterVerdictsByOneTurnsIDs'
COUNTS = 'EngineInterestCountsTests|invariantOracle'
ENGINE = 'EngineFollowTests'
TURN = 'barrierBoundsAnOwedMovesTurnAcrossHolders|barrierBoundsARestsTurnAcrossHolders'
LEGACY = 'barrierWalksOntoAChecksumLessPublication'
ANSWERS = 'EngineFollowBarrierVerdictAnswersTests'
CLAIMS = 'EngineGroupClaimTests'
FULL = 'ZTronAssetSyncTests'
M = [
 # S3-R25 item 1: the drain's turn bound.
 ('drainSpentDrop', FO, '        self.state.drainIDsLeft -= made.spent\n', '        _ = made\n', DRAIN),
 ('drainSeedFull', FO, '        self.drainEventsAfterFollow(ids: budget.ids)\n', '        self.drainEventsAfterFollow()\n', DRAIN),
 ('drainSpentBreakDrop', FO, 'if self.state.followMoving != nil || self.state.drainIDsLeft <= 0 {', 'if self.state.followMoving != nil {', DRAIN),
 ('drainBoundLt', FO, 'if self.state.followMoving != nil || self.state.drainIDsLeft <= 0 {', 'if self.state.followMoving != nil || self.state.drainIDsLeft < 0 {', DRAIN),
 ('drainVisitIDsFull', FO, 'self.follow(transfer, ids: self.state.drainIDsLeft, afterVerdict: true)', 'self.follow(transfer, ids: self.state.followIDsPerTurn, afterVerdict: true)', DRAIN),
 ('drainFollowUpSeedZero', FO, 'self.state.drainIDsLeft = ids ?? self.state.followIDsPerTurn', 'self.state.drainIDsLeft = ids ?? 0', DRAIN),
 # S3-R25 item 2: the per-lane interest counts.
 ('countInsertDrop', ST, '        case (nil, let added?):\n            self.interestCounts.add(added)\n', '        case (nil, let added?):\n            _ = added\n', COUNTS),
 ('countRemovalDrop', ST, '        case (let removed?, nil):\n            self.interestCounts.remove(removed)\n', '        case (let removed?, nil):\n            _ = removed\n', COUNTS),
 ('countLaneChangeDrop', ST, '        case (let old?, let new?):\n            self.interestCounts.remove(old)\n            self.interestCounts.add(new)\n', '        case (let old?, let new?):\n            _ = (old, new)\n', COUNTS),
 ('countInsertDropEngine', ST, '        case (nil, let added?):\n            self.interestCounts.add(added)\n', '        case (nil, let added?):\n            _ = added\n', ENGINE),
 ('countRemovalDropEngine', ST, '        case (let removed?, nil):\n            self.interestCounts.remove(removed)\n', '        case (let removed?, nil):\n            _ = removed\n', ENGINE),
 ('countRemoveAllDrop', ST, '        self.interests.removeAll()\n        self.interestCounts = InterestCounts()\n', '        self.interests.removeAll()\n', COUNTS),
 ('countKeepRecountDrop', ST, '        self.interests = self.interests.filter { isIncluded($0.key, $0.value) }\n        self.interestCounts = InterestCounts(self.interests.values)\n', '        self.interests = self.interests.filter { isIncluded($0.key, $0.value) }\n', COUNTS),
 ('countSingleUserDrop', ST, '            if interest.kind != .ensure {\n                self.singleUser += delta\n            }\n', '', COUNTS),
 ('countsClauseDrop', CO, '                violations.append("job \\(transfer) counts its interests \\(job.interestCounts), which count \\(recount)")\n', '                _ = recount\n', COUNTS),
 ('keptCapDrop', FA, 'let kept = job.interestCounts.highest { !self.reachesCap($0, attempts: attempts) } ?? interest.lane', 'let kept = job.interestCounts.highest ?? interest.lane', ANSWERS),
 ('dropHeldLaneDrop', JO, '            self.state.jobs[transfer]?.heldLane = before\n', '            _ = before\n', CLAIMS),
 # S3-R25 item 5: the turn's bound across holders.
 ('inboundSpentDrop', FO, '                budget.ids -= made.spent\n                moved = moved || made.moved\n', '                moved = moved || made.moved\n', TURN),
 ('restSpentDrop', FO, '        budget.ids -= made.spent\n        guard rest.moves.isDone else {\n', '        guard rest.moves.isDone else {\n', TURN),
 ('visitSpentDrop', FO, '            self.follow(transfer, ids: ids, afterVerdict: false)\n        }\n        budget.ids -= made.spent\n', '            self.follow(transfer, ids: ids, afterVerdict: false)\n        }\n', TURN),
 ('continueMoveBudgetDrop', MV, '                guard spent < budget else {\n                    break\n                }\n', '', TURN),
 # S3-R25 item 6: findInbound's checksum-less lookups.
 ('byIdentifierTargetDrop', FO, '                byIdentifier[target.entry.identifier] = index\n', '                _ = index\n', LEGACY),
 ('byIdentifierLookupDrop', FO, '                    index = byIdentifier[asset].flatMap { SyncEngine.sameTransfer(listed, targets[$0].entry) ? $0 : nil }\n', '                    index = nil\n', LEGACY),
]
extra = os.environ.get('MUT_EXTRA')
if extra:
    exec(open(extra).read())
only = [a for a in sys.argv[1:] if not a.startswith('-')]
dry = '--dry' in sys.argv
env = dict(os.environ, TMPDIR=W + '/.build-s3f/tmp', CLANG_MODULE_CACHE_PATH=W + '/.build-s3f/tmp/mc-mut', LLVM_PROFILE_FILE=W + '/.build-s3f/tmp/%p.profraw')
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
    try:
        subprocess.run(['swift', 'test', '--skip-build', '--scratch-path', BUILD, '--skip', 'Benchmarks', '--filter', flt], cwd=SRC, env=env, stdout=open(log, 'w'), stderr=subprocess.STDOUT, timeout=1500)
    except subprocess.TimeoutExpired:
        print(f'{name} {tag}: TIMEOUT (hang) | load {loads()}', flush=True)
        return True, ['timeout']
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
