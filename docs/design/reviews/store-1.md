# Adversarial review #1 — `docs/design/store.md`

**Lens.** Crash consistency and durability: every file-system operation boundary, fsync/rename ordering, torn or partial writes, index corruption and rebuild, ENOSPC/EIO mid-commit, the P-5 window (published but not yet indexed), the advisory lock and a second opener.
**Reviewer.** review-store-1. I did not write the design.
**Read.** `CLAUDE.md`; SPEC §1.4, §4.2–§4.4, §5.2, §5.3, §5.7, R-SEC-2, §6 (P-2, P-5, P-6, P-13), §7.3; `docs/RECON.md`, `docs/DECISIONS.md`, `docs/BASELINE.md`; all of `store.md`; `sync.md` §3.2, §4.4 and §17.1 as cross-checks; the drafter's probes `.build-probe-store/{crash,lock}`.
**Evidence.** My probes are in `.build-probe-review-store-1/` (git-ignored): `crash2/` (a two-lifetime crash model), `lock/` and `misc/`. Commands and verbatim output are in §4. Every claim below that depends on Swift, POSIX or the model was run in this session. Anything marked *(hint)* was not.
**Notation.** PK = process kill, PL = power loss, as in `store.md` §2.4. *Volatile* means applied to the namespace or page cache but not yet synced. `store.md:NNN` is a line in the design.

---

## 1. Summary

| ID | Sev | Finding | Violates |
|---|---|---|---|
| S1-01 | critical | After a PK, `open()` trusts a namespace the dead process never synced. Adoption, fan-out "first creation" and launch deletions then build durable state on volatile entries. | I-2, H-1, H-10, R-STO-5 (the test cannot see it) |
| S1-02 | critical | The root's own entry in `<base>` is never synced, so a PL can remove the whole store, even after a "durable" commit and after migration deleted the legacy data | R-STO-4, R-STO-11, H-10, I-5 |
| S1-03 | critical | DOOMED is pruned before the unlink is durable. After a PL, 7c re-adopts the resurrected blob for a purged or quarantined record (corrupt bytes served as verified; purge undone) | R-CLN-6, R-CLN-8, R-INT-2, I-1 |
| S1-04 | critical (very unlikely) | `nextGen = 1 + max(parsed generation)` traps on a parsed but corrupt header, causing a crash at every launch | §2.3 "never traps", R-STO-4, R-STO-12 |
| S1-05 | major | P-5 recovery covers only "a new, unreferenced blob". Dedupe, rescue, checksum-less publishes and a retried `apply` re-download after a kill, and identical bytes under a new id are fetched again | §9.1 convergence rule, D3, promise 2, R-SYN-8, R-INT-5 |
| S1-06 | major | A blob name with wrong bytes is reused forever: 7b leaves it in place, and publish dedupes or rescues onto it, discarding the verified download | R-CLN-7, R-CLN-8, R-INT-2/3, I-1 |
| S1-07 | major | ENOSPC livelock: every way to free space needs a commit first, so on a disk filled by another app nothing is ever freed. `open()` failing at step 8 hides every resident asset | R-SYN-11, R-CLN-6, promise 1/3 |
| S1-08 | major | The lock checks existence, not identity, so a replaced root admits a second writer. A failed `open()` leaks the lock. Step 1 mutates before locking | R-STO-9 |
| S1-09 | major | `close()` releases the lock while unit continuations can still mutate and schedule a commit, so a same-process reopen gets two writers | R-STO-9, R-SYN-15, I-5 |
| S1-10 | major | The Apple-pack duplicate may be released "after publish returns", which is before the blob is durable | R-CLN-10, H-7, promise 1 |
| S1-11 | major | Degraded fallback still deletes the older generation's DOOMED keys, including ones the newer (corrupt or newer-schema) generation re-referenced | R-STO-4 |
| S1-12 | major | Hash-then-rename TOCTOU: bytes appended after hashing are published under the verified name | I-1, R-STO-3 |
| S1-13 | major | The reaper "sleeps until the earliest eligibleAt" even when the key is blocked by a lease, a missing ack or a lagging commit, so it spins or lingers | R-SYN-14, P-14, promise 4 |
| S1-14 | minor | Ordered commits `F_FULLFSYNC` the temp file at 4/s (the flush Alternative D rejected for blobs). The "PL only before return" wording and the I-5 checker are model-only | P-5 margin, energy, clarity |
| S1-15 | minor | The `fsync` fallback in `syncOutcome` can mask EIO as a successful barrier | R-STO-6, I-1/I-2 |
| S1-16 | minor | The point at which `droppedInGeneration` is allocated is unspecified; an off-by-one lets the reaper unlink a still-referenced blob | I-3, I-2 |
| S1-17 | minor | Launch staging GC deletes an unpaired `.resume` (background transfer) and keeps unbudgeted `.part` files across crash loops | H-6, R-CLN-3, promise 3 |
| S1-18 | minor | Migration: symlinked intermediate legacy directories are followed; EEXIST in phase 2 is unspecified; "before the first snapshot" contradicts "publish every 64"; the EXDEV copy is never hashed | R-SEC-2, R-STO-11, I-1 |

A caveat on S1-01 to S1-03. APFS likely commits metadata in transaction order, so a later sync probably persists earlier renames and unlinks too *(hint, unverified)*. Those three holes therefore appear under the design's own per-directory model (§3.4, store.md:397) and on volumes without that ordering, such as `.custom` roots. They are still design defects, for two reasons. The design adopts that model as its proof and as the R-STO-5 oracle. And the fixes are cheap: a handful of barriers, or an adoption rule.

---

## 2. Findings

### S1-01 · critical · `open()` builds durable state on a namespace the killed process never synced

**Violates.** I-2 (and the design's stronger claim of "zero `needsHeal` when no blob was externally removed", store.md:253, :948), H-1, H-10. The R-STO-5 test design cannot detect it.

**Root cause.** A process kill preserves the page cache, so the next process sees renames, `mkdir`s and unlinks that are not on media. `open()` treats what it lists as durable in three places.

**Timeline (a): adoption without a fan-out sync** (probe scenario A).
1. Lifetime 1: `apply(M)` commits gen 1 (A absent, `expectedBlob = h`).
2. `publish(A)`: write `.part` → barrier → `createDirectory(blobs/aa)` → `rename(.part → blobs/aa/h, .exclusive)`, then returns. The commit is coalesced (P-5 window), so neither `blobs/` nor `blobs/aa` has been synced.
3. PK. The kernel survives: `blobs/aa/h` is in the namespace but not on media.
4. Lifetime 2 `open()`: step 4 lists `aa/h`, step 7c adopts A → `present(h)`, and step 8 commits gen 2 (ordered). That commit's step 1 syncs only `dirtyDirectories`, which is empty in this process: adoption is not "a fan-out that received a blob since the last commit" (store.md:169). Gen 2's root rename is barrier-synced, and the snapshot says A is present.
5. PL. `blobs/` reverts to its last synced listing (no `aa`); root keeps gen 2.
6. Lifetime 3: gen 2 says `present(h)`, h is gone, so `needsHeal` and a re-download. Probe: **1 of 173** two-lifetime cases.

**Timeline (b): "first creation" is decided from the volatile namespace** (store.md:189).
Lifetime 1 runs `createDirectory(blobs/aa)` and is killed before the rename. Lifetime 2 publishes B into the existing but volatile `aa`. It sees no creation, so `blobs/` is never marked dirty. Gen 2 references `aa/h2`; after a PL, `aa` vanishes from `blobs/`. Probe: **1 of 564**.

**Timeline (c): launch deletions before the root is durable** (store.md:240, :242).
1. Lifetime 1 commits gen N+1 (DOOMED h) and is killed after `rename(tmp → bin)` but before `synchronizeDirectory(root)`.
2. Lifetime 2: chosen = `index.bin` (N+1) and nothing changed, so step 8 does not commit. Step 10 unlinks h.
3. Lifetime 2 publishes into `aa` and commits. Step 1 syncs `aa`, which makes the unlink durable.
4. PL before that commit's step 6. Root reverts to gen N, which references h, and h is gone.

This needs §2.4.3's directory syncs to run only at the first open, as its title says (store.md:194). If they run at every open, the root barrier there closes the hole. Probe: **6 of 417** under the first-open reading, **0** otherwise. The design must say which reading it means.

**Timeline (d): migration resume** (store.md:864).
1. Lifetime 1, phase 2, renames L → `blobs/aa/h` and is killed before the coalesced commit.
2. Lifetime 2, phase 2: "k on disk → r present". The durable "done" commit runs with empty `dirtyDirectories`. Phase 4 removes the legacy tree and the `UserDefaults` key.
3. PL: `aa/h` is lost, while "done" is durable.
4. Next launch: r needs a heal, and the asset is re-downloaded (H-10). Any reverted legacy L is removed again by store.md:849.

**Why the plan misses it.** R-STO-5 enumerates one crash per run. The drafter's fake makes every survivor durable after a PK (`.build-probe-store/crash/main.swift`, `survivingDisk`: "make the survivor fully durable"), so no later PL can expose volatility. Probe: the drafter's model reports **0 of 173** (A) and **0 of 558** (B). The volatility-preserving model reports the cases above.

**Smallest fix.**
1. At `open()`, set `blobs/` dirty, which costs one barrier at the first commit after launch.
2. Every adoption (launch 7c, `apply`-time adoption, migration "k on disk") inserts that blob's fan-out into `dirtyDirectories`.
3. Make §2.4.3's `synchronizeDirectory(root, .barrier)` unconditional at every open, before step 10 (0.37 ms).
4. `FakeFileSystem.survivingDisk()` after `.processKill` keeps the current/durable split. R-STO-5 and the §9.3 oracle add "PK at k1 → reopen → PL at k2" sequences. That is about 170–600 cases per scenario on the inline fake.

For the degraded rebuild (F11), which can adopt across all 256 fan-outs, barrier-sync each fan-out inside its own step-4 listing unit (+0.37 ms per unit). Doing it in one commit (256 × 0.37 ≈ 95 ms) would exceed P-5's 40 ms for that commit. With fixes 1–3 the probe reports **0 of 175**, **0 of 585** and **0 of 426**.

### S1-02 · critical · The store root's entry in `<base>` is never synced

**Violates.** R-STO-4 (a durable flush that a PL undoes), R-STO-11, H-10, I-5 ("any committed prefix is a valid state").

**Timeline.**
1. First launch. `standardDirectory(.applicationSupport)` resolves `<base>` and may have to create it *(hint: iOS does not always pre-create `Application Support`)*. §2.4.3 creates `ZTronAssetKit`, `v1`, `blobs` and `staging`, then syncs `ZTronAssetKit` and `v1` (store.md:196). The entry named `ZTronAssetKit` lives in `<base>`, which nobody syncs.
2. Legacy migration finishes. Phase 3's durable "done" commit runs (`F_FULLFSYNC` on tmp and root). Phase 4 deletes `Caches/CDNAssets` and removes the `UserDefaults` key (store.md:873–875). Both steps are irrevocable.
3. PL. `<base>` reverts to its last synced listing, which has no `ZTronAssetKit`, so the whole root is unreachable.
4. Next launch: an empty store. The legacy files and the stamp are gone, every asset is re-downloaded, and every "durable" commit is lost.

**Evidence.** Probe C models `<base>` as a pre-existing durable directory. It reports **12 of 22** single-crash PL cases with "root VANISHED, recovered gen 0 < returned gen". With `<base>` synced at creation it reports **0 of 23**. This is the design's own R-STO-5 shape, so its enumeration would fail as soon as the fake models `<base>`. The drafter's probe rooted the store at `/v1` and synced `/`, so it could not see this.

**Smallest fix.** After creating `ZTronAssetKit`, barrier-sync its parent `<base>`, and do the same for every ancestor the layout or `standardDirectory` created. The durable commit that precedes an irrevocable step (migration "done", `close()`) also `.full`-syncs `ZTronAssetKit` and `<base>`. That is three calls, once.

### S1-03 · critical · A doomed blob resurrected by PL is re-adopted for purged or quarantined records

**Violates.** R-CLN-8 and R-INT-2 (known-bad bytes are served as `verified: true`), R-CLN-6 (a purge is silently undone), I-1 (7c relies on it without hashing). It also contradicts store.md:771 ("doomed always beats adoption").

**Timeline (quarantine).**
1. A is `present(h)` and committed. The bytes of h rot, or deep verification finds a mismatch. `reportUnreadable(A)` sets A to `quarantined` (`expectedBlob` stays h) and dooms h. An ordered commit writes gen N (DOOMED h).
2. After the acknowledgement and the 10 s grace, the reaper runs `removeItem(blobs/aa/h)`. No sync follows (store.md:200).
3. A lazy commit writes gen N+1 without h in DOOMED and barrier-syncs the root. `blobs/aa` is not synced, because no blob was *received*.
4. PL. Root keeps gen N+1; `blobs/aa` reverts, so h (rotten, same size) reappears.
5. Launch 7c: h is neither referenced nor doomed, `A.expectedBlob == h` and the size matches. 7c sets A to `present(h, verified: true)`, overwriting the quarantine and backoff, and the snapshot serves the rotten bytes.

**Purge variant.** Purged records keep `expectedBlob`, so the same PL undoes `purge(.all | .scope)`. The "bytes freed" result was false, and scope-purged content (for example after a lost entitlement) is back.

**Variant without a PL.** `removeItem` throws EIO for one key in a 64-key batch. The design removes the whole batch from `blobTable` and prunes DOOMED (store.md:580). The file stays and is re-adopted at the next launch.

**Why the plan misses it.** SPEC §7.3's crash scenarios do not include purge or quarantine. In the eviction scenario the same mechanism re-adopts an evicted record, which no invariant flags.

**Evidence.** Probe D: **1 of 68** each ("gen 4 has A quarantined; open() re-adopted aa1 (CORRUPT bytes marked present)", and the same for purged). With the fix: **0 of 68**.

**Smallest fix.** Launch 7c and `apply`-time adoption bind a blob only to records in `absent(.neverFetched | .evicted | .healing)`, `needsHeal` or stale `present`, never to `purged`, `quarantined` or `failed` records. A key whose unlink failed stays doomed and stays in DOOMED. This needs no extra syncs and leaves P-13 untouched.

### S1-04 · critical (very unlikely) · Header arithmetic traps

**Violates.** §2.3's "returns `IndexDecodeError` … and never traps", R-STO-4, and the claim of R-STO-12's fuzz test.

**Timeline.** `index.tmp` or `index.prev` has a valid magic and schema, but its generation bytes read as all ones. Possible sources: a future schema using a sentinel, a garbage file, or rot. At `open()` step 3, `nextGen = 1 + max(generation of every header that parsed, valid or not)` (store.md:176, :208) overflows. The arithmetic-overflow trap then crashes every launch until the app is reinstalled. `64 + bodyLength + 32` has the same failure if it is evaluated before the 64 MiB bound check.

**Evidence.** `misc overflow`: `parsed generation = 18446744073709551615`, then exit **133** (SIGTRAP).

**Smallest fix.** Use valid candidates for `nextGen`. Add parsed-only headers with `addingReportingOverflow`, and treat an overflow as `.malformed`. Check `bodyLength ≤ 64 MiB` before computing the expected size. R-STO-12's fuzz test should add structured headers: a valid magic with random generation and `bodyLength`.

### S1-05 · major · P-5 recovery covers only "a new, unreferenced blob"

**Violates.** The §9.1 convergence rule ("downloads after reopen = only assets whose publish had not returned", store.md:948), D3, promise 2 / R-SYN-8 (sync.md §4.4 counts an identical-bytes rename as a zero-download `Reuse`), R-INT-5.

7c adopts only `k ∈ onDisk \ (referenced ∪ doomed)` (store.md:230), and immediately deletes any other unreferenced blob when not degraded, with no `orphanGrace` (store.md:233). Every publish path that changes only in-memory reference counts is therefore lost on a kill.

- **E. Dedupe onto a live key.** A and B share checksum h, and A is present and committed. `publish(B)` hits a `live` key or EEXIST and removes the staged copy (store.md:583, :679). B is present in memory, and publish returns. On a kill, the committed B is `absent`, h is referenced by A so 7c skips it, and B is re-downloaded. Probe: "after reopen B is absent → RE-DOWNLOAD".
- **F. Rescue.** `apply(M′)` removes A (dooming h, committed in DOOMED) and adds B with the same bytes. `publish(B)` rescues h in memory only. On a kill, 7a deletes h ("never adopted", store.md:228) and B is re-downloaded. Probe: same result.
- **G. Checksum-less entry** (R-MAN-5; `allowUnverifiedAssets` defaults to true). `expectedBlob` is nil (store.md:447), so R4's question "does some record still expect k?" (store.md:623) is false.
  - Read literally, the just-published blob is doomed while the record becomes `present(k)`. After the commit, acknowledgement and grace, the reaper unlinks a referenced blob, and the asset re-downloads on every launch.
  - Read loosely, a kill before the coalesced commit leaves k unexpected, and 7c deletes it at launch.
- **H. A retried `apply`.**
  1. `apply(M)` mutates memory, its commit fails (ENOSPC or EIO) and it throws. Memory stays authoritative (store.md:177).
  2. The engine retries `apply(M)`. The diff is empty, so "no mutation and no commit" (store.md:801), and it returns.
  3. The engine fetches against a manifest that is not committed. A kill leaves an index with M0, whose `expectedBlob`s do not match the new blobs.
  4. 7c deletes them, and the assets are re-downloaded.
- **Promise 2.** §6.1 derefs removed entries *before* running adoption (store.md:724, :728), and adoption excludes doomed and referenced keys. An id rename with identical bytes therefore dooms the blob and fetches it again. The publish then rescues it and throws the download away.

**Smallest fix.**
1. 7c iterates **records**. An `absent`, `needsHeal` or stale record whose `expectedBlob` key is on disk is bound to it, whether the key is referenced or is DOOMED with reason `removed`. Purged, corrupt and quarantined dooms are excluded (S1-03, S1-06).
2. `apply` runs adoption *before* it derefs removed entries, and binds to `live` and `doomed` keys.
3. A checksum-less publish, and a rescue publish, call `requireCommitted(ordered)` before returning. Both are rare.
4. R4 compares the record's revision for checksum-less entries instead of `expectedBlob`.
5. `apply`'s short-circuit tests "the committed generation already records M's digest", not "the diff is empty".

Cross-design note: sync.md §3.2 expects `.interactive` publishes to "flush immediately", but this design coalesces every commit. Phase C must pick one rule.

### S1-06 · major · A blob name with wrong bytes is reused forever

**Violates.** R-CLN-7 ("heals"), R-CLN-8, R-INT-2/3 (the asset ends `failed(.integrity)` even though the server is correct), I-1. Promise 3 ("half-writing files is survivable").

**Timeline.**
1. Launch 7b finds `present(h)` but a 0-byte or short file. 7b only flags `needsHeal(h)` (store.md:229), and the file stays at `aa/h`.
2. The engine re-downloads A and publishes. If `blobTable[h]` is live, the staged duplicate is removed (store.md:583). If it is nil, `RENAME_EXCL` returns EEXIST and the `.part` is removed (store.md:679). Either way A becomes `present(h, verified)` over the short file.
3. The UI calls `reportUnreadable`. The quarantine backs off 60 s, then 600 s, then `failed(.integrity)` "until its manifest entry changes" (store.md:689). The same outcome follows a rescue of a quarantined key while a lease or a slow acknowledgement holds it past the 60 s quarantine.

Separately, when `byteSize` is nil (a checksum-only entry), 7c skips the size check and adopts a truncated orphan as verified (store.md:231).

**Smallest fix.**
1. Add a `corrupt` doom reason, persisted in DOOMED. A size mismatch at 7b dooms h as corrupt, and step 10 deletes it, which is safe because no URL was handed out in this process.
2. Adoption, dedupe and rescue never bind to a corrupt key.
3. A publish onto a corrupt key that is still on disk (for example leased) uses `rename(.replacing)` after the barrier, as a documented exception to "never replaces". Holders of open file descriptors keep the old inode.
4. The EEXIST branch compares `itemInfo` size with the verified size before it trusts the existing file.

### S1-07 · major · ENOSPC livelock: freeing space requires a commit, and a commit requires space

**Violates.** R-SYN-11 ("a shortage evicts"), R-CLN-6 ("returns bytes freed"), promise 3, promise 1 (launch variant), R-STO-9 (lock leak, see S1-08).

**Timeline.**
1. Another app fills the volume. `write(index.tmp)` fails with ENOSPC. `reserveFreeBytes` only guards the store's own downloads (store.md:712).
2. Eviction marks records `absent` and dooms blobs, then "commit" fails. The reaper is blocked by `committedGeneration ≥ droppedInGeneration` (store.md:578).
3. The user taps "Remove downloads". `purge(.all)` step 3 ("a committed generation") fails and throws, freeing 0 bytes.
4. §6.7 frees only blobs already doomed in a committed generation, plus unclaimed staging (store.md:784). Neither exists here. Each retry, 4 times a second, writes up to 1.43 MiB before failing.

**Launch variant.** Step 8's commit fails, and `open()`'s behaviour is unspecified. If it throws, step 9 never publishes a snapshot, so every resident asset is unavailable even offline, and the lock taken at step 2 leaks.

**Smallest fix.**
1. On ENOSPC at commit step 2: `removeItem(index.tmp)` and `removeItem(index.prev)`, then retry once. `prev` is only a corruption fallback, and freeing it reclaims about one index size, which is what the new tmp needs.
2. `open()` never fails because a commit failed after load. It publishes the snapshot from memory, enters `degradedReadOnly` and blocks deletions.
3. Add the test `R-CLN-6: purge on a full volume returns bytes freed` (the fake throws ENOSPC on every write until a blob is unlinked).

### S1-08 · major · The advisory lock can admit a second writer

**Violates.** R-STO-9.

**Timeline (a): root replacement** (store.md:605).
1. Store 1 holds `O_EXLOCK` on `v1/store.lock`.
2. The root is deleted. Possible causes: an app's "clear Caches" for `.caches`, a user on macOS, or a test teardown.
3. A second `AssetClient` recreates the root and `store.lock`. Its `open(O_EXLOCK|O_NONBLOCK)` **succeeds**, because the lock is on a new inode.
4. Store 1's pre-commit check, `itemInfo(store.lock) != nil`, **passes**. Both stores commit, unlink and collect orphans on one root. Each one's orphan GC deletes the other's blobs, and their tmp/bin renames interleave.

Probe: "second opener after root replaced: fd=4 errno=0"; "design check itemInfo(store.lock) != nil: true".

**(b) A failed `open()` leaks the lock.** Any throw after step 2 (EIO, the ENOSPC commit of S1-07) leaves the descriptor open. `flock` is per open file description, so every same-process retry fails with `.locked` until relaunch.

**(c) Step 1 mutates before locking.** `createDirectory`, `applyStoreAttributes` and directory syncs run before step 2 (store.md:220), so a second opener mutates a root it does not own.

**Smallest fix.**
- At acquisition, record the lock file's `(st_dev, st_ino)` in `StoreLockToken`, using `FileManager.attributesOfItem(atPath:)[.systemNumber / .systemFileNumber]`. This needs no pointers. It typechecks at iOS 15.0 and macOS 12.0, and the unsafe gate counts 0 escapes (§4). The pre-commit check compares identity, not existence: a mismatch or absence means `rootVanished`.
- `open()` releases the lock on every throwing path.
- Order `open()` as: create the directory chain to `v1` → lock → attributes, `blobs`, `staging`.

### S1-09 · major · `close()` races continuations of in-flight units

**Violates.** R-STO-9 (a second writer in one process), R-SYN-15 ("tests prove no task leaks"), I-5.

**Timeline.**
1. The engine's `publish(A)` is suspended on its rename unit (R4).
2. `close()` runs a durable flush. The flush's commit unit queues behind the rename unit on the serial metadata queue, runs and returns. `close()` cancels store-owned tasks and releases the lock (store.md:467).
3. `publish(A)` resumes. R4 checks no phase (store.md:623), so it sets `present`, calls `markDirty(.soon)` and spawns a *new* deferred commit task after the cancellation.
4. A new store opens the same root in this process: an `AssetClient` re-init, or the design's own reopen after `rootVanished`. It acquires the lock and commits gen N+1.
5. 250 ms later the old store's deferred task writes `index.tmp` and renames `bin → prev` and `tmp → bin`. The old store's state becomes `index.bin`, and the new store's `committedGeneration` and DOOMED ordering no longer describe the disk, so I-3's precondition is gone.

**Smallest fix.**
1. `close()` first sets `phase = .closing`.
2. It awaits the drain of a counter of in-flight units before the final durable flush and the unlock.
3. Every continuation after an `await` re-checks the phase and drops its mutation. The renamed blob is then an orphan, adoptable at the next launch.
4. `markDirty` and `commitNow` require `phase == .open`.

### S1-10 · major · Irrevocable external step after a non-durable publish (Apple pack release)

**Violates.** R-CLN-10, H-7, promise 1, and the design's own rule that a durable commit must precede an irrevocable step outside the ordering domain (store.md:885).

**Timeline.**
1. A pack file is copied or renamed into a staging reservation.
2. `publish` runs barrier → rename into `blobs/aa/h` and returns. The commit is coalesced and `aa` is not synced.
3. WP-E releases the pack "after that returns" (store.md:813). The OS performs the removal outside our barriers.
4. PL within about 250 ms plus the commit duration. `aa/h` is lost, and the removal of the pack has persisted.
5. Launch: A is absent and the pack is gone, so it must be re-downloaded. Offline, an essential asset is missing.

**Smallest fix.** Release only after `requireCommitted(g, .durable)` for the generation that records the adopted blob. Batching releases keeps this to one durable commit per batch.

### S1-11 · major · Degraded fallback still executes DOOMED deletions from the older generation

**Violates.** R-STO-4: "a torn, corrupt or newer-schema index never causes blobs to be deleted".

**Timeline.**
1. Gen N has h in DOOMED. In gen N+1, h was rescued: B became `present(h)`.
2. `index.bin` (N+1) rots, or a downgrade finds it `.newerSchema`. The load rule picks `index.prev` (N), with `degraded = true`.
3. 7a still deletes DOOMED keys (store.md:228; only orphan GC is suspended, store.md:214), so h is unlinked even though the newest generation references it.

**Smallest fix.** In degraded mode, DOOMED keys are protected exactly like orphans until the next `apply` plus adoption, then deleted only if still unclaimed. *Optional:* an older-schema commit never renames a newer-schema `index.bin` onto `prev`; park it under its own name so a later upgrade does not lose it.

### S1-12 · major · Hash-then-rename TOCTOU publishes bytes that were never hashed

**Violates.** I-1, R-STO-3.

**Timeline.**
1. `publish` hashes `staging/<id>.part` (store.md:674).
2. A late writer appends to the same path. Possible writers: a stale delegate callback of a cancelled `Range` transfer, or a resumed transfer reusing the reservation.
3. The unit runs barrier → `RENAME_EXCL`. The blob's name no longer matches its bytes, and it is served as `verified`.

**Evidence.** `misc toctou`:
- (a) With the design's order, "I-1 holds=false".
- (b) Renaming `.part` to a store-owned name *before* hashing gives "I-1 holds=true". The late per-call writer recreates a stray `.part` that staging GC collects.
- (c) A writer that keeps a file descriptor open still defeats any rename-based fix.

**Smallest fix.** The first step of `publish` renames `.part` to `staging/<id>.verifying`, a name only the store uses. Size check, hash, barrier and `RENAME_EXCL` follow. State the transport contract: no descriptor is held on a staged file after completion. `LiveFileSystem.write`, which opens per call, already satisfies it.

### S1-13 · major · Reaper liveness

**Violates.** R-SYN-14 (idle-silent), P-14, promise 4.

**Timeline.**
1. Key h is doomed and its `eligibleAt` has passed, but a lease holds it during a 2-hour video, or the commit is lagging (S1-07).
2. The reaper "sleeps until the earliest `eligibleAt`" (store.md:582). That instant is in the past, so `sleep(until:)` returns immediately, `reapEligible()` finds nothing deletable, and the loop repeats: a busy loop for the duration of the lease.
3. With `eligibleAt == nil` (no acknowledgement yet), "earliest" is undefined: either the task lingers without a deadline or the case is unhandled.

**Smallest fix.** The reaper waits only for keys whose *only* remaining blocker is time. `releaseLease`, a sink acknowledgement and commit completion re-arm it. If no time-blocked key exists, the task ends. Add the test `R-SYN-14: a doomed but leased blob leaves no running reaper task`.

### S1-14 · minor · Commit durability levels: cost and wording

- Every commit, including the coalesced **ordered** ones, runs `F_FULLFSYNC` on `index.tmp` (store.md:171). That is up to 4 device-cache flushes per second for a whole bulk sync, the battery and flash-wear cost the design rejected for blobs (Alternative D, store.md:51).
  - Ordering needs only `F_BARRIERFSYNC` on tmp. The load rule's "an invalid bin means corruption" still holds, because a barrier orders tmp's data before the rename.
  - Use `.full` only for durable commits. That also leaves the one observed P-5 sample above 40 ms (an `F_FULLFSYNC` sample, R1) off the hot path. On-device `F_FULLFSYNC` cost is unmeasured *(hint)*.
- store.md:174 says "PL reverting to N is allowed because the commit had not returned". An ordered commit *does* return before it is durable, so a PL can revert a commit that returned.
- The I-5 checker's "`committedGeneration` ≥ every generation whose commit returned" (store.md:941) holds only because the fake treats `.barrier` as `.full` (store.md:398). State it as a model property, and assert it on hardware semantics only for durable commits.

### S1-15 · minor · The `syncOutcome` fallback can hide an I/O error

`fcntl(F_FULLFSYNC | F_BARRIERFSYNC)` failure falls back to `fsync` (store.md:369). That is right for ENOTSUP, EINVAL and ENOTTY. For EIO or ENOSPC, `fsync` may succeed while the barrier never happened, and the store then believes an ordering it does not have. Restrict the fallback to the "unsupported" errnos and propagate everything else. Add a table test.

### S1-16 · minor · The allocation point of `droppedInGeneration` decides I-3

`deref` sets `droppedInGeneration: nextGeneration` (store.md:576), but "incremented for every commit attempt" (store.md:176) does not say *when*.

If the number is allocated when a commit completes rather than when its state is captured, a deref during an in-flight commit G gets G. G's captured state still references the blob, G commits, `committedGeneration ≥ G` holds, and the reaper unlinks a referenced blob.

Specify that `commitNow` allocates G at capture, and that `deref` uses the first generation captured *after* it. The `OrderingAuditor` must decode the committed index to prove the reference is gone, not compare numbers.

### S1-17 · minor · Launch staging GC and background transfers

- 7d keeps only `(.part, .resume)` *pairs* and deletes everything else (store.md:234–235). A background transfer's bytes are held by `nsurlsessiond` until relaunch, so its `.resume` is unpaired and is deleted before `reattachedTransfers()` (sync.md RE-S03) can claim it (H-6).
- Kept pairs (up to 72 h) are not counted against the budget. A crash loop that creates a new reservation per launch for the same large asset grows `staging/` outside the budget.
- **Fix.**
  - Keep an unpaired `.resume` younger than `stagingMaxAge`.
  - Key reservations by asset or transfer so a new reservation adopts or replaces the old pair.
  - Include staging bytes in the reserve check.

### S1-18 · minor · Migration details

- **(a)** Phase 2 and phase 4 address legacy files by path. `rename` and `unlink` resolve symlinked *intermediate* components even though the final component is never followed (store.md:844). `lstat` each component (≤ 32) and reject symlinked directories.
- **(b)** EEXIST on the phase-2 `RENAME_EXCL` (two legacy ids with identical bytes) is unspecified. Treat it as dedupe: remove L only after the existing blob is known durable (S1-01).
- **(c)** "Runs inside `open()`, before the first snapshot" (store.md:226) contradicts "publish snapshot every 64 adoptions" (store.md:862). Other APIs await `openTask` either way (R1), so no lookup hits during a multi-second migration (risk R4). Pick one.
- **(d)** The EXDEV fallback copies after hashing L and never hashes the copy. Hash while copying, and publish only on a match.

---

## 3. What I attacked that held

- **Single-crash commit protocol (§2.4.1).** I enumerated every boundary under PK, PK-torn and both PL modes, independently re-implemented in `crash2`. The load rule always finds the newest valid generation: 0 violations across 32 single-crash cases in scenario A, consistent with the drafter's 180.
  - Failed attempts never reuse a generation number.
  - A torn tmp fails its trailer, and the size rule `64 + bodyLength + 32` rejects truncation (modulo S1-04's arithmetic order).
  - A step-5 failure plus best-effort tmp removal leaves `prev` as the newest committed state, which is consistent.
  - A step-6 EIO after both renames leaves a valid N+1 that a reopen may legitimately pick, because no unlink depended on it.
- **ENOSPC/EIO at each commit step, 2–6.** The previous generation stays loadable in every case. Only the liveness problem (S1-07) remains.
- **Blob publication within one lifetime** (size → hash → barrier → `RENAME_EXCL`) holds I-1 under both PL modes. The per-directory "both names" outcome is handled by staging GC.
- **Load rule with a valid `prev` and a corrupt `bin`.** The rebuild by prev plus blob names plus the next manifest is sound, apart from S1-11.
- **Second opener while the root is intact.** Same-process and cross-process attempts both fail with EWOULDBLOCK (re-verified: `fd=-1 errno=35`). Fail-fast instead of queueing is a sound reading of R-STO-9.
- **Runtime I-3 ordering** (acknowledgement + monotonic grace + lease + committed generation before unlink) holds, given S1-16's clarification.
- **iOS 15 / macOS 12 and gates.** Every fix proposed here uses APIs already in the design, or `FileManager.attributesOfItem`. The lock-identity code typechecks at `arm64-apple-ios15.0` and `arm64-apple-macos12.0` with `-warnings-as-errors`, and the frozen unsafe gate counts 0 escapes. All fixes are reachable with the fake (coverage), except lock identity, which a live temp-directory test covers as in my probe.
- **Budgets.**
  - P-2 stays far inside 25 ms even when all three candidates are read, at about 2× the read+SHA cost of 1.43 MiB plus one decode.
  - P-13 is untouched by the chosen fixes, which add no syncs to deletion units.
  - P-5 gains one `blobs/` barrier at the first commit after launch, plus one per adopted fan-out (spread across listing units in a rebuild).
  - P-6 is outside this lens.

---

## 4. Evidence (run in this session)

```
$ cd .build-probe-review-store-1/crash2 && xcrun swiftc -O -swift-version 6 main.swift -o crash2 && ./crash2
== A: P-5 window blob adopted at launch, then power loss (fan-out never synced) ==
A design, R-STO-5 single crash (PK+PL): 32 single-crash cases, 0 violating
A design, drafter model (PK => all durable): 173 two-lifetime cases, 0 violating
A design, PK keeps volatility: 173 two-lifetime cases, 1 violating
    PK before [idle after last op] then PL before [after open() returned]: I-2: gen 2 record A present -> blob aa1 missing (needsHeal, re-download)
A fix: adoption dirties fan-out + blobs/: 175 two-lifetime cases, 0 violating
== B: launch deletes DOOMED of a generation whose rename was never synced ==
B design, drafter model (PK => all durable): 558 two-lifetime cases, 0 violating
B design (+A fix), PK keeps volatility: 564 two-lifetime cases, 1 violating
    PK before [rename …/staging/aa1.part -> …/blobs/aa/aa1] then PL before [after open() returned]: I-2: gen 2 record B present -> blob aa2 missing (needsHeal, re-download)
B (+A fix +open marks fan-outs dirty): 585 two-lifetime cases, 0 violating
B all fixes incl. root barrier before launch deletions: 594 two-lifetime cases, 0 violating
B (+A +open-dirty fixes), layout synced only at first open: 417 two-lifetime cases, 6 violating
    PK before [syncDir /AS/ZTronAssetKit/v1] then PL before [syncDir /AS/ZTronAssetKit/v1/blobs]: I-2: gen 2 record A present -> blob aa1 missing (needsHeal, re-download)
B same + root barrier before launch deletions: 426 two-lifetime cases, 0 violating
A all fixes: 190 two-lifetime cases, 0 violating
== C: <base>/ZTronAssetKit entry is never synced ==
C design (§2.4.3): 22 single-crash cases, 12 violating
    PL before [write /AS/ZTronAssetKit/v1/staging/aa1.part]: durability: root VANISHED, recovered gen 0 < returned gen 1
C fix: sync <base> at creation: 23 single-crash cases, 0 violating
== D: unlink never synced, DOOMED pruned, power loss, 7c re-adopts ==
D quarantined, design: 68 single-crash cases, 1 violating
    PL before [after last op]: gen 4 has A quarantined; open() re-adopted aa1 (CORRUPT bytes marked present)
D purged, design: 68 single-crash cases, 1 violating
    PL before [after last op]: gen 4 has A purged; open() re-adopted aa1 (purged bytes back)
D quarantined, fix: 7c skips purged/quarantined: 68 single-crash cases, 0 violating
D purged, fix: 7c skips purged/quarantined: 68 single-crash cases, 0 violating
E dedupe onto live key: publish(B) returned before the kill; after reopen B is absent -> RE-DOWNLOAD (violates §9.1 convergence rule)
F rescue of a doomed key: publish(B) returned before the kill; after reopen B is absent -> RE-DOWNLOAD (violates §9.1 convergence rule)

$ cd .build-probe-review-store-1/lock && xcrun swiftc -O -swift-version 6 main.swift -o lockprobe && ./lockprobe ./tmp-root
store 1 holds lock: fd=3 errno=0 identity=(16777230, 189790269)
second opener while root intact: fd=-1 errno=35 (EWOULDBLOCK=35)
second opener after root replaced: fd=4 errno=0  <- both now believe they are the single writer
store 1 design check itemInfo(store.lock) != nil: true  <- passes, so no rootVanished
store 1 identity check: recorded=(16777230, 189790269) current=(16777230, 189790272) replaced=true
$ xcrun --sdk iphoneos swiftc -typecheck -target arm64-apple-ios15.0 -swift-version 6 -strict-concurrency=complete -warnings-as-errors main.swift   -> exit=0
$ xcrun --sdk macosx  swiftc -typecheck -target arm64-apple-macos12.0 -swift-version 6 -strict-concurrency=complete -warnings-as-errors main.swift -> exit=0
$ python3 (Scripts/gates.py unsafe_check over lock/main.swift and misc/main.swift placed under a /Sources/ path)
UNSAFE escapes found=0 max=3

$ cd .build-probe-review-store-1/misc && xcrun swiftc -O -swift-version 6 main.swift -o misc
$ ./misc toctou tmp
(a) hash-then-rename, late path writer: hashed=d6004ba5 published=100dc91d I-1 holds=false
(b) rename-then-hash, late path writer: hashed=d6004ba5 published=d6004ba5 I-1 holds=true; stray .part exists=true
(c) rename-then-hash, writer holding an fd: hashed=d6004ba5 published=100dc91d I-1 holds=false
$ ./misc overflow
parsed generation = 18446744073709551615
exit=133   (SIGTRAP: arithmetic overflow in `1 + parsed`)
```

**Model notes.**
- `crash2` re-implements store.md §2.4.1 (commit), §2.4.2 (publish), §2.4.3 (layout), §2.5 (load rule), §2.6 steps 1, 3, 4, 7a–c, 8 and 10, and §4.5 (reaper), on the §3.4 per-directory model.
- `<base>` is modelled as `/AS`, pre-existing and durable.
- The only semantic difference from the drafter's model is that a PK does not make survivors durable.
- In scenarios A, B and D, `<base>` is synced, so that S1-02's whole-root loss does not mask them.

## 5. Tests to add (display names cite SPEC IDs only)

- `R-STO-5: a process kill followed by a power loss in the next lifetime preserves I-1…I-5` (args: scenario × k1 × k2)
- `R-STO-5: power loss after a durable commit keeps the store root reachable`
- `R-CLN-6: a purge is not undone by a power loss after the reaper ran`
- `R-CLN-8: a quarantined blob resurrected by power loss is never re-adopted`
- `R-STO-5: a deduplicated or rescued publish that returned is present after a kill`
- `R-INT-5: an unverified publish that returned survives a kill without a re-download`
- `R-CLN-7: a truncated blob is replaced by the next verified download`
- `R-SYN-11: eviction frees space while every index commit fails with ENOSPC`
- `R-CLN-6: purge on a full volume returns bytes freed`
- `R-STO-9: a replaced root is detected before the next commit`
- `R-STO-9: a failed open releases the lock`
- `R-SYN-15: no store mutation or commit happens after close returns`
- `R-STO-4: a degraded fallback deletes no blob listed in the older generation's doomed set`
- `R-STO-3: bytes appended to a staged file after publication begins are never published`
- `R-STO-12: a header with a maximal generation or body length never traps`
- `R-SYN-14: a doomed but leased blob leaves no running reaper task`
