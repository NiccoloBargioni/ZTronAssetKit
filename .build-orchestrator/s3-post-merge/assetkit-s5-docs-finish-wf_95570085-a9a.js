export const meta = {
  name: 'assetkit-s5-docs-finish',
  description: 'ZTronAssetKit Stage 5 documents: part A fix round (MUTATION-PROBES, DEVICE-TEST-PLAN, RESIDUAL-RISKS) and part B (VERIFICATION.md), each with an independent verifier',
  phases: [
    { title: 'Part A fix', detail: 'one writer applies round 2 issues in .worktrees/s5docs; an independent verifier checks; at most 2 rounds' },
    { title: 'Part B', detail: 'one writer drafts docs/VERIFICATION.md; an independent verifier; at most 3 rounds' },
  ],
}

const ROOT = '/Users/admin/Documents/ZTronAssetKit'
const WT = ROOT + '/.worktrees/s5docs'
const MODEL = 'opus'

const COMMON = (S) => `Repository ${ROOT}. Your worktree is ${WT} (branch wp/s5docs, currently at 6eab1ba or later; it is based on d002758, the feature/asset-kit head after the Stage 3 merge, ADR-057 and the post-merge checks). Use absolute paths or cd into the worktree for EVERY command; never edit outside it. Your scratch path is ${WT}/${S}; put every scratch file there, never in /tmp or the session scratchpad. Never edit Scripts/, SPEC.md, PROMPT.md, CLAUDE.md, Package.swift, docs/ORCHESTRATION.md, docs/TRACEABILITY.md, docs/REOPEN-WP-F.md, Sources/ or Tests/. Never print or commit a secret. No builds or test runs are needed, and the iOS Simulator is not to be used. Never run anything under ${ROOT}/.worktrees/s3* or in the main checkout that changes files. TOKEN DISCIPLINE: read large files by section (grep -n first), never whole; docs/DECISIONS.md ADR-057 starts at its '## ADR-057' heading; .build-orchestrator files and the logs under ${ROOT}/.build-orch/ can be large (use grep, head, tail, sed -n). Commit messages are imperative and end with the line "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>". G2: never claim a result you did not see in a cited log or record; cite file:line or the record for every figure.`

// ---------- Part A: the fix round ----------
const A_ISSUES = `${ROOT}/.build-orchestrator/s3-post-merge/s5docs-partA-wf_c7c92797-46b.json`
const A_TASK = `PART A FIX ROUND. Three Stage 5 documents exist on wp/s5docs: docs/MUTATION-PROBES.md, docs/DEVICE-TEST-PLAN.md and docs/RESIDUAL-RISKS.md. Their round-2 verifier left 1 blocking and 7 non-blocking issues. Apply all 8 exactly as its fix text says, and nothing else.
WHERE THE ISSUES ARE: ${A_ISSUES}. Load it with python: the workflow's return value is under "result"; take result.rounds[1].issues (round 2; the round whose issues include the MUTATION-PROBES.md §6.4 OracleTests item). Each issue has blocking, doc, location, problem and fix.
THE BLOCKING ONE: MUTATION-PROBES.md §6.4 (around line 237) credits OracleTests with killing mutant X, but the oracle never ran against X (evidence: ${ROOT}/.worktrees/s3c/.build-s3c/mut/run-mutants.sh:33 and ${ROOT}/.worktrees/s3c/docs/adr-drafts/s3c.md:484-485, read-only). Split the bullet in two: Z is killed by OracleTests and CleanupFlowCrashTests; X by CleanupFlowCrashTests alone.
THE 7 NON-BLOCKING ONES (summary; the JSON has the exact text): no flows ran against mutant C is on record (MUTATION-PROBES.md ~:239, ~:267, RES-60); MUTATION-PROBES.md ~:198 should cite s3f.md:9096-9102; RES-15's "the one RR that changes an answer" is unsupported; RES-02 derives a lower bound where the log gives the exact figure (7 units over, benchmarks.log:128); RES-54 lacks the citation s3c.md:231-234; RES-71 omits ADR-057's "known miss"; S3-B-110 (L5K-R24's lag) is in neither doc.
RULES: check each fix against the record it cites before applying it (G2). Keep the documents' existing style and structure. Line numbers in the issues may have drifted by a few lines; find the text. Do not rewrite anything the issues do not name. Commit in one or two imperative commits on wp/s5docs and leave the worktree clean (git status empty).`

const A_VERIFY = (fixReport, prev) => `TASK: independently verify a fix round on branch wp/s5docs (worktree ${WT}) for docs/MUTATION-PROBES.md, docs/DEVICE-TEST-PLAN.md and docs/RESIDUAL-RISKS.md. You did NOT write them and you were not their earlier verifier (CLAUDE.md P4). Do not modify or commit anything; leave git status unchanged.
${COMMON('.verify-s5docs-a')}
THE WRITER WAS ASKED TO:
${A_TASK}
THE WRITER REPORTS: ${JSON.stringify(fixReport)}
CHECK, with evidence:
1. Every one of the 8 issues in ${A_ISSUES} (result.rounds[1].issues) is applied as its fix text says: read the changed lines (git -C ${WT} diff 6eab1ba -- docs/) and compare each with the record the fix cites (the hunt JSON ${ROOT}/.build-orchestrator/s3-hunt-result.json key "mutate"; ${ROOT}/.build-orchestrator/s3-post-merge/mut-recheck/summary.txt; the s3 drafts under ${ROOT}/.worktrees/s3*/docs/adr-drafts/, read-only; ${ROOT}/.build-orch/stage5-verify-logs-45df2e1/benchmarks.log; docs/DECISIONS.md ADR-057).
2. The diff changes nothing the issues do not name, and introduces no claim that no record supports (G2), no changed owner classification, and no broken count (27 + 37 = 64 mutants; 11 survivors all killed on e840b0e).
3. The worktree is clean and the commits are on wp/s5docs.
BLOCKING: an issue not applied, or applied wrongly against its record; a new unsupported claim; a changed classification or count; an unrelated change. Everything else is non-blocking.
${prev ? 'Also confirm these previous issues are fixed:\n' + JSON.stringify(prev, null, 1) : ''}
Return structured issues (blocking vs non-blocking) and a status paragraph.`

// ---------- Part B: VERIFICATION.md ----------
const B_INPUTS = `INPUTS for VERIFICATION.md (read by section; every figure you write must come from one of these, cited):
- PROMPT.md lines 60-70 (Stage 5: "what ran, thresholds, results, what was not verified"). CLAUDE.md G2: anything that could not be run (device-only behaviour, real Apple-hosted packs, background sessions) goes under "Not verified".
- ${ROOT}/docs/ORCHESTRATION.md lines 499-660 only: the post-merge checklist ("THE CHECKLIST FROM HERE") with items 1-11, including the merged head's --full (item 3), the iOS Simulator suite (3b), TSan/--perf and P-13 (4), the mutation re-check (5), ADR-057 (6), the tag (7), Stage 5's --full and the tools-6.4 (c) run (item 9). It names every log.
- The Stage 5 --full at 45df2e1 (the accepted end state): ${ROOT}/.build-orch/stage5-full.log and the step logs in ${ROOT}/.build-orch/stage5-verify-logs-45df2e1/ (build, tests-run 1-3 per target counts, coverage per target, TSan, trace, unsafe, docs, benchmarks with its 7 issues, GATES-CONFIG sha256).
- Thresholds: ${ROOT}/Scripts/quality-gates.json (coverage floors, exclusions, budgets, unsafe patterns) and ${ROOT}/Scripts/verify.sh (what each step runs). Quote the numbers the gates enforce; never alter them.
- Tools-6.4 runs: ${ROOT}/.build-orch/t64b/ (check b on e840b0e) and ${ROOT}/.build-orch/t64c/ (check c on 45df2e1): status.txt, warnings.txt and the logs. The owner's requirement: 0 warnings at swift-tools-version 6.4; the committed manifest stays 6.0.
- The iOS Simulator suite on e840b0e: ${ROOT}/.build-orch/sim-merged/ (1732 tests; check the xcresult summary or log, never trust this line alone).
- P-13: ${ROOT}/.build-orch/merge-P13-quiet.log, ${ROOT}/.build-orchestrator/s3-post-merge/p13-verify-wf_19408ffa-9ba.json and docs-followup-items.md (P1-P8); the ruling: p99 (ADR-050's amendment in docs/DECISIONS.md).
- The one load-only case: ${ROOT}/.build-orch/merge-userToBound-rerun1.log and ${ROOT}/.build-orch/merge-full.log (the e840b0e --full).
- The mutation re-check: ${ROOT}/.build-orch/mut-recheck/summary.txt and ${ROOT}/.build-orchestrator/s3-post-merge/mut-recheck/first-issues.txt; docs/MUTATION-PROBES.md on wp/s5docs.
- What was not verified: docs/DECISIONS.md ADR-057's "Not verified" list and Open items; docs/APPLE-API-VERIFICATION.md's UNVERIFIED and device-only items; docs/DEVICE-TEST-PLAN.md (on wp/s5docs); docs/RESIDUAL-RISKS.md for the accepted FAIL (the six R-CLN-6 purge shapes at BenchSyncCycle22Purge.swift:32 and P-13) and the known misses.
- docs/UNSAFE-AUDIT.md (the audited exceptions, if any) and docs/TRACEABILITY.md's header (requirement and test counts), on wp/s5docs.`

const B_TASK = `WRITE docs/VERIFICATION.md (new; Stage 5 of PROMPT.md; the orchestrator owns it and delegates the drafting to you). House style of docs/DECISIONS.md: compact, precise, no marketing; tables where they help.
CONTENT, in this order:
1. Scope: the head verified (45df2e1, feature/asset-kit after the Stage 3 merge e840b0e and ADR-057), the date, the host (an Apple-silicon Mac; macOS and Xcode/Swift versions as the logs print them), and that later commits on the branch are documentation only (name them from git log 45df2e1..HEAD of the main checkout, read-only).
2. What ran: every verify.sh --full step with its command (from Scripts/verify.sh) and the run it came from, plus the extra runs: the iOS Simulator suite, the tools-6.4 checks (b) and (c), the quiet-load P-13 runs and its independent verifier, the load-only re-run, the mutation re-check, TSan.
3. Thresholds: every gate and budget verify.sh enforces, quoted from Scripts/quality-gates.json with its key, next to the measured value.
4. Results: per step, PASS/FAIL/OK with the figures: tests per target per run (3 runs), coverage per target and overall with the floor and the excluded share, TSan, trace counts, unsafe count, docs count, the benchmarks (88 tests, which 7 issues and why each is accepted), GATES-CONFIG sha256, the simulator counts, the 0-warnings result at 6.4, the mutation re-check (11/11 killed), P-13's figures and ruling. State the end state plainly: "VERIFY: FAIL (1 failed: benchmarks)", accepted by the owner (ADR-057, close point 3), with the exact causes.
5. Not verified: everything no run here could prove, each with why and where it is covered (DEVICE-TEST-PLAN.md test ids, RESIDUAL-RISKS.md ids, APPLE-API-VERIFICATION.md items): device-only behaviour, real Apple-hosted packs through TestFlight, background URLSession re-attachment, low storage and memory warnings on a device, and every ADR-057 Not-verified item.
6. How to reproduce: the exact commands (verify.sh modes, the tools-6.4 procedure, the simulator command as the records give it) and where the logs are archived (the archive/build-orchestrator snapshots, by name).
RULES: G2 throughout: every number cites its log or record (path:line). Never claim a gate passed that a log shows failed. Do not restate ORCHESTRATION.md's narrative; extract results. Do not edit any other document. Commit in one imperative commit on wp/s5docs and leave the worktree clean.`

const B_VERIFY = (writeReport, prev) => `TASK: independently verify docs/VERIFICATION.md on branch wp/s5docs (worktree ${WT}). You did NOT write it (CLAUDE.md P4). Do not modify or commit anything; leave git status unchanged.
${COMMON('.verify-s5docs-b')}
THE WRITER WAS ASKED TO:
${B_TASK}
${B_INPUTS}
THE WRITER REPORTS: ${JSON.stringify(writeReport)}
CHECK, with evidence, at least:
- every figure against its cited log or record (open the file at the line; spot-check ALL test counts, coverage figures, benchmark issues, the sha256, the simulator counts, the warning counts, the mutation results, P-13's numbers);
- every threshold against Scripts/quality-gates.json;
- that every verify.sh --full step appears, with the right PASS/FAIL/OK;
- that "Not verified" covers ADR-057's Not-verified list, APPLE-API-VERIFICATION.md's UNVERIFIED items and SPEC section 8's four device areas;
- that no gate is claimed passed that a log shows failed, and that the end state is stated as the accepted FAIL with its exact causes;
- that no other document changed and the worktree is clean.
BLOCKING: a figure that its cited source does not show, a missing step or threshold, a wrong PASS/FAIL, a missing Not-verified item from the lists above, a change to another document. Everything else is non-blocking.
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

phase('Part A fix')
const partA = await rounds('Part A fix', 2,
  (round) => `TASK: part A fix round ${round} on branch wp/s5docs.\n${COMMON('.build-s5docs')}\n${A_TASK}\nReturn the structured report.`,
  (w, prev) => A_VERIFY(w, prev))
if (!partA.converged) {
  log('Part A did not reach 0 blocking in 2 rounds; part B still runs, and the orchestrator rules on what is left.')
}

phase('Part B')
const partB = await rounds('Part B', 3,
  (round) => `TASK: part B, docs/VERIFICATION.md, round ${round} on branch wp/s5docs.\n${COMMON('.build-s5docs')}\n${B_INPUTS}\n${B_TASK}\nReturn the structured report.`,
  (w, prev) => B_VERIFY(w, prev))

return { partA, partB }
