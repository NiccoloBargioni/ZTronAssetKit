"""Generate the Stage 3 rulings and findings files, one pair per close-out (orchestrator, 2026-10-29)."""
import json

ROOT = '/Users/admin/Documents/ZTronAssetKit/.build-orchestrator/'
hunt = json.load(open(ROOT + 's3-hunt-result.json'))
backlog = {b['id']: b for b in json.load(open(ROOT + 's3-backlog.json'))}
findings = {}
for lens, h in hunt['hunts'].items():
    verdicts = {v['id']: v for v in (hunt['confirm'].get(lens) or {}).get('verdicts', [])}
    for f in h['findings']:
        v = verdicts.get(f['id'])
        findings[f['id']] = dict(f, lens=lens, confirm=v)
mutants = {}
for g, r in hunt['mutate'].items():
    for p in r['probes']:
        mutants[p['id']] = dict(p, group=g)

GENERAL = """# Stage 3 orchestrator rulings — {name} (close-out `{wp}`)

Authoritative for this close-out (CLAUDE.md; PROMPT §4 Stage 3). The fixer records each ruling in `docs/adr-drafts/{wp}.md` as "Orchestrator ruling (Stage 3)". Verifiers read this file too.

## General rulings (identical in every Stage 3 close-out)
- **S3-R1 Scope and order.** Fix this work package's BLOCKING items first (failing test committed on its own, then the fix; CLAUDE.md P3), then every REQUIRED item, then OPTIONAL items if the cycle has room. An ADR-RECORD item gets an entry in `docs/adr-drafts/{wp}.md` (decision, evidence, reason) and no code. The findings file `{findings}` holds, by id, the hunters' full findings with the independent confirmer's verdict, the surviving mutants, and the backlog items. An item not listed below is out of scope.
- **S3-R2 Probes.** The hunters' and confirmers' probes under `.build-orchestrator/s3-probes/<lens>/` and `.build-orchestrator/s3-probes/confirm-<lens>/`, and the mutant diffs under `.build-orchestrator/s3-mutants/<group>/`, are evidence you may copy and adapt (all under `/Users/admin/Documents/ZTronAssetKit/.build-orchestrator/`, which is NOT inside your worktree; item texts below cite probes relative to its `s3-probes/` folder). A committed test follows SPEC 7.2: its display name starts with the requirement ID, `.timeLimit` on anything that awaits, `ManualTimeSource` only, no sleeps, and the iOS gating convention (ADR-051, `docs/adr-drafts/ios.md` item 2). Rename probe suites (`S3…Probe`) into the owning suites. Replays that encode a bug's old ordering are evidence only; do not commit them.
- **S3-R3 Mutation survivors.** For each surviving mutant assigned here, write the missing test, then re-apply the mutant's diff in a scratch copy and show the new test FAILS against it; paste that failing line into the draft. Verifiers re-check the same way.
- **S3-R4 Hang guards.** `.timeLimit` stays `.minutes(1)` by default (SPEC 7.2). A test whose measured duration under TSan on a moderately loaded host (load average at most about 30) exceeds half its limit may have its hang guard raised to `.minutes(3)`, or `.minutes(5)` for a model-based or exhaustive enumeration, following the precedents `EngineGateModelTests` and `stalledSubscriberIsBounded`; record each with the measured durations and load. Never cut a test's operations, seeds, crash points or assertions to make it faster (G3); making each step cheaper (incremental checks, less copying) is welcome. Long loops check `Task.isCancelled` so a timed-out test ends at once.
- **S3-R5 C2 at the reference scale.** A single actor turn over about 10 ms at 10,000 records is fixed by bounding the work per turn (owned follow-up turns, re-validation after each `await` with a `// REENTRANCY:` comment and a proposed ledger row) or by moving pure computation off the actor, never by hiding work from a measurement. Pin each with a C2 benchmark in this work package's benchmarks file (`Tests/ZTronAssetKitBenchmarks/`, the existing `c2Budget` convention of ADR-052 R4 and ADR-053; no literal P-n threshold) and, where a deterministic unit test can assert the bound structurally (turns, chunk sizes, operations per key), add that too. A benchmark miss on a loaded host whose only cause is load is not blocking (report load averages).
- **S3-R6 Shared files.** No public or package signature changes. No edit of `Package.swift`, `Scripts/`, `SPEC.md`, `docs/ARCHITECTURE.md`, `docs/DECISIONS.md`, `docs/TRACEABILITY.md`, `docs/ORCHESTRATION.md`, `README.md`, `docs/MIGRATION.md` or any `*ContractTests.swift`. Changes those documents need (ledger rows, §7.6 or §14 notes, §12 statuses) are PROPOSED in the draft; the orchestrator applies them at the Stage 3 merge. Contract files may change only where this file authorises it, bodies only.
- **S3-R7 Parallel close-outs.** Six close-outs run from tag `s3-base` in separate worktrees and merge afterwards in the order ah, b, c, d, f, g. Do not depend on another work package's Stage 3 change. Edit only this work package's files (ARCHITECTURE §1.2) plus the edits authorised below.
- **S3-R8 Strict bar (owner).** Verifiers keep the strict bar. A finding whose fix lies in ANOTHER work package's files is reported NON-blocking with its area prefixed `other-wp:<wp>:`; the orchestrator routes it. Pre-existing behaviour that a recorded ADR accepts is not a finding unless proven to violate a MUST in a way the record did not consider.
- **S3-R9 Records.** `docs/adr-drafts/{wp}.md` is new: one entry per item below (id, disposition, tests added with display names, evidence), then "Authorised edits outside {short}", "Proposed document changes" and "Not verified here". Your work package's Stage 2 record (`docs/adr-drafts/{orig}.md`) is background; read it by section as needed.

## Items for this close-out
"""

LEVEL_TEXT = {'B': 'BLOCKING', 'R': 'REQUIRED', 'O': 'OPTIONAL', 'A': 'ADR-RECORD'}

WPS = {
  's3b': dict(name='Stage 3 WP-B (storage core)', short='WP-B', orig='b', items=[
    ('B', ['S3-SECU-01'], "Saturate both additions in `currentAvailability(of:)` (`AssetStore+Reads.swift:70`, `:85`) with the store's existing `Int64.addingSaturating`; the probe becomes the regression test (expects `bytesMissing == Int64.max`, `missing == 2`). Check every other sum over manifest-declared sizes in WP-B's files for the same trap and list them in the draft."),
    ('B', ['S3-CONF-01', 'S3-CRAS-01'], "One item. Add R-STO-5 crash-at-every-boundary enumerations (SPEC 7.3) for an apply that changes an asset's content (checksum-change update), one that relocates it (directory change), and one that removes it, in every crash mode `StoreCrashTests`' first-sync enumeration uses, asserting I-1…I-5 after each reopen. Enumerate every point (R-STO-5 does not sample). Adapt `s3-probes/crash/` and `confirm-crash/S3-CRAS-01-S3UpdateCrashProbe.swift` and `confirm-conformance/`."),
    ('B', ['S3-CONF-06'], "Test the release of the old blob when a content change adopts bytes another asset already holds (`AssetStore+Apply.swift:345-346`, count 0); the confirmer's mutant (`confirm-conformance/S3-CONF-02-06.mutants.sh`) must fail it."),
    ('R', ['M-S-11'], "R-STO-6: an ENOSPC while staging through `writeStaged` (`Staging/StoreStagingSink.swift:175`, the path the Apple tier's copier uses) surfaces as `noSpace` (ADR-013), never as success. Kill the mutant (S3-R3)."),
    ('R', ['S3-PERF-04'], "Make the reaper's handling of keys a unit did not attempt linear (`AssetStore+Reaper.swift:193`; the confirmer's cursor experiment `confirm-performance/S3-PERF-04-cursor-reaper-experiment.diff` measured linear scaling). Pin it with a deterministic structural test (operations per key) and record the release measurement at 10k/20k/40k."),
    ('R', ['S3-CRAS-05'], "Write the missing half of store-1 S1-03: a purged doom is never rescued by launch adoption. If it fails, it is a bug: the failing test first, then the fix."),
    ('R', ['S3-B-017'], "`StoreCrashTests` 'R-STO-5: a process kill followed by a power loss in the next lifetime preserves I-1…I-5' (`Core/StoreCrashTests.swift:167`) overruns its limit under load and TSan: apply S3-R4 (cheaper steps first; a raised guard only with measurements). The new enumerations of S3-CONF-01 follow the same rule."),
    ('R', ['S3-B-023'], "Write T2-06 (ARCHITECTURE §12.5): the R-SYN-1 cross-launch collision case, a persisted epoch unique per launch."),
    ('O', ['S3-B-013'], "OI-14: count a pruning apply's releases in WP-B's release path so an overlapping maintenance eviction frees no more than needed, if bounded within WP-B's files; otherwise record."),
    ('O', ['S3-B-012'], "OI-12: a per-key reap exclusion so a busy store's orphan runs still collect, if bounded within WP-B's files; otherwise record."),
    ('O', ['S3-B-014'], "OI-15 / L4-R24(5): ruling R3 stands for `apply` and `admit`. If, within WP-B's files only, an on-demand binding of an `absent(.evicted)` record to a key that is live (referenced; not doomed, purged or corrupt) can avoid the redundant download without an engine change, do it with an exhaustive test over the blob states; otherwise record it as a CCR for WP-F (no engine edit here)."),
    ('A', ['S3-PERF-03', 'S3-B-010'], "P-13 stays the owner's (ADR-050). Record the hunter's root-cause evidence (a kernel stall in one unlink about every 850–1,060 unlinks, every 500 in a flat directory, independent of what the store controls) and the confirmer's re-run, as input for the owner. Never edit `BenchStorage.swift`'s P-13 assertion or the gate."),
    ('A', ['S3-PERF-05'], "User-initiated publications copy the present table, so a long run of them is quadratic (10,000: 4.9 s; bulk is linear). Record with the measurement. OPTIONAL fix only if a bounded, low-risk design exists in WP-B's files (for example a small overlay on the snapshot compacted periodically)."),
    ('A', ['S3-B-011', 'S3-B-015', 'S3-B-016', 'S3-B-018', 'S3-B-019', 'S3-B-020', 'S3-B-021', 'S3-B-022'], "Record: re-measure S3-B-011's maxEntries (100,000) stretches if cheap (beyond SPEC's 10,000 reference scale; a chunked `startGrace` is OPTIONAL if simple); try to reproduce S3-B-015 and measure S3-B-016 in release; the rest are recorded limits or device items for Stage 5."),
  ]),
  's3c': dict(name='Stage 3 WP-C (integrity, cleanup, eviction, migration)', short='WP-C', orig='c', items=[
    ('B', ['S3-STAB-01', 'S3-STAB-02', 'S3-B-034'], "CLASS RULING (the check-then-act poll). Enumerate EVERY poll in `Tests/ZTronAssetStorageTests` (all files, not only the listed sites) that releases a `SteppedBlockingExecutor` held unit after reading a condition; list each in the draft. Convert all to one helper: read `heldUnits` first, then the condition, and release only a unit read before a false condition (fix (a), verified by the confirmer, `confirm-stability/S3-STAB-01-fix-a.diff`). Put the helper in a NEW file under `Tests/ZTronAssetStorageTests/Cleanup/` as an `extension CorePoll` (`Core/CoreHarness.swift` is WP-B's), pinned by a deterministic test of exactly the race (a condition that captures its value and then waits for the next held unit). A site in a WP-B `Core/` test file is authorised for this conversion only, test code only. Show each converted test passing in at least 200 repetitions in debug and 20 under TSan, and `LegacyEdgeTests.phaseFourStopsListing` in 50 fresh TSan launches."),
    ('B', ['S3-B-025'], "C2 at the reference scale: evicting or purging one blob shared by 10,000 ids holds the actor 15.4–16.6 ms in one turn (`Eviction/QuotaEviction.swift:266`). Chunk one blob's holders across owned turns (S3-R5) and make `BenchCleanup.swift`'s C2 benchmark assert the 10,000-holders-per-blob case (today it only records it)."),
    ('R', ['M-S-07', 'M-S-08'], "R-CLN-5: (M-S-07) apply skips a planned victim leased after the plan even when its access stamp would not stop it (the lease guard at `QuotaEviction.swift:268` must be reached, so the test must not rely on `acquireLease` bumping `lastAccess`); (M-S-08) the eviction dry run (`evictionPlan`, `EvictionOrder.swift:207`) neither names nor counts a leased blob. Kill both mutants (S3-R3)."),
    ('R', ['M-S-20'], "R-CLN-2: an orphan younger than the orphan grace is kept, and one exactly at the grace is handled as the code's documented boundary says (`Cleanup/OrphanCollection.swift:236`): plant orphans with 0 < age < grace and age == grace. Kill the mutant."),
    ('R', ['S3-STAB-04', 'S3-B-042'], "`LegacyOnDemandRaceTests`: every direct `.task.value` / `.result` join (:46-47, :91-92, :128-129, :163-164, :252, :289-290, :329-330) is preceded by a 'both calls ended' poll that ends on cancellation, so a lost resume fails at the time limit instead of hanging the run (L5K-R27 (1))."),
    ('R', ['S3-CRAS-02'], "The model-based oracle (`OracleTests`) must include deletion work (settle/reap) in its operation sequences so blobs are really unlinked, with I-3 asserted after every step; the confirmer's mutant Z (a `fatalError` in `BlobDeletionUnit.run`) must fail it."),
    ('R', ['S3-CRAS-03'], "Crash-point enumerations (every point, every mode) for purge(.all), purge(.evictable), quarantine, orphan GC, deep verification, the second-extension copy and an eviction held by a lease; adapt `confirm-crash/S3-CRAS-03-S3CleanupCrashProbe.swift` and its audit sink."),
    ('R', ['S3-CRAS-04'], "Kill-then-power-loss pairs for legacy migration (H-10) and for an OS purge after a crash; adapt `confirm-crash/S3-CRAS-04-*`. The legacy pairs took 187 s for 16 cases at load 20–45: parameterise them so each case stays inside its guard under TSan (S3-R4), every pair kept."),
    ('R', ['S3-B-040'], "`recordIntegrityFailure` (`Integrity/StoreIntegrity.swift:54-79`) gets the presence guard `recordFailure` has (:101-107); a failing test first if a seam reaches the window, otherwise record why none does."),
    ('R', ['S3-B-039'], "Comment fix at `Migration/LegacyPhases.swift:426-431` (ARCHITECTURE §4.7 (3))."),
    ('A', ['S3-B-026', 'S3-B-027', 'S3-B-031', 'S3-B-035', 'S3-B-028', 'S3-B-029', 'S3-B-030', 'S3-B-032', 'S3-B-033', 'S3-B-041', 'S3-B-036', 'S3-B-037', 'S3-B-038'], "Record. S3-B-026 (OI-4): within C2 at 10,000 (2.5 ms); the async contract change is declined for Stage 3. S3-B-027: liveness under continuous stamping; OPTIONAL fix only if C-24's serial fits inside WP-C's files. S3-B-035: audit by reading that every persisted WP-B write bumps `commits.mutationSerial` in its turn, and record the audit table. The NEEDS-HUMAN-REVIEW items stay as ratified."),
  ]),
  's3d': dict(name='Stage 3 WP-D (transport)', short='WP-D', orig='d', items=[
    ('B', ['S3-CONC-01'], "Background priority changes: the newest request wins (a per-name serial taken before the first `await` and checked after it, cleared on `.finished`), and a handle's controls are delivered in FIFO order (one stream per handle drained by one task, not a `Task` per call). Commit both probes (`concurrency/S3-CONC-01.swift` and `confirm-concurrency/S3-CONC-01-reverse.swift`) as regression tests; propose the D-9 ledger row amendment in the draft."),
    ('R', ['S3-CONC-02'], "`BackgroundEventsRelay.accept` (`BackgroundSupport.swift:733-750`) must never drop an uncompleted handler: every handler it accepts is called exactly once, and none before the events of its own wake are staged. Test both properties."),
    ('R', ['M-N-22'], "R-NET-8: a weak `ETag` is never the resume validator; with a weak ETag and `Last-Modified` the sidecar keeps `.lastModified`, with only a weak ETag none (`Session/HTTPResponseReading.swift:63`). Kill the mutant."),
    ('R', ['S3-B-057'], "Write S2-19: 'R-SYN-14: no task outlives a transfer in the live foreground backend' (ARCHITECTURE §12.4)."),
    ('R', ['S3-B-055'], "OI-10: the loopback tests that time out under host load (`ForegroundBackendTests.swift:162-164`, `:200-202`) get request timeouts that cannot fire spuriously under load (an injected timeout or a deterministic trigger), with no assertion loosened."),
    ('A', ['S3-B-046', 'S3-B-047', 'S3-B-048', 'S3-B-049', 'S3-B-050', 'S3-B-051', 'S3-B-052', 'S3-B-053', 'S3-B-054', 'S3-B-056'], "Record only; the orchestrator moves the device items to DEVICE-TEST-PLAN at Stage 5. NEEDS-HUMAN-REVIEW items stay as ratified."),
  ]),
  's3f': dict(name='Stage 3 WP-F (sync engine)', short='WP-F', orig='f', items=[
    ('B', ['S3-CONC-04'], "A satisfied FIRST conditions reading counts as an edge for work that failed offline while no reading existed (`EngineConditions.swift:97`, `EngineFailures.swift:84-90`; the hunter's option 1 or 2). Both probes become regression tests; propose the note beside PROBE-C9C-3's rule in ARCHITECTURE §7.6."),
    ('B', ['S3-STAB-03'], "Apply S3-R4 to `EngineModelTests.randomOperations` (`:21`) and the near misses (`EngineLegacyMigrationTransferTests.swift:433`, `:453`, `:711`; `EngineRegressionCycle16Tests.swift:31`; `EngineGroupClaimTests.swift:387`): measure each under TSan (alone, and with a second TSan process running, as two verifiers do), make steps cheaper where possible, raise a guard only with measurements, and make the model loop check `Task.isCancelled` per operation."),
    ('B', ['S3-CONF-03'], "Test a run over a record failed at the integrity cap (`EngineRuns.swift:471-473`, count 0): the run must not end `.complete` and must not write the sync stamp; the dropping mutant must fail it."),
    ('B', ['S3-PERF-01'], "Engine shutdown holds the actor 17–22 ms at 10,000 (`EngineLifecycle.swift:470`, sorts at :493 and :580, `resumeEverything` :516-602), also on the mid-session rootVanished reopen path: bound it per turn (S3-R5; the hunter's three steps are a good start) and add a `BenchSync` C2 benchmark beside `handleReleaseTurns`."),
    ('B', ['S3-PERF-02'], "Applying a manifest under a 10,000-member prefetch group holds the actor 17–19 ms (`followApplied`, `EngineRuns.swift:419`, about 10–12 ms with a 3.6 ms key sort): make the follow proportional to what the apply changed or chunk it; give the same treatment to `finishRun`'s (:823) and `releaseSystemReattachments`' (:489) full sorted walks; `BenchSync` C2 benchmark."),
    ('R', ['S3-CONC-03'], "Event order for a lagging subscriber: run N's `syncFinished` precedes run N+1's `syncStarted` and `syncProgress` for every subscriber (`SubscriberQueue.publish` reuses an undelivered `.run` progress slot in place; `EngineEvents.swift:70-79` retires only `.transfer` slots). Both probes become tests."),
    ('R', ['S3-CONF-04'], "(a) Test `interactiveConcurrencyAtCritical` (ADR-036; `EngineDispatch.swift:79`, count 0). (b) is the documented design: record only."),
    ('R', ['S3-CONF-02'], "Test the Apple-tier catalog update check on an expensive network, not only under Low Data Mode (`EngineDispatch.swift:541`)."),
    ('R', ['S3-CONF-05'], "Test `ensureAvailable`'s mapping of an open auth breaker to `authRejected(.confirmed)` (`EngineCommands.swift:728`)."),
    ('R', ['S3-CONF-08'], "For each uncovered region the conformance hunter listed in Sync (and the Sync-owned ones among Storage/Kit, which are not yours: report those `other-wp:`), add a behaviour test through real APIs or a documented seam where reachable; record the rest as ARCHITECTURE §14 candidates."),
    ('R', ['M-N-09', 'M-N-12', 'M-N-14', 'M-N-16', 'M-N-20', 'M-N-39'], "Tests that kill each surviving mutant (S3-R3), with the scenarios the mutation agent described: promotion of a queued job to prefetch and to the user lane (`EngineJobs.swift:187`), the backoff ceiling doubling per attempt, the breaker's ratio boundary (3 of 6 at 0.5 opens), `Retry-After` exactly at `maxRetryAfter`, and a later shorter 429 that must not shorten the origin throttle."),
    ('R', ['S3-B-064', 'S3-B-065', 'S3-B-081', 'S3-B-082'], "The four proven backlog bugs, each failing test first: L4-R24(1) `reserveManifestProbe()` after `state.run = run` and before `spawn` (F-42), with an observer-side `invariantViolations()` assertion; L4-R24(4) a re-join that changes lane or comes from user work keeps its queue position as the lanes' rules say; L5-R16 a claim inherits the held lane's retry policy, so a claim-only job is not failed on its first failed attempt; L5-R22(4) `invariantViolations()` flags a large give-up's leftover claims only while its Release holds members or pending interests, plus the E2-shape test."),
    ('R', ['S3-B-063'], "L4-R22: lazy re-admission with an ordered index (O(log n) per probe exit) so a chain of half-open probes is no longer quadratic in the parked jobs; pin it structurally (re-admission work per exit) and extend `BenchSync.swift:328` to 10,000 parked members under C2."),
    ('R', ['S3-B-068', 'S3-B-069', 'S3-B-070'], "Write the §12 regression tests with the names ARCHITECTURE §12.3/§12.4 give: S1-01 (both), S1-07, S1-11, S1-12, S1-15's run form, S2-09, S2-10, S2-01's `ensureAvailable` form, S1-09's replaced-alarm and replaced-watcher halves, and an engine-side assertion of R-SYN-15's join-before-close order (mutants M5/M6 must fail it). A test that fails is a bug: commit it failing, then fix."),
    ('R', ['S3-B-077', 'S3-B-078'], "Measure, as `BenchSync` C2 benchmarks at 10,000: the first turn of each re-admission event, `registerGroup`'s de-duplication and sort, retries falling due together in one `fireDue`, and the 10,000-id prune announcement. Any turn over 10 ms is fixed under S3-R5."),
    ('R', ['S3-B-084', 'S3-B-085'], "Comment fixes: `releasesPerTurn`'s cost estimate (`EngineCommands.swift:363`, re-measure) and the REENTRANCY comment at `EngineDispatch.swift:743-744` (the lifecycle, epoch and attempt re-checks before `remote.transfer`)."),
    ('A', ['S3-B-066', 'S3-B-067', 'S3-B-071', 'S3-B-072', 'S3-B-073', 'S3-B-074', 'S3-B-075', 'S3-B-076', 'S3-B-079', 'S3-B-080', 'S3-B-083', 'S3-B-086', 'S3-B-087'], "Record the status of each (unproven or without a seam); write a test only where a real seam now reaches it."),
  ]),
  's3g': dict(name='Stage 3 WP-G (facade)', short='WP-G', orig='g', items=[
    ('R', ['S3-PERF-06'], "Clamp the prefetch window's walk to the carousel's ids (`Prefetch.swift:96`; `prefetchRadius` and `init(radius:)` are unclamped): a radius of `Int.max` must cost what the carousel's size costs. Add a P-8-style test with a huge radius."),
    ('R', ['S3-B-090', 'S3-B-091', 'S3-B-092'], "L5-R22 (1)–(3): pin the events exit for a consumer that stopped during its registration (mutant M05 must fail); tighten `EventContinuityModel` as L5-R22(2) says; a forced sync ending `.insufficientSpace` or `.serverUnavailable` on a healthy root makes exactly one root check, returns the result as given and does not reopen (mutant M01s must fail)."),
    ('R', ['S3-B-096'], "Test the three-reopen limit (`AssetClient.swift:144-149`) through a real or documented seam; if none can reach it, record why."),
    ('A', ['S3-CONF-07'], "Refuted as a defect: K-11 (`docs/adr-drafts/k.md:353`) records the fallback chain's download-before-kind-check deviation. No change; cite K-11 in the draft."),
    ('A', ['S3-B-093', 'S3-B-094', 'S3-B-095', 'S3-B-097', 'S3-B-098', 'S3-B-099', 'S3-B-100'], "Record; S3-B-093 (the optional sliced release survey at 100,000 entries) is OPTIONAL."),
  ]),
  's3ah': dict(name='Stage 3 WP-A and WP-H (model and test support)', short='WP-A and WP-H', orig='a', items=[
    ('R', ['S3-SECU-02'], "The decoder refuses (as the existing per-entry path violation, quarantined) every remote path the transport refuses: empty segment, '.' segment, backslash, trailing slash, and their percent-encoded forms (`%2E`), so no accepted entry fails on every fetch. One rule, in the model; the transport keeps its check as defence. Test each form."),
    ('R', ['S3-SECU-03'], "`StagingFileName(parsing:)` and `TransferAttempt(token:)` accept only canonical forms (no leading zeros), so a parsed name's `rawValue` names the same file. AUTHORISED: bodies of the contract files `Sources/ZTronAssetModel/Identity/TransferID.swift` and `Identity/StagingFileName.swift`, no signature change."),
    ('R', ['S3-B-104'], "L4-R24(2): `ManualTimeSource.advance(to:)` lands exactly on the target instant (`Sources/ZTronAssetTestSupport/ManualTimeSource.swift:144-149`; `MonotonicInstant.adding(seconds:)` truncates a Double, `Sources/ZTronAssetModel/Environment/Time.swift:26-37`). AUTHORISED: the body of the contract file `Environment/Time.swift`, no signature change. Test over a seeded set of gaps; then run the WHOLE suite to show no test relied on the 1 ns shortfall."),
    ('R', ['S3-B-006'], "OI-13: `ManifestFuzzTests`' linear-time check (`ManifestFuzzTests.swift:61`) must not fail on an efficiency core: compare the lowest of a few measurements or pin the QoS, without loosening the 64x bound."),
    ('R', ['S3-B-107'], "`LoopbackHTTPServerTests` 'start racing stop…' (`Tests/ZTronAssetStorageTests/TestSupport/LoopbackHTTPServerTests.swift:400`) under TSan: S3-R4."),
    ('A', ['S3-B-105', 'S3-B-106', 'S3-B-108', 'S3-B-007', 'S3-B-001', 'S3-B-002', 'S3-B-003', 'S3-B-004', 'S3-B-005', 'S3-B-008', 'S3-B-009'], "Record. S3-B-105 (a level-recording FileSystem spy or an `FSOpRecord` level) is a contract change, declined for Stage 3. NEEDS-HUMAN-REVIEW items stay as ratified."),
  ]),
}


def lookup(i):
    if i in findings:
        f = findings[i]
        return dict(id=i, kind='hunt', lens=f['lens'], location=f['location'], requirements=f['requirements'], problem=f['problem'], evidence=f['evidence'], repro=f['repro'], fix=f['fix'], confirmer=f['confirm'])
    if i in mutants:
        m = mutants[i]
        return dict(id=i, kind='surviving-mutant', location=m['file'], requirements=m['requirement'], problem=m['title'], missing_test=m['killing_tests'], notes=m['notes'], diff=m['diff_path'])
    if i in backlog:
        b = backlog[i]
        return dict(id=i, kind='backlog', location=b['status_evidence'], problem=b['title'], category=b['category'], sources=b['sources'], proposed=b['action'])
    raise KeyError(i)


for wp, spec in WPS.items():
    fpath = ROOT + 's3-findings-' + wp + '.json'
    lines = [GENERAL.format(name=spec['name'], wp=wp, findings=fpath, short=spec['short'], orig=spec['orig'])]
    issues = []
    for n, (lvl, ids, text) in enumerate(spec['items'], 1):
        lines.append('- **%s-%d [%s] %s.** %s' % (wp.upper(), n, LEVEL_TEXT[lvl], ', '.join(ids), text))
        for i in ids:
            d = lookup(i)
            issues.append(dict(blocking=(lvl == 'B'), area=LEVEL_TEXT[lvl] + ' ' + wp.upper() + '-' + str(n), location=d['location'], problem=i + ': ' + d['problem'], fix=text, detail=d))
    open(ROOT + 's3-rulings-' + wp + '.md', 'w').write('\n'.join(lines) + '\n')
    json.dump(issues, open(fpath, 'w'), indent=1)
    print(wp, len(spec['items']), 'items', len(issues), 'issues', sum(1 for x in issues if x['blocking']), 'blocking')
