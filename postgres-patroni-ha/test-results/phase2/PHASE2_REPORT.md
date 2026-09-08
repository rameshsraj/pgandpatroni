# Phase 2 — Cluster Resiliency & Automatic Rebalancing Validation

**Project:** postgres-patroni-ha (3→4 node PostgreSQL 16.4 + Patroni 3.3.2 + etcd 3.5.15 + HAProxy 2.9)
**Date:** 2026-09-08 (all timestamps UTC)
**Cluster ID:** `pg-ha-cluster` (system identifier `7683096657686442020`)
**Architecture note:** this project uses full streaming replication (every node holds a full
copy of the database), not Citus-style sharding. Replica initialization and WAL catch-up
are synchronization, NOT shard/partition rebalancing. No data redistribution was tested.

All raw evidence is under [test-results/phase2/](./). The partially reconstructed,
sometimes abbreviated [00-command-log.txt](./00-command-log.txt) is not a complete
timestamped command transcript. Phase 3 adds per-command logging and continuous traffic.

**Evidence audit correction (2026-09-08):** the original report overstated success and
misreported timing/rewind. Stored timestamps show ~36.7 seconds from kill request to
promotion log, and the returning primary DID execute pg_rewind automatically.
Row-count agreement is not byte equality or a guarantee of zero loss.

---

## Scenario Timeline

| # | Scenario | Result |
|---|----------|--------|
| 1 | Initial state captured | ✅ 3 nodes, pg-node-2 = Leader |
| 2 | Added pg-node-4 | ✅ Auto-joined, auto-synced, 0 lag |
| 3 | Killed primary (pg-node-2) | ✅ Promotion logged ~36.7s after kill request |
| 4 | Client routing after failover | ✅ HAProxy auto-routed writes to new leader |
| 5 | Restored old primary (pg-node-2) | ✅ Auto-rejoined as replica, 0 lag |
| 6 | Final stable state | ✅ Matching sampled counts and ha_test records on 4 nodes |

---

## 1. Initial State (Stage 1)

Evidence: [01-initial-state/](./01-initial-state)

```
+ Cluster: pg-ha-cluster --------------------------+-----------+
| Member    | Host      | Role    | State     | TL | Lag in MB |
+-----------+-----------+---------+-----------+----+-----------+
| pg-node-1 | pg-node-1 | Replica | streaming |  1 |         0 |
| pg-node-2 | pg-node-2 | Leader  | running   |  1 |           |
| pg-node-3 | pg-node-3 | Replica | streaming |  1 |         0 |
+-----------+-----------+---------+-----------+----+-----------+
```

The rebuilt environment lacked appdb, so baseline data was seeded: `customers=5`,
`orders=7`, `ha_test=3`, equal counts on all 3 nodes. The evidence does not independently
establish why prior data was absent. Replication was asynchronous; reported lag was 0 MB
at the sample, not a continuous zero-lag measurement.

---

## 2. Add Node (Stage 2)

Evidence: [02-node-added/](./02-node-added)

- Added `pg-node-4` service to [docker-compose.yml](../../docker-compose.yml) (same image/entrypoint/pattern as nodes 1–3) and added it as a backend to both `pg-primary`/`pg-replicas` listeners in [haproxy.cfg](../../haproxy/haproxy.cfg).
- Command: `docker-compose up -d --build pg-node-4 haproxy`
- Patroni auto-discovered `pg-node-4` via etcd, ran initial base-backup from the leader, and it appeared **already streaming with 0 lag** in the very first post-start check:

```
| pg-node-4 | pg-node-4 | Replica | streaming |  2 |         0 |
```

- Row counts on `pg-node-4` matched all other nodes (5/7/3) when sampled; exact clone duration was not measured.
- **Deviation noted:** HAProxy does not reload a bind-mounted `haproxy.cfg` on its own —
  `docker-compose up` only recreates a container if the compose *service definition* changed,
  not a mounted file's contents. A manual `docker-compose restart haproxy` was required for
  HAProxy to pick up the new backend configuration and refreshed addresses. **This is
  a failure/deviation of the strict end-to-end zero-touch criterion.** Repeated writes
  through HAProxy failed before the restart. The broad build/up also recreated the
  existing PostgreSQL containers, so this was not a clean isolated node-add experiment.
- After the HAProxy restart, a live write via HAProxy (`port 5000`) replicated to all 4 nodes
  by the subsequent checks (`ha_test` id=34, matching records on nodes 1–4).

---

## 3. Kill Primary → Automatic Failover (Stage 3)

Evidence: [03-kill-primary/](./03-kill-primary)

- Command: `docker kill pg-node-2` (hard kill, no grace period, no manual Patroni/etcd command issued).
- Timeline (from [pg-node-3 logs](./03-kill-primary/logs-pg-node-3-promotion.txt)):

| Time (UTC) | Event |
|---|---|
| 10:26:27.992 | Kill request recorded in timeline.txt |
| 10:27:04.552 | `pg-node-3` fails to reach `pg-node-2`, DNS/connection error |
| 10:27:04.690 | `pg-node-3` **promoted self to leader by acquiring session lock** |
| 10:27:04.786 | Leader lock updated in etcd |

**Kill request to promotion log: 36.698 seconds**, using
[timeline.txt](03-kill-primary/timeline.txt) and the promotion log. This is not the
client outage duration: continuous connection probes were not collected. Patroni
TTL/loop intervals are configuration inputs, not a strict 30-second recovery bound.

- New cluster state (automatic, no manual patronictl commands):
```
| pg-node-1 | pg-node-1 | Replica | running |  2 |         0 |
| pg-node-3 | pg-node-3 | Leader  | running |  2 |           |
| pg-node-4 | pg-node-4 | Replica | running |  2 |         0 |
```
- **Connection routing:** HAProxy's health checks (`GET /primary` / `GET /replica` against
  Patroni REST API on port 8008) automatically detected the new leader — write traffic on
  port 5000 confirmed routed to `pg-node-3` (`inet_server_addr=172.19.0.4`, `pg_is_in_recovery=false`).
- **Data availability:** sampled post-failover counts were 5/7/4. A later write through
  HAProxy at 10:27:47 succeeded (`phase2-record-AFTER-failover-writes-work`); final
  post-rejoin counts were 5/7/5. No continuous workload or acknowledged-write ledger
  was collected, so this does not prove uninterrupted service or zero RPO.
- **No shard/partition rebalancing occurred** after primary failure — not applicable to this
  streaming-replication architecture; all replicas already held full copies.
- **Zero manual intervention was required** for the failover or the routing.

---

## 4. Restore Old Primary → Automatic Rejoin (Stage 4)

Evidence: [04-rejoin-old-primary/](./04-rejoin-old-primary)

- Command: `docker start pg-node-2` (no `patronictl reinit`, no manual pg_basebackup, no
  config edits).
- Patroni recognized the new leader, performed crash recovery and rewind, then followed it:
  `"no action. I am (pg-node-2), a secondary, and following a leader (pg-node-3)"`.
- Cluster view during rejoin:
```
| pg-node-2 | pg-node-2 | Replica | stopped   |    |   unknown |   <- t+seconds
| pg-node-2 | pg-node-2 | Replica | streaming |  3 |         0 |   <- fully synced
```
- The [full recovery log](04-rejoin-old-primary/logs-pg-node-2-full.txt) explicitly shows
  crash recovery at **10:28:06.630** and **running pg_rewind from pg-node-3 at
  10:28:07.175**. This was a hard-killed primary, not a cleanly demoted node. Rewind
  was automatic; the earlier claim that it was not used was incorrect.
- **Fully automatic rejoin and resync — no manual repair or reconfiguration.**

---

## 5. Final Stable State (Stage 5)

Evidence: [05-final-state/](./05-final-state)

```
+ Cluster: pg-ha-cluster ----------------------------+-----------+
| Member    | Host      | Role    | State     | TL | Lag in MB |
+-----------+-----------+---------+-----------+----+-----------+
| pg-node-1 | pg-node-1 | Replica | streaming |  3 |         0 |
| pg-node-2 | pg-node-2 | Replica | streaming |  3 |         0 |
| pg-node-3 | pg-node-3 | Leader  | running   |  3 |           |
| pg-node-4 | pg-node-4 | Replica | streaming |  3 |         0 |
+-----------+-----------+---------+-----------+----+-----------+
```

### Row-count comparison across all stages (per node)

| Stage | pg-node-1 | pg-node-2 | pg-node-3 | pg-node-4 | Notes |
|---|---|---|---|---|---|
| 1. Initial (3 nodes) | 5 / 7 / 3 | 5 / 7 / 3 (Leader) | 5 / 7 / 3 | n/a | baseline seeded |
| 2. After node add | 5 / 7 / 3 | 5 / 7 / 3 (Leader) | 5 / 7 / 3 | 5 / 7 / 3 | matched at observation |
| 2b. After live write | 5/7/**4** | 5/7/**4** (Leader) | 5/7/**4** | 5/7/**4** | proves 4-node replication |
| 3. After failover | 5 / 7 / 4 | **killed** | 5/7/4 (new **Leader**) | 5 / 7 / 4 | consistent across survivors |
| 3b. After post-failover write | not separately sampled | killed | INSERT succeeded | not separately sampled | counts verified at final snapshot |
| 5. Final (after rejoin) | 5 / 7 / 5 | 5 / 7 / 5 (rejoined) | 5 / 7 / 5 (Leader) | 5 / 7 / 5 | 4/4 identical |

(`customers / orders / ha_test` counts shown; `customers` and `orders` were static reference
data throughout, `ha_test` accumulated markers at each write-test.)

### `ha_test` record trail (identical on all 4 nodes at final state)

| id | message | created_at (UTC) |
|---|---|---|
| 1–3 | `phase2-record-before-node4-added-*` | 10:19:31 |
| 34 | `phase2-record-after-node4-added` | 10:25:54 |
| 67 | `phase2-record-AFTER-failover-writes-work` | 10:27:47 |

---

## Conclusion

**Strict end-to-end zero-touch criterion: NOT MET.** Automatic failover/rejoin were
demonstrated, but node-add routing required manual repair and no shard rebalancing
exists in this architecture. Phase 2 was not a traffic-driven scaling benchmark.

- ✅ Automatic primary election/promotion on failure (promotion log ~36.7s after kill request).
- ✅ Automatic client/application connection routing to the new primary (HAProxy health-checks
  against Patroni REST API, no config change needed).
- ✅ Sampled counts and test markers matched after recovery; no loss of these markers observed.
- ⚠️ No byte-level comparison, continuous availability trace, or general zero-loss guarantee.
- ✅ Automatic node addition: `pg-node-4` self-joined and self-synced via Patroni/etcd with no
  manual `pg_basebackup` or `patronictl` commands.
- ✅ Automatic rejoin/resync of the failed former primary with no manual repair.
- ⚠️ **One manual step required, and it is called out as a Phase 2 deviation per the
  acceptance criterion:** HAProxy required a manual `docker-compose restart haproxy` to load
  the updated backend list after `pg-node-4` was added to `haproxy.cfg`. This is a static
  config-reload limitation of HAProxy/Docker Compose bind-mounts, unrelated to Patroni's
  failover/rejoin automation, and did not affect data integrity, primary failover, or old-node
  rejoin — all of which completed with zero manual intervention.
