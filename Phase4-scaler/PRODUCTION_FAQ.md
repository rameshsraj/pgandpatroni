# Phase 4 — production questions and blog guidance

## Short answer: do we need the same custom scripts in production?

**No, not necessarily these scripts. But automatic load-based replica scaling requires a controller somewhere.**

In this demonstration the controller is custom **PowerShell**, while Bash/pgbench generates synthetic traffic. Docker runs containers, Patroni manages PostgreSQL HA/replication, and HAProxy routes connections. None of those components independently decides to add read replicas because application demand rose.

If this exact stack is deployed without a replacement scaling controller, it is a fixed-size database deployment with Patroni-managed HA, **not automatic demand-based scaling**. Operators can still provision replicas manually. The bounded [lab runner](run-lab.ps1) is not a production service and must not simply be scheduled repeatedly against production: it creates a fresh isolated experiment and generates test traffic.

## What are the production choices?

| Approach | Who supplies the scaling logic? | What the team still owns |
|---|---|---|
| Fixed replicas with manual capacity changes | Human operators and reviewed automation | Forecasting, provisioning, replication checks, routing, safe removal, monitoring and recovery. Often simpler when demand is predictable. |
| Self-managed without Kubernetes | A supported controller/platform with PostgreSQL integration, or an engineered custom controller using Docker/VM provisioning APIs | All database-specific safety and operational responsibilities not supplied by that platform. Ansible/Terraform-style provisioning alone does not constitute a live demand controller. |
| Kubernetes with a PostgreSQL operator | Operator reconciles supported cluster topology; a compatible policy/controller changes the operator's desired replica count | Verify the specific operator's scaling interface, storage/replication behavior and support. Operator reconciliation is not automatically metric-driven autoscaling. |
| Managed PostgreSQL service | Provider control plane, **if the selected service explicitly supports automatic read-replica scaling** | Service selection, limits, consistency/routing choices, cost policy, monitoring, backups and recovery requirements. Some offerings only support manual replicas, compute scaling or storage autoscaling. |

**Kubernetes is not a prerequisite.** Conversely, installing Kubernetes does not automatically make PostgreSQL autoscale. A generic HPA/KEDA setup must not independently change operator-managed database workloads or remove arbitrary pods: use the operator's supported control path and coordinated ownership. Scaling stateless application containers is a separate, generally simpler problem.

## Can the custom controller be used in production after hardening?

Yes in principle, but the team then owns a software service, not merely a script. The language is not the deciding factor; correctness, supportability and failure handling are. At minimum it needs:

- **Persistent reconciliation:** compare desired capacity with actual containers/VMs, Patroni membership, routing and storage on every cycle. Adopt existing resources after restart, resume partial operations and make retries idempotent rather than creating duplicates.
- **Single authoritative writer:** leader election/locking and fencing so two controllers cannot issue conflicting actions. Persist action state and coordinate with maintenance and failover.
- **A real deployment model:** service supervision, restart policy, versioned configuration, least-privilege provisioning credentials, secret management, authenticated/encrypted control channels and restricted network access. Access to a Docker socket is highly privileged.
- **Trustworthy demand signals:** real application/database metrics, freshness checks and missing-data handling. CPU, latency/SLO, queue pressure, pool saturation, read rate and replication lag need workload-specific interpretation. Stop automatic scale-in when telemetry is stale or ambiguous; alert instead of treating missing data as zero demand.
- **Capacity and timing policy:** minimum HA capacity, maximum cost/capacity, stabilization windows, cooldowns, resource headroom and provisioning deadlines that account for base-backup size and catch-up time. Add host capacity when required; containers on a saturated host do not create resources.
- **Database-aware admission/removal:** verify the current primary, replica health, lag, routing and active sessions. Protect eligible HA replicas, coordinate with failover, and confirm replication-slot cleanup/WAL retention after removal. Define reuse/deletion policy for data disks and volumes.
- **Durable routing configuration:** rediscover/reconcile backend membership after proxy restart; do not rely solely on volatile HAProxy runtime edits. Plan connection-pool behavior, drain timeouts and long-running transactions.
- **Operational controls:** alerts, audit trails, dashboards, pause/manual override, bounded rollback/recovery procedures, canary rollout, backup/PITR verification, restore drills and realistic failure tests.

The Phase 4 run does **not** implement or validate that entire list. Its short thresholds, generated traffic and four-slot limit demonstrate mechanics, not recommended production sizing or policy.

## What happens if the controller stops?

In this lab it stops after its experiment. There is no further load-based scaling. PostgreSQL, Patroni, etcd and HAProxy are independent processes and can continue operating if their own dependencies remain healthy; Patroni's failover mechanism does not require this scaling loop. This run did not inject a primary failure to test that behavior.

A controller crash during an action is more complicated than a crash while idle: an extra container, disabled backend, draining replica or uncollected evidence may remain. The lab retains resources for investigation rather than attempting broad destructive cleanup. A production controller must discover and safely reconcile those intermediate states after restart. Merely enabling automatic process restart does not solve state recovery.

## Does adding replicas increase write capacity?

**No.** The demonstration adds read replicas. Writes still go to one primary, and replicas receive those changes through WAL replication. More replicas can increase primary replication/network work as well as consume storage and I/O. High write load needs a separate capacity analysis; read-replica autoscaling is not sharding or multi-primary operation.

Applications must choose primary versus replica endpoints. HAProxy does not parse SQL to decide. Read-after-write or other consistency-sensitive reads may need the primary; asynchronous replicas can lag even after successful admission. Adding a replica also does not migrate established TCP connections, so connection-pool behavior affects how quickly it receives work.

## Why not use the lab TPS thresholds in production?

Completed TPS is **throughput**, not necessarily demand. A slow or failing database can complete fewer transactions while requests are queuing. Scaling in because throughput fell could worsen an incident. The lab's two-sample rules and 15-second cooldown are intentionally short enough to show a full cycle; production policy must be derived from the workload, capacity measurements and recovery/SLO requirements.

The [investigation](SCALING_REPLICATION_INVESTIGATION.md) explains the exact metric window, variable sampling cadence and the eight observed decisions. We did not prove improved capacity or lower latency from adding replicas on this shared Docker host.

## Was replication-slot cleanup proven?

**Yes for the new isolated experiment; no for the original historical run.** The [new results](SLOT_VERIFICATION_RESULTS.md) independently verify all four actual physical-slot absences using timestamped returned slot/sender/receiver rows, matched active slots before stop, stable primary identity/timeline and a healthy permanent replica. Primary logs extend past the last observation and include elastic1 cleanup. Query errors, unknown state and timeout fail closed; the controller does not force-drop slots or manually remove DCS members.

The original run still has only three conditional Patroni cleanup statements without captured returned outcomes. Its [historical evidence gap](SCALING_REPLICATION_INVESTIGATION.md#5-what-the-historical-slot-logs-actually-captured) is not retroactively erased. Neither run proves physical WAL-file/disk reclamation. Observed cleanup delays support asynchronous reconciliation; they do not establish an exact deletion time or fixed 30-second SLA.

Production scale-in needs this check: an abandoned physical slot can retain WAL and eventually exhaust primary storage. Container deletion and volume retention do not establish the slot's state.

## Should production log every SQL statement as this lab does?

Not indiscriminately. Full SQL and debug logging can expose credentials, personal data or business data and add significant overhead/storage cost. Establish a security-reviewed audit/observability policy, access control, retention and redaction appropriate to the workload. Preserve lifecycle decisions, commands, errors and required replication observations, and use targeted statement tracing when justified. The lab's forensic capture is not a blanket production logging recommendation.

## Blog-ready summary

> We demonstrated load-triggered PostgreSQL read-replica scaling without Kubernetes. A custom PowerShell controller measured generated traffic, created four additional Docker containers, admitted them to HAProxy only after replication/readiness checks, and drained and removed them when traffic fell. A separate follow-up captured actual replication-slot rows and independently verified all four target slots absent after Patroni reconciliation, while retaining the permanent replica and data volumes. Patroni managed HA/replication; it did not make load-based capacity decisions. This proves a bounded lifecycle demonstration, not a production-ready autoscaling product. Production requires a supported database-aware scaling platform or an engineered persistent controller. Read scaling does not increase primary write capacity, observed delays are not a cleanup SLA, and slot absence does not prove physical disk reclamation.

### Claims to avoid

- “Docker/Patroni automatically scales PostgreSQL based on load” — our custom controller supplied that policy.
- “No orchestration needed” — no Kubernetes was needed, but orchestration still existed in the controller.
- “Use this script unchanged in production” — the runner is a bounded traffic-generating experiment.
- “Kubernetes/any managed database solves this automatically” — capabilities and supported integration vary.
- “Four new machines were provisioned” — four containers shared the existing Docker host.
- “Writes were load-balanced across replicas” — only read connections were distributed.
- “The original run proved all slot deletions” — it did not; only the separate new run has the required before/after rows.
- “Slot absence proves reclaimed disk space” or “about 30 seconds proves an exact timer” — neither conclusion was established.

For measured outcomes and evidence, see the [original results](RESULTS.md) and [new slot-verification results](SLOT_VERIFICATION_RESULTS.md). These production choices are design guidance, not additional environments tested by Phase 4.