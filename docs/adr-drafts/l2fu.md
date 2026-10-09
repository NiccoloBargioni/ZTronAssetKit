# Level 2 follow-up, cycles 1 and 2 — dispositions (`wp/l2fu`)

Owner: the L2 follow-up work package, on the merged Level 2 head `645caee`. The orchestrator authorised a scope that
crosses work packages: WP-H's test support (and, to use its new waits, the call sites in WP-B's core tests), one
test-cost question about an L1 test, one WP-E fix, and wording nits in the drafts. The orchestrator numbers what
follows into `DECISIONS.md` and ARCHITECTURE §10 at merge. Cycle 2 answers the verifiers' findings on cycle 1 (one
blocking, in item 3); its additions are marked "cycle 2". Commits, in order:

| Commit | What |
|---|---|
| `058a10f` | failing tests: the TestSupport census waits outlive their task's cancellation (item 1) |
| `e207d24` | the fix: every census wait ends on its caller's cancellation; additive throwing forms and test seams (item 1) |
| `62c99d3` | the storage core tests use the throwing forms (item 1, "use it where it helps") |
| `1180216` | failing test: PROBE-C5-3 (item 3) |
| `f1881ee` | the fix: packs whose planned removal has not succeeded count in `sourceCopyBytes()` (item 3) |
| `760430f` | wording nits (item 4) |
| `eda3c59` | the dispositions (cycle 1) |
| `ee2640c` | cycle 2 — failing test: VP-A3, a running removal stops counting after a later survey (item 3) |
| `0cebba5` | cycle 2 — the fix: packs whose removal is running count whatever a later survey finds; doc wording (item 3) |
| `9a26721` | cycle 2 — WP-H's own TestSupport tests use the throwing or `#require`d census waits (item 1) |
| this file | the dispositions (cycle 2) |

## Item 1 — Every TestSupport census wait ends when its caller is cancelled

- **Context.** B-38 (`b.md`) left this to WP-H and the orchestrator. Swift Testing's `.timeLimit` records the issue,
  cancels the test's task and then waits for the test body to return. `SteppedBlockingExecutor.waitForHeldUnits` and
  `ManualTimeSource.waitForSleepers` suspended on a continuation that only their census resumed (a unit parked, a
  sleeper registered). So a regression that never reached the census kept the body suspended for good, and the whole
  run hung instead of failing that one test.
- **Inventory** (`grep CheckedContinuation Sources/ZTronAssetTestSupport`, every wait a test can await):

  | Wait | Before | Disposition |
  |---|---|---|
  | `SteppedBlockingExecutor.waitForHeldUnits(atLeast:)` (public) | census only | **fixed** |
  | `ManualTimeSource.waitForSleepers(atLeast:)` (public) | census only | **fixed** |
  | `FakeDeviceConditionsSource.waitForObservers(equalTo:)` (public) | census only | **fixed** |
  | `FakeMemoryPressureSource.waitForObservers(equalTo:)` (public) | census only | **fixed** |
  | `ScriptedSnapshotSink.waitForInstalls(atLeast:)` (package) | census only | **fixed** |
  | `EventProbe.waitForWaiters(atLeast:)` (internal, `@testable`) | census or `finish()` | **fixed**: `false` on cancellation too |
  | `EventProbe.next(where:)` | already ends on cancellation (h-1, h-3) | unchanged |
  | `ManualTimeSource.sleep(until:)` | already throws on cancellation | unchanged |
  | `LoopbackHTTPServer.start()` | already throws on cancellation (h-6, h-9) | unchanged |
  | `LoopbackHTTPServer.receive`/`send` | private nonisolated bridges | unchanged: no test awaits them; Network calls each completion exactly once, and `stop()` cancels every connection, which completes a pending receive |
  | `SteppedBlockingExecutor.run(_:)`'s gate | the held unit itself | unchanged, see below |

  **The unit gate is not a wait.** It is the held unit, awaited by the store on the test's behalf. Releasing it when its
  caller is cancelled would run the unit before the test releases it, which changes what the reentrancy tests hold
  (`StagingSinkTests.inCancelledTask` cancels its task first, then holds that task's cleanup unit and releases it
  itself). The live serial executor never abandons a submitted unit either. A test that ends while units are held
  leaves a suspended task behind. Such a task does not keep the process from exiting: in the failing-test run of
  `058a10f` below, six waiter tasks stayed suspended for good and the run still exited.
- **Options.** (a) The existing waits return on cancellation, and nothing else changes. Callers that go on to index
  `heldUnits` (15 index expressions in the core tests) would then trap, and callers that await a held publication would still
  hang. (b) As (a), plus additive throwing forms that the call sites use. (c) Make the existing waits throw or return
  `Bool`. This is a signature change, which ADR-049 rules out ("TestSupport grows additively only").
- **Decision: (b).**
  - **Mechanism.** The actors share an internal `CensusWaiters` table and an internal `CensusWaiting` protocol
    (`Sources/ZTronAssetTestSupport/CensusWaiters.swift`). `awaitCensus` checks the census and registers the waiter
    synchronously in the continuation body, so no census change can fall between the check and the registration. It
    does not register a caller that is already cancelled. Its `withTaskCancellationHandler` hops to the actor
    (`cancelCensusWait`), which removes the waiter before resuming it with `false`. The census turn removes a waiter
    before resuming it with `true`. Each waiter is therefore resumed exactly once.
  - **`ManualTimeSource`** is a `Mutex` class. It decides registration and cancellation under its lock, using the
    same `allocated` / `registered` / `cancelled` phases as its sleepers.
  - **A census that is already met counts as met**, even when the caller is cancelled. A wait that ends early never
    reports its census as met: the `Void` forms return with the census unmet, so the caller's following expectations
    fail.
- **Additive API, for ratification.** No existing signature changed.
  - Public: `SteppedBlockingExecutor.requireHeldUnits(atLeast:)`, `ManualTimeSource.requireSleepers(atLeast:)`, and
    `FakeDeviceConditionsSource.requireObservers(equalTo:)` and `FakeMemoryPressureSource.requireObservers(equalTo:)`.
    Each is `async throws(CancellationError)`.
  - Package: `ScriptedSnapshotSink.requireInstalls(atLeast:)`.
  - Package test seams: `waitForHeldUnits(atLeast:registered:)`, `waitForSleepers(atLeast:registered:)`, the two
    `waitForObservers(equalTo:registered:)` and `waitForInstalls(atLeast:registered:)`. Each returns `Bool` (`false`:
    cancelled first) and calls `registered` once the wait is registered.
  - Internal: `EventProbe.waitForWaiters(atLeast:registered:)`, `CensusWaiters` and `CensusWaiting`.
  - The library imports neither Swift Testing nor its traits (macOS 12 target).
- **Call sites ("use it where it helps").**
  - **Converted.** All 52 `waitForHeldUnits` / `waitForSleepers` calls in `Tests/ZTronAssetStorageTests/Core` (WP-B's
    tests) became `requireHeldUnits` / `requireSleepers`, and `StoreRaceTests.step` became `throws`. After an early
    return, 15 index expressions that follow them (`heldUnits[i]`, `held[i]`) would trap. Others are followed by an await of a
    held publication, which would hang.
  - **Converted in cycle 2** (`9a26721`, verifier finding on WP-H's own tests in `Tests/ZTronAssetStorageTests/TestSupport`):
    - `BasicFakesTests.conditionsReachEveryObserver`: both `waitForObservers` became `requireObservers`. After the first
      one the test awaits observer tasks that iterate `conditions()`; had the observations never registered, those
      awaits would hang the run although the wait itself ended.
    - `BasicFakesTests.snapshotSinkInstallCensus`: the `waitForInstalls(atLeast: 2)` that ran in an unstructured task
      runs in a child task (`async let`), so the test's cancellation reaches it. Awaiting an unstructured task does not
      forward cancellation.
    - `ManualTimeSourceTests.sleepers` (the helper behind three tests) uses `requireSleepers` and throws, so a test
      never awaits sleepers that never registered and that nothing would wake.
    - `EventProbeTests`: the six discarded `waitForWaiters` results are `try #require`d; the two census waits that ran
      in unstructured tasks run in child tasks (`async let`).
  - **Not converted.** `StorageContractTests` (3 calls) and `SyncContractTests` (8): contract tests may not be edited,
    and their `Void` waits now end on cancellation. `BenchStorage.swift:466`: a benchmark, skipped in these runs.
    Cycle 2: two `Void` calls stay because the `Void` form is what the test is about. In
    `ManualTimeSourceTests.waitForSleepersIsEventDriven` the test registers its sleepers through the `Void` form
    itself, then `try #require(time.pendingSleepers == 2)` ends it if a wait ended early. In
    `BasicFakesTests.snapshotSinkInstallCensus` the final `waitForInstalls(atLeast: 1)` is met before the call, so it
    returns at once.
  - **Outside the authorised scope (cycle 2, recorded, not changed).** `ConditionsObservation.wait(for:)`
    (`Sources/ZTronAssetTransport/Conditions/ConditionsObservation.swift`, WP-D), exposed as the package seam
    `LiveDeviceConditionsSource.waitForObservations(equalTo:)` and called 3 times in `ConditionsTests`, is the same
    defect class. It suspends on a bare `withCheckedContinuation` that only `wake()` resumes, so a regression that never
    reaches the count would hang the run past the test's limit. No probe shows it hanging. **Request to the
    orchestrator:** a WP-D follow-up that gives it the `withTaskCancellationHandler` and actor-hop pattern used here,
    with a cancelled-waiter behaviour test. The Apple tier's test waits (`PackAvailabilityCoordinator.wait(for:registered:)`,
    `AppleSourceState.waitForDrain`) already end on cancellation.
  - **For WP-C, WP-F and WP-G:** use the `require…` forms in new tests whenever the code after a wait assumes that
    the census was met.
- **Proposed REENTRANCY rows (ARCHITECTURE §10.3).**
  - **l2fu-1.** `CensusWaiting.awaitCensus`: the continuation, inside `withTaskCancellationHandler`. Nothing is
    re-validated. It is a terminal wait, registered synchronously in the continuation body (unless the census is
    already met or the caller is already cancelled). It is resumed exactly once: by the census turn that met its
    target, by `cancelCensusWait(id)`, or by `resumeAll()` (`EventProbe.finish`).
  - **l2fu-2.** `awaitCensus`'s `onCancel` task: `await self.cancelCensusWait(id)`. Nothing is re-validated. The task
    is not the actor's turn, and `cancelCensusWait` re-reads the table, so it does nothing for a waiter that was
    already resumed.
  - **Amended.** TS2 ("resumed only by the actor turn that reached the count") and h-4 now also end on the caller's
    cancellation. The code cites "TS2 … (l2fu-1)".
- **Evidence.**
  - **Failing tests first.** `058a10f` adds six tests, one per wait. Each calls the existing API from a task that is
    cancelled before the wait starts, and awaits it through a stream relay that ends with the test. Against the old
    code: `Test run with 6 tests in 1 suite failed after 63.997 seconds with 12 issues`. Each test recorded "Time
    limit was exceeded: 60.000 seconds" and its outcome expectation; the run exited after 68 s.
  - **With the fix.** `e207d24` adds six tests of a wait cancelled after it registered. Each checks that the census
    is not reported met and that a later census change resumes only a new wait (a second resumption would trap). It
    also adds four tests of the throwing forms. `Test run with 16 tests in 1 suite passed after 0.001 seconds`, 15
    runs out of 15.
  - **Demonstration in scratch copies** (`.build-l2fu/demo/{before,after}`, `git archive` of the commit). The mutant
    changes `AssetStore.runUnit` to run `work()` inline, so no unit ever reaches its executor. The test is `R-STO-9: a
    second close() during the first one's durable commit returns only after the commit and the lock release`, which
    waits for close #1's durable commit to be held.
    - **Before** (`058a10f` + mutant). In two runs the test process was still running 240 s and 241 s after it
      started, at 0.0 % CPU. The watchdog killed it (exit 143), against the test's 60 s limit.
    - **After** (`62c99d3` + mutant). `Time limit was exceeded: 60.000 seconds`, then `Test run with 1 test in 1 suite
      failed after 63.924 seconds with 1 issue`. The process exited with code 1, 69 s after the test run started. The
      `CancellationError` that `requireHeldUnits` throws adds no second issue.
  - **Cycle 2 demonstration for the converted call sites** (`.build-l2fu/demo2/{before,after}`, `git archive` of each
    commit). The mutant stores each observation of `FakeDeviceConditionsSource.conditions()` in a side table, so
    observations never register and `send` reaches none of them. The test is `Test support: FakeDeviceConditionsSource
    delivers each sent state to every live observation`.
    - **Before** (`0cebba5` + mutant, the `Void` wait). The run printed `Time limit was exceeded: 60.000 seconds`. The
      wait then returned, but the test went on to await its observer tasks, which never end. 201 s after the run
      started, `swift-test` and `swiftpm-testing-helper` were still running at 0.0 % CPU. The watchdog killed them
      (exit 143). A first run, with its output buffered to a file, was killed the same way at 200 s.
    - **After** (`9a26721` + mutant, `requireObservers`). `Time limit was exceeded: 60.000 seconds`, then `Test run
      with 1 test in 1 suite failed after 63.984 seconds with 1 issue`. The process exited with code 1, 69 s after it
      started.

## Item 2 — `startRacingStop` under TSan: measured, left unchanged

- **Context.** In the L1 run, `Test support: start racing stop ends every start exactly once, with a port or stopped,
  and never hangs` took 57 s of its one-minute limit under TSan at load 16.
- **Measurements** (TSan, this Mac).
  - **Alone:** 0.246 s and 0.243 s (load 6.1 and 3.9).
  - **A temporary probe, split into phases** (deleted, never committed). Run alone, the whole loop took 0.235 s. Of
    that, 0.215 s went to the 79,800 `Task.yield()`s (rounds 0–399 yield 0–399 times), and 0.029 s to the 400 servers
    without yields. The stop beat the listener only up to round 42.
  - **Beside the two exhaustive index state-space suites in one process** (load 2.4 rising to 6.7): the test took
    6.75 s. In the probe, the whole loop took 6.75 s, the yields alone 3.73 s and the servers alone 0.88 s, and the
    stop beat the listener up to round **294**.
  - **In the whole package's TSan run** (no other agent running; the run itself took the load from 4.5 to 6.1):
    **23.4 s**, the second slowest test after the R-MAN-3 fuzz (34.9 s). Its target ran 303 tests in 160.6 s. That
    leaves a 2.6× margin to the one-minute limit.
  - **Cycle 2, a verifier's whole-package TSan run** at load about 10, with another verifier's `swift test` running
    alongside: **30.06 s**, half the limit. The test passed. Its cost keeps growing with the machine's load; it is not
    a flake.
  - **Cycle 2, this agent's whole-package TSan run** (no other `swift-test`, `swiftpm-testing-helper` or `xctest`
    process at its start, checked with `ps`; load 8.1 at the start, just after this agent's own builds, and 6.7 at the
    end; 262 s): **24.0 s**. Its target ran 303 tests in 158.8 s.
- **Cause.** The test's cost is round trips through the cooperative pool. It makes 79,800 yields, plus an actor hop
  per listener state. Each round trip queues behind every other job on the pool. The exhaustive state-space suites
  saturate the pool with CPU-bound rows, so each round trip waits. Other agents' TSan runs on the same machine (load
  16) make every job slower still. The cost is not inherent: alone, the test takes 0.25 s.
- **Options.**
  - (a) Shrink the yield spread, for example to `round % 50`. Under contention the stop still beats the listener at
    294 yields, so this would stop covering exactly the races that a loaded machine produces. That weakens the test.
  - (b) Serialise the test. Swift Testing's `.serialized` orders tests within one suite only, and no trait isolates a
    test from other suites.
  - (c) Raise the limit. The cost is not inherent, so the rule does not allow it.
  - (d) Leave the test unchanged.
- **Decision: (d).** The time limit is a deadlock detector. On a quiet machine the test keeps a 2.6× margin, and the
  57 s took a machine oversubscribed about twofold. This confirms the process lesson already recorded: run TSan only
  on an otherwise idle machine. If a later level's suites saturate the pool for longer, the next lever is option (a)
  with a spread chosen from a measurement on that machine. Raising the limit stays the last resort.
- **Cycle 2: decision unchanged, with an explicit trigger.** The new figures (24.0 s at load 6–8, 30.06 s at about
  10) fit the cause above: the cost grows with load and stays under the limit. If a later level's TSan run takes
  this test **more than about 45 s**, apply option (a), with a yield spread measured on that machine.

## Item 3 — `sourceCopyBytes()` counts packs whose planned removal has not succeeded (WP-E)

- **Context.** Verifier probe PROBE-C5-3: after `failRemove(.system)`, a reclaim returned `released=[]
  failed=[ZTronExtras]`, the pack stayed installed (`installed=true`), and `sourceCopyBytes()` reported 0. The pack's
  only entry is excluded by the retention scope, so no report names the pack adopted, and nothing released it. The L2
  ruling (R-CLN-9) says that `sourceCopyBytes()` counts adopted packs, packs released in this process that came back,
  and packs whose planned removal has not yet succeeded.
- **Decision.**
  - `AppleSourceState` keeps the last survey's settled packs (`settledPacks`, set by `planRelease`).
  - Cycle 2 (verifier probe VP-A3, blocking): `settledPacks` alone missed a removal still running when a concurrent
    reclaim surveyed a newer report and reset the set. `sourceCopyPacks()` therefore also counts the packs whose
    removal is in flight (`releasing`, the set that already keeps a concurrent call from planning a pack twice). It
    returns `adoptedPacks ∪ releasedInProcess ∪ settledPacks ∪ releasing`.
  - A pack whose planned removal is still running counts its `installedBytes`, whatever later surveys find. A pack
    whose removal failed counts while the last survey still finds it settled (the next reclaim plans it again). Once
    removed, it reports `nil` and adds 0. The sum still saturates.
- **Consequences.**
  - The window while a removal call runs is counted: the bytes are still on the device until the call returns. A
    concurrent reclaim's survey cannot hide it (cycle 2).
  - After a failed removal, a pack that the last survey no longer finds settled (a new manifest adds an entry nobody
    adopted) counts only while it is adopted or released in this process. It is no longer planned for removal, and it
    holds content the store does not have. The cycle-2 test pins this (`sourceCopyBytes() == 0` after the failure),
    and a later settled survey counts it again.
  - Like the other sets, `settledPacks` lives in memory: a fresh source counts nothing until its first reclaim (E-11
    "Limitation").
  - Docs (cycle 2): the public `sourceCopyBytes()` doc now reads "still running, or failed while the last reclaim's
    survey still finds them settled, so a later reclaim plans them again". The `sourceCopyPacks`, `releasing` and
    `settledPacks` docs say the same. The `reclaimSourceCopies` and `finishRelease` docs use the ruled ADR-027 phrase
    "stays installed until a reclaim in a later catalog generation releases it".
- **Evidence.**
  - **Failing test committed first** (`1180216`): `R-CLN-9: a pack whose planned removal is still running or failed
    counts as a source copy until a removal succeeds`. It follows PROBE-C5-3's timeline with `holdRemove` across the
    failing removal, then a successful reclaim. Against the old code: `Test run with 18 tests in 1 suite failed after
    0.012 seconds with 2 issues` (both `sourceCopyBytes() == 4_096` expectations).
  - **With the fix** (`f1881ee`): `Test run with 103 tests in 14 suites passed after 0.384 seconds` (the whole
    AppleHosted target).
  - **Cycle 2, failing test committed first** (`ee2640c`): `R-CLN-9: a pack whose planned removal is running counts as
    a source copy even after a later survey finds it unsettled`. It follows VP-A3's timeline. Reclaim A plans the
    excluded-only pack with `failRemove(.system)` and `holdRemove`. Reclaim B surveys a report in which the pack gained
    an unadopted entry. The test expects 4,096 bytes before `releaseRemove`, 0 after the failure (B's survey is the
    last), 4,096 after a settled survey fails again, and 0 after a successful removal. Against the cycle-1 code: `Test
    run with 19 tests in 1 suite failed after 0.011 seconds with 1 issue`, at `PackReleaseTests.swift:500` ("A's
    removal still runs, whatever B's survey found").
  - **Cycle 2, with the fix** (`0cebba5`): `Test run with 104 tests in 14 suites passed after 0.367 seconds`.

## Item 4 — Wording nits (`760430f`)

- `e.md`, "Requests for the orchestrator (L2 close-out)", ADR-027 item (b): "until the next catalog generation" now
  reads "until a reclaim in a later catalog generation releases it".
- `d.md`, "Contract signatures": "; close-out cycle 5: `forStart(name:expectedBytes:resumeData:)`, D-20.1" is added
  after the cycle-3 `BackgroundTaskTag` entry.
- `BackgroundTaskTag.forStart` `///` doc (`Sources/ZTronAssetTransport/Background/BackgroundTaskTag.swift`): the live
  file "keeps no expression of its own for the tag; only its choice of `downloadTask` overload stays device-only".
- `b.md`, B-33's cycle-5 amendment 6: the forged states keep `launchEpoch` at the source generation, so they do not
  model rot that lowers the newest parsed generation below a committed one (that case reuses an epoch, accepted).
- `b.md`, B-28's cycle-5 amendment: `committedFile` is "the name the store last saw hold the committed generation;
  each decision stats `index.bin` again before acting".

## Process finding (cycle 2) — DerivedData written outside the repository

- **Context.** A requirements verifier of cycle 1 ran `xcodebuild -list` once without `-derivedDataPath`. Xcode then
  created two folders outside the repository, against the owner directive:
  `~/Library/Developer/Xcode/DerivedData/l2fu-amdjkcpjknpnpogbbampxkozfvvi` and
  `~/Library/Developer/Xcode/DerivedData/ZTronAssetKit-amdjkcpjknpnpogbbampxkozfvvi` (8 KB each, created Oct 9 05:43;
  the hash is this worktree's path). This agent confirmed both exist with a read-only `ls`/`du`.
- **Decision.** Not deleted here: CLAUDE.md allows `rm -rf` only inside `.build*`, `.verify-logs` and the agent's own
  worktrees. **Request to the orchestrator or owner:** delete the two folders, and make verifier prompts require
  `-derivedDataPath` for every `xcodebuild` invocation, `-list` included, not only for builds. Every `xcodebuild` of
  this work package passed `-derivedDataPath .build-l2fu/xcode`.

## Verification

All of these ran in this session from the worktree, with scratch path `.build-l2fu` (TMPDIR, the module cache and
`LLVM_PROFILE_FILE` under `.build-l2fu/tmp`). Cycle 2 ran them again on `9a26721` (the code is unchanged since; this
file is the only later change).

- **`SWIFTPM_SCRATCH=.build-l2fu bash Scripts/verify.sh --quick`.** `HARNESS: unchanged since harness-frozen`,
  `toolchain OK: Swift 6.4 >= 6.3`, and the bundles `147 / 10 / 303 / 84 / 12 / 3 / 104` tests passed. The last line
  was `VERIFY: PASS`.
- **`swift build -c release --scratch-path .build-l2fu -Xswiftc -warnings-as-errors`:** `Build complete! (15,86 s)`.
- **Gates.**
  - `gates.py unsafe`: `UNSAFE escapes found=0 max=3`, `UNSAFE: PASS`.
  - `gates.py docs`: `DOCS public declarations=1281 documented=1281 exempt=0 fraction=100.0%`, `DOCS: PASS`. The
    count was 1,277 at the merge; the four new public `require…` methods account for the rest.
- **`xcodebuild … -destination 'generic/platform=iOS' -derivedDataPath .build-l2fu/xcode build
  OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet`:** exit 0. The only output line was xcodebuild's
  `IDERunDestination: Supported platforms for the buildables in the current scheme is empty.` No new folder appeared
  under `~/Library/Developer/Xcode/DerivedData` (checked before and after).
- **The touched targets, three times** (`--filter 'ZTronAssetStorageTests|ZTronAssetAppleHostedTests|ZTronAssetTransportTests'`).
  Each run passed: Transport 147 tests, Storage 303 tests (in 48.0, 50.3 and 51.1 s), AppleHosted 104 tests.
- **The whole package once under TSan** (`--scratch-path .build-l2fu-tsan --sanitize=thread --skip Benchmarks`). It
  took 262 s and exited 0. The bundles `147 / 10 / 303 / 84 / 12 / 3 / 104` tests passed, with 0 ThreadSanitizer
  reports.
- **Coverage** (`swift test --enable-code-coverage --skip Benchmarks`, then the export over all 8 bundles and
  `gates.py coverage`):
  - `COVERAGE target=ZTronAssetAppleHosted lines= 99.76% (1248/1251) min=70.0 OK`.
  - Storage 95.14 %, Transport 99.14 %, Model 99.28 %; overall 93.41 %; the device-only share 1.35 %.
  - The gate as a whole reports `FAIL`: ZTronAssetKit (37.82 %) and ZTronAssetSync (30.57 %) are still the stubs that
    WP-G and WP-F replace at L4–L5. This work does not touch them.
- **`docs/TRACEABILITY.md`.** Untouched: neither `--gates-only` nor `--full` ran.

## Not verified here

Nothing device-only changed. The Apple-tier change runs only against `FakePackBackend`; whether a real
`BackgroundAssets` removal can fail and leave the pack installed is already under "Not verified" (E-12, and the L2
rulings' "concrete BackgroundAssets error types").
