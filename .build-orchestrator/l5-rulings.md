# Level 5 orchestrator rulings (WP-G facade): input for the close-out and for ADR-054

This file is the source of truth for the close-out fixers and verifiers, and later for the docs agents. `docs/adr-drafts/g.md` (G-1…G-12, the g-n REENTRANCY rows, CCR-G1…G3) holds the detail; this file holds what the orchestrator decided. These rulings win over any draft. Findings cited as `L5-V3-nn` are the issues in `.build-orchestrator/l5-remaining-g.json`: verification round 3 of the main run, not yet fixed, HEAD `25b7c8b`.

## Runs
- Owner decisions (2026-10-18):
  - Level 5 starts with WP-G only, after the 22 Oct reset.
  - Close-out bar **strict**: every cycle hunts for new bugs, and any proven bug blocks.
  - All roles run on the session model.
  - Weekly-usage stop **55 % for all of WP-G**: 50 for the main run and the close-out, 55 for docs.
- Main run `wf_6593085d-170`: the author, then three verification rounds and two fix rounds. Blocking went 2 → 3 → 4, out of 16, 12 and 9 issues in total. It took 4.7 h, and weekly usage went 0 % → 5 %.
- What the four blocking items in round 3 are:
  - L5-V3-00 and L5-V3-07 are one defect: CCR-G2.
  - L5-V3-05 is new in round 3.
  - L5-V3-06 is new in round 3.

## Rulings

- **L5-R1 / CCR-G2: R-CAR-3 and sync-1 S1-05 end to end (L5-V3-00, L5-V3-07; blocking). Approved as an authorised edit outside WP-G, and widened to the whole class.**
  - **Cause.** `performRegisterGroup` returns `.success(token)` before the group holds any interest: `joinGroup` adds the interests later, in an owned task, after a store read. A release ordered after that registration, which is exactly what `cancel(after:)` and `PrefetchWindowController` guarantee, can therefore overtake the join. The job's last interest drops, `retire(_:)` cancels its transfer, and the successor's join starts it again.
  - **The proposed fix is not enough.** CCR-G2 proposes adding interests synchronously "to every listed id that already has a job". That closes the measured case, but it leaves a second window of the same class:
    1. Group P is registered with id x while x has no job, so P's join is still in flight.
    2. Successor S is registered with x. x still has no job, so S's x goes to S's asynchronous join.
    3. P's join creates x's job and starts its transfer.
    4. P is released before S's join reaches x.
    5. x's job retires, and S's join then downloads x again.

    Fast swiping (two window moves in quick succession) produces exactly this sequence.
  - **The invariant to make true.** Once `registerGroup` has returned `.success` for a group naming id x, and until that group is released, no other group's release, no waiter withdrawal and no caller cancellation may retire x's job or cancel its transfer. This holds whether or not x had a job at registration time, and whether or not that group's join has reached x yet.
    - The existing exits are unchanged: x left the manifest, its entry now names different content, it became present (L4-R5), or its job failed or was held back by the existing rules.
    - When the group's join reaches x, it joins the job, or skips x as present, exactly as today.
  - **Design (recommended).** At registration, record a *pending claim* for every listed id in the registering turn. The one retirement funnel, `retire(_:)`, keeps a job alive while any of its assets has a pending claim. A claim ends:
    - when its group's join processes that id (join or skip);
    - when the group is released; or
    - when the engine shuts down.

    When a claim ends and the job then has no interest and no claim left, it retires in that turn. The fixer may choose another implementation if it makes the invariant hold for both windows above. A plain "synchronous join for ids that already have a job" alone does not.
    - The recommended design also settles the `heldBackError` / `joinMember(record: nil)` question from g.md: the join keeps using the record from its view.
  - **C2.** The registering turn and the release turn stay within C2 at SPEC §6's 10,000 ids:
    - Measure both with a 10,000-id group and record the figures in g.md.
    - If the claim bookkeeping for 10,000 ids costs more than about 2 ms in one turn, chunk the claim releases the way `releasesPerTurn` already chunks interest releases.
  - **Tests, failing first.** Deterministic engine tests in a **new** file `Tests/ZTronAssetSyncTests/Engine/EngineGroupClaimTests.swift`, with a header citing L5-R1 and CCR-G2, one for each window:
    - (1) The successor is registered while the predecessor's job exists, and the predecessor is released before the successor's join. The transfer starts once, and the promotion reaches the transport as `setPriority`.
    - (2) The predecessor's join creates the job after the successor's registration, with the successor's join held at its store read. Use an existing test gate on `planningView()`, or add one in the test target only. Then the predecessor is released. No second start of the transfer.
    - (3) A release of the only claiming group before its join retires the job, and nothing leaks: `ownedTasks`, `jobs` and the claims are all empty at idle.
  - **Then remove both `withKnownIssue` wrappers** in `PrefetchFacadeTests.swift`, the `isIntermittent` one included. Those two R-CAR-3 tests must pass in **50 consecutive runs** (`swift test --skip-build --filter "R-CAR-3"`, run on the debug build already made), and in the Kit ×3, TSan and simulator runs.
  - **Authorised files.**
    - `Sources/ZTronAssetSync/Engine/EngineCommands.swift`, `EngineJobs.swift` and `EngineState.swift`: internal state and bodies only, with no public or package signature change.
    - The new test file above.
  - **Runs after this change.** Run `ZTronAssetSyncTests` 3 times and once under TSan, besides the Kit runs, and keep Sync coverage ≥ 90 %.
  - **Records.** Record every edit in g.md under "Authorised edits outside WP-G (close-out)": file, change, ruling and test. New awaits get REENTRANCY comments citing g-n (proposed) rows, and the spawn keeps its RE-S30 note.

- **L5-R2: shutdown in `created` leaks owned tasks (L5-V3-05; blocking). Approved as an authorised edit outside WP-G, for the whole class.**
  - **Invariant.** `shutdown()` returns only after every engine-owned task has been cancelled and joined, and every continuation resumed with `.shutDown`, **whatever lifecycle state it began in**, `created` included. From `created` it still never opens the store and never logs.
  - **The change.** The `.created` branch of `performShutdown` (`EngineLifecycle.swift:466-470`) does what the other branches do before `finishShutdown()`:
    - cancel the tasks;
    - `resumeEverything(with: .shutDown)`;
    - run the same join loop.

    `ensureStarted()` must refuse during `shuttingDown`, so that a joined `joinGroup` task cannot open the store. Check this, and pin it in the tests.
  - **Enumerate the class.** List every `spawn` call site reachable while the engine is `created` (at least the `.pressure` observer and `joinGroup`'s `.entry` task), in a table in g.md. Each site needs a test in the same new Sync file or in `EngineCreatedShutdownTests.swift`, with this shape: spawn in `created`, then `shutdown()`, then assert `ownedTasks == 0` and the site's resource released (for example `pressure.activeObservers == 0`) right after `shutdown()` returns, with no further event needed.
  - **WP-G's part.**
    - A facade regression test in PROBE-1's shape: `register(_:)` before `start()`, then `shutdown()`, then assert that `introspect().ownedTasks == 0`, `memoryPressureObserverActive == false` and `activeObservers == 0`.
    - One in PROBE-2's shape, through the existing `reopenWillShutDownEngine` seam or a new seam point after the replacement's pressure request.
  - **Order in `performReopen`.** The pressure request may stay before `start()`: with the engine fix this is safe, and it keeps the newest recorded request live from the replacement's first turn. Changing the order is not required.
  - **Authorised file.** `Sources/ZTronAssetSync/Engine/EngineLifecycle.swift`, bodies only. The same Sync runs as in L5-R1 apply.

- **L5-R3: the event forwarder must not lose the replacement's events (L5-V3-06; blocking; WP-G's own files).**
  - **Invariant.** A consumer stream (`events` or `subscribe()`) that is live when a reopen installs a replacement receives **every event the replacement publishes, from its first one on**. The only exception is the engine's documented coalescing of non-terminal progress.
  - **Make it true by construction.** In `performReopen`, after `makeCore` and **before** `self.core = next` / `endReopen(next)`:
    - Register every live forwarder with the replacement engine through its eager-registering `subscribe()`. At that point the replacement is `created`, unreachable by callers, and cannot publish.
    - Hand each forwarder that stream.
    - The pump switches to the stream it was handed, not to whatever `current()` returns later.
    - Re-check `closed`, and re-check for forwarders created during that await. A forwarder created while the reopen runs may instead register itself after install: it has no history to lose, and its replay covers the state.
    - The retired engine's stream is drained to its end before the pump switches, so the old events precede the new ones.
  - **Why not the verifier's change alone.** Their probe change (`current()` waits only until install) narrows the window, but it leaves a race between the pump's registration and the reopen's own calls on the replacement: the pressure request, the binds and `start()`. It is not sufficient alone. It may still be adopted for the other callers of `current()`, and if so, update g-1 to say the wait ends at install.
  - **Decision on `clientStarted`.** The replacement's `clientStarted(generation:)` **is forwarded**. Consumers learn that a new generation started, which matches the mirror's reset. The retired engine's `clientShutDown` stays hidden, as G-2 decided. Record this in G-2.
  - **Tests, failing first.** PROBE-3's shape in `FacadeReopenTests`: a consumer registered before start, a reopen, then assert that the replacement's `clientStarted(generation: 1)` arrives. Add PROBE-4's shape too: a terminal asset event from a call that reaches the replacement while the reopen is parked at `registrationAnswered` arrives at the consumer.
  - **Records.** Update g-1/g-7 and G-2.

- **L5-R4 / CCR-G3: the reopen trigger after a replaced root (L5-V3-02). Approved, as a package addition authorised by the orchestrator.**
  - **The store change.** WP-B's `Sources/ZTronAssetStorage/Store/AssetStore.swift` gains exactly one read:
    - `package var unavailableReason: StorageUnavailableReason? { self.state.core.unavailable }`, or its equivalent for the current state shape.
    - It carries a `///` comment saying why: the facade owns the B-15 reopen.
    - This is not a public API change, so it is not NEEDS-HUMAN-REVIEW.
  - **Store test.** In a **new** file `Tests/ZTronAssetStorageTests/Core/StoreUnavailableReasonTests.swift`, failing first: `nil` when open and healthy, `.rootVanished` after a replaced root, and the read-only (B-34) reason.
  - **The facade uses it twice** (G-5 amendment):
    - (a) Before `withAsset`'s lease: if the current store reports `.rootVanished`, reopen first.
    - (b) After any `.storageUnavailable(_)` result: if the store then reports `.rootVanished`, treat the result as `rootVanished` (reopen and repeat, within `reopenAttempts`).
  - **Results stay faithful (L4-R23).** Only the store's own `.rootVanished` triggers a reopen; any other storage failure is returned exactly as given. A race in which the root vanishes between the check and the lease is acceptable: leases are reads under B-15. Say so in G-5.
  - **Test changes.** Update the pinned `.ioFailure` assertion in `FacadeReopenTests.swift:109-112` to the new behaviour: `sync` after a replaced root succeeds on the replacement. This is this level's own test, not a pre-existing CDN test, so `MIGRATION.md` does not apply (as with L4-R15). Add a test that `withAsset` after a replaced root leases from the replacement.
  - **Runs.** Run `ZTronAssetStorageTests` once and under TSan, and keep Storage coverage ≥ 90 %.

- **L5-R5 / CCR-G1: R-NET-3's run-time half (L5-V3-01). Declined as proposed; the attestation is the meaning of "wired" in Stage 2.**
  - The proposal was: disable background transfers when `.backgroundEventsFinished` arrives with no finish waiter. That would misfire on a race WP-D deliberately tolerates. `BackgroundTransferCoordinator.awaitBackgroundEvents()` returns at once when "such a report arrived before anybody waited" (`unclaimedFinishes`, `BackgroundSupport.swift:399-401`). The facade's `handleBackgroundEvents` reaches the coordinator through an asynchronous hand-off (G-5), so an early finish is normal for a wired hook.
  - Under ADR-026 (c), `BackgroundTransferPolicy.enabled` *is* the app's attestation that it forwards the hook. The default `.disabled` keeps every transfer in the foreground, and G-6's test covers that half.
  - The run-time half goes under "Not verified" in `VERIFICATION.md` and into the device test plan.
  - Stage 3 may revisit it, but only with a detection that cannot misfire on an early finish. One possibility: a finish that no hook call claims for the whole background wake.
  - No WP-D change in Level 5. g.md G-6/G-11 record this ruling.

- **L5-R6: benchmarks outside WP-G (L5-V3-03, L5-V3-08; non-blocking, `outside-wp`).**
  - P-13 (WP-B) still awaits the owner's ruling (ADR-050, L4-R11).
  - P-11 and the R-SYN-5 C2 benchmark (WP-F) missed only at load averages of 17–141, with other agents running.
  - None of these blocks WP-G. The orchestrator re-runs the whole suite (`verify.sh --perf`) on a near-idle host after the merge and records the figures.
  - WP-G's own benchmarks block as usual: P-1, P-8 ×2, P-9 and P-12. A miss caused only by load is not blocking, but report the load average with every benchmark or TSan figure (L4 process).

- **L5-R7: ARCHITECTURE §2's sentence on sleeping (L5-V3-04; docs level).** The sentence says "nothing ever sleeps for real except the P-11 benchmark's loopback latency". The docs level amends it to also name P-9's `Heartbeat` on `LiveTimeSource` and the Kit benchmarks' live clock. The deterministic suites never sleep. No code change.

- **L5-R8: G-1 and G-5 (the author's "owner review" item). Approved as decided.**
  - G-1 decides how the reopen is triggered, and that prefetch groups, the memory-pressure observer and the run-time retention scope survive it. G-5 decides which failures repeat a call.
  - Neither changes a public signature, so neither is NEEDS-HUMAN-REVIEW under CLAUDE.md. ADR-054 lists them for the owner's information.
  - Pins live in the vanished root's records and are lost with it. This is accepted, and stated in ADR-054 and §8.

- **L5-R9: untested interleavings (fix rounds 1–2 open items; G-5; g.md's untested-lines paragraph). Accepted as listed, with one condition.**
  - Where an existing `LifecycleSeamPoint` reaches an interleaving cheaply, a test is expected.
  - A new seam point is added only together with the fix for a bug a verifier proved there, as G-10 and G-12 did. No seam is added for coverage alone (G4).
  - `bind`'s unreachable early return stays as an invariant guard, listed as deliberately untested.
  - The list goes to `VERIFICATION.md` as "interleavings untested". L5-R3 changes the forwarder paths, so the fixer refreshes the paragraph.
  - Verifiers may still prove bugs there under the strict bar.

- **L5-R10: no merge before L5-R1.** The fallback in g.md, "if the merge precedes WP-F's fix, record R-CAR-3 and S1-05 as failing", does not apply. Under the strict bar WP-G merges only at 0 blocking in both lenses, with L5-R1 landed and both R-CAR-3 tests free of `withKnownIssue`.

- **L5-R11: ownership and records.**
  - The requirements verifier's ownership check (`git diff --name-only l4-merged...HEAD`) accepts WP-G's §1.2 files plus exactly the files authorised in L5-R1, L5-R2 and L5-R4. Any other file outside WP-G is blocking.
  - g.md's section "Authorised edits outside WP-G (close-out)" lists each file with its ruling and test. The docs level copies it into ADR-054 and ARCHITECTURE §1.1/§1.2.
  - No contract signature changes, apart from L5-R4's one package read.

- **L5-R12: merge-time items for the docs level (the fixers' open items).**
  - Fold G-1…G-n into `DECISIONS.md` as ADR-054's ratified WP-G decisions.
  - Put g-1…g-n into ARCHITECTURE §10 as a new §10.6 `ZTronAssetKit`, numbers kept. This includes rows for the engine awaits L5-R1 and L5-R2 add.
  - Write g.md's "Not verified" items into `VERIFICATION.md`, plus L5-R5's run-time half.
  - Make the §2 amendment (L5-R7).
  - Record §8's reopen behaviour (G-1, G-5, L5-R3, L5-R4).
  - Update the §11 credits for R-CAR-3 (engine claims, L5-R1), R-SYN-15 (L5-R2) and R-NET-3 (attestation half, L5-R5).

## Process
- The two verifiers share the worktree. `verify.sh` writes `.verify-logs/` inside it, so take each agent's `--quick` verdict from its own exit status.
- The orchestrator deletes the reviewers' `.build-verify-*` directories between cycles. Verifiers must not rely on an earlier cycle's scratch.
- The fixer runs `ZTronAssetSyncTests` (3× + TSan) whenever an engine file changed, and `ZTronAssetStorageTests` (1× + TSan) whenever a store file changed, besides the Kit runs the close-out requires.
- **Classes, not cases.** When a defect class repeats over two cycles, the orchestrator orders an exhaustive enumeration and one design fix (as L4-R17 and L4-R20 did). L5-R1, L5-R2 and L5-R3 are already written as class rulings: the verifiers check each invariant as stated, try to break it with probes, and check the L5-R2 enumeration for completeness.
- The round-3 correctness verifier's probes are kept in `.build-orchestrator/l5-probes-r3/` for reference: `VerifierProbesR3.swift` (PROBE-1…4), its logs, and `probe-changes.diff` (the probe-only changes it validated). Write your own failing tests in the shapes the rulings name; do not copy probe seams that L5-R3 rejects.

## Close-out continuation (cycle 2 onward; 2026-10-22 17:40)
- Close-out `wf_a049b89c-afb` ran cycle 1 (14:39–17:34, weekly 5 % → 8 %). It fixed every original blocker, and the verifiers reproduced each fix against mutants and probes:
  - L5-R1 engine claims (G-13): R-CAR-3 holds with no `withKnownIssue`; the fast-swipe probe found no second transfer.
  - L5-R2 shutdown from `created` (G-14).
  - L5-R3 hand-over, in its measured shape.
  - L5-R4 reopen trigger.
- Cycle 1's verification left **4 blocking items, 3 distinct defects** (`.build-orchestrator/l5-close1-remaining-g.json`, findings `L5-C1-nn`):
  - L5-C1-00 and L5-C1-03: a `subscribe()` stream that was not pulled before a reopen loses the replacement's events.
  - L5-C1-01: the reworked R-STO-9 test counts the retired engine's download from the shared fake log.
  - L5-C1-02: `promotionNeverRestarts` failed 7 of 50 runs under load, because it waits for "in flight" when it needs "joined".
- Two classes have now repeated across cycles, so the next two rulings order an enumeration and one design fix for each, as L4-R17 and L4-R20 did.
- The cycle-2 fixer was stopped before it changed anything (HEAD `2e828d1`, clean). The close-out restarts at cycle 2 from `l5-close1-remaining-g.json`.

- **L5-R13: event-stream continuity across reopens, as a class (L5-C1-00, L5-C1-03, L5-C1-04; blocking).**
  - **History.** Lost or leaked events in the forwarder came up in round 1 (an abandoned pump leaked), round 3 (L5-V3-06, the replacement's events lost) and cycle 1 (L5-C1-00/03). Fixing shapes one at a time has not converged.
  - **Design rule: followership precedes registration.** A forwarder is recorded as a lifecycle follower **in the same lifecycle turn that chooses the engine it registers with, before the registration's await**.
    - The pump never calls `follow` itself.
    - Every reopen's hand-over covers every follower recorded before it.
    - A forwarder drops a handed stream whose generation is not newer than the one it holds.
    - `stop()`/`end()` unfollow, whether or not a pump ever started. A stream dropped before its first pull leaves no follower entry.
  - **What each stream kind is promised.**
    - A `subscribe()` stream holds a registration from the moment `subscribe()` returns. It must receive every event of that generation from its registration on, and every event of each later generation from that generation's first event on (`clientStarted` included), subject only to the engine's documented coalescing of progress.
    - An `events` stream registers asynchronously: its history starts at its registration. Followership and that registration are one lifecycle step, so no reopen can fall between them.
  - **Enumerate the class.** List in g.md every way a forwarder obtains an engine stream:
    1. `subscribe()`'s eager registration;
    2. an `events` stream's first registration;
    3. the reopen hand-over;
    4. the pump's fallback re-registration when a retired stream ends with nothing handed over;
    5. a registration repeated after `.shutDown` from a retired engine (G-5).

    For each, state how the design rule holds. Path 4 becomes unreachable for a recorded follower: either remove it, or keep it only for the client-shut-down end, with that stated.
  - **Model test.** Write a seeded, randomized model test that prints its failing seed, in the shape of L4-R20's gate model. It interleaves:
    - consumer actions: `subscribe()`, `events` plus a first pull, pulls, dropping a stream, cancelling one;
    - reopens: a wiped root plus a mutating call, parked and released at the existing `LifecycleSeamPoint`s (a seam point is added only if the model needs it);
    - calls that publish terminal events on whichever engine serves them (`resolve`, `performMaintenance`, `sync`);
    - `shutdown()`.

    It checks these invariants after every step and at idle:
    - **I1 no loss:** every stream receives what the promise above says. Use as the oracle a direct test subscriber that the seam registers on each replacement before it is installed.
    - **I2 order:** per stream, generations never go backwards. No retired engine's `clientShutDown` is forwarded. A real shutdown's `clientShutDown` is the last event.
    - **I3 no leak:** at idle after every stream ended, the lifecycle has 0 followers, no pump task is left, and every live engine has 0 subscribers.
    - **I4 bounded:** at most one event waits in each forwarder (R-SYN-12).

    The model must fail on `2e828d1` (it reproduces L5-C1-00) and pass after the fix over ≥ 500 seeds in the suite (time-boxed per the L4-R8 budget) and ≥ 5,000 seeds once by hand, with the figure recorded in g.md.
  - Add PROBE-A's and PROBE-A2's shapes as fixed regression tests too (`.build-orchestrator/l5-probes-c1/VerifierProbesC1.swift`).
  - Update G-2, g-7, g-10 and the `EventForwarder` doc comment, whose line "has no history to lose" is false for `subscribe()`.

- **L5-R14: scheduling-dependent facade tests, as a class (L5-C1-01, L5-C1-02; blocking).**
  - **History.** Flakes came up in main-run round 1 (`uiCallsDoNoMainThreadIO`, `presentAssetResolvesLocally`), the cycle-1 fixer's own pre-run (two setup checks), and cycle 1's verification (L5-C1-01, -02).
  - **Enumerate.** Go through **every** test in `Tests/ZTronAssetKitTests` (the new L5-R13 tests included) and the `KitHarness` helpers, and list each one that does any of these:
    - (a) waits on a weaker condition than its assertion needs, for example "in flight" when it asserts "joined" or "promoted";
    - (b) counts entries in a shared fake log (`starts`, `controls`, `transportLog`) without a baseline taken at a defined point, or counts what another engine generation may have added;
    - (c) scripts a fake (manifest, `serve`) after an operation that may already consult it;
    - (d) waits a bounded number of yields or rounds;
    - (e) asserts a lower bound on, or an exact count of, events a consumer happened to pull;
    - (f) lets a clock advance race a driver that has not applied the previous step.
  - **Convert** each one to wait on an explicit condition (`awaitCondition`, a census `require…` form, a seam hold, the driver's handle) or to a defined baseline. Every wait ends on cancellation, and no assertion is weakened.
  - **Record** the table (file:test → pattern → fix) in g.md. Verifiers check that it is complete.
  - **Stress evidence**, with the load averages recorded:
    - the whole Kit suite ×20 and the R-CAR-3 pair ×50, both while the host is loaded (for example while a release build of the package runs in another scratch path, at a 1-minute load ≥ 8);
    - the L5-R13 model at its suite seed count ×10.
  - Instances already diagnosed: L5-C1-01 (take the baseline right before the forced sync, and correct the comment about `attach`) and L5-C1-02 (wait for each promotion's user-initiated join before the next move).

- **L5-R15: clearly right non-blocking items from cycle 1 (fix).**
  - **L5-C1-08 / L5-C1-06 (`endClaims`).**
    - Add a test in which a registered group's join gives up with claims pending; mutant M11 must fail it.
    - Make `endClaims` respect the C2 bound by construction: route a large give-up through the release follow-up (at most `releasesPerTurn` per turn), with a test above 512 pending claims.
    - If that cannot be done inside the authorised files, record the "no give-up after a running join's read" invariant next to G-13, and test the reachable part.
  - **L5-C1-09 (`heldLane`).** Add the same-lane variant: predecessor and successor both at `.prefetch`, and the transfer's controls stay `[]`. Mutant M12 must fail it.
  - **L5-C1-10.** Correct g.md's three spawn-site line numbers and complete the untested-lines list (`AssetClient.swift:145`, `:148-149`; `ClientLifecycle.swift:337`).

- **L5-R16: a claimed-only job's failure (L5-C1-05; accepted for Level 5 → Stage 3).**
  - A job that only a claim keeps ends on its first failed attempt as `failed(.nextRun)` with `assetFailed`, and the successor's join starts a fresh transfer. This is the unchanged failure exit of L5-R1, so it is not a violation.
  - Qualify G-13's wording: "behaves as if the released interest were still there" holds except on failure.
  - The proposal that a claim inherits the held lane's retry policy goes to the Stage 3 backlog in ADR-054. No `EngineFailures.swift` change in Level 5.

- **L5-R17: the cycle-1 fixer's deviations (G-15), accepted.**
  - The pure split `recordGroup` + `spawnJoin` replaces the `planningView()` gate (no production seam).
  - L5-R1's literal filter was the orchestrator's error. The 50-run series uses `--filter 'PrefetchFacadeTests/(windowMoveByOne|promotionNeverRestarts)'`.
  - The claim check sits in `removeInterest`, not `retire(_:)`. The presence path's direct `retire` is an allowed exit (asset present), and the correctness verifier confirmed that every interest removal goes through `removeInterest`.

- **L5-R18: benchmarks in verification (process; extends L5-R6).**
  - Verifiers and the fixer run **only WP-G's five benchmarks** (P-1, P-8 ×2, P-9, P-12), with a filter that matches only their suite. Check the run's test count.
  - The whole 35-test suite (432 s, and a load source for the other lens) is the orchestrator's near-idle run after the merge. It now includes P-5 as well as P-13 (L5-C1-11), together with P-11 and R-SYN-5 C2.

## Close-out continuation (cycle 3 onward; 2026-10-22 21:05)
- **Cycle 2** (`wf_0ec4322f-bdb`, 17:45–20:55, weekly 8 % → 12 %) applied L5-R13 to R18.
  - The requirements lens **passed with 0 blocking**: every cycle-1 blocker was reproduced as a mutant and now fails its test, the ownership check holds, and nothing flaked.
  - The correctness lens found **1 blocking issue**, L5-C2-00, a third shape of L5-R13's class. Its findings are in `.build-orchestrator/l5-close2-remaining-g.json` (`L5-C2-nn`).
- The cycle-3 fixer was stopped before any change (HEAD `9619770`, clean). The close-out restarts at cycle 3 from `l5-close2-remaining-g.json`.
- Probes are kept in `.build-orchestrator/l5-probes-c2/`. They include `engine-slot-and-strict-model.diff`, the slot change and the strict I1 that the correctness verifier validated.

- **L5-R19: client lifecycle events are never coalesced with each other (L5-C2-00 blocking; L5-C2-08). Approved as an authorised edit outside WP-G (WP-F).**
  - **Defect.** `clientStarted` and `clientShutDown` share the engine's terminal `.client` slot, so a generation's shutdown replaces its undelivered `clientStarted`. The facade then hides that retired `clientShutDown` (G-2), and a lagging consumer receives a retired generation's other events, whose snapshot generation restarted (B-17), with no `clientStarted` at all.
  - **The promise L5-R3 and L5-R13 meant.** For every generation whose `start()` finished, a consumer that was registered when it was installed (or handed its stream) receives that generation's `clientStarted(generation:)`, before that generation's later events. The only exceptions are:
    - (i) progress coalescing per progress key;
    - (ii) the documented per-subject coalescing of the other terminal slots (asset, breaker, maintenance, run), per ARCHITECTURE §7.9 / H-9.

    Client lifecycle events are **not** coalesced with each other. A retired engine's `clientShutDown` stays hidden by the facade (G-2). A real shutdown's `clientShutDown` is forwarded and is the last event. A generation retired before its `start()` finished owes no `clientStarted`.
  - **Fix (option (a) of L5-C2-00).**
    - In `Sources/ZTronAssetSync/Engine/SubscriberQueue.swift`, `clientShutDown` gets its own terminal slot (for example `.clientEnd`), so it never replaces an undelivered `clientStarted`. The per-subscriber bound grows by one constant slot, so nothing becomes unbounded.
    - The two WP-F tests that pin the old mapping are **updated to the new mapping, not weakened**: `EngineUnitTests` "every event maps to the slot it coalesces under" (`EngineUnitTests.swift:145-161`) and `EngineEventsTests.swift:60` (`slots.last == .client`). Each assertion stays as strict, now pinning `.client` for `clientStarted` and the new slot for `clientShutDown`. Add an engine test, failing first, that a subscriber which reads nothing between `clientStarted` and `clientShutDown` receives both, in that order.
    - These are WP-F's Level 4 tests, not pre-existing CDN tests, so `MIGRATION.md` does not apply. Record each change (old assertion → new assertion, L5-R19) in g.md under the authorised edits.
    - Option (b), a clientStarted synthesised by the facade, is rejected: it would reorder events and invent engine events in the facade.
  - **The model's oracle (class fix for L5-R13).**
    - Remove I1's exemption for `clientStarted` (`EventContinuityModelTests.swift:1234-1246`), for retired generations **and** for the final one. With the new slot, the final generation's `clientStarted` is no longer superseded either.
    - Then **audit every exemption or tolerance in the model's invariant checks**. List each in g.md with the clause of L5-R13/L5-R19 that grants it, and remove any exemption that no ruling grants.
    - The tightened model must fail on `9619770` and pass after the fix: ≥ 500 seeds in the suite, and ≥ 5,000 by hand recorded in g.md.
    - Add PROBE-C2-9's shape (an unpulled `subscribe()` stream across two reopens) and PROBE-C2-17's (an `events` stream one event behind) as regression tests in `FacadeReopenTests`.
  - **Authorised file:** `SubscriberQueue.swift` (bodies and the internal enum), plus the two WP-F test updates and a new engine test, preferably in `EngineGroupClaimTests.swift`'s sibling file or a new `EngineClientSlotTests.swift`.
  - **Runs:** `ZTronAssetSyncTests` ×3 + TSan. Update G-2, G-16 and the `EventForwarder` doc comment. The docs level amends §7.9 / H-9: one more terminal slot, and client events not coalesced with each other.

- **L5-R20: detect a replaced root that no commit has noticed yet (L5-C2-01). Approved as a package addition authorised by the orchestrator (WP-B), plus a facade change.**
  - **Defect.** A root replaced while no commit has run since is not reopened: `sync(.force)` returns `.storageUnavailable(.ioFailure)` from the staging listing, `resolve` fails `.serverUnavailable` after its staging fails with ENOENT, and `unavailableReason` stays `nil` until some later commit's root verification flags it. B-15's reopen must not depend on an incidental commit.
  - **Store.** `AssetStore` gains one package method, for example `func verifyRootNow() -> StorageUnavailableReason?`, in the file that holds `unavailableReason`.
    - It runs the existing root verification, `StoreLock.verifyRoot`, the check the commit unit runs, so it duplicates nothing.
    - When the root no longer verifies, it sets `state.core.unavailable = .rootVanished` (the same state as a commit's detection, B-15).
    - It returns the store's reason.
    - It does no other I/O and never writes. Add a store test, failing first, in `StoreUnavailableReasonTests.swift`: healthy root → `nil` with nothing changed; a replaced root → `.rootVanished`, and the store then behaves as after a commit's detection.
  - **Facade (G-5 amendment).** After a failed call whose failure can stem from the file system, the facade calls `verifyRootNow()`; on `.rootVanished` it reopens and repeats, within `reopenAttempts`.
    - List the failures that trigger the check in G-5: at least `.storageUnavailable(_)`, `.serverUnavailable` and transfer or staging failures. Never `.cancelled`, `.shutDown` or the manifest's `.notFound`.
    - Any other outcome is returned exactly as given (L4-R23). One root check per such failure is cheap and runs on the store actor, never on main (C2).
  - **Tests:** PROBE-C2-14's and PROBE-C2-15's shapes (`sync` and `resolve` on a replaced root the store has not flagged) succeed on the replacement. An offline failure on a healthy root is returned as given, with no reopen and no store write.
  - **Runs:** `ZTronAssetStorageTests` once + TSan, Kit ×3 + TSan.

- **L5-R21: clearly right non-blocking items from cycle 2 (fix).**
  - **L5-C2-04.** Add PROBE-P5's shape as a deterministic regression test: the first pull of an `events` stream, or a `subscribe()`, while a reopen is parked at `replacementBuilt`, then release; the replacement's `clientStarted` and a later marker arrive. Mutant MP5 must fail it. Also stamp `registeredAt` at the call's start (the follow turn) in the model, and check every generation installed after it.
  - **L5-C2-05.** Order `stop()` before `hold.open()` in `eventsStreamCancelledDuringItsRegistration`, with a test-only hook (`nil` in production, like `offerParked`). Add the row to the L5-R14 table.
  - **L5-C2-03.** The reworked R-STO-9 test matches the replacement's `syncFinished` by position, after the vanished root's failure event, not by value alone. Add it to the L5-R14 table.
  - **L5-C2-02.** Make the release gate obviously correct: a token still registered in `state.groups` never makes a job "released only". Either `isReleasedOnly`/`setsAside` ignore registered tokens (**`EngineDispatch.swift` is authorised for this guard only**), or give-up leftovers get a table of their own in the authorised files. Add a test if the split seam (`recordGroup`/`spawnJoin`) reaches it; otherwise record the invariant next to G-13.
  - **L5-C2-06, L5-C2-07.** Correct the counts (11 and 12), and list `AssetClient.swift:145`, `:148-149` as untested, noting llvm-cov's underflowed counter.
  - **L5-C2-08.** Settled by L5-R19's promise. Align G-16's wording with it.

## Close-out result and merge rulings (2026-10-22 22:55)
- Cycle 3, `wf_b17021d0-91c` (21:07–22:47, weekly 13 % → 15 %), applied L5-R19 to R21. **Its verification found 0 blocking issues in both lenses** at HEAD `1dca923`:
  - The requirements lens put each fixed defect back as a mutant: MC00, MP5, the release-gate guard removed, the old `unavailableReason`-only path, and the value-only R-STO-9 match. The tests fail against every one of them.
  - The correctness lens ran probes V3-1 to V3-10: an unread or lagging stream across three reopens, and `sync`/`resolve` on a replaced root that no commit had detected.
  - Evidence (fixer and verifiers): `--quick` PASS; Kit 85, Sync 323 and Storage 445 tests; TSan clean; 1,195/1,195 on the iOS 27 simulator; the event model at 5,000 seeds; Kit coverage ≥ 97.8 %; WP-G's five benchmarks within budget.
- **Close-out total:** 3 cycles (`wf_a049b89c-afb` cycle 1, `wf_0ec4322f-bdb` cycle 2, `wf_b17021d0-91c` cycle 3); blocking 4 → 1 → **0**; weekly 5 % → 15 %.

- **L5-R22: the remaining non-blocking items (cycle 3) need no new close-out cycle.** As with L4-R24, each one either goes to the docs level or joins the Stage 3 backlog in ADR-054's Assignments.
  - **(1) Stage 3: the stopped-registration exit is not pinned.** The `events` exit in `next()` for a consumer that stopped during its registration runs, but no assertion depends on it: mutant M05 survives. Pin it with a test read for a started pump, or a census of the replacement's registrations. The docs level states the gap in the untested-lines record.
  - **(2) Docs level: the model's tolerance table.** G-17 lacks two tolerances:
    - (a) the registration generation's own `clientStarted`, and the terminal events of calls that began after the registration, are not owed by I1;
    - (b) I2 accepts one extra `clientStarted` in the first gap.

    The orchestrator confirms both as **measurement limits of the model**, not product promises. L5-R13/R19's promise stands: a stream is owed every event of its registration generation from its registration on. Mutant MC00 is still caught, and no loss is proven. ADR-054 lists both rows with that label. Tightening the model (stamp `performMaintenance`/`sync(.force)` calls; owe the registration engine's `clientStarted` when the follow turn preceded its start) goes to Stage 3.
  - **(3) Stage 3: `sync`'s trigger list is not pinned.** The L5-R20 trigger list for `sync` is pinned only for `.storageUnavailable` (mutant M01s survives). Add a forced-sync test ending `.insufficientSpace` or `.serverUnavailable` on a healthy root: one root check, the result returned as given, no reopen.
  - **(4) Stage 3: a false positive in the engine's own invariant check.** `invariantViolations()` reports a large give-up's leftover claims (a registered token in `releasing`, L5-R15) as "released and registered". No production code calls it, and every test reads it after `releasing.isEmpty`. Flag a registered token only while its `Release` holds members or pending interests, and add the E2-shape test.
  - **(5) Docs level: the `current()` wording.** ADR-054, §8, G-2, G-16 and the `FacadeReopenTests.swift:534` comment use the correct semantics: `current()` waits for a running reopen only until it installs its replacement; during the reopen's tail it returns the installed replacement at once, and a caller's `start()` joins the replacement's single-flight start. The orchestrator fixes the test comment itself: it is a comment-only edit, and test files are outside the docs writer's files.

- **L5-R23: documentation (docs level).** ADR-054 is the "Stage 2 level 5 merge: WP-G facade decisions". It records:
  - **Rulings and decisions:** L5-R1…R23, and the ratified G-1…G-18. The behaviour G-1/G-5 add to §8 is approved for the owner's information (L5-R8); it is not NEEDS-HUMAN-REVIEW, because no public signature changed.
  - **Authorised edits outside WP-G:** `EngineCommands`, `EngineJobs`, `EngineState`, `EngineLifecycle`, `EngineDispatch` (guard only) and `SubscriberQueue` (`.clientEnd`), with the updated WP-F tests (old → new assertion); `AssetStore.unavailableReason` and `verifyRootNow()` (package additions); and the new test files. These go into ARCHITECTURE §1.1/§1.2.
  - **ARCHITECTURE amendments:**
    - §2: P-9's heartbeat and the Kit benchmarks' live clock (L5-R7).
    - §7: the engine's pending claims (L5-R1, G-13); shutdown from `created` (L5-R2); the release-gate guard; the extra terminal slot, with client events never coalesced with each other (§7.9 / H-9, L5-R19).
    - §8: the facade's reopen, its triggers (G-5 with L5-R4/R20), what survives a reopen, the event-continuity promise (L5-R13/R19, G-2/G-16), and the `current()` semantics (L5-R22 (5)).
    - §10: the REENTRANCY rows g-1…g-12 as a new §10.6 `ZTronAssetKit`, numbers kept, plus any new engine rows.
    - §11: credits for R-CAR-3 (claims), R-SYN-12/15, R-STO-9/B-15, R-OBS-3, and R-NET-3's attestation half.
  - **Not verified** (recorded in ADR-054 by reference to g.md; `VERIFICATION.md` is compiled at Stage 5):
    - R-NET-3's run-time half (L5-R5);
    - a real `rootVanished` on a device, and the reopen there;
    - UIKit's background-events hook end to end;
    - the live `MainBundleLookup` against an app bundle with resources;
    - P-8/P-9 on a device;
    - the benchmarks on the simulator;
    - the interleavings g.md lists as untested.
  - **Stage 3 backlog:** L5-R16 (a claim inherits the retry policy) and L5-R22 (1), (3), (4) and the model tightening in (2).
  - No new NEEDS-HUMAN-REVIEW item: the two `AssetStore` additions are package API, not public.

- **L5-R24 (docs merge, 2026-10-23): ADR-054's "Acknowledged at merge" (1)–(5) are confirmed.** Docs workflow `wf_bdef0756-da0`: ledger plus one round, and round 1 verified 0 blocking issues.
  - **(1) Failing-first commits.** The model and the tightened model failed on `666ec0d` (`2e828d1` plus the model and behaviour-neutral seams) and on `a8e3b1d` (`9619770`'s sources plus tests). This meets the intent of L5-R13/R19: the tests failed before the fix. The verifiers also killed each defect as a mutant.
  - **(2) L5-R20's trigger list reads as:** `.storageUnavailable`, `.serverUnavailable`, `.insufficientSpace` and `.integrityFailure` trigger the root check; `.offline`, `.authRejected`, `.notFound`, `.cancelled` and `.shutDown` do not.
  - **(3) `verifyRootNow()` is `async`.** The stat runs on the metadata executor (ADR-003, C2), and it logs one store error line.
  - **(4) `KitContractTests.swift` (G-8)** is an authorised edit (ADR-050's L2 close). It is listed with the other edits outside WP-G.
  - **(5) `current()`.** L5-R22 (5)'s first clause was imprecise. The code's behaviour, as ADR-054 and §8 now state it, is the ruled semantics:
    - a call made after the installation returns the replacement at once;
    - a call already waiting when the installation happens resumes only when the reopen's task ends.

    No requirement needs waiters to resume at the installation, because event continuity rests on the hand-over (L5-R13) and a caller's own call would join the replacement's start anyway. So no code change. The planned rewrite of the `FacadeReopenTests.swift:533-535` comment is **dropped**: that comment is accurate.
  - **The verifier's 8 notes were applied by the orchestrator:**
    - the claim-rule precision (`SyncEngine.swift`/`EngineJobs.swift` doc comments, §7.1);
    - three §14 citations re-pointed (`EngineCommands.swift:287-291`, `:1602`; `EngineJobs.swift:654-657`);
    - a note on the omitted optional §11 credits in ADR-054;
    - the blank line before §10.6;
    - the §2 and §8 precision nits and R-CAR-1's count;
    - ADR-054's 15 ms wording;
    - the API-verification row's L5-R5 wording, and L5-R7 named in ADR-054.

    Three stale test comments were also fixed, comment-only and with line counts kept: `CompositionTests.swift` (ADR-026 (c), CCR-G1 declined) and `FacadeReopenTests.swift` (the L5-R20 root check).
