export const meta = {
  name: 'assetkit-s5-docs-nonblocking',
  description: 'ZTronAssetKit Stage 5 documents: one fix round for the 10 non-blocking items left by the converged part A and part B verifiers, with an independent verifier',
  phases: [
    { title: 'Fix round', detail: 'one writer applies the 10 non-blocking items in .worktrees/s5docs; an independent verifier checks; at most 2 rounds' },
  ],
}

const ROOT = '/Users/admin/Documents/ZTronAssetKit'
const WT = ROOT + '/.worktrees/s5docs'
const MODEL = 'opus'
const BASE = 'd6cfd01'
const ISSUES = `${ROOT}/.build-orchestrator/s3-post-merge/s5docs-finish-wf_95570085-a9a.json`

const COMMON = (S) => `Repository ${ROOT}. Your worktree is ${WT} (branch wp/s5docs, currently at ${BASE} or later; it is based on d002758, the feature/asset-kit head after the Stage 3 merge, ADR-057 and the post-merge checks). Use absolute paths or cd into the worktree for EVERY command; never edit outside it. Your scratch path is ${WT}/${S}; put every scratch file there, never in /tmp or the session scratchpad. Never edit Scripts/, SPEC.md, PROMPT.md, CLAUDE.md, Package.swift, docs/ORCHESTRATION.md, docs/TRACEABILITY.md, docs/REOPEN-WP-F.md, Sources/ or Tests/. Never print or commit a secret. No builds or test runs are needed, and the iOS Simulator is not to be used. Never run anything under ${ROOT}/.worktrees/s3* or in the main checkout that changes files. TOKEN DISCIPLINE: read large files by section (grep -n first), never whole; docs/DECISIONS.md ADR-057 starts at its '## ADR-057' heading; .build-orchestrator files and the logs under ${ROOT}/.build-orch/ can be large (use grep, head, tail, sed -n). Commit messages are imperative and end with the line "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>". G2: never claim a result you did not see in a cited log or record; cite file:line or the record for every figure.`

const TASK = `FIX ROUND FOR THE NON-BLOCKING ITEMS. Four Stage 5 documents exist on wp/s5docs at ${BASE}: docs/MUTATION-PROBES.md, docs/DEVICE-TEST-PLAN.md, docs/RESIDUAL-RISKS.md (their fix round converged at 0 blocking, 2 non-blocking) and docs/VERIFICATION.md (converged at 0 blocking, 8 non-blocking). Apply all 10 non-blocking items as their fix text says, with the orchestrator's rulings below, and nothing else.
WHERE THE ISSUES ARE: ${ISSUES}. Load it with python: d = json.load(...); part A's 2 items are d['result']['partA']['rounds'][0]['issues'] and part B's 8 items are d['result']['partB']['rounds'][0]['issues']. Each has doc, location, problem and fix. Line numbers may have drifted by a few lines; find the text.
THE 10 ITEMS, with the orchestrator's rulings where the verifier left a choice:
A1. DEVICE-TEST-PLAN.md DT-PERF-06, Why a device (~:751-752) and Pass (~:765): "the bound" reads as a host measurement; the probes time nothing (they count the ids missing at return; the 0.2 s is the design bound). Apply the fix text: the observed bound is unseenAtReturn=1 in 5 of 5 (k.md:1409, :1726-1727); Pass records figures beside the 0.2 s design bound and the host probes' unseenAtReturn=1.
A2. MUTATION-PROBES.md ~:268 (§7) and RESIDUAL-RISKS.md ~:1191 (RES-60 What): "All three are killed only by WP-B's targeted tests" / "Only WP-B's targeted tests kill mutants C, F and S" now sits beside "no flows run against C is on record". RULING: narrow it to "of the runs on record, only WP-B's targeted tests kill C, F and S" in both places, keeping the s3c.md:491-497 citation.
B1. VERIFICATION.md §5.2 Gaps (~:360-385): add the bullet for the two Stage 5 assignments not done, S3B-13 with the owner's P-8 run and the chunked startGrace for S3-B-011 (DECISIONS.md:647; figures at :621), pointing to RESIDUAL-RISKS.md RES-44 and RES-45. Check the figures at DECISIONS.md:621 and that RES-44/RES-45 are the right entries before writing them.
B2. VERIFICATION.md §5.4 (~:398-492, the point-8 row ~:488): carry ADR-057's two Process caveats, the second sentence of DECISIONS.md:685 (the ADR-050 P-13 amendment and the P5 corrections not independently verified until their verifier checks them; ADR-050 says the same at :383) and :690 (the /// doc comments made true at the merge are recorded as that pass's, not independently verified). RULING: add them as a §5.4 row (or a §5.2 bullet) citing :685, :690 and :383. Say that the ADR-057 round-2 docs verifier checked them ONLY if the record at docs/ORCHESTRATION.md lines 569-571 at commit 0f909f2 (read it with: git -C ${ROOT} show 0f909f2:docs/ORCHESTRATION.md | sed -n 560,575p) says so; otherwise write them as not independently verified.
B3. VERIFICATION.md §4.7 (~:312-338) or §5.2: state ADR-057's condition at DECISIONS.md:659 ("The TSan Sync bundle runs alone, or paired only at an S3-R12 rule-1 mean of 30 or less") and what the run shows: the TSan step is one swift test --sanitize=thread invocation (Scripts/verify.sh:114, read-only) and the seven bundles are reported one after another at full5:66-72, which fits them running in sequence inside one process; no load was logged during the step. RULING: write that the "alone" reading rests on the step's structure and that the load alternative is not shown; do not write that the condition was measured.
B4. VERIFICATION.md §3.1 Q-6 row (~:106): reword the threshold to what the gate checks, the ID appears in the @Test display name (Scripts/gates.py:107, :111, :121), noting SPEC.md:324 asks that the name start with it. Add that the stronger form also holds at 45df2e1 ONLY if you check it yourself with a read-only script in your scratch path over Tests/ and docs/TRACEABILITY.md; otherwise leave that sentence out.
B5. VERIFICATION.md §3.1 Q-3 rows (~:103-104): add a "Swift 6 mode" row: no JSON key; met by Package.swift:94 (swiftLanguageModes: [.v6]) and :10 (StrictConcurrency=complete), built in the debug, release and iOS steps (full5:15-22). Read Package.swift in the worktree, read-only, and check the line numbers.
B6. VERIFICATION.md §6.3 (~:547): the P-13 reproduction filter must match the command that was run, --filter 'StorageBenchmarks/reclaim\\(\\)' (docs-followup-items.md:50); cite it. Row D (~:77) keeps quoting DECISIONS.md:674.
B7. VERIFICATION.md §5.1 background URLSession row (~:349): cite DEVICE-TEST-PLAN.md:28-31 and cite the fake driver by its own path (Tests/ZTronAssetTransportTests/FakeBackgroundSessionDriver.swift; check it exists).
B8. VERIFICATION.md §0 Conventions, the ORCH row (~:26): add the read command git show 0f909f2:docs/ORCHESTRATION.md so the ORCH:nnn citations stay easy to follow after the file moves on.
OPTIONAL (writer's judgment): DEVICE-TEST-PLAN.md DT-PERF-01's sentence "until then DT-PERF-02 to DT-PERF-05 measure through the probe app" may add that DT-PERF-06 needs no bench bundle.
RULES: check each fix against the record it cites before applying it (G2). Keep the documents' existing style, structure and citation conventions (VERIFICATION.md §0's short names). Do not rewrite anything the items do not name; do not renumber sections or entries. Commit in one or two imperative commits on wp/s5docs (VERIFICATION.md may be its own commit) and leave the worktree clean (git status empty). In your report, list every place you departed from the literal fix text and why.`

const VERIFY = (fixReport, prev) => `TASK: independently verify a fix round on branch wp/s5docs (worktree ${WT}) for docs/MUTATION-PROBES.md, docs/DEVICE-TEST-PLAN.md, docs/RESIDUAL-RISKS.md and docs/VERIFICATION.md. You did NOT write them and you were not their earlier verifier (CLAUDE.md P4). Do not modify or commit anything; leave git status unchanged.
${COMMON('.verify-s5docs-nb')}
THE WRITER WAS ASKED TO:
${TASK}
THE WRITER REPORTS: ${JSON.stringify(fixReport)}
CHECK, with evidence:
1. Every one of the 10 items is applied as its fix text and the orchestrator's rulings say: read the changed lines (git -C ${WT} diff ${BASE} -- docs/) and compare each with the record the fix cites (docs/DECISIONS.md; ${ROOT}/.build-orch/stage5-full.log; ${ROOT}/.build-orchestrator/s3-post-merge/docs-followup-items.md; ${ROOT}/.build-orchestrator/l5k-probes-c4/ (read-only); the s3 drafts under ${ROOT}/.worktrees/s3*/docs/adr-drafts/ (read-only); docs/ORCHESTRATION.md at 0f909f2 via git show; Scripts/gates.py, Scripts/verify.sh and Package.swift in the worktree, read-only).
2. The diff changes nothing the items do not name, and introduces no claim that no record supports (G2), no changed owner classification, no broken count (47 device tests, RES-01 to RES-88, 64 mutants, 1,732 tests, the coverage figures, the end state "VERIFY: FAIL (1 failed: benchmarks)").
3. The worktree is clean and the commits are on wp/s5docs.
BLOCKING: an item not applied, or applied against its record or against a ruling; a new unsupported claim; a changed classification or count; an unrelated change. Everything else is non-blocking.
${prev ? 'Also confirm these previous issues are fixed:\n' + JSON.stringify(prev, null, 1) : ''}
Return structured issues (blocking vs non-blocking) and a status paragraph.`

const FIX_SCHEMA = { type: 'object', properties: {
  summary: { type: 'string' }, commits: { type: 'array', items: { type: 'string' } },
  counts: { type: 'string', description: 'the counts and key figures as written in the documents' },
  not_done: { type: 'array', items: { type: 'string' } },
}, required: ['summary', 'commits', 'counts', 'not_done'] }
const VERIFY_SCHEMA = { type: 'object', properties: {
  issues: { type: 'array', items: { type: 'object', properties: {
    blocking: { type: 'boolean' }, doc: { type: 'string' }, location: { type: 'string' }, problem: { type: 'string' }, fix: { type: 'string' },
  }, required: ['blocking', 'doc', 'location', 'problem', 'fix'] } },
  status: { type: 'string' },
}, required: ['issues', 'status'] }

async function rounds(phaseName, maxRounds, writePrompt, verifyPrompt) {
  const out = []
  let prev = null
  for (let round = 1; round <= maxRounds; round++) {
    const extra = prev ? '\nAn independent verifier reports these issues (JSON). Fix every blocking one, then the clearly right non-blocking ones, check each against its record, and commit:\n' + JSON.stringify(prev, null, 1) : ''
    const w = await agent(writePrompt(round) + extra, { label: phaseName + ' write:' + round, phase: phaseName, schema: FIX_SCHEMA, model: MODEL })
    log(phaseName + ' write ' + round + ': ' + (w ? w.commits.length + ' commits; ' + w.counts : 'NO RESULT'))
    const v = await agent(verifyPrompt(w, prev), { label: phaseName + ' verify:' + round, phase: phaseName, schema: VERIFY_SCHEMA, model: MODEL })
    const blocking = v ? v.issues.filter(i => i.blocking) : []
    log(phaseName + ' verify ' + round + ': ' + blocking.length + ' blocking / ' + (v ? v.issues.length : '?'))
    out.push({ round, write: w, status: v && v.status, issues: v ? v.issues : null })
    if (v && !blocking.length) return { rounds: out, converged: true }
    prev = v ? v.issues : prev
  }
  return { rounds: out, converged: false }
}

phase('Fix round')
const fix = await rounds('Fix round', 2,
  (round) => `TASK: non-blocking fix round ${round} on branch wp/s5docs.\n${COMMON('.build-s5docs')}\n${TASK}\nReturn the structured report.`,
  (w, prev) => VERIFY(w, prev))
if (!fix.converged) log('The fix round did not reach 0 blocking in 2 rounds; the orchestrator rules on what is left.')
return { fix }