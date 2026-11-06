# Independent review of `profile-40ms.md` (profiling of three C2 shapes at 8e1fb24)

Reviewer step of run `wf_6927a3a9-c76`, 4 Nov 13:00–13:15. Read-only on the worktree and the repository; nothing
committed. Inputs: the profiler's report, its exports and pickles under `/Users/admin/Documents/ZTronAssetKit/.build-prof40/out/`,
its rule table `tools/cat.py`, the scratch sources, and the built benchmark binary. Review scripts are in
`/Users/admin/Documents/ZTronAssetKit/.build-prof40/review/` (`check.py`, `adj.py`, `recat.py`, `names.py`, `leaves.py`,
`oth.py`, `est.py`, `estsites.py`). One micro-timing re-run: `out/micro4-review.log`, loads in `out/loads-review.txt`
(1-minute load 4.12 before and after, quiet under S3-R23).

**Verdict: CORRECTED.** The root selection, the category mapping, the shape-1 and shape-2 arithmetic and the four claim
verdicts hold. Three corrections, none of which changes a landing verdict: shape 3's table mixes a trace that lost
events with a clean one and the halves do *not* rank the categories the same; shape 2's landing arithmetic is 0.2 ms
off; and the wording of the `EngineState`-destroy attribution and of C4's verdict needs tightening. The shape-1 landing
margin (1–1.5 ms) is inside the uncertainty of the fix-residual estimate, so it should be read as "lands only if both
fixes land in full".

## 1. Root selection: holds

`check.py` re-selected, from the full sample pickles, every sample whose backtrace holds a root frame, and compared
with the profiler's turn sets.

| Shape | Turn samples | Root entry frame in all of them | Same-thread samples inside the turn windows *without* the root | Root-frame samples outside the windows, and what they are |
|---|---|---|---|---|
| 1 (`s1cpu`) | 3,030 in 15 turns | `publish(_:epoch:file:cancelledAttempt:)` resumption, 3,030/3,030 | 0 | 1,328: other publishes (`publish < finishAttempt < drive`, 842), `bringInbound`/`findInbound` (421), setup `supersede < move` (18) — all other turns |
| 2 (`s2turn`) | 3,466 in 16 turns | `continueFollow()`, 3,466/3,466 | 2 | 975: `continueFollowScans` under `followApplied`/`followFollowUp` outside the windows, `recordDeferredVerdict`, setup moves |
| 3 (`s3b`, clean) | 942 in 6 turns | `publish` → `publicationFailed` → `supersede`, 942/942 | 0 | 1,340: `supersede < move < startMove` — the setup's moves, correctly excluded |

- Adjacency (`adj.py`, ±20 ms on the actor's thread): before shape 1's windows sit 86 `publish` samples (memmove,
  `AssetRecord` copies: the pre-`await` half of `publish`, a separate turn 0.3–4 ms earlier, across the store's
  round trip) and the bench's own closures; after them `answeredFromStore`, `fireDue`, `runSteps` — other turns.
  Shapes 2 and 3 likewise. Nothing of the measured turn is outside the windows.
- The 88 samples that `s2turn.turn.pkl` adds over `s2cpu.turn.pkl` are `releaseFollowFollowUps → followFollowUp →
  continueFollow → continueFollowScans`, in one backtrace from the turn's root: part of the same turn, correctly kept.
- Coverage cross-check by cycle weight: shape 1's turns carry 157–188 Mcycles each (median 179), shape 3's 145–152;
  at the quiet baselines (49.08 / 40.21 ms) both imply the same clock, about 3.65–3.7 GHz. So the sampled turn is the
  whole measured window, not part of it. Shape 2's turns carry 23–170 Mcycles (recorded at a 1-minute load of 389):
  cycles were lost in several turns, which supports using shares only, as the profiler did.
- Three full backtraces were printed and read (one per shape); they run leaf → engine line → `reroute` → root → the
  actor's task closure, with no test or setup frame except, in shape 2, the bench's `releaseOneHeldTurn` that runs
  the turn inline.

## 2. Category mapping: holds, with two wording fixes

`names.py` and `leaves.py` listed what each rule matched and what sits under the deciding lines.

- Formatting: every sample under `ManifestEntry.transferID.getter` / `ContentHash.hex.getter` / `ContentHash.bytes.getter`
  is FMT, including `_xzm_xzone_malloc_tiny`, `_xzm_free_main`, `Array.append`/`reserveCapacity`,
  `UnsafeMutablePointer.initialize` under them (the allocations). No other rule steals from these chains (0 samples).
  Lines :1164 and :109 are 100 % formatting (154/154, 157/157 in shape 1); :1179 splits 160 formatting / 171 the
  `groups[token]?.pending[asset]` write. One small undercount: the release of the formatted string is attributed by
  line to the caller (`:1089`, `:1122`, `:1188`, `:574`, `:1271`) and lands in "everything else": 28 / 20 / 10 samples
  (`__StringStorage` deallocs), i.e. +0.9 / +0.6 / +0.7 points. Formatting is therefore at most 21.5 % / 17.5 % /
  16.6 %. Does not change C1.
- Jobs table: name rule `of Job`/`for Job` matched only `outlined init with copy of Job`, `outlined destroy of Job`,
  `initializeWithCopy for Job`, `destroy for Job`; the line rules cover the ten hashed accesses in `addInterest`
  (:132, :156, :157, :161, :165, :179), `failFastJoiner` (:225, :231, :245, :246), `relane` (:263, :264) and the copied
  Job's destroy at :1188. Under those lines the leaves are `Hasher.combine`, `__RawDictionaryStorage.find`,
  `_stringCompare`/`elementsEqual`, `Dictionary.subscript.modify` — jobs access, as claimed. Job copy/destroy is a third
  of the category: 215/639, 263/930, 151/407 samples (3.5 / 3.4 / 4.0 ms).
- Sorting: `AssetID.<` 278 + merge/stable-sort helpers; sites :1120 and :635 (shape 1), :559 (2), :1270 (3). Right.
- Manifest: `ValidatedManifest.position(of:)` + `entry(for:)` + `ManifestEntry` copies. At :1121 the line rule sends the
  `==` of the two 66-byte transfer-id strings (part of the 69 "dict/hash/==" samples) to MAN rather than to formatting;
  a `sameTransfer` fix removes it too, so the profiler's format-once saving for :1121 is, if anything, conservative.
- `EngineState` copy: confirmed in the binary. `decisionNow()` (`llvm-objdump`) allocates a stack copy of the whole
  `EngineState`, reads `reading?.at`, and destroys the copy. It is inlined into `addInterest`; `atos -i` on the copy /
  destroy call sites gives: copy at 0x396440 → `decisionNow` :242; destroys at 0x396464 → `noteJoin` :193 (the
  `reading != nil` branch; the optimiser sank the destroy past the inlined `noteJoin`'s `if let listed`) and at
  0x3964b0 → :242 (the `?? monotonicNow()` branch). Samples: shape 1 178 copy + 137 destroy(:193); shape 2 209 + 167
  destroy(:242); shape 3 (`s3b`) 67 + 60 destroy(:193). Two further copy/destroy pairs at `noteJoin` :200 (the `.run`
  kind's `self.state.run?.token`) had 0 samples. So it is **one** copy per join, all from `decisionNow()`; the report's
  "destroyed after `noteJoin` returns" should read "its destroy is sunk into the inlined `noteJoin` at :193".
- No double counting: each sample gets exactly one category; the eight categories sum to N in every shape.

## 3. Arithmetic: recomputed

`recat.py` re-ran the profiler's rules (exec'd unchanged from `cat.py`) and added cycle-weighted shares.

Shape 1 (3,030 samples, 49.08 ms): formatting 625 = 20.6 % (weighted 20.8 %) = 10.1 ms; jobs 639 = 21.1 % (21.3) =
10.4 ms; sorting 367 = 12.1 % (11.9) = 5.9; other Set/Dictionary 487 = 16.1 % (15.9) = 7.9; manifest 223 = 7.4 % (7.1)
= 3.6; retire/remove 37 = 1.2 % = 0.6; `EngineState` copy 323 = 10.7 % (10.9) = 5.2; else 329 = 10.9 % (10.8) = 5.3.
Identical to the report; weighting moves nothing by more than 0.3 points. Per id: 1.04 µs jobs, 1.01 µs formatting
(4 × 0.25 µs). Format sites 160/157/154/152 → 2.4–2.6 ms each.

Shape 2 (3,466, 44.92 ms): count vs weighted — jobs 26.8 → 27.8 % (12.1 → 12.5 ms), `EngineState` 11.0 → 10.4 %,
sorting 5.7 → 6.1 %, manifest 7.8 → 7.3 %; the rest within 0.1. The report's count-based figures stand; the weighted
ones are the more cautious reading for jobs (+0.4 ms).

Shape 3: the report's 1,500-sample table is 558 samples from `s3cpu` (lost events, 3 turns, 130–141 Mcycles each)
plus 942 from `s3cpu-b` (clean, 6 turns, 145–152 Mcycles). The halves differ by more than sampling noise:

| Category | `s3cpu` (558) | `s3cpu-b` (942, clean) | combined (1,500, reported) |
|---|---|---|---|
| formatting | 15.2 % | 16.3 % · 6.6 ms | 15.9 % · 6.4 ms |
| jobs table | 22.9 % | **29.6 % · 11.9 ms** | 27.1 % · 10.9 ms |
| sorting | 7.2 % | 8.1 % · 3.2 ms | 7.7 % · 3.1 ms |
| other Set/Dictionary | 19.2 % | 14.9 % · 6.0 ms | 16.5 % · 6.6 ms |
| manifest | **12.5 %** | **6.9 % · 2.8 ms** | 9.0 % · 3.6 ms |
| retire/remove | 1.4 % | 1.4 % · 0.6 ms | 1.4 % · 0.6 ms |
| `EngineState` copy | 11.3 % | 13.7 % · 5.5 ms | 12.8 % · 5.1 ms |
| else | 10.2 % | 9.1 % · 3.7 ms | 9.5 % · 3.8 ms |

The ranking is not the same (manifest 4th in one, 7th in the other; sets 2nd vs 3rd), so the caveat "both halves rank
the categories the same" is wrong. **Correction: quote the clean trace.** Shape 3 per site (`s3b`): formatting :109
2.4, :1164 2.4, :1179 1.75 ms; jobs 11.9 ms (1.19 µs per id); sort :1270 3.1; pending write :1179 2.1; `EngineState`
5.5.

## 4. Micro-timing re-run (once, load 4.12 → 4.12)

`ManifestEntry.transferID` 281 ns (report 296); `ContentHash.hex` 230 (244); `Dictionary<TransferID, Job>` lookup
10,000 jobs 114 ns (120), 3 jobs 105 (111), whole-Job copy 108 (113), in-place 182 (187); `hashValue` 56 (48);
format + lookup 465 (443); `Set<AssetID>(10,000).sorted()` 3.18 ms (3.01); ordered array 0.23 (0.225); Set insert
66 / 31 ns (62 / 31); `entry(for:)` 81.5 ns (76). All within ±7 % of the report; the report's figures stand.

## 5. Conclusions

- **C1 PARTLY — agreed.** Count 4 / 3 / 3 formats per id confirmed from the sites; 0.25 µs in the turn and 0.28–0.30 µs
  micro, the bottom of the claimed 0.3–0.65; share 20.6–21.5 % / 16.9–17.5 % / 15.9–16.6 % (10.1 / 7.6 / 6.4–6.6 ms),
  not 40–50 %; supersede 6.4–6.6 ms, not about 9. Allocation count still unverified (the leaves show several small
  mallocs per format, consistent with the claim).
- **C2 CONFIRMED — agreed**, with a count note: the source shows 10 hashed accesses on the common re-route path
  (not 7–9) and 2 whole-Job copies (:156 `if let job`, :264 `guard let job`; :225 only when blocked), destroyed at
  :1188. Per id 1.04 / 1.21–1.25 / 1.19 µs (clean shape 3), inside the claimed 0.7–1.3, upper half.
- **C3 PARTLY — agreed.** Sorts 2.9–3.1 ms each (claimed 3.3: effectively confirmed); `retireProgress` + `removeJob`
  0.6 ms, not 1.3.
- **C4 — CONFIRMED but the wording should say "at or above the top":** 0.90 / 1.06 / 0.9 µs per id (shape 3 clean:
  manifest 2.8 + pending write 2.1 + inserts 2.6 = 0.75 µs) against the claimed 0.5–0.9. The cautious reading is that
  the claim underestimates by 0–20 %, not that it is confirmed inside its range.
- **New finding (whole-`EngineState` copy per join) — CONFIRMED** in the binary and in the samples: 10.7 / 11.0 /
  13.7 % (clean shape 3) = 5.2 / 4.9 / 5.5 ms, one copy per join.

Savings, recomputed from the same sites:

| Fix family | 1. Commit (49.08) | 2. Drain (44.92) | 3. `supersede` (40.21, clean trace) |
|---|---|---|---|
| Format once | −7.6 (3 of 4 sites; −5.1 if :1121 keeps formatting) ✓ | −4.5 to −4.9 (report −4.7) ✓ | −4.2 to −4.8 (report −4.3) |
| One jobs-table access, no Job copy; residual 2–3 accesses (0.25–0.4 µs) | −6.3 to −7.8 (report −7 to −7.5, inside) | −8 to −10 incl. take-off accesses (report −8.5 to −9) | −8.4 to −9.4 of 11.9 (report −7.5 to −8 of 10.9) |
| `publishTerminal` filter before sort | −3.4 ✓ | 0 | 0 |
| Take-off F4 | — | −2 net ✓ (removes :560 + :615 + `removeAsset` = 3.4 ms, minus the overlap counted above) | — |
| `decisionNow()` copy | −5.2 ✓ | −4.9 ✓ | −5.5 |

Landing at ≤ 32 ms with the analysis's own families, in full: shape 1 **30.6–31.1 ms** (arithmetic ✓; margin
1–1.5 ms, which is smaller than the ±1.5 ms uncertainty of the jobs-table residual and comparable to cycle 20's
baseline spread of 1.4 ms — so "lands only if both fixes land in full; 33–35 ms otherwise", as the report's
conservative column says); shape 2 **29.2–29.7 ms** (report wrote 29.4–29.9: 44.92 − 4.7 − 9.0 − 2 = 29.2 and
− 8.5 = 29.7), margin about 2 ms, with the same caveat; shape 3 **27.3–27.8 ms** on the clean trace (report
27.9–28.4), lands by about 4 ms. With the `decisionNow()` copy removed as well: 25.4–25.9 / 24.3–24.8 / 21.8–22.3 ms,
all with 6–9 ms of margin. At 10 ms nothing here suffices; finding 4 of the analysis stands.

## 6. What this review did not do

No long profile was re-run; no engine code changed; the shape-3 `s3cpu` trace's lost events were not re-recorded (the
clean trace is used instead); allocation counts per format were not measured. The implied-ms method (share × quiet
baseline) is validated by cycle weights for shapes 1 and 3; for shape 2 it rests on the shares alone, because that
trace lost cycles under a 1-minute load of 389.
