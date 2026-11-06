"""Applies one named mutant to the scratch package copy (cycle-2 reqs retry verifier; scratch only)."""
import pathlib
import sys

ROOT = pathlib.Path(sys.argv[1])
NAME = sys.argv[2]
BG = "Sources/ZTronAssetTransport/Background/BackgroundSupport.swift"
TH = "Sources/ZTronAssetTransport/Session/TransferHandles.swift"
HR = "Sources/ZTronAssetTransport/Session/HTTPResponseReading.swift"
TS = "Tests/ZTronAssetTransportTests/TransportTestSupport.swift"

MUTANTS = {
    # S3D-1 cycle 1, original defect (a): no newest-request check after the listing.
    "R1A-no-serial-guard": [(BG, """        guard self.priorityRequests[name] == request else {
            // A later request for the name began meanwhile (or the name's terminal was processed): it decides.
            return
        }
""", "        _ = request\n")],
    # S3D-1 cycle 1, original defect (b): one unstructured Task per control, from the handle's methods.
    "R1B-task-per-call": [
        (BG, "    private let controls: AsyncStream<Control>.Continuation\n",
             "    private let controls: AsyncStream<Control>.Continuation\n    private let mutantCoordinator: BackgroundTransferCoordinator\n"),
        (BG, "        self.controls = controls.continuation\n",
             "        self.controls = controls.continuation\n        self.mutantCoordinator = coordinator\n"),
        (BG, "        self.controls.yield(.priority(priority))\n",
             "        Task { [mutantCoordinator, name, token] in await mutantCoordinator.setPriority(priority, of: name, token: token) }\n"),
        (BG, "        self.controls.yield(.pause)\n",
             "        Task { [mutantCoordinator, name, token] in await mutantCoordinator.control(name, token: token, keepingPartial: true) }\n"),
        (BG, "        self.controls.yield(.cancel)\n",
             "        Task { [mutantCoordinator, name, token] in await mutantCoordinator.control(name, token: token, keepingPartial: false) }\n"),
    ],
    # S3D-1: the control task hands each priority change to its own Task (arrival order lost inside the drain).
    "R1B2-task-inside-drain": [(BG, "                    await coordinator.setPriority(priority, of: name, token: token)\n",
                                 "                    Task { await coordinator.setPriority(priority, of: name, token: token) }\n")],
    # S3D-1 cycle 2, original defect: no re-write after a write that may have landed late.
    "R1C-no-rewrite-loop": [(BG, """        while let newest = self.priorities[name], newest != written {
            written = newest
            // REENTRANCY: D-9 (proposed, amended at Stage 3) — as above: `priorities[name]` is re-read after it.
            await self.driver.setPriority(taskIdentifier: task.taskIdentifier, written)
        }
""", "")],
    # S3D-1 cycle 2: `.finished` keeps the recorded priority (the loop would write after the terminal).
    "R1D-finished-keeps-priority": [(BG, """            self.priorities[name] = nil
            self.priorityRequests[name] = nil
""", """            self.priorityRequests[name] = nil
""")],
    # S3D-1: the attach's end does not finish the control stream (control task outlives the attach).
    "R1E-controls-not-finished": [(BG, """            self.continuation.finish()
            self.controls.finish()
""", """            self.continuation.finish()
""")],
    # S3D-1: the serial is taken before the entry token check (a stale handle may supersede the current attach).
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
    # S3D-1 cycle 2: one re-check instead of a loop.
    "R1K-if-not-while": [(BG, "        while let newest = self.priorities[name], newest != written {\n",
                              "        if let newest = self.priorities[name], newest != written {\n")],
    # S3D-2, original defect: a later handler replaces a waiting one.
    "R2F-replace-handler": [(BG, "        self.handlers[identifier, default: []].append(completionHandler)\n",
                                 "        self.handlers[identifier] = [completionHandler]\n")],
    # S3D-2: one completion calls every waiting handler (a later one before its own wake's events).
    "R2G-complete-calls-all": [(BG, """        let rest = waiting.dropFirst()
        self.handlers[identifier] = rest.isEmpty ? nil : Array(rest)
        oldest()
""", """        _ = oldest
        self.handlers[identifier] = nil
        for handler in waiting {
            handler()
        }
""")],
    # S3D-2: one completion calls the newest waiting handler.
    "R2H-complete-calls-newest": [(BG, """        guard let waiting = self.handlers[identifier], let oldest = waiting.first else {
            return
        }
        let rest = waiting.dropFirst()
""", """        guard let waiting = self.handlers[identifier], let oldest = waiting.last else {
            return
        }
        let rest = waiting.dropLast()
""")],
    # S3D-3: M-N-22 (the orchestrator's mutant diff, as a string edit).
    "R3-MN22-weak-etag": [(HR, """        if let tag = response.value(forHTTPHeaderField: "ETag").flatMap(ETag.init(rawValue:)), !tag.rawValue.hasPrefix("W/") {""",
                               """        if let tag = response.value(forHTTPHeaderField: "ETag").flatMap(ETag.init(rawValue:)) {""")],
    # S3D-4: an S2-19-style per-transfer control reader over a stream nobody finishes, capturing the handle.
    "R4-leaking-control-reader": [(TH, """        self.partial = job.partialName
    }
""", """        self.partial = job.partialName
        let (mutantControl, mutantContinuation) = AsyncStream.makeStream(of: Int.self)
        Task { [self, mutantContinuation] in
            _ = mutantContinuation
            for await _ in mutantControl {
                _ = self.id
            }
        }
    }
""")],
    # S3D-5 plumbing check: the held-stall timeout is tiny, so the tests that pass it must observe a timeout.
    "R5-held-timeout-tiny": [(TS, "    static let heldStallTimeout: TimeInterval = 600\n",
                                  "    static let heldStallTimeout: TimeInterval = 0.05\n")],
    # Equivalence claims of the draft (expected to survive).
    "EQ1-newest-keeps-serial": [(BG, """        // The newest request decides now, so the entry lives only while a request lists the tasks.
        self.priorityRequests[name] = nil
""", "")],
    "EQ2-finished-keeps-serial": [(BG, """            self.priorities[name] = nil
            self.priorityRequests[name] = nil
""", """            self.priorities[name] = nil
""")],
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
