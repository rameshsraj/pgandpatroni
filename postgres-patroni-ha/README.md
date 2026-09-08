# PostgreSQL High Availability with Patroni, etcd and HAProxy

A working three node PostgreSQL cluster that survives losing its primary, built with Docker Compose and tested by deliberately killing the primary.

<<<<<<< Updated upstream
Five containers: three PostgreSQL nodes managed by Patroni, one etcd holding the leader lock, and one HAProxy giving the application a single address that does not change when the primary does.
=======
See [the original guide](docs/POSTGRES_PATRONI_HA_COMPLETE_GUIDE.md) for the initial
three-node experiment. Later phases expand the topology; their measured results and
limitations take precedence over general claims in that historical guide.
>>>>>>> Stashed changes

This is a laboratory build. It is a good way to learn how automatic failover actually works and a bad way to run a production database. See [Known limitations](#known-limitations) before using any of it as a template.

## What this lab demonstrates

The primary was stopped on purpose and the cluster recovered without human intervention. Measured from the captured container logs:

| Question | Result |
|---|---|
| Did a new primary appear on its own? | Yes. Node `pg-node-1` promoted itself. |
| Time to a new primary | About 34 seconds, of which about 30 was the leader lock timeout |
| Time until write traffic followed | About 36 seconds |
| Did the application connection string change? | No. Port 5000 on localhost throughout. |
| Was committed data lost? | No. The PostgreSQL timeline advanced from 1 to 2. |
| Time for the failed node to rejoin | About 1.5 seconds, as a replica |
| Did losing a replica cause a failover? | No, and writes were never interrupted |

Two details worth knowing, because both are widely misunderstood:

**The failed primary rejoined without `pg_rewind`.** Stopping a container lets Patroni shut PostgreSQL down cleanly, so nothing diverged and there was nothing to rewind. A rewind is what you see after an abrupt loss such as a power cut.

**The lock does not expire 30 seconds after the failure.** It expires 30 seconds after its last renewal. In this run the container stopped about 5 seconds after a renewal, so the lock survived roughly 25 more seconds. The delay before an election therefore varies with where in the renewal cycle the failure lands.

## Architecture

<<<<<<< Updated upstream
```
Application
    |
    v
HAProxy        :5000 write traffic to the current primary
               :5001 read traffic across the replicas
               :7000 statistics page
    |
    +--> pg-node-1  PostgreSQL :5432  Patroni :8008
    +--> pg-node-2  PostgreSQL :5432  Patroni :8008
    +--> pg-node-3  PostgreSQL :5432  Patroni :8008
                        |
                        v
                      etcd :2379   leader lock and cluster state
```

Each component has exactly one job:

| Component | Responsibility | Does not do |
|---|---|---|
| PostgreSQL | Stores data, ships the write ahead log to replicas | Decide who is primary, fail over, route connections |
| Patroni | Bootstrap, leader election, promotion, demotion, rejoin | Store data, serve queries |
| etcd | Holds the leader lock, guarantees only one holder | Anything database related |
| HAProxy | Gives clients a stable address, health checks Patroni | Decide who is primary, preserve open connections |

### Ports

| Port | Listener | Reachable from the host | Purpose |
|---|---|---|---|
| 5000 | HAProxy | Yes | Read and write endpoint |
| 5001 | HAProxy | Yes | Read only endpoint |
| 7000 | HAProxy | Yes | Statistics page |
| 5432 | PostgreSQL | No | Database, internal only |
| 8008 | Patroni | No | Health and status API, internal only |
| 2379 | etcd | No | Client API, internal only |

PostgreSQL and the Patroni API are deliberately not published to the host. All client access goes through HAProxy.
=======
- 4 permanent PostgreSQL nodes managed by Patroni (expanded from the original 3)
- Optional `pg-node-5` elastic read replica, excluded from elections; data volume retained on scale-in
- etcd as distributed configuration store (DCS)
- HAProxy as stable client endpoint (port 5000 write, port 5001 read)
>>>>>>> Stashed changes

## Traffic-driven scaling demonstration (Phase 3)

**Results and scenario coverage:** [Phase 3 lab report](docs/PHASE3_TRAFFIC_SCALING_LAB.md),
including unsuccessful attempts, admission/drain fixes, sequential failovers, and
the separate post-benchmark health-check correction.

Run the VS Code task **Phase 3: traffic scaling and resiliency LAB**. It runs
[scripts/phase3/run-lab.ps1](scripts/phase3/run-lab.ps1) using PowerShell 7 and Docker
Desktop, with PostgreSQL's existing pgbench client—no host PostgreSQL install or WSL.

**LAB ONLY:** the task adds a replica, hard-kills the dynamically identified primary,
restarts it, and drains/stops the extra replica. It requires four healthy permanent
nodes and the Phase 2 appdb/public fixtures. It never deletes database volumes or
changes the Citus sharding lab. The dedicated phase3_lab schema holds test data.

The finite controller demonstrates low traffic → high traffic → automatic scale-out
→ automatic failover under reads and retrying writes → automatic rejoin → low traffic
→ safe scale-in. Thresholds are deliberately low for demonstration, not production
capacity recommendations. A new run keeps all previous evidence and generates new
write tokens; repeat runs reuse the elastic volume and test catch-up rather than cloning.

Each run captures SQL, Docker commands, outputs, errors, UTC operation timings,
transaction latency, connection routing, logical row fingerprints, and acknowledged
write-token checks. The task is not a permanent autoscaler or a production application.
Use [scripts/phase3/summarize.ps1](scripts/phase3/summarize.ps1) to build a completed
run's report and comparison CSVs. See [Phase 3 evidence](test-results/phase3/) and
[the audited Phase 2 report](test-results/phase2/PHASE2_REPORT.md).

Read scaling duplicates the full dataset; it does **not** redistribute shards or
increase single-primary write capacity. All containers share one Docker host, so
additional replicas may reduce measured throughput rather than improve it.

## Versions

Tested together and confirmed working:

| Component | Version | Image |
|---|---|---|
| PostgreSQL | 16.4 | `postgres:16.4-bookworm` |
| Patroni | 3.3.2 | Installed with pip into a custom image |
| etcd | 3.5.15 | `quay.io/coreos/etcd:v3.5.15` |
| HAProxy | 2.9 | `haproxy:2.9-alpine` |

One version note that cost real time during the build: etcd 3.5 disables the older version 2 API by default, so Patroni has to be installed and configured for the version 3 API. The environment variable name is what selects the protocol, and it silently overrides the configuration file.

## Prerequisites

- Docker Desktop or Docker Engine, version 4 or later
- Docker Compose version 2, which ships with Docker Desktop
- At least 4 GB of memory available to Docker
- `psql` on the host is optional, since you can run it inside any container

## Quick start

```bash
cp .env.example .env      # then edit .env and change every password
docker compose build
docker compose up -d
```

Give it 15 to 30 seconds, then check the cluster:

```bash
docker exec pg-node-1 patronictl -c /etc/patroni/patroni.yml list
```

```
+ Cluster: pg-ha-cluster ---------+---------+-----------+----+-----------+
| Member    | Host      | Role    | State     | TL | Lag in MB |
+-----------+-----------+---------+-----------+----+-----------+
| pg-node-1 | pg-node-1 | Replica | streaming |  1 |         0 |
| pg-node-2 | pg-node-2 | Leader  | running   |  1 |           |
| pg-node-3 | pg-node-3 | Replica | streaming |  1 |         0 |
+-----------+-----------+---------+-----------+----+-----------+
```

Which node becomes the first leader is a race and is not predictable. Do not assume it is node 1.

Create the sample database and data:

```bash
bash scripts/database-test.sh
```

Connect:

```bash
psql -h localhost -p 5000 -U appuser -d appdb    # writes, always the primary
psql -h localhost -p 5001 -U appuser -d appdb    # reads, across the replicas
```

The HAProxy statistics page is at `http://localhost:7000`.

## Scripts

| Script | What it does |
|---|---|
| `scripts/cluster-status.sh` | Prints the Patroni list, container status, etcd health and HAProxy backend states |
| `scripts/database-test.sh` | Creates the application database, tables and sample data through HAProxy |
| `scripts/capture-state.sh <label>` | Snapshots the whole cluster to `test-results/<label>/` |
| `scripts/failover-test.sh` | Finds the current leader, stops it, waits for promotion, verifies the data |
| `scripts/recovery-test.sh <node>` | Starts a stopped node and confirms it rejoins as a replica |

Run them from the root of this folder.

## Running the failover test

```bash
bash scripts/capture-state.sh before-failover
bash scripts/failover-test.sh
bash scripts/recovery-test.sh pg-node-2      # name the node that was stopped
```

`failover-test.sh` identifies the leader from Patroni rather than assuming it, which matters because the first leader is chosen by a race. It records the time, stops that container, then polls the Patroni list every two seconds until a different node reports itself as leader, and separately retries a connection through HAProxy so the routing delay is observed rather than guessed.

### Useful checks while poking at it

```bash
# Which node am I actually connected to, and is it a replica?
psql -h localhost -p 5000 -U appuser -d appdb \
     -c "SELECT inet_server_addr(), pg_is_in_recovery();"

# Replication state, from the primary
psql -h localhost -p 5000 -U postgres -d postgres \
     -c "SELECT application_name, client_addr, state, sync_state, replay_lsn FROM pg_stat_replication;"

# What Patroni has stored in etcd
docker exec etcd etcdctl get /service/pg-ha-cluster --prefix --print-value-only

# Ask one node what role it thinks it has
docker exec pg-node-1 curl -s http://localhost:8008/patroni

# Follow a node's Patroni log
docker logs -f pg-node-1
```

## Capturing output

`scripts/capture-state.sh <label>` writes a snapshot to `test-results/<label>/`. That folder is not kept in this repository, so you will generate your own when you run the tests.

Each snapshot collects the container status, the Patroni cluster listing, the etcd health and key contents, the HAProxy statistics, the role of each node, the replication view, the row counts, the sample rows, the connection details, and the last hundred log lines from all five containers.

The labels used for the run whose figures appear above were `before-failover`, `failover-events`, `after-failover` and `after-recovery`.

One thing to know when reading your own results: **the HAProxy log carries no timestamps.** HAProxy writes those particular messages without them, so you can verify the order of events and the exact reason codes, but the few seconds it takes HAProxy to notice a new primary has to be inferred from the three second check interval rather than read off the log.

## Cleanup

```bash
docker compose down        # keeps the data volumes
docker compose down -v     # deletes the volumes and all data
```

A full rebuild:

```bash
docker compose down -v
docker compose build --no-cache
docker compose up -d
```

## Known limitations

This build protects against exactly one thing: the loss of a single PostgreSQL node. It does nothing about the following.

| Limitation | Why it matters | What production needs |
|---|---|---|
| One etcd node | If etcd fails, no election can happen and the cluster freezes in place | Three or five etcd nodes |
| All containers on one host | Losing the machine loses everything, however many nodes are configured | Separate physical or virtual machines |
| Credentials in a file, committed defaults | The example values are public | A secrets manager, and your own values |
| Password authentication from any address | Unacceptable outside an isolated network | Restricted source ranges, and `scram-sha-256` |
| No encryption in transit | Traffic is readable on the wire | TLS for PostgreSQL, the Patroni API and etcd |
| No backups | Replication copies mistakes as faithfully as good data | Base backups plus log archiving, with restores tested |
| Every statement logged | Enormous log volume, and query parameters written to disk | Log only slow statements |
| Asynchronous replication | A commit in the final milliseconds before a crash can be lost | Consider synchronous replication |

The most important line is the one about backups, and it is the one most often skipped because replication feels like it already covers the problem. It does not. A mistaken `DROP TABLE` reaches all three nodes in milliseconds.

Note also that HAProxy gives you a stable address, not unbroken sessions. Every open connection breaks during a failover, and the application needs connection and transaction retry logic.

### Credentials

`.env.example` contains obvious lab only values and is committed on purpose. Copy it to `.env` and change them. Patroni prints its rendered configuration at startup, so any container log you capture will contain those passwords in plain text. Worth remembering before you share a snapshot, and before pointing the same setup at anything you care about.
