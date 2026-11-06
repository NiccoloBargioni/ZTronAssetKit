#!/usr/bin/env python3
"""Scratch mutant runner (s3f cycle-16 verification, requirements lens). Applies each named mutant to the probe copy
p/, builds it into pbuild/, runs its filter twice, reverts, and checks the copy matches HEAD again."""
import os, re, subprocess, sys, time
ROOT = '/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f'
S = ROOT + '/.build-verify-s3f-c16-reqs'
P, BUILD, LOGS = S + '/p', S + '/pbuild', S + '/logs/mut'
E = 'Sources/ZTronAssetSync/Engine/'
FOL, FAI, DIS = E + 'EngineFollow.swift', E + 'EngineFailures.swift', E + 'EngineDispatch.swift'
M = {
    'consumeDrop': [(FOL, '        if reroute != nil {\n            self.state.jobs[transfer]?.rerouteOnPass = []\n        }\n', '')],
    'followGenerationDrop': [(FOL, 'let reroute = job.rerouteFor == self.state.followsEnded ? job.rerouteOnPass ?? [] : []', 'let reroute = job.rerouteOnPass ?? []')],
    'failedNeverPasses': [(FOL, '            guard let end = job.attemptEnd else {\n                return nil\n            }\n            if end.deferredAfter == nil', '            guard let end = job.attemptEnd, false else {\n                return nil\n            }\n            if end.deferredAfter == nil')],
    'publicationEndDrop': [(DIS, '        self.recordPublicationEnd(transfer)\n', '')],
    'spaceDeferralRecordDrop': [(FAI, '            self.recordDeferredVerdict(transfer)\n', '')],
    'spaceFailureEpochDropped': [(FOL, 'guard let job = self.state.jobs[transfer], job.epoch == epoch else {', 'guard let job = self.state.jobs[transfer] else {')],
    'laneJobsWalkAlways': [(FAI, 'if lane != .userInitiated, self.followOwed || !verdicts.isEmpty {', 'if lane != .userInitiated {')],
    'laneVisitOwedDrop': [(FAI, 'let visit = self.followOwed ? self.rerouteOnVisit(other) : []', 'let visit = self.rerouteOnVisit(other)')],
    'followAfterVerdictEpochDrop': [(FOL, 'guard moves, self.state.jobs[transfer]?.epoch == epoch else {', 'guard moves else {')],
    'deferralFollowOwedDrop': [(FOL, 'let moved: Set<AssetID> = self.followOwed ? job.assets.filter { self.state.applied.entry(for: $0)?.transferID != transfer } : []', 'let moved: Set<AssetID> = job.assets.filter { self.state.applied.entry(for: $0)?.transferID != transfer }')],
    'startEndResetDrop': [(DIS, '        job.attemptEnd = nil\n', '')],
    'startRerouteResetDrop': [(DIS, '        job.rerouteOnPass = nil\n', '')],
    'rr11ProtoFix': [(FAI, '        case .attempt(.retry):\n            let policy = interest.lane == .userInitiated ? self.tuning.interactiveRetry : self.tuning.retry\n            return job.attempts + 1 >= max(1, policy.maxAttemptsPerRun)\n', '        case .attempt(.retry(let error, _)):\n            let policy = interest.lane == .userInitiated ? self.tuning.interactiveRetry : self.tuning.retry\n            if job.attempts + 1 >= max(1, policy.maxAttemptsPerRun) {\n                return true\n            }\n            let kept = job.lane == .userInitiated ? self.tuning.interactiveRetry : self.tuning.retry\n            if case .transient(_, let hint?) = error, hint.seconds(from: self.environment.time.now()) > kept.maxRetryAfter {\n                return true\n            }\n            return false\n')],
}
M['staleOriginal'] = M['consumeDrop'] + M['followGenerationDrop']
M['enospcOriginal'] = M['publicationEndDrop'] + M['spaceDeferralRecordDrop']
M['laneOriginal'] = M['laneJobsWalkAlways'] + M['laneVisitOwedDrop']

def head(path):
    return subprocess.run(['git', '-C', ROOT, 'show', 'HEAD:' + path], capture_output=True, text=True, check=True).stdout

def run(cmd, log):
    with open(log, 'w') as f:
        r = subprocess.run(cmd, cwd=P, stdout=f, stderr=subprocess.STDOUT)
    return r.returncode

def main():
    name, flt, runs = sys.argv[1], sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 2
    edits = M[name]
    originals = {}
    for path, old, new in edits:
        full = os.path.join(P, path)
        text = originals.get(path) or open(full).read()
        assert text == head(path) or path in originals, f'{path} differs from HEAD before mutating'
        originals.setdefault(path, text)
        cur = open(full).read()
        n = cur.count(old)
        assert n == 1, f'{name}: {path}: expected 1 match, found {n}'
        open(full, 'w').write(cur.replace(old, new))
    out = []
    try:
        t = time.time()
        rc = run(['swift', 'build', '--build-tests', '-j', '6', '--scratch-path', BUILD], f'{LOGS}/{name}-build.log')
        out.append(f'{name}: build rc={rc} ({time.time() - t:.0f} s)')
        if rc == 0:
            for i in range(1, runs + 1):
                log = f'{LOGS}/{name}-run{i}.log'
                rc = run(['swift', 'test', '--skip-build', '--scratch-path', BUILD, '--filter', flt], log)
                text = open(log).read()
                summary = [l for l in text.splitlines() if 'Test run with' in l]
                issues = [re.sub(r'\s+', ' ', l)[:330] for l in text.splitlines() if l.startswith('✘') and ('Expectation failed' in l or 'Time limit' in l or 'Issue recorded' in l or 'error' in l.lower())]
                out.append(f'  run{i} rc={rc} {summary[-1] if summary else "(no summary)"}')
                out.extend('    ' + l for l in issues[:8])
    finally:
        for path, text in originals.items():
            open(os.path.join(P, path), 'w').write(text)
        for path in originals:
            assert open(os.path.join(P, path)).read() == head(path), f'revert failed for {path}'
        out.append(f'  reverted: {", ".join(sorted(originals))} == HEAD')
    print('\n'.join(out))
    with open(f'{LOGS}/summary.log', 'a') as f:
        f.write('\n'.join(out) + '\n')

main()
