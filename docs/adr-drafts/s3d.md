# Stage 3 WP-D close-out (`s3d`): transport

Stage 3 hardening, close-out cycle 1. Branch `wp/s3d` from tag `s3-base`, worktree `.worktrees/s3d`, scratch paths
`.build-s3d`, `.build-s3d-tsan`, `.build-s3d-perf`. The items and their levels come from the orchestrator's rulings
(`.build-orchestrator/s3-rulings-s3d.md`), their evidence from `.build-orchestrator/s3-findings-s3d.json`. WP-D's
Stage 2 record is `docs/adr-drafts/d.md`; the REENTRANCY rows cited here are those of ARCHITECTURE §10.4 (D-n) and
§10.2 (RE-Snn).

## Orchestrator rulings (close-out)

Recorded as given; each item below follows its ruling.

- **Orchestrator ruling (close-out) S3-R1, scope and order.** BLOCKING first (failing test committed on its own, then
  the fix), then REQUIRED, then OPTIONAL; an ADR-RECORD item gets an entry and no code; items not listed are out of
  scope. *Followed:* S3D-1 first (failing tests `b287a88`, fix `e7b9377`), then S3D-2 (failing tests `1e3bee2`, fix
  `fdf5a3d`), S3D-3, S3D-4, S3D-5; S3D-6 recorded only.
- **Orchestrator ruling (close-out) S3-R2, probes.** Probes may be copied and adapted; committed tests follow SPEC 7.2
  (requirement ID first, `.timeLimit` on anything that awaits, `ManualTimeSource` only, no sleeps, ADR-051 gating);
  probe suites are renamed into the owning suites; replays of a bug's old ordering are not committed. *Followed:* both
  S3-CONC-01 probes live in `BackgroundInterleavingTests`, the S3-CONC-02 probe in `BackgroundCoordinatorTests`; every
  new test is gated `@available(macOS 15.0, iOS 18.0, *)` on the `@Test` function (never on a suite) where it uses a
  Mutex-backed fake; no new test sleeps (the one sleeping probe of S3D-5 was evidence only and was deleted).
- **Orchestrator ruling (close-out) S3-R3, mutation survivors.** Write the missing test, re-apply the mutant in a
  scratch copy and paste the failing line. *Followed for M-N-22* (S3D-3).
- **Orchestrator ruling (close-out) S3-R4, hang guards.** `.minutes(1)` by default; long loops check `Task.isCancelled`.
  *Followed:* every new test keeps `.minutes(1)`; the control-task test cancels the awaited task when the test is
  cancelled, because `Task.value` ignores cancellation (without that, a timed-out case held the whole run: measured
  below, S3D-1).
- **Orchestrator ruling (close-out) S3-R5, C2 at the reference scale.** No item of this close-out holds an actor turn
  over 10 ms; no C2 benchmark was added.
- **Orchestrator ruling (close-out) S3-R6, shared files.** No public or package signature change, no edit of the listed
  shared documents; their changes are proposed below. *Followed:* see "Authorised edits outside WP-D".
- **Orchestrator ruling (close-out) S3-R7, parallel close-outs.** Edit only WP-D's files; depend on no other Stage 3
  change. *Followed.*
- **Orchestrator ruling (close-out) S3-R8, strict bar.** Findings in another work package's files are reported
  non-blocking with `other-wp:<wp>:`. *None arose.*
- **Orchestrator ruling (close-out) S3-R9, records.** This file: one entry per item, then "Authorised edits outside
  WP-D", "Proposed document changes" and "Not verified here".
- **Orchestrator ruling (close-out) S3D-1 [BLOCKING] S3-CONC-01**, **S3D-2 [REQUIRED] S3-CONC-02**, **S3D-3 [REQUIRED]
  M-N-22**, **S3D-4 [REQUIRED] S3-B-057**, **S3D-5 [REQUIRED] S3-B-055**, **S3D-6 [ADR-RECORD] S3-B-046…054, 056**: as
  quoted at the head of each entry below.

## S3D-1 [BLOCKING] S3-CONC-01: the newest background priority request wins, and a handle's controls arrive in order

*Ruling:* the newest request wins (a per-name serial taken before the first `await` and checked after it, cleared on
`.finished`), and a handle's controls are delivered in FIFO order (one stream per handle drained by one task, not a
`Task` per call); commit both probes as regression tests; propose the D-9 ledger amendment.

- **Disposition: fixed.** Failing tests first (`b287a88`), fix (`e7b9377`), control-task lifetime test (`0269a1a`).
- **Fix** (`Sources/ZTronAssetTransport/Background/BackgroundSupport.swift`):
  1. `BackgroundTransferCoordinator.setPriority(_:of:token:)` takes a serial from `lastPriorityRequest` and stores it
     in `priorityRequests[name]` before its first await (after the entry token check, so a stale handle never
     supersedes the current attach). After the listing it returns unless `priorityRequests[name]` is still its serial;
     the newest request then clears the entry and goes on with the existing token, processed and listing checks.
     `process(.finished)` also clears the entry, as ruled. Serials are unique for the coordinator's life, so a cleared
     entry never matches an older request.
  2. `BackgroundTransferHandle` no longer starts a `Task` per control. `attach` makes one unbounded control stream per
     attach; the handle yields `.priority`, `.pause` or `.cancel` into it, and one control task, started in the
     handle's `init`, delivers them in order, awaiting each coordinator call before the next. The coordinator keeps
     the stream's continuation in the attach's `Waiter` and finishes it wherever the attach ends (`Waiter.end(with:)`:
     terminal in `finishWaiter`, replacement in `attach`, `consumerGone`, and invalidation through `finishWaiter`);
     the handle's `deinit` finishes it too. The task captures the stream and the coordinator, never the handle.
- **Tests added** (display names):
  - `R-NET-10: the newest of two overlapping priority changes is the one a background transfer's OS task keeps`
    (`BackgroundInterleavingTests.newestPriorityChangeWins`, probe `concurrency/S3-CONC-01.swift`).
  - `R-NET-10: a newer promotion is kept over an older demotion whose listing returns later`
    (`newestPromotionWins`, probe `confirm-concurrency/S3-CONC-01-reverse.swift`).
  - `R-NET-10: a background handle's priority changes reach its OS task in the order the engine made them`
    (`handleControlsInOrder`, new: the first change is held after its listing, the second is made, a whole listing
    runs meanwhile and no change has reached the driver; after the release the driver sees `[0.75, 0.25]`).
  - `R-SYN-14: a background handle's control task ends with its attach, however the attach ends`
    (`BackgroundControlTaskTests`, 5 cases: terminal, replaced, consumerGone, invalidated, handleDropped; it awaits
    the handle's internal `controlTask` and then shows a later control reaches nothing).
- **Evidence, failing on `s3-base`** (`b287a88`, tests only; load average 1.6 to 12.6):
  ```
  ✘ ... "R-NET-10: the newest of two overlapping priority changes ..." ... Expectation failed: changes.last == 0.25
  ↳ the newest request was bulk (0.25), the OS task ends at Optional(0.75); changes [0.25, 0.75]
  ✘ ... "R-NET-10: a newer promotion is kept over an older demotion ..." ... Expectation failed: changes.last == 0.75
  ↳ the newest request was userInitiated (0.75), the OS task ends at Optional(0.25); changes [0.75, 0.75, 0.25]
  ✘ ... "R-NET-10: a background handle's priority changes reach its OS task in the order ..." ... Expectation failed: early.isEmpty
  ↳ a later change overtook the held one: [0.25]
  ✘ ... Expectation failed: changes == [0.75, 0.25]
  ↳ each change reaches the OS task in the order it was made: [0.25, 0.75]
  ```
  The two probe tests fail deterministically (the hold seam orders them). The FIFO test passes by construction after
  the fix, but on `s3-base` its failure depends on when the per-call `Task` runs: it failed in 6 of 6 runs there (the
  `[0.25, 0.75]` order every time, the early check once), and passed in its first form, which had no listing between
  the two changes. After the fix all three pass, and all 154 transport tests then passed.
- **Control-task lifetime (R-SYN-14).** The new control task must not outlive its transfer (the S2-19 hazard), so
  `controlTask` is an internal `let` on the handle and the test awaits it. Mutant evidence: removing
  `self.controls.finish()` from `Waiter.end(with:)` fails four of the five cases (`handleDropped` still ends, through
  `deinit`):
  ```
  ✘ ... with 1 argument ending → terminal at BackgroundControlTaskTests.swift:26:6: Time limit was exceeded: 60.000 seconds
  ✘ ... ending → terminal at BackgroundControlTaskTests.swift:65:9: Expectation failed: !Task.isCancelled
  ↳ the control task outlived its attach
  ```
  (and the same for `replaced`, `consumerGone`, `invalidated`). The first version of that test awaited `controlTask.value`
  directly; against the mutant it recorded the time limit at 60 s but never returned, and the run had to be stopped by
  hand at 9 min. The committed version cancels the control task when the test is cancelled; against the same mutant
  the run ended on its own (130 s, the rebuild included).
- **Considered and not taken: a single writer per name.** The confirmer's third reorder point is the live driver:
  `LiveBackgroundSessionDriver.setPriority` lists the tasks again before it writes, so two calls in flight for one name
  may land in either order. With the fix two writes are in flight together only if their callers overlap the calls.
  The one production caller is a handle's control task, which awaits each call before the next (grep: the only
  production call of `coordinator.setPriority` is in `BackgroundTransferHandle`). A loop that keeps one write in flight
  per name and re-applies the newest wanted value would also cover overlapping direct callers. It would add a second
  table, a loop and a task-identifier check for a name re-created after its terminal, with no production caller that
  needs them. Recorded here so a later direct caller knows to add it.
- **Equivalent by design.** The two clears of `priorityRequests` (by the newest request after its listing, and on
  `.finished`) only bound the table. An entry lives only while a request lists the tasks, and a request whose
  terminal was processed meanwhile is stopped by the `processed` check either way. Removing either clear changes no
  observable behaviour, so a mutant of either survives as an equivalent mutant. The `.finished` clear is kept as ruled.
- **Contract file.** `Background/BackgroundSupport.swift` is a contract file whose bodies WP-D implements. No public or
  package signature changed. Added: the private stored properties `priorityRequests` and `lastPriorityRequest`, the
  private `Waiter.controls` and `Waiter.end(with:)`, the internal `BackgroundTransferHandle.Control` and
  `BackgroundTransferHandle.controlTask`, the handle's `deinit`, and the internal `init`'s `controls:` parameter.
  Removed: the handle's private `coordinator` property, since only the control task uses it now.
- **Proposed ledger amendment (ARCHITECTURE §10.4, row D-9):** "`setPriority(_:of:token:)`: `driver.snapshot()`,
  `driver.setPriority` | the token is checked before the first await **and again after the listing** (a start may
  join the task and replace the attach meanwhile, review round 2); **the request's serial, taken before the first
  await, is checked after the listing to be still the newest for the name, so of overlapping requests the newest
  decides whichever listing returns first (Stage 3, S3-CONC-01)**; after the listing the name is re-checked against
  the processed terminals, so `priorities` is written only for a task still live; nothing is read after the last
  await (two writes for one name overlap only when their callers overlap the calls, and a handle delivers its next
  control only after the previous call returned)". And the paragraph under the table: replace "Control hops from
  `BackgroundTransferHandle` and the stream's `onTermination` are unstructured tasks outside the actor." by "Each
  `BackgroundTransferHandle` owns one control task outside the actor, which delivers its controls in the order they
  were made, each after the previous call returned, and ends with the attach (terminal, replacement, consumer gone,
  invalidation) or the handle (Stage 3, S3-CONC-01); the stream's `onTermination` hop is an unstructured task outside
  the actor."

## S3D-2 [REQUIRED] S3-CONC-02: the events relay keeps every handler

*Ruling:* `BackgroundEventsRelay.accept` must never drop an uncompleted handler: every handler it accepts is called
exactly once, and none before the events of its own wake are staged. Test both properties.

- **Disposition: fixed.** Failing tests first (`1e3bee2`), fix (`fdf5a3d`). Public signatures unchanged, so
  `AssetClient.handleBackgroundEvents` (WP-G) is untouched.
- **Fix.** The relay keeps `[String: [() -> Void]]`, oldest first, and never stores an empty list. `accept` appends;
  `complete(identifier:)` calls and removes the oldest handler still waiting. *Why the oldest:* the facade follows
  each `accept` with one `complete`, issued after a wait for the session's events that began after that handler was
  accepted. A `complete` cannot tell whose wait it ends. By the k-th `complete`, k such waits returned, and at least
  one of them belongs to a handler accepted at or after the k-th (k waits cannot all belong to the k − 1 earlier
  handlers). So that wait began after the k-th handler was accepted, and the k-th handler's events were staged when it
  returned. This is the same premise RE-S42 already makes for a single handler. Calling every waiting handler at each
  `complete` would call a later handler before its own wait returned, and the ticket variant would change
  `AssetClient`, so neither was taken.
- **Tests added:**
  - `R-NET-3: a second background-events handler for one identifier never drops the first one uncalled`
    (`BackgroundCoordinatorTests.secondHandlerKeepsFirst`, the probe `concurrency/S3-CONC-02.swift`, strengthened: one
    completion calls only the oldest, a stray third completion calls nothing, `hasHandler` follows).
  - `R-NET-3: a handler handed over while an earlier one still waits runs only after its own wake's events were staged, and the earlier one still runs`
    (`overlappingWakesCompleteInOrder`: the facade's flow over the coordinator and the fake driver; each handler
    records whether its own wake's download was staged when it ran).
- **Evidence, failing on `s3-base`** (`1e3bee2`):
  ```
  ✘ ... "R-NET-3: a second background-events handler ..." ... Expectation failed: calls == ["first"]
  ↳ one completion calls the oldest handler only: ["second"]
  ✘ ... Expectation failed: calls == ["first", "second"]
  ↳ each handler UIKit handed over runs once, in order: ["second"]
  ✘ ... "R-NET-3: a handler handed over while an earlier one still waits ..." ... Expectation failed: calls == ["first staged: true"]
  ↳ wake 1's completion calls wake 1's handler only: ["second staged: false"]
  ```
  After the fix both pass, and so does the existing `R-NET-3: the events relay keeps a handler only for our identifiers and completes it once`.
- **Proposed ledger wording (ARCHITECTURE §10.2, RE-S42):** "L; the relay's completion runs once per handler UIKit
  handed over, oldest first, each after a wait that began after it was accepted returned, i.e. after the events that
  preceded it were staged; a later handler never replaces a waiting one (Stage 3, S3-CONC-02); after shutdown it runs
  at once (§6.4)".

## S3D-3 [REQUIRED] M-N-22: a weak ETag is never the resume validator

*Ruling:* with a weak `ETag` and `Last-Modified` the sidecar keeps `.lastModified`, with only a weak `ETag` none
(`Session/HTTPResponseReading.swift:63`); kill the mutant.

- **Disposition: test added (`6f27ad7`), no code change.** `R-NET-8: a weak ETag is never the resume validator: a pause keeps Last-Modified instead, or nothing without it`
  (`SizeAndResumeTests.weakETagIsNeverTheValidator`, 2 cases: `weak ETag and Last-Modified` keeps
  `.lastModified(…)` and ends `paused(resumable: true)`; `weak ETag only` keeps no sidecar and ends
  `paused(resumable: false)`). Adapted from `mut-network/M-N-22-candidate-test.swift`.
- **Mutant re-applied** (`git apply .build-orchestrator/s3-mutants/network/M-N-22.diff` in this worktree, run,
  `git checkout` of the one file, `git diff --stat` empty afterwards):
  ```
  ✘ ... with 1 argument tagCase → weak ETag only at SizeAndResumeTests.swift:213:9: Expectation failed: await iterator.next() == .paused(resumable: tagCase.kept != nil)
  ✘ ... with 1 argument tagCase → weak ETag and Last-Modified at SizeAndResumeTests.swift:215:9: Expectation failed: rig.staging.sidecars[request.partialName]?.validator == tagCase.kept
  ↳ sidecar: Optional(ZTronAssetModel.ResumeSidecar(name: c-8cf4….1-1.part, validator: ZTronAssetModel.ResumeValidator.strongETag(W/"v1"), receivedBytes: 524288, expectedBytes: Optional(1048576)))
  ```
  Unmutated: both cases pass.

## S3D-4 [REQUIRED] S3-B-057: S2-19 written

*Ruling:* write S2-19, `R-SYN-14: no task outlives a transfer in the live foreground backend` (ARCHITECTURE §12.4).

- **Disposition: test added (`c69327e`), no code change.** `ForegroundBackendTests.noTaskOutlivesATransfer`, exactly
  that display name. Against the loopback server and the real URLSession backend it ends one transfer each way:
  staged, failed (404 → `permanentMissing(httpStatus: 404)`), paused (no validator → `paused(resumable: false)`) and
  cancelled. For each, a reader that holds only the update stream returns exactly `[terminal]` (it ends because the
  stream finished at its terminal element). Every `transfer` interval ended (4 began, 4 ended), `liveTransfers()` is
  empty, the session lists no task whose state is not `.completed`, and after the handles are dropped weak references
  to all four are `nil`, so no task keeps a transfer's handle alive.
- **Not vacuous:** a scratch S2-19-style control reader in `DataTransferHandle.init`
  (`Task { [self] in for await _ in control { _ = self.id } }` over a stream nobody finishes) fails it:
  ```
  ✘ ... "R-SYN-14: no task outlives a transfer in the live foreground backend" ... Expectation failed: references.allSatisfy { $0.object == nil }
  ↳ a task kept a handle alive after its transfer ended
  ```
  (source restored with `git checkout`; `git status` clean afterwards).
- **Proposed §12.4 status (S2-19):** "Resolved, ADR-021: no control stream exists; `R-SYN-14: no task outlives a
  transfer in the live foreground backend` written at Stage 3 (WP-D, S3D-4)". The background handle's own control task
  (S3D-1) is pinned by `R-SYN-14: a background handle's control task ends with its attach, however the attach ends`.

## S3D-5 [REQUIRED] S3-B-055: OI-10, loopback tests that timed out under load

*Ruling:* the loopback tests that time out under host load (`ForegroundBackendTests.swift:162-164`, `:200-202`) get
request timeouts that cannot fire spuriously under load (an injected timeout or a deterministic trigger), with no
assertion loosened.

- **Disposition: fixed in the tests (`70f4059`), no production change.** *Cause:* both tests stall the response on
  purpose and then act (cancel); the rig's request timeout was 10 s, so a host that delays the test's action by more
  than 10 s ends the stall with `transient(.timedOut)` instead. *Decision:* an injected timeout. `LoopbackRig.heldStallTimeout`
  (600 s) is longer than any test's hang guard (5 min at most), so for a response that stalls until the test acts, the
  stall can never end in a timeout before the action. A missed event still fails the test, at its hang guard.
  *Options not taken:* a timeout that scales with the load average would still race under a large enough load; a
  deterministic trigger already exists (the stall is ended by the test's own action), so only the timer had to go.
- **Tests that now pass `requestTimeout: LoopbackRig.heldStallTimeout`** (each stalls until the test pauses, cancels,
  invalidates or stops the server): `ForegroundBackendTests` `consumerCancellation`, `invalidation`,
  `priorityChangesInPlace`, `cancelByName` (named in the ruling), `handleCancelDiscards` (named in the ruling);
  `SizeAndResumeTests` `pauseKeepsThePartial`, `weakETagIsNeverTheValidator`, and the helper `dropMidway` (behind
  `droppedConnectionResumes`, `checksumLessNeverResumed` and `resumedRequestCarriesTheCurrentKey`);
  `ArithmeticSafetyTests.liveBytesCountTheOffsetOnlyFor206`. No assertion changed (`git show 70f4059` changes only the
  `make(...)` calls and the rig's documentation).
- **Kept short on purpose:** `writtenOverCap` (`SizeAndResumeTests`) and `streamingCap` (`ManifestFetchTests`) stall
  only to detect a missing abort while streaming; there the timeout firing is the failure, so they keep the 10 s
  default.
- **Evidence (a scratch probe, deleted afterwards, the one test in this close-out that slept):** the same stalled
  transfer, cancelled 3 s after its progress, ends
  `transient(TransientCause.timedOut, retryAfter: nil)` with a 1 s request timeout and `cancelled(byClient)` with
  `heldStallTimeout`:
  ```
  PROBE timeout=600.0 terminal=Optional(...TransferUpdate.failed(...TransferError.cancelled(...CancellationCause.byClient)))
  PROBE timeout=1.0 terminal=Optional(...TransferUpdate.failed(...TransferError.transient(...TransientCause.timedOut, retryAfter: nil)))
  ```
- **Proposed:** close OI-10 (ADR-052 and ADR-053 assignments; `docs/adr-drafts/c.md` OI-10) for the transport loopback
  tests. `connectionReuse` keeps its 50 s timeout from Stage 2, because its tasks queue behind three connections and
  do not stall.

## S3D-6 [ADR-RECORD] S3-B-046…054, S3-B-056

*Ruling:* record only; the orchestrator moves the device items to DEVICE-TEST-PLAN at Stage 5; NEEDS-HUMAN-REVIEW items
stay as ratified. No code was changed for any of them.

| Item | Decision recorded | Evidence | Reason |
|---|---|---|---|
| S3-B-046 (D-19.1, D-20.3) | Device plan: does `nsurlsessiond` finish a fresh background download with a ranged 206 after an internal retry? Code unchanged: such a 206 is `unexpectedStatus(206)`. | d.md D-19, D-20.3 and "Not verified here"; ADR-050 | Device-only; no simulator or macOS run can produce an OS-internal retry. |
| S3-B-047 (D-19.2) | Device plan: the OS keeps `taskDescription` (the `ztak1` tag and its resume flag) across relaunch for a task made by `downloadTask(withResumeData:)`. | ADR-050; d.md "Not verified here" | Device-only. |
| S3-B-048 (D-19.2, NEEDS-HUMAN-REVIEW) | Stays as ratified: the continuation flag travels in the persisted tag `ztak1 <name> <size|-> [resume]` (at most 256 bytes); every later build must decode it. | ADR-050; d.md D-19.2 | Accepted deviation awaiting the owner; nothing to change. |
| S3-B-049 | Device plan: background resume data end to end (a 206 with `Content-Range` moving the whole body; −1002, 416 and a range-less 206 for stale data). | ADR-050; d.md ruling 2 | Device-only. |
| S3-B-050 | Device plan: `LiveBackgroundSessionDriver` ordering (task creation vs `invalidate()`, the callback order, `urlSessionDidFinishEvents` timing, relaunch re-attachment); its `resumeData` use (`BackgroundSessionBackend.swift:58-60`) has no test (mutant ME survives) because the file is coverage-excluded and device-only. | d.md D-20.1; ARCHITECTURE §14 | Device-only. S3D-1 adds one more device question: the order in which the live driver's `setPriority` writes land (see "Not verified here"). |
| S3-B-051 | Device plan: real `NWPathMonitor` transitions, a notification between `start` and the first update (D-18.5), HTTP/2 reuse against CloudFront. | ADR-050; ARCHITECTURE §14 | Device and network only. |
| S3-B-052 (D-10, NEEDS-HUMAN-REVIEW) | Stays as ratified: an explicit `shutdown()` cancels in-flight background downloads (the Model's drop-to-cancel rule; ADR-039 as amended by ADR-050). S3D-1 changed how a handle's controls travel (one control task per handle), not this rule. | ADR-050 (D-10); d.md D-10 | Accepted deviation awaiting the owner. |
| S3-B-053 (NEEDS-HUMAN-REVIEW) | Stays as ratified: public `BackgroundSessionDriver.startDownload(_:name:priority:expectedBytes:resumeData:)` (no R-CAR-6 shim affected). | ADR-050 (ratified contract changes); d.md D-14 | Accepted public API change awaiting the owner. |
| S3-B-054 | Device plan: R-NET-3's run-time half, an app that attests `BackgroundTransferPolicy.enabled` without wiring the hook, stays undetected (CCR-G1 declined, L5-R5); revisit only with a detection that cannot misfire on an early finish. S3D-2 does not change this: a relay that holds several handlers still sees only the handlers it was given. | ADR-054; `Tests/ZTronAssetKitTests/CompositionTests.swift:39-44`; L5-R5 | Accepted deviation; device-only. |
| S3-B-056 | Declined options stay declined: D-17.5 (apply the joining job's lane priority when `start` joins a live task), D-17.6 (prove "without polling" inside the conditions test), D-18.3 (change the failure of a direct start of an unbounded job). | d.md D-17.5, D-17.6, D-18.3 | Declined at review rounds 2 and 3 for the reasons given there. S3D-1 keeps D-17.5's premise: a join still asks for the task's creation priority, and the newest-request check orders only explicit changes. |

## Gates and runs on the final tree (this session, 2026-10-30)

Eight commits on `wp/s3d` before this record (`b287a88` … `0269a1a`); the runs below are of that tree.

- `SWIFTPM_SCRATCH=.build-s3d bash Scripts/verify.sh --quick` → `VERIFY: PASS` (harness unchanged since
  `harness-frozen`; Transport 159, Sync 351, Storage 459, Model 84, Kit 85, Compatibility 71, AppleHosted 104 tests;
  load average up to 140 during the run).
- `swift build -c release --scratch-path .build-s3d -Xswiftc -warnings-as-errors` → `Build complete! (34,68 s)`.
- `UNSAFE escapes found=0 max=3` / `UNSAFE: PASS`; `DOCS public declarations=1281 documented=1281 exempt=0 fraction=100.0%` /
  `DOCS: PASS`; `TRACE: PASS` (run without `--write`, so `docs/TRACEABILITY.md` is untouched); `SELFTEST: PASS`.
- `ZTronAssetTransportTests` three times: `✔ Test run with 159 tests in 17 suites passed` each time (0.477 s,
  0.507 s, 0.451 s; load 13.9 to 14.7). Under TSan (`.build-s3d-tsan`): `✔ Test run with 159 tests in 17 suites passed
  after 3.847 seconds`, no ThreadSanitizer report.
- Coverage (all 8 bundles merged, as `verify.sh` does): `COVERAGE target=ZTronAssetTransport lines= 99.10% (2418/2440)
  min=70.0 OK`, `COVERAGE overall lines=96.56% (25176/26073) min=80.0 OK`, `COVERAGE device-only-excluded lines=177
  share=0.67% max=3.0% OK`, `COVERAGE: PASS`. `BackgroundSupport.swift` 592 of 593 lines.
- iOS: `xcodebuild … -destination 'generic/platform=iOS' … OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet` exits 0
  with no warning or error.
- iOS Simulator (iPhone 17e, iOS 27.0, `02CE21B4-…`; ADR-051): `** TEST SUCCEEDED **`; xcresult summary `result:
  Passed, totalTestCount: 1313, passedTests: 1313, failedTests: 0, skippedTests: 0` (387 s; load average 270 at the
  end). The simulator was shut down afterwards.
- WP-D's benchmark (release, `.build-s3d-perf`, `--filter TransportBenchmarks`): `P-10 500 assets: 8 TCP connections
  (max 8), 500 requests, 0.156532125 seconds`, passed (load 190.6 before, 34.6 after).

## Authorised edits outside WP-D

None. Every file changed is WP-D's (ARCHITECTURE §1.2): `Sources/ZTronAssetTransport/Background/BackgroundSupport.swift`
(a contract file whose bodies WP-D implements; no public or package signature changed, see S3D-1 "Contract file"),
`Tests/ZTronAssetTransportTests/{BackgroundInterleavingTests,BackgroundCoordinatorTests,BackgroundControlTaskTests,SizeAndResumeTests,ForegroundBackendTests,ArithmeticSafetyTests,TransportTestSupport}.swift`
(not `TransportContractTests.swift`), and this file.

## Proposed document changes (for the orchestrator at the Stage 3 merge)

1. **ARCHITECTURE §10.4:** row D-9 as amended in S3D-1, and the paragraph under the table (one control task per
   background handle).
2. **ARCHITECTURE §10.2:** row RE-S42 as worded in S3D-2.
3. **ARCHITECTURE §6.4:** after "`AssetClient.handleBackgroundEvents` stores UIKit's handler in the relay", add "(every
   handler it is handed, oldest first; one completion calls the oldest still waiting, S3-CONC-02)"; in **Coordinator
   (D-9)** after "Controls act only while the handle's attach token still holds the name", add "and reach the
   coordinator in the order they were made, through the handle's one control task; of overlapping priority changes
   for one name the newest decides (S3-CONC-01)".
4. **ARCHITECTURE §12.4:** S2-19's status as in S3D-4.
5. **ARCHITECTURE §14 "Not verified here":** add the two device questions below.
6. **DECISIONS (ADR-050, D-10):** the background handle's controls travel through one control task per handle in FIFO
   order, ending with the attach or the handle (was one short-lived unstructured task per control); D-10's
   NEEDS-HUMAN-REVIEW rule on `shutdown()` is unchanged.
7. **TRACEABILITY:** regenerate (new tests under R-NET-3, R-NET-8, R-NET-10 and R-SYN-14).
8. **ADR-052/ADR-053 assignments and `docs/adr-drafts/c.md` OI-10:** closed for the transport loopback tests (S3D-5).

## Not verified here (for `docs/VERIFICATION.md`)

- **UIKit handing a second background-events handler for one session identifier while the first still waits**
  (S3-CONC-02's trigger). The relay now keeps both and completes them oldest first, but whether UIKit ever does this is
  device-only and never ran here.
- **The live driver's priority writes (S3-CONC-01, the confirmer's third point).** `LiveBackgroundSessionDriver.setPriority`
  lists the tasks again before writing `task.priority`; with the fix two writes for one name are in flight together
  only if direct callers overlap them, which no production code does. That the OS applies the last
  `URLSessionTask.priority` written to a background task (and what it does with the hint) is device-only.
- Everything listed under "Not verified here" in `docs/adr-drafts/d.md` stays unverified (S3D-6).
