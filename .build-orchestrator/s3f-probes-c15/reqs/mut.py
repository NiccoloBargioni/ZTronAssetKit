import json, subprocess, sys, os, shutil
R = '/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-verify-s3f-c15-reqs'
SRC = R + '/m'
defs = json.load(open('/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-s3f/c15/mutants.json'))
plan = [l.split(None, 1) for l in open(R + '/mutplan.txt').read().strip().splitlines() if l.strip() and not l.startswith('#')]
env = dict(os.environ, TMPDIR=R + '/tmp', CLANG_MODULE_CACHE_PATH=R + '/tmp/mc', LLVM_PROFILE_FILE=R + '/tmp/%p.profraw')
for name, flt in plan:
    edits = defs[name]['edits']
    backups = {}
    ok = True
    for path, old, new, count in edits:
        p = os.path.join(SRC, path)
        if p not in backups:
            backups[p] = open(p).read()
        text = open(p).read()
        c = text.count(old)
        if c != count:
            print(f'{name}: count {c} != {count} for {path}', flush=True); ok = False; break
        open(p, 'w').write(text.replace(old, new))
    if ok:
        log = f'{R}/mutlogs/{name}-build.log'
        b = subprocess.run(['swift', 'build', '--build-tests', '--scratch-path', R + '/mbuild'], cwd=SRC, env=env, stdout=open(log, 'w'), stderr=subprocess.STDOUT)
        if b.returncode != 0:
            print(f'{name}: BUILD FAILED', flush=True)
        else:
            for run in (1, 2):
                log = f'{R}/mutlogs/{name}-run{run}.log'
                subprocess.run(['swift', 'test', '--skip-build', '--scratch-path', R + '/mbuild', '--filter', flt.strip()], cwd=SRC, env=env, stdout=open(log, 'w'), stderr=subprocess.STDOUT)
                summ = [l for l in open(log, errors='replace') if ('Test run with' in l) or ('✘ Test ' in l and 'failed after' in l)]
                print(f'{name} run{run}: ' + (summ[-1].strip() if summ else 'NO SUMMARY'), flush=True)
    for p, t in backups.items():
        open(p, 'w').write(t)
    d = subprocess.run(['diff', '-r', SRC + '/Sources', '/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/Sources'], capture_output=True, text=True)
    print(f'{name}: revert diff: ' + ('none' if not d.stdout.strip() else d.stdout[:300]), flush=True)
