# ADR drafts — Stage 3 WP-B storage core, close-out cycles 1 and 2 (`wp/s3b`, from `s3-base`)

Items, levels and rulings come from `.build-orchestrator/s3-rulings-s3b.md`; each finding's evidence from
`.build-orchestrator/s3-findings-s3b.json`. Commits are on `wp/s3b`; a bug's failing test is committed on its own before
its fix (CLAUDE.md P3). Every new test follows SPEC 7.2 (display name starting with the requirement, `.timeLimit` on
anything that awaits, `ManualTimeSource` only, no sleeps) and ADR-051's gating (`@available(macOS 15.0, iOS 18.0, *)` on
the `@Test` function; CPU-bound case loops yield once per case). WP-B's Stage 2 record is `docs/adr-drafts/b.md`.

## Orchestrator rulings (Stage 3 close-out)

Recorded as given (`s3-rulings-s3b.md`), each as "Orchestrator ruling (Stage 3 close-out)"; the file is unchanged for
close-out cycle 2, so each stands as "Orchestrator ruling (close-out)" for that cycle too, with the cycle-2 findings
(`.build-orchestrator/s3b-probes-c1/`) answered under their items and in "Close-out cycle 2 findings" below:

- **S3-R1 Scope and order.** BLOCKING first (failing test on its own, then the fix), then REQUIRED, then OPTIONAL;
  ADR-RECORD items get an entry here and no code; items not listed are out of scope.
- **S3-R2 Probes.** Hunters' and confirmers' probes and mutant diffs are evidence to copy and adapt; committed tests follow
  SPEC 7.2 and ADR-051; probe suites are renamed into the owning suites; replays of a bug's old ordering are not committed.
- **S3-R3 Mutation survivors.** Write the missing test, re-apply the mutant in a scratch copy, show the new test fails, paste
  the failing line.
- **S3-R4 Hang guards.** `.timeLimit(.minutes(1))` by default; a raise only with TSan measurements under moderate load;
  never cut operations, seeds, crash points or assertions; cheaper steps are welcome; long loops check cancellation.
- **S3-R5 C2 at the reference scale.** Bound the work per turn or move pure computation off the actor; pin with a C2
  benchmark (no literal P-n threshold) and a structural unit test where possible; load-only misses are not blocking.
- **S3-R6 Shared files.** No public or package signature change; no edit of `Package.swift`, `Scripts/`, `SPEC.md`,
  `docs/ARCHITECTURE.md`, `docs/DECISIONS.md`, `docs/TRACEABILITY.md`, `docs/ORCHESTRATION.md`, `README.md`,
  `docs/MIGRATION.md` or any `*ContractTests.swift`; document changes are proposed below.
- **S3-R7 Parallel close-outs.** Six close-outs from `s3-base`, merged in the order ah, b, c, d, f, g; no dependence on
  another package's Stage 3 change; edit only WP-B's files plus authorised edits.
- **S3-R8 Strict bar.** Fixes in another package's files are reported non-blocking as `other-wp:<wp>:`.
- **S3-R9 Records.** This file: one entry per item, then authorised edits, proposed document changes, not verified here.
- **Items S3B-1 … S3B-14** as listed in the rulings file; each is answered below under its id.

## S3B-1 — `availability` saturates the missing-byte sum (BLOCKING, S3-SECU-01) · fixed

- **Finding.** `currentAvailability(of:)` summed the manifest's declared sizes of missing entries with a trapping `+=`
  (`AssetStore+Reads.swift:70` and `:85` at `s3-base`). Under the public, documented `maxAssetBytes = Int64.max`, two
  entries of 2^62 bytes a manifest declares crash the process on the first `availability(scope:)` or
  `ensureAvailable(scope:)`.
- **Failing test first (`1cd68b2`).** `StoreSnapshotTests.availabilitySaturatesBytesMissing`, display name
  `R-MAN-2: availability saturates bytesMissing at Int64.max instead of trapping when missing entries declare sizes summing past it`
  (the probe adapted: three 2^62-byte entries through the real `ManifestDecoder`, plus an exact one-entry scope). Run on
  the unfixed code: the test process exited with `unexpected signal code 5`; the crash report
  (`swiftpm-testing-helper-2026-10-29-105859.ips`) shows `EXC_BREAKPOINT / SIGTRAP`, `Swift runtime failure: arithmetic
  overflow`, `AssetStore.currentAvailability(of:) AssetStore+Reads.swift 85` → `AssetStore.availability(of:)
  AssetStore.swift 99` → `StoreSnapshotTests.availabilitySaturatesBytesMissing() StoreSnapshotTests.swift 128`.
- **Fix (`92ed2a8`).** The two branches (no record; `absent`/`needsHeal`) are one `switch` case over the optional
  residency, whose single addition is `report.bytesMissing.addingSaturating(max(0, entry.byteSize ?? 0))` (the store's
  existing `Int64.addingSaturating`). The no-record branch was unreachable (only `apply`'s prune removes records, and it
  removes only ids the manifest no longer lists), so merging it leaves no uncovered line. The test passes: `✔ Test run with
  7 tests in 1 suite passed` (`StoreSnapshotTests`).
- **Every other sum in WP-B's files, checked.** No other sum adds manifest-declared sizes:
  - `AssetStore+Reads.swift` `measureFreeSpace()` (`used += bytes`, `pending += bytes`) and `AssetStore+Reaper.swift`
    `reap(maxKeys:)` (`result.bytesFreed +=`, `result.bytesDeferred +=`) add `blobBytes` values. Every writer of
    `blobBytes` stores a size confirmed on disk: launch reconciliation binds only when `onDisk[key] == size`
    (`LaunchReconciliation.swift` 7b, 7a, the corrupt branch and 7c), `adoptKnownBlob` takes a live or rescuable key's
    known size or an orphan's re-statted size, a publication its verified `byteCount` (`AssetStore+References.swift`), and
    `doomOrphans` the listed size (`StoreInternals.swift`). Their sums are bounded by the volume's capacity, far below
    `Int64.max`. Unchanged.
  - `ApplyPlan.swift:130` (the eviction plan's bytes) already saturates.
  - `StoreStagingSink.writeStaged` adds bytes actually written, each step checked against `maxBytes` first;
    `AssetStore+Publish.swift`'s hash offsets add bytes actually read; the index codec's lengths are bounded by
    `IndexHeader.maxBodyLength` (64 MiB). Unchanged.

## S3B-2 — Crash at every boundary of a checksum change, a move and a removal (BLOCKING, S3-CONF-01, S3-CRAS-01) · test added

- **Finding.** SPEC 7.3 lists six crash-at-every-boundary scenarios; only the first sync, eviction and legacy migration
  were enumerated. The oracle samples one crash point per lifetime, and R-STO-5 says the test does not sample.
- **Test (`87d76d6`, tightened in `e4233d0`; WP-B helper `f590ae3`).** New file
  `Tests/ZTronAssetStorageTests/Core/StoreUpdateCrashTests.swift`, suite `Core: crash consistency of a catalog update
  (R-STO-5)`, test `crashAtEveryBoundaryOfAnUpdate(scenario:mode:)`, display name
  `R-STO-5: crash at every file-system boundary during a checksum-change update, a directory change and a removal preserves I-1…I-5`.
  Both probes merged on WP-B's own helpers (no WP-C helper): a durably synced v1 {a, b, c, d}, then one lifetime per
  crash point that applies v2, publishes a's new bytes, commits, waits out the deletion grace (the reaper unlinks what v2
  dropped), flushes durably and closes. Arguments: four scenarios (`checksumChange`, `directoryChange`, `removal`, and
  `allThree` in one apply) × every `CrashMode` (`processKill`, `processKillTornWrite`, `powerLossDropUnsynced`,
  `powerLossKeepMetadata`, the modes of `StoreCrashTests`' first-sync enumeration): 16 cases, every point enumerated
  (`crashes == total`). After each crash: the crashed run's mutations equal the clean run's up to the crash (store-2
  S2-08); I-3 in the crashed lifetime (no blob unlinked before the grace had passed; for the process-kill modes nothing
  the installed snapshot hands out is gone); reopen: I-5 (loaded generation ≥ every returned commit; the launch epoch
  above every index header's generation), I-1, I-2, I-4, DOOMED ∩ referenced = ∅ and the snapshot table equal to a
  rebuild (`CoreInvariants.violations`); the relaunch's own reap keeps them; convergence to v2 (each id serves its v2
  bytes, not stale; the removed id is not served); R-CLN-1 after convergence (every blob on disk is referenced or a launch
  orphan left to orphan GC); and no re-download of content that did not change (the move included), nor of a's new bytes
  once the killed process published them or a commit covered them before a power loss.
- **Crash points per mode.** `checksumChange` 40, `directoryChange` 24, `removal` 25, `allThree` 41
  (`R-STO-5 update <scenario>, <mode>: N crash points enumerated`). Durations of the 16 cases side by side, inside full
  storage runs (`3ea2f21`): 2.611 s, 3.803 s and 2.801 s (debug, load 9–17), 9.630 s under TSan (load about 15).
- **Not vacuous (scratch copy, the crash lens's env-gated mutants `S3-CRAS-05-mutants.diff`).** Killed: `S3MUT=A`
  (no barrier on the placed blob) `✘ Test run with 1 test in 1 suite failed … with 774 issues`, `B` (fan-outs never
  barriered) `… 384 issues`, `I` (ordered commits skip the root sync) `… 52 issues`. Not killed, each for a reason the
  scenario cannot reach: `C` (reap before the dropping generation is committed: `apply` commits before it returns), `F`
  (reap without an acknowledgement: every drop here is acknowledged at once), `S` (no grace check: equivalent, the fresh
  acknowledgement after `eligibleAt` already enforces the grace), `H` (launch-adopted fan-outs not dirtied: needs a power
  loss in the lifetime after the adoption, as the kill→power-loss pairs of the first sync), `E` (rescue of every doom: no
  purged or corrupt doom here; S3B-6 covers it).

## S3B-3 — The old blob's release when a content change adopts bytes another asset holds (BLOCKING, S3-CONF-06) · test added

- **Test (`8650e27`).** `StoreApplyTests.contentChangeOntoLiveBlob`, display name
  `R-CLN-1: a content change onto bytes another asset holds adopts them without a download and prunes the old blob after grace`:
  v1 {a: x, z: y} published and durable; v2 {a: y, z: y}; `a` is served from z's blob at once (not stale, nothing
  downloaded), the shared key is `live(references: 2)`, a's old blob is doomed `unreferenced` and still on disk until the
  grace passed (I-3), then reaped and gone from the blob table; invariants hold. No production change (the code was right).
- **The confirmer's mutant (`S3-CONF-06.mutant.diff`, applied verbatim in a scratch copy) fails it:**
  `✘ Test "R-CLN-1: a content change onto bytes another asset holds adopts them without a download and prunes the old blob after grace" recorded an issue at StoreApplyTests.swift:58:9: Expectation failed: StoreRecoveryTests.isDoomed(await harness.state.core.blobTable[oldKey], .unreferenced)`
  (and at `:62` `!harness.exists(harness.layout.blobURL(oldKey))`, `:64` `oldState == nil`; 3 issues). Both mutants
  (this one and M-S-11, S3B-4) were applied together in one scratch build; the run was `✘ Test run with 22 tests in 3
  suites failed … with 9 issues`, every issue in the two new tests, the other 20 tests (`StagingSinkTests`,
  `StoreApplyTests`) passing.

## S3B-4 — An ENOSPC in `writeStaged` surfaces as `insufficientSpace` (REQUIRED, M-S-11) · test added

- **Test (`8f8c862`).** `StagingSinkTests.writeStagedNoSpace(failingWrite:)`, display name
  `R-STO-6: an ENOSPC while staging a chunk source surfaces as insufficientSpace and leaves nothing behind`, arguments
  1 (the truncating first write) and 2 (an appending write): `writeStaged` throws `StagingError.insufficientSpace`, the
  fault fired once, neither `.parttmp` nor the final name exists, and once space is back the same name stages in full.
- **Mutant `M-S-11.diff` (verbatim, scratch copy) fails both cases:**
  `✘ Test "R-STO-6: an ENOSPC while staging a chunk source surfaces as insufficientSpace and leaves nothing behind" recorded an issue with 1 argument failingWrite → 2 at StagingSinkTests.swift:180:15: Expectation failed: an error was expected but none was thrown and "4" was returned`
  (6 issues over both cases, among them `Caught error: .nameInUse` on the retry: the swallowed write had renamed a short
  file into place).

## S3B-5 — The reaper's queue is read through a cursor (REQUIRED, S3-PERF-04) · fixed

- **Finding.** `reap(maxKeys:)` kept its queue as an `ArraySlice` and put each key a time-bounded unit did not attempt back
  with `queue.insert(_:at:)` near the front: one shift of the whole remaining queue per key, O(n² / 20) element moves for
  units that attempt 20 of 64 keys.
- **Fix (`1daf8bc`).** New WP-B file `Sources/ZTronAssetStorage/Store/ReapQueue.swift`: the sorted keys, never mutated, read
  through a cursor. `nextBatch(limit:admit:)` scans from the cursor (the reaper's per-key re-validation and marking is the
  `admit` closure, unchanged) without consuming; `consume(attempted:)` moves the cursor to the first key the unit did not
  attempt (or past the scan when it attempted all). The unattempted keys stay in place and lead the next batch,
  unchanged, as ARCHITECTURE §4.4 says; the only difference from before is that a key the re-validation refused after the
  first unattempted key is read again by the next batch instead of being dropped from this run (it is re-validated, so
  nothing unsafe follows; a key that became deletable meanwhile is reaped one run earlier). No new await; REENTRANCY R7
  unchanged.
- **Structural tests (deterministic, operations per key), as first written (cycle 1).** `DeletionUnitTests.reapQueueIsLinear`,
  `P-13: the reaper reads each doomed key a bounded number of times whatever the size of the set, so a reclaim in time-bounded units is linear`
  (1,000, 10,000 and 40,000 keys, 64-key batches, 20 attempted per unit: every key consumed exactly once in sorted order,
  the first key of each batch the first one the last unit left, `(n + 19) / 20` units, and reads per key in (3.1, 3.2]
  at every size); `DeletionUnitTests.reapQueuePassesOverRefusedKeys`,
  `P-13: a key the reaper's re-validation refuses is passed over, and the keys before the first unattempted one are consumed`.
  The store-level order and unit count stay pinned by `P-13: a deletion unit stops when its time budget is spent and the
  reaper carries the rest to the next unit` (unchanged, passing).
- **Correction (close-out cycle 2).** Cycle 1 said the read count pins linearity; it does not. Those two tests exercise
  `ReapQueue` on its own, and the old quadratic reaper had the same read figures (3.128–3.198 per key; only its element
  moves differed, 1,077–43,978 per key): with `s3-base`'s `reap(maxKeys:)` restored every deterministic test passed, and
  only the release benchmark caught it, in one run of two.
- **Store-level pin (cycle 2, `aafb43a`).** `reap(maxKeys:)` now records its work list in `StoreCoreState.lastReap`
  (`ReapStatistics`, WP-B's `ReapQueue.swift`: keys listed, deletion units, `ReapQueue.reads`, and the keys its units left
  unattempted, summed), set at the end of every run that listed a key; in memory only, no package or public change.
  New test `DeletionUnitTests.reaperWorkListIsLinear`,
  `P-13: the reaper reclaims 10,000 doomed blobs in 20-unlink units reading each key at most batch / attempted times, so its work is linear in the keys`:
  10,000 blobs a previous launch left are listed as launch orphans and doomed by `doomOrphans(_:)`, and the store's own
  reaper reclaims them while each monotonic read advances the clock 50 µs (`SteppingClock(step:)`, the benchmark's
  20-of-64 shape); it asserts 10,000 files removed, `keys == 10,000`, `units == 500`, `carried` equal to the per-unit
  model (44 while 64 or more keys remain, then 40, 20 and 0; 21,928 in all), `reads == keys + carried` (each key read
  once, and again only where a unit left it) and `reads <= 3.2 × keys`. 10.6 s in debug at load about 120.
- **The original defect fails it (S3-R3; scratch copy of `aafb43a` with `s3-base`'s `reap(maxKeys:)` spliced in, the
  `S3BASEREAP` mutant):** `✘ Test "P-13: the reaper reclaims 10,000 doomed blobs in 20-unlink units reading each key at most
  batch / attempted times, so its work is linear in the keys" recorded an issue at StoreDeletionTests.swift:311:30:
  Expectation failed: await store.state.core.lastReap` / `✘ Test run with 11 tests in 2 suites failed after 8.479 seconds
  with 1 issue.`
- **Benchmark made robust under load (cycle 2, `a5edd1e`).** `reapScaling` now runs, at 20,000 and 40,000, each of its
  three runs followed by the 20-key-batch control at the same size (best of three each) and also asserts
  `seconds[40,000] <= 1.5 × control[40,000]`: the verifier measured the old reaper at 2.47× and 3.29× its control and the
  fixed one at 0.98–1.04×, where the 40k/20k ratio alone let one run of the old reaper pass (1.996). The 1.5 bound is the
  benchmark's own (SPEC §6 has none for the reaper); the deterministic pin is the test above. Measured this cycle
  (release, load 49 → 8.7 and 15.8 → 10.3): fixed, 40k/20k 2.007 and 40,000 against its control 1.036; `s3-base`'s
  reaper spliced into a scratch copy of `a5edd1e`: `[10000: 0.244 s, 20000: 0.658 s, 40000: 1.985 s]`, `✘ … recorded an
  issue at BenchStorage.swift:296:13: Expectation failed: ratio <= ratioMax` (3.018) and `… BenchStorage.swift:297:13:
  Expectation failed: againstControl <= controlRatioMax` (3.131).
- **Release measurement (benchmark `StorageBenchmarks.reapScaling`, `8b3fc89`,
  `P-13: reclaiming a doubled set of blobs in time-bounded units costs the store at most doubling_ratio_max times as much`;
  each blob unlink advances the injected clock 50 µs, so every unit stops after 20 unlinks).**

  | Code | Host load (1-min) | 10,000 | 20,000 | 40,000 | 40k / 20k | 20-key-batch control 20k / 40k |
  |---|---|---|---|---|---|---|
  | before (`s3-base`'s reaper; the benchmark's first, single-run version) | 27.9 → 42.1 | 0.911 s | 2.033 s | 2.966 s | 1.46 (noise) | 0.426 s / 0.875 s |
  | after (`1daf8bc`, best of three) | 13.5 → 12.0 | 0.166 s | 0.333 s | 0.653 s | 1.96 | 0.310 s / 0.633 s |
  | final run (`d66eb2f`, best of three) | 8.9 → 5.7 | 0.161 s | 0.324 s | 0.648 s | 2.00 | 0.323 s / 0.651 s |

  Before, the reclaim was 4.8× (20,000) and 3.4× (40,000) the control's cost at the same size, and the hunter and the
  confirmer measured 40k/20k ratios of 3.14 and 2.67; after, it equals the control (nothing is re-inserted) and doubles
  with the set. The benchmark's ratio is judged against P-4's `doubling_ratio_max` (2.5), read from `QualityBudgets`; the
  "before" row shows one run's ratio is noise-prone under load, which is why the benchmark now takes the best of three
  runs per size (ADR draft B-9's rule: interference only slows a run down).

## S3B-6 — A purged doom is never rescued by launch adoption (REQUIRED, S3-CRAS-05) · test added, no bug

- **Test (`5ef808b`).** `LaunchReconciliationTests.purgedDoomNeverRescuedAtLaunch`, display name
  `R-CLN-6: a purged doom is never rescued by launch adoption, even for another record that expects its bytes after a kill before the reap`:
  x and y published and durable; a scope purge of x dooms x's blob `purged` and waits out its grace; meanwhile a manifest
  re-adds x's bytes under z (`apply` does not adopt the purged doom); the process is killed before the reaper unlinks
  them; the next launch lists the purged name, z expects it and accepts adoption, and z stays `absent(.neverFetched)`,
  not served, the key still doomed `purged`, invariants intact; the reaper then removes the bytes and z is fetched again
  and served from its own verified publication. It passes on `s3-base`: the store-1 S1-03 guard holds.
- **The purged-only mutant (scratch copy: `case .doomed(let info)? where info.reason == .unreferenced ||
  (S3MUT == "P" && info.reason == .purged)` in `LaunchReconciliation.swift` 7c), over all of `ZTronAssetStorageTests`:**
  `✘ Test "R-CLN-6: a purged doom is never rescued by launch adoption, even for another record that expects its bytes after a kill before the reap" failed after 1.382 seconds with 4 issues.`
  and `✘ Test "R-STO-5: launch adoption binds only records that accept it, rescues unreferenced dooms and releases a stale record's old blob" failed after 0.890 seconds with 2 issues.`
  (`✘ Test run with 464 tests in 61 suites failed … with 6 issues`). So the pure unit test `adoption()` already killed it
  (its `fromPurged` record is `needsHeal`, which accepts adoption); the hunter's 98-test filter did not include
  `LaunchReconciliationTests`. The new test is the end-to-end half the finding asked for.

## S3B-7 — The kill→power-loss pair test under load and TSan (REQUIRED, S3-B-017) · cheaper steps, guard unchanged

- **Change.** `StoreCrashTests.killThenPowerLoss`: every pair still runs its second lifetime with its crash and is judged,
  but the reopen that checks I-1…I-5 and converges (`FirstSync.reopenAndConverge`) is a deterministic function of the
  surviving disk alone in this test (a fresh `ManualTimeSource`, a fixed seed, an empty trace), so it now runs once per
  distinct surviving disk (`[DiskImage: Set<AssetID>]`, `DiskImage` is `Hashable`) and every pair's
  `downloaded.isDisjoint(with: trace.committed)` is judged on that result. No pair, crash point, mode, slice or assertion
  is cut; an issue a reopen records is recorded once per distinct disk instead of once per identical pair. The print now
  reports the distinct disks: per case 470–509 pairs, 43–55 distinct disks under `powerLossDropUnsynced` and 191–218 under
  `powerLossKeepMetadata`.
- **Where the time goes (debug, load 43, instrumented run not committed).** Per case: first lifetimes 0.04–0.07 s, second
  lifetimes 0.77–1.30 s, survivor copies 0.01–0.03 s, memo lookups 0.03–0.17 s, reopens 0.32–0.49 s (drop-unsynced) and
  1.46–1.74 s (keep-metadata) for the distinct disks only; without the memo every pair reopened (about 10× the reopens
  under drop-unsynced, 2.5× under keep-metadata).
- **TSan measurements (each variant twice, alternating, same scratch build, `--filter killThenPowerLoss`).**
  | Run | Variant | Host load (1-min, start → end) | 8 cases, all side by side |
  |---|---|---|---|
  | 1 | before (`s3-base`'s test) | 14.1 → 11.7 | 18.202 s |
  | 2 | memoized | 11.1 → 9.7 | 6.295 s |
  | 3 | before | 9.7 → 7.9 | 11.138 s |
  | 4 | memoized | 7.9 → 8.9 | 9.178 s |

  Every run passed (`✔ Test "R-STO-5: a process kill followed by a power loss in the next lifetime preserves I-1…I-5"
  with 8 test cases passed`). Among every other storage test (`3ea2f21`): 6.336 s, 10.733 s and 7.083 s in the three debug
  runs (load 9–17) and 22.039 s in the TSan run (`--sanitize=thread`, all 468 storage tests side by side, load about 15).
- **Guard.** Unchanged at `.timeLimit(.minutes(1))`: under TSan at moderate load the whole test (eight cases side by
  side) took 6.3–9.2 s alone and 22.0 s inside the full TSan storage run, below half its limit, so S3-R4's condition
  for a raise is not met. The overruns the backlog
  records happened at host loads of 441–834; the cheaper reopens lower the work, but no guard can promise one minute at
  such loads.
- **Close-out cycle 2 (the verifier's runs, recorded, no change).** Alone under TSan at load 137 → 280 the test passed in
  21.201 s for its eight cases side by side, below half its limit; inside the full TSan storage run at load 277 → 628
  (976.278 s in all) all eight cases overran the minute and the time-limit cancellation produced 62 follow-on issues
  (`reopen or convergence failed with .cancelled`). S3-R4's condition for a raise (over half the limit at a load of about
  30) is still not met, so the guard stays.

## S3B-8 — T2-06: a persisted launch epoch unique per launch (REQUIRED, S3-B-023) · test added

- **Test (`1d5bf8c`).** `StoreOpenTests.launchEpochUniquePerLaunch`, display name
  `R-SYN-1: each launch persists a launch epoch above every earlier one, so a later launch's attempts never take an earlier launch's staging name and order after it`:
  six launches, ending alternately in a close and a process kill, each starting the same transfer at sequence 1 and
  writing a distinct partial; each launch epoch is above every generation an index header on disk carries; the epochs are
  distinct and increasing, so the attempts order by launch; a seventh launch lists all six partials (`stagingInventory`,
  no foreign name) and each holds its own launch's bytes (`createPartial` truncates, so a reused name would have emptied
  an earlier partial). The cases where the epoch may repeat (a read-only launch, B-34; a launch whose root barrier and
  launch commit both failed, then a power loss, B-36; a wiped root) stay as ARCHITECTURE §4.5 records them; exclusive
  renames report `nameInUse` there.

## S3B-9 — OI-14: `apply`'s own releases count toward an overlapping eviction's need while they stay released (OPTIONAL) · fixed (cycle 1), corrected (cycle 2)

- **Failing test first (`b668371`).** `StoreApplyTests.pruneWhileEvictionCandidatesRun`, display name
  `R-CLN-4: bytes a pruning apply dooms while quota eviction computes its candidates count toward its need`, on WP-C's
  overlap fixture (ten 100-byte assets, budget 500, a run alone evicts six): a maintenance eviction measured 550 bytes and
  waits in its candidates unit; an `apply` prunes the two most recently used assets (200 bytes). Unfixed:
  `result → CleanupResult(bytesFreed: 600, filesRemoved: 6, bytesDeferred: 0)` and `evicted → [0, 1, 2, 3, 4, 5]` (2 issues).
- **Fix, cycle 1 (`fb99142`, WP-B's file only).** `AssetStore+Apply.swift`'s `releaseCountingBytes(_:)` wraps
  `releaseReference(_:dooming: .unreferenced)` for the releases `apply` and `admit` make: when the release dooms a blob
  that was live, its `blobBytes` are added to `state.eviction.releasedBytes` (saturating), as eviction, purge, quarantine
  and recorded failures count theirs (C-2, ruling R7). Now 400 bytes and four evictions (`o0` … `o3`).
- **Cycle-2 finding (correctness lens, blocking).** The count was made the moment a release doomed a blob, but the same
  `apply` can rescue that doom: swapping the contents of two present assets makes both adoption candidates, the first
  adoption dooms one blob (counted, +100) and the second rescues it, so 100 bytes counted as released never left
  `usedBytes` and the overlapping run stopped at `CleanupResult(bytesFreed: 500, filesRemoved: 5)`, 500 bytes used
  against a 450 target (R-CLN-4 [MUST], REENTRANCY R13). The same over-count follows when a later `apply` adopts a pruned
  blob back while one eviction spans both, and when a publication dedupes onto it.
- **Failing tests first (`cb17625`).** `StoreApplyTests.swapWhileEvictionCandidatesRun`,
  `R-CLN-4: a content swap between present assets while quota eviction computes its candidates releases nothing, so the run still frees what it measured`
  (the verifier's probe, renamed into the owning suite), and `StoreApplyTests.pruneThenReadoptWhileEvictionCandidatesRun`,
  `R-CLN-4: bytes one apply released and a later apply adopts back while quota eviction computes its candidates no longer count toward its need`.
  On `fb99142`'s code both gave `result → CleanupResult(bytesFreed: 500, filesRemoved: 5, bytesDeferred: 0)`:
  `✘ Test run with 12 tests in 1 suite failed after 0.017 seconds with 6 issues.`
- **Fix, cycle 2 (`16ac464`, WP-B's files only).** A count is kept for exactly as long as its bytes stay released:
  `releaseCountingBytes` records each counted doom in `StoreCoreState.countedReleases` (key → bytes) through
  `countRelease(of:bytes:)`; every transition of a doomed key back to `live` takes the count back
  (`takeBackCountedRelease(of:)`, subtracting the bytes from `releasedBytes`): `gainReferenceInPlace` (the adoption of
  `apply` and `admit`, `setResidency`, binding) and `acquireReference`'s `.rescued` (a publication's dedupe). A count a
  publication took back with its provisional reference is held in `StoreCoreState.provisionallyRescued`: if the
  publication binds nothing and `dropProvisionalReference` dooms the key afresh, it counts again; if it binds (or another
  reference holds the key), the entry goes with the provisional reference. The reaper's unlink drops the key's entry and
  keeps the count (the bytes are gone for good); `open()` starts both maps empty. A doom counted by an eviction, a purge or
  a quarantine is not in `countedReleases` and is never taken back here. Why subtraction rather than counting at the end
  of the `apply`: `apply` yields between chunks, so an eviction can measure between a release and the end of the `apply`;
  a deferred count would then count bytes that measurement had already seen leave. With the take-back, an eviction that
  measured before the doom sees the doom and the rescue cancel, and one that measured after it frees the returned bytes
  again, so in both cases it ends at its target.
- **Pins (cycle 2).** `StoreApplyTests.publicationRescueTakesTheCountBack`,
  `R-CLN-4: a publication that rescues bytes an apply counted as released takes the count back, and counts them again when it binds nothing`
  (internal `acquireReference` / `abandonAcquisition`, then a real publication for a checksum-less record, then a prune
  and the reaper); `StoreApplyTests.contentChangeOntoLiveBlobWhileEvictionCandidatesRun` (`53ee7f6`),
  `R-CLN-4: the old bytes an apply releases when an asset's content moves onto another asset's bytes count toward an overlapping eviction's need`
  (the verifier's OI14B gap: `adoptKnownBlob`'s previous blob; `CleanupResult(bytesFreed: 500, filesRemoved: 5)`, 400
  bytes used, as a run alone after the change); and a bookkeeping check in `CoreInvariants.violations` (every test that
  calls it): each `countedReleases` key is doomed `unreferenced` or being deleted with exactly the counted bytes, each
  `provisionallyRescued` key is live.
- **The detached record's replacement (cycle-2 finding, non-blocking) · now counted.** `applyDiff`'s replacement of a
  record the applied manifest did not list released its blob with `releaseReference` directly, so cycle 1's "a
  re-inserted record's previous blob counts" held only on `insertRecord`'s path. Failing test first (`5ac4090`):
  `StoreApplyTests.detachedRecordReplacementCounts`,
  `R-CLN-4: an apply that replaces a detached record counts its released bytes toward an overlapping eviction's need unless it adopts them back`
  (the committed index rewritten so `a`'s record is detached, then reopened; new bytes: the 90 bytes count; the same
  bytes: adopted back, nothing counts). Unrouted: `recorded an issue at StoreApplyTests.swift:226:13: Expectation failed:
  await reopened.state.eviction.releasedBytes - start == counted` (new bytes). Fix `9b5b030`: the release goes through
  `releaseCountingBytes`. `insertRecord`'s own previous-blob release (also through `releaseCountingBytes`) is not
  reachable from `apply` or `admit`: both call it only for an id with no record (`admit`'s new id, `changeContent`'s
  vanished record) or for an added id with no planned record, which `ApplyPlan.compute` never leaves; it stays as a
  defensive path and is not separately pinned.
- **Mutants (S3-R3; scratch copy of `9b5b030`, each mutant alone, `StoreApplyTests|EvictionOverlapTests|StoreDeletionTests|DeletionUnitTests|StorePublishTests`).**
  - `GAIN` (no take-back in `gainReferenceInPlace`): `✘ Test run with 43 tests in 5 suites failed after 3.101 seconds with
    11 issues.`, among them the swap test (`StoreApplyTests.swift:127:9: Expectation failed: result ==
    CleanupResult(bytesFreed: 600, filesRemoved: 6)`), the re-adoption test (`:187:9`) and the detached test's same-bytes
    case (`:226:13`).
  - `ACQ` (no take-back in `acquireReference`): 6 issues, `StoreApplyTests.swift:272:9: Expectation failed: await
    harness.state.eviction.releasedBytes == start`.
  - `REDOOM` (no new count when an abandoned rescue dooms afresh): 3 issues, `StoreApplyTests.swift:281:9: Expectation
    failed: await harness.state.eviction.releasedBytes == start + size`.
  - `REAP` (the reaper keeps the entry): 3 issues, `StoreApplyTests.swift:297:9: Expectation failed: await
    harness.state.core.countedReleases.isEmpty` and `CoreInvariants` in `contentChangeOntoLiveBlob` (`:66:9`).
  - `OI14B` (the verifier's mutant: `adoptKnownBlob`'s previous blob released directly): 3 issues,
    `StoreApplyTests.swift:156:9: Expectation failed: result == CleanupResult(bytesFreed: 500, filesRemoved: 5)`.
  - `PERAPPLY` (the cycle-2 prototype's scope: counts forgotten when the apply gate is released): 11 issues, including
    `StoreApplyTests.swift:187:9: Expectation failed: result == CleanupResult(bytesFreed: 600, filesRemoved: 6)` (the
    re-adoption across two `apply` calls).
- **Ownership.** WP-B's files write WP-C's contract field `EvictionState.releasedBytes`, as S3B-9 rules ("count a pruning
  apply's releases in WP-B's release path"); since cycle 2 they also lower it when a counted doom is rescued, so its doc
  comment's "never decreases" no longer holds (a proposed change to WP-C's doc below; WP-C's readers only take
  differences against a value read at their measurement, so a lower value makes a run free more, never less). Listed
  under the authorised edits below. The tests read WP-C's test helpers (`EvictionOverlapTests.harness`, `.evicted`,
  `CleanupSteps.run`) as they are at `s3-base`.

## S3B-10 — OI-12: a per-key reap exclusion (OPTIONAL) · recorded

Not bounded within WP-B's files. The reap window is checked by WP-C's orphan GC (`OrphanCollection.swift`,
`reapWindowClosed(since:)`, per run). A per-key exclusion needs WP-B's reaper to keep a bounded set of the keys it reaped
since a sequence number (a field in `StoreCoreState` and a write in `reap`) **and** orphan GC to pass its start sequence
to `doomOrphans` and stop calling `reapWindowClosed`: the second half is WP-C's file. Proposed as a change request for WP-C
and the orchestrator (`other-wp:c:`): WP-B would add `StoreCoreState.reapedSince` (a ring of the last N reaped keys with a
serial) and an internal `doomOrphans(_:learntBefore:)` that skips a key reaped after the serial; WP-C would use it in place
of the per-run window. Liveness only; each occurrence is logged (`.info`).

## S3B-11 — OI-15 / L4-R24(5): binding an evicted record to live content on demand (OPTIONAL) · recorded as a CCR for WP-F

Ruling R3 stands for `apply` and `admit` (unchanged). Within WP-B's files no call the engine already makes before a
transfer can bind: the engine's pre-transfer read is `location(for:extensions:recordingAccess:)` (or `adoptLegacyNow` while
legacy migration is pending, `EnginePresence.storedLocation`), a read with no I/O and no commit or snapshot, whose
contract (`AssetStore+Reads.swift`: "values from actor state") a binding would break, since a binding must dirty the index
and publish a snapshot. **CCR for WP-F:** before transferring a record that is `absent(.evicted)` (or a shared-content late
joiner) whose expected key is live, the engine calls a new WP-B package primitive `bindToLiveContent(_ id:) async throws
-> AssetLocation?` that binds by `adoptKnownBlob`'s rule restricted to a **live** key (referenced; never doomed, purged or
corrupt, so no eviction is undone), commits with the coalesced window, publishes at the caller's urgency and returns the
location; WP-B adds it with an exhaustive test over the blob states (`live`, `doomed(unreferenced|purged|corrupt)`,
`deleting`, absent, publishing). It is a package signature, so it needs the orchestrator's ruling (S3-R6). Cost of the
status quo: one redundant download per such record, never a correctness bug (probes ZP7-OI1b, ZP8-OI15).

## S3B-12 — P-13: the root cause of the long deletion unit (ADR-RECORD, S3-PERF-03, S3-B-010) · recorded

P-13 stays the owner's (ADR-050); neither `BenchStorage.swift`'s `longest <= batchBudget` assertion nor the gate is edited.
Evidence for the owner:
- **Hunter (isolated probe, swiftc -O, 10,000 unlinks of 64-byte files, each unlink timed beside a CPU spin of the same
  length as a preemption control; load 12.9).** Unlinks show 7–13 stalls over 2 ms per 10,000 (max 4.4–6.6 ms) in every
  combination of file state (fresh, barrier-synced, settled after `sync()` + 5 s), layout (256-way fan-out or flat, sorted
  or random), Spotlight (indexed or `.noindex`), QoS and another process's `F_FULLFSYNC` every 50 ms; the spin control
  shows 0–1. The stalls recur by count: about every 850–1,060 unlinks with fan-out, every 490–550 in a flat directory,
  often in pairs, so the period follows the metadata dirtied, not a timer. Under load (30–90) CPU preemption dominates
  and depends on QoS: unlinks over 4 ms per 10,000 were 18 at default QoS, 136 at utility (the metadata executor's), 333
  at background, 4 at user-interactive. The benchmark's `unlinkProfile` (2,000 unlinks, p50/p99) cannot show an event
  that happens once per 500–1,000 unlinks.
- **Confirmer (re-run at load 93–106).** The count periodicity reproduced (flat: 532, 1,075, 2,138, 2,655, 3,183, 3,693;
  fan-out `.noindex`: 1,054, 2,091, 3,149, 4,281, 5,600); utility QoS raised stalls to 322–342 against spins 135–155;
  the low-load claims (QoS independence, Spotlight and `F_FULLFSYNC` elimination) could not be checked at that load.
- **What no store change fixes.** The stall is inside one `unlink(2)` and recurs by count, so smaller units, rate
  limiting, pre-syncing blobs and fan-out changes do not avoid it; raising the deletion queue's QoS removes only the
  preemption share under load, at an energy cost for background GC.
- **Options for the owner (SPEC 6 or `quality-gates.json`).** (B, robust) `batch_ms_max` about 15 ms (one stall, up to
  about 11 ms in ADR-050's quiet runs, plus the 1 ms unit); (A) judge the batch bound on a percentile, p98 being robust at
  about one stall per 900 unlinks and 20 unlinks per unit; (C, new) judge what the bound protects: units run on the
  dedicated metadata queue, so a stalled unlink holds neither the store's actor nor a cooperative-pool thread; bound the
  longest actor hold between units plus the unit's on-CPU time, the wall maximum printed as information.
- **This cycle's run (release, `d66eb2f`, load 8.9 → 5.7).** `P-13 reclaim of 10000 blobs: 0.597988584 s in 562 units,
  unit max 7.869083 ms (p50 0.96175 ms, p95 0.99275 ms) … unit on-CPU max 1.002791 ms; units over the batch budget:
  ["5.705875 ms wall, 0.286334 ms on CPU", "5.54925 ms wall, 0.953875 ms on CPU", "5.684583 ms wall, 0.778542 ms on CPU",
  "7.869083 ms wall, 0.366375 ms on CPU"]; blob unlinks inside the reclaim: max 7.688 ms, 7 over 4.0 ms`, so
  `✘ … BenchStorage.swift:249:13: Expectation failed: longest <= batchBudget`, the known owner item: each slow unit
  is one stalled unlink (wall far above on-CPU), seven stalls in 10,000 unlinks as the hunter's probe predicts. The total
  (0.60 s against 2.0 s) passes.

## S3B-13 — User-initiated publications copy the present table (ADR-RECORD, S3-PERF-05) · recorded, no fix

- **Measurement.** Release, `S3-PERF-05-S3PerfPublishProbe.swift`: user-initiated publications 2,500 / 5,000 / 10,000 took
  1.32 / 3.94 / 10.67 s (hunter, load 12 rising; 10k/5k 2.71) and 0.51 / 1.72 / 4.92 s (confirmer, load 64–70; 2.86);
  bulk 1.06 / 2.16 / 2.32 s (ratio 2.11 at the confirmer's load). With a control sink that does not retain the snapshot,
  user-initiated publications scaled linearly (0.42 / 1.07 / 2.14 s, ratio 2.00).
- **Cause.** A `.userInitiated` publication installs at once; the snapshot's `entries` is the store's `presentTable`,
  shared copy-on-write and kept by the sink (`SnapshotMirror.current`), so the next `refreshPresentEntry` copies the whole
  table on the actor (`AssetStore+Snapshot.swift`). A run of n such publications is O(n²); bulk and prefetch install at
  most once per `snapshotInstallInterval` and do not pay it. Per publication at 10,000 entries the copy is about
  0.5–1 ms, inside C2; no SPEC 6 budget applies.
- **Why no fix this cycle.** The bounded designs (an overlay of the entries changed since a shared base, rebuilt off the
  hot path past about √n entries; or double-buffering the present table through `InstallAck.retired`) change
  `AssetSnapshot` (`Snapshot/AssetSnapshot.swift`, a contract file of WP-B whose lookup the main actor runs) and the
  install path every reader depends on; the rulings authorise no contract body change for it, and the risk to the R-STO-13
  lookup path outweighs a cost that stays inside C2 per publication. Proposed for Stage 5 with the owner's P-8 run.

## S3B-14 — Recorded limits and device items (ADR-RECORD)

- **S3-B-011 (actor stretches at `maxEntries`, 100,000).** Re-measured this cycle (release, `CleanupBenchmarks`):
  release, `d66eb2f`, load 8.9 → 5.7, thread CPU (worst of runs) at 100,000 assets: WP-B's grace start over every
  doomed key 37.31 ms, the reaper's queue over every deletable key (filter and sort) 22.84 ms (22.93), the reaper's
  deletable filter 4.03 ms (4.10), `freeSpace()` 4.19 ms (8.10, wall), the first present-table copy after a publication
  3.33 ms (6.29), the first records copy under a live snapshot 9.34 ms (9.46, WP-C's figure of WP-B's state); longest
  actor holds of WP-C's operations there: quota eviction of half 21.98 ms, `purge(.all)` of a full store 35.83 ms,
  `purge(.evictable)` 34.02 ms, orphan GC of 100,000 orphans 18.43 ms. At 10,000 (SPEC's reference scale) every hold is
  under 3.2 ms (grace start 1.66 ms, the reaper's queue 1.93 ms) and every C2 assertion passed. The cursor of S3B-5
  removes the reaper's re-insertions, not the queue's initial filter and sort, which is the 22.8 ms figure. SPEC's
  reference scale is 10,000 (C2 holds there); the chunked `startGrace` (OPTIONAL) was not done:
  `startGrace` (`AssetStore+Snapshot.swift`) walks the whole blob table in the acknowledgement's turn. Chunking the walk is
  safe (a key whose grace start is still pending stays `acknowledgement`-blocked, so nothing is reaped early), but it
  needs owned follow-up turns that a later acknowledgement must not overtake (each chunk carrying its own `eligibleAt`),
  or a pending set that every doom site feeds so the walk is O(dooms); neither is "simple", and the stretch lies beyond
  SPEC's 10,000 reference scale. Left for Stage 5 with the other `maxEntries` stretches.
- **S3-B-015 (`pendingReclaim` counted with no deadline).** Not reproduced. A probe (not committed) failed the commit of an
  `apply` that pruns a 300-byte blob in each of four ways (EIO on the `index.tmp` rename, ENOSPC on its write, EIO on the
  root sync, EIO on the file sync; every attempt failing): `apply` threw, `freeSpace().pendingReclaim` was 300 and the key
  was blocked on `acknowledgement`, then on `commit`, while `nextDeadline()` reported the scheduled commit retry at every
  step (never `nil`). With the test configuration's zero `commitMinimumInterval` the retry delay is zero
  (`commitRetryDelay` multiplies the interval), so the deadline stays at "now"; the facade always passes the default
  0.25 s (`AssetClient.storeConfiguration(for:)` sets no interval), where the backoff doubles up to 5 minutes. The states
  in which a doomed key counts in `pendingReclaim` with no deadline are the documented ones: unavailable (B-15),
  degraded (store-1 S1-11), leased (counted as deferred elsewhere), and an acknowledgement-blocked key whose install came
  back unacknowledged (store-1 S1-13). F-25's single sighting fits the last; the engine's fresh read stays.
- **S3-B-016 (`gainReferenceInPlace` copying the blob table).** Measured in release with the new benchmark
  `StorageBenchmarks.gainReferenceInPlace`, `C2: a reference gained in place never copies the blob table, 1,000 gains at 100,000 blobs inside 10 ms`:
  `C2 1,000 in-place reference gains in one turn: ["10000 blobs 0.081084 ms", "100000 blobs 0.103375 ms"] (best of 5;
  budget 10.0 ms)` (release, `d66eb2f`, load 8.9 → 5.7): about 0.1 µs per gain at either size, so the release build
  writes the entry in place and never copies the table (a copy of 100,000 entries per gain would take seconds). The debug
  and TSan copies stay a property of unoptimised builds, where the test suites run at 10,000 entries at most.
- **S3-B-018 (B-33's state-space limits), S3-B-019 (a double fault inside one commit unit), S3-B-020 (declined B-34
  relaxation and B-5 exposure), S3-B-021 (device-only: `F_BARRIERFSYNC`/`F_FULLFSYNC`, file protection, iOS 15 runtime,
  P-5/P-13 on a quiet host), S3-B-022 (a real `rename(2)` that takes effect and reports failure, `lstat`/`pread` I/O errors,
  `LiveFileSystem` catch paths APFS cannot provoke here, how long a volume keeps a killed rename undoable).** Unchanged;
  recorded limits as in `b.md` (B-33, B-28 cycle-5 amendment, B-34, B-36) and ADR-050, for Stage 5's device plan.

## Close-out cycle 2 findings (dispositions)

- **reqs, blocking — S3B-5's linearity had no deterministic pin.** Fixed: `ReapStatistics` / `lastReap` and
  `DeletionUnitTests.reaperWorkListIsLinear`, which `s3-base`'s reaper fails; the benchmark also judged against its
  interleaved control; the cycle-1 wording corrected (S3B-5 above).
- **correct, blocking — OI-14 over-counted bytes the same apply rescued.** Fixed with rescue-aware counting; failing
  tests first; six mutants killed (S3B-9 above).
- **reqs, non-blocking — two counting sites unpinned (OI14B).** Pinned: `contentChangeOntoLiveBlobWhileEvictionCandidatesRun`
  kills OI14B; `insertRecord`'s site is unreachable from `apply` and `admit` (S3B-9 above).
- **correct, non-blocking — the detached record's replacement did not count.** Fixed, failing test first (S3B-9 above).
- **reqs, non-blocking — wording glitches in S3B-14.** Fixed (continuation lines indented, the merged sentence split, the
  final period added).
- **correct, non-blocking — `killThenPowerLoss` under TSan at load 277–628.** Recorded under S3B-7; no change (S3-R4).
- **other-wp:d (two findings) — loopback transport tests time out on the iOS Simulator under host load.** Not WP-B's
  files; routed to WP-D / the orchestrator with the verifier's evidence
  (`.build-orchestrator/s3b-probes-c1/reqs-sim-run1-transport-flake.json`, `reqs-sim-run1-timeouts-excerpt.txt`). This
  cycle's simulator verdict is taken at the lowest load available (below).
- **other-wp:c — `CleanupCrashTests` legacy-migration enumeration overran under TSan at load 280–628.** Routed to WP-C.
- **other-wp:h — `LoopbackHTTPServerTests` 'start racing stop …' overran at load 311–628.** Routed to WP-H (DECISIONS TSan
  headroom item 4).
- **correct, non-blocking — benchmarks under load.** No action: WP-B's new benchmarks passed in both of the verifier's
  runs; P-13's batch maximum stays the owner's (S3B-12).

## Authorised edits outside WP-B

- `Sources/ZTronAssetStorage/Store/AssetStore+Apply.swift` and `AssetStore+References.swift` (WP-B's files) write WP-C's
  contract field `state.eviction.releasedBytes` (`EvictionState.swift`): `countRelease(of:bytes:)` adds a counted doom's
  bytes and `takeBackCountedRelease(of:)` subtracts them when that doom is rescued (S3B-9, "count a pruning apply's
  releases in WP-B's release path", cycles 1 and 2). No WP-C file changed.
- Read-only use of WP-C's test helpers (`EvictionOverlapTests`, `CleanupSteps`) by `StoreApplyTests.pruneWhileEvictionCandidatesRun`;
  no WP-C test file changed.
- No other file outside WP-B's directories, no `Package.swift`, `Scripts/`, contract test or shared document changed.

## Proposed document changes (for the orchestrator at the Stage 3 merge)

- **ARCHITECTURE §1.1 / §1.2.** WP-B's new files: `Sources/ZTronAssetStorage/Store/ReapQueue.swift` (S3-PERF-04) and
  `Tests/ZTronAssetStorageTests/Core/StoreUpdateCrashTests.swift` (S3B-2); WP-B's `AssetStore+Apply.swift` writes
  `EvictionState.releasedBytes` (S3B-9), an addition to §1.1 rule 1/2's list of cross-package writes.
- **ARCHITECTURE §4.4.** "the keys it did not attempt go first into the next unit, unchanged (no backoff)" stays true; add
  "read through a cursor over the sorted keys, so a reclaim is linear in the keys (S3-PERF-04)".
- **ARCHITECTURE §4.6 and §10.1 R13.** Remove "residual: `apply`'s prune, OI-14" and add "`apply`'s and `admit`'s own
  releases (prune, a replaced detached record's or an adopted record's previous blob), each counted while its bytes stay
  released: a rescue of that doom (adoption, publication dedupe) takes the count back, and a publication that binds
  nothing and dooms the key afresh counts it again (`StoreCoreState.countedReleases`, `provisionallyRescued`; S3B-9
  cycle 2)" to the releases that count.
- **WP-C's `EvictionState.releasedBytes` doc comment (`EvictionState.swift`, WP-C's file; for WP-C or the orchestrator).**
  Replace "never decreases" with "lowered when a doom that `apply` or `admit` counted is rescued (its bytes are back in
  `usedBytes`); readers take differences against the value read at their measurement".
- **ARCHITECTURE §4.4 / §14.** The reaper records its work list per run (`StoreCoreState.lastReap`, `ReapStatistics`,
  diagnostics in memory only), pinned by `DeletionUnitTests.reaperWorkListIsLinear`.
- **ARCHITECTURE §11.** R-STO-5: add `R-STO-5: crash at every file-system boundary during a checksum-change update, a directory change and a removal preserves I-1…I-5` (B).
  R-MAN-2: add `R-MAN-2: availability saturates bytesMissing at Int64.max …` (B). R-STO-6: add `R-STO-6: an ENOSPC while
  staging a chunk source surfaces as insufficientSpace and leaves nothing behind` (B). R-CLN-1: add `R-CLN-1: a content
  change onto bytes another asset holds adopts them without a download and prunes the old blob after grace` (B). R-CLN-4:
  add `R-CLN-4: bytes a pruning apply dooms while quota eviction computes its candidates count toward its need` and the
  cycle-2 rows `R-CLN-4: a content swap between present assets while quota eviction computes its candidates releases nothing, so the run still frees what it measured`,
  `R-CLN-4: bytes one apply released and a later apply adopts back while quota eviction computes its candidates no longer count toward its need`,
  `R-CLN-4: the old bytes an apply releases when an asset's content moves onto another asset's bytes count toward an overlapping eviction's need`,
  `R-CLN-4: an apply that replaces a detached record counts its released bytes toward an overlapping eviction's need unless it adopts them back`
  and `R-CLN-4: a publication that rescues bytes an apply counted as released takes the count back, and counts them again when it binds nothing` (B).
  R-CLN-6: add `R-CLN-6: a purged doom is never rescued by launch adoption, …` (B). R-SYN-1: add `R-SYN-1: each launch
  persists a launch epoch above every earlier one, …` (B). P-13: add the two `ReapQueue` tests, `P-13: the reaper reclaims
  10,000 doomed blobs in 20-unlink units reading each key at most batch / attempted times, so its work is linear in the
  keys` and the `reapScaling` benchmark; C2: add the `gainReferenceInPlace` benchmark.
- **ARCHITECTURE §12.1 S1-03.** Add `R-CLN-6: a purged doom is never rescued by launch adoption, …`.
- **ARCHITECTURE §12.5 T2-06.** Replace "the cross-launch collision case … is not written at the level-4 merge (Stage 3,
  ADR-053)" with the new R-SYN-1 test's name.
- **ARCHITECTURE §13.5 #3 / §14 row 3.** The three update scenarios now have their crash-at-every-boundary writer (WP-B).
- **REENTRANCY (§10.1).** No new await in WP-B's files in either cycle, so no new row; R7's text holds for the cursor;
  R13's text changes as above (a rescued counted doom no longer counts).
- **CCR for WP-C (S3B-9 cycle 2).** WP-C's counting sites (`QuotaEviction.swift` `evict`, `StorePurge.swift`,
  `IntegrityBookkeeping.swift`) could count through WP-B's `countRelease(of:bytes:)` instead of adding to
  `releasedBytes` directly, so that a rescue of their dooms is taken back too (and `acquireReference`'s `.replaced` would
  then take back a counted `purged`/`corrupt` doom). Not done here: WP-C's files.
- **DECISIONS (Stage 3).** S3B-11's CCR (a WP-B package primitive for WP-F) and S3B-10's (WP-C), for ruling; S3B-12's
  options for the owner's P-13 decision; S3B-13 for Stage 5.

## Gates and runs (close-out cycle 2, final code)

All on `a5edd1e` (the last code commit; this draft is the only later change), `.build-s3b*` scratch paths; host loads
(1-minute) quoted per run, from other agents' work.
- `SWIFTPM_SCRATCH=.build-s3b bash Scripts/verify.sh --quick` (13:30–13:37, load 59 → 135): `VERIFY: PASS` (Model 151,
  Sync 351, Storage 474, Transport 84, Kit 85, Compatibility 71, Apple-hosted 104 tests, all passing);
  `docs/TRACEABILITY.md` unchanged.
- `swift build -c release --scratch-path .build-s3b -Xswiftc -warnings-as-errors`: `Build complete! (43,23 s)`.
- `gates.py unsafe`: `UNSAFE escapes found=0 max=3` / `UNSAFE: PASS`; `gates.py docs`: `DOCS public declarations=1281
  documented=1281 exempt=0 fraction=100.0%` / `DOCS: PASS`.
- `ZTronAssetStorageTests` three times: `✔ Test run with 474 tests in 61 suites passed after 91.176 seconds.` (load
  56 → 29), `… 75.873 seconds.` (29 → 16), `… 68.528 seconds.` (16 → 14); the new reaper test took 4.4–4.7 s. Under TSan
  once (load 12.6 → 8.1): `✔ Test run with 474 tests in 61 suites passed after 213.749 seconds.`, no ThreadSanitizer
  report; there the reaper test took 11.255 s and `killThenPowerLoss` 23.049 s (limit one minute each).
- Coverage (`--enable-code-coverage`, every test bundle, load 7–8): `COVERAGE target=ZTronAssetStorage lines= 97.56%
  (8228/8434) min=90.0 OK`, `COVERAGE overall lines=96.65% (25249/26125) min=80.0 OK`, `COVERAGE: PASS`.
- iOS: `xcodebuild … -destination 'generic/platform=iOS' … OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet`: exit 0.
- iOS Simulator (ADR-051, simulator `02CE21B4-F307-4CB7-B80A-1F2EF72F115C`, iOS 27.0, Benchmarks built, not run):
  `caffeinate -i xcodebuild test … -skip-testing:ZTronAssetKitBenchmarks -collect-test-diagnostics never
  OTHER_SWIFT_FLAGS='-warnings-as-errors'`: `** TEST SUCCEEDED **`, exit 0, 13:52:20 → 13:57:18 (load 6.9 → 62);
  `xcresulttool get test-results summary`: `result Passed, totalTestCount 1320, passedTests 1320, failedTests 0,
  skippedTests 0` on `iPhone 17e 27.0`; the reaper test took 7.089 s there. The simulator is shut down.
- Benchmarks WP-B owns, release (`swift test -c release --scratch-path .build-s3b-perf -Xswiftc -enable-testing --filter
  StorageBenchmarks`, load 49 → 8.7): `✘ Test run with 7 tests in 2 suites failed after 31.091 seconds with 1 issue.`, the
  one issue P-13's `longest <= batchBudget` (owner item, S3B-12: unit max 7.87 ms against 5.0, every over-budget unit
  about 1 ms on CPU). Everything else passed: P-2 p95 9.72 ms (25), P-5 ordered p95 14.01 ms and durable p95 21.17 ms
  (40), at most 4 commits in any second (4), P-6 2,406 MB/s (800), ratio 0.83 (0.7), peak 0.0 MiB (4), P-13 total
  0.60 s (2.0); reap scaling `[10000: 0.162 s, 20000: 0.327 s, 40000: 0.655 s]`, 40k/20k 2.007 (2.5), controls 0.313 s
  and 0.632 s, 40,000 against its control 1.036 (1.5); in-place gains 0.098 ms at 100,000 blobs (10); C2 at 10,000:
  apply, open, prune and re-adoption at most 4.06 ms (10).

## Not verified here

- Device-only (S3-B-021, S3-B-022): `F_BARRIERFSYNC`/`F_FULLFSYNC` semantics and cost, file protection, iOS 15 runtime
  behaviour (the simulator is iOS 27.0; test bundles build at iOS 17.0), P-5/P-13 on a quiet host.
- The benchmark figures were taken while other worktrees built (loads quoted beside each); P-13's batch maximum is the
  owner's item (S3B-12).
- S3-B-015 was not reproduced (above); S3B-10 and S3B-11 need other packages' files.
- S3B-9's take-back covers the dooms WP-B's `apply` and `admit` count. A doom quota eviction counts (WP-C's
  `QuotaEviction.swift`, reason `unreferenced`) and a publication later rescues is not taken back, so a second run that
  measured before it can still stop that blob's bytes short of its target; the same holds for a `purged` or `corrupt`
  doom a verified publication replaces (new bytes under the name). Not exercised here: the counting sites are WP-C's
  files. Proposed below as a CCR for WP-C.
