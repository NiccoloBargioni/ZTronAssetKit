export const meta = {
  name: 'assetkit-wp-i-docs',
  description: 'ZTronAssetKit WP-I: README with a compiled 20-line quick start and docs consistency, verified by accuracy and usability lenses with fix rounds and a weekly-usage stop',
  phases: [
    { title: 'Write', detail: 'one docs author in the WP-I worktree' },
    { title: 'Verify', detail: 'accuracy and usability verifiers, independent of the author' },
    { title: 'Fix', detail: 'fix rounds until no blocking issue remains' },
  ],
}

const ROOT = '/Users/admin/Documents/ZTronAssetKit'
const A = args || {}
const WT = ROOT + '/.worktrees/' + (A.worktree || 'i')
const BASE = A.base || 'l5-merged'
const STOP = A.usageStop === undefined ? 101 : A.usageStop
const MAXR = A.maxRounds || 6
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

const OWN = `OWNERSHIP (ARCHITECTURE section 1.2, row "end | I docs"): WP-I writes exactly README.md at the repository root (new) and files under docs/ EXCEPT docs/ARCHITECTURE.md, docs/DECISIONS.md, docs/TRACEABILITY.md, docs/ORCHESTRATION.md, docs/MIGRATION.md (WP-K's), docs/adr-drafts/** other than docs/adr-drafts/i.md, and the Stage 3/5 reports docs/MUTATION-PROBES.md, docs/VERIFICATION.md, docs/DEVICE-TEST-PLAN.md and docs/RESIDUAL-RISKS.md, which must not be created or edited now. No Swift file, no Package.swift, nothing under Scripts/ or Tests/. WP-I's decisions go to docs/adr-drafts/i.md.`

const COMMON = (S) => `Repository ${ROOT}; your worktree ${WT} (branch wp/i, based on tag ${BASE}, the merged end of Stage 2 levels 1-5). cd into the worktree for EVERY command; never edit outside it. Your scratch path is ${S} (with ${S}/tmp for TMPDIR and the Swift module cache); every scratch file goes there - never the session scratchpad, /tmp, or another agent's .build-* directory. Run swift with the Bash tool's dangerouslyDisableSandbox: true. Never run xcodebuild -list; never an unscoped pkill/killall. TOKEN DISCIPLINE: read large documents by section (grep -n '^#' first, then read with offset/limit); redirect build output to a log under your scratch path and read only summary lines; batch commands.
${OWN}
QUICK-START COMPILE CHECK (proves the README's quick start against the public API without touching the repository): create ${S}/qs/Package.swift with "// swift-tools-version: 6.0", platforms .macOS(.v12) and .iOS(.v15), one executable target "QS" depending on .package(path: "${WT}") product "ZTronAssetKit"; copy the README's quick-start code block VERBATIM into ${S}/qs/Sources/QS/main.swift (if the snippet is not top-level code, wrap it minimally and say exactly how); then run: swift build --package-path ${S}/qs --scratch-path ${S}/qs-build -Xswiftc -warnings-as-errors > ${S}/qs.log 2>&1, and read its last lines. It must compile with no warning. Never run it against the network.`

const AUTHOR_SCHEMA = { type: 'object', properties: {
  summary: { type: 'string' }, commits: { type: 'array', items: { type: 'string' } }, files_changed: { type: 'array', items: { type: 'string' } },
  quickstart_code_lines: { type: 'number' }, compile_evidence: { type: 'string' }, link_check: { type: 'string' }, open_issues: { type: 'array', items: { type: 'string' } },
}, required: ['summary', 'commits', 'files_changed', 'quickstart_code_lines', 'compile_evidence', 'link_check', 'open_issues'] }
const VERIFY_SCHEMA = { type: 'object', properties: {
  issues: { type: 'array', items: { type: 'object', properties: {
    blocking: { type: 'boolean' }, area: { type: 'string' }, location: { type: 'string' }, problem: { type: 'string' }, fix: { type: 'string' },
  }, required: ['blocking', 'area', 'location', 'problem', 'fix'] } },
  status: { type: 'string' }, evidence: { type: 'string' },
}, required: ['issues', 'status', 'evidence'] }
const FIX_SCHEMA = { type: 'object', properties: {
  summary: { type: 'string' }, commits: { type: 'array', items: { type: 'string' } }, compile_evidence: { type: 'string' }, link_check: { type: 'string' }, open_issues: { type: 'array', items: { type: 'string' } },
}, required: ['summary', 'commits', 'compile_evidence', 'link_check', 'open_issues'] }

const AUTHOR = `TASK: You are the author of WP-I - documentation - the last Stage 2 work package of ZTronAssetKit (SPEC section 8; PROMPT.md section 5 "I docs"; ARCHITECTURE section 1.2 row "end | I docs").
${COMMON('.build-i')}
Read first: SPEC.md section 8 (Deliverables: "A README.md with a 20-line quick start") and section 4.1 (targets, the single library product); docs/ARCHITECTURE.md section 1 (incl. 1.2), section 8 (the facade), section 5 (snapshot and lookup), section 6 (transport, the background opt-in) as needed; docs/DECISIONS.md: the owner review list, ADR-005 (floors), ADR-026, ADR-027, ADR-033, ADR-037, ADR-044, ADR-047, ADR-048, ADR-051, ADR-054, ADR-055; docs/MIGRATION.md (WP-K's adoption guide: link to it, do not duplicate it); and the public API itself in Sources/ZTronAssetKit and Sources/ZTronAssetModel (read the declarations; never guess a signature or a default).
Deliverables:
(1) README.md at the repository root. Evergreen: no transient project status, dates, run ids or usage figures. Accurate to the merged code and the ADRs. It contains:
 - what the package is (remote-asset delivery and on-device storage lifecycle for ZTronCarousel) and what it is not, in one short paragraph; platforms and toolchain (iOS 15 and macOS 12 floors, Swift 6.3+ toolchain, Swift 6 language mode, strict concurrency); no third-party dependencies; the one library product;
 - installation with SwiftPM as a local path dependency (no published URL exists: do not invent one; say a release would switch to a URL);
 - a QUICK START of at most 20 lines of Swift code (count code lines only) that passes the QUICK-START COMPILE CHECK: build the configuration, create the AssetClient, start it, resolve and look up an asset, drive a prefetch window, and listen to events. Use an obviously fake placeholder for any app key and say that keys come from the app's secure configuration and are never logged (R-SEC-1);
 - core concepts in short sections, each pointing to its ARCHITECTURE section or ADR: configuration knobs (ADR-048); main-actor lookup versus async resolve; prefetch windows (R-CAR-3); the bundle-then-local fallback chain (ADR-037); events and subscribe; retention scope, pins and purgeable caches (ADR-027, ADR-044); ensureAvailable and sync modes; diagnosticReport and logging (ADR-047); shutdown; background transfers as an owner opt-in (ADR-026: the app's attestation and the AppDelegate hook); the Apple-hosted tier and its iOS 26 availability; the reopen after a replaced root (B-15, ADR-054);
 - compatibility with ZTronCarouselCore: the shims in Tests/ZTronAssetCompatibilityTests and docs/MIGRATION.md;
 - building and verifying: the exact commands from CLAUDE.md (the verify.sh modes and SWIFTPM_SCRATCH) and the iOS Simulator requirement (ADR-051);
 - a documentation map: every existing file under docs/ with one line each, naming the authoritative ones (ARCHITECTURE.md, DECISIONS.md) and marking the historical ones (RECON.md, BASELINE.md, docs/design/); point to the NEEDS-HUMAN-REVIEW owner review list in DECISIONS.md.
 No license section: the repository has none, so do not invent one.
(2) Consistency of the docs WP-I owns: where a WP-I-owned file presents as current something the merged code or a later ADR contradicts (for example a Stage 1 design doc), add a one-line status note at its top saying it is historical and naming the authoritative document, rather than rewriting history. List each such change in docs/adr-drafts/i.md.
(3) docs/adr-drafts/i.md: the decisions you took (context, options, decision, consequences), the quick-start compile evidence, and anything left for the orchestrator.
Before handoff: the QUICK-START COMPILE CHECK passes (paste its last lines); python3 Scripts/gates.py docs --sources "$PWD/Sources" still reports 100% (no Swift changed); every relative link in README.md and in each file you changed resolves to an existing path (say how you checked); git diff --name-only ${BASE}...HEAD lists only WP-I files. Commit in small imperative commits, each message ending with the line "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"; leave the worktree clean. Never push; never touch other branches.
Return the structured report.`

const LENSES = [
  { key: 'accuracy', text: `LENS: technical accuracy. Check every factual statement in README.md and in every file changed since ${BASE} against the merged code (public declarations, signatures, defaults and availability in Sources/) and against ARCHITECTURE and the ADRs. Run the QUICK-START COMPILE CHECK yourself from the README text as committed (copy it verbatim) and count its code lines. Confirm: no invented URL, license, version number or API; no secret or real app key; ownership (git diff --name-only ${BASE}...HEAD lists only WP-I files, and no Swift, Package.swift, Scripts/ or Tests/ file changed). BLOCKING: a proven factual error, a quick start that does not compile or has more than 20 code lines, an ownership violation, or a secret. NOT blocking: wording preferences.` },
  { key: 'usability', text: `LENS: usability and completeness for a newcomer and for the app that adopts the package. Walk through the README as a newcomer would: is installation complete and correct; does the quick start show the essential flow (configure, start, resolve and look up, prefetch, events); are the facts an adopting app needs present (the main-actor lookup rule, the background opt-in requirements, the iOS 26 gating of the Apple tier, adoption from ZTronCarouselCore through docs/MIGRATION.md); does every relative link resolve (check each path); is the documentation map complete for the files that exist under docs/; does the README avoid transient status; is it consistent with MIGRATION.md and ARCHITECTURE's terms; are SPEC section 8's README requirements met. BLOCKING: a missing SPEC section 8 element, a broken link, a statement that would mislead an adopter into wrong usage, or an incomplete documentation map. NOT blocking: style.` },
]

const VERIFY = (lens, round, prev) => `TASK: Independent verification (round ${round}, ${lens.key}) of WP-I - documentation - on branch wp/i. You did NOT write it (CLAUDE.md P4). Do NOT modify or commit anything; scratch files only under your scratch path; leave git status unchanged.
${COMMON('.build-verify-i-' + lens.key + '-r' + round)}
Read SPEC.md section 8, docs/ARCHITECTURE.md section 1.2, docs/adr-drafts/i.md, the diff git diff ${BASE}...HEAD, and the sources the documents cite.
${lens.text}
${prev && prev.length ? 'The previous round reported these issues (JSON); confirm each blocking one is fixed and say so in evidence:\n' + JSON.stringify(prev) : ''}
Return structured issues (blocking vs non-blocking) with file:line and a concrete fix, a status paragraph, and evidence lines.`

const FIX = (issues, round) => `TASK: Fix round ${round} for WP-I - documentation - on branch wp/i. Independent verifiers reported these issues (JSON):
${JSON.stringify(issues, null, 1)}
${COMMON('.build-i')}
Read docs/adr-drafts/i.md and the files the issues cite. Fix every blocking issue and every non-blocking one that is clearly right; for an issue you decline, record the reason in docs/adr-drafts/i.md and in open_issues. Re-run the QUICK-START COMPILE CHECK and the link check, keep ownership, commit in small imperative commits each ending with the line "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>", and leave the worktree clean. Return the structured report with evidence.`

phase('Write')
if (!(await gate('author'))) return { stopped }
const author = await agent(AUTHOR, { label: 'author:i', phase: 'Write', schema: AUTHOR_SCHEMA })
if (!author) return { failed: 'author produced no result' }
log('WP-I author: quick start ' + author.quickstart_code_lines + ' code lines; ' + author.compile_evidence.slice(0, 160))
const history = []
let last = null
for (let round = 1; round <= MAXR; round++) {
  phase('Verify')
  if (!(await gate('verify:' + round))) break
  const results = await parallel(LENSES.map(lens => () => agent(VERIFY(lens, round, last ? last.issues : null), { label: 'verify:i:' + lens.key + ':' + round, phase: 'Verify', schema: VERIFY_SCHEMA })))
  const issues = results.map((r, i) => r ? r.issues.map(x => ({ lens: LENSES[i].key, ...x })) : []).flat()
  const status = results.map((r, i) => ({ lens: LENSES[i].key, status: r ? r.status : 'missing' }))
  const blocking = issues.filter(x => x.blocking)
  const missing = results.filter(r => !r).length
  log('WP-I verify round ' + round + ': ' + blocking.length + ' blocking / ' + issues.length + (missing ? ' (' + missing + ' verifier missing)' : ''))
  last = { round, issues, status }
  const entry = { round, blocking: blocking.length, total: issues.length, status }
  history.push(entry)
  if (blocking.length === 0 && missing === 0) break
  if (round === MAXR) break
  phase('Fix')
  if (!(await gate('fix:' + round))) break
  const fix = await agent(FIX(issues, round), { label: 'fix:i:' + round, phase: 'Fix', schema: FIX_SCHEMA })
  entry.fix = fix
  if (fix) log('WP-I fix ' + round + ': ' + fix.compile_evidence.slice(0, 160))
}
return { stopped, author, history, remaining: last ? last.issues : [] }
