"""Applies one named mutant to the scratch package copy (S3D cycle-3 reqs verifier; scratch only)."""
import pathlib
import sys

ROOT = pathlib.Path(sys.argv[1])
NAME = sys.argv[2]
BG = "Sources/ZTronAssetTransport/Background/BackgroundSupport.swift"
FS = "Sources/ZTronAssetTransport/Session/ForegroundSession.swift"
FB = "Tests/ZTronAssetTransportTests/ForegroundBackendTests.swift"

MUTANTS = {
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
        // Controls already made are still delivered; the control task ends after them.
    }
""")],
    "R1C-no-rewrite-loop": [(BG, """        while let newest = self.priorities[name], newest != written {
            written = newest
            // REENTRANCY: D-9 (proposed, amended at Stage 3) — as above: `priorities[name]` is re-read after it.
            await self.driver.setPriority(taskIdentifier: task.taskIdentifier, written)
        }
""", "        _ = written\n")],
    "R1A-no-serial-guard": [(BG, """        guard self.priorityRequests[name] == request else {
            // A later request for the name began meanwhile (or the name's terminal was processed): it decides.
            return
        }
""", "        _ = request\n")],
    # S2-19 timing amplifier (timing only): the interval ends 50 ms after the stream was released.
    "AMP-delay-interval-end": [(FS, """                interval.end()
            }
            task.delegate = TaskMailbox""", """                Thread.sleep(forTimeInterval: 0.05)
                interval.end()
            }
            task.delegate = TaskMailbox""")],
    # The amplifier plus the S2-19 test's original order (edges read before stop()): the cycle-2 defect.
    "AMP-plus-old-order": [(FS, """                interval.end()
            }
            task.delegate = TaskMailbox""", """                Thread.sleep(forTimeInterval: 0.05)
                interval.end()
            }
            task.delegate = TaskMailbox"""),
        (FB, """        #expect(await rig.foreground.liveTransfers().isEmpty)
        let unfinished = await rig.foreground.session.allTasks.filter { $0.state != .completed }
""", """        let earlyEdges = transferIntervalEdges(rig.tap)
        #expect(earlyEdges.began == expected.count && earlyEdges.ended == expected.count)
        #expect(await rig.foreground.liveTransfers().isEmpty)
        let unfinished = await rig.foreground.session.allTasks.filter { $0.state != .completed }
""")],
}

for rel, old, new in MUTANTS[NAME]:
    path = ROOT / rel
    text = path.read_text()
    count = text.count(old)
    if count != 1:
        sys.exit(f"{NAME}: pattern found {count} times in {rel}")
    path.write_text(text.replace(old, new))
print(f"== {NAME} applied")
