# D2: `answerPresentMembers`' answer turn at 10,000 present ids (PROBE-C21-APM)

This is a read-only analysis for ruling S3-R27, covering open item 5 of the WP-F draft (`docs/adr-drafts/s3f.md:6836-6838`).

- **Code base.** Worktree `.worktrees/s3f`, branch `wp/s3f`, HEAD `d5b2ab9`; the last code commit is `e599ae1`. Paths are relative to the worktree.
- **What was run.** Nothing was built, run or timed for this report.
- **Figures.** Each figure is one of two kinds:
  - a measurement, quoted with its source;
  - an estimate, marked "est.", resting on two things:
    - the quiet micro-timings in `.build-orchestrator/s3f-c20-analysis/profile-40ms.md`;
    - the differences between the probe's three shapes.
- **Units.** "ms" means at 10,000 ids or rows. "Production" means the whole answer turn, the parts the probe leaves out included (§1.3).
- **UNCONFIRMED.** Anything not confirmed from the code is marked UNCONFIRMED and listed in §6.

## 0. In brief

**What the time is made of.** The probe times `bind` and `answerPresentMembers` alone (`ProbeC21APM.swift:51-57`):

- group: 10.79 ms (10.51 on the rerun);
- groups: 12.76 ms (12.26);
- users: 14.17 ms (13.27).

Per id, the cost falls into four parts:

- **About 0.29 µs that every shape pays.** It is the binding, the index release, the set operations and the call.
- **0.44 to 0.50 µs per row.** It is mostly one `jobs[transfer]?` access per row (the 66-byte TransferID hashed each time) and `setInterest`'s three lookups. The token sort costs 0.4 to 0.7 ms at 10,000 rows, and a one-element `sorted()` array is built per row.
- **The answer.**
  - A group member's drop costs about 0.47 to 0.49 µs: three table accesses and one or two `Group` copies.
  - A waiter's move to the store costs about 0.57 to 0.63 µs. Most of that is one `spawn` (a `Task`) per waiter.
- **The group shape only: 3.0 ms.** It is the `row.held.sorted()` of the one 10,000-id row.

There is no formatting on this path. The probe cannot see the production extras, about 0.6 to 1.65 ms (§1.3).

**The routes.**

- **Route (a), branch-free cuts (§2.1).** The cuts remove the sorts that order nothing observable. Each row's job access becomes one access for all rows, as `Job.takeOff` already does. The group drop is done in one access, the index and interest tables are hit fewer times, and no `Job` copy is held at the answer site. Route (a) changes neither the order nor the answers. It lands the group shape. It brings the groups shape to the edge, and it is short for users.
- **Route (b), batched store reads (§2.2).** The binding and every interest's removal stay in the turn, and so do the group drops: those cannot leave the turn, because the group's pending clause forbids it. Only the waiters' store reads leave the turn. They go to owned tasks of `answersPerTurn` reads each, instead of one task per waiter. This lands the users shape. Its premise holds: after (a), the binding and the removals fit by themselves (§2.2).
- **Route (c), a bounded answer over turns (§2.4).** It is not triggered. It stays as the contingency and needs its own state, clauses and a two-order probe.

**Recommendation (§3).** Take (a) together with (b)'s B1, and commit a BenchSync case for the turn's whole post-await tail. The expected production figures, central estimate (range), from the best-of-3 base, are:

| Shape | Central | Range |
|---|---|---|
| group | 5.9 ms | 5.1 to 6.6 |
| groups | 8.1 ms | 7.3 to 8.9 |
| users | 7.1 ms | 5.6 to 8.6 |

From the rerun base they are 5.6, 7.6 and 6.2 ms.

If the committed case shows groups or users above 8.5 ms, the fallback is A7: drop the rows' token sort. That is an order change and needs the ruling, as S3-R26 item 10 accepted the table's order in `resolveAll`. With A7, the conservative ends become 8.5 for groups and 8.2 for users.

Two shapes of the same reference set were not measured: 10,000 one-member ensure groups, and a run row of 10,000 ids. Each needs one more item (§2.5).

## 1. What the turn costs

### 1.1 What the probe times and what the production turn adds

The probe calls `engine.bind(present, to:since:)` and then `engine.answerPresentMembers(of:_:)` inside the actor (`.build-s3f/c21/apm/Tests/ZTronAssetKitBenchmarks/ProbeC21APM.swift:51-57`). The job holds 10,000 ids sharing one 16-byte content, and its download is held at the source.

In production the turn is the last segment of `answeredFromStore` (`Sources/ZTronAssetSync/Engine/EnginePresence.swift:201-293`). It begins after the last await:

- for a prefetch-lane job, the last id's read (`:224`);
- for a user-initiated job, `adoptLegacyNow` (`:263`).

It then runs:

1. `unaskedIDs` (`:247` or `:275`, defined at `:298-303`);
2. the final guard, which binds `current` and `active` (`:277-278`);
3. `bind` and `answerPresentMembers` (`:282-283`), the part the probe times;
4. `retire`, `pump` and `reconcileIdle` (`:289-291`). `reconcileIdle` runs `pruneBoundContent` (`EngineConditions.swift:16`, `EnginePresence.swift:78-94`).

`sparePresent` is the other caller (`EngineFailures.swift:532-555`). Its last turn runs `assets.subtracting(present).sorted()` (`:542`), `bind` (`:545`), the `current` copy (`:546`), the answer (`:547`) and `removeJob` (`:550`).

### 1.2 The cost by part

| Part | Code | Unit (est.) | group | groups | users |
|---|---|---|---|---|---|
| `bind`: one `boundContent` insert per id, capacity reserved | `EnginePresence.swift:66-69` | ~40 ns/id | 0.40 | 0.40 | 0.40 |
| The rows' `intersection(present)`: one lookup per id; the result is the interest's own set when every id matches | `:351` | ~45 ns/id | 0.45 | 0.45 | 0.45 |
| The index release in `setInterest`: two hashed `tokensByID` accesses per id | `EngineState.swift:917-919`, `:1090-1094` | ~120 ns/id | 1.20 | 1.20 | 1.20 |
| `job.assets.subtract(present)` | `EnginePresence.swift:368` | ~55 ns/id | 0.55 | 0.55 | 0.55 |
| The `answerPresent` call and its `notifyObservers` (with no observers, two `isEmpty` reads) | `:100-117`; `EngineCommands.swift:1709-1735` | ~25 ns/answer | 0.25 | 0.25 | 0.25 |
| **Common per id, C** | | **~0.285 µs** | 2.85 | 2.85 | 2.85 |
| `row.held.sorted()` | `EnginePresence.swift:364` | 3.01 ms per 10,000 ids (profile); ~50-55 ns per one-id row | 3.0 | 0.5 | 0.5 |
| The per-row `self.state.jobs[transfer]?` access (`_modify`, TransferID hash 48 ns) | `:360`, `:362` | ~187 ns/row (profile, in-place `jobs[key]?.field`) | ~0 | 1.87 | 1.87 |
| `setInterest(nil)`'s fixed part: `interests` looked up three times (`:904`, `:915`, `:923`), two `JobInterest` or `Set` copies, the counts | `EngineState.swift:903-924` | ~100 ns/row | ~0 | 1.0 | 1.0 |
| The rows' tuples, the copy that `sorted` makes and the token sort | `EnginePresence.swift:349-353` | ~65-100 ns/row (the sort alone ~0.4-0.7 ms at 10,000) | ~0 | 0.65-1.0 | 0.65-1.0 |
| The rows' deallocation: a whole row's `held` is the removed interest's set storage, freed here | end of `:345-369` | ~35 ns/row | ~0 | 0.35 | 0.35 |
| **Per row, R** (bottom-up) | | **~0.44-0.48 µs** | | | |
| A group member's answer, `dropGroupMember`: three `groups` accesses (`:659`, `:662`, `:663`; the third binds a whole `Group`, which the first may copy too) and two `pending` hashes | `EngineJobs.swift:658-668` | bottom-up ~275-345 ns | 2.75-3.45 | 2.75-3.45 | — |
| A waiter's answer, `answerWaiterFromStore`: the waiter copied and written back, then `spawn` (a `Task` created and enqueued, a `tasks` insert, a second notify) | `EnginePresence.swift:130-144`; `EngineLifecycle.swift:52-69` | bottom-up ~400-650 ns (update 100-150, spawn 300-500) | — | — | 4.0-6.5 |

**The anchors.** These come from the measured figures. S is the group shape's big sort, D a group drop, W a waiter's answer.

- **R.** R = (groups − group + S) / 10,000 = (12.76 − 10.79 + 3.0) / 10,000 = **0.497 µs**. The rerun gives (12.26 − 10.51 + 3.0) / 10,000 = 0.475. The bottom-up figure is 0.44 to 0.48.
- **W − D.** W − D = (users − groups) / 10,000 = (14.17 − 12.76) / 10,000 = **0.141 µs**; the rerun gives 0.101. W is the waiter's answer and D the group drop.
- **C + D.** C + D = (group − S) / 10,000 = (10.79 − 3.0) / 10,000 = **0.779 µs**; the rerun gives 0.751.
  - With C at 0.285, the anchored D is **0.47 to 0.49 µs**, against 0.28 to 0.35 bottom-up.
  - The anchored W is D + 0.10 to 0.14, which is **0.57 to 0.63 µs**.
- **The unexplained part.** The bottom-up sums fall short of the measurements:

  | Shape | Bottom-up | Measured | Short by |
  |---|---|---|---|
  | group | 8.95 ms | 10.79 | 17% |
  | groups | 10.55 ms | 12.76 | 17% |
  | users | 12.45 ms | 14.17 | 12% |

  Between 0.12 and 0.2 µs per id is not explained by the micro-timings. A likely cause, not confirmed, is memory traffic over about 3 to 5 MB of tables and per-interest sets at a load of about 7. The micro-timings were taken quiet and warm. Every expected figure below subtracts savings from the measured totals, so this part stays in them: the conservative choice.

**Formatting: none.** No `record(...)`, interpolation or `String(format:)` runs in any of these:

- `answerPresentMembers`, `answerPresent`, `dropGroupMember`, `answerWaiterFromStore`;
- `spawn`, `setInterest`, `release`.

The profile's 296 ns per format does not apply here.

**Hashed table accesses**, each behind a `self.state` exclusivity check:

- **Per id, every shape:** five hashed accesses, all on AssetID, whose String-backed hash and `==` are the slow part:
  - `boundContent` 1;
  - `present` 1;
  - `tokensByID` 2;
  - `assets` 1.
- **Per row:** `jobs` 1 (a TransferID), `interests` 3 (an InterestToken, which hashes as a `UInt64`).
- **Per group member:** `groups` 3 (an InterestToken), `pending` 2 (an AssetID).
- **Per waiter:** `waiters` 2 and `tasks` 1 (`UInt64` keys).

**Job copies.**

- **Inside `answerPresentMembers`:** one per call. The `map` at `EnginePresence.swift:349` binds the table's job while the rows are built. It dies before the first removal, which is what B11 intended. There is none per id.
- **In production:** several copies are bound across the removals:
  - `job` (`:202`, used up to `:218`);
  - `current` and `active` (`:277-278`);
  - `sparePresent`'s `current` (`EngineFailures.swift:546`).

  The first removal copies the job's `interests`, `tokensByID` and `assets` (10,000 entries each) on write, if those copies are still alive there. Under lexical lifetimes they probably are: the `Task` creation in `spawn` and a continuation resume are calls into the runtime, so the optimizer may not end the copies early across them. UNCONFIRMED; est. 0.3 to 0.8 ms with the frees.

### 1.3 The production extras the probe leaves out

| Extra | Code | Est. |
|---|---|---|
| `unaskedIDs` over 10,000 ids. Every id was asked, so `!asked.contains($0)` fails first and the entry read never runs. The function also copies the job | `EnginePresence.swift:298-303` | 0.45-0.65 ms |
| Copy-on-write of the job's tables while `job`/`current` live (§1.2) | `:202`, `:277`; `EngineFailures.swift:546` | 0-0.8 ms (UNCONFIRMED) |
| `retire` and `pump` (`materializeEnsures` walks the groups) | `EnginePresence.swift:289-290` | ~0.05 ms |
| `reconcileIdle` → `pruneBoundContent`: `removeAll` and the walk of the groups when the job was the last; the filter path when other jobs exist | `EngineConditions.swift:16`; `EnginePresence.swift:78-94` | ~0.1 ms (filter path ~+0.5) |
| The users shape only: `uninstalled.removeAll()` | `EnginePresence.swift:274` | ~0.02 ms |

**E** is the sum of these extras:

- 0.6 to 0.85 ms when no job copy is alive (A8) and the job is the only one;
- 0.9 to 1.65 ms without A8;
- up to about 0.5 ms more when other jobs keep the ledger's filter path.

The production turns today are therefore est. group 11.7 to 12.4 ms, groups 13.7 to 14.4, users 15.1 to 15.8. Each is the best of 3 plus E without A8.

## 2. The routes, ranked

The routes are ranked by the change they need:

1. Route (a) adds no state, no branch, and no change of order or answers.
2. Route (b) adds one bounded loop and needs no new invariant clause.
3. A7 is an order change.
4. Route (c) adds new state and new invariant clauses.

### 2.1 Route (a): branch-free cuts

Each cut keeps the same interests answered, the same answers and the same caller-visible order. Their tests are the existing answer-site suites, run unchanged, plus the committed bench (§5).

**A1. Iterate `row.held` without sorting it** (`EnginePresence.swift:364`: `for asset in row.held`).

- **Saving:** 3.0 ms for group (profile: 3.01 ms for sorting 10,000 AssetIDs taken from a Set); 0.50 to 0.55 ms for groups and users (a one-element array allocated and freed per row).
- **Correctness:** inside one row the order of the per-id answers reaches no caller. Kind by kind:
  - **Waiter:** a waiter row holds one id.
  - **Prefetch member:** each drop changes only `pending`.
  - **Ensure group:** it settles at the row's last member whatever the order, so its single resume happens at the same point (`EngineJobs.swift:663-667`).
  - **Run:** each id adds 1 to `fetched` (`EnginePresence.swift:124`). The transfer's claim set empties at the row's last id in either order (`EngineRuns.swift:510-513`), so the progress values come in the same sequence.
  - **Heal:** each answer is an independent `heals[asset] = nil`.

  The sort predates B11. B11 only moved it into rows, as `git show bbf5eaa` shows.
- **Branches and risk:** no branch. The only change a test could see is which intermediate state a test-seam observer is shown mid-row; A5 removes those notifications anyway.

**A2. One access to the job for every row.** Add `mutating func takeOffPresent(_ present: Set<AssetID>) -> [PresentRow]` to `Job`, beside `takeOff` (`EngineState.swift:1034-1076`):

1. it builds the rows from `self.interests`, as `:349-353` does now;
2. it sorts them in place by token;
3. it removes each row's ids (`setInterest(nil)` for a whole row, `subtractAssets` for a partial one);
4. it subtracts `present` from `assets`;
5. it returns the rows.

`answerPresentMembers` (`EnginePresence.swift:345-369`) then has one guard, `guard !present.isEmpty, let rows = self.state.jobs[transfer]?.takeOffPresent(present) else { return }`, and answers the rows afterwards.

- **Saving:** 187 ns per row (one in-place TransferID-keyed access, profile) × 10,000 = **1.87 ms** for groups and users, plus about 0.1 ms for the sorted copy that the in-place sort avoids. Nothing for group.
- **Correctness:** the rows are the same. They are built before any change, as now, so the whole/partial split reads the same snapshot, and the token order is the same. The removals are the same, and so are the answers, in the same order.

  Only the interleaving inside the turn moves: every removal now comes before every answer. No answer reads the job's interests or ids:
  - `answerWaiterFromStore` writes `waiters` and `tasks`;
  - `dropGroupMember` writes `groups`;
  - `releaseRunClaim` writes `run.outstanding`;
  - `countRunFetched` and `offerRunProgress` read only `jobs[t]?.active?.bytesReceived` (`EngineEvents.swift:98-100`), which no removal changes;
  - a heal writes `heals`.

  A resumed caller runs after the turn. This is the shape `takeOff` already has, and its doc records the precedent: 27.66 ms through the engine against 7.26 ms in one access (`EngineState.swift:1028-1030`).
- **Branches:** none new. The empty-`held` filter and the `whole` split move into the method; their existing mutants are re-run at the new lines. The guard that the draft lists as structural and unreached, `EnginePresence.swift:356` (`docs/adr-drafts/s3f.md:6754`), merges into the reached guard at `:346`.
- **Risk:** a `waitUntil` predicate that depended on a mid-turn state. None is known (UNCONFIRMED).

**A3. `dropGroupMember` in one access** (`EngineJobs.swift:658-668`). Add `mutating func dropMember(_ asset: AssetID, waitingFor transfer: TransferID) -> CheckedContinuation<Bool, Never>?` to `Group` (`EngineState.swift:1234-1279`). It does three things:

1. it checks and clears `pending[asset]`;
2. it returns the continuation, after setting it to `nil`, when the group is an ensure, it is settled and it still holds the continuation;
3. otherwise it returns `nil`.

The engine then does `guard let continuation = self.state.groups[token]?.dropMember(asset, waitingFor: transfer) else { return }` and resumes it.

- **A3′, optional, the same predicate in one hash:** `pending.index(forKey:)`, compare `pending.values[index]`, `pending.remove(at:)`. All three are in the installed SDK's `Swift.swiftinterface`: `:7807`; `:7908-7909` (`@discardableResult`); and `Values` `_modify` at `:8048-8058`.
- **Saving:** two outer accesses and one or two `Group` copies: **140 to 210 ns** per drop, which is −1.4 to −2.1 ms for group and groups. A3′ saves another 20 to 40 ns, which is −0.2 to −0.4 ms.
- **Correctness:** the same conditions in the same order. The ensure continuation is taken out once and resumed once, as now.
- **Branches:** none new; the two guards are relocated, and their existing mutants are re-run at the new lines.
- **Other callers:** `reroute` (`EngineDispatch.swift:1212`) and the purge walk (`EngineCommands.swift:1025`, `:1073`, `:1108`) gain the same saving. That helps open item 2, `purgeWhileOwedTurns`, and D3's row 14.
- **Risk:** low. `dropGroupMember` is hot on several paths, and the full Sync suite and the group-pending clause (`EngineCommands.swift:1856-1862`) cover it.

**A4. The waiter's move to the store in one access** (`EnginePresence.swift:131-136`). Add `mutating func answerFromStore(at transfer: TransferID)` to `Waiter` (`EngineState.swift:1182-1193`). The engine then does `guard self.state.waiters[token]?.answerFromStore(at: transfer) != nil else { return }`.

- **Saving:** one lookup and two retain/release pairs, 40 to 60 ns per waiter: −0.4 to −0.6 ms for users.
- **Correctness:** the same guard, nothing for a missing waiter, and the same two field writes.
- **Branches:** the existing guard is relocated; there is no new branch.

**A5. One notify per answer site.** Split `answerPresent` (`EnginePresence.swift:100-117`) into a quiet body and the existing wrapper, which notifies (`:116`). `reroute` keeps the wrapper (`EngineDispatch.swift:1221`). `answerPresentMembers` calls the quiet body and notifies once at its end.

- **Saving:** 10 to 15 ns per answer, −0.1 to −0.15 ms. The `notifyObservers` call inside `spawn` (`EngineLifecycle.swift:67`) goes away with B1.
- **Correctness:** with no observers, production does nothing on a notify. Test seams evaluate their predicates once, on the turn's final state.
- **Branches:** none.

**A6. Fewer hashes in the index and in the interest table.**

- **(a) `release` in one hash** (`EngineState.swift:1090-1094`): `index(forKey:)`, `values[index].remove(token)`, then `remove(at:)` when no holder is left. The predicate and the result are the same as `tokensByID[asset]?.remove(token) == false`. The index stays valid across a copy-on-write copy: the installed interface's `_NativeDictionary.copy()` keeps the storage's age and its buckets (`Swift.swiftinterface:15801-15812`), and `validatedBucket` checks exactly those (`:15835-15839`). **Saving:** 35 to 60 ns per released id, −0.35 to −0.6 ms in every shape.
- **(b) `setInterest` reads the old interest once** (`EngineState.swift:903-924`): `let previous = self.interests[token]` drives the switch (`:904`) and the old ids (`:915`); the write at `:923` stays. **Saving:** one of three lookups and one set copy, 25 to 40 ns per call, −0.25 to −0.4 ms for groups and users. Every interest change, `addInterest` included, gains too.
- A variant takes the interest out with `removeValue` or `updateValue` and saves two lookups (−0.4 to −0.6 ms). It turns the switch's nil/non-nil split into an `if let` on the argument. Every add and remove test kills that, but it is a rewritten branch, so it is not in (a).
- **Correctness:** both are equivalent rewrites of private mutators. Index clause I1 recounts `tokensByID`, and the counts are recounted too, after every test that checks `invariantViolations()`.
- **Branches:** none new.

**A8. No `Job` copy alive at the answer sites.** This cut acts on production only.

- **In `answeredFromStore`:**
  - Take the initial sorted ids and the initial lane in one scoped `map` over `self.state.jobs[transfer]` (`EnginePresence.swift:202-212`), as B11 did at `:349`.
  - The fallback at `:218` uses that lane.
  - Replace the binding guard at `:277-278` with projections: `self.state.jobs[transfer].map { $0.epoch == epoch && $0.active?.attempt == attempt && $0.active?.handle == nil } == true`.
- **In `sparePresent`:** use `if self.state.jobs[transfer]?.epoch == epoch` (`EngineFailures.swift:546`).
- **Saving:** 0.3 to 0.8 ms (UNCONFIRMED: whether the copies live there today depends on the optimizer).
- **Correctness:** the same conditions, with no copy held across the mutations.
- **Branches:** none.

**What (a) alone gives**, probe-equivalent and then production, the latter being the probe-equivalent plus E with A8, 0.6 to 0.85 ms:

| Shape | Savings | Probe-equivalent | Production |
|---|---|---|---|
| group | A1 3.0 + A3 1.4-2.1 + A3′ 0.2-0.4 + A5 0.1-0.15 + A6a 0.35-0.6 = **5.05-6.25 ms** | 10.79 → 4.54-5.74 (rerun 4.26-5.46) | **5.1-6.6** |
| groups | A1 0.5-0.55 + A2 1.87 + A3 1.4-2.1 + A3′ 0.2-0.4 + A5 0.1-0.15 + A6a 0.35-0.6 + A6b 0.25-0.4 = **4.67-6.07 ms** | 12.76 → 6.69-8.09 (rerun 6.19-7.59) | **7.3-8.9** (rerun 6.8-8.4) |
| users | A1 0.5-0.55 + A2 1.87 + A4 0.4-0.6 + A5 0.1-0.15 + A6a 0.35-0.6 + A6b 0.25-0.4 = **3.47-4.17 ms** | 14.17 → 10.0-10.7 | **10.6-11.6**: still a miss; (b) is needed |

### 2.2 Route (b): the binding and the removals stay in the turn; only the store reads leave it

**The premise holds.** After (a), the turn's own part fits by itself:

- the binding (about 0.4 ms);
- the rows and the removals;
- the group drops, which must stay. Owing a drop would leave a pending member whose job holds no interest, which breaks clause `EngineCommands.swift:1856-1862`. The run-claim clause `:1893-1897` likewise rules out owing a run claim.

The probe-equivalent figures for that part are group 4.3 to 5.7 ms, groups 6.2 to 8.1 and users 4.1 to 7.7; the users figure is after B1. So (b) applies, and (c) is not needed. A waiter's answer is already asynchronous: its store read is an owned task. What costs is starting 10,000 tasks in the turn.

**B1. Batched store reads.**

- **The change.**
  - Collect, in the turn, the waiters moved to the store as `PresentRead(token, asset, lane)`. A4 marks each one (`fromStore = true`, `transfer`), so no waiter holds an interest or lacks the mark between turns.
  - After the rows, call a new `spawnPresentReads(_ reads: [PresentRead])`. It spawns one owned task per `state.answersPerTurn` reads, the seam at `EngineState.swift:133`. Each task runs an isolated `readPresentLocations(_ batch:)`, which awaits the unchanged `readPresentLocation` (`EnginePresence.swift:147-170`) once per read, in order.
  - When `spawn` refuses, every waiter of the batch is answered as the per-waiter arm answers it today (`:141-143`).
  - `answerWaiterFromStore` stays for its single-waiter callers: `performAwaitAsset` (`EngineCommands.swift:105`), the manifest join (`EngineManifest.swift:426`) and `reroute` through `answerPresent` (`EngineDispatch.swift:1221`). It becomes "mark, then spawn a batch of one", so their behaviour does not change.
  - The await in the loop gets `// REENTRANCY: RE-S36` — each read re-validates its own waiter (`readPresentLocation`); nothing carries over from one read to the next. The spawn closure keeps RE-S21.
- **The saving.** The spawn is about 300 to 500 ns per waiter: a `Task` created and enqueued, a `tasks` insert and a notify (`EngineLifecycle.swift:52-69`). Twenty spawns replace 10,000, so users saves **−3.0 to −5.0 ms**.

  Not counted, and UNCONFIRMED: today 10,000 new tasks hop onto the busy actor during the turn, contending on the actor's queue word. B1 removes that too.
- **The answers.** They are unchanged. Each waiter gets what its own read gives:
  - the location, when the read finds one (`:154-158`);
  - otherwise the job path with the current entry (`:160-169`), or `.notFound`.

  Withdrawal (`EngineCommands.swift:176-192`) and shutdown work as now, because each read re-checks `isRunning` and `fromStore` (`EnginePresence.swift:151`).

  Two things move: the moment of a waiter's read, which can be up to 511 reads later inside its batch, and the number of tasks, 20 instead of 10,000. The store's `location(for:extensions:recordingAccess:)` is a synchronous read of the actor's state with no I/O (`Sources/ZTronAssetStorage/Store/AssetStore.swift:93-95`). The reads are therefore serialized at the store today too, and the batches change little in total time (UNCONFIRMED).
- **R-NET-6 and L4-R5.** They are unchanged:
  - the interests leave the job in the turn, before the attempt can transfer (`EnginePresence.swift:284-292`);
  - each waiter is marked `fromStore` in the turn, so clause `EngineCommands.swift:1763` skips it, as today;
  - a read that finds nothing puts the waiter on the job path of its current entry.
- **S3-R16, in both orders.** The answer site does not depend on the `LaneDropVisit` order. B1 moves only when a read happens relative to later turns, such as an apply that re-binds the id. Such a read already runs after the turn today, at a moment no one controls. This is the "when an answer arrives" class (S3-R16 item 2, non-blocking). The two orders do not differ.

  A probe should confirm it: an apply that re-binds one id between two reads of one batch, run in both orders. The waiter should get what a per-waiter read gives at that moment (UNCONFIRMED).
- **Liveness.** Every `fromStore` waiter is answered in one of three ways:
  - by its read;
  - by `withdraw`;
  - by shutdown's drain. `performShutdown` takes every waiter in the turn it sets `shuttingDown` (`EngineLifecycle.swift:490-498`; `EngineShutdown.swift:53-66`) and joins the tasks afterwards.

  A batch task ends after its last read. A shutdown join waits for at most `answersPerTurn` synchronous store reads per batch: timing only.

  No new state and no new invariant clause is needed. The waiter clause already allows `fromStore` waiters, and an owned task holds each batch.
- **New branches.**
  - The chunk bound in `spawnPresentReads` is new.
  - The refused-spawn arm is relocated: it is the same per-waiter answer, in a loop over the batch.
  - The loop over the batch adds no condition.
- **Tests (§5):**
  - T-B1 kills the chunk bound's two mutants 2/2: one batch for all, and one batch per waiter.
  - The refused-spawn arm stays reached through the single-waiter callers. The draft does not list `EnginePresence.swift:141-143` as unreached.
  - T-B2, optional, checks liveness under withdrawal and shutdown.
- **Risks.**
  - One slow store read delays the rest of its batch. That is unlikely, because the read has no I/O.
  - A test that asserts one task per waiter, or that counts tasks, would need its count changed. That counts as an order or timing assertion under S3-R16 item 4 (UNCONFIRMED: none found by name).

**B2 (for the unmeasured ensure shape, §2.5): owed ensure resumes.** When the rows number more than `answersPerTurn`, as the trigger `job.interests.count > answersPerTurn` works in `resolveAll` (`EngineJobs.swift:703`), the ensure continuation goes into `owedAnswers` as `.ensure(token, continuation)` instead of being resumed (`dropGroupMember`'s resume, `EngineJobs.swift:667`, or A3's caller). After the rows, the answer site calls `scheduleAnswerFollowUp()`. That function is `private` at `EngineJobs.swift:736`, so it must become internal or gain a wrapper.

- **Correctness:** the same value (`true`), resumed once by a follow-up or by the shutdown drain. This is C12's argument (`docs/adr-drafts/s3f.md:6528-6535`; S3-R26 item 4). `answerViolations` holds (`EngineCommands.swift:1976-1993`).
- **New branches:** the owing decision and the schedule condition.
- **Tests:** T-B3 (§5), on the pattern of T-A1 to T-A5 in `EngineOwedAnswersTests.swift`.
- **Saving:** about 0.34 µs per settled group, which is C12's measured resume, (11.27 − 7.89) / 10,000. That makes −3.4 ms on the ensure shape.

**What (a) and B1 give together:**

| Shape | Savings | Probe-equivalent | Production (+0.6 to 0.85) |
|---|---|---|---|
| group | 5.05-6.25 ms | 4.54-5.74 (rerun 4.26-5.46) | **5.1-6.6** (rerun 4.9-6.3) |
| groups | 4.67-6.07 ms | 6.69-8.09 (rerun 6.19-7.59) | **7.3-8.9** (rerun 6.8-8.4) |
| users | 3.47-4.17 + B1 3.0-5.0 = 6.47-9.17 ms | 5.00-7.70 (rerun 4.10-6.80) | **5.6-8.6** (rerun 4.7-7.7) |

The central estimates, at midpoint savings, are:

- from the best base: group 5.9 ms, groups 8.1, users 7.1;
- from the rerun base: 5.6, 7.6 and 6.2.

### 2.3 A7, the fallback: drop the rows' token sort

The change removes the sort `.sorted { $0.token < $1.token }` (`EnginePresence.swift:353`), or the in-place sort in A2's method. The rows then follow the job's table order.

- **Saving:** 0.4 to 0.7 ms for groups and users: the sort itself, plus the copy A2 has not already removed.
- **What changes:** three things, and nothing else:
  - the order of the ensure resumes at the answer site;
  - the order in which the read batches are spawned;
  - which waiters share a batch.

  No answer changes. It is the same class as "the table's order of resumes in `resolveAll`", which S3-R26 item 10 accepted (`s3-rulings-s3f.md:608-610`). So it needs the same ruling: an accepted order.
- **Risks:** the table's order is seeded per process, so it is not deterministic from run to run. A test that asserts the order of answers at this site would become flaky, which S3-R16 1(d) calls blocking. The tests need an audit first (UNCONFIRMED: none found).
- **Branches:** none.
- **With A7:** groups becomes 6.6 to 8.5 ms (rerun 6.1 to 8.0), and users 4.9 to 8.2 (rerun 4.0 to 7.3).

### 2.4 Route (c), the contingency: a bounded answer over turns

Route (c) applies only if the binding, or the binding and the removals, cannot fit the turn. Here the binding is about 0.4 ms at 10,000 ids, so (c) is not triggered.

**The state needed between turns.** On `Job`, a `presentAnswer: PresentAnswer?` holding:

- the epoch;
- the attempt;
- the present ids not yet taken off;
- the ledger serial of the reads.

The attempt's driver (`answeredFromStore`) works through it in steps:

1. **First turn.** It binds every present id; at about 40 ns an id, the binding fits.
2. **Each turn.** It takes off and answers at most `answersPerTurn` holders. It reads them from the index, as `moveItems(of:)` does (`EngineState.swift:1011-1023`).
3. **Between turns.** It awaits an explicit hop. The REENTRANCY comment re-validates the lifecycle, the epoch, the attempt and `handle == nil`. After the hop the driver re-reads the remaining holders from the index, because joins and moves may have changed them.
4. **While `presentAnswer` is set.** The driver does not request bytes.

**The R-NET-6 and L4-R5 argument.** No transfer is started while ids are left, so no transfer outcome (a 404, an integrity failure, ENOSPC) can reach a present id. Every other path that ends a job's interests without a transfer must do one of two things: be impossible for a job with `presentAnswer`, or first answer the remaining present ids from the store. Those paths are a supersede, a removal, a purge, a cancel or pause, and the drain. This needs an audit of every caller of `resolveAll` and `removeJob`, which was not done here (UNCONFIRMED). An id that a follow moves meanwhile is re-routed. It is answered from the store if its new content is bound (`EngineDispatch.swift:1220-1222`); otherwise it joins its new job.

**The invariant clauses (new):**

- **(c1)** A job with `presentAnswer` has an active attempt with that epoch and attempt and no handle, and while running, its driver task is alive (`tasks[driver] != nil`).
- **(c2)** `presentAnswer.ids ⊆ job.assets`.
- **(c3)** Every one of those ids is bound to the job's content in the ledger, unless `ledgerForgets` has passed the serial. In that case the driver re-reads before it answers.
- **(c4)** No publication or commit runs for such a job.

Each clause needs a test that breaks it, as `forgetIndexForTests` does for I1.

**The visit-first comparison, in both orders.**

- **The single-turn reference.** Every present interest is answered before any later apply can act, so the waiter gets the old content's location.
- **`followVisitedFirst`.** A visit between two turns moves an id whose entry an apply changed. The interest is re-routed to the new content, and the caller gets the new content's location or a download.
- **`sweepFollowsFirst`.** The same apply's follow may run after the last turn. Then the caller gets the old location.

So the two orders can give different content for the same caller, which is S3-R16 1(a), blocking. There are two ways to avoid it:

- answer the moved ids' remaining present holders from the store before the visit's re-routes;
- hold the visits of a job that has `presentAnswer` until it ends.

Each adds branches. The probes needed, in both orders, are:

- an apply between two turns;
- a withdrawal between two turns;
- a shutdown between two turns;
- an id joining between two turns (UNCONFIRMED: not designed in detail).

**The cost.** New state, at least four clauses, and at least six new branches, each needing a deterministic test that kills its drop-mutant 2/2. This is the largest route by far.

### 2.5 Shapes in the reference set that the probe did not measure

C2's reference set is 10,000 ids however they are grouped (`s3-rulings-s3f.md:342`). Two groupings reach this site and have no figure.

- **10,000 one-member ensure groups.** These are rows like the groups shape. Each settled group is also resumed in the turn (`EngineJobs.swift:663-667`), at about 0.34 µs each.
  - **Today:** est. 16 to 17 ms in production.
  - **After (a) and B1:** 7.3 to 8.9 + 3.4 to 3.9, so 10.7 to 12.8 ms: a miss.
  - **With B2:** about +0.2 to 0.3 ms over groups, so 7.5 to 9.2 ms: at the edge, like groups.

  The lane is user-initiated, so the last turn is the turn after `adoptLegacyNow` (`EnginePresence.swift:263`), with the same E. UNCONFIRMED: unmeasured.
- **A run row of 10,000 ids** (for example, ids that the adoption at the pre-transfer read makes present while migration is pending, L5K-R1; UNCONFIRMED as a practical shape). Each id runs two functions today:
  - `releaseRunClaim` (`EngineRuns.swift:505-514`), with three or four TransferID-hashed `outstanding` accesses;
  - `countRunFetched` (`EnginePresence.swift:120-127`), which copies the `Run` and calls `offerRunProgress` (`EngineEvents.swift:90-110`). That function copies the `Run` again, looks up the job and copies it for each outstanding transfer, reads the clock and runs the rate limiter.

  That is est. 0.7 to 0.9 µs per id, or 13 to 15 ms probe-equivalent today; (a) brings it to about 10 to 11 ms, still a miss.

  **R1.** Answer a run row once: one `outstanding[transfer]?.subtract(held)` and one count of `held.count`, with a single `offerRunProgress`. That gives est. 4 to 5 ms. The run's final state is the same. Its progress events differ: one offer with the final count, instead of a first emission of +1 and a trailing one carrying the final count. That is a difference in progress events, which S3-R16 item 2 does not list, so it needs a ruling on its class (UNCONFIRMED).

## 3. Recommendation

**The smallest route that lands all three measured shapes at or below 8.5 ms in the central estimate is route (a) together with B1.**

1. **Route (a).** A1, A2, A3 with A3′, A4, A5, A6a, A6b and A8, as §2.1 describes them.
2. **B1.** Batched store reads, `answersPerTurn` reads per owned task (§2.2).
3. **The pin.** Commit a BenchSync case for the whole post-await tail (§5, PIN-APM): group, groups and users, best of 3, checked against `c2Budget`, with 8.5 ms recorded as the edge (S3-R26 item 9, `s3-rulings-s3f.md:603`).

Expected production figures (§2.2):

- group 5.9 ms (5.1 to 6.6);
- groups 8.1 (7.3 to 8.9);
- users 7.1 (5.6 to 8.6).

From the rerun base they are 5.6, 7.6 and 6.2.

**The decision rule, on PIN-APM's committed figures:**

- **If groups or users is above 8.5 ms:** take A7 under an order ruling, after the tests are audited for order assertions. A7 lowers the conservative ends to groups 8.5 and users 8.2.
- **If either is still above 8.5:** take the variant of A6b that saves two lookups (−0.15 to −0.2 ms more). Re-measure E on the real path (§5, PIN-APM-REAL).
- **Route (c) only if a shape stays above 10 ms.**

**In the same change, for the reference set's other shapes:**

- **B2** (owed ensure resumes): without it, 10,000 one-member ensure groups are est. 10.7 to 12.8 ms after (a) and B1.
- **R1** (a run row answered once), after a ruling on the class of its progress-event difference.

Neither has a figure. Both should get PIN-APM shapes (`ensureGroups`, `run`).

**What the route keeps:**

- S3-R6: every change is internal (`Job`, `Group`, `Waiter` and the engine's extension methods have no `package` or `public` modifier).
- C1: no unsafe escape.
- C2's own rule: no I/O on the actor.
- C3: every new await gets a REENTRANCY comment (B1's loop: RE-S36; the spawn: RE-S21).
- C4: no time or randomness.
- S3-R26 answer 2: the site publishes no terminal events, and `publishTerminal` is untouched.
- S3-R26 answer 4: one subscriber matters only to R1's progress events.

**The order of work:**

1. Make the probe a committed case: PIN-APM's red figures on today's code.
2. A8, A1 and A5: no behaviour change.
3. A2.
4. A3 and A3′.
5. A6.
6. A4 and B1.
7. Re-measure.
8. B2.
9. A7 or R1, if they are ruled.

## 4. Figures per shape

All figures are in ms.

- **Base:** best of 3 (rerun), measured at a 1-minute load of about 7.
- **Production today:** the base plus E without A8 (0.9 to 1.65).
- **After (a)+B1:** the base minus the savings, plus E with A8 (0.6 to 0.85).

| Shape | Base | Production today (est.) | (a)+B1 savings | (a)+B1 production: central (range) | With A7 |
|---|---|---|---|---|---|
| group: 1 row × 10,000 ids | 10.79 (10.51) | 11.7-12.4 | 5.05-6.25 | **5.9** (5.1-6.6); rerun 5.6 (4.9-6.3) | unchanged |
| groups: 10,000 one-member prefetch groups | 12.76 (12.26) | 13.7-14.4 | 4.67-6.07 | **8.1** (7.3-8.9); rerun 7.6 (6.8-8.4) | 7.6 (6.6-8.5) |
| users: 10,000 user waiters | 14.17 (13.27) | 15.1-15.8 | 6.47-9.17 | **7.1** (5.6-8.6); rerun 6.2 (4.7-7.7) | 6.5 (4.9-8.2) |
| ensure groups ×10,000 (unmeasured) | — | est. 16-17 | as groups + B2 3.4 | est. 8.3 (7.5-9.2) | est. 7.8 |
| run row of 10,000 (unmeasured) | — | est. 13-15 | (a) + R1 | est. 4-5 | — |

**The arithmetic, for one example:** groups at the central estimate is 12.76 − (4.67 + 6.07) / 2 + (0.6 + 0.85) / 2 = 12.76 − 5.37 + 0.725 = 8.1 ms.

**The savings, part by part.** Every figure is for 10,000 ids or rows:

- **A1:** the profile's 3.01 ms sort; for one-id rows, 50 to 55 ns a row.
- **A2:** 187 ns a row.
- **A3:** 140 to 210 ns a drop; **A3′:** 20 to 40 ns.
- **A4:** 40 to 60 ns.
- **A5:** 10 to 15 ns.
- **A6a:** 35 to 60 ns; **A6b:** 25 to 40 ns.
- **B1:** a spawn, 300 to 500 ns.
- **A7:** 0.4 to 0.7 ms.
- **B2:** C12's resume, 0.34 µs.

## 5. Tests and pins

- **PIN-APM (new, committed; it replaces the scratch probe).**
  - **The seam.** Factor everything `answeredFromStore` does after its last await into one internal `answerSite(...)`: the final guard (`EnginePresence.swift:277-292`), preceded by the last `unaskedIDs` (made internal). The production code calls it, and the bench calls it inside the actor, as `indexOwnCosts` times the index. The bench therefore times the production code of the last turn, and no work is hidden.
  - **The shapes:** group, groups and users; with B2 and R1, also `ensureGroups` and `run`.
  - **The setup:** 10,000 ids, one shared content, the download held, as in `ProbeC21APM.swift:60-109`.
  - **The check:** best of 3, `c2Budget`, with 8.5 ms recorded as the edge.
  - **What it does not see:** with A8, no `Job` copy is alive on the real path either, so the case is representative. Without A8 it cannot see the copy-on-write cost.
- **PIN-APM-REAL (optional).** It reaches the real site with present ids. One way: prior-art files with migration pending, so that the pre-transfer reads adopt them (L5K-R1). Another: content made present after the interests registered and before dispatch. The heartbeat times the longest turn. UNCONFIRMED: whether the test support can set this up; the scratch probe's note says no BenchSync case reaches the site today (`docs/adr-drafts/s3f.md:6693-6695`).
- **The existing tests pin (a)'s answers, unchanged:**
  - the answer-site suites, which cover L4-R5 and R-NET-6 at the pre-transfer read, `sparePresent`, and L5K-R21 and L5K-R23. They are in `EngineLegacyMigrationTransferTests.swift`, `EngineRegressionCycle3Tests.swift`, `EngineFollowBarrierReroutePresentTests.swift` and `EngineRegressionCloseOutTests.swift`, among others;
  - the T21 drops and the ensure-completion tests;
  - every invariant check: I1 to I3, the group pending clause and `answerViolations`.

  Re-run the mutants of the relocated conditions at their new lines and kill them 2/2:
  - the empty-`held` filter and `whole`;
  - the pending and settled checks;
  - the last-holder removal;
  - `setInterest`'s cases.
- **A partial row (needed if it is missing):** an interest that holds one present id and one absent id. It keeps the absent id, and I1 to I3 recount cleanly. This kills `whole`'s mutant in A2's method. UNCONFIRMED: whether B11 added such a test.
- **T-B1 (new).**
  - **The setup:** `answersPerTurn = 2`, through the seam, as `EngineOwedAnswersTests.swift:39` sets it to 4. Five user waiters of one content, all present at the pre-transfer read.
  - **The record:** a test seam `presentReadBatchesForTests: [Int]?`, like `admissionsForTests` (`EngineState.swift:82`), records the batch sizes.
  - **The expectations:** `[2, 2, 1]`; every waiter answered `.success` with the store's location; `invariantViolations()` empty.
  - **What it kills, 2/2:** "one batch" (`[5]`) and "one per waiter" (`[1, 1, 1, 1, 1]`). It runs in both orders wherever the answer suites already do.
- **T-B2 (optional; liveness).** A hold seam on the batch tasks, on the pattern of `holdAnswerFollowUps` (`EngineJobs.swift:776-788`), released by `drainEverything` as the other holds are. It covers two cases:
  - a caller withdrawn inside a held batch gets `.cancelled` once, and the rest get `.success`;
  - a shutdown with batches held answers every caller `.shutDown` once, and the joins end.

  No test sleeps. The checks use `waitUntil` and the `.timeLimit` guard.
- **T-B3 (with B2).**
  - **The setup:** `answersPerTurn = 2`, three one-member ensure groups present at the site, `holdAnswerFollowUps()`.
  - **While held:** no ensure caller has returned; `owedAnswers` holds three `.ensure` entries; the invariants are clean.
  - **On release:** every caller returns `true`.
  - **With a shutdown instead:** each caller is resumed once, by the drain.
  - **What it kills, 2/2 in both orders:** "never owe", "always owe" and "never schedule".

## 6. UNCONFIRMED

1. **The split of the unexplained 0.12 to 0.2 µs per id.** It may sit in the group drop, in the common part, or in memory traffic. The savings estimates assume it stays after the cuts.
2. **A3's saving.** It depends on whether the first `groups[token]?.pending[asset]` read (`EngineJobs.swift:659`) copies the whole `Group` today: 140 ns if not, 210 ns if so.
3. **The spawn's cost per waiter** (300 to 500 ns), and so B1's −3.0 to −5.0 ms. The contention of 10,000 hops onto the busy actor is not counted.
4. **Whether `job` (`EnginePresence.swift:202`), `current` and `active` (`:277-278`) and `sparePresent`'s `current` (`EngineFailures.swift:546`) are alive across the removals.** If they are, the job's tables are copied on write and A8 saves 0.3 to 0.8 ms. The probe cannot show it.
5. **E's components:** `unaskedIDs` 0.45 to 0.65 ms; the prune about 0.1, or about 0.6 on the filter path; `retire` and `pump` about 0.05. Nothing has measured them.
6. **That no `waitUntil` predicate or condition seam depends on the mid-turn states that A2 and A5 remove.**
7. **That no test asserts the token order of answers at this site,** which matters for A7. Also, which existing tests exercise a partial row and a multi-member ensure row at the answer site.
8. **That reads in batches leave each waiter's answer the same** when an apply re-binds an id between two reads of one batch, in both `LaneDropVisit` orders (§2.2 probe). Also, that the store's serialization makes the batches' total read time about equal to today's.
9. **That no existing test counts owned tasks per waiter** at this site.
10. **The two unmeasured shapes:** the ensure shape (est. 16 to 17 ms today; 7.5 to 9.2 ms with (a), B1 and B2), and the run shape (est. 13 to 15 ms today; 4 to 5 with R1). Whether a run row of 10,000 present ids is a practical shape. And the class of R1's progress-event difference.
11. **Route (c)'s audit and design:** the audit of every caller of `resolveAll` and `removeJob` for a job with `presentAnswer`, and its visit-first fix.
12. **PIN-APM-REAL's setup:** whether the test support can make content present after interests register and before dispatch, or set up 10,000 prior-art files.
13. **The C7 checks.** The `Dictionary` APIs and copy semantics used by A3′ and A6a were checked only in the installed macOS SDK's `Swift.swiftinterface` (MacOSX27.0.sdk). The iOS SDK's interface was not opened. The APIs carry no availability annotation, so iOS 15 should be unaffected.
