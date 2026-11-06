# Cycle 22's copy of .build-s3f/c21/tools/mut21s.py: the same runner, logging under .build-s3f/c22/mut (c21 stays unchanged).
import subprocess, sys, os
W = '/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f'
SRC = W + '/.build-s3f/mutsrc'
LOG = W + '/.build-s3f/c22/mut'
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
A = 'EngineFollowBarrierTests/(barrierWaitsTheJoinsBehindAVerdictOutsideTheQueue|barrierPlacesTheJoinsBehindAVerdictRightBehindItNewestFirst|barrierJoinsTheJoinsBehindASkippedVerdict|onlyAnExitVerdictsEventNamesItsAttempt|barrierPurgeWithdrawsTheJoinsBehindAVerdict|barrierDecidesA429OnTheLaneTheJoinsBehindAVerdictGive|invariantsReportTheJoinsBehindAVerdictOutOfPlace|shutdownClearsTheJoinsBehindAVerdict)'
SD = E + 'EngineShutdown.swift'
APPEND = '        self.state.joinsBehindVerdicts[VerdictKey(transfer: target.transfer, epoch: target.epoch), default: []].append(JoinBehindVerdict(join: join, stamp: self.worldStamp()))'
QUEUE = """        let events = self.state.eventsAfterFollow
        let verdict = events.lastIndex { event in event.verdictKey == VerdictKey(transfer: target.transfer, epoch: target.epoch) }
        let index = (verdict ?? events.count - 1) + 1
        self.state.eventsAfterFollow.insert(.join(join), at: index)
        self.state.eventStamps.insert(self.worldStamp(), at: min(index, self.state.eventStamps.count))"""
M = [
 ('a-drop-append', FO, APPEND, '', A),
 ('a-drop-materialize', FO, 'let behind = self.state.joinsBehindVerdicts.removeValue(forKey: key) {', 'let behind = Optional<[JoinBehindVerdict]>.none {', A),
 ('a-arrival-order', FO, '                for entry in behind.reversed() {\n                    if batch.count', '                for entry in behind {\n                    if batch.count', A),
 ('a-tail-materialize', FO, """                for entry in behind.reversed() {
                    if batch.count < Self.eventsAfterFollowPerTurn {
                        batch.append((.join(entry.join), entry.stamp))
                    } else {
                        overflow.append((.join(entry.join), entry.stamp))
                    }
                }""", """                for entry in behind.reversed() {
                    self.state.eventsAfterFollow.append(.join(entry.join))
                    self.state.eventStamps.append(entry.stamp)
                }""", A),
 ('a-given-verdict-only', FO, 'if let key = event.verdictKey, let behind', 'if let key = event.verdictKey, self.state.verdictsAfterFollow[key.transfer] != nil, let behind', A),
 ('a-drop-space-arm', FO, """        case .spaceFailure(let transfer, let epoch, _):
            return VerdictKey(transfer: transfer, epoch: epoch)""", """        case .spaceFailure:
            return nil""", A),
 ('a-drop-attempt-arm', FO, """        case .attemptFailed(let transfer, let epoch, _):
            return VerdictKey(transfer: transfer, epoch: epoch)
        case .join""", """        case .attemptFailed:
            return nil
        case .join""", A),
 ('a8-drop-bucket-arm', CO, '            for slot in (0..<count).reversed() {', '            for slot in (0..<count).reversed() where slot < 0 {', A),
 ('a8-drop-bucket-writeback', CO, '                    self.state.joinsBehindVerdicts[key]?[slot].join = join', '                    _ = join', A),
 ('a9-recount-no-withdrawn-filter', CO, """                for entry in (self.state.joinsBehindVerdicts[key] ?? []).reversed() {
                    register(entry.join)
                }""", """                for entry in (self.state.joinsBehindVerdicts[key] ?? []).reversed() {
                    joins[entry.join.token, default: [:]][entry.join.asset] = entry.join.entry.transferID
                }""", A),
 ('a9-drop-recount-walk', CO, """                for entry in (self.state.joinsBehindVerdicts[key] ?? []).reversed() {
                    register(entry.join)
                }""", '', A),
 ('a7-drop-bucket-walk', FA, '            for behind in self.state.joinsBehindVerdicts.values {', '            for behind in self.state.joinsBehindVerdicts.values where behind.isEmpty {', A),
 ('a7-count-without-reaches', FA, '                for entry in behind where reaches(entry.join) {', '                for entry in behind {', A),
 ('a10-drop-clear', SD, '        self.state.joinsBehindVerdicts = [:]\n', '', A),
 ('k1-drop', CO, 'waitingVerdicts[key] != 1 }.count\n        if unplaced > 0 {', 'waitingVerdicts[key] != 1 }.count\n        if unplaced > 0, unplaced < 0 {', A),
 ('k3-drop', CO, '        if unstamped > 0 {', '        if unstamped > 0, unstamped < 0 {', A),
 ('e1-event-loop-break', FA, """                raise(join.lane)
                if lane == .userInitiated {
                    return .userInitiated
                }""", """                raise(join.lane)
                if lane == .userInitiated {
                    break
                }""", A),
 ('e2-bucket-loop-no-return', FA, """                    raise(entry.join.lane)
                    if lane == .userInitiated {
                        return .userInitiated
                    }""", '                    raise(entry.join.lane)', A),
]
# The sources come from a snapshot of a commit (MUT_SNAP), so edits in the worktree meanwhile change nothing.
SNAP = os.environ.get('MUT_SNAP', W)
extra = os.environ.get('MUT_EXTRA')
if extra:
    exec(open(extra).read())
only = [a for a in sys.argv[1:] if not a.startswith('-')]
dry = '--dry' in sys.argv
env = dict(os.environ, TMPDIR=W + '/.build-s3f/tmp', CLANG_MODULE_CACHE_PATH=W + '/.build-s3f/tmp/mc-mut', LLVM_PROFILE_FILE=W + '/.build-s3f/tmp/%p.profraw')
if dry:
    for name, path, old, new, flt in M:
        c = open(os.path.join(SNAP, path)).read().count(old)
        print(f'{name}: count {c}')
    sys.exit(0)
os.makedirs(LOG, exist_ok=True)
for sub in ('Sources', 'Tests'):
    subprocess.run(['rsync', '-a', '--delete', f'{SNAP}/{sub}/', f'{SRC}/{sub}/'], check=True)
subprocess.run(['cp', f'{SNAP}/Package.swift', f'{SRC}/Package.swift'], check=True)
d = subprocess.run(['diff', '-r', SRC + '/Sources', SNAP + '/Sources'], capture_output=True, text=True)
print('sync diff: ' + ('none' if not d.stdout.strip() else d.stdout[:300]), flush=True)


def loads():
    return subprocess.run(['sysctl', '-n', 'vm.loadavg'], capture_output=True, text=True).stdout.strip()


def run(name, tag, flt):
    log = f'{LOG}/{name}-{tag}.log'
    proc = subprocess.Popen(['swift', 'test', '--skip-build', '--scratch-path', BUILD, '--skip', 'Benchmarks', '--filter', flt], cwd=SRC, env=env, stdout=open(log, 'w'), stderr=subprocess.STDOUT, start_new_session=True)
    try:
        proc.wait(timeout=int(os.environ.get('MUT_TIMEOUT', '1500')))
    except subprocess.TimeoutExpired:
        # The whole group: the testing helper outlives swift-test and would spin on a hung mutant otherwise.
        import signal
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait()
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
d = subprocess.run(['diff', '-r', SRC + '/Sources', SNAP + '/Sources'], capture_output=True, text=True)
print('revert diff: ' + ('none' if not d.stdout.strip() else d.stdout[:300]), flush=True)
