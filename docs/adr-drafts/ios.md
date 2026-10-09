# iOS Simulator test build, cycle 1 — dispositions (`wp/ios`)

Owner request, not a SPEC work package: the owner runs the unit tests in Xcode on an iOS Simulator and they did not
build. This branch makes every test target build under `-warnings-as-errors` and pass on the iOS Simulator, keeps the
macOS run green, and leaves the package floors (iOS 15.0, macOS 12.0) unchanged. The orchestrator numbers what follows
into `DECISIONS.md` at merge. Commits, in order, on `48271e7`:

| Commit | What |
|---|---|
| `b9f2752` | the owner's own edits, applied verbatim: `iOS 26.0` beside `macOS 26.0` on the Apple-tier tests (item 1) |
| `7b0ead0` | availability attributes only: `iOS 18.0` beside every `macOS 15.0` test gate, and the two TestSupport doc comments that state the convention (item 2) |
| `b671ea2` | runtime fix: the loopback server no longer sets `acceptLocalOnly`, which the simulator enforces by resetting loopback connections (item 3) |
| this file | the dispositions |

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
     `.timeLimit` included. Anything newer needs the pair of clauses for the release that ships it.
  5. `ZTronAssetTestSupport` is a library target and builds at the package floors (macOS 12.0 / iOS 15.0): every
     declaration there that uses a newer API carries both clauses, and Swift Testing traits stay out of it.
  6. No `#available` in `Sources/` (R-APL-5: `SingleAvailabilityScanTests` counts exactly one).
  7. The check is the simulator build below; a work package that adds tests runs it (or at least
     `build-for-testing`) before hand-off.
- **TestSupport gates.** Every gated declaration in `Sources/ZTronAssetTestSupport` already carried `iOS 18.0`. The two
  places whose gate lacked the iOS clause were the doc comments that tell tests how to gate
  (`FakeFileSystem.swift:351`, `ManualTimeSource.swift:8`); both now say `@available(macOS 15.0, iOS 18.0, *)`.
- **Scope of `7b0ead0`.** 480 attributes in 63 test files (the `*ContractTests.swift` edits are availability
  attributes only, as authorised), 2 doc comments, 1 blank line. No test body, assertion, trait or floor changed.

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
  `acceptLocalOnly` among the server's parameters; amend them at merge. Also observed only in the broken run: after
  the Transport bundle reported its result, the test process did not exit, and `xcodebuild` restarted it ("Restarting
  after unexpected exit, crash, or test timeout") and spent about 10 minutes in `simctl diagnose`. It did not recur
  once the server worked, and it was not investigated further (a candidate for a later look at what a failed
  loopback transfer leaves running).

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
# every test target on one simulator (the Benchmarks bundle is built, not run)
xcodebuild test -scheme ZTronAssetKit -destination 'platform=iOS Simulator,id=<UDID>' \
  -derivedDataPath .build-ios/xcode-sim -skip-testing:ZTronAssetKitBenchmarks OTHER_SWIFT_FLAGS='-warnings-as-errors'
# the result
xcrun xcresulttool get test-results summary --path .build-ios/xcode-sim/Logs/Test/<bundle>.xcresult
```

Running tests on a simulator installs the test host and bundles into that device's container under
`~/Library/Developer/CoreSimulator` and writes there while they run (the host app's data, caches and logs). The owner
accepted this for this task. Use one named simulator per agent, never the owner's booted one, and
shut it down afterwards (`xcrun simctl shutdown <UDID>`).

## Evidence (this branch, 2026-10-09)

- iOS Simulator (iPhone 18 Pro, iOS 27.0), `xcodebuild test`: `** TEST SUCCEEDED **`; xcresult summary
  `{'result': 'Passed', 'totalTestCount': 667, 'passedTests': 667, 'failedTests': 0, 'skippedTests': 0}`. By bundle:
  AppleHosted 104, Compatibility 3, Kit 12, Model 84, Storage 303, Sync 10, Transport 151. `ZTronAssetKitBenchmarks`
  builds as part of the test action.
- iOS library build (`generic/platform=iOS`): exit 0, no diagnostics.
- macOS `SWIFTPM_SCRATCH=.build-ios bash Scripts/verify.sh --quick`: `VERIFY: PASS`.
- `gates.py unsafe`: `UNSAFE escapes found=0 max=3`, `UNSAFE: PASS`. `gates.py docs`:
  `DOCS public declarations=1281 documented=1281 exempt=0 fraction=100.0%`, `DOCS: PASS`.
