# Baseline (Stage 0)

## Prior-art test baseline

| Repository | Ref | CDN-related tests | All tests |
|---|---|---|---|
| ZTronCarouselCore | `main` @ `b4a5f4c` | **0** | 1 (`example()`, assertion-free template) |
| ZTronCarousel | `main` @ `f8c7ccb` | 0 | not counted (no CDN code under test) |

SPEC §2.1 expects ~128 CDN tests; they do not exist on any branch (see `RECON.md` §1). The simulator run of
PROMPT Stage 0 step 3 was **not executed**: the only test is an empty template, and running it would require
resolving five third-party GitHub dependencies of ZTronCarouselCore (outside the network policy of
`CLAUDE.md`) and writing build state into a repository this project must not modify. The characterization
baseline is therefore the prior art's behaviour *as read* (`RECON.md` §5), re-expressed as tests here
(facade parity, legacy migration, compatibility shims).

## This package at skeleton time

- Toolchain: Apple Swift 6.4 (swiftlang-6.4.0.34.1), Xcode 27.0 (27A266a), iPhoneOS27.0 SDK, macOS 27.0, Apple M3 (8 cores, 24 GB).
- `bash Scripts/verify.sh --quick`: `VERIFY: PASS` (6 smoke tests).
- `bash Scripts/verify.sh --full`: `VERIFY: FAIL (2 failed: coverage,trace)` — both for missing implementation only
  (placeholder code below the 90 % critical floor; no requirement-tagged tests yet). Every other step passed,
  including the iOS compile, TSan and the benchmark runner.
