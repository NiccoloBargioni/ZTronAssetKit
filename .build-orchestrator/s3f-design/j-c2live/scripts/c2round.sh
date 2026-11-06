#!/bin/bash
# usage: c2round.sh <round> <suites...> ; runs each suite for base, defer, budget, root in turn (interleaved)
J=/Users/admin/Documents/ZTronAssetKit/.build-orchestrator/s3f-design/j-c2live/scripts
R=$1; shift
for suite in "$@"; do
  for k in base defer budget root; do
    bash $J/test.sh $k release c2-$R-$suite-$k --filter "$suite"
  done
done
