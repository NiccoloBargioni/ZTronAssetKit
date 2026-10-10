# ADR drafts — WP-C integrity, cleanup, eviction, legacy migration (Stage 2, level L3)

WP-C implements every stub of `Sources/ZTronAssetStorage/{Integrity,Cleanup,Eviction,Migration}/` on the merged WP-B
store (`l3-base`), the §11 rows whose WP column names C, the H-2/H-10 tests that fall to C, the explicit writers of
ARCHITECTURE §13.5 item 3, and ADR-050's assignments (the B-36 test, the package initialisers through real APIs, the
B-16 seams). No public or package signature changed. Tests live in `Tests/ZTronAssetStorageTests/Cleanup/`, the legacy
fixture in `Tests/Fixtures/legacy-v0/`. Every choice below was made without stopping, as CLAUDE.md asks; the
orchestrator numbers them. At the L3 close-out the orchestrator's rulings authorised exactly three edits outside WP-C's
directories, all made: the additive primitive `doomOrphans(_:)` in WP-B's `Store/StoreInternals.swift` (R2), the orphan
check in `adoptKnownBlob`'s `case nil` (R1) and the refusal of evicted records in `adoptKnownBlob` and
`ApplyPlan.compute` (R3); and one new file, `Tests/ZTronAssetKitBenchmarks/BenchCleanup.swift` (R4's C2 measurement,
C-22), nested in the benchmarks' parent suite. Cycle 3 made two more orchestrator-authorised test edits outside WP-C's
paths: WP-A's table-estimate test and its helper (`Tests/ZTronAssetModelTests/Manifest/ManifestFootprintTests.swift`,
`Tests/ZTronAssetModelTests/Support/DecodeMeasurement.swift`; OI-8) and WP-D's loopback rig and 500-download test
(`Tests/ZTronAssetTransportTests/TransportTestSupport.swift`, `ForegroundBackendTests.swift`; OI-10). No production file
outside WP-C's directories changed in cycle 3.

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
- **Amended in review round 3 (the S2-06 regression).** That byte-budget test cannot tell whether the doomed bytes are
  counted: usage alone decides its second run. `R-CLN-4: pending reclaim decides a second eviction within the grace
  window, against a reserve and a fractional budget (store-2 S2-06)` makes free space decide it: four 10,000-byte assets,
  a reserve 15,000 bytes above free space (unlimited budget) and a `.fractionOfFreeSpace(0.5)` budget with 10,000 bytes
  free; the first run evicts two (20,000), the second nothing. The mutant `effective = max(0, available)` at
  `EvictionOrder.swift:129` fails both cases (`second == CleanupResult(bytesFreed: 20000, filesRemoved: 2)` for the
  reserve, `10000, 1` for the fraction) while the byte-budget test passes it. For the orchestrator: §12.2's S2-06 row
  should name the new test.

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
  stamps the cleanup`). A purge stamps once its commit succeeded, before the grace wait, and again when the wait ends:
  a caller cancelled during the wait gets `.cancelled`, but the purge is committed and the reaper frees its bytes, so
  it is a cleanup run (review round 2; `R-CLN-6: a purge cancelled during its grace wait…` asserts the stamp).
- **Consequences.** R-CLN-12's second run is a strict no-op: no file-system mutation, no record, blob-table or stamp
  change (test `R-CLN-12: every cleanup operation run twice is a no-op the second time`, eight operations since review
  round 3, which added deep verification after a corrupt quarantine and a finished legacy migration called again; the
  sync stamp and the migration state are compared too). `StorageReport.lastCleanupAt` therefore means "the last cleanup
  that did something".
- **Amended in review round 3 (C-23).** Orphan GC dooms in the one turn after its decision unit, so a cancelled orphan
  GC (during its listing or its decision) dooms, counts and stamps nothing and throws `.cancelled`; the test is now
  `R-CLN-12: a cancelled orphan GC dooms, counts and stamps nothing, and the next run collects every orphan` (one to one
  with `…keeps what it removed, counts it and stamps the cleanup`, whose partial state no longer exists). Its stamp and
  `gcBytes` count what it released to the reaper, as quota eviction's (C-3).

## C-5 — Purge
- **Decision.** (1) Every purge bumps `purgeEpoch` before its first own await (an empty selection too, so a running
  sync can never stamp across a purge request). (2) Selection: `.all` every record holding a blob; `.scope` those in the
  scope; `.evictable` the records of every live, unleased, not-being-placed blob none of whose records is essential or
  pinned (no residency window: the user asked). (3) Records become `absent(.purged)`, blobs are doomed `purged`. (4)
  Every purge clears the stamp and sets "sync due" before its first own await (SPEC R-CLN-6: each purge "makes a sync
  due"; amended in review round 3, ruling R4: it used to be every `.all` and every purge that selected something, which
  the off-actor selection no longer knows before its await), so the purge's commit holds it; a purge on a store that has
  no stamp and is already due changes nothing but the epoch. (5) The
  snapshot is installed at once, the generation committed, then the caller's task waits: it reaps
  (`reapDeletable`), sleeps on `TimeSource.sleep(until:)` until the earliest `DoomInfo.eligibleAt` of the selection
  (awake clock converted to the monotonic one), installs one fresh snapshot after the grace (ADR-017), and stops when
  every selected blob is reaped or rescued or only waits for something time cannot clear (a lease, a sink that does
  not acknowledge, a failed unlink's backoff). (6) `bytesFreed` counts the selection's bytes deleted before the return,
  `bytesDeferred` those still leased; bytes held back by a non-acknowledging sink are in neither (the reaper takes
  them later). A cancelled caller gets `.cancelled` from the wait; the purge is already committed.
- **Consequences.** Purge waits on contract fields (`blobTable`'s `DoomInfo`, the leases) and primitives only, not on
  the reaper's internal blocker (C-16).
- **Amended in review round 3 (C2, ruling R4).** The selection is computed and sorted on the bulk executor from a value
  snapshot (`PurgeSelection.select`), then applied in chunks of `CleanupState.chunk` (1,000) records, one actor turn each,
  with a no-op metadata unit in between (as C-21); each record is re-validated when it is purged (`purgeChunk`: it still
  references the blob recorded at selection; for `.evictable` it is still neither essential nor pinned and its blob
  neither leased nor being placed). The epoch is bumped and the stamp cleared before the selection's await, and both
  again in the turn of the last chunk: a sync that read the epoch while the selection ran, or between chunks, saw records
  the purge then removed, so it may not stamp either (`R-CLN-6: a purge clears the stamp before its selection runs off the
  actor, and a sync that read the epoch meanwhile cannot stamp`; `R-CLN-6: purge all…` now expects the epoch + 2).
  `assetsRemoved` counts the records actually purged. A purge closed between chunks leaves the chunks it made (a valid
  state: the stamp is already cleared, and a later purge removes the rest). `awaitReclaim` makes one pass per round.
- **Amended at the L3 close-out, cycle 2 (review of cycle 1).** (1) A chunk ends only at a blob boundary:
  `PurgeSelection.select` groups the selection by blob off the actor and sorts the groups by their first id, and a chunk
  takes whole groups until it holds at least `CleanupState.chunk` records. Chunks cut by record count let one blob's
  records straddle two chunks, so a holder pinned between them stayed while the other was purged, an outcome no
  sequential order of the purge and the pin gives. For `.evictable` a chunk re-reads every current holder of each blob
  (`holders(of:known:)`) and skips the whole blob when one of them is no longer evictable; otherwise it purges every
  current holder (one bound since the selection too, as a purge after that binding would). `.all` and `.scope` still
  re-validate per record. Test `R-CLN-6: a purge of the evictable set keeps a shared blob with all its records when one
  of them is pinned between chunks` (failed first in `590a02b`: `assetsRemoved == 1`, `kept == (true, true)` false; fix
  `ca27df8`; mutant: the per-record check of the round-3 chunk inside a blob group fails it, 2 issues). (2) Each round of
  `awaitReclaim` passes over the pending blobs in chunks of `CleanupState.chunk` with a no-op metadata unit in between
  (`reclaimPass`; one `PurgeSelection.Reclaim` per purged blob, the leased bytes counted in the same pass): the whole
  pass in one turn held the actor 27.6 ms for a full-store purge at `maxEntries` (2.9 ms at 10,000), measured in this
  cycle; one chunk is 0.13 ms (C-22). REENTRANCY: R9 amendment. The chunk-yield purge test now also checks the freed
  bytes summed over the pass's chunks (`28c6312`).
- **Purge during legacy migration (review round 2, a spec question; for store.md §6.5).** `purge(.all)` selects records
  holding a blob; records still waiting for a legacy file stay `absent(.neverFetched)` and later batches may adopt
  their files. Kept, and documented here rather than changed: a purge makes a sync due (R-CLN-6) and that sync fetches
  the same entries again, so adopting a legacy file whose digest verifies is the same bytes without the download; the
  legacy tree is not the store's to purge, and phase 4 removes what is left of it when migration ends. Abandoning the
  queue instead would turn a purge into a forced re-download of every not-yet-migrated file.

## C-6 — Apple-adopted assets are not ranked after ordinary ones
- **Context.** `EvictionPlan`'s doc and ADR-027 rank Apple-adopted assets after ordinary ones of the same class.
- **Decision.** Not applied: a record carries no tier and a store serves one tier at a time, so within one store the
  rule has nothing to compare. If a client mixes tiers in one store (kill switch flipped), the rule needs a record flag
  (an index-format change), for the orchestrator. Accepted as documented by ruling R5 (L3 close-out).

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
- **One incarnation per hash (review round 2, ZProbeC).** A blob's name can be replaced while it is hashed (quarantine
  or eviction, then a re-download over the doomed name, ADR draft B-24, or a reap and a new placement): the hash then
  mixes chunks of two files and quarantined the fresh, verified one. Verification stats the name (identity
  `(st_dev, st_ino)`, size) in one metadata unit before the hash and again after it; a change, or a placement of the
  key in flight (`publishing`), discards the result: no quarantine, no `verifiedAt`, and the key is not marked done,
  so the pass checks it again (`R-INT-4: deep verification discards a hash whose blob name was replaced meanwhile…`,
  failing first in `28076fa`). A write in place keeps the identity and is what verification exists to find. A
  per-key placement serial from WP-B would be an alternative; the identity needs no contract change.
- **Amended in review round 3 (C2, ruling R4).** The due list (live, referenced, not being placed, not verified in this
  pass; oldest `verifiedAt` first, then key) is built and sorted on the bulk executor from a value snapshot
  (`DeepVerification.due`, with each blob's holders at the snapshot); before each hash the blob is checked again (live,
  not being placed, not verified in this pass meanwhile), after it R16 as before, and the holders are read again with
  `holders(of:known:)` (C-21). A blob quarantined while the list is built is skipped (`R-INT-4: deep verification builds
  its due list off the actor and skips a blob quarantined while it is built`). A blob placed after the snapshot waits for
  the next pass. `quarantine(blob:known:)` takes the holders the caller saw.

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
  at the deadline. The re-check runs in the turn that submits **each** removal unit, including the units a removal
  batch's time budget splits off (`removeInUnits(recheck:)`); a file whose unlink fails stays an orphan for the next
  run and never stops the sweep, which ends only at the deadline or the caller's cancellation (review round 2; test
  `R-CLN-2: an orphan whose removal keeps failing does not stop orphan GC…`). Suspended while degraded (S1-11) or unwritable (B-15/B-34, through `checkWritable()`). The
  unreferenced blobs it leaves (young or adoptable) are remembered for the report (`CleanupState.orphans`).
- **Residual risk, reported as CCR-1 — closed at the L3 close-out (C-23).** The unlink unit ran off the actor: between
  the sweep decision and the unit, a publication of the very same bytes for a record that did not expect them at
  decision time could find the orphan by exclusive rename, bind it, and lose it to the unit.
- **Residual race 2, reported as CCR-2 (review round 1, ZProbe4) — closed at the L3 close-out (C-23).** `apply` confirms
  a launch orphan in one unit and binds it only after its plan unit and write chunks; a sweep in that window removed it
  and `apply` then bound the record to a missing blob (I-2).
- **Superseded in review round 3 (C-23).** The sweep no longer unlinks: it dooms (`doomOrphans`), so the removal units,
  their per-unit re-check and the deadline after the listing are gone; the deadline bounds the listing only.

## C-11 — Storage report
- **Decision.** Live blobs come from the records (`bytesByKind` by the blob's lowercased extension; a blob any current
  record still wants counts as present, otherwise stale); `pendingDeletion` is `FreeSpace.pendingReclaim` plus the
  doomed blobs still leased (sizes recorded with the lease, `CleanupState.leasedBytes`); `evictableBytes` sums C-1's
  candidates; `orphanBytes` is what the last orphan GC listing of this lifetime left (0 before one); staging bytes and
  free space take one unit each and are 0 before `open()` or when the read fails; `sourceCopyBytes` is 0 (the engine
  adds the source's, ADR-027); `budgetBytes` is `FreeSpace.budgetBytes`.
- **Amended in review round 3 (C2, ruling R4).** The per-blob sums, the unverified count and the evictable bytes are
  computed in one bulk unit from a value snapshot (`StorageFigures`); on the actor only the leased doomed bytes (O(1) per
  lease) and the orphans left by the last GC (O(1) per orphan, against the blob table and `publishing`) remain. Orphans
  doomed by GC (C-23) count in `pendingDeletion` (through `FreeSpace.pendingReclaim`), not in `orphanBytes`.

## C-12 — The legacy plan
- **Decision.** The path rule is the prior art's (`localPathComponents`, else the identifier's dot segments without
  the last; file name `resolvedFileName.fileExtension`, extension as published). Every component must be non-empty,
  not `.`/`..`, free of `/` and NUL, ≤ 255 UTF-8 bytes (R-SEC-2); the file must appear in a **non-following** listing
  of the root (a symbolic link is neither descended into nor listed, S2-10; at most 64 levels and `maxEntries`
  directories). The expected digest is the manifest checksum, or for a checksum-less entry the prior art's local
  checksum (64 lowercase hex digits; anything else came from a custom `computeChecksum`). An entry whose local
  checksum disagrees with its manifest checksum is dropped (the prior art stored other bytes, the file is stale); one
  with neither is dropped. Entries naming one file share it when they expect one digest; a later one expecting another
  is dropped. The legacy manifest is decoded under `configuration.limits` with duplicates keeping the first. An entry
  whose file the listing does not find is reported apart (`LegacyPlan.unlisted`, with the digest it expected), not
  dropped: an earlier lifetime may have moved it into `blobs/` (review round 2). The plan also lists every valid
  entry path (`paths`), the only files phase 4 may remove besides the two metadata files. Decoding and planning run in
  one bulk unit (C2: at `maxEntries` the plan alone took about 94 ms on the actor).
- **Deviation from store.md §7 (for the orchestrator; accepted by ruling R5, to be tagged NEEDS-HUMAN-REVIEW by the
  orchestrator).** store.md hashed checksum-less files without a local checksum
  in phase 1; ADR-029 moved all hashing out of `open()`, and SPEC R-STO-11 adopts files "whose checksum verifies", so
  such files are dropped and downloaded again instead (the prior art always recorded a local checksum when it stored a
  file, so this case needs a failed hash in the prior art).

## C-13 — Legacy phase 1 inside `open()`
- **Decision.** Skipped in a lifetime that cannot write (B-34), when the root cannot be stat-ed (no decision on an
  I/O error), and when the legacy root **overlaps the store** (review round 2, ZProbeA/A2): it is the store's own
  directory `<base>/ZTronAssetKit`, one of its ancestors (the prior art's `baseDirectory:` was the root itself, so
  `StorageLocation.custom(X)` with `LegacyMigrationPolicy(root: X)` is natural), or lies inside it. Compared by path
  (dot segments applied, canonical composition, case folded) and then by `(st_dev, st_ino)` of the root, the store's
  directory and their ancestors in one metadata unit, so a symbolic link in either path cannot hide the overlap. Such
  a lifetime logs, writes nothing and leaves the stamp; migrating would rename files inside the store's tree and phase
  4 would remove it. The store's directory, not its base, is the boundary: the default root `<Caches>/CDNAssets` lies
  inside the base of a `.caches` store without touching it (test `R-STO-11: a legacy root that is, contains or lies
  inside the store's directory is never migrated, and the store survives`, four placements, one through a link). Before migration started, a missing root (a symbolic link counts as missing, never followed) removes the
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
  already holds their bytes, and so are unlisted entries (review round 2, ZProbeB: a relaunch counted the files an
  earlier lifetime adopted as dropped; test `R-STO-11: a relaunch in phase inProgress counts files adopted by an earlier
  lifetime neither adopted nor dropped`). Phase 1 publishes no snapshot.
- **Amended in review round 3 (transient I/O, ZProbe-read and ZProbe-list).** A stat or a read of `manifest.json` or
  `local-checksums.json` that fails (`LegacyRead.failed`, distinct from `.unusable`: not a regular file or over the
  size limit), a chunk read that comes back short, or a directory listing that fails (`LegacyTree.failed`) decides
  nothing in this lifetime, as a root that cannot be stat-ed: no write, no commit, no phase change, the prior art's key
  kept, `root` cleared so no later phase runs; a relaunch in phase `inProgress` keeps its persisted plan. Before, phase
  1 took the error for an undecodable manifest or for missing files and committed a plan that adopted nothing (or dropped
  the unlisted files), and phase 4, whose own reads then succeeded, removed every file the plan never adopted (13 of 13
  for ZProbe-read). Tests `R-STO-11: a transient I/O error while phase 1 reads the legacy metadata or lists the tree
  decides nothing, and the next launch moves every file` (failed stat, failed manifest read, failed checksums read,
  failed listing) and `R-STO-11: a transient I/O error in phase 1 of a relaunch in phase inProgress keeps the persisted
  plan and moves or removes nothing`; the stat and read cases of the unreadable-manifest test moved there, one to one,
  with the corrected expectation (that test keeps the directory case). Both readers re-check the phase after every unit.
- **Amended in review round 3 (overlap through a link at a compared level).** `itemInfo` does not follow a final link,
  so with `/A → R` and the store at `/A/app` the identity chain compared the link's own inode at `/A` and missed that
  the store lies inside the root. The guard now also compares, for each level of either path, the item one level below
  it, stat-ed through that path (so the level is followed when it is a link), with the item of the same name directly
  under the other directory (`LegacyPlacement.resolves`): equal identities are one item, and a directory has one parent.
  A stat that fails with an I/O error decides nothing (`nil`); a missing item or ENOTDIR is no match (a regular file at
  the root still has its stamp removed, test `R-STO-11: a regular file where the legacy root should be is no legacy
  tree…`). Placement `linkToRoot` added to `R-STO-11: a legacy root that is, contains or lies inside the store's
  directory…`; the root-stat test gains the new stat of the root (cases 1, 2, 3).
- **Amended at the L3 close-out, cycle 2 (review of cycle 1).** *Wording corrected:* the round-2 text above said a
  symbolic link in either path "cannot hide the overlap"; that was inaccurate: `resolves` only catches a level that
  resolves to the other directory itself, and a link to a directory below it hid the overlap (the review proved it on
  the fake for `/A → R/x` with the store at `/A/app`, and for `/A → <container>/sub` with the root `/A/CDNAssets`). The
  injected `FileSystem` has no primitive that reads a link's destination (adding one is a change of the public protocol),
  and `URL.resolvingSymlinksInPath()` would read the real volume past the injected one (C4) and could not be tested on
  the fake, so the guard compares identities where a link can hide the overlap: (1) the root's identity (its stat
  follows every intermediate link) is looked for among the store's own directories, by a non-following walk from
  `<base>/ZTronAssetKit` that never descends into a fan-out of `blobs/` (`LegacyPlacement.storeHolds`, in the same
  metadata unit: the container, `v1`, `blobs`, `staging` and anything foreign); (2) the legacy listing stats each
  directory in its listing unit and never enters the store's directory (`LegacyListingUnit`, `LegacyTree.reachesStore`),
  and phase 1 takes reaching it for an overlap (logged, nothing written); phase 4 just does not enter it. Placements
  `linkIntoRoot` and `rootThroughLinkIntoStore` added to `R-STO-11: a legacy root that is, contains or lies inside the
  store's directory…` (failed first in `ea7b702`; fix `28b1c36`; mutants: without the walk `rootThroughLinkIntoStore`
  fails, without `reachesStore` `linkIntoRoot` fails, 21 issues each). Residual: a root inside one of the 256 fan-out
  directories through a link is not found (the walk does not list every blob; the store's launch treats any such name as
  foreign). *Error mapping (ZProbe-perm):* only an I/O error, or a failed stat of the root itself, decides nothing; a
  refused permission (EPERM, EACCES), a missing item or ENOTDIR on an ancestor or a sibling is no match, as the identity
  chains already treated it; deciding nothing is now logged as an error ("could not tell whether the legacy root overlaps
  the store's directory…"). Test `R-STO-11: a refused stat of a directory above the legacy root is no overlap and
  migration runs; an I/O error decides nothing and says so` (EPERM on `Caches`: migrated, 13 adopted; EIO: nothing
  decided, logged; failed first in `ea7b702`; mutant: EPERM deciding nothing fails it, 3 issues). Device behaviour under
  "Not verified".
- **Amended at the L3 close-out, cycle 3 (review of cycle 2, ZProbe-overlap-io).** An I/O error on either stat of a
  listing unit (the store's directory in the first unit, the directory about to be listed) now fails the unit as a
  failed listing does (`LegacyListingUnit.run`, through `LegacyPlacement.identity`): phase 1 decides nothing (logged
  "legacy phase 1 could not read the prior art's files…"), phase 4 removes nothing; any other error stays no match.
  Before, `try?` took an EIO for "no identity": with the `linkIntoRoot` placement the walk listed the store's own tree and
  migration ran (the review found no damage, but the rule that an I/O error decides nothing was broken). Test
  `R-STO-11: an I/O error on a stat of the legacy walk decides nothing, and the walk never enters the store's directory`
  (EIO on the n-th stat of a path ending in `ZTronAssetKit`, n = 2…10; failed first in `c656fe0` for n = 6 and 7, 4
  issues each; fix `bd6681b`; mutants: the directory's EIO taken for no identity → n = 7 fails, the store's → n = 6
  fails, 4 issues each).
- **Deviation from store.md §7 (for the orchestrator; accepted by ruling R5, to be tagged NEEDS-HUMAN-REVIEW by the
  orchestrator).** An undecodable legacy manifest does not hash and move the
  legacy files as protected orphans: placing a blob with no record that expects it needs a store primitive that does
  not exist (the same gap as CCR-1). The launch is degraded as the contract says, nothing is adopted, and phases 3–4
  remove the prior art's metadata and the key with a sync due, so those entries are downloaded again; their files stay
  where they are (C-15: without a manifest nothing attributes them). A legacy root without
  `manifest.json` (the prior art creates the directory at init) migrates nothing and never the stamp. Ruling R2 allowed
  `doomOrphans` for this case if cheap; it is not: the legacy files are outside `blobs/`, so keeping them as protected
  orphans would need each hashed and placed under its digest without a record (a "place without records" primitive),
  which `doomOrphans` (table entries for files already under `blobs/`) does not give. Kept as it is.

## C-14 — Phase 2 and adopt-on-demand
- **Decision.** Files are processed in path order from a queue (stored reversed: a batch takes the last and a call
  that did not finish puts it back in O(1), so a migration of `maxEntries` files stays linear, C2; adopt-on-demand
  searches it once per call); a file being processed is claimed. Each file is hashed
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
  Deviation accepted by ruling R5 (to be tagged NEEDS-HUMAN-REVIEW by the orchestrator).

- **Amended at the L3 close-out, cycle 2 (review of cycle 1, ZProbe-hash; blocking).** A transient error on one legacy
  file in phase 2 no longer drops it: before, a failed read while hashing (EIO), or a failed move into `blobs/` (EIO,
  ENOSPC, EPERM), counted the file dropped without requeueing it, so phases 3 and 4 ran, phase 4 removed the file, and
  an asset whose checksum would have verified was downloaded again (R-STO-11). `processLegacyFile` now returns
  `.deferred` for any file-system error but a missing file (it vanished) or a cross-device rename (this decision's
  other-volume drop, accepted by ruling R5), and for a volume too full to place it; a digest or size mismatch, a vanished
  file and an unwanted one still drop. A deferred file goes back to the head of the queue and the batch ends (as a
  lifecycle error does), so phases 3 and 4 never run while a file waits; an adopt-on-demand that defers its queued file
  requeues it the same way. After `AssetStore.legacyAttempts` (3) deferrals of one file in one lifetime it is **kept**:
  out of the queue, counted dropped (its asset is downloaded again), and left out of phase 4's removal set in this
  lifetime (`MigrationState.kept`), so a permanently unreadable file neither holds migration back nor is removed unread.
  Tests `R-STO-11: a transient I/O error while phase 2 hashes or moves a legacy file ends the batch and the file is moved
  by a later one, never dropped` (EIO on the first read of `icon.heic` (ZProbe-hash), EIO and ENOSPC on its rename) and
  `R-STO-11: a legacy file that fails on every attempt is kept where it is after three…` (failed first in `ad04468`, 20
  issues; fix `b254db9`; mutants: no transient class fails both (20 issues), kept files not excluded fails the second,
  a deferral that does not end the batch fails the first (6 issues)). **Residual, for the orchestrator (a deviation from
  R-STO-11 in a crash window, beside ruling R5's):** the kept set is in memory, so if the process dies after the durable
  "done" commit and before phase 4 finished, the next lifetime's phase 4 removes a kept file the manifest attributes (its
  asset is downloaded again, as C-12's drops are); persisting it needs a STAMPS field (WP-B's codec).
## C-15 — Phases 3 and 4
- **Decision.** Phase 3 migrates the stamp (`SyncStamp(appVersion: legacyStamp, …)` over the applied digest) only when
  a legacy manifest was decoded, the applied manifest is still that one (its digest, recorded by phase 1 in
  `MigrationState.manifestDigest`; amended in review round 3, ZProbe-stamp: a newer manifest applied during migration was
  claimed synced although its new entries were never fetched, test `R-STO-11: the legacy stamp migrates only over the
  legacy manifest itself, never over a newer one applied during migration`), and every one of its entries is present at
  its current content, and never over a stamp the engine wrote meanwhile; when not every entry was adopted and no stamp exists, it sets "sync due". Phase
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
- **Amended in review round 2: phase 4 removes only what the prior art wrote.** The prior art's docs suggest a
  `Documents`-rooted `baseDirectory:`, so the legacy root may hold the user's own files; a recursive removal would
  delete them (and, with an overlapping root, the store: C-13). Phase 4 now reads `manifest.json` and lists the tree
  without following links, then removes each legacy entry's file (`LegacyPlan.paths`) and `local-checksums.json`
  (and a symbolic link where the prior art had a file or a directory: the link only), then the directories on the
  entries' paths deepest first (one still holding anything fails with ENOTEMPTY and stays), then `manifest.json`
  **last** (so a call that stopped part way still attributes the files next time), then the root only if empty. It is
  finished when everything the prior art wrote is gone; a root holding other files stays and is not pending at the
  next launch (pending in phase `done` = the stamp, a non-directory at the root, a metadata file, or an empty root).
  Test `R-STO-11: phase 4 removes only what the prior art wrote, never recursively…` (a file at the root, one beside
  a legacy file, one in its own directory). Consequence, accepted: an undecodable or unreadable manifest attributes
  nothing, so its files stay in the root (the two tests of that case now assert they are kept, the metadata file and
  the key removed; one-to-one with their previous "removes the tree" assertion); a file the prior art left from an
  older manifest (it pruned on every reconcile) stays too. In `Caches` the OS may purge them; elsewhere they are the
  app's to delete, which is the safe direction for data that might not be ours. Deviation from R-STO-11 ("remove the
  legacy directory") accepted by ruling R5 (to be tagged NEEDS-HUMAN-REVIEW by the orchestrator).
- **Amended in review round 3.** Phase 4 removes nothing and reports unfinished when its read of `manifest.json` or a
  listing failed (C-13's `.failed`): a manifest it cannot read attributes no file and a failed listing hides some, and
  `manifest.json` goes last, so the next call still attributes them (test `R-STO-11: phase 4 removes nothing after a
  failed read of the legacy manifest or a failed listing, and the next call removes the tree`). The `UserDefaults` key
  goes only once the tree is done, so the documented order (tree, then key) holds when a call stops part way. The
  listing re-checks the phase and the caller's cancellation after every unit (`R-STO-11: phase 4 stops listing the
  legacy tree after the unit in flight once the caller cancels or the store closes`: 14 listings after a cancellation or a
  close before, 2 now).

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
  12 s of wall time alone, 120 s under TSan. Review round 2: one disk at a time (`width = 1`), and the oracle's seeds and
  the three crash suites' modes are `.serialized`, so WP-C's suites hold at most one cooperative thread each beside
  WP-B's kill-then-power-loss cases and WP-H's start/stop race under TSan. The space is asserted, not printed: every disk ran, and each disk's fault
  and crash-view counts equal the counts its window implies. The B-36 mutation check still fails 27 of 49 rows.

## C-21 — Eviction candidates off the actor; the chunk yield (review round 2, C2)
- **Context.** `EvictionOrder.candidates` groups every record by blob and sorts: about 228 ms on the actor at
  `maxEntries` (ZProbeF, loaded host). The R8 yield between chunks of 1,000 was never reached by a test.
- **Decision.** `evictIfNeeded()` and `storageReport()` compute the candidates in a bulk unit from a value snapshot
  (records, blob table, `publishing`, leases, rules); eviction re-validates each candidate against the state when it
  marks it, with holders read after the await, as before (R8). The dry run `evictionPlan(toFree:protecting:)` keeps
  computing on the actor: it is synchronous by contract (OI-4). The yield between chunks is a no-op metadata unit
  instead of `Task.yield()`: the actor is free for the whole hop, and a test holds eviction at that point
  (`R-CLN-4: eviction releases the actor between chunks and re-validates every later candidate…`: with
  `EvictionState.chunk` lowered to 2 through a test-target seam, a candidate accessed and one leased during the
  yield are kept). For the orchestrator: R8's ledger text names `Task.yield()`; it now reads "a no-op metadata unit".
- **Consequences.** A snapshot captured by the unit makes the actor's next mutation of that dictionary copy it once
  (copy-on-write) while the unit runs; that copy is linear and far cheaper than the grouping and sort.
- **Amended in review round 3 (C2, ruling R4).** Each candidate's holders are read with `holders(of:known:)`: the
  planned victims re-read in O(victims) when they account for every reference the blob table counts (ADR-018: each
  present record holds one), otherwise (a provisional reference of a publication in flight, or a record bound after the
  snapshot) one scan of the records; so the full `referenceIndex()` after every chunk, in `apply`'s eviction and per
  quarantine is gone (2.6 ms at 10,000 records, 45 ms at `maxEntries`, review round 3).

- **Amended at the L3 close-out, cycle 2.** The fallback scan of `holders(of:known:)` (a `reportUnreadable` of a blob
  several records share passes only its own id; or a candidate bound after the snapshot) holds the actor 0.76 ms at
  10,000 records and 7.7–8.3 ms at `maxEntries` in this cycle's bench (the review measured 9.47–12.16 ms). Recorded in
  C-22 (c), not moved off the actor: holders computed in a bulk unit from a records snapshot make the next record
  mutation copy `records` while the unit's closure still holds the snapshot (C-22 (a), 9.3 ms at `maxEntries`), the same
  order, so nothing is gained without the executor change routed to WP-B (OI-9).

## C-22 — C2 at the benchmark scale and at `maxEntries` (review round 3, ruling R4)
- **Context.** Round 3 measured, as thread CPU of exactly the actor stretches in release: deep verification's due list
  13.5–14.0 ms at 10,000 records (198–204 ms at 100,000), purge's selection, sort and one `setResidency` per record in
  one turn 17.3–17.9 ms (210–211 ms), and secondary linear stretches (orphan GC's re-check per removal unit, the storage
  report's tail, `referenceIndex()` per eviction chunk, per apply eviction and per quarantine, the first copy of `records`
  while a snapshot is alive). Ruling R4 makes C2 at 10,000 mandatory and asks, at 100,000, for O(1) per candidate or off
  the actor where cheap, recording what remains.
- **Decision.** Purge (C-5), deep verification (C-8) and the storage report (C-11) build their lists and sums on the bulk
  executor from value snapshots; purge applies its selection in chunks of 1,000 with the actor released in between;
  eviction, `apply`'s eviction and quarantine read one blob's holders in O(holders) (C-21); orphan GC dooms in one turn
  after an off-actor decision and accumulates its listing per fan-out (C-23; a dictionary grown across the 256 listing
  units rehashed every blob in one turn); purge's reclaim wait makes one pass per round. Every new await has a row (c-5,
  c-6, R10 amendment, c-2 amendment).
- **Measurement (release, this Mac; `Tests/ZTronAssetKitBenchmarks/BenchCleanup.swift`).** Two benchmarks, nested in the
  parent suite as its doc asks of every work package; ARCHITECTURE §1.2 lists no benchmark file for WP-C, so this file is
  a new path in WP-C's write set, for the orchestrator. (1) WP-B's probe pattern (`ActorHoldProbe`, wall clock of a probe
  calling `metrics()` in a loop, best of five runs) around every WP-C operation at 10,000 assets on the fake file system
  with dispatch executors, asserted against 10 ms: it failed first on the round-2 code (`d9f2471`: deep verification
  10.9 ms, `purge(.evictable)` 15.9 ms, `purge(.all)` 13.3 ms) and passes now (figures in the Evidence section). (2) The
  thread CPU of each stretch measured directly on the actor (as the review did) at 10,000 and 100,000 assets, best of
  five samples: the chunked, per-item stretches are asserted against 10 ms at both scales; the rest is recorded, with the
  probe's holds of each operation at 100,000 (WP-B's stretches inside them included).
- **What stays linear on the actor at `maxEntries` (recorded, ruling R4).** (a) The first mutation of `records` (or of the
  blob table) while a unit still holds a snapshot of it copies the dictionary (copy-on-write): 9.3–9.5 ms for `records`
  and 1.0 ms for the blob table at 100,000 (0.68 ms and 0.05 ms at 10,000). It happens when the actor resumes and
  mutates before the executor released the unit's closure (`DispatchBlockingExecutor` resumes inside its block), so it
  is timing-dependent and cannot be closed by WP-C without a persistent map or an executor change. (b) WP-B's own
  stretches inside WP-C's operations: the copy of the present table on the first record change after a publication
  (an installed snapshot shares it; 3.1–6.2 ms at 100,000), the reaper's deletable filter over the blob table (4.0 ms),
  `freeSpace()`'s sums (4.1–8.0 ms wall). Together they make the probe's longest holds at 100,000: quota eviction of half
  21.7 ms and `purge(.all)` 22.8 ms (the first chunk pays (a) and the present-table copy), the storage report 8.0 ms
  (`freeSpace()`), a quarantine 5.4 ms (the present-table copy); orphan GC 2.2 ms (6.8 ms before the per-fan-out
  listing), a verification slice 2.2 ms. The synchronous dry run `evictionPlan` stays on the actor (OI-4, contract).

- **Amended at the L3 close-out, cycle 2 (review of cycle 1).** Release, this Mac, `BenchCleanup.swift` at `afc3a6b`
  (load 2.8–3.5; figures in the cycle-2 Evidence). Probe at 10,000 assets, best of five: storage report 0.56 ms, deep
  verification 0.25, orphan GC of 100 orphans 0.19, **orphan GC of 10,000 orphans 1.33** (new; the review's probe held
  7.0 ms with the one-turn doom), quarantine 0.24, eviction of half 2.23, `purge(.evictable)` 1.90, `purge(.all)` 1.90:
  all ≤ 10. Thread CPU at 10,000 / 100,000 assets, best of five, asserted ≤ 10: **orphan GC doom chunk of 1,000** 0.24 /
  0.29 ms, **`purge(.evictable)` chunk of 1,000** 1.49 / 1.87 ms, **purge's reclaim pass, chunk of 1,000** 0.05 / 0.13 ms
  (the whole pass in one turn was 2.9 / 27.6 ms before `28c6312`), purge chunk 0.95 / 1.45, eviction chunk 1.95 / 2.38,
  holders of 1,000 blobs 0.51 / 0.73. What stays linear on the actor at `maxEntries`, added to (a) and (b) above: **(c)**
  the holders fallback scan, 7.7 ms (0.76 at 10,000; C-21); **(d) WP-B's grace start**: the acknowledgement of the
  install after a purge or an eviction starts the grace of every doomed key in one turn (`startGrace`, iterating the whole
  blob table), 33.4 ms (probe, wall clock) over 100,000 newly doomed keys (1.7 ms at 10,000); **(e) WP-B's reaper queue**
  (`reap`: the deletable keys filtered and sorted in one turn), 23.0 ms over 100,000 deletable keys (1.9 ms at 10,000;
  the filter alone, with nothing deletable, 4.0 ms). Full-store purges at 100,000 (probe, one run each, WP-B's stretches
  included): `purge(.evictable)` 34.5 ms and `purge(.all)` 34.6 ms (the review: 33.2–34.8 and 33.6–33.7); after eviction
  the rest 22.3 ms; eviction of half 21.6; report 8.1; quarantine 5.0; verification slice 2.3; GC of 100 orphans 3.1.
  Attribution: a full-store purge's longest hold (34.5) is WP-B's grace start over 100,000 keys (33.4, (d)); the reaper's
  queue (23.0, (e)) is the next; WP-C's own stretches inside a purge are ≤ 2 ms each now. The extra ~12 ms over eviction's
  hold is consistent with (d) over twice the keys (eviction dooms half; its grace start was not measured separately). (d)
  and (e) are WP-B's (OI-9).

- **Amended at the L3 close-out, cycle 3 (review of cycle 2; C-24).** Legacy migration, measured by a new benchmark,
  `C2: legacy migration's actor holds at 10,000 and at 100,000 legacy files` (WP-B's probe, release, a prior-art tree of
  40-byte files, 500 per directory, with its `manifest.json`; best of three runs at 10,000, asserted ≤ 10 ms; one run at
  100,000, recorded). Before the change (`f4b8fc4`, load 6.7–8.3): at 10,000 `open()` with phase 1 7.51 ms, longest batch
  of 500 0.84, last call (its batch, phases 3 and 4) 4.57; at 100,000 160.94, 52.08 and 70.13. After (`8cc3c19`, load
  2.2–3.5, the simulator running beside it): 0.16, 0.70 and 1.94 at 10,000; **2.66, 15.39 and 7.73 at 100,000**. An
  attribution probe at 100,000 (scratch, not committed; release, load 7–13) put phase 3's one-turn check at 26.1–26.6
  ms of thread CPU and the first copy of these legacy records under a live snapshot at 27.4–29.8 ms; phase 4 held the
  actor 0.29 ms and a durable commit 0.03 ms. What stays: a batch's longest hold at 100,000 is WP-B's copy of `records`
  (or of the present table) inside an adoption's binding (C-22 (a), (b); OI-9). The rest of the benchmark at this
  commit, same run: every 10,000-asset hold ≤ 2.32 ms and every asserted chunk ≤ 2.47 ms at both scales, as in cycle 2.
  Under host load the 100,000 figures run about 25–30 % higher (OI-9, cycle 3 note).

## C-23 — Orphan GC dooms; a launch orphan binds only while it is one (CCR-1, CCR-2; rulings R1, R2)
- **Decision.** `StoreInternals.swift` gains `doomOrphans(_ orphans: [BlobKey: Int64]) -> [BlobKey]` (ruling R2,
  additive): each key unknown to the blob table and not in `publishing` becomes `doomed(DoomInfo(reason: .unreferenced,
  sinceSnapshotVersion: <current>, droppedInGeneration: 0, eligibleAt: uptime + deletionGrace))` with its listed size in
  `blobBytes`, is removed from `state.core.orphans`, and the state is marked dirty (`.lazy`, DOOMED rides along). It is
  never in a snapshot, so its grace starts at the doom; the reaper then needs a fresh acknowledgement after it, no lease,
  a store neither degraded nor unavailable (ARCHITECTURE §4.4), and a publication (`acquireReference`'s rescue) or an
  adoption (`adoptKnownBlob`, launch) of the key before that rescues it. Orphan GC lists (units), decides off the actor
  (`OrphanCollection.decide`: unknown keys of the snapshot, those to sweep: unexpected and older than the grace), then
  in one turn re-checks each key in O(1) against the blob table and `publishing` and dooms the sweep. Its result,
  `gcBytes` and the cleanup stamp count what it released to the reaper (as C-3). A key a record started expecting during
  the decision unit is doomed but stays rescuable until the grace ends (efficiency only; I-2 cannot break: a present
  record's key is live).
- **Ruling R1's two halves.** WP-C's half (clear `state.core.orphans[key]` in the actor turn that submits the sweep) is
  done by `doomOrphans` itself, in that very turn, so WP-C makes no direct write to WP-B bookkeeping and the rule-1
  exemption R1 granted is not used. WP-B's half: `adoptKnownBlob`'s `case nil` binds only while
  `state.core.orphans[key] == confirmed[key]` (`Store/AssetStore+Apply.swift`, the authorised edit).
- **Tests.** `R-CLN-2: orphan GC never sweeps a launch orphan that a running apply is about to adopt` lost its
  `withKnownIssue` and gained a second case: `stillOnDisk` (the sweep runs while `apply`'s plan unit is held; `apply` then
  rescues the doomed key and the record stays bound to the file after the reaper's grace) and `reaped` (the reaper unlinks
  the swept orphan before `apply` resumes; the record stays `absent(.neverFetched)`). Both failed on the round-2 code
  (`32f3e1d`, I-2: `x references 952f6c….png, which is missing`). Mutants: `adoptKnownBlob` without the orphan check, or
  `doomOrphans` without clearing `orphans[key]`, each fail the `reaped` case (3 issues). The orphan GC tests settle the
  reaper before asserting a file is gone (`orphanGC` asserts the doom, the pending reclaim and the reaped figures); the
  failing-unlink test asserts the reaper's backoff and that a later GC sees the key doomed, not orphaned; the cancelled-GC
  tests (C-4) and the crash test (`settleDeletions` after its GC, so a wrongful doom would still be caught).

- **Amended at the L3 close-out, cycle 2 (review of cycle 1, ZProbe-phantom; blocking).** A doom must have its file:
  WP-B rescues a doomed `unreferenced` key without I/O (I-2), so a doom made after the file left the disk binds a record
  to a missing blob. That happened when a key the listing saw left the disk and the blob table before the decision:
  doomed before the run and reaped once the listing passed it, doomed by an overlapping run and reaped, or a launch
  orphan adopted, dropped and reaped meanwhile. The old unlinking sweep was harmless there (unlinking a missing file
  does nothing). Now (a) the run snapshots the blob table and `publishing` before its first listing unit
  (`OrphanCollection.Start`) and a listed key is unknown only when that snapshot and the one after the listing both lack
  it: only the reaper takes a key out of the blob table, and only a key it holds. (b) A key the store learnt after the
  start and the reaper removed before the doom is excluded by the reap window: such a key was doomed after the start, so
  the reaper needs its grace to end (no earlier than `start + deletionGrace` on the awake clock) and an acknowledgement
  after the doom (the one that starts the grace, or the fresh one after it); a doom turn therefore proceeds only while
  `uptimeNow < start + deletionGrace` or `StoreMetrics.acknowledgedInstalls` is unchanged since the start
  (`reapWindowClosed`), and a run that fails both dooms no more, logs, and leaves the rest for the next run. (c) Runs are
  serialized (`CleanupState.collectingOrphans`): a call while another run is in flight returns `CleanupResult()` at
  once. (d) The sweep dooms in chunks of `CleanupState.chunk` keys sorted off the actor, with a no-op metadata unit in
  between, and decides each chunk again in its own turn (the phase, the suspension rules, the reap window, each key in
  O(1)); one turn over 10,000 swept orphans held the actor 9.7 ms (review), a chunk of 1,000 now 0.24 ms (C-22). A
  cancellation is seen only before the first chunk (the chunks make no I/O, and the run accounts for what it doomed); a
  close between chunks accounts, then throws `.closed`. The report keeps the listing's unknown keys minus the doomed ones,
  and filters at read time as before. Tests `R-CLN-2: orphan GC never dooms a key whose file the reaper removed after the
  listing saw it` (`reapedDoom`, `overlappingRun`, `adoptedAndReaped`; ZProbe-phantom: the run is held after the doomed
  key's fan-out is listed, the reaper runs, then a manifest naming the key again; failed first in `c60d37e`, 12 issues,
  `I-2` among them; fix `167a0ea`; mutants: without the start snapshot `reapedDoom` fails, without the reap window
  `adoptedAndReaped`, without the serialization `overlappingRun`) and `R-CLN-2: orphan GC dooms in chunks with the actor
  released in between, and a chunk after the reap window opened dooms nothing` (failed first in `717f774`, 5 issues; fix
  `fc6395a`). The window cost is one `blobTable` and one `publishing` snapshot held across the listing (the first
  mutation of the blob table meanwhile copies it once: 0.05 ms at 10,000, 0.98 ms at `maxEntries`, C-22 (a)). The reap
  window rests on WP-B's rules as they are (`AssetStore+Snapshot.swift`, `AssetStore+Reaper.swift`): every doom WP-B makes
  starts its grace only at an acknowledgement (`startGrace`), a failed unlink's backoff follows an attempt that already
  needed both, and `doomOrphans` is the only doom with an immediate `eligibleAt`; a WP-B change to these needs the window
  revisited.

## C-24 — Legacy migration's actor stretches at `maxEntries` (L3 close-out, cycle 3; ruling R4)
- **Context.** The review of cycle 2 measured legacy migration's turns with its own probe (release, load 3–6): at
  10,000 entries each stretch was ≤ 7 ms (12.9 ms for phase 1's record writes at load 13–16); at 100,000, phase 1's
  record writes took 97–107 ms, its queue build 63.5 ms, `open()`'s longest hold 113–131 ms, a batch up to 44 ms and the
  last call (phases 3 and 4) 53–58 ms. C-22 listed none of them.
- **Decision.** (1) Phase 1's bulk unit (`LegacyDecoding.phaseOne`) decodes and plans as before, then makes phase 1's
  record writes and builds the reversed queue from snapshots of `records` and of the applied manifest taken before it;
  `applyLegacyPlanWrites(_:stamp:)` assigns the records in O(1). Only `open()` runs while the store is `opening` (R1:
  async APIs await it, synchronous ones throw `.notOpen`), so nothing changes the records between the snapshot and the
  assignment; the writes are the ones §1.1 rule 1 grants (the legacy manifest while none is applied, `absent(.neverFetched)`
  records for ids the index lacks). (2) Each listing unit classifies its own items (`LegacyListing`); the actor appends
  the unit's listing and queues its subdirectories (`LegacyWalk`), and the bulk units merge the sets (`LegacyTree(_:)`),
  so a prior-art directory of `maxEntries` files no longer hashes every path in one turn. (3) Phase 4's removal unit
  also subtracts the kept files and builds the URLs (`LegacyRemoval.items(below:)`). (4) Phase 3's check reads the
  legacy entries in chunks of 5,000 with a no-op metadata unit in between (`legacyEntriesPresent`, proposed row c-7). A
  pass answers "every entry present" only if `CommitBookkeeping.mutationSerial` is unchanged since it began: WP-B bumps
  it in the turn of every persisted change, through `markDirty`, which `requireCommitted`'s coverage already relies on.
  Otherwise the pass starts again, and after three interrupted passes the check runs in one turn. An entry found
  missing is missing in that turn, so "no" needs no guard. A call that finds the migration finished, or a file back in
  the queue, after the check leaves it to the other call.
- **Options not taken.** Phase 3's check in a bulk unit over a `records` snapshot: a records mutation while the unit
  holds it copies the dictionary (27–30 ms at 100,000 with these records, C-22 (a)); the chunks on the actor hold no
  snapshot. Leaving the check in one turn and recording it: ruling R4 asks for O(1) per item where that is cheap, and
  here it is.
- **Tests.** `R-STO-11: phase 3 checks the legacy entries with the actor released between chunks and migrates the stamp
  only over a pass no mutation interrupted`, with the chunk lowered to 2 (`MigrationState.checkChunk`) and the release
  after the first chunk held: `quarantine` (the first entry is quarantined meanwhile, so the stamp does not migrate and a
  sync is due) and `pin` (a counted mutation that leaves it present: the pass restarts and the stamp migrates). It failed
  first in `33e2f57` (time limit: no release existed); fix `8cc3c19`; mutant: the serial guard dropped → `quarantine`
  fails (`view.stamp == nil && view.syncDue`). Since `99850e4` it also runs with one pass allowed
  (`MigrationState.checkPasses`), which reaches the one-turn check (mutant: that check answering yes → `quarantine`,
  one pass, fails); and `R-STO-11: a call whose phase 3 check was running while another call finished the migration
  decides nothing again` holds one call's check while a second call runs phases 3 and 4 to the end: the first call then
  returns the same progress and makes no file-system operation (mutant: the guard without the phase → a second "done"
  commit and removal pass, the operation count fails). Moves (1)–(3) change no behaviour: every legacy test passes unchanged; their
  effect is measured (`C2: legacy migration's actor holds at 10,000 and at 100,000 legacy files`, C-22 amendment of
  cycle 3), before (`f4b8fc4`) and after (`3b6e84b`, `8cc3c19`).
- **Consequences.** What stays linear on the actor in legacy migration at `maxEntries`: the first copy of `records`
  under a live snapshot and WP-B's present-table copy inside phase 2's bindings (C-22 (a), (b); OI-9), now the longest
  legacy holds; and, when migration starts on a store that already indexes many assets, the old records dictionary may
  be freed on the actor at the O(1) assignment (if the unit's closure was released first). Not measured: a first
  migration normally starts on an empty index.

## Orchestrator rulings (L3 close-out)

- **Orchestrator ruling (L3 close-out) R1 — CCR-2, merge-gating, approved in both halves.** WP-C clears
  `state.core.orphans[key]` in the actor turn that submits a sweep of that key (a §1.1 rule-1 exemption for this single
  write); WP-B's `adoptKnownBlob` `case nil` binds a launch orphan only while `state.core.orphans[key]` still equals the
  confirmation the plan saw. The `withKnownIssue` goes. Done: C-23 (the clear is made by `doomOrphans` in that turn).
- **Orchestrator ruling (L3 close-out) R2 — CCR-1, approved.** Add the package primitive `doomOrphans(_:)` to
  `Store/StoreInternals.swift` and switch orphan GC to doom instead of unlinking; use it for C-13 too if cheap. Done:
  C-23; not cheap for C-13 (C-13).
- **Orchestrator ruling (L3 close-out) R3 — OI-1 is a WP-B bug, fix approved in WP-B's apply plan.** Records
  `absent(.evicted)` are adopted only by the launch adoption, never by a later `apply`. Done: `adoptKnownBlob` refuses
  them (so `admit` does not adopt them either) and `ApplyPlan.compute` no longer lists them; test `R-CLN-4: an apply or
  admit within the deletion grace never adopts an evicted asset again; only a relaunch does` (failed first in `bdacee0`:
  `report.reused` non-empty and the record present again, for `apply` and `admit`; the relaunch case passed, as launch
  adoption intends); the oracle no longer reaps right after an eviction and reconciles after every open (with R3 reverted
  15 of 16 seeds fail). An evicted record whose content changes stays evicted until it is fetched (a publication dedupes
  onto a live key), the literal reading of the ruling.
- **Orchestrator ruling (L3 close-out) R4 — C2 at 10,000 records mandatory.** Done: C-22, C-5, C-8, C-11, C-21, C-23.
- **Orchestrator ruling (L3 close-out) R5 — deviations accepted.** C-12 (checksum-less legacy files without a local
  checksum are downloaded again), C-13 (an undecodable legacy manifest keeps its files where they are), C-14 (a legacy
  root on another volume is dropped) and C-15 (phase 4 keeps unattributable files and a non-empty root) are accepted as
  deviations from R-STO-11 / store.md §7 and will be tagged NEEDS-HUMAN-REVIEW by the orchestrator; C-6 (no Apple-tier
  ranking in eviction) is accepted as documented. Kept documented, each marked in place.

## Contract change requests

- **CCR-1 — an orphan-doom primitive for orphan GC (`Store/StoreInternals.swift`, WP-B/orchestrator). Approved by ruling
  R2 and done at the L3 close-out (C-23); the text below is the request as made.** Proposed:
  `func doomOrphans(_ orphans: [BlobKey: Int64]) -> [BlobKey]`: for each key unknown to the blob table and not in
  `publishing`, insert `.doomed(DoomInfo(reason: .unreferenced, sinceSnapshotVersion: <current version>,
  droppedInGeneration: 0, eligibleAt: uptimeNow))` with its size, and return the keys doomed. The reaper then unlinks
  them under the I-3 protocol (a fresh acknowledgement, no lease), and a publication or adoption of such a key rescues
  it (ADR-018) instead of losing it. `collectGarbage` would doom instead of unlinking and report what the reaper frees.
  Until then C-10's residual race stands; it needs a publication of byte-identical content to an orphan older than
  `orphanGrace` within one executor hop of the sweep. The same primitive (or a "place without records") would let an
  undecodable legacy manifest keep its files as protected orphans (C-13).

- **CCR-2 — close the orphan sweep / `apply` adoption race (C-10, review round 1 ZProbe4; WP-B and the orchestrator).
  Approved by ruling R1 and done at the L3 close-out (C-23); the text below is the request as made.**
  Two halves, both needed (checked together in a scratch copy, see Evidence): WP-C, in the turn that submits a removal
  batch, sets `self.state.core.orphans[key] = nil` for each swept key (a write to WP-B bookkeeping that §1.1 rule 1 does
  not allow WP-C today); WP-B, in `adoptKnownBlob`'s `case nil` (`Store/AssetStore+Apply.swift`), binds only when
  `confirmed[key] != nil && self.state.core.orphans[key] == confirmed[key]`. A key `apply` bound before the GC decision
  is in the blob table and stays marked; one a decision swept is no longer adoptable. CCR-1's doom-instead-of-unlink
  primitive closes it too (the swept key would be doomed `unreferenced` and rescued by `apply`). The known-issue test
  `R-CLN-2: orphan GC never sweeps a launch orphan that a running apply is about to adopt` then passes, and
  `withKnownIssue` must be removed from it.

## Open issues (for the orchestrator)

- **OI-1 — `apply` rescues blobs that quota eviction just doomed. Closed at the L3 close-out (ruling R3; see the ruling's
  entry above).** `ApplyPlan.adoptionCandidates` includes records in
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

- **OI-4 — `evictionPlan(toFree:protecting:)` computes its candidates on the actor (C2, review round 2).** It is a
  synchronous package API by contract, so its grouping and sort (about 228 ms at `maxEntries` under load, a few ms at
  realistic catalog sizes) stay one actor stretch. Moving it off the actor needs an `async` signature (a contract
  change, for the orchestrator with WP-F, its caller).
- **OI-5 — ARCHITECTURE §14 (orchestrator).** It describes `LiveLegacyDefaults.swift`'s untested part as 3 lines; the
  coverage export counts 3 of 14 lines covered (11 uncovered). The file is unchanged since the contract.

- **OI-6 — ARCHITECTURE text after the L3 close-out (orchestrator).** §1.1's `StoreInternals.swift` row gains
  `doomOrphans(_:)` (ruling R2), and rule 1's exemption for clearing `state.core.orphans` (ruling R1) is unused (the
  primitive clears it, C-23); §4.6's orphan GC dooms instead of unlinking, and every purge clears the stamp before its
  first await (C-5); §4.7's stamp migrates only over the legacy manifest phase 1 decoded (C-15); §10.1's R8 reads "a no-op
  metadata unit" and per-candidate holders (C-21), R10 gains the decision unit, and rows c-5 and c-6 are new; §12.2's
  S2-06 row should name `R-CLN-4: pending reclaim decides a second eviction within the grace window…` (C-2); §11's R-CLN-8
  row should credit C's store-side test and give F's engine re-download test a distinct name (review round 3, finding 6).
- **OI-6, cycle 2 additions.** §4.6: orphan GC dooms only keys unknown since before its listing, within the reap window,
  in chunks, one run at a time (C-23); purge chunks end at blob boundaries and its reclaim pass is chunked (C-5). §4.7:
  phase 2 defers a file on a transient error and keeps it in place after three attempts (C-14); the overlap guard's
  identity walks (C-13). §10.1: the R10 amendment as amended, the new R9 amendment, rows c-4 and c-5 as amended.
- **OI-7 — a benchmark file for WP-C (§1.2).** `Tests/ZTronAssetKitBenchmarks/BenchCleanup.swift` is new (ruling R4's C2
  measurement, C-22), nested in the parent suite as its doc asks of every work package; §1.2's L3 row lists none.
- **OI-9 — WP-B's C2 stretches at `maxEntries` (cycle 2, for WP-B and the orchestrator; ruling R4 records them).** (a)
  `startGrace` iterates the whole blob table in the acknowledgement's turn: 33.4 ms over 100,000 newly doomed keys, the
  longest hold of a full-store purge (C-22 (d)); (b) `reap` filters and sorts every deletable key in one turn: 23.0 ms
  over 100,000 (C-22 (e)); `runDueWork`'s `freshNeeded` scan and `nextDeadlineInternal` are linear too (code reading, not
  measured). Suggested: keep a
  doomed-key index (or start the grace and build the queue in chunks). (c) The copy-on-write of `records` (9.3 ms at
  `maxEntries`, C-22 (a)) and of the present table (3.3 ms, (b)): the review suggests releasing a unit's closure, and with
  it the captured snapshot, before resuming the actor in `runUnit` / `DispatchBlockingExecutor`, which removes (a)
  without an unsafe construct.
- **OI-8 — WP-A's `R-MAN-3: the table estimate bounds the storage of a dictionary from AssetID to Int reserved for any
  count` was flaky on the iOS Simulator. Closed at the L3 close-out, cycle 3, by the orchestrator-authorised edit of that
  test and its helper (`2f07410`).** Cause: it measured the process-wide in-use heap (`malloc_zone_statistics`) around
  one reservation, the lowest of three runs, so every allocation the tests running beside it made in that window counted
  (cycle 1: `measured` 544, 19,680 and 3,392 bytes for counts 1, 1 and 3 against estimates of 128–192; a passing run
  proved nothing). Fix: the test reads the size of the table's own malloc block,
  `DecodeMeasurement.storageBlockSize(of:)` (`malloc_size` of the native storage object that the dictionary's one word
  references: `Dictionary` is ABI-stable on Apple platforms and tail-allocates its bitmap, keys and values in that single
  allocation), and checks that the block holds at least `capacity` buckets, so a layout change fails loudly rather than
  measuring something else. No other thread can change that figure; the bound (`measured <= ManifestFootprint.table`)
  is unchanged. Mutants: the estimate without its 3/4 load factor fails (`count: 2, measured: 192, estimated: 128`, …),
  and without its 64-byte header (`count: 1, measured: 128, estimated: 64`, …); a third mutant, the bitmap counted in
  bits (fix round 3's bug), passes: `ManifestFootprint.allocated` now rounds to the coarser magazine size classes, which
  absorb the missing word at every count measured.
  Evidence: 20 consecutive passes on macOS and 20 iterations on the simulator (cycle-3 Evidence).
- **OI-10 — transport loopback tests under host load (WP-D/WP-E and the orchestrator; cycle 3).** `R-NET-2: 500
  downloads through one backend use at most maxConnectionsPerHost TCP connections` failed on the simulator at load
  110–327 (191 transfers `.transient(.timedOut)`): its 500 tasks queue behind 3 connections and a queued task's
  wall-clock request timeout (the rig's 10 s) runs while it waits. Fixed by the authorised test edit `36dd17c`:
  `LoopbackRig.make` takes `requestTimeout` (default 10 s, every other test unchanged) and that test passes 50 s, within
  its one-minute limit; every assertion is kept (500 outcomes, each staged to its own file, 1–3 connections, 500
  requests). The review also saw four other loopback tests time out or miss `awaitProgress(512 KiB)` at load 3→84 (all
  passed on rerun; wp/c changes no transport file). For the orchestrator: run simulator verification on an idle host or
  one simulator at a time; for WP-E: whether its loopback request timeouts should be injected or scale with load,
  without loosening an assertion.
- **OI-11 — two R-STO-11 deviations that ruling R5 does not cover (cycle 3, for the orchestrator: DECISIONS.md,
  NEEDS-HUMAN-REVIEW).** (a) *Three-attempt abandonment* (C-14, cycle 2): a legacy file whose read or move fails
  transiently three times in one lifetime is kept in place, counted dropped and downloaded again; attempts are counted
  per lifetime with no backoff, so an ENOSPC streak or an EIO burst can use all three; phase 3 then commits "done", and
  phase 4 removes `manifest.json` and the key, so no later lifetime retries the file, which stays in the legacy root
  unattributed for good (R-STO-11: files that verify are moved, not downloaded again, and the legacy directory is
  removed). (b) *Its crash residual*: the kept set lives in memory, so a crash after the durable "done" lets the next
  lifetime's phase 4 remove a kept file. A lifetime-based bound (end the lifetime's migration unfinished when a file
  reaches its attempts, without phase 3, retry at the next launch, abandon only after N lifetimes) needs a persisted
  per-file count, a STAMPS field in WP-B's codec (a CCR); not made here.
- **OI-12 — orphan GC's reap window is per run, not per key (cycle 3, liveness only; WP-B with the orchestrator).** If a
  run's listing outlasts `deletionGrace` (10 s by default) while an install is acknowledged, the run dooms nothing and
  leaves everything to the next run (C-23); on a busy store every run could hit it and orphans would wait. Correctness
  and I-2 are unaffected; on the fake a listing of 10,000 orphans takes well under a second. Each occurrence is logged
  (`.info`, "an orphan sweep outlasted the deletion grace; the next run collects"), so maintenance scheduling can be
  tuned from logs. A per-key exclusion (the reaper keeping a bounded set of the keys reaped since a sequence number) is a
  WP-B change.
- **OI-9, cycle 3 note.** The 100,000-entry figures rise about 25–30 % under host load: the review of cycle 2 measured
  WP-B's grace start at 38.99 ms (C-22: 33.4), the reaper queue at 22.98 ms (23.0), a full-store purge at 43.5–44.0 ms
  (34.5–34.6), quota eviction of half at 29.27 ms (21.6), the purge of the rest at 36.23 ms (22.3) and the storage
  report at 9.58 ms (8.1), at load 13.6–20; C-22's own figures come from a near-idle host (load about 3). For C-22 /
  DECISIONS at merge.
- **OI-6, cycle 3 additions.** §4.5: `apply`'s and `admit`'s adoption bind by the launch rule except `absent(.evicted)`,
  which only the launch adoption takes (ruling R3, OI-1); the text still says apply binds by the same rule as launch.
  §4.7: phase 1's writes and queue are built in its bulk unit and assigned whole while `opening` (C-24); each listing
  unit fails on an I/O error stat (C-13, cycle 3); phase 3's check is chunked under the mutation-serial guard (C-24).
  §10.1: new row c-7; the c-4 amendment below.
- **OI-5, cycle 3.** Unchanged: `LiveLegacyDefaults.swift` has 11 of 14 lines uncovered (cycle-3 coverage export);
  §14's "3 lines" should read "11 of 14 lines uncovered".

## Proposed REENTRANCY rows (ARCHITECTURE §10.1)

| Row | Await | Re-validated afterwards |
|---|---|---|
| c-1 (proposed) | the removal units of `collectStaging` and legacy phase 4 (`removeInUnits`, `removeAllInUnits`) | the phase; the next unit starts only after the caller's cancellation is checked (a cancellation ends the loop with the partial result, which the caller accounts for before it throws `.cancelled`, C-4); a failed removal does not stop the loop. (Since review round 3 orphan GC dooms instead of removing, C-23, so the per-unit `recheck` and the deadline are gone.) |
| c-2 (proposed) | `storageReport()`'s staging listing unit, and its figures unit (bulk, review round 3) | nothing: the sum and the figures are snapshots; the pending and orphan bytes are read from the state after the await (O(1) per lease and per orphan) |
| c-3 (proposed) | `verifyIntegrity`'s trailing snapshot install | nothing but the phase (as R17): the quarantines were made synchronously before it and the report describes them |
| c-4 (proposed) | legacy phase 4's stats, manifest read, listing, removal-set unit (bulk) and removal units and the `UserDefaults` key removal; the key removal of phase 1 when no tree exists; the read and listing units of phases 1 and 4 (`readLegacyFile`, `listLegacyTree`; since cycle 2 each listing unit also stats its directory, and the first one the store's, `LegacyListingUnit`) | after the durable "done" commit (or with no tree before migration) the prior art's files and the key are the migration's alone, and every step is idempotent; the root's kind is a snapshot taken without following it, and anything but a directory is unlinked, never listed; only items of the non-following listing that the prior art could have written are removed (C-15). Since review round 3: the phase after every read and listing unit, in phase 4 also the caller's cancellation; a read or listing that failed decides nothing (phase 1) or removes nothing (phase 4) (C-13, C-15); the key goes only once the tree is done |
| c-5 (proposed, review round 3) | `purge`'s selection unit (bulk) and its no-op metadata unit between chunks | the phase and writability; per record (`purgeChunk`): it still references the blob recorded at selection, and for `.evictable` (since cycle 2, per blob: chunks end at blob boundaries) the blob is still live, unleased and not being placed and every current holder (`holders(of:known:)`) is still neither essential nor pinned, else the whole blob stays; the epoch and the stamp were written before the first await and are written again in the turn of the last chunk (C-5) |
| c-6 (proposed, review round 3) | `verifyIntegrity`'s due-list unit (bulk) | the phase and writability; per blob before its hash: live, not being placed, not verified in this pass meanwhile; after it R16; the holders read again with `holders(of:known:)` (C-8) |
| R10 amendment (proposed, review round 3; amended in cycle 2) | `collectGarbage`'s decision unit (bulk), after the full listing, and its no-op metadata unit between doom chunks | the phase, the caller's cancellation (before the first chunk only: nothing doomed then), degraded or unavailable (nothing doomed); a key counts as unknown only if the snapshot taken before the first listing unit lacks it too; each chunk's turn checks the reap window (`reapWindowClosed`: no key learnt since the start can have been reaped) and every key again in O(1) against the blob table and `publishing` (`doomOrphans`); runs are serialized; a key a record started expecting meanwhile is doomed but stays rescuable until the grace ends (C-23) |
| R9 amendment (proposed, cycle 2) | `awaitReclaim`'s no-op metadata unit between chunks of its pass | the phase; each later key is classified from the blob table as it is then; the round's figures only decide whether to wait, install or stop, and the next round (or the reaper) sees what changed (C-5) |
| c-7 (proposed, cycle 3) | phase 3's no-op metadata unit between chunks of its check (`legacyEntriesPresent`), and the return to `finishLegacyMigration` | the phase after each release; the pass answers "present" only if `commits.mutationSerial` is unchanged since it began (else it starts again; after three interrupted passes one turn decides); a missing entry is missing in the turn it is found; then writability, and the migration's phase, queue and claims (a call that finished migration meanwhile, or a file back in the queue, leaves it) (C-24) |
| c-4 amendment (proposed, cycle 3) | the listing units of phases 1 and 4 (`LegacyListingUnit`) and phase 1's bulk unit | an I/O error on either stat of a listing unit fails the walk as a failed listing (C-13, cycle 3); phase 1's bulk unit builds the records and the queue from snapshots that nothing else writes while the store is `opening` (R1), and they replace the store's whole (C-24) |
| R16 amendment (proposed) | `verifyIntegrity`'s stat units around each hash (`blobIncarnation`) | as R16, plus: the identity and size under the name are the same before and after the hash and the key is not in `publishing`; otherwise the result is discarded and the key stays due in this pass (C-8) |
| R8 amendment (proposed) | quota eviction's candidate unit (bulk) and its no-op metadata unit between chunks | as R8: the phase and writability, then per candidate against its holders as they are then (`holders(of:known:)`, review round 3; C-21) |

Existing rows WP-C's awaits cite: R1 (async APIs await `open()`; phase-1 units), R3/R4 (through `adoptVerifiedFile`),
R7 and R9 (purge's reap and grace wait), R8 (eviction chunks), R10 (orphan listing and decision), R11 (migration units), R12
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

## Review round 2 — dispositions

Two lenses reported 16 issues, 5 of them blocking. Every blocking one is fixed with a test that failed first
(`28076fa`); none is declined. Routed items are unchanged where WP-C's write set cannot close them.

| # | Lens, issue | Disposition |
|---|---|---|
| 1 | reqs, blocking: the superseded-publication R-CLN-2 test passed for any implementation | rewritten: checksum-less entries (no record expects the key), an orphan older than the grace already under the name, A's placement held while one complete sweep runs (its listing units released one by one), then a second sweep while B's placement is held; mutant M-B (`orphanMarks()` without `publishing`) now fails it (`first.value.filesRemoved == 0`), it passed before |
| 2 | reqs: CCR-2 merge-gating | routed, unchanged (CCR-2; `withKnownIssue` stays until both halves land) |
| 3 | reqs: WP-C's suites halve the TSan headroom of WP-B's and WP-H's races | the oracle's seeds and the three crash suites are `.serialized`, the state space runs one disk at a time (C-20) |
| 4 | reqs: the R8 yield and `adoptLegacyNow`'s requeue path uncovered | C-21: chunk size in `EvictionState` (test-target seam), the yield a no-op metadata unit, test of a candidate accessed and one leased during the yield; `R-STO-11: an adopt-on-demand cancelled while it hashes puts its file back…` (mutant: no requeue → fails) |
| 5 | reqs: OI-1 | routed, unchanged |
| 6 | reqs: P-13 at load | OI-3, unchanged (WP-B's benchmark) |
| 7 | reqs: C-17 ownership | none needed (orchestrator) |
| 8 | reqs: §14's LiveLegacyDefaults figure | OI-5 (orchestrator; WP-C cannot edit ARCHITECTURE.md) |
| 9 | correct, blocking: phase 4 removed a store inside the legacy root | C-13 (overlap check, four placements tested) and C-15 (phase 4 removes only the prior art's files, never recursively) |
| 10 | correct, blocking: verification quarantined a replacement hashed across two incarnations | C-8 incarnation check; ZProbeC is the regression test |
| 11 | correct, blocking: a relaunch counted earlier adoptions as dropped | C-12/C-13: `LegacyPlan.unlisted`, dropped only without a record at the expected digest |
| 12 | correct, blocking: a cancelled purge was never stamped | C-4: stamped after the commit and again after the wait |
| 13 | correct: C2 stretches at the manifest limit | planning in the bulk decode unit, legacy queue O(1) per file (C-12, C-14), eviction candidates in a bulk unit for `evictIfNeeded` and the report (C-21); the synchronous dry run stays (OI-4, contract) |
| 14 | correct: one failing unlink stopped orphan GC | C-10: the sweep stops only at the deadline or cancellation; the marks are re-checked per unit, including units a time budget splits off (found while fixing: the old loop re-checked per batch only) |
| 15 | correct: CCR-2 and OI-1 still open | routed, unchanged |
| 16 | correct: purge during legacy migration | decided and documented (C-5): kept, no code change |

## Review round 3 — dispositions (L3 close-out, cycle 1)

Two lenses reported 17 findings, 5 of them blocking (`.build-orchestrator/l3-remaining-c.json`). Every blocking one is
fixed with a test committed failing first; the orchestrator's rulings R1–R5 are applied (see "Orchestrator rulings").
None is declined.

| # | Lens, finding | Disposition |
|---|---|---|
| 1 | reqs, blocking: the S2-06 regression test does not catch S2-06 | C-2 amendment: `R-CLN-4: pending reclaim decides a second eviction within the grace window, against a reserve and a fractional budget (store-2 S2-06)` (`8d9943f`); the mutant at `EvictionOrder.swift:129` fails both cases, the old test passes it. For the orchestrator: point §12.2's S2-06 row at the new test |
| 2 | reqs: CCR-2 known I-2 violation | fixed under rulings R1 and R2 (C-23); `withKnownIssue` removed, failing first in `32f3e1d`, fixed in `eea3d02` |
| 3 | reqs: TSan headroom of the shared Storage bundle | for the orchestrator (idle host at merge); this round's TSan run is in the Evidence section, with WP-H's race and WP-C's state space |
| 4 | reqs: the oracle never applies within the grace after an eviction (OI-1) | fixed with ruling R3 (`143f167`); the oracle reaps no more right after an eviction and reconciles after every open (`1e168d1`); R3 reverted fails 15 of 16 seeds |
| 5 | reqs: §14's `LiveLegacyDefaults` figure | for the orchestrator (OI-5, unchanged: 11 of 14 lines uncovered) |
| 6 | reqs: R-CLN-8's test name in §11 is F's | for the orchestrator: the store-side test keeps its name (the trace gate links it to R-CLN-8); §11 should credit C's test and give F's engine re-download test a distinct name |
| 7 | reqs: R-CLN-12 leaves out deep verification and legacy migration | `.deepVerification` and `.legacyMigration` added to `R-CLN-12: every cleanup operation run twice is a no-op the second time` (`011fa54`); the stamp and the migration state are compared too |
| 8 | reqs: deviations not tagged NEEDS-HUMAN-REVIEW | ruling R5: the orchestrator tags them in DECISIONS.md; C-12, C-13, C-14, C-15 and C-6 say so in place |
| 9 | reqs: the round-2 iOS Simulator evidence line was missing | pasted in the round-2 Evidence section from that run's own result bundle, read in this session |
| 10 | reqs: P-13 at load (informational) | OI-3, unchanged: WP-C changed no reaper code (`doomOrphans` only inserts doomed entries the reaper already handles) |
| 11 | correct, blocking: transient legacy I/O deletes unadopted files (ZProbe-read, ZProbe-list) | C-13 and C-15 amendments: failing tests `208866d`, fix `4fcb887` |
| 12 | correct, blocking: the legacy stamp claims a newer manifest synced (ZProbe-stamp) | C-15 amendment: failing test `416bf0b`, fix `e40ddf8` |
| 13 | correct, blocking: deep verification's due list on the actor (C2) | C-8 amendment, C-22: failing benchmark `d9f2471` (10.9 ms), fix `ed8ca25` (0.25 ms at 10,000) |
| 14 | correct, blocking: purge's selection and residency changes in one turn (C2) | C-5 amendment, C-22: failing benchmark `d9f2471` (15.9 and 13.3 ms), fix `ed8ca25` (1.9 ms at 10,000) |
| 15 | correct: secondary O(N) stretches at `maxEntries` | C-22: orphan GC decides off the actor and dooms in one turn (no per-unit re-check), the report's sums off the actor, holders per blob instead of the reference index, the listing per fan-out; what stays linear (copy-on-write of a snapshotted dictionary, WP-B's present-table copy, reaper filter and free-space sums) is measured and recorded |
| 16 | correct: the overlap guard misses a link at a compared level | C-13 amendment: failing placement `c46bab9`, fix `c2f3857` |
| 17 | correct: the legacy readers do not re-check the phase; phase 4 ignores cancellation | C-15 amendment and row c-4: failing test in `208866d` (14 listings after a cancellation or close), fix `4fcb887` (2) |

## Review of cycle 1 — dispositions (L3 close-out, cycle 2)

The close-out verification of cycle 1 reported 11 issues, 2 of them blocking. Both blocking ones are fixed with a test
committed failing first; every clearly-right non-blocking one is fixed the same way or recorded; the rest are for the
orchestrator. None is declined.

| # | Lens, issue | Disposition |
|---|---|---|
| 1 | reqs: the holders fallback scan at `maxEntries` (9.5–12.2 ms) unrecorded | recorded: C-21 amendment and C-22 (c), 7.7 ms in this cycle's bench; not moved off the actor (it would trade the scan for the `records` copy of C-22 (a), the same order) |
| 2 | reqs: `BenchCleanup.swift` outside §1.2's write set (OI-7) | for the orchestrator at merge, unchanged (OI-7) |
| 3 | reqs: the copy-on-write residue at `maxEntries` (C-22 (a)) | for WP-B and the orchestrator (OI-9 (c), with the review's executor suggestion) |
| 4 | reqs: §14's `LiveLegacyDefaults` figure | for the orchestrator, unchanged (OI-5: 11 of 14 lines uncovered, measured again in this cycle) |
| 5 | correct, blocking: orphan GC dooms a key the reaper removed after the listing (ZProbe-phantom, I-2) | fixed (C-23 amendment): start snapshot, reap window, serialized runs; `c60d37e` → `167a0ea`; three mutants caught |
| 6 | correct, blocking: phase 2 drops a file on a transient error, phase 4 removes it (ZProbe-hash, R-STO-11) | fixed (C-14 amendment): `.deferred`, three attempts, kept files out of phase 4; `ad04468` → `b254db9`; three mutants caught; the crash-window residual is for the orchestrator |
| 7 | correct: a link to a directory below either one hides the overlap | fixed by identity walks (C-13 amendment), wording of C-13 corrected; `ea7b702` → `28b1c36`; residual: a root inside a fan-out directory |
| 8 | correct: any ancestor error decides nothing, silently (ZProbe-perm) | fixed (C-13 amendment): only EIO or the root's own stat decides nothing, and it is logged; device check under "Not verified" |
| 9 | correct: purge chunks split a shared blob | fixed (C-5 amendment): chunks at blob boundaries, `.evictable` re-validates every holder; `590a02b` → `ca27df8` |
| 10 | correct: orphan GC's doom turn (9.7 ms at 10,000 orphans) | fixed (C-23 amendment (d)): chunks of 1,000 with a release in between; `717f774` → `fc6395a`; 0.24 ms per chunk (C-22) |
| 11 | correct: C-22's purge figure was of half a store; the extra ~10 ms unattributed | C-22 amendment: full-store figures (34.5 / 34.6 ms) attributed to WP-B's grace start (33.4 ms) and reaper queue (23.0 ms), routed (OI-9); WP-C's own reclaim pass was 27.6 ms in one turn and is chunked (`28c6312`, 0.13 ms per chunk) |

## Review of cycle 2 — dispositions (L3 close-out, cycle 3)

The close-out verification of cycle 2 reported 14 issues, 3 of them blocking (two of which are the same WP-A test, OI-8,
seen by both lenses), and the orchestrator's note repeats OI-8. All blocking ones are fixed: OI-8 and the transport
timeout by the orchestrator-authorised test edits, each shown passing 20 times on macOS and on the simulator and the
OI-8 measurement failing against mutants. Every clearly-right non-blocking one is fixed with a test committed failing
first, or measured first; the rest are for the orchestrator. None is declined.

| # | Lens, issue | Disposition |
|---|---|---|
| 1 | reqs, blocking: OI-8, WP-A's table-estimate test flaky on the simulator | fixed (authorised edit, `2f07410`): the table's own malloc block instead of the process-wide heap delta; two mutants caught; 20 passes on macOS and on the simulator (OI-8) |
| 2 | reqs, blocking: WP-D's 500-download test times out under load | fixed (authorised test edit, `36dd17c`): `LoopbackRig.make(requestTimeout:)`, 50 s in that test, every assertion kept; 20 passes on macOS and on the simulator (OI-10) |
| 3 | reqs: three-attempt abandonment not covered by ruling R5 | for the orchestrator (OI-11 (a), NEEDS-HUMAN-REVIEW in DECISIONS.md; the lifetime-based bound needs a CCR) |
| 4 | reqs: OI-6 misses ARCHITECTURE §4.5 | added (OI-6, cycle 3 additions) |
| 5 | reqs: §14's `LiveLegacyDefaults` figure (OI-5) | for the orchestrator, unchanged (OI-5, cycle 3: 11 of 14 lines uncovered) |
| 6 | reqs: `BenchCleanup.swift` outside §1.2 (OI-7) | for the orchestrator, unchanged; the file gains the legacy measurement (C-24) |
| 7 | reqs: C2 residue at `maxEntries` rises under load | recorded (OI-9, cycle 3 note: about 25–30 % above C-22's near-idle figures) |
| 8 | correct, blocking: OI-8 (same test as 1) | as 1 |
| 9 | correct: an EIO on the walk's stat of the store taken for no identity (ZProbe-overlap-io) | fixed (C-13, cycle 3): `c656fe0` → `bd6681b`; two mutants caught |
| 10 | correct: legacy migration's actor stretches at `maxEntries` unrecorded | fixed (C-24): measured first (`f4b8fc4`), phase 1, the walk and phase 4 off the actor (`3b6e84b`), phase 3 chunked (`33e2f57` → `8cc3c19`, one mutant caught; fallback and second-call tests `99850e4`, two more); `open()` with phase 1 at 100,000 from 160.9 ms to a few ms; the rest recorded (C-22, cycle 3) |
| 11 | correct: transport loopback tests under host load | the 500-download test fixed (2); the others for the orchestrator and WP-E (OI-10) |
| 12 | correct: kept legacy files, a deviation not covered by ruling R5, and its crash residual | for the orchestrator (OI-11) |
| 13 | correct: orphan GC liveness (the reap window per run) | recorded for WP-B and the orchestrator (OI-12); each occurrence is already logged |
| 14 | correct: carried orchestrator items (§14, §1.2, OI-9, OI-4) | unchanged, for the orchestrator (OI-5, OI-7, OI-9, OI-4) |

## Not verified here

- Device behaviour of the legacy rename (`Caches` → `Application Support` on one APFS volume) and of a legacy root on
  another volume (dropped, C-14); `LiveLegacyDefaults` (writing real defaults is outside the repository, ARCHITECTURE
  §14); Unicode normalisation or case differences between a legacy manifest's path components and the names on disk
  (a mismatch drops the file, which is then downloaded again).
- The ordered/durable distinction of phase 3 on a device (OI-2).
- The overlap check's identity comparison on a device (C-13): `(st_dev, st_ino)` through `/var` → `/private/var` and
  through an App Group container were exercised on the fake volume only (a link in the store's base, test case
  `throughLink`); the live conformer reports `systemNumber`/`systemFileNumber`, and the path comparison does not depend
  on them.
- Deep verification's incarnation check against a real rename-over on APFS (C-8): the fake gives every new file a new
  inode, as APFS does; a volume that reuses inode numbers at once could hide a replacement of the same size.
- The overlap guard's resolved-identity comparison (C-13, review round 3) on a device: the fake follows intermediate
  links and reports ENOTDIR below a file as `LiveFileSystem` maps it (`.notFound`); `/var` → `/private/var` and App Group
  containers were not exercised.
- The overlap guard's error mapping and identity walks on a device (C-13, cycle 2): whether the iOS sandbox refuses the
  stat of a directory above the app container (EPERM is taken for no match, so migration then runs), and the walk of the
  store's directories through `/var` → `/private/var`; exercised on the fake volume only. `LiveFileSystem`'s listings
  report no identity, so both new checks stat each directory and never use a listing's identity.
- The kept-file protection of phase 4 across a crash (C-14, cycle 2): in memory only, by design (residual stated there).
- Phase 3's mutation-serial guard (C-24) relies on WP-B bumping `commits.mutationSerial` in the turn of every
  persisted change (`markDirty`): read in `AssetStore+Commit.swift` and implied by `requireCommitted`'s coverage, not
  audited across every WP-B write; the test exercises it with WP-C's quarantine and pin only.
- OI-8's measurement relies on `Dictionary`'s ABI-stable layout (one word referencing the native storage); a layout
  change makes `storageBlockSize(of:)` return 0 or a smaller block, which the test's capacity check reports. Checked on
  this Mac (macOS 27) and the iOS 27.0 simulator only.
- The actor-hold figures of C-22 on a device: measured on this Mac in release with the fake file system; a device's
  slower CPU scales every stretch, and the copy-on-write copies of C-22 (a) depend on when the executor releases a unit's
  closure, which only the probe sees.

## Evidence of the L3 close-out, cycle 3 (this worktree, `wp/c`, 2026-10-10; this Mac, 8 cores)

Commits, in order (each failing test on its own first): `2f07410` (OI-8, authorised WP-A test edit), `36dd17c` (OI-10,
authorised WP-D test edit), `c656fe0` → `bd6681b` (an I/O error on the walk's stats), `f4b8fc4` (legacy benchmark,
before figures), `3b6e84b` (phase 1, the walk and phase 4 off the actor), `33e2f57` → `8cc3c19` (phase 3 chunked),
`99850e4` (fallback and second-call tests), then this record. The final runs below are at `99850e4` (the record changes
no code) unless stated.

- Failing first, each on the sources before its fix (`swift test --filter …`): `c656fe0`: 8 issues, 4 for each of n = 6
  and 7 (`!storeListed`, `!report.legacyMigrationPending && !report.degraded`, the phase `.notStarted`, the records
  empty); `33e2f57`: both cases exceed their one-minute limit (4 issues: the time limit and `CorePoll.until`), since the
  check never released the actor.
- Mutants (each reverted, `git diff` clean afterwards): OI-8: the table estimate without its 3/4 load factor → `under`
  non-empty (`count: 2, measured: 192, estimated: 128`, …), without its 64-byte header → (`count: 1, measured: 128,
  estimated: 64`, …); the bitmap counted in bits → passes (masked, OI-8). The listing unit taking the directory's EIO for
  no identity → n = 7 fails (4 issues), the store's → n = 6 (4). Phase 3's serial guard dropped (`>=`) → `quarantine`
  fails (`view.stamp == nil && view.syncDue`); the one-turn fallback answering yes → `quarantine`, one pass, fails; the
  finish guard without the phase → `secondFinishingCallLeavesIt` fails (`operations.count == operations`).
- OI-8 and OI-10 on macOS: 20 consecutive runs of `swift test --skip-build --scratch-path .build-c/loop --filter
  "ZTronAssetModelTests|connectionReuse"` at `36dd17c` (load 2.73–18.77): every run exit 0, `Test run with 84 tests in 18
  suites passed` 20 times, `R-MAN-3: the table estimate bounds the storage of a dictionary…` passed 20/20 and `R-NET-2:
  500 downloads through one backend use at most maxConnectionsPerHost TCP connections` passed 20/20.
- OI-8 and OI-10 on the iOS Simulator (`897F9D8D-B10D-4D91-8E22-417A2B9D70AA`, iOS 27.0) at `8cc3c19`, 04:14:58–04:35:20,
  load 6.68 at the start (up to 39.7 meanwhile, other agents): `caffeinate -i xcodebuild test … -only-testing:ZTronAssetModelTests
  -only-testing:'ZTronAssetTransportTests/ForegroundBackendTests/connectionReuse()' -test-iterations 20
  -collect-test-diagnostics never OTHER_SWIFT_FLAGS='-warnings-as-errors'`: `** TEST SUCCEEDED **`; `xcresulttool get
  test-results summary` of `Test-ZTronAssetKit-2026.10.10_04-15-08-+0200.xcresult`: `{'result': 'Passed',
  'totalTestCount': 85, 'passedTests': 85, 'failedTests': 0, 'skippedTests': 0, 'expectedFailures': 0}`; 1,700
  repetition nodes passed (85 × 20), none failed; the two tests 20/20 each.
- `TMPDIR=… SWIFTPM_SCRATCH=.build-c bash Scripts/verify.sh --quick`: `VERIFY: PASS` (`::: SUMMARY mode=--quick
  steps-failed=0`; Storage bundle `Test run with 419 tests in 55 suites passed after 60.473 seconds`; the other bundles
  151, 10, 84, 12, 3 and 104 tests passed).
- `swift build -c release --scratch-path .build-c -Xswiftc -warnings-as-errors`: `Build complete! (19,58 s)`, exit 0.
- `gates.py unsafe`: `UNSAFE escapes found=0 max=3`, `UNSAFE: PASS`; `gates.py docs`: `DOCS public declarations=1281
  documented=1281 exempt=0 fraction=100.0%`, `DOCS: PASS`. Every `await` in WP-C's four directories,
  `StoreInternals.swift` and `AssetStore+Apply.swift` has a `// REENTRANCY:` line (scripted check: `awaits 145 missing
  0`).
- Storage tests three times (`swift test --scratch-path .build-c --skip Benchmarks --filter ZTronAssetStorageTests`, load
  7.0–7.5): `Test run with 419 tests in 55 suites passed after 59.999 / 60.935 / 61.378 seconds`.
- TSan once (`swift test --scratch-path .build-c-tsan --sanitize=thread --skip Benchmarks --filter
  ZTronAssetStorageTests`, load 6.52 → 5.51): `Test run with 419 tests in 55 suites passed after 198.816 seconds`, 0
  `ThreadSanitizer` lines, 0 failures.
- Coverage (`swift test --scratch-path .build-c --enable-code-coverage --skip Benchmarks`, all 7 test runs passed;
  `llvm-cov export -summary-only` over the 7 test bundles; `gates.py coverage`): `COVERAGE target=ZTronAssetStorage
  lines= 97.31% (7494/7701) min=90.0 OK`; WP-C's files with `StoreInternals.swift` 2528/2609 = 96.90%, lowest
  `LiveLegacyDefaults.swift` 21.43% (11 of 14 lines uncovered, OI-5) then `LegacyPlacement.swift` 95.24%.
  `ZTronAssetKit` 37.82% and `ZTronAssetSync` 30.57% fail on the WP-F/WP-G stubs, as in cycles 1 and 2 (`COVERAGE: FAIL`
  for those two only).
- `xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath .build-c/xcode build
  OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet`: exit 0, no error or warning.
- iOS Simulator, full (`897F9D8D-…`, iOS 27.0; `caffeinate -i xcodebuild test -scheme ZTronAssetKit -destination
  'platform=iOS Simulator,id=897F9D8D-B10D-4D91-8E22-417A2B9D70AA' -derivedDataPath .build-c/xcode-sim
  -skip-testing:ZTronAssetKitBenchmarks -collect-test-diagnostics never OTHER_SWIFT_FLAGS='-warnings-as-errors'`,
  05:05:34–05:08:31, load 4.29 at the start, 28.89 at the end): `** TEST SUCCEEDED **`; `xcresulttool get test-results
  summary` of `Test-ZTronAssetKit-2026.10.10_05-05-42-+0200.xcresult`: `{'result': 'Passed', 'totalTestCount': 783,
  'passedTests': 783, 'failedTests': 0, 'skippedTests': 0, 'expectedFailures': 0}`; 0 "Restarting after" or "exceeded
  execution time". The simulator is shut down.
- C2 benchmarks at `8cc3c19` (release; `swift test -c release --scratch-path .build-c-perf -Xswiftc -enable-testing
  --filter CleanupBenchmarks`, load 2.21 → 3.51, the simulator iteration run beside it): `Test run with 3 tests in 2
  suites passed after 57.313 seconds`. `C2 longest actor hold of legacy migration over 10000 files (best of 3): open()
  with phase 1 0.156958 ms (max of runs 0.267541 ms), longest batch of 500 0.699542 ms (max of runs 0.741541 ms), last
  call with phases 3 and 4 1.935 ms (max of runs 2.395209 ms)`; `… over 100000 files (best of 1): open() with phase 1
  2.662125 ms, longest batch of 500 15.389709 ms, last call with phases 3 and 4 7.726375 ms`. Before, at `f4b8fc4` (load
  6.70 → 7.62, the macOS loop beside it): 7.507125 / 0.842542 / 4.570041 ms and 160.938834 / 52.07525 / 70.128542 ms.
  The rest of the run: `C2 longest actor hold at 10,000 assets (WP-C): storage report 0.57275 ms, deep verification of
  every blob 0.254042 ms, orphan GC of 100 orphans 0.124209 ms, orphan GC of 10,000 orphans 1.346958 ms, quarantine of
  one blob 0.2535 ms, quota eviction of half 2.320334 ms, purge(.evictable) of all 1.915625 ms, purge(.all) of all
  1.930125 ms`; thread CPU, 10,000 / 100,000, asserted: orphan GC doom chunk of 1000 0.244833 / 0.302042 ms, purge chunk
  0.97325 / 1.501167, `purge(.evictable)` chunk 1.581125 / 1.921042, eviction chunk 2.058667 / 2.468125, reclaim pass
  chunk 0.053417 / 0.140041, holders of 1000 blobs 0.528958 / 0.741292; recorded at 100,000: first records copy
  9.704875, holders fallback scan 7.798209, WP-B grace start 35.712709, WP-B reaper queue 23.222833; holds at 100,000:
  storage report 8.251417, verification slice 2.463958, orphan GC of 100 0.998458, quarantine 15.119583, eviction of half
  21.992458, purge(.all) of the rest 22.559125, full-store purges 34.094916 / 35.362667 ms.
- `docs/TRACEABILITY.md`: untouched (`--gates-only` and `--full` were not run).

## Evidence of the L3 close-out, cycle 2 (this worktree, `wp/c`, 2026-10-09; this Mac, 8 cores)

Commits, in order (each failing test on its own first): `c60d37e` → `167a0ea` (phantom doom), `ad04468` → `b254db9`
(phase 2 deferral), `717f774` → `fc6395a` (doom chunks), `590a02b` → `ca27df8` (purge chunks at blob boundaries),
`ea7b702` → `28b1c36` (overlap guard), `28c6312` (reclaim pass chunks), `afc3a6b` (benchmark), then this record. Every
run below is at `afc3a6b` (the record changes no code).

- Failing first, each on the sources before its fix (`swift test --filter …`): `c60d37e`: 12 issues, 4 per case
  (`reapedDoom`, `overlappingRun`, `adoptedAndReaped`): `!doomed || harness.hasBlob(gone.key)`, `violations.isEmpty`
  (I-2), the presence check, and `second.value == CleanupResult()` / the result count; `ad04468`: 20 issues (the three
  transient faults: `first.dropped == 0 && !first.finished…`, the file still in the tree, `progress == (13, 0, 0,
  true)`, `isPresent`, the stamp; the persistent fault: `reads.count == 3` and the kept file); `717f774`: 5 issues
  (`!held.isEmpty && …`, the result, the files, the report, the second run); `590a02b`: 2 issues (`assetsRemoved == 1`,
  `kept == (true, true)`); `ea7b702` (re-counted on its sources): 46 issues, `linkIntoRoot` 21 and
  `rootThroughLinkIntoStore` 21 (migrated: pending, records, applied manifest, phase, key, files), `permissionDenied` 3
  (not migrated), `io` 1 (not logged).
- Mutants (each reverted, `git status` clean afterwards): orphan GC without the start snapshot → `reapedDoom` fails (4
  issues); without the reap window → `adoptedAndReaped` (4); without the serialization → `overlappingRun` (2);
  `isTransientLegacyFailure` false → both phase-2 tests (20); kept files not excluded from phase 4 → the persistent test
  (1); a deferral that does not end the batch → the transient test (6); no store walk → the overlap test (21, the new
  `rootThroughLinkIntoStore`); `reachesStore` never set → the overlap test (21, `linkIntoRoot`); EPERM deciding nothing →
  the ancestor test (3); `.evictable` checked per record inside a blob group → the shared-blob purge test (2).
- `TMPDIR=… SWIFTPM_SCRATCH=.build-c bash Scripts/verify.sh --quick`: `VERIFY: PASS` (`::: SUMMARY mode=--quick
  steps-failed=0`; Storage bundle `Test run with 416 tests in 55 suites passed after 59.530 seconds`; the other bundles
  151, 10, 84, 12, 3 and 104 tests passed).
- `swift build -c release --scratch-path .build-c -Xswiftc -warnings-as-errors`: `Build complete! (20,20 s)`, exit 0.
- `gates.py unsafe`: `UNSAFE escapes found=0 max=3`, `UNSAFE: PASS`; `gates.py docs`: `DOCS public declarations=1281
  documented=1281 exempt=0 fraction=100.0%`, `DOCS: PASS`. Every `await` in WP-C's four directories,
  `StoreInternals.swift` and `AssetStore+Apply.swift` has a `// REENTRANCY:` line (scripted check: `awaits 143 missing
  0`).
- Storage tests three times (`swift test --scratch-path .build-c --skip Benchmarks --filter ZTronAssetStorageTests`):
  `Test run with 416 tests in 55 suites passed after 58.944 / 60.582 / 61.362 seconds`.
- TSan once (`swift test --scratch-path .build-c-tsan --sanitize=thread --skip Benchmarks --filter
  ZTronAssetStorageTests`, load 7.15 → 6.24): `Test run with 416 tests in 55 suites passed after 198.963 seconds`, 0
  `ThreadSanitizer` lines, 0 failures.
- Coverage (`swift test --scratch-path .build-c --enable-code-coverage --skip Benchmarks`, all 7 test runs passed;
  `llvm-cov export -summary-only` over the 7 test bundles; `gates.py coverage`): `COVERAGE target=ZTronAssetStorage
  lines= 97.23% (7374/7584) min=90.0 OK`; WP-C's files with `StoreInternals.swift` 2409/2492 = 96.67%, lowest
  `LiveLegacyDefaults.swift` 21.43% (11 of 14 lines uncovered, OI-5) then `LegacyPlacement.swift` 94.56%.
  `ZTronAssetKit` 37.82% and `ZTronAssetSync` 30.57% fail on the WP-F/WP-G stubs, as at cycle 1 (`COVERAGE: FAIL` for
  those two only).
- `xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath .build-c/xcode build
  OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet`: exit 0, no error or warning.
- iOS Simulator (`897F9D8D-B10D-4D91-8E22-417A2B9D70AA`, iOS 27.0; `caffeinate -i xcodebuild test -scheme ZTronAssetKit
  -destination 'platform=iOS Simulator,id=897F9D8D-…' -derivedDataPath .build-c/xcode-sim
  -skip-testing:ZTronAssetKitBenchmarks -collect-test-diagnostics never OTHER_SWIFT_FLAGS='-warnings-as-errors'`, load
  2.88 at the start): `** TEST SUCCEEDED **`; `xcresulttool get test-results summary` of
  `Test-ZTronAssetKit-2026.10.09_21-08-14-+0200.xcresult`: `{'result': 'Passed', 'totalTestCount': 780, 'passedTests':
  780, 'failedTests': 0, 'skippedTests': 0, 'expectedFailures': 0}`; 0 "Restarting after" or "exceeded execution
  time". WP-A's `R-MAN-3` (OI-8) passed in this run. The simulator is shut down.
- C2 benchmarks (release; `swift test -c release --scratch-path .build-c-perf -Xswiftc -enable-testing --filter
  CleanupBenchmarks`, load 3.46 → 2.84): `Test run with 2 tests in 2 suites passed after 41.469 seconds`. `C2 longest
  actor hold at 10,000 assets (WP-C): storage report 0.555666 ms, deep verification of every blob 0.251542 ms, orphan GC
  of 100 orphans 0.192792 ms, orphan GC of 10,000 orphans 1.329083 ms, quarantine of one blob 0.239875 ms, quota
  eviction of half 2.225667 ms, purge(.evictable) of all 1.900792 ms, purge(.all) of all 1.903334 ms` (best of five;
  budget 10). Thread CPU, best of five, 10,000 / 100,000: orphan GC doom chunk of 1000 0.2395 / 0.292042 ms,
  purge(.evictable) chunk of 1000 1.493375 / 1.873625 ms, purge's reclaim pass chunk of 1000 0.0475 / 0.125834 ms, purge
  chunk of 1000 0.949625 / 1.453417 ms, eviction chunk of 1000 1.953125 / 2.377209 ms, holders of 1000 blobs 0.506 /
  0.7285 ms, snapshot capture 0.000916 / 0.000958 ms (asserted); recorded: holders(of:known:) fallback scan 0.762458 /
  7.689875 ms, WP-B grace start over every doomed key (probe) 1.684291 / 33.358708 ms, WP-B reaper's queue over every
  deletable key 1.905959 / 22.989667 ms, first records copy under a live snapshot 0.665292 / 9.255667 ms, WP-B
  present-table copy 0.2405 / 3.252541 ms. `C2 longest actor hold at 100000 assets (WP-C operations, one run, WP-B's
  stretches inside them included): storage report 8.055 ms, verification slice of 1,000 blobs 2.323167 ms, orphan GC of
  100 orphans 3.054167 ms, quarantine of one blob 4.9895 ms, quota eviction of half 21.56925 ms, purge(.all) of the rest
  22.319625 ms, purge(.evictable) of a full store 34.52225 ms, purge(.all) of a full store 34.621 ms`. Before `28c6312`
  (same bench, the whole reclaim pass in one turn): `purge's reclaim pass over the selection 2.932167 / 27.612042 ms`.
  WP-B's own benchmarks were not run (OI-3 unchanged).
- `docs/TRACEABILITY.md`: untouched (`--gates-only` and `--full` were not run).

## Evidence of the L3 close-out, cycle 1 (this worktree, `wp/c`, 2026-10-09; this Mac, 8 cores)

Commits, in order (each failing test on its own first): `8d9943f` (S2-06 test), `208866d` → `4fcb887` (transient legacy
I/O, phase 4's listing), `416bf0b` → `e40ddf8` (legacy stamp), `c46bab9` → `c2f3857` (overlap through a link),
`32f3e1d` → `eea3d02` (rulings R1, R2), `bdacee0` → `143f167` → `1e168d1` (ruling R3, oracle), `d9f2471` → `ed8ca25`
→ `2a7f04b` (ruling R4, C2), `011fa54` (R-CLN-12), `b06ab86` (comments only).

- Failing first, each on the sources before its fix (`swift test --filter …`): `208866d`: the transient-fault tests
  recorded 57 issues over 8 cases, among them ZProbe-read (`kept.count → 0` of the 15 fixture files, the key removed) and
  ZProbe-list, and `phaseFourStopsListing` `listings() → 14` for both stops (re-run on the old sources after the test's
  baseline was corrected and the commit amended); `416bf0b`: `newerManifest` `view.stamp → SyncStamp(appVersion: "1.4+77",
  …, manifestDigest: 804f51…)` and `view.syncDue → false` (ZProbe-stamp), `sameManifest` passed; `c46bab9`: `linkToRoot`
  21 issues (migrated: phase, records, applied manifest, key, files); `32f3e1d`: both cases, `I-2: x references
  952f6c….png, which is missing or the wrong size`; `bdacee0`: `apply` and `admit` (`report.reused.isEmpty` false, the
  record present again), `relaunch` passed; `d9f2471` (release, below): deep verification 10.9 ms, `purge(.evictable)`
  15.9 ms, `purge(.all)` 13.3 ms against 10.
- Mutants (each reverted, `git diff` empty afterwards): `EvictionOrder.swift:129` `let effective = max(0, available)` →
  the new S2-06 test fails both cases (`second → CleanupResult(bytesFreed: 20000, filesRemoved: 2…)` reserve,
  `10000, 1` fraction), the byte-budget test passes; `adoptKnownBlob` without the `orphans[key] == orphan` check → the
  CCR-2 test's `reaped` case fails (3 issues); `doomOrphans` without clearing `orphans[key]` → the same (3 issues);
  ruling R3 reverted in `adoptKnownBlob` and `ApplyPlan` → the oracle fails 15 of 16 seeds.
- `SWIFTPM_SCRATCH=.build-c bash Scripts/verify.sh --quick` at `011fa54` (load 2.65): `VERIFY: PASS` (`::: SUMMARY
  mode=--quick steps-failed=0`; Storage bundle `Test run with 410 tests in 55 suites passed after 56.041 seconds`, no
  known issue any more).
- `swift build -c release --scratch-path .build-c -Xswiftc -warnings-as-errors` at `b06ab86`: `Build complete! (18,98
  s)`, exit 0 (also at `011fa54`: `Build complete! (20,05 s)`).
- `gates.py unsafe` at `b06ab86`: `UNSAFE escapes found=0 max=3`, `UNSAFE: PASS`; `gates.py docs`: `DOCS public
  declarations=1281 documented=1281 exempt=0 fraction=100.0%`, `DOCS: PASS`; `gates.py selftest`: `SELFTEST: PASS`.
  Every `await` in WP-C's four directories, `StoreInternals.swift` and `AssetStore+Apply.swift` has a `// REENTRANCY:`
  line (scripted check: 0 missing).
- Storage tests three times at `011fa54` (`swift test --scratch-path .build-c --skip Benchmarks --filter
  ZTronAssetStorageTests`; 1-minute load 3.27 / 8.13 / 9.22): `Test run with 410 tests in 55 suites passed after
  55.961 / 57.605 / 59.029 seconds`, 0 `Time limit was exceeded`.
- TSan once at `011fa54` (`swift test --scratch-path .build-c-tsan --sanitize=thread --skip Benchmarks --filter
  ZTronAssetStorageTests`, load 7.86 → 6.44): `Test run with 410 tests in 55 suites passed after 189.886 seconds`, 0
  `WARNING: ThreadSanitizer`, 0 `Time limit was exceeded`; WP-H's start/stop race 35.6 s, WP-B's `R-STO-5: a process
  kill followed by a power loss…` 23.0 s, the oracle 19.3 s, WP-C's legacy state space 189.9 s (49 rows).
- Coverage at `b06ab86` (`swift test --scratch-path .build-c --enable-code-coverage --skip Benchmarks`, all 7 test runs
  passed; `llvm-cov export -summary-only` over all 8 bundles; `gates.py coverage`): `COVERAGE target=ZTronAssetStorage
  lines= 97.29% (7169/7369) min=90.0 OK`; WP-C's files 2156/2228 = 96.77% (97.24% without `LiveLegacyDefaults.swift`,
  ARCHITECTURE §14), lowest `LegacyPlacement.swift` 94.23%; the WP-B files ruled for edit: `StoreInternals.swift`
  49/49, `AssetStore+Apply.swift` 95.50%, `ApplyPlan.swift` 98.63%. `ZTronAssetKit` 37.82% and `ZTronAssetSync` 30.57%
  fail on the WP-F/WP-G stubs, as expected at L3 (`COVERAGE: FAIL` for those two only).
- `xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath .build-c/xcode build
  OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet` at `011fa54`: exit 0, no error or warning.
- iOS Simulator (`897F9D8D-B10D-4D91-8E22-417A2B9D70AA`, `caffeinate -i xcodebuild test … -skip-testing:ZTronAssetKitBenchmarks
  -collect-test-diagnostics never OTHER_SWIFT_FLAGS='-warnings-as-errors'`) at `b06ab86`: two runs, `** TEST FAILED **`
  both, `{'result': 'Failed', 'totalTestCount': 774, 'passedTests': 773, 'failedTests': 1, 'skippedTests': 0,
  'expectedFailures': 0}` (`Test-ZTronAssetKit-2026.10.09_19-16-30…` at load 3.6, `…19-20-03…` at load 19.5). The one
  failure, both times, is WP-A's `R-MAN-3: the table estimate bounds the storage of a dictionary from AssetID to Int
  reserved for any count` (`ZTronAssetModelTests`; `under → [(count: 1, measured: 544, estimated: 128)]`, then
  `measured: 19680`); a run of `ZTronAssetModelTests` alone failed it too (`count: 3, measured: 3392, estimated: 192`,
  load 19.6). It measures process-wide heap growth around one allocation, so allocations of tests running beside it
  count; this branch changes nothing under `Sources/ZTronAssetModel`, `Tests/ZTronAssetModelTests` or
  `Sources/ZTronAssetTestSupport` (`git diff --stat l3-base..HEAD` on them is empty), and it passed in round 2's runs.
  For the orchestrator (WP-A). Per bundle in the second run: `ZTronAssetStorageTests` 410 passed, Transport 151,
  AppleHosted 104, Model 83 passed and 1 failed, Kit 12, Sync 10, Compatibility 3; 0 "Restarting after", 0 "exceeded
  execution time". CCR-2's known issue is gone (0 expected failures). The simulator is shut down.
- C2 benchmarks (release; `swift test -c release --scratch-path .build-c-perf -Xswiftc -enable-testing --filter
  CleanupBenchmarks`, load 8.06; sources identical to `b06ab86` but for comments, checked with `git diff ed8ca25 HEAD --
  Sources`): `Test run with 2 tests in 2 suites passed after 23.120 seconds`. `C2 longest actor hold at 10,000 assets
  (WP-C): storage report 0.5435 ms, deep verification of every blob 0.261541 ms, orphan GC of 100 orphans 0.15775 ms,
  quarantine of one blob 0.23475 ms, quota eviction of half 2.202291 ms, purge(.evictable) of all 1.928666 ms,
  purge(.all) of all 1.92375 ms` (best of five; budget 10). Thread CPU per stretch, best of five, at 10,000 / 100,000:
  purge chunk of 1,000 1.08 / 1.51 ms, eviction chunk of 1,000 1.93 / 2.38 ms, holders of 1,000 blobs 0.50 / 0.72 ms,
  snapshot capture 0.0009 / 0.0009 ms (asserted ≤ 10); recorded: first records copy under a live snapshot 0.68 / 9.35
  ms, first blob-table copy 0.05 / 0.98 ms, WP-B's present-table copy 0.26 / 3.10 ms, WP-B's reaper filter 0.45 / 4.00
  ms, WP-B's `freeSpace()` 0.46 / 4.10 ms (wall), off the actor: eviction candidates 14.1 / 196.1 ms, purge selection
  1.17 / 18.3 ms, verification due list 0.74 / 122.4 ms. `C2 longest actor hold at 100000 assets (WP-C operations, one
  run, WP-B's stretches inside them included): storage report 8.020916 ms, verification slice of 1,000 blobs 2.17675 ms,
  orphan GC of 100 orphans 2.214625 ms, quarantine of one blob 5.395542 ms, quota eviction of half 21.655333 ms,
  purge(.all) of the rest 22.794792 ms` (C-22 attributes them). WP-B's own benchmarks were not run in this cycle (the
  host's load rose to 20–36 while the simulator ran); OI-3 is unchanged.
- `docs/TRACEABILITY.md`: untouched (`--gates-only` and `--full` were not run).

## Evidence (this worktree, `wp/c`, 2026-10-09, fix round 2; this Mac, 8 cores)

- Failing first (`28076fa`, the tests alone on the round-1 sources): `swift test` of the Storage bundle recorded 113
  issues in 8 tests, among them `R-STO-11: a legacy root that is, contains or lies inside the store's directory…` (all
  4 placements), `R-STO-11: phase 4 removes only what the prior art wrote…` (8 issues), `R-INT-4: deep verification
  discards a hash…` (`report.corrupt.isEmpty` failed: ZProbeC reproduced), `R-STO-11: a relaunch in phase inProgress
  counts…` (`dropped` 4), `R-CLN-6: a purge cancelled during its grace wait…` (no stamp), `R-CLN-2: an orphan whose
  removal keeps failing…` (3 issues). The rewritten superseded-publication test passed on the round-1 sources and
  failed with mutant M-B (`orphanMarks()` without `publishing`): `first.value.filesRemoved == 0` at
  `GarbageCollectionTests.swift:207`. Mutant "no requeue" in `adoptLegacyNow`'s error path fails
  `R-STO-11: an adopt-on-demand cancelled while it hashes…`. Every mutant was reverted (`git diff` empty).
- `SWIFTPM_SCRATCH=.build-c bash Scripts/verify.sh --quick` at `c19bef5`: `VERIFY: PASS` (Storage bundle `Test run
  with 399 tests in 55 suites passed after 65.170 seconds with 2 known issues`, CCR-2's test).
- `swift build -c release --scratch-path .build-c -Xswiftc -warnings-as-errors`: `Build complete!`, exit 0.
- `xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath .build-c/xcode build
  OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet`: exit 0, no error or warning.
- `gates.py unsafe`: `UNSAFE escapes found=0 max=3`, `UNSAFE: PASS`; `gates.py docs`: `DOCS public declarations=1281
  documented=1281 exempt=0 fraction=100.0%`, `DOCS: PASS`; `gates.py selftest`: `SELFTEST: PASS`. Every `await` in
  WP-C's four directories has a `// REENTRANCY:` line (scripted check, no exception).
- Coverage (`swift test --enable-code-coverage --skip Benchmarks` at `6536e5d`, `llvm-cov export` over all bundles):
  `COVERAGE target=ZTronAssetStorage lines= 97.18% (6967/7169) min=90.0 OK`; WP-C's files 1978/2054 = 96.30% (96.81%
  without `LiveLegacyDefaults.swift`), lowest `CleanupUnits.swift` 92.6%. The R8 yield and `adoptLegacyNow`'s requeue
  path are covered now. Kit and Sync fail on WP-F/WP-G stubs, as expected at L3.
- TSan (`swift test --scratch-path .build-c-tsan --sanitize=thread --filter ZTronAssetStorageTests`, load 45 → 12):
  `Test run with 399 tests in 55 suites passed after 237.444 seconds with 2 known issues`, 0 ThreadSanitizer reports,
  0 `Time limit was exceeded`; WP-B's `R-STO-5: a process kill followed by a power loss…` 31.6 s, WP-H's start/stop
  race 48.1 s, the oracle (seeds serialized) 26.0 s, the state space (one disk at a time) 237.4 s for 49 rows.
- iOS Simulator (`897F9D8D…`, `caffeinate -i xcodebuild test … -skip-testing:ZTronAssetKitBenchmarks
  -collect-test-diagnostics never OTHER_SWIFT_FLAGS='-warnings-as-errors'`). The line this entry promised was missing
  (review round 3); pasted now from that run's own result bundle, read in the L3 close-out session with `xcrun
  xcresulttool get test-results summary --path .build-c/xcode-sim/Logs/Test/Test-ZTronAssetKit-2026.10.09_17-21-39-+0200.xcresult`
  (started 17:21:39, after `6536e5d`; `5977c2e` changed only this file): `{'result': 'Passed', 'totalTestCount': 763,
  'passedTests': 762, 'failedTests': 0, 'skippedTests': 0, 'expectedFailures': 1}`, device `897F9D8D-B10D-4D91-8E22-417A2B9D70AA`
  (the expected failure is CCR-2's known issue). The earlier bundle of that afternoon (`…17-05-57…`) reads the same.
- Benchmarks (informational; WP-C owns none): `swift test -c release --scratch-path .build-c-perf -Xswiftc
  -enable-testing --filter Benchmarks` at load 7–10: 8 of 9 passed; WP-B's P-13 failed again (`unit max 7.1545 ms
  (p50 0.961375 ms, p95 0.994083 ms); budgets 2.0 s, 5.0 ms per batch`), as OI-3; WP-C changed no reaper code.

## Evidence of fix round 1 (this worktree, `wp/c`, 2026-10-09; this Mac, 8 cores)

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
