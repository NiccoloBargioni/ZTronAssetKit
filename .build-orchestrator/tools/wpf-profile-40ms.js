export const meta = {
  name: 'wpf-profile-40ms',
  description: 'Profile three WP-F C2 shapes in a scratch copy and independently review the attribution',
  phases: [
    { title: 'Profile', detail: 'scratch copy of 8e1fb24, baselines, CPU profiles, micro-timings' },
    { title: 'Review', detail: 'independent check of root selection, categories and arithmetic' },
  ],
}

const ROOT = '/Users/admin/Documents/ZTronAssetKit'
const WT = ROOT + '/.worktrees/s3f'
const SCR = ROOT + '/.build-prof40'
const AN = ROOT + '/.build-orchestrator/s3f-c20-analysis'
const REPORT = AN + '/profile-40ms.md'

const RULES = `RULES
- Do not modify the git worktree ${WT}. Read it only, and never cd into it.
- Do not modify anything tracked in ${ROOT}. Commit nothing.
- Work only inside ${SCR}/ (create it). rm -rf is allowed only inside it.
- Make the scratch source copy with: git -C ${WT} archive 8e1fb24 | tar -x -C ${SCR}/src
- Build and test only with --scratch-path ${SCR}/spm. Never use the default .build or another agent's path.
- The benchmark configuration is verify.sh's: swift test -c release --scratch-path <path> -Xswiftc -enable-testing --filter <name>
- The host is shared with other projects, and its 1-minute load was about 94 on 8 cores when this started.
  - Never stop, slow down or touch other processes or simulators. No iOS Simulator is needed here.
  - Record \`sysctl -n vm.loadavg\` before and after every timed or profiled run.
- A timing figure counts only at a 1-minute load of 10 or less (ruling S3-R23). If the load stays above 10:
  - still profile, because the share of on-CPU samples is what matters;
  - report each timing as "not at a quiet load", with its loads.
- Do not spend more than about 15 minutes in total waiting for a quiet host.
- No network.
- Write the report to ${REPORT}. Keep the raw exports under ${SCR}/out/.`

const PROFILE_TASK = `Measurement task for the ZTronAssetKit orchestrator. Profile three C2 shapes of the WP-F sync engine, the Swift 6 actor SyncEngine, at commit 8e1fb24. The goal is to confirm or refute a read-only analysis of where their time goes. That analysis INFERRED its numbers; it did not profile.

${RULES}

THE THREE SHAPES (10,000 ids, release)

1. Commit re-routes.
   - Case: BenchSync.concentrationCommitRerouteTurns (Tests/ZTronAssetKitBenchmarks/BenchSync.swift:657).
   - Cycle 20 measured 47.99-49.35 ms, best of 3.
   - The measured window is one actor turn: publish()'s resumption after store.publish. It runs:
     - committed(), in Sources/ZTronAssetSync/Engine/EngineDispatch.swift at about lines 1100-1139;
     - its re-routes: reroute at about 1147-1189, which calls addInterest in EngineJobs.swift at about 108-181;
     - then resolveAll, removeJob, publishTerminal, pump and reconcileIdle.

2. Drain take-off.
   - Case: BenchSync.movedBeforeDrainTurns (BenchSync.swift:677).
   - Cycle 20 measured 45.67-49.08 ms.
   - The timed span is one turn, run by releaseOneHeldTurn (BenchSync.swift at about 3457-3467). The chain is continueFollow, then drainEventsAfterFollow, then the verdict replay, then takeOffMovedBefore (EngineFollow.swift at about 552) and its re-routes.

3. supersede of a superseded publication.
   - The verifiers' probe ${ROOT}/.build-orchestrator/s3f-probes-c20/correct/VerifyC20SupersedeBench.swift measured 41.09 ms.
   - In one turn it runs publicationFailed (EngineDispatch.swift at about 1192), its .superseded arm, supersede (at about 1256-1280) and reconcileIdle.
   - To see how the verifiers installed and ran probes in a scratch copy, read:
     - ${ROOT}/.build-orchestrator/s3f-probes-c20/reqs/scripts/probebuild.sh and proberun.sh;
     - the logs under ${ROOT}/.build-orchestrator/s3f-probes-c20/correct/logs/, especially rel-superq.log*.

THE CLAIMS TO TEST
The analysis INFERRED these. Its full text is in ${AN}/analysis-40ms.md and ${AN}/analysis-40ms/analyze-*.md.
- C1: the transfer id is formatted 3-4 times per re-routed id. Each format goes ContentHash.hex, then TransferID.content, with about 4-5 heap allocations, and costs about 0.3-0.65 µs. That would be about 40-50% of the commit re-route and drain take-off turns, and about 9 ms of supersede's 41 ms.
- C2: about 7-9 jobs-table accesses per id, keyed by a 66-byte TransferID string, with 2-3 whole-Job copies. About 0.7-1.3 µs per id.
- C3: the two 10,000-id AssetID sorts each cost about 3.3 ms: unbound.sorted() in committed, and job.assets.sorted() in publishTerminal. removeJob's retireProgress costs about 1.3 ms.
- C4: manifest lookups with ManifestEntry copies, group pending writes and set inserts cost about 0.5-0.9 µs per id.

WHAT TO DO
1. Build the scratch copy: release, with -enable-testing. Add the supersede probe to the scratch copy's benchmark target, the way the verifiers did.

2. Baselines. Run each of the three cases, best of 3, and check the figures are close to cycle 20's. Record the loads.

3. Profiles.
   - Profile each case with \`xcrun xctrace record\`, on the release test run filtered to that one case.
   - Use the "CPU Profiler" template if it works on this Mac; otherwise "Time Profiler".
   - Aim for at least 500 samples inside the measured turn per shape. To get them, you may raise the case's repetition count in the scratch copy only, for example by looping the scenario. Do not change the engine code.

4. Attribution.
   - Export the samples with \`xcrun xctrace export\`, from the cpu-profile or time-profile table.
   - Attribute only samples whose backtrace contains the measured turn's root frame:
     - shape 1: publish's post-await partial function, or committed;
     - shape 2: the drain's verdict replay or takeOffMovedBefore, inside continueFollow's turn;
     - shape 3: publicationFailed or supersede.
   - Exclude setup work: building the 10,000 ids, and the applies and follows before the timed turn.

5. Breakdown. Within each measured turn, give the share of samples by category, including callees, and the ms it implies at the baseline figure. The categories:
   - transfer-id formatting: ContentHash.hex, TransferID.content or legacy, ManifestEntry.transferID, and the allocations under them;
   - jobs-table access: Dictionary<TransferID, Job> lookups, hashing and == of TransferID or String, and the Job copies those accesses cause (retain/release, outlined copy, swift_beginAccess);
   - sorting: AssetID comparisons and sort;
   - Set and Dictionary inserts and removals other than the jobs table;
   - manifest lookups (applied.entry(for:)) and ManifestEntry copies;
   - retireProgress and removeJob;
   - everything else, naming its top items.
   Also list the top 15 functions by self time inside the turn.

6. Micro-timings. In the scratch copy's release build (a temporary test is fine), using ContinuousClock and best of 3, measure:
   - ns per ManifestEntry.transferID on a checksummed entry, over at least 40,000 calls;
   - ns per Dictionary lookup with a TransferID key, in the style of Dictionary<TransferID, Job>;
   - ms to sort 10,000 AssetIDs;
   - ns per Set<AssetID> insert.

7. Verdicts and estimates.
   - For each claim C1-C4, say CONFIRMED, PARTLY or REFUTED, with the measured numbers.
   - Then estimate, from the measured shares only, what each fix family in analysis-40ms.md would save on each shape:
     - formatting each transfer id once;
     - one jobs-table access per id, with no Job copy;
     - filtering before sorting in publishTerminal;
     - any others the shares point to.
   - Say whether each shape would land at 32 ms or less with the branch-free fixes.

OUTPUT: write the report file, then return the structured result.`

const PROFILE = {
  type: 'object',
  properties: {
    method: { type: 'string', description: 'toolchain, template, commands, repetitions, loads' },
    shapes: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          shape: { type: 'string' },
          baselineMs: { type: 'string', description: 'best of 3 with loads; say if not at a quiet load' },
          rootFrame: { type: 'string' },
          samplesInTurn: { type: 'number' },
          categories: {
            type: 'array',
            items: {
              type: 'object',
              properties: { category: { type: 'string' }, sharePct: { type: 'number' }, impliedMs: { type: 'number' } },
              required: ['category', 'sharePct'],
            },
          },
          topSelf: { type: 'array', items: { type: 'string' } },
          fixSavings: { type: 'string', description: 'per fix family: ms saved, from measured shares; whether the shape lands at 32 ms or less' },
        },
        required: ['shape', 'baselineMs', 'rootFrame', 'samplesInTurn', 'categories', 'topSelf', 'fixSavings'],
      },
    },
    microTimings: {
      type: 'array',
      items: { type: 'object', properties: { what: { type: 'string' }, result: { type: 'string' } }, required: ['what', 'result'] },
    },
    claims: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          claim: { type: 'string' },
          verdict: { type: 'string', enum: ['CONFIRMED', 'PARTLY', 'REFUTED', 'NOT_TESTED'] },
          evidence: { type: 'string' },
        },
        required: ['claim', 'verdict', 'evidence'],
      },
    },
    caveats: { type: 'string' },
    reportPath: { type: 'string' },
  },
  required: ['method', 'shapes', 'microTimings', 'claims', 'caveats', 'reportPath'],
}

const REVIEW = {
  type: 'object',
  properties: {
    verdict: { type: 'string', enum: ['CONFIRMED', 'CORRECTED', 'UNRELIABLE'] },
    corrections: { type: 'array', items: { type: 'string' } },
    recomputed: { type: 'string', description: 'shares you recomputed yourself, with the shape' },
    microTimingRerun: { type: 'string' },
    bottomLine: { type: 'string', description: 'per shape: corrected shares of transfer-id formatting and jobs access, and whether the branch-free fixes land at 32 ms or less' },
  },
  required: ['verdict', 'corrections', 'recomputed', 'bottomLine'],
}

phase('Profile')
log('One profiler on a scratch copy of 8e1fb24, then one independent reviewer. The engine code is unchanged; nothing is committed.')
const prof = await agent(PROFILE_TASK, { label: 'profile:three-shapes', phase: 'Profile', schema: PROFILE, effort: 'high' })
if (!prof) {
  return { profile: null, review: null }
}

phase('Review')
const REVIEW_TASK = `Independent review of a profiling result for the ZTronAssetKit orchestrator.

${RULES}

What the review may do beyond reading:
- run quick parsing scripts over the saved exports under ${SCR}/out/;
- re-run the micro-timing test once, in the already-built scratch copy at ${SCR}/, with the same scratch path.
Do not re-run the long profiles, and do not change engine code.

Here is what the profiler was asked to do:
${PROFILE_TASK}

The profiler's result:
${JSON.stringify(prof, null, 2)}

Its report is at ${REPORT}.

Check:
1. Root selection. Do the attributed samples cover exactly the measured turn of each shape, and exclude setup? Check some backtraces yourself.
2. Category mapping.
   - Are frames assigned to the right category? For example, malloc, free, retain and release under ContentHash.hex count as formatting, and Job copies under dictionary getters count as jobs access.
   - Is any category double-counted?
3. Arithmetic. Recompute the shares from the exports for at least one shape.
4. Conclusions. Do the CONFIRMED, PARTLY and REFUTED calls, and the savings estimates, follow from the numbers?

Return corrections with numbers. When unsure, take the more cautious reading.`
const review = await agent(REVIEW_TASK, { label: 'review:profile', phase: 'Review', schema: REVIEW, effort: 'high' })

return { profile: prof, review }
