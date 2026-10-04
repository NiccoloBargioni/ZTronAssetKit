# WP-H (test support) — ADR drafts, proposed REENTRANCY rows, contract additions

Owner: WP-H, Stage 2, level L1. Scope: every WP-H stub in `Sources/ZTronAssetTestSupport`, the shared conformance
contract (R-STO-6) and the fakes' own behaviour tests in `Tests/ZTronAssetStorageTests/TestSupport/`. The orchestrator
numbers these into `DECISIONS.md` and ARCHITECTURE §10.3 at merge.

## H-1 — `FakeFileSystem` is an inode graph; `DiskImage` carries it

- **Context.** store.md §3.4 (as amended by store-1 S1-01) needs names and data durable *separately* and per
  directory, and a process kill that keeps the current/durable split into the next lifetime. The contract's
  `DiskImage` has four path-keyed package fields (`files`, `directories`, `durableFiles`, `durableDirectories`),
  which cannot say that a synced `.part` renamed into an un-synced fan-out is still the same file whose bytes are
  durable (S1-01 timeline (a)), nor that `index.bin` was replaced by a rename while the old inode is still the one a
  power loss brings back.
- **Options.** (a) Path-keyed only (loses inode identity across lifetimes: false I-1 violations or missed ones).
  (b) Replace the package fields with computed views (changes how B and C seed and edit disks). (c) Keep the four
  package fields authoritative and add an internal exact graph plus internal symlink and attribute views.
- **Decision.** (c). Internally an inode table: files have current and synced bytes, directories a current and a
  synced listing, links a target. `DiskImage` carries the exact graph when it comes from a fake. When a test edits
  the package fields (seeding, corrupting a file, an OS purge between launches), the next fake **applies the edit to
  the carried graph path by path** (fix round 1): a removed name is unlinked, a file whose content changed is
  rewritten in place (same identity, same synced bytes), new items are created with their missing parents, synced
  names and synced bytes are edited in the synced listings, attributes follow; every path the edit did not touch
  keeps its exact state, including what the views cannot show (the synced listing of a directory only current names
  reach, one inode under two names). Only an edit the graph cannot take that way (new content for one of a file's
  two names), and a disk built by hand, are rebuilt from the fields: a durable path equal to a current path is the
  same file; a current file without a durable path keeps the synced bytes and mtime the old graph had at that path
  when its content is unchanged; other durable paths are files only a power loss brings back; missing parent
  directories are implied. The namespaces are edited separately, so removing a path from `files` alone is a volatile
  removal a later power loss undoes; `purge(_:)` (public addition, fix round 1) removes a path and everything below
  it from both, as an OS purge does. Garbage collection after a crash keeps every inode that **any mix** of current
  and synced listings reaches from the root (fix round 1; it used to keep only the union of the two pure namespaces,
  which dropped a synced-then-unlinked file of a directory that only current names reached). Equality and hashing
  compare the observable state only (current and durable namespaces with contents, symbolic links, attributes), never
  inode numbers; `digest()` is SHA-256 over the sorted current tree. `makeDurable()` (public addition) marks a seeded
  disk durable, keeping the graph and mtimes when there is one (an edit is applied first; items it creates get the
  latest mtime the graph records). The volume root, `Library/Application Support` and `Library/Caches` always exist
  and are durable (the OS made them), so `standardDirectory` resolves to an existing directory.
- **Consequences.** "PK at k1 → reopen → PL at k2" is exact (tested: `Test support: data synced in a killed lifetime
  stays durable when the next lifetime syncs the directory naming it`, `…a replacing rename keeps the replaced file
  durable under its name until the directory is synced`, `…an unlink a process kill kept un-synced is undone by a
  power loss after the next lifetime syncs the parent`), also across an edit (`…editing one path of a killed disk
  keeps the durable state of every path the edit did not touch`, `…rewriting a file's content in a disk image keeps
  the file's identity and its synced bytes`, `…a fake started on an edited disk shows exactly the edited disk` over
  20 kinds of edit, `…a purge removes a path from both namespaces, while an edit of files alone is undone by a power
  loss`). A power loss can leave one file under two names (directories are independent); it is then one inode
  (tested: `…a file a power loss left under two names is one file…`).

## H-2 — Crash points, modes and durability levels

- **Decision.** Mutations (the eight crash-boundary kinds) are numbered from 0 in call order, **failed ones
  included** (a failed rename is still a boundary the store crossed); queries and `releaseLock` are logged but not
  numbered. `crashBefore: k` makes mutation k and everything after it never happen: the call throws `.io`, every
  later call throws `.io` (`releaseLock` becomes a no-op), and `survivingDisk()` returns the disk frozen at that
  point per `crashMode`. Lock state lives in one lifetime only, so nothing clears it at the crash (fix round 2: the
  `locks.removeAll()` there could not be observed and was removed); the lock **file** survives a process kill with
  its identity and the next lifetime locks that same file (R-STO-9). Without a crash, `survivingDisk()` applies the mode *now* (a test's
  "power loss now"). `processKill` keeps the graph unchanged (split intact); `processKillTornWrite` additionally lands
  half of a crashing `write` (equal to `processKill` for any other op); `powerLossDropUnsynced` rebuilds the namespace
  from synced listings with synced bytes; `powerLossKeepMetadata` keeps the namespace and reverts bytes. After a power
  loss the disk is fully durable and unreachable inodes are dropped. `.barrier` and `.full` both make the synced item
  durable at the call (store.md §3.4's stated simplification); `synchronizeFile` on a directory syncs its listing.
- **Consequences.** Enumeration is deterministic: tested over every k and every mode of a store-shaped scenario
  (`Test support: crash enumeration is deterministic…`, which requires the crashing call's `.io` record), including
  that the crash run's op log equals the clean run's (store-2 S2-08). A crash point under a power-loss mode leaves
  exactly what a kill at that point followed by that power loss leaves (`Test support: a crash point under a
  power-loss mode leaves what a kill at that point followed by that power loss leaves`, every k, both power-loss
  modes, and at least one k where the power loss loses something; a mutant that froze every crash as a process kill
  fails it 30 times), so B's and C's R-STO-5 enumerations really cover power loss.

## H-3 — Faults, capacity and misuse

- **Decision.** Every rule counts the calls that match its operation and URL; the first rule that fires wins.
  `.nth(n)` fires on the n-th match, `.every` on each, `.afterBytes(n)` (writes only) when the bytes that landed on
  that path since the rule was added would pass n: the crossing write lands up to n bytes, every later one lands
  none. The error decides where a write fault fails (fix round 2). An error `write(2)` itself returns (`.noSpace`,
  `.io`, `.other` with EFBIG, EINTR, EDQUOT or EAGAIN) fails **after** `open(2)` succeeded (fix round 1): the file
  exists afterwards, a `.truncate` write has emptied it, and `partialBytes` (default 0), or what an `.afterBytes`
  threshold lets through, land before the error: the pessimistic outcome for `index.tmp` and `.resumetmp`. Any other
  error (`.permissionDenied`, `.notFound`, `.other` with EISDIR, ENOTDIR, EACCES, …) fails `open(2)` itself and
  changes nothing, whatever `partialBytes` says, as store.md §3.4 and F19 require for EACCES before the first
  unlock (round 1 created and truncated the file for every error). No `FaultRule` field was added (that would change
  a contract type): the classification is by error and documented on `partialBytes`. Faults apply to queries too.
  Free space is the configured
  capacity minus the net bytes the lifetime added (deleting frees, an inode still linked elsewhere frees nothing); a
  write that does not fit lands what fits and throws `.noSpace` (an emergent ENOSPC, so a reaper that frees space
  really makes room). Misuse is reported, never trapped: a read over 1 MiB or a negative offset is `EINVAL`, a
  non-file URL `EINVAL`, a directory where a file is needed `EISDIR`, a file used as a directory `ENOTDIR`, a link
  chain over 32 `ELOOP`, removing the volume root `.permissionDenied`; `createDirectory` over any existing item
  succeeds (live `mkdir` maps EEXIST to success).

## H-4 — Symbolic links are a seeded fixture

- **Decision.** `FakeFileSystem.createSymbolicLink(at:destination:)` (public addition) seeds a durable link without
  logging an op or consuming a crash point (the seam never creates links). Lookups follow intermediate links as POSIX
  does (relative targets against the link's directory, `.`/`..` applied lexically) and a final link only where POSIX
  follows it (`read`, `write`, syncs, attributes, locks, listings of a linked directory), never for `itemInfo`,
  `removeItem`, `rename` or `createDirectory`. Needed by the conformance contract's non-following clauses and by
  WP-C's R-SEC-2 test with the fake.

## H-5 — The shared conformance contract (`FileSystemConformance.violations(of:in:)`)

- **Decision.** 29 clauses in disjoint subdirectories of the caller's root: one-level and idempotent `createDirectory`
  (and `.notFound` below a missing parent); truncate and append writes (and `.notFound` into a missing directory);
  bounded reads with empty `Data` at or past EOF (and `.notFound`); exclusive rename failing with `.alreadyExists`
  and touching neither name, moving onto a free name, replacing rename, `.notFound` for a missing source; identity
  kept by truncate and by rename (checked only when the conformer reports identities); absent-is-success removal (also
  below a missing directory), removal of a file and an empty directory, `.notEmpty` for a non-empty one; `itemInfo`
  and one-level listings with names, kinds and sizes (and `.notFound`); links reported as links and removed without
  their target; a short write reporting its error after the bytes that landed (fake only: nothing else can be made
  to write short); syncs at both levels (and `.notFound`); locks (`.wouldBlock` while held, token identity equals the
  lock file's, idempotent release, re-acquire, and, fix round 1, **a stale token's release leaves a lock taken since
  then held**); backup exclusion round-trip; non-negative capacity. Listing order is not a clause: the live order is
  arbitrary, so the fake lists in **descending** name order (fix round 1; it used to sort ascending, which would hide
  store code that relies on an order) and callers sort. Fixtures the seam cannot make reach the fake through the
  internal, ungated `FileSystemFixtureSeeding` cast (no `#available`, R-APL-5); for any other conformer the link is
  created with `FileManager` inside the caller's root. The suite never calls `standardDirectory` (the live one may
  create a directory outside the repository). It returns values and imports no Swift Testing (ADR-041). Of the
  `FileSystemError` mapping it checks only what a test can induce on both conformers inside its root (`.notFound`,
  `.alreadyExists`, `.notEmpty`, `.wouldBlock`, plus `.noSpace` in the fake-only short-write clause); the live
  mapping of every other errno belongs to WP-B's pure errno-mapping table tests (fix round 2: the type's doc used to
  claim "the closed `FileSystemError` mapping").
- **Consequences.** `R-STO-6: FakeFileSystem satisfies the shared FileSystem conformance contract` passes; 36
  single-defect conformers cover every one of the 29 clauses (`R-STO-6: the conformance contract reports a conformer
  that breaks one of its clauses`; a script cross-checks the clause strings against the defects), so no clause is
  vacuous. WP-B calls the same function on `LiveFileSystem` from `Core/`. **For WP-B (please ratify):** the stale-token
  clause binds `LiveFileSystem.releaseLock`, whose planned body (`flock(fd, LOCK_UN)` then `close(fd)`, store.md §3.3)
  would release a lock re-acquired on a reused descriptor number. It can satisfy the clause without an unsafe escape
  or a lock type above the floor, for example by recording a per-acquisition nonce in the lock descriptor's own file
  offset (`lseek(fd, nonce, SEEK_SET)` at acquisition, the nonce carried in the token's handle next to the
  descriptor, compared with `lseek(fd, 0, SEEK_CUR)` before unlocking; the lock file stays empty). **Still open after
  fix round 2 (orchestrator, before WP-B starts):** ratify the clause in DECISIONS.md and amend store.md §3.2 and
  §3.3 and the `FileSystem.releaseLock` doc in the Model ("releasing a stale token releases nothing"), or drop the
  clause; otherwise WP-B's `R-STO-6: the fake and live file systems agree on the shared conformance contract` fails
  on a reused descriptor number. WP-H owns none of those files. The contract owner may also want one sentence in
  `FileSystem`'s doc: "`contentsOfDirectory` returns no particular order".

## H-6 — `FakeRemoteSource` scripting

- **Decision.** One step queue per transfer id (`script` appends). An attempt consumes steps until a terminal step
  (`.stage`, `.stageGenerated`, `.fail`) or a `.hold`; the rest belongs to later attempts, so `[.fail(x), .stage(d)]`
  is a failed attempt and a successful retry. Steps run **synchronously inside `transfer(_:)`**, staging writes
  included: an attempt that is not held is finished before its handle returns, so outcomes never depend on
  scheduling, `activeTransfers` is exact at any read, and `invalidate()` has no in-flight write to wait for. An
  attempt at a `.hold` or at the end of its queue stays active: `release(_:with:)` ends the oldest such attempt of the
  id, and a release with none waiting is **kept for the next hold of that id** (no test can race the engine's start);
  `script` wakes an attempt that ran out of steps, never one at an explicit `.hold`; a progress release lets the
  attempt continue with its queue. `pause()`/`cancel()` on a handle ends that attempt (read from the handle's own
  control log), and so does terminating its `updates` stream (fix round 3, the Model's `TransferHandle`: the
  consuming task cancelled, or the handle dropped; see H-7); its remaining steps go to the next attempt. A parked
  attempt keeps only the handle's **channel** (fix round 3), never the handle or its stream, so an engine that
  releases a held attempt's handle really drops the stream. Parked attempts the
  engine stopped are dropped at every interaction that reads or adds parked attempts: `transfer`, `script`,
  `release` and the `activeTransfers` census (fix round 2: only `script` and `release` did, so an engine run that
  cancels many held attempts and never scripts or releases kept each one, with its handle and request, and every
  census scanned them all; tested with 40 stopped attempts). `.stage(Data)` is one
  `createPartial` + one `appendPartial`, indexing the scripted bytes from their own `startIndex` (fix round 3: a
  `Data` slice such as `payload.dropFirst(2)` used to trap the test process); `.stageGenerated` appends `GeneratedPayload.chunkBytes` chunks, each
  generated just before it is written. With `request.resume`, the fake continues the earlier partial
  (`continuePartial`) and appends only the bytes it lacks (`resumed: true`). Sink failures map like the transport:
  ENOSPC → `.insufficientSpace(requiredBytes: nil)`, `.io(c)` → `.transient(.localIO(posixCode: c))`, others to
  `localIO` with EFBIG/EIO/EEXIST; no sink → `localIO(ENXIO)`. `httpStatus` is 200 on the AWS tier (206 for a resumed request, fix
  round 3: the real transport's final status), `nil` on the Apple tier; `pause()` reports `resumable: true` only for
  an attempt that continues an earlier partial (`request.resume`, which carries the validator), because an attempt of
  this fake writes nothing before its terminal step (fix round 3: it always reported `true`); manifests come from `.network` or `.installedPack(updateChecked: true)` by tier. An unscripted manifest
  fetch answers 304 (the origin has nothing new); responses are queued. `invalidate()` fails every active attempt with
  `.cancelled(.byClient)` and every later `transfer` at once (the start is still recorded, so a start after
  shutdown is visible) **until the next `attach(staging:)`** (fix round 3): `StagingAttachable` says a later attach
  is "a restarted client", and `FakeRemoteSourceFactory` must hand out the same source (`R-NET-1: FakeRemoteSourceFactory
  hands the store's staging sink…` checks identity), so the attach revives it; `isInvalidated` reads `true` until
  then, and scripts, manifests and re-attached transfers carry over to the new client (R-NET-6 and R-NET-3 relaunch
  scenarios, R-CLN-3). The `transportLog` keeps every start (documented on `.stageGenerated`: about 200 bytes per
  start, whatever the payload, so P-7 either uses a fresh source per catalog size or counts that growth as the
  fake's).
- **Cost (fix round 1, documented on the type).** A whole attempt's staging writes run in one turn of the actor on
  the cooperative pool. Over a live sink (P-7's real files) each scripted asset stays at a few MiB (about 8 MiB is
  ~10 ms of writing, C2's stretch): P-7's catalog is many assets, never one large one. Over a `FakeFileSystem` those
  writes are numbered mutations of the fake, so a crash-enumeration scenario must not run transfers concurrently with
  other store work (the crash-point numbering would depend on scheduling). Writing each chunk through a
  `BlockingExecutor` unit was not taken: it would reintroduce the scheduling dependence H-6 removes.

## H-7 — Other fakes

- `FakeTransferHandle` (fix round 1): the terminal update is decided under a lock, so a scripted terminal delivery
  racing a `cancel()` or `pause()` on another thread ends the stream with exactly one terminal element (tested over
  2,000 races; the old yield-then-finish pair delivered two); the control is still recorded, and a non-terminal
  delivery after the end is dropped.
- `FakeTransferHandle` (fix round 3): the Model's `TransferHandle` says terminating `updates` (consumer cancelled or
  dropped) cancels the transfer; the contract body installed no `onTermination`, so an engine that ended a held
  attempt by cancelling its driver task never brought `activeTransfers` (R-SYN-14/15, P-14) to 0. The handle now
  splits into the public handle (which owns the stream) and an internal `FakeTransferChannel` (control log, terminal
  decision, continuation; no stream). `onTermination` captures the channel: on `.cancelled` it marks the stream
  ended and records `.cancel` once, exactly as `cancel()` would; `.finished` (from the channel's own `end(with:)`,
  which holds the lock while it finishes) is ignored without taking the lock. `AsyncStream` reports `.cancelled` both
  for a cancelled consumer and for a stream dropped with every iterator (checked with a scratch probe before relying
  on it), and since `FakeRemoteSource` parks only channels, releasing the handle drops the stream. A consumer that
  keeps `updates` after releasing the handle keeps the attempt (tested). `FakeTransferBackend` keeps its handles in
  `handles`, so only a cancelled consumer applies there. The capture cycle channel → continuation → handler →
  channel is broken by `AsyncStream`, which drops the handler once it ran. `setPauseResumable(_:)` (public addition)
  says what `pause()` reports; `true` until set, so a stand-alone handle behaves as before.
- `FakeTransferBackend`: each `start` returns a fresh `FakeTransferHandle` (no shared log) reachable in `handles`;
  `liveTransfers()` reports `scriptLiveTransfers(_:)` minus names cancelled since; `invalidate()` fails every handle
  with `.cancelled(.byClient)` and is counted.
- `FakeStagingSink`: exclusive `continuePartial`/`adoptDownload`/`writeStaged` (`.nameInUse`), a missing source is
  `.io(ENOENT)`, `readStaged`/`writeStaged` refuse more than `maxBytes` (`.tooLarge`, nothing kept), `discard`
  removes the file and its sidecar, sidecars are keyed by the partial they describe, `adoptDownload` reads (never
  moves or deletes) the real file the test made inside the repository, `failNext(_:with:)` queues one failure per
  operation.
- `EventProbe`: one owned consuming task; `next(where:)` returns the earliest matching event no earlier call
  returned (each event at most once), else waits; `nil` once the stream finished, after `stop()`, or when the
  calling task is cancelled; `stop()` cancels the consumer, which terminates the stream's iteration (so an engine
  subscription is released); so does releasing the probe without `stop()` (its `deinit`, fix round 1). An internal
  `waitForWaiters(atLeast:)` lets the probe's own tests reach the waiting path deterministically; it answers `false`
  once the probe finished (fix round 1: it used to hang). Received events are kept for the probe's lifetime and
  `next` scans them, so a probe serves one test's events, not an unbounded stream (documented, not trimmed:
  `received` promises every event).

## H-8 — `LoopbackHTTPServer` details

- Responses are sent as **complete** messages (`isComplete: true`): an incomplete default-context message holds back
  every later send on another context, which hung the first Connection-close test. A receive that reports the end of
  the client's stream (with or without bytes) is the last one Network completes, so the buffered requests are
  answered and the connection closed. Requests with a `Content-Length` body are consumed (split bodies awaited).
  Ranges: `bytes=a-` and `bytes=a-b` only (anything else is ignored → 200), 206 with `Content-Range`, 416 with
  `bytes */total` past the end, `If-Range` must equal the tag. `start()` is idempotent while running and throws after
  `stop()` (found by a test: it used to return the closed port); concurrent starts wait for one listener (fix round
  1: a second start used to create a second listener and make the first throw).
- **Start versus stop (fix round 2).** Round 1 bridged the listener's state handler to one continuation and assumed
  Network delivers exactly one terminal state. It does not: when `stop()`'s `cancel()` races the listener coming up,
  the handler can see a terminal state and then `.cancelled` (clearing the handler inside the callback does not stop
  a callback already scheduled), so the continuation was resumed twice and the test process trapped; and a listener
  cancelled before its `start(queue:)` sometimes reports nothing, so `start()` hung. Now the waiting starts live on the
  actor (`startWaiters`, registered synchronously in the continuation body) and are resumed only from actor code,
  through one helper that empties the list before resuming: on `.ready` with the port, on `.failed`/`.waiting` with
  the listener error (the listener is cancelled and cleared, so a later `start()` makes a new one), and by `stop()`
  itself with `.stopped`, so a missing callback cannot hang a start and a repeated one finds nothing left to resume.
  The listener is created and started synchronously in `start()`, so `stop()` can no longer land between the two.
  The state handler forwards each state to the actor with the listener's generation number; a state of any listener
  but the current one, or after the port is known, is ignored (fix round 3 narrows the second rule to a repeated
  `.ready`: see the next item). A start resumed with a port re-reads `stopped` and
  throws if `stop()` ran in between. Tested: `Test support: start racing stop ends every start exactly once, with a
  port or stopped, and never hangs` (400 rounds of two starts and a stop spread over the listener's start-up by
  `Task.yield()`; the round-1 server traps with "SWIFT TASK CONTINUATION MISUSE: ready(_:on:) tried to resume its
  continuation more than once" in both runs made; three runs of a scratch probe, 6,000 raced starts each, saw both
  outcomes and no other).
- **Start cancellation and late failure (fix round 3).** Waiting starts are keyed by id; `start()` waits inside
  `withTaskCancellationHandler`, whose `onCancel` task removes that id on the actor and resumes it with
  `CancellationError` (removal before resumption, as `resumeStartWaiters`, so each waiter is still resumed exactly
  once); the listener keeps coming up for later starts. A `.failed`/`.waiting` of the current listener after it was
  ready now cancels it and forgets its port (it used to be ignored behind `port == nil`, so `start()` kept returning
  a dead port); the next `start()` makes a new listener; accepted connections are kept. Tests reach both paths
  through internal seams: `holdListenerStates()`/`releaseListenerStates()` keep a listener "coming up" whatever
  Network's timing, and `listenerStateChanged` and `listenerGeneration` are internal. Range responses index the body
  from its own `startIndex` (a `Data` slice body trapped the test process).
- **Head cap (fix round 2).** A request head over 64 KiB, or 64 KiB without the blank line that ends a head, is
  answered `431 Request Header Fields Too Large` with `Connection: close` and the connection closed (it used to grow
  the buffer without limit and rescan it on every receive). Tested: the round-1 server hit the one-minute time limit.
  A `Content-Length` that is not `1*DIGIT` within 64 MiB is answered 400 and the connection closed (fix round 1: a
  negative one trapped the test process); header names merge case-insensitively, a scripted `Content-Length` wins (a
  test can announce a size other than the body's, R-NET-7) and the server's other headers replace scripted ones. Gzip: header with MTIME 0 and OS 255 (nothing
  clock-dependent), system raw DEFLATE, stored blocks as a fallback (tested), plain-Swift CRC-32.

## Additive public API (contract additions — please ratify or veto)

No existing public or package signature changed. These members were added because the contract's own doc comments
promise them ("Records the cancellation", "Returns a scripted handle", …) and later work packages cannot observe or
drive the fakes without them:

- `FakeRemoteSource`: `manifestRequests`, `cancelledTransfers`, `reclaimReports`, `backgroundEventIdentifiers`,
  `isInvalidated` (all read-only). F's `R-NET-3: an offline launch cancels no live background task` needs
  `cancelledTransfers`; R-NET-5-style engine tests need `manifestRequests`.
- `FakeTransferBackend`: `handles`, `scriptLiveTransfers(_:)`, `cancellations`, `invalidations`; new value type
  `FakeBackendCancellation`.
- `FakeStagingSink`: `sidecars`, `failNext(_:with:)`; new enum `FakeStagingOperation`.
- `FakeTransferHandle.setPauseResumable(_:)` (fix round 3; `pause()`'s contract doc said `.paused(resumable: true)`
  always, now "unless `setPauseResumable(false)`", and `FakeRemoteSource` sets it per attempt: **contract doc
  wording to ratify**).
- `FakeFileSystem.createSymbolicLink(at:destination:)`; `DiskImage.makeDurable()`; `DiskImage.purge(_:)` (fix round
  1: the durable OS-purge edit R-CLN-7 tests need); `DiskImage`'s `==` and `hash(into:)` are now explicit
  (observable state only) instead of synthesized.
- **Semantic change to ratify:** the contract synthesized `DiskImage` equality over its four package fields; it now
  compares the observable state, which **also includes symbolic links (current and durable) and applied
  attributes**, and still never inode numbers or modification times. Two disks that differ only in a link or in
  backup exclusion are therefore unequal (R-SYN-11's "zero side effects" needs that). `DiskImage.paths` keeps the
  contract's body and lists files and directories only; its doc now says so and points at `digest()`, which covers
  links (fix round 2).
- Total (counted by the reqs verifier, fix round 2): 21 additive public declarations, 0 contract declarations
  missing or changed. Fix round 2 added no public declaration (`FakeRemoteSource.parkedAttempts` and
  `LoopbackHTTPServer.maxRequestHeadBytes` are internal, for the fakes' own tests). Fix round 3 adds one
  (`setPauseResumable`), so **22**, and still 0 missing or changed (a `comm` of every `public` line against the
  `contracts` tag); `FakeTransferChannel`, the listener seams and `listenerGeneration` are internal. Ratified by the
  orchestrator before fix round 3: every addition listed up to fix round 2 and the explicit `DiskImage` `==`/hash.

## Proposed REENTRANCY rows (ARCHITECTURE §10.3)

| Row | Await | Re-validated afterwards |
|---|---|---|
| h-1 | `EventProbe.next(where:)`: the waiter's continuation | nothing: a terminal wait; registered synchronously in the continuation body and resumed only by its removal from `waiters` (a matching event, finish, stop or the caller's cancellation) |
| h-2 | `EventProbe`'s consumer task (created in `init`): each `await self.receive(event)`, the stop-signal child, `group.next()`, `finish()` | nothing: the task is not the actor; `receive` appends on the actor in stream order and `finish` is idempotent |
| h-3 | `EventProbe.next`'s `onCancel` task: `await self.cancelWaiter(id)` | nothing: the task is not the actor; `cancelWaiter` re-reads the table and is a no-op for a waiter already resumed |
| h-4 | `EventProbe.waitForWaiters(atLeast:)` | nothing: a terminal wait as TS2, resumed by the count or by `finish()` |
| h-5 | `LoopbackHTTPServer`: the listener's `newConnectionHandler` task (`accept`) and the per-connection task (`serve`) | nothing: the tasks are not the actor's turn; `accept` re-reads `stopped` and cancels a late connection, `serve` re-reads `stopped` after each of its awaits |
| h-6 | `LoopbackHTTPServer.start()`: the waiter's continuation (the listener coming up), inside `withTaskCancellationHandler` | `stopped`: a start resumed with a port throws if `stop()` ran before its turn. The waiter is registered by id synchronously in the continuation body and resumed exactly once, only by actor code that removed it first: `resumeStartWaiters` (empties the list) with the port on `.ready`, with the error on `.failed`/`.waiting`, with `.stopped` from `stop()`; `cancelStartWaiter` with `CancellationError` (fix round 3); concurrent starts wait for the one current listener |
| h-7 | `LoopbackHTTPServer.serve`/`respond`: `respond`, `receive`, the injected delay, `send` | `stopped`: no response is sent and no connection is served after `stop()`; the request log entry was appended before the await; a closing connection removes only its own entry |
| h-8 | `LoopbackHTTPServer`: the listener's `stateUpdateHandler` task (`listenerStateChanged`); `receive`/`send` (nonisolated static bridges) | nothing: the handler task is not the actor's turn, and `listenerStateChanged` ignores a state of any listener but the current one (generation number) and a repeated `.ready`, however late, often or rarely Network reports it (a `.failed`/`.waiting` after `.ready` drops the listener and its port, fix round 3); the bridges touch no actor state and Network calls each completion exactly once |
| h-9 | `LoopbackHTTPServer.start()`'s `onCancel` task: `await self.cancelStartWaiter(id)` (fix round 3) | nothing: the task is not the actor; `cancelStartWaiter` re-reads the table and is a no-op for a waiter already resumed |

`FakeRemoteSource`, `FakeTransferBackend` and the Mutex-backed fakes contain no await.

## Fix round 1 — dispositions of the verifiers' findings

| Finding | Disposition |
|---|---|
| reqs, blocking: no test that a power-loss crash point equals kill-then-power-loss | Fixed: new crash test (H-2); it fails 30 times on the scratch mutant the verifier described |
| reqs, blocking: trivially-true `FakeAppVersionSource`/`SeededRandom` test | Fixed: deleted (new in this WP; `SeededRandom` has no draw API to test) |
| correct, blocking: crash GC dropped synced listings of current-only directories (VERIFYPROBE-5) | Fixed, test first (H-1, mixed-path GC) |
| correct, blocking: any edit rebuilt the whole disk (VERIFYPROBE-6) | Fixed, test first (H-1, edits applied path by path; `rebuild` only as a fallback) |
| correct, blocking: concurrent `start()` made the first throw (VERIFYPROBE-1) | Fixed, test first (H-8, row h-6) |
| correct, blocking: negative `Content-Length` trapped the process (VERIFYPROBE-2) | Fixed, test first (H-8; five malformed lengths tested) |
| reqs: 11 clauses without a defect; clause count | Fixed: 12 new defects (one per uncovered clause plus the new stale-token clause), 29 clauses, count corrected (H-5) |
| reqs: stale-token release not in the contract | Fixed: new clause (H-5); binds WP-B, flagged for ratification |
| reqs: sorted listings hide order reliance | Fixed: descending order, documented on the fake and the contract (H-5); the `FileSystem` doc sentence is the contract owner's |
| reqs: `if let crashIndex` skipped silently | Fixed: `try #require` |
| reqs: "on the caller" not asserted | Fixed: a task-local value set by the caller is read inside the unit |
| reqs: indentation | Fixed |
| correct: handle terminal race | Fixed, test first (H-7) |
| correct: `EventProbe` without `deinit`; census wait hangs after finish | Fixed, tests first (H-7) |
| correct: failed truncating write kept the old bytes (VERIFYPROBE-3a) | Fixed, test first (H-3) |
| correct: purge guidance (VERIFYPROBE-3c) | Fixed: `DiskImage` doc and `purge(_:)` (H-1) |
| correct: synchronous staging cost and op ordering | Documented (H-6); per-chunk executor units declined (they reintroduce scheduling dependence) |
| correct: header case conflicts | Fixed, test first (H-8) |
| correct: unbounded growth | Request body capped at 64 MiB (H-8). **Declined:** a counts-only op-log option for `FakeFileSystem` (it would change the contract's configuration type, and the fake holds every file's bytes in memory anyway, so no memory budget can be measured over it: documented on the type); trimming `EventProbe` events (`received` promises every event: documented) |
| reqs/correct: TestSupport not compiled for iOS by the gate | Orchestrator decision (WP-H cannot edit `Scripts/` or `Package.swift`); WP-H ran the cross-compile by hand (see the fix-round report) |
| reqs: coverage, optional stop-during-start test | **Declined in round 1 (wrongly; superseded in fix round 2):** whether `stop()` lands before or after the listener is ready is up to Network. The race this hid trapped the process; round 2 tests the invariant instead (H-8) |
| reqs: additive public API | For the orchestrator to ratify (list above, now with `purge(_:)`) |
| reqs: process | (a) for the orchestrator (WP-A re-run); (b) the probe file `ZZVerifyHCorrectProbes.swift` was not in this worktree when fix round 1 started (`git status` clean) |

## Fix round 2 — dispositions of the verifiers' findings

| Finding | Disposition |
|---|---|
| reqs, blocking: trivially-true "a process kill releases every lock" test (G4) | Fixed: replaced by `Test support: a process kill keeps the lock file with its identity, and the next lifetime locks that same file` (identity of the token, of the file after the kill and of the next lifetime's token; `.wouldBlock` after it). Two scratch mutants fail it: acquisition replacing the lock file (2 issues) and a kill frozen as a power loss (3 issues). The unobservable `state.locks.removeAll()` at the crash was removed, with a comment saying why none is needed (H-2) |
| correct, blocking: `start()` vs `stop()` double resume (trap) and hang | Fixed, test first (H-8, rows h-6 and h-8). The new race test trapped the round-1 server with the continuation-misuse message, before and after the yield spread was added; it passes on the fix |
| reqs: `InlineBlockingExecutor` test passes for an unstructured `Task` | Fixed: the unit also reports the identity of the task it runs in (`withUnsafeCurrentTask { $0?.hashValue }`, in the test only; no gated pattern), which must equal the caller's. Scratch mutants `await Task { work() }.value` and a task-group child both fail it |
| correct: write faults always applied the after-open side effects | Fixed, test first (H-3): open-time errors change nothing; 5 errors tested (`.permissionDenied`, `.notFound`, EACCES, EISDIR, ENOTDIR), 20 issues on the round-1 fake |
| correct: `FakeRemoteSource` kept dead parked attempts | Fixed, test first (H-6): dropped at every `transfer` and census read; the round-1 fake kept 20 and then 41 |
| correct: unbounded request head in `LoopbackHTTPServer` | Fixed, test first (H-8): 431 and close past 64 KiB; the round-1 server hit the one-minute time limit |
| reqs: conformance doc claimed the closed error mapping | Fixed (H-5): the doc names the errors the clauses check and points the rest at WP-B's errno-mapping tests |
| reqs: additive API, `DiskImage` equality, `paths` | `paths` documented as files and directories only (body is the contract's); equality change and additions listed above for ratification |
| reqs: stale-token clause binds WP-B (ratification) | For the orchestrator before WP-B starts (H-5): DECISIONS.md, store.md §3.2/§3.3 and the Model's `releaseLock` doc are not WP-H files. Not declined, not doable here |
| reqs: verifier's xcodebuild wrote an error result bundle to the system temp directory | Not a WP-H defect; WP-H may not delete outside the repository, so a human should remove that one `.xcresult`. WP-H's own iOS build in this round passes `-resultBundlePath` inside `.build-h`, with `TMPDIR` and the module caches inside `.build-h` too, so no failing build of WP-H writes outside the repository |

## Fix round 3 — dispositions of the verifiers' remaining findings

Failing test first for every bug: each regression test below was run before its fix (or against a mutant restoring
the pre-fix body, for the handle termination that an interrupted earlier attempt of this round had already written)
and failed as stated.

| Finding | Disposition |
|---|---|
| correct, blocking: `.stage(Data)` sliced a `Data` slice with zero-based offsets (trap) | Fixed (H-6): offsets count from the slice's `startIndex`. `Test support: a stage step scripted with a Data slice stages the slice's bytes, fresh and resumed` (`dropFirst(4)` fresh, `parent[4..<10]` resumed) ended the pre-fix test helper with "unexpected signal code 5" |
| correct, blocking: the loopback Range path sliced a `Data` slice body with zero-based indices (trap) | Fixed (H-8): the range counts from the body's `startIndex`. `Test support: a range request against a body that is a Data slice gets the slice's bytes` (`bytes=2-`, `bytes=0-3`, no range) ended the pre-fix helper with "unexpected signal code 5" |
| correct, blocking: `FakeTransferHandle` ignored the termination of its stream; the census kept a cancelled consumer's attempt | Fixed (H-6, H-7): `onTermination` records `.cancel` once on `.cancelled`; the source parks the channel, not the handle, so a dropped handle also cancels. Tests: `…cancelling the task that consumes a held attempt cancels the attempt and drops it from the census`, `…dropping the handle of a held attempt cancels the attempt and drops it from the census`, `…cancelling the task that consumes a handle's updates records a cancellation on the handle` (backend), plus two guards that must not cancel: `…a consumer cancelled after its attempt ended records no cancellation`, `…an attempt whose updates stream outlives its handle stays active and still ends by release`. A mutant without the handler's effect fails the first three (8 issues); the guards pass on it, as they must. `oneOrderedTransportLog` now keeps its parked handle alive (it used to discard it, which the contract makes a cancellation) and asserts on it |
| correct, blocking: `invalidate()` made the source permanently dead for a restarted client | Fixed (H-6): `attach(staging:)` revives the source (the factory must return the same source, which `R-NET-1: FakeRemoteSourceFactory hands the store's staging sink…` checks). `…a source re-attached by a restarted client after shutdown transfers again through the new sink` (start → shutdown → new client on the same factory → transfer) failed on the pre-fix fake with 3 issues |
| correct: `.paused(resumable: true)` always; resumed AWS stage reported 200 | Fixed (H-6, H-7): `resumable` is `request.resume != nil` on the source's handles (new public `setPauseResumable(_:)`, default `true` for stand-alone handles); a resumed AWS stage reports 206. `…pausing a parked attempt is resumable only when it continues an earlier partial with a validator` failed before (1 issue), the resume test's new 206 expectation failed before (1 issue); `…a stand-alone handle pauses resumably unless the test says no partial was kept` covers the default. No sidecar is written by the fake (documented: the test that scripts `request.resume` seeds what the engine needs) |
| correct: O(k·n) appends in `FakeFileSystem` | Fixed: the kind and size are read without binding the node, so the append mutates a uniquely referenced array. No deterministic test can show a complexity class without timing, so a throwaway probe (256 appends of 256 KiB, debug build, last 8 over first 8) measured the ratio: **22.4** before, **0.65** after; the probe was deleted |
| correct: `start()` not cancellation-aware; `.failed` after `.ready` ignored | Fixed (H-8, rows h-6, h-9): `…a start cancelled while the listener comes up throws CancellationError, and a later start gets the port` hung the pre-fix server past its one-minute time limit (killed after 120 s); `…a listener that fails after it was ready is replaced at the next start, whose port serves` failed before (1 issue) |
| reqs: latency test name claimed an untested default | Fixed: renamed to `…scripted latency is awaited through the injected delay, and a response without latency awaits nothing` (what it asserts), and `…a server with the default delay answers a response scripted with an hour of latency at once` runs `NoLoopbackDelay.wait` (a sleeping default would hit the time limit) |
| reqs: ADR said 21 kinds of edit | Fixed: 20 (`Edit.allCases`) |
| correct: unbounded `transportLog` and `FakeTransferBackend.made` | Documented on `.stageGenerated` (one request per start, a few hundred bytes; P-7 uses a fresh source per size or counts it as the fake's). **Declined:** a counts-only mode (new API with no consumer; `starts`/`controlLog` promise every entry) and trimming `made` (`handles` promises every handle, which tests drive) |
| reqs: contract surface (21 additions, explicit `DiskImage` `==`/hash) | Ratified by the orchestrator before this round; fix round 3 adds `FakeTransferHandle.setPauseResumable(_:)` (22) and changes the wording of `pause()`'s doc (listed above) |
| reqs: stale-token clause binds WP-B | Orchestrator decision: the clause stays; WP-B makes `LiveFileSystem` satisfy it. Nothing to change here |
| reqs: `.barrier`/`.full` indistinguishable; `FSOpRecord` has no `SyncLevel` | Not doable in WP-H (`FSOpRecord`'s initializer is contract): for the orchestrator (a level-recording spy in WP-B, or a contract change) |
| reqs: ADR-038 wording (conformance suite's `FileManager` link fixture) | For the orchestrator when merging H-5 (record the test-fixture exception) |
| reqs: iOS gate does not compile TestSupport | Orchestrator (the gate is `Scripts/`). WP-H type-checked `Sources/ZTronAssetTestSupport` for `arm64-apple-ios15.0` against the iOS products of the required build: exit 0 |
| reqs: DerivedData folder outside the repository | Not WP-H code; for the human (`rm -rf ~/Library/Developer/Xcode/DerivedData/h-hgsfxwgcziygfseopnrziiztmbdq`). The folder may come from an earlier `xcodebuild` in this worktree (15:57); every `xcodebuild` build of fix round 3 passed `-derivedDataPath` and `-resultBundlePath` inside `.build-h`. See the fix-round-3 incident below |

## Evidence and incidents

- Test-first: the new remote-source, staging-sink, backend, probe and loopback tests were run against the stubs
  first (each run stopped at the stub's `fatalError("WP-H: …")`), then implemented. The `FakeFileSystem` tests were
  written together with the fake; two throwaway mutation probes confirmed they bite (a process kill that makes
  everything durable, and a no-op `synchronizeDirectory`, each failed at least five durability tests).
- Per-test file I/O: `adoptDownload`'s test writes one file under `<repo>/.build-testsupport-fixtures/` (git-ignored)
  and removes its own directory. The loopback tests use a raw `NWConnection` client on 127.0.0.1 only (no URLSession,
  nothing written).
- **Incident.** While diagnosing a hung loopback run, a `pkill -f swiftpm-testing-helper` was issued before the
  per-worktree filter was in place; it may have terminated a concurrently running test helper of another worktree
  (WP-A's `.build-a` was running at the time). If WP-A saw an unexplained aborted test run around then, it should
  re-run. Every later kill was restricted to this worktree's own `.worktrees/h` test bundles.
- **Incident (fix round 3).** One `xcodebuild -list -derivedDataPath .build-h/xcode` (to look for a TestSupport
  scheme) was refused because `-list` does not take `-derivedDataPath`, and xcodebuild wrote its error result bundle
  to the per-user temp directory despite `TMPDIR` pointing inside `.build-h`:
  `/var/folders/7y/s6b_jp997bl6j5yw9d17lvfm0000gn/T/ResultBundle_2026-05-10_00-34-0037.xcresult` (20 KiB). WP-H may
  not delete outside the repository, so a human should remove it (`rm -rf` that path). Every later `xcodebuild` call
  of this round named a scheme and passed `-resultBundlePath` inside `.build-h`.
