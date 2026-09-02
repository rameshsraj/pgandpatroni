# PostgreSQL Sharding with Citus

A working Citus cluster that spreads a database across several machines, tested by adding a worker to a cluster that was already full of data and rebalancing onto it without downtime.

One coordinator and two workers to begin with, holding 10,500 rows across twelve shards. A third worker is then added to the running cluster and the shards are redistributed.

This is a laboratory build. It demonstrates the mechanics of sharding clearly and is not a production template. See [Known limitations](#known-limitations), and in particular read the note about availability, because it is counter-intuitive.

## What this lab demonstrates

| Question | Result |
|---|---|
| Does adding a worker move data automatically? | No. The new worker held zero shards until a rebalance was triggered. |
| Did the rebalance need downtime? | No. The cluster stayed queryable and no existing container was restarted. |
| How much data moved? | 4 of 12 shard groups, the minimum for an even split |
| Were rows lost or duplicated? | Neither. 10,500 before and after, no orphans, no duplicates. |
| Did query results change? | No. Aggregates and joins returned identical values. |
| How does Citus move a shard? | Logical replication, then a brief metadata cutover |

The customer row distribution before and after the rebalance:

| Worker | Shards before | Rows before | Shards after | Rows after |
|---|---|---|---|---|
| worker-1 | 6 | 241 | 4 | 148 |
| worker-2 | 6 | 259 | 4 | 168 |
| worker-3 | 0 | 0 | 4 | 184 |
| **Total** | **12** | **500** | **12** | **500** |

Two things worth drawing out of those numbers:

**A shard move relocates data, it does not re-hash it.** Every shard arrived holding exactly the rows it left with. The distribution column decides which shard a row belongs to and that never changed, only the shard's location did. This is why an online rebalance is safe.

**An even shard count does not mean an even row count.** Four shards each, but 148, 168 and 184 rows. The rebalancer equalises shard cost, which by default in Citus 12.1 is disk size, and never looks at row counts.

## Architecture

```
Application / psql
    |
    v
Coordinator  :5432 published to the host
             Holds Citus metadata, no table data
             Plans every query and routes it
    |
    +--> worker-1   :5432 internal only
    +--> worker-2   :5432 internal only
    +--> worker-3   :5432 internal only, added later
```

Two structural points shape everything else:

**The coordinator stores no table data.** It holds only the metadata saying which shard lives where and which hash range each shard owns. All 10,500 rows sit on the workers. That makes the coordinator cheap to run and a total single point of failure.

**Workers are ordinary, independent PostgreSQL servers.** They do not replicate to each other and are not aware of each other. A shard is a normal table with a number appended to its name, and you can connect to a worker and read it directly:

```bash
docker exec citus-worker-1 psql -U postgres -d customer_orders \
  -c "SELECT count(*) FROM customers_102010;"
```

That is the command worth running if sharding still feels abstract.

## Versions

| Component | Version |
|---|---|
| PostgreSQL | 16.6 |
| Citus | 12.1.6 |
| Docker image | `citusdata/citus:12.1` |

Citus reports two different version numbers and they answer different questions. The extension catalogue reports the SQL script version, `12.1-1`. The `citus_version()` function reports the compiled library version, `12.1.6`. Only the second gives you the patch level.

## Prerequisites

- Docker Desktop or Docker Engine, version 4 or later
- Docker Compose version 2
- At least 4 GB of memory available to Docker

If port 5432 is already in use on your host, which usually means a locally installed PostgreSQL, the coordinator will fail to start. Change the published port in `docker-compose.yml`.

## Quick start

Run these from the root of this folder, in this order. The order matters: tables must exist before they can be distributed, and they must be distributed before data is loaded, or the rows land on the coordinator instead of the workers.

```bash
# 1. Start the coordinator and the first two workers
docker compose up -d
docker compose ps            # wait until all three report healthy

# 2. Create the database and the Citus extension on every node
bash scripts/01-init-databases.sh

# 3. Register the workers with the coordinator
bash scripts/02-setup-cluster.sh

# 4. Create the schema, distribute it, load the data
docker exec -i citus-coordinator psql -U postgres -d customer_orders < scripts/03-create-schema.sql
docker exec -i citus-coordinator psql -U postgres -d customer_orders < scripts/04-distribute-tables.sql
docker exec -i citus-coordinator psql -U postgres -d customer_orders < scripts/05-generate-data.sql

# 5. See where the data went and how queries route
docker exec -i citus-coordinator psql -U postgres -d customer_orders < scripts/06-inspect-distribution.sql
docker exec -i citus-coordinator psql -U postgres -d customer_orders < scripts/07-query-routing-demo.sql
```

On PowerShell, replace the redirect with a pipe:

```powershell
Get-Content scripts/03-create-schema.sql | docker exec -i citus-coordinator psql -U postgres -d customer_orders
```

### Add a worker and rebalance

This is the core of the lab.

```bash
bash scripts/capture-evidence.sh 01-before-shard3   # snapshot first
bash scripts/08-add-shard3.sh                       # start and register worker-3
bash scripts/09-rebalance.sh                        # move shards onto it
docker exec -i citus-coordinator psql -U postgres -d customer_orders < scripts/10-validate.sql
bash scripts/capture-evidence.sh 02-after-rebalance
```

`08-add-shard3.sh` finishes by printing the shard distribution, which will show the new worker holding nothing. That is expected. Adding a node to Citus registers it and nothing more, because moving data costs disk reads, network transfer and write ahead log volume on the source workers. Citus separates the decision that a node exists from the decision to pay that cost.

## Scripts

| Script | What it does |
|---|---|
| `01-init-databases.sh` | Creates the `customer_orders` database and the Citus extension on every node |
| `02-setup-cluster.sh` | Sets the coordinator host and registers both workers |
| `03-create-schema.sql` | Creates `customers`, `orders` and `order_items` |
| `04-distribute-tables.sql` | Distributes all three on `customer_id`, co-located |
| `05-generate-data.sql` | Loads 500 customers, 2,500 orders, 7,500 order items |
| `06-inspect-distribution.sql` | Shard placement, shard counts, row counts per shard and per worker |
| `07-query-routing-demo.sql` | Query plans showing single shard routing and co-located joins |
| `08-add-shard3.sh` | Starts worker-3, prepares it, registers it with the coordinator |
| `09-rebalance.sh` | Triggers the rebalance and prints the placement before and after |
| `10-validate.sql` | Totals, duplicate checks, referential integrity, identifier range |
| `capture-evidence.sh <phase>` | Snapshots the cluster state to `evidence/<phase>/` |

## Useful queries

```sql
-- Cluster membership, coordinator included
SELECT nodeid, nodename, nodeport, noderole, isactive FROM pg_dist_node ORDER BY nodeid;

-- Where every shard lives
SELECT shardid, shard_name, nodename FROM citus_shards
WHERE table_name::text = 'customers' ORDER BY shardid;

-- Which shard owns a given customer
SELECT get_shard_id_for_distribution_column('customers', 42);

-- Row count in every shard of a table
SELECT shardid, result FROM run_command_on_shards('customers', 'SELECT count(*) FROM %s')
ORDER BY shardid;

-- Progress of a rebalance that is still running
SELECT * FROM get_rebalance_progress();
```

## Design notes

**The shard key is `customer_id` on all three tables.** It exists in every table, so a customer and all their orders land on the same shard. Joins on it stay inside one worker, and a lookup for one customer touches one worker rather than all of them.

**Every unique constraint includes the distribution column.** `orders` is keyed on `(order_id, customer_id)` rather than `order_id` alone. Citus can only enforce uniqueness inside a shard, so including the distribution column means all rows that could collide are in the same shard and a local index is sufficient. This is normally the largest piece of work in adopting Citus, and it is worth knowing before you start rather than halfway through.

**Co-location is the decision you cannot cheaply undo.** All three tables share one co-location group, which is why the rebalancer moves related shards together and why joins are local. Getting it wrong makes almost every query distributed, and fixing it later means redistributing everything.

**A bad shard key would look fine in testing.** Sharding on `city` would put all 50 customers of a city on one shard, and with ten cities and twelve shards at least two shards would be permanently empty. The imbalance would only become a problem at scale.

## Cleanup

```bash
docker compose --profile add-shard down       # keeps the volumes
docker compose --profile add-shard down -v    # deletes the volumes and all data
```

Include the profile, or worker-3's container and volume are left behind and the next startup is confusing.

## Known limitations

Read the first row carefully, because it is the one people get wrong.

| Limitation | Why it matters | What production needs |
|---|---|---|
| One copy of each shard | **No redundancy at all.** Any one of four containers failing takes down part or all of the database. | Each worker behind its own highly available cluster |
| Single coordinator | It holds no data but all the metadata, so losing it loses the cluster | Replication for the coordinator too |
| All containers on one host | No real network separation, one machine to lose | Separate machines |
| Trust authentication | No password is required at all | TLS with password or certificate authentication |
| No backups | Data loss is permanent | Base backups and log archiving per node, restores tested |
| Twelve shards | Too few to spread across a larger cluster later, and changing it means redistributing everything | Between 32 and 128, depending on expected growth |
| No connection pooling | Connection overhead lands on the coordinator | A pooler in front of the coordinator |

### The availability point, stated plainly

**As built, this cluster is less available than a single PostgreSQL server.** With one copy of each shard and four containers, the number of things that can break has been multiplied by four and no redundancy has been added.

Sharding is a technique for scale, not for availability. Conflating the two is a genuinely dangerous mistake and an easy one to make, because both get described as distributing the database.

Citus does expose a setting for more than one copy of each shard, but it is not the answer here: that mechanism is statement based replication intended for append only workloads, it is deprecated in current Citus, and it does not apply to the hash distributed tables this lab uses.

The correct approach keeps scale and availability as separate layers, with each worker running as its own replicated cluster.

### When not to shard

Sharding imposes permanent costs. Queries that do not filter on the shard key get slower, unique constraints have to include the distribution column, foreign keys are constrained, and every operational task multiplies by node count.

Before reaching for it, exhaust the cheaper options: indexing, query tuning, connection pooling, read replicas, table partitioning, and simply using a larger machine. Modern hardware runs single node PostgreSQL into the multi terabyte range without complaint.

Shard when you have a demonstrated limit on write throughput or data volume that one machine cannot meet, and when your access patterns have a natural distribution key, usually a tenant or customer. If you cannot name that key with confidence, you are not ready to shard.
