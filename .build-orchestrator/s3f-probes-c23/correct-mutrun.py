# Cycle-23 correctness verifier (s3f close-out, point 8): re-applies point 6's mutants (S3-R3) in a Sync-only snapshot of
# HEAD under this verifier's scratch path, each against its kill test(s), 2 runs each, after a green baseline. Never committed.
import subprocess, sys, os, re, time, json
W = '/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f'
S = W + '/.build-verify-s3f-c23-correct'
SNAP = S + '/snap'
BUILD = SNAP + '/.build'
LOG = S + '/logs/mut'
os.makedirs(LOG, exist_ok=True)
E = 'Sources/ZTronAssetSync/Engine/'
FA, FO, MV, JO, DI = (E + n for n in ('EngineFailures.swift', 'EngineFollow.swift', 'EngineMoves.swift', 'EngineJobs.swift', 'EngineDispatch.swift'))
OWNER_T = 'owedRerouteOfAWaiterRemovedAheadCountsForNothing'
PINEND_T = 'waitingJoinPinnedToACommittedJobEndsUnderItsChainAtA429'
UNLISTED_T = 'waitingUnlistedJoinCountsTowardA429sLane'
HOLDERS_T = 'barrierContinuesAnOwedMoveInsideItsHoldersPublication'
LAYER_T = 'layerOfAnOwedBatchPinsAVerdictBetweenItAndALaterJoin'
P2 = 'afterVerdictVisitInsideAnENOSPCsReadGetsItsVerdict|afterVerdictVisitForAnApplyInsideAnENOSPCsReadSkipsItsVerdict'
PS = 'owedReroutePinnedToASupersededJob'
P1 = 'owedReroutePinnedToAJobInItsSpaceReadGetsItsVerdict|userJoinFromJustBeforeAnENOSPCReplayedInItsReadGetsItsVerdict|userJoinFromInsideAnENOSPCsReadSkipsItsVerdict'
VISIT = '        if self.state.inFollowVisit || self.state.visitingAfterVerdict {\n'
COUNTDOWN = '            self.state.reroutesWaiting -= 1\n            self.releaseRerouteHolds()\n'
SUPERSEDE_IF = """            if !self.state.eventsAfterFollow.isEmpty {
                self.state.reroutePinCommits[VerdictKey(transfer: transfer, epoch: epoch)] = PinEnd(serial: self.state.copySerial, keepsEntry: false)
            }
            self.transition(transfer, to: .queued)
            self.supersede(transfer, bound: self.inboundIDsNow)"""
P1_RULE = """        guard let reading = self.state.reading, let stamped = job.attemptEnd?.stamped else {
            return false
        }
        return reading.serial <= stamped"""
M = [
 ('k1-b22-no-waiter-owner', FA, 'guard let waiter = self.state.waiters[item.token], !waiter.fromStore, waiter.asset == item.asset, waiter.transfer == batch.from else {', 'guard self.state.waiters[item.token] != nil || true else {', OWNER_T),
 ('k2-p7-forget-at-last-batch', FO, COUNTDOWN, '            self.state.reroutesWaiting -= 1\n            if self.state.reroutesWaiting == 0 {\n                self.state.reroutePinCommits = [:]\n            }\n            self.releaseRerouteHolds()\n', PINEND_T),
 ('k2-r5-lane-engine-copy', FA, 'let listed = (self.joinListing(join) ?? copy).entry(for: join.asset)', 'let listed = copy.entry(for: join.asset)', PINEND_T),
 ('k3-r8-fast-any-join', FA, 'if join.chain != nil, !here(join.asset) {', 'if !here(join.asset) {', UNLISTED_T),
 ('k4-vy-owed-moves-too', MV, '        let rerouting = listing == nil ? self.state', '        let rerouting = true ? self.state', HOLDERS_T),
 ('k5-r2c-made-ignores-verdicts', FO, 'if let made, made.previous == previous, made.verdicts == verdicts.count {', 'if let made, made.previous == previous {', LAYER_T),
 ('p2-after-verdict-replay-rule', JO, VISIT, '        if self.state.inFollowVisit {\n', P2),
 ('ps-write-dropped', DI, SUPERSEDE_IF, """            self.transition(transfer, to: .queued)
            self.supersede(transfer, bound: self.inboundIDsNow)""", PS),
 ('ps-write-always', DI, SUPERSEDE_IF, SUPERSEDE_IF.replace('            if !self.state.eventsAfterFollow.isEmpty {', '            if true {'), PS + '|Supersed|supersed'),
 ('ps-literal-requeue', DI, SUPERSEDE_IF, SUPERSEDE_IF.replace('keepsEntry: false', 'keepsEntry: true'), PS),
 ('p1-rule-false', JO, P1_RULE, '        return false', P1),
 ('p1-rule-true', JO, P1_RULE, '        return self.state.reading != nil', P1),
 ('p1-le-as-lt', JO, 'return reading.serial <= stamped', 'return reading.serial < stamped', P1),
 ('p1-count-not-kept', FO, 'let end = AttemptEnd(failedAfter: self.state.appliesFollowed, deferredAfter: nil, stamped: self.state.stampsMinted)', 'let end = AttemptEnd(failedAfter: self.state.appliesFollowed, deferredAfter: nil, stamped: nil)', P1),
 ('p2-after-verdict-never', JO, VISIT, '        if self.state.visitingAfterVerdict {\n            return false\n        }\n        if self.state.inFollowVisit {\n', P2),
 ('x-p2-after-verdict-true', JO, VISIT, '        if self.state.visitingAfterVerdict {\n            return true\n        }\n        if self.state.inFollowVisit {\n', P2),
]

CO = E + 'EngineCommands.swift'
S1T = 'EngineLongPurgeTurnLogTests'
S1_REGION = """        let turnBegan = self.environment.time.monotonicNow()
        let jobsBefore = self.state.jobs.count
        let groupsBefore = self.state.groups.count
        self.state.purgeEpoch += 1
        // The store clears the stamp before its first await of the purge (R-CLN-6).
        self.state.lastStamp = nil
        // A purge unbinds what it removes: nothing the engine saw bound before it is assumed present (L4-R5).
        self.dropBindings()
        self.settleRun(.cancelled)
        self.withdrawPurged(request)
        self.state.commitTurnMarksForTests?(true)
"""
def s1_move(lines_to_move):
    out = S1_REGION
    for l in lines_to_move:
        out = out.replace(l + '\n', '', 1)
    return out.replace('        self.withdrawPurged(request)\n', '        self.withdrawPurged(request)\n' + ''.join(l + '\n' for l in lines_to_move), 1)
M += [
 ('s1-ge', CO, '        guard elapsed > Self.turnTimeLimit else {', '        guard elapsed >= Self.turnTimeLimit else {', S1T),
 ('s1-no-line', CO, '        self.logLongPurgeTurn(since: turnBegan, jobs: jobsBefore, groups: groupsBefore)\n', '        _ = (turnBegan, jobsBefore, groupsBefore)\n', S1T),
 ('s1-late-start', CO, S1_REGION, s1_move(['        let turnBegan = self.environment.time.monotonicNow()']), S1T),
 ('s1-jobs-after', CO, S1_REGION, s1_move(['        let jobsBefore = self.state.jobs.count']), S1T),
 ('s1-groups-after', CO, S1_REGION, s1_move(['        let groupsBefore = self.state.groups.count']), S1T),
]
ENV = dict(os.environ, TMPDIR=S + '/tmp', CLANG_MODULE_CACHE_PATH=S + '/tmp/mc')
def load():
    return subprocess.run(['sysctl', '-n', 'vm.loadavg'], capture_output=True, text=True).stdout.strip()
def sh(args, log):
    with open(log, 'w') as f:
        return subprocess.run(args, stdout=f, stderr=subprocess.STDOUT, env=ENV, cwd=W).returncode
def summarize(log):
    text = open(log, errors='replace').read()
    runs = re.findall(r'Test run with .*', text)
    issues = re.findall(r'recorded an issue(?: with \d+ arguments? (.*?))? at (\S+?\.swift:\d+)', text)
    byarg = {}
    for arg, loc in issues:
        key = 'visit' if 'followVisitedFirst' in arg else ('swept' if 'sweepFollowsFirst' in arg else (arg or 'noarg'))
        byarg.setdefault(key, []).append(loc.split('/')[-1])
    tl = len(re.findall(r'[Tt]ime limit', text))
    return runs[-1] if runs else 'NO RUN LINE', byarg, tl
def build(tag):
    return sh(['swift', 'build', '--package-path', SNAP, '--scratch-path', BUILD, '--build-tests'], f'{LOG}/{tag}-build.log')
def test(tag, flt, n):
    log = f'{LOG}/{tag}-run{n}.log'
    t0 = time.time()
    rc = sh(['swift', 'test', '--package-path', SNAP, '--scratch-path', BUILD, '--skip-build', '--filter', flt], log)
    return rc, time.time() - t0, summarize(log)
out = open(S + '/logs/mut-summary.txt', 'a')
def say(s):
    print(s, flush=True); out.write(s + '\n'); out.flush()
which = sys.argv[1:] or ['baseline'] + [m[0] for m in M]
for name in which:
    if name == 'baseline':
        say(f'== baseline start {time.strftime("%T")} load {load()}')
        rc = build('baseline'); say(f'baseline build rc={rc} {time.strftime("%T")} load {load()}')
        allf = '|'.join(sorted({m[4] for m in M}))
        for n in (1, 2):
            rc, dt, (line, byarg, tl) = test('baseline', allf, n)
            say(f'baseline run{n} rc={rc} {dt:.1f}s: {line} issues={ {k: len(v) for k, v in byarg.items()} } timelimit={tl} load {load()}')
        continue
    spec = [m for m in M if m[0] == name][0]
    _, path, old, new, flt = spec
    p = SNAP + '/' + path
    src = open(p).read()
    count = src.count(old)
    if count != 1:
        say(f'!! {name}: old text occurs {count} times in {path}; skipped'); continue
    open(p, 'w').write(src.replace(old, new))
    try:
        say(f'== {name} ({path}) start {time.strftime("%T")} load {load()}')
        rc = build(name)
        if rc != 0:
            say(f'{name}: build FAILED rc={rc}'); continue
        for n in (1, 2):
            rc, dt, (line, byarg, tl) = test(name, flt, n)
            detail = {k: sorted(set(v)) for k, v in byarg.items()}
            say(f'{name} run{n} rc={rc} {dt:.1f}s: {line} | per order: { {k: len(v) for k, v in byarg.items()} } | locs {detail} | timelimit-mentions={tl} | load {load()}')
    finally:
        open(p, 'w').write(src)
        assert open(p).read() == src
say(f'== done {time.strftime("%T")}')
