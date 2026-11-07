"""Applies one named mutant to the scratch package copy (S3D close-out cycle 3; scratch only, never committed)."""
import pathlib
import sys

ROOT = pathlib.Path(sys.argv[1])
NAME = sys.argv[2]
BG = "Sources/ZTronAssetTransport/Background/BackgroundSupport.swift"
FS = "Sources/ZTronAssetTransport/Session/ForegroundSession.swift"
FB = "Tests/ZTronAssetTransportTests/ForegroundBackendTests.swift"

MUTANTS = {
    # R1J / MI: the serial is taken before the entry token check.
    "R1J": [(BG, """        if let token, self.waiters[name]?.token != token {
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
    # R1K: one re-check instead of the loop.
    "R1K": [(BG, "        while let newest = self.priorities[name], newest != written {\n",
                 "        if let newest = self.priorities[name], newest != written {\n")],
    # MG: the control task hands each priority change to its own Task.
    "MG": [(BG, "                    await coordinator.setPriority(priority, of: name, token: token)\n",
                "                    Task { await coordinator.setPriority(priority, of: name, token: token) }\n")],
    # MK: the handle's deinit does not finish the control stream.
    "MK": [(BG, """        // Controls already made are still delivered; the control task ends after them.
        self.controls.finish()
""", """        // mutant
""")],
    # S3D-4 timing amplifier (not a mutant of behaviour): 50 ms before the interval ends in onTermination.
    "DELAY": [(FS, """                interval.end()
            }
            task.delegate = TaskMailbox""", """                Thread.sleep(forTimeInterval: 0.05)
                interval.end()
            }
            task.delegate = TaskMailbox""")],
    # S3D-4: the test's old order (edges read before stop()), on top of DELAY.
    "DELAY-OLDTEST": [(FS, """                interval.end()
            }
            task.delegate = TaskMailbox""", """                Thread.sleep(forTimeInterval: 0.05)
                interval.end()
            }
            task.delegate = TaskMailbox"""),
        (FB, """        #expect(await rig.foreground.liveTransfers().isEmpty)
        let unfinished = await rig.foreground.session.allTasks""", """        let earlyEdges = transferIntervalEdges(rig.tap)
        #expect(earlyEdges.began == expected.count && earlyEdges.ended == expected.count)
        #expect(await rig.foreground.liveTransfers().isEmpty)
        let unfinished = await rig.foreground.session.allTasks""")],
}

if NAME == "M0":
    print("MUTANT M0 (none)")
    sys.exit(0)
for path, old, new in MUTANTS[NAME]:
    target = ROOT / path
    text = target.read_text()
    count = text.count(old)
    if count != 1:
        print(f"MUTANT {NAME}: old string occurs {count} times in {path}; not applied")
        sys.exit(3)
    target.write_text(text.replace(old, new))
print(f"MUTANT {NAME} applied ({len(MUTANTS[NAME])} edit(s))")
