# Profiling three C2 shapes of the WP-F sync engine at 8e1fb24

Analysis only: C2 stays 10 ms. This measures where the three 41–49 ms turns spend their time, to check the
read-only analysis in `analysis-40ms.md`, which INFERRED its numbers. Nothing in the engine was changed; nothing
tracked was modified; nothing was committed.

Run `wf_6927a3a9-c76`, profiler step. Started 2 Nov (paused 14:19 at the owner's request, before the report was
written); resumed 4 Nov 12:54, when the host was quiet, and finished. The profiles, attribution and micro-timings are
the 2 Nov ones; the baselines and micro-timings were re-taken on 4 Nov at a 1-minute load of 4.8–5.3.

## 1. Method

- Scratch copy: `git archive 8e1fb24` of the `.worktrees/s3f` worktree, extracted to
  `/Users/admin/Documents/ZTronAssetKit/.build-prof40/src` (its `Package.swift` is byte-identical to 8e1fb24's). Added to
  the benchmark target only: the verifiers' probe `VerifyC20SupersedeBench.swift` (copied from
  `.build-orchestrator/s3f-probes-c20/correct/`) and a scratch-only `Prof40Shapes.swift` that repeats each benchmark's own
  10,000-id scenario `PROF40_RUNS` times (default 15) and holds the micro-timings. No engine source changed.
- Toolchain: Apple Swift 6.4 (swiftlang-6.4.0.34.1), macOS 27.0 SDK, target arm64-apple-macosx14.0, 8 cores.
- Build: `swift build -c release --scratch-path .build-prof40/spm -Xswiftc -enable-testing` (verify.sh's benchmark
  configuration), 13:26–13:32 on 2 Nov, exit 0 (`out/build.log`). Not rebuilt on 4 Nov (sources untouched).
- Baselines: `swift test -c release --skip-build --scratch-path .build-prof40/spm -Xswiftc -enable-testing --filter <case>`,
  the case's own best of 3 (`out/baseline.sh`, logs `out/base*-*.log`). The cases fail their 10 ms expectation by design
  (rc=1); the figures are the benchmarks' own printed windows.
- Profiles: `xcrun xctrace record --template "CPU Profiler"` (it works on this Mac) on the release
  `swiftpm-testing-helper` run filtered to one `Prof40Shapes` case (`out/prof.sh`, `out/prof2.sh`). Exported with
  `xcrun xctrace export --xpath '/trace-toc/run/data/table[@schema="cpu-profile"]'` to `out/s*cpu*.cpu.xml`, parsed to
  pickles by `tools/parse.py` and `tools/symb.py`.
- Turn selection (`tools/turn.py`): samples on the actor's thread, inside each repetition's time cluster, whose backtrace
  contains the measured turn's root frame. Setup (building the ids, the applies and follows before the timed turn) is
  excluded by the root-frame rule.
  - Shape 1: `SyncEngine.publish(_:epoch:file:cancelledAttempt:)`'s resumption (3,030 of 3,030 samples) and
    `SyncEngine.committed(_:binding:locations:since:)` (3,010 of them).
  - Shape 2: `releaseOneHeldTurn` → `continueFollow` (3,466 of 3,466), with `drainEventsAfterFollow` (3,392) and the verdict
    replay `replayVerdict(_:epoch:_:)` (3,378); `takeOffMovedBefore` itself holds 604, its re-routes (`rerouteMovedBefore` →
    `reroute`) 2,759.
  - Shape 3: `publicationFailed(_:epoch:file:error:…)` (1,500 of 1,500) and `supersede(_:settling:listing:)` (1,494).
- Attribution (`tools/cat.py`, inclusive of callees): a leaf-to-root walk; the first frame matching a name rule
  (`ManifestEntry.transferID.getter`, `ContentHash.hex.getter`, `TransferID.content(`; `.sorted(`/`_merge`/`AssetID.<`;
  `Set.insert`/`Job.insertAsset`/…; `ValidatedManifest.entry(for:)`/`of ManifestEntry`; `of Job`/`for Job`;
  `retireProgress`/`removeJob`; `of EngineState`) decides, else the innermost engine source line decides by a line table.
  The residual is "everything else" and is itemised in `out/attribution-shape{1,2,3}.txt`.
- Repetitions and samples inside the measured turn: shape 1, 15 turns, 3,030 samples (187–244 per turn); shape 2, 16
  turns, 3,466 samples (57–257 per turn); shape 3, 9 turns, 1,500 samples (153–191 per turn) from two traces, `s3cpu`
  (3 turns; xctrace reported lost events, so the 10-run recording was stopped) and `s3cpu-b` (6 turns, clean). The mean
  on-CPU sample interval was 0.27–0.60 ms, so each shape has well over the 500 samples asked for.
- Micro-timings: `Prof40Shapes/micro`, `ContinuousClock`, best of 3 inside the test, run 3 times (`out/micro3-*.log`,
  4 Nov, quiet) and earlier at a loaded host (`out/micro1.log`, `out/micro2-*.log`).
- Loads: `sysctl -n vm.loadavg` before and after every run, in `out/loads.txt`.

### Loads

| Run | 1-minute load before → after | Quiet (≤ 10)? |
|---|---|---|
| Build (2 Nov) | 50.6 → 143.0 | no |
| Baselines base1 (2 Nov 13:33) | 84.5 → 72.7 | no |
| Profile s1cpu, shape 1 (2 Nov 13:33) | 77.2 → 40.7 | no (shares only) |
| Profile s2cpu, shape 2 (2 Nov 13:38) | 389.4 → 272.4 | no (shares only) |
| Profile s3cpu, shape 3 (2 Nov 13:39) | 272.4 → 84.3 | no (shares only; lost events) |
| Profile s3cpu-b, shape 3 (2 Nov 13:56) | 31.6 → 24.4 | no (shares only) |
| Quiet wait (2 Nov 13:58–14:11, 13 min) | 20.7 → 214.3 | gave up |
| Baselines base2/base3 (2 Nov 14:11–14:17) | 214.3 → 207.7 | no |
| **Baselines base4 (4 Nov 12:54:16–12:54:32)** | **4.94 → 5.26** | **yes** |
| **Micro-timings micro3 (4 Nov 12:54:54–12:54:55)** | **4.75 → 4.75** | **yes** |

Under S3-R23, only the 4 Nov figures count as timings. The 2 Nov profiles are used for the share of on-CPU samples,
which is what matters for attribution; their per-turn spans were inflated 1.1–3× by the load and are not quoted as timings.

## 2. Baselines

Best of 3, the benchmark's own window.

| Shape | Case | 4 Nov, quiet (load 4.9–5.3) | 2 Nov, loaded | Cycle 20 |
|---|---|---|---|---|
| 1. Commit re-routes | `BenchSync.concentrationCommitRerouteTurns` | **49.08 ms** [49.17, 49.08, 49.15] | 48.94 ms | 47.99–49.35 ms |
| 2. Drain take-off | `BenchSync.movedBeforeDrainTurns` | **44.92 ms** [44.92, 47.61, 45.41] | 54.65 ms (inflated) | 45.67–49.08 ms |
| 3. `supersede` of a superseded publication | `VerifyC20SupersedeBench` (PROBE-C20C-SUPERSEDE-C2) | **40.21 ms** [40.21, 40.43, 40.52] | 41.07 ms | 41.09 ms |

All three quiet figures are within 2 % of cycle 20's. The implied ms below use the quiet baselines.

## 3. Breakdown inside the measured turn

Share of samples by category, including callees, and the ms it implies at the quiet baseline.

| Category | 1. Commit re-routes (3,030 samples, 49.08 ms) | 2. Drain take-off (3,466 samples, 44.92 ms) | 3. `supersede` (1,500 samples, 40.21 ms) |
|---|---|---|---|
| Transfer-id formatting (`ManifestEntry.transferID` → `ContentHash.hex` → `TransferID.content`, and their allocations) | 625 · **20.6 %** · 10.1 ms | 587 · **16.9 %** · 7.6 ms | 239 · **15.9 %** · 6.4 ms |
| Jobs-table access (`Dictionary<TransferID, Job>` lookups, `TransferID`/`String` hashing and `==`, Job copies, retain/release, `swift_beginAccess`) | 639 · **21.1 %** · 10.3 ms | 930 · **26.8 %** · 12.1 ms | 407 · **27.1 %** · 10.9 ms |
| Sorting (AssetID `<`, sort) | 367 · **12.1 %** · 5.9 ms | 199 · **5.7 %** · 2.6 ms | 116 · **7.7 %** · 3.1 ms |
| Other Set and Dictionary inserts, removals, lookups | 487 · **16.1 %** · 7.9 ms | 767 · **22.1 %** · 9.9 ms | 247 · **16.5 %** · 6.6 ms |
| Manifest lookups (`applied.entry(for:)`) and `ManifestEntry` copies | 223 · **7.4 %** · 3.6 ms | 270 · **7.8 %** · 3.5 ms | 135 · **9.0 %** · 3.6 ms |
| `retireProgress` and `removeJob` | 37 · **1.2 %** · 0.6 ms | 0 · **0 %** · 0 ms | 21 · **1.4 %** · 0.6 ms |
| Whole-`EngineState` copy in `decisionNow()` (not in the analysis) | 323 · **10.7 %** · 5.2 ms | 380 · **11.0 %** · 4.9 ms | 192 · **12.8 %** · 5.1 ms |
| Everything else | 329 · **10.9 %** · 5.3 ms | 333 · **9.6 %** · 4.3 ms | 143 · **9.5 %** · 3.8 ms |

### Where each category's samples sit (call site, samples, implied ms)

Shape 1, commit re-routes:
- Formatting, 4 sites of equal weight: `reroute` EngineDispatch.swift:1179 (160, 2.6 ms), `addInterest`
  EngineJobs.swift:109 (157, 2.5 ms), `committed` EngineDispatch.swift:1121 (154, 2.5 ms), `reroute` :1164 (154, 2.5 ms).
  About 0.25 µs per format in the turn.
- Jobs table: `addInterest` :157 (100), :156 (80), :165 (58), :161 (49), :132 (41), :179 (11); `failFastJoiner` :231
  (61), :225 (56), :245 (43), :246 (11); `relane` :264 (43), :263 (19); `reroute` :1188 (62, the destroy of the
  copied Job). About 9–12 hashed accesses per id, 1.03 µs per id.
- Sorting: `unbound.sorted()` in `committed` :1120 (183, 2.96 ms) and `job.assets.sorted()` in `publishTerminal`
  EngineJobs.swift:635 (182, 2.95 ms).
- Other sets: `groups[token]?.pending[asset] = …` in `reroute` :1179 (176, 2.8 ms), `Job.insertAsset` EngineState.swift:791
  (97, 1.6 ms), `assets.insert` in `addInterest` :156 (78, 1.3 ms), `committed` :1122 (73, 1.2 ms), the set building in
  `committed` :1104/:1110/:1114 (54, 0.9 ms).
- Manifest: `committed` :1121 `applied.entry(for:)` + entry copy (119, 1.9 ms), `noteJoin` :191 (58, 0.9 ms),
  `reroute` :1151 (35, 0.6 ms).
- EngineState copy: `decisionNow()` EngineFollow.swift:242 `outlined init with copy of EngineState` (182, 2.9 ms) and its
  `outlined destroy of EngineState` after `noteJoin`, attributed to EngineJobs.swift:193 (137, 2.2 ms). One per join.
- Everything else: the retain/release and `outlined destroy of RemoteSource?` / `ValidatedManifest` of the values passed
  through `committed` :1122 → `reroute` :1188 → `addInterest` (about 3.9 ms), `publish` :1089 resumption (1.0 ms),
  `publishTerminal` :638 lookups (0.4 ms).

Shape 2, drain take-off:
- Formatting, 3 sites in the re-route plus the follow scan: `reroute` :1164 (197, 2.6 ms), :1179 (177, 2.3 ms),
  `addInterest` :109 (172, 2.2 ms), `continueFollowScans` EngineFollow.swift:772 (39, 0.5 ms, outside the re-route).
- Jobs table: `addInterest` :156 (120), :157 (107), :165 (83), :161 (57), :132 (52), :179 (12); `reroute` :1188 (99);
  `relane` :264 (65), :263 (19); `failFastJoiner` :245 (55), :231 (55), :225 (52), :246 (20); `takeOffMovedBefore`
  :560 (66); `replayVerdict` :615 (60). 1.21 µs per id. `initializeWithCopy for Job` alone is 2.1 % self.
- Sorting: `interest.assets.sorted()` in `takeOffMovedBefore` :559 (198, 2.6 ms).
- Other sets: `reroute` :1179 pending write (194, 2.5 ms), `Job.removeAsset` :797 (139, 1.8 ms), `Job.insertAsset` :791
  (123, 1.6 ms), `addInterest` :156 (92, 1.2 ms), `rerouteMovedBefore` :574 (81, 1.0 ms), `takeOffMovedBefore`
  :559 `held.contains` (53), :557 `subtract` (48), :552 `intersection` (27) (1.7 ms together).
- Manifest: `reroute` :1151 (172, 2.2 ms), `noteJoin` :191 (52, 0.7 ms), `continueFollowScans` :768 (24), :574 (18).
- EngineState copy: `decisionNow()` :242 (378, 4.9 ms).
- Everything else: value destroys and retain/release around `rerouteMovedBefore` :574 → `reroute` :1188 (3.4 ms).

Shape 3, `supersede`:
- Formatting, 3 sites: `addInterest` :109 (87, 2.3 ms), `reroute` :1164 (83, 2.2 ms), :1179 (69, 1.8 ms).
- Jobs table: `addInterest` :157 (66), :156 (54), :165 (35), :161 (34), :132 (25), :177/:179 (7); `reroute` :1188
  (43); `failFastJoiner` :225 (39), :245 (27), :231 (26), :246 (10); `relane` :264 (26), :263 (13). 1.09 µs per id.
- Sorting: `interest.assets.sorted()` in `supersede` EngineDispatch.swift:1270 (112, 3.0 ms).
- Other sets: `reroute` :1179 pending write (92, 2.5 ms), `addInterest` :156 (55, 1.5 ms), `Job.insertAsset` :791
  (55, 1.5 ms), `supersede` :1271 (43, 1.2 ms).
- Manifest: `reroute` :1151 (55, 1.5 ms), the `contains(where:)` listing check in `supersede` :1263 (39, 1.0 ms),
  `noteJoin` :191 (28, 0.8 ms).
- EngineState copy: `decisionNow()` :242 (100, 2.7 ms) and its destroy after `noteJoin` :193 (92, 2.5 ms).
- Everything else: value destroys and retain/release in `supersede` :1271 → `reroute` :1188 (3.2 ms),
  `publicationFailed` :1211 (0.4 ms).

### Top 15 functions by self time inside the turn

Shape 1 (3,030 samples): `swift_release` 206 (6.8 %, 3.3 ms); `protocol witness for Collection.subscript.read in
String.UTF8View` 174 (5.7 %, 2.8 ms); `_xzm_free_main` 171 (5.6 %, 2.8 ms); `swift_retain` 152 (5.0 %, 2.5 ms);
`Hasher.combine(bytes:)` 122 (4.0 %, 2.0 ms); `_xzm_xzone_malloc_tiny` 99 (3.3 %, 1.6 ms); `swift_bridgeObjectRelease`
99 (3.3 %, 1.6 ms); `swift_bridgeObjectRetain` 91 (3.0 %, 1.5 ms); `DYLD-STUB$$swift_bridgeObjectRelease` 79 (2.6 %,
1.3 ms); `DYLD-STUB$$swift_bridgeObjectRetain` 79 (2.6 %, 1.3 ms); `specialized Sequence.lexicographicallyPrecedes`
63 (2.1 %, 1.0 ms); `<deduplicated_symbol>` 55 (1.8 %, 0.9 ms); `_platform_memmove` 54 (1.8 %, 0.9 ms);
`specialized UnsafeMutablePointer.initialize(to:)` 54 (1.8 %, 0.9 ms); `Hasher._finalize()` 54 (1.8 %, 0.9 ms).

Shape 2 (3,466 samples): `swift_release` 219 (6.3 %, 2.8 ms); `_xzm_free_main` 215 (6.2 %, 2.8 ms);
`Hasher.combine(bytes:)` 197 (5.7 %, 2.6 ms); `swift_retain` 152 (4.4 %, 2.0 ms); `String.UTF8View subscript.read
witness` 150 (4.3 %, 1.9 ms); `_xzm_xzone_malloc_tiny` 117 (3.4 %, 1.5 ms); `swift_bridgeObjectRelease` 112 (3.2 %,
1.5 ms); `DYLD-STUB$$swift_bridgeObjectRelease` 94 (2.7 %, 1.2 ms); `_platform_memmove` 83 (2.4 %, 1.1 ms);
`swift_bridgeObjectRetain` 79 (2.3 %, 1.0 ms); `specialized Sequence.elementsEqual` 76 (2.2 %, 1.0 ms);
`<deduplicated_symbol>` 74 (2.1 %, 1.0 ms); `_stringCompare(_:_:expecting:)` 74 (2.1 %, 1.0 ms);
`initializeWithCopy for Job` 72 (2.1 %, 0.9 ms); `DYLD-STUB$$swift_bridgeObjectRetain` 68 (2.0 %, 0.9 ms).

Shape 3 (1,500 samples): `swift_release` 108 (7.2 %, 2.9 ms); `swift_retain` 94 (6.3 %, 2.5 ms);
`swift_bridgeObjectRelease` 79 (5.3 %, 2.1 ms); `_xzm_free_main` 70 (4.7 %, 1.9 ms); `Hasher.combine(bytes:)` 68
(4.5 %, 1.8 ms); `DYLD-STUB$$swift_bridgeObjectRelease` 53 (3.5 %, 1.4 ms); `String.UTF8View subscript.read witness`
48 (3.2 %, 1.3 ms); `swift_bridgeObjectRetain` 47 (3.1 %, 1.3 ms); `_xzm_xzone_malloc_tiny` 46 (3.1 %, 1.2 ms);
`DYLD-STUB$$swift_bridgeObjectRetain` 44 (2.9 %, 1.2 ms); `_platform_memmove` 41 (2.7 %, 1.1 ms); `Hasher._finalize()`
36 (2.4 %, 1.0 ms); `specialized Sequence.lexicographicallyPrecedes` 23 (1.5 %, 0.6 ms); `specialized
Sequence.elementsEqual` 23 (1.5 %, 0.6 ms); `ValidatedManifest.entry(for:)` 21 (1.4 %, 0.6 ms).

Reading: retain/release and malloc/free are about 25–30 % of self time in every shape, and the 66-byte `TransferID`
string shows up as `Hasher.combine(bytes:)` + `String.UTF8View` reads + `_stringCompare`/`elementsEqual` (hashing and
`==` of the jobs key), together 10–12 %. No single function dominates.

## 4. Micro-timings (release, `ContinuousClock`, best of 3 inside the test, 3 runs on 4 Nov at load 4.75)

| What | 4 Nov quiet (best; the 3 runs) | 2 Nov loaded |
|---|---|---|
| `ManifestEntry.transferID` on a checksummed entry, 40,000 calls over 10,000 entries | **296 ns/call** (296, 299, 315) | 301–416 |
| `ManifestEntry.transferID`, 40,000 calls on one entry | 297 ns (297, 302, 313) | 302–384 |
| `ContentHash.hex` alone, 40,000 calls | 244 ns (244, 249, 250) | 239–359 |
| `Dictionary<TransferID, Job>` lookup, 10,000 jobs, fresh equal key | **120 ns** (120, 122, 122) | 121–157 |
| `Dictionary<TransferID, Job>` lookup, 3 jobs, read one field | 111 ns (111, 113, 114) | 112–146 |
| `if let job = jobs[key]` (whole-Job copy), 3 jobs | 113 ns (113, 115, 121) | 116–141 |
| In-place `jobs[key]?.field = v`, 3 jobs | 187 ns (187, 192, 194) | 192–264 |
| `TransferID.hashValue` alone | 48 ns (48, 52, 52) | 52–70 |
| Format + lookup, `jobs[entry.transferID]` | 443 ns (443, 446, 452) | 454–571 |
| `Set<AssetID>(10,000).sorted()` | **3.01 ms** (3.01, 3.03, 3.14) | 3.07–3.93 |
| `[AssetID]` of 10,000, already in order, `.sorted()` | 0.225 ms | 0.225–0.285 |
| `Set<AssetID>` insert, 10,000 into an empty set | **62 ns/insert** (62, 64, 66) | 61–83 |
| `Set<AssetID>` insert into a reserved set | 31 ns/insert (31, 32, 32) | 30–40 |
| `ValidatedManifest.entry(for:)`, 10,001 entries, 40,000 calls | 76 ns/call (76, 78, 81) | 78–99 |

The in-turn figures agree: one format is about 0.25 µs of turn time (shape 1: 156 samples per site), one hashed jobs
access about 0.11–0.12 µs, so 9 of them are the measured 1.0 µs per id.

## 5. Verdicts on the claims

- **C1 — PARTLY.** The count is confirmed: 4 formats per re-routed id in the commit (EngineDispatch.swift:1121, :1164,
  :1179 and EngineJobs.swift:109) and 3 in the drain and supersede re-routes (:1164, :1179, :109). The cost per format
  is at the bottom of the claimed range: 0.30 µs micro, 0.25 µs in the turn (claimed 0.3–0.65). The share is refuted:
  formatting is **20.6 % / 16.9 % / 15.9 %** of the three turns (10.1 / 7.6 / 6.4 ms), not 40–50 %; in `supersede` it is
  6.4 ms, not about 9. The 4–5 heap allocations per format were not counted (no allocation instrument was run); the
  malloc/free self time under the formatting frames is consistent with several small allocations per call.
- **C2 — CONFIRMED.** 9–12 hashed `Dictionary<TransferID, Job>` accesses per id at about 13 call sites in `addInterest`,
  `failFastJoiner`, `relane` and `reroute`, with whole-Job copies at EngineJobs.swift:132, :165 and `relane` :263
  (`initializeWithCopy for Job` is 2.1 % of shape 2's self time). Measured **1.03 / 1.21 / 1.09 µs per id**, inside the
  claimed 0.7–1.3 µs and in the upper half. It is the largest category in every shape: 21.1 % / 26.8 % / 27.1 %.
- **C3 — PARTLY.** The two 10,000-id sorts are confirmed: `unbound.sorted()` in `committed` 2.96 ms and
  `job.assets.sorted()` in `publishTerminal` 2.95 ms in the turn; 3.01 ms micro (claimed 3.3). `removeJob`'s
  `retireProgress` is overstated: `retireProgress` + `removeJob` together are **0.6 ms** (1.2 %), not 1.3 ms.
- **C4 — CONFIRMED, at the top of the range.** Manifest lookups with `ManifestEntry` copies are 0.36 / 0.35 / 0.36 µs
  per id (3.6 / 3.5 / 3.6 ms), and the per-id group pending write, `assets.insert` and `Job.insertAsset` (and
  `Job.removeAsset` in the drain) another 0.55 / 0.71 / 0.55 µs: about **0.9 / 1.06 / 0.91 µs per id** against the claimed
  0.5–0.9. `entry(for:)` itself is 76 ns; the rest is copying and destroying the entry's strings.
- **Not in the analysis:** `decisionNow()` (EngineFollow.swift:242, `self.state.reading?.at ?? …`) makes an
  `outlined init with copy of EngineState` — the whole 260-field struct, retaining every reference field — on every
  join, destroyed after `noteJoin` returns. It is **10.7 % / 11.0 % / 12.8 %** (5.2 / 4.9 / 5.1 ms), about 0.5 µs per id,
  the fourth-largest category. The supersede analysis's F2 noted the clock read as "about 1 ms"; it is 5 ms.
- **No single cost dominates**: the largest category is 21–27 %, and the sum of the three largest is 50–60 %.

## 6. What each fix family would save, from the measured shares

Savings are the measured samples of the call sites a fix removes, times the quiet baseline. "Jobs-table, one access"
assumes about 2 accesses (one in-place modify and one read) survive per id, about 0.3 µs, since the micro-timings put
one hashed access at 0.11–0.19 µs.

| Fix family (branch-free unless noted) | 1. Commit re-routes, 49.08 ms | 2. Drain take-off, 44.92 ms | 3. `supersede`, 40.21 ms |
|---|---|---|---|
| Format each transfer id once (C1 / F1: hoist in `reroute`, pass to `addInterest`; in the commit also compare with `sameTransfer` at :1121) | **−7.6 ms** (3 of 4 sites); −5.1 ms if :1121 keeps formatting | **−4.7 ms** (2 of 3 sites; the follow scan's 0.5 ms stays) | **−4.3 ms** (2 of 3 sites) |
| One jobs-table access per id, no Job copy (C4 / F3 / F2 `Job.join`) | **−7 to −7.5 ms** of 10.3 | **−8.5 to −9 ms** of 12.1 (includes the take-off's per-id `removeAsset` accesses) | **−7.5 to −8 ms** of 10.9 |
| Filter before sorting in `publishTerminal` (C2 of the commit analysis) | **−3.4 ms** (sort 2.95 + lookups 0.5) | 0 (not in this turn) | 0 (not in this turn) |
| Take-off by intersection and one subtract (F4) | — | **−2 ms** net (`removeAsset` 1.8, `contains`/`subtract`/`intersection` 1.7, minus the overlap counted above); the sort stays, since the held set is the whole interest | — |
| Stop copying `EngineState` in `decisionNow()` (read `reading` without forming the optional projection, or keep the decision instant beside `reading`; engine-only, no branch; not in the analysis) | **−5.2 ms** | **−4.9 ms** | **−5.1 ms** (F2 already drops the unused `decisionNow()` on the join path) |
| Cheaper or stored `TransferID` (C3 / F2b / F1b, model type, NEEDS-HUMAN-REVIEW) | −2.0 to −2.5 ms more (the last site) | −2.5 to −3 ms more (incl. the scan) | −1.6 to −2.1 ms more |
| Candidates the shares point to, not in the analysis | `unbound.sorted()` 2.96 ms; the pending write `groups[token]?.pending[asset]` 2.8 ms; `committed`'s set building 0.9 ms | the pending write 2.5 ms; `interest.assets.sorted()` 2.6 ms (F7's AssetID `<` fast path would take 1.5–2 ms, 1 branch) | `interest.assets.sorted()` at :1270 3.0 ms; the pending write 2.5 ms; the listing check at :1263 1.0 ms |

### Does each shape land at 32 ms or less with the branch-free fixes?

| Shape | The analysis's own families, in full | Plus the `decisionNow()` copy | Conservative variant |
|---|---|---|---|
| 1. Commit re-routes | 49.1 − 7.6 − 7.3 − 3.4 = **30.6–31.1 ms: yes, by 1–1.5 ms** | **25.4–25.9 ms: yes** | 4→2 formats and a partial jobs-table fix (−6): 33–35 ms, **no** |
| 2. Drain take-off | 44.9 − 4.7 − 8.8 − 2 = **29.4–29.9 ms: yes, by about 2 ms** | **24.5–25 ms: yes** | jobs-table −6.5: 31.7 ms, borderline |
| 3. `supersede` | 40.2 − 4.3 − 7.8 = **27.9–28.4 ms: yes, by about 4 ms** | **22.8–23.3 ms: yes** | jobs-table −6: 29.9 ms, yes |

So: all three can reach 32 ms with no new branch, but shapes 1 and 2 only with the formatting and jobs-table fixes
applied in full, and with 1–2 ms of margin at the quiet baseline. Removing the `EngineState` copy in `decisionNow()`
is the single change that gives every shape a 6–9 ms margin, and it is engine-only. The analysis's expected 26–36 /
24–35 / 28–33 ms after the fixes hold, but for a different reason than it gave: formatting is worth about half of what
it inferred, the jobs table and the hidden state copy make up the difference.

At 10 ms, none of this is enough: even the "plus `decisionNow()`" column leaves 23–26 ms of per-id work, so finding 4
of the analysis (10 ms still needs RR-21's splitting) stands.

## 7. Caveats and what was not verified

- The CPU profiles were recorded at 1-minute loads of 24–389 (the host was shared and never fell to 10 during the
  13-minute wait on 2 Nov). The shares are of on-CPU samples on the actor's thread, which the load does not
  redistribute between the engine's own functions, but the per-turn spans in the traces (52–140 ms for shape 1) are
  not timings and are not quoted. The implied ms are share × the 4 Nov quiet baseline.
- Shape 3's 1,500 samples combine two traces; the first (`s3cpu`) lost events under load, so its 10-run recording was
  stopped after 3 turns and re-recorded (`s3cpu-b`, 6 clean turns). Both halves give the same category ranking.
- The categorisation is by rule (`tools/cat.py`): a frame-name table first, then the innermost engine line. Where a
  line both formats and looks up (EngineDispatch.swift:1121) the name rule splits it. "Everything else" (9.5–10.9 %)
  is mostly retain/release and the destroys of `RemoteSource?`, `ValidatedManifest` and tuple values passed by value
  through `committed`/`supersede`/`rerouteMovedBefore` → `reroute` → `addInterest`; it is itemised in the attribution files.
- Inlining moves line attribution: the `EngineState` destroy sits on EngineJobs.swift:193 because `noteJoin` is
  inlined into `addInterest`; the copy itself is unambiguous (`outlined init with copy of EngineState` under
  `decisionNow()`).
- Not verified: the number of heap allocations per `TransferID` format (no Allocations instrument was run); the
  per-fix savings are arithmetic on measured shares, not measurements of patched code; the one-user-waiter-per-id and
  10,000-group variants the analysis worried about were not profiled.
- The profiler's temporary tests and the probe live only in the scratch copy; the worktree and the repository were not
  modified and nothing was committed.

## Raw exports

Under `/Users/admin/Documents/ZTronAssetKit/.build-prof40/out/`: traces `s1cpu.trace`, `s2cpu.trace`, `s3cpu.trace`,
`s3cpu-b.trace`; exports `*.cpu.xml`; parsed samples `*.pkl`, turn samples `*.turn.pkl`, annotated `*.ann.pkl`
(`s1cpu.ann.pkl`, `s2.ann.pkl`, `s3all.ann.pkl` are the three attributed sets); `attribution-shape{1,2,3}.txt`;
baselines `base1-*.log`, `base2-*.log`, `base3-*.log`, `base4-*.log` (4 Nov, quiet); micro-timings `micro1.log`,
`micro2-{1,2,3}.log`, `micro3-{1,2,3}.log` (4 Nov, quiet); `loads.txt`; the scripts `baseline.sh`, `prof.sh`,
`prof2.sh`, `quiet.sh`. Parsers under `.build-prof40/tools/`.
