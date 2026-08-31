#!/bin/bash
# capture-evidence.sh
# Captures the current cluster state into evidence/<phase>/ directory.
# Usage: bash scripts/capture-evidence.sh <phase-name>
# Example: bash scripts/capture-evidence.sh before-shard3

set -e

PHASE="${1:?Usage: capture-evidence.sh <phase-name>}"
COORD="citus-coordinator"
DB="customer_orders"
DIR="evidence/$PHASE"

mkdir -p "$DIR"

echo "=== Capturing evidence for phase: $PHASE ==="

# Docker container status
echo "--- Docker status ---"
docker compose ps > "$DIR/docker-status.txt" 2>&1
echo "  saved docker-status.txt"

# Citus version
docker exec "$COORD" psql -U postgres -d "$DB" -t -c \
    "SELECT citus_version();" > "$DIR/citus-version.txt" 2>&1
echo "  saved citus-version.txt"

# Cluster nodes
docker exec "$COORD" psql -U postgres -d "$DB" -c \
    "SELECT nodeid, nodename, nodeport, noderole, isactive FROM pg_dist_node ORDER BY nodeid;" \
    > "$DIR/cluster-nodes.txt" 2>&1
echo "  saved cluster-nodes.txt"

# Shard placement (customers)
docker exec "$COORD" psql -U postgres -d "$DB" -c \
    "SELECT shardid, shard_name, table_name::text, nodename
     FROM citus_shards
     WHERE table_name::text = 'customers'
     ORDER BY shardid;" \
    > "$DIR/shard-placement-customers.txt" 2>&1
echo "  saved shard-placement-customers.txt"

# Shard count per worker (all tables)
docker exec "$COORD" psql -U postgres -d "$DB" -c \
    "SELECT table_name::text, nodename, count(*) AS shard_count
     FROM citus_shards
     WHERE table_name::text IN ('customers', 'orders', 'order_items')
     GROUP BY table_name::text, nodename
     ORDER BY table_name::text, nodename;" \
    > "$DIR/shard-count-per-worker.txt" 2>&1
echo "  saved shard-count-per-worker.txt"

# Row counts per worker (customers)
docker exec "$COORD" psql -U postgres -d "$DB" -c \
    "SELECT cs.nodename, count(*) AS shard_count, sum(r.result::bigint) AS total_rows
     FROM run_command_on_shards('customers', \$cmd\$ SELECT count(*) FROM %s \$cmd\$) r
     JOIN citus_shards cs USING (shardid)
     WHERE cs.table_name::text = 'customers'
     GROUP BY cs.nodename
     ORDER BY cs.nodename;" \
    > "$DIR/row-count-per-worker-customers.txt" 2>&1
echo "  saved row-count-per-worker-customers.txt"

# Row counts per worker (orders)
docker exec "$COORD" psql -U postgres -d "$DB" -c \
    "SELECT cs.nodename, count(*) AS shard_count, sum(r.result::bigint) AS total_rows
     FROM run_command_on_shards('orders', \$cmd\$ SELECT count(*) FROM %s \$cmd\$) r
     JOIN citus_shards cs USING (shardid)
     WHERE cs.table_name::text = 'orders'
     GROUP BY cs.nodename
     ORDER BY cs.nodename;" \
    > "$DIR/row-count-per-worker-orders.txt" 2>&1
echo "  saved row-count-per-worker-orders.txt"

# Row counts per worker (order_items)
docker exec "$COORD" psql -U postgres -d "$DB" -c \
    "SELECT cs.nodename, count(*) AS shard_count, sum(r.result::bigint) AS total_rows
     FROM run_command_on_shards('order_items', \$cmd\$ SELECT count(*) FROM %s \$cmd\$) r
     JOIN citus_shards cs USING (shardid)
     WHERE cs.table_name::text = 'order_items'
     GROUP BY cs.nodename
     ORDER BY cs.nodename;" \
    > "$DIR/row-count-per-worker-order-items.txt" 2>&1
echo "  saved row-count-per-worker-order-items.txt"

# Total row counts
docker exec "$COORD" psql -U postgres -d "$DB" -c \
    "SELECT 'customers' AS t, count(*) FROM customers
     UNION ALL SELECT 'orders', count(*) FROM orders
     UNION ALL SELECT 'order_items', count(*) FROM order_items
     ORDER BY t;" \
    > "$DIR/total-row-counts.txt" 2>&1
echo "  saved total-row-counts.txt"

# Sample data
docker exec "$COORD" psql -U postgres -d "$DB" -c \
    "SELECT * FROM customers ORDER BY customer_id LIMIT 5;" \
    > "$DIR/sample-customers.txt" 2>&1
echo "  saved sample-customers.txt"

echo ""
echo "=== Evidence captured in $DIR/ ==="
ls -la "$DIR/"
