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
  21 kinds of edit, `…a purge removes a path from both namespaces, while an edit of files alone is undone by a power
  loss`). A power loss can leave one file under two names (directories are independent); it is then one inode
  (tested: `…a file a power loss left under two names is one file…`).

## H-2 — Crash points, modes and durability levels

- **Decision.** Mutations (the eight crash-boundary kinds) are numbered from 0 in call order, **failed ones
  included** (a failed rename is still a boundary the store crossed); queries and `releaseLock` are logged but not
  numbered. `crashBefore: k` makes mutation k and everything after it never happen: the call throws `.io`, every
  later call throws `.io` (`releaseLock` becomes a no-op), locks are dropped, and `survivingDisk()` returns the
  disk frozen at that point per `crashMode`. Without a crash, `survivingDisk()` applies the mode *now* (a test's
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
  none. A write fault models `write(2)` failing **after** `open(2)` succeeded (fix round 1; it used to leave the file
  untouched): the file exists afterwards, a `.truncate` write has emptied it, and `partialBytes` (default 0) land
  before the error, which is the pessimistic outcome for `index.tmp` and `.resumetmp`. Faults apply to queries too. Free space is the configured
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
  create a directory outside the repository). It returns values and imports no Swift Testing (ADR-041).
- **Consequences.** `R-STO-6: FakeFileSystem satisfies the shared FileSystem conformance contract` passes; 36
  single-defect conformers cover every one of the 29 clauses (`R-STO-6: the conformance contract reports a conformer
  that breaks one of its clauses`; a script cross-checks the clause strings against the defects), so no clause is
  vacuous. WP-B calls the same function on `LiveFileSystem` from `Core/`. **For WP-B (please ratify):** the stale-token
  clause binds `LiveFileSystem.releaseLock`, whose planned body (`flock(fd, LOCK_UN)` then `close(fd)`, store.md §3.3)
  would release a lock re-acquired on a reused descriptor number. It can satisfy the clause without an unsafe escape
  or a lock type above the floor, for example by recording a per-acquisition nonce in the lock descriptor's own file
  offset (`lseek(fd, nonce, SEEK_SET)` at acquisition, the nonce carried in the token's handle next to the
  descriptor, compared with `lseek(fd, 0, SEEK_CUR)` before unlocking; the lock file stays empty). The contract owner may also want one sentence in
  `FileSystem`'s doc (Model, not WP-H's): "`contentsOfDirectory` returns no particular order" and "releasing a stale
  token releases nothing".

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
  control log; `FakeTransferHandle` is unchanged); its remaining steps go to the next attempt. `.stage(Data)` is one
  `createPartial` + one `appendPartial`; `.stageGenerated` appends `GeneratedPayload.chunkBytes` chunks, each
  generated just before it is written. With `request.resume`, the fake continues the earlier partial
  (`continuePartial`) and appends only the bytes it lacks (`resumed: true`). Sink failures map like the transport:
  ENOSPC → `.insufficientSpace(requiredBytes: nil)`, `.io(c)` → `.transient(.localIO(posixCode: c))`, others to
  `localIO` with EFBIG/EIO/EEXIST; no sink → `localIO(ENXIO)`. `httpStatus` is 200 on the AWS tier, `nil` on the
  Apple tier; manifests come from `.network` or `.installedPack(updateChecked: true)` by tier. An unscripted manifest
  fetch answers 304 (the origin has nothing new); responses are queued. `invalidate()` fails every active attempt with
  `.cancelled(.byClient)` and every later `transfer` at once (the start is still recorded, so a start after
  shutdown is visible).
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
  `stop()` (found by a test: it used to return the closed port); concurrent starts await one in-flight start task,
  so there is one listener (fix round 1: a second start used to create a second listener and make the first throw).
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
- `FakeFileSystem.createSymbolicLink(at:destination:)`; `DiskImage.makeDurable()`; `DiskImage.purge(_:)` (fix round
  1: the durable OS-purge edit R-CLN-7 tests need); `DiskImage`'s `==` and `hash(into:)` are now explicit
  (observable state only) instead of synthesized.

## Proposed REENTRANCY rows (ARCHITECTURE §10.3)

| Row | Await | Re-validated afterwards |
|---|---|---|
| h-1 | `EventProbe.next(where:)`: the waiter's continuation | nothing: a terminal wait; registered synchronously in the continuation body and resumed only by its removal from `waiters` (a matching event, finish, stop or the caller's cancellation) |
| h-2 | `EventProbe`'s consumer task (created in `init`): each `await self.receive(event)`, the stop-signal child, `group.next()`, `finish()` | nothing: the task is not the actor; `receive` appends on the actor in stream order and `finish` is idempotent |
| h-3 | `EventProbe.next`'s `onCancel` task: `await self.cancelWaiter(id)` | nothing: the task is not the actor; `cancelWaiter` re-reads the table and is a no-op for a waiter already resumed |
| h-4 | `EventProbe.waitForWaiters(atLeast:)` | nothing: a terminal wait as TS2, resumed by the count or by `finish()` |
| h-5 | `LoopbackHTTPServer`: the listener's `newConnectionHandler` task (`accept`) and the per-connection task (`serve`) | nothing: the tasks are not the actor's turn; `accept` re-reads `stopped` and cancels a late connection, `serve` re-reads `stopped` after each of its awaits |
| h-6 | `LoopbackHTTPServer.start()`: awaiting the one in-flight start task (the listener coming up) | `stopped`: a `stop()` meanwhile cancelled the listener, so every waiting start throws instead of reporting a dead port; concurrent starts share the task, so there is one listener and no identity to re-check; a failed start clears the task only if it is still the current one |
| h-7 | `LoopbackHTTPServer.serve`/`respond`: `respond`, `receive`, the injected delay, `send` | `stopped`: no response is sent and no connection is served after `stop()`; the request log entry was appended before the await; a closing connection removes only its own entry |
| h-8 | `LoopbackHTTPServer.ready/receive/send` (nonisolated static bridges) | nothing: they touch no actor state; each continuation is resumed exactly once by Network |

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
| reqs: coverage, optional stop-during-start test | **Declined:** whether `stop()` lands before or after the listener is ready is up to Network, so the test would assert either outcome and cover a line only by chance (SPEC 7.2) |
| reqs: additive public API | For the orchestrator to ratify (list above, now with `purge(_:)`) |
| reqs: process | (a) for the orchestrator (WP-A re-run); (b) the probe file `ZZVerifyHCorrectProbes.swift` was not in this worktree when fix round 1 started (`git status` clean) |

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
