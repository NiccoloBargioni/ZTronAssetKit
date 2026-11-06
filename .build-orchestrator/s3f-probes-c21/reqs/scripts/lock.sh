# Sourced: take_lock / drop_lock for the shared sim.lock (S3-R22 item 3).
LOCK=/Users/admin/Documents/ZTronAssetKit/.build-orchestrator/sim.lock
take_lock() {
  while ! mkdir "$LOCK" 2>/dev/null; do
    if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +45 2>/dev/null)" ]; then
      echo "$(date +%H:%M:%S) stale lock removed" >> "$S/logs/lock.txt"; rmdir "$LOCK" 2>/dev/null
    fi
    sleep 10
  done
  echo "verify-s3f-c21-reqs $(date +%H:%M:%S)" > "$LOCK/owner" 2>/dev/null
  echo "$(date +%H:%M:%S) lock taken ($1)" >> "$S/logs/lock.txt"
}
drop_lock() {
  rm -f "$LOCK/owner"; rmdir "$LOCK" 2>/dev/null
  echo "$(date +%H:%M:%S) lock released ($1)" >> "$S/logs/lock.txt"
}
