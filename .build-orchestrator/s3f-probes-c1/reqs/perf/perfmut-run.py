# Release benchmark mutants: each variant = list of edits; builds release (-enable-testing) and runs three C2 benchmarks.
import sys, os, shutil, subprocess
P = sys.argv[1]; src = os.path.join(P, "src"); build = os.path.join(P, "build")
S = "Sources/ZTronAssetSync/Engine/"
OLD_POP = '''        var low = 0
        var high = self.entries.count
        while low < high {
            let middle = (low + high) / 2
            if self.entries[middle].at <= now {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let count = min(low, max(0, limit))
        let due = Array(self.entries.prefix(count))
        self.entries.removeFirst(count)
        return due'''
NEW_POP = '''        var due: [Deadline] = [] // MUTANT: the s3-base loop, no limit
        while let first = self.entries.first, first.at <= now {
            due.append(self.entries.removeFirst())
        }
        return due'''
VARIANTS = {
 "head": [],
 "original-defects": [
   (S+"DeadlineHeap.swift", OLD_POP, NEW_POP, 1),
   (S+"EngineTimers.swift", "self.state.heap.popDue(at: now, limit: Self.dueDeadlinesPerTurn)", "self.state.heap.popDue(at: now)", 1),
   (S+"EngineShutdown.swift", "if steps == SyncEngine.shutdownStepsPerTurn {", "if steps == -1 {", 2),
   (S+"EngineRuns.swift", "        for transfer in candidates.sorted() {\n", "        _ = candidates\n        for transfer in self.state.jobs.keys.sorted() {\n", 1),
 ],
 "fireDue-no-limit": [
   (S+"EngineTimers.swift", "self.state.heap.popDue(at: now, limit: Self.dueDeadlinesPerTurn)", "self.state.heap.popDue(at: now)", 1),
 ],
}
FILTER = "SyncBenchmarks/(dueRetriesTurns|shutdownTurns|refreshUnderGroupTurns)"
for name in (sys.argv[2:] or list(VARIANTS)):
    shutil.rmtree(os.path.join(src, "Sources")); shutil.copytree(os.path.join(P, "pristine", "Sources"), os.path.join(src, "Sources"))
    ok = True
    for f, old, new, n in VARIANTS[name]:
        p = os.path.join(src, f); t = open(p).read(); c = t.count(old)
        if c != n: print(f"[{name}] ANCHOR COUNT {c} != {n} in {f}", flush=True); ok = False; break
        open(p, "w").write(t.replace(old, new))
    if not ok: continue
    log = os.path.join(P, name + ".log")
    with open(log, "w") as lf:
        lf.write("load before: " + subprocess.run(["uptime"], capture_output=True, text=True).stdout)
        lf.flush()
        r = subprocess.run(["swift", "test", "-c", "release", "--scratch-path", build, "-Xswiftc", "-enable-testing", "--filter", FILTER], cwd=src, stdout=lf, stderr=subprocess.STDOUT, timeout=3600)
        lf.write("load after: " + subprocess.run(["uptime"], capture_output=True, text=True).stdout)
    print(f"[perf {name}] exit={r.returncode}", flush=True)
    for l in open(log, errors="replace"):
        if l.startswith("load") or "R-SYN" in l and ("runs" in l or "✘" in l or "✔" in l) or "Expectation failed" in l or "error:" in l:
            print("   ", l.rstrip()[:420], flush=True)
print("PERF DONE", flush=True)
