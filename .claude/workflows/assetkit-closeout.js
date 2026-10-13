export const meta = {
  name: 'assetkit-closeout',
  description: 'ZTronAssetKit level close-out for one work package: fix -> two-lens independent verification cycles until 0 blocking, with orchestrator rulings from a file, close-out bar, per-role models and a weekly-usage stop',
  phases: [
    { title: 'Fix', detail: 'one fixer in the WP worktree' },
    { title: 'Verify', detail: 'requirements/tests and correctness/concurrency verifiers' },
  ],
}

// args (all paths absolute):
//   wp: 'f'                      work package key; worktree .worktrees/<wp>, branch wp/<wp>
//   name: 'WP-F (sync engine)'   display name
//   base: 'l3-merged'            base tag of the level
//   target, testTarget           e.g. 'ZTronAssetSync', 'ZTronAssetSyncTests'
//   sections                     ARCHITECTURE sections to read, e.g. 'sections 1.1, 1.2, 7, 10.2, 13.5, 14'
//   coverageMin                  90 for Storage/Sync, 70 otherwise
//   rulingsFile                  orchestrator rulings for this close-out (authoritative; may authorise edits outside the WP)
//   findingsFile                 the verification findings this cycle starts from (JSON)
//   focus                        short orchestrator focus text for the fixer (optional)
//   bar: 'strict' | 'converge'   close-out bar (see CONVERGE)
//   models: { fix, verify }      'opus' | 'fable' | 'sonnet' (optional)
//   sims: { fix, reqs, correct } simulator UDIDs (never the owner's booted iPhone 17)
//   fromCycle, maxCycle, verifyFirst, usageStop
const ROOT = '/Users/admin/Documents/ZTronAssetKit'
const A = args
const STOP = A.usageStop === undefined ? 101 : A.usageStop
const MODELS = A.models || {}
const withModel = (role, opts) => MODELS[role] ? Object.assign({}, opts, { model: MODELS[role] }) : opts
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

const COMMON = (S, sim) => `Repository ${ROOT}; your worktree ${ROOT}/.worktrees/${A.wp} (branch wp/${A.wp}, based on tag ${A.base}). cd into the worktree for EVERY command; never edit outside it. YOUR scratch path is ${S} (and ${S}-perf, ${S}-tsan, ${S}/xcode, ${S}/xcode-sim, ${S}/tmp for TMPDIR, the module cache and LLVM_PROFILE_FILE); every scratch file goes there - never the session scratchpad, /tmp, or another agent's .build-* directory. Never run 'xcodebuild -list'. YOUR simulator is ${sim} (iOS 27.0): use only it, never the owner's booted iPhone 17, never create/erase/delete simulators, shut it down when you finish; its device container is the one owner-accepted write outside the repository (ADR-051).
Owner directives: standalone package; ../ZTronCarouselCore and ../ZTronCarousel are read-only; iOS 15.0 / macOS 12.0 floors. Never edit Scripts/, SPEC.md, PROMPT.md, CLAUDE.md, KICKOFF-README.md, docs/ARCHITECTURE.md, docs/DECISIONS.md, docs/TRACEABILITY.md, docs/ORCHESTRATION.md, Package.swift or any *ContractTests.swift unless the rulings authorise that exact edit. Never run an unscoped pkill/killall.
TOKEN DISCIPLINE: logs to your scratch path, read summary lines only; read large documents by section; never re-read an unchanged file; batch commands. Never lowers the bar.
Run swift / xcodebuild with the Bash tool's dangerouslyDisableSandbox: true. Commands (from the worktree):
  SWIFTPM_SCRATCH=${S} bash Scripts/verify.sh --quick
  swift build -c release --scratch-path ${S} -Xswiftc -warnings-as-errors
  python3 Scripts/gates.py unsafe --sources "$PWD/Sources" --audit docs/UNSAFE-AUDIT.md && python3 Scripts/gates.py docs --sources "$PWD/Sources"
  ${A.testTarget} x3: swift test --scratch-path ${S} --skip Benchmarks --filter ${A.testTarget}; TSan once: swift test --scratch-path ${S}-tsan --sanitize=thread --skip Benchmarks --filter ${A.testTarget}
  coverage: swift test --scratch-path ${S} --enable-code-coverage --skip Benchmarks; xcrun llvm-cov export -summary-only -instr-profile ${S}/out/Products/Debug/codecov/default.profdata <first .xctest binary> -object <others> > ${S}/cov.json; python3 Scripts/gates.py coverage --json ${S}/cov.json (${A.target} >= ${A.coverageMin || 70}%)
  iOS: xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath ${S}/xcode build OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet
  iOS Simulator tests (ADR-051 / docs/adr-drafts/ios.md item 2): caffeinate -i xcodebuild test -scheme ZTronAssetKit -destination 'platform=iOS Simulator,id=${sim}' -derivedDataPath ${S}/xcode-sim -skip-testing:ZTronAssetKitBenchmarks -collect-test-diagnostics never OTHER_SWIFT_FLAGS='-warnings-as-errors' > ${S}/sim.log 2>&1; xcrun xcresulttool get test-results summary --path <bundle under ${S}/xcode-sim/Logs/Test>
  benchmarks the WP owns (release): swift test -c release --scratch-path ${S}-perf -Xswiftc -enable-testing --filter Benchmarks (on a loaded host, report load averages; budget misses caused only by load are not blocking)
If you ran --gates-only or --full, restore docs/TRACEABILITY.md.`

const CONVERGE = `CLOSE-OUT BAR (owner): converge. First confirm that every issue the previous verification reported is fixed (reproduce each with your own probe or mutant) and re-run every gate; a regression introduced by the fixes is blocking. A NEW finding is blocking only if it breaks a SPEC invariant (I-1..I-5) or violates a SPEC MUST requirement, loses or corrupts data, crashes, deadlocks or leaks a task, leaks a secret, breaks C2 at the 10,000-record reference scale, makes a required gate or test fail (including on the iOS Simulator), or shows that a required requirement test does not genuinely verify its requirement (CLAUDE.md G4). Report every other new finding as NON-blocking with its probe or timeline and the area label prefixed 'stage3:' - it goes to Stage 3 hardening.`

const FIX_SCHEMA = { type: 'object', properties: {
  summary: { type: 'string' }, commits: { type: 'array', items: { type: 'string' } },
  quick_line: { type: 'string' }, gates_lines: { type: 'string' }, coverage_line: { type: 'string' }, sim_line: { type: 'string' },
  declined: { type: 'array', items: { type: 'string' } }, contract_changes_made: { type: 'array', items: { type: 'string' } },
}, required: ['summary', 'commits', 'quick_line', 'gates_lines', 'sim_line', 'declined', 'contract_changes_made'] }
const VERIFY_SCHEMA = { type: 'object', properties: {
  issues: { type: 'array', items: { type: 'object', properties: {
    blocking: { type: 'boolean' }, area: { type: 'string' }, location: { type: 'string' }, problem: { type: 'string' }, fix: { type: 'string' },
  }, required: ['blocking', 'area', 'location', 'problem', 'fix'] } },
  status: { type: 'string' }, evidence: { type: 'string' },
}, required: ['issues', 'status', 'evidence'] }

const fixPrompt = (cycle, prev) => `TASK: Close-out fix (cycle ${cycle}) for ${A.name} on branch wp/${A.wp}.
${COMMON('.build-' + A.wp, A.sims.fix)}
Read CLAUDE.md, docs/ARCHITECTURE.md ${A.sections} (by section), docs/adr-drafts/${A.wp}.md, the ORCHESTRATOR RULINGS in ${A.rulingsFile} (authoritative; record each in docs/adr-drafts/${A.wp}.md as "Orchestrator ruling (close-out)"), and the code the findings cite.
FINDINGS TO FIX: ${prev ? JSON.stringify(prev) : 'read ' + A.findingsFile + ' (all issues)'}
${A.focus || ''}
Fix every blocking finding first (failing test committed on its own, then the fix, CLAUDE.md P3), then the clearly-right non-blocking ones${A.bar === 'converge' ? ' (items labelled stage3: are recorded in the ADR draft for Stage 3, not fixed now)' : ''}. Rules: SPEC 7.2 test rules; new tests follow the iOS gating convention (ADR-051); 0 unsafe escapes; docs 100%; every await inside an actor carries a // REENTRANCY: comment whose re-validation happens (propose rows); blocking work only in BlockingExecutor units; write only ${A.name}'s files (ARCHITECTURE 1.2) plus edits the rulings authorise; no contract signature change unless ruled. Record every disposition in docs/adr-drafts/${A.wp}.md. Re-run --quick, the release build, gates, coverage, the ${A.testTarget} tests 3 times and once under TSan, the iOS build and the iOS Simulator tests. Commit on wp/${A.wp} in small imperative commits, each message ending with the line "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"; leave the worktree clean. Return the structured report with pasted evidence.`

const LENS = {
  reqs: `LENS: requirements, tests and gates. (1) Every blocking finding is fixed; for each test-strength item re-apply the original defect as a mutant in a scratch copy and show the test now FAILS against it; (2) ownership: git diff --name-only ${A.base}...HEAD stays within ${A.name}'s ARCHITECTURE 1.2 files plus edits the rulings authorise; any other change, or a contract signature change not ruled, is blocking; (3) no regression: --quick green, release and iOS builds green, ${A.testTarget} 3 consecutive passes and once under TSan with no report, unsafe 0, docs 100%, ${A.target} coverage >= ${A.coverageMin || 70}%, and every test passes on YOUR iOS Simulator; (4) the rulings were applied and recorded. Any flake is blocking.`,
  correct: `LENS: correctness and concurrency. (1) Reproduce every previously blocking correctness defect against the new code with your OWN probes under your scratch path; (2) review every close-out commit for new bugs: actor reentrancy (REENTRANCY comments and their re-validation), cancellation leaks or double resumes, races between concurrent operations, unbounded growth, overflow on external values, C2 at 10,000 records, iOS 15 availability, crash consistency where the WP touches the store; (3) ${A.bar === 'converge' ? 'look for regressions the fixes introduced' : 'hunt once more for bugs of the classes earlier rounds kept finding'}. PROVE each suspected bug with a failing probe or exact timeline: proven bugs are blocking; unproven suspicions non-blocking.`,
}
const verifyPrompt = (lens, cycle, prev) => `TASK: Independent close-out verification (cycle ${cycle}, ${lens}) of ${A.name} on branch wp/${A.wp}. You did NOT write this code (CLAUDE.md P4). Do NOT modify or commit anything; scratch only under your scratch path; leave git status unchanged.
${COMMON('.build-verify-' + A.wp + '-c' + cycle + '-' + lens, A.sims[lens])}
Read CLAUDE.md, ${A.rulingsFile}, docs/adr-drafts/${A.wp}.md (dispositions and rulings), docs/ARCHITECTURE.md ${A.sections} (by section), the SPEC requirements in scope, and the close-out commits.
${LENS[lens]}
${prev ? 'The previous verification reported these issues (JSON); confirm each blocking one is fixed (reproduce it):\n' + JSON.stringify(prev) : 'The findings this close-out started from are in ' + A.findingsFile + '; confirm each blocking one is fixed (reproduce it).'}
${A.bar === 'converge' ? CONVERGE : ''}
Return structured issues (blocking vs non-blocking) with file:line and a concrete fix, a status paragraph, and evidence lines.`

const verifyBoth = async (cycle, prev) => {
  if (!(await gate('verify:' + cycle))) return null
  const rs = (await parallel(['reqs', 'correct'].map(l => () => agent(verifyPrompt(l, cycle, prev), withModel('verify', { label: 'verify:' + A.wp + ':' + l + ':c' + cycle, phase: 'Verify', schema: VERIFY_SCHEMA })).then(r => r ? { lens: l, ...r } : null)))).filter(Boolean)
  return { issues: rs.flatMap(r => r.issues.map(x => ({ lens: r.lens, ...x }))), status: rs.map(r => ({ lens: r.lens, status: r.status })), missing: 2 - rs.length }
}

phase('Fix')
const out = { cycles: [] }
let prev = null
const FROM = A.fromCycle || 1, MAXC = A.maxCycle || 4
for (let cycle = FROM; cycle <= MAXC; cycle++) {
  if (A.verifyFirst && cycle === FROM) {
    const v0 = await verifyBoth(cycle, null)
    out.cycles.push({ cycle, fix: null, verify: v0 })
    if (!v0) break
    log(A.name + ' verify ' + cycle + ' (committed fixes): ' + v0.issues.filter(i => i.blocking).length + ' blocking / ' + v0.issues.length)
    if (!v0.issues.filter(i => i.blocking).length && !v0.missing) break
    prev = v0.issues
    continue
  }
  if (!(await gate('fix:' + cycle))) break
  const fx = await agent(fixPrompt(cycle, prev), withModel('fix', { label: 'fix:' + A.wp + ':c' + cycle, phase: 'Fix', schema: FIX_SCHEMA }))
  log(A.name + ' fix ' + cycle + ': ' + (fx ? fx.quick_line : 'NO RESULT'))
  const v = await verifyBoth(cycle, prev)
  out.cycles.push({ cycle, fix: fx && { summary: fx.summary, quick: fx.quick_line, sim: fx.sim_line, declined: fx.declined, contract: fx.contract_changes_made }, verify: v })
  if (!v) break
  const blocking = v.issues.filter(i => i.blocking)
  log(A.name + ' verify ' + cycle + ': ' + blocking.length + ' blocking / ' + v.issues.length)
  if (!blocking.length && !v.missing) break
  prev = v.issues
}
out.stopped = stopped
return out
