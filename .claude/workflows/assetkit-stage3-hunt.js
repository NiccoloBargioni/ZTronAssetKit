export const meta = {
  name: 'assetkit-stage3-hunt',
  description: 'ZTronAssetKit Stage 3 discovery: backlog survey, six independent adversarial hunters with failing probes, two mutation-probe agents, and an independent confirmation of every claimed bug, under a weekly-usage stop',
  phases: [
    { title: 'Backlog', detail: 'one reader compiles every open Stage 3 item from the ADRs, drafts, rulings and findings files' },
    { title: 'Hunt', detail: 'six independent hunters (stability, concurrency, crash/fault, security, performance, conformance) prove bugs with failing probes' },
    { title: 'Mutate', detail: 'two independent agents inject >= 20 mutants one at a time and record the test that kills each (SPEC 7.4, Q-8)' },
    { title: 'Confirm', detail: 'one independent confirmer per hunter reproduces or refutes every proven finding' },
  ],
}

// args:
//   base: 's3-base'              tag every agent works from (read-only on the repository)
//   usageStop: 65                weekly all-models % at which no new agent starts (in-flight agents finish)
//   pool: 4                      heavy agents (each builds the package) at once; PROMPT 3 allows <= 6, the host has 8 cores
//   sim: '<udid>'                the stability hunter's simulator (never the owner's iPhone 17)
//   models: { hunt, confirm, mutate, backlog }   'opus' | 'fable' | 'sonnet' (hunt/confirm default: session model)
//   only: ['crash', ...]         optional subset of lens / group keys, for a re-run
const ROOT = '/Users/admin/Documents/ZTronAssetKit'
const A = args || {}
const BASE = A.base || 's3-base'
const STOP = A.usageStop === undefined ? 101 : A.usageStop
const POOL = A.pool || 4
const MODELS = A.models || {}
const ONLY = A.only || null
const pick = (keys) => keys.filter(k => !ONLY || ONLY.includes(k))
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

// At most POOL agents that build the package run at once; a waiting agent takes the next free slot (FIFO).
let active = 0
const waiters = []
const acquire = () => new Promise(res => { if (active < POOL) { active++; res() } else waiters.push(res) })
const release = () => { const next = waiters.shift(); if (next) next(); else active-- }
const heavy = async (tag, run) => {
  await acquire()
  try {
    if (!(await gate(tag))) return null
    return await run()
  } finally { release() }
}

const COMMON = (key) => {
  const S = '.build-s3-' + key
  return `Repository ${ROOT}, branch feature/asset-kit, Stage 3 base tag ${BASE}: Stage 2 is complete (seven targets, the WP-K compatibility shims in Tests/ZTronAssetCompatibilityTests, README). You are an INDEPENDENT Stage 3 agent and did not write this code (CLAUDE.md P4).
Do NOT modify, stage or commit anything in the repository checkout; leave its git status unchanged. For probes create your own detached worktree: git -C ${ROOT} worktree add --detach ${ROOT}/${S}-wt ${BASE} ; edit and build only there; never commit. When you finish, copy every probe or diff you cite to ${ROOT}/.build-orchestrator/s3-probes/${key}/ (create it; plain files named after the finding id) and run git -C ${ROOT} worktree remove --force ${ROOT}/${S}-wt .
YOUR scratch paths: ${ROOT}/${S} (SwiftPM), ${ROOT}/${S}-tsan, ${ROOT}/${S}/tmp for TMPDIR, the module cache and LLVM_PROFILE_FILE. Never the session scratchpad, /tmp, or another agent's .build-* directory. Never run 'xcodebuild -list'. Use no simulator unless your task names one; never the owner's iPhone 17 or any simulator you did not boot yourself. Never run an unscoped pkill/killall.
Owner directives: standalone package; ../ZTronCarouselCore and ../ZTronCarousel are read-only prior art; iOS 15.0 / macOS 12.0 floors; PROMPT Stage 4 is cancelled (the R-CAR-6 shims are test-only, ADR-006/033/051).
Known and accepted: docs/DECISIONS.md (ADR-001..056, NEEDS-HUMAN-REVIEW items) and docs/adr-drafts/*.md record accepted deviations with reasons. A recorded decision is not a finding unless you PROVE it violates a SPEC MUST or invariant in a way its record did not consider. P-13 (ADR-050) is a known owner item.
TOKEN DISCIPLINE: logs go to your scratch path and you read summary lines only; read large documents by section (grep the headings first); never re-read an unchanged file; batch commands.
Run swift / xcodebuild with the Bash tool's dangerouslyDisableSandbox: true. Commands (from your worktree):
  SWIFTPM_SCRATCH=${ROOT}/${S} bash Scripts/verify.sh --quick
  swift test --scratch-path ${ROOT}/${S} --skip Benchmarks --filter <Target>Tests[/<Suite>]
  swift test --scratch-path ${ROOT}/${S}-tsan --sanitize=thread --skip Benchmarks --filter <Target>Tests
The host is shared (8 cores, up to ${POOL} agents building at once, plus the owner's own work): build once, then run filtered tests; note the load average next to any timing you report.`
}

const BLOCKING = `SEVERITY (the owner's strict bar): a finding is BLOCKING only if it is PROVEN (a failing probe you ran, or an exact interleaving / crash-point timeline checked against the code) AND it breaks a SPEC invariant (I-1..I-5) or a MUST requirement, loses or corrupts data, crashes, deadlocks, leaks a task or continuation, leaks a secret, breaks C2 at the 10,000-record reference scale, makes a required gate or test fail (including on the iOS Simulator), flakes, or shows that a required requirement test does not genuinely verify its requirement (CLAUDE.md G4). Everything else (unproven suspicions, SHOULD gaps, robustness or clarity improvements) is NON-blocking; report it with its evidence anyway.`

const FINDINGS_SCHEMA = { type: 'object', properties: {
  findings: { type: 'array', items: { type: 'object', properties: {
    id: { type: 'string', description: 'S3-<LENS>-nn' },
    title: { type: 'string' },
    blocking: { type: 'boolean' },
    proven: { type: 'boolean' },
    wp: { type: 'string', description: 'owning work package by ARCHITECTURE 1.2 file ownership: a, b, c, d, e, f, g, h or k' },
    location: { type: 'string', description: 'file:line' },
    requirements: { type: 'string', description: 'SPEC requirement / invariant / budget IDs' },
    problem: { type: 'string' },
    evidence: { type: 'string', description: 'probe file under .build-orchestrator/s3-probes/<lens>/ and the exact failing output line, or the timeline' },
    repro: { type: 'string', description: 'exact command' },
    fix: { type: 'string' },
  }, required: ['id', 'title', 'blocking', 'proven', 'wp', 'location', 'requirements', 'problem', 'evidence', 'repro', 'fix'] } },
  searched: { type: 'string', description: 'what you tried that found nothing' },
  status: { type: 'string' },
}, required: ['findings', 'searched', 'status'] }

const LENS = {
  stability: (sim) => `LENS: determinism and stability (SPEC 7.1 Q-3, Q-4, Q-5; 7.2; CLAUDE.md C4). Known items to settle: the pre-existing TSan flake in WP-C's 'R-STO-11: phase 4 stops listing the legacy tree after the unit in flight once the caller cancels or the store closes' (LegacyEdgeTests.phaseFourStopsListing, Tests/ZTronAssetStorageTests/Cleanup/LegacyEdgeTests.swift:417-446; ADR-055 L5K-R26/R27 describe it and two candidate fixes) and the liveness waits of LegacyOnDemandRaceTests (L5K-R27 item 1).
Hunt statically: real sleeps or wall-clock waits in tests, Date()/DispatchTime.now()/Task.sleep/SystemRandomNumberGenerator outside live conformers (C4), order or parallelism dependence, joins that never end on cancellation, tests that pass only by timing, unseeded randomness.
Then run in your worktree: the whole suite 4 times (swift test --skip Benchmarks), the whole package under TSan twice, and the full suite once on the iOS Simulator ${sim}: caffeinate -i xcodebuild test -scheme ZTronAssetKit -destination 'platform=iOS Simulator,id=${sim}' -derivedDataPath ${ROOT}/.build-s3-stability/xcode-sim -skip-testing:ZTronAssetKitBenchmarks -collect-test-diagnostics never OTHER_SWIFT_FLAGS='-warnings-as-errors' > ${ROOT}/.build-s3-stability/sim.log 2>&1 , read the result with xcrun xcresulttool get test-results summary --path <bundle under the xcode-sim Logs/Test>, and shut that simulator down afterwards. The host is loaded on purpose: a test that fails under load is a flake (Q-5). For every failure, find the root cause (which wait, which interleaving) and prove it with a probe or repeated runs of that test; report pass counts per run.`,
  concurrency: () => `LENS: concurrency (SPEC 4.2; 5.6 R-SYN-*; 5.8 R-CAR-*; 7.3 "Concurrency"; hard problems H-3, H-4, H-5, H-8, H-9; docs/ARCHITECTURE.md sections 7 and 10, the REENTRANCY ledger). Targets: ZTronAssetSync (the engine), ZTronAssetKit (the facade), the transport's background coordinator, and the TestSupport waits. Hunt: actor reentrancy (for each // REENTRANCY: comment, is the claimed re-validation really done after the await?), single-flight with 100 callers and random cancellations, cancellation storms, priority promotion of an in-flight bulk transfer, shutdown mid-flight (leaked tasks, continuations resumed twice or never), event subscribers that stall or terminate, waitUntil / census waits that can hang, lost wake-ups, unbounded queues. Write probes with ManualTimeSource and the TestSupport fakes, run them, and run ZTronAssetSyncTests and ZTronAssetKitTests under TSan.`,
  crash: () => `LENS: crash consistency and faults (SPEC 4.3 invariants I-1..I-5; 5.2 R-STO-*; 5.3 R-INT-*; 5.7 R-CLN-*; 7.3 "Crash at every boundary", "Faults", "Storage lifecycle", "Model-based"; hard problems H-1, H-2, H-10; docs/ARCHITECTURE.md sections 4 and 5). Target: ZTronAssetStorage (store, index, blobs, lock, snapshot, integrity, cleanup, eviction, legacy migration) and the engine paths that call it. Hunt: crash points the exhaustive enumerations do not cover (a crash combined with ENOSPC / EIO / EACCES, a torn index.tmp, a crash during eviction or during legacy migration, a crash between a blob placement and its index commit), snapshot-before-delete ordering, lease / grace window / hysteresis edges, OS purge between launches (delete blobs/, the root, half the blobs), a second opener on the lock, golden index fixtures per schema version. Use the fake FileSystem's fault and crash scripting and assert I-1..I-5 after every step.`,
  security: () => `LENS: security and hostile input (SPEC 5.9 R-OBS-*, R-SEC-*; 5.1 R-MAN-*; 5.4 R-NET-*; 5.5 R-APL-*; 2.4 defects D-1..D-12; 7.3 "Network" and "Manifest"). Hunt: path traversal and normalisation (manifest paths with '..', percent-encoding, Unicode normalisation, absolute paths, symlinks inside the store root, legacy migration paths, pack IDs and pack locations), app-key leakage (logs, error descriptions, events, diagnostic reports, background task descriptions, redirects to another host or scheme, an HTTP downgrade), size caps (announced vs actual size, a gzip body whose decoded size differs from Content-Length, a truncated body, Int64 edges), Retry-After and header parsing, manifest fuzzing and limit boundaries, duplicate identifiers, digest / file-name confusion. Use the loopback server and the fakes; no external network.`,
  performance: () => `LENS: performance and C2 (SPEC 6 budgets P-1..P-14 with their keys in Scripts/quality-gates.json; 4.2; CLAUDE.md C2; ADR-053's L4-R22 quadratic probe-chain total; ADR-050's P-13 analysis). Hunt at the 10,000-record reference scale: work on the main thread, cooperative-pool threads blocked for more than ~10 ms, actor holds over ~10 ms, quadratic or worse algorithms (vary N and compare ratios), unbounded memory growth, timers or tasks left after quiescence. Do NOT run the whole benchmark suite: the shared host makes absolute numbers meaningless, and the orchestrator runs verify.sh --perf on an idle machine. Targeted timing probes reported as ratios are fine. P-13: find the root cause of the occasional 5-11 ms single blob unlink inside a deletion unit (the benchmark's freshly written, unsynced files? directory syncs? fan-out directory removal? the kernel?) with an isolated probe measuring the unlink latency distribution for fresh vs. synced files and for each fan-out pattern, and propose evidence-backed options for the owner. Never edit a benchmark or a gate (CLAUDE.md G1); a code change that only hides the stall from the measurement is not an option.`,
  conformance: () => `LENS: requirement conformance and test strength (every MUST of SPEC 5; 7.2; 7.3 mandatory scenarios; CLAUDE.md G4; docs/TRACEABILITY.md maps every MUST and budget to its tests). (1) For each 7.3 mandatory scenario, name the test(s) that implement it, or report it missing. (2) Sample at least 25 MUST requirements across all targets, weighted toward those with a single test; for each, read the test and decide whether it genuinely verifies the requirement; prove a weak test by writing a mutant of the production code that breaks the requirement while the test still passes. (3) Export per-file line coverage (swift test --enable-code-coverage, then xcrun llvm-cov report over the .xctest bundles under your scratch path) and list uncovered regions in Storage, Sync and Kit that hide untested behaviour (not trivia). (4) Facade parity (R-CAR-*; the prior art's BasicImagePageFallbackTests cases re-expressed on AssetClient) and the compatibility shims' tests (R-CAR-6, Q-10 as ADR-051 reinterprets it).`,
}

const huntPrompt = (lens) => `TASK: Stage 3 adversarial hunt, lens "${lens}". Find real bugs and weak tests; PROVE each one.
${COMMON(lens)}
Read CLAUDE.md (already loaded), the SPEC sections and docs/ARCHITECTURE.md sections your lens names (by section), and the code. Read docs/DECISIONS.md only by grepping for the identifiers you need.
${LENS[lens](A.sim)}
${BLOCKING}
For every bug write the probe as a Swift Testing test in the owning test target of your worktree (a failing test the fixer can commit as is: display name starts with the requirement ID, .timeLimit(.minutes(1)) on anything that awaits, ManualTimeSource only, no sleeps), run it, and paste its failing line as evidence. Number findings S3-${lens.toUpperCase().slice(0, 4)}-01, -02, ... Return the structured findings, what you searched that found nothing, and a status paragraph.`

const CONFIRM_SCHEMA = { type: 'object', properties: {
  verdicts: { type: 'array', items: { type: 'object', properties: {
    id: { type: 'string' },
    verdict: { type: 'string', enum: ['confirmed', 'refuted', 'unclear'] },
    blocking: { type: 'boolean' },
    wp: { type: 'string' },
    reason: { type: 'string' },
  }, required: ['id', 'verdict', 'blocking', 'wp', 'reason'] } },
  status: { type: 'string' },
}, required: ['verdicts', 'status'] }

const confirmPrompt = (lens, findings) => `TASK: Independent confirmation of the Stage 3 "${lens}" hunter's proven findings. You did not write the code or the probes.
${COMMON('confirm-' + lens)}
For EACH finding below: (1) re-run its probe (copied under ${ROOT}/.build-orchestrator/s3-probes/${lens}/) in your own worktree against ${BASE} and check that it fails for the stated reason, not because of a broken probe, a timing assumption, a misuse of a test-only seam, or a misreading of the SPEC; (2) check the claimed expected behaviour against the SPEC requirement and the recorded decisions (a recorded, accepted decision is not a bug); (3) try to REFUTE it. Default to refuted when you cannot reproduce it. Judge severity under this bar, which may differ from the hunter's:
${BLOCKING}
Also confirm the owning work package (ARCHITECTURE 1.2).
FINDINGS: ${JSON.stringify(findings)}
Return one verdict per finding and a status paragraph.`

const MUT_SCHEMA = { type: 'object', properties: {
  probes: { type: 'array', items: { type: 'object', properties: {
    id: { type: 'string', description: 'M-<G>-nn' },
    title: { type: 'string' },
    file: { type: 'string', description: 'mutated file:line' },
    requirement: { type: 'string' },
    diff_path: { type: 'string' },
    killed: { type: 'boolean' },
    killing_tests: { type: 'string', description: 'display names of the tests that failed, or the missing test when it survived' },
    notes: { type: 'string' },
  }, required: ['id', 'title', 'file', 'requirement', 'diff_path', 'killed', 'killing_tests', 'notes'] } },
  status: { type: 'string' },
}, required: ['probes', 'status'] }

const MUT = {
  storage: `GROUP "storage": ZTronAssetStorage (store, integrity, cleanup, eviction, migration); catching tests in ZTronAssetStorageTests, or ZTronAssetSyncTests where the engine is the natural catcher. Mandatory probes from SPEC 7.4: skip hash verification; publish a blob before verification; delete before publishing the snapshot; drop the lock; off-by-one in LRU order; forget to reset the sync stamp after a purge; evict a leased asset; swallow ENOSPC. Add at least 3 of your own (for example: skip the index sync before the rename, adopt a legacy file without checking its checksum, release a lease early, skip the grace window).`,
  network: `GROUP "network": ZTronAssetTransport, ZTronAssetSync, ZTronAssetModel, ZTronAssetAppleHosted, ZTronAssetKit. Mandatory probes from SPEC 7.4: ignore Retry-After; keep the app key on a cross-host redirect; cancel a transfer when any waiter cancels; treat 403 as transient. Add at least 7 of your own (for example: accept a '..' manifest path, an off-by-one in the size cap, break single-flight deduplication, ignore a priority promotion, release an Apple pack twice in one catalog generation, do file-system work in lookup on the main thread, drop a backoff step).`,
}
const mutPrompt = (g) => `TASK: Stage 3 mutation probes (SPEC 7.4, gate Q-8), group "${g}". You did not write this code.
${COMMON('mut-' + g)}
${MUT[g]}
Method, one mutant at a time in your worktree: apply a minimal, realistic defect to production code under Sources/ (never to tests); confirm it compiles; run the narrowest test target that should catch it (swift test --filter <Target>Tests) and, if nothing fails, the whole suite; record KILLED with the failing tests' display names, or SURVIVED; then restore the file (git checkout -- <file>) and confirm git diff is empty before the next mutant. Save each mutant's diff as ${ROOT}/.build-orchestrator/s3-mutants/${g}/M-${g === 'storage' ? 'S' : 'N'}-nn.diff (create the directory). A mutant that does not compile or is equivalent (no observable behaviour change) does not count; replace it. A SURVIVOR needs a precise description of the missing test: the behaviour, the requirement ID, and the test file it belongs in. Return the structured list and a status paragraph.`

const BACKLOG_SCHEMA = { type: 'object', properties: {
  counts_by_category: { type: 'string' },
  counts_by_wp: { type: 'string' },
  top_open: { type: 'array', items: { type: 'string' } },
  status: { type: 'string' },
}, required: ['counts_by_category', 'counts_by_wp', 'top_open', 'status'] }

const backlogPrompt = `TASK: Stage 3 backlog survey (read-only; no builds or test runs). It also answers the owner's open question "any non-blocking bugs up to this point?".
Repository ${ROOT}, branch feature/asset-kit, tag ${BASE}. Modify nothing except the two output files named below. Never the session scratchpad or /tmp.
TOKEN DISCIPLINE: grep headings and identifiers first; read by section; never re-read an unchanged file.
Sources: docs/DECISIONS.md ADR-049..056 (their Open, Deferred, "Stage 3", Assignments, Merge rulings and "Not verified" bullets); docs/adr-drafts/*.md (open items, "stage3:" items, items declined for now or deferred); docs/ORCHESTRATION.md (every "Stage 3 backlog" list); the findings files .build-orchestrator/*.json (non-blocking issues, and anything labelled stage3:) and the rulings .build-orchestrator/*-rulings.md (items sent to Stage 3).
For each distinct item (deduplicate across sources): id S3-B-nnn; title; sources; category (proven-open-bug | unproven-suspicion | accepted-deviation | performance-limit | test-or-environment | documentation | device-only); owning work package by docs/ARCHITECTURE.md 1.2 file ownership (a, b, c, d, e, f, g, h, k, i); status at HEAD (still-open | resolved, citing file:line or the test name that resolves it | cannot-tell); the action proposed for Stage 3 (fix | test | ADR-record | device-plan | none).
Write ${ROOT}/.build-orchestrator/s3-backlog.json (an array of the items) and ${ROOT}/.build-orchestrator/s3-backlog.md (grouped by category, one line per item). Return the counts per category and per work package, the 20 most important still-open items (one line each, with id and WP), and a status paragraph.`

phase('Hunt')
const backlogRun = gate('backlog').then(ok => ok ? agent(backlogPrompt, { label: 'backlog', phase: 'Backlog', model: MODELS.backlog || 'sonnet', schema: BACKLOG_SCHEMA }) : null)

const LENSES = pick(['stability', 'concurrency', 'crash', 'security', 'performance', 'conformance'])
const huntRuns = Promise.all(LENSES.map(async (lens) => {
  const h = await heavy('hunt:' + lens, () => agent(huntPrompt(lens), withModel('hunt', { label: 'hunt:' + lens, phase: 'Hunt', schema: FINDINGS_SCHEMA })))
  if (!h) return { lens, hunt: null, confirm: null }
  const proven = h.findings.filter(f => f.proven)
  log(lens + ': ' + h.findings.length + ' findings, ' + proven.length + ' proven, ' + h.findings.filter(f => f.blocking).length + ' claimed blocking')
  if (!proven.length) return { lens, hunt: h, confirm: null }
  const c = await heavy('confirm:' + lens, () => agent(confirmPrompt(lens, proven), withModel('confirm', { label: 'confirm:' + lens, phase: 'Confirm', schema: CONFIRM_SCHEMA })))
  if (c) log(lens + ' confirmed: ' + c.verdicts.filter(v => v.verdict === 'confirmed').length + '/' + proven.length + ', blocking after confirmation: ' + c.verdicts.filter(v => v.verdict === 'confirmed' && v.blocking).length)
  return { lens, hunt: h, confirm: c }
}))

const GROUPS = pick(['storage', 'network'])
const mutRuns = Promise.all(GROUPS.map(g => heavy('mutate:' + g, () => agent(mutPrompt(g), { label: 'mutate:' + g, phase: 'Mutate', model: MODELS.mutate || 'sonnet', schema: MUT_SCHEMA })).then(m => {
  if (m) log('mutants ' + g + ': ' + m.probes.length + ' run, ' + m.probes.filter(p => !p.killed).length + ' survived')
  return { group: g, result: m }
})))

const [backlog, hunts, mutation] = await Promise.all([backlogRun, huntRuns, mutRuns])
return { backlog, hunts, mutation, stopped }
