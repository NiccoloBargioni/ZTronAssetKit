import sys, pathlib
ROOT = pathlib.Path(sys.argv[1])  # mutpkg
which = sys.argv[2]
BG = "Sources/ZTronAssetTransport/Background/BackgroundSupport.swift"
TH = "Sources/ZTronAssetTransport/Session/TransferHandles.swift"
HR = "Sources/ZTronAssetTransport/Session/HTTPResponseReading.swift"
M = {
 "MA": (BG, """        guard self.priorityRequests[name] == request else {
            // A later request for the name began meanwhile (or the name's terminal was processed): it decides.
            return
        }
""", "        _ = request\n"),
 "MB": (BG, "                    await coordinator.setPriority(priority, of: name, token: token)\n",
            "                    Task { await coordinator.setPriority(priority, of: name, token: token) }\n"),
 "MC": (BG, """        while let newest = self.priorities[name], newest != written {
            written = newest
            // REENTRANCY: D-9 (proposed, amended at Stage 3) — as above: `priorities[name]` is re-read after it.
            await self.driver.setPriority(taskIdentifier: task.taskIdentifier, written)
        }
""", ""),
 "MD": (BG, """            self.priorities[name] = nil
            self.priorityRequests[name] = nil
            self.processed.set(true, for: name)""", """            self.priorityRequests[name] = nil
            self.processed.set(true, for: name)"""),
 "ME": (BG, """            self.continuation.finish()
            self.controls.finish()
        }""", """            self.continuation.finish()
        }"""),
 "MF": (BG, "        self.handlers[identifier, default: []].append(completionHandler)\n",
            "        self.handlers[identifier] = [completionHandler]\n"),
 "MG": (BG, """        let rest = waiting.dropFirst()
        self.handlers[identifier] = rest.isEmpty ? nil : Array(rest)
        oldest()
""", """        _ = oldest
        self.handlers[identifier] = nil
        for handler in waiting { handler() }
"""),
 "MG2": (BG, """        guard let waiting = self.handlers[identifier], let oldest = waiting.first else {
            return
        }
        let rest = waiting.dropFirst()
""", """        guard let waiting = self.handlers[identifier], let oldest = waiting.last else {
            return
        }
        let rest = waiting.dropLast()
"""),
 "MH": (HR, """        if let tag = response.value(forHTTPHeaderField: "ETag").flatMap(ETag.init(rawValue:)), !tag.rawValue.hasPrefix("W/") {""",
            """        if let tag = response.value(forHTTPHeaderField: "ETag").flatMap(ETag.init(rawValue:)) {"""),
 "MI": (TH, """        self.partial = job.partialName
    }
""", """        self.partial = job.partialName
        let (control, leaked) = AsyncStream.makeStream(of: Int.self)
        Task { [self, leaked] in
            _ = leaked
            for await _ in control { _ = self.id }
        }
    }
"""),
 "MJ": (BG, """        if let token, self.waiters[name]?.token != token {
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
"""),
 "MK": (BG, "        while let newest = self.priorities[name], newest != written {\n",
            "        if let newest = self.priorities[name], newest != written {\n"),
}
M["MB3"] = [
 (BG, "    private let controls: AsyncStream<Control>.Continuation\n    /// The task that delivers",
      "    private let controls: AsyncStream<Control>.Continuation\n    private let mutCoordinator: BackgroundTransferCoordinator\n    /// The task that delivers"),
 (BG, "        self.controls = controls.continuation\n        let pending = controls.stream\n",
      "        self.controls = controls.continuation\n        self.mutCoordinator = coordinator\n        let pending = controls.stream\n"),
 (BG, "        self.controls.yield(.priority(priority))\n",
      "        Task { [mutCoordinator, name, token] in await mutCoordinator.setPriority(priority, of: name, token: token) }\n"),
 (BG, "        self.controls.yield(.pause)\n",
      "        Task { [mutCoordinator, name, token] in await mutCoordinator.control(name, token: token, keepingPartial: true) }\n"),
 (BG, "        self.controls.yield(.cancel)\n",
      "        Task { [mutCoordinator, name, token] in await mutCoordinator.control(name, token: token, keepingPartial: false) }\n"),
]
edits = M[which] if isinstance(M[which], list) else [M[which]]
for f, old, new in edits:
    p = ROOT / f
    s = p.read_text()
    n = s.count(old)
    if n != 1:
        print(f"MUTANT {which}: old string occurs {n} times; not applied"); sys.exit(3)
    p.write_text(s.replace(old, new))
print(f"MUTANT {which} applied ({len(edits)} edit(s))")
