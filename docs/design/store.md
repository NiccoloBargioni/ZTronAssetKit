# Storage layer design — `ZTronAssetStorage`
**Historical.** A Stage 1 design draft, kept for its rationale and probe evidence; where it differs from the merged code, [ARCHITECTURE.md](../ARCHITECTURE.md) and [DECISIONS.md](../DECISIONS.md) are authoritative.\
**Status.** Stage 1 Phase A draft (drafter: store). Input to Phase B (adversarial review) and Phase C (`ARCHITECTURE.md`, ADRs, contract code).
**Owns.** SPEC §1.4 **H-1, H-2, H-10** · §4.2 (store side of the concurrency model) · §4.3 (layout, I-1…I-5) · §4.4 · R-STO-1…13 · R-INT-1…6 · R-CLN-1…12 · R-SEC-2 · budgets P-2, P-5, P-6, P-13.
**Read before writing.** `CLAUDE.md`, SPEC §1–§7 and appendices, `docs/RECON.md` (all), `docs/DECISIONS.md` (ADR-001…011), `docs/BASELINE.md`, prior art `../ZTronCarouselCore/Sources/ZTronCarouselCore/CDN/{CDNLocalStore,CDNAsset,CDNSyncCoordinator,CDNAssetResolver,StaticManifestCDNProvider,BackgroundAssetsCDNProvider}.swift`, which was read only and never written.
**Evidence.** Everything marked *(measured)* or *(compiled)* was run in this session. The probes are in `.build-probe-store/` (git-ignored); §10 gives the commands and their output. Statements marked *(hint)* are unverified.
**Standalone package.** Nothing in this design writes outside this repository at build or test time. At runtime the store writes only under its root and, during migration, removes the legacy `Caches/CDNAssets` tree and the legacy `UserDefaults` key (§7).

---

## 0. Decisions at a glance

| # | Question | Decision | Evidence |
|---|---|---|---|
| D1 | Index structure (H-1) | One compact binary `index.bin` with a SHA-256 trailer, replaced atomically. Each commit uses temp → `F_FULLFSYNC` → rename(bin→prev) → rename(tmp→bin) → directory sync. On load, take the newest **valid** generation among `index.bin`, `index.tmp` and `index.prev`. Commits are coalesced to at most 4/s. | §10: 180 crash cases, 0 violations; commit including encode p50 11.3 ms, max 13.3 ms (budget 40) |
| D2 | Blob publication | Write to staging → size check → streaming hash → `F_BARRIERFSYNC` → `renamex_np(RENAME_EXCL)` into `blobs/<aa>/<sha256>.<ext>`. The fan-out directory is barrier-synced before the first commit that references the blob. | The two mutants (no barrier, no fan-out sync) are caught by the crash model |
| D3 | P-5 window (blob published, not yet recorded) | Each record stores `expectedBlob`, the manifest checksum or a legacy planned hash. At launch, every unreferenced blob whose key equals some record's `expectedBlob` is **adopted without re-download**. Manifest application is committed **before** any fetch for that manifest. The commit's root-directory barrier orders it ahead of every later blob write, so "a blob of manifest M is on disk" implies "M is committed", even after power loss. | Covered by the crash model; test `R-STO-5 …P-5 window…` |
| D4 | Snapshot vs deletion (H-2) | Epoch reclamation. A blob is deleted only when the snapshot without it has been **acknowledged by the main-actor mirror**, `deletionGrace` has passed since that acknowledgement, no lease covers it, and the index generation without it has been committed with an ordering barrier. A doomed list persisted in the index finishes any deletion a crash interrupted. | — |
| D5 | `FileSystem` shape | **Synchronous**, path-based (`URL`), 15 methods, typed `throws(FileSystemError)`. It is only ever called inside a bounded unit on an injected `BlockingExecutor`: in `.live`, two dedicated serial `DispatchQueue`s (metadata, bulk) with `autoreleaseFrequency: .workItem`; in tests, inline. | Typechecks at iOS 15.0 and macOS 12.0; unsafe gate finds 0 escapes |
| D6 | Hashing | Stateless 1 MiB units (`FileHandle` open → `seek` → `read(upToCount:)` → close) with the `SHA256` value (`Sendable`) passed across units. `Task.isCancelled` is checked between units. No pointers. | 2539 MB/s = 0.81× one-shot (3124 MB/s); RSS Δ 1.77 MiB |
| D7 | Advisory lock | `open(store.lock, O_RDWR\|O_CREAT\|O_CLOEXEC\|O_EXLOCK\|O_NONBLOCK)`. Contention fails immediately with `StoreError.locked`; there is no queueing. | Same-process and cross-process second opens get EWOULDBLOCK; `SIGKILL` releases the lock |
| D8 | Test fakes and the unsafe budget | `FakeFileSystem` holds `Synchronization.Mutex` and carries `@available(macOS 15.0, iOS 18.0, *)`. Tests reach it through an unannotated factory funnel (§3.5), because Swift Testing rejects `@available` on `@Suite` and multi-platform `@available` on `@Test`. Zero escapes. | Compiled; macro diagnostics reproduced |
| D9 | Legacy migration (H-10) | Three committed phases (plan → adopt by hash via same-volume rename → done), then teardown. The legacy stamp is migrated only if **every** legacy entry was adopted. The `UserDefaults` key is removed only after a **durable** "done" commit. | — |
| D10 | Eviction and GC batching (P-13) | Deletion units of **64** unlinks (max unit 2.87 ms; 128 would be 5.42 ms). Record marking runs in chunks of ≤ 1,000 blobs per actor turn. | 10,000 blobs reclaimed in 359 ms |

**NEEDS-HUMAN-REVIEW** (ADR candidates for Phase C; I did not edit `DECISIONS.md`):
- **ADR-012 (layout deviation).** Two names beyond SPEC §4.3 (`index.prev`, transient `index.tmp`), the `DOOMED` section, and the byte format of §2.3.
- **ADR-013.** Two-level commit durability (ordered vs durable, §2.4.1).
- **ADR-014.** Test-fake availability funnel (§3.5).
- **ADR-015.** Default storage-policy numbers (§6.0).

---

## 1. Hard problems

### H-1 — Crash consistency

**Decision.** Content-addressed immutable blobs plus one atomically replaced snapshot index (D1, D2), with these rules:
1. **Write-once blobs.** A name under `blobs/` appears only by `rename(RENAME_EXCL)` of a file that is already complete, size-checked, hash-verified and barrier-synced (I-1).
2. **The index is a value, not a log.** Each commit writes the entire state as a new generation. Any committed generation is a complete, valid state (I-5), so recovery never replays anything.
3. **References are made durable in dependency order.** The fan-out directory of a new blob is barrier-synced before the index generation that references it. The generation that drops a reference is committed with a barrier before the blob is unlinked. Durability therefore always flows in the same direction as references (I-2).
4. **Recovery is idempotent reconciliation.** Recovery adopts blobs whose names match expected hashes, deletes doomed and orphan blobs, and collects staging. Running it twice is a no-op.

**Alternatives seriously considered and rejected**

| Alternative | Why it was attractive | Why it was rejected |
|---|---|---|
| **A. Write-ahead log + periodic checkpoint.** Append record deltas with a per-entry CRC, compact periodically. | O(1) bytes per mutation; no 1.4 MiB rewrite per commit. | Torn-tail handling, replay and compaction are crash-consistency problems in their own right. Every log append is an extra crash boundary, which inflates the R-STO-5 enumeration roughly 10× for a bulk sync. Load cost is checkpoint plus replay, which needs its own bound for P-2. The measured cost of D1 (commit including encode p50 11.3 ms at ≤ 4/s, about 4.5 % of one core) makes the optimisation unnecessary. |
| **B. SQLite (WAL).** | Battle-tested atomicity. | SQLite performs its own I/O. That violates R-STO-6 (every effect through `FileSystem`) and makes R-STO-5's exhaustive enumeration impossible through our seam. Binding with `SQLITE_TRANSIENT` conventionally requires `unsafeBitCast`, an unsafe-gate escape. SQLite in shared containers carries 0xdead10cc risk. ADR-002 already rejected it. |
| **C. One small record file per asset** (`records/<hash(id)>`). | O(1) atomic per-asset update. | Loading 10,000 files would far exceed P-2 (25 ms). The listing alone took 52 ms *(measured, §10)*, before opening and reading each file. There is no atomic multi-asset transition, so applying a manifest that relocates 1,000 entries could not be atomic, which reintroduces D-10/D-18. |
| **D. Make every blob durable with `F_FULLFSYNC`** instead of barrier plus fan-out barrier-sync. | Each blob is durable on its own. | A directory `F_FULLFSYNC` costs p50 4.15 ms, max 12.5 ms, against 0.37 ms for a barrier *(measured)*. Per blob this flushes the device cache thousands of times during a bulk sync (battery, flash wear). Consistency only needs ordering. |
| **E. `renamex_np(RENAME_SWAP)` of tmp and bin**, so `index.bin` always exists. | No window without `index.bin`. | Swap support varies by volume (`VOL_CAP_INT_RENAME_SWAP`), so a fallback is needed anyway. The newest-valid-generation load rule (§2.5) already makes that window harmless, as the crash model showed. |

**Test.** `R-STO-5` exhaustive crash-point enumeration over six scenarios × four crash modes (§9.2), plus the model-based oracle (§9.3).

### H-2 — Snapshot vs deletion

**Decision (D4): epoch-based reclamation with acknowledged publication.**
- UI readers call `SnapshotMirror.lookup` on the main actor. It reads `current: AssetSnapshot`, an immutable value. Swapping `current` is a single main-actor assignment, so readers never see a torn state (R-STO-13).
- The store publishes with `await sink.install(snapshot)`. For the mirror this is a main-actor hop that assigns `current` and **returns only after the swap**. That return is the acknowledgement: from then on no reader can obtain a URL that is absent from the new snapshot.
- A blob `k` becomes **deletable** only when all of the following hold (checked on the actor, §4.5):
  1. `ackedVersion ≥ k.unreferencedSinceVersion`, meaning a snapshot without `k` has been acknowledged.
  2. `monotonicNow ≥ ackInstant + deletionGrace`, meaning every URL handed out from an older snapshot (or by `resolve`) has had at least `deletionGrace` to be opened. On Darwin an already open file descriptor survives `unlink`, so the grace window only has to cover "URL obtained but not yet opened".
  3. `leaseCount(k) == 0`. Leases (`withAsset`) cover long use such as video playback.
  4. `committedGeneration ≥ k.droppedInGeneration`. The commit uses an ordering barrier, so an unlink can never reach the disk before the generation that dropped the reference.
- **The resulting contract (documented on the public API):** every URL the module hands out stays readable for at least `deletionGrace` (default 10 s), and for the whole duration of a lease.

**Alternatives rejected**

| Alternative | Why it was rejected |
|---|---|
| **A. Reference-count every handed-out URL** (lookup increments, consumer releases). | `lookup` returns a plain URL synchronously, and consumers such as `UIImage(contentsOfFile:)` and `AVPlayer` never release. That would require an API change and would leak. |
| **B. Never delete while the app runs; sweep tombstones at the next launch** (at launch no reader exists). | Simple and obviously safe, but quota eviction, `purge` ("bytes freed now", R-CLN-6) and ENOSPC recovery mid-sync could not free anything until a relaunch. **Kept as the crash fallback:** the doomed list is swept at launch. |
| **C. Fire-and-forget snapshot stream** (`AsyncStream`, newest wins) with a fixed delay before deletion. | The store could never know whether the main actor had actually switched (a busy main thread delays delivery arbitrarily), so I-3 would rest on timing. Rejected. Acknowledgement is what makes I-3 a proof rather than a heuristic. |
| **D. Hard link per reader.** | Needs file-system work on the main thread (C2, R-STO-7). |

**Test.** `R-CLN-5: deletion waits for the acknowledged snapshot without the blob, the grace window and every lease` (an ordering auditor over the fake's op log and the sink's acknowledgement log), plus mutation probe *delete before publishing the snapshot* (SPEC §7.4).

### H-10 — Migration

**Decision (D9): adopt-by-hash via same-volume rename, in committed phases (§7).** Every legacy file whose checksum verifies is renamed (moved, not copied) into `blobs/` under its hash name. The legacy manifest becomes the applied manifest, so offline `lookup` works before the first sync, preserving `existingLocalURL` behaviour (RECON §5). The legacy `UserDefaults` stamp is copied into the index only if every legacy entry was adopted, and the key is removed only after a durable "done" commit. A crash anywhere resumes, and the resumed run never re-hashes or re-downloads what was already adopted, because the index records each entry's `expectedBlob` before any file moves.

**Alternatives rejected**

| Alternative | Why it was rejected |
|---|---|
| **A. Reference legacy files in place** (index points at `Caches/CDNAssets/<pretty path>`). | Paths built from manifest text (D-14, R-SEC-2). Data stays in OS-purgeable `Caches` (contradicts ADR-001). Two layouts forever, and it breaks I-1 (name ≠ hash). |
| **B. Copy, then delete.** | Doubles peak storage (a 1 GB catalog needs 1 GB free) and doubles I/O. **Kept only as the `EXDEV` fallback** for a `.custom` root on another volume. |
| **C. Hash-blind move.** Hash every file into `blobs/` without reading the legacy manifest and let the first sync adopt by hash. | Loses offline lookup until the first successful sync (promise 1) and loses checksum-less entries. **Kept as the degraded path** when `manifest.json` is unreadable: degraded mode suspends orphan GC (§2.6), so the next manifest can adopt them. |
| **D. Discard and re-download.** | Violates H-10 and R-STO-11. |

**Test.** `R-STO-11` fixtures generated from the real prior-art code, with crash enumeration over the migration (§9.2 scenario 6).

---

## 2. On-disk layout, formats, protocols, recovery

### 2.1 Tree

```
<base>/ZTronAssetKit/v1/                  root  (<base> = Application Support | Caches | custom; ADR-001)
  store.lock                              advisory lock; empty; never deleted by the module
  index.bin                               current index generation (binary, §2.3)
  index.prev                              previous generation (same format; fallback against single-file corruption)
  index.tmp                               transient: the generation being committed (garbage if its trailer fails)
  blobs/<aa>/<64 lowercase hex>.<ext>     immutable content; <aa> = first two hex chars; <ext> ∈ [a-z0-9]{1,8}
  staging/<UUID>.part                     in-progress or completed-but-unpublished download bytes
  staging/<UUID>.resume                   resume metadata (format owned by Transport/Sync; the store manages only the name, claim and age)
```
- **R-SEC-2.** No manifest-supplied text is ever a path component. `<aa>/<hex>` comes from our own digest. `<ext>` is the manifest's `fileExtension`, re-validated by `BlobExtension.init?` (lowercased, `[a-z0-9]{1,8}`) before any URL is built. `<UUID>` comes from the injected random source. All URLs are built by one type, `StoreLayout`, and nothing else in the module concatenates path strings.
- R-STO-1 and R-STO-2: nothing else is persisted anywhere. The manifest ETag, sync stamps, refresh bookkeeping, integrity backoff, access times, pins, legacy-migration state and doomed list all live inside `index.bin`. Deleting the root resets everything together.

### 2.2 Files

| File | Writer | Format | Write protocol | Read by |
|---|---|---|---|---|
| `store.lock` | store `open()` | empty | `open(O_RDWR\|O_CREAT\|O_CLOEXEC\|O_EXLOCK\|O_NONBLOCK, 0600)`, held for the store's lifetime | kernel only |
| `index.tmp` → `index.bin` → `index.prev` | commit unit (metadata queue) | §2.3 | §2.4.1 | `open()` load rule §2.5 |
| `blobs/<aa>/<h>.<ext>` | `publish`, legacy migration | raw asset bytes | §2.4.2 | consumers via URL; reconciliation lists names only |
| `staging/<id>.part` | Transport (URLSession temp moved in synchronously from the delegate; or `Range` appends) | raw bytes | not synced; becomes a blob only through `publish` | `publish`, staging GC |
| `staging/<id>.resume` | Transport/Sync | owned by WP-D/F | not synced; garbage if it does not parse | engine; staging GC (age, claim) |

### 2.3 `index.bin` byte format (schemaVersion 1)

All integers are little-endian. `varint` = unsigned LEB128. `zigzag` = signed varint. `strref` = varint index into the STRINGS table. Times are whole seconds since 2001-01-01 (`Date.timeIntervalSinceReferenceDate`) as `zigzag`, except `writtenAtMillis`.

**Header (fixed 64 bytes)**

| Offset | Size | Field | Notes |
|---|---|---|---|
| 0 | 8 | magic | `5A 54 41 4B 49 44 58 00` ("ZTAKIDX\0") |
| 8 | 2 | `schemaVersion` | `1` |
| 10 | 2 | `headerLength` | `64` |
| 12 | 4 | `flags` | bit0 `degraded`, bit1 `legacyMigrationInProgress`; others 0 |
| 16 | 8 | `generation` | UInt64; strictly increasing per commit **attempt** (I-5) |
| 24 | 8 | `bodyLength` | bytes from offset 64 up to the trailer; ≤ 64 MiB |
| 32 | 8 | `writtenAtMillis` | Int64 from the injected `TimeSource` (diagnostics only) |
| 40 | 16 | `storeID` | random UUID bytes fixed at store creation (seeded in tests). A `prev` or `tmp` whose `storeID` differs from the chosen file's is ignored. |
| 56 | 4 | `sectionCount` | UInt32 |
| 60 | 4 | reserved | 0 |
| 64 | `bodyLength` | body | `sectionCount` × (`tag: UInt8`, `length: varint`, `payload`) |
| 64 + `bodyLength` | 32 | **trailer** | SHA-256 over bytes `[0, 64 + bodyLength)` |

The file size must equal `64 + bodyLength + 32` exactly; anything else is `torn`.

**Sections** (each at most once, in tag order; an unknown tag `< 0x80` is `malformed`; an unknown tag `≥ 0x80` is ancillary and skipped, which leaves room for additive changes without a schema bump)

| Tag | Name | Payload |
|---|---|---|
| `0x01` | STAMPS | presence bitmap (varint), then the present fields in this order: `lastSyncedAt` zigzag · `lastSyncedAppVersion` strref · `manifestETag` strref · `manifestFetchedAt` zigzag · `manifestDigest` 32 bytes · `lastCleanupAt` zigzag · `lastMaintenanceAt` zigzag · `syncDue` u8 · `legacyState` u8 (0 none, 1 inProgress, 2 done) · `legacyStamp` strref |
| `0x02` | STRINGS | `count` varint, then `count` × (`len` varint, UTF-8 bytes). Deduplicated across identifiers, path components, tags, extensions, remote paths. |
| `0x03` | RECORDS | `count` varint, then per record: `flags` varint (bit0 hasFileName, bit1 hasChecksum, bit2 hasBlob, bit3 blobEqualsChecksum, bit4 pinned, bit5 verified, bit6 hasByteSize, bit7 hasFailedChecksum, bit8 hasPlannedHash) · `id` strref · `ext` strref · `remotePath` strref · `dirCount` varint + strref× · `fileName` strref (bit0) · `byteSize` varint (bit6) · `checksum` 32 B (bit1) · `tagCount` varint + strref× · `policy` u8 (0 standard, 1 essential, 2 onDemand) · `residency` u8 (0 absent, 1 present, 2 needsHeal, 3 failed, 4 quarantined) · `absenceOrFailureReason` u8 · `blobHash` 32 B (bit2 ∧ ¬bit3) · `blobSize` varint (bit2) · `plannedHash` 32 B (bit8) · `lastAccess` zigzag · `storedAt` zigzag · `verifiedAt` zigzag · `integrityAttempts` u8 · `nextEligibleAt` zigzag (0 = none) · `failedChecksum` 32 B (bit7) |
| `0x04` | DOOMED | `count` varint + `count` × (32-byte hash, `ext` strref) |

**Decoding.** The whole file is read in ≤ 1 MiB units. The trailer is verified **before** decoding. Decoding uses a bounds-checked cursor over `[UInt8]` that returns `IndexDecodeError` (`.torn`, `.badMagic`, `.newerSchema(UInt16)`, `.trailerMismatch`, `.limitExceeded`, `.malformed`) and never traps. Limits: records ≤ 100,000 (= the R-MAN-2 entry limit), strings ≤ 400,000, string ≤ 65,535 bytes, dirs per record ≤ 32, tags ≤ 64.

**Size and speed** *(measured, 10,000 realistic records)*: 1.43 MiB; encode p50 5.2 ms; load (read + SHA-256 verify + decode into a dictionary) p50 2.8 ms, max 3.3 ms, against the **P-2** budget of 25 ms.

**Versioning (R-STO-12).** `Tests/Fixtures/index/v1/*.bin` is committed with a JSON description of its expected decoded content. Every future schema adds `vN` fixtures and a decoder `vN → current`. The chain test decodes every fixture into the current model and re-encodes it.

### 2.4 Write protocols and what a crash at each step leaves

Each numbered step is one `FileSystem` mutation and therefore one crash boundary (§3.4). "PK" = process kill (the kernel survives, so every applied op persists). "PL" = power loss (un-synced data and directory entries may revert).

#### 2.4.1 Index commit (one unit on the metadata queue; input: an immutable `IndexState` value plus `dirtyDirectories`)

| # | Op | Crash before this op leaves | Recovery |
|---|---|---|---|
| 1 | `synchronizeDirectory(blobs/<aa>, .barrier)` for each fan-out that received a blob since the last commit, then `blobs/` itself if a fan-out was created | blobs published but not yet referenced | adopted by hash (§2.6 step 7c); nothing re-downloads |
| 2 | `write(encoded, to: index.tmp, .truncate)` | no tmp, or an old tmp | an old tmp fails `storeID`/generation checks or its trailer; ignored, then deleted |
| 3 | `synchronizeFile(index.tmp, .full)` = **`F_FULLFSYNC`**, the "durable flush" of R-STO-4 | PK: complete tmp (valid). Torn PK: half tmp (trailer fails). PL: tmp lost or empty. | load rule picks the newest valid generation |
| 4 | `rename(index.bin → index.prev, .replacing)` (skipped when there is no bin) | valid tmp (N+1) + bin (N) | picks N+1 from tmp |
| 5 | `rename(index.tmp → index.bin, .replacing)` | **no `index.bin`**; tmp (N+1) and prev (N) | picks N+1 from tmp (shown safe by the crash model) |
| 6 | `synchronizeDirectory(root, level)`. `level = .barrier` for **ordered** commits (the coalesced default), `.full` for **durable** commits (`flush()`, `close()`, migration "done") | PK: bin = N+1, prev = N. PL: renames may revert. | PL reverting to N is allowed because the commit had not returned, and any later unlink is ordered after this barrier |

- **Generation.** `nextGeneration` is set at open to `1 + max(generation of every parseable header, valid or not)` and is incremented for every commit **attempt**. A failed attempt therefore never shares a number with a later success, and I-5 holds strictly.
- **Failure.** On ENOSPC/EIO the unit best-effort removes `index.tmp`, keeps `index.bin`/`index.prev` untouched, the in-memory state stays authoritative, `dirtyDirectories` are restored, and the error surfaces (§6.7).
- **Two durability levels (ADR-013).** An ordered commit guarantees I-5 and the ordering I-2 and I-3 need: an unlink issued after the root barrier cannot reach the media before the renames. A durable commit additionally makes the generation survive power loss. That is required before an irrevocable step outside our ordering domain, namely removing the legacy `UserDefaults` key (§7), and on `flush()`/`close()`. *(measured, 16 dirtied fan-outs, encode included)*: ordered p50 11.3 / p95 12.4 / max 13.3 ms; durable p50 16.0 / p95 17.9 / max 21.1 ms.
- **Rate limit (P-5).** Commits are coalesced to `commitMinimumInterval = 0.25 s`, i.e. at most 4 per second (§4.6).

#### 2.4.2 Blob publication (R-STO-3; detailed flow in §5.3)

| # | Op (queue) | Crash before this op leaves | Recovery |
|---|---|---|---|
| 1 | Transport fills `staging/<id>.part` (URLSession temp `rename`d in synchronously by the delegate) | partial or complete `.part` | staging GC (unclaimed or older than `stagingMaxAge`); a resumable pair may be resumed by the engine |
| 2 | `itemInfo(.part)`: size equals `byteSize` (query, not a boundary) | — | — |
| 3 | hash units (bulk queue, reads only) | — | — |
| 4 | `synchronizeFile(.part, .barrier)` = `F_BARRIERFSYNC` | complete, un-synced `.part` | staging GC |
| 5 | `createDirectory(blobs/<aa>)`, idempotent; first creation marks `blobs/` dirty | — | — |
| 6 | `rename(.part → blobs/<aa>/<h>.<ext>, .exclusive)`; EEXIST means dedupe: `removeItem(.part)` | PK: blob present, unreferenced (**P-5 window**). PL: blob present with full data (barrier), or `.part` still in staging, or both names (per-directory model) | adopted by `expectedBlob`; staging GC removes the second name |

**Why the barrier is needed.** The crash model's "metadata survives, data lost" mode turns a renamed but un-synced file into a zero-length blob (I-1 violation). The probe's `mutant-no-barrier-before-rename` produced 64 violating cases.

#### 2.4.3 Directory creation at first open

`createDirectory` of `<base>/ZTronAssetKit`, `v1`, `blobs`, `staging` (each idempotent) → `applyStoreAttributes(root)` → `synchronizeDirectory(<base>/ZTronAssetKit, .barrier)` and `synchronizeDirectory(root, .barrier)`. A crash leaves some directories, and the next open recreates the rest.

#### 2.4.4 Deletion (prune, evict, purge, GC, quarantine)

`removeItem` in units of 64 (§6.8). No sync is needed afterwards: an unlink lost to power loss makes the file reappear, and it is then either doomed (index DOOMED section) or an orphan, so it is deleted again. `removeItem` on an absent file succeeds, which keeps every sweep idempotent (R-CLN-12).

### 2.5 Index load rule

```
candidates = read+validate(index.bin), read+validate(index.tmp), read+validate(index.prev)   // ≤ 64 MiB each, in 1 MiB units
valid      = candidates where trailer ok ∧ schemaVersion ≤ current ∧ (storeID agrees with the highest valid)
chosen     = valid.max(by: generation)                       // tmp may win: it was F_FULLFSYNC'd before any rename
nextGen    = 1 + max(generation of every header that parsed)
degraded   = chosen == nil
           ∨ (index.bin exists ∧ index.bin ∉ valid)          // corruption, not a crash window: bin is only ever a fully synced tmp
           ∨ any candidate is .newerSchema                    // downgrade: never delete what a newer build referenced
state      = chosen.map(decode) ?? IndexState.empty(storeID: new or reused)
```
In `degraded` mode orphan GC is suspended (R-STO-4: a torn, corrupt or newer-schema index never causes blobs to be deleted) until a manifest has been applied **and** adoption by hash has run against it (§2.6 step 7c). The flag is persisted in the header (bit0), so a crash cannot end it early.

### 2.6 Launch reconciliation (`open()`)

```
open():
  1  [unit] standardDirectory(location) → root URL; create layout (§2.4.3); verify/re-apply attributes (R-STO-8)
  2  [unit] acquireExclusiveLock(root/store.lock)            → .wouldBlock ⇒ throw StoreError.locked   (R-STO-9)
  3  [units] load rule (§2.5)                                → state, degraded, nextGen
  4  [256 units] list blobs/<aa>/ for every fan-out           → onDisk: [BlobKey: size, mtime]
       names not matching ^[0-9a-f]{64}\.[a-z0-9]{1,8}$, files in the wrong fan-out, symlinks, other kinds → foreign (delete list)
  5  [unit] list staging/                                     → staging entries
  6  legacy migration if detected (§7). It runs here, inside open(), before the first snapshot.
  7  reconcile on the actor (pure; ≤ 2,000 records per turn, with revision check):
     a  doomed (from DOOMED)            → delete list; never adopted, even if a record expects the same key
     b  record.present(k)               → k ∈ onDisk ∧ size == blobSize ? keep : needsHeal(k); missing += 1
     c  for k ∈ onDisk \ (referenced ∪ doomed):
          if ∃ records r with r.expectedBlob == k.hash ∧ r.ext == k.ext ∧ (r.byteSize == nil ∨ r.byteSize == size)
               → every such r becomes present(k, verified: r.entry.checksum != nil)   (P-5 window; no re-download)
          else → orphan: delete list if ¬degraded, else keep (protected until a manifest adopts or rejects it)
     d  staging: keep (.part, .resume) pairs younger than stagingMaxAge with a parseable .resume (the engine may claim them);
        everything else → delete list                                                            (R-CLN-3, D-7)
     e  OS-purge detection (R-CLN-7, D-6):
          if missing > 0  ∨  (state had present records ∧ onDisk is empty)  ∨  (blobs/ had to be recreated ∧ state had present records)
             → lastSyncedAt = nil, lastSyncedAppVersion = nil, syncDue = true; emit .osPurgeDetected(missing)
        (A vanished root needs no special case: the stamp lived inside it, so the new state is empty and a sync is due.)
  8  if anything changed ∨ chosen ≠ index.bin: commit (ordered)
  9  build the presentTable and publish snapshot v1 (await install)
 10  delete list in units of 64. No grace is needed: nothing in this process ever handed these URLs out.
     Afterwards a lazy commit drops the processed DOOMED entries. A crash in between re-runs 7a, which is idempotent.
```
- **P-5 note.** Because commits are coalesced, up to ~250 ms of publications (plus the commit's own duration) can be on disk but absent from `index.bin`. Step 7c adopts them by `expectedBlob` without hashing. That relies on I-1, which the barrier guarantees for both PK and PL. Two rules make the match always possible: `apply(manifest:)` commits **before** any fetch for that manifest, and legacy checksum-less entries record their `plannedHash` in phase 1 of §7.
- **Rebuild.** If the index is lost but `index.prev` is valid, `prev` plus blob names is the rebuild (7b and 7c). If nothing is valid, the store starts empty in degraded mode. The next `apply(manifest:)` performs 7c against the fresh manifest, adopting every blob that matches a checksum, then clears `degraded`, and from then on orphan GC may delete the rest. Only checksum-less (unverified) entries can need a re-download in that double-failure case.

### 2.7 Invariants: where each is enforced

| Invariant | Enforced by | Checked by |
|---|---|---|
| **I-1** blob complete and named by its hash | publish order: size → hash → barrier → `RENAME_EXCL`; migration does the same; nothing else creates names in `blobs/` | `InvariantChecker` re-hashes every blob after every reopen (crash and model tests) |
| **I-2** every `present` record has its blob after reconciliation, or is `needsHeal` | §2.6 7b; fan-out barrier before the referencing commit; unlink only after the ordered commit that dropped the reference | checker; crash enumeration also asserts **zero** `needsHeal` when no blob was externally removed |
| **I-3** delete only after the acknowledged snapshot without the blob and the grace window | deletable predicate §4.5; the reaper is the only runtime caller of `removeItem` on `blobs/` | `OrderingAuditor` (§9.1) |
| **I-4** staging never referenced | `SnapshotEntry` and records hold only `BlobKey`; URLs come only from `StoreLayout.blobURL` | type-level, plus checker scan |
| **I-5** strictly increasing generations; any committed prefix is valid | `nextGen` rule; whole-state commits; load rule | checker reads headers before and after each crash |

---

## 3. The `FileSystem` abstraction (R-STO-6)

### 3.1 Synchronous or asynchronous? **Synchronous**, behind an injected `BlockingExecutor`

| Criterion | Synchronous protocol + executor (chosen) | `async` protocol (each conformer hops internally) |
|---|---|---|
| **C2 / ADR-003** (no blocking on the cooperative pool; bounded units) | The store composes a bounded unit explicitly (one ≤ 1 MiB read + hash update; one commit; 64 unlinks; one directory listing) and submits it to a dedicated queue. The unit size is visible at the call site and reviewable. | The hop granularity is hidden in each conformer: one hop per syscall (too many: a commit would be 8 hops) or one hop per large op (unbounded). The store cannot group effects. |
| **R-STO-5** exhaustive crash enumeration | Each call is exactly one boundary, executed atomically under the fake's lock in program order. With an inline executor the whole scenario is deterministic: the same op sequence on every run, so "crash before op k" means the same thing every time. | Every effect becomes a suspension point. The order of effects from concurrent tasks depends on the scheduler, so k is not stable across runs and enumeration becomes sampling, which R-STO-5 forbids. |
| URLSession delegate must move the temp file **before returning** | The delegate (on its own `OperationQueue`, not the pool) calls `fileSystem.rename` synchronously into a pre-reserved staging URL. | It cannot await inside the delegate callback before the OS deletes the file. |
| Cancellation | Checked between units (`Task.isCancelled`), so no shared flag, lock or `@unchecked` is needed (ADR-003). | Same, but the conformer would have to implement it. |
| Test executor | `InlineBlockingExecutor` runs the unit on the caller. No thread hops, TSan-clean. | The fake would have to be async (actor) and could not serve synchronous callers such as the delegate. |

A third option was rejected: calling `FileManager`/POSIX directly from the store and faking at a lower level (e.g. a temporary directory with fault-injecting hooks). It offers no crash points and no power-loss model, which R-STO-5 and R-STO-6 require.

### 3.2 Exact signatures (contract code for Phase C; `public` because `AssetEnvironment` is public, SPEC §4.2)

```swift
/// Kinds of directory entry the store distinguishes. Symbolic links are never followed (R-SEC-2).
public enum FileItemKind: Sendable, Equatable { case file, directory, symbolicLink, other }

/// Metadata of one existing item (directory listings return these too).
public struct FileItemInfo: Sendable, Equatable {
    public let name: String
    public let kind: FileItemKind
    public let byteSize: Int64
    public let modifiedAt: Date?
}

/// How strongly a sync orders or persists earlier writes.
public enum SyncLevel: Sendable, Equatable {
    /// `F_BARRIERFSYNC`: data reaches the device and is ordered before every later write.
    case barrier
    /// `F_FULLFSYNC`: data and the device cache are flushed to stable storage.
    case full
}

/// `truncate` and `append` both create the file when absent.
public enum WriteMode: Sendable, Equatable { case truncate, append }

/// `replacing` = rename(2); `exclusive` = renamex_np(RENAME_EXCL) and fails with `.alreadyExists`.
public enum RenameMode: Sendable, Equatable { case replacing, exclusive }

/// Platform directories the store may be rooted in (ADR-001); resolved inside a unit, never at init (P-12).
public enum StandardDirectory: Sendable, Equatable { case applicationSupport, caches }

/// Data-protection classes the store can request.
public enum ProtectionClass: Sendable, Equatable { case completeUntilFirstUserAuthentication, complete, none }

/// Backup and protection state of the root (R-STO-8). `protection` is nil where the platform has none (macOS).
public struct StoreAttributes: Sendable, Equatable {
    public var excludedFromBackup: Bool
    public var protection: ProtectionClass?
}

/// Opaque handle of a held advisory lock (a file descriptor in `.live`).
public struct StoreLockToken: Sendable, Hashable { package let rawValue: Int64 }

/// Closed taxonomy of file-system failures; the live conformer maps errno / NSError here, exhaustively tested.
public enum FileSystemError: Error, Sendable, Equatable {
    case noSpace, io, permissionDenied, notFound, alreadyExists, crossDevice, wouldBlock, notEmpty, notSupported
    case other(errno: Int32)
}

/// Every file-system effect of the module (R-STO-6). Synchronous by design: each call is one bounded,
/// atomic step and one crash boundary. Production code calls it only inside `BlockingExecutor.run`
/// (ADR-003), or, for the URLSession temp-file hand-off, from the delegate queue.
public protocol FileSystem: Sendable {
    // Queries — not crash boundaries.
    func standardDirectory(_ directory: StandardDirectory) throws(FileSystemError) -> URL
    func itemInfo(at url: URL) throws(FileSystemError) -> FileItemInfo?
    func contentsOfDirectory(at url: URL) throws(FileSystemError) -> [FileItemInfo]
    func read(from url: URL, offset: Int64, maxLength: Int) throws(FileSystemError) -> Data
    func availableCapacity(at url: URL) throws(FileSystemError) -> Int64
    func storeAttributes(at url: URL) throws(FileSystemError) -> StoreAttributes
    // Mutations — each one crash boundary.
    func createDirectory(at url: URL) throws(FileSystemError)
    func write(_ data: Data, to url: URL, mode: WriteMode) throws(FileSystemError)
    func synchronizeFile(at url: URL, level: SyncLevel) throws(FileSystemError)
    func synchronizeDirectory(at url: URL, level: SyncLevel) throws(FileSystemError)
    func rename(from source: URL, to destination: URL, mode: RenameMode) throws(FileSystemError)
    func removeItem(at url: URL) throws(FileSystemError)
    func applyStoreAttributes(_ attributes: StoreAttributes, at url: URL) throws(FileSystemError)
    func acquireExclusiveLock(at url: URL) throws(FileSystemError) -> StoreLockToken
    func releaseLock(_ token: StoreLockToken)
}

/// Runs bounded blocking units off the cooperative pool (ADR-003). `.live`: a dedicated serial DispatchQueue
/// (`autoreleaseFrequency: .workItem`) bridged with `withCheckedContinuation`; tests: inline.
public protocol BlockingExecutor: Sendable {
    func run<T: Sendable>(_ work: @escaping @Sendable () throws(FileSystemError) -> T) async throws(FileSystemError) -> T
}
```

**Typed-throws trap (compiled).** Inside a `throws(FileSystemError)` closure, a plain `do { try … } catch { … }` binds `error` as `any Error` and fails to compile. Write `do throws(FileSystemError) { … } catch { … }`. The live executor's body is therefore
`do throws(FileSystemError) { continuation.resume(returning: .success(try work())) } catch { continuation.resume(returning: .failure(error)) }`, followed by `try result.get()`. House style: closures passed to `run` are annotated `{ () throws(FileSystemError) -> T in … }`.

**Semantics shared by both conformers** (pinned by a conformance suite that runs against `LiveFileSystem` in a per-test temporary directory and against `FakeFileSystem`):
- `removeItem` on an absent item succeeds (idempotent sweeps). It removes a file, a symlink (without following it) or an *empty* directory; a non-empty directory gives `.notEmpty`.
- `createDirectory` creates one level and succeeds if the directory already exists.
- `read` returns `Data()` at EOF, and `maxLength` ≤ 1 MiB is a precondition.
- `rename(.exclusive)` fails with `.alreadyExists` without touching either name.
- `acquireExclusiveLock` returns `.wouldBlock` while any other holder exists, **including in the same process** (a different open file description).

### 3.3 `LiveFileSystem` (only `Sources/ZTronAssetStorage/FileSystem/LiveFileSystem.swift` touches POSIX or `FileManager`)

| Method | Implementation (compiled at iOS 15.0 and macOS 12.0; no forbidden pattern) |
|---|---|
| `read` | `autoreleasepool { FileHandle(forReadingFrom:) → seek(toOffset:) → read(upToCount:) → close }`. Returns `Data`, so no buffer pointer is involved. The pool is defence in depth: an inline loop on a thread without a pool accumulated **1,285 MiB** over 5×256 MiB *(measured)*. |
| `write` | `open(path, O_WRONLY\|O_CREAT\|O_CLOEXEC\|(O_TRUNC\|O_APPEND), 0o600)` → `FileHandle(fileDescriptor:closeOnDealloc: true).write(contentsOf:)` → `close()`. A `String` argument bridges to `UnsafePointer<CChar>` (immutable), and no `&` is used. |
| `synchronizeFile/Directory` | `open(O_RDONLY[\|O_DIRECTORY]\|O_CLOEXEC)` → `fcntl(fd, F_FULLFSYNC \| F_BARRIERFSYNC)`; on failure fall back to `fsync(fd)` (volumes without support). The decision is a pure function `syncOutcome(fcntlResult:errno:)` so the fallback branch is coverable on macOS. |
| `rename` | `Darwin.rename` / `renamex_np(src, dst, UInt32(RENAME_EXCL))` |
| `removeItem` | `unlink`; on `EPERM`/`EISDIR`, `rmdir`; `ENOENT` counts as success |
| `createDirectory` | `mkdir(path, 0o700)`; `EEXIST` counts as success |
| `contentsOfDirectory` / `itemInfo` | `FileManager.contentsOfDirectory(at:includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])` (10,000 blobs across 256 fan-outs: 52 ms total, about 0.2 ms per unit *(measured)*) |
| `availableCapacity` | `URLResourceValues.volumeAvailableCapacityForImportantUsage` |
| `applyStoreAttributes` | `URLResourceValues.isExcludedFromBackup = true` via `setResourceValues`. On iOS: `FileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])`. On macOS the protection branch is compiled out (`#if os(iOS) \|\| os(tvOS) \|\| os(watchOS) \|\| os(visionOS)`). |
| `acquireExclusiveLock` | `open(path, O_RDWR\|O_CREAT\|O_CLOEXEC\|O_EXLOCK\|O_NONBLOCK, 0o600)` → `StoreLockToken(fd)`; `EWOULDBLOCK` maps to `.wouldBlock` |
| `releaseLock` | `flock(fd, LOCK_UN)`, then `close(fd)` |
| errno mapping | pure function `FileSystemError.posix(_:)` plus `from(_ error: any Error)` (NSPOSIXErrorDomain, `NSUnderlyingErrorKey`, `CocoaError` codes), each unit-tested with every mapped code |

`LiveFileSystem` is a `struct` with no stored state, so it is `Sendable` with no escape.

### 3.4 `FakeFileSystem`: the fault and crash model (owned by WP-H)

**State.** `dirs: [path: Dir]` with `Dir { current: [name: Entry], durable: [name: Entry] }`, `inodes: [id: Inode]` with `Inode { current: [UInt8], durable: [UInt8], mtime }`, a lock table, an op log `[FSOp]` (op, URL, `isMainThread`, unit id), and the attributes applied per URL. Everything sits in one `Mutex<State>`.

**Crash boundaries = every mutation:** `createDirectory`, `write`, `synchronizeFile`, `synchronizeDirectory`, `rename`, `removeItem`, `applyStoreAttributes`, `acquireExclusiveLock`. Queries are not boundaries, because a crash before a query equals a crash after the preceding mutation. `releaseLock` is not a boundary (process death releases locks anyway).

**Configured with** `crashBefore: Int?` (index of the mutation that never happens) and a `CrashMode`:

| Mode | Surviving disk | What it catches |
|---|---|---|
| `processKill` | every applied mutation persists (kernel page cache survives) | logic-ordering bugs; the P-5 window |
| `processKillTornWrite` (only when op k is a `write`) | as above, and op k landed **half** its bytes | torn `index.tmp`, partial staged file |
| `powerLossDropUnsynced` | each directory reverts to its last `synchronizeDirectory` snapshot; each file's data reverts to its last `synchronizeFile` content (never-synced new files are **empty**); unreachable directories vanish | missing fan-out sync before a commit (the probe mutant produced 25 violations); missing root sync |
| `powerLossKeepMetadata` | namespace as applied; file data reverts to its last synced content (a renamed but never-synced file becomes **zero-length**) | missing barrier before a rename (the probe mutant produced 64 violations) |

- Directories are modelled **independently** (pessimistic): a rename between two directories may persist in neither, one or both. A file present under both names is therefore possible after power loss, and recovery must tolerate it; it does, because staging GC removes the second link.
- Model simplification (documented on the type): `.barrier` and `.full` both mark the synced item durable at the call. A real barrier can lose the synced item **together with everything after it**, but that outcome equals "crash before the barrier op", which the enumeration covers. The design never reports an ordered commit as durable to anyone outside the ordering domain (§2.4.1).
- After a crash every further call throws `.io`, the fake reports `crashed == true`, and `survivingDisk()` yields the post-crash state, which seeds a fresh fake for the reopen (with no locks held, as after process death).

**Faults** (independent of crashes): `FaultRule(op: FSOpKind, matching: URLMatcher, occurrence: Occurrence (.nth(n) | .every | .afterBytes(n)), error: FileSystemError, partialBytes: Int? = nil)`:
- ENOSPC: `write` throws `.noSpace`. With `partialBytes`, the first n bytes landed first (a short write).
- EIO: any op throws `.io`, e.g. on `rename` or `read`.
- EACCES: `.permissionDenied`, e.g. on `createDirectory` of the root ("protected data unavailable before first unlock").
- Rename failure: `.crossDevice` (exercises the copy fallback) or `.io`.
- Partial write: `.noSpace` after `partialBytes`.
- `availableCapacity` is scriptable.

**Recording.** For R-STO-7 every call records `isMainThread` (sync context, so `Thread.isMainThread` is allowed). `applyStoreAttributes` calls are recorded (R-STO-8). The op log feeds the `OrderingAuditor`.

**Determinism.** `mtime` comes from an injected `TimeSource`, and there is no real clock. The store's own staging names come from the seeded `RandomSource`.

### 3.5 Test fakes and the 3-escape budget (target: 0 escapes)

- `FakeFileSystem` and `FakeLegacyDefaults` are `final class … : Sendable` whose only stored property is `let state: Mutex<State>`, carrying `@available(macOS 15.0, iOS 18.0, *)`. `Mutex` is `Sendable`, so no `@unchecked` is needed.
- **Verified trap.** Swift Testing (this toolchain) rejects `@available` on any `@Suite`, and rejects multi-platform `@available(macOS 15.0, iOS 18.0, *)` on a `@Test`: *"Attribute 'Test' cannot be applied to this function because it has been marked '@available(…)'"*. A single-platform `@available(macOS 15.0, *)` on a `@Test` compiles and runs, and so does a body `#available` guard.
- **Decision (ADR-014): availability funnel.** `ZTronAssetTestSupport` exposes an unannotated protocol `FakeFileSystemControl: FileSystem` (crash and fault control, op log, `survivingDisk()`). It also exposes `func makeFakeFileSystem(…) -> any FakeFileSystemControl`, which does `if #available(macOS 15.0, iOS 18.0, *) { return FakeFileSystem(…) }` and otherwise `preconditionFailure("ZTronAssetTestSupport needs Synchronization.Mutex (macOS 15 / iOS 18)")`. Test suites stay unannotated. The `else` branch lives in TestSupport, which is excluded from coverage. Test targets are never compiled for iOS (`verify.sh` builds only the `ZTronAssetKit` scheme for iOS), and TestSupport compiles for iOS 15 thanks to the gate *(compiled via xcodebuild, §10)*.

---

## 4. The `AssetStore` actor

### 4.1 Value types

```swift
/// 32 raw SHA-256 bytes as four words: no heap, cheap `Hashable`. Hex only at the edges.
/// (If WP-A's Model already defines a checksum type, the store uses that one; it must be a fixed-size value.)
public struct ContentHash: Hashable, Sendable { /* w0…w3: UInt64; init(digest: SHA256.Digest); init?(hex:); var hex: String */ }
/// Validated, lowercased blob extension, `[a-z0-9]{1,8}` (R-SEC-2).
package struct BlobExtension: Hashable, Sendable { package let rawValue: String; package init?(_ raw: String) }
/// A blob's identity = its file name.
package struct BlobKey: Hashable, Sendable { package let hash: ContentHash; package let ext: BlobExtension }

package enum Residency: Sendable, Equatable {
    case absent(AbsenceReason)                               // .neverFetched, .evicted, .purged, .healing
    case present(blob: BlobKey, byteSize: Int64, verified: Bool)
    case needsHeal(lastBlob: BlobKey)                        // I-2: blob vanished (OS purge, external deletion)
    case quarantined(until: Date)                            // R-CLN-8 / R-INT-3 backoff
    case failed(FailureReason)                               // .integrity, .unreadable; until the entry changes
}
package struct IntegrityHistory: Sendable, Equatable {       // R-INT-3; persisted, so it survives relaunch (D-16)
    package var attempts: UInt8; package var failedChecksum: ContentHash?; package var nextEligibleAt: Date?
}
package struct AssetRecord: Sendable, Equatable {
    package var entry: ManifestEntry                         // WP-A's validated entry (all 7 legacy fields plus tags and policy)
    package var residency: Residency
    package var expectedBlob: ContentHash?                   // entry.checksum ?? legacy plannedHash (adoption key, §2.6)
    package var lastAccess: Date; package var storedAt: Date?; package var verifiedAt: Date?
    package var pinned: Bool
    package var integrity: IntegrityHistory
    // derived: isStale = residency.present(k) where k.hash != expectedBlob (content update in flight)
}
```

### 4.2 API (exact signatures; `package` access: visible to Sync, the facade and tests, not to apps; compiled in the probe package)

```swift
package actor AssetStore {
    /// No I/O (P-12): stores configuration and environment only.
    package init(configuration: StoreConfiguration, environment: StoreEnvironment)

    // MARK: Lifecycle
    /// Lock, load, migrate, reconcile, commit, publish the first snapshot (§2.6). Other APIs await it.
    package func open() async throws(StoreError) -> OpenReport
    /// Forces a commit now (still respecting the 4/s limit) at the given durability.
    package func flush(_ durability: CommitDurability = .durable) async throws(StoreError)
    /// Durable flush, cancels store-owned tasks, releases the lock. Every later call throws `.closed`.
    package func close() async

    // MARK: Reads (no I/O)
    package var currentSnapshot: AssetSnapshot { get }
    package func planningView() -> StorePlanningView                     // immutable records, stamps, integrity (CoW, O(1))
    package func syncStamp() -> SyncStamp                                // lastSyncedAt, lastSyncedAppVersion, syncDue, ETag
    package func location(for id: AssetID, recordingAccess: Bool) -> AssetLocation?   // resolve fast path
    package func availability(of scope: AssetScope) -> AvailabilityCounts

    // MARK: Manifest (reconcile-before-download, R-SYN-8)
    /// Applies relocations, removals (prune → doomed) and content changes (stale), adopts by hash,
    /// clears `degraded`, and returns only after a **committed** generation that records the manifest.
    package func apply(_ manifest: ValidatedManifest, etag: String?) async throws(StoreError) -> ApplyReport
    package func markSynced(appVersion: String) async throws(StoreError)
    package func markSyncDue() async throws(StoreError)

    // MARK: Staging and publication
    /// Reserves `staging/<UUID>.part|.resume` and claims it; the transport writes or moves bytes there.
    package func reserveStaging(for id: AssetID) throws(StoreError) -> StagingReservation
    package func releaseStaging(_ reservation: StagingReservation) async
    /// Size check → streaming hash → verify → barrier → RENAME_EXCL. The expectation comes from the record,
    /// never from the caller (R-INT-6). Returns the URL immediately; the commit is coalesced (§4.6).
    package func publish(_ reservation: StagingReservation, for id: AssetID) async throws(StoreError) -> AssetLocation
    package func collectStaging(keeping claimed: Set<StagingID>) async throws(StoreError) -> CleanupResult

    // MARK: Access, leases, pins
    package func recordAccesses(_ ids: [AssetID])
    package func acquireLease(_ id: AssetID) throws(StoreError) -> AssetLease          // .notPresent if absent
    package func releaseLease(_ lease: AssetLease)                                     // idempotent per token
    package func setPinned(_ ids: Set<AssetID>, _ pinned: Bool) async throws(StoreError)

    // MARK: Cleanup (R-CLN-*); each idempotent and cancellation-safe
    package func makeRoom(forAdditionalBytes bytes: Int64) async throws(StoreError) -> SpaceReport   // dry run, then evict
    package func evictIfNeeded() async throws(StoreError) -> CleanupResult
    package func collectGarbage() async throws(StoreError) -> CleanupResult                          // orphan GC
    package func purge(_ request: PurgeRequest) async throws(StoreError) -> PurgeResult
    package func reportUnreadable(_ id: AssetID) async throws(StoreError)
    package func verifyIntegrity(byteBudget: Int64) async throws(StoreError) -> VerificationReport  // R-INT-4 (SHOULD)
    package func storageReport() async -> StorageReport
    package func metrics() -> StoreMetrics
}

package struct StoreConfiguration: Sendable {
    package var location: StorageLocation                // .applicationSupport (default) | .caches | .custom(URL)  (R-STO-10)
    package var policy: StoragePolicy                    // §6.0
    package var legacy: LegacyLayout?                    // nil disables migration (§7)
    package var allowUnverifiedAssets: Bool = true       // R-INT-5
    package var commitMinimumInterval: TimeInterval = 0.25   // P-5: ≤ 4 commits/s
    package var deletionBatchSize: Int = 64              // P-13
    package var hashChunkBytes: Int = 1 << 20            // R-INT-1 (precondition ≤ 1 MiB)
}
package struct StoreEnvironment: Sendable {
    package var fileSystem: any FileSystem
    package var metadataExecutor: any BlockingExecutor  // commits, renames, unlinks, listings
    package var bulkExecutor: any BlockingExecutor      // hash and copy reads (a 256 MiB hash never delays a commit)
    package var time: any TimeSource                    // wall clock (persisted stamps) + monotonic instant (grace) + sleep(until:)
    package var random: any RandomSource                // storeID, staging UUIDs
    package var snapshotSink: any SnapshotSink
    package var legacyDefaults: any LegacyDefaults
    package var events: any StoreEventSink              // non-blocking; bounded downstream (WP-F, H-9)
}
package enum StoreError: Error, Sendable, Equatable {
    case locked, closed, cancelled
    case fileSystem(FileSystemError)
    case insufficientSpace(required: Int64, available: Int64)
    case integrity(IntegrityFailure)                    // .sizeMismatch(expected:actual:), .checksumMismatch(expected:actual:)
    case unverifiedRejected(AssetID)                    // R-INT-5
    case unknownAsset(AssetID), notPresent(AssetID), superseded(AssetID)
    case assetFailed(AssetID, FailureReason)
    case storageUnavailable(StorageUnavailableReason)   // .protectedDataUnavailable, .rootVanished, .degradedReadOnly
}
```
Typed throws on actor methods are compile-time only (ADR-004) and typechecked at the iOS 15 floor in the probe. `CancellationError` never escapes; it is mapped to `.cancelled`. The facade maps `StoreError` to `AssetError` (R-CAR-7).

### 4.3 `AssetSnapshot` and the main-actor mirror (R-STO-13)

```swift
package struct AssetSnapshot: Sendable {
    package let version: UInt64                         // strictly increasing per store instance
    package let indexGeneration: UInt64                 // diagnostics
    let blobsRoot: URL
    let entries: [AssetID: SnapshotEntry]               // present (incl. stale) assets only — I-4 by construction
    package static let empty: AssetSnapshot
    /// O(1): one dictionary probe plus case-insensitive extension match, then URL = blobsRoot/aa/hex.ext.
    package func location(for id: AssetID, extensions: [String]) -> AssetLocation?
}
package struct SnapshotEntry: Sendable, Hashable { let blob: BlobKey; let byteSize: Int64; let flags: Flags /* verified, stale, essential */ }
public struct AssetLocation: Sendable, Hashable { public let id: AssetID; public let url: URL; public let byteSize: Int64; public let isVerified: Bool; public let isStale: Bool }
```
- **Cheap at 10,000 entries.** The actor maintains `presentTable: [AssetID: SnapshotEntry]` incrementally next to `records`. Publishing wraps it, which is O(1) because storage is shared. The first mutation after a publication pays one copy-on-write copy, **0.14 ms** at 10,000 entries *(measured)*. A full rebuild (at open) is 0.88 ms *(measured)*. Lookup, including URL construction, is p50 2.4 µs / **p99 2.75 µs** *(measured; P-1 budget 25 µs)*. A persistent HAMT was rejected: slower lookups, much more code, and no need at these costs.
- **Mirror (facade target, WP-G):** `@MainActor final class SnapshotMirror { private(set) var current: AssetSnapshot; private var accessLog: BoundedAccessLog }`.
  - `install(_ s) -> [AssetID]` assigns `current = s` only if `s.version > current.version` (out-of-order delivery is ignored), then drains and returns the access log.
  - `lookup(id, extensions)` reads `current` and appends hits to the access log (capacity 1,024 distinct ids; overflow drops the oldest). It does no I/O and takes no locks.
- **Sink contract:** `package protocol SnapshotSink: Sendable { func install(_ snapshot: AssetSnapshot) async -> [AssetID] }`. The live sink is `await mirror.install(s)`. The store treats the **return** as the acknowledgement (H-2) and feeds the returned ids to `recordAccesses`. LRU therefore learns about synchronous lookups without timers or polling (P-14). Before eviction the store re-installs the current snapshot (the same version, so it is a no-op swap) purely to drain accesses.
- Publication cadence: after every mutating API call (one install per publish, or per reconciliation chunk). Coalescing at ≤ 10 Hz is an allowed optimisation if P-8 needs it.

### 4.4 Leases, pins, grace

- **Lease** = `package struct AssetLease: Sendable, Hashable { let id: AssetID; let blob: BlobKey; let token: UInt64; package let url: URL }`, kept in memory as `leases: [BlobKey: [UInt64: AssetID]]`. Acquiring a lease bumps `lastAccess` and does not await, so there is no window. The facade's `withAsset` acquires, runs the body, and releases on both the success and error paths (no `await` in `defer`). Leases die with the process.
- **Pins**: `record.pinned`, persisted, set through `setPinned`. **Essential** comes from `entry.policy == .essential`. Neither is ever evicted. Only `purge(.all)` and `purge(.scope)` remove them, because the user asked for it.
- **Grace**: `deletionGrace` (default 10 s) is measured from the acknowledgement instant on the **monotonic** clock, so wall-clock changes cannot shorten it. Eviction also skips anything accessed within `max(minimumResidency, deletionGrace)` (R-CLN-4, R-CLN-5).

### 4.5 How I-3 is guaranteed: the blob table and the reaper

`blobTable: [BlobKey: BlobState]` with
`live(refCount)` · `doomed(DoomInfo)` · `deleting(batch: Task<Void, Never>)` · plus `publishingKeys: Set<BlobKey>` (keys whose rename unit is in flight).

```
deref(k):  refCount -= 1; if 0 → doomed(DoomInfo(sinceVersion: nextSnapshotVersion, droppedInGeneration: nextGeneration, eligibleAt: nil))
install acknowledged(v, at t):  for doomed k with sinceVersion ≤ v ∧ eligibleAt == nil → eligibleAt = t + deletionGrace
deletable(k) ⇔ doomed(d) ∧ d.eligibleAt ≤ monotonicNow ∧ committedGeneration ≥ d.droppedInGeneration ∧ leases[k] == ∅ ∧ k ∉ publishingKeys
reapEligible():  K = first 64 deletable keys → mark each .deleting(task) on the actor (synchronously) → await metadata unit { removeItem ×64 }
                 → remove K from blobTable → doomedNeedsPruning = true (a lazy commit drops them from DOOMED)
```
- The **reaper** is a store-owned task that exists only while `doomed` is non-empty. It sleeps until the earliest `eligibleAt` via `TimeSource.sleep(until:)` and is cancelled by `close()`. It is idle-silent, so with nothing pending it has no task and no timer (P-14). `purge()` calls `reapEligible()` itself after waiting out the grace period, so its caller gets "bytes freed".
- **Rescue and dedupe.** Publishing key k: `live` → refCount += 1 and the staged duplicate is removed. `doomed` → back to `live(1)`, deletion cancelled, staged duplicate removed. `deleting` → await that batch task, then re-evaluate (REENTRANCY R3).
- **Crash.** Doomed keys are in the committed generation's DOOMED section, so the next launch deletes them (§2.6 7a). If the crash came before that commit, the older generation still references the blob, so nothing is lost and the deletion simply has not happened yet. That is idempotent.

### 4.6 Commit scheduling (P-5)

State: `dirtyLevel ∈ {none, lazy, soon}`, `lastCommitInstant`, `inFlight: Task?`, `deferred: Task?`, `committedGeneration`, `dirtyDirectories`.
- `lazy` (access times and DOOMED pruning only) never schedules a commit; it rides along with the next one or with `flush()`/`close()`.
- `soon` (publish, quarantine, pins) schedules exactly one deferred task, which wakes at `max(now, lastCommitInstant + 0.25 s)` on `TimeSource`.
- `requireCommitted(generation g, durability)` is used by `apply`, deletion paths, `markSynced`, migration and `flush`. It loops: if `committedGeneration ≥ g` with sufficient durability, return; otherwise, if a commit is in flight, await it; otherwise, if inside the interval, `sleep(until:)`; otherwise `commitNow()`.
- `commitNow()` captures `let state = indexState` (a CoW value, O(1)) and `dirtyDirectories`, and runs **one metadata unit** (encode, then §2.4.1). The actor keeps serving calls in the meantime, and mutations made during the unit belong to the next commit.
- **P-5 check:** the commit unit measured p50 11.3 ms (ordered) / 16.0 ms (durable) at 10,000 records, against a budget of 40 ms. The rate is ≤ 4 per second **by construction**, proven on a `ManualTimeSource` (§9).

### 4.7 Advisory lock (R-STO-9)

- `store.lock` is opened with `O_EXLOCK|O_NONBLOCK`, which takes the lock atomically with the open and has `flock` semantics: the lock belongs to the *open file description*.
- Consequences *(runtime-verified)*:
  - A second open in the **same process** fails with `EWOULDBLOCK`, so two `AssetClient`s on one root are detected.
  - Another process fails the same way.
  - `SIGKILL` of the holder releases the lock (the kernel closes the descriptor).
  - `flock()` and `O_EXLOCK` conflict with each other.
  - POSIX `fcntl(F_SETLK)` locks were rejected: they are per-process (a same-process double open would go undetected) and are dropped when *any* descriptor to the file closes.
- **Deterministic fail, not queue.** `open()` throws `StoreError.locked` immediately. A queueing variant would have to poll (blocking `flock` cannot be cancelled), which contradicts "no polling" and is still non-deterministic. A second client is a programming or configuration error; the facade surfaces `storageUnavailable` and the app decides.
- The module never deletes `store.lock`, including under `purge(.all)`. Before each commit the unit does `itemInfo(store.lock)` (one stat). If the root vanished while running, the store enters `storageUnavailable(.rootVanished)` and asks the facade to reopen.
- **App Group warning (risk R6).** A file lock held in a *shared* container while the app is suspended gets the app terminated (0xdead10cc). The default root is the app's own Application Support, so this does not apply by default. A `.custom` App Group root is documented as unsupported unless the app closes the client on backgrounding.

### 4.8 Protection and backup attributes (R-STO-8)

- `applyStoreAttributes(StoreAttributes(excludedFromBackup: true, protection: .completeUntilFirstUserAuthentication), at: root)` runs at open, and again on `blobs/` and `staging/` when they are created.
- New files inherit the directory's protection class on iOS *(hint: verify on device; listed in `DEVICE-TEST-PLAN.md`)*. Backup exclusion on a directory covers its contents.
- At every open `storeAttributes(at: root)` is compared with the expected values and re-applied if needed (for example after a restore).
- The fake records each application, so tests assert the exact values. On macOS `protection` is `nil` (not applicable).
- Before first unlock, the root's protection class makes `open()` fail with `.permissionDenied`, which maps to `storageUnavailable(.protectedDataUnavailable)` with no partial mutation (risk R5).

### 4.9 REENTRANCY ledger for the store (H-5; each becomes a `// REENTRANCY:` comment)

| # | Await | Re-validated after resumption |
|---|---|---|
| R1 | units inside `open()` | `phase == .opening`; other APIs await `openTask`, so nothing interleaves except store-owned work |
| R2 | hash units in `publish` | the record still exists; its entry revision is unchanged (otherwise compare the digest with the *new* expectation, or `.superseded`); the store is not closed |
| R3 | awaiting a `.deleting` batch in `publish` | re-read `blobTable[k]` (now absent, so publish normally) |
| R4 | rename unit in `publish` | does some record still expect `k`? If not, doom `k` immediately (it was never in a snapshot, so no grace is needed, only the commit ordering). Remove `k` from `publishingKeys`. |
| R5 | commit unit | `committedGeneration = max(…)`; mutations made meanwhile stay dirty; on failure restore `dirtyDirectories` |
| R6 | `sink.install` | `ackedVersion = max(ackedVersion, v)`; set `eligibleAt` for the newly covered doomed keys; merge accesses |
| R7 | deletion unit | the `.deleting` keys are gone; resume waiting publishers |
| R8 | `Task.yield()` between eviction and reconciliation chunks | per candidate: still present, unleased, not accessed since selection, still evictable; skip otherwise |
| R9 | `TimeSource.sleep` (deferred commit, reaper, purge grace) | recompute dirty and deletable state from scratch; the timer only "pokes" |
| R10 | listing units in `collectGarbage` | the sweep set is computed **after** the listing, against `blobTable ∪ publishingKeys` at sweep time, and orphans must have `mtime < now − orphanGrace` |
| R11 | migration units (§7) | the file still exists and its blob is still absent (each file step is idempotent) |

---

## 5. Integrity (R-INT-1…6)

### 5.1 Streaming SHA-256 (R-INT-1) without mutable pointers

```swift
func streamingSHA256(of url: URL, fileSystem: any FileSystem, executor: any BlockingExecutor,
                     chunk: Int = 1 << 20) async throws(StoreError) -> (digest: ContentHash, byteCount: Int64) {
    var hasher = SHA256()                       // CryptoKit `SHA256: Sendable` (SDK .swiftinterface:307)
    var offset: Int64 = 0
    while true {
        if Task.isCancelled { throw .cancelled }            // cancellation between units, no shared flag
        let current = hasher, start = offset
        let (next, count) = try await run(executor) { () throws(FileSystemError) -> (SHA256, Int) in
            var h = current
            let data = try fileSystem.read(from: url, offset: start, maxLength: chunk)   // ≤ 1 MiB, Data
            h.update(data: data)
            return (h, data.count)
        }
        hasher = next; offset += Int64(count)
        if count < chunk { break }
    }
    return (ContentHash(digest: hasher.finalize()), offset)
}
```
- Bytes arrive as `Data` from `FileHandle.read(upToCount:)` (iOS 13.4+, compiled at iOS 15). Neither `withUnsafeMutable*` nor `UnsafeMutable(Raw)Pointer` nor inout-to-pointer `&` is used. `SHA256.update(data:)` takes `DataProtocol`.
- The 32-byte comparison works on the `ContentHash` words, so no `withUnsafeBytes` is needed either.
- The unit runs on the **bulk** executor, off the cooperative pool. Each unit takes about 0.4 ms at the measured throughput, well under the ~10 ms C2 bound.
- **P-6 *(measured, release, 256 MiB, page-cache warm, fresh process per variant)*:** one-shot `SHA256.hash(data:)` = 3124 MB/s. **Design = 2539 MB/s, which is 0.81× one-shot** (floors: ≥ 800 MB/s and ≥ 0.7×). **Peak RSS delta = 1.77 MiB** (cap 4 MiB).
- A pipelined variant (the next read overlapping the current hash on two queues) reached 2781 MB/s = 0.89× with an RSS delta of 2.91 MiB. It is held in reserve if device numbers come in low; it is not needed on this Mac.
- On-device throughput is **not verified** (risk R2).

### 5.2 Size-first verification (R-INT-2, R-NET-7)

`publish` first compares `itemInfo(.part).byteSize` with `entry.byteSize` when known (never with `Content-Length`). It also rejects anything above `maxAssetBytes`. On mismatch it removes the staged bytes, records the integrity failure, increments `metrics.integrityFailures[.size]`, and throws `.integrity(.sizeMismatch)` **without hashing**. A checksum mismatch takes the same path with `.checksumMismatch(expected, actual)`. Nothing is renamed into `blobs/` before both checks pass.

### 5.3 Publish flow (consolidated)

```
publish(reservation, id):
  r = records[id] ?? throw .unknownAsset; E = (r.entry.byteSize, r.entry.checksum, r.revision)
  size check (§5.2) → hash units → REENTRANCY R2
  if E.checksum: digest == E.checksum ? ok : fail(.checksumMismatch)
  else if !allowUnverifiedAssets: fail(.unverifiedRejected)                       // R-INT-5
  k = BlobKey(digest, r.ext)                                                      // R-INT-6: our digest, never the claim
  switch blobTable[k]: live/doomed → dedupe or rescue (remove .part) | deleting → await (R3) and retry | nil →
      publishingKeys.insert(k); metadata unit { syncFile(.part,.barrier); createDirectory(fan-out); rename(.part→blob,.exclusive) (EEXIST → removeItem(.part)) }  → R4
  records[id].residency = .present(k, size, verified: E.checksum != nil); integrity = .clean; storedAt = lastAccess = now
  deref(previous blob, if any); dirtyDirectories ∪= {fan-out[, blobs/]}; markDirty(.soon); publish snapshot (await, R6)
  return AssetLocation(url: StoreLayout.blobURL(k), …)
```

### 5.4 Repeated mismatches (R-INT-3)

- On each integrity failure for record r with expected checksum C: if `r.integrity.failedChecksum != C`, reset `attempts` to 0 and set `failedChecksum = C`. Then `attempts += 1`.
  - `attempts < maxIntegrityAttempts` (default 3): `residency = .quarantined(until: now + base × multiplier^(attempts−1))` (defaults 60 s, ×10), and `nextEligibleAt` is set.
  - Otherwise: `residency = .failed(.integrity)`.
- The bookkeeping is persisted in RECORDS, so a relaunch cannot restart the loop (prior-art D-16).
- **Reset** happens only when `apply(manifest:)` changes that entry's `checksum`, `remotePath` or `byteSize` ("until its manifest entry changes"), or on a successful publish.
- The engine reads `nextEligibleAt` from `planningView()` and never fetches earlier. The store also rejects early publishes for a failed entry with `.assetFailed`.

### 5.5 Checksum-less entries (R-INT-5) and the recorded checksum (R-INT-6)

- Checksum-less entries are admitted only when `allowUnverifiedAssets` (default true). They carry `verified: false` in their record, snapshot entry, `AssetLocation.isVerified`, `availability` and `storageReport`.
- The recorded `blob.hash` is always our digest of the bytes that were renamed into place (the same inode). The publish API takes no checksum parameter, so the caller cannot supply a claim. A test feeds a manifest whose checksum differs and asserts the record holds the real digest, or that the publish was rejected.

### 5.6 Deep verification (R-INT-4, SHOULD, implemented)

`verifyIntegrity(byteBudget:)` resumes from the oldest `verifiedAt`, hashes present blobs until the budget is spent, and routes any mismatch to the §6.6 quarantine path. It is called from `performMaintenance` (R-SYN-16).

---

## 6. Cleanup (R-CLN-1…12)

### 6.0 `StoragePolicy` defaults (ADR-015, NEEDS-HUMAN-REVIEW)

| Field | Default | Note |
|---|---|---|
| `budget` | `.fractionOfFreeSpace(0.5)`, computed as `0.5 × (storeUsage + availableCapacity)` | `.bytes(n)` and `.unlimited` are selectable |
| `reserveFreeBytes` | 256 MiB | also the ENOSPC guard for commits |
| `hysteresisTarget` | 0.90 | evict down to 90 % of budget |
| `minimumResidency` | 24 h | |
| `deletionGrace` | 10 s | |
| `orphanGrace` | 1 h | |
| `stagingMaxAge` | 72 h | |
| `maxIntegrityAttempts` / base / multiplier | 3 / 60 s / ×10 | |
| `deletionBatchSize` | 64 | P-13 |

### 6.1 Prune (R-CLN-1)

Prune is part of `apply(manifest:)`, which preserves reconcile-before-download (R-SYN-8):
- **Removed entries:** the record is deleted and `deref(blob)` is called.
- **`metadataChanged`** (path, directory, name, tags, policy): only the record's `entry` is updated. There is **no file operation** because the layout is content-addressed (fixes D-10). A directory change costs zero downloads and zero renames.
- **`contentChanged`:** the entry is updated and the residency stays `present(oldBlob)`, which is now `stale`. Stale entries keep being served by `lookup`, as in the prior art, until the new blob is published. Integrity history resets.
- **`added`:** a record is created with `absent(.neverFetched)`.
- Then adoption by hash (§2.6 7c), `degraded = false`, **commit**, publish the snapshot. Deletions follow later through the reaper once the grace window and leases allow (R-CLN-5).

### 6.2 Orphan GC (R-CLN-2): mark and sweep

- **Mark** = referenced blobs ∪ doomed ∪ `publishingKeys` ∪ claimed staging.
- **Sweep**, after listing (256 units; REENTRANCY R10):
  - blobs that are not marked, have `mtime < now − orphanGrace` and the store is not `degraded` are added to doomed with `eligibleAt = now`;
  - staging files that are unclaimed and older than `stagingMaxAge`, or unparseable, are removed.
- The pass is idempotent and crash-safe because it is the same path as doomed deletion.

### 6.3 Staging GC (R-CLN-3)

- At launch, §2.6 7d runs.
- After every sync the engine calls `collectStaging(keeping: claimed)`, which removes every unclaimed `.part`/`.resume`. This fixes D-7: nothing goes to `tmp` and nothing leaks.

### 6.4 Quota eviction (R-CLN-4, R-CLN-5)

```
evictIfNeeded():
  drain accesses (re-install the current snapshot)
  liveBytes = Σ size(live blobs); budgetBytes = policy.budget.resolve(liveBytes, availableCapacity)
  trigger  = liveBytes > budgetBytes ∨ availableCapacity < reserveFreeBytes
  target   = min(hysteresis × budgetBytes, liveBytes − max(0, reserveFreeBytes − availableCapacity))
  candidates = live blobs k where every record r referencing k: ¬essential ∧ ¬pinned
               ∧ leases[k] == ∅ ∧ now − r.lastAccess ≥ max(minimumResidency, deletionGrace)
  key(k)   = (max lastAccess over its records ↑, size ↓, hash ↑)            // LRU; ties larger first; total order ⇒ deterministic
  choose the prefix until liveBytes − Σ ≤ target; mark in chunks of 1,000 (R8): records → absent(.evicted), deref
  publish → commit (ordered) → the reaper deletes after acknowledgement and grace
  shortfall (protected bytes exceed budget) → event .evictionShortfall(bytes); never evict protected content
```
- `makeRoom(forAdditionalBytes:)` (R-SYN-11) first runs a dry run: it computes what eviction could free without mutating anything. If that is not enough, it throws `.insufficientSpace(required, available)` with **no side effects**; otherwise it evicts.
- Evicted records stay in the index (the manifest still lists them), so `availability` reports them as missing and `resolve` refetches lazily.
- **Cross-WP note (WP-F):** the planner must not bulk-refetch `standard` assets beyond the budget, or the store would thrash.

### 6.5 Purge (R-CLN-6)

`purge(.all | .evictable | .scope(AssetScope))` proceeds as follows:
1. Select records: all / evictable now (not essential, pinned or leased) / scope matches. Scope is evaluated with WP-A's pure function.
2. Records become `absent(.purged)` and blobs are dereferenced. For `.all`, also `lastSyncedAt = nil` and `syncDue = true` (a sync is due afterwards).
3. Publish, then a **committed** generation.
4. `sleep(until: ack + grace)`, then `reapEligible()` until the selection is gone.
5. Return `PurgeResult(bytesFreed, bytesDeferred /* leased; deleted on release */, assetsRemoved)`.

Purge keeps `store.lock`, the root and the manifest records. The persisted DOOMED section makes a purge interrupted by a crash **finish** at the next launch instead of re-adopting the purged blobs (doomed always beats adoption, §2.6 7a).

### 6.6 Corruption quarantine (R-CLN-8)

`reportUnreadable(id)`:
- Every record referencing the same blob is quarantined through the §5.4 bookkeeping (backoff, eventually failed).
- The blob is dereferenced, so it is deleted after acknowledgement, grace and leases.
- An event is emitted and `markDirty(.soon)` is set.
- A second call for an already quarantined id is a no-op.
- The engine re-downloads once `nextEligibleAt` passes.

### 6.7 ENOSPC and EIO in the store itself

- **A commit failing with ENOSPC** keeps the previous generation (§2.4.1). The store then frees only what needs no commit: blobs that are *already* doomed in a committed generation, plus unclaimed staging. It retries at the next interval.
- While commits keep failing:
  - `publish` and `apply` throw `.insufficientSpace` (or `storageUnavailable(.degradedReadOnly)` after N failures);
  - `lookup` keeps working from the last snapshot;
  - no deletion happens that would require a newer generation.

### 6.8 P-13 batching

- Marking runs on the actor in chunks of ≤ 1,000 blobs, each ≤ ~1.5 ms, with `Task.yield()` between chunks.
- Unlinks run in metadata units of 64 *(measured: 10,000 blobs reclaimed in 359 ms total; max unit 2.87 ms; max actor-side gap between suspension points 0.004 ms. Batches of 128 reached a 5.42 ms max unit, so 64 it is.)*
- One commit unit (~11 ms) runs in between. Budget: total ≤ 2 s, batches ≤ 5 ms.
- The benchmark sets `deletionGrace = 0` on a `ManualTimeSource`, so the grace wait never counts toward the time measured.

### 6.9 Idempotency and cancellation (R-CLN-12)

| Operation | Second run | Cancelled at any suspension point leaves |
|---|---|---|
| prune (`apply`) | the same manifest gives an all-`unchanged` diff, so no mutation and no commit | either the old generation (before the commit) or the new one; doomed keys are reaped later |
| orphan GC | the marked set is unchanged, so nothing is unmarked | a partial listing has no effect, because the sweep only happens after the full listing |
| staging GC | nothing unclaimed remains | removed files stay removed; the rest is collected next time |
| eviction | below target, so nothing is chosen | a chunk-consistent state: each marked blob is fully doomed, unmarked ones untouched |
| purge | the selection is empty, so 0 bytes | records already absent; the reaper (or the next launch, through DOOMED) finishes |
| quarantine | already quarantined, so no-op | either before (no change) or after (complete), with no await in between |
| reaper | `removeItem` of an absent file succeeds | keys in `.deleting` complete in their unit (units are never interrupted), so the state is exact |

The caller's cancellation never cancels a store-owned unit already submitted. Units are atomic, and the actor applies their result.

### 6.10 Not owned here

- **R-CLN-10 (SHOULD), release of the Apple-pack duplicate.** Owned by WP-E (H-7). The store's part is only the adoption path: the pack file is renamed or copied into a `StagingReservation`, then `publish` runs. After that returns, WP-E may release the pack when policy allows.
- **R-CLN-11 (MAY).** RECON §4 found no carousel caches, so this is a facade-level protocol hook (WP-G) with no storage involvement.

---

## 7. Legacy migration (R-STO-11, H-10)

**Detected inputs** (exact names from RECON §5 and the prior-art source):
- `LegacyLayout.root`, default `<Caches>/CDNAssets`, resolved via `standardDirectory(.caches)` + `"CDNAssets"`. It is overridable because the prior art allowed `baseDirectory:`.
- `manifest.json`: a bare JSON array of `CDNAsset`. `localPathComponents` is required; the other optional fields may be absent.
- `local-checksums.json`: `[identifier: lowercase-hex SHA-256]`. Values that are not 64 hex characters are ignored, because the prior art allowed a custom `computeChecksum`.
- `UserDefaults` key `ZTronCarouselCore.CDNSyncCoordinator.lastSyncedVersion`, value `"<CFBundleShortVersionString>+<CFBundleVersion>"`. The suite is `.standard` by default, overridable because the prior art took `defaults:`.

**Injectable `UserDefaults` (tests never touch real defaults):**
```swift
package protocol LegacyDefaults: Sendable {
    func string(forKey key: String) -> String?
    func removeValue(forKey key: String)
}
/// Stores only the suite name (a String), so it is Sendable without wrapping a non-Sendable `UserDefaults`
/// (compiled: "stored property … of 'Sendable'-conforming struct … has non-Sendable type 'UserDefaults'").
/// Called only inside units, because the first access may do I/O.
package struct LiveLegacyDefaults: LegacyDefaults { let suiteName: String? }
```
The fake is `FakeLegacyDefaults` (a `Mutex` dictionary, behind the §3.5 funnel).

**Legacy path rule.** It reproduces `CDNLocalStore.localURL(for:)` exactly (RECON §5):
- directories = `localPathComponents` if non-empty, else `identifier.split(".").dropLast()`;
- file name = `localFileName ?? identifier.split(".").last ?? identifier`;
- path = `root/dirs…/name.ext`.

R-SEC-2 / D-14 hardening: every component must be non-empty, not `.` or `..`, free of `/` and NUL, and ≤ 255 bytes. The standardized path must have `root` as a prefix. Symlinks are never followed. A failing entry is dropped; its file, if any, is removed in phase 4 only if it lies inside `root`.

**Algorithm.** The phase is persisted in STAMPS.`legacyState`.
```
migrateIfNeeded()  [inside open(), before reconciliation step 7]:
  if legacyState == done: if root exists → phase 4; if key exists → remove key; return          // crash after "done"
  stamp = defaults.string(forKey:)  [unit];  exists = itemInfo(root) is a directory  [unit]
  if ¬exists: if stamp != nil → remove key (files gone ⇒ never migrate the stamp: D-6); return
  if legacyState == none:                                   // Phase 1: plan (reads only, plus one committed generation)
     manifest = read manifest.json (≤ 32 MiB, 1 MiB units) → WP-A legacy decode/validate. Duplicate ids (D-13): keep
                the first and drop the rest. Undecodable → no records; files are hashed-and-moved as protected orphans
                (rejected alternative C as the degraded path; degraded = true).
     checksums = read local-checksums.json (bounded; invalid values ignored)
     for valid entries e with a legacy file L:
        expected = e.checksum ?? checksums[e.id]  (64 hex)  ?? (plannedHash = streamingSHA256(L))   // hash only checksum-less files
     merge into records: legacy entries fill ids the index lacks and never override newer state; residency = absent;
        expectedBlob = expected; legacyState = inProgress; legacyStamp = stamp
     commit (ordered)         ← crash before: nothing moved; restart from scratch
  Phase 2 (per file, idempotent; publish snapshot every 64 adoptions so lookups start hitting):
     k = BlobKey(r.expectedBlob, r.ext)
     if k on disk / in blobTable → r present; removeItem(L) if it still exists        // resumed after crash, or dedupe
     else if L exists: d = streamingSHA256(L)   (re-hash: verifies the file is what was planned)
          d != expected → drop (L removed in phase 4)
          d == expected → [metadata unit] syncFile(L,.barrier); createDirectory(fan-out); rename(L → blob,.exclusive)
                          (EXDEV → copy into staging in 1 MiB units, barrier, rename, remove L); r → present(verified: e.checksum != nil)
                          dirtyDirectories; markDirty(.soon)        (coalesced commits; the P-5 window is covered by expectedBlob)
     else → r stays absent
  Phase 3: allAdopted = every legacy record present
           lastSyncedAppVersion = allAdopted ? legacyStamp : nil; syncDue = ¬allAdopted; legacyState = done
           commit (**durable**, F_FULLFSYNC on file and directory) ← required before the irrevocable step below
  Phase 4: list root recursively (one unit per directory); removeItem every file and symlink (never followed);
           remove directories bottom-up, then root; then defaults.removeValue(forKey:)  [unit]
```

| Crash during | Next launch sees | Outcome |
|---|---|---|
| phase 1 | `legacyState` none, legacy intact | restart from scratch |
| phase 2 (any boundary, any mode) | inProgress; some files in `blobs/`, some still in legacy | §2.6 7c adopts moved blobs by `expectedBlob` (no re-hash); phase 2 resumes the rest. A file present under both names (per-directory PL) gets its legacy name removed. |
| phase 3 commit | inProgress or done | inProgress → phase 2 (a no-op) then phase 3; done → phase 4 |
| phase 4 | done; legacy partly removed and/or key present | finish removal, remove key |

The stamp is never lost and never falsely claimed: it is migrated only on full adoption, and the key is removed only after a durable done commit. Removing the key is a `cfprefsd` write and is **not** ordered with our barriers, which is why that commit is durable.

**Fixtures.** `Tests/Fixtures/legacy-v0/` is generated by running the real prior-art `CDNAsset.swift` and `CDNLocalStore.swift` (Foundation and CryptoKit only) inside a throwaway SwiftPM package under a git-ignored `.build-probe-legacy/` **inside this repo**. The two files are copied read-only from `../ZTronCarouselCore`, and nothing is written there (owner directive). The package is driven through the shipped example manifest series (ADR-008). Tests load the tree into the fake, including a legacy defaults entry.

**Duration (risk R4).** Phase 2 hashes the whole legacy catalog once: about 0.4 s per GB at the measured Mac throughput, more on older devices. Lookups are served progressively because snapshots publish every 64 adoptions.

---

## 8. Failure analysis

| # | Scenario | What happens | Invariant that holds | Test (display-name prefix) |
|---|---|---|---|---|
| F1 | Kill while the transport writes `.part` | partial staged file, unreferenced | I-4, I-1 | `R-CLN-3: staging GC removes unowned partial files…`; `R-STO-5` scenario 1 |
| F2 | Kill after the barrier, before the rename | complete `.part` in staging, collected; that asset is re-fetched | I-1, I-4 | `R-STO-5` scenario 1 (op enumeration) |
| F3 | Kill after the rename, before the coalesced commit (P-5 window) | unreferenced blob = `expectedBlob`, adopted at launch, **0 downloads** | I-1, I-2 | `R-STO-5: blobs published before a rate-limited commit are adopted after a crash, never re-downloaded` |
| F4 | Power loss after a rename with no barrier (mutant) | zero-length blob under its hash name | I-1 would break, so the barrier is mandatory | `R-STO-5` mode `powerLossKeepMetadata`; mutation probe "publish before verification/barrier" |
| F5 | Power loss: fan-out not synced before the commit (mutant) | index references a lost blob | I-2 would break, so the fan-out barrier is mandatory | `R-STO-5` mode `powerLossDropUnsynced` |
| F6 | Kill or tear during `index.tmp` write | tmp trailer fails, ignored | I-5 | `R-STO-4: a torn index.tmp is ignored…` |
| F7 | Kill between rename bin→prev and tmp→bin | no `index.bin`; newest valid is tmp | I-5 | `R-STO-5` (every scenario) |
| F8 | Kill after the commit that drops X, before the unlink | X in DOOMED, deleted at launch, never re-adopted | I-3 (no reader in the new process) | `R-CLN-12: an interrupted purge finishes at the next launch` |
| F9 | Kill mid unlink batch | rest deleted at launch; ENOENT counts as success | I-3; idempotency | `R-CLN-12: every cleanup operation run twice is a no-op…` |
| F10 | `index.bin` bit-rot | fall back to `prev` plus blob names; degraded until the next manifest | I-2, I-5; no blob deleted | `R-STO-4: a corrupt index.bin falls back to the previous generation without deleting blobs` |
| F11 | Both index files corrupt or missing, blobs present | empty and degraded; orphan GC suspended; the next manifest adopts by hash | no deletion; verified entries not re-downloaded | `R-STO-4: with no valid index the store rebuilds from blob names and the next manifest…` |
| F12 | Newer-schema index (downgrade) | degraded; no deletion until a manifest is applied and adoption has run | R-STO-4 | `R-STO-4: a newer-schema index enters degraded mode and deletes no blob` |
| F13 | OS deletes `blobs/` between launches | present records become needsHeal; stamp reset; sync due | I-2 | `R-CLN-7: deleting blobs/ between launches resets the sync stamp…` |
| F14 | OS deletes the root | fresh empty store; sync due; legacy key, if any, removed without a stamp | R-STO-2 | `R-CLN-7: deleting the whole root…` |
| F15 | OS deletes half the blobs | exactly those records become needsHeal; stamp reset | I-2 | `R-CLN-7: deleting half the blobs…` |
| F16 | ENOSPC while staging (transport write) | partial file removed; `insufficientSpace`; nothing published | I-1, I-4 | `R-STO-6: a partial write followed by ENOSPC is never published` |
| F17 | ENOSPC mid index commit | previous generation intact; in-memory state kept; retry; deletions that need it are blocked | I-5, I-3 | `R-STO-6: ENOSPC during an index commit keeps the previous generation and retries` |
| F18 | EIO on the publish rename | `.part` stays; publish throws; staging GC later | I-1, I-4 | `R-STO-6: EIO on rename leaves the staged file unpublished…` |
| F19 | EACCES at open (before first unlock) | `storageUnavailable(.protectedDataUnavailable)`, no mutation | — | `R-STO-6: EACCES at open surfaces storageUnavailable without mutating state` |
| F20 | Second `AssetClient` or process on the same root | `StoreError.locked` immediately | R-STO-9 | `R-STO-9: a second store on the same root fails with locked deterministically` |
| F21 | Reader holds an old-snapshot URL during prune | unlink only after acknowledgement and grace; an already open fd survives unlink | I-3 | `R-CLN-5: every URL handed out stays readable for at least the grace window` |
| F22 | Video lease during eviction | not a candidate | R-CLN-5 | `R-CLN-5: a leased asset survives eviction and prune until its lease ends` |
| F23 | Publish of a key that is being deleted | awaits the batch, then publishes fresh | I-1, I-2 | `R-CLN-2: orphan GC never deletes a blob whose publication is in flight` (and a rescue variant) |
| F24 | Manifest changes while hashing | revalidated; `.superseded` or accepted against the new checksum | I-2 | `R-INT-2: a publish superseded by a manifest change mid-hash is not published` |
| F25 | Crash mid migration | resume; adopt by `expectedBlob`; finish teardown | I-1, I-2 | `R-STO-5 R-STO-11: crash at every boundary during legacy migration…` |
| F26 | Legacy manifest with `..` or `/` components | entry dropped; nothing outside the legacy root touched | R-SEC-2 | `R-SEC-2: legacy paths with traversal segments are rejected during migration` |
| F27 | Legacy directory purged, key still present | key removed; stamp **not** migrated | D-6 fixed | `R-STO-11: a vanished legacy directory drops the UserDefaults stamp without claiming synced` |
| F28 | Server keeps serving wrong bytes | quarantined (60 s, then 600 s), then failed; survives relaunch | R-INT-3 | `R-INT-3: repeated mismatches back off and finally mark the asset failed…` |
| F29 | UI reports an undecodable file | quarantine, delete after grace, re-download with backoff | R-CLN-8 | `R-CLN-8: reportUnreadable quarantines…` |
| F30 | Wall clock jumps backwards | grace and reaper use the monotonic instant; persisted stamps use wall time but only compare against themselves | I-3 | `R-CLN-5: deletion grace uses the monotonic clock…` |
| F31 | Root deleted while running (unexpected for `Caches`) | pre-commit lock check, then `storageUnavailable(.rootVanished)` and reopen | R-STO-9 | `R-STO-9: a vanished root is detected before the next commit` |

---

## 9. Test plan

All storage tests use `makeFakeFileSystem()` plus `InlineBlockingExecutor`, `ManualTimeSource` and `SeededRandom` (Q-4: no sleeping, seeds printed), and carry `.timeLimit(.minutes(1))` when they await. `LiveFileSystem` and live-lock tests use a per-test temporary directory. Display names cite only SPEC IDs (the trace gate rejects unknown IDs). "I-n" and "H-n" in names are inert to the gate.

### 9.1 Shared test machinery (WP-H/WP-B)

- `InvariantChecker.check(disk:store:)`:
  - I-1: re-hash every blob.
  - I-2: every present record has its blob; in crash-only runs also **zero** needsHeal.
  - I-4: no staging path in the index or snapshot.
  - I-5: header generations monotonic across reopen; `committedGeneration` ≥ every generation whose commit returned before the crash.
- `OrderingAuditor(opLog:, ackLog:, leaseLog:)`: for every `removeItem` in `blobs/`, the auditor checks:
  - an acknowledged snapshot lacking the blob, with `ackInstant + grace ≤ unlinkInstant`;
  - no live lease at unlink;
  - an ordered commit dropping the reference earlier in the op log.

  Used by every cleanup test (I-3).
- `ScenarioRunner(scenario).enumerateCrashes(modes:)`: one clean run counts the mutations N. Then for k in 0…N and every mode, it runs, crashes, takes `survivingDisk()`, reopens a fresh store, checks invariants, re-runs the scenario's remaining intent to convergence, and asserts that the final state equals the clean run's final state and that **downloads after reopen = only assets whose publish had not returned**.

### 9.2 Display names (grouped by requirement)

**Layout, index, crash safety**
- `R-STO-1: every mutation the store performs targets a URL under the versioned root`
- `R-STO-1: a URLSession temp file is renamed into staging before the delegate returns`
- `R-STO-2: deleting the root resets manifest, records, ETag and sync stamp together`
- `R-STO-2: the legacy UserDefaults stamp is migrated once and then removed`
- `R-STO-3: a blob never appears at its final path before size check, hash verification and barrier`
- `R-STO-3: publishing uses an exclusive same-volume rename and never replaces an existing blob`
- `R-STO-4: a commit writes tmp, full-syncs, renames bin to prev, renames tmp to bin, then syncs the root, in that order`
- `R-STO-4: a torn index.tmp is ignored and the newest valid generation wins`
- `R-STO-4: a corrupt index.bin falls back to the previous generation without deleting blobs`
- `R-STO-4: a newer-schema index enters degraded mode and deletes no blob`
- `R-STO-4: with no valid index the store rebuilds from blob names and the next manifest without re-downloading verified assets`
- `R-STO-5: crash at every file-system boundary during a first sync preserves I-1…I-5` (args: 4 crash modes)
- `R-STO-5: crash at every boundary during a checksum-change update preserves I-1…I-5`
- `R-STO-5: crash at every boundary during a directory change preserves I-1…I-5 and downloads nothing`
- `R-STO-5: crash at every boundary during a removal preserves I-1…I-5`
- `R-STO-5: crash at every boundary during eviction preserves I-1…I-5`
- `R-STO-5 R-STO-11: crash at every boundary during legacy migration preserves I-1…I-5 and adopts every verified file`
- `R-STO-5: blobs published before a rate-limited commit are adopted after a crash, never re-downloaded`
- `R-STO-5: model-based random operations with crash and reopen agree with the oracle` (§9.3)
- `R-STO-6: the fake and live file systems agree on the shared conformance contract` (parameterized over conformers)
- `R-STO-6: ENOSPC during an index commit keeps the previous generation and retries`
- `R-STO-6: a partial write followed by ENOSPC is never published`
- `R-STO-6: EIO on rename leaves the staged file unpublished and the index unchanged`
- `R-STO-6: EACCES at open surfaces storageUnavailable without mutating state`
- `R-STO-6: every errno and Cocoa error maps to the closed FileSystemError taxonomy`
- `R-STO-7: store operations invoked from the main actor perform every file-system call off the main thread` (facade-level variants for `lookup`/`prefetch`/`events`/`resolve` belong to WP-G)
- `R-STO-8: the root is excluded from backup and uses completeUntilFirstUserAuthentication`
- `R-STO-8: missing root attributes are re-applied at open`
- `R-STO-9: a second store on the same root fails with locked deterministically`
- `R-STO-9: the live lock rejects a second opener in the same process and frees on close`
- `R-STO-9: a vanished root is detected before the next commit`
- `R-STO-10: the default location is Application Support and caches or custom roots are selectable`
- `R-STO-11: legacy files whose checksum verifies are moved into blobs, not re-downloaded` (fixtures `legacy-v0`)
- `R-STO-11: legacy files with a mismatching checksum are dropped and the legacy directory is removed`
- `R-STO-11: running migration twice is a no-op the second time`
- `R-STO-11: a legacy manifest with duplicate identifiers migrates without crashing`
- `R-STO-11: a vanished legacy directory drops the UserDefaults stamp without claiming synced`
- `R-STO-11: a partly adopted legacy catalog leaves a sync due`
- `R-STO-12: the v1 golden index fixture decodes and re-encodes byte-identically`
- `R-STO-12: every older-schema golden fixture migrates through the chain to the current schema`
- `R-STO-12: decoding fuzzed index bytes never traps and never deletes a blob` (seeded)
- `R-STO-13: a snapshot held by a reader is unaffected by later mutations`
- `R-STO-13: snapshot lookup returns the blob URL for present assets only and matches extensions case-insensitively`
- `R-STO-13: the mirror ignores an out-of-order snapshot version`

**Integrity**
- `R-INT-1: streaming SHA-256 equals CryptoKit one-shot for 0, 1, 1 MiB−1, 1 MiB, 1 MiB+1 and 5 MiB`
- `R-INT-1: hashing reads at most 1 MiB per unit and performs every read inside the blocking executor`
- `R-INT-1: cancelling a hash stops at the next unit boundary and leaves the staged file in place`
- `R-INT-2: a size mismatch is rejected before hashing and the staged bytes are deleted`
- `R-INT-2: a checksum mismatch deletes the staged bytes, throws integrity, counts a metric and publishes nothing`
- `R-INT-2: a publish superseded by a manifest change mid-hash is not published`
- `R-INT-3: repeated mismatches back off and finally mark the asset failed until its manifest entry changes`
- `R-INT-3: integrity backoff bookkeeping survives a relaunch`
- `R-INT-4: deep verification repairs a corrupted resident blob within its byte budget`
- `R-INT-5: unverified entries are rejected when allowUnverifiedAssets is false and flagged unverified otherwise`
- `R-INT-6: the recorded blob hash is the digest of the written bytes, not the manifest claim`

**Cleanup**
- `R-CLN-1: prune removes blobs of removed entries only after acknowledgement and grace`
- `R-CLN-1: prune keeps a blob still referenced by another identifier`
- `R-CLN-1: a directory change is an index edit with zero file operations on blobs`
- `R-CLN-2: orphan GC removes unreferenced blobs older than the orphan grace`
- `R-CLN-2: orphan GC is suspended while the index is degraded`
- `R-CLN-2: orphan GC never deletes a blob whose publication is in flight`
- `R-CLN-3: staging GC removes unowned partial files at launch and after sync`
- `R-CLN-3: staging GC keeps files claimed by an active transfer`
- `R-CLN-4: eviction removes least-recently-used first, larger first on ties, down to 90 % of budget`
- `R-CLN-4: eviction never removes essential, pinned, leased or recently accessed assets`
- `R-CLN-4: a fractional budget and reserveFreeBytes are both honoured`
- `R-CLN-4: makeRoom fails with insufficientSpace and no side effects when protected bytes exceed the budget`
- `R-CLN-4: synchronous lookups reach LRU through the snapshot acknowledgement`
- `R-CLN-5: deletion waits for the acknowledged snapshot without the blob, the grace window and every lease`
- `R-CLN-5: a leased asset survives eviction and prune until its lease ends`
- `R-CLN-5: every URL handed out stays readable for at least the grace window`
- `R-CLN-5: deletion grace uses the monotonic clock, not wall time`
- `R-CLN-6: purge all returns bytes freed, leaves the store consistent and makes a sync due`
- `R-CLN-6: purge evictable and purge scope remove exactly the matching assets`
- `R-CLN-7: deleting blobs/ between launches resets the sync stamp and heals lazily`
- `R-CLN-7: deleting the whole root between launches starts empty with a sync due`
- `R-CLN-7: deleting half the blobs flags exactly those records needsHeal`
- `R-CLN-8: reportUnreadable quarantines the entry, removes the blob after grace and schedules a re-download`
- `R-CLN-9: storageReport sums bytes by kind and state with pinned, evictable, staging, orphan and free space`
- `R-CLN-12: every cleanup operation run twice is a no-op the second time` (args: prune, orphan GC, staging GC, evict, purge, quarantine)
- `R-CLN-12: cancelling cleanup at every suspension point leaves invariants intact` (args: suspension index; executor cancels the task before unit k)
- `R-CLN-12: an interrupted purge finishes at the next launch instead of re-adopting blobs`

**Security**
- `R-SEC-2: manifest text never becomes a path component of the store` (seeded fuzz over identifiers, paths, names)
- `R-SEC-2: legacy paths with traversal segments are rejected during migration`
- `R-SEC-2: a blob extension outside [a-z0-9]{1,8} is refused before any URL is built`
- `R-SEC-2: symbolic links in blobs, staging or the legacy tree are removed and never followed`

**Benchmarks** (`Tests/ZTronAssetKitBenchmarks/StoreBenchmarks.swift`, suite `StoreBenchmarks`; thresholds read from `quality-gates.json`; live FS in a temp directory)
- `P-2: cold index load of 10,000 records off the main thread is under budget`
- `P-5: index commit of 10,000 records is under budget and a bulk sync commits at most 4 per second` (duration: live FS; rate: 1,000 publishes on a `ManualTimeSource`, commits counted per simulated second)
- `P-6: streaming SHA-256 of 256 MiB meets the throughput floor, the one-shot ratio and the memory cap` (peak RSS delta measured in-process; the one-shot reference allocates last)
- `P-13: reclaiming 10,000 blobs finishes under budget in batches of bounded duration`

### 9.3 Model-based oracle (SPEC §7.3)

- **Generator:** a seeded `SystemRandomNumberGenerator` replacement, with the seed printed on failure. It draws 200 operations from `apply(manifest′)` (random add / remove / relocate / content change over a 40-id universe), `publish(id)`, `lease`/`release`, `recordAccess`, `evict(budget′)`, `purge(scope′)`, `reportUnreadable`, `advance(time)`, `ack`, and `crash(mode, at: random next mutation)` followed by reopen.
- **Oracle:** a plain dictionary `id → OracleState {absent, present(content), unknownAfterCrash}` plus the manifest. Rules:
  - a returned publish makes the asset present;
  - removal, eviction or purge makes it absent;
  - after a crash, an asset whose publish *returned* must be present again **or adoptable**, because the oracle allows "not yet committed" only for publications whose blob is on disk.
- **After every step:** `InvariantChecker` (I-1…I-5), `OrderingAuditor` (I-3), `snapshot == oracle.present` (after acknowledgement), `storageReport.liveBytes == Σ oracle sizes`.
- **Runs:** 100 seeds × 200 operations in the normal run (sub-second with the inline fake); 2,000 seeds behind an environment flag for soak runs.

### 9.4 Coverage plan (Storage ≥ 90 %)

- Every branch of `LiveFileSystem` is reachable on macOS. Syscall shims are thin, and the decisions are pure functions (`syncOutcome`, `FileSystemError.posix`, `from(_:)`) with table tests.
- EACCES is produced via `chmod 000` on a temp directory. EXDEV and ENOSPC are covered through the fake and the pure mappers.
- The iOS-only protection line is compiled out on macOS, so it is not counted.
- No storage file is excluded.

---

## 10. Evidence (run in this session)

Probe directory: `.build-probe-store/` (git-ignored by `.build*`). The SwiftPM scratch path was `.build-store`.

**Compile evidence**

| Check | Command | Result |
|---|---|---|
| Live FS, executor, streaming hash, legacy defaults, store-shaped actor, at the floors | `bash .build-probe-store/typecheck.sh LiveFSProbe.swift`, i.e. `xcrun --sdk iphoneos swiftc -typecheck -target arm64-apple-ios15.0 -swift-version 6 -strict-concurrency=complete -warnings-as-errors`, and the same with `--sdk macosx -target arm64-apple-macos12.0` | `== arm64-apple-ios15.0 … exit=0`, `== arm64-apple-macos12.0 … exit=0` |
| APIs proven callable at the floors | the same probe | `open` with `O_EXLOCK\|O_NONBLOCK\|O_CLOEXEC`, `flock(LOCK_EX\|LOCK_NB)`, `fcntl(fd, F_FULLFSYNC)`, `fcntl(fd, F_BARRIERFSYNC)`, `fsync`, `Darwin.rename`, `renamex_np(…, UInt32(RENAME_EXCL))`, `unlink`, `rmdir`, `mkdir`, `FileHandle.read(upToCount:)` / `seek(toOffset:)` / `write(contentsOf:)`, `autoreleasepool`, `URLResourceValues.isExcludedFromBackup` / `.volumeAvailableCapacityForImportantUsage`, `FileProtectionType.completeUntilFirstUserAuthentication`, `withCheckedContinuation` + `Result.get()` typed throws, `SHA256` across `@Sendable` closures |
| Unsafe gate over the live probe | `gates.unsafe_check` from `Scripts/gates.py` on the probe source under a `/Sources/` path | `UNSAFE escapes found=0 max=3` |
| `Mutex` fake, `@available(macOS 15.0, iOS 18.0, *)`, at the floors | `typecheck.sh LiveFSProbe.swift crash/main.swift` | both `exit=0`; unsafe gate `found=0` |
| `package` access across targets plus the gated fake, built for iOS | probe package `.build-probe-store/pkg`: `xcodebuild -scheme StoreProbe -destination 'generic/platform=iOS' … OTHER_SWIFT_FLAGS='-warnings-as-errors'` | `** BUILD SUCCEEDED **` |
| Swift Testing and availability | `swift test` in the probe package | `@available(macOS 15.0, iOS 18.0, *)` on `@Suite` or `@Test`, and `@available(macOS 15.0, *)` on `@Suite`, give *error: Attribute 'Suite'/'Test' cannot be applied … because it has been marked '@available(…)'*. Single-platform on `@Test` and a body `#available` guard pass (`✔ Test run with 2 tests in 1 suite passed`). |
| Typed-throws trap | first probe compile | `do { try work() } catch { …(error) }` in a `throws(FileSystemError)` context: *cannot convert value of type 'any Error' to expected argument type 'FileSystemError'*. Fixed with `do throws(FileSystemError)`. |
| SDK facts | `iPhoneOS27.0.sdk` headers and `.swiftinterface` | `F_FULLFSYNC 51`, `F_BARRIERFSYNC 85`, `O_EXLOCK 0x20` (`sys/fcntl.h`); `renamex_np` iOS 10.0 and `RENAME_EXCL 0x4` (`sys/stdio.h`); `public struct SHA256 : Swift::Sendable` (CryptoKit interface :307); `Digest : … Sendable`; `NSFileHandle` is `NS_SWIFT_SENDABLE`; `UserDefaults` is **not** `Sendable` (`ud_probe.swift`: *stored property 'defaults' of 'Sendable'-conforming struct 'Holder' has non-Sendable type 'UserDefaults'*) |

**Runtime evidence** (macOS 27, Apple M3, internal APFS SSD; `swiftc -O -wmo`; `.build-probe-store/lock`, `crash`, `bench`)

| Check | Result |
|---|---|
| Lock semantics | a second open in the **same process**: `fd=-1 errno=35` (EWOULDBLOCK); in another process: `errno=35`; after `kill -9` of the holder the other process gets `fd=3`; `flock` while `O_EXLOCK` is held: `-1 errno=35` |
| Directory sync on APFS | `fcntl(dirfd, F_FULLFSYNC)=0`, `fcntl(dirfd, F_BARRIERFSYNC)=0` |
| `RENAME_EXCL` | onto an existing name: `-1 errno=17` (EEXIST); onto a free name: `0` |
| **Crash model** (§3.4) over the commit + publish + dedupe + delete protocols | `protocol-as-designed: 44 mutating ops, 180 crash cases, 0 violating` · `mutant-no-barrier-before-rename: 64 violating` (*I-1: blob … has 0 bytes*) · `mutant-no-fanout-sync-before-commit: 25 violating` (*I-2: gen 1 references missing blob*) · `CRASH-MODEL PROBE: PASS` |

**Benchmarks** (release, this Mac; the real benchmarks must be re-run by the P-n suites)

| Budget | Measured | Threshold |
|---|---|---|
| P-2 index load, 10,000 records (1.43 MiB) | read + SHA verify + decode **p50 2.8 ms, max 3.3 ms**; encode p50 5.2 ms | ≤ 25 ms |
| P-5 commit, encode included, 16 dirtied fan-outs, n=120 | ordered **p50 11.3 / p95 12.4 / max 13.3 ms**; durable p50 16.0 / p95 17.9 / max 21.1 ms | ≤ 40 ms; rate ≤ 4/s by construction |
| P-5 rejected variant | fan-out syncs at `F_FULLFSYNC` (encode excluded): p50 15–27 ms per run, **max up to 74 ms** | — |
| P-5 tail observation | `F_FULLFSYNC` on file and directory, 0 fan-outs, encode excluded, 9 runs × 30: per-run max 12.9–41.7 ms; one sample > 40 ms | (see R1) |
| Directory sync cost | barrier p50 0.37 ms · full p50 4.15 ms, max 12.5 ms · file barrier after a 200 KB write p50 0.36 ms | — |
| P-6 streaming SHA-256, 256 MiB | **2539 MB/s = 0.81× one-shot (3124 MB/s); peak RSS Δ 1.77 MiB**; pipelined 2781 MB/s (0.89×), Δ 2.91 MiB; no pool on the main thread: Δ **1285 MiB** (motivates `autoreleasepool` and `.workItem`) | ≥ 800 MB/s, ≥ 0.7×, ≤ 4 MiB |
| P-13 reclaim 10,000 blobs | batch 64: **total 359 ms, max unit 2.87 ms**; batch 128: max unit 5.42 ms | ≤ 2 s; ≤ 5 ms per batch |
| Reconciliation listing | 10,000 blobs across 256 fan-outs: 52 ms total (about 0.2 ms per unit) | (part of open) |
| Snapshot | CoW copy 0.14 ms · rebuild 0.88 ms · lookup p99 **2.75 µs** | P-1 ≤ 25 µs |

---

## 11. Open risks and items for Phase C / other work packages

| # | Risk or item | Mitigation and owner |
|---|---|---|
| R1 | **P-5 tail latency.** In the first (noisier) runs, the I/O-only commit (`F_FULLFSYNC` on file and directory) had per-run maxima of 12.9–41.7 ms, with exactly one of 270 samples above 40 ms. The later 120 samples, encode included, maxed at 21.1 ms (durable) and 13.3 ms (ordered). A benchmark that asserts the *max* could flake (Q-5). | The benchmark statistic should be p95 or p50, decided by whoever writes `StoreBenchmarks` and recorded in an ADR. Commits run off the pool, so a tail sample harms nothing else. |
| R2 | P-6, P-13 and F_FULLFSYNC costs were measured on an M3 Mac only, not on a device. | `DEVICE-TEST-PLAN.md`: re-measure on the oldest supported iPhone. The pipelined hash is the fallback. |
| R3 | Durability semantics of `F_BARRIERFSYNC` on non-Apple or external volumes are a *(hint)*. | The live conformer falls back to `fsync` when fcntl fails. The design's correctness does not depend on barriers being stronger than the fake models. |
| R4 | First launch after the update hashes the whole legacy catalog (about 0.4 s/GB on the Mac, slower on old devices). | Progressive snapshot publication. Optional: trust a `local-checksums.json` match only after a sampled re-hash (decline unless measured necessary). |
| R5 | Protected data unavailable before first unlock (background launch) means `open()` fails. | Surfaced as `storageUnavailable(.protectedDataUnavailable)`. The facade retries on the next `start()`. No UIKit observer (R-CAR-9). |
| R6 | An App Group or `.custom` shared root with a held `flock` risks 0xdead10cc. | Documented as unsupported by default. If ever needed, `AssetClient.suspend()` would close the store. |
| R7 | The `Mutex` funnel means test fakes need macOS 15+ hosts. This host is macOS 27; the test host floor is effectively macOS 15. | ADR-014. Production floors are unaffected (iOS 15 / macOS 12). |
| R8 | Cross-WP contracts this design assumes. **WP-A:** `ManifestEntry`, `ValidatedManifest`, `ManifestDiff`, `AssetScope` evaluation, `ContentHash` (fixed-size), and a legacy `[CDNAsset]` decoder. **TimeSource:** wall `now`, a monotonic instant and `sleep(until:)` on the monotonic clock (coordinate with the sync design, H-8). **WP-D:** the URLSession delegate renames into `StagingReservation.partURL` synchronously, and `.resume` is owned by D/F. **WP-F:** the planner respects the budget (no eviction thrash) and calls `collectStaging` after sync. **WP-G:** `SnapshotMirror.install` returns drained accesses. | Phase C contract code |
| R9 | Layout deviation from SPEC §4.3 (`index.prev`, `index.tmp`, DOOMED) and the byte format. | ADR-012, NEEDS-HUMAN-REVIEW |
| R10 | Snapshots publish after every mutating call. That is fine at bulk-sync rates (0.14 ms CoW each), but if P-8 shows main-actor pressure, coalesce to ≤ 10 Hz (H-9 style). | WP-G/WP-B, measured by P-8 |
