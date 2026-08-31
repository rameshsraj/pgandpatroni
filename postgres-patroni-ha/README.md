# PostgreSQL + Patroni HA Lab

A complete PostgreSQL High Availability environment using Patroni, etcd, and HAProxy on Docker Desktop.

See `docs/POSTGRES_PATRONI_HA_COMPLETE_GUIDE.md` for the full guide including test results and failover evidence.

## Quick Start

```bash
cp .env.example .env
docker compose up -d
# Wait ~30 seconds for cluster initialization
docker exec pg-node-1 patronictl -c /etc/patroni/patroni.yml list
psql -h localhost -p 5000 -U appuser -d appdb
```

## Architecture

- 3x PostgreSQL nodes managed by Patroni
- etcd as distributed configuration store (DCS)
- HAProxy as stable client endpoint (port 5000 write, port 5001 read)

## Versions

- PostgreSQL 16.4
- Patroni 3.3.2
- etcd 3.5.15
- HAProxy 2.9
