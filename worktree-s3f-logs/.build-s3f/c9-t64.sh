#!/bin/bash
# S3-R13: export HEAD, set tools 6.4 in the export only, build debug (with tests, -warnings-as-errors) and release
WT=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
cd $WT
rm -rf .build-s3f/t64 && mkdir -p .build-s3f/t64 .build-s3f/t64-build/tmp/mc
git archive HEAD | tar -x -C .build-s3f/t64
cd .build-s3f/t64 && sed -i '' '1s#.*#// swift-tools-version: 6.4#' Package.swift
echo "HEAD $(git -C $WT rev-parse --short HEAD); $(head -1 Package.swift)"
export TMPDIR=$WT/.build-s3f/t64-build/tmp/ CLANG_MODULE_CACHE_PATH=$WT/.build-s3f/t64-build/tmp/mc
swift build --build-tests --scratch-path ../t64-build -Xswiftc -warnings-as-errors > ../c9-t64f-debug.log 2>&1; echo "debug exit $? warnings $(grep -c 'warning:' ../c9-t64f-debug.log) errors $(grep -c 'error:' ../c9-t64f-debug.log)"
sed 's/\x1b\[[0-9;]*m//g' ../c9-t64f-debug.log | tail -1
swift build -c release --scratch-path ../t64-build > ../c9-t64f-release.log 2>&1; echo "release exit $? warnings $(grep -c 'warning:' ../c9-t64f-release.log)"
sed 's/\x1b\[[0-9;]*m//g' ../c9-t64f-release.log | tail -1
swift --version 2>&1 | head -1
