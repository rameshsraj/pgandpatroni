#!/bin/bash
set -euo pipefail
# PGDATABASE is supplied through the environment; --debug is deliberately long-form.
# Each transaction reconnects so existing sessions do not pin traffic to baseline.
duration=${1:?duration}; rate=${2:?rate}; clients=${3:?clients}
printf 'traffic start UTC=%s duration=%s offered_tps=%s clients=%s\n' "$(date -u +%FT%TZ)" "$duration" "$rate" "$clients"
stop=0
trap 'stop=1' TERM INT
started=$SECONDS
batch=0
# Docker signals this shell only. Let the foreground bounded batch finish and flush
# its transaction logs before honoring stop; never interrupt pgbench mid-record.
while (( SECONDS - started < duration && stop == 0 )); do
  remaining=$((duration - (SECONDS - started)))
  segment=10
  (( remaining < segment )) && segment=$remaining
  batch=$((batch + 1))
  printf 'batch start UTC=%s batch=%s seconds=%s\n' "$(date -u +%FT%TZ)" "$batch" "$segment"
  pgbench --debug --random-seed=42 -n -C -c "$clients" -j 2 \
    -T "$segment" -R "$rate" -P 2 -f /work/read.sql \
    -l --log-prefix="/evidence/tx.$batch"
  printf 'batch complete UTC=%s batch=%s exit=0\n' "$(date -u +%FT%TZ)" "$batch"
done
printf 'traffic complete UTC=%s stop_requested=%s\n' "$(date -u +%FT%TZ)" "$stop"
