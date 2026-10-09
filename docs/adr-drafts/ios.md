# iOS Simulator test build, cycles 1–2 — dispositions (`wp/ios`)

Owner request, not a SPEC work package: the owner runs the unit tests in Xcode on an iOS Simulator and they did not
build. This branch makes every test target build under `-warnings-as-errors` and pass on the iOS Simulator, keeps the
macOS run green, and leaves the package floors (iOS 15.0, macOS 12.0) unchanged. The orchestrator numbers what follows
into `DECISIONS.md` at merge. Commits, in order, on `48271e7`:

| Commit | What |
|---|---|
| `b9f2752` | the owner's own edits, applied verbatim: `iOS 26.0` beside `macOS 26.0` on the Apple-tier tests (item 1) |
| `7b0ead0` | availability attributes only: `iOS 18.0` beside every `macOS 15.0` test gate, and the two TestSupport doc comments that state the convention (item 2) |
| `b671ea2` | runtime fix: the loopback server no longer sets `acceptLocalOnly`, which the simulator enforces by resetting loopback connections (item 3) |
| `122a22e` | this file, cycle 1 |
| `b6e23a2` | runtime fix (cycle 2): the crash enumerations give their cooperative thread back once per case, so the live lock test no longer overruns its time limit on a loaded host (item 4) |
| `6a51450` | tests (cycle 2): two tests pin the loopback server's 127.0.0.1-only binding (item 5) |
| this file | the dispositions, cycle 2 (verifier notes applied) |

## Item 1 — The owner's iOS 26 edits

`git apply` of the owner's saved diff (12 files): `@available(macOS 26.0, *)` became `@available(macOS 26.0, iOS 26.0, *)`
on every Apple-tier test and on `AppleTierFixture`, plus a stray blank line in `SyncContractTests.swift`, which
`7b0ead0` drops.

## Item 2 — The gating convention for tests (new tests must follow it)

- **Context.** On iOS the trailing `*` of `@available(macOS 15.0, *)` means "every iOS version the target builds for",
  so the gate vanishes there. The Mutex-backed fakes in `ZTronAssetTestSupport` (`ManualTimeSource`, `FakeFileSystem`,
  the recording fakes) are `@available(macOS 15.0, iOS 18.0, *)`, so every iOS test that touched one failed to build.
  The build before `7b0ead0`, with the owner's edits applied, stopped at
  `AppleTierFixture.swift:107:10: error: 'RecordingLogTap' is only available in iOS 18.0 or newer` (and 12 more in that
  file: `FakeStagingSink`, `Mutex`, `withLock`).
- **What the compiler showed about deployment targets** (the `-target` triples in the `xcodebuild build-for-testing`
  log for the simulator): the 7 library targets, `ZTronAssetTestSupport` included, build at
  `arm64-apple-ios15.0-simulator`; all 8 test bundles, Benchmarks included, build at `arm64-apple-ios17.0-simulator`.
  This mirrors macOS, where SwiftPM builds the libraries at 12.0 and the test bundles at 14.0
  (APPLE-API-VERIFICATION §3.2, correction of ADR-041). So the request's premise that test targets build at iOS 15.0
  does not hold with this Xcode: Swift Testing's `.timeLimit` (iOS 16) compiles ungated in a test bundle on iOS, and no
  `iOS 16.0` gate was needed or added. The compiler was the judge: with only the `iOS 18.0` clauses added, the
  simulator `build-for-testing` reports `** TEST BUILD SUCCEEDED **` under `-warnings-as-errors`.
- **Convention.**
  1. A test that uses a Mutex-backed TestSupport fake carries `@available(macOS 15.0, iOS 18.0, *)` on each `@Test`
     **function** (or on the helper type or function that uses the fake). Never on a `@Suite` type: Swift Testing
     rejects that (APPLE-API-VERIFICATION §3 #21). The accepted forms are a gated `@Test` function in an ungated
     suite, a gated free `@Test` function, or `guard #available(…) else { return }` in the body; this package uses
     the first.
  2. An Apple-hosted tier test carries `@available(macOS 26.0, iOS 26.0, *)`.
  3. Every gate names **both** platforms. `@available(macOS N, *)` alone is a bug: it builds on macOS and fails on
     iOS (or, worse, admits an iOS version the API does not exist on).
  4. In a test bundle (built at macOS 14.0 / iOS 17.0), APIs available at macOS 14 / iOS 17 or earlier need no gate,
     `.timeLimit` included. Anything newer needs the pair of clauses for the release that ships it. This holds for
     the current Xcode (27.0, 27A266a). If a toolchain ever builds test bundles at the package floor, the point-7
     simulator build flags every ungated `.timeLimit`, and those then take `iOS 16.0` beside `macOS 13.0`.
  5. `ZTronAssetTestSupport` is a library target and builds at the package floors (macOS 12.0 / iOS 15.0): every
     declaration there that uses a newer API carries both clauses, and Swift Testing traits stay out of it.
  6. No `#available` in `Sources/` (R-APL-5: `SingleAvailabilityScanTests` counts exactly one).
  7. The check is the simulator build below; a work package that adds tests runs it (or at least
     `build-for-testing`) before hand-off.
  8. Time limits and the cooperative pool. Swift Testing starts every test and every case at once, and each
     `.timeLimit` runs from its own start. A test that loops over many CPU-bound cases on the cooperative pool (crash
     points, fault points, seeds) awaits `Task.yield()` at the top of each case, so that no time-limited test beside it
     depends on getting a pool thread while it runs (item 4). Awaits into a store over `InlineBlockingExecutor` do not
     count, because they need not suspend. Under `xcodebuild` an overrun costs more than one failure: the runner is
     killed and restarted, and the tests in flight are lost from the totals (item 3, follow-ups).
- **TestSupport gates.** Every gated declaration in `Sources/ZTronAssetTestSupport` already carried `iOS 18.0`. The two
  places whose gate lacked the iOS clause were the doc comments that tell tests how to gate
  (`FakeFileSystem.swift:351`, `ManualTimeSource.swift:8`); both now say `@available(macOS 15.0, iOS 18.0, *)`.
- **Scope of `7b0ead0`.** 479 `@available` attributes in 63 test files (the `*ContractTests.swift` edits are
  availability attributes only, as authorised), 3 doc comments (2 in `Sources/ZTronAssetTestSupport`, 1 in
  `Tests/ZTronAssetStorageTests/Core/CoreHarness.swift`), and 1 blank line. No test body, assertion, trait or floor
  changed. Counted from `git show 7b0ead0`: 479 added lines are attributes, and the other 3 added lines are the doc
  comments.

## Item 3 — Runtime failures on the simulator, fixed at the cause

- **Symptom.** With item 2 in place the first simulator run had 64 failures, all on the loopback server: the 19
  `LoopbackHTTPServerTests` (`Caught error: POSIXErrorCode(rawValue: 54): Connection reset by peer`, or a 0-byte
  response) and 45 transport tests that drive the real foreground `URLSession` against it (timeouts after ~11 s,
  `.transient(.timedOut, …)`, and three tests that hit their 1-minute `.timeLimit`). Every server-side connection was
  logged as `nw_flow_service_reads [C… 127.0.0.1:… failed socket-flow (satisfied (Path is satisfied), interface:
  lo0)] No output handler`, followed by `nw_protocol_socket_reset_linger … SO_LINGER`.
- **Cause, isolated with a probe.** A standalone program (`.build-ios/probe`, not committed) started an `NWListener`
  with six parameter sets and sent one HTTP request from an `NWConnection` client to `127.0.0.1`. It was run on the
  macOS host and inside the simulator with `xcrun simctl spawn`:

  | Listener parameters | macOS 27 | iOS 27.0 Simulator |
  |---|---|---|
  | `.loopback` + `acceptLocalOnly` + `requiredLocalEndpoint 127.0.0.1` (the server's) | served | **reset, server sees nothing** |
  | `.loopback` + `acceptLocalOnly` | served | **reset** |
  | `acceptLocalOnly` + `requiredLocalEndpoint 127.0.0.1` | served | **reset** |
  | `.loopback` + `requiredLocalEndpoint 127.0.0.1` | served | served |
  | `requiredLocalEndpoint 127.0.0.1` only | served | served |
  | none | served | served |

  `acceptLocalOnly` alone decides it: the simulator's Network stack refuses connections from 127.0.0.1 to such a
  listener.
- **Fix (`b671ea2`).** `makeListener()` no longer sets `acceptLocalOnly`, on every platform (one code path, tested on
  both). The listener is still bound to `127.0.0.1` with `requiredInterfaceType = .loopback`, which is what keeps other
  hosts out: nothing off the machine can reach 127.0.0.1 on `lo0`. The failing tests already existed (the server's own
  tests fail on the simulator before the fix), so no new test was written; after the fix all 454 Storage and Transport
  tests pass on the simulator and all of `--quick` passes on macOS.
- **Follow-ups for the orchestrator.** `docs/design/transport.md:1031` and APPLE-API-VERIFICATION §3 #24 still list
  `acceptLocalOnly` among the server's parameters. At merge, drop it from both and cite the probe table above (the
  simulator resets 127.0.0.1 connections to an `acceptLocalOnly` listener). Item 5 now pins the binding with tests.
- **Runner restarts and the 10-minute stall (corrected in cycle 2).** Cycle 1 blamed the runner restart and the
  roughly 10 minutes in `simctl diagnose` after the broken run on what a failed loopback transfer leaves running. The
  cycle-2 verifiers showed that this was wrong. There are two separate `xcodebuild` behaviours:
  1. Any Swift Testing `.timeLimit` overrun is reported in the xcresult as "Test exceeded execution time allowance of 1
     minute", and `xcodebuild` kills and restarts the test runner ("Restarting after unexpected exit, crash, or test
     timeout"). The tests in flight at the kill never report, so the totals come out short (665 of 667 in a verifier's
     run). The cycle-1 broken run had three such overruns, which explains its restart. With a working server, the
     restart happened again after the overrun that item 4 fixes.
  2. Any failing run makes `xcodebuild` collect diagnostics from the simulator, and it can wait up to 600 s ("Failure
     collecting diagnostics from simulator: Timed out after 600.0 seconds"). In a verifier's reproduction against
     `122a22e`, both xctest processes exited after reporting, and the 10 minutes were this collection, not leaked
     state.

  Agent runs therefore pass `-collect-test-diagnostics never`, a flag this Xcode lists in `xcodebuild -help` as
  "on-failure|never" (see Commands). It changes no test outcome. The owner can drop it when a sysdiagnose is wanted.
  Whether a crash, as opposed to a time-limit overrun, also restarts the runner is taken from `xcodebuild`'s own
  message and was not confirmed here.

## Item 4 — Runtime fix (cycle 2): the crash enumerations starved the live tests of pool threads

- **Symptom (the cycle-2 verifier's full simulator run 1, on `122a22e`).** `R-STO-9: the live lock rejects a second
  opener in the same process and frees on close` (`LiveFileSystemTests.swift:28`, `.timeLimit(.minutes(1))`) recorded
  "Time limit was exceeded: 60.000 seconds" and failed after 73.261 s. The runner was restarted, `totalTestCount` came
  out as 665 instead of 667, the run waited 600 s for diagnostics, and it ended `** TEST FAILED **` (exit 65). The host
  load average was about 88, and the crash enumerations running side by side took 45–123 s. The verifier's
  storage-only run and a second full run passed. Alone, the test takes 0.938 s on this simulator and 0.091 s on macOS
  (both measured here). In full runs before the fix it already took 6.161 s on the simulator and 5.837 s on macOS:
  most of that time is waiting, not work.
- **Cause.** The enumerations run whole store lifetimes over the fake file system on the cooperative pool. Their awaits
  into the store need not suspend: `InlineBlockingExecutor` runs each unit on the caller, and a hop to an idle actor can
  stay on the same thread. So a case keeps its thread for its whole run, and a few cases side by side hold every pool
  thread (8 on this host). The live test's store hops through two `DispatchBlockingExecutor` queues and resumes by
  continuation, so after each unit it waits for a pool thread, while its time limit keeps running from its start. On
  the simulator, under host load, the waits add up past 60 s.
- **Fix (`b6e23a2`).** `await Task.yield()` at the top of each case, which returns the thread to the pool so a waiting
  continuation can run:
  - `StoreCrashTests`: per crash point (`crashAtEveryBoundary`, `crashThenFullVolume`), per kill point and per
    second-lifetime point (`killThenPowerLoss`), and per fault occurrence (`faultAtEveryCommitThenFullVolume`, not on
    the verifier's list, but it is the same kind of loop).
  - `IndexCommitStateSpaceTests`: the per-row start loop; per survivor in `checkCrashes`; per slice, volume script and
    snapshot in `unorderedSurvivors`; per crash in `enumerateUnordered`. The crash-point loop already yielded once per
    point, at the end of the iteration, and the yield now opens the iteration. The fault loops already yielded once
    per case.
  - `FakeFileSystemCrashTests`: both crash-point enumerations become `async`, only so that they can yield once per
    crash point.

  No assertion, trait, time limit or case count changed. Rejected alternatives: raising the time limit or excluding the
  test (forbidden, G3), and a shared gate that caps how many heavy cases run at once. Under a gate, the waiting cases'
  own one-minute limits would keep running, and the state-space rows already take about 53 s of a full run.
- **Evidence.** The R-STO-9 duration in each full run, with every run green:

  | Run | Commit | Host 1-min load (start → end) | R-STO-9 |
  |---|---|---|---|
  | before the fix, cycle 1 | `b671ea2` | not recorded | 6.161 s |
  | before the fix, verifier | `122a22e` | ~88 | **failed, 73.261 s** |
  | 1 | `b6e23a2` | → 82.9 | 1.502 s |
  | 2 | `6a51450` | 5.2 → 42.7 | 2.263 s |
  | 3 | `6a51450` | 39.4 → 36.1 | 1.269 s |
  | 4, **loaded** | `6a51450` | 30.9 → 238.3, peak 262.7 | 6.188 s |
  | 5 | `6a51450` | 31.2 → 50.1 | 1.400 s |
  | 6 | `6a51450` | 50.1 → 37.8 | 1.099 s |

  Runs 2–6 are five consecutive green full runs on the final code. The commit after them changes only this file. During
  run 4, 24 `yes > /dev/null` processes and a concurrent macOS `verify.sh --quick` loaded the host, on top of the other
  agents' work. That run took 348 s instead of about 146 s, and its macOS `--quick` also ended `VERIFY: PASS`. The
  burners were started and killed by PID. On macOS, R-STO-9 took 1.705 s in the first full `--quick` after the fix.

## Item 5 — The loopback-only binding is pinned by tests (cycle 2)

Once `acceptLocalOnly` was gone, only `requiredLocalEndpoint` 127.0.0.1 kept the server loopback-only, and no test
pinned that. The listener's parameters move into `LoopbackHTTPServer.listenerParameters()` (internal), and two tests in
`LoopbackHTTPServerTests` pin them:

- `listenerIsLoopbackOnly` asserts that the listener is bound to 127.0.0.1 on `.loopback`, with
  `acceptLocalOnly == false`.
- `otherLocalAddressIsRefused` connects to the server's port on `::1`. It asserts that the connection is refused
  ("Connection refused") and never reaches the server, while a 127.0.0.1 client on the same port is served.
  `LoopbackRawClient` gains `init(host:port:)` for this probe. The test assumes the host's `lo0` carries `::1`, as
  macOS and the simulator do.

Mutation check on macOS: with the `requiredLocalEndpoint` line deleted, both tests fail. The first fails on the
endpoint, and the second fails with "an error was expected but none was thrown" and 2 accepted connections. The file
was restored afterwards. A probe of a LAN address (via `getifaddrs`) was not used, because it needs mutable pointers
(CLAUDE.md C1). `::1` shows the same thing (the listener is bound to one address, not every address) without them. Both
tests pass on the simulator (runs 2–6).

## iOS-only exclusions

**None.** No test is excluded, skipped, or conditioned on the platform. Every test in every `*Tests` target builds and
runs on the iOS Simulator. The tests that reach the repository through `#filePath` work unchanged, because a simulator
process can read and write host paths: the source scans (`SingleAvailabilityScanTests`, `PackageScanContractTests`,
`SourceScan`), the manifest fixtures (`Tests/Fixtures`), and the live store tests, which create their directories
under the worktree's git-ignored `.build-tests/storage-core/` (`CoreFixture.liveDirectory`) exactly as on macOS.

## Commands

From the worktree, with `TMPDIR` and `LLVM_PROFILE_FILE` pointing into the agent's scratch path:

```
# the library, generic iOS device
xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath .build-ios/xcode build \
  OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet
# every test target on one simulator (the Benchmarks bundle is built, not run); agent runs skip the up-to-600 s
# diagnostics collection after a failure (item 3)
xcodebuild test -scheme ZTronAssetKit -destination 'platform=iOS Simulator,id=<UDID>' \
  -derivedDataPath .build-ios/xcode-sim -skip-testing:ZTronAssetKitBenchmarks -collect-test-diagnostics never \
  OTHER_SWIFT_FLAGS='-warnings-as-errors'
# the result
xcrun xcresulttool get test-results summary --path .build-ios/xcode-sim/Logs/Test/<bundle>.xcresult
```

Running tests on a simulator installs the test host and bundles into that device's container under
`~/Library/Developer/CoreSimulator` and writes there while they run (the host app's data, caches and logs). The owner
accepted this for this task. Use one named simulator per agent, never the owner's booted one, and
shut it down afterwards (`xcrun simctl shutdown <UDID>`).

## Evidence (this branch, 2026-10-09)

Cycle 2, on `6a51450`. The docs commit after it changes only this file.

- iOS Simulator (iPhone 18 Pro, iOS 27.0), `xcodebuild test` (command above): five consecutive full runs (2–6 in the
  item 4 table), each `** TEST SUCCEEDED **` with exit 0, and each xcresult summary
  `{'result': 'Passed', 'totalTestCount': 669, 'passedTests': 669, 'failedTests': 0, 'skippedTests': 0}`. No
  "Restarting after", "Time limit was exceeded" or "exceeded execution time" line appears in any of the five logs. By
  bundle: AppleHosted 104, Compatibility 3, Kit 12, Model 84, Storage 305 (the 303 of cycle 1 plus item 5's two),
  Sync 10, Transport 151. `ZTronAssetKitBenchmarks` builds as part of the test action. Run 4 ran with the host under
  load (peak 1-min load average 262.7).
- iOS library build (`generic/platform=iOS`, `-warnings-as-errors`): exit 0, no errors or warnings.
- macOS `SWIFTPM_SCRATCH=.build-ios bash Scripts/verify.sh --quick`: `VERIFY: PASS` (Storage 305 tests, R-STO-9 in
  1.796 s).
- `gates.py unsafe`: `UNSAFE escapes found=0 max=3`, `UNSAFE: PASS`. `gates.py docs`:
  `DOCS public declarations=1281 documented=1281 exempt=0 fraction=100.0%`, `DOCS: PASS`.
- Cycle 1 (on `b671ea2`, for the record): 667/667 on the simulator, with macOS `--quick` `VERIFY: PASS`.
