# profile:three-shapes

Read-only analysis for ruling S3-R26 (workflow wf_e80338c6-07f, on 8e1fb24). UNCONFIRMED marks what the agent read but did not run.

## method

Resumed wf_6927a3a9-c76 without re-extracting or rebuilding. Scratch copy /Users/admin/Documents/ZTronAssetKit/.build-prof40/src (git archive of 8e1fb24; Package.swift byte-identical to the commit) plus, in the benchmark target only, the verifiers' VerifyC20SupersedeBench.swift and a scratch Prof40Shapes.swift that repeats each benchmark scenario PROF40_RUNS times and holds the micro-timings. Toolchain Apple Swift 6.4 (swiftlang-6.4.0.34.1), macOS 27.0 SDK, arm64-apple-macosx14.0, 8 cores. Build: swift build -c release --scratch-path .build-prof40/spm -Xswiftc -enable-testing (2 Nov, exit 0). Baselines: swift test -c release --skip-build --scratch-path .build-prof40/spm -Xswiftc -enable-testing --filter <case>, best of 3 (the case's own window; the cases fail their 10 ms expectation by design). Profiles: xcrun xctrace record --template "CPU Profiler" on the release swiftpm-testing-helper run filtered to one Prof40Shapes case; exported with xcrun xctrace export (cpu-profile table), parsed to pickles; turn samples = actor-thread samples inside each repetition whose backtrace holds the root frame (shape 1: publish's resumption / committed; shape 2: releaseOneHeldTurn → continueFollow → drainEventsAfterFollow / replayVerdict / takeOffMovedBefore; shape 3: publicationFailed / supersede); setup excluded by that rule. Attribution by a frame-name rule table then the innermost engine line (tools/cat.py). Repetitions: shape 1 15 turns (3,030 samples), shape 2 16 turns (3,466), shape 3 9 turns (1,500, from two traces; the first lost events under load). Micro-timings: ContinuousClock, best of 3 in-test, 3 runs. Loads via sysctl -n vm.loadavg before/after every run (out/loads.txt): profiles at 1-minute loads 24–389 (2 Nov, shares only); baselines base4 and micro3 on 4 Nov at 4.75–5.26 (quiet, S3-R23). Earlier 2 Nov baselines (loads 70–338) and the 13-minute quiet wait that gave up are recorded too.

## shapes

- {
 "shape": "1. Commit re-routes (BenchSync.concentrationCommitRerouteTurns)",
 "baselineMs": "49.08 ms best of 3 [49.17, 49.08, 49.15] at a quiet load 4.94\u21924.95 (4 Nov); cycle 20 47.99\u201349.35; 2 Nov loaded 48.94",
 "rootFrame": "SyncEngine.publish(_:epoch:file:cancelledAttempt:) post-await resumption (3,030/3,030 samples) and SyncEngine.committed(_:binding:locations:since:) (3,010)",
 "samplesInTurn": 3030,
 "categories": [
  {
   "category": "transfer-id formatting (4 sites: EngineDispatch.swift:1121, :1164, :1179, EngineJobs.swift:109, ~156 samples each)",
   "sharePct": 20.6,
   "impliedMs": 10.1
  },
  {
   "category": "jobs-table access (addInterest :132/:156/:157/:161/:165/:179, failFastJoiner :225/:231/:245/:246, relane :263/:264, reroute :1188 Job destroy; ~9\u201312 hashed accesses, 1.03 \u00b5s/id)",
   "sharePct": 21.1,
   "impliedMs": 10.3
  },
  {
   "category": "sorting (unbound.sorted() committed:1120 2.96 ms; job.assets.sorted() publishTerminal EngineJobs.swift:635 2.95 ms)",
   "sharePct": 12.1,
   "impliedMs": 5.9
  },
  {
   "category": "other Set/Dictionary (groups pending write reroute:1179 2.8 ms, Job.insertAsset 1.6, assets.insert 1.3, committed :1122 1.2, set building 0.9)",
   "sharePct": 16.1,
   "impliedMs": 7.9
  },
  {
   "category": "manifest lookups + ManifestEntry copies (committed:1121 1.9 ms, noteJoin:191 0.9, reroute:1151 0.6)",
   "sharePct": 7.4,
   "impliedMs": 3.6
  },
  {
   "category": "retireProgress + removeJob",
   "sharePct": 1.2,
   "impliedMs": 0.6
  },
  {
   "category": "whole-EngineState copy in decisionNow() (EngineFollow.swift:242 outlined init with copy; destroy after noteJoin) \u2014 not in the analysis",
   "sharePct": 10.7,
   "impliedMs": 5.2
  },
  {
   "category": "everything else (retain/release and destroys of RemoteSource?/ValidatedManifest passed through committed\u2192reroute\u2192addInterest ~3.9 ms, publish resumption 1.0, publishTerminal lookups 0.4)",
   "sharePct": 10.9,
   "impliedMs": 5.3
  }
 ],
 "topSelf": [
  "swift_release 206 (6.8 %, 3.3 ms)",
  "String.UTF8View subscript.read witness 174 (5.7 %, 2.8 ms)",
  "_xzm_free_main 171 (5.6 %, 2.8 ms)",
  "swift_retain 152 (5.0 %, 2.5 ms)",
  "Hasher.combine(bytes:) 122 (4.0 %, 2.0 ms)",
  "_xzm_xzone_malloc_tiny 99 (3.3 %, 1.6 ms)",
  "swift_bridgeObjectRelease 99 (3.3 %, 1.6 ms)",
  "swift_bridgeObjectRetain 91 (3.0 %, 1.5 ms)",
  "DYLD-STUB$$swift_bridgeObjectRelease 79 (2.6 %, 1.3 ms)",
  "DYLD-STUB$$swift_bridgeObjectRetain 79 (2.6 %, 1.3 ms)",
  "specialized Sequence.lexicographicallyPrecedes 63 (2.1 %, 1.0 ms)",
  "<deduplicated_symbol> 55 (1.8 %, 0.9 ms)",
  "_platform_memmove 54 (1.8 %, 0.9 ms)",
  "specialized UnsafeMutablePointer.initialize(to:) 54 (1.8 %, 0.9 ms)",
  "Hasher._finalize() 54 (1.8 %, 0.9 ms)"
 ],
 "fixSavings": "Format once (3 of 4 sites; sameTransfer at :1121): \u22127.6 ms (\u22125.1 if :1121 keeps formatting). One jobs-table access per id, no Job copy (~2 accesses survive): \u22127 to \u22127.5 ms of 10.3. Filter before sorting in publishTerminal: \u22123.4 ms (sort 2.95 + lookups 0.5). Stop the EngineState copy in decisionNow (engine-only, no branch, not in the analysis): \u22125.2 ms. Cheaper/stored TransferID (model type, NEEDS-HUMAN-REVIEW): \u22122.0 to \u22122.5 more. Other candidates: unbound.sorted() 2.96 ms, the pending write 2.8 ms. Result: the analysis's three families in full \u2192 30.6\u201331.1 ms, lands at \u226432 by 1\u20131.5 ms; plus the decisionNow fix \u2192 25.4\u201325.9 ms; conservative variant (4\u21922 formats, partial jobs-table \u22126) \u2192 33\u201335 ms, does not land."
}
- {
 "shape": "2. Drain take-off (BenchSync.movedBeforeDrainTurns)",
 "baselineMs": "44.92 ms best of 3 [44.92, 47.61, 45.41] at a quiet load 4.95\u21925.11 (4 Nov); cycle 20 45.67\u201349.08; 2 Nov loaded 54.65 (inflated)",
 "rootFrame": "releaseOneHeldTurn \u2192 SyncEngine.continueFollow (3,466/3,466), with drainEventsAfterFollow (3,392) and the verdict replay replayVerdict(_:epoch:_:) (3,378); takeOffMovedBefore 604, its re-routes via rerouteMovedBefore \u2192 reroute 2,759",
 "samplesInTurn": 3466,
 "categories": [
  {
   "category": "transfer-id formatting (reroute :1164 2.6 ms, :1179 2.3, addInterest :109 2.2, continueFollowScans :772 0.5)",
   "sharePct": 16.9,
   "impliedMs": 7.6
  },
  {
   "category": "jobs-table access (addInterest sites, reroute :1188, relane, failFastJoiner, takeOffMovedBefore :560, replayVerdict :615; 1.21 \u00b5s/id; initializeWithCopy for Job 2.1 % self)",
   "sharePct": 26.8,
   "impliedMs": 12.1
  },
  {
   "category": "sorting (interest.assets.sorted() takeOffMovedBefore EngineFollow.swift:559)",
   "sharePct": 5.7,
   "impliedMs": 2.6
  },
  {
   "category": "other Set/Dictionary (pending write :1179 2.5 ms, Job.removeAsset 1.8, Job.insertAsset 1.6, assets.insert 1.2, rerouteMovedBefore :574 1.0, take-off contains/subtract/intersection 1.7)",
   "sharePct": 22.1,
   "impliedMs": 9.9
  },
  {
   "category": "manifest lookups + ManifestEntry copies (reroute :1151 2.2 ms, noteJoin :191 0.7, scans :768/:574 0.5)",
   "sharePct": 7.8,
   "impliedMs": 3.5
  },
  {
   "category": "retireProgress + removeJob",
   "sharePct": 0,
   "impliedMs": 0
  },
  {
   "category": "whole-EngineState copy in decisionNow() :242",
   "sharePct": 11,
   "impliedMs": 4.9
  },
  {
   "category": "everything else (value destroys and retain/release around rerouteMovedBefore :574 \u2192 reroute :1188, 3.4 ms)",
   "sharePct": 9.6,
   "impliedMs": 4.3
  }
 ],
 "topSelf": [
  "swift_release 219 (6.3 %, 2.8 ms)",
  "_xzm_free_main 215 (6.2 %, 2.8 ms)",
  "Hasher.combine(bytes:) 197 (5.7 %, 2.6 ms)",
  "swift_retain 152 (4.4 %, 2.0 ms)",
  "String.UTF8View subscript.read witness 150 (4.3 %, 1.9 ms)",
  "_xzm_xzone_malloc_tiny 117 (3.4 %, 1.5 ms)",
  "swift_bridgeObjectRelease 112 (3.2 %, 1.5 ms)",
  "DYLD-STUB$$swift_bridgeObjectRelease 94 (2.7 %, 1.2 ms)",
  "_platform_memmove 83 (2.4 %, 1.1 ms)",
  "swift_bridgeObjectRetain 79 (2.3 %, 1.0 ms)",
  "specialized Sequence.elementsEqual 76 (2.2 %, 1.0 ms)",
  "<deduplicated_symbol> 74 (2.1 %, 1.0 ms)",
  "_stringCompare(_:_:expecting:) 74 (2.1 %, 1.0 ms)",
  "initializeWithCopy for Job 72 (2.1 %, 0.9 ms)",
  "DYLD-STUB$$swift_bridgeObjectRetain 68 (2.0 %, 0.9 ms)"
 ],
 "fixSavings": "Format once (2 of 3 re-route sites; the scan's 0.5 ms stays): \u22124.7 ms. One jobs-table access per id, no Job copy: \u22128.5 to \u22129 ms of 12.1 (includes the take-off's per-id removeAsset accesses). publishTerminal filter: 0 (not in this turn). Take-off by intersection + one subtract (F4): \u22122 ms net; the sort stays (held = whole interest). decisionNow EngineState copy: \u22124.9 ms. Stored/cheaper TransferID: \u22122.5 to \u22123 more. Candidates: pending write 2.5 ms; the 2.6 ms sort (F7's AssetID < fast path would take 1.5\u20132 ms, but adds 1 branch). Result: analysis families in full \u2192 29.4\u201329.9 ms, lands at \u226432 by ~2 ms; plus decisionNow \u2192 24.5\u201325 ms; conservative (jobs-table \u22126.5) \u2192 31.7 ms, borderline."
}
- {
 "shape": "3. supersede of a superseded publication (VerifyC20SupersedeBench, PROBE-C20C-SUPERSEDE-C2)",
 "baselineMs": "40.21 ms best of 3 [40.21, 40.43, 40.52] at a quiet load 5.11\u21925.26 (4 Nov); verifiers' probe 41.09; 2 Nov loaded 41.07",
 "rootFrame": "SyncEngine.publicationFailed(_:epoch:file:error:\u2026) (1,500/1,500) and SyncEngine.supersede(_:settling:listing:) (1,494); reroute 1,300",
 "samplesInTurn": 1500,
 "categories": [
  {
   "category": "transfer-id formatting (addInterest :109 2.3 ms, reroute :1164 2.2, :1179 1.8)",
   "sharePct": 15.9,
   "impliedMs": 6.4
  },
  {
   "category": "jobs-table access (addInterest, reroute :1188, failFastJoiner, relane; 1.09 \u00b5s/id)",
   "sharePct": 27.1,
   "impliedMs": 10.9
  },
  {
   "category": "sorting (interest.assets.sorted() supersede EngineDispatch.swift:1270 3.0 ms)",
   "sharePct": 7.7,
   "impliedMs": 3.1
  },
  {
   "category": "other Set/Dictionary (pending write :1179 2.5 ms, assets.insert 1.5, Job.insertAsset 1.5, supersede :1271 1.2)",
   "sharePct": 16.5,
   "impliedMs": 6.6
  },
  {
   "category": "manifest lookups + ManifestEntry copies (reroute :1151 1.5 ms, listing check :1263 1.0, noteJoin :191 0.8)",
   "sharePct": 9,
   "impliedMs": 3.6
  },
  {
   "category": "retireProgress + removeJob",
   "sharePct": 1.4,
   "impliedMs": 0.6
  },
  {
   "category": "whole-EngineState copy in decisionNow() (:242 2.7 ms + destroy after noteJoin 2.5 ms)",
   "sharePct": 12.8,
   "impliedMs": 5.1
  },
  {
   "category": "everything else (value destroys/retain-release supersede :1271 \u2192 reroute :1188 3.2 ms, publicationFailed :1211 0.4)",
   "sharePct": 9.5,
   "impliedMs": 3.8
  }
 ],
 "topSelf": [
  "swift_release 108 (7.2 %, 2.9 ms)",
  "swift_retain 94 (6.3 %, 2.5 ms)",
  "swift_bridgeObjectRelease 79 (5.3 %, 2.1 ms)",
  "_xzm_free_main 70 (4.7 %, 1.9 ms)",
  "Hasher.combine(bytes:) 68 (4.5 %, 1.8 ms)",
  "DYLD-STUB$$swift_bridgeObjectRelease 53 (3.5 %, 1.4 ms)",
  "String.UTF8View subscript.read witness 48 (3.2 %, 1.3 ms)",
  "swift_bridgeObjectRetain 47 (3.1 %, 1.3 ms)",
  "_xzm_xzone_malloc_tiny 46 (3.1 %, 1.2 ms)",
  "DYLD-STUB$$swift_bridgeObjectRetain 44 (2.9 %, 1.2 ms)",
  "_platform_memmove 41 (2.7 %, 1.1 ms)",
  "Hasher._finalize() 36 (2.4 %, 1.0 ms)",
  "specialized Sequence.lexicographicallyPrecedes 23 (1.5 %, 0.6 ms)",
  "specialized Sequence.elementsEqual 23 (1.5 %, 0.6 ms)",
  "ValidatedManifest.entry(for:) 21 (1.4 %, 0.6 ms)"
 ],
 "fixSavings": "Format once (2 of 3 sites): \u22124.3 ms. One jobs-table access per id, no Job copy (F2 Job.join, 9\u21922): \u22127.5 to \u22128 ms of 10.9. publishTerminal filter: 0. decisionNow EngineState copy (F2 already drops the unused decisionNow on the join path): \u22125.1 ms. Stored/cheaper TransferID: \u22121.6 to \u22122.1 more. Candidates: interest.assets.sorted() at :1270 3.0 ms, pending write 2.5 ms, listing check :1263 1.0 ms. Result: analysis families (format + jobs-table) \u2192 27.9\u201328.4 ms, lands at \u226432 by ~4 ms; plus decisionNow \u2192 22.8\u201323.3 ms; conservative (jobs-table \u22126) \u2192 29.9 ms, still lands."
}

## microTimings

- {
 "what": "ManifestEntry.transferID on a checksummed entry, 40,000 calls over 10,000 entries (release, ContinuousClock, best of 3; 3 runs, 4 Nov, load 4.75)",
 "result": "296 ns/call (296, 299, 315); on one entry 297 ns; 2 Nov loaded 301\u2013416"
}
- {
 "what": "ContentHash.hex alone, 40,000 calls",
 "result": "244 ns/call (244, 249, 250)"
}
- {
 "what": "Dictionary<TransferID, Job> lookup, 10,000 jobs, fresh equal key",
 "result": "120 ns/lookup (120, 122, 122); 3 jobs reading one field 111 ns; `if let job = jobs[key]` whole-Job copy 113 ns; in-place `jobs[key]?.field = v` 187 ns; TransferID.hashValue alone 48 ns; format + lookup 443 ns"
}
- {
 "what": "Sort 10,000 AssetIDs (Set<AssetID>(10,000).sorted())",
 "result": "3.01 ms (3.01, 3.03, 3.14); already-ordered [AssetID] 0.225 ms"
}
- {
 "what": "Set<AssetID> insert, 10,000 into an empty set",
 "result": "62 ns/insert (62, 64, 66); into a reserved set 31 ns/insert"
}
- {
 "what": "ValidatedManifest.entry(for:), 10,001 entries, 40,000 calls",
 "result": "76 ns/call (76, 78, 81)"
}

## claims

- {
 "claim": "C1: the transfer id is formatted 3\u20134 times per re-routed id, each 0.3\u20130.65 \u00b5s with 4\u20135 heap allocations, about 40\u201350 % of the commit re-route and drain take-off turns and about 9 ms of supersede's 41 ms",
 "verdict": "PARTLY",
 "evidence": "Count confirmed: 4 formats per id in the commit (EngineDispatch.swift:1121, :1164, :1179, EngineJobs.swift:109, ~156 samples each) and 3 in the drain and supersede re-routes. Cost per format at the bottom of the range: 0.30 \u00b5s micro, 0.25 \u00b5s in the turn. Share refuted: 20.6 % / 16.9 % / 15.9 % = 10.1 / 7.6 / 6.4 ms, not 40\u201350 %; supersede 6.4 ms, not ~9. Allocation count not measured (no Allocations instrument)."
}
- {
 "claim": "C2: about 7\u20139 jobs-table accesses per id, keyed by a 66-byte TransferID string, with 2\u20133 whole-Job copies, about 0.7\u20131.3 \u00b5s per id",
 "verdict": "CONFIRMED",
 "evidence": "9\u201312 hashed Dictionary<TransferID, Job> accesses at ~13 call sites (addInterest :132/:156/:157/:161/:165/:179, failFastJoiner :225/:231/:245/:246, relane :263/:264, reroute :1188), Job copies at :132, :165, relane :263 (initializeWithCopy for Job 2.1 % self in shape 2). Measured 1.03 / 1.21 / 1.09 \u00b5s per id; 21.1 % / 26.8 % / 27.1 % of the turns, the largest category in each. One hashed access is 111\u2013120 ns micro, so 9 accesses = the measured 1.0 \u00b5s."
}
- {
 "claim": "C3: the two 10,000-id AssetID sorts each cost about 3.3 ms (unbound.sorted() in committed, job.assets.sorted() in publishTerminal); removeJob's retireProgress costs about 1.3 ms",
 "verdict": "PARTLY",
 "evidence": "Sorts confirmed: committed :1120 2.96 ms and publishTerminal :635 2.95 ms in the turn (183/182 samples of 3,030 at 49.08 ms); 3.01 ms micro. retireProgress + removeJob together are 0.6 ms (37 samples, 1.2 %), about half the claimed 1.3 ms."
}
- {
 "claim": "C4: manifest lookups with ManifestEntry copies, group pending writes and set inserts cost about 0.5\u20130.9 \u00b5s per id",
 "verdict": "CONFIRMED",
 "evidence": "Manifest lookups + entry copies 0.36 / 0.35 / 0.36 \u00b5s per id (3.6 / 3.5 / 3.6 ms) plus the per-id pending write, assets.insert, Job.insertAsset (and removeAsset in the drain) 0.55 / 0.71 / 0.55 \u00b5s: about 0.9 / 1.06 / 0.91 \u00b5s per id, at or just above the top of the claimed range. entry(for:) itself is 76 ns; the rest is copying/destroying the entry's strings."
}
- {
 "claim": "New, not in the analysis: decisionNow() copies the whole EngineState on every join",
 "verdict": "CONFIRMED",
 "evidence": "outlined init with copy of EngineState under SyncEngine.decisionNow() (EngineFollow.swift:242, `self.state.reading?.at ?? \u2026`; EngineState has 260 fields) and the matching outlined destroy after noteJoin (attributed to EngineJobs.swift:193 by inlining): 10.7 % / 11.0 % / 12.8 % = 5.2 / 4.9 / 5.1 ms, ~0.5 \u00b5s per id. The supersede analysis's F2 put the clock read at ~1 ms."
}

## caveats

The CPU profiles were recorded on 2 Nov at 1-minute loads of 24–389 (the host never fell to 10 during a 13-minute wait); only the on-CPU sample shares are used from them, and the implied ms are share × the 4 Nov quiet baseline (loads 4.75–5.26, S3-R23). Per-turn spans inside the traces (52–140 ms for shape 1) are not timings and are not quoted. Shape 3's 1,500 samples combine two traces (s3cpu lost events under load and was stopped after 3 turns; s3cpu-b 6 clean turns); both halves rank the categories the same. Categorisation is rule-based (tools/cat.py: frame-name table, then innermost engine line); "everything else" is 9.5–10.9 % and itemised in the attribution files; inlining shifts some line attribution (the EngineState destroy sits on EngineJobs.swift:193). The per-fix savings are arithmetic on measured shares, not measurements of patched code; "one jobs-table access" assumes ~2 accesses (0.3 µs) survive per id. Not verified: allocations per TransferID format; the one-user-waiter-per-id and 10,000-group variants. Micro-timings on 2 Nov were 5–40 % slower under load; the 4 Nov quiet ones are the figures. The pre-existing `M Package.swift` in the repository predates this session and was not touched; nothing tracked was modified, nothing committed, the s3f worktree was only read. The report is the profiler's own output and has not yet had the independent review (step 4 of the resume plan). At 10 ms none of the fixes suffices (23–26 ms of per-id work remains even with every branch-free fix), so the analysis's finding 4 stands.

## reportPath

/Users/admin/Documents/ZTronAssetKit/.build-orchestrator/s3f-c20-analysis/profile-40ms.md
