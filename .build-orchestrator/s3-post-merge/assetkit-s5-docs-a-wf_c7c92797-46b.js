export const meta = {
  name: 'assetkit-s5-docs-a',
  description: 'ZTronAssetKit Stage 5 documents, part A: MUTATION-PROBES, DEVICE-TEST-PLAN and RESIDUAL-RISKS, one writer and an independent verifier, one fix round',
  phases: [
    { title: 'Write', detail: 'one writer in .worktrees/s5docs (branch wp/s5docs)' },
    { title: 'Verify', detail: 'independent verifier; at most one fix round' },
  ],
}

const ROOT = '/Users/admin/Documents/ZTronAssetKit'
const WT = ROOT + '/.worktrees/s5docs'
const BASE = 'd002758'

const COMMON = (S) => `Repository ${ROOT}. Your worktree is ${WT} (branch wp/s5docs, based on ${BASE}, the feature/asset-kit head after the Stage 3 merge, ADR-057 and the post-merge checks). cd into the worktree for EVERY command and never edit outside it. Your scratch path is ${WT}/${S}; put every scratch file there, never in /tmp or the session scratchpad. Never edit Scripts/, SPEC.md, PROMPT.md, CLAUDE.md, Package.swift, docs/ORCHESTRATION.md, docs/TRACEABILITY.md, docs/REOPEN-WP-F.md, Sources/ or Tests/. Never print or commit a secret. No builds or test runs are needed; the iOS Simulator is not to be used. TOKEN DISCIPLINE: read large files by section (grep -n first), never whole: docs/DECISIONS.md ADR-057 starts at its '## ADR-057' heading; .build-orchestrator files can be large.`

const INPUTS = `INPUTS (read what each document needs, by section):
- SPEC.md: section 7.4 (Mutation probes) and section 8 (Deliverables; DEVICE-TEST-PLAN is "what only a physical device can prove: background session re-attachment, Apple-hosted packs through TestFlight, low-storage behaviour, memory warnings"). PROMPT.md lines 55-66 (Stages 3 and 5).
- docs/DECISIONS.md ADR-057 (the Stage 3 merge record: known misses, the known-risk class, the accepted FAIL, f3c's open shapes, N33's items, Not verified, Open) and the ADR-050 P-13 amendment; docs/APPLE-API-VERIFICATION.md (UNVERIFIED and device-only items).
- ${ROOT}/.build-orchestrator/s3-hunt-result.json, key "mutate" -> "storage"/"network" -> "probes": the 64 discovery mutants at s3-base, each with id, title, file, requirement, diff_path, killed, killing_tests, notes. The diffs are at each diff_path (${ROOT}/.build-orchestrator/s3-mutants/...).
- ${ROOT}/.build-orchestrator/s3-post-merge/mut-recheck/summary.txt and first-issues.txt: the post-merge re-check on e840b0e of the 11 discovery survivors, all KILLED, with the killing test and file:line; M-N-39.reapplied.diff is the survivor re-made for the moved context.
- ${ROOT}/.build-orchestrator/s3-post-merge/docs-followup-items.md (P1-P8: P-13's margin, failure rate and records) and p13-verify-wf_19408ffa-9ba.json.
- ${ROOT}/.build-orchestrator/s3-post-merge/adr057-docs-journal.jsonl: the ADR-057 workflow's journal. Its first 8 'result' lines are the ledgers (items with kind, target, source, text, code_check). Extract with python the items whose kind is 'not-verified', 'residual-risk', 'later-stage-note' or 'needs-human-review', and any item that names a device, TestFlight, background session, low storage, memory warning or iOS.
- docs/ORCHESTRATION.md: only the checklist that starts at 'THE CHECKLIST FROM HERE' (the post-merge results).
- docs/adr-drafts/*.md sections titled 'Not verified' (s3f.md: '## Not verified here', line 11992 on) for device-only items, and WP-F's close-out mutant records (ADR-057 points to them).`

const TASK = `WRITE THREE NEW DOCUMENTS (Stage 5 of PROMPT.md; the orchestrator owns them and delegates the drafting to you):
1. docs/MUTATION-PROBES.md (SPEC 7.4: "the diff and the test that failed").
   - Method: who injected the mutants and how (independent agents, base, one at a time, narrowest target), and how survivors became tests (S3-R3).
   - A table of all 64 discovery mutants: id, what it breaks, file:line, requirement, outcome, the killing test(s).
   - For each of the 11 discovery survivors, the close-out test that now kills it and the post-merge re-check on e840b0e, with the test's file:line.
   - The diff of every mutant, compactly (for example a fenced diff block per mutant, grouped by target). Generate the table and the diff blocks with a small python script in your scratch path rather than by hand, and check the counts (27 storage, 37 network, 64 total).
   - A map from SPEC 7.4's suggested probes to the mutants that cover them, naming any suggestion not covered.
   - WP-F's own close-out mutant runs and recorded survivors, by reference to ADR-057 and the s3f draft sections, with the survivors listed.
2. docs/DEVICE-TEST-PLAN.md.
   - Everything only a physical device can prove: SPEC 8's four areas, plus every device-only or UNVERIFIED item from the inputs.
   - Each test gets: an id; the requirement IDs; why the simulator or host cannot prove it; the setup (device, OS, build, TestFlight where relevant); the steps; the expected observations; and the pass criteria.
   - Group the tests by area, and keep it practical for a person with one iPhone.
3. docs/RESIDUAL-RISKS.md.
   - Every risk the project accepts at the end of Stage 3, each with: what it is; its classification and the ruling that made it (quote the owner's words where ADR-057 quotes them); its evidence and figures; its likelihood and impact in the field; how it would be noticed; and the trigger for re-opening (docs/REOPEN-WP-F.md for WP-F).
   - It must include:
     - the known misses (the six purge cases, N7's five, APM, item 4 as unproven, the section 7 variants, route A's third shape);
     - the ENOSPC-window known-risk class;
     - f3c's two OPEN shapes, as OPEN, not as known misses;
     - N33's open items;
     - the accepted FAIL (the six and P-13);
     - P-13's no-spare-units margin and its expected failure rate (P1, P2, P7);
     - the RR items the rulings send to the residual risks, for example S3-R24 item 1;
     - every other 'residual-risk' ledger item;
     - ADR-057's Open items.
RULES: Never claim a result you did not see in a cited log or record (G2). Cite file:line or the record for every figure. Keep the house style of docs/DECISIONS.md: compact, precise, no marketing. Do not create VERIFICATION.md (the orchestrator writes it after Stage 5's --full).
Commit the three files on wp/s5docs in up to three imperative commits, each message ending with the line "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"; leave the worktree clean.`

const FIX_SCHEMA = { type: 'object', properties: {
  summary: { type: 'string' }, commits: { type: 'array', items: { type: 'string' } },
  counts: { type: 'string', description: 'mutant counts, test counts, risk counts as written' },
  not_done: { type: 'array', items: { type: 'string' } },
}, required: ['summary', 'commits', 'counts', 'not_done'] }
const VERIFY_SCHEMA = { type: 'object', properties: {
  issues: { type: 'array', items: { type: 'object', properties: {
    blocking: { type: 'boolean' }, doc: { type: 'string' }, location: { type: 'string' }, problem: { type: 'string' }, fix: { type: 'string' },
  }, required: ['blocking', 'doc', 'location', 'problem', 'fix'] } },
  status: { type: 'string' },
}, required: ['issues', 'status'] }

const verifyPrompt = (prev) => `TASK: independently verify three new Stage 5 documents on branch wp/s5docs: docs/MUTATION-PROBES.md, docs/DEVICE-TEST-PLAN.md and docs/RESIDUAL-RISKS.md. You did NOT write them (CLAUDE.md P4). Do not modify or commit anything; leave git status unchanged.
${COMMON('.verify-s5docs')}
THE WRITER'S TASK WAS:
${TASK}
${INPUTS}
Check against the inputs, with evidence. The following are blocking:
- a missing mutant;
- a wrong outcome or wrong killing test;
- a mutant count that is not 27 + 37 = 64, or a survivor whose post-merge kill is missing;
- a risk from ADR-057's known misses, known risks, accepted FAIL, f3c, N33 or Open that RESIDUAL-RISKS omits or misclassifies, or any changed owner classification;
- a missing SPEC 8 device area;
- a figure or claim that no record supports (G2).
Spot-check at least 10 diff blocks against their diff files and at least 10 killing tests against the hunt JSON or the re-check summary.
${prev ? 'Also confirm these previous issues are fixed:\n' + JSON.stringify(prev, null, 1) : ''}
Return structured issues (blocking vs non-blocking) and a status paragraph.`

phase('Write')
const out = { rounds: [] }
let prev = null
for (let round = 1; round <= 2; round++) {
  const extra = prev ? '\nAn independent verifier reports these issues (JSON). Fix every blocking one, then the clearly right non-blocking ones, and commit:\n' + JSON.stringify(prev, null, 1) : ''
  const w = await agent(`TASK: Stage 5 documents on branch wp/s5docs.\n${COMMON('.build-s5docs')}\n${INPUTS}\n${TASK}${extra}\nReturn the structured report.`,
    { label: 'write:' + round, phase: 'Write', schema: FIX_SCHEMA })
  log('write ' + round + ': ' + (w ? w.commits.length + ' commits; ' + w.counts : 'NO RESULT'))
  const v = await agent(verifyPrompt(prev), { label: 'verify:' + round, phase: 'Verify', schema: VERIFY_SCHEMA })
  const blocking = v ? v.issues.filter(i => i.blocking) : []
  log('verify ' + round + ': ' + blocking.length + ' blocking / ' + (v ? v.issues.length : '?'))
  out.rounds.push({ round, write: w, status: v && v.status, issues: v ? v.issues : null })
  if (v && !blocking.length) break
  prev = v ? v.issues : prev
}
return out
