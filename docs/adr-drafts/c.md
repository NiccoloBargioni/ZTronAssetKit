# ADR drafts — WP-C integrity, cleanup, eviction, legacy migration (Stage 2, level L3)

WP-C implements every stub of `Sources/ZTronAssetStorage/{Integrity,Cleanup,Eviction,Migration}/` on the merged WP-B
store (`l3-base`), the §11 rows whose WP column names C, the H-2/H-10 tests that fall to C, the explicit writers of
ARCHITECTURE §13.5 item 3, and ADR-050's assignments (the B-36 test, the package initialisers through real APIs, the
B-16 seams). No public or package signature changed. Tests live in `Tests/ZTronAssetStorageTests/Cleanup/`, the legacy
fixture in `Tests/Fixtures/legacy-v0/`. Every choice below was made without stopping, as CLAUDE.md asks; the
orchestrator numbers them.

## C-1 — Eviction candidates are blobs, evicted with all their records
- **Context.** R-CLN-4 orders *assets*; bytes are freed per *blob*, and identical bytes dedupe (SPEC §4.3), so evicting
  one record of a shared blob frees nothing.
- **Decision.** A candidate is a live blob, not being placed (`publishing`), unleased, whose present records are all
  evictable (not essential, not pinned, not protected by the dry run's `protecting`, last access at least
  `max(minimumResidency, deletionGrace)` ago; an access stamped in the future counts as recent). Order: every record
  outside the retention scope first (ADR-027), then the blob's most recent access (LRU), larger first on ties, then
  the key (total order, R-SYN-1). `EvictionPlan` lists one victim per record (identifier order within a blob), each
  carrying the blob's size; `EvictionPlan.bytes` counts each blob once. `applyEviction` and the maintenance run
  re-validate per blob: the blob's present records must be exactly the planned victims, each still evictable and not
  accessed since the selection (REENTRANCY R8), otherwise the blob is skipped.
- **Consequences.** Sizes come from the records' `present(byteSize:)` (every record of a blob records its size, I-2).
  Pure and shared by the dry run, maintenance and the report (`EvictionOrder`).

## C-2 — How much quota eviction frees
- **Decision.** `bytesToFree(used, available, pendingReclaim)`: the budget is resolved over usage plus free space plus
  the pending reclaim (doomed bytes the reaper frees after grace, store-2 S2-06); eviction triggers when usage exceeds
  the budget or free space plus pending reclaim is below `reserveFreeBytes`, and evicts down to
  `min(hysteresis × budget, used − reserve shortfall)` (store.md §6.4). Free space is `FreeSpace.volumeImportant`.
- **Consequences.** `FreeSpace.budgetBytes` (WP-B) resolves over usage plus free space only, so the two figures differ
  by the pending reclaim for a fractional budget; eviction's is the one store.md §6.4 specifies. A second run within
  the grace window evicts nothing more (test `R-CLN-4: evicting twice within the grace window…`).

## C-3 — What `evictIfNeeded()` reports
- **Decision.** `CleanupResult.bytesFreed`/`filesRemoved` of quota eviction are the bytes and blobs released to the
  reaper by this run (they leave `FreeSpace.usedBytes` at once and are unlinked after acknowledgement and grace);
  `bytesDeferred` is 0 (leased blobs are never selected). The run publishes the snapshot without the victims
  (`.userInitiated`) and returns after an ordered commit; a failed commit throws and leaves the evictions dirty (R5).
  A shortfall (protected bytes over target) is logged with a count, no identifier. A blob whose records were all
  evicted but which stays live (an in-flight publication of the same bytes under another id holds a provisional
  `.reused` reference) counts in neither figure; the run still stamps, publishes and commits the evicted records
  (review round 1; test `R-CLN-4: eviction reports no removed file when an in-flight publication of the same bytes
  keeps the blob`, committed failing first in `3077533`).
- **Consequences.** The engine sees freed space through `freeSpace()` immediately; `runDueWork()`'s `reapedBytes`
  reports the unlinks.

## C-4 — `lastCleanupAt` is stamped only by a run that changed something
- **Decision.** Orphan GC, staging GC, quota eviction (maintenance and `apply`'s plan) and purge stamp
  `lastCleanupAt` (persisted with the next commit, a lazy mutation) only when they removed, evicted or purged
  something. A cancelled orphan or staging GC accounts for what its earlier units removed (stamp, `gcBytes`, the
  report's orphan table) before it throws `.cancelled` (review round 1; tests `R-CLN-12: a cancelled orphan GC keeps
  what it removed, counts it and stamps the cleanup` and `R-CLN-12: a cancelled staging GC keeps what it removed and
  stamps the cleanup`).
- **Consequences.** R-CLN-12's second run is a strict no-op: no file-system mutation, no record, blob-table or stamp
  change (test `R-CLN-12: every cleanup operation run twice is a no-op the second time`, six operations).
  `StorageReport.lastCleanupAt` therefore means "the last cleanup that did something".

## C-5 — Purge
- **Decision.** (1) Every purge bumps `purgeEpoch` before its first own await (an empty selection too, so a running
  sync can never stamp across a purge request). (2) Selection: `.all` every record holding a blob; `.scope` those in the
  scope; `.evictable` the records of every live, unleased, not-being-placed blob none of whose records is essential or
  pinned (no residency window: the user asked). (3) Records become `absent(.purged)`, blobs are doomed `purged`. (4)
  Every purge that removes something, and every `.all`, clears the stamp and sets "sync due" in the same commit (SPEC
  R-CLN-6 says each purge "makes a sync due"); an empty `.evictable`/`.scope` purge changes nothing else. (5) The
  snapshot is installed at once, the generation committed, then the caller's task waits: it reaps
  (`reapDeletable`), sleeps on `TimeSource.sleep(until:)` until the earliest `DoomInfo.eligibleAt` of the selection
  (awake clock converted to the monotonic one), installs one fresh snapshot after the grace (ADR-017), and stops when
  every selected blob is reaped or rescued or only waits for something time cannot clear (a lease, a sink that does
  not acknowledge, a failed unlink's backoff). (6) `bytesFreed` counts the selection's bytes deleted before the return,
  `bytesDeferred` those still leased; bytes held back by a non-acknowledging sink are in neither (the reaper takes
  them later). A cancelled caller gets `.cancelled` from the wait; the purge is already committed.
- **Consequences.** Purge waits on contract fields (`blobTable`'s `DoomInfo`, the leases) and primitives only, not on
  the reaper's internal blocker (C-16).

## C-6 — Apple-adopted assets are not ranked after ordinary ones
- **Context.** `EvictionPlan`'s doc and ADR-027 rank Apple-adopted assets after ordinary ones of the same class.
- **Decision.** Not applied: a record carries no tier and a store serves one tier at a time, so within one store the
  rule has nothing to compare. If a client mixes tiers in one store (kill switch flipped), the rule needs a record flag
  (an index-format change), for the orchestrator.

## C-7 — Integrity bookkeeping (R-INT-3, R-NET-6)
- **Decision.** `IntegrityBookkeeping.failure` (pure): a failure of another identity than the recorded one restarts the
  count; `attempts` saturates; the backoff is `StoragePolicy.integrityBackoff(afterAttempt:)`, a non-finite one waits
  until `Date.distantFuture`; at the cap `nextEligibleAt` is cleared and the record becomes `failed`.
  `recordIntegrityFailure` skips records whose identity changed and records already `failed`; a record without a blob
  becomes `quarantined(until:)`; a record still serving stale bytes **keeps serving them** during the backoff
  (store.md §6.1: stale content stays visible until the new bytes commit) and loses them only when it becomes
  `failed(.integrity)` (its old blob is doomed `unreferenced`: those bytes are healthy). `recordFailure` marks
  `failed(reason)` literally (a stale blob goes too). Both commit (ordered) before returning; a dropped blob is first
  published out of the snapshot (`.bulk`).

## C-8 — Quarantine and deep verification share one path
- **Decision.** `quarantine(blob:)` puts every record of the blob through C-7's bookkeeping with its own identity:
  `quarantined(until:)`, or `failed(.unreadable)` at the cap; the blob is doomed `corrupt` (never re-adopted or
  rescued, ADR-018; the next verified download replaces the name). `reportUnreadable` of a record without a blob is a
  no-op, so a second report changes nothing. Deep verification takes live, referenced blobs not yet verified in the
  current pass, oldest `verifiedAt` first (never verified first), then by key; the pass is tracked in memory
  (`IntegrityState.verifiedInPass`, so a wall clock set back cannot make a pass endless; after a relaunch the
  persisted `verifiedAt` resumes it about where it stopped); `cursor` records the last id checked. A slice stops at
  its deadline, and before a blob that would take it past `byteBudget` (the first blob of a slice always runs, so a
  blob larger than the budget is still verified). A digest or size mismatch, or a blob whose read fails, quarantines.
  Nothing runs while degraded (R16). Quarantines are installed at once; their commit follows in the coalescing window.

## C-9 — Staging GC
- **Decision.** One listing (R14), then removals in units of `deletionBatchSize` and at most 1 ms of the injected clock
  (the reaper's B-10 bound): a name that does not parse, or an item that is not a regular file, is collected at once;
  one of ours older than `stagingMaxAge` is collected even when claimed; an unclaimed one older than
  `stagingClaimGrace`. An item without a modification time, or one modified in the future, is kept. Launch epochs are
  never compared (ARCHITECTURE §4.5). The caller must claim every transfer it still works on, those with a
  publication in flight included (their `.verifying` file is kept by the claim or the grace). A cancelled caller stops
  between units with `.cancelled`, after accounting for what it removed (C-4).

## C-10 — Orphan GC
- **Decision.** Mark: the blob table, `publishing`, and the adoption key (`expectedKey`) of every record (a later
  `apply` or launch adopts such a blob instead of downloading it). The listing (one unit for `blobs/`, one per
  fan-out, non-following) must complete before any decision; a deadline that passes first sweeps nothing. Sweep:
  unmarked well-named blobs in their own fan-out older than `orphanGrace` (no modification time: kept), re-checked
  against the marks right before each removal unit is submitted (same actor turn), removed in units as C-9, stopping
  at the deadline. Suspended while degraded (S1-11) or unwritable (B-15/B-34, through `checkWritable()`). The
  unreferenced blobs it leaves (young or adoptable) are remembered for the report (`CleanupState.orphans`).
- **Residual risk, reported as CCR-1.** The unlink unit runs off the actor: between the sweep decision and the unit, a
  publication of the very same bytes for a record that did not expect them at decision time (a checksum-less
  re-download, or a manifest applied in that window) can find the orphan by exclusive rename (`EEXIST`, same size,
  keep), bind it, and lose it to the unit. The mark of expected keys and the same-turn re-check make the window one
  executor hop; closing it needs WP-B's blob table (CCR-1).
- **Residual race 2, reported as CCR-2 (review round 1, ZProbe4).** `apply` confirms a launch orphan in one unit and
  binds it only after its plan unit and write chunks (WP-B, `adoptKnownBlob`'s `case nil` uses that confirmation). No
  record expects the key in that window and the blob table does not know it, so a sweep removes it and `apply` then
  binds the record to a missing blob (I-2). The window is a whole plan unit, not one hop. Reproduced deterministically
  by `R-CLN-2: orphan GC never sweeps a launch orphan that a running apply is about to adopt`, committed under
  `withKnownIssue` (it fails as soon as the race is closed, so the wrapper goes with the fix). WP-C cannot close it
  alone: GC cannot see `apply`'s incoming manifest, and the fix writes WP-B bookkeeping (`state.core.orphans`) and
  edits `AssetStore+Apply.swift`.

## C-11 — Storage report
- **Decision.** Live blobs come from the records (`bytesByKind` by the blob's lowercased extension; a blob any current
  record still wants counts as present, otherwise stale); `pendingDeletion` is `FreeSpace.pendingReclaim` plus the
  doomed blobs still leased (sizes recorded with the lease, `CleanupState.leasedBytes`); `evictableBytes` sums C-1's
  candidates; `orphanBytes` is what the last orphan GC listing of this lifetime left (0 before one); staging bytes and
  free space take one unit each and are 0 before `open()` or when the read fails; `sourceCopyBytes` is 0 (the engine
  adds the source's, ADR-027); `budgetBytes` is `FreeSpace.budgetBytes`.

## C-12 — The legacy plan
- **Decision.** The path rule is the prior art's (`localPathComponents`, else the identifier's dot segments without
  the last; file name `resolvedFileName.fileExtension`, extension as published). Every component must be non-empty,
  not `.`/`..`, free of `/` and NUL, ≤ 255 UTF-8 bytes (R-SEC-2); the file must appear in a **non-following** listing
  of the root (a symbolic link is neither descended into nor listed, S2-10; at most 64 levels and `maxEntries`
  directories). The expected digest is the manifest checksum, or for a checksum-less entry the prior art's local
  checksum (64 lowercase hex digits; anything else came from a custom `computeChecksum`). An entry whose local
  checksum disagrees with its manifest checksum is dropped (the prior art stored other bytes, the file is stale); one
  with neither is dropped. Entries naming one file share it when they expect one digest; a later one expecting another
  is dropped. The legacy manifest is decoded under `configuration.limits` with duplicates keeping the first.
- **Deviation from store.md §7 (for the orchestrator).** store.md hashed checksum-less files without a local checksum
  in phase 1; ADR-029 moved all hashing out of `open()`, and SPEC R-STO-11 adopts files "whose checksum verifies", so
  such files are dropped and downloaded again instead (the prior art always recorded a local checksum when it stored a
  file, so this case needs a failed hash in the prior art).

## C-13 — Legacy phase 1 inside `open()`
- **Decision.** Skipped in a lifetime that cannot write (B-34) and when the root cannot be stat-ed (no decision on an
  I/O error). Before migration started, a missing root (a symbolic link counts as missing, never followed) removes the
  prior art's `UserDefaults` key and migrates nothing (D-6). Otherwise phase 1 reads the stamp (only when starting),
  `manifest.json` and `local-checksums.json` (whole, ≤ `maxPayloadBytes`, 1 MiB units), lists the tree, decodes off
  the actor, and — when starting — writes exactly ARCHITECTURE §1.1 rule 1's set: the legacy manifest becomes the
  applied one (ETag `nil`) only while the applied manifest is empty; a record is inserted only for an id the applied
  manifest lists and the index lacks, as `absent(.neverFetched)` with the applied entry and `expectedBlob` = the
  applied checksum, or, for a checksum-less applied entry with the legacy content identity, the planned digest; an
  undecodable (or unreadable, or oversized) manifest sets `degraded`; then `legacyStamp`, phase `inProgress`, one
  ordered commit. A failed phase-1 commit is logged and tolerated (the launch commit retries it); phase 2 commits
  before the first file moves (`planCommitted`; test `R-STO-11: no legacy file moves before a generation holding the
  phase-1 plan is committed`, which fails with the gate removed), and so does an adopt-on-demand (review round 1,
  ZProbe2: `adoptLegacyNow` bypassed the gate; test `R-STO-11: an adopt-on-demand moves no legacy file before a
  generation holding the phase-1 plan is committed`). A relaunch in phase `inProgress` rebuilds the plan without
  writing and marks the state dirty, so its first move waits for a commit of this lifetime: B-36 counts the loaded
  generation committed only after the barrier, and a launch whose barrier and launch commit both failed must not move
  files on a plan that only an unsynced `index.tmp` may hold. The launch commit normally covers the mark already
  (`requireCommitted` then returns at once). Test `R-STO-11: a relaunch in phase inProgress whose barrier and launch
  commit failed commits before moving a legacy file`. Files nothing wants any more are counted dropped unless a record
  already holds their bytes. Phase 1 publishes no snapshot.
- **Deviation from store.md §7 (for the orchestrator).** An undecodable legacy manifest does not hash and move the
  legacy files as protected orphans: placing a blob with no record that expects it needs a store primitive that does
  not exist (the same gap as CCR-1). The launch is degraded as the contract says, nothing is adopted, and phases 3–4
  remove the tree and the key with a sync due, so those files are downloaded again. A legacy root without
  `manifest.json` (the prior art creates the directory at init) migrates nothing and never the stamp.

## C-14 — Phase 2 and adopt-on-demand
- **Decision.** Files are processed in path order from a queue; a file being processed is claimed. Each file is hashed
  (`hashFile`, R11), re-validated (records still expect the digest and accept adoption; digest and stated size match)
  and adopted through `adoptVerifiedFile` (rename from the legacy tree, dedupe onto a live key); lifecycle and
  cancellation errors end the call (the file goes back to the head of the queue), every other failure drops the file
  — unless a record meanwhile holds its bytes (adopted by a racing call). `adoptLegacyNow` returns the current location
  when the asset is present; otherwise it adopts the asset's file at once (taking it from the queue; when a batch holds
  it, it processes it too and the record decides, R18) and installs the snapshot at once. Each adoption is counted once,
  by the call that adopted the file (the other one sees it `alreadyAdopted`); a drop only by the call that took the
  file from the queue. Batches publish at bulk urgency. Progress is cumulative per lifetime; `finished` once the tree is
  gone. A legacy root on another volume cannot be renamed into `blobs/`: such files are dropped and downloaded again
  (store.md's EXDEV copy needs a store copy primitive; iOS keeps `Caches` and `Application Support` on one volume).

## C-15 — Phases 3 and 4
- **Decision.** Phase 3 migrates the stamp (`SyncStamp(appVersion: legacyStamp, …)` over the applied digest) only when
  a legacy manifest was decoded and every one of its entries is present at its current content, and never over a
  stamp the engine wrote meanwhile; when not every entry was adopted and no stamp exists, it sets "sync due". Phase
  `done` is committed **durably** before phase 4, on every call: a `migrateLegacy` that finds `done` with the removal
  unfinished requires that commit again, because the call that wrote `done` throws when its durable commit fails and
  `done` is then in memory only (review round 1, ZProbe1: a retry removed the tree and the key, and a relaunch lost
  the stamp; test `R-STO-11: no call removes the legacy tree or the key before a generation holding "done" is durably
  committed, and a relaunch still migrates the stamp`). Phase 4 stats the root without following it: anything but a
  directory there (a symbolic link that replaced the root) is unlinked itself and never listed, since a listing
  follows a final link (ZProbe3; test `R-SEC-2: phase 4 removes a symbolic link that replaced the legacy root, never
  what it points to`); a root it cannot stat is left for the next call (`R-STO-11: phase 4 leaves a legacy root it
  cannot stat for the next call, which removes it`). Otherwise it lists the tree without following links, removes
  every file and link (never a target), then the directories deepest first, then the root, then the `UserDefaults`
  key. Phase 4 is idempotent: a relaunch in phase `done` with the tree or the key left returns
  `legacyMigrationPending`, and the next `migrateLegacy` finishes it.

## C-16 — How WP-C reaches WP-B
- **Decision.** WP-C writes `StoreCoreState` only where its doc allows (records' `pinned`/`integrity`/`verifiedAt`,
  `purgeEpoch`, `stamp`, `syncDue`, the three metrics, and legacy phase 1's set) and reads only the contract fields
  above `StoreCoreState`'s "WP-B bookkeeping" mark (`phase`, `layout`, `records`, `blobTable` with its `DoomInfo`,
  `publishing`, `degraded`, `appliedManifest`, `etag`, `committedGeneration` in tests). Besides the primitives of
  `StoreInternals.swift` and WP-B's package API (`location`, `recordAccesses`, `freeSpace`, `nextDeadline`), it calls
  four WP-B lifecycle helpers no primitive replaces: `awaitOpen()` (async APIs await a running `open()`, R1; `open()`
  itself would open a created store), `checkLive()` (the phase check after every await), `checkWritable()` (rule 4a)
  and `runUnit(on:)` (units counted for `close()`'s drain, S1-09: an uncounted WP-C unit could outlive `close()`).
  An earlier draft of this level read `blobBytes`, `unavailable`, `orphans` and the reaper's `deletionBlocker`; commit
  `dd7605d` removed every such read.

## C-17 — B-16 seams replaced (ADR-050)
- **Decision.** In WP-B's `Tests/ZTronAssetStorageTests/Core/` (authorised by ADR-050's assignment; no concurrent
  writer at L3): `testSetLease`/`testClearLeases` → `acquireLease`/`releaseLease` (StoreDeletionTests), 
  `testSetRetentionScope` → `setRetentionScope` (StoreReentrancyTests), `testSetIntegrity` → two
  `recordIntegrityFailure` calls (StoreApplyTests), `testBumpPurgeEpoch` → an empty `purge` (StoreApplyTests); the
  seam declarations are deleted. Kept: `testExpect` (only phase 1 sets `expectedBlob` on an existing record, at
  insertion), `testInsertRecord` (no API inserts without adoption), `testRaiseApplyFence` (WP-B's own fence).
  Assertions unchanged.

## C-18 — The `legacy-v0` fixture
- **Decision.** Produced by the prior art itself (read-only copies of `CDNAsset.swift` and `CDNLocalStore.swift` in a
  throwaway package under the git-ignored `.build-c-legacy/`, driven through `aws/v1.json` then
  `aws/v2-checksum-change.json` as `CDNSyncCoordinator` does); `Tests/Fixtures/legacy-v0/README.md` records the
  commands, the driver, the sources' hashes and every file's hash. Nothing was written into `../ZTronCarouselCore`.
- **Consequence.** `python3 Tests/Fixtures/generate_fixtures.py --check` lists `legacy-v0/` as not produced by the
  generator, as it already lists WP-B's `index/v1/` at `l3-base`; no gate runs that check.

## C-19 — Signpost intervals (ARCHITECTURE §13.5 item 2)
- **Decision.** Orphan GC and staging GC run inside one `.gc` interval each, quota eviction inside one `.eviction`
  interval; tests assert them through the tap (`R-OBS-1: quota eviction runs inside exactly one eviction interval`,
  and the gc interval in `R-CLN-2: orphan GC removes…`).

## C-20 — The index state space with legacy phase 1 (companion of B-33)
- **Context.** The task asks to extend `IndexCommitStateSpaceTests` when WP-C adds index-file mutations. Legacy phase 1
  commits inside `open()` before its root barrier, a point of the lifetime WP-B's enumeration never reaches.
- **Decision.** A companion suite in WP-C's own directory (`LegacyPhaseOneStateSpaceTests`, reusing WP-B's `IndexSpace`
  helpers read-only; WP-B's file is not edited): every one of the 392 unforged initial index disks (49 rows of 8) with
  a legacy tree; lifetime `open()` (phase 1, barrier, launch commit) then `close()`; events: none, EIO at every
  index-file or root operation up to and including the barrier, ENOSPC at every `index.tmp` write there, each also on a
  volume that fills up after phase 1's first index write (so the launch commit and the flush fail, B-36's sequence),
  and a crash before every mutation of that window in every mode (a torn write only at writes). Invariants: B-33's
  I-a under every crash view of the survivor (or the crash's own view), and I-b when `open()` returns without a crash.
  About 600 cases per row, 30,000 in all (every case still checked; only identical work is shared, see below).
- **Consequences.** Found nothing in the shipped code (its first version reported I-b "violations" that were the
  test's own: it read the crash image of a crashed run; fixed by holding crashed runs to I-a only). Mutation check:
  B-36's cycle-5 rule reverted in a scratch edit of `AssetStore+Open.swift` (adopt the loaded ledger after the barrier
  even when phase 1 committed) fails 27 of 49 rows (e.g. "bin=newer prev=badHeader tmp=absent, no fault, full after
  phase 1: I-b: generation 11 counted in index.bin, which holds 12"); a single-event version without the full volume
  missed that mutant, hence the second volume.
- **Cost and scheduling (review round 1).** All 49 rows used to start at once, so each row's one-minute limit measured
  the whole suite: on a host at load ~36, 48 of 49 rows timed out, and under TSan all 49 did. Now the rows run one at a
  time (`.serialized`), each enumerating its eight disks two at a time (`width`) as low-priority child tasks that
  yield once per case, and identical work is shared (every case is still checked): one kill run per crash point gives
  the counted generation and the survivor, whose power-loss views are derived as B-33's `MutationRecorder` does (the
  fake fails mutation k in every mode; only `survivingDisk()` differs); a torn write is run again at writes only; a
  free-volume run that never attempted a second `index.tmp` write is also the full-volume run (the full volume fails
  only the second and later writes); the initial disk's floors are computed once; and the load rule's choice is
  memoized per distinct set of index files (the power-loss view that drops unsynced state is read from the survivor's
  durable files, checked once per disk against the fake's own view). Two disks at a time, not eight: with eight, WP-H's
  start/stop race (400 rounds, about 80,000 `Task.yield()`s) took 55.6–58.1 s of its 60 under TSan beside this suite
  (30.7 s without it); with two, 37.1 s. Cost: about 25 s of CPU in debug on this Mac (was 112 s), about 0.5 s per row,
  12 s of wall time alone, 120 s under TSan. The space is asserted, not printed: every disk ran, and each disk's fault
  and crash-view counts equal the counts its window implies. The B-36 mutation check still fails 27 of 49 rows.

## Contract change requests

- **CCR-1 — an orphan-doom primitive for orphan GC (`Store/StoreInternals.swift`, WP-B/orchestrator).** Proposed:
  `func doomOrphans(_ orphans: [BlobKey: Int64]) -> [BlobKey]`: for each key unknown to the blob table and not in
  `publishing`, insert `.doomed(DoomInfo(reason: .unreferenced, sinceSnapshotVersion: <current version>,
  droppedInGeneration: 0, eligibleAt: uptimeNow))` with its size, and return the keys doomed. The reaper then unlinks
  them under the I-3 protocol (a fresh acknowledgement, no lease), and a publication or adoption of such a key rescues
  it (ADR-018) instead of losing it. `collectGarbage` would doom instead of unlinking and report what the reaper frees.
  Until then C-10's residual race stands; it needs a publication of byte-identical content to an orphan older than
  `orphanGrace` within one executor hop of the sweep. The same primitive (or a "place without records") would let an
  undecodable legacy manifest keep its files as protected orphans (C-13).

- **CCR-2 — close the orphan sweep / `apply` adoption race (C-10, review round 1 ZProbe4; WP-B and the orchestrator).**
  Two halves, both needed (checked together in a scratch copy, see Evidence): WP-C, in the turn that submits a removal
  batch, sets `self.state.core.orphans[key] = nil` for each swept key (a write to WP-B bookkeeping that §1.1 rule 1 does
  not allow WP-C today); WP-B, in `adoptKnownBlob`'s `case nil` (`Store/AssetStore+Apply.swift`), binds only when
  `confirmed[key] != nil && self.state.core.orphans[key] == confirmed[key]`. A key `apply` bound before the GC decision
  is in the blob table and stays marked; one a decision swept is no longer adoptable. CCR-1's doom-instead-of-unlink
  primitive closes it too (the swept key would be doomed `unreferenced` and rescued by `apply`). The known-issue test
  `R-CLN-2: orphan GC never sweeps a launch orphan that a running apply is about to adopt` then passes, and
  `withKnownIssue` must be removed from it.

## Open issues (for the orchestrator)

- **OI-1 — `apply` rescues blobs that quota eviction just doomed.** `ApplyPlan.adoptionCandidates` includes records in
  `absent(.evicted)` (they accept adoption), and `adoptKnownBlob` rescues a key doomed `unreferenced`. So any `apply`
  within the deletion grace after an eviction binds the evicted records again, undoing the eviction until the next
  run (found by the oracle test; reproduction: evict `a`, then `apply` the same manifest before `runDueWork()` reaps:
  `a` is present again). Launch adoption of evicted records is intended (crash recovery, ADR-018); in-lifetime it
  defeats R-CLN-4 for the grace window and can make maintenance eviction and sync thrash. Suggested WP-B fix: adopt
  `.evicted` records only at launch (or skip keys doomed by eviction in this lifetime). WP-C's files cannot change it
  (the residency and doom reason of eviction are contract). The oracle test reaps right after evicting.
- **OI-2** — `FakeFileSystem` makes `.barrier` and `.full` identical (ADR-049), so phase 3's durable commit before the
  key removal is asserted by code reading only.
- **OI-3 — benchmarks (informational).** The round-1 reviewer's release runs failed WP-B's P-13 (longest deletion unit
  13.37 ms and 10.44 ms against 5 ms; p95 0.99 ms) at load averages of 65–75; WP-C changed no reaper code and owns no
  benchmark (ARCHITECTURE §1.2). The orchestrator re-runs `--perf` on an idle machine at merge (ORCHESTRATION.md).

## Proposed REENTRANCY rows (ARCHITECTURE §10.1)

| Row | Await | Re-validated afterwards |
|---|---|---|
| c-1 (proposed) | the removal units of `collectStaging`, `collectGarbage` and legacy phase 4 (`removeInUnits`, `removeAllInUnits`) | the phase; the next unit starts only after the caller's cancellation and the deadline are checked (a cancellation ends the loop with the partial result, which the caller accounts for before it throws `.cancelled`, C-4); for orphans the sweep set of each unit is re-checked against the blob table, `publishing` and the records' adoption keys in the turn that submits it (C-10) |
| c-2 (proposed) | `storageReport()`'s staging listing unit | nothing: the sum is a snapshot; the report's other figures are read from the state after the await |
| c-3 (proposed) | `verifyIntegrity`'s trailing snapshot install | nothing but the phase (as R17): the quarantines were made synchronously before it and the report describes them |
| c-4 (proposed) | legacy phase 4's stats, listing and removal units and the `UserDefaults` key removal; the key removal of phase 1 when no tree exists | nothing: after the durable "done" commit (or with no tree before migration) the tree and the key are the migration's alone, and every step is idempotent; the root's kind is a snapshot taken without following it, and anything but a directory is unlinked, never listed |

Existing rows WP-C's awaits cite: R1 (async APIs await `open()`; phase-1 units), R3/R4 (through `adoptVerifiedFile`),
R7 and R9 (purge's reap and grace wait), R8 (eviction chunks), R10 (orphan listing), R11 (migration units), R12
(purge's fresh install), R13 (`freeSpace()` in eviction and the report), R14 (staging listing), R16 (deep
verification hashes), R17 (trailing commits and installs of pins, failures, quarantine, eviction, purge, migration
phases), R18 (adopt-on-demand).

## Review round 1 — dispositions

Two lenses (requirements, correctness) reported 21 issues, 8 of them blocking. Every one is fixed or routed. None is
declined except where noted.

| # | Lens, issue | Disposition |
|---|---|---|
| 1 | reqs, blocking: the legacy state-space suite overran its limit on a loaded host and under TSan | C-20: rows serialized, two disks at a time, identical work shared, about 25 s of CPU instead of 112; evidence below |
| 2 | reqs, blocking: nothing pinned the hysteresis target | `R-CLN-4: eviction goes down to the hysteresis target, not just under the budget, least recently used first even when smaller` (maintenance and dry run + `apply`); mutant M1 caught |
| 3 | reqs, blocking: nothing pinned the `deletionGrace` half of the residency window | `R-CLN-5: eviction never takes an asset accessed within the deletion grace, even with no minimum residency` (both routes); mutant M2 caught |
| 4 | reqs, blocking: the S2-13 tests dereferenced only through `reportUnreadable` | both tests parameterized over `apply` dropping, `reportUnreadable`, `evictIfNeeded`, `apply` with a plan and `purge(.scope)`; held commit asserts `.commit`, held install `.acknowledgement` and a grace that starts only with the later acknowledgement |
| 5 | reqs: three WP-B `Core/` test files edited | none needed (ADR-050, C-17); for the orchestrator at merge |
| 6 | reqs: `apply` undoes an eviction within the grace (OI-1) | routed to WP-B and the orchestrator (OI-1, unchanged) |
| 7 | reqs: uncovered regions | added: an unreadable legacy manifest (a directory, a failed stat, a failed read), a failing and a cancelled orphan listing, cancelled orphan and staging GC; not added: the eviction chunk yield (needs over 1,000 blobs in one run) and an oversized manifest (`CoreHarness.cleanup` takes no manifest limits; the size check shares its `.unusable` branch with the cases added) |
| 8 | reqs: staging GC's `.gc` interval unasserted | asserted in `R-CLN-3: staging GC removes unowned partial files at launch and after sync` |
| 9 | reqs/correct: awaits without a `// REENTRANCY:` line | added (`LegacyPhases.swift` phase 1 guard; every await of `removeLegacyTree`) |
| 10 | reqs: test hygiene | `heldWaiters` removed; `planCommitted` and `migration.queue` reads replaced by the operation log and `migrateLegacy(maxFiles: 0)`; `leasedBytes` kept (bookkeeping no API shows) beside a new report check |
| 11 | reqs: P-13 failed on a loaded host | OI-3 (WP-B's benchmark; WP-C owns none) |
| 12 | correct, blocking: a retry in phase `done` removed the tree and the key without a durable commit | C-15; failing test first (`2aa12bb`), fix `595ef4b`; mutant M7 caught |
| 13 | correct, blocking: `adoptLegacyNow` bypassed the plan-commit gate | C-13; failing test first, fix `595ef4b`; mutant M6 caught |
| 14 | correct, blocking: phase 4 followed a link at the root | C-15; failing test first, fix `595ef4b`; mutant M8 caught |
| 15 | correct, blocking: orphan GC sweeps a launch orphan `apply` is about to bind (I-2) | not fixable inside WP-C's write set: reproduced by a known-issue test (`f862873`), both halves proposed as CCR-2 and checked together in a scratch copy (mutant M10: the known issue disappears) |
| 16 | correct: suite robustness under load | as 1 |
| 17 | correct: `filesRemoved` counted a blob that stayed live | C-3; the claim was unproven, the failing test (`3077533`) proved it; fix `e0fec7c`; mutant M9 caught |
| 18 | correct: a relaunch set `planCommitted` without a commit of its own | C-13: the relaunch marks the state dirty; failing test (it first failed for a wrong reason: one failed write is retried, so the corrected test fails both launch-commit writes); fix `595ef4b`; mutant M5 caught |
| 19 | correct: a cancelled GC skipped its bookkeeping | C-4; fix and tests `f862873`; mutant M4 caught |
| 20 | correct: `CleanupState.orphans` doc said the report uses the launch's orphans | doc corrected to what the code and C-11 say (0 before the first orphan GC) |
| 21 | correct: same as 9 | as 9 |

## Not verified here

- Device behaviour of the legacy rename (`Caches` → `Application Support` on one APFS volume) and of a legacy root on
  another volume (dropped, C-14); `LiveLegacyDefaults` (writing real defaults is outside the repository, ARCHITECTURE
  §14); Unicode normalisation or case differences between a legacy manifest's path components and the names on disk
  (a mismatch drops the file, which is then downloaded again).
- The ordered/durable distinction of phase 3 on a device (OI-2).

## Evidence (this worktree, `wp/c`, 2026-10-09, fix round 1; this Mac, 8 cores)

- `SWIFTPM_SCRATCH=.build-c bash Scripts/verify.sh --quick` at `4255271`: `VERIFY: PASS` (Storage bundle `Test run with
  392 tests in 54 suites passed after 57.114 seconds with 2 known issues`, the 2 known issues being CCR-2's test).
- Three consecutive `swift test --filter ZTronAssetStorageTests` runs at `4255271` beside a TSan run and the simulator
  run: 1-minute load averages 4.4, 198.2 and 165.5 at their starts (5-minute up to 121): all `passed … with 2 known
  issues` (179.8 s, 131.6 s, 110.4 s), 0 `Time limit was exceeded`; the state-space suite took 130.3 s, 84.9 s and
  72.1 s for its 49 serialized rows. (At `d2abe9c`, eight disks at a time and no memo, three more at load 9–68: all
  green, 0 time-limit issues.)
- TSan (`--sanitize=thread`, `.build-c-tsan`, Storage bundle) at `4255271`, host load 4–9: `Test run with 392 tests in
  54 suites passed after 184.743 seconds with 2 known issues`, 0 ThreadSanitizer reports; the state-space suite 119.9 s,
  WP-H's start/stop race 37.1 s. Every TSan run of this round reported 0 ThreadSanitizer warnings and no time-limit
  issue in a WP-C suite; neighbours did overrun on a loaded host. The runs, in order: eight disks at a time beside my
  own three debug runs (load up to 68): WP-B's `R-STO-5: a process kill followed by a power loss in the next lifetime
  preserves I-1…I-5` (8 cases) and WP-H's start/stop race over 60 s; eight at a time at load 19–37: WP-H's race over
  60 s; without this suite (`--skip`) at load 6–19: green, WP-H's race 30.7 s; eight at a time at load 4–13: green, the
  race 58.1 s and 55.6 s; two at a time at load 4–9: green, the race 37.1 s (the run quoted above); two at a time
  beside the three runs above (load up to ~200): WP-B's 8 cases and WP-H's race over 60 s again, this suite green
  (315.6 s). WP-H's race (about 80,000 `Task.yield()`s) takes 0.26 s alone under TSan. For the orchestrator: neither
  overrunning test is WP-C's.
- `swift build -c release --scratch-path .build-c -Xswiftc -warnings-as-errors`: `Build complete!`, exit 0.
- `xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath .build-c/xcode build
  OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet`: exit 0, no compiler error or warning.
- iOS Simulator (iPhone 18 Pro `897F9D8D…`), `caffeinate -i xcodebuild test … -skip-testing:ZTronAssetKitBenchmarks
  -collect-test-diagnostics never OTHER_SWIFT_FLAGS='-warnings-as-errors'` at `4255271`: `** TEST SUCCEEDED **`,
  xcresult summary `{'result': 'Passed', 'totalTestCount': 756, 'passedTests': 755, 'failedTests': 0, 'skippedTests':
  0, 'expectedFailures': 1}` (the expected failure is CCR-2's known issue), 0 "Restarting after", 0 "exceeded
  execution time"; the simulator is shut down.
- `gates.py unsafe`: `UNSAFE escapes found=0 max=3`, `UNSAFE: PASS`. `gates.py docs`: `DOCS public declarations=1281
  documented=1281 exempt=0 fraction=100.0%`, `DOCS: PASS`. `gates.py selftest`: `SELFTEST: PASS`. `gates.py trace`
  (written to the scratch path): `TRACE MUST without a test (7): R-CAR-1, R-SYN-12, R-SYN-13, R-SYN-14, R-SYN-4,
  R-SYN-6, R-SYN-7`, none WP-C's (unchanged).
- Coverage (`swift test --enable-code-coverage --skip Benchmarks`, `llvm-cov export` over all bundles):
  `COVERAGE target=ZTronAssetStorage lines= 97.08% (6705/6907) min=90.0 OK`; WP-C's files 1717/1792 = 95.81% (96.40%
  without `LiveLegacyDefaults.swift`, deliberately untested, ARCHITECTURE §14; was 95.27%). Kit and Sync fail on
  WP-F/WP-G stubs, as expected at L3.
- Benchmarks: WP-C owns none (ARCHITECTURE §1.2); not run (OI-3).
- Mutation checks of this round (scratch copy `.build-c/mut`, its sources identical to the branch's; each mutant
  reverted after its run): M1 hysteresis forced to 1 → the hysteresis test fails (both routes); M2 residency =
  `minimumResidency` → the grace test fails (both routes); M3 B-36's cycle-5 rule reverted → 27 of 49 state-space rows
  and `LegacyCommitTests` fail (as before the restructuring); M4 `removeInUnits` throwing on cancellation → both
  cancelled-GC tests fail; M5 relaunch not marking dirty → the relaunch gate test fails; M6 `adoptLegacyNow` without
  the gate → its test fails; M7 `done` branch without the durable commit → its test fails; M8 a linked root listed →
  `R-SEC-2: phase 4 removes a symbolic link…` fails; M9 a still-referenced blob counted → the reuse test fails; M10
  CCR-2's two halves applied → the known-issue test reports "Known issue was not recorded" (the race is closed).
- Earlier mutation checks (round 0) are unchanged: the phase-2 commit gate removed → `R-STO-11: no legacy file moves
  before…`; `applyEviction` evicting nothing → the oracle (16 of 16 seeds); the old adoption counting → `R-STO-11: an
  adopt-on-demand racing a batch on the same file adopts it once…`.
