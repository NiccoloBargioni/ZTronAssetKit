#!/usr/bin/env python3
"""Compact per-mutant kill table from the mutant runner's logs: exit, issues and failing orders per run."""
import os, re, glob
L = "/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-verify-s3f-c21-reqs/logs/mut"
names = []
for line in open(L + "/summary.txt"):
    m = re.match(r"\S+ ([a-z0-9-]+): (build|run\d)", line)
    if m and m.group(1) not in names:
        names.append(m.group(1))
for n in names:
    parts = []
    for i in (1, 2):
        p = f"{L}/{n}-run{i}.log"
        if not os.path.exists(p):
            continue
        out = open(p, errors="replace").read()
        res = re.findall(r"Test run with (\d+) tests? in \d+ suites? (passed|failed) after ([\d.]+) seconds(?: with (\d+) issues?)?", out)
        orders = set()
        for l in out.splitlines():
            if "recorded an issue" in l:
                if ".sweepFollowsFirst" in l: orders.add("S")
                elif ".followVisitedFirst" in l: orders.add("V")
                else: orders.add("U")
        lines = sorted(set(re.findall(r"at (\w+\.swift:\d+):\d+", out)))
        r = res[-1] if res else ("?", "NO-RESULT", "?", "")
        parts.append(f"run{i} {r[1]} ({r[0]} tests, {r[3] or 0} issues, {r[2]} s) orders {''.join(sorted(orders)) or '-'} lines {', '.join(lines[:4])}")
    print(f"{n}: " + " | ".join(parts))
