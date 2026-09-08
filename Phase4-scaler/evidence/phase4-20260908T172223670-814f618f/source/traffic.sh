#!/bin/bash
set -euo pipefail
# PGDATABASE is supplied through the environment; --debug is deliberately long-form.
# Each transaction reconnects so existing sessions do not pin traffic to baseline.
duration=${1:?duration}; rate=${2:?rate}; clients=${3:?clients}
printf 'traffic start UTC=%s duration=%s offered_tps=%s clients=%s\n' "$(date -u +%FT%TZ)" "$duration" "$rate" "$clients"
exec pgbench --debug --random-seed=42 -n -C -c "$clients" -j 2 \
  -T "$duration" -R "$rate" -P 2 -f /work/read.sql \
  -l --log-prefix=/evidence/tx