Confirmation of the S3-PERF findings (independent agent), base s3-base b5796ba, detached worktree .build-s3-confirm-performance-wt (removed), scratch .build-s3-confirm-performance.
Release = swift build/test -c release -Xswiftc -enable-testing. 1-minute load average start -> end of each run:
run01a (S3-PERF-01, unmodified): 37.8 -> 71.5. run02a (S3-PERF-02, unmodified): 63.2 -> 65.1. run040506a (04, 05, 06 unmodified): 63.8 -> 70.3.
run0102b (wall-time instrumentation of performShutdown's first turn and applied()): 59.7 -> 64.9.
run0405b (reaper patched with a cursor; publish control with a non-retaining sink): 70.0 -> 78.1.
run0102c (wall + thread-CPU instrumentation): 83.1 -> 93.2.
Unlink probe (swiftc -O -swift-version 5): matrix 105.7 -> 96.3; period 93.7 -> 93.4.
Instrumentation and the reaper patch are experiment-only diffs (*.diff); nothing was committed.
