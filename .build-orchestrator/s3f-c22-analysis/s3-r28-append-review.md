# S3-R28 append: the independent review (P4)

- **Text:** `s3-r28-append.md` (280 lines, 14:43) against `s3-r28-final.md` (227). ":n" is the append's line, "F :n"
  the final text's, "N :n" `s3-r28-orchestrator-rulings.md`'s.
- **Method:** reading only, and one `diff` of the two texts (17 hunks), each traced to a ruling. Code at
  `.worktrees/s3f` (`wp/s3f`, HEAD `9aa337c`, clean). No build, no test, no edit outside this file.
- **Brief:** N21 to N23. N24 (14:26) and N25 (14:37) are later; where they bear on the text, see O2 and O3.

## Verdict: CORRECTED

Every point of N21, N22 and N23 is carried, and the only other edits are ones they force. Over 50 citations checked
hold. Three consistency gaps need text (M1 to M3). Item 8's stop conditions need a ruling (O1) before step 0's first
table, since they are checked "at the end of every part and every measurement" (:255).

## Checked and right

- **N21:** :74 and :76 are O1's text word for word, :201 is O1's :170 text, :63 carries O1's sentence and N21's "not
  a narrowing of the bar" (N :130), and :77 is N23.1's added line.
- **N22 → item 8 (:247-280):** points 1 to 7 verbatim. Three additions hold: "the branch of `.worktrees/s3f`" (it is
  `wp/s3f`), the two UNSOUND verdicts (f1 review :8, f1b review :11), and "swept first in both drain timings"
  (N23.6). "Items 1 to 7 included" is S3-R27's style for a later item (rulings :1019, :1049).
- **N23:** 1 → :63, :74, :76-77, :201. 2 and 3 confirm text that stands (:66, :176-179). 4 → :54, :57, :59; no count
  is in the text (the list now holds about 48 to 50 shapes with ends, corners and variants; ORCHESTRATION.md:276 says
  "about 35"). 5 → :61. 6 → :63, :67. 7 → :159, with the edits it forces at :157-158 and :160. 8 → :140-141.
  9 → :144-149. 10 → :151-152, :213. 11 → :188-189. 12 → :150. 13 → :5, :200-201, :220-221. F :184's "The shapes
  may run after step 1's commits instead" goes, by N22.1 (see O4).
- **Citations:** N :127-130, :136, :170; f1 :200-207; f1 review :8; f1b :116, :120-121, :125, :232-233, :271-273; f1b
  review :11, :53-54, :161-163; f3 :139-163, :207-216, :319-345; f3b-route-a :32, :51, :167; f3b review :35, :53,
  :89-92, :97-100; rulings :585, :587, :639, :763, :972, :1091, :1121, :1233-1234, :1257; probe file :285, :320, :338,
  :368, :445, :461; `EngineFollowTests.swift:783`; `EngineFollowBarrierReachTests.swift:25-27`; `EngineJobs.swift`
  :289-297, :311-314, :327, :360-364, :424-437, :563-578; `EngineCommands.swift` :998-1022, :1065, :1773, :1884;
  `EngineState.swift:1131`; `EngineFollow.swift` :800, :981; `ValidatedManifest.swift` :15, :86-91. All hold.

## Must fix

**M1. A stop's red test breaks the green-commit rule (:69, :216; 8.3).** 8.3 commits "the evidence (the red test …)"
and goes on. :69 commits a red shape "only right before item 1b's fix for it"; :216 keeps every other stage green at
every commit, as S3-R26 item 11 does (rulings :639). Item 8's precedence covers the evidence commit, not the later
ones: one verifier accepts the red Sync test at each later commit, another reports each one.
- :69: "only right before item 1b's fix for it." → "only right before item 1b's fix for it, or as a stop's evidence
  (item 8's point 3)."
- :216, the whole bullet: "Every other stage is green at every commit, except at S3-R26 item 11's red-first commits,
  which may also carry those cases, and except for a stop's red test (item 8's point 3), which may stay red from its
  evidence commit until the orchestrator's ruling on the stop is carried out. Each commit message names it."

**M2. Item 8's early probe has no place in item 5's order (:210, :220; 8.6).** 8.6 probes "before the fixer moves
on", but item 5 goes from item 1b's route to the next step, and item 6 ends a run only at its budget or at a stop.
- :210, the whole bullet: "Item 1b: its red shapes first, then its route, then item 8's early probe (point 6). The
  fixer starts no later step until the prober has reported and the orchestrator has ruled any red it found."
- :220: "or at a stop that leaves no work independent of the stopped item (item 8)." → "at a stop that leaves no work
  independent of the stopped item, or while item 8's early probe runs (item 8)."

**M3. Step 0's table has two definitions of "red" (:61, :63-67).** :61 makes a swept-first answer red when it is
"none of visit-first's answers"; :64 when the shape "fails" in either round, and the probes compare each round with
the same round's visit-first run (probe file :368). Where two visit-first rounds differ, one verifier reads green and
another red. :63 gives the answer set for three shapes only, though N21 lists "each such shape" (N :130), and a red
visited-first cell is not defined, though N21's check (:77) reads the table.
- :63: "For the multi-change lazy shape, W-BACK-PUB and pending-move corner (iii), record both visit-first answers and
  the timing that selects each" → "For the multi-change lazy shape, W-BACK-PUB, pending-move corner (iii), and any
  other shape whose visit-first runs give more than one answer for the same inputs in the same order, record each
  visit-first answer and the timing that selects it".
- :64, after its first sentence: "A swept-first round fails when its answer is none of the visit-first answers recorded
  for the same inputs in the same order, when the failed job's start count differs from visit-first's, or when it
  breaks a MUST or invariant, or hangs. A visited-first round fails only by a broken MUST or invariant, or a hang; a
  missed prediction is recorded as "The reference is the measured visit-first run" says."
- :65: "an answer different from visit-first's" → "an answer that is none of visit-first's". :67: "pending-move corner
  (iii) are classed" → "pending-move corner (iii) and any other shape listed there are classed".

## Should fix

**S1. The header and item 8 give item 8's reach differently (:5, :247).** :5's last sentence → "Item 8, "Fail fast",
binds the fixer and the verifiers from cycle 23 on, wherever an earlier ruling, or items 1 to 7, order the work
otherwise."

**S2. Stage C's new trigger needs stage B to have run (:159).** With stage B skipped, a case that retires no job at
10-12 ms after stage A waits for stage C by :141 (N23.8: "if stages B or C can move it"), but :159 reads "after stage
B". "when, after stage B, a case" → "when, after stage B (after stage A, if stage B did not run), a case".

**S3. Step 0's hours leave out f1's windows 8 to 10 (:227),** which neither f1b's 4-6 h (its §2 rows, f1b :125) nor
the f1b review's 4-6 h covers; item 8's 2(e) reads this figure. The bullet → "step 0's shapes, about 11-18 h
(derived): f1b's 4-6 h for its step 0 (f1b §8), the f1b review's 4-6 h for the late drain and its new shapes, and
f1's windows 8 to 10 at the f1 review's 1-2 h a new shape (both in the f1b review's "must add" 8);".

**S4. "N9" and "N21" are not defined in the text (:61-77, :151, :201).** After :34: "- **N-numbers** are the
orchestrator's notes behind this ruling (`s3f-c22-analysis/s3-r28-orchestrator-rulings.md`): N9 is item 3's re-lane
paragraph, and N21 is the owner's 13:30 ruling with the orchestrator's reading of it (item 1)."

## For the orchestrator

**O1. Item 8's stop conditions, before step 0.** Five readings split two verifiers; item 3b's draft settles (b) and
(e) for its own parts only (`s3-r28-item3b.md:96`, `:126`).
- **(a)** Does a start-count-only red (:66) stop? Proposed: "is still red" → "is still red in a way that blocks
  (item 1's "Which red shapes block")".
- **(b)** f3 §5 gives each stage's figure (5-12, 4-10.5, 2-7 ms), not a saving, and names no end of the range. A case
  at 13 ms after stage B, which stage C saves 2.2-3.8 ms on (`oneGroupScope`'s row, f3 §3.2), stops at the lower end
  and not at the upper. Proposed: "the later stages' estimated savings (f3 §5)" → "the upper end of what the later
  stages save on that case (f3 §3.2)".
- **(c)** Is a 'before' figure above its "today" estimate (`keptUnderThreeGroups`, 38-48 ms, :129) a fixer stop, or
  input to the orchestrator's check "while the fixer goes on" (8.1)? And 8.3 names no committer for a stop found by
  the orchestrator (:77) or the prober (8.6). Proposed: "the orchestrator rules it and says what the fixer commits".
- **(e)** Items 3 and 6 estimate stages, steps and items, not parts (f3 :336: 1-1.5 h a part), and nothing records
  hours spent. Proposed: "a part" → "a part, stage or step that items 2, 3, 3b or 6 estimate, timed in the status list".
- **Load:** the trigger follows S3-R27 item 10 at a noisy load (:162); a stop is not said to. Proposed: a figure above
  10 ms seen only at a load above 10 stops nothing until rulings :763 decides it.

**O2. N24 and N25 leave three lines stale.**
- :145-146 ("its A-3 replaces the sort … for two classes of job"): the merge's M-4 replaces it for classes A, B and B′
  (`s3-r28-item3b.md:30`); A-3 is not among M-0 to M-5. Proposed: "(C-3, and the sort at `EngineCommands.swift:1019`)".
- :150 ("item 3b gates or routes them"): two of the three are N25's known misses, neither gated nor routed, and M-4
  routes the third (`s3-r28-item3b.md:91`). Proposed: "item 3b says what cycle 23 does with each (N25)".
- :272's "a known miss" collides with N25's non-blocking known misses. Proposed: "a blocking miss".

**O3. An appended item against items 1 to 8.** :5 says only that appended items bind the verifiers, and :247 puts
item 8 over items 1 to 7; item 3b's draft amends item 8's step-0 order (`s3-r28-item3b.md:88`). Proposed for :5: "An
appended item decides where it differs from items 1 to 8."

**O4. N22.1 against N12.** N20's option for the shapes goes, but N12's for S3-R27 items 3's and 4's 'before' figures
(at the start of steps 4 and 5, on a copy of `9aa337c`) stays (:201). Confirm it, or strike it.

**O5. M2 reads 8.6 strictly.** If work independent of item 1b may go on, M2's :210 text ends instead: "…; until it
reports, the fixer goes on only as item 8's point 3 allows after a stop."

**O6. Corner (iii) (N23.6).** Its two visit-first answers turn on whether the waiter's withdrawal comes before or
after the layer's apply (f1b :232-233), an order the probe sets. Have the draft record each answer with its inputs'
order, or the class reads as accepting the other order's answer, narrowing "Keep it blocking" (N :127-129).
