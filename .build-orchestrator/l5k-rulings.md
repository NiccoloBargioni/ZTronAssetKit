# Level 5 WP-K orchestrator rulings (R-CAR-6 compatibility shims): input for the close-out and for ADR-055

This file is the source of truth for the close-out fixers and verifiers, and later for the docs agents. `docs/adr-drafts/k.md` (K-1…K-15, the k-n REENTRANCY rows, CCR-K1) holds the detail; this file holds what the orchestrator decided. These rulings win over any draft. Findings cited as `L5K-V3-nn` are the issues in `.build-orchestrator/l5k-remaining-k.json`: verification round 3 of the main run, not yet fixed. The WP-G rulings (`l5-rulings.md`, especially L5-R14 and L5-R18) apply where they are general.

## Runs
- **Owner (2026-10-23): "continue"**, taken as the go-ahead for WP-K.
  - Strict bar and the session model, as for WP-G.
  - The owner gave no stop, so the orchestrator applied its suggested default of **45 % for all of WP-K**: 40 for the main run and the close-out, 45 for docs. The owner may change it.
- **Main run `wf_5feaaf72-e33`** (11:42–16:44): the author, then three verification rounds and two fix rounds.
  - Blocking went 3 → 2 → 2, out of 18, 10 and 11 issues in total.
  - Weekly usage went 18 % → about 25 %.
  - The author's `--quick` gave `VERIFY: PASS` (Compatibility 54 tests, later 69). Shims coverage was 97.59 % in the compatibility bundle, and the simulator ran 1,246/1,246.
- **The two blocking items in round 3:**
  - L5K-V3-05: CCR-K1 needs a ruling.
  - L5K-V3-04: the CCR-K1 tripwire test races the end of migration under TSan.

## Rulings

- **L5K-R1 / CCR-K1: no download of a prior-art file that legacy migration can still adopt (L5K-V3-05 blocking, L5K-V3-00). Approved as an authorised edit outside WP-K (WP-F), widened to the class.**
  - **Defect.** On a launch with legacy migration pending, an explicit sync (`performSync` → `startRun(.explicit)`, `EngineRuns.swift:10-39`) starts bulk jobs that download prior-art files phase 2 has not adopted yet. R-STO-11, a MUST, wants those files moved, not downloaded. Only `resolve` tries `store.adoptLegacyNow` (`EngineCommands.swift:56`). Prefetch joins and `ensureAvailable` jobs during migration take the same path as the explicit sync.
  - **Invariant.** While legacy migration is pending or running, **no transfer starts for an asset whose prior-art file can still be adopted**, whatever created the job:
    - an explicit, due or launch run;
    - `ensureAvailable`;
    - a prefetch join;
    - a reroute or `followApplied`;
    - a resolve.

    Before any bytes, the engine adopts the file instead, and the job is answered from the store as for a present asset (L4-R5).
  - **Design (recommended: option (b) in the one funnel).** Every attempt already passes the pre-transfer store read, `answeredFromStore` (`EnginePresence.swift:177`, f-11), before any bytes. While `state.migration` is pending or running, that read asks `store.adoptLegacyNow(id)` instead of `store.location(for:)`.
    - `adoptLegacyNow` returns the current location when the asset is present, otherwise adopts its legacy file now, and returns `nil` when there is nothing to adopt or the file did not verify.
    - With no migration pending, the read stays `location(for:)`, so there is no extra cost.
    - Option (a), joining the migration's launch run, covers only the explicit sync and is not sufficient alone.
    - Check how the store already serialises an on-demand adoption against the migration loop's adoption of the same file (the resolve path coexists with it), and state it in a REENTRANCY row.
  - **Enumerate the class.** List in k.md every path that starts a transfer: the run kinds, `ensureAvailable`, prefetch joins, reroute/`followApplied`, resolve, and the parked launch run.
    - For each, show that it passes the funnel during migration.
    - Settle the parked launch run (`EngineRuns.swift:1055-1058`): when migration ends while another run is active, `startRun(.launch)` is a no-op. Decide whether that run satisfies the launch's sync or the launch run starts after it. Pin the choice with a test; no flag or waiter may be left behind.
  - **C2.** One `adoptLegacyNow` per id of a job during migration only, done on the store's executors, never on main. The store's install-rate limiter coalesces snapshot installs (`StoreInternals.swift:76`). Measure a 150-file and a 1,000-file adoption-by-sync in release and record the longest engine turn.
  - **Tests, failing first.** Engine tests in a **new** file `Tests/ZTronAssetSyncTests/Engine/EngineLegacyMigrationTransferTests.swift`, deterministic (hold migration with the existing gates or stepped executors):
    - an explicit sync during migration downloads none of the pending files;
    - so does a prefetch join during migration;
    - so does `ensureAvailable` during migration;
    - the parked launch run behaves as decided;
    - a later launch that resumes an interrupted migration behaves the same (L5K-V3-06).
  - **WP-K's part.**
    - Replace the tripwire's `withKnownIssue(isIntermittent: true)` with strict expectations: `downloaded == 0`, and every prior-art file gone once the sync returns (with the fix, nothing is downloaded, so every legacy file is adopted).
    - Add a resumed-migration shim test in ProbeResumedMigration's shape (L5K-V3-06): launch 1 starts migration and is shut down mid-way; launch 2's `syncIfNeeded()` right after `start()` downloads nothing.
    - Then rewrite MIGRATION.md step 4 and §4 and K-15/K-7: the launch-task sync is safe; only the lookups' migration window remains (L5K-R4).
  - **Authorised files:** `Sources/ZTronAssetSync/Engine/EnginePresence.swift`, `EngineRuns.swift`, `EngineState.swift`, `EngineLifecycle.swift` (internal state and bodies only, no public or package signature change), plus the new engine test file.
  - **Runs:** `ZTronAssetSyncTests` ×3 + TSan, `ZTronAssetStorageTests` once (no store change is expected), Kit ×3 (the facade must not regress), and the compatibility target ×3 + TSan.
  - **Records:** every edit in k.md under "Authorised edits outside WP-K (close-out)".

- **L5K-R2: the compatibility tests' timing dependence, as a class (L5K-V3-04 blocking).**
  - **The instance.** `launchSyncDuringLegacyMigration`'s `legacyLeft == 0` races the end of migration: it failed 5 of 6 runs under TSan, with no ThreadSanitizer report. After L5K-R1 its post-condition becomes deterministic. Write it as the verifier proposed:
    - assert strictly on the assets not downloaded;
    - never use `.syncStarted(_, .launch)` as an "end of migration" signal (`startRun` is a no-op while a run is active).
  - **Class.** Apply L5-R14's enumeration to **every** test in `Tests/ZTronAssetCompatibilityTests` and the shim harness, with patterns (a)–(g) of L5-R14. Also cover the interplay with K-10's auto-advancing clock: a test whose outcome depends on whether the engine processed a step before the clock auto-advanced must wait on a publicly observable condition instead (events, `availability`, `lookup`, the coordinator's published state).
  - Record the table in k.md.
  - **Stress evidence**, with load averages: the compatibility target ×20 while the host is loaded (1-minute load ≥ 8), ×5 under TSan, and on the simulator.

- **L5K-R3: K-10, the shim test harness's auto-advancing clock. Accepted, with conditions.**
  - `AutoAdvancingClock` wraps `ManualTimeSource`. It never reads the wall clock and never sleeps for real (C4). It advances only to the earliest registered sleeper's deadline within its 1 s bound.
  - The fenced driver of `KitHarness` needs `@testable` engine state, which this public-API-only target must not import (K-1: the shims must stay copyable into ZTronCarouselCore).
  - **Conditions:**
    - every assertion waits on an explicit, publicly observable condition, never on an advance having happened (L5K-R2);
    - `manifestFetchDeadline = 1e6` is a harness setting that no test of a deadline relies on, stated in K-10;
    - any flake under load or TSan blocks and goes through L5K-R2's class rule.

- **L5K-R4: migration-window docs (L5K-V3-01, L5K-V3-06).**
  - Rescope every passage to "a launch on which legacy migration is still adopting the prior art's files: the first one after adoption, and any later launch that resumes an interrupted migration". That covers MIGRATION.md step 3, step 4 and §4; K-7, K-11, K-15 and the CCR-K1 header; and the shim doc comments the verifier listed.
  - "Harmless on later launches" goes.
  - After L5K-R1 the sync part of the window is closed. What remains is K-15's lookup miss, which the shims cannot close without main-thread I/O (C2).

- **L5K-R5: existingLocalURL's lifetime (L5K-V3-07): document it.**
  - Add the ADR-017 consumer contract to MIGRATION §4, K-11 and `existingLocalURL`'s doc comment:
    - the URL names stored content;
    - after a content change, a prune or an eviction, the old file is removed `StoragePolicy.deletionGrace` after the new snapshot;
    - a consumer that re-reads the path later (BasicVideoPage's player) looks it up again on failure, or holds a lease (`AssetClient.withAsset`).

- **L5K-R6: NetworkAvailabilityMonitor's retry trigger (L5K-V3-08): document it, no behaviour change.**
  - Retries run on every satisfied conditions report: path changes, and also Low Power Mode and thermal reports. The prior art retried on path updates only.
  - Filtering on a changed `network` value would lose some path updates the prior art retried on, for example Wi-Fi to another Wi-Fi.
  - So state the behaviour in K-8, the MIGRATION §2 row and the monitor's doc comment.

- **L5K-R7: K-8 (the monitor watches `AssetEnvironment.conditions`, not a client's events). Approved as decided.**
  - An idle client observes nothing (R-SYN-14), and failing test `c623b34` proved that the event-driven version misses the prior art's retry moment.
  - `shared` builds its own live conditions source (ADR-038: fresh conformers per call). That means a second path monitor in the process, which is acceptable for a shim; say so in K-8.
  - The public API is unchanged, so this is not NEEDS-HUMAN-REVIEW.

- **L5K-R8: the NEEDS-HUMAN-REVIEW shim decisions. Approved as the safest defaults (CLAUDE.md: choose, record, continue).**
  - The decisions:
    - **K-2:** a write-once install point; `installed = nil` and re-installation are ignored.
    - **K-3:** `@MainActor` lookups; the prior-art call sites compile, pinned by `PriorArtCallSiteTests`.
    - **K-5:** the providers describe a client tier and no longer download (`CDNShimError.downloadsGoThroughTheClient`). The app key follows option (a): documentation and a manifest source that sends the key. Option (b), a key-taking initialiser that would copy the secret outside `AppKey`'s redaction, is declined.
    - **K-6:** the deprecated initialisers share one client per install point; `CDNLocalStore(baseDirectory: X)` roots the store at X's parent `/ZTronAssetKit/v1` (storage location); one store per parent directory, with the shared-registry alternative declined as global mutable state.
    - **K-15:** the lookup miss during a migration window, rescoped by L5K-R4.
  - Each keeps its tag in ADR-055 and goes into DECISIONS.md's owner review list.

- **L5K-R9: K-7, K-11, K-13 and the partial pin.**
  - **K-7:** `CDNSyncProgress(outcome:)` maps a `.complete` run with `manifestFresh == false` to `.complete`. This is accepted: no stamp is written, and the next launch retries as the prior art did.
  - **K-11:** the behaviour differences inherited from the module (ADR-032/L4-R16, ADR-037) are accepted, and documented and pinned as they are.
  - **K-13:** a public read of the applied manifest is not added in Level 5. It would be a public API addition to `ZTronAssetKit` (NEEDS-HUMAN-REVIEW) that no requirement needs. Record it as an owner option.
  - **The partial pin:** the coordinator's `.complete` on an app-version change is not orderable through public API. This is accepted as recorded (K-7, MIGRATION §3).

- **L5K-R10: ownership.** `docs/MIGRATION.md` is WP-K's file, authorised by the launch notes (L5K-V3-02, L5K-V3-09). The docs level adds a "Files WP-K added" paragraph to ARCHITECTURE §1.2. The requirements verifier's ownership check accepts:
  - WP-K's §1.2 files and `docs/MIGRATION.md`;
  - the files L5K-R1 authorises;
  - nothing else.

- **L5K-R11: benchmarks (L5K-V3-03, L5K-V3-10).** WP-K owns no benchmark, so **the fixer and the verifiers run no benchmark** (as L5-R18). The whole suite, including P-13 (owner item, ADR-050), is the orchestrator's near-idle run after the merge.

- **L5K-R12: coverage for a test-only package.** The gate's per-target figures must not drop: Sync ≥ 90 %, Storage ≥ 90 %, and Kit ≥ 70 % (currently 97.6 %). WP-K's own measure is llvm-cov over `Shims/*.swift` in the compatibility bundle, ≥ 70 % (currently 97.59 %). The uncovered lines listed by the author are accepted as listed.

## Process
- Two verifiers share the worktree. Take `--quick` verdicts from each agent's exit status.
- The orchestrator deletes `.build-verify-*` between cycles.
- When a defect class repeats over two cycles, the orchestrator stops the run right after the verification and adds a class ruling (L5 lesson).

## Close-out continuation (cycle 2 onward; 2026-10-23 19:20)
- **Cycle 1** (`wf_d5c59efd-6db`, 16:52–19:16, weekly 25 % → 28 %) fixed both original blockers. The verifiers reproduced the fixes against mutants M1/M2 and probes:
  - L5K-R1's funnel works for explicit syncs, bulk and default-priority jobs and resolves;
  - the tripwire is strict and passes under TSan;
  - the parked launch run follows option (a).
- **Its verification:** the requirements lens **0 blocking**; the correctness lens **1 blocking**, L5K-C1-00, a second shape of the CCR-K1 class. Findings are in `.build-orchestrator/l5k-close1-remaining-k.json` (`L5K-C1-nn`). Probes are kept in `.build-orchestrator/l5k-probes-c1/` (`VerifierKC1StoreProbe.swift`, and the verifier's `legacyphases-prototype.diff`).
- The cycle-2 fixer was stopped before any change (HEAD `990752a`, clean). The close-out restarts at cycle 2 from `l5k-close1-remaining-k.json`.
- **Correction to L5K-R1.** Its line "the store's install-rate limiter coalesces snapshot installs" was wrong. `adoptLegacyNow` publishes at `.userInitiated`, which the limiter never coalesces, as the fixer recorded. L5K-R14 below fixes the consequence.

- **L5K-R13: one adoption per prior-art file, whoever asks (L5K-C1-00, blocking). Approved as an authorised edit outside WP-K (the store's legacy-migration files).**
  - **Defect.** `performAdoptLegacyNow` processes a file that a migration batch has already claimed (`queued == nil`, `LegacyPhases.swift:510-520`), concurrently with that batch. When the batch's placement has renamed the file into `blobs/` but has not bound the record yet:
    - the on-demand hash fails `.notFound`;
    - `legacyFailureOutcome` (`:250-255`) answers `.dropped`, because `legacyAdopted` is still false;
    - `adoptLegacyNow` returns `nil`, and the user-initiated job downloads the file that the batch adopts moments later.

    Proven deterministically (store probe PS1/PS1b) and through the public API (`ensureAvailable` and a user-initiated prefetch right after `start()`, 8–13 of 20 launches). This breaks R-STO-11 and L5K-R1's invariant.
  - **Invariant.** At most one adoption runs per prior-art file at a time, among a batch, an on-demand call or two on-demand calls. Every concurrent asker gets the outcome of that one adoption: the adopted location, or `nil` only when the file was really dropped or kept. A failure caused only by the other adopter (the file moved away, the key in `publishing`) is never reported as `.dropped`, `.deferred` or `nil`.
  - **Design (recommended: single flight per file).** Mark a file in progress when a batch or an on-demand call starts processing it. An asker that finds it in progress waits for that processing to end and then reads the record. This avoids a second hash, which matters for C2 and the battery.
    - A file a batch has claimed but not yet started stays adoptable on demand at once, as today, so a user's lookup never waits behind a whole batch. The batch then sees it adopted (`alreadyAdopted`, uncounted).
    - The verifier's prototype is acceptable only if the fixer shows the invariant holds for every interleaving in the enumeration below. The prototype has `legacyFailureOutcome` wait out an in-flight placement of the same bytes, then re-check `legacyAdopted`.
  - **Enumerate the class.**
    - States of a prior-art file: queued; claimed and not started; hashing; placing (key in `publishing`); binding; adopted; deferred; dropped or kept.
    - Pairs of concurrent processors: batch with on-demand, on-demand with batch, on-demand with on-demand.
    - For each pair and state, record in k.md the outcome each side reports and why. Exactly one adoption counts, and no side reports `.dropped` for an adopted file.
    - A shutdown or close while an asker waits resumes it with the store's shutdown answer: `close()` resumes every waiter, with a REENTRANCY row.
  - **Tests, failing first.** In a **new** store test file `Tests/ZTronAssetStorageTests/Cleanup/LegacyOnDemandRaceTests.swift`:
    - PS1b's shape (hold the batch's placement unit, fault the on-demand read with `.notFound`; the call answers the location);
    - the reverse order (the on-demand call places, the batch's hash fails; the batch reports `alreadyAdopted` and does not count it dropped);
    - two on-demand calls;
    - a close while waiting.

    In the engine's `EngineLegacyMigrationTransferTests.swift`: `ensureAvailable` and a user-initiated prefetch join over a migration that is **not** held, repeated (or seeded) so that the PK2b race is reached, with zero transfers.
  - **Authorised files** (bodies, internal state; the `MigrationState` fields; REENTRANCY rows):
    - `Sources/ZTronAssetStorage/Migration/LegacyPhases.swift`;
    - `Sources/ZTronAssetStorage/Migration/MigrationState.swift`;
    - `Sources/ZTronAssetStorage/Migration/StoreMigration.swift`, for L5K-R14's parameter only.
  - **Runs:** `ZTronAssetStorageTests` ×3 + TSan, Sync ×3 + TSan, Kit ×3, and the compatibility target ×3 + TSan.
  - **Records:** correct the k-4 REENTRANCY row, k.md:617-621, MIGRATION.md:69-74 and the matching shim doc comments.

- **L5K-R14: bulk-lane adoptions keep the store's install-rate bound (L5K-C1-02). Approved as a package API change.**
  - `AssetStore.adoptLegacyNow(_:urgency:)` gains `urgency: AssetPriority = .userInitiated`. The default keeps every existing caller's behaviour.
  - `performAdoptLegacyNow` publishes at the given urgency.
  - The engine's funnel passes `.userInitiated` for a job whose lane is user-initiated, and `.bulk` otherwise. Bulk-lane adoptions are then coalesced by the install-rate limiter, so ARCHITECTURE §5's bound ("at most 10 snapshot builds … per second") holds during migration too. A user-initiated adoption still installs at once.
  - **Tests:** a store or engine test that a bulk sync adopting 100 files under `ManualTimeSource` installs no more snapshots than the limiter allows, and that a user-initiated adoption installs at once.
  - **Authorised:** `StoreMigration.swift` (the package signature, defaulted) and `EnginePresence.swift` (the funnel's argument). Not NEEDS-HUMAN-REVIEW: package API, not public.

- **L5K-R15: clearly right non-blocking items from cycle 1 (fix).**
  - **L5K-C1-03 / L5K-C1-01.** Hold migration across the coordinator's call in `launchSyncDuringLegacyMigration` and in `launchSyncDuringResumedMigration`'s launch 2, as the requirements verifier lists:
    - use `SteppedBlockingExecutor(holding: true)` with `startHoldingMigration` and a releaser;
    - prove the overlap with `heldUnits ⊇ migration`;
    - keep every strict assertion;
    - update the two L5K-R2 rows.
  - **L5K-C1-04.** End k.md's CCR-K1 header bullet with a status line: ruled L5K-R1 and L5K-R13, fixed in the close-out, the test strict, the window rescoped (L5K-R4).
  - **L5K-C1-05.** Pin the migration loop's flag clear at shutdown (in the resumed-migration test's launch 1, after the stop: `launchRunWaiting == false`).

## Close-out continuation (cycle 3 onward; 2026-10-23 21:30)
- **Cycle 2** (`wf_d80dd07d-5cd`, 19:22–21:22, weekly 28 % → 30 %) fixed L5K-C1-00. L5K-R13's single flight held in every interleaving both verifiers worked through, and the public-API probes saw 0 downloads in 50–100 launches each.
- **Its verification:** **2 distinct blocking defects** (both lenses; findings `.build-orchestrator/l5k-close2-remaining-k.json`, `L5K-C2-nn`):
  - **(A)** Coalesced (`.bulk`) publications whose trailing install the engine never schedules. Two shapes:
    - L5K-C2-00/02: the funnel's bulk-lane adoptions, which L5K-R14 introduced. My ruling caused this.
    - L5K-C2-03: migration's own batch publications once a run has taken the parked launch run's place, which L5K-R1's option (a) made reachable.

    In both, the store holds the assets but `lookup`, `existingLocalURL` and `hasAsset` miss them until an unrelated install.
  - **(B)** L5K-C2-01: the migration loop busy-spins, about 280,000 `migrateLegacy` calls a second, while an adopt-on-demand holds the last claimed file. The root predates Level 5; L5K-R1 made it the normal end of every sync during migration.
- The cycle-3 fixer was stopped before any change (HEAD `1901e91`, clean). The close-out restarts at cycle 3 from `l5k-close2-remaining-k.json`.

- **L5K-R16: every coalesced publication gets its trailing install scheduled, as a class (L5K-C2-00, -02, -03; blocking).**
  - **Invariant.** At the end of every engine turn in which the store may have marked an install due, the engine's heap holds a store deadline no later than the store's `nextDeadline()`. No adopted, committed or published asset can stay out of the readers' snapshot for longer than one install interval after its publication, unless a commit is still pending.
  - **Enumerate the class.** List in k.md **every** engine call of a store method that can publish, directly or indirectly, at a coalesced urgency:
    - at least the funnel's `adoptLegacyNow` (`EnginePresence`);
    - `migrateLegacy` (`migrateLoop`);
    - the commit path, which already calls `refreshStoreDeadlineAfterPublish`, RE-S40;
    - apply, purge, reclaim and maintenance, and every other store call the engine makes.

    For each, state how the deadline is re-read afterwards: the RE-S40 helper, the alarm turn's `runDueWork()` report, or a run's own re-read. Add the RE-S40 re-arm where nothing does. Keep its O(1) shortcut, so a bulk sync never reads `nextDeadline()` once per asset (F-12).
  - **Tripwire (cheap).** Add one engine invariant to the test-only check (`invariantViolations()`): at idle, `store.installDue` implies a store entry on the heap. Assert it at idle in the new tests, the existing engine model and the migration tests.
  - **Tests, failing first.**
    - The engine shapes PR14a, PR14b, PR14c and probe I/J: `installInterval 0.1`, the clock driven past the window, then every adopted id is in `harness.sink.installed`, and the installs still stay within the limiter.
    - **One compatibility test with the production install interval** (`snapshotInstallInterval 0.1`, PK-R14b's shape): `existingLocalURL` and `lookup` see every stored neighbour after the window. The harness's interval of 0 hid this class.
  - **Authorised:**
    - `EnginePresence.swift` and `EngineRuns.swift`, as before.
    - `EngineTimers.swift`, for the re-arm helper only.
    - Re-arm call additions with their REENTRANCY comments in any other engine file the enumeration finds. List each in k.md.
  - Correct MIGRATION.md §4 (:192-196), k.md's L5K-R14 section (:798-801), the f-11 amendment and the k-4 row.

- **L5K-R17: no hot loop around a store call (L5K-C2-01; blocking; SPEC goal 4 "no polling").**
  - **Fix as the correctness verifier proposed.** In `performMigrateLegacy` (`LegacyPhases.swift`, authorised by L5K-R13), when the queue is empty and every claimed file is held by an on-demand adoption:
    - await that adoption's flight;
    - re-read the queue, the claims and the phase (a REENTRANCY row);
    - fall through to the finish check, so the same call finishes the migration.

    The wait is bounded by one adoption, and `close()` and shutdown resume it (row k-5).
  - **Enumerate the class.** List in k.md every engine loop that repeats a store call until a condition holds: `migrateLoop`, catch-up, release follow-ups, reclaim loops, and any other. Show that each iteration either makes progress or suspends on a real event. No iteration returns at once without progress.
  - **Tests, failing first:** a store test in PS3's shape (`migrateLegacy` returns only after the on-demand adoption, with `finished == true`), and an engine test with a call-count seam that bounds the loop's calls while a job's hash unit is held.

- **L5K-R18: a job promoted during its adoption (L5K-C2-05): fix.** After the funnel's `adoptLegacyNow` await, re-read the job's lane. When it became `.userInitiated`, ask the store once more at `.userInitiated`, so a user-initiated asker never returns before the readers' snapshot holds the asset (ARCHITECTURE §5: a user-initiated publication installs at once). Add a test if a seam reaches it; otherwise record the reasoning in k.md.

- **L5K-R19: non-blocking items from cycle 2 (fix).**
  - **L5K-C2-04.** Make the `joins > 0` premise of `ensureAvailableBesideARunningMigration` and `userInitiatedPrefetchBesideARunningMigration` deterministic with a held-migration variant that provably reaches the join, keeping the per-launch zero-transfer assertions. If a stochastic variant stays, record its premise in the L5K-R2 table as pattern (a), with the measured margin.
  - **L5K-C2-06.** Correct k.md:7 and :30. Under L5K-R14, one package signature in WP-C's contract file changed: `adoptLegacyNow(_:urgency:)`, defaulted.
  - **L5K-C2-07.** State in k.md that the four defensive branches of `awaitLegacyAdoption`/`awaitLegacyFlight`/`endLegacyAdoption`/`endLegacyOnDemand` are unreachable by construction and deliberately untested, for ARCHITECTURE §14.

- **Process note.** This is WP-K's third shape of the CCR-K1 family: the download, then the store race, then the install scheduling. L5K-R16 and L5K-R17 are written as class rulings. The verifiers check the two enumerations for completeness and the invariant tripwire, and try to break both by probe.

## Close-out continuation (cycle 4 onward; 2026-10-24 00:55)
- **Cycle 3** (`wf_cfb1c56d-e3f`, 21:31–00:43, weekly 30 % → 34 %) fixed every cycle-2 blocker. The verifiers re-ran the cycle-2 probes and killed mutants M16a–d, M18a/b, M19 and M17 (the store test).
- **3 blocking items in two classes** that have now repeated across cycles (findings `.build-orchestrator/l5k-close3-remaining-k.json`, `L5K-C3-nn`; probes kept in `.build-orchestrator/l5k-probes-c3/`):
  - **Trailing install vs a long store call.** L5K-C3-01: L5K-R17's wait runs inside the same `migrateLegacy` call that has just published at `.bulk`, so the engine's re-arm cannot run until the call returns (probe KC3-WAITWINDOW). By reading, the same applies to the last batch's publication followed by phases 3–4 in one call.
  - **A user-initiated asker answered before the readers' snapshot holds the asset.** L5K-C3-00: a promotion during the funnel's RE-S40 re-read (probe PE5, 9 of 9).
  - **A test premise.** L5K-C3-02: the L5K-R17 engine test checks nothing in whole-file runs.
- The cycle-4 fixer was stopped before any change (HEAD `9c53e06`, clean). The close-out restarts at cycle 4 from `l5k-close3-remaining-k.json`.

- **L5K-R20: a store call never suspends after a coalesced publication, as a class (L5K-C3-01; blocking).**
  - **Rule.** A store method the engine calls that publishes at a coalesced urgency **returns right after that publication**. It suspends afterwards on nothing but its own bounded blocking units, never on another flight, a wait or a later phase.
  - **For `performMigrateLegacy`, option (b) of L5K-C3-01:**
    - a call that published returns at once (`remaining > 0`, `finished == false`), and the engine's loop re-arms (RE-S40) and calls again;
    - a call that published nothing may wait for an on-demand flight (L5K-R17), or run phases 3–4 and finish;
    - if finishing publishes too, it returns right after.

    This keeps L5K-R17's "no hot loop" (the next call waits rather than returning empty) and costs at most one extra call per batch.
  - **Enumerate the class.** Add a column "suspends after publishing?" to the L5K-R16 table for every publishing store call: `migrateLegacy`, `adoptLegacyNow` (its flight wait must precede its publication), apply, commit, purge, reclaim and the rest. Fix any "yes".
  - **Tests, failing first:**
    - KC3-WAITWINDOW's shape as an engine test: the job's hash held, the batch at its wait, the clock past the window, every batch-adopted id in `harness.sink.installed`;
    - the phases 3–4 case: hold a phase-3 or phase-4 unit after the last batch's publication, and the readers see every adopted id within the bound.

- **L5K-R21: user-initiated answers come after the install, enforced at the answer site, as a class (L5K-C3-00; blocking).**
  - **Rule.** Wherever the engine answers a user-initiated asker (a waiter, an `.ensure` group or a user-initiated join) with a location the store gave it, **the last step before the answer is a check of the job's interests made after the last ordinary await**.
    - When that check finds a user-initiated interest and any answered id came from a publication still coalesced (a bulk-urgency adoption or a pending trailing install), exactly one user-initiated publication follows. For example, `adoptLegacyNow(id, urgency: .userInitiated)` for the last adopted id, which installs at once.
    - Nothing else is awaited between that publication and the synchronous answer.
    - A promotion after the check cannot interleave, because no suspension follows. A promotion before it is seen by it.
  - **Apply it in `answeredFromStore`, after the reads loop**, with the RE-S40 re-arm moved before the check. That covers a promotion during any id's read, during the re-arm, or when migration ends mid-loop.
  - **Enumerate** in k.md every other site that answers user-initiated askers from the store (joins answered from the ledger, `ensureAvailable`'s present members, the resolve path) and state why each meets the rule.
  - **Tests, failing first:** PE5's shape (the gated planner plus `holdNextStoreDeadlineRead()`; when `ensureAvailable` returns, `harness.sink.installed` holds the asset), and a promotion during a later id's read in a multi-id job.

- **L5K-R22: other items from cycle 3.**
  - **L5K-C3-02 / L5K-C3-03 (blocking test strength).** Make `migrationLoopWaitsForTheLastAdoption` establish and assert its premise:
    - three files, with the job taking the last pending one;
    - `#require` that the pending count is right after the start;
    - wait, ending on cancellation, until the store logs that the batch waits, or until the call count rises by 2;
    - count calls over a loop that releases every non-job unit for N yields, as PSPIN-c3 does.

    Show that it fails against M17 in whole-file and full-suite runs, and record the premise in the L5K-R2 table.
  - **L5K-C3-08.** Add the two liveness cases: `close()` and `shutdown()` while a batch waits in k-7 (probes in `l5k-probes-c3/`).
  - **L5K-C3-04 / -07 / -05 / -06 / -09 (records).**
    - Correct the L5K-R16 table's "pinned by" cells: PR14b and PK-R14b pin the funnel. Optionally make PR14a drive the clock before migration finishes.
    - Add the `availability(of:)` row.
    - Record the point-admission re-arm as defensive, or pin it.
    - Qualify the bound as "within about two install intervals (RE-S40's shortcut, F-12)" in the invariant, MIGRATION.md §4 and `EnginePresence`'s doc.
    - Add the parked-run sentence: since L5K-R16 the migration loop's re-arm installs migration's later adoptions.
  - **L5K-C3-10 (ownership): ratified.** These edits serve L5K-R16, R18 and R21, change no signature and are listed in k.md:
    - `EngineTimers.swift`'s `fireDue`/`applyStoreDeadline` change and its test seam;
    - `EngineCommands.swift`'s lease release restructured into a private `releaseLease`;
    - `LegacyPhases.swift`'s L5K-R18 present path;
    - `EngineLifecycle.swift`'s `reconcileLaunch` returning `Bool`, and the shutdown seam release.
  - **L5K-C3-11.** Retire PS3 in favour of `batchWaitsForTheLastOnDemandAdoption`, and run PSPIN filtered to itself.

- **Usage note.** Weekly usage is 34 % at this relaunch; the close-out stop is 40 %. If the stop comes first, the orchestrator stops, re-forecasts and asks the owner for a new stop.

## Owner stop (2026-10-24 01:25)
- **Owner: "move usage target to 65%".** The weekly-usage stop for all of WP-K is now **65 %**: **60 %** for the close-out and **65 %** for docs, leaving room for the merge and docs (memory rule).
- The running close-out `wf_da30f4d9-921` has 40 baked into its arguments. The orchestrator relaunches it with `usageStop: 60` at the next clean boundary, never killing a fixer mid-change:
  - right after cycle 4's verification, with `fromCycle: 5` and `findingsFile` = cycle 4's issues; or
  - if the old gate halts the run first, from the cycle it stopped at, with `verifyFirst: true` when fix 4 had already finished.

## Close-out continuation (cycle 5 onward; 2026-10-24 03:35; owner stop 65 %, so the close-out gate is 60)
- **Cycle 4** (`wf_da30f4d9-921`, 00:58–03:2x, weekly 34 % → 44 %; its verifiers alone cost about 7 points) applied L5K-R20–R22. The run then stopped at the old 40 % gate before fix 5, a clean boundary. Findings are in `.build-orchestrator/l5k-close4-remaining-k.json` (`L5K-C4-nn`); probes are in `.build-orchestrator/l5k-probes-c4/`.
- **Four distinct blocking defects.** The verifiers validated a fix for the first three in scratch copies:
  - **(1) L5K-C4-00/04: a stale read across an await.** L5K-R20's early return uses `last`, read before the publication's await, so a batch can return RE-S29's back-off signal (`remaining == 0`, `!finished`) with everything adopted, and the engine defers a finished migration. Validated fix: FIXLAST.
  - **(2) L5K-C4-01/05: the per-read re-arm was lost.** L5K-R21's restructuring moved the RE-S40 re-arm after all of a job's reads, so a multi-id job's earlier bulk adoption has no deadline while later reads hash. Validated fix: PERREAD.
  - **(3) L5K-C4-02: a late joiner is never asked.** An id of the same content that joins during the pre-transfer reads is never read, so its content is downloaded. This has been present since L5K-R1. Validated fix: re-read until no new id is left.
  - **(4) L5K-C4-03 (with L5K-C4-10): L5K-R21's class at sites WP-K did not change.** The commit path, `ensureAvailable`'s present members, the resolve fast hit and ledger joins answer user-initiated askers while the asset may still be only in a coalesced snapshot. This is pre-existing behaviour (ADR-016). See L5K-R24.

- **L5K-R23: the three validated fixes (blocking).** Failing test first for each, then the fix in the authorised files:
  - **(1)** In `performMigrateLegacy`, after the publication's await, re-read the queue and the claims. When an install is due, return the progress if work is left; otherwise install at once (`.userInitiated`) before the wait or the finish check. Name the queue and the claims in the REENTRANCY row. Tests: KC4-STALELAST's store shape and its engine shape (the loop ends with `pending == false`).
  - **(2)** In `answeredFromStore`, re-arm (RE-S40, keeping its O(1) shortcut) after **each** bulk-urgency read inside the loop. The final check after the loop stays, so the last read's re-arm is the last ordinary await before it (L5K-R21 holds). Test: KC4-MULTIID.
  - **(3)** In `answeredFromStore`, after the loop, read the ids the job gained during the reads whose applied entry maps to this transfer, and repeat until no new id is left. Do this before the last re-arm and the final check. Tests: both variants of P1-LATEJOIN (a prefetch join and `ensureAvailable`); `starts` stays empty and both ids are present.
  - Update the L5K-R1, L5K-R16 and L5K-R17 tables and the records the correctness verifier lists (L5K-C4-06).

- **L5K-R24: L5K-R21 applies to the funnel, the code WP-K changed. The other answer sites keep ADR-016's documented lag (L5K-C4-03, L5K-C4-10; ruled non-blocking for Level 5).**
  - **My error.** L5K-R18/R21 stated an invariant stronger than the architecture: §5 makes a user-initiated *publication* install at once; it does not make every user-initiated *answer* wait for the readers' snapshot. ADR-016 lets the main-actor snapshot lag the actor's state by the install interval.
  - **Scope.** The funnel keeps the L5K-R21 guarantee, which WP-K's coalesced adoptions made necessary. The commit path, `ensureAvailable`'s present members (including during migration, P21-ENSURE-MIG), the resolve fast hit and ledger joins keep the pre-existing behaviour: such an answer can precede the readers' snapshot by at most about two install intervals (0.2 s by default, RE-S40's shortcut).
  - **Records.** MIGRATION.md §4 and ADR-055 state this for the owner. The Stage 3 backlog gets: an optional `AssetStore.installIfDue()` plus the answer-site check at those sites, if a device test shows the lag matters.
  - **Verifiers:** report such instances as non-blocking, labelled `pre-existing (L5K-R24)`. Do not pin them. P21-COMMIT and P21-ENSURE-MIG are recorded in k.md as the observed bound.

- **L5K-R25: clearly right non-blocking items from cycle 4 (fix).**
  - **L5K-C4-07.** The answer-site publication tries the next answered id when the first is no longer present (`adoptLegacyNow` answered `nil`), so the install never depends on one id surviving.
  - **L5K-C4-08 / L5K-C4-14: no request for a retired job.** After `answeredFromStore` returns `false`, `drive` returns before `remote.transfer` when the job is gone or its epoch or attempt is no longer current, and clears the draining record as the existing exit does.
    - **`EngineDispatch.swift` is authorised for this guard only.**
    - Test: KC4-MULTIID's release variant, where the group is released during the second read's adoption; `starts` stays empty.
  - **L5K-C4-12.** The liveness tests wait on a cancellation-aware condition (`CorePoll.until`) before reading the calls' results, at both places.
  - **L5K-C4-11: dooms.** The removal-only install before `recordFailure`/`recordIntegrityFailure`'s ordered commit is accepted as the one exception to L5K-R20: it holds back no adopted or committed asset, and I-3 keeps the bytes until a snapshot without the asset is acknowledged. ADR-055 records it, and `IntegrityBookkeeping.swift` is not changed.
  - **L5K-C4-13 and L5K-C4-09: environment.** WP-B's time-limited crash tests and the loopback start/stop test exceeded their limits at loads of 441–834 created by parallel probe campaigns. They are non-blocking when they pass on a re-run at moderate load. Take every verdict from the exit status (shared `.verify-logs`).

- **L5K-R26: a verification budget (process; a cycle now costs 7–10 points).**
  - Each lens runs the required gates **once**: `--quick`, the release and iOS builds, coverage, the compatibility target ×3 plus TSan, the suites the changed files require, and the simulator.
  - It probes only to prove or disprove a specific suspected defect: at most 20 launches per probe, one heavy command at a time, no parallel stress beyond L5K-R2's required series.
  - Behaviour in code WP-K did not change is reported as non-blocking `pre-existing`, unless WP-K's changes made it reachable or worse. CCR-K1 was such a case and blocked.

## Close-out result and merge rulings (2026-10-24 05:50)
- Cycle 5 (`wf_02981dcc-c86`, 03:37–05:4x, weekly 44 % → 57 %) applied L5K-R23 to R26. **Its verification found 0 blocking issues in both lenses** at HEAD `2df51ab`. Part of the meter's rise is the owner's own Fable use (the Fable meter 12 % → 32 %).
  - The requirements lens put each fixed defect back as a mutant: STALE, LASTBULK, PERREAD, LATEJOIN, LATEJOIN2, GUARD, NOANSWER and CHECKFIRST. The new tests fail on the defect assertions.
  - The correctness lens ran probes KC5-S1, E1–E6 and the L5K-R21 pins. They pass on HEAD and fail on the cycle-4 sources.
  - Gates: `--quick` PASS; release and iOS builds green; unsafe 0, docs 100 %, coverage PASS (shims 98.18 %); the compatibility target ×3 plus TSan; simulator 1,305/1,305.
  - The fixer's extension of L5K-R23(3), re-reading ids that join during the answer-site publication, is **ratified**.
- **Close-out total:** 5 cycles; blocking went 2 → 1 → 3 → 6 (4 distinct) → **0**; weekly 25 % → 57 %, including the owner's other use.

- **L5K-R27: the remaining non-blocking items need no new cycle** (the Stage 3 backlog in ADR-055, or the docs level):
  - **(1)** The liveness robustness of `waiterTakesOverACancelledProcessing` and the other tracked-call reads in `LegacyOnDemandRaceTests.swift`: wait on `CorePoll.until` before reading results, so a lost resume fails at the time limit. Stage 3.
  - **(2)** A pre-existing TSan flake in a WP-C test. Make it deterministic before Stage 5's `--full`, by either of the reqs verifier's options. Stage 3, and a note for Stage 5.
  - **(3)** The pre-existing L5K-R24 sites: ADR-016's lag of at most about two install intervals. MIGRATION.md §4 records it; Stage 3 holds the optional `installIfDue()`.
  - **(4)** The removal-only dooms install, the accepted exception to L5K-R20. ADR-055 records it.
  - **(5)** The L5K-R25 next-id fallback, defensive and unpinned. ADR-055 records it.

- **L5K-R28: documentation (docs level).** ADR-055 is "Stage 2 level 5 merge: WP-K compatibility shims". It records:
  - **Rulings and decisions:** L5K-R1…R28 and the ratified K-1…K-n (the draft's decisions).
  - **NEEDS-HUMAN-REVIEW items:**
    - K-2: a write-once install point;
    - K-3: `@MainActor` lookups;
    - K-5: the providers no longer download, with the key handled by option (a);
    - K-6: one client per install point, and `CDNLocalStore(baseDirectory:)` rooting at its parent's `ZTronAssetKit/v1` (storage location);
    - K-15: the lookups' migration window.

    Each is tagged in the ADR heading and added to the owner review list.
  - **Authorised edits outside WP-K**, recorded in ARCHITECTURE §1.1/§1.2:
    - WP-F's `EnginePresence`, `EngineRuns`, `EngineState`, `EngineLifecycle`, `EngineTimers`, `EngineCommands` (the lease restructure) and `EngineDispatch` (re-arm calls and the L5K-R25 guard), with the new engine tests;
    - WP-C's `LegacyPhases`, `MigrationState` and `StoreMigration`, including the **package signature** `adoptLegacyNow(_:urgency:)` (L5K-R14), with the new store tests;
    - WP-K's `docs/MIGRATION.md`, in a "Files WP-K added" paragraph.
  - **ARCHITECTURE amendments:**
    - §4: legacy migration: one adoption per file (L5K-R13), the batch's wait for an on-demand flight (L5K-R17), and the early return after a coalesced publication (L5K-R20/R23).
    - §5: the install-rate bound holds during migration (L5K-R14); trailing installs within about two install intervals (RE-S40's shortcut); the user-initiated answer rule for the funnel; the ADR-016 lag at the other sites (L5K-R24).
    - §7: the pre-transfer funnel adopts during migration (L5K-R1); the transfer-path, publishing-call and store-loop enumerations (L5K-R1/R16/R17); the parked launch run (option (a)); the idle tripwire.
    - §10: rows k-1…k-n into a §10.7 (the compatibility target, plus the engine and store rows WP-K added), numbers kept.
    - §11: R-CAR-6's credits.
    - §14: untested lines, including the defensive branches.
  - **Not verified:** k.md's list, Q-10's adoption inside ZTronCarouselCore, the live provider and monitor, the migration window's length on a device, and the shims at run time below the iOS 17 test-bundle target.

- **L5K-R29 (docs merge, 2026-10-24).** Docs workflow `wf_763379c2-80b`: the ledger plus two rounds; round 2 verified 0 blocking issues.
  - ADR-055's "Acknowledged corrections" (1)–(4) are the orchestrator's own corrections. They are confirmed as written:
    - L5K-R1's wrong limiter claim;
    - L5K-R24's scoping of L5K-R18/R21;
    - L5K-R16's implied authorisation of `EngineFailures.swift`, `EngineManifest.swift` and `EngineModelTests.swift`, ratified;
    - the two meanings of "option (a)".
  - The orchestrator applied the verifier's last 3 notes:
    - ADR-055 K-5's per-provider precision;
    - the complete shim public API in ADR-055 (5) and the ADR-033 amendment;
    - §5's paragraph and the ADR-022 amendment: the early return only after a publication that left a trailing install due, the O(1) shortcut only after a publication, and the cross-reference to RE-S40 and k.md.
