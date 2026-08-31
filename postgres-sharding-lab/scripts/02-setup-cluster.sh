#!/bin/bash
# 02-setup-cluster.sh
# Registers worker nodes with the Citus coordinator.
# Run AFTER 01-init-databases.sh.

set -e

COORD="citus-coordinator"
DB="customer_orders"

echo "=== Registering coordinator host ==="
docker exec "$COORD" psql -U postgres -d "$DB" -c \
    "SELECT citus_set_coordinator_host('coordinator', 5432);"

echo ""
echo "=== Adding worker nodes ==="
docker exec "$COORD" psql -U postgres -d "$DB" -c \
    "SELECT citus_add_node('worker-1', 5432);"
docker exec "$COORD" psql -U postgres -d "$DB" -c \
    "SELECT citus_add_node('worker-2', 5432);"

echo ""
echo "=== Active worker nodes ==="
docker exec "$COORD" psql -U postgres -d "$DB" -c \
    "SELECT * FROM citus_get_active_worker_nodes() ORDER BY node_name;"

echo ""
echo "=== All cluster nodes (including coordinator) ==="
docker exec "$COORD" psql -U postgres -d "$DB" -c \
    "SELECT nodeid, nodename, nodeport, noderole, isactive FROM pg_dist_node ORDER BY nodeid;"

echo ""
echo "=== Cluster setup complete ==="
