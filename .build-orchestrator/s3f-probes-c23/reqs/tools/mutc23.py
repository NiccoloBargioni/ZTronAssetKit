# Cycle-23 reqs verifier (independent of the fixer): re-applies the original defects as mutants in a scratch copy of
# d88bdb1 (Sync-only package under .build-verify-s3f-c23-reqs/mut/src) and runs each kill test twice per mutant.
# Usage: python3 mutc23.py baseline|mutants [names...]
import os, re, signal, subprocess, sys, time

W = '/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f'
R = W + '/.build-verify-s3f-c23-reqs'
SRC = R + '/mut/src'
BUILD = R + '/mut/build'
LOG = R + '/mut/logs'
T = R + '/tmp'
env = dict(os.environ, TMPDIR=T, CLANG_MODULE_CACHE_PATH=T + '/module-cache', LLVM_PROFILE_FILE=T + '/mut-%p.profraw')
E = 'Sources/ZTronAssetSync/Engine/'
FA, FO, MV, JO, CO = (E + n for n in ('EngineFailures.swift', 'EngineFollow.swift', 'EngineMoves.swift', 'EngineJobs.swift', 'EngineCommands.swift'))

OWNER_T = 'owedRerouteOfAWaiterRemovedAheadCountsForNothing'
PINEND_T = 'waitingJoinPinnedToACommittedJobEndsUnderItsChainAtA429'
UNLISTED_T = 'waitingUnlistedJoinCountsTowardA429sLane'
HOLDERS_T = 'barrierContinuesAnOwedMoveInsideItsHoldersPublication'
LAYER_T = 'layerOfAnOwedBatchPinsAVerdictBetweenItAndALaterJoin'
P2 = 'afterVerdictVisitInsideAnENOSPCsReadGetsItsVerdict|afterVerdictVisitForAnApplyInsideAnENOSPCsReadSkipsItsVerdict'
P1 = 'owedReroutePinnedToAJobInItsSpaceReadGetsItsVerdict|userJoinFromJustBeforeAnENOSPCReplayedInItsReadGetsItsVerdict|userJoinFromInsideAnENOSPCsReadSkipsItsVerdict'
S1 = 'EngineLongPurgeTurnLogTests'
ATSD = 'shutdownClearsTheJoinsBehindAVerdict'
D5 = 'barrierMakesAMoveOntoAJobItsDrainedPublicationReQueued'

COUNTDOWN = '            self.state.reroutesWaiting -= 1\n            self.releaseRerouteHolds()\n'
VISIT = '        if self.state.inFollowVisit || self.state.visitingAfterVerdict {\n'
P1_RULE = ('        guard let reading = self.state.reading, let stamped = job.attemptEnd?.stamped else {\n'
           '            return false\n'
           '        }\n'
           '        return reading.serial <= stamped')
LOGCALL = '        self.state.commitTurnMarksForTests?(true)\n        self.logLongPurgeTurn(since: turnBegan, jobs: jobsBefore, groups: groupsBefore)\n'

M = [
    # run 12's five kill tests, each against the survivor(s) it names (texts as cycles 21/22 defined them)
    ('b22-no-waiter-owner', FA, 'guard let waiter = self.state.waiters[item.token], !waiter.fromStore, waiter.asset == item.asset, waiter.transfer == batch.from else {', 'guard self.state.waiters[item.token] != nil || true else {', OWNER_T),
    ('p7-forget-at-last-batch', FO, COUNTDOWN, '            self.state.reroutesWaiting -= 1\n            if self.state.reroutesWaiting == 0 {\n                self.state.reroutePinCommits = [:]\n            }\n            self.releaseRerouteHolds()\n', PINEND_T),
    ('r5-lane-engine-copy', FA, 'let listed = (self.joinListing(join) ?? copy).entry(for: join.asset)', 'let listed = copy.entry(for: join.asset)', PINEND_T),
    ('r8-fast-any-join', FA, 'if join.chain != nil, !here(join.asset) {', 'if !here(join.asset) {', UNLISTED_T),
    ('vy-owed-moves-too', MV, '        let rerouting = listing == nil ? self.state', '        let rerouting = true ? self.state', HOLDERS_T),
    ('r2c-made-ignores-verdicts', FO, 'if let made, made.previous == previous, made.verdicts == verdicts.count {', 'if let made, made.previous == previous {', LAYER_T),
    # e1-P2's other side
    ('p2-after-verdict-replay-rule', JO, VISIT, '        if self.state.inFollowVisit {\n', P2),
    # 64f276d: e1-P1's other side must now fail on answers/counts, not on a time limit
    ('p1-rule-false', JO, P1_RULE, '        return false', P1),
    # row 3's set-up check: a T20 regression (relane's .failed arm never re-queues) must fail A-T-SD
    ('t20-never', JO, '            if isUser, disposition != .untilEntryChanges, self.originAdmitsUser() {', '            if isUser, disposition != .untilEntryChanges, self.originAdmitsUser(), !isUser {', ATSD),
    # S1's line
    ('s1-no-line', CO, '        self.log.log(.sync, .info, "long purge turn: \\(milliseconds) ms, \\(jobs) jobs, \\(groups) groups")', '        _ = milliseconds', S1),
    ('s1-ge', CO, 'guard elapsed > Self.turnTimeLimit else {', 'guard elapsed >= Self.turnTimeLimit else {', S1),
    ('s1-counts-after', CO, LOGCALL, '        self.state.commitTurnMarksForTests?(true)\n        self.logLongPurgeTurn(since: turnBegan, jobs: self.state.jobs.count, groups: self.state.groups.count)\n', S1),
    ('s1-read-before-end-mark', CO, LOGCALL, '        self.logLongPurgeTurn(since: turnBegan, jobs: jobsBefore, groups: groupsBefore)\n        self.state.commitTurnMarksForTests?(true)\n', S1),
    ('s1-level-debug', CO, '.sync, .info, "long purge turn', '.sync, .debug, "long purge turn', S1),
    ('s1-limit-11ms', CO, 'static let turnTimeLimit: TimeInterval = 0.010', 'static let turnTimeLimit: TimeInterval = 0.011', S1),
]
BASE = [OWNER_T, PINEND_T, UNLISTED_T, HOLDERS_T, LAYER_T, P2, P1, ATSD, S1, D5]


def loads():
    return subprocess.run(['sysctl', '-n', 'vm.loadavg'], capture_output=True, text=True).stdout.strip()


def build(tag):
    log = f'{LOG}/{tag}-build.log'
    t0 = time.time()
    b = subprocess.run(['swift', 'build', '--build-tests', '--scratch-path', BUILD], cwd=SRC, env=env, stdout=open(log, 'w'), stderr=subprocess.STDOUT)
    return b.returncode == 0, time.time() - t0


def run(tag, flt, timeout=900):
    log = f'{LOG}/{tag}.log'
    proc = subprocess.Popen(['swift', 'test', '--skip-build', '--scratch-path', BUILD, '--filter', flt], cwd=SRC, env=env, stdout=open(log, 'w'), stderr=subprocess.STDOUT, start_new_session=True)
    try:
        proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait()
        return 'TIMEOUT', {}, 0, 0
    text = open(log, errors='replace').read().splitlines()
    summ = [l.strip() for l in text if 'Test run with' in l]
    issues = [l for l in text if l.startswith('✘ Test') and 'recorded an issue' in l]
    byorder, tl = {}, 0
    for l in issues:
        m = re.search(r'visit → \.(\w+)', l)
        order = m.group(1) if m else '-'
        at = l.split(' at ', 1)[-1] if ' at ' in l else l
        if 'Time limit was exceeded' in l:
            tl += 1
            order += '(TIMELIMIT)'
        loc = at.split(': ')[0]
        loc = loc.rsplit(':', 1)[0] if loc.count(':') >= 2 else loc
        byorder.setdefault(order, set()).add(loc)
    return (summ[-1] if summ else 'NO SUMMARY'), byorder, tl, len(issues)


def fmt(byorder):
    return '; '.join(f'{o}: ' + ', '.join(sorted(s)[:6]) for o, s in sorted(byorder.items()))


def main():
    os.makedirs(LOG, exist_ok=True)
    mode = sys.argv[1]
    names = sys.argv[2:]
    out = open(f'{R}/mut/results.txt', 'a')

    def say(s):
        print(s, flush=True)
        out.write(s + '\n')
        out.flush()

    say(f'== {mode} start {time.strftime("%H:%M:%S")} load {loads()}')
    if mode == 'baseline':
        ok, secs = build('baseline')
        say(f'baseline build ok={ok} {secs:.0f}s load {loads()}')
        if not ok:
            return
        for flt in (names or BASE):
            for r in (1, 2):
                s, bo, tl, n = run(f'base-{flt[:40]}-run{r}', flt)
                say(f'base {flt[:60]} run{r}: {s} | issues {n} {fmt(bo)} | load {loads()}')
    else:
        chosen = [m for m in M if not names or m[0] in names]
        for name, path, old, new, flt in chosen:
            p = os.path.join(SRC, path)
            text = open(p).read()
            c = text.count(old)
            if c != 1:
                say(f'{name}: count {c} != 1, skipped')
                continue
            line = text[:text.index(old)].count('\n') + 1
            open(p, 'w').write(text.replace(old, new))
            try:
                ok, secs = build(name)
                if not ok:
                    say(f'{name} ({path}:{line}): BUILD FAILED')
                    continue
                for r in (1, 2):
                    s, bo, tl, n = run(f'{name}-run{r}', flt)
                    killed = s != 'TIMEOUT' and 'failed' in s
                    say(f'{name} ({path.split("/")[-1]}:{line}) run{r}: {"KILLED" if killed else "SURVIVED" if s != "TIMEOUT" else "TIMEOUT"} | {s} | issues {n}, time-limit issues {tl} | {fmt(bo)} | build {secs:.0f}s | load {loads()}')
            finally:
                open(p, 'w').write(text)
        d = subprocess.run(['git', '-C', W, 'diff', '--no-index', '--stat', W + '/Sources/ZTronAssetSync', SRC + '/Sources/ZTronAssetSync'], capture_output=True, text=True)
        say('revert check (snapshot vs worktree Sync sources): ' + ('identical' if not d.stdout.strip() else d.stdout[:300]))
    say(f'== {mode} end {time.strftime("%H:%M:%S")} load {loads()}')


main()
