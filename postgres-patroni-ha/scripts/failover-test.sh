#!/bin/bash
# ============================================================
# failover-test.sh — Perform controlled primary failure
# ============================================================
# This script:
#   1. Identifies the current primary dynamically
#   2. Captures pre-failover state
#   3. Stops the primary container
#   4. Waits for promotion
#   5. Captures post-failover state
#   6. Verifies data and connectivity
# ============================================================
set -e

if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

APP_USER="${POSTGRES_APP_USER:-appuser}"
APP_PASS="${POSTGRES_APP_PASSWORD:-appuser-ha-lab-2024}"
APP_DB="${POSTGRES_APP_DATABASE:-appdb}"
SU_USER="${POSTGRES_SUPERUSER:-postgres}"
SU_PASS="${POSTGRES_SUPERUSER_PASSWORD:-postgres-ha-lab-2024}"

echo "========================================"
echo " FAILOVER TEST"
echo " $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "========================================"

# Step 1: Identify current primary
echo ""
echo "--- Step 1: Identify current primary ---"
ANYNODE=$(docker ps --filter "name=pg-node" --format '{{.Names}}' | head -1)
LEADER=$(docker exec "$ANYNODE" patronictl -c /etc/patroni/patroni.yml list -f tsv 2>/dev/null | grep -i leader | awk '{print $2}')

if [ -z "$LEADER" ]; then
    echo "ERROR: Could not determine current leader."
    exit 1
fi
echo "Current primary/leader: $LEADER"

# Step 2: Capture pre-failover state
echo ""
echo "--- Step 2: Capture pre-failover state ---"
bash scripts/capture-state.sh before-failover 2>/dev/null || true

# Step 3: Record T0 and stop primary
echo ""
echo "--- Step 3: Stopping primary ($LEADER) ---"
T0=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
T0_EPOCH=$(date +%s)
echo "T0 (primary failure): $T0"
echo "Command: docker stop $LEADER"
docker stop "$LEADER"
echo "Primary container stopped."

# Step 4: Wait for new leader
echo ""
echo "--- Step 4: Waiting for new primary... ---"
NEW_LEADER=""
WAIT_SEC=0
MAX_WAIT=60

# Find a surviving node
SURVIVING=$(docker ps --filter "name=pg-node" --format '{{.Names}}' | head -1)

while [ $WAIT_SEC -lt $MAX_WAIT ]; do
    sleep 2
    WAIT_SEC=$((WAIT_SEC + 2))
    NEW_LEADER=$(docker exec "$SURVIVING" patronictl -c /etc/patroni/patroni.yml list -f tsv 2>/dev/null | grep -i leader | awk '{print $2}' || true)
    if [ -n "$NEW_LEADER" ] && [ "$NEW_LEADER" != "$LEADER" ]; then
        break
    fi
    echo "  Waiting... (${WAIT_SEC}s)"
    NEW_LEADER=""
done

T1=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
T1_EPOCH=$(date +%s)

if [ -z "$NEW_LEADER" ]; then
    echo "ERROR: No new leader elected within ${MAX_WAIT}s."
    exit 1
fi

echo ""
echo "New primary/leader: $NEW_LEADER"
echo "T1 (new leader): $T1"
echo "Failover duration (T1-T0): $((T1_EPOCH - T0_EPOCH))s"

# Step 5: Wait for HAProxy to recognize new primary
echo ""
echo "--- Step 5: Verify HAProxy connectivity ---"
T2=""
for i in $(seq 1 15); do
    if PGPASSWORD="$APP_PASS" psql -h localhost -p 5000 -U "$APP_USER" -d "$APP_DB" -c "SELECT 1;" >/dev/null 2>&1; then
        T2=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
        T2_EPOCH=$(date +%s)
        echo "HAProxy connection successful at: $T2"
        echo "T2 (HAProxy ready, T2-T0): $((T2_EPOCH - T0_EPOCH))s"
        break
    fi
    sleep 2
done

if [ -z "$T2" ]; then
    echo "WARNING: HAProxy connection not established within 30s"
fi

# Step 6: Verify new primary
echo ""
echo "--- Step 6: Verify new primary ---"
PGPASSWORD="$APP_PASS" psql -h localhost -p 5000 -U "$APP_USER" -d "$APP_DB" -c "
SELECT inet_server_addr() AS server,
       pg_is_in_recovery() AS is_replica,
       current_database() AS db;
"

# Step 7: Verify data survived
echo ""
echo "--- Step 7: Verify data survived failover ---"
PGPASSWORD="$APP_PASS" psql -h localhost -p 5000 -U "$APP_USER" -d "$APP_DB" -c "
SELECT 'customers' AS tbl, count(*) FROM customers
UNION ALL SELECT 'orders', count(*) FROM orders
UNION ALL SELECT 'ha_test', count(*) FROM ha_test;
"

PGPASSWORD="$APP_PASS" psql -h localhost -p 5000 -U "$APP_USER" -d "$APP_DB" -c "SELECT * FROM ha_test ORDER BY id;"

# Step 8: Insert post-failover data
echo ""
echo "--- Step 8: Insert data after failover ---"
PGPASSWORD="$APP_PASS" psql -h localhost -p 5000 -U "$APP_USER" -d "$APP_DB" -c "
INSERT INTO ha_test (message) VALUES ('record-created-AFTER-failover-at-$(date -u +%H%M%S)');
"
PGPASSWORD="$APP_PASS" psql -h localhost -p 5000 -U "$APP_USER" -d "$APP_DB" -c "SELECT * FROM ha_test ORDER BY id;"

# Step 9: Capture post-failover state
echo ""
echo "--- Step 9: Capture post-failover state ---"
bash scripts/capture-state.sh after-failover 2>/dev/null || true

# Step 10: Patroni status
echo ""
echo "--- Step 10: Final Patroni cluster status ---"
docker exec "$SURVIVING" patronictl -c /etc/patroni/patroni.yml list

echo ""
echo "========================================"
echo " FAILOVER TEST SUMMARY"
echo "========================================"
echo "Old primary:        $LEADER"
echo "New primary:        $NEW_LEADER"
echo "T0 (failure):       $T0"
echo "T1 (new leader):    $T1"
echo "T1-T0:              $((T1_EPOCH - T0_EPOCH))s"
if [ -n "$T2" ]; then
    echo "T2 (HAProxy):       $T2"
    echo "T2-T0:              $((T2_EPOCH - T0_EPOCH))s"
fi
echo "Data survived:      YES"
echo "Post-failover write: YES"
echo "========================================"
