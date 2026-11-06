# Level 4 orchestrator rulings (WP-F sync engine) — input for the close-out and for ADR-053

Source of truth for the close-out fixers and verifiers and later for the docs agents. `docs/adr-drafts/f.md` (F-1…, f-n REENTRANCY rows, CCR-1) holds the detail; this file holds what the orchestrator decided. The orchestrator's rulings win over any draft. Findings referenced as `L4-V3-nn` are the issues in `.build-orchestrator/l4-remaining-f.json` (verification round 3 of the main run, not yet fixed).

## Runs
- Owner decisions (2026-10-15): close-out bar **strict** (every cycle hunts for new bugs; any proven bug blocks); weekly-usage stop 55 %; all roles on Opus 5.5.
- Level 4 main run `wf_3286fe9b-a79` (author → three verification rounds → two fix rounds; blocking 13 → 11 → 8). 7.8 h; weekly usage 2 % → 13 %.

## Rulings

- **L4-R1 / CCR-1 (R-APL-3 end to end, approved; Package.swift already changed).** The orchestrator committed `7cf647c` on `wp/f`: `ZTronAssetSyncTests` gains a **test-only** dependency on `ZTronAssetAppleHosted` (the same pattern as its test-only Transport dependency); Sync's production dependencies stay Model and Storage. WP-F writes its **own** pack-backend fake inside `Tests/ZTronAssetSyncTests/` (a copy of, or a subset of, `Tests/ZTronAssetAppleHostedTests/FakePackBackend.swift`, with a header naming its source and ADR-040). WP-E's files and `ZTronAssetTestSupport` stay untouched (no new dependency for the target every test links). Write the test with the exact §11 display name `R-APL-3: an asset adopted from a FakePackBackend source is served from blobs/ after its pack is released`: an `AppleHostedRemoteSource` over the fake, driven through the real engine and the real store; assert that the served location is under `blobs/` after the pack release and never a pack location. `AppleHostedRemoteSource` is `@available(iOS 26.0, macOS 26.0, *)`, so gate the test (and the fake's uses) per test, following `docs/adr-drafts/ios.md`; it must run and pass on the macOS host and on the iOS 27 simulator. Findings L4-V3-02 and L4-V3-11 close when this test exists and genuinely fails if adoption serves a pack location (show it with a mutant).

- **L4-R2 / F-15 (approved as decided):** a run whose manifest fetch passed `manifestFetchDeadline` ends `.complete` with `manifestFresh == false`, writes no stamp and leaves the sync due. The docs level amends ARCHITECTURE §7.10's "`markSynced` only for `.complete`" to "only for a `.complete` run with a fresh manifest".

- **L4-R3 / F-16 (approved as decided):** one debounced retry of an offline run without a network edge, then edge-only. This is one bounded retry, not polling, so R-SYN-13 ("without polling") holds. The docs level records it in §7.6 / §7.10.

- **L4-R4 / F-20 ENOSPC on a roomy volume (approved, with one condition):** when the fresh free-space read shows that the volume holds the job, the engine retries with backoff instead of `awaitingSpace` / `insufficientSpace`. Condition: the backoff is bounded and joins the ordinary retry budget, so a volume that keeps answering ENOSPC while reading roomy ends in a typed failure, never an endless loop. If the current code has no such bound, add one with a test. The docs level amends the §7.6 `insufficientSpace` row.

- **L4-R5 Redundant downloads and failures recorded against present assets (L4-V3-07, L4-V3-08, F-19; blocking).**
  - The engine never creates a job for an id whose record the store holds **present at the entry's current content**. That covers runs (`materializeRun`), `ensureAvailable` materialisation, `followApplied` / `reroute`, and joins. Feed the check from what the engine already learns: `report.reused` ∪ `report.relocated` of an apply, the `locations` of commits since a plan, and a presence read where neither is enough. Answer such ids from the store instead: a waiter gets the location, a group drops the member as done, and a run counts the asset as fetched. Add PROBE-R3-2 and PROBE-R3-3/3b as regression tests (failing first).
  - Defence in depth: a failed transfer must never mark a present record failed. The engine re-checks presence before `store.recordFailure`. If the remaining await window cannot be closed engine-side, WP-F is **authorised** to add the minimal guard to `AssetStore.recordFailure(_:identity:reason:)` in `Sources/ZTronAssetStorage/Integrity/StoreIntegrity.swift`: a record that is present at `identity` is left unchanged. This is a body-only edit with a store test in `Tests/ZTronAssetStorageTests` (failing first), recorded in `f.md` as an authorised edit outside WP-F.
  - Accepted residue → Stage 3 (with OI-15): the late joiner whose new content is already live in another blob still downloads it a second time (L4-V3-12, "G"). Avoiding that needs a store primitive that binds an id to a live blob, which is a contract change not made in Level 4. That download can no longer mark anything failed (second bullet).

- **L4-R6 Space and staging (L4-V3-09, L4-V3-10; blocking):** fix as the verifier proposed. `state.freeSpace` keeps the measured reading; only the planner and the ensure's own space decision see the important-for-opportunistic copy. An attempt that fails with ENOSPC discards its partial, or keeps it through `resumePoint(after:)` when a sidecar makes it resumable. Add PROBE-R3-1 and PROBE-R3-4 as regression tests (failing first).

- **L4-R7 Suspicions by reading (L4-V3-13, L4-V3-14):** under the strict bar the fixer addresses both. For each, try to demonstrate it with a probe first. If it reproduces, commit the failing test and then the fix. If it cannot be produced, record why in `f.md` and make the code obviously correct anyway: for 13, adopt the free-space read in the turn it returns; for 14, make catch-up broadcast `assetRemoved(.pruned)` for the dropped ids, take the view's generation and send `snapshotChanged`.

- **L4-R8 Test time budgets and flakes (L4-V3-00, -01, -03, -15; blocking where a test failed).** Make the tests deterministic or cheaper; never weaken an assertion.
  - L4-V3-00: drain the stream each round, or assert on the engine's published count, so the lower bound does not depend on scheduling.
  - L4-V3-01: force each of the two orders deterministically (`NextUnitGate` / `SteppedBlockingExecutor`) instead of 500 racing iterations.
  - L4-V3-03 / -15: reduce the cost under the sanitizer.
  - A `.timeLimit` may be raised only together with a cost reduction. The test's **in-suite** TSan time at a host load around 25 must then stay at or below 50 % of its limit. Record the measured figures in F-17.

- **L4-R9 Diagnostics while degraded (orchestrator question in the author's open items; R-OBS-3):** `SyncEngine.diagnostics()` answers while the engine is degraded or its store is unavailable. That is when support needs the error ring most. It reports the last-known generation (0 if never read) and the last-known stamp (or `nil`); no signature changes. After `shutdown()` it still fails `.shutDown` (ADR-042). `metrics()` keeps its current behaviour. Add one behaviour test (display name prefix `R-OBS-3:`).

- **L4-R10 Store manifest ahead of the engine after a failed index commit (author's finding):** this is by design (ADR-050: "the in-memory state stays authoritative"). The engine follows the store's view through catch-up (made complete by L4-R7). No WP-B change in Level 4.

- **L4-R11 Outside WP-F, not blocking Level 4:** P-13 (WP-B's BenchStorage) awaits the owner's ruling (ADR-050). The `ZTronAssetKit` coverage stub and the TRACE budgets P-1/P-8/P-9/P-12 belong to WP-G (Level 5). Verifiers report them as non-blocking with the label `outside-wp`.

- **L4-R12 Coverage:** the gate is per target (`ZTronAssetSync` ≥ 90 %, measured 93.09 %). Per-file margins are not a gate. Cheap behaviour tests for EngineRuns' and EngineFailures' uncovered paths are welcome; coverage-only tests are not (G4).

- **L4-R13 REENTRANCY rows f-1…f-n:** keep citing them as "f-n (proposed)". The docs level adds them to ARCHITECTURE §10.2 with these numbers as final.

- **L4-R14 Tests written after their fixes** (the F-15 assertion and `R-SYN-4: a resolve that joins a job waiting to be online is answered offline at once`): no rewrite. The requirements verifier re-applies each old defect as a mutant and shows the test fails against it.

- **L4-R15 Earlier WP-F tests adjusted in fix round 2** (three, recorded in F-20): these are this level's own tests, not pre-existing CDN tests, so `MIGRATION.md` does not apply. They are accepted if each still verifies its requirement (the requirements verifier checks this).

## Process
- Two verifiers share the worktree: `verify.sh` writes `.verify-logs/` inside it, so take `--quick` verdicts from each agent's own exit status.
- Benchmarks and TSan on a loaded host: report the load average. A budget miss caused only by load is not blocking. A time-limit overrun counts as a flake and is blocking (L4-R8).

## Close-out continuation (cycle 11 onward; owner 2026-10-16: keep the strict bar, weekly stop 65 % for all of Level 4)
- Strict close-out `wf_0989cd6c-62c` ran cycles 1–10 (blocking per cycle 1, 3, 1, 3, 1, 1, 1, 5, 3, 2). Cycle 11 starts from `.build-orchestrator/l4-close10-remaining-f.json` (findings `L4-C10-nn`; 2 blocking, both test flakes).

- **L4-R16 Store guard in `recordFailure` (answers the cycle-1 fixer's question; approved).** Add the guard L4-R5 authorised: `AssetStore.recordFailure(_:identity:reason:)` leaves a record that is bound to a live blob at `identity` unchanged. WP-C's test `R-CLN-4: bytes a quarantine or a recorded failure dooms while quota eviction computes its candidates count toward its need` has a "failure" case that records a 404 on a present record. Retarget that case to a record the guard still lets fail, for example a stale record whose blob a recorded failure still dooms. Keep its assertions about the doomed bytes counting toward the eviction's need unchanged; the requirement it checks is the same. This is an authorised body-only edit in `Sources/ZTronAssetStorage/Integrity/StoreIntegrity.swift`, plus that one test case in `Tests/ZTronAssetStorageTests` and a new store test for the guard (failing first). Record it in `f.md` as an authorised edit outside WP-F. The engine's presence read before `recordFailure` (row f-10) stays.

- **L4-R17 Scheduling-dependent tests, as a class (blocking).** Flakes recurred in cycles 4, 8 and 10, so fixing the two reported tests is not enough. Enumerate **every** WP-F test, including the regression suites of cycles 1–10 and the test helpers (`driving`, `pump`, the stream collectors), that does any of these:
  - waits a bounded number of `Task.yield()`s or rounds for something to happen;
  - asserts a lower bound on events a consumer happens to have pulled;
  - lets a clock advance race with a driver that has not yet applied the previous step.

  Convert each one to wait on an explicit condition: the engine's `awaitCondition`, a census (`requireSleepers`, `requireObservers`, `requireHeldUnits`, `requireInstalls`), a gate, or the driver's handle. Each such wait ends on cancellation, and no assertion is weakened. Record the enumeration (file:test → pattern → fix) in `f.md`. Verifiers check the enumeration's completeness. L4-C10-07 and L4-C10-08 are instances.

- **L4-R18 Clearly right non-blocking items from cycle 10 (fix):**
  - L4-C10-00: add a test that fails under mutant M-EDGESTART, so the R-SYN-13 bound of one retry per edge is pinned.
  - L4-C10-01: a set-aside member that regains an interest keeps its original relative order; members joined in one turn are no longer reversed, and they do not jump ahead of earlier queued work beyond what R-SYN-3's lane rules require. Add a test.
  - L4-C10-02: the "Orchestrator, at merge" paragraph of `f.md` lists the §7.1 (downloading → queued triggers) and §7.6 (offline row) amendments that F-30 needs.

- **L4-R19 Stop for this close-out:** the close-out gate is 60 %, so that the merge, gates and docs fit under the owner's 65 %. If the close-out reaches 60 % with blocking issues left, the orchestrator stops, re-forecasts and asks.

## Close-out continuation (cycle 20 onward; owner 2026-10-17: weekly stop 70 % for all of Level 4; the strict bar stays)
- Continuation `wf_d8affeb1-4b4` ran cycles 11–19 (blocking per cycle 1, 1, 1, 4, 3, 1, 3, 2, 3) and stopped at the 60 % gate before fix 20. Cycle 20 starts from `.build-orchestrator/l4-close19-remaining-f.json` (findings `L4-C19-nn`). They hold 3 blocking items but 2 distinct bugs: (A) F-39's fix misses a half-open breaker whose probe passed its watchdog; (B) a probe that ends without a verdict leaves `halfOpen(probe: nil)`, nothing re-admits the parked claims, and runs repeat with a manifest request each while the clock never moves.

- **L4-R20 The stale-gate race family, as a class (blocking).** Every blocking item since cycle 15 is one family: a decision is taken from a gate state that the clock or an attempt's outcome has already changed, but that the engine has not yet processed (F-35, F-36, F-38, F-39, and L4-C19's A and B). Fixing reported cases one at a time has not converged, so:
  1. **Enumerate the gates and their transitions.** Every gate and every transition it can make without an engine turn:
     - origin throttle end (manifest and object 429s, extensions and shortening);
     - circuit breaker: open past its cooldown; half-open with a probe in flight; half-open whose probe passed `probeWatchdog`; `halfOpen(probe: nil)` after any exit without a verdict (404, cancelled, paused, superseded, offline, different cause);
     - space: `awaitingSpace` with reclaim due, a free-space sweep still owing claims;
     - policy pause whose lane is admitted again;
     - offline with a satisfied edge already seen;
     - pending-run debounce;
     - a user join's `interactiveMaxWait`.
  2. **Enumerate every decision site that reads a gate:**
     - a run settling and its outcome or blocked reason;
     - the reported `retryAt` or throttle end;
     - the pending run's gate state and its start;
     - parking or unparking a job, and re-admitting parked claims;
     - a user request failing fast or waiting;
     - the alarm's re-arm.
  3. **Make each site read the gate as it is at `now`** through **one** shared, pure evaluation, for example `gateState(origin:lane:at:)`, used by every site. Alternatively, guarantee that due transitions are processed before any settle decision. Either way the design must make the class impossible, not patch one more instance. Every no-verdict exit of a half-open probe must re-admit the claims the breaker parked.
  4. **Add a randomized model test** (seeded, prints the failing seed) that interleaves clock advances, held alarm turns (`holdAlarmTurns()`), probe outcomes of every kind, 429s and space events. Check these invariants:
     - no run settles blocked by a gate that admits at `now`;
     - no pending run starts while the gate it waits on is closed at `now`;
     - no parked claim stays parked once its gate admits and the alarm has had its turn;
     - manifest requests are bounded while the clock does not move (no runaway runs).

     It must fail on `d5191e2` for A and B.

  Record the tables (gate → transitions; site → gate read → fix) in `f.md` as F-40. Verifiers check that the enumeration is complete and try to break the invariants.

- **L4-R21 Stops:** the owner's 70 % covers all of Level 4. The close-out gate is **65 %**, so that the merge, gates and docs fit under 70 %. At 65 % with blocking issues left, the orchestrator stops, re-forecasts and asks.

## Close-out result and merge rulings (2026-10-17)
- Continuation `wf_7e52a3a2-ebc` ran cycles 20–22 (blocking 1, 1, **0**). Cycle 22's verification (both lenses, HEAD `8a3f5ad`) found no blocking issue. Its evidence: `--quick` PASS, release and iOS builds green, Sync ×3 plus TSan clean, Sync coverage 93.22–93.33 %, 1,100/1,100 on the iOS 27 simulator, the gate model over 2,000 fresh seeds, every WP-F benchmark passed. Level 4's close-out took 22 cycles in total under the strict bar (`wf_0989cd6c-62c` 1–10, `wf_d8affeb1-4b4` 11–19, `wf_7e52a3a2-ebc` 20–22). Weekly usage 13 % → ~64 %.

- **L4-R22 F-41's chain cost (decided: accept for Level 4 → Stage 3).** A chain of half-open probes ending without a verdict re-admits every job the breaker parked on each exit, so the total is quadratic (1,000 parked: 2.6–3.6 s; 10,000: ~161 s), while every turn stays within C2 (longest 2.1–3.0 ms; benchmark `R-SYN-5: a chain of half-open probes ending without a verdict over 1,000 prefetch members …`). This is accepted for Level 4: it needs a breaker that tripped and then thousands of parked objects all answering 404 in turn. The lazy re-admission F-41 describes, with an ordered index of the parked set so that each exit costs O(log n), is **assigned to Stage 3 hardening** under SPEC goal 4 (battery), with the existing benchmark as its baseline and a new bound on the total.

- **L4-R23 F-38 (a)/(b) (decided: (a), by design).** An `ensureAvailable` whose manifest is already in hand reports its scope. A member that a throttle extension answered counts as `missing`, consistent with the long-standing answer for members the gate fails fast at admission. A fresh call whose manifest fetch the throttle refuses gets `.serverUnavailable(retryAfter:)`. SPEC R-SYN-10 does not decide between the two. **WP-G (Level 5)** must keep the facade's `ensureAvailable` result faithful to this, so that a throttled-out member surfaces as missing with the report's `manifestFresh`. Revisit only if the facade's compatibility shims (WP-K) need a retry-after for the prior art's behaviour.

- **L4-R24 Remaining non-blocking items → Stage 3 hardening (no new close-out cycle):**
  - (1) Condition observers can see a half-started run inside `startRun`: `reserveManifestProbe()` runs before `state.run = run` (test seams only; both cycle-22 verifiers). The proposed fix moves the reservation after `state.run = run` and before `spawn`, and adds an observer-side `invariantViolations()` assertion to the start-turn test.
  - (2) `ManualTimeSource.advance(to:)` lands 1 ns short of a boundary in ~2.9 % of gaps (`Double` truncation in `MonotonicInstant.adding(seconds:)`). This is WP-H's file; WP-F's tests use exact moves meanwhile.
  - (3) `recordIntegrityFailure` has no presence guard (F-14's remaining window).
  - (4) A re-join that changes lane, or comes from user work, still goes to the back of the queue through `relane`.
  - (5) L4-V3-12, the shared-content late joiner's second download (with OI-15).
  - (6) WP-B's `gainReferenceInPlace` copies the blob table per publication in debug and TSan builds; whether release builds do is unchecked.

- **L4-R25 Documentation (docs level).** ADR-053 (Level 4 merge: WP-F sync engine) records L4-R1…R25. It also records the F-n decisions the rulings ratify: F-15/F-16/F-20 as approved; F-30's new downloading → queued triggers; F-40/F-41/F-42's gate design (one pure origin-gate evaluation at `now`, re-admission on probe exits without a verdict, the run holding the half-open probe from its start turn).
  - ARCHITECTURE amendments as listed in `f.md`'s "Orchestrator, at merge" paragraph, including the §7.1 and §7.6 rows and §7.10's "only for a `.complete` run with a fresh manifest".
  - The REENTRANCY rows f-1…f-n into §10.2 with their numbers kept.
  - §1.2: WP-F's new files, including `Tests/ZTronAssetSyncTests/Engine/FakePackBackend.swift` (L4-R1) and `EngineOriginGate.swift`.
  - §1.1/§1.2: the authorised edits outside WP-F (L4-R5/L4-R16: `StoreIntegrity.swift`'s guard and the retargeted R-CLN-4 case).
  - §11: credit the R-APL-3 end-to-end test to F.
  - The Stage 3 backlog (L4-R22, L4-R24) into ADR-053's Assignments.
  - Not verified: OI-2 (FakeFileSystem barrier = full sync), device-only behaviour (background URLSession relaunch, real packs, NWPathMonitor, thermal and Low Power Mode), and P-11's speedup as a lower bound.
  - No new NEEDS-HUMAN-REVIEW item arises from Level 4: L4-R1 adds a test-only internal dependency, not a third-party one.

- **L4-R26 (docs merge, 2026-10-17): ADR-053's "Acknowledged at merge" (1)–(4) are confirmed.**
  - (1) L4-R5's "never creates a job" holds as "never downloads": after a dropped ledger, one store read per id may precede the first attempt, and nothing is downloaded.
  - (2) Relocations do not feed the ledger, because the store relocates absent records too.
  - (3) An ENOSPC with pending reclaim waits `awaitingSpace` and counts against the retry budget, without a timed backoff. L4-R4's essential condition, a bounded number of attempts ending in a typed failure, holds. F-27(c) is not taken; Stage 3 may revisit it if a device test shows churn.
  - (4) L4-R14 extends to the other pins written after their fixes, each killed by a named mutant.

  Docs workflow `wf_922413b4-a66`: 2 rounds; round 2 verified 0 blocking issues. The orchestrator applied the verifier's last 5 notes (wording, two `///` comments).
