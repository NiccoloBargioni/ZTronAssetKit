#!/bin/bash
# usage: run.sh <label> ; runs the s3ah-relevant tests in the mutant harness and keeps summary lines
M="$(cd "$(dirname "$0")" && pwd)"
S="$(dirname "$M")"
export TMPDIR=$S/tmp CLANG_MODULE_CACHE_PATH=$S/tmp/mc LLVM_PROFILE_FILE=$S/tmp/prof-%p.profraw
cd "$M"
F='ManifestValidationTests|ModelBehaviourTests|TestSupportManualTimeSourceTests'
uptime > "$M/$1.log"
swift test --scratch-path "$M/.build-m" --filter "$F" >> "$M/$1.log" 2>&1
echo "exit $?" >> "$M/$1.log"
uptime >> "$M/$1.log"
