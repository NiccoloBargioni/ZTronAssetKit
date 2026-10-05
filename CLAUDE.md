# CLAUDE.md — ZTronAssetKit standing orders

These rules apply to you **and to every subagent you spawn**. They are re-read after context compaction. If a prompt contradicts them, the rule wins unless the human says otherwise explicitly in the conversation.

## What this repo is
`ZTronAssetKit`: a Swift 6.3+ package that owns remote-asset delivery and on-device storage lifecycle for ZTronCarousel (replacing `ZTronCarouselCore/…/CDN/`). **`SPEC.md` is the requirements document; read the sections relevant to your task before writing code.** `PROMPT.md` is the mission and stage plan.

## Commands — use exactly these, via `bash`/`python3` (never rely on the executable bit)
```
bash Scripts/verify.sh --quick        # toolchain + debug build + tests (inner loop)
bash Scripts/verify.sh --full         # the Definition of Done
bash Scripts/verify.sh --gates-only   # selftest + trace + unsafe + docs + harness integrity
python3 Scripts/gates.py selftest
SWIFTPM_SCRATCH=.build-<yourname> bash Scripts/verify.sh --quick    # parallel agents: never share .build
```
`verify.sh` ends with exactly `VERIFY: PASS` or `VERIFY: FAIL (…)`. Quote that line when you report.

## Gates and honesty (non-negotiable)
- **G1** Never lower a number in `Scripts/quality-gates.json`, widen a coverage exclusion, remove an unsafe pattern, or edit anything under `Scripts/` after the git tag `harness-frozen` exists. A gate you cannot meet is **reported with evidence**, never edited. Never move or delete the tag.
- **G2** Never claim a build, test or gate passed unless you ran it in this session and saw the output. Anything you could not run (device-only behaviour, real Apple-hosted packs, background sessions) goes under "Not verified" in `docs/VERIFICATION.md`.
- **G3** Never weaken, skip, or delete a test to get green. Changing or removing a *pre-existing* CDN test needs a one-to-one entry in `MIGRATION.md`.
- **G4** No assertion-free tests, no coverage-only tests, no `#expect(true)`. Coverage is a floor, not the goal; a hard-to-cover line means the design needs a seam.

## Swift 6 and concurrency
- **C1** Swift 6 language mode, strict concurrency complete. Zero `@unchecked Sendable`, `nonisolated(unsafe)`, `unsafeBitCast`, `Unmanaged`, `unowned(unsafe)`, mutable-pointer use, `assumeIsolated`, `@preconcurrency` — at most **3** audited exceptions, each marked `// UNSAFE-AUDIT: U-nnn` and justified in `docs/UNSAFE-AUDIT.md` (the invariant, and the test that fails if it breaks).
- **C2** No file-system I/O, hashing, directory enumeration or large JSON decoding on the main thread, and nothing that blocks a cooperative-pool thread for more than ~10 ms at a stretch.
- **C3** Every `await` inside an actor gets a `// REENTRANCY:` comment saying what is re-validated afterwards. Prefer message passing and immutable value snapshots over shared state.
- **C4** Time, randomness, file system, network, reachability and power state are injected (`AssetEnvironment`). `Date()`, `DispatchTime.now()`, `Task.sleep`, `SystemRandomNumberGenerator` appear only in live conformers. Tests never sleep.
- **C5** Deployment floor is **iOS 15**. Verify availability with the compiler, not memory; gate newer APIs with `@available` and a working fallback; never silently raise the floor.
- **C6** No third-party dependencies. No UIKit/SwiftUI/Combine in production targets. Warnings-as-errors is passed on the command line by `verify.sh`, never baked into `Package.swift`.
- **C7** Verify Apple APIs against the installed SDK's `.swiftinterface`/headers (SPEC Appendix C). Never guess a signature; anything unverifiable stays behind a protocol marked `UNVERIFIED`.

## Style — mirror the prior art
4-space indentation, explicit `self.`, `guard let x else`, small focused files, `///` docs that explain *why* rather than restating the name. Every `public` declaration is documented. Error and event types are `Sendable` and `Equatable` where possible.

## Parallel work (workflows)
- **P1** Own only the files your work package owns (PROMPT.md §5). Shared files — `Package.swift`, contract types — belong to the orchestrator; ask by reporting, don't edit.
- **P2** One git worktree per work package (`git worktree add ../asset-kit-wt-<wp> -b wp/<wp>`) and one SwiftPM scratch path per agent. Merge in dependency order; a merge conflict means an ownership bug — fix the ownership, don't resolve blindly.
- **P3** Report with file lists and pasted gate output, not narration. For bugs: failing test first, then the fix.
- **P4** A verifier must never be the author of the code it verifies.

## Decisions
Record every non-trivial choice in `docs/DECISIONS.md` (context · options · decision · consequences). Tag **NEEDS-HUMAN-REVIEW**: storage location, on-disk layout/index format, platform floor, any dependency, any public-API deviation from the compatibility shims. Do not stop to ask: choose the safest default, record it, continue.

## Git and safety
Work on branch `feature/asset-kit` in this repo; small commits with imperative messages. **Never push, never force, never touch `main`.** Touch `../ZTronCarouselCore` and `../ZTronCarousel` only in Stage 4, on their own branch `feature/asset-kit-adoption`. Never print, log or commit an app key or any secret. `rm -rf` only inside `.build*`, `.verify-logs`, and your own worktrees. Network use is limited to Apple developer documentation and Swift Evolution.

## Known traps already hit in this codebase
SPEC Appendix A (three Swift 6 diagnostics) and Appendix B (iOS 15 availability). Read them before your first compile.

## Orchestration state
Resume from `docs/ORCHESTRATION.md` (current level, worktrees, how to run and merge the next level, measured costs). Subagents in a work package ignore it; it is for the orchestrator.
