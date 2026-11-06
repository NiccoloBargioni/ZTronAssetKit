# WP-I orchestrator rulings (documentation and README): input for ADR-056

These rulings are the source of truth for the WP-I merge docs; they win over `docs/adr-drafts/i.md`.

## Run
- **Owner, 2026-10-24:** "Run WP-I: documentation and README". The usage stop was 70 % by the orchestrator's default; the owner set it to **75 %**.
- **Workflow:** `wf_3045417c-704` (`.claude/workflows/assetkit-wp-i-docs.js`): an author, then accuracy and usability verifiers.
  - Round 1: 3 blocking out of 19 (README facts: the budget default, the prior-art symbol list, the fallback chain's prior art).
  - The fix round fixed all 19.
  - **Round 2: 0 blocking out of 11.**
- **The orchestrator applied the 11 last notes** (`f234cda`) and checked each fact against the code first:
  - `prepare(kinds:)` replaces the index and starts empty;
  - `PurgeRequest.scope` deletes pinned and essential entries;
  - `TierSelection.select` has no fallback for a configured Apple tier;
  - the manifest defaults (`manifest.json`, the envelope);
  - shutdown's scope;
  - document precedence.

  The quick start is unchanged (19 code lines, compiled verbatim; iOS 15 cross-build), and the link check passes (102 links).

## Rulings
- **WPI-R1: I-1…I-8 are ratified as ADR-056.** I-1's README design; I-2 the quick start (top-level code, ≤ 20 code lines, compiled verbatim); I-3 the other snippets compiled; I-4 links name files, not anchors; I-5 the one-line historical notes at line 2, with no line moved; I-6 the README carries ADR-051's simulator commands; I-7 the documentation map; I-8 the fix round.
- **WPI-R2: ARCHITECTURE §1.2's "end | I docs" row** also excludes `docs/ORCHESTRATION.md` (orchestrator) and the Stage 3/5 reports (`MUTATION-PROBES.md`, `VERIFICATION.md`, `DEVICE-TEST-PLAN.md`, `RESIDUAL-RISKS.md`: Stage 3's and the orchestrator's at Stage 5). `README.md` stays WP-I's.
- **WPI-R3: ARCHITECTURE §8** gains the fact the code shows: `AssetEnvironment.live()` passes no `MemoryPressureSource`, so a registered `PurgeableCache` is purged only when the app supplies a source (ADR-044 amendment). Verify it against `LiveEnvironment.swift` before writing.
- **WPI-R4: ADR-051 and ADR-053** each get a dated amendment. Their "`docs/design/` is not amended" now reads "not amended beyond the one-line status note at line 2 (WP-I, I-5; ADR-056)". ADR-052's "store.md §6.5 is not amended" stays.
- **WPI-R5: the consumer toolchain. NEEDS-HUMAN-REVIEW** (toolchain floor for consumers, owner information for ZTronCarouselCore).
  - The facts: SPEC §3's Swift 6.3 requirement is for building this repository. A consumer compiles the sources, and three unguarded `@concurrent` functions need Swift 6.2, so consumers need a Swift 6.2+ toolchain. The README states it.
  - ADR-056 records it with the tag and adds it to the owner review list. No code change: letting an older toolchain build would be a code change outside WP-I.
- **WPI-R6: `StorageLocation.custom`'s doc comment** (`Sources/ZTronAssetModel/Policy/StoragePolicy.swift`, a `///` edit only). It says an App Group container is unsupported "unless the app closes the client when it is backgrounded", but `AssetClient` has no close and `shutdown()` is final. Reword it: "unless the app shuts the client down when it is backgrounded and creates a new one when it returns". This matches the README.
- **WPI-R7: the orchestrator's own edit at merge.** A one-line pointer in `docs/MIGRATION.md`, WP-K's file, at step 3: `appleHosted` presumes the app ships the downloader extension and packs, as in the README's "The Apple-hosted tier" section and APPLE-API-VERIFICATION §1.7 (c). The orchestrator makes it, because the docs writer may not edit MIGRATION.md.
- **WPI-R8: the remaining items go to later stages.**
  - The README's documentation map gains rows for the Stage 3/5 reports when they exist.
  - Re-run the quick-start and snippet checks (`.build-i/tools/` logic in I-2/I-3) after any public-signature change and at Stage 5.
  - Update the README sentences that state NEEDS-HUMAN-REVIEW decisions when the owner rules, and switch the Installation snippet to a URL form on release.
- **WPI-R9 (docs merge, 2026-10-24): ratified.** Docs workflow `wf_915bed8f-166`: the ledger plus two rounds; round 2 verified 0 blocking issues.
  - The writer's unruled doc-comment precisions are ratified as written: `AssetEnvironment`'s type doc and `memoryPressure` doc, and `AssetEnvironment.live()`'s doc. The verifier found each true.
  - The orchestrator applied the verifier's last 2 notes: the live seams are listed as examples, now including `HTTPRemoteSource`'s foreground backend.
  - It closed ADR-056's open items: the README cites ADR-056 for the toolchain; MIGRATION.md step 1 asks for Swift 6.2+ pending the owner; ORCHESTRATION.md's swapped Model/Transport counts are fixed.
