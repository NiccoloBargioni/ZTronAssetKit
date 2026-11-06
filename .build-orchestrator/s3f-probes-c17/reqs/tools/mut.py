#!/usr/bin/env python3
"""Scratch mutant runner (s3f cycle-17 verification, requirements lens; never committed). Applies each named mutant to
the probe copy p/ (HEAD plus scratch probes), builds it into pbuild/, runs its filter `runs` times, reverts, and checks
the copy's Sources match HEAD again. Usage: mut.py <mutant> <filter> [runs]."""
import os, re, subprocess, sys, time
ROOT = '/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f'
S = ROOT + '/.build-verify-s3f-c17-reqs'
P, BUILD, LOGS = S + '/p', S + '/pbuild', S + '/logs/mut'
E = 'Sources/ZTronAssetSync/Engine/'
FOL, FAI, DIS, JOB = E + 'EngineFollow.swift', E + 'EngineFailures.swift', E + 'EngineDispatch.swift', E + 'EngineJobs.swift'

SPACE_CASE = ('            var measured = job\n'
              '            measured.lastError = self.spaceFigures(job, required: required)\n'
              '            switch self.spaceVerdict(measured) {\n'
              '            case .retry, .awaitReclaim:\n'
              '                return self.reachesCap(interest.lane, attempts: attempts)\n'
              '            case .insufficient:\n'
              '                return self.failFastError(.insufficientSpace, for: interest, of: measured, at: now) != nil\n'
              '            }\n')
RETRY_AFTER = ('            let kept = job.interests.values.filter { !self.reachesCap($0.lane, attempts: attempts) }.map(\\.lane).max() ?? interest.lane\n'
               '            return self.retryDelay(job.transfer, error: error, attempts: attempts, lane: kept, wall: self.environment.time.now()) == nil\n')
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
INBOUND_MOVE = ('            _ = self.withReading(self.state.followStamps[holder] ?? self.worldStamp()) {\n'
                '                self.move(job.assets.intersection(ids), of: job)\n'
                '            }\n')

M = {
    # The original defects of the cycle-16 blocking findings, re-applied.
    'retryAfterDrop': [(FAI, RETRY_AFTER, '            _ = error\n            return false\n')],
    'throttleFailFastDrop': [(FAI, '                return self.failFastError(.throttled(until: end), for: interest, of: job, at: now) != nil\n', '                _ = end\n                return false\n')],
    'offlineFailFastDrop': [(FAI, '            return !requeue && self.failFastError(.offline, for: interest, of: job, at: now) != nil\n', '            _ = requeue\n            return false\n')],
    'spaceOriginal': [(FAI, SPACE_CASE, '            _ = required\n            return false\n')],
    'takeOffDrop': [(FOL, '        let held = job.assets.intersection(job.attemptEnd?.movedBefore ?? [])\n', '        let held: Set<AssetID> = []\n')],
    'rule3Drop': [(JOB, 'if self.state.inFollowVisit, !self.state.bringingInbound, let waiting = self.state.jobs[transfer], waiting.attemptEnd?.deferredAfter != nil {', 'if false, self.state.inFollowVisit, !self.state.bringingInbound, let waiting = self.state.jobs[transfer], waiting.attemptEnd?.deferredAfter != nil {')],
    'bringInboundDrop': [(FOL, '        guard self.followOwed, let target = self.state.jobs[transfer] else {\n', '        guard !transfer.rawValue.isEmpty && false, let target = self.state.jobs[transfer] else {\n')],
    'startEndResetDrop': [(DIS, '        job.attemptEnd = nil\n', '')],
    'startRerouteResetDrop': [(DIS, '        job.rerouteOnPass = nil\n', '')],
    # Fixer's table, re-checked (S3-R3: verifiers re-check the same way).
    'vaKeptLane': [(FAI, 'lane: kept, wall: self.environment.time.now()) == nil', 'lane: interest.lane, wall: self.environment.time.now()) == nil && kept == kept')],
    'flMovedBeforeDrop': [(FAI, 'if visit?.contains(asset) ?? true || movedBefore.contains(asset) {', 'if visit?.contains(asset) ?? true || (movedBefore.contains(asset) && false) {')],
    'relaneGuardRevert': [(JOB, '            if job.attemptEnd?.deferredAfter != nil {\n', '            if self.state.verdictsAfterFollow[transfer] != nil {\n')],
    'deferralFollowOwedDrop': [(FOL, 'let away: Set<AssetID> = self.followOwed ? job.assets.filter { self.state.applied.entry(for: $0)?.transferID != transfer } : []', 'let away: Set<AssetID> = job.assets.filter { self.state.applied.entry(for: $0)?.transferID != transfer }')],
    'publishBringInboundDrop': [(DIS, '        self.bringInbound(transfer)\n', '')],
    'spaceBringInboundDrop': [(FAI, '            self.bringInbound(transfer)\n', '')],
    # New candidates (not in the fixer's table).
    'vaStampDrop': [(FAI, STAMP, '        _ = stamp\n        return self.verdictAnswers(verdict, interest, of: job)\n')],
    'bringInboundStampDrop': [(FOL, INBOUND_MOVE, '            _ = self.move(job.assets.intersection(ids), of: job)\n')],
    'takeOffAssetsKeep': [(FOL, '        self.state.jobs[job.transfer]?.assets.subtract(held)\n', '')],
    'rerouteOnPassKeepWhole': [(FOL, RECORD, RECORD_OLD)],
}


def head(path):
    return subprocess.run(['git', '-C', ROOT, 'show', 'HEAD:' + path], capture_output=True, text=True, check=True).stdout


def run(cmd, log):
    with open(log, 'w') as f:
        r = subprocess.run(cmd, cwd=P, stdout=f, stderr=subprocess.STDOUT)
    return r.returncode


def main():
    name, flt = sys.argv[1], sys.argv[2]
    runs = int(sys.argv[3]) if len(sys.argv) > 3 else 2
    os.makedirs(LOGS, exist_ok=True)
    edits = M[name]
    originals = {}
    for path, old, new in edits:
        full = os.path.join(P, path)
        if path not in originals:
            text = open(full).read()
            assert text == head(path), f'{path} differs from HEAD before mutating'
            originals[path] = text
        cur = open(full).read()
        n = cur.count(old)
        assert n == 1, f'{name}: {path}: expected 1 match, found {n}'
        open(full, 'w').write(cur.replace(old, new))
    out = []
    try:
        t = time.time()
        rc = run(['swift', 'build', '--build-tests', '--scratch-path', BUILD], f'{LOGS}/{name}-build.log')
        out.append(f'{name}: build rc={rc} ({time.time() - t:.0f} s) load={os.getloadavg()[0]:.1f}')
        if rc == 0:
            for i in range(1, runs + 1):
                log = f'{LOGS}/{name}{"-bundle" if len(sys.argv) > 4 else ""}-run{i}.log'
                cmd = ['swift', 'test', '--skip-build', '--scratch-path', BUILD, '--filter', flt]
                if len(sys.argv) > 4:
                    cmd += ['--skip', sys.argv[4]]
                rc = run(cmd, log)
                text = open(log).read()
                summary = [l for l in text.splitlines() if 'Test run with' in l]
                issues = [re.sub(r'\s+', ' ', l)[:300] for l in text.splitlines() if l.startswith('✘') and ('Expectation failed' in l or 'Time limit' in l or 'Issue recorded' in l or 'error' in l.lower() or 'require' in l)]
                out.append(f'  run{i} rc={rc} load={os.getloadavg()[0]:.1f} {summary[-1] if summary else "(no summary)"}')
                out.extend('    ' + l for l in issues[:10])
    finally:
        for path, text in originals.items():
            open(os.path.join(P, path), 'w').write(text)
        for path in originals:
            assert open(os.path.join(P, path)).read() == head(path), f'revert failed for {path}'
        diff = subprocess.run(['git', '-C', ROOT, 'diff', '--no-index', '--quiet', ROOT + '/Sources', P + '/Sources'])
        out.append(f'  reverted: {", ".join(sorted(originals))} == HEAD; copy Sources vs worktree diff rc={diff.returncode}')
    print('\n'.join(out))
    with open(f'{LOGS}/summary.log', 'a') as f:
        f.write('\n'.join(out) + '\n')


main()
