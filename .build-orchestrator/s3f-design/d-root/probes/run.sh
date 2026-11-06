#!/bin/bash
# usage: run.sh <log> <swift args...>   (runs in the d-root worktree with its own scratch, TMPDIR and module cache)
WT=/Users/admin/Documents/ZTronAssetKit/.build-s3f-d-root-wt
LOG=$1; shift
export TMPDIR=$WT/.build-x/tmp/ CLANG_MODULE_CACHE_PATH=$WT/.build-x/tmp/mc
cd $WT
"$@" > $LOG 2>&1
echo "exit $?"
