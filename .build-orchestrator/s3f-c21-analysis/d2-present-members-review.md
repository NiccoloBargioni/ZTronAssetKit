# Review of D2 (`d2-present-members.md`): `answerPresentMembers`' answer turn at 10,000 present ids

Adversarial review for ruling S3-R27. Code base: worktree `.worktrees/s3f`, branch `wp/s3f`, HEAD `d5b2ab9` (last code
commit `e599ae1`). Paths are relative to the worktree unless they start with `.build-orchestrator/`.

- **What was run.** Nothing was built, run or timed. Read-only: `sed`, `grep`, `git show`/`blame`, and one
  `xcrun llvm-cov show` of the fixer's existing second-gate-run coverage profile
  (`.build-s3f/c21/cov-gate/default.profdata` with its copied `ZTronAssetSyncTests` bundle; the counts below are from
  it, on `e599ae1`, which `d5b2ab9` does not change in `Sources`).
- **UNCONFIRMED** marks what the code alone cannot settle.

## Verdict: CORRECTED

The diagnosis is right, and so is the direction of the routes:
- the turn's cost is per-row table traffic and per-waiter task creation, not formatting;
- the binding fits in the turn, so route (c) is not needed;
- the waiters' store reads are the only part that may leave the turn.

The correctness arguments for A1, A2, A3, A6 and the "reads leave the turn" idea hold against the code. Four things in
the report are wrong or missing, and the ruling must fix them:
1. **It adds unreached changed lines while calling them "relocated, no new branch".** Three of the guards it relocates
   are at **zero count** today. B1's design makes the refused-spawn arm a changed line, and that arm is unreachable at the
   new site.
2. **Its pin, as specified, times nothing.** On the probe's setup, the final guard of `answeredFromStore` returns
   `false`, because the attempt holds its handle.
3. **It leaves the second caller, `sparePresent` (the 404 and integrity paths), unpinned.** That path has a Job copy that
   is certainly alive across the answer, and A8 does not remove it.
4. **It under-counts the production extras of the 10,000-groups shapes.** Two walks over every group run in the same
   turn. The groups shape is therefore not shown to land at or below 8.5 ms. A7 has to be ruled now, not after a second
   measurement, or the fixer cannot finish in one cycle.

## 1. What was checked and holds

- **The cost decomposition.** It agrees with the code and with `profile-40ms.md` §4:
  - in-place `jobs[key]?.field` access: 187 ns;
  - `TransferID.hashValue`: 48 ns;
  - `Set<AssetID>(10,000).sorted()`: 3.01 ms;
  - the profile's "pending write" at 2.5 to 2.8 ms per 10,000, which supports the anchored D of 0.47 to 0.49 µs.

  There is no formatting on the path (`EnginePresence.swift:100-144`, `:345-369`; `EngineJobs.swift:658-668`;
  `EngineState.swift:903-924`, `:1085-1095`).
- **A1.** The sort predates B11 (`git show bbf5eaa`). Inside a row, the order of the per-id answers is not observable:
  - a waiter row holds one id;
  - a prefetch drop touches only `pending`;
  - an ensure settles at the row's last pending member in any order (`Group.isSettled`, `EngineState.swift:1267-1269`);
  - a run's `fetched` and its claim-set emptying are order-free (`EnginePresence.swift:120-127`;
    `EngineRuns.swift:505-514`);
  - `offerRunProgress` reads only `run` and `jobs[t]?.active?.bytesReceived` (`EngineEvents.swift:90-110`);
  - a heal is `heals[asset] = nil`.
- **A2.** No answer reads the job's `interests`, `tokensByID` or `assets`:
  - `answerWaiterFromStore` writes `waiters` and `tasks`;
  - `dropGroupMember` writes `groups`;
  - `releaseRunClaim` and `countRunFetched` read and write `run`;
  - a resumed continuation runs after the turn.

  Moving every removal, and `assets.subtract`, before every answer changes no answer and no caller-visible order.
  `takeOff` (`EngineState.swift:1034-1076`) is the precedent.
- **A3, A3′ and A6a.** Index validity across a copy-on-write copy holds. `_NativeDictionary.copy()` keeps the scale, the
  age and the buckets, and `validatedBucket` checks exactly those (the installed `Swift.swiftmodule` interface, lines
  15801-15839, as cited). The ruling should still ask for the iOS SDK's interface to be cited too (C7). It is installed:
  `iPhoneOS27.0.sdk`.
- **Route (b)'s premise.** Group drops and run claims cannot be owed:
  - a pending member with no interest breaks `EngineCommands.swift:1856-1862`;
  - an orphaned run claim breaks the run-claim clause near `:1893-1897`.

  A waiter already leaves its interest in the turn and is skipped by `EngineCommands.swift:1763` (`!waiter.fromStore`).
  Withdrawal answers a `fromStore` waiter at once (`EngineCommands.swift:179`). Shutdown takes every waiter in the turn
  that sets `.shuttingDown`: `EngineLifecycle.swift:490-498`, then `drainEverything` is evaluated before the `settle`
  await, and `EngineShutdown.swift:53-66` takes `waiters` out. So no new state and no new invariant clause is needed.
- **S3-R6.** Every proposed change is internal. `scheduleAnswerFollowUp` (private, `EngineJobs.swift:736`) and
  `unaskedIDs` (private, `EnginePresence.swift:298`) may become internal without any package or public signature change.
- **Route (c) is not triggered.** The binding is one reserved insert per id (`EnginePresence.swift:61-70`).

## 2. Must-fix items

### M1. Three "relocated" guards are at zero count today, and B1's refused-spawn arm is unreachable where it is moved

The report says A3, A4 and B1 add "no new branch": the guards are relocated and their mutants re-run. It also says the
refused-spawn arm "stays reached through the single-waiter callers. The draft does not list
`EnginePresence.swift:141-143` as unreached" (§2.2).

That evidence is invalid. The draft's list (`docs/adr-drafts/s3f.md:6730-6760`) covers only lines changed in cycle 21.
Lines 141-143 last changed in `6cc4d925` (30 Oct) and `bf46fad2`. The coverage of the second gate run gives:

| Line | What | Count |
|---|---|---|
| `EnginePresence.swift:131-132` | `answerWaiterFromStore`'s missing-waiter `return` (A4 relocates it) | **0** |
| `EnginePresence.swift:141-143` | the refused-spawn arm: `removeValue(...)?.continuation?.resume(.shutDown / .cancelled)` (B1 relocates it into a loop over the batch) | **0** |
| `EngineJobs.swift:659-660` | `dropGroupMember`'s pending-mismatch `return` (A3 relocates it into `Group.dropMember`) | **0** |
| `EnginePresence.swift:151-152`, `:162-164` | `readPresentLocation`'s lifecycle and withdrawn guard, and the `.notFound` arm | 0 (B1 leaves them unchanged, so no new obligation) |
| `EnginePresence.swift:362` | the partial-row `subtractAssets` | 1 (a partial row is reached) |
| `EnginePresence.swift:356` | `guard let rows else { return }` | 0 (already listed as structural) |

A moved line is a changed line. S3-R25 item 10 and S3-R16 1(e) apply to each of them on the final HEAD.

**The refused-spawn arm is not structural:** it has statements whose drop leaves a caller unanswered. At the new site it
is unreachable:
- `spawn` refuses only in `.shuttingDown`, `.shutDown` and `.degraded` (`EngineLifecycle.swift:52-56`);
- both callers of `answerPresentMembers` checked `isRunning` (`lifecycle == .running`, `EngineLifecycle.swift:99-101`)
  earlier in the same turn: `EnginePresence.swift:277` and `EngineFailures.swift:543`;
- nothing between those checks and the spawn changes the lifecycle.

So no deterministic test can reach it, and the report's T-B1 does not.

**Replacement text for the ruling:**
> - `answerWaiterFromStore` (`EnginePresence.swift:130-144`) stays byte-identical. Its single-waiter callers keep it:
>   `EngineCommands.swift:105`, `EngineManifest.swift:426`, and `reroute` through `answerPresent`
>   (`EngineDispatch.swift:1221`).
> - The batched read exists only at `answerPresentMembers`.
> - Its `spawn` result is discarded. A doc comment states the argument: both callers checked `isRunning` in this turn,
>   and `spawn` refuses only outside `.running`, so it cannot refuse here. Were it ever to refuse, shutdown would already
>   have taken every waiter in the turn it began (`EngineShutdown.swift:53-66`). No refused arm is written at the batch
>   site (S3-R16 item 3: removal, recorded in the draft with this argument).
> - A4's mark is written without a guard, as `self.state.waiters[row.token]?.markFromStore(at: transfer)`, and the read
>   is collected unconditionally. A missing waiter makes its read return at `readPresentLocation`'s existing guard
>   (`EnginePresence.swift:151`, an unchanged line), so A4 adds no conditional.
> - A3's `Group.dropMember` keeps the pending check. Its `nil` return on a mismatch is a changed line. The fixer either
>   reaches it with a deterministic test (a member whose `pending` names another transfer, answered at the old job)
>   that kills the "drop the check" mutant 2/2, or records it as structural with the argument and a citation that no
>   caller reaches it, as the draft did for `EnginePresence.swift:356`. A bare relocation is not enough.
> - The covdiff check on the final HEAD lists every relocated line with its count.

### M2. B1's code shape must be fixed so that no `answerPresent` arm is duplicated or orphaned

The report does not say how the answer site collects reads while `answerPresent`'s waiter arm spawns. It also turns
`answerWaiterFromStore` into "mark, then spawn a batch of one", which rewrites the zero-count lines of M1.

**Replacement text:**
> `answerPresentMembers` answers the rows that `Job.takeOffPresent` returns:
> - **A waiter row** (`row.kind == .waiter`): mark it, then append `PresentRead(token, asset, lane)`. This is a new
>   branch. Every answer-site waiter test reaches it, and its drop-mutant leaves a caller unanswered, which the existing
>   L4-R5 answer-site suites kill. Show that kill 2/2.
> - **Any other row:** call `answerPresent` per id, unchanged.
>
> After the rows, at most one call starts the reads, then one `notifyObservers()` follows (A5, below).
> `answerPresent`'s `.waiter` arm keeps its current text, for `reroute`.

### M3. PIN-APM as specified passes vacuously: the final guard rejects the probe's setup

The report's pin factors `EnginePresence.swift:277-292` into `answerSite(...)` and calls it "on the setup of
`ProbeC21APM.swift:60-109`", with the download held. On that setup the attempt has its handle:
- the fake's `.hold` is a stream step that runs after `remote.transfer` returned (`RecordingFakes.swift:629-637`);
- the driver then sets `active.handle` (`EngineDispatch.swift:817-820`).

`answerSite`'s guard `active.handle == nil` (`EnginePresence.swift:278`) therefore returns `false`. The bench would time
a guard, and work would be hidden from the measurement. The probe avoided this only by calling `answerPresentMembers`
directly.

**Replacement text:**
> PIN-APM calls `unaskedIDs` (made internal) and then `answerSite(transfer, epoch:, attempt:, present:, serial:)` (the
> factored `EnginePresence.swift:277-292`) inside the actor, timed together. Before timing, the bench reads the job's
> `epoch` and `active.attempt` and sets `active.handle = nil`. It records this setup as a state seam. After timing, it
> asserts that the answer happened:
> - `answerSite` returned `true`;
> - the job is gone;
> - 10,000 interests were removed;
> - for users, 10,000 waiters are `fromStore`; for groups, every `pending` is empty.
>
> A run in which the guard fails is a failed case, not a fast one.
>
> The shapes are group, groups and users, plus ensureGroups (with B2) and run (with R1). Each is best of 3 against
> `c2Budget`, with 8.5 ms recorded as the edge.

### M4. The 404 and integrity caller (`sparePresent`) is not pinned, and A8 misses the Job copy that is certainly alive there

`failed` binds `job` at `EngineFailures.swift:73`. It uses that copy after `sparePresent` returns:
- `job.identity` at `:153`;
- `job.assets.sorted()` and `job.identity` at `:193`.

So the copy is alive across `sparePresent`'s answer turn. That is certain, not an optimizer question. If no join
changed the interests during the reads, the first removal copies the job's `interests`, `tokensByID` and `assets` on
write (est. 0.3-0.8 ms), and they are freed in the same turn when every id was present: `ids` is empty, so the guard at `:165`
runs `pump` and `reconcileIdle` (`EngineFailures.swift:165-176`) and returns. In addition, `sparePresent`'s `assets` parameter is `job.assets` itself,
alive for the whole call, so `assets.subtract` copies that set on write anyway (est. 0.1-0.2 ms).

The turn also runs three more things:
- `assets.subtracting(present).sorted()` (`:542`; est. 0.3-0.45 ms at 10,000);
- `removeJob`;
- the caller's `pump` and `reconcileIdle`.

Against the answer-site tail with A8, that is est. +0.15 to +0.6 ms. The report's only measure here is A8 on
`sparePresent`'s `current` (`:546`).

**Replacement text:**
> - **A8 extends to `failed`:** read `job.identity` and the assets argument into locals before the reads, so that no
>   `Job` copy is bound across `sparePresent` (`EngineFailures.swift:73`, `:145`, `:153`, `:193`).
> - **PIN-APM-SPARE:** the same three shapes, timing `sparePresent`'s post-read tail. Factor `EngineFailures.swift:541-552`
>   into an internal function the bench can call. Include the caller's `pump` and `reconcileIdle`, and assert that the
>   job was removed.
> - **The two ends:** the 404 path passes the job's own `assets` set, and the integrity path a fresh `Set(ids)`. The
>   pin measures the 404 end, the worse of the two.

### M5. E is under-counted for the groups shapes; groups is not shown to land at or below 8.5 ms

The report puts `retire`, `pump` and the prune at about 0.15 ms (§1.3). With 10,000 groups registered, the same turn
runs two walks over every group:
- `pump` → `materializeEnsures`: `self.state.groups.compactMap { … }` (`EngineDispatch.swift:229-231`);
- `reconcileIdle` → `pruneBoundContent`: `!self.state.groups.values.contains(where: …)` (`EnginePresence.swift:82`).
  The ledger is non-empty after `bind` and no prefetch group has fetches left, so the walk runs to the end.

Each walk copies every `Group` it visits: about six refcounted fields, with a cache miss per object header. The
draft's commit figures put the class in range: `manyGroups` 9.34 ms against `.waiters` 7.27 on `2c351e8`
(`docs/adr-drafts/s3f.md:6545-6548`). The difference includes the walks. Estimate: +0.4 to +1.0 ms for groups and for
ensureGroups, and nothing for group and users. UNCONFIRMED: not measured alone.

Corrected production estimate for groups after (a) and B1:
- range: 7.3-8.9 plus 0.4-1.0, so **7.7 to 9.9 ms**;
- central: **about 8.8 ms**.

That is above the edge. With A7 (−0.4 to −0.7) it becomes **7.3 to 9.5**, central **about 8.3**: borderline. The
report's "the smallest route that lands all three shapes at or below 8.5 ms is (a) + B1" does not hold for groups.

**Replacement text:**
> PIN-APM's tail includes `pump` and `reconcileIdle`, and its groups and ensureGroups shapes keep their 10,000 groups
> registered. If either shape is above 8.5 ms after (a), B1 and A7, cut the two walks without a branch, in this order:
> 1. Visit the groups without copying each `Group`, by reading only the fields the predicates need through
>    `self.state.groups.values[index]`, or by an equivalent borrow. Measure the saving.
> 2. Only if that is not enough, an index of the ensure groups with fetches left. That is new state, so it needs an
>    `invariantViolations()` clause that recounts it, and a drop-mutant killed 2/2 for each update.
>
> A miss that stays is blocking and reported with figures (S3-R16 1(f)).

### M6. Rule A7's and R1's classes now, or the fixer cannot finish in one cycle

The report's decision rule takes A7 "under an order ruling" after PIN-APM's figures, and R1 "after a ruling on its
progress-event class". Both are a second trip to the orchestrator inside the cycle. M5 makes A7 likely to be needed.

**Replacement text:**
> **A7 is ruled now.** At the present-answer site, the rows (and so the ensure resumes, owed or immediate, and the order
> of the waiters' store reads) follow the job table's order. This is an accepted order (S3-R16 item 2), the class of
> S3-R26 item 10's order of resumes in `resolveAll`. The fixer applies A7 if PIN-APM's groups, ensureGroups or users
> shape is above 8.5 ms after (a), B1 and B2. Before that, it audits the answer-site tests for order assertions; a test
> that depends on the order keeps the sorted order and is reported (G3).
>
> **R1's class is ruled now.** A run row answered once offers one progress value with the final count, where the
> per-id answers offer an immediate value followed by a trailing value of the same final count. Every caller's
> answer is unchanged, the terminal events are unchanged, and R-SYN-12 (newest-wins, rate-limited progress) holds. The
> difference is non-blocking and recorded as a residual risk. R1's new row-kind branch must be reached by a run-row
> answer-site test that kills its drop-mutant 2/2.

## 3. Should-fix items

1. **B1's saving is gross, not net.** It saves the spawn (300 to 500 ns), but it adds:
   - the collection of a `PresentRead` per waiter, about 20 to 40 ns;
   - with batches, the slice copies into each task's closure.

   Net 2.6 to 4.7 ms, not 3.0 to 5.0. Users after (a) and B1 is **5.9 to 8.95 ms**, central **about 7.4**, not 7.1
   (5.6 to 8.6). It lands at the central figure, with its upper end above the edge.
2. **The chunk bound buys nothing measurable, and it costs a branch plus a production test seam**
   (`presentReadBatchesForTests`). Each read is its own turn segment, so C2 holds with one owned task that reads every
   waiter in sequence. The store reads are serialized on the store actor and the engine actor anyway, so 20 tasks do
   not shorten the last waiter's wait. Under S3-R16 item 3, prefer **one owned task per answer site**, with no bound and
   no seam:
   - `// REENTRANCY: RE-S36` on the loop's await;
   - `RE-S21` on the spawn closure.

   T-B1 then becomes: five waiters at the site, every one answered `.success`, invariants clean, and the drop-mutant of
   the read loop's call killed. If the orchestrator keeps the bound, the report's T-B1 stands.
3. **A5 without a new branch.** Move `notifyObservers()` (`EnginePresence.swift:116`) out of `answerPresent` to its
   callers: one line after `EngineDispatch.swift:1221`, and one at the end of `answerPresentMembers`. Do not add a
   "quiet" flag.

   Before landing A2 and A5, audit the `waitUntil` and `awaitCondition` predicates of the answer-site suites for a
   state that exists only mid-turn: a partial removal, or some waiters marked but not all. Such a predicate would no
   longer be satisfied and would hang to `.timeLimit` (S3-R16 1(c) and 1(d)). The report lists this as UNCONFIRMED
   (§6 item 6) but asks for no audit.
4. **The relocated conditions whose mutants must be re-run** should be listed in full:
   - the final guard's epoch, attempt and `handle == nil` conditions, which A8's projection rewrites
     (`EnginePresence.swift:277-278`);
   - `takeOffPresent`'s empty-`held` filter and `whole` split;
   - `Group.dropMember`'s pending and settled checks;
   - `release`'s last-holder removal (A6a);
   - `setInterest`'s four cases (A6b).

   The partial row is already reached (`:362`, count 1). Check its mutant kill rather than adding a test "if missing".
5. **The `answerSite` seam.** `unaskedIDs` is the loop's condition (`EnginePresence.swift:247`, `:275`) and cannot move
   into `answerSite` without restructuring the loop. Factor `:277-292` only; the bench calls `unaskedIDs` and then
   `answerSite`. State that the turn also includes `drive`'s continuation:
   - on `true`, `taskEnded` and its notify;
   - on `false`, `interests.values.contains(where:)` (`EngineDispatch.swift:812`), O(remaining interests), as far as
     `remote.transfer`.

   Neither is in the pin. Both are small for these shapes.
6. **The anchors.** "R = 0.497 µs" is really R + (D₁₀,₀₀₀ groups − D₁ group): a drop in 10,000 distinct groups is
   colder than in one. The savings are bottom-up, so the expected figures do not change. W and R are not separately
   identified, though, and the "unexplained 12-17 %" may sit partly in the distinct-groups drops.
7. **Shutdown with batched reads.** Shutdown cancels every owned task (`EngineLifecycle.swift:492-494`), but a cancelled
   read task still awaits its remaining store reads, each failing its `isRunning` guard afterwards. With 10,000 pending
   reads, the shutdown join may take tens of milliseconds longer (UNCONFIRMED). That is timing only; record it as a
   residual risk. Do not add a `Task.isCancelled` branch, whose mutant no test can kill.
8. **B2.** `dropGroupMember`'s `owing` parameter must default to `false`, so that the reroute and purge callers
   (`EngineDispatch.swift:1212`; `EngineCommands.swift:1025`, `:1073`, `:1108`) keep their behaviour. The owing
   trigger is the row count, mirroring `EngineJobs.swift:703`. `answerViolations` (`EngineCommands.swift:1976-1993`)
   needs the follow-up scheduled in the same turn. T-B3 as written covers it.

## 4. What the ruling must add

1. **Name both callers in the C2 inventory row:** `answeredFromStore`'s tail and `sparePresent`'s tail (M3, M4), each
   with its own pinned figures.
2. **The integrity-failure path's first turn is a separate inventory row** (not D2's turn; UNCONFIRMED, not measured).
   `failed` runs in one turn, before the first await:
   - two `job.assets.min()` walks (`EngineFailures.swift:77`, `:80`);
   - `job.assets.sorted()` (`:193`);
   - `integrityFailed`'s `Set(ids)` (`:494`);
   - `sparePresent`'s `assets.sorted()` (`:535`).

   That is two 10,000-id sorts plus 10,000 inserts, est. 6.5 to 7.5 ms at 10,000. Ask for a figure. The 404 path has
   one sort (`:535`).
3. **The order of work, with the review's changes:**
   1. PIN-APM and PIN-APM-SPARE, red on today's code with the M3 assertions;
   2. A8 (with M4's extension), A1 and A5 (as should-fix 3 describes it);
   3. A2;
   4. A3 and A3′, with M1's obligation for the pending check;
   5. A6;
   6. B1 in M1 and M2's shape;
   7. re-measure;
   8. B2;
   9. A7, by M6's rule;
   10. the group-walk cut, by M5's rule;
   11. R1.

   Every relocated line goes through the covdiff check on the final HEAD.
4. **An aside, not D2's change** (UNCONFIRMED whether it is reachable). `answerPresentMembers` subtracts the present ids
   from `job.assets` before `removeJob`. `removeJob` retires the progress keys only of the ids still in `job.assets`
   (`EngineJobs.swift:488`). On the 404 and integrity path, a job whose progress key was a present id would leave that
   `lastEmitted` entry behind. Worth one probe; not blocking here.

## 5. Answers to the review questions

- **Cost claims.** They are supported, with three exceptions:
  - E for the groups shapes (M5);
  - B1's gross saving (should-fix 1);
  - the anchor algebra (should-fix 6).
- **Visit-first, the MUSTs and the invariants.** (a) and B1 keep visit-first's answers in both `LaneDropVisit` orders.
  The site does not branch on the order, and the later reads are the existing per-waiter read code. R-NET-6 and L4-R5
  hold, because the binding and every interest's removal stay in the turn. R-SYN-12 is touched only by R1 (M6). The
  group-pending, run-claim, waiter and `answerViolations` clauses hold.
- **Signatures.** No public or package signature changes.
- **Unreachable branches.** Yes, as written: the relocated refused-spawn arm, and two relocated zero-count guards (M1).
  M1 and M2's shape removes or settles them.
- **Landing at or below 8.5 ms in one cycle.**
  - group: yes;
  - users: at the central estimate, yes;
  - groups and ensureGroups: not shown. They need A7 ruled in advance, and possibly the group-walk cut (M5, M6).
  - `sparePresent`'s shapes: unknown until they are pinned (M4).
- **Missed by the report:**
  - the second caller's live Job copy (M4);
  - the two group walks (M5);
  - the vacuous pin setup (M3);
  - the zero-count relocations (M1);
  - shutdown's cancelled-but-reading tasks (should-fix 7);
  - the `waitUntil` audit (should-fix 3).

  No issue was found with cancels and withdrawal (`EngineCommands.swift:179`), purges (a read that finds nothing takes
  the job path, as today) or the follow drain (`fromStore` waiters are skipped at `EngineFailures.swift:860`,
  `EngineFollow.swift:995` and `EngineCommands.swift:2133`, as today).
