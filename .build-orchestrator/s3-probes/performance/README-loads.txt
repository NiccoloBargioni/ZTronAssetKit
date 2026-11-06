S3-PERF probe runs (release = swift test -c release -Xswiftc -enable-testing; base s3-base b5796ba), 1-minute load average at start -> end:
S3-PERF-01 shutdown: debug 60.6->54.9 (best 51.1 ms); release run A 12.1->65.5 (best 18.73 ms); B 52.7->49.0 (best 19.66); C 49.0->42.4 (best 21.24); D 14.5->13.3 (best 17.01 ms; control R-SYN-4 handle release 3.98 ms in the same run); E dispatch executors 31.9->49.5 (best 18.96).
S3-PERF-02 refresh under group: inline executors 38.0->45.3 (best 17.28 ms); dispatch executors 31.9->49.5 (best 19.10); with diagnostic 50.8->47.7 (best 16.94; followApplied alone 9.99-10.44 ms, key sort 2.85-2.95 ms).
S3-PERF-03 unlink probe: run1 76.1->77.6, run2 87.4->96.5, run3 44.8->41.8, run4 31.2->28.4, run5 41.7->48.3, run6 12.9->11.2 (the clean run), run7 25.0->30.6.
S3-PERF-04 reap: 12.1->65.5 and 39.8->32.8. S3-PERF-05 publish: 12.1->65.5. S3-PERF-06: 20.7->18.3.
