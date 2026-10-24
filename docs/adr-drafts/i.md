# WP-I decision drafts (documentation: the README and the consistency of WP-I's docs)

Stage 2, the "end | I docs" row of ARCHITECTURE §1.2, branch `wp/i` (based on `l5-merged`). One entry per non-trivial
decision, in the `DECISIONS.md` shape (context · options · decision · consequences); the orchestrator numbers them at
merge. Toolchain of every command below: Apple Swift 6.4 (swiftlang-6.4.0.34.1), Xcode 27.0 (27A266a), macOS 27.0.

**Files changed** (no Swift file, no `Package.swift`, nothing under `Scripts/` or `Tests/`):
- `README.md` (new).
- One line each, line 2 (the blank line under the title) replaced by a status note: `docs/design/store.md`,
  `docs/design/sync.md`, `docs/design/transport.md`, `docs/design/reviews/store-1.md`, `store-2.md`, `sync-1.md`,
  `sync-2.md`, `transport-1.md`, `transport-2.md` (I-5).
- `docs/adr-drafts/i.md` (this file).

Fix round 1 (I-8) changed `README.md` and this file only.

Not touched, as the task requires: `docs/ARCHITECTURE.md`, `DECISIONS.md`, `TRACEABILITY.md`, `ORCHESTRATION.md`,
`MIGRATION.md`, the other ADR drafts, and the Stage 3/5 reports (`MUTATION-PROBES.md`, `VERIFICATION.md`,
`DEVICE-TEST-PLAN.md`, `RESIDUAL-RISKS.md`), none of which was created.

---

## I-1 — The README: an integrator's guide, evergreen, every statement sourced

- **Context.** SPEC §8 asks for "A `README.md` with a 20-line quick start"; the task lists the sections. The
  repository's documents are exact but dense and full of process state (run ids, dates, usage, test counts).
- **Options.** (a) A short README that points at ARCHITECTURE.md for everything. (b) A self-contained guide that
  restates ARCHITECTURE.md and MIGRATION.md. (c) An integrator's guide: one short section per concept, each statement
  taken from the merged public declarations' doc comments or from an ADR or ARCHITECTURE passage, citing it, and
  linking to MIGRATION.md instead of repeating it.
- **Decision.** (c). Sections: what the package is and is not (one paragraph); at a glance (floors iOS 15.0 / macOS 12.0,
  ADR-005; Swift 6.3+ to build here and tools version 6.0 for a consumer's manifest, SPEC §3, and, since round 1, Swift
  6.2 at least for a consumer's toolchain, which compiles sources that use `@concurrent`; Swift 6 mode with strict
  concurrency; no third-party dependency; the single product, `ZTronAssetModel` re-exported); installation as a path
  dependency on a checkout, worded so it stays true once a repository is published (no URL invented); the quick start
  (I-2); how it works in one paragraph; the core concepts the task names, each pointing to its ARCHITECTURE section or
  ADR; compatibility (the shims and MIGRATION.md, linked, not duplicated); building and verifying (the CLAUDE.md
  commands verbatim, the iOS Simulator requirement with ADR-051's commands, I-6); the documentation map (I-7).
  Evergreen rule: no stage status, date, run id, usage figure, test count, coverage figure or benchmark number; stage
  names appear only to label the historical documents and the drafts; no license section (the repository has none).
  API names, defaults and behaviour were read from `Sources/ZTronAssetKit/**` and `Sources/ZTronAssetModel/**` (and,
  where a doc comment points there, the engine: `registerSubscriber`'s replay, the memory-pressure observer's
  `environment.memoryPressure != nil` guard), never from memory; every Swift block was compiled (I-2, I-3).
- **Consequences.** Facts that are NEEDS-HUMAN-REVIEW decisions are stated as the code does them and cite their ADR
  (the storage location, ADR-001; pack retention, ADR-027; background transfers, ADR-026, and an explicit shutdown
  cancelling them, ADR-039 / D-10; the fallback-chain deviations, ADR-037; the migration deviations, ADR-052; the shims,
  ADR-033, ADR-055), so a ruling that changes one also changes a README sentence (left for the orchestrator). Three
  facts the README states that the authoritative documents do not state outright: `AssetEnvironment.live()` passes no
  `MemoryPressureSource`, so a registered `PurgeableCache` is purged only when the app supplies one
  (`AssetEnvironment.memoryPressure` is a public `var`; the README shows the three lines); the app must add the
  downloader extension for Apple hosting, which APPLE-API-VERIFICATION §1.7 consequence (c) asks "`README`/`MIGRATION.md`"
  to say (the README states only what §1.7 records: StoreKit's `StoreDownloaderExtension`, iOS 26, from the SDK, and
  download policies as build-time data, from its labelled web cross-check; it names no Info.plist key, since none was
  verified, lists the Info.plist keys and the App Group only as SPEC §1.3 does, and, since round 1, sends the reader to
  Apple's BackgroundAssets documentation for them); and (round 1) a consumer needs Swift 6.2 or newer, because it
  compiles this package's sources and three `@concurrent` functions in `Sources/ZTronAssetSync/Engine/`
  (`EngineLifecycle.swift`, `EngineRuns.swift`, `EngineCommands.swift`) have no compiler guard; `@concurrent` is
  SE-0461, whose swift-evolution status line, read in this session, is "Implemented (Swift 6.2)". SPEC §3's "The 6.3
  requirement is for *building and testing here*, not for consumers" stays true, but tools version 6.0 does not let an
  older toolchain build the package (left for the orchestrator, item 9).

## I-2 — The quick start: top-level code, 20 lines, compiled verbatim

- **Context.** The task: at most 20 lines of Swift code (code lines only) that build the configuration, create the
  `AssetClient`, start it, resolve and look up an asset, drive a prefetch window and listen to events, with an obviously
  fake key, R-SEC-1 stated, and a verbatim compile under `-warnings-as-errors`.
- **Options.** (a) An `async throws` function, which the check would have to call (wrapping). (b) Top-level code.
  (c) `AssetFallbackChain` for the lookup. (d) `events` or `subscribe()` for the listener.
- **Decision.** (b), so the block compiles exactly as printed: top-level code that contains `await` runs on the main
  actor (SE-0343), so the main-actor `lookup` and `PrefetchWindowController.update` are called synchronously, as in an
  app's main-actor launch task; the prose under the block says so and points to MIGRATION.md step 3 for an app.
  `lookup` then `resolve` rather than (c), which needs `prepare(kinds:)` and more lines; the chain has its own snippet.
  `subscribe()` rather than `events`: it returns registered, with the current state replayed, while `events` registers
  on its first pull, so the listener's order against `start()` would be unspecified. The key is
  `AppKey("PLACEHOLDER-APP-KEY")` and the origin `https://assets.example.com/` (a name reserved for documentation, RFC
  2606), under the comment "the real key comes from the app's secure configuration and is never logged (R-SEC-1)".
  `import Foundation` is needed for `URL`.
- **Counting rule.** A code line is any line that is neither blank nor a whole-line `//` comment; a line with a trailing
  comment counts. SPEC §8 asks for "a 20-line quick start", which can also be read as 20 physical lines, so round 1
  removed the block's four blank lines and both readings hold: **20 lines, 19 of them code**, 1 comment line, no blank
  line (`QUICKSTART block lines=20 code_lines=19 comment_lines=1 blank_lines=0`; before round 1, `lines=24
  code_lines=19 comment_lines=1 blank_lines=4`).
- **Consequences.** The quick start depends on public signatures only (`AppKey.init(_:)`,
  `HTTPSourceConfiguration.init(baseURL:…appKey:…)`, `RemoteConfiguration.init(http:…)`,
  `AssetClientConfiguration.init(remote:…)`, `AssetClient.init(configuration:environment:)`, `start()`, `subscribe()`,
  `AssetEvent.assetAvailable`, `PrefetchWindowController.init(client:radius:)`, `update(ids:current:)`,
  `lookup(_:extensions:)`, `resolve(_:priority:)`); re-run the check after any change to them.

### Quick-start compile evidence

Scratch package `.build-i/qs/Package.swift`: `// swift-tools-version: 6.0`, platforms `.macOS(.v12)` and `.iOS(.v15)`,
one executable target `QS` depending on `.package(path: "/Users/admin/Documents/ZTronAssetKit/.worktrees/i")`, product
`ZTronAssetKit` (package identity `i`, the directory's name). `.build-i/qs/Sources/QS/main.swift` is the README block
copied by a script that takes the first ```` ```swift ```` block of `## Quick start`; a byte comparison with the README
block reads `VERBATIM identical`. **No wrapping**: the block is top-level code as printed. Re-run in fix round 1 on the
20-line block (README at `4ac324c`), after `rm -rf .build-i/qs-build` (a clean build), with `TMPDIR`,
`CLANG_MODULE_CACHE_PATH` and `SWIFTPM_MODULECACHE_OVERRIDE` under `.build-i/tmp`:

```
swift build --package-path .build-i/qs --scratch-path .build-i/qs-build -Xswiftc -warnings-as-errors > .build-i/qs.log 2>&1
```

Last lines of `.build-i/qs.log` (the exit status appended by the wrapper):

```
[203 / 212] ZTronAssetKit
[207 / 214] QS-product
[208 / 214] ZTronAssetSync
[212 / 214] QS-product
Build complete! (11,88 s)
exit=0
```

`grep -c -i warning .build-i/qs.log` → 0; `grep -c -i error .build-i/qs.log` → 0. Never run (no network use). The
first hand-off's clean build of the 24-line block also ended `Build complete!`, exit 0, 0 warnings.

Beyond the task, the same package cross-built for the iOS floor (round 1, clean), `swift build --package-path
.build-i/qs --scratch-path .build-i/qs-ios-build --triple arm64-apple-ios15.0 --sdk "$(xcrun --sdk iphoneos
--show-sdk-path)" -Xswiftc -warnings-as-errors`: `Build complete! (8,12 s)`, exit 0, 0 warnings; `xcrun vtool
-show-build` on the product reads `platform IOS`, `minos 15.0`.

## I-3 — The other README snippets compile too

- **Context.** Besides the quick start the README has five Swift snippets (configuration, fallback chain, retention
  scope with pins and purge, the memory-pressure environment, the background-events hook) and a `Package.swift`
  fragment.
- **Decision.** A second scratch package, `.build-i/qsx` (target `QSX`, same dependency), wraps each snippet verbatim
  in its own `@MainActor func snippetN() async throws`, after a prelude that declares the names the README's prose
  takes from the quick start (`remote`, `configuration`, `client`) and the app-side values the snippets assume
  (`identifier`, `completionHandler`, `appMemoryWarnings`, a stub `MemoryPressureSource`, and `imageCache`, a stub
  `PurgeableCache`), the snippet inside a nested `do { }` so it may redeclare them. Result of the round-1 re-run (clean,
  README at `4ac324c`): `Build complete! (10,11 s)`, exit 0, no error, exactly two warnings, both "never used" on a name
  a snippet leaves for the reader (`client` at the end of the configuration snippet, `url` of the fallback chain). The
  first hand-off had a third, `handled` of the background hook; round 1's hook snippet uses the return value
  (`if !client.handleBackgroundEvents(…) { completionHandler() }`), so that warning is gone. The manifest fragment is
  not compiled: its two forms are the ones the check package's own manifest uses, and that package resolving
  `package: "i"` for the worktree directory `i` confirms the identity rule the README states.
- **Consequences.** As for I-2.

## I-4 — Links name files only; sections are named in the text

- **Context.** The README cites ARCHITECTURE sections and ADRs. GitHub anchors are slugs of headings, and ADR headings
  carry review tags (`· **NEEDS-HUMAN-REVIEW** (…)`) that change when the owner rules.
- **Options.** (a) Anchor links. (b) Links to files, with the section or ADR named in the link text or beside it.
- **Decision.** (b): no link in the files WP-I wrote carries an anchor, so the link check (below) checks every link
  completely and no link breaks when a heading changes.

## I-5 — Historical status notes, without moving a line

- **Context.** Deliverable (2): a WP-I-owned file that presents as current something the merged code or a later ADR
  contradicts gets a one-line status note at its top naming the authoritative document, rather than a rewrite.
  ARCHITECTURE's header already says it wins where a design disagrees, and ADR-051 records that `docs/design/` is not
  amended (ADR-053 repeats it, citing ADR-051). The note on line 2 is the only change (below), so what that rule
  protects, the designs' content and the line numbers the repository cites, is unchanged; the two ADR sentences are
  now literally stale, which round 1 hands to the orchestrator (item 8 of "Left for the orchestrator").
- **Files examined.**

  | File | Note | Why |
  |---|---|---|
  | `docs/design/store.md` | yes | e.g. lines 416 and 1084 say Swift Testing rejects a two-platform `@available` on a `@Test` and that test targets are never compiled for iOS (superseded, ADR-051) |
  | `docs/design/sync.md` | yes | e.g. line 749 gates suites with `@available(macOS 15.0, *)` (superseded by ADR-014 as amended by ADR-051) |
  | `docs/design/transport.md` | yes | e.g. lines 270 and 544 run foreground transfers as download tasks (superseded by ADR-019: data tasks into staging) |
  | `docs/design/reviews/*.md` (6) | yes | each states defects of the design draft in the present tense; their resolutions are ARCHITECTURE §12 |
  | `docs/RECON.md` | no | titled "Stage 0 recon" and dated; it describes the prior art at fixed commits, which nothing here contradicts |
  | `docs/BASELINE.md` | no | titled "Baseline (Stage 0)"; its figures for this package are labelled "at skeleton time" |
  | `docs/APPLE-API-VERIFICATION.md` | no | a dated record the level documentation passes keep in step (amended through ADR-054); §0, §4 and §5 read against the merged code show no contradiction |
  | `docs/UNSAFE-AUDIT.md` | no | its state (0 of 3 escapes) matches `UNSAFE escapes found=0 max=3` run in this session; the unsafe gate reads the file (`--audit`) |

- **Options for placement.** (a) Insert the note and a blank line under the title. (b) Put the note on the blank line 2
  under the title.
- **Decision.** (b). The first commit did (a); the repository cites these files by line about a hundred times
  (88 `store.md:NNN`, 9 `sync.md:NNN` and 2 `transport.md:NNN` citations, ADR-051's "store.md (lines 416 and 1084)"
  and "sync.md (lines 749 and 1388)" among them), and (a) moved every cited line by two, so the follow-up commit took
  (b): each file keeps its line count, and lines 3 onwards are byte-identical to `l5-merged` (checked per file with
  `diff`). The note matches line 3's form, a paragraph or a blockquote line (prefixed `> ` in `sync.md`, `sync-1.md`,
  `sync-2.md` and `transport-2.md`), and ends in a backslash, a hard line break, so it renders on its own line as the
  first line of the header block that follows. The three designs say "kept for its rationale", not "kept as written",
  because `transport.md` was amended once (`4f83dd5`):

  ```text
  **Historical.** A Stage 1 design draft, kept for its rationale and probe evidence; where it differs from the merged code, [ARCHITECTURE.md](../ARCHITECTURE.md) and [DECISIONS.md](../DECISIONS.md) are authoritative.\
  **Historical.** A Stage 1 adversarial review of a design draft, kept as written; each finding's resolution is in [ARCHITECTURE.md](../../ARCHITECTURE.md) §12, which with [DECISIONS.md](../../DECISIONS.md) is authoritative.\
  ```

## I-6 — The iOS Simulator commands in the README

- **Context.** ADR-051: every test target builds and passes on the iOS Simulator, `verify.sh` does not run it, and
  CLAUDE.md's commands do not mention it (ADR-051 "Open"; CLAUDE.md is the owner's).
- **Decision.** The README quotes ADR-051's commands (the generic iOS build, `xcodebuild test` on a named simulator
  with `-skip-testing:ZTronAssetKitBenchmarks -collect-test-diagnostics never`, the `xcresulttool` summary, `simctl
  shutdown`), says `VERIFY: PASS` alone does not show the simulator run, and keeps build output inside the repository
  (a scratch path, `-derivedDataPath` under it). `caffeinate -i` and `LLVM_PROFILE_FILE`, agent-run details of
  ADR-051, are left to the ADR, which the README links.

## I-7 — The documentation map

- **Decision.** One table row for every file under `docs/` (31 with this file), ARCHITECTURE.md and DECISIONS.md marked
  authoritative, RECON.md, BASELINE.md, `docs/design/` and its reviews marked historical, TRACEABILITY.md marked
  generated, ORCHESTRATION.md marked as orchestration state rather than product documentation, and a pointer to the
  owner review list at the top of DECISIONS.md; one sentence on the decision drafts (numbered into DECISIONS.md; where
  a draft and its ADR disagree, the ADR wins, as the "Rulings over the draft" of ADR-054 and ADR-055 say); one sentence
  on the root documents (SPEC.md, PROMPT.md, CLAUDE.md, KICKOFF-README.md). The Stage 3/5 reports are not listed: they
  do not exist, and a forward reference would be a broken link and transient status.

## I-8 — Fix round 1: the verifiers' findings

- **Context.** Two independent verifiers (an accuracy lens and a usability lens) reported 19 findings on the first
  hand-off, three of them blocking. Each was checked against the code or document it cites before it was fixed.
- **Decision.** Every finding is fixed; none is declined. Where a suggested wording was changed, the change and its
  reason are in the table. Duplicates across the lenses (the budget default, the prior-art list, the section pointer)
  got one fix each.

  | Finding (lens, README line before round 1) | Checked against | Fix |
  |---|---|---|
  | Budget default "half of the free space" (accuracy, blocking; usability; :117) | `StorageBudget.resolve` and `StoragePolicy.budget`'s doc, `StoragePolicy.swift` | Comment reads "half of (store usage + free space)". |
  | Prior-art symbol list (accuracy, blocking; usability; :317-319) | ADR-033 and its WP-K amendment, MIGRATION.md §2, the shim files' public types | The prior art's public types listed as MIGRATION.md §2 maps them, `CDNReconciliationSummary` and the providers' error types included; `NetworkAvailabilityMonitor` over the environment's conditions source; `CDNRefreshPolicy`, `CDNProviderFactory` and `CDNConfiguration` "provided new". |
  | "reproduces the prior art's `BasicImagePage` chain" (accuracy, blocking; :155) | RECON §1, MIGRATION.md steps 3 and 6, R-CAR-2 | The chain is "the three-step chain R-CAR-2 asks for"; only ZTronCarousel's `ZTronSVGView` has three steps, `BasicImagePage` is bundle-only, `BasicVideoPage` bundle then local. The suggested "with the prior art's candidate extensions" became "trying each candidate extension of the asset's kind": RECON records the prior art's image extensions only. |
  | App Group caveat cited to ADR-001; "closes the client" (accuracy; usability; :110-113) | `StorageLocation.custom`'s doc, store.md risk R6, `AssetClient.shutdown()`, `StoreLock`, the store's close releasing the lock | A sentence of its own after the ADR list: unsupported unless the app calls `shutdown()` on backgrounding and creates a new client on return, citing `StorageLocation.custom` and store.md R6; the doc comment's own "closes the client" is item 10 of "Left for the orchestrator". |
  | `withAsset` "checks it" (accuracy; :308-309) | `performOnCore` and `withAsset` in `AssetClient.swift`, ARCHITECTURE §8 and §14's untested list | The root check is "one stat, off the main actor"; `withAsset` reads the recorded reason (no I/O); added that a replacement nothing has detected yet still serves calls that succeed, a `withAsset` lease included. |
  | APPLE-API-VERIFICATION pointers (accuracy; usability; :297-298) | its headings | §1.7 for the extension and pack policies, §1 for the surface, §5 for the device-only items. |
  | Reopen example "the system purging a `.caches` root" (accuracy; :303-304) | store.md F31, R-CLN-7 | "something outside the client deletes or replaces it"; a `.caches` purge between launches is healed at the next launch (R-CLN-7). |
  | I-5 against ADR-051/ADR-053 "not amended" (accuracy) | DECISIONS.md lines 374 and 428 | I-5 says so; "Left for the orchestrator" item 8. |
  | When `lookup` misses (usability; :127-128) | ADR-016's install-rate and user-initiated-answer (L5K-R24) amendments, MIGRATION.md §4, `publishTerminal` in `EngineJobs.swift` (prefetch-lane jobs broadcast `assetAvailable`) | Added the lag of up to about two `snapshotInstallInterval`s after `resolve` or `assetAvailable`, and the legacy-migration miss. The suggested last sentence also says what to do on `assetAvailable`: call `resolve`, which answers a stored asset without a transfer (MIGRATION.md §2, `resolveViaNetwork`'s row). |
  | Hook's return value discarded (usability; :267-273) | `BackgroundEventsRelay.accept`, `handleBackgroundEvents`; `UIApplicationDelegateAdaptor` in the iOS 27.0 SDK's SwiftUI interface (`@available(iOS 14.0, …)`) | The snippet calls the handler when the result is `false`; the prose says a foreign handler is kept nowhere; one clause on `@UIApplicationDelegateAdaptor`. |
  | Consumer toolchain (usability; :16-18) | the three `@concurrent` uses, SE-0461's status line | See I-1; "Left for the orchestrator" item 9. |
  | Apple-hosting prerequisites unnamed (usability; :294-297) | SPEC §1.3, APPLE-API-VERIFICATION (no Info.plist key or App Group anywhere) | The README says none was verified, names none, and sends the reader to Apple's BackgroundAssets documentation. The suggestion to say that page covers the keys and the App Group was not taken: nothing in the repository shows what it covers. |
  | Single writer per root (usability; :79-82) | R-STO-9, `StoreLock.acquire`, the facade test `R-CAR-4: a prefetch on a client whose store cannot open…` (`start()` throws `.storageUnavailable(.locked)`) | One sentence after "keep the client alive for the app's lifetime". |
  | Quick start is 24 physical lines (usability; :52-77) | SPEC §8 | Blank lines removed (I-2). |
  | Transient status (usability; :28-30, :34-35) | — | "Decisions that need the owner's confirmation"; the installation line describes both dependency forms. |

- **Consequences.** README.md has 98 relative links (93 before; added: ADR-016 and MIGRATION.md in the lookup section,
  store.md in the configuration section, RECON.md in the fallback chain, MIGRATION.md in the compatibility section).
  Every check of "Checks before hand-off" was run again on the result.

---

## Checks before hand-off (this session)

All re-run in fix round 1 on the final README.

- **Quick start**: above (clean build, exit 0, 0 warnings; verbatim, no wrapping; iOS 15 cross-build too). The other
  snippets: I-3 (exit 0, two expected "never used" warnings).
- **Docs gate** (no Swift changed): `python3 Scripts/gates.py docs --sources "$PWD/Sources" --config
  Scripts/quality-gates.json` → `DOCS public declarations=1281 documented=1281 exempt=0 fraction=100.0%`, `DOCS: PASS`.
  Unsafe gate, for I-5: `UNSAFE escapes found=0 max=3`, `UNSAFE: PASS`. The trace gate was not run: it rewrites
  `docs/TRACEABILITY.md`, which this work package must not edit.
- **Links**: `.build-i/tools/check_links.py` extracts every inline link `[text](target)`, image and reference
  definition outside fenced code blocks (indented ones included) and inline code spans (wrapped ones included), skips
  external schemes (none occur), strips an anchor (none occurs, I-4) and requires the path, resolved against the
  linking file's directory, to exist. Self-tested on scratch files: it flagged a missing file and a missing reference
  target, ignored links inside fenced blocks and code spans, and passed file, directory and anchored links that exist.
  Run over `README.md`, this file and the nine status-noted files: `LINKS: PASS`, with 98 relative links in
  `README.md` (as many as its `](` occurrences, none inside a fence), none in this file and 2 in each noted file.
- **Ownership**: `git diff --name-only l5-merged...HEAD` lists `README.md`, `docs/adr-drafts/i.md` and the nine files
  under `docs/design/`, and nothing else.

## Left for the orchestrator

1. Number I-1…I-8 into DECISIONS.md (no NEEDS-HUMAN-REVIEW item arises from WP-I's own choices: no public signature,
   storage location, on-disk format, floor or dependency changed; item 9 is a fact about the existing code).
2. When Stage 3/5 create `MUTATION-PROBES.md`, `VERIFICATION.md`, `DEVICE-TEST-PLAN.md` and `RESIDUAL-RISKS.md`, add
   one row each to the README's documentation map.
3. Re-run the quick-start check (I-2, including the iOS cross-build) and the snippet build (I-3) after any change to a
   public signature the README uses, and at Stage 5. The scripts are in the git-ignored `.build-i/tools/`; their whole
   logic is in I-2, I-3 and "Links" above.
4. When the owner rules on a NEEDS-HUMAN-REVIEW decision the README states (I-1's list), update that sentence; when a
   release publishes a repository URL, show its `.package(url:from:)` form in the snippet under "Installation", whose
   first line already covers both forms (and update MIGRATION.md step 1, WP-K's file).
5. MIGRATION.md (WP-K's file) does not tell the owner to add the downloader extension, which APPLE-API-VERIFICATION §1.7
   consequence (c) asks of "`README`/`MIGRATION.md`", although its step 3 configures `appleHosted:
   AppleTierConfiguration()`; the README now says it. A one-line pointer in MIGRATION.md is WP-K's or the
   orchestrator's call.
6. ARCHITECTURE §8 and ADR-044 do not say that `AssetEnvironment.live()` passes no `MemoryPressureSource` (the code does:
   `LiveEnvironment.swift` builds the environment without one, and the engine observes only when it is non-`nil`); the
   README states it (I-1). A sentence in §8 at merge would close the gap.
7. ARCHITECTURE §1.2's "end | I docs" row does not exclude `docs/ORCHESTRATION.md` or the Stage 3/5 reports, which this
   work package's task excluded; WP-I followed the task. Aligning the row is the orchestrator's choice.
8. ADR-051 (DECISIONS.md line 374, "because `docs/design/` is not amended") and ADR-053 (line 428, "`docs/design/` is
   not amended; … ADR-051") are literally stale after I-5's status notes. Suggested amendment at merge: "not amended
   beyond the one-line status note at line 2 (WP-I, I-5)". ADR-052's "store.md §6.5 is not amended" stays true.
9. SPEC §3 (the owner's) says the 6.3 requirement is "not for consumers", and the tools version 6.0 lets a manifest on
   tools 6.0 declare the dependency; but a consumer compiles the sources, and the three unguarded `@concurrent`
   functions need Swift 6.2 (I-1). The README states it. Whether to record it in DECISIONS.md (beside ADR-005, or as a
   note on SPEC §3) and whether the owner should confirm it for ZTronCarouselCore's toolchain is the orchestrator's
   call. Letting an older toolchain build the package would be a code change outside WP-I; only Swift 6.4 was
   exercised in this work package.
10. `StorageLocation.custom`'s doc comment (`Sources/ZTronAssetModel/Policy/StoragePolicy.swift`, a contract type) says
    an App Group container is unsupported "unless the app closes the client when it is backgrounded", but `AssetClient`
    has no close and `shutdown()` is final; the README reads it as `shutdown()` on backgrounding and a new client on
    return. Aligning the doc comment is a Swift change outside WP-I.
