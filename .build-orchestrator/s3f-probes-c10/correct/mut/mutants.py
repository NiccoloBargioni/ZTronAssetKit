import sys, pathlib
root = pathlib.Path(__file__).resolve().parent.parent / "src/Sources/ZTronAssetSync/Engine"
M = {
 "enospcNoDefer": ("EngineFailures.swift", "        if self.defersToFollow {\n            // The verdict reads the room", "        if false, self.defersToFollow {\n            // The verdict reads the room"),
 "reinstateNoReplay": ("EngineFollow.swift", "                self.reinstate(transfer)\n            case .join(let join):", "                _ = transfer\n            case .join(let join):"),
 "edgeNoReplay": ("EngineFollow.swift", "            case .edge(let transfer, let epoch):\n                self.replayEdge(transfer, epoch: epoch)", "            case .edge(let transfer, let epoch):\n                _ = (transfer, epoch)"),
 "relaneNoDefer": ("EngineJobs.swift", "                    self.state.eventsAfterFollow.append(.relane(transfer, epoch: job.epoch, from: before))", "                    _ = before"),
 "throttleAtNow": ("EngineFollow.swift", "self.park(transfer, reason: .throttled(until: until), answeredAt: at)", "self.park(transfer, reason: .throttled(until: until), answeredAt: nil); _ = at"),
}
name, action = sys.argv[1], sys.argv[2]
f, old, new = M[name]
p = root / f
s = p.read_text()
if action == "apply":
    assert s.count(old) == 1, (name, s.count(old))
    p.write_text(s.replace(old, new))
else:
    assert s.count(new) == 1, (name, "revert", s.count(new))
    p.write_text(s.replace(new, old))
print(name, action, "ok")
