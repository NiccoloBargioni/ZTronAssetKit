# Stage 3 close-out `s3ah` — WP-A (model) and WP-H (test support): dispositions

Branch `wp/s3ah`, from tag `s3-base`. Inputs: the orchestrator's rulings
(`.build-orchestrator/s3-rulings-s3ah.md`, authoritative) and the findings file
(`.build-orchestrator/s3-findings-s3ah.json`, 16 entries, none blocking). Background: WP-A's Stage 2 record
`docs/adr-drafts/a.md`, WP-H's `docs/adr-drafts/h.md`. Commits: failing tests first (`1a41f29`), then one fix per
item (CLAUDE.md P3): S3AH-1 `dea6d83`, S3AH-2 `af7c0d1`, S3AH-3 `87d108c`, S3AH-4 `8b2e979`, S3AH-5 `a4a7542`, and
this record.

## Orchestrator rulings (close-out)

The rulings file calls each of these an "Orchestrator ruling (Stage 3)"; they are recorded here as received.

- **Orchestrator ruling (close-out) S3-R1, scope and order.** Blocking items first, then REQUIRED, then OPTIONAL; an
  ADR-RECORD item gets an entry and no code. This close-out has no blocking item: S3AH-1…S3AH-5 are REQUIRED, S3AH-6
  is ADR-RECORD. All five REQUIRED items are fixed; S3AH-6 is recorded below.
- **Orchestrator ruling (close-out) S3-R2, probes.** Probes are evidence. The hunter's `S3-SECU-02.swift` and
  `S3-SECU-03.swift` cases were adapted into WP-A's own suites (`ManifestValidationTests`, `ModelBehaviourTests`);
  no `S3…Probe` suite is committed, and no replay of an old ordering.
- **Orchestrator ruling (close-out) S3-R3, mutation survivors.** None is assigned to this close-out.
- **Orchestrator ruling (close-out) S3-R4, hang guards.** Applied to S3AH-5 only (measurements below). No other
  test's limit changed.
- **Orchestrator ruling (close-out) S3-R5, C2 at the reference scale.** No item of this close-out holds an actor
  turn; no actor and no `await` inside an actor changed, so no REENTRANCY row is proposed.
- **Orchestrator ruling (close-out) S3-R6, shared files.** No public or package signature changed. Contract files
  changed only where authorised (S3AH-2: `Identity/TransferID.swift`; S3AH-3: `Environment/Time.swift`), bodies plus
  the one `///` precision listed under "Proposed document changes". `Identity/StagingFileName.swift` was authorised
  and did not need a change. No edit of `Package.swift`, `Scripts/`, `SPEC.md`, `docs/ARCHITECTURE.md`,
  `docs/DECISIONS.md`, `docs/TRACEABILITY.md`, `docs/ORCHESTRATION.md`, `README.md`, `docs/MIGRATION.md` or any
  `*ContractTests.swift`.
- **Orchestrator ruling (close-out) S3-R7, parallel close-outs.** Nothing here depends on another work package's
  Stage 3 change. One finding's second half lies in WP-D's file and is routed as `other-wp:d` (S3AH-1).
- **Orchestrator ruling (close-out) S3-R8, strict bar.** Kept. Pre-existing behaviour that a recorded ADR accepts is
  recorded under S3AH-6, not changed.
- **Orchestrator ruling (close-out) S3-R9, records.** This file.
- **Orchestrator rulings (close-out) S3AH-1 … S3AH-6.** Each has its entry below.

## S3AH-1 — S3-SECU-02: the decoder quarantines every remote path the transport refuses (REQUIRED) — fixed

- **Finding.** `RemoteURL.make` (WP-D, `Sources/ZTronAssetTransport/Policy/RequestFactory.swift:72`, ADR draft D-6)
  refuses an empty component, a component that percent-decodes to `.` or `..`, and any `?`, `#` or `\`. Fix round 3
  made the Model quarantine `?` and `#` for that reason, but the decoder still accepted `media//a.png`,
  `media/./a.png`, `./a.png`, `media/%2E/a.png`, `media\a.png` and `media/`: such an entry was planned and then
  failed at once on every run (`failed(.nextRun)`, waiters answered `.serverUnavailable(retryAfter: nil)`).
- **Decision.** One rule, in the Model (`ManifestRules.visitRemotePathViolations`, shared by the streaming parser
  and `ManifestDecoder.violations(of:limits:)`): a path is also refused when it contains a `\` anywhere, or a
  `/`-separated segment that is empty (`a//b`, a trailing `/`) or `.` (`./a`, `a/./b`, also `%2E`, `%2e`). These are exactly the transport's refusals that the Model did not already make; a `..` that percent-decodes
  to `..` was already `parentSegment` (A-4.7). The empty and `.` checks read `/`-separated segments only, like the
  transport's split: a percent-encoded slash or backslash (`%2F`, `%5C`) is a literal character to the transport,
  which accepts it, so `a/%2E%2Fb` and `a/%5Cb` stay accepted (the `..` check keeps treating them as separators, A-4.7,
  where the Model is stricter by design). The transport keeps its own check as defence.
- **Which diagnostic.** The ruling says "as the existing per-entry path violation, quarantined":
  `ManifestEntryViolation.remotePathInvalid(_)`. `RemotePathViolation` has no case for these spellings, and adding one
  changes a public enum (S3-R6 forbids it). They are reported as `.parentSegment`, the rule for segments that do not
  name a child of the path before them (RFC 3986's dot-segments, plus the empty segment and the `\` separator that
  some origins normalise away). The slashes that `.absolute` and `.authority` already report are not counted again:
  `/abs` stays `[absolute]`, `//cdn.example/x` stays `[authority, absolute]`, `https://evil/x` stays
  `[scheme, authority]`; `///x` is `[authority, absolute, parentSegment]` (one more, empty, segment), `a/?x` is
  `[parentSegment, queryOrFragment]`. A dedicated case is proposed below for a later contract round.
- **Cost.** The pass is unchanged for ordinary bytes (one table load); at a `/` it compares at most three bytes, and
  a `\` ends the pass. R-MAN-3's figures are re-measured by the fuzz test and P-3 (Evidence).
- **Pre-existing tests updated (WP-A's own, not CDN tests; MIGRATION.md does not apply).**
  - `R-MAN-2: remotePath must be relative, without parent segments, scheme, authority, control characters, query or
    fragment`: `a/./b` moved from the accepted list to the rejected list (`[parentSegment]`), as the ruling requires;
    added accepted `a/.b/c.`, `a/%2E.png`, `a/%2E%2Fb`, `a/%5Cb` and rejected `///x`, `https:///x`, `a/?x`. No
    expectation weakened.
  - `R-MAN-2: rules and identifier hashing see the same bytes in bridged and native strings`: its bridged path is
    `"p/"` × 600, which ends with `/`; the exact expected list gained `.remotePathInvalid(.parentSegment)` (the rule
    now sees the bridged bytes' empty last segment too). Stricter, not weaker.
- **Tests added** (`Tests/ZTronAssetModelTests/Manifest/ManifestValidationTests.swift`):
  - `R-MAN-2: a remote path with an empty or dot segment (also %2E), a backslash or a trailing slash is quarantined,
    the rest applied` — 14 cases (`media//a.png`, `media/./a.png`, `./a.png`, `media/%2E/a.png`, `media/%2e/a.png`,
    `media\a.png`, `media/`, `media/a.png/`, `.`, `%2E`, `a/.`, `\a`, `a\`, `a/.?v=1`): `violations(of:)`, the
    decoded manifest's entries (`["ok"]`), `quarantinedCount == 1` and the exact `QuarantinedEntry`.
  - `R-MAN-2: over seeded remote paths the decoder accepts only paths the transport can fetch, exactly so without
    schemes, queries or encoded separators` — 8,000 seeded paths (seed `0x5EED_5EC0_0002`): over names, dots, `%2E`
    and `\` the decoder accepts exactly what `transportAccepts` (the transport's join rule restated: the Model's test
    target cannot import the transport) accepts; with `:`, `?`, `#`, `%2F`, `%5C`, `%3F`, `%` and `//` mixed in, every
    accepted path is one the transport accepts. Both outcomes occur (`acceptedByBoth > 100`, `refusedByBoth > 1,000`).
- **Evidence.** Before the fix (`1a41f29`, the fix not applied):
  `✘ Test "R-MAN-2: a remote path with an empty or dot segment (also %2E), a backslash or a trailing slash is
  quarantined, the rest applied" with 14 test cases failed after 0.004 seconds with 54 issues.`,
  `✘ Test "R-MAN-2: over seeded remote paths the decoder accepts only paths the transport can fetch, …" failed after
  0.084 seconds with 2122 issues.`, and `✘ Test "R-MAN-2: remotePath must be relative, …" failed after 0.001 seconds
  with 4 issues.` (for the argument `"media//a.png"`: the `violations(of:)` comparison, `manifest.entries.map(\.identifier) ==
  ["ok"]` and `manifest.quarantinedCount == 1` all failed). After
  the fix (`dea6d83`): every Model test passes (Evidence below).
- **Routed (`other-wp:d`, non-blocking).** WP-D's `RemoteURL` doc says "The Model already rejected absolute paths,
  schemes, authorities, `..`, control characters, `?` and `#`"; it may add empty segments, `.` and `\`. A transport
  test that feeds decoder-accepted paths to the real `RemoteURL.make` (the confirmer's
  `.build-orchestrator/s3-probes/confirm-security/S3-SECU-02.swift`) would pin the agreement from WP-D's side.

## S3AH-2 — S3-SECU-03: staging names and attempt tokens parse only canonically (REQUIRED) — fixed

- **Finding.** `TransferAttempt(token:)` accepted leading zeros, so `c-<h>.01-2.part` parsed as `c-<h>.1-2.part`,
  another file: `StagingCollection.garbage` kept a fresh one under the age rules instead of removing it as foreign,
  and two directory entries collapsed onto one inventory key.
- **Decision.** `TransferAttempt(token:)` accepts each part only as ASCII digits without a leading zero, or `0`
  alone, the spelling `token` writes (a local closure in the init's body; no member added). With `TransferID`
  keeping its exact text and `StagingFileName.Kind` its raw value, a parsed name's `rawValue` is the parsed text, so
  `StagingFileName(parsing:)` is again "nil for anything that is not exactly one of our names" without a change of
  its own (`Identity/StagingFileName.swift` untouched). `BackgroundTaskTag(decoding:)` (WP-D), which parses staging
  names, inherits the fix. The confirmer refuted the finding's other half: `TransferID(rawValue:)` accepting any
  `c-[a-z0-9-]*` is its documented contract (1…96 bytes of `[0-9a-z-]` with a known prefix), and such names
  round-trip; it stays.
- **Tests added** (`Tests/ZTronAssetModelTests/ModelBehaviourTests.swift`):
  - `R-SEC-2: staging names and attempt tokens parse only in the canonical spelling the module writes` — 7 tokens
    (`01-2`, `1-02`, `00-0`, `0-00`, `007-1`, `1-0010`, `00000000000000000001-1`), each refused as a token and inside a
    staging name of every `Kind`.
  - `R-SEC-2: every staging name that parses round-trips to the same file name, and every attempt token to the same
    text` — the canonical edges (`0-0`, `10-20`, `UInt64.max-UInt32.max`), `c-zz.1-2.part`, and 20,000 seeded strings
    over `[0-9-]` (seed `0x5EED_5EC0_0003`): each that parses has `token` equal to the text and its staging name's
    `rawValue` equal to the file name; more than 1,000 parse.
- **Evidence.** Before the fix: `✘ Test "R-SEC-2: staging names and attempt tokens parse only in the canonical
  spelling the module writes" with 7 test cases failed after 0.005 seconds with 42 issues.` and `✘ Test "R-SEC-2:
  every staging name that parses round-trips …" failed after 0.068 seconds with 456 issues.` After (`af7c0d1`): pass.

## S3AH-3 — S3-B-104, L4-R24(2): `ManualTimeSource.advance(to:)` lands exactly (REQUIRED) — fixed

- **Finding.** `advance(to:)` converted the gap to seconds (`seconds(since:)`) and moved by `advance(by:)`, whose
  `MonotonicInstant.adding(seconds:)` truncated `seconds × 1e9`: about 3 % of gaps landed 1 ns short, and a sleeper
  at exactly the target stayed asleep.
- **Decision.** Two changes. (1) WP-H: `advance(to:)` moves in nanoseconds under the lock: monotonic time becomes the
  target (when later), awake time moves by the same nanoseconds (saturating), the wall clock by the gap in seconds,
  and due sleepers wake as before; an earlier target moves nothing (`advanceToThePastIsANoOp` unchanged). Exact for
  every gap. (2) WP-A, the authorised body of `Environment/Time.swift`: `adding(seconds:)` rounds to the nearest
  nanosecond instead of truncating, so `a.adding(seconds: b.seconds(since: a)) == b` for every gap below 2^50 ns
  (13 days; each of the two floating-point roundings has relative error at most 2^-53, so the total stays under
  0.5 ns). Saturation, NaN, zero and negative handling are unchanged (`MonotonicInstant.adding saturates …`, the
  contract test, passes unchanged). Production deadlines move by at most half a nanosecond, now without a
  systematic low bias.
- **Tests added.**
  - `Tests/ZTronAssetModelTests/ModelBehaviourTests.swift`: `R-ENV-1: adding the seconds between two instants lands
    exactly on the later one for every seeded gap below 2^50 ns` — 20,005 gaps (seed `0x5EED_0000_0104`, magnitudes
    2^1…2^50 plus edges), each from a random start below 2^62.
  - `Tests/ZTronAssetStorageTests/TestSupport/ManualTimeSourceTests.swift`: `R-ENV-1: advance(to:) lands exactly on
    the target instant, moves the awake clock by the same nanoseconds and wakes a sleeper there` — 2,004 seeded gaps
    up to 2^60 ns (same seed): monotonic lands on the target, awake time moves by the gap, wall time by its seconds;
    for the first 64 a sleeper parked at exactly the target wakes (a sleeper left asleep is cancelled, so a miss
    fails instead of hanging). `@available(macOS 15.0, iOS 18.0, *)` on the function (ADR-051), `.timeLimit(.minutes(1))`,
    `Task.checkCancellation()` per gap.
- **Evidence.** Before the fix: `✘ Test "R-ENV-1: adding the seconds between two instants lands exactly on the later
  one for every seeded gap below 2^50 ns" failed after 0.010 seconds with 1 issue.` (`651 of 20005 gaps missed their
  target`) and `✘ Test "R-ENV-1: advance(to:) lands exactly on the target instant, …" failed after 0.017 seconds with
  450 issues.` After (`87d108c`): pass. The ruling's whole-suite run (no test relied on the 1 ns shortfall) is under
  Evidence.

## S3AH-4 — S3-B-006, OI-13: the fuzz test's linear-time check on an efficiency core (REQUIRED) — fixed

- **Finding.** `R-MAN-3: seeded fuzz …` compared one CPU-time sample of the 32 MiB dense manifest with 64 × one
  sample of the 1 MiB reference; it failed once (6.08 s against 5.86 s) when the samples ran on different core types.
- **Decision.** Each side keeps the lowest of up to three samples (`ManifestFuzzTests.lowestDenseCPU`): the 1 MiB
  reference is decoded three times first, which fixes the bound and can only tighten it (a lower minimum, never a
  looser one than the single sample before); the limit side starts from the case's own measurement and is decoded
  again, at most twice, only while its lowest sample is over the bound, since another sample could only lower it.
  The verdict is that of three samples per side; the 64x ratio (`linearTimeRatio`) is unchanged, and the samples are
  printed and named in the failure message. A QoS pin was not used: a thread's QoS steers but does not bind it to a
  performance core, and the cooperative pool's threads are not this test's to re-prioritise.
- **Test changed.** `R-MAN-3: seeded fuzz of random, truncated, mutated and deeply nested manifests never traps, and
  outside Thread Sanitizer stays within 4x the payload in linear time` (same display name, same cases, same bounds).
- **Evidence.** Below (its `R-MAN-3 linear time:` line from this session's runs).

## S3AH-5 — S3-B-107: `startRacingStop` under Thread Sanitizer (REQUIRED) — S3-R4 applied

- **Finding.** `Test support: start racing stop ends every start exactly once, with a port or stopped, and never
  hangs` (`LoopbackHTTPServerTests.swift:400`, one-minute limit) took 36–42 s under TSan in whole-target runs at
  loads around 7–11 (WP-C's cycles, `c.md`), more than half its limit, and overran it at loads of 17–834.
- **Measurements** (whole `ZTronAssetStorageTests` target under TSan, this Mac, this session).
  - Load 7.3 at the start and 20.9 at the end, two other agents' test processes running at the start: **41.342 s**
    (`✔ Test "Test support: start racing stop …" passed after 41.342 seconds.`, with the new guard; the target ran 460
    tests in 446.108 s, 0 `ThreadSanitizer` lines). That is more than half of one minute on a moderately loaded host.
  - Load 168.9 at the start (peaking at 223 while another agent's simulator booted) and 50.4 at the end, with the
    one-minute guard still in place: `✘ Test "Test support: start racing stop …" failed after 64.842 seconds with 1
    issue.` (`Time limit was exceeded: 60.`). Not a moderate load; recorded because it also shows the new per-round
    cancellation check ending the run 4.8 s past the limit instead of letting it finish its rounds.
  - Earlier records at moderate load: 36.107 s, 38.575 s, 41.367 s (load 10.9 → 7.3) and 42.519 s (WP-C's L3
    close-out cycles, `docs/adr-drafts/c.md` Evidence); 30.06 s at about 10 (`l2fu.md` item 2). Alone, about 0.25 s.
- **Decision (S3-R4).** The hang guard is raised to `.minutes(3)`; the 400 rounds, their yields (0…399 per round)
  and the assertions are unchanged (G3). Each round now starts with `try Task.checkCancellation()`, so a run past its
  limit ends at the next round. The cause is unchanged from `l2fu.md` item 2 (the yields queue behind every other job
  on the cooperative pool); making each round cheaper would mean fewer yields, which spread the stop over the
  listener's start-up, so they stay. The test's doc comment records the guard and why.

## S3AH-6 — ADR-RECORD items (no code)

Each stays as recorded; NEEDS-HUMAN-REVIEW items stay as ratified.

- **S3-B-105 — declined for Stage 3 (contract change).** `FakeFileSystem` treats `.barrier` and `.full` alike and
  `FSOpRecord` carries no `SyncLevel` (`Sources/ZTronAssetTestSupport/FakeFileSystem.swift:53-75`, documented at
  `:355-356`), so ordered-versus-durable commits are proven by reading only (OI-2). A level-recording spy or an
  `FSOpRecord` level changes a public test-support type; the ruling declines it for Stage 3. Evidence: ADR-049 (fake
  fidelity limits), ADR-053 "Not verified".
- **S3-B-106 — accepted deviation, documented on the types.** `FakeTransferBackend` retains every handle (drop-to-cancel
  is observable through `FakeRemoteSource` only); the conformance suite creates its symbolic-link fixture with
  `FileManager` (accepted exception to ADR-038). ADR-049. No change.
- **S3-B-108 — not probed, recorded.** The loopback server's refusal of a LAN address is pinned through the `::1`
  probe, which assumes `lo0` carries `::1`; a `getifaddrs` probe needs mutable pointers (C1). ADR-051 "Not verified",
  `ios.md` item 5. Stays under "Not verified here".
- **S3-B-007 — kept by ruling (OI-8).** The allocation tests read process-wide heap figures and rely on
  `Array`/`Dictionary` layout and `malloc_size` of reused blocks, checked on macOS 27 and the iOS 27 simulator only.
  ADR-052 (OI-8 audit), `c.md`. No change.
- **S3-B-001 — NEEDS-HUMAN-REVIEW, as ratified.** R-MAN-1 deviation: UTF-16/UTF-32 manifests are `notJSON` (A-4.5);
  the owner confirms no published manifest is UTF-16. ADR-049. No change.
- **S3-B-002 — NEEDS-HUMAN-REVIEW, as ratified.** The R-OBS-1 interval seam (`LogIntervalName`, `LogRoute.interval`,
  `LogInterval`) is a public API addition awaiting the owner (A-7, ADR-049). No change.
- **S3-B-003 — accepted (A-8).** Entry-dense manifests (entry array over 2 MiB at about 111 bytes per entry) are
  `decodedSizeExceeded` by the 3.75x allocation bound; realistic catalogs (250–350 bytes per entry) are unaffected.
  No change.
- **S3-B-004 — device-only, not verified.** R-MAN-3's allocation bound was measured on macOS 27 and the iOS 27
  simulator; device allocators are unverified (A-8, A-14 #3). For `DEVICE-TEST-PLAN.md` (Stage 5).
- **S3-B-005 — documentation, for Stage 5.** R-MAN-3's 1 s bound is asserted by the release P-3 benchmark (and the
  fuzz test when optimised); debug and TSan runs assert linear scaling only (A-5). `VERIFICATION.md` and
  `TRACEABILITY.md` must say so.
- **S3-B-008 — declined for now.** `ManifestEntryViolation.duplicateIdentifier`, `ManifestLimits.maxPathComponents`
  (the cap stays the internal 32) and a hashed log description (`AssetLog.describe`) are not added (A-11.2, A-11.3,
  A-11.7; ADR-049). No change.
- **S3-B-009 — accepted, for the device plan.** `AssetEnvironment.live()` supplies no memory-pressure source
  (`memoryPressure` is optional, default `nil`), so on a device a memory warning purges nothing (R-CLN-11) unless the
  app supplies a UIKit source. ADR-056 (WPI-R3). For `DEVICE-TEST-PLAN.md` (Stage 5).

## Authorised edits outside WP-A and WP-H

None outside the two work packages' paths. Inside them, the contract files the rulings authorised:
`Sources/ZTronAssetModel/Identity/TransferID.swift` (S3AH-2: `TransferAttempt.init?(token:)`'s body and its `///`
line) and `Sources/ZTronAssetModel/Environment/Time.swift` (S3AH-3: `MonotonicInstant.adding(seconds:)`'s body only).
No signature changed.

## Proposed document changes (for the orchestrator at the Stage 3 merge)

1. `DECISIONS.md` ADR-049, A-4.7: "`.` … stay allowed" is superseded: an empty or `.` (also `%2E`) `/`-separated
   segment and any `\` are `RemotePathViolation.parentSegment` (S3AH-1), after the slashes `absolute` and
   `authority` report; `%2F` and `%5C` stay literal to this rule.
2. `Sources/ZTronAssetModel/Manifest/ManifestError.swift` (contract file, not authorised here): `RemotePathViolation.
   parentSegment`'s `///` "Contains a `..` segment." could read "Contains a segment that does not name a child of the
   path before it: `..` or `.` (also percent-encoded), an empty segment, or a `\` (the transport refuses each on every
   fetch)". A dedicated case (for example `.unfetchableSegment`) is a contract change for a later round.
3. `TransferID.swift`: ratify the `///` precision of `TransferAttempt.init?(token:)` ("in the canonical decimal form
   `token` writes (no sign, no leading zero)"), made with the authorised body change.
4. `ARCHITECTURE.md` §2 (Time): `MonotonicInstant.adding(seconds:)` rounds to the nearest nanosecond, and
   `ManualTimeSource.advance(to:)` lands exactly on its target (L4-R24(2) closed; ADR-053's assignment).
5. `ARCHITECTURE.md` §12 / backlog: S3-B-104 (L4-R24(2)), S3-B-006 (OI-13) and S3-B-107 closed by this close-out;
   S3-SECU-02 and S3-SECU-03 fixed.
6. `other-wp:d` (non-blocking): the `RemoteURL` doc line and transport-side agreement test under S3AH-1.
7. `TRACEABILITY.md`: regenerated by the orchestrator (this branch restores it).

## Not verified here

- Device behaviour of every changed line (simulator and macOS only); S3-B-004 and S3-B-009 are device-plan items.
- S3-B-108 (the LAN-address refusal is not probed).
- S3-B-105 (ordered-versus-durable commits are proven by reading, not by a test).
- The transport side of S3AH-1 is checked in this branch only through the restated rule in the Model's test; the
  real `RemoteURL.make` agreement test belongs to WP-D (routed above).

## Evidence

All runs in this session, in the worktree, scratch paths `.build-s3ah`, `.build-s3ah-tsan`, `.build-s3ah-perf`
(TMPDIR, module cache and profiles under `.build-s3ah/tmp`). The host was shared with other agents; loads are given.

- **`SWIFTPM_SCRATCH=.build-s3ah bash Scripts/verify.sh --quick`** (all fixes applied; load 33.8 → 10.6):
  `::: SUMMARY mode=--quick steps-failed=0` and `VERIFY: PASS`. Per target: Transport `✔ Test run with 151 tests in
  16 suites passed`, Sync `351 tests in 52 suites`, Storage `460 tests in 60 suites`, Model `89 tests in 18 suites`,
  Kit `85 tests in 11 suites`, Compatibility `71 tests in 10 suites`, Apple-hosted `104 tests in 14 suites`. This is
  S3AH-3's whole-suite run: no test relied on the 1 ns shortfall (nor, S3AH-1, on a decoder-accepted empty or `.`
  segment or backslash). The coverage run below passed the whole suite a second time.
- **Release build** `swift build -c release --scratch-path .build-s3ah -Xswiftc -warnings-as-errors`:
  `Build complete! (49,48 s)`, 0 warnings.
- **Gates.** `python3 Scripts/gates.py unsafe …`: `UNSAFE escapes found=0 max=3`, `UNSAFE: PASS`.
  `python3 Scripts/gates.py docs …`: `DOCS public declarations=1281 documented=1281 exempt=0 fraction=100.0%`,
  `DOCS: PASS`.
- **Coverage** (`swift test --enable-code-coverage --skip Benchmarks`, all seven targets passed; export over 8 bundles):
  `COVERAGE target=ZTronAssetModel lines= 99.32% (3383/3406) min=70.0 OK`, overall `96.58% (25189/26082)`,
  `COVERAGE: PASS`. Changed files: `ManifestRules.swift` 326/326, `TransferID.swift` 105/105, `Time.swift` 47/51
  (the four uncovered lines are `LiveTimeSource`'s: `now()`, A-12, and the end of a live sleep that ran to its
  deadline, which no test takes), `ManualTimeSource.swift` 451/454 (lines 103, 243, 244, none of them changed here).
- **`ZTronAssetModelTests` × 3** (debug): `✔ Test run with 89 tests in 18 suites passed after 85.214 seconds.` (load
  25.7), `… after 60.866 seconds.` (12.5), `… after 102.371 seconds.` (23.1). S3AH-4's samples:
  `R-MAN-3 linear time: dense 1 MiB samples [0.089218583, 0.089821417, 0.092232333] s, limit samples [2.949464833] s`,
  `[0.08944825, 0.089093625, 0.089672792]` / `[2.955981041]`, `[0.089800625, 0.090917875, 0.091909291]` /
  `[2.915704084]` (about 33x, under 64x on the first limit sample each time); in the `--quick` run at load 33.8,
  `[0.204761125, 0.206732, 0.206317791]` / `[6.433017]`.
- **`ZTronAssetModelTests` under TSan** (once): `✔ Test run with 89 tests in 18 suites passed after 178.908 seconds.`,
  0 `ThreadSanitizer` lines (load 18.4 → 40.2).
- **`ZTronAssetStorageTests` under TSan**: S3AH-5's measurements above (the moderate-load run passed all 460 tests,
  0 `ThreadSanitizer` lines).
- **Benchmarks the work packages own** (`swift test -c release --scratch-path .build-s3ah-perf -Xswiftc
  -enable-testing --filter ModelBenchmarks`; WP-H owns none; load 19.0 → 179.1): `P-3 reference 3283455 bytes: p50
  30.81325 ms, max 33.862208 ms, budget 80.0 ms`; at the limit the worst case was `529.676792 ms, threshold
  817.5396221358295 ms`; `✔ Test run with 2 tests in 2 suites passed after 38.412 seconds.`
- **iOS build** `xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' … OTHER_SWIFT_FLAGS='-warnings-as-errors'
  -quiet`: exit 0, no `error:` or `warning:` line (the only output is Xcode's `IDERunDestination: Supported platforms
  for the buildables in the current scheme is empty.` notice).
- **iOS Simulator tests** (ADR-051; `caffeinate -i xcodebuild test -scheme ZTronAssetKit -destination 'platform=iOS
  Simulator,id=02CE21B4-F307-4CB7-B80A-1F2EF72F115C' -derivedDataPath .build-s3ah/xcode-sim
  -skip-testing:ZTronAssetKitBenchmarks -collect-test-diagnostics never OTHER_SWIFT_FLAGS='-warnings-as-errors'`, this
  close-out's own simulator, iPhone 17e, iOS 27.0; load 252.6 at the start, 785.4 at the end): `** TEST SUCCEEDED **`;
  `xcrun xcresulttool get test-results summary` on `Test-ZTronAssetKit-2026.10.29_23-37-42-+0100.xcresult`:
  `result Passed`, `totalTestCount 1311`, `passedTests 1311`, `failedTests 0`, `skippedTests 0` (the seven targets'
  151 + 351 + 460 + 89 + 85 + 71 + 104). The simulator was shut down afterwards (`simctl` reports `Shutdown`).
- **`docs/TRACEABILITY.md`**: `--quick` left it unchanged (`git status` showed only this draft); `--gates-only` and
  `--full` were not run.
