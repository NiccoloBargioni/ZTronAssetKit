export const meta = {
  name: 'assetkit-stage2-l3-close',
  description: 'ZTronAssetKit Stage 2 L3 close-out: fix the remaining WP-C findings and apply the orchestrator rulings (CCR-1, CCR-2, OI-1), two-lens verification, weekly-usage stop',
  phases: [
    { title: 'Fix', detail: 'WP-C fixer in wp/c' },
    { title: 'Verify', detail: 'requirements/tests and correctness verifiers' },
  ],
}

const ROOT = '/Users/admin/Documents/ZTronAssetKit'
const STOP = args.usageStop
let stopped = null
const gate = async (tag) => {
  if (stopped) return false
  const r = await agent('Do exactly this and nothing else: use ToolSearch with query "select:mcp__ccd_session_mgmt__get_usage", call mcp__ccd_session_mgmt__get_usage with no arguments, and return the "Weekly · all models" percentUsed as percent (use -1 if the tool is unavailable). Do not read or modify any file.', { label: 'usage:' + tag, model: 'haiku', effort: 'low', schema: { type: 'object', properties: { percent: { type: 'number' } }, required: ['percent'] } })
  const p = r ? r.percent : -1
  log('weekly usage before ' + tag + ': ' + p + '%')
  if (p >= STOP) { stopped = { before: tag, percent: p }; return false }
  return true
}
const SIM = { fix: '897F9D8D-B10D-4D91-8E22-417A2B9D70AA', reqs: '6BE15CAF-7E02-4060-9338-9DAC025EDF0B', correct: '5B940E6E-490F-4E9E-A917-A6456A18225E' }

const COMMON = (S, sim) => `Repository ${ROOT}; your worktree ${ROOT}/.worktrees/c (branch wp/c, based on tag l3-base). cd into the worktree for EVERY command; never edit outside it. YOUR scratch path is ${S} (and ${S}-perf, ${S}-tsan, ${S}/xcode, ${S}/xcode-sim, ${S}/tmp for TMPDIR, the module cache and LLVM_PROFILE_FILE); every scratch file goes there - never the session scratchpad, /tmp, or another agent's .build-* directory. Never run 'xcodebuild -list'. YOUR simulator is ${sim} (iOS 27.0): use only it, never the owner's booted iPhone 17, never create/erase/delete simulators, shut it down when you finish; its device container is the one owner-accepted write outside the repository.
Owner directives: standalone package; ../ZTronCarouselCore and ../ZTronCarousel are read-only; iOS 15.0 / macOS 12.0 floors. Never edit Scripts/, SPEC.md, PROMPT.md, CLAUDE.md, KICKOFF-README.md, docs/ARCHITECTURE.md, docs/DECISIONS.md, docs/TRACEABILITY.md, Package.swift or any *ContractTests.swift. Never run an unscoped pkill/killall.
TOKEN DISCIPLINE: logs to your scratch path, read summary lines only; read large documents by section; never re-read an unchanged file; batch commands. Never lowers the bar.
Run swift / xcodebuild with the Bash tool's dangerouslyDisableSandbox: true. Commands (from the worktree):
  SWIFTPM_SCRATCH=${S} bash Scripts/verify.sh --quick
  swift build -c release --scratch-path ${S} -Xswiftc -warnings-as-errors
  python3 Scripts/gates.py unsafe --sources "$PWD/Sources" --audit docs/UNSAFE-AUDIT.md && python3 Scripts/gates.py docs --sources "$PWD/Sources"
  storage tests x3: swift test --scratch-path ${S} --skip Benchmarks --filter ZTronAssetStorageTests; TSan once: swift test --scratch-path ${S}-tsan --sanitize=thread --skip Benchmarks --filter ZTronAssetStorageTests
  coverage: swift test --scratch-path ${S} --enable-code-coverage --skip Benchmarks; xcrun llvm-cov export -summary-only -instr-profile ${S}/out/Products/Debug/codecov/default.profdata <first .xctest binary> -object <others> > ${S}/cov.json; python3 Scripts/gates.py coverage --json ${S}/cov.json (ZTronAssetStorage >= 90%)
  iOS: xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath ${S}/xcode build OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet
  iOS Simulator tests (docs/adr-drafts/ios.md convention): caffeinate -i xcodebuild test -scheme ZTronAssetKit -destination 'platform=iOS Simulator,id=${sim}' -derivedDataPath ${S}/xcode-sim -skip-testing:ZTronAssetKitBenchmarks OTHER_SWIFT_FLAGS='-warnings-as-errors' > ${S}/sim.log 2>&1; xcrun xcresulttool get test-results summary --path <bundle under ${S}/xcode-sim/Logs/Test>
If you ran --gates-only or --full, restore docs/TRACEABILITY.md.`

const RULINGS = `ORCHESTRATOR RULINGS (record each in docs/adr-drafts/c.md as "Orchestrator ruling (L3 close-out)"; the authorised edits to WP-B files are limited to exactly what is named):
(R1) CCR-2 is merge-gating and APPROVED in both halves: WP-C clears state.core.orphans[key] in the actor turn that submits a sweep of that key (a §1.1 rule-1 exemption for this single write); and in WP-B's Store/AssetStore+Apply.swift adoptKnownBlob 'case nil' a launch orphan binds only while state.core.orphans[key] still equals the confirmation the plan saw (edit of that function authorised). Remove the withKnownIssue from 'R-CLN-2: orphan GC never sweeps a launch orphan that a running apply...' so the test asserts the invariant; it must fail before the fix and pass after.
(R2) CCR-1 is APPROVED: add the package primitive doomOrphans(_ orphans: [BlobKey: Int64]) -> [BlobKey] to Store/StoreInternals.swift (additive; for each key unknown to blobTable and not in publishing it inserts a .doomed(.unreferenced) entry with its size, eligible per the deletion grace, so the reaper unlinks it under I-3 and a publication or adoption rescues it), and switch orphan GC to doom instead of unlinking. Use it for C-13 too if cheap (an undecodable legacy manifest keeps its files as protected orphans); otherwise keep C-13 as is.
(R3) OI-1 is a WP-B bug, fix APPROVED in WP-B's apply plan (ApplyPlan / adoptKnownBlob, edit authorised): records absent(.evicted) are adopted only by the launch adoption, never by a later apply, so an apply within the deletion grace cannot undo an eviction. Failing test first (the oracle without the immediate settleDeletions after evict, or a direct test), then the fix; then drop the oracle's workaround.
(R4) C2 at the 10,000-record benchmark scale is mandatory: deep verification's due list and purge's selection/sort are built in bulk units from value snapshots (as evictionCandidatesOffActor does), with per-key re-validation on the actor afterwards; purge bumps purgeEpoch and clears the stamp synchronously before any await. The secondary O(N) stretches (orphan re-check per removal unit, storageReport tail, referenceIndex after eviction chunks and per quarantined blob, the first records copy) must also stay <= 10 ms at 10,000 records; at maxEntries (100,000) make each O(1) per candidate or move it off the actor where cheap, and record any that remain with measurements. Add a C2 measurement for these paths to the existing C2 probe pattern of WP-B (thread-CPU of the actor stretch, release) and record the figures.
(R5) Deviations C-12 (checksum-less legacy files without a local checksum are re-downloaded), C-13, C-14 (a legacy root on another volume is dropped) and C-15 (phase 4 keeps unattributable files and a non-empty root) are accepted as deviations from R-STO-11 / store.md §7 and will be tagged NEEDS-HUMAN-REVIEW by the orchestrator; keep them documented. C-6 (no Apple-tier ranking in eviction) is accepted as documented.`

const FOCUS = `Findings: ${ROOT}/.build-orchestrator/l3-remaining-c.json (round 3; read all).
Fix ALL FIVE blocking findings (failing test committed on its own first for each bug, then the fix): (1) the S2-06 regression test must make pending reclaim decide the second eviction run (the verifier's reserve-driven example) and must fail against the 'effective = max(0, available)' mutant; (2) legacy transient I/O: readLegacyFile returns a distinct .failed on itemInfo/read errors (keep .unusable for not-a-regular-file / over the size limit), listLegacyTree reports a failed listing distinctly, and any failure in phase 1 decides nothing (as C-13 already does for the root stat) - never commit a plan that would make phase 4 delete files it could not read; regression test with FakeFileSystem EIO on the manifest read and on a directory listing; (3) the stale synced claim: record the legacy manifest digest at phase 1 and migrate the stamp in finishLegacyMigration only when appliedManifest.digest still equals it (otherwise leave syncDue set) - regression test from ZProbe-stamp; (4)+(5) C2 per ruling R4.
Then apply rulings R1-R3, and the clearly-right non-blocking items: the symlink overlap guard compares resolved identities (add the '/A -> R' placement to LegacyRootTests.overlappingRootSkipped); readLegacyFile/listLegacyTree re-check the phase (checkLive) after each unit and the phase-4 caller checks cancellation; add .legacyMigration and .deepVerification cases to the R-CLN-12 idempotency suite; paste the missing iOS Simulator evidence line in c.md.`

const FIX_SCHEMA = { type: 'object', properties: {
  summary: { type: 'string' }, commits: { type: 'array', items: { type: 'string' } },
  quick_line: { type: 'string' }, gates_lines: { type: 'string' }, coverage_line: { type: 'string' }, sim_line: { type: 'string' }, c2_figures: { type: 'string' },
  declined: { type: 'array', items: { type: 'string' } }, contract_changes_made: { type: 'array', items: { type: 'string' } },
}, required: ['summary', 'commits', 'quick_line', 'gates_lines', 'sim_line', 'declined', 'contract_changes_made'] }
const VERIFY_SCHEMA = { type: 'object', properties: {
  issues: { type: 'array', items: { type: 'object', properties: {
    blocking: { type: 'boolean' }, area: { type: 'string' }, location: { type: 'string' }, problem: { type: 'string' }, fix: { type: 'string' },
  }, required: ['blocking', 'area', 'location', 'problem', 'fix'] } },
  status: { type: 'string' }, evidence: { type: 'string' },
}, required: ['issues', 'status', 'evidence'] }

const fixPrompt = (cycle, extra) => `TASK: Level 3 close-out fix (cycle ${cycle}) for WP-C (storage integrity, cleanup, eviction, legacy migration) on branch wp/c.
${COMMON('.build-c', SIM.fix)}
Read CLAUDE.md, docs/ARCHITECTURE.md sections 1.1, 1.2, 4.4-4.7, 10.1 and 14 (by section), docs/adr-drafts/c.md, docs/adr-drafts/b.md for the WP-B code you touch, and the code the findings cite.
${RULINGS}
${FOCUS}
${extra || ''}
Rules: SPEC 7.2 test rules; 0 unsafe escapes; docs 100%; every await inside an actor carries a // REENTRANCY: comment whose re-validation happens (propose c-n rows); blocking work only in BlockingExecutor units; no public signature change; package additions only as ruled. Record every disposition in docs/adr-drafts/c.md. Re-run --quick, the release build, gates, coverage, the storage tests 3 times and once under TSan, the iOS build and the iOS Simulator tests. Commit on wp/c in small imperative commits (failing tests on their own first), each message ending with the line "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"; leave the worktree clean. Return the structured report with pasted evidence.`

const LENS = {
  reqs: `LENS: requirements, tests and gates. (1) Every blocking finding and ruling is done; for each test-strength item re-apply the original defect as a mutant in a scratch copy and show the test now FAILS against it (S2-06 mutant; the withKnownIssue removal; OI-1); (2) ownership: git diff --name-only l3-base...HEAD stays within WP-C's §1.2 files plus exactly the WP-B edits the rulings authorise (AssetStore+Apply.swift adoptKnownBlob/ApplyPlan, StoreInternals.swift doomOrphans) and the four WP-B Core test files the author already touched; any other WP-B change or any public signature change is blocking; (3) no regression: --quick green, release and iOS builds green, storage tests 3 consecutive passes and once under TSan with no report, unsafe 0, docs 100%, Storage coverage >= 90% with WP-C files >= 90%, and all tests pass on YOUR iOS Simulator; (4) the R-CLN-12 suite now covers legacy migration and deep verification; (5) the C2 figures are measured and recorded and every path is <= 10 ms at 10,000 records. Any flake is blocking.`,
  correct: `LENS: correctness and concurrency. (1) Reproduce every round-3 correctness defect (legacy transient I/O timeline, ZProbe-stamp, the C2 stretches, the symlink overlap, CCR-2's ZProbe4, OI-1) against the new code with your OWN probes under your scratch path; (2) review every close-out commit for new bugs: I-1..I-5 and crash consistency at each file-system step of eviction, orphan dooming and the four legacy phases; actor reentrancy (REENTRANCY comments and their re-validation, especially around the new off-actor snapshots: what changed between snapshot and apply), cancellation, overflow, unbounded growth; (3) hunt once more in WP-C's production code for bugs of the classes earlier rounds kept finding (legacy migration under faults and races, cleanup racing apply/publication, C2). PROVE each suspected bug with a failing probe or exact timeline: proven bugs are blocking; unproven suspicions non-blocking.`,
}
const verifyPrompt = (lens, cycle, prev) => `TASK: Independent Level 3 close-out verification (cycle ${cycle}, ${lens}) of WP-C on branch wp/c. You did NOT write this code (CLAUDE.md P4). Do NOT modify or commit anything; scratch only under your scratch path; leave git status unchanged.
${COMMON('.build-verify-c-close-' + lens + cycle, SIM[lens])}
Read ${ROOT}/.build-orchestrator/l3-remaining-c.json, docs/adr-drafts/c.md (dispositions and rulings), CLAUDE.md, docs/ARCHITECTURE.md sections 1.1, 1.2, 4.4-4.7, 10.1 (by section), and the close-out commits.
${RULINGS}
${LENS[lens]}
${prev ? 'Also confirm these issues from the previous verification are fixed (reproduce each):\n' + JSON.stringify(prev, null, 1) : ''}
Return structured issues (blocking vs non-blocking) with file:line and a concrete fix, a status paragraph, and evidence lines.`

const verifyBoth = async (cycle, prev) => {
  if (!(await gate('verify:' + cycle))) return null
  const rs = (await parallel(['reqs', 'correct'].map(l => () => agent(verifyPrompt(l, cycle, prev), { label: 'verify:c:' + l + ':c' + cycle, phase: 'Verify', schema: VERIFY_SCHEMA }).then(r => r ? { lens: l, ...r } : null)))).filter(Boolean)
  return { issues: rs.flatMap(r => r.issues.map(x => ({ lens: r.lens, ...x }))), status: rs.map(r => ({ lens: r.lens, status: r.status })), missing: 2 - rs.length }
}

phase('Fix')
const out = { cycles: [] }
let prevIssues = null
// args.fromCycle / args.maxCycle let a new session continue (e.g. fromCycle 2 with args.previousIssues = the cycle-1
// findings and args.verifyFirst = true to verify the committed cycle-2 fixes before fixing again).
const FROM = args.fromCycle || 1, MAXC = args.maxCycle || 2
if (args.previousIssues) prevIssues = args.previousIssues
for (let cycle = FROM; cycle <= MAXC; cycle++) {
  if (args.verifyFirst && cycle === FROM) {
    const v0 = await verifyBoth(cycle, prevIssues)
    out.cycles.push({ cycle, fix: null, verify: v0 })
    if (!v0) break
    log('WP-C close-out verify ' + cycle + ' (committed fixes): ' + v0.issues.filter(i => i.blocking).length + ' blocking / ' + v0.issues.length)
    if (!v0.issues.filter(i => i.blocking).length && !v0.missing) break
    prevIssues = v0.issues
    continue
  }
  if (!(await gate('fix:' + cycle))) break
  const extra = prevIssues ? 'The previous close-out verification reports these issues (JSON) - fix every blocking one first (failing test committed first), then the clearly-right non-blocking ones:\n' + JSON.stringify(prevIssues, null, 1) : ''
  const fx = await agent(fixPrompt(cycle, extra), { label: 'fix:c:c' + cycle, phase: 'Fix', schema: FIX_SCHEMA })
  log('WP-C close-out fix ' + cycle + ': ' + (fx ? fx.quick_line : 'NO RESULT'))
  const v = await verifyBoth(cycle, prevIssues)
  const entry = { cycle, fix: fx && { summary: fx.summary, quick: fx.quick_line, sim: fx.sim_line, c2: fx.c2_figures, declined: fx.declined, contract: fx.contract_changes_made }, verify: v }
  out.cycles.push(entry)
  if (!v) break
  const blocking = v.issues.filter(i => i.blocking)
  log('WP-C close-out verify ' + cycle + ': ' + blocking.length + ' blocking / ' + v.issues.length)
  if (!blocking.length && !v.missing) break
  prevIssues = v.issues
}
out.stopped = stopped
return out