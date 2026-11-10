#!/bin/bash
# Checklist item 5: re-apply each of the 11 Stage 3 survivors (ORCHESTRATION.md, M-S-07, 08, 11, 20; M-N-09, 12, 14,
# 16, 20, 22, 39) on the merged head and show a test fails against it (S3-R3). One file is mutated at a time and
# restored with `git checkout -- <file>` right after its run. A mutant that survives its own target is re-run against
# every non-benchmark target before it is called a survivor.
set -u
R=/Users/admin/Documents/ZTronAssetKit
M=$R/.worktrees/merge-check
D=$R/.build-orchestrator/s3-mutants
O=$R/.build-orch/mut-recheck
mkdir -p "$O"
cd "$M" || exit 2
[ "$(git rev-parse HEAD)" = "$(git rev-parse e840b0e)" ] || { echo "HEAD is not e840b0e" | tee "$O/summary.txt"; exit 2; }
git status --short > "$O/status-before.txt"
: > "$O/summary.txt"

run_target() { # $1 log, $2 filter (empty = all targets)
    {
        date '+%H:%M:%S'; sysctl -n vm.loadavg
        if [ -n "$2" ]; then
            swift test --scratch-path .build-orch-merge --enable-code-coverage --skip Benchmarks --filter "$2" 2>&1
        else
            swift test --scratch-path .build-orch-merge --enable-code-coverage --skip Benchmarks 2>&1
        fi
        echo "exit $?"
        date '+%H:%M:%S'; sysctl -n vm.loadavg
    } > "$1" 2>&1
}

verdict_of() { # $1 log
    local ex
    ex=$(grep '^exit ' "$1" | tail -1 | cut -d' ' -f2)
    if [ "$ex" = "0" ]; then echo SURVIVED
    elif grep -q 'Test run with' "$1"; then echo KILLED
    else echo STILLBORN
    fi
}

for spec in "S-07 storage ZTronAssetStorageTests" "S-08 storage ZTronAssetStorageTests" \
            "S-11 storage ZTronAssetStorageTests" "S-20 storage ZTronAssetStorageTests" \
            "N-09 network ZTronAssetSyncTests" "N-12 network ZTronAssetSyncTests" \
            "N-14 network ZTronAssetSyncTests" "N-16 network ZTronAssetSyncTests" \
            "N-20 network ZTronAssetSyncTests" "N-22 network ZTronAssetTransportTests" \
            "N-39 network ZTronAssetSyncTests"; do
    set -- $spec
    id="M-$1"; target="$3"
    diff="$D/$2/$id.diff"
    [ -f "$O/$id.reapplied.diff" ] && diff="$O/$id.reapplied.diff"
    file=$(grep '^+++ b/' "$diff" | sed 's|^+++ b/||')
    if ! git diff --quiet -- "$file"; then echo "$id SKIPPED ($file not clean)" >> "$O/summary.txt"; continue; fi
    if ! git apply "$diff"; then echo "$id NOT-APPLIED ($diff)" >> "$O/summary.txt"; continue; fi
    git diff -- "$file" > "$O/$id.applied.diff"
    run_target "$O/$id.log" "$target"
    v=$(verdict_of "$O/$id.log")
    wide=""
    if [ "$v" = SURVIVED ]; then
        run_target "$O/$id.all.log" ""
        v=$(verdict_of "$O/$id.all.log")
        wide=" (re-run on all targets)"
    fi
    git checkout -- "$file"
    log="$O/$id.log"; [ -n "$wide" ] && log="$O/$id.all.log"
    failing=$(sed -E 's/\x1b\[[0-9;]*m//g' "$log" | grep -E '^✘ Test .* (failed after|recorded an issue)' \
        | sed -E 's/^✘ Test ("[^"]*"|[^ ]*).*/\1/' | sort -u | head -5 | tr '\n' ';')
    echo "$id $v$wide target=$target diff=$(basename "$diff") failing=[$failing]" >> "$O/summary.txt"
done
git status --short > "$O/status-after.txt"
cat "$O/summary.txt"
echo "status before:"; cat "$O/status-before.txt"; echo "status after:"; cat "$O/status-after.txt"
