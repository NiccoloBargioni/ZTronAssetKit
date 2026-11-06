import re, sys
p = "/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-verify-s3f-c20-correct/probesrc/Tests/ZTronAssetSyncTests/Engine/VerifyC20CorrectProbes.swift"
s = open(p).read()
def rep(old, new):
    global s
    assert s.count(old) == 1, old
    s = s.replace(old, new)
rep("""        let ms: Double
        let eventsBefore: Int""", """        let ms: Double
        let cpu: Double
        let eventsBefore: Int""")
rep("""            "\\(self.kind) \\(String(format: "%.2f", self.ms))ms E""", """            "\\(self.kind) \\(String(format: "%.2f", self.ms))ms cpu \\(String(format: "%.2f", self.cpu))ms E""")
rep("""        var longestFollow: Double {
            self.turns.filter { $0.kind == "follow" }.map(\\.ms).max() ?? 0
        }
""", """        var longestFollow: Double {
            self.turns.filter { $0.kind == "follow" }.map(\\.ms).max() ?? 0
        }

        var longestFollowCPU: Double {
            self.turns.filter { $0.kind == "follow" }.map(\\.cpu).max() ?? 0
        }
""")
rep("""            "apply window \\(String(format: "%.2f", self.applyWait)) ms; longest follow turn \\(String(format: "%.2f", self.longestFollow)) ms;""", """            "apply window \\(String(format: "%.2f", self.applyWait)) ms; longest follow turn \\(String(format: "%.2f", self.longestFollow)) ms (thread CPU \\(String(format: "%.2f", self.longestFollowCPU)) ms);""")
rep("""            let clock = ContinuousClock()
            let start = clock.now
            if follow {""", """            let clock = ContinuousClock()
            let cpu0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let start = clock.now
            if follow {""")
rep("""            let span = clock.now - start
            e.holdFollowFollowUps()""", """            let span = clock.now - start
            let cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu0) / 1e6
            e.holdFollowFollowUps()""")
rep("""ms: VerifyC20Correct.milliseconds(span), eventsBefore:""", """ms: VerifyC20Correct.milliseconds(span), cpu: cpu, eventsBefore:""")
rep("""        let longest = runs.map(\\.longestFollow)
        print("PROBE-C20C-DEFER-BEHIND waits=\\(waits) count=\\(count): longest follow turn per run \\(longest) ms, best \\(longest.min() ?? -1) ms; load""", """        let longest = runs.map(\\.longestFollow)
        let cpus = runs.map(\\.longestFollowCPU)
        print("PROBE-C20C-DEFER-BEHIND waits=\\(waits) count=\\(count): longest follow turn per run \\(longest) ms, best \\(longest.min() ?? -1) ms; thread CPU per run \\(cpus) ms; stride \\(MemoryLayout<EventAfterFollow>.stride) B; load""")
open(p, "w").write(s)
print("patched")
