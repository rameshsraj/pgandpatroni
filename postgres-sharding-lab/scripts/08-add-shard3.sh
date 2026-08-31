#!/bin/bash
# 08-add-shard3.sh
# Starts worker-3, creates the database, and registers it with the coordinator.
# Run AFTER the initial cluster is set up and data is loaded.

set -e

COORD="citus-coordinator"
DB="customer_orders"

echo "=== Starting worker-3 container ==="
docker compose --profile add-shard up -d worker-3

echo ""
echo "Waiting for worker-3 to be healthy..."
until docker exec citus-worker-3 pg_isready -U postgres > /dev/null 2>&1; do
    sleep 2
    echo "  still waiting..."
done
echo "worker-3 is ready."

echo ""
echo "=== Creating $DB database on worker-3 ==="
docker exec citus-worker-3 psql -U postgres -c "CREATE DATABASE $DB;"
docker exec citus-worker-3 psql -U postgres -d "$DB" -c "CREATE EXTENSION IF NOT EXISTS citus;"

echo ""
echo "=== Registering worker-3 with coordinator ==="
docker exec "$COORD" psql -U postgres -d "$DB" -c \
    "SELECT citus_add_node('worker-3', 5432);"

echo ""
echo "=== All cluster nodes ==="
docker exec "$COORD" psql -U postgres -d "$DB" -c \
    "SELECT nodeid, nodename, nodeport, noderole, isactive FROM pg_dist_node ORDER BY nodeid;"

echo ""
echo "=== Shard distribution BEFORE rebalance ==="
docker exec "$COORD" psql -U postgres -d "$DB" -c \
    "SELECT nodename, count(*) AS shard_count
     FROM citus_shards
     WHERE table_name::text = 'customers'
     GROUP BY nodename
     ORDER BY nodename;"

echo ""
echo "=== worker-3 added. Run 09-rebalance.sh to redistribute shards. ==="
