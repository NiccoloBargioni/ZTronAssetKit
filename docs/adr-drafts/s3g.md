# Stage 3 WP-G close-out (`s3g`): the facade

Stage 3 hardening, branch `wp/s3g` (based on tag `s3-base`), close-out fix cycle 1. The rulings are
`.build-orchestrator/s3-rulings-s3g.md` and the evidence `.build-orchestrator/s3-findings-s3g.json` (13 entries, none
blocking). WP-G's Stage 2 record is `docs/adr-drafts/g.md`. One entry per item below; then the authorised edits outside
WP-G, the proposed document changes and what is not verified here.

## Orchestrator rulings (close-out)

- **Orchestrator ruling (close-out), S3-R1 (scope and order).** No item is BLOCKING. Done in order: the REQUIRED items
  S3G-1, S3G-2 and S3G-3 (each test committed on its own; S3G-1's failing benchmark before its fix), then the ADR-RECORD
  items S3G-4 and S3G-5 (this file, no code). Nothing outside the listed items was changed.
- **Orchestrator ruling (close-out), S3-R2 (probes).** The S3-PERF-06 probe (`s3-probes/performance/`) was adapted into
  the WP's benchmarks file under a requirement name; no `S3…Probe` suite was committed, and no replay of an old ordering.
  Every new test follows SPEC 7.2 (requirement ID first, `.timeLimit(.minutes(1))` on each that awaits, `ManualTimeSource`
  only, no sleeps) and the ADR-051 gating convention (both platforms in each `@available`, on the `@Test` or the helper
  that uses a Mutex-backed fake, never on a `@Suite`).
- **Orchestrator ruling (close-out), S3-R3 (mutation survivors).** The diffs of M05 and M01s are not on disk (they are
  named in L5-R22 and ADR-054 only), so each was rebuilt from its description, applied in place to a build under
  `.build-s3g/` and reverted (`git status` clean after each); the diffs and logs are in `.build-s3g/mutants/`. The failing
  lines are pasted under each item.
- **Orchestrator ruling (close-out), S3-R4 (hang guards).** No time limit was raised: every new test stays at
  `.minutes(1)`, the model keeps its `.minutes(2)` per case (precedent `EngineGateModelTests`), and 5,000 seeds take
  20.2 s in all on this host.
- **Orchestrator ruling (close-out), S3-R5 (C2 at the reference scale).** No C2 item is assigned to WP-G; S3G-1 is a
  main-actor (P-8) cost and is pinned by a P-8 benchmark and a structural test.
- **Orchestrator ruling (close-out), S3-R6 (shared files).** No public or package signature changed. The only source
  edit is the body of `PrefetchWindow.targets` plus one new internal static (`PrefetchWindow.reach`) and doc comments, in
  WP-G's `Prefetch.swift` (authorised by S3G-1). No shared document, `Package.swift`, `Scripts/` or `*ContractTests.swift`
  was edited; the changes they need are proposed below.
- **Orchestrator ruling (close-out), S3-R7 (parallel close-outs).** Worktree `.worktrees/s3g`, scratch `.build-s3g*`,
  simulator `02CE21B4-F307-4CB7-B80A-1F2EF72F115C` only. Nothing depends on another work package's Stage 3 change.
- **Orchestrator ruling (close-out), S3-R8 (strict bar).** No finding was routed to another work package.
- **Orchestrator ruling (close-out), S3-R9 (records).** This file.

## S3G-1 [REQUIRED] S3-PERF-06: the prefetch window's walk is clamped to the carousel

- **Disposition: fixed.** `PrefetchWindow.targets` (`Sources/ZTronAssetKit/Prefetch/Prefetch.swift`) walked `distance`
  from 1 to the radius whatever the carousel's size, allocating a two-element array per step, on the main actor
  (`PrefetchWindowController.update`). The walk now stops at
  `PrefetchWindow.reach(count:current:radius:) = min(max(radius, 0), max(current, count - 1 - current))`, the farther
  side of `current`, and visits the two sides without an array. Past that reach neither side has an index left, so the
  result is unchanged for every radius, and neither `current + distance` nor the counter can overflow. The controller's
  doc comment now says O(min(radius, ids.count)). `AssetClientConfiguration.prefetchRadius` and `init(radius:)` are left
  unclamped (a contract file, and the clamp in the walk makes any value safe).
- **Tests.** `P-8: a prefetch window update over 10 pages stays within ui_call_ms_max with a radius far beyond the carousel`
  (`Tests/ZTronAssetKitBenchmarks/BenchKit.swift`, release; radii 10,000,000 and `Int.max`, medians of five updates);
  `R-CAR-3: a window radius beyond the carousel, Int.max included, walks only the carousel's ids and yields the whole carousel once`
  (`Tests/ZTronAssetKitTests/PrefetchFacadeTests.swift`, structural: the walk's length for every `current` and radii up to
  `Int.max`, and the window equal to the one for the carousel's own size).
- **Failing first** (`b483477`, the benchmark alone, on the unfixed source; load averages 61.8 / 33.0 / 51.2 when the
  run began):
  `P-8 prefetch window update over 10 pages, radius 10000000: median 11.058084000000001 ms (runs [10.940125, 12.4525, 11.058084000000001, 10.657333000000001, 11.229125]; budget 1.0 ms)`
  `✘ Test "P-8: a prefetch window update over 10 pages stays within ui_call_ms_max with a radius far beyond the carousel" recorded an issue at BenchKit.swift:277:17: Expectation failed: median <= callMax`
- **After the fix** (`8688503`; load averages 25.05 / 130.22 / 135.67 at the start, 23.68 at the end):
  `P-8 prefetch window update over 10 pages, radius 10000000: median 0.007 ms`;
  `P-8 prefetch window update over 10 pages, radius 9223372036854775807: median 0.008959 ms`; all six Kit benchmarks
  pass (`✔ Test run with 6 tests in 2 suites passed after 12.988 seconds.`).
- **Mutant (S3-R3).** MC1, `reach` returning `max(radius, 0)` (the old walk): the structural test fails at once, before it
  would walk 2^63 steps: `PrefetchFacadeTests.swift:167:33: Issue recorded` ("the walk goes … steps, past the carousel's …").

## S3G-2 [REQUIRED] S3-B-090, S3-B-091, S3-B-092: L5-R22 (1)–(3)

### (1) S3-B-090: the events exit for a consumer that stopped during its registration

- **Disposition: pinned (test only).** `R-SYN-12: an events stream stopped while its first registration waits for a reopen subscribes nothing of its own to the replacement`
  (`FacadeRaceTests.swift`): the schedule of the existing cancelled-registration test (the `stopped` seam orders the stop
  before the parked reopen goes on), plus a census of the replacement's registrations (`state.lastSubscriber`): exactly
  one, the subscription the reopen's hand-over made for the follower and dropped at once. No production test read was
  needed.
- **Mutant M05 (rebuilt):** the `guard !self.finished else { unfollow; return nil }` exit after `registerEvents` in
  `EventForwarder.next()` removed, so the stopped forwarder registers and starts a pump, which subscribes to the
  replacement by itself (`makeEventStream()`), and the replacement's replay (launch snapshot and conditions) ends that pump.
  The existing test still passes against it; the new one fails:
  `FacadeRaceTests.swift:437:9: Expectation failed: registrations == 1` (`.build-s3g/mutants/M05-test.log`).

### (2) S3-B-091: the event continuity model, tightened

- **Disposition: tightened (test only), as L5-R22 (2) says.** `EventContinuityModelTests.swift`:
  - **The registration engine's `clientStarted`.** For each consumer the walk records the generation serving when it
    registered and whether that engine's `clientStarted` came before or after the registration. Before the action it reads
    the serving engine's lifecycle and newest subscriber key in one engine turn; a started engine (`running` or later) had
    broadcast its `clientStarted` before the registration (`before`). An unstarted one (`created`/`starting`: an installed
    replacement whose reopen is parked before its start finished) is followed, for an `events` stream, by a condition wait
    on that engine that records the lifecycle in the turn that registered the stream (`SyncEngine.lifecycleAtRegistration`,
    test file): still unstarted there means the `clientStarted` is broadcast later and is **owed** (`after`). I1 now
    requires it in the first gap; observed 35 such registrations over the 500 suite seeds (27 `created`, 8 `starting`).
  - **Stamped calls.** `performMaintenance` and `sync(.force)` calls the walk awaits are stamped like the markers (start
    tick, serving generation, the oracle log's length at their start, and the event their result names:
    `maintenanceFinished(report)`, or `syncFinished(_, outcome)` for an outcome only a run returns). For the consumer's
    registration generation, each such call begun after the registration owes its event, or a later one of its subject,
    inside that generation's part of the stream (from the start to the first handed generation's `clientStarted`). The
    oracle's first matching event at or after the call's start stands for it, so the check never asks for more than the
    call's own event.
  - **I2's spare `clientStarted`.** The first gap accepts the registration engine's own `clientStarted` beyond the owed
    ones only when the walk could not tell its start from the registration: a `subscribe()` that met the engine unstarted
    (the call starts it itself before it registers), or one started while a reopen was parked before its install.
- **What remains measurement limits of the model** (proposed replacements for ADR-054's two rows): (a′) a `subscribe()`
  stream whose registration engine was unstarted when the call began, and one started while a reopen was parked before its
  install, are not owed that engine's `clientStarted` and may receive it once; (a″) calls begun while a reopen was parked
  before its install, and `sync(.force)` calls that returned `.failed` or `.notDue`, are not stamped (they may return
  without publishing). L5-R13/L5-R19's promise is unchanged.
- **Evidence.** 500 seeds (the suite, 10 cases) pass in 2.4 s and 5,000 by hand (`EVENT_MODEL_SEED_COUNT=5000`) in
  20.2 s (load about 30). Two mutants show the tightening's reach, each fails all 10 cases on the tightened model and
  passes on `s3-base`'s model (`OLD_MODEL=1`, `.build-s3g/mutants/summary3.txt`):
  - MT1, the forwarder drops `clientStarted` from its registration stream:
    `seed 48: I1: consumer 0 (events, registered at 14, live) lost a clientStarted: generations [] each published one, and the registration generation 3 its own after the registration, and 0 arrived before its first marker (generation 3): []`;
    old model `✔ Test run with 1 test in 1 suite passed after 14.841 seconds.`
  - MT2, the forwarder drops `maintenanceFinished` from its registration stream:
    `seed 13: I1: consumer 0 (subscribe(), registered at 2, live) lost maintenanceFinished(…) of its registration generation 0, from performMaintenance begun at t6 after its registration, and no later event of its subject arrived in that generation's part of its stream`;
    old model `✔ Test run with 1 test in 1 suite passed after 14.966 seconds.`
  - MC00 (the L5-R19 defect rebuilt: `EventSlot` maps `clientShutDown` to `.client` again, in a scratch build of WP-F's
    `SubscriberQueue.swift`, reverted) is still caught: 10 of 10 cases fail, e.g.
    `seed 9: I1: consumer 2 (subscribe(), registered at 9, live) lost a clientStarted: generations [1] each published one and 0 arrived before its first marker (generation 1): []`.

### (3) S3-B-092: `sync`'s L5-R20 trigger list

- **Disposition: pinned (test only).** `R-STO-9: a forced sync ending serverUnavailable or insufficientSpace on a healthy root is checked once against the root, returned as given, and never reopens`
  (`FacadeReopenTests.swift`, two cases): an undecodable manifest (`.failed(.serverUnavailable(retryAfter: nil))`) and a
  plan over a 1,000-byte budget (`.failed(.insufficientSpace(required: ≥ 2,000, …))`); each makes exactly one stat of the
  lock file, returns the engine's outcome as given and keeps generation 0.
- **Mutant M01s (rebuilt):** `sync`'s hand-off narrowed to `.shutDown` and `.storageUnavailable`. Both cases fail:
  `… with 1 argument failure → .insufficientSpace at FacadeReopenTests.swift:775:9: Expectation failed: checks.count == 1`
  and `… → .serverUnavailable at FacadeReopenTests.swift:775:9: Expectation failed: checks.count == 1`.

## S3G-3 [REQUIRED] S3-B-096: the three-reopen limit

- **Disposition: tested through a documented seam.** The seam is the store's file system (`AssetEnvironment.fileSystem`,
  ADR-038): `VanishingRootVolume` (test file `FacadeReopenLimitTests.swift`) delegates to `FakeFileSystem` and, while
  armed, moves the store root aside in one operation of the fake volume at every `itemInfo` of a `store.lock`, which only
  the root checks make (`StoreLock.verifyRoot`, from a commit or from `verifyRootNow()`). `KitHarness.make` gained a
  `volume:` parameter for it (test file). The `withAsset` case also uses the lifecycle's documented seam (G-10): at
  `replacementObservesPressure` it starts the replacement and checks its root, so each pair knows its root was replaced
  before the next attempt.
- **Tests.** `R-STO-9: a call whose root vanishes at every root check reopens reopenAttempts times, then reports the replaced root`
  (`purge(.all)`: three reopens, then the fourth attempt's `.storageUnavailable(.rootVanished)` as given, at least four roots
  replaced, the last store knows it; the next call on a root that stays reopens once more and succeeds: the limit is per
  call) and `R-STO-9: withAsset whose every pair knows its root was replaced reopens three times, then throws without leasing`
  (three reopens before any lease, then `AssetClient.swift`'s refusal after every reopen allowed: exactly four roots
  replaced, the body never ran, no lease in the first or the last store).
- **Mutants.** `reopenAttempts = 4` and `= 2`: both tests fail, e.g.
  `FacadeReopenLimitTests.swift:52:9: Expectation failed: limited.generation == 3` and
  `FacadeReopenLimitTests.swift:106:9: Expectation failed: limited.generation == 3`.
- **Coverage.** See the evidence section: `AssetClient.swift`'s fall-through after `reopenAttempts` now runs (it was the
  underflowed 18.4E counter of L5-C2-07).

## S3G-4 [ADR-RECORD] S3-CONF-07: the fallback chain downloads before its candidate check

- **Disposition: refuted as a defect; no change.** `AssetFallbackChain.fetch` resolves (downloading an entry of another
  kind at `.userInitiated`) and only then checks the candidate extension, where the prior art checked the manifest entry
  first. This deviation is recorded: `docs/adr-drafts/k.md` K-11 (line 353: "an on-demand resolve that downloads before
  its candidate check (as `AssetFallbackChain.fetch`; the prior art checked the manifest entry first)"), accepted by
  ADR-055 and documented for adopters in MIGRATION.md. The residue the confirmer noted (`FallbackChain.fetch`'s doc
  comment implies parity, the WP-K shim cites ADR-037 rather than K-11) is proposed below as a docs note, not changed here.

## S3G-5 [ADR-RECORD] S3-B-093, S3-B-094, S3-B-095, S3-B-097, S3-B-098, S3-B-099, S3-B-100

- **S3-B-093 (OPTIONAL, not done).** ADR-050's deferred sliced release survey of P-9 at 100,000 manifest entries (E-16)
  is not written in this cycle: it is optional, and the cycle's room went to the REQUIRED items. P-9's 64-resolve heartbeat
  stays the measured case (`heartbeat gaps 870, p99 19.667 ms … (budget 50.0 ms)` here).
- **S3-B-094 (accepted deviation, recorded).** Replaced-root limits under L5-R4/L5-R20, unchanged: a call that succeeds
  on a replaced root no commit has detected does not reopen until a qualifying failure or a commit; a root check whose own
  stat fails records nothing; a root that vanishes between `withAsset`'s read of `unavailableReason` and its lease leases
  from the vanished store (a read). Cost: one `lstat` per qualifying failure. Device plan.
- **S3-B-095 (untested interleavings, recorded).** A reopen landing between two hops of one facade call (`subscribe()`'s
  registration, the background-events hand-off, the diagnostic report's three reads) and a stream registration
  overlapping the client's shutdown (`register(_:)` answered `.shutDown` by an engine no reopen retired) are still shown by
  reading only: no seam point is added without a bug proven there (L5-R9).
- **S3-B-097 (unproven suspicion, recorded).** R-CAR-5's lost update is not reproduced: the record-first order (G-3)
  removes the window by construction and no seam reaches it.
- **S3-B-098, S3-B-099, S3-B-100 (device-only, recorded).** A real `rootVanished` on a device and the reopen's cost there;
  UIKit's background-events hook end to end and the live `MainBundleLookup` against an app bundle with resources; P-8 and
  P-9 on a device, the C2 figures on a device, and the benchmark bundle on the simulator (built, not run, ADR-051). All go
  to the device test plan.

## Authorised edits outside WP-G

None. Every file changed is WP-G's (`Sources/ZTronAssetKit/**`, `Tests/ZTronAssetKitTests/**` but not
`KitContractTests.swift`, `Tests/ZTronAssetKitBenchmarks/BenchKit.swift`) or this draft. The MC00 run mutated WP-F's
`SubscriberQueue.swift` in a scratch build only and reverted it.

## Proposed document changes (for the orchestrator at the Stage 3 merge)

- **ARCHITECTURE §1.2**, WP-G's test files: add `FacadeReopenLimitTests` (with `VanishingRootVolume`).
- **ARCHITECTURE §8**: after "`PrefetchWindow.targets` (implemented): current, +1, −1, +2, −2…" add "; the walk stops at the
  carousel's farther end (`PrefetchWindow.reach`), so any radius, `Int.max` included, costs what the carousel's size costs
  (S3-PERF-06)".
- **ARCHITECTURE §14, "Known deliberately untested lines"**: drop the `AssetClient.swift:146-151` fall-through after
  `reopenAttempts` (now run by both `FacadeReopenLimitTests`), drop "run but not pinned (L5-R22 (1))" for
  `EventForwarder.swift:159-165` (pinned by the census test) and "Test gap (L5-R22 (3))" for `sync`'s trigger list (pinned
  for `.serverUnavailable` and `.insufficientSpace`).
- **ARCHITECTURE §14, the model sentence** ("with the tolerances G-17's audit lists and the two measurement limits ADR-054
  records (L5-R22 (2))"): "with the tolerances G-17's audit lists and the measurement limits Stage 3 left (S3G-2): (a′)
  and (a″) above".
- **ADR-054, "The model's measurement limits (L5-R22 (2))"**: replace rows (a) and (b) with (a′) and (a″) above, and
  record that the registration generation's `clientStarted` (when the registration preceded its start) and its stamped
  calls' terminal events are owed since Stage 3.
- **ARCHITECTURE §11**: credit R-CAR-3/P-8 with the two S3G-1 tests, R-STO-9 with the forced-sync and the two reopen-limit
  tests, and R-SYN-12 with the census test.
- **ARCHITECTURE §10.6**: no new row; no await was added in `Sources/ZTronAssetKit` (the `// REENTRANCY:` comments of the
  new test helper `SyncEngine.lifecycleAtRegistration` follow the test files' own convention, like `awaitNoSubscribers`).
- **Docs note (S3G-4 residue):** `AssetFallbackChain.fetch`'s doc comment and the WP-K shim's comment could cite K-11 /
  ADR-055 for the download-before-check order; a comment-only change, left to the docs level.
- **TRACEABILITY**: regenerated at the merge (the new display names above).

## Not verified here

- S3-B-094, S3-B-098, S3-B-099 and S3-B-100 as recorded under S3G-5 (device-only or accepted).
- The S3G-1 figures come from the macOS 27 host (release, loaded), not a device.
- The tightened model's (a′)/(a″) remain measurement limits (above).

## Evidence (final source tree `a03a96c`, macOS 27 host; scratch `.build-s3g*`)

- `SWIFTPM_SCRATCH=.build-s3g bash Scripts/verify.sh --quick` (load 14.92 at the start, 16.96 at the end):
  `::: OK   harness`, `::: OK   toolchain`, `::: OK   build-debug`, `::: OK   tests`, **`VERIFY: PASS`**; the Kit
  bundle `✔ Test run with 90 tests in 12 suites passed after 5.202 seconds.` (85 before, plus the census, the forced-sync
  pair counted once, the two reopen-limit tests and the huge-radius test).
- `swift build -c release --scratch-path .build-s3g -Xswiftc -warnings-as-errors`: `Build complete! (33,30 s)`, exit 0.
- `python3 Scripts/gates.py unsafe …`: `UNSAFE escapes found=0 max=3`, `UNSAFE: PASS`; `python3 Scripts/gates.py docs …`:
  `DOCS public declarations=1281 documented=1281 exempt=0 fraction=100.0%`, `DOCS: PASS`.
- Coverage (the `--quick` run's merged profile, exported over all 8 test bundles):
  `COVERAGE target=ZTronAssetKit            lines= 97.99% (1464/1494) min=70.0 OK`, `COVERAGE overall lines=96.55% (25146/26045) min=80.0 OK`,
  `COVERAGE: PASS`. `llvm-cov show` of the Kit bundle for `AssetClient.swift`: `:147` 2, `:148` 1, `:149` 1, `:150` 1,
  `:151` 1 (the underflowed 18.4E counter of L5-C2-07 is gone; `:142` stays 0, schedule-dependent as recorded).
- `swift test --scratch-path .build-s3g --skip Benchmarks --filter ZTronAssetKitTests`, three runs (load 7.25, 20.16,
  18.78): `✔ Test run with 90 tests in 12 suites passed after 2.442 seconds.`, `… 2.071 seconds.`, `… 2.037 seconds.`
- TSan once: `swift test --scratch-path .build-s3g-tsan --sanitize=thread --skip Benchmarks --filter ZTronAssetKitTests`
  (load 7.25 at the start, 31.36 at the end): `✔ Test run with 90 tests in 12 suites passed after 35.292 seconds.`, exit 0,
  0 `WARNING: ThreadSanitizer` lines; the model's ten cases took 35.3 s under TSan, under half its 2-minute guard.
- iOS Simulator (ADR-051; `iPhone 17e`, iOS 27.0, `02CE21B4-F307-4CB7-B80A-1F2EF72F115C`, benchmarks skipped; load 16.93
  at the start, 39.88 at the end): `** TEST SUCCEEDED **`; `xcresulttool get test-results summary`:
  `result Passed, totalTestCount 1310, passedTests 1310, failedTests 0, skippedTests 0`. The simulator is shut down.
- The event model by hand: `EVENT_MODEL_SEED_COUNT=5000`: `✔ Test run with 1 test in 1 suite passed after 20.172 seconds.`
  (load 34.93 → 27.06).
- iOS: `xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath .build-s3g/xcode build OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet`:
  exit 0, no error or warning line (only xcodebuild's `IDERunDestination: Supported platforms … is empty` notice).
- Kit benchmarks (release, `--filter '/KitBenchmarks/'`, the six WP-G benchmarks; load 25.05 → 23.68): all pass, figures
  under S3G-1 and `P-1 lookup p99 0.625 µs at 10,000`, `P-8 window update: p99 0.015417 ms`,
  `P-9 … heartbeat gaps 870, p99 19.667 ms`, `P-12 init p99 0.008666 ms over fakes`.
