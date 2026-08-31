#!/bin/bash
# 09-rebalance.sh
# Triggers the Citus shard rebalancer to redistribute shards
# evenly across all worker nodes (including the newly added worker-3).
#
# The rebalancer uses logical replication to move shard data.
# During the move, the source shard remains readable.
# At the end of the move, Citus briefly locks the shard to switch
# the authoritative copy to the new location.

set -e

COORD="citus-coordinator"
DB="customer_orders"

echo "=== Shard distribution BEFORE rebalance ==="
docker exec "$COORD" psql -U postgres -d "$DB" -c \
    "SELECT nodename, count(*) AS shard_count
     FROM citus_shards
     WHERE table_name::text = 'customers'
     GROUP BY nodename
     ORDER BY nodename;"

echo ""
echo "=== Starting shard rebalance ==="
echo "(This moves shards using logical replication. May take a few seconds.)"
echo ""

docker exec "$COORD" psql -U postgres -d "$DB" -c \
    "SELECT rebalance_table_shards();"

echo ""
echo "=== Shard distribution AFTER rebalance ==="
docker exec "$COORD" psql -U postgres -d "$DB" -c \
    "SELECT nodename, count(*) AS shard_count
     FROM citus_shards
     WHERE table_name::text = 'customers'
     GROUP BY nodename
     ORDER BY nodename;"

echo ""
echo "=== Row count per worker AFTER rebalance (customers) ==="
docker exec "$COORD" psql -U postgres -d "$DB" -c \
    "SELECT cs.nodename,
            count(*)              AS shard_count,
            sum(r.result::bigint) AS total_rows
     FROM run_command_on_shards('customers', \$cmd\$ SELECT count(*) FROM %s \$cmd\$) r
     JOIN citus_shards cs USING (shardid)
     WHERE cs.table_name::text = 'customers'
     GROUP BY cs.nodename
     ORDER BY cs.nodename;"

echo ""
echo "=== Detailed shard placement AFTER rebalance (customers) ==="
docker exec "$COORD" psql -U postgres -d "$DB" -c \
    "SELECT shardid, shard_name, nodename
     FROM citus_shards
     WHERE table_name::text = 'customers'
     ORDER BY shardid;"

echo ""
echo "=== Rebalance complete ==="
