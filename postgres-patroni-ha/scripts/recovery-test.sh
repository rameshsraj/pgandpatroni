#!/bin/bash
# ============================================================
# recovery-test.sh — Bring back the failed node and verify rejoin
# ============================================================
# Usage: ./scripts/recovery-test.sh <stopped-node>
# Example: ./scripts/recovery-test.sh pg-node-1
# ============================================================
set -e

if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

STOPPED_NODE="${1}"
APP_USER="${POSTGRES_APP_USER:-appuser}"
APP_PASS="${POSTGRES_APP_PASSWORD:-appuser-ha-lab-2024}"
APP_DB="${POSTGRES_APP_DATABASE:-appdb}"
SU_USER="${POSTGRES_SUPERUSER:-postgres}"
SU_PASS="${POSTGRES_SUPERUSER_PASSWORD:-postgres-ha-lab-2024}"

if [ -z "$STOPPED_NODE" ]; then
    echo "Usage: $0 <stopped-node-name>"
    echo "Example: $0 pg-node-1"
    exit 1
fi

echo "========================================"
echo " RECOVERY TEST — Bringing back $STOPPED_NODE"
echo " $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "========================================"

# Step 1: Restart the stopped node
echo ""
echo "--- Step 1: Restart $STOPPED_NODE ---"
R0=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
R0_EPOCH=$(date +%s)
echo "R0 (restart): $R0"
docker start "$STOPPED_NODE"
echo "Container started."

# Step 2: Wait for Patroni to initialize
echo ""
echo "--- Step 2: Wait for Patroni to initialize ---"
WAIT=0
MAX_WAIT=90
while [ $WAIT -lt $MAX_WAIT ]; do
    sleep 3
    WAIT=$((WAIT + 3))
    HEALTH=$(curl -sf http://localhost:$(docker port "$STOPPED_NODE" 8008 2>/dev/null | head -1 | cut -d: -f2)/health 2>/dev/null || \
             docker exec "$STOPPED_NODE" curl -sf http://localhost:8008/health 2>/dev/null || true)
    if [ -n "$HEALTH" ]; then
        R1=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
        R1_EPOCH=$(date +%s)
        echo "Node healthy at: $R1 (took $((R1_EPOCH - R0_EPOCH))s)"
        break
    fi
    echo "  Waiting for $STOPPED_NODE Patroni... (${WAIT}s)"
done

# Step 3: Check cluster status
echo ""
echo "--- Step 3: Patroni cluster status ---"
ANYNODE=$(docker ps --filter "name=pg-node" --format '{{.Names}}' | head -1)
docker exec "$ANYNODE" patronictl -c /etc/patroni/patroni.yml list

# Step 4: Verify the restarted node is a replica
echo ""
echo "--- Step 4: Verify $STOPPED_NODE role ---"
docker exec "$STOPPED_NODE" psql -U "$SU_USER" -d postgres -c "SELECT pg_is_in_recovery();" 2>&1 || echo "Node not ready yet"

# Step 5: Verify replication from current primary
echo ""
echo "--- Step 5: Replication status ---"
PGPASSWORD="$SU_PASS" psql -h localhost -p 5000 -U "$SU_USER" -d postgres -c "
SELECT application_name, client_addr, state, sync_state,
       sent_lsn, write_lsn, flush_lsn, replay_lsn
FROM pg_stat_replication ORDER BY application_name;
"

# Step 6: Verify all data accessible
echo ""
echo "--- Step 6: Data verification ---"
PGPASSWORD="$APP_PASS" psql -h localhost -p 5000 -U "$APP_USER" -d "$APP_DB" -c "
SELECT 'customers' AS tbl, count(*) FROM customers
UNION ALL SELECT 'orders', count(*) FROM orders
UNION ALL SELECT 'ha_test', count(*) FROM ha_test;
"
PGPASSWORD="$APP_PASS" psql -h localhost -p 5000 -U "$APP_USER" -d "$APP_DB" -c "SELECT * FROM ha_test ORDER BY id;"

# Step 7: Insert another test record
echo ""
echo "--- Step 7: Insert post-recovery record ---"
PGPASSWORD="$APP_PASS" psql -h localhost -p 5000 -U "$APP_USER" -d "$APP_DB" -c "
INSERT INTO ha_test (message) VALUES ('record-created-AFTER-recovery-at-$(date -u +%H%M%S)');
"
PGPASSWORD="$APP_PASS" psql -h localhost -p 5000 -U "$APP_USER" -d "$APP_DB" -c "SELECT * FROM ha_test ORDER BY id;"

# Step 8: Capture recovery state
echo ""
echo "--- Step 8: Capture recovery state ---"
bash scripts/capture-state.sh after-recovery 2>/dev/null || true

echo ""
echo "========================================"
echo " RECOVERY TEST COMPLETE"
echo "========================================"
echo "Recovered node: $STOPPED_NODE"
echo "Role:           Replica (expected)"
echo "Cluster:        3 nodes healthy (expected)"
echo "========================================"
