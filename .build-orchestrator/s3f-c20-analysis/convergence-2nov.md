# WP-F: can C2's 10 ms converge? (2 Nov 2026, after cycle 20)

The owner asked on 2 Nov: "can we decide if it's realistically possible to converge to 10ms or it will never happen because during design we were too strict?"

## Answer

- **It is technically possible to keep every turn under 10 ms at 10,000 ids.** Each of cycle 20's six C2 shapes has a known fix.
- **The fix loop under the current bar does not converge.** Cycles 13–20 show no trend.
- **The design was not too strict.**
  - SPEC.md:111 makes "~10 ms" a *(hint)* for blocking work, which P-9 proves (heartbeat gap p99 ≤ 50 ms).
  - The hard 10.0 ms per-turn bar came from Stage 2's benchmarks and from Stage 3's rulings.
  - That bar was applied to an engine built without bounded turns.

## Blocking items by cycle

Counts are from `s3f-c*-issues.json`, both lenses, not deduplicated.

| Cycle | Blocking | Mostly |
|---|---|---|
| 4 | 2 | A hang-guard margin; a C2 regression in the space sweep's follow |
| 8 | 4 | 2 correctness (R-SYN-11, F-28); stability; C2 in the sweep's follows |
| 12 | 11 | Follow-barrier answer differences (R-H, R-C, R-A, R-I); G4 in replay branches; a hang in a barrier test; records |
| 14 | 5 | 4 follow-barrier answer differences; G4 in `followedLane` |
| 17 | 9 | 4 C2 (`bringInbound`, the follow's turns); 3 answer differences (barrier, RR-14); 2 G4 in cycle 17's deferrals |
| 18 | 5 | 1 answer difference from the bounded moves; 1 C2; 2 G4 in the owed moves; liveness of the wait for owed moves |
| 19 | 9 | 3 C2 (one in the bounded drain); 4 G4 in deferral and replay branches; 2 flakes (one in a barrier test) |
| 20 | 12 (8 distinct) | 6 C2; 2 G4 in deferral code; no answer difference |

## The chain

1. **29 Oct.** S3F-5 found a 17–19 ms turn: a manifest applied under a 10,000-member group. Under S3-R5 the follow was split over turns (`followsPerTurn`, `958348e`).
2. **30 Oct.** Events landing in the middle of a follow changed answers compared with the visit-first reference. The follow barrier (`02d51a0`) was added to prevent that.
3. **Cycles 5–12.** Each cycle found new members of the barrier's defect class.
   - S3-R11, S3-R14 and S3-R15 responded to them.
   - S3-R16 then narrowed the bar to observable answers: "Eight cycles (5–12) did not converge on exact visit-first equivalence."
4. **Cycles 13–20.** Blocking counts were 7, 5, ~8, 5, 6, 5, 8, 8.
   - The bounds added for C2 (`followIDsPerTurn` and `inboundIDsNow` on 1 Nov, `drainIDsLeft` on 2 Nov) are where cycles 18–20 found the next C2 figures, G4 gaps and answer differences.

## Where the bar came from

- **SPEC.md:111 (the design).** "Blocking work (hashing, copying, directory enumeration) never runs on a cooperative-pool thread for more than ~10 ms at a stretch. *(hint)* … decide by ADR and prove it with P-9."
  - SPEC.md:5 defines *(hint)* statements as starting points to verify.
- **P-9** (SPEC §6, `quality-gates.json`). 64 concurrent resolves plus hashing run while a heartbeat ticks every 10 ms. The heartbeat gap p99 must be ≤ 50 ms.
- **16 Oct, Stage 2 (`f50cdfb`).** BenchSync's `c2Budget = 10.0` per actor turn at 10,000 members.
- **Stage 3 rulings:**
  - S3-R5: a turn over ~10 ms at 10,000 is fixed by bounding the work per turn.
  - S3F-4 and S3F-5 were made blocking at 17–22 ms.
  - S3-R16 1(f): a C2 figure blocks close-out.
  - S3-R20 to S3-R25: every inventory row gets a figure, best of 3 at a load ≤ 10.

## Why it loops

- The measured shapes cost 36–49 ms at 10,000 ids, about 4–5 µs per id. One pass over every id therefore already uses about the whole budget.
- So every operation over all ids must either be re-indexed, so that it touches only the affected ids, or be split over turns.
- A split lets events land in the middle of an operation. S3-R16 1(a) then needs machinery that keeps the answers identical in both LaneDropVisit orders.
- That machinery brings its own problems:
  - new branches, which need G4 coverage and killed mutants in both orders;
  - new answer differences;
  - its own C2 figures.
- RR-21, the next split, adds about 32 branches.

## Cycle 20's six C2 shapes

| Shape | Figure | Kind of fix (from cycle 20's fix text) |
|---|---|---|
| `move` (owed moves off a large holder) | 79.55 ms at 16 moves, 304.79 ms at 64 | Re-index: index each job's interests by asset |
| `deferBehindVerdict` | 35.78–39.55 ms | Re-index: a bucket per verdict, O(1) |
| Commit re-routes (RR-21) | 47.99–49.34 ms | Split over turns |
| Drain take-off | 47.03 ms | Split over drain turns |
| `supersede` | 41.09 ms | Split over turns (RR-21's batches) |
| Commit window | 10.16 ms, against 9.82 in another run | Split the binding and the answers, or remove an O(N log N) sort |

## Options put to the owner

- **A. Freeze at `8e1fb24`, with a C2 waiver for the six shapes (recommended).**
  - No more cycles. An optional G4 pass takes about 2–3 h.
  - Residual risk: in rare shapes at 10,000 ids, the sync actor holds one pool thread for 36–49 ms, and for up to 305 ms in the 64-move shape. The main thread is not blocked.
- **B. Continue unchanged.** There is no end to forecast. Each cycle costs about 7–10 h and about 15 weekly points.
- **C. Re-scope C2 to the SPEC.**
  - C2 becomes P-9 plus a per-turn ceiling that the owner names. The suggestion is 100 ms at 10,000 ids.
  - Fix only `move` by re-indexing, and optionally `deferBehindVerdict`. Neither fix adds a state in the middle of an operation.
  - The answer, MUST and G4 bars are unchanged.
  - Cost: about 1 cycle, about 10 h and about 15 weekly points.

**Lesson for later stages:** set hard performance bars before building, and build for them. That means bounded steps from the start, with a correctness bar written for operations that are split over turns. Adding a hard bar to a finished engine is the expensive order.
