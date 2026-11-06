"""Applies one named mutant to a scratch package copy (s3d cycle-3 correctness verifier; scratch only).
Usage: python3 mutate.py <pristine-root> <target-root> <name>  (target is reset from pristine first)."""
import pathlib, shutil, sys

PRISTINE = pathlib.Path(sys.argv[1]); ROOT = pathlib.Path(sys.argv[2]); NAME = sys.argv[3]
BG = "Sources/ZTronAssetTransport/Background/BackgroundSupport.swift"
FS = "Sources/ZTronAssetTransport/Session/ForegroundSession.swift"

MUTANTS = {
    "none": [],
    "R1J-serial-before-token": [(BG, """        if let token, self.waiters[name]?.token != token {
            return
        }
        self.lastPriorityRequest += 1
        let request = self.lastPriorityRequest
        self.priorityRequests[name] = request
""", """        self.lastPriorityRequest += 1
        let request = self.lastPriorityRequest
        self.priorityRequests[name] = request
        if let token, self.waiters[name]?.token != token {
            return
        }
""")],
    "R1K-if-not-while": [(BG, "        while let newest = self.priorities[name], newest != written {\n",
                              "        if let newest = self.priorities[name], newest != written {\n")],
    "MG-task-inside-drain": [(BG, "                    await coordinator.setPriority(priority, of: name, token: token)\n",
                                  "                    Task { await coordinator.setPriority(priority, of: name, token: token) }\n")],
    "MK-deinit-finishes-nothing": [(BG, """    deinit {
        // Controls already made are still delivered; the control task ends after them.
        self.controls.finish()
    }
""", """    deinit {
    }
""")],
    # Own extra mutants (hunting).
    "X1-no-second-token-check": [(BG, """        self.priorityRequests[name] = nil
        if let token, self.waiters[name]?.token != token {
            return
        }
""", """        self.priorityRequests[name] = nil
""")],
    "X2-no-serial-guard": [(BG, """        guard self.priorityRequests[name] == request else {
            // A later request for the name began meanwhile (or the name's terminal was processed): it decides.
            return
        }
""", "        _ = request\n")],
    "X3-finished-keeps-serial": [(BG, """            self.priorities[name] = nil
            self.priorityRequests[name] = nil
            self.processed.set(true, for: name)
""", """            self.priorities[name] = nil
            self.processed.set(true, for: name)
""")],
    "X4-no-entry-token-check": [(BG, """        if let token, self.waiters[name]?.token != token {
            return
        }
        self.lastPriorityRequest += 1
""", """        self.lastPriorityRequest += 1
""")],
    # Timing amplifier for S3D-4: the interval ends 50 ms after the reader may have seen the end.
    "AMP-delay-interval-end": [(FS, "                interval.end()\n",
                                    "                Thread.sleep(forTimeInterval: 0.05)\n                interval.end()\n")],
}

for rel in ("Sources", "Tests"):
    shutil.rmtree(ROOT / rel, ignore_errors=True)
    shutil.copytree(PRISTINE / rel, ROOT / rel)
shutil.copy(PRISTINE / "Package.swift", ROOT / "Package.swift")
for rel, old, new in MUTANTS[NAME]:
    p = ROOT / rel
    text = p.read_text()
    if text.count(old) != 1:
        sys.exit(f"MUTANT {NAME}: pattern count {text.count(old)} in {rel}")
    p.write_text(text.replace(old, new))
print(f"MUTANT {NAME} applied")
