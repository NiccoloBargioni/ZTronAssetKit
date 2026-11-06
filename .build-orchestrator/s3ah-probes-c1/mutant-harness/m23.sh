#!/bin/bash
cd "$(dirname "$0")"
T=Sources/ZTronAssetModel/Identity/TransferID.swift
E=Sources/ZTronAssetModel/Environment/Time.swift
MS=Sources/ZTronAssetTestSupport/ManualTimeSource.swift
restore() { cp orig/TransferID.swift.head $T; cp orig/Time.swift.head $E; cp orig/ManualTimeSource.swift.head $MS; }
restore
cp orig/TransferID.swift.base $T; bash run.sh M2-transferid-base; restore
cp orig/Time.swift.base $E; bash run.sh M3a-time-base; restore
cp orig/ManualTimeSource.swift.base $MS; bash run.sh M3b-mts-base-time-head; restore
cp orig/ManualTimeSource.swift.base $MS; cp orig/Time.swift.base $E; bash run.sh M3c-both-base; restore
python3 mutate.py $MS '            state.uptime = MonotonicInstant(nanoseconds: overflow ? UInt64.max : uptime)
' '            _ = (uptime, overflow)
' && bash run.sh M3d-no-uptime; restore
python3 mutate.py $MS '            state.wall = state.wall.addingTimeInterval(deadline.seconds(since: state.monotonic))
' '' && bash run.sh M3e-no-wall; restore
echo ALLDONE
