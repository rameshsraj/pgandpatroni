#!/bin/bash
# ============================================================
# cluster-status.sh — Display current Patroni cluster status
# ============================================================
set -e

echo "========================================"
echo " Patroni Cluster Status"
echo " $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "========================================"

# Find any running pg-node container to run patronictl
NODE=$(docker ps --filter "name=pg-node" --format '{{.Names}}' | head -1)

if [ -z "$NODE" ]; then
    echo "ERROR: No pg-node containers are running."
    exit 1
fi

echo ""
echo "--- patronictl list ---"
docker exec "$NODE" patronictl -c /etc/patroni/patroni.yml list

echo ""
echo "--- Docker Compose status ---"
docker compose ps 2>/dev/null || docker-compose ps 2>/dev/null

echo ""
echo "--- etcd health ---"
docker exec etcd etcdctl endpoint health --endpoints=http://localhost:2379 2>&1 || echo "etcd not reachable"

echo ""
echo "--- HAProxy stats (pg-primary backend) ---"
curl -sf http://localhost:7000/\;csv 2>/dev/null | grep -E "^pg-primary|^pg-replicas" | head -20 || echo "HAProxy stats not reachable"
