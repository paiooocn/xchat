#!/usr/bin/env bash
# Poll the build log every 120s until BUILD_DONE / failure, writing snapshots
# to dist/poll.log.
LOG="/mnt/kd/dop/pcr/aicoding/ds-xchat/dist/build.log"
OUT="/mnt/kd/dop/pcr/aicoding/ds-xchat/dist/poll.log"
: > "$OUT"
i=0
while true; do
  i=$((i+1))
  echo "----- poll #$i  $(date '+%H:%M:%S') -----" >> "$OUT"
  tail -5 "$LOG" >> "$OUT" 2>&1
  if grep -q "BUILD_DONE" "$LOG" 2>/dev/null; then
    echo "==> POLLER: build succeeded" >> "$OUT"
    break
  fi
  if grep -qiE "FAILURE:|Error:|Gradle task .* failed|BUILD FAILED|Exception" "$LOG" 2>/dev/null; then
    echo "==> POLLER: build may have failed" >> "$OUT"
    break
  fi
  sleep 120
done
echo "==> POLLER_EXIT" >> "$OUT"
