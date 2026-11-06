# s3f close-out cycle 4, requirements lens: evidence

Worktree `.worktrees/s3f` at c2a78a0 (code HEAD 07ca8cb).

- `mut-noSweepParkHook.diff`, `mut-noSweepRequeueHook.diff`: the two cycle-4 hooks of `sweepSpaceParked` removed in a
  scratch copy; `run-m1.summary.log`, `run-m2.summary.log` show the committed test (and PROBE-C3-SPACE for m1) failing;
  `run-head.summary.log` both passing at HEAD (PROBE-C3-SPACE = `.build-orchestrator/s3f-probes-c3/VerifyC3CorrectProbes.swift`, unchanged).
- `mut-noDispatchOwedFlag.txt` + `run-m3.summary.log`: the recorded survivor still survives (405 passed).
- `tsan-single.*`: `swift test --sanitize=thread --filter ZTronAssetSyncTests`, one process; `tsan-paired-*`: the same
  bundle run twice at once through swiftpm-testing-helper (DYLD_INSERT_LIBRARIES = the bundle's
  libclang_rt.tsan_osx_dynamic.dylib, DYLD_FRAMEWORK_PATH/DYLD_LIBRARY_PATH = MacOSX platform Developer dirs).
  Load files: time and 1-min load every 10 s.
