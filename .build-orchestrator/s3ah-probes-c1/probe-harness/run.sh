#!/bin/bash
P="$(cd "$(dirname "$0")" && pwd)"; S="$(dirname "$P")"
export TMPDIR=$S/tmp CLANG_MODULE_CACHE_PATH=$S/tmp/mc LLVM_PROFILE_FILE=$S/tmp/prof-%p.profraw
cd "$P"; uptime > "$P/$1.log"
swift test --scratch-path "$P/.build-p" >> "$P/$1.log" 2>&1; echo "exit $?" >> "$P/$1.log"
