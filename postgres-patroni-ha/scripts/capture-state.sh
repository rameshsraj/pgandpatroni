#!/bin/bash
# ============================================================
# capture-state.sh — Capture complete cluster state snapshot
# ============================================================
# Usage: ./scripts/capture-state.sh [label]
# Example: ./scripts/capture-state.sh before-failover
# ============================================================
set -e

LABEL="${1:-snapshot}"
TIMESTAMP=$(date -u '+%Y%m%d_%H%M%S')
OUTDIR="test-results/${LABEL}"
mkdir -p "$OUTDIR"

if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

APP_USER="${POSTGRES_APP_USER:-appuser}"
APP_PASS="${POSTGRES_APP_PASSWORD:-appuser-ha-lab-2024}"
APP_DB="${POSTGRES_APP_DATABASE:-appdb}"
SU_USER="${POSTGRES_SUPERUSER:-postgres}"
SU_PASS="${POSTGRES_SUPERUSER_PASSWORD:-postgres-ha-lab-2024}"

echo "Capturing cluster state: $LABEL ($TIMESTAMP)"
echo "Output directory: $OUTDIR"

# 1. Docker status
echo "  [1/10] Docker status..."
docker compose ps > "$OUTDIR/docker-compose-ps.txt" 2>&1 || true
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" > "$OUTDIR/docker-ps.txt" 2>&1 || true

# 2. Patroni cluster status
echo "  [2/10] Patroni cluster status..."
NODE=$(docker ps --filter "name=pg-node" --format '{{.Names}}' | head -1)
if [ -n "$NODE" ]; then
    docker exec "$NODE" patronictl -c /etc/patroni/patroni.yml list > "$OUTDIR/patroni-list.txt" 2>&1 || true
fi

# 3. etcd status
echo "  [3/10] etcd status..."
docker exec etcd etcdctl endpoint health --endpoints=http://localhost:2379 > "$OUTDIR/etcd-health.txt" 2>&1 || true
docker exec etcd etcdctl get /service/pg-ha-cluster --prefix --print-value-only > "$OUTDIR/etcd-keys.txt" 2>&1 || true

# 4. HAProxy status
echo "  [4/10] HAProxy status..."
curl -sf http://localhost:7000/\;csv > "$OUTDIR/haproxy-stats.csv" 2>/dev/null || echo "HAProxy not reachable" > "$OUTDIR/haproxy-stats.csv"

# 5. PostgreSQL node roles
echo "  [5/10] PostgreSQL node roles..."
for n in pg-node-1 pg-node-2 pg-node-3; do
    echo "=== $n ===" >> "$OUTDIR/pg-roles.txt"
    docker exec "$n" psql -U "$SU_USER" -d postgres -c "SELECT pg_is_in_recovery(), inet_server_addr(), current_setting('server_version');" >> "$OUTDIR/pg-roles.txt" 2>&1 || echo "$n: not reachable" >> "$OUTDIR/pg-roles.txt"
done

# 6. Replication status (from primary)
echo "  [6/10] Replication status..."
PGPASSWORD="$SU_PASS" psql -h localhost -p 5000 -U "$SU_USER" -d postgres -c "
SELECT pid, application_name, client_addr, state, sync_state,
       sent_lsn, write_lsn, flush_lsn, replay_lsn
FROM pg_stat_replication;
" > "$OUTDIR/pg-replication.txt" 2>&1 || echo "Could not query replication" > "$OUTDIR/pg-replication.txt"

# 7. Database row counts
echo "  [7/10] Database row counts..."
PGPASSWORD="$APP_PASS" psql -h localhost -p 5000 -U "$APP_USER" -d "$APP_DB" -c "
SELECT 'customers' AS tbl, count(*) FROM customers
UNION ALL SELECT 'orders', count(*) FROM orders
UNION ALL SELECT 'ha_test', count(*) FROM ha_test;
" > "$OUTDIR/row-counts.txt" 2>&1 || echo "Could not query database" > "$OUTDIR/row-counts.txt"

# 8. Sample records
echo "  [8/10] Sample records..."
PGPASSWORD="$APP_PASS" psql -h localhost -p 5000 -U "$APP_USER" -d "$APP_DB" -c "
SELECT * FROM ha_test ORDER BY id;
" > "$OUTDIR/ha-test-records.txt" 2>&1 || true

# 9. Connection info
echo "  [9/10] Connection info..."
PGPASSWORD="$APP_PASS" psql -h localhost -p 5000 -U "$APP_USER" -d "$APP_DB" -c "
SELECT inet_server_addr(), inet_server_port(), current_database(),
       current_user, pg_is_in_recovery(), pg_current_wal_lsn();
" > "$OUTDIR/connection-info.txt" 2>&1 || echo "Could not connect" > "$OUTDIR/connection-info.txt"

# 10. Relevant logs (last 100 lines each)
echo "  [10/10] Container logs..."
for c in etcd pg-node-1 pg-node-2 pg-node-3 haproxy; do
    docker logs --tail 100 "$c" > "$OUTDIR/logs-${c}.txt" 2>&1 || true
done

echo ""
echo "State captured to: $OUTDIR/"
ls -la "$OUTDIR/"
