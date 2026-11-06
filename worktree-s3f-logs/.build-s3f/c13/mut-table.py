#!/usr/bin/env python3
"""Maps every recorded issue of each cycle-13 mutant (full run logs) to the enclosing test at the commit its batch ran on."""
import re, subprocess, pathlib, collections, sys
WT = pathlib.Path("/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f")
C = WT / ".build-s3f/c13"
BATCH = {"a": ("mut", "8f459c3"), "b": ("mut2", "8f459c3"), "c": ("mut3", "dc5e3c3"), "d": ("mut4", "3e3ef0d"),
         "e": ("mut", "3e3ef0d"), "f": ("mut2", "3e3ef0d"), "g": ("mut", "3e3ef0d"), "h": ("mut2", "3e3ef0d"), "i": ("mut", "128fda9")}
_files = {}
def lines_of(commit, fname):
    key = (commit, fname)
    if key not in _files:
        path = subprocess.run(["git", "ls-tree", "-r", "--name-only", commit], cwd=WT, capture_output=True, text=True).stdout.split()
        rel = [p for p in path if p.endswith("/" + fname)]
        _files[key] = subprocess.run(["git", "show", f"{commit}:{rel[0]}"], cwd=WT, capture_output=True, text=True).stdout.splitlines() if rel else []
    return _files[key]
def test_at(commit, fname, line):
    ls = lines_of(commit, fname)
    if not ls:
        return "?"
    i = line - 1
    # a time limit is reported at the @Test line: look forward for the func
    if "@Test" in ls[i]:
        for j in range(i, min(i + 6, len(ls))):
            m = re.search(r"func (\w+)", ls[j])
            if m:
                return m.group(1)
    for j in range(i, -1, -1):
        m = re.search(r"^\s*(?:@\w+[^\n]*)?\s*(?:private |static )?func (\w+)", ls[j])
        if m:
            return m.group(1)
    return "?"
order = []
res = collections.OrderedDict()
for b, (d, commit) in BATCH.items():
    log = C / f"mut-{b}.log"
    if not log.exists():
        continue
    for line in log.read_text().splitlines():
        m = re.match(r"MUTANT (\w+) run (\d): (.*)", line)
        if m:
            res.setdefault((m.group(1), b), {"batch": b, "dir": d, "commit": commit, "runs": {}})
            res[(m.group(1), b)]["runs"][m.group(2)] = m.group(3)
for (name, _b), r in res.items():
    per = collections.OrderedDict()
    vf = 0
    for run in sorted(r["runs"]):
        p = C / r["dir"] / f"{name}-run{run}.log"
        if not p.exists():
            continue
        for line in p.read_text().splitlines():
            if "recorded an issue" not in line:
                continue
            m = re.search(r"at (\w+\.swift):(\d+):\d+: (.*)", line)
            if not m:
                continue
            if "followVisitedFirst" in line:
                vf += 1
            arg = "sweep-first" if "sweepFollowsFirst" in line else ("visit-first" if "followVisitedFirst" in line else "no argument")
            f, ln, msg = m.group(1), int(m.group(2)), m.group(3)
            key = (f, ln, "time limit" if "Time limit" in msg else "", arg)
            per.setdefault(key, set()).add(run)
    print(f"{name} [{r['batch']}@{r['commit']}] runs={len(r['runs'])} visitFirstIssues={vf} :: " + " | ".join(f"run{k}: {v[:70]}" for k, v in r["runs"].items()))
    tests = collections.OrderedDict()
    for (f, ln, tl, arg), runs in per.items():
        t = test_at(r["commit"], f, ln)
        tests.setdefault((f.replace("EngineFollowBarrier", "").replace(".swift", ""), t), []).append(f":{ln}{' (time limit)' if tl else ''}{'' if arg == 'sweep-first' else ' ['+arg+']'}{'' if len(runs) == len(r['runs']) else ' [run '+','.join(sorted(runs))+' only]'}")
    for (f, t), ls in tests.items():
        print(f"    {f} {t}: {', '.join(ls)}")
