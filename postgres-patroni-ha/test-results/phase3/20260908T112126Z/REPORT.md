# Phase 3 — Traffic-driven scaling and recovery LAB

Run: **20260908T112126Z**. Evidence generated from recorded results; all times UTC.

## Verdict

- **Functional bounded elasticity: PASS** — observed traffic triggered optional replica provisioning, automatic DNS/health-based routing, and low-demand drain/stop without operator action during the scenarios.
- **Read continuity during scale/rejoin/removal: FAIL / deviation** — 3 aborted pgbench batches across scale-out, rejoin, scale-in, and final low traffic. Failures remain in the evidence even if the client later retries.
- **Failover/rejoin: PASS for this run** — primary was hard-killed; Patroni promoted another node; retrying client probes resumed through the same HAProxy endpoint; the old primary rejoined without repair.
- **Performance: no throughput improvement observed.** Four-node high-load throughput was 98.43 TPS; five-node throughput was 88.7 TPS (-9.89%). Extra containers share one host rather than adding physical resources.
- **Uninterrupted writes: NOT achieved.** Failover has a measured recovery window and failed client attempts. Successful retries are not evidence that existing connections migrated.
- **Sharding/rebalancing: NOT applicable.** Full physical replicas; zero partitioned tables and no Citus extension. Connection distribution is not data redistribution.
- **Container health telemetry: deviation.** HAProxy was marked unhealthy by its configuration-check probe while it continued serving traffic. DNS lookup of the stopped elastic slot exceeded the 5-second health-check timeout. The liveness-probe fix was deployed separately AFTER benchmark measurement, so this is not an all-health-green benchmark certification.

## Setup and reproducibility

- Docker Desktop Linux engine: 8 CPUs, 8,210,579,456 bytes (~7.65 GiB) RAM shared by the lab and other workloads. PostgreSQL 16.4; Patroni 3.3.2; HAProxy runtime 2.9.15; etcd 3.5.15.
- One primary plus three permanent replicas; optional pg-node-5 is a read-only, nofailover replica. Minimum four nodes, maximum five. Existing pg-node-* names preserved.
- Synthetic client: pgbench SELECT-only range reads on 100,000 immutable rows; separate idempotent SQL write probes. This is a client demonstration, not integration with a production application.
- Low traffic: 5 offered TPS / 2 clients; high traffic: 120 offered TPS / 12 clients. Two threads; each read transaction reconnects (-C). Batches last at most 10 seconds and retry automatically after aborts.
- SQL trace logging is enabled: pgbench -d means DEBUG (the database argument is positional), and PostgreSQL logs all statements/durations. This deliberately captures executed queries but adds substantial overhead.
- Trigger: >30 observed successful read TPS for two samples to add capacity; <10 TPS for two samples to drain/remove it. Samples derive from transaction logs (buffered); resource stats are also captured. Deliberately low lab thresholds, NOT production SLO-based autoscaling.
- Image build, static slot definition, DNS configuration, and one HAProxy restart are explicit feature-deployment preparation, before baseline measurement. No HAProxy restart or configuration-file edits during measured scenarios. Runtime admission/drain commands are automated by the controller; review the run-specific commands for the exact implementation version.
- HAProxy resolves Docker DNS repeatedly and requires the replica role with lag <=1 MiB. This is bounded predeclared membership, not arbitrary service discovery. Scale-in checks role, three healthy remaining replicas, and zero active backend sessions before stop; volumes are preserved.
- The optional node uses the fifth available WAL-sender slot during cloning (four steady replicas fit within configured limits). Do not extend this policy to more nodes without revisiting slots, sender headroom, CPU, storage, and connection limits.
- Rerun with the VS Code task **Phase 3: traffic scaling and resiliency LAB**. It requires exactly four healthy active nodes, creates a unique evidence directory, and preserves existing data. The elastic volume is reused on later runs, so later starts test catch-up rather than fresh cloning.
- Sources/configuration for this exact run are frozen in [source/](source/). Live reusable entry point: [run-lab.ps1](../../../scripts/phase3/run-lab.ps1).

## Throughput and latency

| Scenario | Offered TPS | Observed TPS | Completed reads | Mean ms | p95 ms | p99 ms | Aborted batches |
|---|---:|---:|---:|---:|---:|---:|---:|
| 01-low-four | 5 | 5.25 | 105 | 23.19 | 41.21 | 48.62 | 0 |
| 02-high-four | 120 | 98.43 | 2953 | 1055.41 | 2265.26 | 2468.45 | 0 |
| 03-auto-scale-out | 120 | 80.51 | 5233 | 1477.23 | 2951.29 | 3319.59 | 1 |
| 04-high-five | 120 | 88.7 | 2661 | 1407.91 | 2589.66 | 2803.82 | 0 |
| 05-failover-under-load | 120 | 79.29 | 7136 | 1748.88 | 3467.55 | 4898.62 | 0 |
| 07-rejoin-under-load | 120 | 55.1 | 3306 | 2554.12 | 5418.19 | 6678.47 | 1 |
| 09-auto-scale-in | 5 | 5.78 | 231 | 30.18 | 59.25 | 77.84 | 0 |
| 10-low-four-final | 5 | 3.4 | 68 | 33.41 | 61.21 | 72.79 | 1 |

TPS = logged successful reads / requested traffic duration. Batch startup/rounding creates small timing differences (actual completion spans and UTC times are retained). Latencies include rate-schedule delay and reconnection; they are not server query execution times. Only successful transactions contribute percentiles. Failed batches, client probes, connection failures, and nonzero commands are retained separately. No repeated trials, fixed random seed, isolated hardware, pooler, or warmed production-sized workload: not a capacity certification.

## Operation timings

| Operation | Start UTC | End UTC | Seconds |
|---|---|---|---:|
| Traffic trigger to ready observation | 2026-09-08T11:23:29.3916676Z | 2026-09-08T11:23:53.0417449Z | 23.65 |
| Kill command | 2026-09-08T11:25:23.8818910Z | 2026-09-08T11:25:24.6545164Z | 0.773 |
| Kill start to promotion observation | 2026-09-08T11:25:23.8818910Z | 2026-09-08T11:25:57.6830492Z | 33.801 |
| Restore to rejoin observation | 2026-09-08T11:26:59.5602001Z | 2026-09-08T11:27:20.1908621Z | 20.631 |
| Low demand trigger to stopped replica | 2026-09-08T11:28:16.9325490Z | 2026-09-08T11:28:59.4371370Z | 42.505 |

Killed primary: **pg-node-3**; elected primary: **pg-node-2**. Returning node becomes a replica, not a failback/switchover to its former role.

First successful write-probe completion after kill: **2026-09-08T11:26:00.1937796Z**, **36.312 seconds** after kill start. Failed write attempts after kill: **5**. Last pre-kill acknowledgment: 2026-09-08T11:25:23.4915545Z. These are sampled recovery observations, not precise downtime; snapshots interrupt write probing but not the independent pgbench read stream.

## Row counts on every node

Cells show **items / events** and role (P=primary, R=replica). Public reference tables remained customers=5, orders=7, ha_test=5 wherever reachable; full counts and fingerprints are in [row-count-comparison.csv](row-count-comparison.csv). Each snapshot is sequential, not an atomic cluster-wide snapshot.

| Scenario | pg-node-1 | pg-node-2 | pg-node-3 | pg-node-4 | pg-node-5 |
|---|---|---|---|---|---|
| 00-baseline | 100000 / 0 R | 100000 / 0 R | 100000 / 0 P | 100000 / 0 R | Unavailable / absent |
| 02-high-four-end | 100000 / 25 R | 100000 / 25 R | 100000 / 25 P | 100000 / 25 R | Unavailable / absent |
| 03-during-node-join | 100000 / 27 R | 100000 / 27 R | 100000 / 27 P | 100000 / 27 R | 100000 / 27 R |
| 04-five-ready | 100000 / 43 R | 100000 / 43 R | 100000 / 43 P | 100000 / 43 R | 100000 / 43 R |
| 05-during-primary-failure | 100000 / 60 R | 100000 / 60 R | Unavailable / absent | 100000 / 60 R | 100000 / 60 R |
| 06-after-failover | 100000 / 75 R | 100000 / 75 P | Unavailable / absent | 100000 / 75 R | 100000 / 75 R |
| 07-during-rejoin | 100000 / 76 R | 100000 / 76 P | Unavailable / absent | 100000 / 76 R | 100000 / 76 R |
| 08-after-rejoin | 100000 / 89 R | 100000 / 89 P | 100000 / 89 R | 100000 / 89 R | 100000 / 89 R |
| 09-drained-before-stop | 100000 / 91 R | 100000 / 91 P | 100000 / 91 R | 100000 / 91 R | 100000 / 91 R |
| 11-final | 100000 / 102 R | 100000 / 102 P | 100000 / 102 R | 100000 / 102 R | Unavailable / absent |

The removed node is unavailable in the final snapshot, NOT empty and NOT synchronized with writes after removal. Its last online counts appear at drain time; its volume is retained. All final online nodes have matching deterministic MD5 row fingerprints for the two lab tables. This verifies logical fixture content, not physical byte-for-byte equality of PostgreSQL data directories.

Acknowledged unique write tokens: **102**. Missing on final online nodes: **0**. The client retries the same token after an ambiguous outcome using a primary key and ON CONFLICT DO NOTHING. See [acknowledged-write-validation.json](acknowledged-write-validation.json). Asynchronous replication still does not guarantee zero data loss for arbitrary crashes or untested writes.

## Read connection distribution

| Scenario | node-1 | node-2 | node-3 | node-4 | node-5 |
|---|---:|---:|---:|---:|---:|
| 01-low-four | 39 | 39 | 0 | 39 | 0 |
| 02-high-four | 990 | 990 | 0 | 991 | 0 |
| 03-auto-scale-out | 1420 | 1420 | 0 | 1421 | 1013 |
| 04-high-five | 670 | 669 | 0 | 669 | 669 |
| 05-failover-under-load | 2064 | 983 | 0 | 2065 | 2065 |
| 07-rejoin-under-load | 907 | 0 | 620 | 908 | 907 |
| 09-auto-scale-in | 78 | 0 | 78 | 78 | 12 |
| 10-low-four-final | 27 | 0 | 26 | 27 | 4 |

Counters are HAProxy replica-backend session deltas, including benchmark clients and monitoring queries. Connections—not individual SQL statements—are balanced. Role-ineligible servers are expected DOWN in the opposite listener; absent node-5 is expected MAINT (resolution). Per-snapshot SQL routing results identify actual server IP and recovery role. PostgreSQL direct Unix-socket queries legitimately show a null server address.

## Evidence and limitations

- [commands.jsonl](commands.jsonl): exact Docker/curl/SQL commands, stdin, redacted credentials, UTC start/end, exit status, duration, and a separate output file for every invocation.
- [events.jsonl](events.jsonl), [metrics.jsonl](metrics.jsonl), [operation-durations.csv](operation-durations.csv): decisions, transitions, resource observations and timing.
- [benchmark-comparison.csv](benchmark-comparison.csv), [routing-comparison.csv](routing-comparison.csv), [row-count-comparison.csv](row-count-comparison.csv): compact comparisons.
- [write-probes.csv](write-probes.csv), [read-probes.csv](read-probes.csv), [nonzero-commands.csv](nonzero-commands.csv): failed and successful attempts, including expected missing/stopped nodes; errors are not silently treated as passes.
- Per-stage client.log and traffic/tx-* retain expanded read SQL and transaction timing. Per-command Docker/Patroni/PostgreSQL logs retain role changes, WAL recovery, and warnings. Stdout and stderr are separate in raw command files; use embedded UTC timestamps to order events across streams.
- [verification.json](verification.json) and [SHA256SUMS.csv](SHA256SUMS.csv) record independent acknowledgment/fingerprint checks, redaction scan, raw-output completeness, and file hashes. Regenerate hashes after changing derived reports.
- No external human intervention during measured scaling/recovery. Scripted kill and restore are fault-injection actions, not automatic machine resurrection. Initial feature deployment and test seeding are manual preparation. There is no persistent production controller after this finite task exits.
- The first attempt (20260908T110410Z) failed before scaling because Windows denied concurrent reads of a pgbench log. It is retained separately, not counted as a successful scenario. File sharing was fixed before this run. Preflight also rejected an unsupported HAProxy 2.9 keyword before deployment; see [preparation-notes.txt](../preparation-notes.txt).
- The first completed run (20260908T112126Z) exposed early DNS admission and post-stop slot re-enabling: three transition/final batches aborted. It is retained as a deviation. The revised controller starts the elastic backend disabled, admits only SQL-ready replicas, quarantines a returning node during recovery, and leaves a removed node in maintenance. A repeat run tests the fix and kills the previously promoted primary again.
- This run does not test coordinator sharding, write scale-out, arbitrary node discovery, scale-down of a primary, loss of etcd/HAProxy/the Docker host, divergent-write repair, sustained network partitions, or production application retry semantics.
- Earlier Phase 2 claims of byte-identical storage, instantaneous cloning, guaranteed zero loss, and ~12-second failover should not be reused as benchmark facts. Its stored kill timestamp is 10:26:27.992 and promotion log timestamp 10:27:04.690 (~36.698 seconds).

**Conclusion:** bounded traffic-triggered read-replica scale-out/scale-in and automatic PostgreSQL recovery were demonstrated. Transition/final aborted batches: 3; throughput change: -9.89%. Shard rebalancing and production-grade elastic capacity remain outside this validation.
