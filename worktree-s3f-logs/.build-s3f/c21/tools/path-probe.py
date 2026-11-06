#!/usr/bin/env python3
"""Which existing tests take the commit's owing path (integrate-rr21.md's unconfirmed "which existing tests change
path"): a scratch copy of the working tree whose `deferReroutes` prints a marker, the Sync tests run serially, each
marker attributed to the test that started last. Writes .build-s3f/c21/path-probe/summary.txt."""
import os, subprocess, re, time
WT = '/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f'
RED = WT + '/.build-s3f/red'
BUILD = RED + '/.build-s3f/redbuild'
OUT = WT + '/.build-s3f/c21/path-probe'
os.makedirs(OUT, exist_ok=True)
env = dict(os.environ)
env.update(TMPDIR=WT + '/.build-s3f/tmp', CLANG_MODULE_CACHE_PATH=WT + '/.build-s3f/tmp/module-cache', LLVM_PROFILE_FILE=WT + '/.build-s3f/tmp/default-%p.profraw')
def load():
    return os.popen('sysctl -n vm.loadavg').read().strip()
summary = open(OUT + '/summary.txt', 'w')
summary.write(f'start {time.strftime("%H:%M")} load {load()}\n'); summary.flush()
subprocess.run(['rsync', '-a', '--delete', WT + '/Sources/', RED + '/Sources/'], check=True)
subprocess.run(['rsync', '-a', '--delete', WT + '/Tests/', RED + '/Tests/'], check=True)
subprocess.run(['cp', WT + '/Package.swift', RED + '/Package.swift'], check=True)
path = RED + '/Sources/ZTronAssetSync/Engine/EngineFollow.swift'
src = open(path).read()
old = '''    func deferReroutes(_ items: [RerouteItem], from transfer: TransferID) {
'''
new = old + '''        print("RR21-PROBE-OWES \\(items.count)")
'''
assert src.count(old) == 1
open(path, 'w').write(src.replace(old, new))
b = subprocess.run(['swift', 'build', '--build-tests', '--scratch-path', BUILD], cwd=RED, env=env, capture_output=True, text=True)
open(OUT + '/build.log', 'w').write(b.stdout + b.stderr)
if b.returncode != 0:
    summary.write('build failed\n'); summary.close(); raise SystemExit(1)
log = OUT + '/test.log'
t = subprocess.run(['script', '-q', log, 'swift', 'test', '--skip-build', '--no-parallel', '--scratch-path', BUILD, '--filter', 'ZTronAssetSyncTests'], cwd=RED, env=env, capture_output=True, text=True, timeout=5400)
text = re.sub(r"\x1b\[[0-9;]*m", "", open(log, errors='replace').read())
current = None
hits = {}
overlap = 0
running = 0
for line in text.splitlines():
    m = re.match(r'^◇ Test (.+) started\.$', line)
    if m:
        if running > 0:
            overlap += 1
        current = m.group(1)
        running += 1
        continue
    if re.match(r'^[✔✘] Test .+ (passed|failed)', line) and 'Test run with' not in line:
        running = max(0, running - 1)
    if 'RR21-PROBE-OWES' in line:
        hits.setdefault(current, []).append(line.split('RR21-PROBE-OWES')[-1].strip())
runs = [l for l in text.splitlines() if 'Test run with' in l]
summary.write(f'exit {t.returncode} | {runs[-1].strip() if runs else "no run line"} | overlapping starts {overlap} | load {load()}\n')
for name in sorted(hits, key=lambda n: n or ''):
    summary.write(f'{len(hits[name]):4d} owings  {name}  sizes {sorted(set(hits[name]))[:6]}\n')
summary.write(f'end {time.strftime("%H:%M")} load {load()}\n')
summary.close()
