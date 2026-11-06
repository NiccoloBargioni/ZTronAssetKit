"""Apply one named mutant to the scratch package copy (restoring every mutated file from the worktree first)."""
import sys, pathlib, shutil
W = pathlib.Path("/Users/admin/Documents/ZTronAssetKit/.worktrees/k")
P = W / ".build-verify-k-c2-reqs/pkg"
M = W / ".build-verify-k-c2-reqs/mutants"
FILES = [
    "Sources/ZTronAssetStorage/Migration/LegacyPhases.swift",
    "Sources/ZTronAssetSync/Engine/EnginePresence.swift",
    "Sources/ZTronAssetSync/Engine/EngineRuns.swift",
    "Tests/ZTronAssetCompatibilityTests/MigrationLaunchShimTests.swift",
]
def restore():
    for f in FILES:
        src, dst = W / f, P / f
        if src.read_bytes() != dst.read_bytes():
            shutil.copyfile(src, dst)
def rep(path, old, new, count=1):
    p = P / path
    s = p.read_text()
    assert s.count(old) == count, (path, old[:80], s.count(old))
    p.write_text(s.replace(old, new))
name = sys.argv[1]
restore()
LP = FILES[0]; EP = FILES[1]; ER = FILES[2]; SH = FILES[3]
if name == "none":
    pass
elif name == "M13":
    shutil.copyfile(M / "M13-LegacyPhases.swift", P / LP)
elif name == "M14s":
    rep(LP, "await self.publishSnapshot(urgency: urgency)", "await self.publishSnapshot(urgency: .userInitiated)", count=2)
elif name == "M14e":
    rep(EP, "urgency: lane == .userInitiated ? .userInitiated : .bulk", "urgency: .userInitiated")
elif name == "M14b":
    rep(EP, "urgency: lane == .userInitiated ? .userInitiated : .bulk", "urgency: .bulk")
elif name in ("D", "OLD-D"):
    if name == "OLD-D":
        shutil.copyfile(M / "MigrationLaunchShimTests.990752a.swift", P / SH)
    stall = '        if let ms = ProcessInfo.processInfo.environment["PROBE_STALL_MS"].flatMap(Int.init) { try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000) }\n'
    rep(SH, "        await coordinator.syncIfNeeded()\n", stall + "        await coordinator.syncIfNeeded()\n", count=2)
elif name in ("FIX1", "FIX2"):
    rep(EP, """        var present: Set<AssetID> = []
        for id in job.assets.sorted() where self.state.applied.entry(for: id)?.transferID == transfer {
            // The job's lane as of this read (a promotion during an earlier read raised it): only a user-initiated job's
            // adoption installs its snapshot at once (L5K-R14).
            let lane = self.state.jobs[transfer]?.lane ?? job.lane
""", """        var present: Set<AssetID> = []
        var coalescedAdoption = false
        for id in job.assets.sorted() where self.state.applied.entry(for: id)?.transferID == transfer {
            // The job's lane as of this read (a promotion during an earlier read raised it): only a user-initiated job's
            // adoption installs its snapshot at once (L5K-R14).
            let lane = self.state.jobs[transfer]?.lane ?? job.lane
            if self.state.migration.pending, lane != .userInitiated {
                coalescedAdoption = true
            }
""")
    rep(EP, """        guard !present.isEmpty, self.isRunning, let current = self.state.jobs[transfer], current.epoch == epoch,""",
        """        if coalescedAdoption, !present.isEmpty, self.isRunning {
            await self.refreshStoreDeadlineAfterPublish()
        }
        guard !present.isEmpty, self.isRunning, let current = self.state.jobs[transfer], current.epoch == epoch,""")
    if name == "FIX2":
        rep(ER, """                progress = try await self.store.migrateLegacy(maxFiles: 64)
            } catch {
                self.state.migration.deferred = true
                return
            }
            guard self.isRunning else {
                return
            }
""", """                progress = try await self.store.migrateLegacy(maxFiles: 64)
            } catch {
                self.state.migration.deferred = true
                return
            }
            guard self.isRunning else {
                return
            }
            await self.refreshStoreDeadlineAfterPublish()
            guard self.isRunning else {
                return
            }
""")
elif name == "FIX1-OLDPARK":
    rep(EP, """            let lane = self.state.jobs[transfer]?.lane ?? job.lane
""", """            let lane = self.state.jobs[transfer]?.lane ?? job.lane
            if self.state.migration.pending, lane != .userInitiated {
                coalescedAdoption = true
            }
""")
    rep(EP, """        var present: Set<AssetID> = []
""", """        var present: Set<AssetID> = []
        var coalescedAdoption = false
""")
    rep(EP, """        guard !present.isEmpty, self.isRunning, let current = self.state.jobs[transfer], current.epoch == epoch,""",
        """        if coalescedAdoption, !present.isEmpty, self.isRunning {
            await self.refreshStoreDeadlineAfterPublish()
        }
        guard !present.isEmpty, self.isRunning, let current = self.state.jobs[transfer], current.epoch == epoch,""")
    # the pre-L5K-R1 parked launch run: a run that starts meanwhile does not take its place
    rep(ER, """        self.state.migration.launchRunWaiting = false
        self.broadcast(.syncStarted(run.id, trigger))""", """        self.broadcast(.syncStarted(run.id, trigger))""")
elif name == "M3":
    rep(ER, """            let launchRunWaiting = self.state.migration.launchRunWaiting
            self.state.migration.launchRunWaiting = false
            if launchRunWaiting, self.isRunning {
                self.startRun(trigger: .launch, mode: .force)
            }""", """            if self.state.migration.launchRunWaiting, self.isRunning {
                self.state.migration.launchRunWaiting = false
                self.startRun(trigger: .launch, mode: .force)
            }""")
elif name == "M1":
    rep(EP, "        guard self.state.migration.pending else {\n", "        guard false else {\n")
else:
    raise SystemExit("unknown mutant " + name)
print("applied", name)
