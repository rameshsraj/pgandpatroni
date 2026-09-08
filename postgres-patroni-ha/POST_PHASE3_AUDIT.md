# After Phase 3: activity and SQL evidence audit

## Verified activity (8 September 2026, UTC)

| Time | Activity | Evidence |
|---|---|---|
| 11:40:39 | Final guarded Phase 3 run completed: four permanent nodes, elastic volume preserved, 103 acknowledged write tokens. | [run events](test-results/phase3/20260908T113236Z/events.jsonl) |
| 11:46:27–11:46:56 | Diagnosed HAProxy's failing Docker health check; the HTTP statistics endpoint was reachable despite the health-check timeout. | [maintenance transcript](test-results/phase3/20260908T113236Z/post-benchmark-healthcheck.jsonl) |
| 11:46:56–11:47:23 | Validated Compose and recreated **only HAProxy**, using an HTTP health check instead of the problematic configuration-validation health check. Container became healthy. This was separate from benchmark timing. | [maintenance transcript](test-results/phase3/20260908T113236Z/post-benchmark-healthcheck.jsonl) |
| 11:47:23 | Executed `SELECT inet_server_addr(),pg_is_in_recovery(),count(*) FROM phase3_lab.items;` through the primary endpoint. Result: `172.19.0.8`, `false`, `100000`. | [maintenance transcript](test-results/phase3/20260908T113236Z/post-benchmark-healthcheck.jsonl) |
| 12:09:16 | Commit `d1bf2a1` recorded Phase 3 scripts/configuration and related changes. A commit timestamp is not an execution timestamp. | Git history |
| 12:58:52 | Commit `950b39c` updated the HA lab README only. | Git history |

**No subsequent Phase 4 or Citus sharding execution was established by this audit.** Sharding scripts exist, but their presence is not evidence that they ran after Phase 3. Unrecorded activity cannot be ruled out.

## Why the evidence was difficult to find

- Post-benchmark maintenance used a separate transcript, not the main Phase 3 command stream.
- SQL was spread across command arguments/stdin, individual command output files, pgbench debug client traces and PostgreSQL logging-collector files. Docker logs alone do not contain all PostgreSQL statements.
- [The ignore rules](.gitignore) exclude both `test-results/` and `docs/`. The local evidence and the prior detailed guide therefore are not available in an ordinary Git checkout or repository view.
- This audit is outside those ignored directories so the explanation can be committed. Raw SQL archives remain ignored deliberately: they are large and can expose sensitive literals. A separate access-controlled evidence archive is still required for sharing/retention; none was uploaded by this audit.

## Capture performed now

The [capture inventory](test-results/sql-capture/20260908T165641Z/README.md) describes the completed, non-destructive collection:

- **1,421 command records** from all three retained Phase 3 runs, including the separate maintenance transcript.
- **842 psql invocation records**, preserving SQL input, command, timestamps, exit status and references to full results. These are invocation counts, not individual SQL-statement counts or committed-transaction counts.
- Full historical command output files and pgbench client traces, preserving expanded read queries and multiline text without deduplication.
- **28 retained PostgreSQL server log files (120,512,207 bytes)** copied successfully from all five nodes, including stopped `pg-node-5` without starting it.
- **1,465 evidence files SHA-256 verified** against the [manifest](test-results/sql-capture/20260908T165641Z/SHA256SUMS.csv).
- [All commands](test-results/sql-capture/20260908T165641Z/all-commands.jsonl), [SQL invocation index](test-results/sql-capture/20260908T165641Z/sql-command-records.jsonl), and [collection outcomes](test-results/sql-capture/20260908T165641Z/collection-commands.jsonl) are separate entry points.

The earlier capture directory `20260908T165528Z` is an incomplete attempt: manifest generation encountered a self-read conflict. It was preserved, not overwritten. Use the completed capture above.

## Future collection and limits

[capture-sql-evidence.ps1](scripts/phase3/capture-sql-evidence.ps1) consolidates retained Phase 3 records; its `IncludeRetainedServerLogs` switch also copies the existing PostgreSQL log directory from each node. It does not replay queries or alter cluster state.

[run-lab.ps1](scripts/phase3/run-lab.ps1) now writes an explicit SQL invocation index and named per-node server-log snapshots with source command/exit-status references, and attempts a cleanup archive on failed runs as well as successful runs. Existing pgbench debug tracing continues to capture expanded workload queries. The modified destructive lab has **not** been rerun as part of this audit.

This captures **all available retained records**, not a provably complete lifetime audit. Deleted/rotated logs, unrecorded shell statements, statements never sent to the server and buffered concurrent writes cannot be reconstructed. Logs copied from live nodes are not atomic snapshots. Known configured passwords are redacted; other sensitive SQL literals may remain. Complete ongoing retention needs periodic archival and monitoring for collection failures, rotation and storage capacity. Statement logging also adds substantial overhead and is not recommended indiscriminately for production.