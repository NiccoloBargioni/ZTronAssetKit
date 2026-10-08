# ADR drafts — WP-B storage core (Stage 2, level L2)

Owner: WP-B. The orchestrator numbers these into `DECISIONS.md` at merge (ARCHITECTURE §1.2). Each entry: context · options · decision · consequences.

## B-1 — Live lock tokens carry a nonce parked in the descriptor's file offset
- **Context.** The conformance suite's stale-token clause (ADR-049) binds `LiveFileSystem.releaseLock`: descriptor numbers are reused after `close`, so a token holding only the descriptor would unlock a lock taken since. `LiveFileSystem` is a stateless struct; the iOS 15 floor and the unsafe budget rule out a lock table.
- **Options.** (a) A process-wide token table (needs a lock or an escape). (b) Write a nonce into `store.lock` (the file is documented empty). (c) Park a nonce in the descriptor's file offset with `lseek`, which writes nothing, and carry it in `FileLockToken.handle`.
- **Decision.** (c): `handle = nonce << 32 | descriptor`, nonce in `1...Int32.max` from `SystemRandomNumberGenerator` (a live conformer may draw, R-ENV-1 scan). `releaseLock` unlocks and closes only when `lseek(fd, 0, SEEK_CUR) == nonce`.
- **Consequences.** Release twice and stale releases are no-ops (conformance passes on the live conformer). **For the orchestrator:** `FileLockToken.handle`'s doc ("the descriptor (live)") and `FileSystem.releaseLock`'s doc could say "releasing a stale token releases nothing" (Model files, not WP-B's).

## B-2 — Resource values are read through a fresh `URL`
- **Context.** `NSURL` caches resource values for the object's lifetime on threads without a run loop; the store keeps one root `URL` for its lifetime, so free space and backup exclusion read through it went stale (a live test caught it).
- **Decision.** `availableCapacity` and `storeAttributes` read through `URL(fileURLWithPath:)` built per call.
- **Consequences.** One small allocation per query; figures are current.

## B-3 — The v1 `index.bin` byte layout · **NEEDS-HUMAN-REVIEW** (on-disk format)
- **Context.** store.md §2.3 and ADR-012 fixed the shape; Stage 2 fixes the bytes (schema 1 is not shipped yet).
- **Decision.** Header (64 bytes, little-endian): magic `ZTAKIDX\0` · `schemaVersion` u16 · `sectionCount` u16 · flags u32 (bit 0 degraded) · `generation` u64 · `bodyLength` u64 (≤ 64 MiB) · `writtenAtMillis` i64 · launch epoch u64 · `storeID` 16 bytes. (store.md's `headerLength` field is dropped: 64 is implied by the schema; the launch epoch takes its room.) Body: sections `(tag, varint length, payload)` in increasing tag order, STAMPS `0x01`, STRINGS `0x02`, RECORDS `0x03`, DOOMED `0x04`; unknown tags `< 0x80` malformed, `≥ 0x80` skipped. Trailer SHA-256 over header and body. Dates are the IEEE bit pattern of `timeIntervalSinceReferenceDate` (exact round trips; store.md's whole seconds would lose sub-second stamps). STAMPS: presence bitmap, sync stamp (app version, completion, manifest digest, optional ETag), applied ETag, `syncDue`, `lastCleanupAt`, legacy stamp, legacy phase, applied manifest digest, wire shape, quarantine count. RECORDS: per-record flag varint (12 bits) with the omissions "expected = checksum" and "blob = expected"; DOOMED: sorted keys with `DoomReason`. Strings are interned by their UTF-8 bytes (identifiers differing only in normalisation stay distinct). The decoder accepts exactly one encoding per state (sorted DOOMED, no redundant hashes), so a valid file re-encodes byte-identically (golden fixture `Tests/Fixtures/index/v1/golden.bin` + `golden.json`, R-STO-12).
- **Consequences.** 10,000 records encode to 1.41 MB. A schema change adds `v2` fixtures and a decoder.

## B-4 — The applied manifest is persisted through its records
- **Decision.** RECORDS are written in applied-manifest order; records not in the manifest follow, sorted and flagged *detached*; an applied entry without a record is written as `absent(.neverFetched)`. Load rebuilds `ValidatedManifest` from the non-detached entries plus STAMPS' digest, shape and quarantine count. Per-entry quarantine **diagnostics** are not persisted (`quarantined == []` after a reload; `quarantinedCount` kept).
- **Consequences.** No second copy of 10,000 entries. WP-C's legacy phase 1 keeps the invariant (records ⊆ applied ids) by construction.

## B-5 — Launch epoch, launch commit, read-only open
- **Decision.** `launchEpoch` is the generation of the commit every `open()` performs (persisted by that commit; `nextGeneration = 1 + max(generation, launch epoch)` over every parsed header). A failed launch commit leaves the store open on the loaded state with the commit due (store-1 S1-07); `OpenReport.generation` is then the loaded one.
- **Consequences.** One ordered commit per launch (P-5-cheap). If the launch commit fails before anything reached the disk, the next launch may reuse the epoch; staging names of that launch then collide only with this launch's (exclusive renames report `nameInUse`).

## B-6 — Degraded mode: when, and what it suspends
- **Decision.** Degraded when the load rule says so (no valid generation although a file existed, an invalid `index.bin`, a newer schema, a persisted degraded flag) **or** when no index exists but `blobs/` holds blobs. While degraded the reaper deletes nothing at all (S1-11's "DOOMED keys protected" generalised: the doom set itself is untrusted). Unreferenced blobs listed at launch are remembered as orphans; `apply` re-stats each candidate in one unit before binding it (proposed row b-5), then clears degraded.
- **Consequences.** R-STO-4's rebuild works without re-downloading verified assets.

## B-7 — Commit coverage and the coalescing window
- **Decision.** Mutations are counted (`markDirty`); a commit covers every mutation counted before its capture; at most one commit runs; commits start at most once per `commitMinimumInterval` — `runDueWork()` serves `.soon` mutations at the window, and `requireCommitted` sleeps on `TimeSource.sleep(until:)` in the **caller's** task until the window opens (proposed row b-2; the store still owns no task or timer). `requireCommitted` re-checks the phase first.
- **Consequences.** ≤ 4 commits/s by construction (P-5 rate benchmark: at most 4 in any second of a simulated 10 s bulk sync). Checksum-less and rescue publishes, which must commit before returning (S1-05), share these commits: a checksum-less bulk sync publishes at most `concurrency × 4` assets per second — acceptable for the legacy tier, recorded here for WP-F.

## B-8 — Snapshots: incremental table, fresh acknowledgements
- **Decision.** `presentTable` (one `SnapshotEntry` per present record) is updated per changed record, so an install wraps it in O(1) (the test invariant checker compares it with a rebuild). Acknowledgements count only for the store's epoch. The "fresh acknowledgement" of ADR-017 is the start instant (awake clock) of the newest acknowledged install: a key is deletable when its grace ended before that instant. An install started after the grace that came back unacknowledged makes the key acknowledgement-blocked: no deadline (store-1 S1-13), but every later `runDueWork()` retries the fresh install.
- **Consequences.** No busy alarm with a sink that keeps an older or foreign snapshot; recovery as soon as it acknowledges.

## B-9 — Benchmark statistics (P-2, P-5, P-6, P-13)
- **Decision.** Durations: p95 (store.md §11 R1 measured single-sample tails 2–3× the p95, scheduler noise on a shared machine; a max-based budget would flake, Q-5). P-5's budget is applied to the ordered commit a bulk sync performs (p95); durable commits (flush, close, adoption report) are judged on their median, their tail being the device-wide `F_FULLFSYNC` cache flush shared with all I/O. P-6 throughput: best of five runs per variant after a warm-up (interference only slows runs down); memory: peak resident delta sampled after every hash unit (`MemoryProbe`). P-13: total wall time and the p95 of deletion-unit durations.
- **Consequences.** Recorded in `BenchStorage.swift`'s doc comment.

## B-10 — Deletion units are bounded by time as well as by count
- **Context.** P-13 bounds the time between suspension points (5 ms). Measured during this level with other worktrees building (load average 7–15): 64 raw `unlink`s took p50 5.3 ms, p95 7.8 ms in a standalone probe — the count bound alone cannot hold the budget on a busy or slow volume.
- **Decision.** `deletionBatchSize` (64, ADR-035) stays the maximum; each deletion unit also stops after 3 ms of the injected monotonic clock (at least one unlink), and the keys it did not attempt go first into the next unit, unchanged (no backoff).
- **Consequences.** Units stay inside the budget under load (P-13 p95 3.2 ms); `ManualTimeSource` never advances inside a unit, so deterministic tests see count-bounded units. Deviation from ARCHITECTURE §4.4's "units of 64" wording, for the orchestrator.

## B-11 — Publication details
- **Decision.** (1) Ids are validated, not all-or-nothing: unknown and changed ids are skipped; `.unknownAsset`, `.assetFailed` or `.superseded` is thrown only when none remains; the returned dictionary lists the ids bound. (2) Ids sharing a checksum but not an extension get one blob per extension: the placed blob is copied (≤ 1 MiB units on the bulk executor) to `staging/<transfer>.<epoch>-4294967295.parttmp` and bound like a verified file. (3) A cancelled hash renames `.verifying` back to `.part`, so the caller can retry with the same `StagedFile`. (4) Size cap and manifest size are checked before hashing; the hashed byte count must equal the claimed size (bytes added to a claimed file are a size mismatch). (5) A verified publication replaces a `purged` or `corrupt` name with `rename(.replacing)`; an `unreferenced` doom is rescued and committed before returning.
- **Consequences.** Covered by `StorePublishTests`, `StoreEdgeTests`, `StoreInternalsTests`.

## B-12 — Launch and `apply` adoption also bind records to live blobs
- **Context.** ARCHITECTURE §4.5 binds "an unreferenced, non-doomed blob" to records that expect it. A dedupe publish (a second id onto a live key) that returned before a kill is in no committed generation; restricting adoption to unreferenced blobs would re-download it.
- **Decision.** Adoption binds a record that accepts adoption (ADR-018's residencies) to any listed key that is live, unreferenced, or doomed `unreferenced` (rescued) — never to `purged` or `corrupt` dooms.
- **Consequences.** Strictly fewer downloads; for the orchestrator to reword §4.5.

## B-13 — Staleness and checksum-less expectations
- **Decision.** `AssetRecord.isStale` ⇔ the referenced blob differs from the expected key (expected hash with the entry's extension). A checksum-less publish records the digest of the written bytes as `expectedBlob` (R-INT-6), and a checksum-less content change (`remotePath`) clears it, which makes the present blob stale.
- **Consequences.** One rule for checksum, checksum-less and extension changes; `isStale`, `referencedBlob` and `expectedKey` are `package` for the planner.

## B-14 — `setResidency(.present)` and unknown records
- **Decision.** A transition to `present` through `setResidency` is honoured only for a key that can be referenced without I/O (live, or doomed `unreferenced`); otherwise, and for an unknown id, nothing changes. (`adoptVerifiedFile` is the I/O path.)

## B-15 — A replaced root stops all commits
- **Decision.** When the commit unit finds the lock file's identity changed, the store records `unavailable = .rootVanished`: every later commit and mutating API throws `.storageUnavailable(.rootVanished)` at once, `nextDeadline()` keeps no commit deadline, reads keep working; the facade reopens.

## B-16 — Test seams that stand in for WP-C at L2
- `AssetStore.testSetLease`, `testClearLeases`, `testSetRetentionScope`, `testSetIntegrity`, `testBumpPurgeEpoch`, `testExpect`, `testInsertRecord` (test-target extensions) write WP-C's fields the way WP-C's APIs will, so WP-B's reaper, adoption report and stamp logic are tested before WP-C exists. WP-C may switch these tests to its APIs.
- Live file-system tests and benchmarks use directories under `.build-tests/` at the repository root (git-ignored through `.build*`), removed by each test.

## Measured in this level (release, this Mac, shared with other worktrees: load average 7–15)
A passing run of `swift test -c release --scratch-path .build-b-perf -Xswiftc -enable-testing --filter StorageBenchmarks` (load average 14.5): P-2 index load of 10,000 records (1.41 MB) p50 11.3 ms, p95 12.4 ms (budget 25); P-5 ordered commit p50 17.9 ms, p95 21.4 ms, durable p50 29.3 ms, p95 34.0 ms (budget 40), bulk sync 40 commits in 10 s, at most 4 in any second (budget 4); P-6 2,192 MB/s, 0.80× one-shot (2,723 MB/s), peak resident delta 0.0 MiB (floors 800 MB/s, 0.7×, cap 4 MiB); P-13 10,000 blobs in 1.29 s, unit p95 4.9 ms (budgets 2 s, 5 ms). Runs minutes apart on the same build failed during I/O contention spikes from other worktrees (P-5 ordered p50 267–289 ms, P-2 p95 245–265 ms): environment, not the code; the orchestrator's perf run on a quiet machine is the reference.

## Proposed REENTRANCY rows (ARCHITECTURE §10.1)
| Row | Await | Re-validated afterwards |
|---|---|---|
| b-1 | `close()`'s drain wait and its lock-release unit | the drain loop re-reads `unitsInFlight`; units resuming meanwhile see `closing` and drop their mutation; nothing after the release (closing is terminal) |
| b-2 | `requireCommitted`'s sleep until the coalescing window opens (caller's task) | the loop recomputes coverage, the in-flight flag, the window and the phase from scratch (the timer only pokes, as R9) |
| b-3 | the discard unit before a publication throws (`.unverifiedRejected`, integrity failure, superseded, cancelled claim hand-back) | nothing: the call throws right after |
| b-4 | the copy units of an extra-extension blob | the phase; the copy is a staging file no other producer names |
| b-5 | `apply`'s orphan re-stat unit | the phase; a candidate counts only if it is still an orphan of the same size and still unknown to the blob table |

## Not verified here
`F_BARRIERFSYNC`/`F_FULLFSYNC` semantics and costs on device; file protection on device (the iOS branch compiles, `xcodebuild` generic iOS); iOS 15 runtime behaviour; benchmark figures on an idle machine (this level's runs shared the machine with other worktrees, load average 7–15).
