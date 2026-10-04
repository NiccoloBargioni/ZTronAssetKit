#!/usr/bin/env bash
# Scripts/verify.sh — the single source of truth for "is it done?".
#
#   Scripts/verify.sh --quick       toolchain + debug build + one test run          (inner loop)
#   Scripts/verify.sh --full        EVERYTHING below                                (Definition of Done)
#   Scripts/verify.sh --perf        benchmarks only
#   Scripts/verify.sh --gates-only  gate self-test + trace/unsafe/docs + harness integrity
#
# Final line is exactly `VERIFY: PASS` or `VERIFY: FAIL (<n> failed: a,b,c)`; the exit code mirrors it.
# Parallel agents: set SWIFTPM_SCRATCH=.build-<agent> so concurrent SwiftPM runs never share a build dir.
#
# STATUS: written without access to a Swift toolchain. The control flow and every Python gate are tested;
# the exact swift/xcodebuild flags are NOT. Stage 0 must run this on the real toolchain and fix the
# command lines — then freeze it (git tag harness-frozen). Do not weaken a gate to make it pass.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

MODE="${1:---full}"
CFG="Scripts/quality-gates.json"
SCRATCH="${SWIFTPM_SCRATCH:-.build}"
LOGS=".verify-logs"
mkdir -p "$LOGS"
FAILED=()

cfgval() {  # cfgval swift.min_toolchain
  python3 - "$CFG" "$1" <<'PY'
import json, sys
node = json.load(open(sys.argv[1]))
for part in sys.argv[2].split("."):
    node = node[part]
print(node)
PY
}

# run_logged <name> <cmd...> : full output goes to .verify-logs/<name>.log; the transcript only gets a summary.
run_logged() {
  local name="$1"; shift
  local log="$LOGS/${name//[^A-Za-z0-9_.-]/_}.log"
  echo "::: STEP $name"
  if "$@" >"$log" 2>&1; then
    grep -E "Test run with|Executed [0-9]+ tests|Build complete|\*\* BUILD SUCCEEDED|COVERAGE|TRACE|UNSAFE|DOCS|SELFTEST|HARNESS|GATES-CONFIG|toolchain OK|Swift version" "$log" | tail -25
    echo "::: OK   $name"
  else
    tail -40 "$log"
    echo "::: FAIL $name (full log: $log)"
    FAILED+=("$name")
  fi
}

# ---------------------------------------------------------------------------------------------- steps
toolchain() {
  local out; out="$(swift --version 2>&1)" || { echo "swift not found on PATH"; return 1; }
  echo "$out" | head -2
  python3 - "$out" "$(cfgval swift.min_toolchain)" <<'PY'
import re, sys
out, need = sys.argv[1], sys.argv[2]
m = re.search(r"Swift version (\d+)\.(\d+)", out)
if not m:
    print("cannot parse `swift --version`"); sys.exit(1)
have, want = (int(m.group(1)), int(m.group(2))), tuple(int(x) for x in need.split(".")[:2])
if have < want:
    print(f"need Swift >= {need}, have {have[0]}.{have[1]}"); sys.exit(1)
print(f"toolchain OK: Swift {have[0]}.{have[1]} >= {need}")
PY
}

harness_integrity() {
  echo "GATES-CONFIG sha256=$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$CFG")"
  if git rev-parse -q --verify refs/tags/harness-frozen >/dev/null 2>&1; then
    if git diff --quiet harness-frozen -- Scripts/ && [ -z "$(git status --porcelain -- Scripts/)" ]; then
      echo "HARNESS: unchanged since harness-frozen"
    else
      echo "HARNESS: MODIFIED since harness-frozen — the agent may not edit Scripts/ after Stage 0 (rule G1)"
      git diff --stat harness-frozen -- Scripts/
      return 1
    fi
  else
    echo "HARNESS: not frozen yet (Stage 0 unfinished) — tag it: git tag harness-frozen"
  fi
}

gates_selftest() { python3 Scripts/gates.py selftest; }
build_debug()    { swift build --scratch-path "$SCRATCH" -Xswiftc -warnings-as-errors; }
build_release()  { swift build -c release --scratch-path "$SCRATCH" -Xswiftc -warnings-as-errors; }
build_ios() {
  command -v xcodebuild >/dev/null 2>&1 || { echo "xcodebuild not found: iOS compile check cannot run"; return 1; }
  xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath "$SCRATCH/xcode" \
    build OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet
}
run_tests()      { swift test --scratch-path "$SCRATCH" --enable-code-coverage --skip Benchmarks; }
coverage_gate() {
  local json; json="$(swift test --scratch-path "$SCRATCH" --show-codecov-path 2>/dev/null | tail -1)"
  [ -f "$json" ] || { echo "coverage JSON not found at '$json' (did a test run with --enable-code-coverage happen?)"; return 1; }
  python3 Scripts/gates.py coverage --json "$json" --config "$CFG"
}
tsan_tests()     { swift test --scratch-path "$SCRATCH-tsan" --sanitize=thread --skip Benchmarks; }
perf_tests()     { swift test -c release --scratch-path "$SCRATCH-perf" -Xswiftc -enable-testing --filter Benchmarks; }
trace_gate()     { python3 Scripts/gates.py trace --spec SPEC.md --tests Tests --config "$CFG" --write docs/TRACEABILITY.md; }
unsafe_gate()    { python3 Scripts/gates.py unsafe --sources Sources --audit docs/UNSAFE-AUDIT.md --config "$CFG"; }
docs_gate()      { python3 Scripts/gates.py docs --sources Sources --config "$CFG"; }

# ---------------------------------------------------------------------------------------------- modes
case "$MODE" in
  --quick)
    run_logged harness  harness_integrity
    run_logged toolchain toolchain
    run_logged build-debug build_debug
    run_logged tests run_tests
    ;;
  --perf)
    run_logged toolchain toolchain
    run_logged benchmarks perf_tests
    ;;
  --gates-only)
    run_logged gates-selftest gates_selftest
    run_logged harness harness_integrity
    run_logged trace trace_gate
    run_logged unsafe unsafe_gate
    run_logged docs docs_gate
    ;;
  --full)
    run_logged gates-selftest gates_selftest
    run_logged harness harness_integrity
    run_logged toolchain toolchain
    run_logged build-debug build_debug
    run_logged build-release build_release
    run_logged build-ios build_ios
    repeats="$(cfgval tests.full_run_repeats)"
    for i in $(seq 1 "$repeats"); do
      run_logged "tests-run-$i-of-$repeats" run_tests
    done
    run_logged coverage coverage_gate
    if [ "$(cfgval tests.tsan)" = "True" ]; then run_logged tsan tsan_tests; fi
    run_logged benchmarks perf_tests
    run_logged trace trace_gate
    run_logged unsafe unsafe_gate
    run_logged docs docs_gate
    ;;
  *)
    echo "usage: Scripts/verify.sh [--quick|--full|--perf|--gates-only]"; exit 2 ;;
esac

# ---------------------------------------------------------------------------------------------- verdict
echo "::: SUMMARY mode=$MODE steps-failed=${#FAILED[@]}"
if [ "${#FAILED[@]}" -eq 0 ]; then
  echo "VERIFY: PASS"
  exit 0
fi
( IFS=,; echo "VERIFY: FAIL (${#FAILED[@]} failed: ${FAILED[*]})" )
exit 1
