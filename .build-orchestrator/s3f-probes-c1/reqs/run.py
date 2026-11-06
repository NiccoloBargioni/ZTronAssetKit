# Usage: run.py <mutdir> <name>...  For each mutant: restore pristine Sources, apply edits, build tests, run filter.
import sys, os, shutil, subprocess, importlib.util
M = sys.argv[1]
spec = importlib.util.spec_from_file_location("mutants", os.path.join(M, "mutants.py")); mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
src = os.path.join(M, "src"); build = os.path.join(M, "build")
def restore():
    shutil.rmtree(os.path.join(src, "Sources")); shutil.copytree(os.path.join(M, "pristine", "Sources"), os.path.join(src, "Sources"))
def edits(entry):
    if isinstance(entry[0], list): return entry[0], entry[1]
    f, old, new, n, flt = entry; return [(f, old, new, n)], flt
names = sys.argv[2:] or list(mod.MUTANTS)
for name in names:
    restore()
    es, flt = edits(mod.MUTANTS[name])
    ok = True
    for f, old, new, n in es:
        p = os.path.join(src, f); t = open(p).read(); c = t.count(old)
        if c != n: print(f"[{name}] ANCHOR COUNT {c} != {n} in {f}", flush=True); ok = False; break
        open(p, "w").write(t.replace(old, new))
    if not ok: continue
    log = os.path.join(M, name + ".log")
    with open(log, "w") as lf:
        b = subprocess.run(["swift", "build", "--build-tests", "--scratch-path", build], cwd=src, stdout=lf, stderr=subprocess.STDOUT)
        if b.returncode != 0: print(f"[{name}] BUILD FAILED (see {log})", flush=True); continue
        r = subprocess.run(["swift", "test", "--skip-build", "--scratch-path", build, "--filter", flt], cwd=src, stdout=lf, stderr=subprocess.STDOUT, timeout=1500)
    lines = [l.rstrip() for l in open(log, errors="replace") if ("✘" in l or "Test run with" in l or "passed after" in l and "Test " in l and "Suite" not in l) ]
    print(f"[{name}] exit={r.returncode}", flush=True)
    for l in lines[:14]: print("   ", l[:400], flush=True)
restore()
print("DONE", flush=True)
