#!/bin/bash
# A bounded synthetic read client. Failed pgbench batches are retried, not hidden.
set -u
duration="$1"
rate="$2"
clients="$3"
start=$SECONDS
batch=0
while (( SECONDS - start < duration )); do
    remaining=$((duration - (SECONDS - start)))
    segment=10
    (( remaining < segment )) && segment=$remaining
    (( segment < 1 )) && break
    batch=$((batch + 1))
    printf '%s BEGIN batch=%s\n' "$(date -u +%FT%T.%NZ)" "$batch"
    cmd=(pgbench -n -h haproxy -p 5001 -U "$PGUSER" -d "$PGDATABASE"
        -c "$clients" -j 2 -C -T "$segment" -R "$rate" -P 2
        -f /work/read.sql -l --log-prefix="/evidence/tx-${batch}")
    printf 'COMMAND'; printf ' %q' "${cmd[@]}"; printf '\n'
    "${cmd[@]}"
    rc=$?
    printf '%s END batch=%s exit=%s\n' "$(date -u +%FT%T.%NZ)" "$batch" "$rc"
done