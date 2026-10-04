# Decisions (ADRs)

Format: context · options · decision · consequences. **NEEDS-HUMAN-REVIEW** marks choices the owner should confirm.

---

## ADR-001 — Storage location · **NEEDS-HUMAN-REVIEW**
- **Context.** Promise 1 ("no mid-use waiting") cannot hold if the OS may silently purge essential assets. The prior art used `Library/Caches/CDNAssets` with the sync stamp in `UserDefaults` (D-6).
- **Options.** (a) `Caches/` — OS-purgeable, no backup cost, no module-owned eviction needed. (b) `Application Support/` excluded from backup, module-owned quota/eviction. (c) `Documents/` — visible in Files, backed up.
- **Decision.** (b) by default: `Application Support/ZTronAssetKit/v1/`, `isExcludedFromBackup = true`, file protection `completeUntilFirstUserAuthentication`. `StorageLocation.caches` and `.custom(URL)` remain selectable (R-STO-10).
- **Consequences.** The module must own eviction (R-CLN-4) and OS-purge recovery still matters for `.caches` (R-CLN-7). Storage is not reclaimed by the OS under pressure — the budget and `purge` API are the user's levers.

## ADR-002 — On-disk layout and index format · **NEEDS-HUMAN-REVIEW**
- **Context.** D-10: a pretty-path layout makes a directory change a set of non-atomic moves; D-14: manifest text became path components.
- **Options.** (a) Keep pretty paths. (b) Content-addressed blobs + one atomically replaced index (SPEC §4.3). (c) SQLite.
- **Decision.** (b). `blobs/<aa>/<sha256>.<ext>`, `staging/<uuid>.part|.resume`, `store.lock`, and `index.bin`: a compact, versioned binary format (magic, `schemaVersion`, `generation`, length-prefixed records, SHA-256 trailer to detect torn writes) replaced via write-temp → `F_FULLFSYNC` → rename. Final details are fixed in `ARCHITECTURE.md` (Stage 1). SQLite is rejected: a dependency-free binary index meets P-2 and keeps crash enumeration (R-STO-5) tractable through the `FileSystem` seam.
- **Consequences.** Directory changes are index edits; identical bytes dedupe; the index is rebuildable from blob names + the last manifest. Legacy files are adopted by hash (R-STO-11). Debugging needs a dump tool rather than `cat` (provided via `diagnosticReport()`).

## ADR-003 — Blocking work off the cooperative pool
- **Context.** C2 / §4.2: hashing, copying and directory enumeration must not block a cooperative-pool thread for more than ~10 ms. At an iOS 15 floor there is no `Mutex`, `OSAllocatedUnfairLock` or custom executors.
- **Options.** (a) Dedicated GCD queue(s) bridged with `withCheckedThrowingContinuation` + `withTaskCancellationHandler`. (b) Chunked work on the pool with `Task.yield()` between chunks.
- **Decision.** (a) for anything that touches the file system: production code never performs a blocking file-system call directly from an async context; it submits *bounded* units (one rename, one ≤ 1 MiB read, one index commit) to an injected blocking-I/O executor — a dedicated `DispatchQueue` in `.live`, bridged with `withCheckedThrowingContinuation`. Long operations (hashing 256 MiB, enumerating 10,000 blobs) are decomposed into such units with `Task.checkCancellation()` between them, so cancellation needs no shared mutable flag (no lock, no `@unchecked`). CPU-only work on ≤ 1 MiB (one SHA-256 update, < 1 ms) may run inline. (b) is used for pure in-memory work (diff/plan over 10,000 entries), yielding periodically. Stage 1 fixes the exact interfaces in `ARCHITECTURE.md`.
- **Consequences.** P-9 (heartbeat gap) and P-6 (≥ 0.7× one-shot hash throughput despite the hops) prove it. Tests inject an executor that runs inline so they stay deterministic.

## ADR-004 — Typed throws
- **Context.** R-ENV-6 (SHOULD). Typed throws are a compile-time feature; concrete error types back-deploy.
- **Decision.** Public async APIs throw `AssetError` concretely (`throws(AssetError)`) wherever the compiler accepts it at the iOS 15 floor; APIs that run caller-supplied throwing closures (`withAsset`) stay untyped. Internal layers use their own closed error types (`ManifestError`, `TransferError`, `StoreError`) mapped once at the facade.
- **Consequences.** Callers can switch exhaustively over `AssetError` (R-CAR-7).

## ADR-005 — Platform floors · **NEEDS-HUMAN-REVIEW**
- **Decision.** iOS **15.0** (owner requirement, matches ZTronCarouselCore; R-ENV-2). macOS **12.0** for the test host — the macOS release that matches iOS 15's API set (`OSSignposter`, async `URLSession`, `os.Logger`), so code that compiles for macOS tests the same availability surface it ships on iOS. The Apple-hosted tier is `@available(iOS 26.0, macOS 26.0, *)` behind `#if canImport(BackgroundAssets)`.

## ADR-006 — Standalone package; PROMPT Stage 4 replaced · **NEEDS-HUMAN-REVIEW**
- **Context.** The owner instructed (2026-10-04): build a standalone package, do not modify any other package; read-only access to the siblings only. PROMPT Stage 4 planned the adoption inside `ZTronCarouselCore` on a branch.
- **Decision.** No file outside this repository is written. R-CAR-6 is delivered *inside this repo*: drop-in compatibility shims for every pre-existing public CDN symbol, compiled and exercised by a test target here (so the shims are proven against the real `AssetClient`), plus `docs/MIGRATION.md` describing how to adopt them in ZTronCarouselCore. Q-10 ("pre-existing CDN tests pass through the shims in ZTronCarouselCore") is reported as **not verified** in `VERIFICATION.md` — and there were no pre-existing CDN tests to port (`BASELINE.md`).
- **Consequences.** Adoption is a follow-up the owner performs; `verify.sh` never depended on it.

## ADR-007 — Harness fixes before the freeze
- **Context.** PROMPT Stage 0 step 6 — make the harness real on this toolchain.
- **Decision.** Two fixes, both strengthening: (1) Swift 6.4's `swiftbuild` engine builds one `.xctest` bundle per test target but `--show-codecov-path` exports coverage for only one of them, so the coverage gate re-exports the merged profile over every bundle (`llvm-cov export -summary-only`); (2) `gates.py` filters on `"/Sources/"`, which relative paths never contain, so the unsafe and docs gates checked nothing — `verify.sh` now passes absolute paths. Both were proven: per-target coverage appears for all six targets; an injected `@unchecked Sendable` and an undocumented `public func` now fail their gates. `quality-gates.json` is untouched (sha256 `2725907c…026f`).

## ADR-008 — Fixtures for the "shipped example manifests"
- **Context.** `Manifests/` does not exist in either sibling (RECON §1).
- **Decision.** Author the series under `Tests/Fixtures/manifests/` from real fixture payloads (so every checksum is a real SHA-256): AWS tier (`remotePath = media/<sha256[:16]>/<name>.<ext>`) and Apple tier (`remotePath = <packID>/<path>`), each as v1 → checksum change → directory change → removal, in both wire shapes (bare array and envelope).

## ADR-009 — Worktree location
- **Context.** CLAUDE.md P2 suggests `../asset-kit-wt-<wp>`; this session may only write inside this repository.
- **Decision.** Worktrees live at `.worktrees/<wp>` (git-ignored), branches `wp/<wp>`. Same isolation, same merge discipline.

## ADR-010 — Benchmarks target
- **Decision.** All `P-n` benchmarks live in the test target `ZTronAssetKitBenchmarks` (suites named `*Benchmarks`), so `--skip Benchmarks` / `--filter Benchmarks` select them exactly. Thresholds are read at run time from `Scripts/quality-gates.json` (located via `#filePath`).

## ADR-011 — No test-only dependencies
- **Decision.** None. Swift Testing ships with the toolchain; the loopback HTTP server is hand-written on `Network.framework` in `ZTronAssetTestSupport`.
