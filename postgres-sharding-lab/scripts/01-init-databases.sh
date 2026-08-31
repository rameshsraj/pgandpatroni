#!/bin/bash
# 01-init-databases.sh
# Creates the customer_orders database and citus extension on ALL nodes.
# Run from the host after 'docker compose up -d' and all containers are healthy.

set -e

COORD="citus-coordinator"
WORKERS=("citus-worker-1" "citus-worker-2")
DB="customer_orders"

echo "=== Creating $DB database on all nodes ==="

# Coordinator
echo "  coordinator..."
docker exec "$COORD" psql -U postgres -c "SELECT 1;" > /dev/null 2>&1
docker exec "$COORD" psql -U postgres -c "CREATE DATABASE $DB;"
docker exec "$COORD" psql -U postgres -d "$DB" -c "CREATE EXTENSION IF NOT EXISTS citus;"

# Workers
for w in "${WORKERS[@]}"; do
    echo "  $w..."
    docker exec "$w" psql -U postgres -c "CREATE DATABASE $DB;"
    docker exec "$w" psql -U postgres -d "$DB" -c "CREATE EXTENSION IF NOT EXISTS citus;"
done

echo "=== Databases created ==="
echo ""
echo "Verify citus extension:"
docker exec "$COORD" psql -U postgres -d "$DB" -c "SELECT extname, extversion FROM pg_extension WHERE extname = 'citus';"
