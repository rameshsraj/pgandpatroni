# Phase 4: isolated dynamic replica scaler (draft)

This is a bounded demonstration, **not a production autoscaler**. It creates its own run-specific network, etcd, Patroni scope, primary, permanent replica and HAProxy. It does not use Compose or change the existing Phase 3 cluster. No host ports are published. All container/network/volume names start with `phase4-`.

## Run prerequisites and parameters

- Windows PowerShell **7.2+**, Docker Desktop in Linux-container mode, and bind-mount access to this checkout. No host Python, WSL, image build, package install or image pull is required.
- Existing local images: `postgres-patroni-ha-pg-node-1:latest`, `quay.io/coreos/etcd:v3.5.15`, `haproxy:2.9-alpine`. The node image must contain Patroni, PostgreSQL 16 clients, curl and the writable postgres-owned directories from the existing Dockerfile.
- Run [run-lab.ps1](run-lab.ps1) with PowerShell 7 (`pwsh -NoProfile -File` followed by its path). Docker must already be running. The runner validates HAProxy inside its pinned image when actually executed.
- Parameters: `NodeImage`, `EtcdImage`, `ProxyImage`; `TrafficDurationSeconds=360` (per driver, hard bound); `ReadyTimeoutSeconds=180`; `CommandTimeoutSeconds=60`; `CooldownSeconds=15`; `LabTimeoutSeconds=1200`; `NodeMemoryMB=512`.
- Typical duration **5–10 minutes**, depending on storage, base backups and verbose log copying. The default overall experiment deadline is 20 minutes, plus bounded final evidence capture. On slower hosts increase the traffic and lab deadlines together. Timeout is a failure, never a successful scale-in demonstration.
- Maximum database allocation is six × 512 MiB, plus 256 MiB etcd, 128 MiB HAProxy, 256 MiB live traffic and Docker overhead. Existing clusters consume additional memory; an 8 GiB Docker VM is recommended. Verbose SQL/pgbench logging needs ample disk space.

## Experiment and independent policy

1. Start primary; confirm leader and SQL writable before creating the permanent replica. Seed 100,000 deterministic immutable fixture rows and an empty token-primary-key events table in database `postgres` using admin `postgres`.
2. Drive 2 offered TPS for at least 15 seconds, then 100 offered TPS / eight clients. Each transaction reconnects to HAProxy's replica route.
3. Controller reads **completed native pgbench transaction logs**, not offered load. Two samples strictly above 20 TPS create the next elastic replica, sequentially, up to four. Two samples strictly below 5 TPS remove one. A 15-second cooldown follows each completed action. Neither stage nor offered rate is a controller argument.
4. Every elastic node is a real dynamic `docker run`, with its own named volume and `nofailover=true`. Admission requires Patroni running/replica, streaming membership, known zero-byte lag, recovery SQL, fixture count/hash and HAProxy health. Runtime slot addresses come from narrowly formatted Docker IP inspection, not DNS guesses.
5. Four admitted replicas must be confirmed before the driver holds high load for at least 20 more seconds and lowers demand. Low traffic continues until all four are removed, then at least 10 more seconds.
6. Removal checks baseline safety, fixture/token agreement and target nofailover/replica, drains sessions to `scur=0`, enters maintenance and rechecks safety. SIGTERM shutdown precedes **full** Docker and PostgreSQL log copying. Only then is the container removed, without `-v`; absence and retained volume are verified.

[traffic.sh](traffic.sh) uses `PGDATABASE=postgres` and explicit `pgbench --debug` (short `-d` means debug, not database). [read.sql](read.sql) uses a fixed random seed and random indexed ranges, returning server address and recovery status. pgbench normally discards result rows; expanded SQL appears in debug logs and server SQL logs. Routing CSV and explicit SQL snapshots provide complementary evidence.

## Evidence and retention

Each invocation exclusively creates `evidence/<run-id>/`, ignored by Git:

- LF-normalized source copies, including the existing entrypoint and the new template; never a rendered password-bearing Patroni config or environment file.
- `commands.jsonl`: timestamp, exact redacted argv/stdin, exit, stdout, stderr, timeout and duration. Concurrent output reads avoid pipe deadlocks. Timeout kills the local CLI process tree; the remote action might already have happened, so inspect retained resource state.
- `sql.jsonl`: every controller SQL input, target and outcome. Traffic SQL lives in the copied workload plus pgbench debug/server logs, not as one JSON entry per transaction.
- Metrics, controller evaluations, lifecycle/driver events, roles/routing, fixture hashes and token snapshots; resource observations; raw transaction logs; full redacted server archives.
- `result.json`, narrowly scoped `resources.json`, and SHA-256 `manifest.json` excluding itself. A failed final archive makes the run unsuccessful, even if scaling completed.

Writes always pass through the own proxy primary route. Ambiguous write outcomes retry the **same** token, using conflict-safe insertion. Before removal and at final validation, every replica must contain exactly the primary's complete expected token set and fixture hash.

Success leaves primary, permanent replica, etcd and proxy running; names are printed and recorded. Elastic containers are removed but all named volumes remain. Traffic containers are stopped and retained for inspection. Failure stops traffic and archives what it can, but **does not tear down database resources**: a slot may remain ready, draining or in maintenance. Review the result and inventory before manual cleanup; do not use broad prune commands. No automatic rollback, teardown or resource adoption is attempted.

Random alphanumeric lab passwords exist only in process memory and Docker container metadata. All evidence replaces exact password values, including copied SQL logs; no full environment inspect is performed. During `docker cp`, raw log files can briefly exist before redaction. Anyone with Docker/host access can retrieve credentials; this is not a secret-management design. Retained PostgreSQL volumes contain the database itself and are outside the evidence redaction boundary. Local `docker exec` as image user postgres can use local trust authentication for later examination; passwords are deliberately not recoverable from evidence.

## Limitations / validation status

- Written and statically checked only; Docker and the lab were **not run** during implementation. Image/tool compatibility, bind permissions, lag reporting, memory headroom and actual performance require execution on the target Docker Desktop host.
- Samples use a trailing 10-second transaction-timestamp window ending two seconds in the past. Windows readers allow `ReadWrite | Delete`. Native pgbench buffering can undercount recent/low-rate completions; overlapping windows and debug I/O mean this is demonstrative rather than an unbiased capacity metric. No offered-rate fallback exists. A stopped driver fails the run instead of inducing scale-in.
- Observation polling uses blocking `docker stats --no-stream`, not sleeps. Actions and evidence collection are synchronous; sample cadence is variable and controller decisions pause during base backups/archives. The driver is a separate function, not a production concurrent service.
- Primary/base can technically fail over, but this experiment expects the original primary to remain writable and aborts on role changes. It injects no failures and does not demonstrate HA of the single etcd/proxy, durable HAProxy runtime state, CPU-based scaling, latency SLOs or production pooling.
- Elastic stopped-container logs are complete through shutdown; final running baseline logs are a live, non-atomic copy. Log files are not truncated by the runner, but disk-full/OOM/external deletion can invalidate evidence. SQL text logging is intentionally costly and inappropriate as a production default.
- One bounded up/down cycle; no reusable-volume rejoin or resource cleanup controller. A manual report can be prepared later in the parent repository from completed evidence. No report or success measurements are fabricated here.
