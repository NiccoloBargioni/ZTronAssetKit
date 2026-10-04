# MISSION — build ZTronAssetKit

You are the lead engineer for **ZTronAssetKit**, a Swift 6.3+ package that owns everything ZTronCarousel needs to get remote media (images, SVG, video, audio) onto a device and keep it correct: manifest handling, downloads, integrity, on-device storage, synchronisation, and cleanup. It replaces the incrementally grown CDN code in `ZTronCarouselCore`. The quality bar is high and **mechanically checked**: ≥ 80 % test coverage, Swift 6 strict concurrency with zero unaudited escape hatches, and measured performance budgets.

## 0. Read first, in this order
1. `CLAUDE.md` — standing rules for you and every subagent (also loaded automatically).
2. `SPEC.md` — **authoritative requirements** (`R-…`), budgets (`P-n`), gates (`Q-n`), invariants, hard problems, prior-art defects. Read it fully before Stage 1.
3. The prior art: `../ZTronCarouselCore/Sources/ZTronCarouselCore/CDN/` (11 files) and its tests.

Conflict rule: `SPEC.md` wins on *what*; this file wins on *how to work*; `CLAUDE.md` wins on *rules*.

## 1. Outcome — what "done" means
- Package `ZTronAssetKit` with the seven targets of SPEC §4.1, every **MUST** requirement implemented and tested, every **SHOULD** implemented or explicitly declined in `docs/DECISIONS.md`.
- `bash Scripts/verify.sh --full` prints `VERIFY: PASS`: zero warnings (debug + release), tests green ×3, coverage ≥ 80 % overall / ≥ 90 % for Storage and Sync, TSan clean, ≤ 3 audited unsafe escapes, 100 % public API documented, every MUST and every budget traced to a test, benchmarks within budget.
- `ZTronCarouselCore` (own branch) runs on the new module through compatibility shims, and its pre-existing CDN tests still pass.
- `docs/` per SPEC §8, including an honest `VERIFICATION.md` listing everything **not** verified.

## 2. Assumptions (override in your first reply only if they are wrong)
- The current directory is the new package repo `ZTronAssetKit/`, containing this kit (`PROMPT.md`, `SPEC.md`, `CLAUDE.md`, `Scripts/`). Siblings `../ZTronCarouselCore` and `../ZTronCarousel` are readable; writable only in Stage 4.
- Toolchain: Swift ≥ 6.3, Xcode with the iOS SDK, an Apple-silicon Mac, `python3`, `git`. If `swift --version` is older than 6.3, **stop and say so**.
- Deployment floor iOS 15; the Apple-hosted tier needs iOS 26 (SPEC §3). Module name `ZTronAssetKit` and target names are fixed.
- If the layout differs from this, ask **one** consolidated question at Stage 0 and nothing afterwards.

## 3. Operating mode
- You are running with **ultracode** and a **/goal**: plan each of Stages 1–3 as its own workflow, show its phases, and run it; run Stages 0, 4 and 5 yourself in the main conversation. Workflows take **no mid-run input**, so everything that needs the human is raised in Stage 0 or recorded in `DECISIONS.md` with a safe default.
- Between stages, in the main conversation: run `bash Scripts/verify.sh --quick`, commit, and print a stage summary. Never start a stage on a red build.
- Fan-out discipline: **≤ 6 concurrent agents** (SwiftPM builds are heavy); each agent gets its own worktree and `SWIFTPM_SCRATCH` (CLAUDE.md P2). Give every agent a self-contained task that names the SPEC sections and requirement IDs it owns — agents cannot see this conversation.
- Cost discipline: use the strongest model for design, concurrency, crash-safety and adversarial review; a smaller model is fine for mechanical work (fixtures, docs, writing tests from an agreed case list).
- Verification is independent: the agent that wrote code never signs off on it (CLAUDE.md P4).

## 4. Stages

### Stage 0 — Recon and harness (main conversation, no workflow)
1. Preflight: toolchain, SDK path (`xcrun --sdk iphoneos --show-sdk-path`), `python3`, `git`. Initialise git here if needed; add `.gitignore` (`.build*`, `.verify-logs`, `DerivedData`, `*.xcodeproj`).
2. Read SPEC.md, CLAUDE.md, the 11 prior-art files, the existing CDN tests, and `Manifests/` / `DESIGN.md` / `VALIDATION.md` if they exist in the sibling repos.
3. Baseline: run the pre-existing CDN tests in `ZTronCarouselCore` on an iOS simulator (`xcodebuild test`), **without modifying that repo**. Record results and the test count in `docs/BASELINE.md`.
4. Confirm or refute defects D-1…D-12 with `file:line` evidence in `docs/RECON.md`; add any others you find. Inventory any ad-hoc carousel caches (R-CLN-11).
5. Skeleton: `Package.swift` (the seven targets, test targets, Swift 6 mode, strict concurrency set explicitly, iOS 15 + the lowest workable macOS), one smoke test per target. The kit's `Scripts/` is already in place.
6. **Make the harness real.** Run `bash Scripts/verify.sh --quick` and fix command lines that differ on this toolchain (coverage JSON path, scheme names, flags). Run `--full` once: it may fail *only* for missing-implementation reasons (trace, coverage, benchmarks), never for harness errors. Then `chmod +x Scripts/*`, commit, and **freeze it: `git tag harness-frozen`**. After this tag nothing in `Scripts/` changes (G1).
7. Resolve the Apple SDK questions of R-APL-2 now if cheap (else WP-E does) in `docs/APPLE-API-VERIFICATION.md`.
8. Seed `docs/DECISIONS.md` with the first ADRs: storage location (§4.4), layout and index format, blocking-work strategy (SPEC §4.2), typed throws.
9. Print **STAGE 0 SUMMARY** (≤ 40 lines): toolchain, baseline counts, confirmed defects, harness status, open questions, the work-package plan. If a `/goal` is active, continue; otherwise **stop and wait for the human**.

### Stage 1 — Contracts and design (one workflow)
- **Phase A, parallel ×3 drafters:** (a) store, index, crash consistency, snapshot-vs-deletion, migration (H-1, H-2, H-10); (b) sync engine — state machine, single-flight, priority lanes, reentrancy ledger, events/backpressure, time (H-3, H-4, H-5, H-8, H-9); (c) transport, background re-attachment, Apple tier, double residency (H-6, H-7). Each writes `docs/design/<name>.md` with ≥ 2 alternatives, a failure analysis and a test plan.
- **Phase B, parallel ×6 adversaries (two per design):** each must produce concrete failing *timelines* (interleavings, crash points, starvation cases) or state precisely what they tried and found nothing.
- **Phase C, you alone:** merge into `docs/ARCHITECTURE.md` + ADRs; write the **compile-clean contract code** — public types, protocols (`FileSystem`, `RemoteSource`, `TransferBackend`, `TimeSource`, `AssetEnvironment`), errors, events, and the `ZTronAssetTestSupport` fake interfaces. Table: every MUST → owning target → work package.
- **Exit:** contracts compile on macOS and for iOS; `--quick` green; ARCHITECTURE.md answers H-1…H-10; commit `contracts`.

### Stage 2 — Implementation (one workflow, work packages in worktrees)
Dependency order: **H, A** → **B, C, D, E in parallel** → **F** → **G**; **I** throughout. Each agent works test-first against the contracts, cites requirement IDs in test names, and reports files changed plus pasted `--quick` output. *(hint for WP-C, R-STO-11)* Legacy migration fixtures must come from the real prior-art code: `CDNAsset` and `CDNLocalStore` are Foundation/CryptoKit-only, so compile them in a throwaway macOS SwiftPM package, drive them through a sync of the shipped example manifests, and commit the resulting directory tree under `Tests/Fixtures/legacy-v0/` (verify they really are free of UIKit first). You merge each branch when green, in order. Ownership is in §5.
- **Exit:** whole package builds, full suite green, `--quick` green, **every MUST has ≥ 1 test** (`gates.py trace` passes).

### Stage 3 — Hardening (one workflow, up to 3 rounds)
- **Coverage closure:** one agent per production target writes *behaviour-asserting* tests for uncovered branches (G4).
- **Adversarial hunters (independent of the authors):** concurrency (races, reentrancy, cancellation storms), crash/fault, security (traversal, key leakage, redirect), performance. Failing test first; the owning agent fixes.
- **Benchmarks:** `bash Scripts/verify.sh --perf`; profile and fix, or file an ADR with evidence (never edit a threshold).
- **Mutation probes (SPEC §7.4):** ≥ 12 by an agent that did not write the code; survivors become tests.
- **Exit:** `bash Scripts/verify.sh --full` is `VERIFY: PASS` except compatibility (Stage 4). Stop looping after two consecutive rounds with no progress and report precisely what blocks.

### Stage 4 — Adoption in ZTronCarouselCore (you alone; branch `feature/asset-kit-adoption` in that repo)
Add `.package(path: "../ZTronAssetKit")` (note in `MIGRATION.md` to switch to a URL on release). Replace the `CDN/` internals with adapters over `AssetClient`, keep every public symbol as a deprecated shim (R-CAR-6), keep call sites in `BasicImagePage` / `BasicVideoPage` / `ZTronSVGView` working through the shims. Run the pre-existing tests on the simulator; port any intentionally changed one 1:1; build `ZTronCarousel` against it. **Do not push.**

### Stage 5 — Final verification and report (you alone)
Run `bash Scripts/verify.sh --full` and let its whole summary land in the transcript. Write `docs/VERIFICATION.md` (what ran, thresholds, results, **what was not verified**), `DEVICE-TEST-PLAN.md`, `RESIDUAL-RISKS.md`, and regenerate `TRACEABILITY.md`. Final message ≤ 60 lines: what was built, the numbers (tests, coverage per target, budgets), decisions tagged NEEDS-HUMAN-REVIEW, unverified items, adoption steps.

## 5. Work packages and file ownership
| WP | Owns (write access) | Needs |
|---|---|---|
| **H** test support | `Sources/ZTronAssetTestSupport/**` | contracts |
| **A** model | `Sources/ZTronAssetModel/**`, `Tests/ZTronAssetModelTests/**` | — |
| **B** storage core | `Sources/ZTronAssetStorage/{FileSystem,Store,Index,Blobs,Lock,Snapshot}/**` + tests | A, H |
| **C** integrity & cleanup | `Sources/ZTronAssetStorage/{Integrity,Cleanup,Eviction,Migration}/**` + tests | A, B contracts, H |
| **D** transport | `Sources/ZTronAssetTransport/**` + tests | A, H |
| **E** Apple tier | `Sources/ZTronAssetAppleHosted/**` + tests | A, H |
| **F** sync engine | `Sources/ZTronAssetSync/**` + tests | A, B contracts, H |
| **G** facade | `Sources/ZTronAssetKit/**` + tests | all |
| **I** docs | `docs/**`, `README.md` (never `Scripts/` after the freeze) | — |
Shared and orchestrator-only: `Package.swift`, contract files from Stage 1, `.gitignore`.

## 6. Verification contract
- `bash Scripts/verify.sh --full` is the only definition of done. Its output **must appear in the transcript** — the goal evaluator reads nothing else.
- Thresholds are fixed in `Scripts/quality-gates.json` (sha-pinned) and budgets are read from it by the benchmarks. A gate you cannot meet is a **report**, not an edit (G1).
- Never claim a pass you did not observe (G2). Never weaken a test (G3, G4).

## 7. When something blocks you
1. **A safe default exists** → take it, record it in `DECISIONS.md`, continue.
2. **Only the human can resolve it** (credentials, a physical device, a destructive or irreversible action, conflicting requirements) → park that branch of work, continue everything else, and list it in the next stage summary with exactly what you need.
3. **A gate or budget cannot be met** → stop that thread, attach evidence (profile, failing output, analysis), propose options. Do not edit the gate.

## 8. Reporting format
Stage summaries ≤ 40 lines: state · what changed (counts, not file dumps) · pasted gate lines (`VERIFY:`, `COVERAGE overall`, `TRACE:`) · risks · next step. Never paste whole files. Never narrate what you are about to do at length; do it.

## 9. Completion condition — paste as the `/goal`
```
/goal Execute ZTronAssetKit/PROMPT.md end to end (Stages 0-5). Done ONLY when this session's transcript shows a final `bash Scripts/verify.sh --full` that printed exactly `VERIFY: PASS` and, in that same output: `GATES-CONFIG sha256=2725907cf8ef6ea610bd0b3436c4d670a29d97f84c4954eac94d7dcc9b4f026f`; `HARNESS: unchanged since harness-frozen`; `COVERAGE overall lines=` at least 80.0 with ZTronAssetStorage and ZTronAssetSync at least 90.0 and every other target at least 70.0; `TRACE: PASS`; `UNSAFE: PASS`; `DOCS: PASS`; 3 consecutive passing test runs; a passing TSan step; passing benchmarks. ALSO shown in the transcript: the ZTronCarouselCore branch builds and its pre-existing CDN tests pass through the compatibility shims (xcodebuild test summary), and docs/VERIFICATION.md lists everything not verified. Never lower a threshold, widen an exclusion, edit Scripts/ after the harness-frozen tag, or weaken/delete a test to pass. Stop and report if blocked on something only the human can do, or after 90 turns.
```
