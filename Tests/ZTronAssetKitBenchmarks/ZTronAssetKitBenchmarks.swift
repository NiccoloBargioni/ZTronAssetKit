import Testing

/// The one parent suite of every benchmark (SPEC §6, sync-2 S2-14, ADR-010 as amended by ADR-046).
///
/// `.serialized` applies to every suite nested in it, so no two benchmarks run at once: independent top-level
/// suites would run concurrently and contaminate the timing and memory budgets (P-1, P-6, P-7, P-9, P-12). The name
/// contains "Benchmarks", so `--skip Benchmarks` / `--filter Benchmarks` select exactly this tree. Each work package
/// adds its benchmarks as a nested suite in an `extension ZTronAssetKitBenchmarks` in its own file
/// (ARCHITECTURE §11: `BenchModel.swift` WP-A, `BenchStorage.swift` WP-B, `BenchTransport.swift` WP-D,
/// `BenchSync.swift` WP-F, `BenchKit.swift` WP-G), never as a new top-level suite.
@Suite(.serialized)
struct ZTronAssetKitBenchmarks {}
