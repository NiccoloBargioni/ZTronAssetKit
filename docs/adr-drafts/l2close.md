# Level 2 close pass, code — dispositions (`wp/l2ccode`)

Owner: the L2 close code pass, on the merged Level 2 head `a137af8` (ADR-050 and the L2 follow-up included). The
orchestrator authorised exactly two changes: the WP-D census wait that the L2 follow-up recorded but could not touch
(`docs/adr-drafts/l2fu.md`, item 1, "Outside the authorised scope"), and two orchestrator-owned contract tests. The
orchestrator numbers what follows into `DECISIONS.md` and ARCHITECTURE §10 at merge. Commits, in order:

| Commit | What |
|---|---|
| `7de3e04` | failing test: the live conditions census wait outlives its task's cancellation (item 1) |
| `4d42441` | the fix: `ObservationRegistry.wait(for:)` ends on its caller's cancellation; an additive throwing form and a test seam (item 1) |
| `fa228ec` | the two contract tests use the throwing census waits (item 2) |
| this file | the dispositions |

## Item 1 — The live conditions census wait ends when its caller is cancelled (WP-D)

- **Context.** `ObservationRegistry.wait(for:)` (`Sources/ZTronAssetTransport/Conditions/ConditionsObservation.swift`),
  exposed as the package seam `LiveDeviceConditionsSource.waitForObservations(equalTo:)`, suspended on a bare
  `withCheckedContinuation` that only `wake()` resumed (the count matched). Swift Testing's `.timeLimit` records the
  issue, cancels the test's task and then waits for the test body to return. So a regression that never brings the
  count to its target (an observation never registered, or never stopped) kept the body suspended for good, and the
  whole run hung instead of failing one test. It is the defect class that the L2 follow-up fixed in TestSupport.
- **Options.**
  - (a) Change `waitForObservations(equalTo:)` to throw or to return `Bool`. That changes a package signature, which
    the authorisation rules out.
  - (b) Reuse TestSupport's `CensusWaiters` / `CensusWaiting`. Transport depends on Model only, and a production
    target may not depend on the test support.
  - (c) Give `ObservationRegistry` the same mechanism, in place, plus additive package forms.
- **Decision: (c).**
  - **Mechanism.** `wait(for:registered:)` checks the count and registers the waiter synchronously in the continuation
    body, so no `add()` or `remove()` can fall between the check and the registration. It does not register a caller
    that is already cancelled (`Task.isCancelled`). Its `withTaskCancellationHandler` hops to the actor
    (`cancel(id)`), which removes the waiter before resuming it with `false`. `wake()` removes every matching waiter
    before resuming it with `true`. Each waiter is therefore resumed exactly once. `cancel(id)` is a no-op for a waiter
    `wake()` already resumed.
  - **A count that already matches is reported matched**, even when the caller is cancelled. A wait that ends early
    never reports its count as met: the seam returns `false`, the throwing form throws, and the `Void` form returns
    with the count unmet, so the caller's following expectations fail.
  - The internal `wait(for:)` gains a defaulted `registered:` parameter and a `@discardableResult Bool` result; it is
    internal, and the one existing call (`waitForObservations(equalTo:)`) compiles unchanged.
- **Additive API, for ratification.** No public or package signature changed.
  - Package: `LiveDeviceConditionsSource.requireObservations(equalTo:) async throws(CancellationError)`, the form for a
    test whose next step relies on the count.
  - Package test seam: `LiveDeviceConditionsSource.waitForObservations(equalTo:registered:) async -> Bool` (`false`:
    cancelled first; `registered` runs once the wait is registered).
  - Nothing public: the docs gate's count of public declarations is unchanged (1,281).
- **Tests** (`Tests/ZTronAssetTransportTests/ConditionsCensusWaitTests.swift`, a new file; the helpers copy the L2
  follow-up's `outcome(of:)` relay, since the Transport test target cannot see the Storage test target):
  - `Seams: a waitForObservations whose task is cancelled returns while no observation is active` (the failing test,
    committed first; it uses only the existing API).
  - `Seams: a waitForObservations cancelled while registered reports no match, and a later observation resumes only a
    new wait`. A cancelled waiter left registered would be resumed a second time by the later count, which traps.
  - `Seams: a waitForObservations for fewer observations, cancelled while registered, reports no match and leaves the
    observation running`.
  - `Seams: requireObservations throws CancellationError when cancelled first and returns once the count matches,
    cancelled or not`.
  - The names cite no requirement ID ("Seams:", as in `AppleTestSeamTests`), so `docs/TRACEABILITY.md` does not change.
- **Call sites, recorded, not changed.** `ConditionsTests.terminationStopsObservation` calls the `Void` form three
  times; the authorisation does not list that file.
  - The first call (`equalTo: 0`, before any observation) is met before the call and returns at once.
  - After the second (`equalTo: 1`) and third (`equalTo: 0`) calls the test cancels its consumer, reads
    `path.isCancelled`, awaits the consumer and starts a second observation. With this fix, a regression that never
    registers an observation ends the second call at the time limit; the third call is then met at once and the
    expectations fail. A regression in which `conditions()` itself never returns would still leave the body awaiting
    `consumer.value` and the second `conditions()`.
  - **Request to the orchestrator:** a WP-D follow-up that makes the second and third calls
    `try await source.requireObservations(equalTo:)` (the function already `throws`).
- **Out of scope, for the record.** The other bare continuations in Transport are production waits, not test census
  waits: `SessionGate.invalidate` (D-1, resumed by the session's `.invalidated` event) and
  `BackgroundTransferCoordinator.awaitBackgroundEvents` (D-8, resumed by the pump or `invalidate()`).
- **Proposed REENTRANCY rows (ARCHITECTURE §10.4).**
  - **l2close-1 (amends D-11).** `ObservationRegistry.wait(for:registered:)`: the continuation, inside
    `withTaskCancellationHandler`. Nothing is re-validated. It is a terminal wait, registered synchronously in the
    continuation body (unless the count already matches or the caller is already cancelled). It is resumed exactly
    once: by the `wake()` whose count matched, or by `cancel(id)`. The code cites "D-11 (amended, l2close-1
    proposed)"; the orchestrator may fold this text into D-11 and keep D-11 as the identifier.
  - **l2close-2.** `wait(for:registered:)`'s `onCancel` task: `await self.cancel(id)`. Nothing is re-validated. The
    task is not the actor's turn, and `cancel(id)` re-reads the table, so it does nothing for a waiter `wake()` already
    resumed.
- **Evidence.**
  - **Failing test first** (`7de3e04`, against the unfixed code): `Time limit was exceeded: 60.000 seconds` and
    `Expectation failed: ended != nil`, then `Test run with 1 test in 1 suite failed after 63.988 seconds with 2
    issues`; `swift test` exited 1 and the run ended.
  - **With the fix** (`4d42441`, `--filter 'ConditionsCensusWaitTests|ConditionsTests'`, `-warnings-as-errors`):
    `Test run with 8 tests in 2 suites passed after 0.001 seconds`. In every later run below, the Transport bundle
    ran 151 tests (147 in the L2 follow-up's runs, plus these four).

## Item 2 — The two orchestrator-owned contract tests use the throwing census waits

- **Context.** The L2 follow-up left `StorageContractTests` and `SyncContractTests` on the `Void` census waits
  (contract tests may not be edited). Two of their functions await work that depends on the census after such a wait:
  - `StorageContractTests.steppedExecutorOrdersUnits` awaits `second.value`, a unit only a `release(2)` of a held unit
    ends.
  - `SyncContractTests.manualTimeWakeOrder` awaits each sleeper's `value`, which only an `advance` past a registered
    sleeper ends.
  The `Void` waits now end on cancellation, but if the census was never met, these awaits never end, so a fake
  regression still hangs the run.
- **Decision.** The orchestrator authorised edits of exactly these two functions. Each `waitForHeldUnits(atLeast:)` /
  `waitForSleepers(atLeast:)` became `try await requireHeldUnits(atLeast:)` / `try await requireSleepers(atLeast:)`,
  and each function became `async throws`. No expectation, statement or order changed; the diff is five lines.
  - The other contract-test calls stay as they are: no other function was authorised.
- **Evidence.** The demonstration ran in this worktree with temporary mutants of the test support, reverted before any
  commit (`git status` clean after; the patch is kept in `.build-l2ccode/demo/mutant.patch`, which is not committed).
  - **Mutants.** `SteppedBlockingExecutor.run` parks each held unit's continuation in a side array instead of `gates`,
    so a unit stays suspended and never reaches the held census. `ManualTimeSource.sleep(until:)` parks each future
    sleeper's continuation in a side table instead of registering it, so no sleeper reaches the census and no
    `advance` wakes it.
  - **Before** (`4d42441`'s tests, the `Void` waits, + mutants; one filtered `swift test --skip-build` per test, under
    a watchdog that kills only its own process tree after 200 s; `.build-l2ccode/demo/watchdog.sh`).
    - `steppedExecutorOrdersUnits`: 201 s after the start, `swift-test` and `swiftpm-testing-helper` were still
      running, both at 0.0 % CPU; the watchdog killed them (exit 143). At 101 s a `ps` already showed both at 0.0 %
      CPU, past the 64 s at which the time limit fires.
    - `manualTimeWakeOrder`: the same, 201 s, both at 0.0 % CPU, killed (exit 143).
    - Their output was buffered to a file and lost with the kill (the L2 follow-up saw the same), so the log shows no
      line; the process table is the evidence.
  - **After** (`fa228ec`'s tests, the throwing waits, + the same mutants; one `swift test --skip-build --filter
    'steppedExecutorOrdersUnits|manualTimeWakeOrder'`): `Time limit was exceeded: 60.000 seconds`, then `Test run
    with 1 test in 1 suite failed after 63.995 seconds with 1 issue` (Sync) and `… failed after 64.000 seconds with 1
    issue` (Storage). `swift test` exited 1 after 130 s, both bundles having run. The `CancellationError` that the
    `require…` form throws adds no second issue.
  - **Without the mutants** both pass in every run below (`Suite "Storage contracts" passed`, `Suite "Sync contracts"
    passed`).

## Verification

All of these ran in this session from the worktree on `fa228ec` (this file is the only later change), with scratch
path `.build-l2ccode` (TMPDIR, the module cache and `LLVM_PROFILE_FILE` under `.build-l2ccode/tmp`) and
`.build-l2ccode-tsan` for TSan.

- **`SWIFTPM_SCRATCH=.build-l2ccode bash Scripts/verify.sh --quick`.** `HARNESS: unchanged since harness-frozen`,
  `toolchain OK: Swift 6.4 >= 6.3`, and the bundles `151 / 10 / 303 / 84 / 12 / 3 / 104` tests passed. The last line
  was `VERIFY: PASS`.
- **`swift build -c release --scratch-path .build-l2ccode -Xswiftc -warnings-as-errors`:** `Build complete! (20,86 s)`.
- **Gates.** `gates.py unsafe`: `UNSAFE escapes found=0 max=3`, `UNSAFE: PASS`. `gates.py docs`: `DOCS public
  declarations=1281 documented=1281 exempt=0 fraction=100.0%`, `DOCS: PASS` (unchanged: the additions are `package`).
- **`xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath .build-l2ccode/xcode build
  OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet`:** exit 0; the only output line was xcodebuild's `IDERunDestination:
  Supported platforms for the buildables in the current scheme is empty.` `ConditionsObservation.o` was built for
  `Debug-iphoneos`. The listing of `~/Library/Developer/Xcode/DerivedData` was the same before and after.
- **Transport, Storage and Sync, three times** (`--filter
  'ZTronAssetTransportTests|ZTronAssetStorageTests|ZTronAssetSyncTests'`). Each run exited 0: Transport 151 tests,
  Sync 10 tests, Storage 303 tests (in 49.4, 50.7 and 51.3 s).
- **The whole package once under TSan** (`--scratch-path .build-l2ccode-tsan --sanitize=thread --skip Benchmarks`;
  no other `swift-test`, `swiftpm-testing-helper` or `xctest` process at its start; load 8.0 at the start, 6.2 at the
  end). It took 289 s and exited 0. The bundles `151 / 10 / 303 / 84 / 12 / 3 / 104` tests passed, with 0
  ThreadSanitizer reports. `startRacingStop` (l2fu item 2) took 24.4 s, under its 45 s trigger.
- **`docs/TRACEABILITY.md`.** Untouched: neither `--gates-only` nor `--full` ran, and the new test names cite no ID.

## Not verified here

Nothing device-only changed. The live `NWPathMonitor` path is unchanged; the new tests use the scripted path observer
or start no observation at all.
