#!/bin/bash
# Summarises test logs: the run line, issue, time-limit, sanitizer and warning counts.
for f in "$@"; do
  [ -f "$f" ] || { echo "$f: missing"; continue; }
  echo "== $(basename $f): $(grep -E "Test run with" "$f" | tail -2 | tr '\n' ' ' | cut -c1-200)"
  echo "   issues $(grep -c "recorded an issue" "$f") timelimit $(grep -ci "time limit" "$f") tsan $(grep -c "ThreadSanitizer" "$f") warning $(grep -c "warning:" "$f") crash $(grep -ciE "signal|crashed|fatal error" "$f")"
  grep "recorded an issue" "$f" | head -5 | cut -c1-300
done
