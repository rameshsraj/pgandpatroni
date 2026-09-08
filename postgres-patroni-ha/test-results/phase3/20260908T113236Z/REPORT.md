# Phase 3 — Traffic-driven scaling and recovery LAB

Run: **20260908T113236Z**. Evidence generated from recorded results; all times UTC.

## Verdict

- **Functional bounded elasticity: PASS** — observed traffic triggered optional replica provisioning, automatic DNS/health-based routing, and low-demand drain/stop without operator action during the scenarios.
- **Read continuity during scale/rejoin/removal: PASS for observed workload** — 0 aborted pgbench batches across scale-out, rejoin, scale-in, and final low traffic. Failures remain in the evidence even if the client later retries.
- **Failover/rejoin: PASS for this run** — primary was hard-killed; Patroni promoted another node; retrying client probes resumed through the same HAProxy endpoint; the old primary rejoined without repair.
- **Performance: no throughput improvement observed.** Four-node high-load throughput was 91.63 TPS; five-node throughput was 68.5 TPS (-25.25%). Extra containers share one host rather than adding physical resources.
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
| 01-low-four | 5 | 5.2 | 104 | 24.48 | 50.58 | 63.6 | 0 |
| 02-high-four | 120 | 91.63 | 2749 | 965.95 | 2208.83 | 2512.5 | 0 |
| 03-auto-scale-out | 120 | 78.12 | 5078 | 1662.54 | 3874.35 | 4901.4 | 0 |
| 04-high-five | 120 | 68.5 | 2055 | 2257.03 | 4160.36 | 4909.28 | 0 |
| 05-failover-under-load | 120 | 58.23 | 5241 | 2760.62 | 5223.09 | 5768.18 | 0 |
| 07-rejoin-under-load | 120 | 47.98 | 2879 | 2867.27 | 5953.41 | 7027.7 | 0 |
| 09-auto-scale-in | 5 | 5 | 200 | 26.64 | 55.12 | 69.6 | 0 |
| 10-low-four-final | 5 | 4.95 | 99 | 23.82 | 50.04 | 62.44 | 0 |

TPS = logged successful reads / requested traffic duration. Batch startup/rounding creates small timing differences (actual completion spans and UTC times are retained). Latencies include rate-schedule delay and reconnection; they are not server query execution times. Only successful transactions contribute percentiles. Failed batches, client probes, connection failures, and nonzero commands are retained separately. No repeated trials, fixed random seed, isolated hardware, pooler, or warmed production-sized workload: not a capacity certification.

## Operation timings

| Operation | Start UTC | End UTC | Seconds |
|---|---|---|---:|
| Traffic trigger to ready observation | 2026-09-08T11:34:38.6286158Z | 2026-09-08T11:35:04.5126709Z | 25.884 |
| Kill command | 2026-09-08T11:36:37.1178584Z | 2026-09-08T11:36:37.9204217Z | 0.803 |
| Kill start to promotion observation | 2026-09-08T11:36:37.1178584Z | 2026-09-08T11:37:06.3360169Z | 29.218 |
| Restore to rejoin observation | 2026-09-08T11:38:14.2102141Z | 2026-09-08T11:38:41.2412856Z | 27.031 |
| Low demand trigger to stopped replica | 2026-09-08T11:39:32.7620294Z | 2026-09-08T11:39:43.0581879Z | 10.296 |

Killed primary: **pg-node-2**; elected primary: **pg-node-3**. Returning node becomes a replica, not a failback/switchover to its former role.

First successful write-probe completion after kill: **2026-09-08T11:37:09.5500244Z**, **32.432 seconds** after kill start. Failed write attempts after kill: **3**. Last pre-kill acknowledgment: 2026-09-08T11:36:36.5648846Z. These are sampled recovery observations, not precise downtime; snapshots interrupt write probing but not the independent pgbench read stream.

## Row counts on every node

Cells show **items / events** and role (P=primary, R=replica). Public reference tables remained customers=5, orders=7, ha_test=5 wherever reachable; full counts and fingerprints are in [row-count-comparison.csv](row-count-comparison.csv). Each snapshot is sequential, not an atomic cluster-wide snapshot.

| Scenario | pg-node-1 | pg-node-2 | pg-node-3 | pg-node-4 | pg-node-5 |
|---|---|---|---|---|---|
| 00-baseline | 100000 / 102 R | 100000 / 102 P | 100000 / 102 R | 100000 / 102 R | Unavailable / absent |
| 02-high-four-end | 100000 / 126 R | 100000 / 126 P | 100000 / 126 R | 100000 / 126 R | Unavailable / absent |
| 03-during-node-join | 100000 / 128 R | 100000 / 128 P | 100000 / 128 R | 100000 / 128 R | 100000 / 91 R |
| 04-five-ready | 100000 / 142 R | 100000 / 142 P | 100000 / 142 R | 100000 / 142 R | 100000 / 142 R |
| 05-during-primary-failure | 100000 / 155 R | Unavailable / absent | 100000 / 155 R | 100000 / 155 R | 100000 / 155 R |
| 06-after-failover | 100000 / 170 R | Unavailable / absent | 100000 / 170 P | 100000 / 170 R | 100000 / 170 R |
| 07-during-rejoin | 100000 / 171 R | Unavailable / absent | 100000 / 171 P | 100000 / 171 R | 100000 / 171 R |
| 08-after-rejoin | 100000 / 181 R | 100000 / 181 R | 100000 / 181 P | 100000 / 181 R | 100000 / 181 R |
| 09-drained-before-stop | 100000 / 183 R | 100000 / 183 R | 100000 / 183 P | 100000 / 183 R | 100000 / 183 R |
| 11-final | 100000 / 205 R | 100000 / 205 R | 100000 / 205 P | 100000 / 205 R | Unavailable / absent |

The removed node is unavailable in the final snapshot, NOT empty and NOT synchronized with writes after removal. Its last online counts appear at drain time; its volume is retained. All final online nodes have matching deterministic MD5 row fingerprints for the two lab tables. This verifies logical fixture content, not physical byte-for-byte equality of PostgreSQL data directories.

Acknowledged unique write tokens: **103**. Missing on final online nodes: **0**. The client retries the same token after an ambiguous outcome using a primary key and ON CONFLICT DO NOTHING. See [acknowledged-write-validation.json](acknowledged-write-validation.json). Asynchronous replication still does not guarantee zero data loss for arbitrary crashes or untested writes.

## Read connection distribution

| Scenario | node-1 | node-2 | node-3 | node-4 | node-5 |
|---|---:|---:|---:|---:|---:|
| 01-low-four | 39 | 0 | 38 | 39 | 0 |
| 02-high-four | 922 | 0 | 922 | 922 | 0 |
| 03-auto-scale-out | 1455 | 0 | 1455 | 1454 | 745 |
| 04-high-five | 517 | 0 | 517 | 517 | 517 |
| 05-failover-under-load | 1549 | 0 | 630 | 1550 | 1550 |
| 07-rejoin-under-load | 831 | 412 | 0 | 831 | 830 |
| 09-auto-scale-in | 71 | 72 | 0 | 71 | 11 |
| 10-low-four-final | 37 | 37 | 0 | 37 | 0 |

Counters are HAProxy replica-backend session deltas, including benchmark clients and monitoring queries. Connections—not individual SQL statements—are balanced. Role-ineligible servers are expected DOWN in the opposite listener; absent node-5 is expected MAINT (resolution). Per-snapshot SQL routing results identify actual server IP and recovery role. PostgreSQL direct Unix-socket queries legitimately show a null server address.

## Evidence and limitations

- [commands.jsonl](commands.jsonl): exact Docker/curl/SQL commands, stdin, redacted credentials, UTC start/end, exit status, duration, and a separate output file for every invocation.
- [events.jsonl](events.jsonl), [metrics.jsonl](metrics.jsonl), [operation-durations.csv](operation-durations.csv): decisions, transitions, resource observations and timing.
- [benchmark-comparison.csv](benchmark-comparison.csv), [routing-comparison.csv](routing-comparison.csv), [row-count-comparison.csv](row-count-comparison.csv): compact comparisons.
- [write-probes.csv](write-probes.csv), [read-probes.csv](read-probes.csv), [nonzero-commands.csv](nonzero-commands.csv): failed and successful attempts, including expected missing/stopped nodes; errors are not silently treated as passes.
- Per-stage client.log and traffic/tx-* retain expanded read SQL and transaction timing. Per-command Docker/Patroni/PostgreSQL logs retain role changes, WAL recovery, and warnings. Stdout and stderr are separate in raw command files; use embedded UTC timestamps to order events across streams.
- [Post-benchmark health-check maintenance](post-benchmark-healthcheck.jsonl): recorded timed-out configuration checks, validated wget HTTP liveness, recreated ONLY HAProxy, and checked routing. This intentional maintenance restart is outside all benchmark timings; it must not be silently counted as zero-touch recovery. [Live verification](live-verification.jsonl) retains both earlier unhealthy and later healthy observations.
- [verification.json](verification.json) and [SHA256SUMS.csv](SHA256SUMS.csv) record independent acknowledgment/fingerprint checks, redaction scan, raw-output completeness, and file hashes. Regenerate hashes after changing derived reports.
- No external human intervention during measured scaling/recovery. Scripted kill and restore are fault-injection actions, not automatic machine resurrection. Initial feature deployment and test seeding are manual preparation. There is no persistent production controller after this finite task exits.
- The first attempt (20260908T110410Z) failed before scaling because Windows denied concurrent reads of a pgbench log. It is retained separately, not counted as a successful scenario. File sharing was fixed before this run. Preflight also rejected an unsupported HAProxy 2.9 keyword before deployment; see [preparation-notes.txt](../preparation-notes.txt).
- The first completed run (20260908T112126Z) exposed early DNS admission and post-stop slot re-enabling: three transition/final batches aborted. It is retained as a deviation. The revised controller starts the elastic backend disabled, admits only SQL-ready replicas, quarantines a returning node during recovery, and leaves a removed node in maintenance. A repeat run tests the fix and kills the previously promoted primary again.
- This run does not test coordinator sharding, write scale-out, arbitrary node discovery, scale-down of a primary, loss of etcd/HAProxy/the Docker host, divergent-write repair, sustained network partitions, or production application retry semantics.
- Earlier Phase 2 claims of byte-identical storage, instantaneous cloning, guaranteed zero loss, and ~12-second failover should not be reused as benchmark facts. Its stored kill timestamp is 10:26:27.992 and promotion log timestamp 10:27:04.690 (~36.698 seconds).

**Conclusion:** bounded traffic-triggered read-replica scale-out/scale-in and automatic PostgreSQL recovery were demonstrated. Transition/final aborted batches: 0; throughput change: -25.25%. Shard rebalancing and production-grade elastic capacity remain outside this validation.
