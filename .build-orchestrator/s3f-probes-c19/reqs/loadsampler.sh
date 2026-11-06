#!/bin/bash
# usage: loadsampler.sh <outfile> <interval-seconds>
out="$1"; iv="${2:-5}"
while true; do echo "$(date +%H:%M:%S) $(sysctl -n vm.loadavg)" >> "$out"; sleep "$iv"; done
