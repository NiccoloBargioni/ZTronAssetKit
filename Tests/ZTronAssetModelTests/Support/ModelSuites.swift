import Testing

/// The one parent of every WP-A test suite in this target, serialized (fix round 2).
///
/// R-MAN-3's heap figures are process-wide (`DecodeMeasurement`): whatever another test allocates while a decode is
/// measured adds to the sample, and R-MAN-2's 32 MiB boundaries or the source scans allocate tens of megabytes.
/// Swift Testing runs top-level suites in parallel, so each WP-A suite is nested here (`extension ModelSuites { … }`)
/// and none runs while another does. Each test target is its own process, so other targets never share the heap.
/// The orchestrator's contract suites in this target (`ModelContractTests.swift`, `PackageScanContractTests.swift`)
/// stay top-level and run beside this one at start-up: the fuzz test's limit-scale cases are measured only after its
/// small corpus has run for seconds, and the one quick heap assertion keeps the lowest peak of three decodes.
@Suite(.serialized)
struct ModelSuites {}
