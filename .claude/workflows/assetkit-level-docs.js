export const meta = {
  name: 'assetkit-level-docs',
  description: 'ZTronAssetKit level merge documentation: ledger readers per ADR draft, one writer (ADRs, ARCHITECTURE, contract doc comments), independent verifier, fix rounds',
  phases: [
    { title: 'Ledger', detail: 'one reader per ADR draft extracts orchestrator items, checked against the merged code' },
    { title: 'Docs', detail: 'single writer in its own worktree' },
    { title: 'Verify', detail: 'independent verifier; up to two fix rounds' },
  ],
}

// args: { level: 'L3', worktree: 'l3docs', base: '<merged head sha>', drafts: ['c', 'ios'], rulings: '<abs path>',
//         adrs: 'ADR-051 (…) and ADR-052 (…)', amendTargets: '<extra instructions>', usageStop: 101 }
const ROOT = '/Users/admin/Documents/ZTronAssetKit'
const A = args
const STOP = A.usageStop === undefined ? 101 : A.usageStop
let stopped = null
const gate = async (tag) => {
  if (stopped) return false
  if (STOP > 100) return true
  const r = await agent('Do exactly this and nothing else: use ToolSearch with query "select:mcp__ccd_session_mgmt__get_usage", call mcp__ccd_session_mgmt__get_usage with no arguments, and return the "Weekly · all models" percentUsed as percent (use -1 if the tool is unavailable). Do not read or modify any file.', { label: 'usage:' + tag, model: 'haiku', effort: 'low', schema: { type: 'object', properties: { percent: { type: 'number' } }, required: ['percent'] } })
  const p = r ? r.percent : -1
  log('weekly usage before ' + tag + ': ' + p + '%')
  if (p >= STOP) { stopped = { before: tag, percent: p }; return false }
  return true
}

const COMMON = (S) => `Repository ${ROOT}; your worktree ${ROOT}/.worktrees/${A.worktree} (branch wp/${A.worktree}, based on ${A.base}, the merged ${A.level} head of feature/asset-kit). cd into the worktree for EVERY command; never edit outside it. YOUR scratch path is ${S} (${S}/tmp for TMPDIR and the module cache); every scratch file goes there - never the session scratchpad, /tmp, or another agent's .build-* directory. Never run 'xcodebuild -list'.
Owner directives: standalone package; ../ZTronCarouselCore and ../ZTronCarousel are read-only; iOS 15.0 / macOS 12.0 floors. Never edit Scripts/ (incl. quality-gates.json), SPEC.md, PROMPT.md, CLAUDE.md, KICKOFF-README.md, docs/TRACEABILITY.md, docs/ORCHESTRATION.md, Package.swift. Never run an unscoped pkill/killall.
TOKEN DISCIPLINE: read large documents by section (grep -n '^#' first); never re-read an unchanged file; batch commands. Never lowers the bar.
Run swift with the Bash tool's dangerouslyDisableSandbox: true.`

const LEDGER_SCHEMA = { type: 'object', properties: {
  items: { type: 'array', items: { type: 'object', properties: {
    kind: { type: 'string', description: 'architecture-amendment, reentrancy-row, test-assignment, untested-line, decisions-amendment, aav-amendment, contract-doc, contract-ack, needs-human-review, not-verified, later-wp-note, other' },
    target: { type: 'string' }, source: { type: 'string' }, text: { type: 'string' }, code_check: { type: 'string' },
  }, required: ['kind', 'target', 'source', 'text', 'code_check'] } },
  conflicts_with_rulings: { type: 'array', items: { type: 'string' } },
}, required: ['items', 'conflicts_with_rulings'] }
const FIX_SCHEMA = { type: 'object', properties: {
  summary: { type: 'string' }, commits: { type: 'array', items: { type: 'string' } }, gates_lines: { type: 'string' },
  files_changed: { type: 'array', items: { type: 'string' } }, not_applied: { type: 'array', items: { type: 'string' } },
}, required: ['summary', 'commits', 'gates_lines', 'files_changed', 'not_applied'] }
const VERIFY_SCHEMA = { type: 'object', properties: {
  issues: { type: 'array', items: { type: 'object', properties: {
    blocking: { type: 'boolean' }, area: { type: 'string' }, location: { type: 'string' }, problem: { type: 'string' }, fix: { type: 'string' },
  }, required: ['blocking', 'area', 'location', 'problem', 'fix'] } },
  status: { type: 'string' }, evidence: { type: 'string' },
}, required: ['issues', 'status', 'evidence'] }

const ledgerPrompt = (k) => `TASK (read-only): compile the orchestrator ledger for docs/adr-drafts/${k}.md of ${A.level}. Work in ${ROOT} (the main checkout, merged head ${A.base}); do not modify, create or commit any file; no builds.
Read ${A.rulings} first (the orchestrator's rulings win over any draft), then the WHOLE of docs/adr-drafts/${k}.md (by section), and the sections of docs/ARCHITECTURE.md and docs/DECISIONS.md it asks to amend.
Extract EVERY item the draft asks the orchestrator to do or that must land in an orchestrator-owned document: ARCHITECTURE wording amendments (exact section, current text, replacement text), proposed REENTRANCY rows (copy each verbatim; confirm the code cites it: grep -rn 'REENTRANCY' Sources/ for the identifier; list rows the code cites that the draft lacks, and vice versa), new or reassigned tests for later work packages (§11 rows: requirement, WP, exact display name), 'known deliberately untested lines' for §14, amendments to earlier ADRs or to docs/APPLE-API-VERIFICATION.md, contract doc comments that are now stale, contract additions to acknowledge, NEEDS-HUMAN-REVIEW items, 'Not verified' items, and notes later work packages need. For every ARCHITECTURE amendment check the merged code and give the file:line that shows it is true. If the draft contradicts a ruling, list it under conflicts_with_rulings (the ruling wins). Be exhaustive: a missed item leaves a stale document for the next level.`

const TASK = `ORCHESTRATOR-DELEGATED DOCUMENT PASS for ${A.level} (you may edit exactly: docs/DECISIONS.md, docs/ARCHITECTURE.md, docs/APPLE-API-VERIFICATION.md, docs/UNSAFE-AUDIT.md (prose only - the unsafe gate parses it), docs/adr-drafts/*.md (wording fixes only), and /// doc comments ONLY - no declaration, no code line - in Sources/**/*.swift). Inputs: ${A.rulings} (authoritative) and the ledgers below, each checked against the code.
(a) docs/DECISIONS.md: append ${A.adrs} in the style of ADR-049/ADR-050 (compact bullets: Context; Ratified contract changes; Benchmarks where measured; Ratified decisions with NEEDS-HUMAN-REVIEW tags exactly as the rulings mark them (also in each ADR heading and in the owner review list); Assignments to later work packages; REENTRANCY rows; Not verified (by reference to the drafts' sections, with the notable items); Process). The drafts are normative detail by reference. Amend earlier ADRs only by dated amendment bullets.
(b) docs/ARCHITECTURE.md: every architecture-amendment item (mark each changed passage "(${A.adrs.split(' ')[0]})" or the ADR it belongs to), the REENTRANCY rows into §10 (draft identifiers become final numbers), §11 rows for later work packages exactly as the rulings and ledgers name them (WP column set: the level script implements "every row of section 11 whose WP column names X"), §12 regression mappings, §14 untested lines. ${A.amendTargets || ''} Do not change any requirement's meaning beyond what the rulings/ledgers state; never touch SPEC.md.
(c) Stale contract doc comments the ledgers list: fix the /// text so it is true of the merged code (cite file:line in your report).
(d) Resolve every item here; anything you cannot resolve within these files goes into the ADR's "Open" bullet with the reason (keep it short - the goal is that nothing stays open).
Keep each document's style and density.`

const gates = (S) => `Checks: python3 Scripts/gates.py docs --sources "$PWD/Sources"; python3 Scripts/gates.py unsafe --sources "$PWD/Sources" --audit docs/UNSAFE-AUDIT.md; swift build --scratch-path ${S} -Xswiftc -warnings-as-errors; git diff ${A.base} -- Sources must contain only /// (and // comment) lines.`

const apply = (ledgers, extra) => `TASK: ${A.level} merge documentation on branch wp/${A.worktree}.
${COMMON('.build-' + A.worktree)}
Read CLAUDE.md, ${A.rulings}, docs/DECISIONS.md ADR-049 and ADR-050 (style), and only the document sections and code you need.
${TASK}
LEDGERS (JSON):
${JSON.stringify(ledgers)}
${extra || ''}
${gates('.build-' + A.worktree)}
Commit on wp/${A.worktree} in a few imperative commits, each message ending with the line "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"; leave the worktree clean. Return the structured report (in summary, every ledger item applied or deliberately not applied with the reason).`

const verify = (ledgers, prev) => `TASK: Independent verification of the ${A.level} merge documentation on branch wp/${A.worktree}. You did NOT write it (CLAUDE.md P4). Do NOT modify or commit anything; scratch only under your scratch path; leave git status unchanged.
${COMMON('.build-verify-' + A.worktree)}
THE WRITER'S TASK WAS:
${TASK}
LEDGERS (JSON):
${JSON.stringify(ledgers)}
Check with evidence (git diff ${A.base}...HEAD): (1) every ruling in ${A.rulings} and every ledger item is reflected faithfully - a missing item is blocking; (2) every ARCHITECTURE statement and doc comment added or changed is true of the merged code (spot-check each against file:line; a false statement is blocking); (3) NEEDS-HUMAN-REVIEW tags exactly as ruled; (4) no requirement weakened, SPEC/Scripts/TRACEABILITY/ORCHESTRATION untouched, Sources diffs are comment lines only; (5) ADR numbering continuous, earlier ADRs amended by dated bullets only; (6) the §11 rows for later work packages carry the right WP column and exact display names; (7) the REENTRANCY rows match what the code cites (grep -rn 'REENTRANCY' Sources/): rows the code cites but the architecture lacks are blocking. ${gates('.build-verify-' + A.worktree)}
${prev ? 'Also confirm these issues from the previous verification are fixed:\n' + JSON.stringify(prev, null, 1) : ''}
Return structured issues (blocking vs non-blocking), a status paragraph, and evidence.`

phase('Ledger')
const ledgers = []
if (await gate('ledger')) {
  const ls = await parallel(A.drafts.map(k => () => agent(ledgerPrompt(k), { label: 'ledger:' + k, phase: 'Ledger', schema: LEDGER_SCHEMA }).then(r => r ? { draft: k, ...r } : null)))
  ls.filter(Boolean).forEach(l => ledgers.push(l))
  log('ledgers: ' + ledgers.map(l => l.draft + '=' + l.items.length + (l.conflicts_with_rulings.length ? ' (' + l.conflicts_with_rulings.length + ' conflicts)' : '')).join(', '))
}
const out = { ledger_counts: ledgers.map(l => ({ draft: l.draft, items: l.items.length, conflicts: l.conflicts_with_rulings })), rounds: [] }
let prev = null
for (let round = 1; round <= 3 && ledgers.length; round++) {
  if (!(await gate('apply:' + round))) break
  const extra = prev ? 'An independent verifier reports these issues (JSON) - fix every blocking one, then the clearly-right non-blocking ones:\n' + JSON.stringify(prev, null, 1) : ''
  const ap = await agent(apply(ledgers, extra), { label: 'docs:apply:' + round, phase: 'Docs', schema: FIX_SCHEMA })
  log('docs apply ' + round + ': ' + (ap ? ap.files_changed.length + ' files' : 'NO RESULT'))
  if (!(await gate('verify:' + round))) break
  const v = await agent(verify(ledgers, prev), { label: 'docs:verify:' + round, phase: 'Verify', schema: VERIFY_SCHEMA })
  const blocking = v ? v.issues.filter(i => i.blocking) : []
  log('docs verify ' + round + ': ' + blocking.length + ' blocking / ' + (v ? v.issues.length : '?'))
  out.rounds.push({ round, apply: ap && { summary: ap.summary, not_applied: ap.not_applied }, status: v && v.status, issues: v ? v.issues : null })
  if (v && !blocking.length) break
  prev = v ? v.issues : prev
}
out.stopped = stopped
return out
