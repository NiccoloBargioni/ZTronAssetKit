# Cycle-22 reqs verifier's mutation runner (scratch only). Usage: python3 mutrun.py <mutants.py> [name ...]
# Applies each mutant to the scratch copy, builds, runs its filter twice, reverts. Logs under mut/logs.
import os, re, subprocess, sys, time, signal

ROOT = '/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-verify-s3f-c22-reqs'
SRC = ROOT + '/mut/src'
BUILD = ROOT + '/mut/build'
LOGS = ROOT + '/mut/logs'
TMP = ROOT + '/tmp'
os.makedirs(LOGS, exist_ok=True)
ENV = dict(os.environ, TMPDIR=TMP, CLANG_MODULE_CACHE_PATH=TMP + '/module-cache', LLVM_PROFILE_FILE=TMP + '/prof-%p.profraw')

def load():
    return subprocess.run(['sysctl', '-n', 'vm.loadavg'], capture_output=True, text=True).stdout.strip()

def run(cmd, log, timeout):
    t0 = time.time()
    with open(log, 'w') as fh:
        p = subprocess.Popen(cmd, stdout=fh, stderr=subprocess.STDOUT, env=ENV, start_new_session=True)
        try:
            rc = p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGTERM)
            time.sleep(3)
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            p.wait()
            rc = 'TIMEOUT'
    return rc, time.time() - t0

def summarize(log):
    text = open(log, errors='replace').read()
    runs = re.findall(r'Test run with .*', text)
    issues = re.findall(r'recorded an issue.*? at ([A-Za-z0-9_]+\.swift:\d+:\d+)', text)
    limits = len(re.findall(r'time limit', text))
    uniq = []
    for i in issues:
        if i not in uniq:
            uniq.append(i)
    return (runs[-1] if runs else 'NO TEST RUN LINE'), uniq[:8], len(issues), limits

def main():
    spec = {}
    exec(open(sys.argv[1]).read(), spec)
    wanted = sys.argv[2:]
    out = open(ROOT + '/mut/results.txt', 'a')
    for (name, rel, old, new, filt) in spec['M']:
        if wanted and name not in wanted:
            continue
        path = os.path.join(SRC, rel)
        orig = open(path).read()
        n = orig.count(old)
        if n != 1:
            msg = f'{name}: ANCHOR COUNT {n} in {rel} (not applied)'
            print(msg); out.write(msg + '\n'); out.flush()
            continue
        open(path, 'w').write(orig.replace(old, new))
        try:
            brc, bt = run(['swift', 'build', '--package-path', SRC, '--scratch-path', BUILD, '--build-tests'], f'{LOGS}/{name}-build.log', 1800)
            if brc != 0:
                msg = f'{name}: BUILD FAILED rc={brc} ({bt:.0f}s) load {load()}'
                print(msg); out.write(msg + '\n'); out.flush()
                continue
            for i in (1, 2):
                l0 = load()
                rc, t = run(['swift', 'test', '--package-path', SRC, '--scratch-path', BUILD, '--skip-build', '--filter', filt], f'{LOGS}/{name}-run{i}.log', 900)
                line, issues, nissues, limits = summarize(f'{LOGS}/{name}-run{i}.log')
                msg = f'{name} run{i}: rc={rc} {t:.0f}s load {l0} -> {load()} | {line} | issues={nissues} timelimit-mentions={limits} | {issues}'
                print(msg); out.write(msg + '\n'); out.flush()
        finally:
            open(path, 'w').write(orig)
    out.close()

main()
