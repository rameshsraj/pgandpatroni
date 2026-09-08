# Phase 4 Docker execution results — 8 September 2026

## Status and completed checklist

- [x] Inspected prior implementation, changes, Phase 3 pitfalls and Docker configuration.
- [x] Validated PowerShell syntax, policy tests and Bash syntax; validated HAProxy in its actual image.
- [x] Ran an isolated Docker stack, generated traffic and dynamically created four real PostgreSQL replica containers.
- [x] Lowered demand, drained and removed all four containers, preserving their named volumes.
- [x] Independently verified artifact hashes, transaction records, policy decisions, data agreement and live resources.
- [x] Preserved and documented unsuccessful/incomplete attempts.

**Verified run:** `phase4-20260908T173358240-1efd4a87`.

Experiment: **17:33:58–17:40:31 UTC, 393.211 seconds**. Final evidence collection follows the experiment. Independent verification began at **17:41:36 UTC**, including live container and SQL checks.

The [machine-readable report](reports/phase4-20260908T173358240-1efd4a87.json) contains measurements and the exact live verification commands, outputs, exit codes, UTC start times and durations. The [runner result](evidence/phase4-20260908T173358240-1efd4a87/result.json) records success, retained resources and all token identifiers.

This is a **bounded non-production demonstration**, not an always-on autoscaler or a capacity improvement claim. The existing Phase 3 and unrelated database containers were not stopped, changed or deleted; their existing health checks remained healthy in the observed final inventory.

## Environment and isolation

- Windows host, PowerShell 7, Linux containers on Docker Desktop; 8 CPUs and 8,210,579,456 bytes Docker memory reported at preflight. No WSL or host Python was used.
- Existing images, no pulls/builds: PostgreSQL/Patroni node image ID `db72c0d677a3c6688e960cee809f409080df997bea47058fc1da945249cd4e48`; etcd ID `0934690612905554eb61ddefb9faaaecb47c2f6931dbb453e694358092ee8990`; HAProxy ID `3e29449a6beed63262e36104adf531b4e41b359f61937303f5ea8607987b3748`.
- HAProxy actually reported **2.9.15**. Tags are not immutable; each run records image IDs.
- Run-specific network, etcd data, Patroni scope, primary, permanent replica, proxy, traffic containers and named PostgreSQL volumes. No host ports published.
- Baseline: **2 PostgreSQL containers**, one primary plus one permanent replica. Peak: **6 PostgreSQL containers**, one primary plus five replicas. This is deliberately separate from the four-node Phase 3 baseline.
- See [topology and dataflow](README.md#topology-and-dataflow). All writes use proxy port 5000; read traffic uses proxy port 5001. WAL/base-backup replication supplies the dynamic replicas; controller input comes from completed native pgbench logs, not the configured offered rate.

## Measured scaling actions

Two controller evaluations above 20 completed TPS are required for scale-out; two below 5 TPS for scale-in. A 15-second cooldown follows each action. Samples cover a trailing 10-second timestamp window ending two seconds behind observation. Sampling cadence is variable and windows may overlap.

Times below are UTC. Action duration is decision to admission/removal, including readiness or drain/archive work, not just container startup/shutdown.

| Action | Slot | Decision UTC | Completed UTC | Decision TPS | Duration seconds |
|---|---|---|---|---:|---:|
| Create/admit | elastic1 | 17:34:57.776 | 17:35:08.733 | 60.0 | 10.957 |
| Create/admit | elastic2 | 17:35:27.424 | 17:35:40.057 | 56.5 | 12.633 |
| Create/admit | elastic3 | 17:36:04.485 | 17:36:18.802 | 63.8 | 14.317 |
| Create/admit | elastic4 | 17:36:41.666 | 17:36:58.248 | 56.0 | 16.582 |
| Drain/remove | elastic4 | 17:38:25.701 | 17:38:39.226 | 1.4 | 13.525 |
| Drain/remove | elastic3 | 17:38:59.762 | 17:39:11.028 | 2.4 | 11.266 |
| Drain/remove | elastic2 | 17:39:33.061 | 17:39:43.290 | 2.6 | 10.229 |
| Drain/remove | elastic1 | 17:40:02.071 | 17:40:12.249 | 2.6 | 10.178 |

Each admission checked Patroni replica/running, streaming membership, known zero lag, SQL recovery role and the fixture count/hash. Every elastic node had `nofailover=true` and served proxy traffic. Each removal checked the permanent replica, target role and data agreement; drained to zero active sessions; entered maintenance; rechecked readiness; stopped with SIGTERM/exit 0; archived logs; removed the container without deleting its volume; verified absence and volume retention. Final slots were all `MAINT` with zero sessions.

At the four-active steady-end snapshot, replica-route cumulative connections were: permanent **4,050**, elastic1 **2,581**, elastic2 **1,738**, elastic3 **1,074**, elastic4 **606**. All five were `UP`, with `econ=0` and `eresp=0`. These are proxy connections, not independent SQL transaction counts.

## Traffic, SQL and data outcomes

| Stage | Offered TPS | Complete transaction records | Invalid records | Mean scheduled transaction latency (ms) |
|---|---:|---:|---:|---:|
| Low baseline | 2 | 52 | 0 | 23.874 |
| High | 100 | 10,182 | 0 | 2,210.003 |
| Low final | 2 | 364 | 0 | 33.197 |

**10,598 complete records** total; **zero detected pgbench error/abort/connection-failure signatures**. All three traffic containers exited **0**. Natural 10-second batches flush logs before the traffic shell honors SIGTERM. Finite samples, deterministic seed reset per batch, connection-per-transaction overhead, scheduling lag, verbose logging and shared Docker resources affect rates and latency. High-load mean latency includes pgbench rate-scheduling delay; it is not isolated SQL execution latency. Adding replicas did not demonstrate an SLO or prove higher capacity.

- [Seed SQL](seed.sql): 100,000 deterministic rows in `phase4_lab.items`, plus primary-key token events in `phase4_lab.events`, all inside the isolated database `postgres`.
- [Read SQL](read.sql): random indexed 100-row ranges; returns server address, recovery role, count and aggregates. Debug traces contain expanded SQL; pgbench does not retain result rows. Proxy statistics and explicit controller SQL provide routing/role evidence.
- Write probes: insert a unique token with `ON CONFLICT(token) DO NOTHING`, then select its token, server address and recovery role. Ambiguous retries reuse the same token.
- **54 tokens** were acknowledged and present on both final primary and permanent replica; all active replicas agreed before removal.
- Final primary and replica each contained **100,000 fixture rows**, fixture MD5 **`0f42f18a2baad7f892d29c774a09d284`**. MD5 here is a deterministic fixture equality check, not a security checksum; artifact integrity uses SHA-256.
- Live SQL independently reconfirmed final counts and expected primary/recovery roles.

## Commands, logs, timings and evidence

The reproducible entry point is VS Code task **Phase 4: isolated dynamic replica scaling LAB**, invoking PowerShell 7 with [run-lab.ps1](run-lab.ps1) and `-TrafficDurationSeconds 900`. All other runner parameters used defaults. Static tests are in [validate-static.ps1](validate-static.ps1); Bash syntax was checked with the existing node image and an isolated `--network none` transient container. HAProxy config validation occurs in each actual lab run.

Independent validation invoked [verify-evidence.ps1](verify-evidence.ps1) with the successful evidence directory and `-Live`; it completed successfully. The first verifier invocation against this final run hit a StrictMode empty-regex-match handling bug; the verifier was fixed and rerun against unchanged raw evidence.

Evidence index (local, Git-ignored):

- [All 794 Docker commands](evidence/phase4-20260908T173358240-1efd4a87/commands.jsonl): exact redacted argv/stdin, stdout/stderr, exit, UTC start, elapsed milliseconds and timeout flag. End time is start plus elapsed duration.
- [Controller SQL inputs/results](evidence/phase4-20260908T173358240-1efd4a87/sql.jsonl).
- [Lifecycle events and UTC milestones](evidence/phase4-20260908T173358240-1efd4a87/events.jsonl), [metrics](evidence/phase4-20260908T173358240-1efd4a87/metrics.jsonl), [controller evaluations](evidence/phase4-20260908T173358240-1efd4a87/decisions.jsonl).
- [Topology, fixture and token snapshots](evidence/phase4-20260908T173358240-1efd4a87/snapshots.jsonl), [proxy routing samples](evidence/phase4-20260908T173358240-1efd4a87/routing.jsonl), [resource inventory](evidence/phase4-20260908T173358240-1efd4a87/resources.json).
- The same evidence directory contains exact LF-normalized source/config-template snapshots, raw per-batch transaction logs, complete captured client/Docker logs and PostgreSQL CSV/stderr logs. Elastic server archives extend through graceful shutdown; running baseline copies are live/non-atomic.
- [SHA-256 manifest](evidence/phase4-20260908T173358240-1efd4a87/manifest.json): **144 files, 53,572,758 bytes** verified, no extra unmanifested files. Manifest SHA-256: **`B875BCEBCA5546E137B9E190D8917DCA3EF055DE771C467B09925CA99F35B38A`**.

There were **18 nonzero commands**, all retained: six expected initial REST connection-refused readiness probes, and twelve expected absent-container inspections after elastic removal (four immediate, four archive inventory, four final inventory). There were **zero command timeouts**. Nonzero startup probes are not concealed as successful commands.

Exact generated secrets were scrubbed by the runner; the independent verifier also found no standalone 48-hex credential patterns. This is not a general secret scanner. Credentials remain available to Docker administrators through container metadata, and database volumes are outside the redacted evidence boundary. No rendered password-bearing config was copied into evidence.

## Earlier attempts — preserved, not rewritten

| Run | Actual outcome | Correction |
|---|---|---|
| `phase4-20260908T172223670-814f618f` | Primary/base started; HAProxy rejected missing final LF; no elastic admission. | Normalize captured source/config to end with LF. [Failure result](evidence/phase4-20260908T172223670-814f618f/result.json). |
| `phase4-20260908T172330223-7440cd0b` | Traffic ran; elastic1 created and ready, but runner rejected HAProxy's positive address-change acknowledgement; zero admissions recorded. | Accept the exact expected positive response; retain rejection of unexpected replies. [Failure result](evidence/phase4-20260908T172330223-7440cd0b/result.json). |
| `phase4-20260908T172559675-6d1659c7` | Runner completed four admissions/removals, but independent validation rejected interrupted transaction-log tails. **Not fully verified**, despite its historical runner success flag. | Replace direct pgbench termination with bounded batches that flush; require clean traffic exit. [Historical result](evidence/phase4-20260908T172559675-6d1659c7/result.json). |
| `phase4-20260908T173358240-1efd4a87` | Four admissions/removals, complete transaction logs, manifest/data/live checks passed. | Final verified run reported above. |

## Retention, safety and remaining limitations

**Replication-slot verification gap:** retained primary logs show Patroni conditional cleanup statements for elastic4, elastic3 and elastic2, with completion durations; they do not capture the returned rows or before/after slot inventories. No elastic1 cleanup statement was found within the archived primary-log window. Graceful shutdown and container removal do not prove all slots were deleted or WAL reclaimed. See the [replication investigation and exact scaling decision timeline](SCALING_REPLICATION_INVESTIGATION.md) for direct evidence and the first measurements to add to a future run.

The verified run retains primary, permanent replica, etcd and proxy running; three stopped traffic containers; four removed elastic containers' named data volumes; all other run volumes and its network. Earlier attempts' resources are also retained, including the second attempt's unadmitted elastic1. No database-volume cleanup was performed. Some images inherit Compose project/service labels: **do not use Compose project labels to clean up Phase 4**; use the exact run names or `phase4.run` label, inspect first, and preserve volumes unless explicitly authorized otherwise. No broad prune operation is appropriate.

The controller is synchronous, bounded to one up/down cycle and four slots. It lacks restart/adoption logic, durable proxy runtime state, concurrency control across controllers, production credentials, multi-etcd/proxy HA, reusable-volume rejoin tests and latency/CPU-based policy. It injects no primary failure and aborts on an unexpected original-primary role change. Earlier retained stacks share resources with the verified test. These measurements demonstrate lifecycle/routing/data-preservation behavior, **not production autoscaling readiness**.