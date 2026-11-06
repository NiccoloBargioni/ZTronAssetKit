#!/usr/bin/env python3
"""Red-first runs of rr21-C3's four holes: for each, a scratch copy of the working tree with the hole's guard removed,
built and run on the hole's test (S3-R26 item 11). Writes .build-s3f/c21/red-holes/summary.txt."""
import os, subprocess, re, time
WT = '/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f'
RED = WT + '/.build-s3f/red'
BUILD = RED + '/.build-s3f/redbuild'
OUT = WT + '/.build-s3f/c21/red-holes'
os.makedirs(OUT, exist_ok=True)
env = dict(os.environ)
env.update(TMPDIR=WT + '/.build-s3f/tmp', CLANG_MODULE_CACHE_PATH=WT + '/.build-s3f/tmp/module-cache', LLVM_PROFILE_FILE=WT + '/.build-s3f/tmp/default-%p.profraw')
E = 'Sources/ZTronAssetSync/Engine/'
HOLES = [
    ('RR21-HOP', E + 'EngineFollow.swift', '            let inFlight = publishing ?? self.publishingEnds()\n', '            let inFlight = publishing ?? [:]\n',
     'owedReroutePinnedToAPublishingJobGetsItsIntegrityFailure|owedReroutePinnedToAPublishingJobGetsItsStorageFailure'),
    ('RR21-WINDOW-GATE', E + 'EngineFollow.swift', 'if self.state.followMoving?.holder == transfer || self.state.reroutesWaiting > 0 {', 'if self.state.followMoving?.holder == transfer {',
     'publicationDuringTheWindowBindsTheOwedIDsBehindAClosedGate'),
    ('RR21-PRESENT-PRUNE', E + 'EnginePresence.swift', 'self.state.presenceReaders == 0, self.state.eventsAfterFollow.isEmpty else {', 'self.state.presenceReaders == 0 else {',
     'owedReroutesOntoAPresentContentAreServedFromTheStore'),
    ('RR21-RUN-MIDDRAIN', E + 'EngineRuns.swift', '!self.state.runClaimTakenOff, self.state.reroutesWaiting == 0 else {', '!self.state.runClaimTakenOff else {',
     'runSettlesOnlyAfterTheOwedBatchItsVerdictDrainsWith'),
]
def load():
    return os.popen('sysctl -n vm.loadavg').read().strip()
summary = open(OUT + '/summary.txt', 'w')
head = subprocess.run(['git', '-C', WT, 'rev-parse', '--short', 'HEAD'], capture_output=True, text=True).stdout.strip()
summary.write(f'start {time.strftime("%H:%M")} worktree {head} + uncommitted C3 load {load()}\n'); summary.flush()
for name, path, old, new, filt in HOLES:
    subprocess.run(['rsync', '-a', '--delete', WT + '/Sources/', RED + '/Sources/'], check=True)
    subprocess.run(['rsync', '-a', '--delete', WT + '/Tests/', RED + '/Tests/'], check=True)
    subprocess.run(['cp', WT + '/Package.swift', RED + '/Package.swift'], check=True)
    src = open(RED + '/' + path).read()
    if src.count(old) != 1:
        summary.write(f'{name}: guard text found {src.count(old)} times; skipped\n'); summary.flush(); continue
    open(RED + '/' + path, 'w').write(src.replace(old, new))
    b = subprocess.run(['swift', 'build', '--build-tests', '--scratch-path', BUILD], cwd=RED, env=env, capture_output=True, text=True)
    open(f'{OUT}/{name}-build.log', 'w').write(b.stdout + b.stderr)
    if b.returncode != 0:
        errs = sorted(set(l for l in (b.stdout + b.stderr).splitlines() if 'error:' in l))[:5]
        summary.write(f'{name}: build failed {errs}\n'); summary.flush(); continue
    log = f'{OUT}/{name}-test.log'
    t = subprocess.run(['script', '-q', log, 'swift', 'test', '--skip-build', '--scratch-path', BUILD, '--filter', filt], cwd=RED, env=env, capture_output=True, text=True, timeout=900)
    text = open(log, errors='replace').read()
    issues = re.findall(r'(\w+Tests\.swift:\d+:\d+): (Expectation failed|Requirement failed)[^\n]*', text)
    first = [l for l in text.splitlines() if 'Expectation failed' in l or 'Requirement failed' in l][:4]
    runs = [l for l in text.splitlines() if 'Test run with' in l]
    summary.write(f'{name} ({filt}): exit {t.returncode} | {runs[-1].strip() if runs else "no run line"} | load {load()}\n')
    for l in first:
        summary.write('    ' + l.strip()[:900] + '\n')
    summary.flush()
summary.write(f'end {time.strftime("%H:%M")} load {load()}\n')
summary.close()
