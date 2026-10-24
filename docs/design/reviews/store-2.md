# Adversarial review #2: `docs/design/store.md`

> **Historical.** A Stage 1 adversarial review of a design draft, kept as written; each finding's resolution is in [ARCHITECTURE.md](../../ARCHITECTURE.md) §12, which with [DECISIONS.md](../../DECISIONS.md) is authoritative.

**Reviewer.** review-store-2. I did not write the design.
**Lens.** Snapshot-vs-deletion and lifecycle races: leases, the grace window and I-3; GC, eviction and prune racing a concurrent resolve, publish or commit; OS purge between launches; idempotence and crash safety of legacy migration; quota, LRU and hysteresis; P-13 batching; whether ≥ 90 % coverage of `ZTronAssetStorage` is reachable.
**Inputs read.** `CLAUDE.md`; SPEC §1.4, §4.2–4.4, §5.2, §5.3, §5.7, §5.9 (R-SEC-2), §6 (P-2, P-5, P-6, P-13), §7.3; `docs/RECON.md`; `docs/DECISIONS.md` (ADR-001…011); `docs/BASELINE.md`; `docs/design/store.md` (all); `docs/design/sync.md` §3.2, §9, §12, §13.3–13.5 (only where the store's lifecycle depends on them).
**Evidence.** Every claim marked *(probe)* was compiled and run in this session in `.build-probe-review-store-2/` (git-ignored by `.build*`). Commands and output are in §3. Nothing was written outside this repository. No file under `Scripts/`, and no `SPEC.md`, `PROMPT.md`, `CLAUDE.md` or design document, was edited.

Section references such as "§4.5" and "store.md:582" point at `docs/design/store.md` unless prefixed `sync`.

---

## 1. Summary

| ID | Severity | Title | Violates |
|---|---|---|---|
| S2-01 | critical | Concurrent publications of one key (cross-id dedupe) corrupt `refCount` and drop orphan protection; apply-time adoption bypasses the blob state machine | I-2, I-3, H-5 (R2–R4), R-CLN-5 |
| S2-02 | critical | Acknowledgement is unconditional: the mirror ignores a snapshot but the store still treats the return as an ack (reopen restarts versions; the sync design's mirror orders by generation) | I-3, H-2 |
| S2-03 | critical | The reaper busy-spins (measured: about 7 M iterations/s, one full core) whenever a key is past `eligibleAt` but blocked by a lease, the commit gate or a failed unlink. It deadlocks outright under nonisolated-nonsending semantics *(probe)*. | P-14, R-SYN-14, C2, H-2 liveness |
| S2-04 | critical | A committed generation can hold `DOOMED ∋ k` while a `present` record references `k`. Launch step 9 then publishes `k` and step 10 unlinks it with no grace. | I-3, I-2 |
| S2-05 | critical (in the design's own crash model) | Power loss leaves a `.part` and its blob as one inode. Launch keeps the pair because of its `.resume`, and a Range resume then appends into the blob. | I-1 |
| S2-06 | major | Eviction ignores bytes that are doomed but not yet freed. Repeat calls inside one grace window over-evict: 10.74 GiB instead of 6.50 GiB in the default fractional policy *(probe)*. | R-CLN-4 (hysteresis), promise 1, R-SYN-11 |
| S2-07 | major | Launch step 10 deletes the previous instance's DOOMED keys immediately. In a same-process reopen (after `shutdown()` or `.rootVanished`) that breaks leases and the grace window. | I-3, R-CLN-5 |
| S2-08 | major | The R-STO-5 op sequence is not deterministic. Store-owned deferred tasks interleave by priority (2 distinct sequences in 2,000 identical runs), and Set/Dictionary order changes on every process start *(probe)*. | R-STO-5, Q-4, Q-5 |
| S2-09 | major | Migration runs inside `open()` before reconciliation. "Publish every 64 adoptions" contradicts "before the first snapshot", and every API, `resolve` included, blocks on hashing the whole legacy catalog. | promise 1, R-STO-11, I-2/I-3 (pre-reconciliation snapshots) |
| S2-10 | major | Legacy paths follow **intermediate** directory symlinks: a file outside the legacy root is read and *moved* into `blobs/` *(probe)*. `standardizedFileURL` consults the file system and strips `/private` asymmetrically. | R-SEC-2, R-STO-6 |
| S2-11 | major | Launch staging GC (7d) deletes a lone `.part` that a background-session delegate handed off after relaunch, so a completed transfer is lost and downloaded again. | H-6, R-NET-3, R-CLN-3 |
| S2-12 | major | The sync design's interface creates URL holders the ack never covers (engine snapshot copies, a public `snapshot`, a two-step verify→commit leaving an unreferenced blob). | I-3, I-2 |
| S2-13 | major | The design never says where the snapshot version and commit generation are allocated. Allocating either after the `await` makes a key eligible on an ack or commit of a state that still contains it. | I-3, I-2 |
| S2-14 | major | The grace premise ("an open fd survives unlink") is false for `UIImage(contentsOfFile:)`, which reloads from the path *(Apple doc)*. The grace clock also runs through sleep and suspension. | H-2, R-CLN-5 |
| S2-15 | major | R4 does not re-check the record's revision, and `publish` can return a URL for a key it just doomed "with no grace". | I-3 contract, I-2, H-5 |
| S2-16 | major | Cross-design build break: the sync design's `@available(macOS 15.0, *)` on suites does not compile *(probe)*. The ADR-014 funnel must also cover `ManualTimeSource`. | Q-1, Q-3 |
| S2-17 | minor | `nextGen = 1 + max(parsed generation)` traps on a bit-rotted header and crash-loops `open()` *(probe)*. | R-STO-4, R-STO-12 |
| S2-18 | minor | A lease taken during eviction's `Task.yield()` can force `makeRoom` to fail after partial marking. | R-SYN-11 |
| S2-19 | minor | LRU input is lossy: the 1,024-id access log with no installs while idle; wall-clock jumps defeat `minimumResidency`. | R-CLN-4 |
| S2-20 | minor | The purge loop has no stated termination ("until the selection is gone") under rescue, lease or `close()`. | R-CLN-6, R-CLN-12 |
| S2-21 | minor | Migration edge cases: the stamp is migrated by vacuous truth, `inProgress` can stick, and an overlap of legacy root and store root lets phase 4 delete the store. | R-STO-11, H-10 |
| S2-22 | minor | A key doomed by quarantine can be rescued by a re-download, which keeps the corrupt file. | R-CLN-8, R-INT-3 |
| S2-23 | minor | 7c re-adopts a key that 7b just flagged for a size mismatch when `byteSize == nil`. | I-2 intent, R-CLN-7 |
| S2-24 | minor | Checksum-less publishes in the P-5 window cannot be adopted, which contradicts the ScenarioRunner and oracle assertions. | R-STO-5 test plan, R-MAN-5 |
| S2-25 | minor | ENOSPC on commit: no way out, unbounded retries, and `requireCommitted` does not say how it fails. | R-STO-6, battery |
| S2-26 | minor | Live-FS tests and benchmarks write to an unspecified temp directory (owner directive), and `LiveLegacyDefaults` cannot be tested without writing `~/Library/Preferences`. | owner directive, Q-2 |
| S2-27 | minor | P-13: what a "batch" is stays undefined (an 11 ms commit unit sits "in between"), and choosing deletable keys is an O(D) scan per batch. | P-13 |

What held after a genuine attempt is in §4.

---

## 2. Findings

### S2-01 — critical — Concurrent publications of one key corrupt `refCount` and drop orphan protection

**Where.** store.md:576–583 (blob table, rescue and dedupe), :623 (R4), :678–681 (§5.3 publish), :728 (apply "adoption by hash"), :864 (migration phase 2).

**Root cause.** `publishingKeys` is a `Set<BlobKey>`. The switch on `blobTable[k]` happens **before** the rename `await`, and the flow after R4 is written as straight-line code. Nothing says the second publisher of the same key waits for the first, nor that the post-await update is read-modify-write. SPEC §4.3 makes deduplication a feature ("identical bytes dedupe"), and parallelism is 4 (R-SYN-3), so two ids with identical bytes publishing at once is an ordinary bulk-sync event.

**Timeline A (refCount overwrite, then a live blob is deleted).**
1. Ids A and B have the same bytes, so the same key `k`. Neither has been published, and `blobTable[k] == nil`.
2. `publish(A)` finishes hashing, sees `nil`, runs `publishingKeys.insert(k)`, submits rename unit U_A and suspends (R4).
3. `publish(B)` finishes hashing and sees `blobTable[k] == nil`, because A has not resumed. It runs `publishingKeys.insert(k)` (a no-op on a Set), submits U_B and suspends.
4. U_A renames `.partA → k`. U_B gets `EEXIST`, removes `.partB` and succeeds.
5. A resumes: `blobTable[k] = live(1)`, A becomes `present(k)`, and `publishingKeys.remove(k)`.
6. B resumes. Following the §5.3 text ("nil → …"), it writes `blobTable[k] = live(1)`, an assignment. Two records now reference `k` but `refCount == 1`.
7. The manifest removes A: `deref(k)` takes `refCount` to 0, so `k` is `doomed(sinceVersion: v)`.
8. Snapshot v, which still contains **B → k**, is acknowledged. The predicate tests `ackedVersion ≥ sinceVersion`, not whether `k` is absent, so `eligibleAt = t + 10 s`.
9. The reaper unlinks `k`. `lookup(B)` returns a dead URL in this process (I-3), and the next launch flags B `needsHeal`, resets the stamp and triggers a full re-sync (I-2 "holds" only through healing).

**Timeline B (the first publisher is superseded).** Steps 1–4 as above. While U_A runs, `apply(M′)` changes A's checksum. At R4, A finds that "some record still expects k" is true (B does), so A does not doom `k`, does not set `blobTable[k]`, and **removes `k` from `publishingKeys`**. Until B resumes, `k` sits on disk, unreferenced and unmarked. An orphan-GC sweep in that window dooms it with `eligibleAt = now` (§6.2). The `mtime` guard does not protect blobs renamed in from old files, such as Apple-pack adoption (§6.10) or the legacy EXDEV/rename paths, which keep their original `mtime`. The reaper deletes `k`. B resumes into its EEXIST branch, which assumed `k` exists, and sets `present(k)` on a deleted file.

**Timeline C (apply-time adoption of a `.deleting` key).**
1. `k` is doomed (A removed) and eligible. `reapEligible` marks it `.deleting(task)` and awaits the unlink unit.
2. `apply(M3)` re-adds A, or adds B, with checksum `k`. §6.1 says "Then adoption by hash (§2.6 7c)". The rescue and dedupe rules (:583) are written only for `publish`, so a naive `blobTable[k] != nil ⇒ present` makes B `present(k)`.
3. `apply` commits and publishes, so `lookup(B)` hands out `k`. The unit unlinks `k`, then "remove K from blobTable" also erases B's reference.

**Fix (smallest).** Make one operation the only way any path gains a reference:
- `acquireReference(k) async`: `.publishing` → await that task; `.deleting` → await the batch; `.doomed` → rescue; `.live(n)` → `.live(n + 1)`; `nil` → caller-specific (rename, or adopt only when the file is known on disk).
- Replace `publishingKeys: Set` with `publishing: [BlobKey: Task<PublishOutcome, Never>]`. The second publisher of `k` awaits the first and takes the dedupe path.
- Every `blobTable` update after an `await` is read-modify-write.
- `apply` adoption and migration phase 2 ("k on disk / in blobTable → present") call the same operation.

The shape typechecks at iOS 15.0 and macOS 12.0 with 0 escapes *(probe `fixes_floor.swift`)*.

**Tests.**
- `R-CLN-5: two identifiers with identical bytes published concurrently keep the blob until both are removed` (inline executor with a gate that holds U_A).
- `R-CLN-2: a superseded publication never leaves its key unprotected while another publication of the same key is in flight`.
- `R-CLN-1: a manifest that re-adds a key being deleted waits for the deletion and re-downloads`.

---

### S2-02 — critical — Acknowledgement does not check whether the sink installed the snapshot

**Where.** store.md:559 (mirror `install` "assigns only if `s.version > current.version` … then returns"), :561 ("the store treats the **return** as the acknowledgement"), :546 ("version strictly increasing **per store instance**"), :605 ("asks the facade to reopen"); sync.md:1069 ("monotonic (older **generations** are ignored)").

**Timeline A (reopen in the same process).**
1. Store instance S1 publishes up to version 500, so the mirror's `current.version == 500`.
2. A pre-commit stat finds the root vanished, or the facade restarts the client after `shutdown()`. The facade opens store instance S2 on the **same mirror**.
3. S2's versions start at 1. Every `install(v ≤ 500)` is ignored by the mirror but **returns**, so S2 counts each as acknowledged.
4. In S2, the manifest removes A, `k` is doomed with `sinceVersion = 7`, and `install(7)` is ignored and returns. After 10 s, `k` is unlinked.
5. The mirror still serves S1's version-500 snapshot. That snapshot references `k` (and anything else S2 has since doomed), so `lookup` hands out dead URLs indefinitely.

**Timeline B (the facade follows the sync design's generation ordering).**
1. `committedGeneration == G`, and the mirror holds snapshot X (generation G) containing `k`.
2. Eviction marks `k` and follows "publish → commit" (store.md:755). The new snapshot Y lacks `k` but still carries `indexGeneration == G`, because the commit comes after.
3. A mirror that ignores "older generations" compares with `>` (equal is ignored) or `≥`, and the text does not say which. Either way, if Y is ignored, `install(Y)` returns, and the store acknowledges Y's version. Once the commit lands, `k` passes the grace and is unlinked while X, which contains `k`, is still current.

**Fix.**
- Order snapshots by one key, `SnapshotKey(epoch, version)`, where `epoch = nextGeneration` at `open()`. It is persisted and strictly increasing across instances (§2.4.1), so the key is monotonic across reopen.
- `install` returns `InstallAck { installed: SnapshotKey, accesses }`.
- The store sets `ackedVersion = installed.version` only when `installed.epoch == myEpoch`.
- A mirror reset (sync §12.7 "the facade empties the mirror") must be an explicit `reset()`, never an install of `.empty`.
- Phase C fixes this in the contract for both designs. The shape typechecks at the floors *(probe)*.

**Test.** `R-CLN-5: a sink that keeps an older or foreign snapshot never counts as acknowledgement` (a fake sink that refuses installs; assert no unlink).

---

### S2-03 — critical — The reaper busy-loops, and deadlocks under nonisolated-nonsending semantics

**Where.** store.md:582 ("exists only while `doomed` is non-empty. It sleeps until the earliest `eligibleAt`"), :578 (deletable needs time ∧ commit ∧ no lease ∧ not publishing), :734 (orphan GC dooms with `eligibleAt = now`); sync.md §9.1/§9.2 (`sleep(until:)` "returns immediately if `deadline <= monotonicNow()`").

**Root cause.** Only time wakes the reaper. Four other conditions gate deletion: leases, `committedGeneration`, `publishingKeys`, and a failed unlink batch. None of them has a wake-up. Once a doomed key is past `eligibleAt` but blocked by any of the four, "sleep until the earliest `eligibleAt`" returns at once, `reapEligible()` finds nothing, and the loop repeats.

**Timeline A (lease).**
1. A video page holds `withAsset` on `k`.
2. The manifest changes A's checksum, the new blob is published and `k` is doomed. The ack arrives and 10 s pass.
3. The reaper's `sleep(until: eligibleAt(k))` now returns immediately on every iteration. The loop runs until the lease is released, which can be minutes or hours of playback.

**Timeline B (orphan GC with no lease involved).**
1. `performMaintenance` runs `collectGarbage`, which dooms orphans with `eligibleAt = now`. The design does not say what `droppedInGeneration` is for an orphan.
2. If it is `nextGeneration`, as in `deref`, and GC does not mark the store dirty, no commit is ever scheduled. The reaper spins until some unrelated mutation commits, possibly never in an idle app.

**Timeline C (EIO).** An unlink batch fails partway. The design gives the failure path no state: the keys stay `.deleting` or go back to doomed with a past `eligibleAt`, so the loop spins, and any publisher re-awaiting the finished batch task loops as well.

**Measured *(probe `reaper_spin.swift`, release, macOS 27, M3)*.**
- Exactly that loop shape against a `LiveTimeSource`-shaped `sleep(until:)`, with one leased, eligible key: **1,402,016 iterations in 200 ms** (about 7 M/s; one core saturated, 3.7 G instructions retired over the probe run).
- The actor stayed reachable (21 µs call latency), because in Swift 6 mode a nonisolated `async` call hops off the actor.
- Compiled with `-enable-upcoming-feature NonisolatedNonsendingByDefault`, the same program **never yields the actor**: `release()` cannot run, and the process was still spinning after 5 s and had to be killed. Under that upcoming default the store deadlocks.
- In tests, a `ManualTimeSource` whose `sleep` returns immediately produces the same spin, which only the 1-minute time limit stops.

**Fix (event-driven, no polling, P-14-clean).**
- The reaper computes its deadline only over keys whose *only* missing condition is time.
- Otherwise it parks on a continuation. `releaseLease`, the commit completion (R5), the ack (R6) and the `publishing` removal (R4) call `poke()`.
- Orphans get `droppedInGeneration = 0`: no committed generation references a key that is absent from `blobTable`.
- A failed unlink returns the keys to `doomed` with exponential backoff on `TimeSource`.
- Lease-blocked and commit-blocked keys keep no task alive, which satisfies the idle introspection of P-14.
- Shape typechecked *(probe)*.

**Tests.**
- `P-14: a doomed key blocked only by a lease leaves the store with no running task and no armed timer`.
- `R-CLN-5: releasing the last lease on an eligible blob deletes it without any time advance`.

---

### S2-04 — critical — A committed generation can contain `DOOMED ∋ k` and a `present` reference to `k`

**Where.** store.md:580 ("remove K from blobTable → `doomedNeedsPruning = true` (a lazy commit drops them from DOOMED)"), :583 (rescue: "doomed → back to `live(1)`", with no statement about the persisted DOOMED), :228 (7a: "never adopted, even if a record expects the same key"), :229 (7b keeps a present record whose blob is on disk), :241–242 (step 9 publishes, then step 10 deletes "No grace is needed").

The design keeps DOOMED as a list with its own lazy pruning, and never states the invariant `DOOMED ∩ referenced = ∅` for a committed generation.

**Timeline.**
1. `k` (A's old content) is reaped. `blobTable[k]` is removed, and DOOMED still lists `k`, waiting for a lazy commit.
2. The manifest reverts A's checksum to `k`, or B with the same bytes is fetched. `publish` sees `blobTable[k] == nil`, renames `k` in and makes A `present(k)`. The `.soon` commit G+1 encodes `records ∋ A → present(k)` **and** `DOOMED ∋ k`.
3. The process is killed.
4. At launch, 7a puts `k` on the delete list. 7b keeps A `present(k)`, because `k` is on disk per the step-4 listing.
5. Step 9 publishes snapshot v1 with A → `k`. Step 10 unlinks `k` with no grace. `lookup(A)` returns a dead URL (I-3), and the next launch flags it `needsHeal`, resets the stamp (7e) and runs a full re-sync.

The rescue path (step 2 via `doomed → live(1)` instead of a fresh rename) produces the same committed state if rescue does not remove `k` from the persisted list in the same mutation.

**Fix.**
1. Encode `DOOMED := { k | blobTable[k] ∈ {doomed, deleting} }` **at capture time**, so it is derived and never a separately maintained list.
2. At load, apply `DOOMED := DOOMED \ { blobs of present records }` and record the repair as a metric, so a buggy older generation cannot delete a referenced blob.
3. `InvariantChecker` asserts `DOOMED ∩ referenced = ∅` on every committed generation.

**Test.** `R-STO-5: a blob reaped and then republished before the lazy commit survives a crash and the next launch`.

---

### S2-05 — critical within the design's crash model — a `.part` and its blob as one inode, then a Range resume writes into the blob

**Where.** store.md:397 ("A file present under both names is therefore possible after power loss, and recovery must tolerate it; it does, because staging GC removes the second link"), :234 (7d **keeps** `(.part, .resume)` pairs younger than 72 h with a parseable `.resume`), :190 (§2.4.2 step 6), R-NET-8 (resume with `Range`).

**Timeline (mode `powerLossDropUnsynced`, per-directory model as specified).**
1. A transfer was interrupted earlier, so `staging/X.part` and `staging/X.resume` exist. It later completes, and `publish` barrier-syncs `X.part` and renames it to `blobs/aa/k`.
2. The next commit barrier-syncs `blobs/aa`, so the blob name is durable. `staging/` is never synced, so its entries revert to the pre-rename state.
3. Power is lost. On disk, `staging/X.part` and `blobs/aa/k` are one inode, and `staging/X.resume` is still present. The design never says that publish deletes it, and if it did, the unsynced deletion would revert anyway.
4. At launch, 7d keeps the pair (young, `.resume` parses), and the engine claims and resumes it.
5. The transport appends with `Range: bytes=<offset>-`, or truncates to the offset recorded in `.resume`, writing into `X.part`, which is the **same inode** as `blobs/aa/k`. Blob `k` no longer matches its name: I-1 is broken for every reader.

**Realism.** APFS commits a cross-directory rename in one transaction *(hint, not verified here)*, so the two-names outcome may be impossible on device. But the design proves I-1 against this model and claims to tolerate the outcome, so the claim is false as written. R-STO-5 scenarios that include a resumable transfer will fail.

**Fix.** In `publish`, `removeItem(X.resume)` before the `F_BARRIERFSYNC` of the `.part`. The barrier is device-wide, so it orders the earlier unlink too. After any crash, a `.part` that is also a blob then has no `.resume` and is deleted by 7d, which only unlinks the staging name.

**Test.** Add a resumable pair to `R-STO-5: crash at every file-system boundary during a first sync…`.

---

### S2-06 — major — Eviction counts doomed-but-unfreed bytes nowhere, so repeat calls over-evict

**Where.** store.md:745–757 (§6.4) and :711 (`budget = 0.5 × (storeUsage + availableCapacity)`). `liveBytes` excludes doomed keys at once, but `availableCapacity` grows only after ack + grace + lease + commit. Every evaluation inside that window sees both the shrunken `liveBytes` and the unchanged free space, and evicts again.

**Timeline.**
1. Default policy, `live = 20 GiB`, `avail = 10 GiB`. The correct single eviction frees 6.50 GiB, down to 13.5 GiB (90 % of 15 GiB).
2. `makeRoom` before a plan, then `performMaintenance`, then `evictIfNeeded` from the engine all run within the 10 s grace.
3. *(probe `evict_sim.py`, the formulas of §6.4 verbatim)*: 2 calls evict 9.42 GiB, and 3 or more evict **10.74 GiB**. That is **4.24 GiB** of LRU content (65 % more than needed) that the planner then downloads again, which is the thrash §6.4 warns WP-F about.
4. With a `.bytes(100 GiB)` budget and a near-full disk (`avail = 200 MiB < reserve = 256 MiB`), every call evicts another 56 MiB without bound: 10 calls take **0.55 GiB** instead of 0.05 GiB.

**Fix.**
- `pendingReclaim = Σ size(k) for k doomed or deleting and unleased`.
- Use `avail′ = availableCapacity + pendingReclaim` in `budget.resolve`, `trigger` and `target`, and in the `makeRoom` dry run. Under the fractional policy the budget then stays invariant while deletion is pending.
- Leased doomed bytes are not reclaimable, so they stay out of `avail′`.

**Test.** `R-CLN-4: evicting twice within the grace window frees no more than evicting once`.

---

### S2-07 — major — Same-process reopen deletes the previous instance's DOOMED keys with no grace and no lease check

**Where.** store.md:242 ("No grace is needed: nothing in this process ever handed these URLs out"), :605 (reopen on `.rootVanished`); sync.md:1010 (`AssetClient.deinit` shuts the engine down; a new client in the same process opens the same root).

**Timeline.**
1. Instance S1: `k` is doomed (content change) and leased by a playing video. Its ack came 2 s ago.
2. The app tears its client down, or the facade reopens. `close()` durably commits `DOOMED ∋ k` and releases the lock.
3. Instance S2's `open()`: 7a puts `k` on the delete list, and step 10 unlinks it **immediately**. The lease, a process-memory object of S1, is gone, and URLs handed out 2 s ago were promised 10 s.
4. If the player re-opens the file, it fails.

Secondary: step 10 runs inside `open()`, so after a large purge (10,000 DOOMED keys, about 450 ms at the measured 2.87 ms per batch) every `resolve` awaits it.

**Fix.**
- Put launch DOOMED keys into `blobTable` as `doomed(sinceVersion: 1, droppedInGeneration: 0)` and let the reaper delete them after the first ack plus grace.
- `open()` returns after step 9. This also gives `publish` the rescue and await path for those keys, closing a step-10-versus-publish race.
- Document that leases end at `close()`, or make `close()` await outstanding leases.
- Synchronous APIs called before `open()` completes (`reserveStaging`, `acquireLease`, store.md:486/495) must throw `.notOpen`, because they cannot await `openTask`.

**Test.** `R-CLN-5: reopening the same root in one process never deletes a blob within the grace window of its last acknowledgement`.

---

### S2-08 — major — The R-STO-5 op sequence is not deterministic

**Where.** store.md:267 ("With an inline executor the whole scenario is deterministic: the same op sequence on every run"), :948 (ScenarioRunner: "for k in 0…N" over the clean run's count), §4.6 (deferred commit task), §4.5 (reaper task), and the Set/Dictionary-ordered op emission in "for each fan-out" (`dirtyDirectories`), "first 64 deletable keys", the delete lists and phase-4 removal.

**Evidence.**
- *(probe `hash_order.swift`)*: Set iteration order differed on **3 of 3** runs and was stable only with `SWIFT_DETERMINISTIC_HASHING=1`. `verify.sh` does not set that variable and is frozen.
- *(probe `interleave_prio.swift`)*: a store-shaped actor whose deferred commit task (`.utility`) is woken by a Mutex `ManualTimeSource`, driven by a `.userInitiated` scenario script: **2 distinct op sequences in 2,000 identical runs**, three times over (1667/333, 1372/628, 1392/608).
- At equal priority the order was stable *(probe `interleave.swift`)*, but the commit landed after `rename3` although the script advanced the clock before `publish(2)`. Its position is set by executor scheduling, not by the script.

**Consequence.**
- "Crash before op k" means a different op on different runs, so a failing (k, mode) cannot be reproduced from its printed index (Q-4).
- `ScenarioRunner`'s N from the clean run need not equal N in the crash run, so the enumeration samples (R-STO-5 forbids that).
- A `requireCommitted` sleeping on a `ManualTimeSource` that the test never advances hangs until the time limit. This includes the P-13 benchmark, which uses `ManualTimeSource`.

**Fix.**
1. Sort every collection before it becomes file ops (fan-outs, delete lists, reap batches, phase-4 listings). This is cheap and typechecked.
2. Give the store a test seam that runs store-owned work deterministically. For example, `StoreScheduling` with `.live` (tasks plus `TimeSource`) and `.manual`, where the deferred commit and the reaper run only when the test calls `await store.runDueWork()`. Alternatively, `ManualTimeSource.waitForSleepers(count:)` plus an awaited `store.quiesce()` after each scenario step.
3. ScenarioRunner asserts that the crash run's op prefix equals the clean run's prefix up to k.

---

### S2-09 — major — Migration inside `open()` blocks every API and would publish snapshots before reconciliation

**Where.** store.md:226 ("It runs here, inside open(), before the first snapshot"), :862 ("publish snapshot every 64 adoptions so lookups start hitting"), :620 (R1: "other APIs await `openTask`"), :889 (risk R4: about 0.4 s/GB on the M3, more on older devices).

**Timeline.**
1. First launch after the update. The legacy catalog is 2 GB, and phase 2 hashes it all inside `open()`: about 0.8 s on the M3 and several seconds on an A12-class device *(hint: device throughput unverified, risk R2)*.
2. Throughout, `lookup` returns `nil`, because the mirror is still empty. The prior art's `existingLocalURL` served these files offline at once (RECON §5).
3. The carousel's fallback chain goes to step 3, `resolve`, which awaits `openTask`. The user waits on a blank page, against promise 1.
4. If the "every 64" publication *is* implemented, those snapshots are built **before** step 7. A pre-existing record `present(k)` whose blob vanished, which 7b will flag `needsHeal`, is served, and DOOMED keys (7a) are not yet removed. That hands out URLs that step 10 deletes.

**Fix.**
- `open()` does the lock, the load, reconciliation 7a–7e on the existing index, phase 1 (cheap: `local-checksums.json` covers almost every file) with its ordered commit, and then the first snapshot.
- Phase 2 becomes a store-owned, resumable task after `open()` returns, publishing progressively.
- A `resolve` or `acquireLease` for a legacy id that is not yet adopted moves that file to the front of the queue (adopt on demand). That is one hash, far cheaper than a download.
- Crash safety is unchanged, because phase 2 is already idempotent per file (R11).

**Test.** `R-STO-11: lookups hit adopted legacy files while migration is still running, and no snapshot precedes reconciliation`.

---

### S2-10 — major — R-SEC-2: legacy paths follow intermediate directory symlinks

**Where.** store.md:844 (component rule, "The standardized path must have `root` as a prefix. Symlinks are never followed."), :858 (`streamingSHA256(L)`), :867 (`rename(L → blob)`); test name :1044.

**Evidence *(probe `symlink_paths.swift`, live FS inside the probe directory)*.**
1. Setup: `CDNAssets/images → ../AppDatabase`, and the entry's `localPathComponents ["images"]`, name `hero`, ext `png`. Every component passes the rule.
2. For `L = CDNAssets/images/hero.png`, resource values give `isSymbolicLink=false isRegularFile=true`, so a kind check on `L` does not catch it.
3. `FileHandle(forReadingFrom: L)` read `"precious"` from `AppDatabase/hero.png`. The unstandardized prefix check passes.
4. `rename(L → blobs/ab)` returned 0, and **`AppDatabase/hero.png` no longer exists**: a file from outside the legacy root, which could be any app data, was moved into the store and later deleted by eviction or GC.
5. `URL.standardizedFileURL` gives `/private/tmp` → `/tmp` (the path exists) but leaves `/private/tmp/<missing>` unchanged. It consults the file system, so it is asymmetric, and it is Foundation I/O outside the `FileSystem` seam (R-STO-6).

**Fix.**
- Drive phases 1, 2 and 4 from the non-following recursive listing. `contentsOfDirectory` reports `.symbolicLink` for the link itself, so the listing never descends into a linked directory.
- Match each manifest entry's computed relative path against the listed regular files, and drop entries whose path is not listed.
- Drop the standardization prefix check: once components are validated, it adds nothing.
- Add an intermediate-symlink case to the FileSystem conformance suite (fake and live must agree).

**Test.** `R-SEC-2: a legacy entry whose directory component is a symbolic link is dropped and nothing outside the legacy root moves`.

---

### S2-11 — major — Launch staging GC deletes a background-session hand-off (H-6)

**Where.** store.md:234 (7d keeps only pairs with a parseable `.resume`; "everything else → delete list"), :268 (the delegate renames the URLSession temp file into a staging URL synchronously).

**Timeline.**
1. A background download completes while the app is dead.
2. On relaunch, the app re-creates the background session at startup. `didFinishDownloadingTo` is delivered, and the delegate renames the temp file to `staging/<id>.part`. The id travels in `taskDescription`, and a background download has no `.resume` file.
3. `open()` runs concurrently. Its step 5 lists `staging/` after that rename, and 7d puts the lone `.part` on the delete list. Step 10 deletes it.
4. The engine re-attaches the task (`getAllTasks`), but the bytes are gone, so the asset is downloaded again. H-6 requires re-attaching, not duplicating.

At runtime, `collectStaging(keeping:)` takes the engine's claim set, which can miss a reservation made after the engine computed it. Keep `passed ∪ store-side live reservations`.

**Fix.**
- 7d keeps any unclaimed `.part` or `.resume` younger than a `stagingClaimGrace` (`mtime ≥ now − 1 h`).
- Alternatively, `open(claimed:)` receives the transport's re-attached staging ids (WP-D/F contract).
- Runtime staging GC never deletes a store-side reservation.

**Test.** `R-CLN-3: a staged file handed off by a relaunched background session survives launch staging GC`.

---

### S2-12 — major — URL holders that the acknowledgement does not cover (cross-design, Phase C)

**Where.** sync.md:184 and :188 (`apply(…) -> AssetSnapshot`, `commit(…) -> AssetSnapshot`, `verify(…) -> VerifiedBlob` then a separate `commit`), sync.md:1067 (`public private(set) var snapshot: AssetSnapshot`), sync.md:1110 (`resolve` fast path "if present"), sync.md:192 (engine-driven GC versus the store's reaper, store.md:582).

**Timeline A (engine snapshot copy).**
1. The engine keeps snapshot S5, returned by `commit`, which contains `k`.
2. The store publishes S6 without `k`, and the mirror acknowledges it at t0.
3. At t0 + 11 s, `k` is reaped.
4. At t0 + 12 s, `resolve(A)` takes the engine's fast path from S5 and returns the URL of `k`, which is already deleted.

**Timeline B (two-step publish).**
1. `verify` publishes `k` unreferenced and returns `VerifiedBlob`. `publishingKeys` no longer contains `k`, and `blobTable[k] == nil`.
2. Before the engine calls `commit`, an orphan-GC sweep sees `k`. A pack file adopted by rename keeps its weeks-old `mtime`, so the 1 h guard does not protect it. GC dooms `k` with `eligibleAt = now`, and the reaper deletes it.
3. `commit` then references a deleted blob (I-2).

A related conflict: both designs claim the GC timer, the engine's alarm on one side and the store's reaper task on the other. P-14 needs exactly one owner.

**Fix (Phase C contract).**
- Only sinks registered with the store's ack protocol may derive URLs from a snapshot. The engine hands out URLs only through `store.location(for:)`, which reads current actor state.
- `AssetSnapshot` stays `package`, and the mirror exposes `lookup`, not the snapshot.
- `VerifiedBlob` carries a provisional reference counted in `blobTable` until `commit` or release.
- One owner wakes the reaper.

---

### S2-13 — major — Where the snapshot version and commit generation are allocated is unspecified

**Where.** store.md:576 (`deref`: `sinceVersion: nextSnapshotVersion, droppedInGeneration: nextGeneration`), :176 ("incremented for every commit **attempt**"), :592 (commit captures `indexState`, and the actor keeps serving).

**Timeline (generation allocated at completion).**
1. A commit captures a state that still references `k` and is in flight, with `nextGeneration == N`.
2. During the unit, `deref(k)` records `droppedInGeneration = N`.
3. The unit succeeds and `committedGeneration = N`, so `k` is deletable after ack and grace. But generation N on disk references `k`.
4. `k` is unlinked, and the process crashes before N+1. At launch the record is `needsHeal`, 7e treats this as an OS purge, and the stamp reset forces a full re-sync.

The same pattern applies to the snapshot version: a version incremented after `await install` resumes lets an ack of a snapshot that contains `k` cover it.

**Fix.** State normatively that the version and the generation are allocated synchronously **at capture** (snapshot built or state captured), before any `await`. Add an interleaving test: a fake executor or sink that runs `deref` during the await, then asserts no unlink until a later commit or ack.

---

### S2-14 — major — The grace premise does not hold for real consumers

**Where.** store.md:63 ("On Darwin an already open file descriptor survives `unlink`, so the grace window only has to cover 'URL obtained but not yet opened'"), :568 (monotonic clock).

**Evidence.**
- Apple documentation for `UIImage(contentsOfFile:)` (fetched this session): *"loads the image data into memory and marks it as purgeable. If the data is purged and needs to be reloaded, the image object loads that data again from the specified path."* The SDK header carries no such note, which I checked.
- The sync design's `LiveTimeSource` uses `CLOCK_MONOTONIC`, which "keeps counting during device sleep" (sync §9.1).

**Timeline A.**
1. A page displays image A through `UIImage(contentsOfFile: url)`.
2. A content update publishes A′ and dooms the old blob, which is unlinked 10 s later.
3. Under memory pressure UIKit purges the decoded data and reloads from the path, and the image goes blank.

**Timeline B.**
1. The UI obtains a URL and enqueues a decode.
2. The app is suspended for an hour.
3. On resume, the reaper's deadline has long passed and it may run before the decode, so the reader never had its 10 s.

**Fix.**
- The public contract says "open or read within `deletionGrace`, or hold a lease". The R-CAR-2 adoption guidance in `MIGRATION.md` loads images through `Data`, or holds a lease while displaying. `AVURLAsset` playback uses `withAsset`.
- Measure grace on `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)`, which stops in system sleep (typechecked at iOS 15).
- Require one fresh ack round-trip, a no-op re-install, **after** the deadline and before each unlink batch. That proves the main actor ran after the wait.

---

### S2-15 — major — R4 is incomplete: wrong residency, and a URL with no grace

**Where.** store.md:623 (R4 "doom `k` immediately (it was never in a snapshot, so no grace is needed…)"), :680–682 (§5.3 continues with `.present(k…)` and returns the URL).

**Timeline.**
1. `publish(A)` passes R2 against revision r1 and submits the rename.
2. During the unit, `apply(M2)` changes A's checksum (revision r2).
3. R4: no record expects `k`, so `k` is doomed "immediately".
4. The §5.3 text then makes A `present(k, verified: true)`, with stale content marked verified and referencing a doomed key, and **returns `AssetLocation(k)`** to the engine.
5. The engine hands the URL to a `resolve` waiter, and the reaper deletes `k` at once. A handed-out URL vanished in under `deletionGrace`, against the contract stated at store.md:66.

**Fix.** R4 re-runs the R2 check: same revision, or digest equals the new expectation. On failure, throw `.superseded`, never return the URL, and leave A's residency untouched. Only then may `k` be doomed (droppedInGeneration 0, no grace, since it was never handed out).

**Test.** `R-INT-2: a manifest change during the publish rename yields superseded and never returns the URL`.

---

### S2-16 — major — Cross-design build break: `@available` on suites

**Where.** sync.md:749 ("Suites that use it are annotated `@available(macOS 15.0, *)`"); store.md:416–417 (ADR-014 funnel for `FakeFileSystem` and `FakeLegacyDefaults` only).

**Evidence *(probe package `avail/`, `swift build --build-tests`)*.** A Mutex-backed `ManualTimeSource` stand-in plus exactly that annotation fails to build: *error: Attribute 'Suite' cannot be applied to this structure because it has been marked '@available(macOS 15.0, *)'*, and the same error appears for the `@Test` inside. This reproduces the store drafter's finding, now against the sync design.

**Fix.** ADR-014 covers **every** Mutex fake in `ZTronAssetTestSupport`: `makeManualTimeSource() -> any ManualTimeControl` and the same funnel for the remaining fakes. Suites stay unannotated. Phase C must reconcile the two designs before contract code.

---

### S2-17 — minor — A bit-rotted header crash-loops `open()`

**Where.** store.md:176, :208 (`nextGen = 1 + max(generation of every header that parsed)`, *valid or not*).

**Evidence *(probe `hash_order.swift trap`)*.** `1 + UInt64.max` traps (exit 133).

**Timeline.** Bit rot leaves a candidate's magic intact but its generation at `0xFFFF…`. Every `open()` traps, and the app crash-loops at launch. The fuzz test (store.md:993) decodes bytes but does not go through the load rule.

**Fix.** Ignore unverified headers whose generation is ≥ 2^62 (or use the generation from trailer-valid files only, plus a saturating `+ 1`). Fuzz through `open()`.

---

### S2-18 — minor — `makeRoom` can fail after partially marking

**Where.** store.md:754 (chunks of 1,000 with `Task.yield()`; R8 skips candidates that became leased), :758 ("throws … with **no side effects**").

**Timeline.**
1. The dry run says 2 GiB can be freed.
2. Chunk 1 marks 1 GiB, then `Task.yield()`.
3. `withAsset` leases the largest remaining candidate, so chunk 2 skips it.
4. The shortfall now exceeds the request. Throwing `.insufficientSpace` leaves 1 GiB evicted, which is a side effect (R-SYN-11).

**Fix.** Either continue past the planned prefix to the next LRU candidates, or roll the marks back. Rollback is possible because nothing is deleted before ack and commit: `records → present`, keys rescued.

---

### S2-19 — minor — LRU input is lossy

**Where.** store.md:560 (access log "capacity 1,024 distinct ids; overflow drops the oldest"), :562 (installs happen only after mutating calls), :752 (`now − r.lastAccess` on the wall clock); sync.md:1077 says "bounded by catalog size", which contradicts the store design.

**Timeline A.** The app sits idle, so no mutations and no installs. The user browses 3,000 pages over a day. Only the last 1,024 accesses survive to the next drain, so 1,976 recently viewed assets keep old `lastAccess` values and are evicted first.

**Timeline B.** The user sets the date forward 2 days. Every `now − lastAccess ≥ 24 h`, so `minimumResidency` no longer protects anything.

**Fix.** Use a catalog-bounded `[AssetID: Date]` (latest wins, ≤ N entries) as sync.md specifies. Clamp `lastAccess > now` to `now`. For accesses made in this process, compare on the monotonic clock.

---

### S2-20 — minor — The purge loop has no stated termination

**Where.** store.md:768 ("`reapEligible()` until the selection is gone").

**Timeline.**
1. `purge(.all)` dooms `k` for A.
2. A `userInitiated` resolve, re-queued per sync §12.4 step 3, downloads the same bytes and rescues `k`, which is live again.
3. If the loop condition is "selected keys gone from `blobTable`", it never ends.
4. Likewise, `close()` during the purge's grace sleep leaves the purge calling `reapEligible()` on a closed store.

**Fix.** Loop until each selected key is reaped, rescued (it counts in neither `bytesFreed` nor `bytesDeferred`) or leased (counted in `bytesDeferred`). Check `closed` after every await (R9).

---

### S2-21 — minor — Migration edge cases

**Where.** store.md:849–876.

1. **Vacuous truth.** An undecodable legacy `manifest.json` (degraded hash-blind path) yields zero legacy records, so `allAdopted` (store.md:871) is true and the stamp is migrated, which contradicts :885 ("never falsely claimed"). It is harmless today only because the update always changes the app version. **Fix:** never migrate the stamp on the degraded path.
2. **Stuck `inProgress`.** The legacy root vanishes after phase 1. The rule at :851 returns without setting `legacyState = done`, so every launch re-stats it. **Fix:** set `done`, with `stamp` nil and `syncDue`.
3. **Root overlap.** `LegacyLayout.root` is overridable (:821) and `.custom` roots exist. If the legacy root contains the store root, or the reverse, phase 4's recursive removal deletes the store, including `store.lock` and `index.bin`. **Fix:** refuse migration unless the two roots are disjoint, checked on the validated, unstandardized component paths.
4. **Compatibility shims.** R-CAR-6 shims in this repo (ADR-006) must not write `Caches/CDNAssets` or the legacy key. Otherwise phase 4 deletes shim-written files on every launch, because the `done` branch re-runs phase 4 whenever the root exists. Cross-WP note for the shim owner.

---

### S2-22 — minor — Rescuing a quarantined key keeps the corrupt file

**Where.** store.md:583 (rescue "staged duplicate removed"), §6.6 (quarantine derefs), §5.6 (deep verification routes to quarantine).

**Timeline.**
1. Blob `k` rots on disk. `verifyIntegrity` or `reportUnreadable` quarantines A for 60 s and dooms `k`.
2. `k` is still leased (a player in an error state holds `withAsset`), so it is not reaped.
3. After 60 s the engine re-downloads the correct bytes, which hash to `k`.
4. `publish` sees `doomed` and rescues: it **deletes the good staged copy** and keeps the corrupt file. Readers hit corruption again, and after 3 attempts A is `failed(.integrity)`, although the server is fine.

**Fix.** Doom quarantine-originated keys as `corrupt`, which is not rescuable. Publishing such a key replaces it with `rename(.replacing)`: readers with open descriptors keep the old inode, and I-1 holds afterwards.

---

### S2-23 — minor — 7c re-adopts a key that 7b just flagged

**Where.** store.md:229 (7b: size ≠ `blobSize` → `needsHeal(k)`), :231 (7c adopts when `r.byteSize == nil ∨ r.byteSize == size`).

**Timeline.**
1. External truncation (or a non-APFS `.custom` volume with the fsync fallback, R3) leaves `k` short.
2. 7b flags A `needsHeal`.
3. 7c sees `k` as unreferenced, and A's manifest entry has no `byteSize` (legacy optional), so it adopts `k` again as `present`. The corrupt file is served.

**Fix.** A key whose on-disk size contradicts a recorded `blobSize` goes on the delete list as foreign, and 7c skips it.

---

### S2-24 — minor — Checksum-less publishes in the P-5 window cannot be adopted

**Where.** store.md:447 (`expectedBlob = entry.checksum ?? legacy plannedHash`), :245, :948 (ScenarioRunner asserts that downloads after reopen cover "only assets whose publish had not returned"), :1058 (the oracle: "present again or adoptable").

**Timeline.**
1. A checksum-less, non-legacy entry is published, the URL returned, and the commit is coalesced.
2. The process is killed.
3. At launch `expectedBlob == nil`, so the blob is an orphan and is deleted, and the asset is downloaded again. The scenario assertion fails, or has to be silently weakened (G3).

**Fix.** Either `publish` of a checksum-less entry runs `requireCommitted(.ordered)` before returning (these entries are rare), or the test plan exempts them explicitly, with the reason recorded in the design.

---

### S2-25 — minor — No way out of ENOSPC on commit

**Where.** store.md:177, :784–788.

**Timeline.**
1. Another app fills the disk.
2. The commit (3 × 1.43 MiB on disk at peak: bin, prev and tmp) fails, so keys doomed after the last committed generation cannot be deleted. Eviction only creates more such keys.
3. The store retries 4 times a second, each time writing 1.4 MiB plus `F_FULLFSYNC`, until "N failures". The design does not say how `requireCommitted` callers learn that the attempt covering their generation failed.

**Fix.**
- On ENOSPC, remove `index.prev` first. It is only a fallback, and removing it frees 1.4 MiB, enough for the tmp.
- Back off exponentially on `TimeSource`.
- `requireCommitted` rethrows the failure of the attempt that covered `g`.

---

### S2-26 — minor — Test directories and `LiveLegacyDefaults` coverage

**Where.** store.md:933 ("per-test temporary directory"), :1046 (benchmarks on the live FS: P-6 writes 256 MiB, P-13 writes 10,000 files), :835 (`LiveLegacyDefaults`).

**Problem.**
- The design does not say where the per-test directory is. `FileManager.temporaryDirectory` is `/var/folders/…`, outside the repository, which the owner directive forbids.
- `LiveLegacyDefaults` cannot be exercised meaningfully on macOS without writing a plist under `~/Library/Preferences`.

**Fix.**
- Per-test directories under a git-ignored repo path derived from `#filePath`, for example `.build-test-fs/<test-uuid>/`, created and removed by the test.
- Keep `LiveLegacyDefaults` at about 10 lines and accept it uncovered: about 0.3 % of a ~3,000-line target, well inside the 10 % slack. Do not write a coverage-only test (G4).

---

### S2-27 — minor — P-13 wording and an O(D) selection

**Where.** store.md:579 ("K = first 64 deletable keys"), :794 ("One commit unit (~11 ms) runs in between. Budget … batches ≤ 5 ms"); SPEC P-13 ("batches ≤ `batch_ms_max` ms between suspension points").

**Problem.**
- If the benchmark measures metadata-unit durations, the 11 ms commit unit fails 5 ms. If it measures actor gaps, the 2.87 ms unlink units do not count either. The design must say which.
- "First 64 deletable keys" is a scan over every doomed key per batch: 157 batches × 10,000 keys at 10,000 blobs, and 10× that at the R-MAN-2 limit of 100,000 entries. At that limit one scan is about 5–10 ms on the actor *(estimate, not measured)*.

**Fix.**
- Define P-13's measured interval as (a) the longest actor turn between suspension points and (b) each deletion unit's duration, with the commit unit governed by P-5 instead.
- Keep a ready queue (a min-heap on `eligibleAt` plus a deletable FIFO) so each batch is O(64 log D).

---

## 3. Evidence (run in this session)

Directory `.build-probe-review-store-2/`, git-ignored. Toolchain: Apple Swift 6.4 (swiftlang-6.4.0.34.1), macOS 27 host, M3.

| Probe | Command | Output |
|---|---|---|
| `reaper_spin.swift`: the §4.5 reaper shape with one leased, eligible key | `xcrun --sdk macosx swiftc -O -swift-version 6 -strict-concurrency=complete -parse-as-library -target arm64-apple-macos12.0 reaper_spin.swift`; `/usr/bin/time -l ./reaper_spin` | `reaper iterations while leased (200 ms window): 1402016` · `actor call latency during spin: 21.0 us` · `after release: … deleted=["k"] elapsed=207 ms` · `3712445947 instructions retired` |
| the same with `-enable-upcoming-feature NonisolatedNonsendingByDefault` | run for 5 s | `STILL RUNNING after 5 s => store actor monopolised (deadlock: release() never runs)` (killed) |
| `hash_order.swift`: Set and Dictionary order across processes | 3 runs; 2 runs with `SWIFT_DETERMINISTIC_HASHING=1` | 3 different orders (`1f,4d,ad,…`, `5e,7a,ad,…`, `6f,00,4d,…`); identical with the variable set |
| the same, `trap` argument | `./hash_order trap` | `exit=133` (`1 + UInt64.max` traps) |
| `interleave.swift`: deferred commit task woken by a Mutex `ManualTimeSource` | `-target arm64-apple-macos15.0`, 2 × 2,000 runs | `distinct op sequences over 2000 identical runs: 1` · `rename1 rename2 rename3 commit rename4` (the commit lands after `rename3`, although the clock was advanced before `publish(2)`) |
| `interleave_prio.swift`: same, store task `.utility`, scenario `.userInitiated` | 3 × 2,000 runs | `2` distinct sequences each time: 1667/333, 1372/628, 1392/608 |
| `symlink_paths.swift`: legacy path through an intermediate directory symlink; standardization | `./symlink_paths "$PWD/fs-sandbox"` | `final component isSymbolicLink=false isRegularFile=true size=8` · `FileHandle read through intermediate symlink: precious` · `prefix check on unstandardized path: true` · `rename(L -> blobs/ab) = 0; outside file still exists: false` · `standardizedFileURL(/private/tmp) = /tmp` · `standardizedFileURL(/private/tmp/<missing>) = /private/tmp/does-not-exist-ztron-probe` |
| `avail/`: the sync design's suite annotation | `swift build --build-tests --scratch-path ../.build-avail` | `error: Attribute 'Suite' cannot be applied to this structure because it has been marked '@available(macOS 15.0, *)'` (and the same for `Test`) |
| `evict_sim.py`: the §6.4 formulas, k calls inside one grace window | `python3 evict_sim.py` | fractional budget, live 20 / avail 10 GiB: 1 call 6.50 GiB, 2 calls 9.42, ≥ 3 calls **10.74** (over-eviction 4.24 GiB); `.bytes(100 GiB)`, avail 0.2 GiB: 10 calls 0.55 GiB instead of 0.05 |
| `fixes_floor.swift`: shapes of the proposed fixes (`SnapshotKey`/`InstallAck`, publishing single-flight map, read-modify-write reference acquisition, reaper `poke`, `CLOCK_UPTIME_RAW`, saturating generation, sorted fan-outs) | `bash .build-probe-store/typecheck.sh fixes_floor.swift` (iOS 15.0 and macOS 12.0, Swift 6, strict concurrency, warnings as errors) | `== arm64-apple-ios15.0 … exit=0`, `== arm64-apple-macos12.0 … exit=0`; `grep` of the unsafe-gate patterns: `0` |
| Apple documentation | `developer.apple.com/tutorials/data/documentation/uikit/uiimage/init(contentsoffile:).json` | Discussion: *"…marks it as purgeable. If the data is purged and needs to be reloaded, the image object loads that data again from the specified path."* `UIImage.h` in the iPhoneOS 27 SDK carries no such note (grep). |

---

## 4. Areas attacked that held

- **Index commit and load rule (H-1, I-5).** I walked every crash point of §2.4.1 under process kill, torn write, and both power-loss modes. That includes a stale *valid* tmp left by an attempt whose `F_FULLFSYNC` failed and whose best-effort removal also failed: the load picks a state the store really held in memory, deletions waited for commits, and nothing breaks. "No `index.bin`" between steps 4 and 5 resolves correctly. Within one store instance, `storeID` filtering and "tmp may win" are sound. Only S2-17 survived.
- **Ordering of unlink after commit (I-2 under power loss).** The unlink unit is submitted after the commit's root `F_BARRIERFSYNC` on the same serial metadata queue. With a device-level barrier (as specified, risk R3), an unlink cannot persist without the generation that dropped the reference. Held.
- **Interrupted purge and eviction across a crash (F8, F9).** The DOOMED section finishes the deletion, and the absent `.purged`/`.evicted` records are never re-adopted (7a). Held, apart from the DOOMED-versus-referenced hole in S2-04.
- **OS purge between launches (R-CLN-7).** Deleting `blobs/`, the root, half the blobs, single fan-out directories, or only `staging/` is each detected or harmless. Fan-out re-creation is visible through the step-4 listing. The stamp lives inside the root, so a vanished root is a fresh store with a sync due. D-6 cannot recur. Held. *(Not verified: whether iOS purges `Caches` of a **suspended** app. If it does, a `.caches` root serves dead URLs until the next commit's lock stat. This needs a device check; see `DEVICE-TEST-PLAN.md`.)*
- **Migration crash table (H-10).** Phases 1 to 4 under every crash mode, including a legacy file present under both names after power loss, the EXDEV copy fallback leaving a partial staging file (collected by 7d, then redone from L), a crash between the durable "done" commit and key removal, and the legacy directory vanishing after phase 1 (stamp not migrated, sync due). Idempotence held. Remaining issues are S2-09, S2-10 and S2-21.
- **Rescue during `.deleting` (R3), concurrent `reapEligible` callers (purge and reaper), leases.** Marking is synchronous, so two reapers never choose the same key. Leases attach only to live keys, are keyed by `BlobKey`, and survive content changes correctly. Within one instance, an out-of-order install delivery under *version* ordering cannot acknowledge a key that a later snapshot contains (the doomed key is absent from every later snapshot unless rescued, which un-dooms it). Held.
- **Budgets.** P-2: reading `bin` and `prev` (the load rule validates all candidates) roughly doubles the measured 2.8 ms, still far under 25 ms. P-5: the rate is ≤ 4/s by construction, and failed attempts are rate-limited too. P-6: the design holds at the measured 0.81× ratio with a 1.77 MiB delta. P-13: at 10,000 blobs, 157 units × 2.87 ms ≈ 450 ms, under 2 s. Remaining issues are S2-27 and the determinism caveat in S2-08.
- **Coverage ≥ 90 % for `ZTronAssetStorage` is reachable.** `LiveFileSystem` decisions are pure functions (`syncOutcome`, the errno and Cocoa mappers) with table tests. EACCES comes from `chmod 000` on a repo-local directory, and EXDEV and ENOSPC come through the fake. The iOS-only protection branch is compiled out on macOS. The fakes sit in excluded `ZTronAssetTestSupport`. The live executor, lock and attribute paths run on macOS. The only structurally uncoverable code is `LiveLegacyDefaults` (about 10 lines, S2-26). No seam is missing for the 90 % floor once S2-08's deterministic scheduling seam exists, because that seam is also what makes the reaper and deferred-commit branches reachable without sleeping.
- **iOS 15 and macOS 12 availability, and the unsafe gate.** Every API in this lens, and every proposed fix, typechecks at both floors with 0 escapes (`fixes_floor.swift`). The design needs no `@unchecked`, `nonisolated(unsafe)` or pointer API in production. The only availability coupling is the test-fake funnel, whose cross-design gap is S2-16.
