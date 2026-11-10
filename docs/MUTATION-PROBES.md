# Mutation probes

SPEC §7.4 (Q-8): in Stage 3 an agent that did not write the code injects at least 12 deliberate defects one at a time and records here "the diff and the test that failed"; a surviving mutant means writing the missing test. This file holds Stage 3's records: the method (§2), discovery's 64 mutants on `s3-base` (§3), the 11 survivors' close-out tests and their re-check on the merged head (§4), the map from SPEC §7.4's suggestions (§5), the close-outs' own mutant runs (§6), what stays open (§7), and every discovery diff (Appendix A).

Nothing in this file was re-run when it was written (Stage 5, on `d002758`); each figure cites the record it comes from (G2). The discovery records are `.build-orchestrator/s3-hunt-result.json`, key `mutate` (`storage.probes`, `network.probes`); the diffs are in `.build-orchestrator/s3-mutants/storage/` and `network/`; the re-check is in `.build-orchestrator/s3-post-merge/mut-recheck/` (`summary.txt`, `first-issues.txt` and the applied diffs), with one log per mutant in `.build-orch/mut-recheck/`. Paths that start with `.build-orchestrator/`, `.build-orch/` or `.worktrees/` are relative to the main checkout and are not tracked by git. The tables and Appendix A are generated from those records by a script that checks the counts below.

## 1. Counts

| | Storage group | Network group | Total |
|---|---|---|---|
| Mutants applied, all compiled | 27 | 37 | 64 |
| Killed at discovery | 23 | 30 | 53 |
| Survived at discovery | 4 | 7 | 11 |
| Survivors killed by a close-out test, re-checked on `e840b0e` | 4 of 4 | 7 of 7 | 11 of 11 |

`docs/ORCHESTRATION.md:880` records the same totals (64 mutants, 27 storage, 37 network, 11 survived). Each group alone meets Q-8's floor of 12. No gate checks Q-8: `grep -ril mutation Scripts/` finds no file, so this document is its only evidence.

## 2. Method

### 2.1 Discovery (29 Oct 2026)

- **Who.** The two mutation agents of the Stage 3 discovery workflow, `.claude/workflows/assetkit-stage3-hunt.js` (`:7`: "two independent agents inject >= 20 mutants"; model Sonnet unless configured otherwise, `:178`), in run `wf_124dbd46-f15`, 08:58-10:46 (`docs/ORCHESTRATION.md:878`). Their prompt opens "You did not write this code" (`:143-146`). Scopes (`:139-141`): **storage** (`ZTronAssetStorage`) with SPEC §7.4's eight store suggestions, and **network** (Transport, Sync, Model, AppleHosted and Kit) with its four network suggestions.
- **Base.** `s3-base` (`b5796ba`), in a detached worktree per agent. Nothing was committed, and each worktree was removed afterwards (both groups' `status` texts).
- **One mutant at a time** (`:143-146`). One minimal, realistic defect under `Sources/`, never in a test; compile; run the narrowest target that should catch it (`swift test --filter <Target>Tests`), then the whole suite when nothing fails; record KILLED with the failing tests' display names, or SURVIVED; restore with `git checkout -- <file>`; save the diff. A mutant that does not compile, or is equivalent, is replaced: the storage agent replaced an equivalent first LRU mutant (`<=` in the `lastAccess` comparator, behind a `!=` guard) with M-S-05.
- **Survivors.** A survivor must name the missing test's behaviour, requirement ID and file (`:143-146`). Each agent wrote a candidate test that passes on the unmutated code and fails on its mutant, which shows the mutant is not equivalent. None was committed: `.build-orchestrator/s3-probes/mut-storage/M-S-07_08_11_17_20-survivor-probe-tests.swift` (5 of 5 pass on the clean tree) and `.build-orchestrator/s3-probes/mut-network/M-N-nn-candidate-test.swift` (M-N-09 and M-N-12 share a file). The storage survivors were re-run against Sync (351 tests), Kit (85), Compatibility (71) and, for M-S-11, AppleHosted (104). M-N-09, M-N-12 and M-N-14 survived all 7 test targets (Benchmarks skipped); M-N-16, M-N-20, M-N-22 and M-N-39 survived their own target and every target that depends on it.
- **Conditions and caveats** (the two `status` texts):
  - Host load averages were 10-50 for storage (8 shared cores) and 14-100 for network, so absolute timings are inflated.
  - A killed mutant's killing-test list is the first failing target's, not exhaustive. The storage survivors were not run against the Model and Transport targets, which do not use the real store.
  - Seven network kills (M-N-02, M-N-05, M-N-08, M-N-15, M-N-35, M-N-36 and M-N-38) show partly as 60 s per-test time limits, "alongside failed expectations". M-N-05 was stopped by hand after its first killing tests because it hung, and M-N-19 hit the agent's 300 s watchdog; the agent records both as "already clearly killed".
  - Neither agent ran TSan. The network agent states that it did not run `verify.sh --quick`; the storage agent's record does not mention `verify.sh`.
  - The network `status` text is stale. It says "34 mutants applied … 28 KILLED and 6 SURVIVED" and "Thirty own probes", while its records hold 37 mutants (30 killed and 7 survived, the seven survivors the same text names) and 32 own probes (M-N-06 to M-N-40 without M-N-30, M-N-32 and M-N-33, which were never applied). This file follows the records, as ORCHESTRATION does.
  - The records' own locations are approximate for many mutants (a `~` line, or a line near the change). The tables give the line where each change block of the diff starts at `s3-base`; Appendix A also keeps the record's location.

### 2.2 From survivor to test (S3-R3)

- **The ruling** (`.build-orchestrator/s3-rulings-s3b.md:8`; each close-out's rulings file carries it): "For each surviving mutant assigned here, write the missing test, then re-apply the mutant's diff in a scratch copy and show the new test FAILS against it; paste that failing line into the draft. Verifiers re-check the same way." A kill by a time limit alone does not count (ADR-057, `docs/DECISIONS.md:684`, on breakerReadLive).
- **Assignments.** S3B-4: M-S-11 (`.build-orchestrator/s3-rulings-s3b.md:21`). S3C-3: M-S-07 and M-S-08 (`s3-rulings-s3c.md:20`). S3C-4: M-S-20 (`s3-rulings-s3c.md:21`). S3D-3: M-N-22 (`s3-rulings-s3d.md:20`). S3F-11: M-N-09, M-N-12, M-N-14, M-N-16, M-N-20 and M-N-39 (`s3-rulings-s3f.md:28`).
- **One deviation.** WP-D applied M-N-22 in its own worktree and removed it with `git checkout`, not in a scratch copy; the cycle-2 requirements verifier re-applied it in its own scratch copy and it failed (`docs/DECISIONS.md:683`, citing `.build-orchestrator/s3d-probes-c2/retry-reqs-mutants.out:37-42`).

### 2.3 The post-merge re-check (7 Nov 2026, on `e840b0e`)

The orchestrator re-applied each survivor's diff, one file at a time, in `.worktrees/merge-check` at `e840b0e` (the s3f merge), ran that target's tests (Storage, Sync or Transport), and restored the file with `git checkout -- <file>`; a survivor of its own target would have been re-run against every target (`docs/ORCHESTRATION.md:554-556`). Ten diffs applied as they were. M-N-39's context had moved, so it was re-made on the same line (`max(previous ?? .zero, until)` becomes `until`, at `EngineFailures.swift:374` on `e840b0e`; `:557`; Appendix A gives both diffs). Result: all 11 KILLED, each by an assertion failure in a test named for its mutant, with no time-out (`:540`); the unmutated head passed these tests in the `--full`'s three runs, in TSan and on the simulator (`:552`). ADR-057 records the same result (`docs/DECISIONS.md:686`).

## 3. Discovery's 64 mutants

"Changed at `s3-base`" is the line where each change block of the diff starts (the first line it replaces, or the line it inserts before), under `Sources/`. "Killing tests" are the discovery record's display names, separated by semicolons as recorded; for a survivor, §4 names the close-out test.

### Storage group (27)

| Id | What it breaks | Changed at `s3-base` | Requirement | Outcome | Killing tests at discovery |
|---|---|---|---|---|---|
| M-S-01 | Skip the checksum comparison after hashing (hash verification skipped) | `ZTronAssetStorage/Store/AssetStore+Publish.swift:121` | R-INT-2 / R-STO-3 (hash-verified before publication, I-1) | KILLED | R-INT-6: the recorded blob hash is the digest of the written bytes, not the manifest claim; R-STO-3: a blob never appears at its final path before size check, hash verification and barrier |
| M-S-02 | Bind/publish the blob before the checksum comparison (publish before verification) | `ZTronAssetStorage/Store/AssetStore+Publish.swift:121`, `:150` | R-STO-3 (a blob never appears under its final path until hash-verified) | KILLED | R-INT-6: the recorded blob hash is the digest of the written bytes, not the manifest claim; R-STO-3: a blob never appears at its final path before size check, hash verification and barrier |
| M-S-03 | Deletion grace starts from an acknowledged snapshot that still contained the key (delete before the lacking snapshot is published) | `ZTronAssetStorage/Store/AssetStore+Snapshot.swift:88` | R-CLN-5 / I-3 / H-2 (snapshot publication always precedes file deletion) | KILLED | R-CLN-5: a deref during an in-flight install starts its grace only with a later acknowledged install (5 test cases) |
| M-S-04 | Lock released right after acquisition (drop the lock) | `ZTronAssetStorage/Store/LaunchReconciliation.swift:71` | R-STO-9 (single writer via advisory lock) | KILLED | R-STO-9: a second store on the same root fails with locked deterministically |
| M-S-05 | Off-by-one in the LRU plan: EvictionOrder.plan keeps selecting at an exact fit (freed <= bytes) | `ZTronAssetStorage/Eviction/EvictionOrder.swift:92` | R-CLN-4 (LRU eviction down to a target, shortest prefix of the eviction order) | KILLED | R-CLN-4: a quota eviction measured before apply evicted its plan frees only what is still needed; R-CLN-4: bytes apply's eviction plan dooms while quota eviction releases the actor between chunks count toward its need |
| M-S-06 | Purge no longer clears the sync stamp (forget to reset the stamp after a purge) | `ZTronAssetStorage/Cleanup/StorePurge.swift:89` | R-CLN-6 (purge makes a sync due) / R-STO-2 | KILLED | R-CLN-6: a purge clears the stamp before its selection runs off the actor, and a sync that read the epoch meanwhile cannot stamp; R-CLN-6: purge all returns bytes freed, leaves the store consistent and makes a sync due |
| M-S-07 | AssetStore.evict no longer re-checks leases at apply time (single layer removed) | `ZTronAssetStorage/Eviction/QuotaEviction.swift:268` | R-CLN-5 (eviction never removes a leased asset) | SURVIVED; killed since by `LeaseTests.swift:370` (§4) | none |
| M-S-08 | EvictionOrder.Ranking no longer excludes leased blobs (dry-run plan names and counts them) | `ZTronAssetStorage/Eviction/EvictionOrder.swift:207` | R-CLN-5 / R-SYN-11 (eviction and its dry run never include a leased asset) | SURVIVED; killed since by `LeaseTests.swift:394` (§4) | none |
| M-S-09 | Evict a leased asset: lease protection removed from both the ranking and evict() | `ZTronAssetStorage/Eviction/EvictionOrder.swift:207`; `ZTronAssetStorage/Eviction/QuotaEviction.swift:268` | R-CLN-4 / R-CLN-5 (leased assets are never evicted) | KILLED | R-CLN-4: essential, pinned, leased and recently accessed assets are never evicted |
| M-S-10 | Index commit swallows ENOSPC (write failure returns as success, no fallback or retry) | `ZTronAssetStorage/Index/IndexCommitUnit.swift:316` | R-STO-4 / R-STO-6 (atomic index replacement; ENOSPC fault handling, ADR-015) | KILLED | R-STO-4: every initial index state, with one fault at every operation, a kill or a power loss at every mutation, keeps I-a…I-e (169 test cases); R-STO-5: every kill survivor with unordered index names, with a fault at open()'s root barrier or a crash before it, keeps I-a…I-e (49 test cases); R-STO-5: the unordered-name survivors are every distinct kill survivor of the fault-free lifetimes whose crash views differ |
| M-S-11 | StoreStagingSink.writeStaged swallows a .noSpace write failure and reports success (swallow ENOSPC) | `ZTronAssetStorage/Staging/StoreStagingSink.swift:175` | R-STO-6 (ENOSPC injected and surfaced; ADR-013 maps it to insufficientSpace) | SURVIVED; killed since by `StagingSinkTests.swift:165` (§4) | none |
| M-S-12 | Skip the sync of index.tmp before the rename (skip the index sync before rename) | `ZTronAssetStorage/Index/IndexCommitUnit.swift:176` | R-STO-4 (write temp, durable flush, rename) | KILLED | R-STO-4: a commit writes tmp, syncs it, renames bin to prev, renames tmp to bin, then syncs the root, in that order |
| M-S-13 | Legacy migration adopts a file under its claimed digest without checking the hash | `ZTronAssetStorage/Migration/LegacyPhases.swift:247`, `:257` | R-STO-11 (adopt every legacy file whose checksum verifies, drop the rest) | KILLED | R-STO-11: a legacy file whose bytes do not verify is dropped and the stamp is not migrated |
| M-S-14 | Releasing one lease drops every holder of the blob (release a lease early) | `ZTronAssetStorage/Cleanup/StoreLeases.swift:33` | R-CLN-5 / R-CAR-8 (a blob is not deleted while any lease holds it) | KILLED | R-CLN-5: every lease on a blob must end before it is deleted, and a second release is a no-op |
| M-S-15 | Reaper skips the awake-clock grace window | `ZTronAssetStorage/Store/AssetStore+Reaper.swift:61` | R-CLN-5 / I-3 (deletion only after the grace window) | KILLED | R-CLN-5: a deref during an in-flight install starts its grace only with a later acknowledged install (5 test cases) |
| M-S-16 | Reaper ignores the 'dropping generation not yet committed' blocker (delete before commit) | `ZTronAssetStorage/Store/AssetStore+Reaper.swift:55` | R-CLN-5 / R-STO-4 / I-3 (never unlink a blob a power loss could still need) | KILLED | R-CLN-5: a launch whose root barrier fails unlinks nothing a power loss could still need, until a commit succeeds; R-STO-4: keys doomed only in a loaded index.tmp wait for a commit that survives the failed launch commit (3 test cases) |
| M-S-17 | Eviction residency window boundary off-by-one ('>=' becomes '>') | `ZTronAssetStorage/Eviction/EvictionOrder.swift:54` | R-CLN-4 / R-CLN-5 (not accessed within minimumResidency / the grace window) | KILLED | ZTronAssetSyncTests only (confirmed twice): R-SYN-10: ensureAvailable downloads a member that an apply evicted before it threw. ZTronAssetStorageTests SURVIVED (459/459 pass). |
| M-S-18 | LRU tie-break flipped: smaller blob first instead of larger first | `ZTronAssetStorage/Eviction/EvictionOrder.swift:229` | R-CLN-4 (least-recently-used first, ties: larger first) | KILLED | R-CLN-4: eviction removes least-recently-used first, larger first on ties, down to 90 % of budget |
| M-S-19 | Staging GC ignores active-transfer claims (collects claimed files past the claim grace) | `ZTronAssetStorage/Cleanup/StagingCollection.swift:70` | R-CLN-2 / R-CLN-3 (staging files owned by an active transfer are kept) | KILLED | R-CLN-3: a staged file handed off by a relaunched background session survives launch staging GC; R-CLN-3: staging GC removes unowned partial files at launch and after sync |
| M-S-20 | Orphan GC compares the age with 0 instead of orphanGrace (grace ignored) | `ZTronAssetStorage/Cleanup/OrphanCollection.swift:236` | R-CLN-2 (orphans removed only after a grace period) | SURVIVED; killed since by `GarbageCollectionTests.swift:606` (§4) | none |
| M-S-21 | Launch reconciliation no longer treats a missing or wrong-sized blob as OS-purge evidence | `ZTronAssetStorage/Store/LaunchReconciliation.swift:222` | R-CLN-7 (OS purge detected: stamp reset, sync due) | KILLED | R-CLN-7: a wrong-sized blob makes its records needsHeal and is quarantined as corrupt, never adopted |
| M-S-22 | Index decode skips the SHA-256 trailer comparison | `ZTronAssetStorage/Index/IndexCodec.swift:383` | R-STO-4 (torn or corrupt index never trusted) | KILLED | R-STO-4: a newer schema, a corrupt index.bin or a degraded generation makes the load degraded |
| M-S-23 | Deep verification ignores the digest (size-only check), so bit rot passes | `ZTronAssetStorage/Integrity/DeepVerification.swift:82` | R-INT-4 (resident blobs verified, corrupt ones repaired) | KILLED | R-INT-4: deep verification repairs a corrupted resident blob within its byte budget; R-CLN-12: deep verification cancelled while it builds its due list or hashes a blob records nothing, and the next run completes the pass (3 test cases) |
| M-S-24 | Reaper treats a failed unlink as success (failure swallowed, key dropped from the table) | `ZTronAssetStorage/Store/AssetStore+Reaper.swift:194` | R-CLN-2 / R-CLN-12 (failed unlinks stay doomed with backoff) | KILLED | R-CLN-2: an orphan whose unlink keeps failing stays doomed with backoff and does not stop the others from being collected |
| M-S-25 | Reaper deletes while the store is degraded (degraded blocker removed) | `ZTronAssetStorage/Store/AssetStore+Reaper.swift:49` | R-STO-4 (a torn, corrupt or newer-schema index never causes blobs to be deleted) | KILLED | R-STO-4: a degraded fallback deletes no blob listed in the older generation's doomed set |
| M-S-26 | Reader access stamps no longer clamped to now (future access pins an asset as recent) | `ZTronAssetStorage/Store/AssetStore+Snapshot.swift:108` | R-STO-13 / R-CLN-4 (LRU input; store-2 S2-19) | KILLED | R-STO-13: accesses reach the records through acknowledgements, clamped to now and never moved backwards |
| M-S-27 | Quota arithmetic ignores pending reclaim (doomed bytes not counted as soon-free) | `ZTronAssetStorage/Eviction/EvictionOrder.swift:356` | R-CLN-4 (budget resolved over usage plus free space plus pending reclaim, store-2 S2-06) | KILLED | R-CLN-4: pending reclaim decides a second eviction within the grace window, against a reserve and a fractional budget (store-2 S2-06) (2 test cases) |

### Network group (37)

| Id | What it breaks | Changed at `s3-base` | Requirement | Outcome | Killing tests at discovery |
|---|---|---|---|---|---|
| M-N-01 | Ignore Retry-After in the backoff delay (mandatory) | `ZTronAssetSync/Engine/EngineSupport.swift:215` | R-SYN-5 (honour Retry-After as a lower bound) | KILLED | R-SYN-5: backoff delays are full jitter keyed by asset and attempt and reproducible from the seed |
| M-N-02 | Engine drops the Retry-After hint on a transient failure | `ZTronAssetSync/Engine/EngineFailures.swift:235` | R-SYN-5 (honour Retry-After) | KILLED | R-SYN-5: a Retry-After beyond maxRetryAfter fails the waiter with that wait and ends the job for the run, holding nothing |
| M-N-03 | Keep the app key on a cross-host redirect (mandatory) | `ZTronAssetTransport/Policy/TransportSecurity.swift:137` | R-NET-4 (key never leaves the original origin), R-SEC-1 | KILLED | R-NET-4: a cross-host redirect to an allow-listed host is followed without the app key; R-NET-4: once stripped, the key never returns on a redirect back to the original origin; R-NET-4: the redirect decision keeps the key only while every hop stays on the original origin; R-NET-6: a 403 after the key was withheld on a cross-origin redirect is reported as keyWithheldOnRedirect |
| M-N-04 | Classify HTTP 403 as transient (mandatory) | `ZTronAssetTransport/Classify/TransferClassifier.swift:84` | R-NET-6 (403 is forbiddenAmbiguous, never retried blindly) | KILLED | R-NET-6: HTTP statuses map to the closed taxonomy; R-NET-6: a 403 is reported as forbiddenAmbiguous with evidence, never as notFound or a confirmed rejection; R-NET-6: an XML 403 on the manifest is object-missing-likely, never key rejection; R-NET-6: an XML 403 on the manifest is reported with its evidence through the delegate; R-NET-6: status mapping through the real delegate matches the pure table |
| M-N-05 | Cancel the running transfer when any one waiter withdraws (mandatory) | `ZTronAssetSync/Engine/EngineJobs.swift:257` | R-SYN-4 / H-3 (a caller's cancellation affects only that caller) | KILLED | R-SYN-4: the transfer is cancelled only after the last of 100 callers cancels; R-SYN-4: withdrawing the highest-priority interest demotes the running transfer; R-SYN-10: cancelling ensureAvailable cancels transfers wanted by nobody else and throws cancelled; R-SYN-2: 10,000 seeded random operations never leave the transition table and keep every engine invariant; R-SYN-3: seeded random releases and re-joins of overlapping handles larger than one release turn keep every engine invariant and leave no job |
| M-N-06 | Accept a '..' manifest path segment | `ZTronAssetModel/Manifest/Decoding/ManifestRules.swift:301` | R-MAN-2 (no parent segments in remotePath) | KILLED | R-MAN-2: remotePath must be relative, without parent segments, scheme, authority, control characters, query or fragment; R-MAN-2: every structural violation rejects the manifest and every per-entry violation quarantines only that entry; R-MAN-2: violations(of:) reports every rule an entry breaks, in field order |
| M-N-07 | Off-by-one in the transfer size cap | `ZTronAssetTransport/Policy/PriorityAndSize.swift:42` | R-NET-7 (a transfer exactly at the cap is allowed) | KILLED | R-NET-7: the size guard aborts when the written or announced size exceeds the cap or byteSize is exceeded; R-NET-7: the size guard decides at the edges of Int64 without trapping |
| M-N-08 | Break manifest-fetch single flight | `ZTronAssetSync/Engine/EngineManifest.swift:79` | R-SYN-4 (one manifest fetch is shared by concurrent askers) | KILLED | R-STO-11: ensureAvailable right after start, beside a legacy migration that runs at its own pace, downloads none of the prior-art files, launch after launch (L5K-R13); R-SYN-5: a run that joins a manifest fetch admitted while the breaker was closed holds no probe for it, so that fetch's answer does not close the breaker; R-SYN-5: an unknown-id resolve that a throttled manifest fetch answers after an earlier waiter's admission reports the time left until the origin's extended end |
| M-N-09 | Ignore promotion bulk to prefetch of a queued job | `ZTronAssetSync/Engine/EngineJobs.swift:187` | R-SYN-3 (a request at a higher lane promotes the shared job; sync-1 S1-06) | SURVIVED; killed since by `EngineBoundaryTests.swift:39` (§4) | none |
| M-N-10 | Release an Apple pack twice in one catalog generation | `ZTronAssetAppleHosted/AppleSourceState.swift:241` | R-CLN-10 / ADR-027 (at most one release per pack per catalog generation) | KILLED | R-CLN-10: a pack that comes back after release is released at most once per catalog generation; R-CLN-10: requesting an excluded asset after its pack's release removes the pack once per catalog generation, never in a loop; R-CLN-10: a released pack a transfer downloaded again for an adopted asset stays installed until the next catalog generation; R-CLN-10: a pack a transfer downloaded again while its release call was running stays released for that generation; R-CLN-10: a transfer that ends in skew never re-arms its pack's release within a catalog generation; R-CLN-10: a pack the system already removed counts as released; R-CLN-10: a release made before the first catalog fetch counts for that catalog's generation; R-CLN-10: a copy staged from a pack downloaded on demand that reaches no consumer leaves the pack released for the generation |
| M-N-11 | File-system work in lookup on the main thread | `ZTronAssetKit/Facade/AssetClient.swift:192` | R-STO-7 / R-CAR-1 (lookup does zero file-system calls) | KILLED | R-STO-7: lookup, prefetch, events and resolve entry make zero file-system calls on the main thread; R-CAR-2: a local asset is found synchronously with zero file-system calls when the bundle misses |
| M-N-12 | Ignore any promotion of a queued job (including to the user lane) | `ZTronAssetSync/Engine/EngineJobs.swift:187` | R-SYN-3 / R-NET-10 (promotion of a queued shared job) | SURVIVED; killed since by `EngineBoundaryTests.swift:47` (§4) | none |
| M-N-13 | Running transfer: promotion never reaches the transport | `ZTronAssetSync/Engine/EngineJobs.swift:197`, `:199` | R-NET-10 / R-SYN-3 | KILLED | R-NET-10: a promoted asset's priority change reaches the transport before any other transfer starts; R-SYN-3: a userInitiated request for an in-flight bulk asset promotes it without restarting the transfer; R-CAR-3: a release that overtakes a successor's join keeps the job the successor named, and its join promotes the running transfer; R-CAR-3: a successor naming another id of the same content keeps the job through the predecessor's release; R-CAR-3: groups registered before start keep the job the successor named through the predecessor's release; R-CAR-3: a job a predecessor's join creates after a successor's registration survives the predecessor's release until the successor joins; R-SYN-4: withdrawing the highest-priority interest demotes the running transfer; R-SYN-4: a waiter's withdrawal that overtakes a group's join keeps the job the group named |
| M-N-14 | Drop a backoff step (ceiling grows one step late) | `ZTronAssetSync/Engine/EngineSupport.swift:211` | R-SYN-5 (exponential backoff with full jitter) | SURVIVED; killed since by `EngineBoundaryTests.swift:58` (§4) | none |
| M-N-15 | Auth breaker threshold off by one (>= becomes >) | `ZTronAssetSync/Engine/EngineSupport.swift:476` | R-SYN-5 (breaker trips after repeated authentication failures) | KILLED | R-SYN-5: three ambiguous 403s on distinct assets open the auth breaker but one does not; R-SYN-5: a half-open probe that ends without a verdict lets the next parked job probe, so the run neither settles blocked nor starts further runs without the clock moving; R-SYN-5: a pending run that waits for a half-open breaker starts once its silent probe's watchdog passes; R-SYN-5: a retry that falls due in the alarm turn of the cooldown's end probes before the pending run starts; R-SYN-5: a run that starts while the half-open breaker admits only a probe holds it for its manifest fetch from its start turn |
| M-N-16 | 5xx breaker: error ratio boundary (>= becomes >) | `ZTronAssetSync/Engine/EngineSupport.swift:483` | R-SYN-5 (trip after sustained 5xx at serverErrorRatio) | SURVIVED; killed since by `EngineBoundaryTests.swift:82` (§4) | none |
| M-N-17 | Object success no longer clears the auth suspects | `ZTronAssetSync/Engine/EngineSupport.swift:464` | R-SYN-5 (403s need to be without a success in between) | KILLED | R-SYN-5: three ambiguous 403s on distinct assets open the auth breaker but one does not |
| M-N-18 | Probe failure re-opens without incrementing trips | `ZTronAssetSync/Engine/EngineSupport.swift:380` | R-SYN-5 (doubled cooldown per trip) | KILLED | R-SYN-5: a same-cause probe failure re-opens with a doubled cooldown |
| M-N-19 | Open breaker admits a probe one tick late (>= becomes >) | `ZTronAssetSync/Engine/EngineSupport.swift:420` | R-SYN-5 / R-SYN-6 (probe at the cooldown's end) | KILLED | R-SYN-5: a same-cause probe failure re-opens with a doubled cooldown; R-SYN-5: a silent probe is abandoned after the watchdog and the next transfer probes; R-SYN-5: sustained 5xx opens the breaker and a single half-open probe closes it; R-SYN-2: the invariant check accepts a pending run whose gate the clock opened before the alarm's turn starts it (EngineRegressionCycle13Tests.swift:66) |
| M-N-20 | Retry-After exactly equal to maxRetryAfter is deferred (> becomes >=) | `ZTronAssetSync/Engine/EngineSupport.swift:208` | R-SYN-5 (a Retry-After above maxRetryAfter defers to the next run) | SURVIVED; killed since by `EngineBoundaryTests.swift:99` (§4) | none |
| M-N-21 | Resume Range offset off by one | `ZTronAssetTransport/Policy/RequestFactory.swift:39` | R-NET-8 (Range from the partial's size) | KILLED | R-NET-8: a connection dropped mid-download resumes with Range and If-Range and the staged file is complete; R-NET-8: a live resumed transfer counts the resume offset only when the origin continued it with a 206 |
| M-N-22 | Weak ETag accepted as the resume validator | `ZTronAssetTransport/Session/HTTPResponseReading.swift:63` | R-NET-8 / RFC 9110 (If-Range needs a strong validator) | SURVIVED; killed since by `SizeAndResumeTests.swift:203` (§4) | none |
| M-N-23 | Redirect hop limit off by one | `ZTronAssetTransport/Policy/TransportSecurity.swift:126` | R-NET-4 (at most 5 redirects) | KILLED | R-NET-4: a redirect outside the allow-list, past the hop limit or without a usable Location is refused; R-NET-4: same-origin redirects keep the key and the sixth hop is refused |
| M-N-24 | HTTP 410 no longer permanent-missing | `ZTronAssetTransport/Classify/TransferClassifier.swift:85` | R-NET-6 (404/410 permanent-missing) | KILLED | R-NET-6: HTTP statuses map to the closed taxonomy; R-NET-6: status mapping through the real delegate matches the pure table |
| M-N-25 | Plain HTTP allowed to any allow-listed host under loopbackOnly | `ZTronAssetTransport/Policy/TransportSecurity.swift:95` | R-NET-4 / R-SEC (HTTPS only; plaintext for loopback hosts only) | KILLED | R-NET-4: an HTTPS to HTTP downgrade is refused |
| M-N-26 | 304 accepted without a conditional request | `ZTronAssetTransport/Classify/TransferClassifier.swift:66` | R-NET-5 | KILLED | R-NET-5: a 304 without a conditional request is rejected; R-NET-6: HTTP statuses map to the closed taxonomy |
| M-N-27 | RemoteURL.make accepts a '..' component | `ZTronAssetTransport/Policy/RequestFactory.swift:73` | R-NET-4 / TR1-10 (defence in depth for paths reaching the transport) | KILLED | R-NET-4: a remote path that could leave the base path is refused as an invalid URL |
| M-N-28 | 206 without Content-Range accepted | `ZTronAssetTransport/Classify/TransferClassifier.swift:64` | R-NET-6 / ARCHITECTURE section 6.3 | KILLED | R-NET-6: HTTP statuses map to the closed taxonomy |
| M-N-29 | Metadata-only change classified as unchanged | `ZTronAssetModel/Manifest/ManifestDiff.swift:92` | R-MAN-4 | KILLED | R-MAN-2: a manifest built in memory rejects repeated identifiers, and the diff reports each class; R-MAN-4: applying diff(a, b) to a yields b and every identifier is classified exactly once; R-MAN-4: every shipped transition of both tiers classifies exactly as expectations.json lists; R-MAN-4: seeded manifest pairs partition every identifier and apply back to the newer manifest; R-MAN-5: a checksum-less entry changes content identity only when its remotePath changes |
| M-N-31 | Swallow POSIX ENOSPC from an Apple pack error | `ZTronAssetAppleHosted/PackErrorMapping.swift:77` | R-NET-6 / R-SYN-11 (out of space is insufficientSpace) | KILLED | R-NET-6: an out-of-space pack error is insufficientSpace, so the engine frees space instead of retrying |
| M-N-34 | Swallow ENOSPC in the URL-error classifier | `ZTronAssetTransport/Classify/TransferClassifier.swift:154` | R-NET-6 / R-SYN-11 | KILLED | R-NET-6: URL error codes map to the closed taxonomy; R-NET-6: background cancel reasons map to cancelled by the system and file errors keep their POSIX code |
| M-N-35 | PrefetchHandle deinit no longer releases its group | `ZTronAssetKit/Prefetch/Prefetch.swift:40` | R-CAR-4 | KILLED | R-CAR-4: a handle released without cancel() releases its interest on deinit |
| M-N-36 | Prefetch window radius off by one | `ZTronAssetKit/Prefetch/Prefetch.swift:96` | R-CAR-3 | KILLED | R-CAR-3: a neighbour that becomes current is promoted without a second transfer; R-CAR-3: moving the window by one cancels exactly the asset that left and starts exactly the one that entered |
| M-N-37 | Prefetch window order (backward before forward) | `ZTronAssetKit/Prefetch/Prefetch.swift:97` | R-CAR-3 | KILLED | R-CAR-3: window targets are current, then ±1, then ±2, clamped at both ends; R-CAR-3: a repeated identifier keeps its closest occurrence and an out-of-range index yields nothing |
| M-N-38 | Facade window ignores a priority promotion of an existing handle | `ZTronAssetKit/Prefetch/Prefetch.swift:137` | R-CAR-3 (a neighbour that becomes current is promoted) | KILLED | R-CAR-3: a neighbour that becomes current is promoted without a second transfer; R-CAR-3: moving the window by one cancels exactly the asset that left and starts exactly the one that entered |
| M-N-39 | A later 429 with a shorter Retry-After shortens the origin throttle | `ZTronAssetSync/Engine/EngineFailures.swift:314` | R-SYN-5 / ARCHITECTURE section 7.6 (origin-wide throttle until the clamped deadline; a later 429 only extends it) | SURVIVED; killed since by `EngineBoundaryTests.swift:114` (§4) | none |
| M-N-40 | Per-run attempt cap off by one | `ZTronAssetSync/Engine/EngineFailures.swift:282` | R-SYN-5 (cap attempts per asset) | KILLED | R-SYN-11: a publication that runs out of space fails a user request with insufficientSpace; R-SYN-11: a volume that keeps answering ENOSPC while it reads roomy ends in insufficientSpace once the retry budget is spent; R-SYN-11: a volume that keeps answering ENOSPC while the store holds bytes it has not scheduled to reclaim ends in insufficientSpace once the retry budget is spent; R-SYN-6: a run reports each asset it could not fetch with its failure class |

## 4. The 11 survivors: close-out tests and the re-check

Each close-out test was written under S3-R3 (§2.2) and named for its mutant's requirement. "Declared at" is the `@Test` line at `e840b0e` and at `d002758` (`git diff --stat e840b0e d002758 -- Tests/` is empty). The last column is the re-check's first failing assertion on `e840b0e` (`.build-orchestrator/s3-post-merge/mut-recheck/first-issues.txt`; target from `summary.txt`).

| Mutant | What it breaks | Ruling | Close-out test, declared at | Commit · record | Re-check on `e840b0e`: target, first failing assertion |
|---|---|---|---|---|---|
| M-S-07 | AssetStore.evict no longer re-checks leases at apply time (single layer removed) | S3C-3 (WP-C) | "R-CLN-5: apply skips a planned victim leased after the plan, even when no access since the plan protects it", `Tests/ZTronAssetStorageTests/Cleanup/LeaseTests.swift:370` | `3372b76` · `docs/adr-drafts/s3c.md:476-477` | ZTronAssetStorageTests: `LeaseTests.swift:387:9`, `report.evicted.isEmpty` |
| M-S-08 | EvictionOrder.Ranking no longer excludes leased blobs (dry-run plan names and counts them) | S3C-3 (WP-C) | "R-CLN-5: the eviction dry run neither names a leased asset nor counts its bytes", `Tests/ZTronAssetStorageTests/Cleanup/LeaseTests.swift:394` | `3372b76` · `docs/adr-drafts/s3c.md:478` | ZTronAssetStorageTests: `LeaseTests.swift:409:9`, `beyond == nil` |
| M-S-11 | StoreStagingSink.writeStaged swallows a .noSpace write failure and reports success (swallow ENOSPC) | S3B-4 (WP-B) | "R-STO-6: an ENOSPC while staging a chunk source surfaces as insufficientSpace and leaves nothing behind", `Tests/ZTronAssetStorageTests/Core/StagingSinkTests.swift:165` | `8f8c862` · `docs/adr-drafts/s3b.md:118-120` | ZTronAssetStorageTests: `StagingSinkTests.swift:180:15` (argument failingWrite → 1), `an error was expected but none was thrown and "4" was returned` |
| M-S-20 | Orphan GC compares the age with 0 instead of orphanGrace (grace ignored) | S3C-4 (WP-C) | "R-CLN-2: an orphan younger than the orphan grace, or exactly that old, is kept; one older is doomed", `Tests/ZTronAssetStorageTests/Cleanup/GarbageCollectionTests.swift:606` | `3372b76` · `docs/adr-drafts/s3c.md:479-480` | ZTronAssetStorageTests: `GarbageCollectionTests.swift:622:9`, `inside == CleanupResult() && insideDoom == nil` |
| M-N-09 | Ignore promotion bulk to prefetch of a queued job | S3F-11 (WP-F) | "R-SYN-3: a queued bulk job a prefetch request joins is promoted and starts before the bulk job queued ahead of it", `Tests/ZTronAssetSyncTests/Engine/EngineBoundaryTests.swift:39` | `1dcc21e` · `docs/adr-drafts/s3f.md:8990` | ZTronAssetSyncTests: `EngineBoundaryTests.swift:42:9`, `Array(result.starts.prefix(2)) == result.order` |
| M-N-12 | Ignore any promotion of a queued job (including to the user lane) | S3F-11 (WP-F) | "R-SYN-3: a queued bulk job a user-initiated request joins is promoted and starts before the bulk job queued ahead of it", `Tests/ZTronAssetSyncTests/Engine/EngineBoundaryTests.swift:47` | `1dcc21e` · `docs/adr-drafts/s3f.md:8991` | ZTronAssetSyncTests: `EngineBoundaryTests.swift:50:9`, `Array(result.starts.prefix(2)) == result.order` |
| M-N-14 | Drop a backoff step (ceiling grows one step late) | S3F-11 (WP-F) | "R-SYN-5: the backoff ceiling doubles with every attempt, so some key draws above the previous attempt's ceiling", `Tests/ZTronAssetSyncTests/Engine/EngineBoundaryTests.swift:58` | `1dcc21e` · `docs/adr-drafts/s3f.md:8992` | ZTronAssetSyncTests: `EngineBoundaryTests.swift:73:13`, `largest > previous` |
| M-N-16 | 5xx breaker: error ratio boundary (>= becomes >) | S3F-11 (WP-F) | "R-SYN-5: a window whose 5xx share equals serverErrorRatio exactly opens the breaker", `Tests/ZTronAssetSyncTests/Engine/EngineBoundaryTests.swift:82` | `1dcc21e` · `docs/adr-drafts/s3f.md:8993` | ZTronAssetSyncTests: `EngineBoundaryTests.swift:94:9`, `breaker.state == .open(cause: .serverErrors, until: now.adding(seconds: 30), trips: 1)` |
| M-N-20 | Retry-After exactly equal to maxRetryAfter is deferred (> becomes >=) | S3F-11 (WP-F) | "R-SYN-5: a Retry-After equal to maxRetryAfter is honoured, one above it defers to the next run", `Tests/ZTronAssetSyncTests/Engine/EngineBoundaryTests.swift:99` | `1dcc21e` · `docs/adr-drafts/s3f.md:8994` | ZTronAssetSyncTests: `EngineBoundaryTests.swift:102:25`, `Backoff.delay(attempt: 1, retryAfter: policy.maxRetryAfter, policy: policy, seed: 1, key: 1)` |
| M-N-22 | Weak ETag accepted as the resume validator | S3D-3 (WP-D) | "R-NET-8: a weak ETag is never the resume validator: a pause keeps Last-Modified instead, or nothing without it", `Tests/ZTronAssetTransportTests/SizeAndResumeTests.swift:203` | `6f27ad7` · `docs/adr-drafts/s3d.md:305-310` | ZTronAssetTransportTests: `SizeAndResumeTests.swift:213:9` (argument tagCase → weak ETag only), `await iterator.next() == .paused(resumable: tagCase.kept != nil)` |
| M-N-39 | A later 429 with a shorter Retry-After shortens the origin throttle | S3F-11 (WP-F) | "R-SYN-5: a later transfer 429 with a shorter Retry-After never shortens the origin's throttle", `Tests/ZTronAssetSyncTests/Engine/EngineBoundaryTests.swift:114` | `1dcc21e` · `docs/adr-drafts/s3f.md:8995` | ZTronAssetSyncTests: `EngineBoundaryTests.swift:137:9`, `end == throttledAt.adding(seconds: 60)` |

- **M-N-12** failed 4 tests in the re-check (`summary.txt:6`): "R-SYN-2: a slot freed during an owed follow goes to the queued job the follow raises to user work, not to prefetch work queued before it (F-28)"; "R-SYN-2: with one slot, the queued job an owed follow raises to user work takes the freed slot and the room before prefetch work (F-28)"; "R-SYN-3: a queued bulk job a prefetch request joins is promoted and starts before the bulk job queued ahead of it"; "R-SYN-3: a queued bulk job a user-initiated request joins is promoted and starts before the bulk job queued ahead of it". ORCHESTRATION counts its issues as "`EngineBoundaryTests.swift:50` and 13 more issues" (`docs/ORCHESTRATION.md:546`).
- **M-S-11**'s close-out re-application failed both arguments (`failingWrite → 2` is the one the draft quotes, `docs/adr-drafts/s3b.md:118-120`); the re-check's first issue is `failingWrite → 1`, at the same line.
- **M-N-22**'s close-out run also failed at `SizeAndResumeTests.swift:215:9` for the "weak ETag and Last-Modified" argument (`docs/adr-drafts/s3d.md:308-310`).
- **M-N-39** was re-made for the re-check (§2.3); its discovery diff names `EngineFailures.swift:314` at `s3-base` (the record says `:317`).

## 5. SPEC §7.4's suggested probes

Every suggestion has at least one mutant, and each of those mutants was killed, at discovery or, for a survivor, in the re-check on `e840b0e`; no suggestion is uncovered. "Related" lists further mutants on the same rule.

| SPEC §7.4 suggestion | Mutant | Outcome | Related mutants |
|---|---|---|---|
| skip hash verification | M-S-01 | killed | M-S-13 (legacy adoption without the hash), M-S-22 (index trailer), M-S-23 (deep verification by size only): killed |
| publish a blob before verification | M-S-02 | killed | — |
| delete before publishing the snapshot | M-S-03 | killed; one parameterised test is its only guard (record) | M-S-15 (grace window), M-S-16 (commit blocker): killed |
| drop the lock | M-S-04 | killed | — |
| ignore `Retry-After` | M-N-01 (Backoff), M-N-02 (engine) | killed; M-N-01 only by `SyncContractTests.swift:76` (record) | M-N-20 (at `maxRetryAfter`) and M-N-39 (a shorter 429): survived, killed since (§4) |
| keep the app key on a cross-host redirect | M-N-03 | killed | M-N-23 (hop limit), M-N-25 (plain HTTP): killed |
| cancel a transfer when *any* waiter cancels | M-N-05 | killed (stopped by hand after it hung, §2.1) | — |
| off-by-one in LRU order | M-S-05 | killed, incidentally (record: no direct exact-fit test) | M-S-17 (residency boundary; the Storage target misses it, §7), M-S-18 (tie-break): killed |
| treat `403` as transient | M-N-04 | killed | M-N-15, M-N-17 (the authentication breaker): killed |
| forget to reset the sync stamp after a purge | M-S-06 | killed | M-S-21 (OS-purge evidence): killed |
| evict a leased asset | M-S-09 (both layers) | killed, by one test (record) | M-S-07 and M-S-08 (one layer each): survived, killed since (§4); M-S-14 (lease release): killed |
| swallow ENOSPC | M-S-10 (index commit), M-S-11 (staging), M-N-31 (Apple pack error), M-N-34 (URL-error classifier) | M-S-10, M-N-31 and M-N-34 killed; M-S-11 survived, killed since (§4) | — |

## 6. The close-outs' own mutant runs

The close-outs ran mutants of their own fixes under S3-R3. This section lists them by reference; the drafts hold the commands, logs and full failing lines. `<Name>` in WP-F's tables stands for `Tests/ZTronAssetSyncTests/Engine/EngineFollowBarrier<Name>Tests.swift`.

### 6.1 WP-F

Sources: ADR-057's WP-F records (`docs/DECISIONS.md:684`) and `docs/adr-drafts/s3f.md` "Point 6: run 12's work and the mutant runs" (`:8231-8323`). Scratch files are under `.worktrees/s3f/.build-s3f/c23/` (`mut-k23.txt`, `mut-e1.txt`, logs in `mut/`, the specifications in `tools/`).

**Point 6, run 13** (`tools/mut23s.py` on `git archive` of `f38dd8c`, 17:26:51-17:28:54 on 6 Nov, 1-minute load 2.98 to 6.15; each filter is the kill test alone, so each kill is that test's; every mutant failed both runs by assertions only, no time limit; `s3f.md:8260-8276`; the mutated lines are identical at the merged head, ADR-057):

| Mutant | Mutated line at `f38dd8c` | Killing test (commit) | Failing lines | Orders that fail |
|---|---|---|---|---|
| b22-no-waiter-owner | `EngineFailures.swift:858` | RerouteOwner (`1b911a1`) | `:424`, `:425`, `:429` (7 issues) | swept first, the only order that reaches it |
| p7 forget-at-last-batch | `EngineFollow.swift:762` | ReroutePinEnd (`486ee2a`) | `:371` (2 issues) | both |
| r5 lane-engine-copy | `EngineFailures.swift:841` | ReroutePinEnd (`486ee2a`) | `:373` (2 issues) | both |
| r8 fast-any-join | `EngineFailures.swift:838` | Unlisted (`8b252f2`) | `:188`, `:192`, `:195` (3 issues) | swept first, the only order that reaches it |
| vy owed-moves-too | `EngineMoves.swift:308` | MoveHolders (`06880a8`) | `:371`, `:384`, `:387` (3 issues) | swept first, the only order that reaches it |
| r2c made-ignores-verdicts | `EngineFollow.swift:704` | RerouteLayer (`9e9a500`) | `:554`, `:561`, `:564` (10 issues) | both |
| p2-after-verdict-replay-rule | `EngineJobs.swift:290` | AfterVerdictSpace (e1-P2's other side) | `:171`, `:172` (2 issues) | swept first, the only order that reaches it |

**Run 12's e1 runs** (`mut-e1.txt`, a snapshot of `64f276d`, from 16:25:30 at a load of 3.58; `s3f.md:8289-8316`):

| Mutant | Result | Orders that fail |
|---|---|---|
| ps-write-dropped (`EngineDispatch.swift:1271-1273`) | 2/2, 8 issues each: ReroutePinSupersede `:88`, `:89`, `:100`, `:101` | both |
| ps-write-always | 3/3, 5 issues each | visited first only; its swept-first side has no kill and stays open |
| ps-literal-requeue | 2/2, 4 issues each: ReroutePinSupersede `:88`, `:89` | both |
| p1-rule-false | 2/2 by assertions, no time limit; 8 to 10 issues a run (c23 #2, not independently verified); the kill rests on PinSpace `:154`, `:155`, `:167`, `:168` | both |
| p1-rule-true | 2/2, 4 issues each: PinSpace `:181`, `:182` | both |
| p1-le-as-lt | 2/2, 4 issues each: PinSpace `:167`, `:168` | both |
| p1-count-not-kept | 2/2, 7 to 8 issues a run (c23 #6, not independently verified): PinSpace `:111`, `:154`, `:155`, `:182` | both |
| p2-after-verdict-never | 2/2, 2 issues each: AfterVerdictSpace `:160`, `:161` | swept first, the only order that reaches it |
| p2-after-verdict-true | killed 2/2 swept first by the cycle-23 correctness verifier on a snapshot of `d88bdb1` (AfterVerdictSpace `:171`, `:172`; `.build-orchestrator/s3f-probes-c23/correct-mut-summary.txt`); not independently verified, and nobody repeated the run | swept first |

**Earlier cycles** (ADR-057, `docs/DECISIONS.md:684`): noDispatchOwedFlag (cycle 12) and noFlagPump (cycle 13) killed (`EngineFollowBarrierSurvivorTests.swift:76-77`, `:21-22`); spaceFailureEpochDropped killed in cycle 16 (`EngineFollowBarrierSpaceEpochTests.swift:71`); of cycle 21's twelve, b23-no-lane, b23-no-kind and f7 killed in cycle 22 (`4ca9044`) and r7 removed; laneJobsWalkAlways equivalent under S3-R19, alarmAtPark equivalent by reasoning and s1-groups-after equivalent (the purge's first turn removes no group); followSkipsPerTurnUnbounded and applyWalkedDrop cost only. M5 and M6, the R-SYN-15 mutants, are reconstructed (`s3f.md:11999-12000`) and fail the new R-SYN-15 test (`s3f.md:9096-9102`, `:758`).

**WP-F's recorded survivors and unkilled mutants** (ADR-057, `docs/DECISIONS.md:684` and `:640`; `s3f.md:8313-8322`):

- r2b and b22-no-run-owner: never run in point 6; open.
- ps-write-always's swept-first side: no kill; open.
- breakerReadLive: killed only by a time limit (`barrierAnswersAJoinOnTheBreakerAtItsRequest`), which S3-R3 does not count; open.
- s1-late-start (c23 #4): survives S1's test, because the test moves the clock only at the `?(true)` mark; S1's code is right by review, so S1 stays (re-open route: a seam mark inside the walk).
- e1-R1's rewritten kill table (the `r1-*` mutants of `mut-e1.py`) and `i5-pin-fold`'s re-run (T-E2): not run; open.
- Open with them, but not mutants: the three unreached lines (`EngineCommands.swift:1025`, `:1028`, `:1033` at the merged head; `:1001`, `:1004`, `:1009` at `9aa337c`) and item 5's default-tuning probe.

### 6.2 WP-G

`docs/adr-drafts/s3g.md`; listed for this file by ADR-057 (`docs/DECISIONS.md:646`). M05 and M01s were rebuilt from their descriptions, because their diffs were not on disk (`s3g.md:18-20`); diffs and logs are in `.build-s3g/mutants/`.

- MC1 (`reach` returning `max(radius, 0)`, the old walk): `PrefetchFacadeTests.swift:167:33` (`s3g.md:59-60`).
- M05 (the stopped forwarder's exit after `registerEvents` removed): `FacadeRaceTests.swift:437:9`, `registrations == 1` (`s3g.md:71-75`).
- M01s (`sync`'s hand-off narrowed to `.shutDown` and `.storageUnavailable`): `FacadeReopenTests.swift:775:9` for both cases (`s3g.md:122-124`).
- MR4 and MR2 (`reopenAttempts = 4` and `= 2`): MR4 fails at `FacadeReopenLimitTests.swift:52:9`, `:106:9` and `:107:9`, MR2 at those and `:53:9` (`.build-orchestrator/s3g-probes-c1/reqs-mutants-summary.txt:44-53`, `:54-63`). ADR-057 lists the four lines (`docs/DECISIONS.md:646`); the draft quotes `:52:9` and `:106:9` (`s3g.md:141-143`).
- MT1 and MT2 (the forwarder drops `clientStarted` or `maintenanceFinished`): each fails 10 of 10 model cases and passes on `s3-base`'s model; MC00 (the L5-R19 defect rebuilt) is still caught 10 of 10 (`s3g.md:104-115`).
- Discovery's M-N-11 and M-N-35 to M-N-38 are killed (§3).
- Not re-run on the merged head: these were measured on `wp/s3g` before WP-F's merge changed `SubscriberQueue.swift` (MC00's file), `EngineEvents.swift` and `EngineLifecycle.swift` (ADR-057, `docs/DECISIONS.md:670`).

### 6.3 WP-D

`docs/adr-drafts/s3d.md`; ADR-057 (`docs/DECISIONS.md:623`, `:673`, `:683`).

- M1 (the cycle-1 code, no rewrite loop) and M2 (`process(.finished)` no longer clears `priorities[name]`): fail at `BackgroundInterleavingTests.swift:454:9` and `:482:9` (`s3d.md:162-169`). Their evidence survives only as quotes: `.build-s3d/mutpkg` is gone (ADR-057, `docs/DECISIONS.md:673`).
- R1J (also MI: the serial taken before the entry token check) and R1K (`if` in place of the rewrite loop) survived the committed suite in cycle 2 and are killed by `2528a8c`: R1J at `BackgroundInterleavingTests.swift:531`, `:553`, `:554`; R1K at `:591`, `:592` (`s3d.md:190-200`; scratch copy `.build-s3d/c3/mutpkg`, 165 tests, load 12-16).
- MK (a `deinit` that finishes nothing) is pinned by `95bb342`; against MK the run ended at the hang guard (63.995 s, 2 issues; `s3d.md:221-227`).
- MG (a `Task` per priority change inside the control task's loop): the FIFO test alone catches it only some of the time (2 of 6 runs before `defc67e`; 1 of 5 to 10 of 10 after it, by load); whole-suite runs kill it every time through three other tests (`s3d.md:205-219`).
- The two clears of `priorityRequests` are equivalent by design: they only bound the table (`s3d.md:233-236`).
- Stage 2's mutant ME, at `BackgroundSessionBackend.swift:58-60` (the live driver's `resumeData` use), still survives: the file is coverage-excluded and device-only (S3-B-050); `docs/DEVICE-TEST-PLAN.md` DT-BG-04 exercises that path on a device. It is distinct from cycle 1's killed "ME".

### 6.4 WP-C

`docs/adr-drafts/s3c.md` "Mutant evidence (S3-R3)" (`:470-500`), in the scratch copy `.build-s3c/mut/src`:

- M-S-07, M-S-08 and M-S-20 killed (§4).
- Z (`fatalError` in `BlobDeletionUnit.run`): killed by `OracleTests` (`BlobUnits.swift:169: Fatal error: S3MUT Z`) and by `CleanupFlowCrashTests`.
- X (`fatalError` in `copyBlob`): killed by `CleanupFlowCrashTests` (`AssetStore+Publish.swift:358: Fatal error: S3MUT X: copyBlob ran`). Every shipped test passed it, and the oracle was not run against X (`s3c.md:484-485`, `.build-s3c/mut/run-mutants.sh:33`).
- G (`deletionBlocker` answers `.none` for every doomed key): killed by the grace- and acknowledgement-aware audit (235 issues in `OracleTests`, 363 in `CleanupFlowCrashTests`).
- C (the reaper ignores the commit blocker), F (no acknowledged snapshot needed) and S (no grace): each masked by another guard of `deletionBlocker`, and killed by WP-B's targeted tests (`StoreDeletionTests`, `LeaseTests`, `StoreRecoveryTests`; the confirmer's runs; `s3c.md:491-497`). C: masked in WP-C's oracle (oracle-C passed, `.build-s3c/mut/results.txt`); no flows run against C is on record (`run-mutants.sh:35`). F and S: masked in both (oracle-F/S and flows-F/S passed). The hunter's suggestion of commit faults inside the oracle's sequences, to reach C, was not made.

### 6.5 WP-B

`docs/adr-drafts/s3b.md`:

- The crash lens's environment-gated mutants: A, B and I killed (774, 384 and 52 issues); C, F, S, H and E not killed by that scenario, each for a reason it cannot reach (`s3b.md:89-96`).
- The confirmer's S3-CONF-06 mutant: `StoreApplyTests.swift:58:9`, 3 issues (`s3b.md:105-108`).
- M-S-11: both arguments of the new R-STO-6 test (`s3b.md:118-120`; §4).
- S3BASEREAP (`s3-base`'s `reap(maxKeys:)` spliced into `aafb43a`): `StoreDeletionTests.swift:311:30` (`s3b.md:157-160`).
- P (purged dooms rescued by launch adoption): two tests fail, 4 and 2 issues (`s3b.md:197-200`).
- GAIN, ACQ, REDOOM, REAP, OI14B and PERAPPLY (the counted releases and their take-back): 11, 6, 3, 3, 3 and 11 issues (`s3b.md:311-326`).

### 6.6 WP-A/WP-H

No mutant was assigned to WP-A/WP-H in Stage 3 (`docs/adr-drafts/s3ah.md:20`).

## 7. Open at the end of Stage 3

- **Discovery survivors:** none open; all 11 are killed by a close-out test on `e840b0e` (§4).
- **Weak spots the discovery agents recorded on killed mutants** (at discovery, on `s3-base`; not re-checked since). No Stage 3 ruling assigned them: a search of the rulings files, the drafts, DECISIONS, ARCHITECTURE and ORCHESTRATION for these ids finds them only in M-N-11's case, as killed (`docs/DECISIONS.md:646`).
  - M-S-17 (residency boundary, `>=` becomes `>`): the whole Storage target (459 tests) missed it; only the Sync test "R-SYN-10: ensureAvailable downloads a member that an apply evicted before it threw" (`Tests/ZTronAssetSyncTests/Engine/EngineRegressionCloseOutTests.swift:55`) killed it. Whether a Storage test added since catches it was not checked. The storage test the agent proposed ("R-CLN-4: an asset last accessed exactly minimumResidency ago is evictable, one second less is not") does not exist: `grep -rn "minimumResidency ago" Tests` finds nothing.
  - One catcher each: M-S-03 (one parameterised test), M-S-09 (one test; its single layers now have their own tests, §4), M-S-15 (only the 5-case parameterised test), M-S-25 (one test), M-N-01 (`SyncContractTests.swift:76` only), M-N-25 (one test, through the redirect policy) and M-N-28 (one table row).
  - M-S-05: killed only incidentally; no direct test that the dry-run plan is the shortest prefix at an exact fit.
  - M-N-02 (one test, partly a time limit; no engine test of a Retry-After inside the limit delaying a 5xx retry) and M-N-08 (mostly time limits; no sharp single-flight test).
  - M-N-11: the harness counts only the injected file-system seam's calls, so a direct `FileManager` call in `lookup` would not be seen (a design limit the agent recorded).
- **WP-F:** r2b, b22-no-run-owner, ps-write-always's swept-first side, breakerReadLive, s1-late-start, e1-R1's kill table and `i5-pin-fold` (§6.1); `docs/RESIDUAL-RISKS.md` carries them with the re-open route.
- **WP-D:** ME survives (device-only, §6.3); MG is caught by the whole suite only, not reliably by its own test.
- **WP-C:** C is masked in WP-C's oracle (oracle-C passed, `.build-s3c/mut/results.txt`); no flows run against C is on record (`.build-s3c/mut/run-mutants.sh:35`). F and S are masked in both (oracle-F/S and flows-F/S passed). All three are killed only by WP-B's targeted tests.
- **WP-G:** the mutants were not re-run on the merged head.

## Appendix A. Discovery diffs

One block per mutant, grouped by discovery group and then by the source module the diff changes, in record order. Each block is the saved diff without its `diff --git` and `index` lines; every hunk applies to `s3-base` (`b5796ba`). The line under each heading is the record: its location as recorded, its requirement, its outcome and its notes (absolute paths shortened to the main checkout).

### Storage group (27)

#### ZTronAssetStorage (27)

**M-S-01 · Skip the checksum comparison after hashing (hash verification skipped).** Record: `Sources/ZTronAssetStorage/Store/AssetStore+Publish.swift:121` · R-INT-2 / R-STO-3 (hash-verified before publication, I-1) · KILLED. performPublish step 5 removed: a staged file whose digest differs from the manifest checksum is placed and bound. Caught by the narrow filter PublishTests (StorePublishTests) with 9 issues.

```diff
--- a/Sources/ZTronAssetStorage/Store/AssetStore+Publish.swift
+++ b/Sources/ZTronAssetStorage/Store/AssetStore+Publish.swift
@@ -118,10 +118,7 @@ extension AssetStore {
             try await self.rejectIntegrity(.sizeMismatch(expected: size, actual: hashedBytes), verifying, sidecar)
         }
         // (5) Compare with the manifest's claim; checksum-less entries record our digest instead (R-INT-5/6).
-        if case .checksum(let expected) = identity, expected != digest {
-            // REENTRANCY: b-3 (proposed) — nothing: the call throws right after.
-            try await self.rejectIntegrity(.checksumMismatch(expected: expected, actual: digest), verifying, sidecar)
-        }
+
         // (6)–(10) Sidecar, reference, barrier, rename, bind; ids with another extension get their own copy.
         let groups = self.extensionGroups(ids, expectation)
         guard let primary = groups.first else {
```

**M-S-02 · Bind/publish the blob before the checksum comparison (publish before verification).** Record: `Sources/ZTronAssetStorage/Store/AssetStore+Publish.swift:121,150` · R-STO-3 (a blob never appears under its final path until hash-verified) · KILLED. The compare block is moved after bindVerifiedFile, so a mismatching file is placed and records are bound before .integrity is thrown. Caught by StorePublishTests with 4 issues.

```diff
--- a/Sources/ZTronAssetStorage/Store/AssetStore+Publish.swift
+++ b/Sources/ZTronAssetStorage/Store/AssetStore+Publish.swift
@@ -118,10 +118,6 @@ extension AssetStore {
             try await self.rejectIntegrity(.sizeMismatch(expected: size, actual: hashedBytes), verifying, sidecar)
         }
         // (5) Compare with the manifest's claim; checksum-less entries record our digest instead (R-INT-5/6).
-        if case .checksum(let expected) = identity, expected != digest {
-            // REENTRANCY: b-3 (proposed) — nothing: the call throws right after.
-            try await self.rejectIntegrity(.checksumMismatch(expected: expected, actual: digest), verifying, sidecar)
-        }
         // (6)–(10) Sidecar, reference, barrier, rename, bind; ids with another extension get their own copy.
         let groups = self.extensionGroups(ids, expectation)
         guard let primary = groups.first else {
@@ -147,6 +143,10 @@ extension AssetStore {
             await self.discardClaimed(verifying, sidecar)
             throw .fileSystem(failure)
         }
+        if case .checksum(let expected) = identity, expected != digest {
+            // REENTRANCY: b-3 (proposed) — nothing: the call throws right after.
+            try await self.rejectIntegrity(.checksumMismatch(expected: expected, actual: digest), verifying, sidecar)
+        }
         var (locations, rescued) = bound
         for group in groups.dropFirst() {
             // REENTRANCY: R4 — as above, for the copy bound under the group's extension.
```

**M-S-03 · Deletion grace starts from an acknowledged snapshot that still contained the key (delete before the lacking snapshot is published).** Record: `Sources/ZTronAssetStorage/Store/AssetStore+Snapshot.swift:88` · R-CLN-5 / I-3 / H-2 (snapshot publication always precedes file deletion) · KILLED. startGrace no longer requires info.sinceSnapshotVersion <= acknowledgedVersion. Narrow filters StoreSnapshotTests and GarbageCollectionTests passed; only the whole storage target caught it, through a single parameterised test (15 issues). That one test is the only guard of this rule.

```diff
--- a/Sources/ZTronAssetStorage/Store/AssetStore+Snapshot.swift
+++ b/Sources/ZTronAssetStorage/Store/AssetStore+Snapshot.swift
@@ -85,7 +85,7 @@ extension AssetStore {
     private func startGrace(acknowledgedVersion: UInt64, at uptime: MonotonicInstant) {
         let eligibleAt = uptime.adding(seconds: self.configuration.policy.deletionGrace)
         for (key, blobState) in self.state.core.blobTable {
-            guard case .doomed(var info) = blobState, info.eligibleAt == nil, info.sinceSnapshotVersion <= acknowledgedVersion else {
+            guard case .doomed(var info) = blobState, info.eligibleAt == nil else {
                 continue
             }
             info.eligibleAt = eligibleAt
```

**M-S-04 · Lock released right after acquisition (drop the lock).** Record: `Sources/ZTronAssetStorage/Store/LaunchReconciliation.swift:71` · R-STO-9 (single writer via advisory lock) · KILLED. OpenUnits.prepare calls fileSystem.releaseLock(lock) before returning the PreparedRoot, so a second open succeeds. Caught by StoreOpenTests.

```diff
--- a/Sources/ZTronAssetStorage/Store/LaunchReconciliation.swift
+++ b/Sources/ZTronAssetStorage/Store/LaunchReconciliation.swift
@@ -68,6 +68,7 @@ enum OpenUnits {
             }
             let blobsExisted = try OpenUnits.makeDirectory(layout.blobsDirectory, fileSystem)
             _ = try OpenUnits.makeDirectory(layout.stagingDirectory, fileSystem)
+            fileSystem.releaseLock(lock)
             return .success(PreparedRoot(layout: layout, lock: lock, blobsRecreated: !blobsExisted))
         } catch {
             fileSystem.releaseLock(lock)
```

**M-S-05 · Off-by-one in the LRU plan: EvictionOrder.plan keeps selecting at an exact fit (freed <= bytes).** Record: `Sources/ZTronAssetStorage/Eviction/EvictionOrder.swift:92` · R-CLN-4 (LRU eviction down to a target, shortest prefix of the eviction order) · KILLED. Killed only incidentally by the whole storage target; EvictionOrderTests and EvictionTests (the order and dry-run tests) both passed, so there is no direct test that the dry-run plan is the SHORTEST prefix when freed == requested exactly. Consider adding one. A first version of this probe (lastAccess '<=' in the sort comparator) was equivalent because the preceding '!=' guard makes '<' and '<=' identical, and was replaced.

```diff
--- a/Sources/ZTronAssetStorage/Eviction/EvictionOrder.swift
+++ b/Sources/ZTronAssetStorage/Eviction/EvictionOrder.swift
@@ -89,7 +89,7 @@ enum EvictionOrder {
         var victims: [EvictionVictim] = []
         var freed: Int64 = 0
         for ranked in ranking.order {
-            guard freed < bytes else {
+            guard freed <= bytes else {
                 break
             }
             ranking.appendVictims(of: ranked, to: &victims)
```

**M-S-06 · Purge no longer clears the sync stamp (forget to reset the stamp after a purge).** Record: `Sources/ZTronAssetStorage/Cleanup/StorePurge.swift:89` · R-CLN-6 (purge makes a sync due) / R-STO-2 · KILLED. clearStampForPurge keeps syncDue = true but leaves state.core.stamp set. Caught by PurgeTests (4 issues).

```diff
--- a/Sources/ZTronAssetStorage/Cleanup/StorePurge.swift
+++ b/Sources/ZTronAssetStorage/Cleanup/StorePurge.swift
@@ -86,7 +86,6 @@ extension AssetStore {
         guard self.state.core.stamp != nil || !self.state.core.syncDue else {
             return false
         }
-        self.state.core.stamp = nil
         self.state.core.syncDue = true
         self.markDirty(.soon)
         return true
```

**M-S-07 · AssetStore.evict no longer re-checks leases at apply time (single layer removed).** Record: `Sources/ZTronAssetStorage/Eviction/QuotaEviction.swift:268` · R-CLN-5 (eviction never removes a leased asset) · SURVIVED at discovery (§4). Defence in depth masks the mutant: acquireLease bumps lastAccess to now, so evict's 'not accessed since the selection' guard (stillEvictable) refuses the victim before the lease guard is reached. The lease guard is observable only when the lease lands at the instant of the last access (zero residency and a frozen clock); existing tests (EvictionTests chunkYieldRevalidates, protectedAssetsStay) never reach it. Real-clock reachability is a sub-microsecond window, so the severity is low, but the guard is untested.

```diff
--- a/Sources/ZTronAssetStorage/Eviction/QuotaEviction.swift
+++ b/Sources/ZTronAssetStorage/Eviction/QuotaEviction.swift
@@ -265,8 +265,7 @@ extension AssetStore {
     /// or `nil` when nothing was evicted.
     func evict(_ victims: ArraySlice<EvictionVictim>, rules: EvictionOrder.Rules, scan: inout HolderScan) -> BlobEviction? {
         guard let key = victims.first?.blob, case .live(let references)? = self.state.core.blobTable[key],
-            self.state.core.publishing.isEmpty || !self.state.core.publishing.contains(key),
-            self.state.cleanup.leases.isEmpty || self.state.cleanup.leases[key]?.isEmpty ?? true
+            self.state.core.publishing.isEmpty || !self.state.core.publishing.contains(key)
         else {
             return nil
         }
```

**M-S-08 · EvictionOrder.Ranking no longer excludes leased blobs (dry-run plan names and counts them).** Record: `Sources/ZTronAssetStorage/Eviction/EvictionOrder.swift:207` · R-CLN-5 / R-SYN-11 (eviction and its dry run never include a leased asset) · SURVIVED at discovery (§4). No test calls evictionPlan with a lease held. The maintenance run (evictIfNeeded) is still protected by evict's own lease guard, which is why EvictionTests protectedAssetsStay passes; only the synchronous dry run that sync's apply(eviction:) relies on is wrong (it over-reports freeable bytes, so a plan 'succeeds' that cannot free the space). M-S-09 shows that removing both layers is caught.

```diff
--- a/Sources/ZTronAssetStorage/Eviction/EvictionOrder.swift
+++ b/Sources/ZTronAssetStorage/Eviction/EvictionOrder.swift
@@ -204,7 +204,7 @@ enum EvictionOrder {
             order.reserveCapacity(self.tallies.count)
             for slot in self.tallies.indices where self.tallies[slot].evictable {
                 let key = self.tallies[slot].key
-                guard case .live? = blobTable[key], publishing.isEmpty || !publishing.contains(key), leases.isEmpty || leases[key]?.isEmpty ?? true else {
+                guard case .live? = blobTable[key], publishing.isEmpty || !publishing.contains(key) else {
                     continue
                 }
                 order.append(
```

**M-S-09 · Evict a leased asset: lease protection removed from both the ranking and evict().** Record: `Sources/ZTronAssetStorage/Eviction/EvictionOrder.swift:207, Sources/ZTronAssetStorage/Eviction/QuotaEviction.swift:268` · R-CLN-4 / R-CLN-5 (leased assets are never evicted) · KILLED. Combined M-S-07 + M-S-08. Killed by exactly one test (EvictionTests protectedAssetsStay, 1 issue); the two single-layer mutants survive, so the whole lease protection of eviction rests on that one test.

```diff
--- a/Sources/ZTronAssetStorage/Eviction/EvictionOrder.swift
+++ b/Sources/ZTronAssetStorage/Eviction/EvictionOrder.swift
@@ -204,7 +204,7 @@ enum EvictionOrder {
             order.reserveCapacity(self.tallies.count)
             for slot in self.tallies.indices where self.tallies[slot].evictable {
                 let key = self.tallies[slot].key
-                guard case .live? = blobTable[key], publishing.isEmpty || !publishing.contains(key), leases.isEmpty || leases[key]?.isEmpty ?? true else {
+                guard case .live? = blobTable[key], publishing.isEmpty || !publishing.contains(key) else {
                     continue
                 }
                 order.append(
--- a/Sources/ZTronAssetStorage/Eviction/QuotaEviction.swift
+++ b/Sources/ZTronAssetStorage/Eviction/QuotaEviction.swift
@@ -265,8 +265,7 @@ extension AssetStore {
     /// or `nil` when nothing was evicted.
     func evict(_ victims: ArraySlice<EvictionVictim>, rules: EvictionOrder.Rules, scan: inout HolderScan) -> BlobEviction? {
         guard let key = victims.first?.blob, case .live(let references)? = self.state.core.blobTable[key],
-            self.state.core.publishing.isEmpty || !self.state.core.publishing.contains(key),
-            self.state.cleanup.leases.isEmpty || self.state.cleanup.leases[key]?.isEmpty ?? true
+            self.state.core.publishing.isEmpty || !self.state.core.publishing.contains(key)
         else {
             return nil
         }
```

**M-S-10 · Index commit swallows ENOSPC (write failure returns as success, no fallback or retry).** Record: `Sources/ZTronAssetStorage/Index/IndexCommitUnit.swift:316` · R-STO-4 / R-STO-6 (atomic index replacement; ENOSPC fault handling, ADR-015) · KILLED. writeTemporary's 'catch .noSpace' body replaced by 'return'. Caught by the IndexCommit state-space suites (269 issues, 104 s under load). StoreCommitTests and StoreRecoveryTests did not need to run because the first filter failed.

```diff
--- a/Sources/ZTronAssetStorage/Index/IndexCommitUnit.swift
+++ b/Sources/ZTronAssetStorage/Index/IndexCommitUnit.swift
@@ -313,11 +313,7 @@ enum IndexCommitUnit {
         do throws(FileSystemError) {
             try fileSystem.write(data, to: temporary, mode: .truncate)
         } catch .noSpace {
-            try fileSystem.removeItem(at: temporary)
-            if committedFile == .current, IndexCommitUnit.isFile(layout.indexURL(.current), fileSystem) {
-                try fileSystem.removeItem(at: layout.indexURL(.previous))
-            }
-            try fileSystem.write(data, to: temporary, mode: .truncate)
+            return
         }
     }
 
```

**M-S-11 · StoreStagingSink.writeStaged swallows a .noSpace write failure and reports success (swallow ENOSPC).** Record: `Sources/ZTronAssetStorage/Staging/StoreStagingSink.swift:175` · R-STO-6 (ENOSPC injected and surfaced; ADR-013 maps it to insufficientSpace) · SURVIVED at discovery (§4). The only ENOSPC staging test (StagingSinkTests, partialsAndContinuations) covers appendPartial on '.part'; the writeStaged path (the Apple-tier PackCopier uses it) has no ENOSPC test, and the AppleHosted tests use a fake sink. With the mutant, writeStaged keeps going after a failed write and renames a short or empty file into place as a success, which would then fail the size check later as a misleading sizeMismatch instead of insufficientSpace.

```diff
--- a/Sources/ZTronAssetStorage/Staging/StoreStagingSink.swift
+++ b/Sources/ZTronAssetStorage/Staging/StoreStagingSink.swift
@@ -172,6 +172,8 @@ package struct StoreStagingSink: StagingSink {
                     }
                     do throws(FileSystemError) {
                         try fileSystem.write(data, to: temporary, mode: truncate ? .truncate : .append)
+                    } catch .noSpace {
+                        // swallowed
                     } catch {
                         throw FileSystemErrorMapping.stagingError(error)
                     }
```

**M-S-12 · Skip the sync of index.tmp before the rename (skip the index sync before rename).** Record: `Sources/ZTronAssetStorage/Index/IndexCommitUnit.swift:176` · R-STO-4 (write temp, durable flush, rename) · KILLED. Step 3 removed. Caught by StoreCommitTests (2 issues).

```diff
--- a/Sources/ZTronAssetStorage/Index/IndexCommitUnit.swift
+++ b/Sources/ZTronAssetStorage/Index/IndexCommitUnit.swift
@@ -173,7 +173,6 @@ enum IndexCommitUnit {
         }
         do throws(FileSystemError) {
             try IndexCommitUnit.writeTemporary(data, layout: layout, committedFile: outcome.committedFile, fileSystem: fileSystem)
-            try fileSystem.synchronizeFile(at: temporary, level: level)
         } catch {
             try? fileSystem.removeItem(at: temporary)
             outcome.result = .failure(.fileSystem(error))
```

**M-S-13 · Legacy migration adopts a file under its claimed digest without checking the hash.** Record: `Sources/ZTronAssetStorage/Migration/LegacyPhases.swift:247,257` · R-STO-11 (adopt every legacy file whose checksum verifies, drop the rest) · KILLED. Two hunks: the 'hashed.digest == file.digest' clause is dropped from the guard and adoptVerifiedFile receives file.digest instead of hashed.digest. A single-hunk version (guard only) is behaviourally equivalent because adoptVerifiedFile's .digest expectation already refuses records that expect another digest, so I used the two-hunk version. Caught by LegacyMigrationTests (3 issues).

```diff
--- a/Sources/ZTronAssetStorage/Migration/LegacyPhases.swift
+++ b/Sources/ZTronAssetStorage/Migration/LegacyPhases.swift
@@ -244,7 +244,7 @@ extension AssetStore {
         // REENTRANCY: k-6 (proposed) — the records below are read once no other call's adoption of the file is in flight.
         try await self.awaitLegacyAdoption(of: file)
         let wanting = self.legacyWanters(file)
-        guard hashed.digest == file.digest, file.byteSize.map({ $0 == hashed.byteCount }) ?? true, !wanting.isEmpty else {
+        guard file.byteSize.map({ $0 == hashed.byteCount }) ?? true, !wanting.isEmpty else {
             return self.legacyAdopted(file) ? .alreadyAdopted : .dropped
         }
         // No other adoption of the file is in flight in this turn (the wait above): this call's starts.
@@ -254,7 +254,7 @@ extension AssetStore {
             // REENTRANCY: R11, R18, R3, R4 — `adoptVerifiedFile` re-validates every record after its placement unit and
             // binds only those that still expect the digest; this call's mark in `adopting` keeps every other call that
             // processes the file waiting until the binding is done (k-5, k-6).
-            locations = try await self.adoptVerifiedFile(at: url, digest: hashed.digest, byteCount: hashed.byteCount, for: wanting)
+            locations = try await self.adoptVerifiedFile(at: url, digest: file.digest, byteCount: hashed.byteCount, for: wanting)
         } catch {
             self.endLegacyAdoption(of: file)
             try AssetStore.rethrowLifecycle(error)
```

**M-S-14 · Releasing one lease drops every holder of the blob (release a lease early).** Record: `Sources/ZTronAssetStorage/Cleanup/StoreLeases.swift:33` · R-CLN-5 / R-CAR-8 (a blob is not deleted while any lease holds it) · KILLED. Caught by LeaseTests (1 issue).

```diff
--- a/Sources/ZTronAssetStorage/Cleanup/StoreLeases.swift
+++ b/Sources/ZTronAssetStorage/Cleanup/StoreLeases.swift
@@ -30,6 +30,7 @@ extension AssetStore {
     /// Valid in every phase: a lease released after `close()` changes nothing that matters (leases end with the store).
     package func releaseLease(_ lease: AssetLease) -> MonotonicInstant? {
         if var holders = self.state.cleanup.leases[lease.blob], holders.removeValue(forKey: lease.token) != nil {
+            holders.removeAll()
             self.state.cleanup.leases[lease.blob] = holders.isEmpty ? nil : holders
             if holders.isEmpty {
                 self.state.cleanup.leasedBytes[lease.blob] = nil
```

**M-S-15 · Reaper skips the awake-clock grace window.** Record: `Sources/ZTronAssetStorage/Store/AssetStore+Reaper.swift:61` · R-CLN-5 / I-3 (deletion only after the grace window) · KILLED. The test named 'R-CLN-5: deletion waits for the acknowledged snapshot without the blob, the grace window and every lease' did NOT fail: the fresh-acknowledgement rule (an acknowledged install started at or after eligibleAt) independently delays deletion, so the grace check is only observable through the 5-case parameterised test (LeaseTests took 64 s with the mutant).

```diff
--- a/Sources/ZTronAssetStorage/Store/AssetStore+Reaper.swift
+++ b/Sources/ZTronAssetStorage/Store/AssetStore+Reaper.swift
@@ -58,9 +58,7 @@ extension AssetStore {
         if let leases = self.state.cleanup.leases[key], !leases.isEmpty {
             return .lease
         }
-        if eligibleAt > self.environment.time.uptimeNow() {
-            return .grace(eligibleAt)
-        }
+
         guard let fresh = self.state.core.snapshots.lastAcknowledgedInstallStart, fresh >= eligibleAt else {
             let attempted = self.state.core.snapshots.lastInstallStart.map { $0 >= eligibleAt } ?? false
             return .freshAcknowledgement(unanswered: attempted)
```

**M-S-16 · Reaper ignores the 'dropping generation not yet committed' blocker (delete before commit).** Record: `Sources/ZTronAssetStorage/Store/AssetStore+Reaper.swift:55` · R-CLN-5 / R-STO-4 / I-3 (never unlink a blob a power loss could still need) · KILLED. GarbageCollectionTests and StoreCrashTests (7 tests, 10 s) passed; StoreRecoveryTests caught it (6 issues).

```diff
--- a/Sources/ZTronAssetStorage/Store/AssetStore+Reaper.swift
+++ b/Sources/ZTronAssetStorage/Store/AssetStore+Reaper.swift
@@ -52,9 +52,7 @@ extension AssetStore {
         guard let eligibleAt = info.eligibleAt else {
             return .acknowledgement
         }
-        if self.state.core.committedGeneration < info.droppedInGeneration {
-            return .commit
-        }
+
         if let leases = self.state.cleanup.leases[key], !leases.isEmpty {
             return .lease
         }
```

**M-S-17 · Eviction residency window boundary off-by-one ('>=' becomes '>').** Record: `Sources/ZTronAssetStorage/Eviction/EvictionOrder.swift:54` · R-CLN-4 / R-CLN-5 (not accessed within minimumResidency / the grace window) · KILLED. Storage-level SURVIVOR that an engine test catches incidentally. MISSING storage test (Tests/ZTronAssetStorageTests/Cleanup/EvictionTests.swift): 'R-CLN-4: an asset last accessed exactly minimumResidency ago is evictable, one second less is not' (policy minimumResidency 600, seed one asset, advance 599 and expect evictionPlan(toFree: 1) == nil, advance 1 more and expect a plan naming the asset and evictIfNeeded freeing it). Verified: passes clean, fails on the mutant (probe test residencyBoundary). protectedAssetsStay only tests 599 s, never the edge. Note the SPEC wording 'not accessed within minimumResidency' is ambiguous at equality; the code and its doc comment say equality is evictable.

```diff
--- a/Sources/ZTronAssetStorage/Eviction/EvictionOrder.swift
+++ b/Sources/ZTronAssetStorage/Eviction/EvictionOrder.swift
@@ -51,7 +51,7 @@ enum EvictionOrder {
             guard policy != .essential, !pinned, self.protecting.isEmpty || !self.protecting.contains(id()) else {
                 return false
             }
-            return self.now.timeIntervalSince(lastAccess) >= self.residency
+            return self.now.timeIntervalSince(lastAccess) > self.residency
         }
     }
 
```

**M-S-18 · LRU tie-break flipped: smaller blob first instead of larger first.** Record: `Sources/ZTronAssetStorage/Eviction/EvictionOrder.swift:229` · R-CLN-4 (least-recently-used first, ties: larger first) · KILLED. Caught by EvictionTests (4 issues). EvictionOrderTests (2 tests) does not cover the tie-break.

```diff
--- a/Sources/ZTronAssetStorage/Eviction/EvictionOrder.swift
+++ b/Sources/ZTronAssetStorage/Eviction/EvictionOrder.swift
@@ -226,7 +226,7 @@ enum EvictionOrder {
                     return lhs.lastAccess < rhs.lastAccess
                 }
                 if lhs.bytes != rhs.bytes {
-                    return lhs.bytes > rhs.bytes
+                    return lhs.bytes < rhs.bytes
                 }
                 if lhs.prefix != rhs.prefix {
                     return lhs.prefix < rhs.prefix
```

**M-S-19 · Staging GC ignores active-transfer claims (collects claimed files past the claim grace).** Record: `Sources/ZTronAssetStorage/Cleanup/StagingCollection.swift:70` · R-CLN-2 / R-CLN-3 (staging files owned by an active transfer are kept) · KILLED. Caught by GarbageCollectionTests (7 issues).

```diff
--- a/Sources/ZTronAssetStorage/Cleanup/StagingCollection.swift
+++ b/Sources/ZTronAssetStorage/Cleanup/StagingCollection.swift
@@ -67,7 +67,7 @@ enum StagingCollection {
             if age > policy.stagingMaxAge {
                 return true
             }
-            return !claimed.contains(name.transfer) && age > policy.stagingClaimGrace
+            return age > policy.stagingClaimGrace
         }
     }
 }
```

**M-S-20 · Orphan GC compares the age with 0 instead of orphanGrace (grace ignored).** Record: `Sources/ZTronAssetStorage/Cleanup/OrphanCollection.swift:236` · R-CLN-2 (orphans removed only after a grace period) · SURVIVED at discovery (§4). orphanGC plants its 'young' control blob AFTER the clock advance, so its age is exactly 0 and 'age > 0' is false; the test never has an orphan with 0 < age < grace, nor one at exactly the grace. A real regression here would delete just-published, not yet committed blobs on the next GC.

```diff
--- a/Sources/ZTronAssetStorage/Cleanup/OrphanCollection.swift
+++ b/Sources/ZTronAssetStorage/Cleanup/OrphanCollection.swift
@@ -233,7 +233,7 @@ enum OrphanCollection {
         var decision = Decision(unknown: [:], sweep: [])
         for blob in listed.joined() where !known.contains(where: { $0.contains(blob.key) }) {
             decision.unknown[blob.key] = blob.item.byteSize
-            guard !expected.contains(blob.key), let modified = blob.item.modifiedAt, now.timeIntervalSince(modified) > grace else {
+            guard !expected.contains(blob.key), let modified = blob.item.modifiedAt, now.timeIntervalSince(modified) > 0 else {
                 continue
             }
             decision.sweep.append(Swept(key: blob.key, size: blob.item.byteSize))
```

**M-S-21 · Launch reconciliation no longer treats a missing or wrong-sized blob as OS-purge evidence.** Record: `Sources/ZTronAssetStorage/Store/LaunchReconciliation.swift:222` · R-CLN-7 (OS purge detected: stamp reset, sync due) · KILLED. 'missing > 0' dropped from osPurge. Caught by LaunchReconciliationTests (1 issue).

```diff
--- a/Sources/ZTronAssetStorage/Store/LaunchReconciliation.swift
+++ b/Sources/ZTronAssetStorage/Store/LaunchReconciliation.swift
@@ -219,7 +219,7 @@ enum LaunchReconciliation {
             }
         }
         let orphans = onDisk.filter { table[$0.key] == nil }
-        let osPurge = missing > 0 || (hadPresent && onDisk.isEmpty) || (blobsRecreated && hadPresent)
+        let osPurge = (hadPresent && onDisk.isEmpty) || (blobsRecreated && hadPresent)
         return Result(
             records: records,
             blobTable: table,
```

**M-S-22 · Index decode skips the SHA-256 trailer comparison.** Record: `Sources/ZTronAssetStorage/Index/IndexCodec.swift:383` · R-STO-4 (torn or corrupt index never trusted) · KILLED. Caught by IndexCodecTests (2 issues).

```diff
--- a/Sources/ZTronAssetStorage/Index/IndexCodec.swift
+++ b/Sources/ZTronAssetStorage/Index/IndexCodec.swift
@@ -380,7 +380,7 @@ enum IndexCodec {
         }
         let signed = IndexHeader.length + Int(header.bodyLength)
         let digest = Array(SHA256.hash(data: bytes[0..<signed]))
-        guard digest.elementsEqual(bytes[signed..<expected]) else {
+        guard digest.count == IndexHeader.trailerLength else {
             return .failure(.trailerMismatch)
         }
         do throws(IndexDecodeError) {
```

**M-S-23 · Deep verification ignores the digest (size-only check), so bit rot passes.** Record: `Sources/ZTronAssetStorage/Integrity/DeepVerification.swift:82` · R-INT-4 (resident blobs verified, corrupt ones repaired) · KILLED. Caught by IntegrityTests (16 issues).

```diff
--- a/Sources/ZTronAssetStorage/Integrity/DeepVerification.swift
+++ b/Sources/ZTronAssetStorage/Integrity/DeepVerification.swift
@@ -79,7 +79,7 @@ extension AssetStore {
             }
             self.state.integrity.cursor = first
             report.bytesVerified = report.bytesVerified.addingSaturating(outcome?.byteCount ?? item.size)
-            if let outcome, outcome.digest == key.hash, outcome.byteCount == item.size {
+            if let outcome, outcome.byteCount == item.size {
                 let now = self.environment.time.now()
                 for id in holders {
                     self.state.core.records[id]?.verifiedAt = now
```

**M-S-24 · Reaper treats a failed unlink as success (failure swallowed, key dropped from the table).** Record: `Sources/ZTronAssetStorage/Store/AssetStore+Reaper.swift:194` · R-CLN-2 / R-CLN-12 (failed unlinks stay doomed with backoff) · KILLED. Caught by GarbageCollectionTests (2 issues).

```diff
--- a/Sources/ZTronAssetStorage/Store/AssetStore+Reaper.swift
+++ b/Sources/ZTronAssetStorage/Store/AssetStore+Reaper.swift
@@ -191,7 +191,7 @@ extension AssetStore {
                         self.state.core.blobTable[key] = .doomed(info)
                     }
                     queue.insert(key, at: queue.startIndex + (position - outcome.attempted))
-                } else if outcome.failures[key] != nil, var doom = info {
+                } else if false, outcome.failures[key] != nil, var doom = info {
                     doom.failedUnlinks += 1
                     doom.eligibleAt = uptime.adding(seconds: AssetStore.unlinkBackoff(afterFailures: doom.failedUnlinks))
                     self.state.core.blobTable[key] = .doomed(doom)
```

**M-S-25 · Reaper deletes while the store is degraded (degraded blocker removed).** Record: `Sources/ZTronAssetStorage/Store/AssetStore+Reaper.swift:49` · R-STO-4 (a torn, corrupt or newer-schema index never causes blobs to be deleted) · KILLED. StoreRecoveryTests and GarbageCollectionTests passed; only the whole storage target caught it, via a single test (2 issues), so this guard has one catcher.

```diff
--- a/Sources/ZTronAssetStorage/Store/AssetStore+Reaper.swift
+++ b/Sources/ZTronAssetStorage/Store/AssetStore+Reaper.swift
@@ -46,9 +46,7 @@ extension AssetStore {
         if self.state.core.unavailable != nil {
             return .unavailable
         }
-        if self.state.core.degraded {
-            return .degraded
-        }
+
         guard let eligibleAt = info.eligibleAt else {
             return .acknowledgement
         }
```

**M-S-26 · Reader access stamps no longer clamped to now (future access pins an asset as recent).** Record: `Sources/ZTronAssetStorage/Store/AssetStore+Snapshot.swift:108` · R-STO-13 / R-CLN-4 (LRU input; store-2 S2-19) · KILLED. Caught by StoreSnapshotTests (2 issues).

```diff
--- a/Sources/ZTronAssetStorage/Store/AssetStore+Snapshot.swift
+++ b/Sources/ZTronAssetStorage/Store/AssetStore+Snapshot.swift
@@ -105,7 +105,7 @@ extension AssetStore {
             guard var record = self.state.core.records[id] else {
                 continue
             }
-            let clamped = min(stamp, now)
+            let clamped = stamp
             if clamped > record.lastAccess {
                 record.lastAccess = clamped
                 self.state.core.records[id] = record
```

**M-S-27 · Quota arithmetic ignores pending reclaim (doomed bytes not counted as soon-free).** Record: `Sources/ZTronAssetStorage/Eviction/EvictionOrder.swift:356` · R-CLN-4 (budget resolved over usage plus free space plus pending reclaim, store-2 S2-06) · KILLED. Caught by EvictionTests (4 issues).

```diff
--- a/Sources/ZTronAssetStorage/Eviction/EvictionOrder.swift
+++ b/Sources/ZTronAssetStorage/Eviction/EvictionOrder.swift
@@ -353,7 +353,7 @@ enum EvictionOrder {
     /// `min(hysteresis × budget, used − reserve shortfall)`. Zero when nothing is due.
     static func bytesToFree(usedBytes used: Int64, availableBytes available: Int64, pendingReclaim pending: Int64, policy: StoragePolicy) -> Int64 {
         let used = max(0, used)
-        let effective = max(0, available).addingSaturating(max(0, pending))
+        let effective = max(0, available)
         let budget = policy.budget.resolve(usedBytes: used, availableBytes: effective)
         let shortfall = max(0, max(0, policy.reserveFreeBytes) - effective)
         guard used > budget || shortfall > 0 else {
```

### Network group (37)

#### ZTronAssetSync (16)

**M-N-01 · Ignore Retry-After in the backoff delay (mandatory).** Record: `Sources/ZTronAssetSync/Engine/EngineSupport.swift:215` · R-SYN-5 (honour Retry-After as a lower bound) · KILLED. Backoff.delay returns the jittered value without max(jittered, retryAfter). Only this one unit test (SyncContractTests.swift:76) fails; no engine-level test catches it, because the 429 path re-applies the bound itself.

```diff
--- a/Sources/ZTronAssetSync/Engine/EngineSupport.swift
+++ b/Sources/ZTronAssetSync/Engine/EngineSupport.swift
@@ -212,7 +212,7 @@ package enum Backoff {
         let ceiling = min(policy.maxDelay, policy.baseDelay * pow(2, min(exponent, 62)))
         let unit = KeyedRandom.unitInterval(seed: seed, key: key, counter: UInt64(max(attempt, 1)))
         let jittered = max(0, ceiling) * unit
-        return max(jittered, retryAfter ?? 0)
+        return jittered
     }
 }
 
```

**M-N-02 · Engine drops the Retry-After hint on a transient failure.** Record: `Sources/ZTronAssetSync/Engine/EngineFailures.swift:235` · R-SYN-5 (honour Retry-After) · KILLED. retryLater uses retryAfter = nil. Killed by one test (EngineRecoveryTests.swift:109, :121), partly as a 60 s time limit. No test covers a Retry-After inside the limit that delays a 5xx retry at engine level.

```diff
--- a/Sources/ZTronAssetSync/Engine/EngineFailures.swift
+++ b/Sources/ZTronAssetSync/Engine/EngineFailures.swift
@@ -232,7 +232,7 @@ extension SyncEngine {
         let policy = remaining.lane == .userInitiated ? self.tuning.interactiveRetry : self.tuning.retry
         let retryAfter: TimeInterval?
         if case .transient(_, let hint?) = error {
-            retryAfter = hint.seconds(from: wall)
+            retryAfter = nil; _ = hint
         } else {
             retryAfter = nil
         }
```

**M-N-05 · Cancel the running transfer when any one waiter withdraws (mandatory).** Record: `Sources/ZTronAssetSync/Engine/EngineJobs.swift:250` · R-SYN-4 / H-3 (a caller's cancellation affects only that caller) · KILLED. removeInterest abandons the active attempt whenever any interest is removed, not only the last. One further test hung to its 60 s limit and I killed the run by hand (R-SYN-4: 100 callers on one asset with seeded random cancellations share one transfer and each resumes exactly once).

```diff
--- a/Sources/ZTronAssetSync/Engine/EngineJobs.swift
+++ b/Sources/ZTronAssetSync/Engine/EngineJobs.swift
@@ -254,6 +254,9 @@ extension SyncEngine {
                 self.retire(transfer)
             }
         } else {
+            if let active = job.active {
+                self.abandon(transfer, active)
+            }
             self.relane(transfer, from: before)
         }
         self.notifyObservers()
```

**M-N-08 · Break manifest-fetch single flight.** Record: `Sources/ZTronAssetSync/Engine/EngineManifest.swift:79` · R-SYN-4 (one manifest fetch is shared by concurrent askers) · KILLED. The manifestFetch == nil guard was removed from beginManifestFetch. Caught mostly through 60 s time limits plus expectation failures (EngineRegressionCycle22Tests.swift:524, Cycle18:209). No sharp test asserts that N unknown-id resolves send one manifest GET.

```diff
--- a/Sources/ZTronAssetSync/Engine/EngineManifest.swift
+++ b/Sources/ZTronAssetSync/Engine/EngineManifest.swift
@@ -76,7 +76,7 @@ extension SyncEngine {
 
     /// Starts the fetch task unless one runs.
     func beginManifestFetch() {
-        guard self.state.manifestFetch == nil, self.isRunning || self.state.lifecycle == .starting else {
+        guard self.isRunning || self.state.lifecycle == .starting else {
             return
         }
         self.state.lastFetch += 1
```

**M-N-09 · Ignore promotion bulk to prefetch of a queued job.** Record: `Sources/ZTronAssetSync/Engine/EngineJobs.swift:187` · R-SYN-3 (a request at a higher lane promotes the shared job; sync-1 S1-06) · SURVIVED at discovery (§4). relane for a queued job: `after != before || isUser` became `after < before || isUser`, so a promotion that is not to the user lane is never re-queued into the higher lane's queue and the job keeps its bulk rank. Existing promotion tests only cover running (downloading) jobs. All 7 targets pass (Sync 351, Kit 85, Compat 71, Storage 459, Model 84, Transport 151, Apple 104). Candidate test: .build-orchestrator/s3-probes/mut-network/M-N-09-candidate-test.swift. It passes on s3-base and fails on this mutant.

```diff
--- a/Sources/ZTronAssetSync/Engine/EngineJobs.swift
+++ b/Sources/ZTronAssetSync/Engine/EngineJobs.swift
@@ -184,7 +184,7 @@ extension SyncEngine {
         let isUser = after == .userInitiated
         switch job.state {
         case .queued:
-            if after != before || isUser {
+            if after < before || isUser {
                 self.enqueue(transfer)
             }
         case .downloading:
```

**M-N-12 · Ignore any promotion of a queued job (including to the user lane).** Record: `Sources/ZTronAssetSync/Engine/EngineJobs.swift:187` · R-SYN-3 / R-NET-10 (promotion of a queued shared job) · SURVIVED at discovery (§4). relane for a queued job: `after != before || isUser` became `after < before`. A queued bulk job that a user-initiated waiter joins stays in the bulk queue. Survives all 7 targets, Benchmarks skipped. Candidate: .build-orchestrator/s3-probes/mut-network/M-N-12-candidate-test.swift (same file as M-N-09's). It passes on s3-base and fails on this mutant. A user-lane promotion that is invisible to every test is the more serious of the two survivors.

```diff
--- a/Sources/ZTronAssetSync/Engine/EngineJobs.swift
+++ b/Sources/ZTronAssetSync/Engine/EngineJobs.swift
@@ -184,7 +184,7 @@ extension SyncEngine {
         let isUser = after == .userInitiated
         switch job.state {
         case .queued:
-            if after != before || isUser {
+            if after < before {
                 self.enqueue(transfer)
             }
         case .downloading:
```

**M-N-13 · Running transfer: promotion never reaches the transport.** Record: `Sources/ZTronAssetSync/Engine/EngineJobs.swift:197` · R-NET-10 / R-SYN-3 · KILLED. setPriority was moved inside the demotion branch only, so a promotion of a running transfer is never sent.

```diff
--- a/Sources/ZTronAssetSync/Engine/EngineJobs.swift
+++ b/Sources/ZTronAssetSync/Engine/EngineJobs.swift
@@ -194,8 +194,8 @@ extension SyncEngine {
             if after > before {
                 self.state.metrics.promotions += 1
             }
-            self.setPriority(transfer, after)
             if after < before {
+                self.setPriority(transfer, after)
                 self.pauseIfRefused(transfer)
             }
         case .failed(let disposition):
```

**M-N-14 · Drop a backoff step (ceiling grows one step late).** Record: `Sources/ZTronAssetSync/Engine/EngineSupport.swift:211` · R-SYN-5 (exponential backoff with full jitter) · SURVIVED at discovery (§4). exponent = max(attempt - 1, 1) - 1 makes attempts 1 and 2 share the same ceiling and shifts every later one down a step. The existing test asserts only delay >= 0 && delay <= ceiling (an upper bound), so any slower backoff passes. Survives all 7 targets. Candidate: .build-orchestrator/s3-probes/mut-network/M-N-14-candidate-test.swift. It passes on s3-base and fails on this mutant.

```diff
--- a/Sources/ZTronAssetSync/Engine/EngineSupport.swift
+++ b/Sources/ZTronAssetSync/Engine/EngineSupport.swift
@@ -208,7 +208,7 @@ package enum Backoff {
         if let retryAfter, retryAfter > policy.maxRetryAfter {
             return nil
         }
-        let exponent = Double(max(attempt, 1) - 1)
+        let exponent = Double(max(attempt - 1, 1) - 1)
         let ceiling = min(policy.maxDelay, policy.baseDelay * pow(2, min(exponent, 62)))
         let unit = KeyedRandom.unitInterval(seed: seed, key: key, counter: UInt64(max(attempt, 1)))
         let jittered = max(0, ceiling) * unit
```

**M-N-15 · Auth breaker threshold off by one (>= becomes >).** Record: `Sources/ZTronAssetSync/Engine/EngineSupport.swift:~468` · R-SYN-5 (breaker trips after repeated authentication failures) · KILLED. authSuspects.count >= authDistinctAssets became >.

```diff
--- a/Sources/ZTronAssetSync/Engine/EngineSupport.swift
+++ b/Sources/ZTronAssetSync/Engine/EngineSupport.swift
@@ -473,7 +473,7 @@ package struct CircuitBreaker: Sendable, Hashable {
             if !self.authSuspects.contains(asset) {
                 self.authSuspects.append(asset)
             }
-            if self.authSuspects.count >= max(1, self.policy.authDistinctAssets) {
+            if self.authSuspects.count > max(1, self.policy.authDistinctAssets) {
                 self.open(.authentication, trips: self.carriedTrips + 1, at: now, seed: seed)
             }
         case .failure(_, .serverErrors, _):
```

**M-N-16 · 5xx breaker: error ratio boundary (>= becomes >).** Record: `Sources/ZTronAssetSync/Engine/EngineSupport.swift:~471` · R-SYN-5 (trip after sustained 5xx at serverErrorRatio) · SURVIVED at discovery (§4). Double(errors) >= ratio * samples became >. Existing tests only use a window of 100 percent failures. Survives Sync 351, Kit 85, Compat 71. Model and Storage targets cannot reach this code. Candidate: .build-orchestrator/s3-probes/mut-network/M-N-16-candidate-test.swift. It passes on s3-base and fails on this mutant.

```diff
--- a/Sources/ZTronAssetSync/Engine/EngineSupport.swift
+++ b/Sources/ZTronAssetSync/Engine/EngineSupport.swift
@@ -480,7 +480,7 @@ package struct CircuitBreaker: Sendable, Hashable {
             self.appendWindow(true)
             let errors = self.serverWindow.filter { $0 }.count
             let samples = self.serverWindow.count
-            if samples >= max(1, self.policy.serverMinimumSamples), Double(errors) >= self.policy.serverErrorRatio * Double(samples) {
+            if samples >= max(1, self.policy.serverMinimumSamples), Double(errors) > self.policy.serverErrorRatio * Double(samples) {
                 self.open(.serverErrors, trips: self.carriedTrips + 1, at: now, seed: seed)
             }
         case .neutral, .abandoned:
```

**M-N-17 · Object success no longer clears the auth suspects.** Record: `Sources/ZTronAssetSync/Engine/EngineSupport.swift:~455` · R-SYN-5 (403s need to be without a success in between) · KILLED. The authSuspects.removeAll() line was deleted from the objectSuccess branch.

```diff
--- a/Sources/ZTronAssetSync/Engine/EngineSupport.swift
+++ b/Sources/ZTronAssetSync/Engine/EngineSupport.swift
@@ -461,7 +461,6 @@ package struct CircuitBreaker: Sendable, Hashable {
     private mutating func recordClosed(_ outcome: Outcome, at now: MonotonicInstant, seed: UInt64) {
         switch outcome {
         case .objectSuccess:
-            self.authSuspects.removeAll()
             self.appendWindow(false)
             self.successesSinceClose += 1
             self.resetCarriedTripsIfDue()
```

**M-N-18 · Probe failure re-opens without incrementing trips.** Record: `Sources/ZTronAssetSync/Engine/EngineSupport.swift:~371` · R-SYN-5 (doubled cooldown per trip) · KILLED. open(cause, trips: trips) instead of trips + 1. 2 issues.

```diff
--- a/Sources/ZTronAssetSync/Engine/EngineSupport.swift
+++ b/Sources/ZTronAssetSync/Engine/EngineSupport.swift
@@ -377,7 +377,7 @@ package struct CircuitBreaker: Sendable, Hashable {
                 self.successesSinceClose = 1
                 self.resetCarriedTripsIfDue()
             case .failure(_, let failureCause, _) where failureCause == cause:
-                self.open(cause, trips: trips + 1, at: now, seed: seed)
+                self.open(cause, trips: trips, at: now, seed: seed)
             case .failure, .neutral, .abandoned:
                 self.state = .halfOpen(cause: cause, trips: trips, probe: nil, watchdog: nil)
             }
```

**M-N-19 · Open breaker admits a probe one tick late (>= becomes >).** Record: `Sources/ZTronAssetSync/Engine/EngineSupport.swift:~420` · R-SYN-5 / R-SYN-6 (probe at the cooldown's end) · KILLED. My 300 s watchdog fired because some tests hung; the failing tests above were already recorded.

```diff
--- a/Sources/ZTronAssetSync/Engine/EngineSupport.swift
+++ b/Sources/ZTronAssetSync/Engine/EngineSupport.swift
@@ -417,7 +417,7 @@ package struct CircuitBreaker: Sendable, Hashable {
         case .closed:
             return .allow
         case .open(let cause, let until, _):
-            return now >= until ? .probe : .reject(cause, until: until)
+            return now > until ? .probe : .reject(cause, until: until)
         case .halfOpen(let cause, _, let probe, let watchdog):
             if let probe, probe != transfer, let watchdog, now < watchdog {
                 return .reject(cause, until: watchdog)
```

**M-N-20 · Retry-After exactly equal to maxRetryAfter is deferred (> becomes >=).** Record: `Sources/ZTronAssetSync/Engine/EngineSupport.swift:208` · R-SYN-5 (a Retry-After above maxRetryAfter defers to the next run) · SURVIVED at discovery (§4). The existing test checks only the value one above the limit. Survives Sync 351, Kit 85, Compat 71. Model and Storage targets cannot reach this code. Candidate: .build-orchestrator/s3-probes/mut-network/M-N-20-candidate-test.swift. It passes on s3-base and fails on this mutant.

```diff
--- a/Sources/ZTronAssetSync/Engine/EngineSupport.swift
+++ b/Sources/ZTronAssetSync/Engine/EngineSupport.swift
@@ -205,7 +205,7 @@ package enum Backoff {
         seed: UInt64,
         key: UInt64
     ) -> TimeInterval? {
-        if let retryAfter, retryAfter > policy.maxRetryAfter {
+        if let retryAfter, retryAfter >= policy.maxRetryAfter {
             return nil
         }
         let exponent = Double(max(attempt, 1) - 1)
```

**M-N-39 · A later 429 with a shorter Retry-After shortens the origin throttle.** Record: `Sources/ZTronAssetSync/Engine/EngineFailures.swift:317` · R-SYN-5 / ARCHITECTURE section 7.6 (origin-wide throttle until the clamped deadline; a later 429 only extends it) · SURVIVED at discovery (§4). `end = max(previous ?? .zero, until)` became `end = until`. Existing tests cover a shorter manifest 429 (EngineRegressionCycle15Tests) and an extending transfer 429 (Cycle16/17), but not a shorter transfer 429. Survives Sync 351, Kit 85, Compat 71. Model and Storage targets cannot reach this code. Candidate: .build-orchestrator/s3-probes/mut-network/M-N-39-candidate-test.swift. It passes on s3-base and fails on this mutant (it relies on p's 429 being handled first, which is the order the fake source and queue produce).

```diff
--- a/Sources/ZTronAssetSync/Engine/EngineFailures.swift
+++ b/Sources/ZTronAssetSync/Engine/EngineFailures.swift
@@ -311,7 +311,7 @@ extension SyncEngine {
         }
         let until = self.environment.time.monotonicNow().adding(seconds: max(delay, seconds ?? 0))
         let previous = self.state.throttles[origin]
-        let end = max(previous ?? .zero, until)
+        let end = until
         self.state.throttles[origin] = end
         self.state.metrics.retries[.throttled] += 1
         self.state.jobs[transfer]?.active = nil
```

**M-N-40 · Per-run attempt cap off by one.** Record: `Sources/ZTronAssetSync/Engine/EngineFailures.swift:278` · R-SYN-5 (cap attempts per asset) · KILLED. attempts >= maxAttemptsPerRun became >.

```diff
--- a/Sources/ZTronAssetSync/Engine/EngineFailures.swift
+++ b/Sources/ZTronAssetSync/Engine/EngineFailures.swift
@@ -279,7 +279,7 @@ extension SyncEngine {
                 continue
             }
             let policy = interest.lane == .userInitiated ? self.tuning.interactiveRetry : self.tuning.retry
-            if attempts >= max(1, policy.maxAttemptsPerRun) {
+            if attempts > max(1, policy.maxAttemptsPerRun) {
                 self.deliver(.failed(assetError), to: token, interest: interest, transfer: transfer)
                 self.state.jobs[transfer]?.interests[token] = nil
             }
```

#### ZTronAssetTransport (12)

**M-N-03 · Keep the app key on a cross-host redirect (mandatory).** Record: `Sources/ZTronAssetTransport/Policy/TransportSecurity.swift:134` · R-NET-4 (key never leaves the original origin), R-SEC-1 · KILLED. keepKey changed to keyStillPresent && previous == original, so the hop to a foreign host keeps the key. Caught by both the pure-policy and the loopback tests.

```diff
--- a/Sources/ZTronAssetTransport/Policy/TransportSecurity.swift
+++ b/Sources/ZTronAssetTransport/Policy/TransportSecurity.swift
@@ -134,6 +134,6 @@ public enum RedirectPolicy {
             return .refuse(violation == .insecureScheme ? .insecureScheme : .hostNotAllowed)
         }
         // Monotone: once a hop left the original origin the key is gone for good, even back at the origin.
-        return .follow(keepKey: keyStillPresent && previous == original && proposed == original)
+        return .follow(keepKey: keyStillPresent && previous == original)
     }
 }
```

**M-N-04 · Classify HTTP 403 as transient (mandatory).** Record: `Sources/ZTronAssetTransport/Classify/TransferClassifier.swift:73` · R-NET-6 (403 is forbiddenAmbiguous, never retried blindly) · KILLED. 403 returns .transient(.serverError(403)). 18 issues across 5 tests.

```diff
--- a/Sources/ZTronAssetTransport/Classify/TransferClassifier.swift
+++ b/Sources/ZTronAssetTransport/Classify/TransferClassifier.swift
@@ -81,7 +81,8 @@ public enum TransferClassifier {
                 keyPresented: facts.keyPresented,
                 resumed: resumed
             )
-            return .authentication(.forbiddenAmbiguous(evidence))
+            _ = evidence
+            return .transient(.serverError(httpStatus: status), retryAfter: facts.retryAfter)
         case 404, 410:
             return .permanentMissing(httpStatus: status)
         case 408:
```

**M-N-07 · Off-by-one in the transfer size cap.** Record: `Sources/ZTronAssetTransport/Policy/PriorityAndSize.swift:42` · R-NET-7 (a transfer exactly at the cap is allowed) · KILLED. written > limit changed to written >= limit.

```diff
--- a/Sources/ZTronAssetTransport/Policy/PriorityAndSize.swift
+++ b/Sources/ZTronAssetTransport/Policy/PriorityAndSize.swift
@@ -39,7 +39,7 @@ public enum SizeVerdict: Sendable, Hashable {
 public enum SizeGuard {
     /// The verdict for the bytes seen so far.
     public static func verdict(written: Int64, announced: Int64?, expected: Int64?, limit: Int64) -> SizeVerdict {
-        if written > limit {
+        if written >= limit {
             return .abortOversize
         }
         if let announced, announced >= 0, announced > Saturating.add(limit, limit / 1_024 + 64) {
```

**M-N-21 · Resume Range offset off by one.** Record: `Sources/ZTronAssetTransport/Policy/RequestFactory.swift:44` · R-NET-8 (Range from the partial's size) · KILLED. bytes=offset+1- sent.

```diff
--- a/Sources/ZTronAssetTransport/Policy/RequestFactory.swift
+++ b/Sources/ZTronAssetTransport/Policy/RequestFactory.swift
@@ -36,7 +36,7 @@ struct RequestFactory: Sendable {
         if let resume = job.resume {
             // Our own partial continues with Range + If-Range (ADR-019); the validator came from our sidecar, the
             // key from the current configuration, so a resumed request never carries a stale key (TR1-5).
-            request.setValue("bytes=\(resume.offset)-", forHTTPHeaderField: "Range")
+            request.setValue("bytes=\(resume.offset + 1)-", forHTTPHeaderField: "Range")
             switch resume.validator {
             case .strongETag(let tag):
                 request.setValue(tag.rawValue, forHTTPHeaderField: "If-Range")
```

**M-N-22 · Weak ETag accepted as the resume validator.** Record: `Sources/ZTronAssetTransport/Session/HTTPResponseReading.swift:63` · R-NET-8 / RFC 9110 (If-Range needs a strong validator) · SURVIVED at discovery (§4). The !tag.rawValue.hasPrefix("W/") check was removed, so resumeValidator returns .strongETag(W/...) and skips the Last-Modified fallback. A resumed request would then send a weak If-Range, which servers ignore, so the whole file is refetched. No test anywhere uses a weak ETag on the transport side. Survives Transport 151, Sync 351, Kit 85, Compat 71, Apple 104. Candidate: .build-orchestrator/s3-probes/mut-network/M-N-22-candidate-test.swift. It passes on s3-base and fails on this mutant.

```diff
--- a/Sources/ZTronAssetTransport/Session/HTTPResponseReading.swift
+++ b/Sources/ZTronAssetTransport/Session/HTTPResponseReading.swift
@@ -60,7 +60,7 @@ enum HTTPResponseReading {
     /// The `If-Range` validator a later attempt may send (RFC 9110 §13.1.5): a strong `ETag`, else `Last-Modified`.
     /// A weak tag is never a valid `If-Range`.
     static func resumeValidator(of response: HTTPURLResponse) -> ResumeValidator? {
-        if let tag = response.value(forHTTPHeaderField: "ETag").flatMap(ETag.init(rawValue:)), !tag.rawValue.hasPrefix("W/") {
+        if let tag = response.value(forHTTPHeaderField: "ETag").flatMap(ETag.init(rawValue:)) {
             return .strongETag(tag)
         }
         if let date = response.value(forHTTPHeaderField: "Last-Modified"), ETag(rawValue: date) != nil {
```

**M-N-23 · Redirect hop limit off by one.** Record: `Sources/ZTronAssetTransport/Policy/TransportSecurity.swift:~121` · R-NET-4 (at most 5 redirects) · KILLED. hop <= maxRedirects became hop <.

```diff
--- a/Sources/ZTronAssetTransport/Policy/TransportSecurity.swift
+++ b/Sources/ZTronAssetTransport/Policy/TransportSecurity.swift
@@ -123,7 +123,7 @@ public enum RedirectPolicy {
         keyStillPresent: Bool,
         policy: TransportSecurityPolicy
     ) -> Decision {
-        guard hop <= policy.maxRedirects else {
+        guard hop < policy.maxRedirects else {
             return .refuse(.tooManyRedirects)
         }
         guard let proposed else {
```

**M-N-24 · HTTP 410 no longer permanent-missing.** Record: `Sources/ZTronAssetTransport/Classify/TransferClassifier.swift:75` · R-NET-6 (404/410 permanent-missing) · KILLED. case 404, 410 became case 404.

```diff
--- a/Sources/ZTronAssetTransport/Classify/TransferClassifier.swift
+++ b/Sources/ZTronAssetTransport/Classify/TransferClassifier.swift
@@ -82,7 +82,7 @@ public enum TransferClassifier {
                 resumed: resumed
             )
             return .authentication(.forbiddenAmbiguous(evidence))
-        case 404, 410:
+        case 404:
             return .permanentMissing(httpStatus: status)
         case 408:
             return .transient(.timedOut, retryAfter: facts.retryAfter)
```

**M-N-25 · Plain HTTP allowed to any allow-listed host under loopbackOnly.** Record: `Sources/ZTronAssetTransport/Policy/TransportSecurity.swift:95` · R-NET-4 / R-SEC (HTTPS only; plaintext for loopback hosts only) · KILLED. Only one test catches it, via the redirect policy. There is no direct test of TransportSecurityPolicy.check for a non-loopback http origin, but the one test is enough to kill it.

```diff
--- a/Sources/ZTronAssetTransport/Policy/TransportSecurity.swift
+++ b/Sources/ZTronAssetTransport/Policy/TransportSecurity.swift
@@ -92,7 +92,7 @@ public struct TransportSecurityPolicy: Sendable, Hashable {
         }
         if origin.scheme != "https" {
             let loopback = origin.host == "127.0.0.1" || origin.host == "::1" || origin.host == "localhost"
-            guard self.plaintext == .loopbackOnly, loopback else {
+            guard self.plaintext == .loopbackOnly else {
                 return .insecureScheme
             }
         }
```

**M-N-26 · 304 accepted without a conditional request.** Record: `Sources/ZTronAssetTransport/Classify/TransferClassifier.swift:57` · R-NET-5 · KILLED. sentConditional ? nil : rejected became always nil.

```diff
--- a/Sources/ZTronAssetTransport/Classify/TransferClassifier.swift
+++ b/Sources/ZTronAssetTransport/Classify/TransferClassifier.swift
@@ -63,7 +63,7 @@ public enum TransferClassifier {
             }
             return facts.contentRangeStart == nil ? .transient(.resumeRejected, retryAfter: nil) : nil
         case 304:
-            return sentConditional ? nil : .rejected(.unexpectedNotModified)
+            return nil
         case 300...399:
             // A redirect delivered as the final response was refused or had no usable `Location`; the delegate
             // recomputes the precise refusal when it can (transport.md §5.2).
```

**M-N-27 · RemoteURL.make accepts a '..' component.** Record: `Sources/ZTronAssetTransport/Policy/RequestFactory.swift:~73` · R-NET-4 / TR1-10 (defence in depth for paths reaching the transport) · KILLED. Failed for '../secret' and 'a/%2e%2e/b'. 8 issues.

```diff
--- a/Sources/ZTronAssetTransport/Policy/RequestFactory.swift
+++ b/Sources/ZTronAssetTransport/Policy/RequestFactory.swift
@@ -70,7 +70,7 @@ enum RemoteURL {
         for component in path.split(separator: "/", omittingEmptySubsequences: false) {
             let text = String(component)
             let decoded = text.removingPercentEncoding ?? text
-            guard !text.isEmpty, decoded != ".", decoded != "..",
+            guard !text.isEmpty, decoded != ".",
                 !text.contains("?"), !text.contains("#"), !text.contains("\\")
             else {
                 return nil
```

**M-N-28 · 206 without Content-Range accepted.** Record: `Sources/ZTronAssetTransport/Classify/TransferClassifier.swift:62` · R-NET-6 / ARCHITECTURE section 6.3 · KILLED. Caught by the 206/resumed=true table row only.

```diff
--- a/Sources/ZTronAssetTransport/Classify/TransferClassifier.swift
+++ b/Sources/ZTronAssetTransport/Classify/TransferClassifier.swift
@@ -61,7 +61,7 @@ public enum TransferClassifier {
             guard resumed else {
                 return .rejected(.unexpectedStatus(status))
             }
-            return facts.contentRangeStart == nil ? .transient(.resumeRejected, retryAfter: nil) : nil
+            return nil
         case 304:
             return sentConditional ? nil : .rejected(.unexpectedNotModified)
         case 300...399:
```

**M-N-34 · Swallow ENOSPC in the URL-error classifier.** Record: `Sources/ZTronAssetTransport/Classify/TransferClassifier.swift:~151` · R-NET-6 / R-SYN-11 · KILLED. ENOSPC under -3000...-3005 now becomes transient localIO.

```diff
--- a/Sources/ZTronAssetTransport/Classify/TransferClassifier.swift
+++ b/Sources/ZTronAssetTransport/Classify/TransferClassifier.swift
@@ -151,9 +151,7 @@ public enum TransferClassifier {
         case -1206 ... -1200:
             return .transient(.secureConnectionFailed(urlErrorCode: urlErrorCode), retryAfter: nil)
         case -3005 ... -3000:
-            if underlyingPOSIXCode == ENOSPC {
-                return .insufficientSpace(requiredBytes: nil)
-            }
+
             return .transient(.localIO(posixCode: underlyingPOSIXCode ?? 0), retryAfter: nil)
         case -997 ... -995:
             return .transient(.backgroundSessionUnavailable(urlErrorCode: urlErrorCode), retryAfter: nil)
```

#### ZTronAssetModel (2)

**M-N-06 · Accept a '..' manifest path segment.** Record: `Sources/ZTronAssetModel/Manifest/Decoding/ManifestRules.swift:~296` · R-MAN-2 (no parent segments in remotePath) · KILLED. isParentSegment length guard changed from >= 2 to >= 3, so a literal '..' passes while '%2e%2e' is still caught. 19 issues.

```diff
--- a/Sources/ZTronAssetModel/Manifest/Decoding/ManifestRules.swift
+++ b/Sources/ZTronAssetModel/Manifest/Decoding/ManifestRules.swift
@@ -298,7 +298,7 @@ enum ManifestRules {
     /// Whether `utf8[start..<end]` is `..`, also spelled with percent-encoded dots (`%2e`, `%2E`).
     private static func isParentSegment(_ utf8: UnsafeRawBufferPointer, from start: Int, to end: Int) -> Bool {
         // `..` is 2 bytes; with both dots encoded it is 6.
-        guard end - start >= 2, end - start <= 6 else {
+        guard end - start >= 3, end - start <= 6 else {
             return false
         }
         var dots = 0
```

**M-N-29 · Metadata-only change classified as unchanged.** Record: `Sources/ZTronAssetModel/Manifest/ManifestDiff.swift:~96` · R-MAN-4 · KILLED. 6,635 issues.

```diff
--- a/Sources/ZTronAssetModel/Manifest/ManifestDiff.swift
+++ b/Sources/ZTronAssetModel/Manifest/ManifestDiff.swift
@@ -89,7 +89,7 @@ public struct ManifestDiff: Sendable, Hashable {
         if old.contentIdentity != new.contentIdentity {
             return .contentChanged
         }
-        return old == new ? .unchanged : .metadataChanged
+        return .unchanged
     }
 
     /// The entries of the newer manifest, rebuilt from `old` plus this diff in O(n); `nil` when the diff does not
```

#### ZTronAssetAppleHosted (2)

**M-N-10 · Release an Apple pack twice in one catalog generation.** Record: `Sources/ZTronAssetAppleHosted/AppleSourceState.swift:241` · R-CLN-10 / ADR-027 (at most one release per pack per catalog generation) · KILLED. The subtracting(self.released) set was dropped from the release plan. 38 issues.

```diff
--- a/Sources/ZTronAssetAppleHosted/AppleSourceState.swift
+++ b/Sources/ZTronAssetAppleHosted/AppleSourceState.swift
@@ -238,7 +238,7 @@ actor AppleSourceState {
     func planRelease(_ survey: ReleaseSurvey) -> ReleasePlan {
         self.adoptedPacks = survey.adopted
         self.settledPacks = survey.settled
-        let packs = survey.settled.subtracting(self.released).subtracting(self.releasing).sorted()
+        let packs = survey.settled.subtracting(self.releasing).sorted()
         self.releasing.formUnion(packs)
         return ReleasePlan(packs: packs, generation: self.generation)
     }
```

**M-N-31 · Swallow POSIX ENOSPC from an Apple pack error.** Record: `Sources/ZTronAssetAppleHosted/PackErrorMapping.swift:~93` · R-NET-6 / R-SYN-11 (out of space is insufficientSpace) · KILLED. The NSPOSIXErrorDomain/ENOSPC branch was removed; the Cocoa branch remained.

```diff
--- a/Sources/ZTronAssetAppleHosted/PackErrorMapping.swift
+++ b/Sources/ZTronAssetAppleHosted/PackErrorMapping.swift
@@ -74,7 +74,7 @@ enum PackErrorMapping {
     /// `transient(.unknown)`. A code of another domain is not a URL error code, so it is reported as 0 (the source
     /// logs the domain and code). Which errors BackgroundAssets throws is UNVERIFIED (APPLE-API-VERIFICATION §1.8).
     static func systemError(domain: String, code: Int) -> TransferError {
-        if (domain == NSPOSIXErrorDomain && code == Int(ENOSPC)) || (domain == NSCocoaErrorDomain && code == NSFileWriteOutOfSpaceError) {
+        if domain == NSCocoaErrorDomain && code == NSFileWriteOutOfSpaceError {
             return .insufficientSpace(requiredBytes: nil)
         }
         guard domain == NSURLErrorDomain else {
```

#### ZTronAssetKit (5)

**M-N-11 · File-system work in lookup on the main thread.** Record: `Sources/ZTronAssetKit/Facade/AssetClient.swift:191` · R-STO-7 / R-CAR-1 (lookup does zero file-system calls) · KILLED. lookup calls the injected environment.fileSystem.itemInfo on the hit. Caught because the harness counts calls through the injected seam. A direct FileManager call would not be seen (design limit, not a survivor).

```diff
--- a/Sources/ZTronAssetKit/Facade/AssetClient.swift
+++ b/Sources/ZTronAssetKit/Facade/AssetClient.swift
@@ -189,7 +189,11 @@ public final class AssetClient: Sendable {
     /// filters case-insensitively; empty means any. `nil` after shutdown.
     @MainActor
     public func lookup(_ id: AssetID, extensions: [String] = []) -> AssetLocation? {
-        self.mirror.lookup(id, extensions: extensions)
+        let found = self.mirror.lookup(id, extensions: extensions)
+        if let found {
+            _ = try? self.environment.fileSystem.itemInfo(at: found.url)
+        }
+        return found
     }
 
     /// The network step: single-flight, at `priority`, fetch-first for unknown ids (R-CAR-1, R-SYN-4). The
```

**M-N-35 · PrefetchHandle deinit no longer releases its group.** Record: `Sources/ZTronAssetKit/Prefetch/Prefetch.swift:~25` · R-CAR-4 · KILLED. Caught by a failed expectation (KitContractTests.swift:253) plus a 60 s time limit.

```diff
--- a/Sources/ZTronAssetKit/Prefetch/Prefetch.swift
+++ b/Sources/ZTronAssetKit/Prefetch/Prefetch.swift
@@ -37,9 +37,7 @@ public final class PrefetchHandle: Sendable {
         }
     }
 
-    deinit {
-        PrefetchHandle.release(self.registration, from: self.registry)
-    }
+
 
     /// Suspends until the engine registered this handle's interest. Throws `.shutDown` when the client was shut
     /// down first (R-SYN-15); the handle then holds nothing and `cancel()` is a no-op.
```

**M-N-36 · Prefetch window radius off by one.** Record: `Sources/ZTronAssetKit/Prefetch/Prefetch.swift:~95` · R-CAR-3 · KILLED. while distance <= reach became <; also fails the Facade contracts window test (5 issues).

```diff
--- a/Sources/ZTronAssetKit/Prefetch/Prefetch.swift
+++ b/Sources/ZTronAssetKit/Prefetch/Prefetch.swift
@@ -93,7 +93,7 @@ public enum PrefetchWindow {
         var seen: Set<AssetID> = [ids[current]]
         let reach = max(radius, 0)
         var distance = 1
-        while distance <= reach {
+        while distance < reach {
             for index in [current + distance, current - distance] where ids.indices.contains(index) {
                 let id = ids[index]
                 if seen.insert(id).inserted {
```

**M-N-37 · Prefetch window order (backward before forward).** Record: `Sources/ZTronAssetKit/Prefetch/Prefetch.swift:~97` · R-CAR-3 · KILLED. Within each distance the neighbours are visited behind first.

```diff
--- a/Sources/ZTronAssetKit/Prefetch/Prefetch.swift
+++ b/Sources/ZTronAssetKit/Prefetch/Prefetch.swift
@@ -94,7 +94,7 @@ public enum PrefetchWindow {
         let reach = max(radius, 0)
         var distance = 1
         while distance <= reach {
-            for index in [current + distance, current - distance] where ids.indices.contains(index) {
+            for index in [current - distance, current + distance] where ids.indices.contains(index) {
                 let id = ids[index]
                 if seen.insert(id).inserted {
                     result.append(PrefetchTarget(id: id, priority: .prefetch, distance: distance))
```

**M-N-38 · Facade window ignores a priority promotion of an existing handle.** Record: `Sources/ZTronAssetKit/Prefetch/Prefetch.swift:~125` · R-CAR-3 (a neighbour that becomes current is promoted) · KILLED. existing.priority == target.priority became <=, so promotions are skipped. Both tests fail as expectation failures plus 60 s time limits.

```diff
--- a/Sources/ZTronAssetKit/Prefetch/Prefetch.swift
+++ b/Sources/ZTronAssetKit/Prefetch/Prefetch.swift
@@ -134,7 +134,7 @@ public final class PrefetchWindowController {
         var next: [AssetID: (handle: PrefetchHandle, priority: AssetPriority)] = [:]
         for target in targets {
             if let existing = self.handles[target.id] {
-                if existing.priority == target.priority {
+                if existing.priority <= target.priority {
                     next[target.id] = existing
                 } else {
                     let replacement = self.client.prefetch([target.id], priority: target.priority)
```

### The re-check's re-made M-N-39 (`e840b0e`)

`.build-orchestrator/s3-post-merge/mut-recheck/M-N-39.reapplied.diff` (§2.3):

```diff
--- a/Sources/ZTronAssetSync/Engine/EngineFailures.swift
+++ b/Sources/ZTronAssetSync/Engine/EngineFailures.swift
@@ -371,7 +371,7 @@
         }
         let until = now.adding(seconds: max(delay, seconds ?? 0))
         let previous = self.state.throttles[origin]
-        let end = max(previous ?? .zero, until)
+        let end = until
         self.state.throttles[origin] = end
         self.state.metrics.retries[.throttled] += 1
         self.state.jobs[transfer]?.active = nil
```
