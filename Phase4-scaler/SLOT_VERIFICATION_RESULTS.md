# Phase 4 — returned-row replication-slot verification

## Checklist

- [x] Read the historical evidence gap, implementation and repository notes.
- [x] Check Docker/host headroom without stopping or pruning unrelated resources.
- [x] Implement read-only slot/sender/receiver observations and fail-closed removal outcomes.
- [x] Run offline policy/process and slot/unknown/error/timeout/hash-tamper tests.
- [x] Preserve and explain the first failed new attempt.
- [x] Complete a fresh isolated four-admission/four-removal experiment.
- [x] Independently verify actual rows, data tokens, archives, artifact hashes and live resources.
- [x] Publish measured timings, source ownership and remaining limitations.

## Verified result — new run only

Fresh run: `phase4-20260908T231619712-a9cb57ed`. Executed through the existing Phase 4 VS Code task with `TrafficDurationSeconds=900`; slot-absence deadline 120 seconds per removal; overall lab deadline 1,800 seconds plus bounded final archives. Dates in run IDs are **UTC**: 8 September late evening UTC is 9 September in the Windows host's IST timezone. No timestamps are relabeled to match a calendar date.

**Passed: four admissions, four graceful container removals and four verified physical-slot absences.** Each outcome separately has `containerRemoved=true`, `dataAgreementVerified=true`, `slotAbsentVerified=true` and captured preconditions. PostgreSQL topology went from 2 to 6 to 2 nodes. The permanent replica stayed healthy with its original slot active in every captured replication sample and in final live verification.

Experiment events span **2026-09-08 23:16:20.292–23:35:01.729 UTC**, **1,121.437 seconds** (18m 41.437s); equivalent to **2026-09-09 04:46:20.292–05:05:01.729 IST**. Independent live verification began at **23:36:05.602 UTC**. See the [machine-readable verification report](reports/phase4-20260908T231619712-a9cb57ed.json) and [runner result](evidence/phase4-20260908T231619712-a9cb57ed/result.json).

The [runner](run-lab.ps1), [read-only observer](slot-observation.ps1), [independent verifier](verify-slot-evidence.ps1) and [offline tests](test-slot-observation.ps1) implement the new evidence contract. The actual run's source copies remain immutable even though the independent verifier received later UTC-normalization and validation improvements; the report records the exact final verifier source hashes used.

## Actual returned rows and observation times

**41 samples:** baseline 1, admission readiness 4, pre-drain 4, pre-stop 4, post-stop 4, post-remove 4, additional reconciliation observations 19, final 1. Every sample contains actual SQL results and raw-command references, not merely logged SELECT text.

Primary identity stayed `phase4-20260908T231619712-a9cb57ed-primary`, address `172.25.0.3`, system identifier `7683307404063899704`, timeline **1**. The final sole physical slot was **`phase4_20260908t231619712_a9cb57ed_base`**, active with its matching streaming sender and receiver. The four learned target names were `phase4_20260908t231619712_a9cb57ed_elastic1` through `phase4_20260908t231619712_a9cb57ed_elastic4`, each corroborated by its exact member application name, sender PID and receiver slot name. No normalization assumption supplies the outcome.

All table times are UTC on 8 September. “First absent SQL” is the returned inventory timestamp. The last-presence / first-absence pair brackets an **observed state transition**, not an exact deletion event.

| Target | Stop completed | Container removal completed | Last present SQL | First absent SQL | Returned-row evidence |
|---|---|---|---|---|---|
| elastic4 | 23:29:28.345 | 23:29:36.562 | 23:29:52.622 | 23:30:00.233 | [Active → inactive → absent](evidence/phase4-20260908T231619712-a9cb57ed/slot-samples.jsonl#L7-L12) |
| elastic3 | 23:31:02.306 | 23:31:09.577 | 23:31:30.184 | 23:31:33.870 | [Active → inactive → absent](evidence/phase4-20260908T231619712-a9cb57ed/slot-samples.jsonl#L14-L20) |
| elastic2 | 23:32:46.255 | 23:32:54.734 | 23:33:15.919 | 23:33:19.643 | [Active → inactive → absent](evidence/phase4-20260908T231619712-a9cb57ed/slot-samples.jsonl#L22-L30) |
| elastic1 | 23:34:03.087 | 23:34:07.537 | 23:34:30.739 | 23:34:34.902 | [Active → inactive → absent](evidence/phase4-20260908T231619712-a9cb57ed/slot-samples.jsonl#L32-L40) |

The full observation also collects permanent-replica health and ending primary REST identity, so its completion is slightly later than the inventory query. The runner's elapsed metrics conservatively use **completed observations**:

| Target | First absence sample completed UTC | From stop completion (s) | From removal completion (s) | Presence/absence SQL sampling interval (s) |
|---|---|---:|---:|---:|
| elastic4 | 23:30:02.297 | 33.953 | 25.735 | 7.611 |
| elastic3 | 23:31:35.181 | 32.874 | 25.604 | 3.686 |
| elastic2 | 23:33:21.290 | 35.035 | 26.556 | 3.725 |
| elastic1 | 23:34:36.198 | 33.112 | 28.661 | 4.163 |

Every target was active with a matching streaming sender before stop, remained present but inactive in post-stop/post-remove SQL, then was observed absent within 120 seconds. Later inventories did not show a removed target reappearing. [Final sample 41](evidence/phase4-20260908T231619712-a9cb57ed/slot-samples.jsonl#L41) completed at **23:35:01.642 UTC**, with only the active baseline slot.

## Primary archive includes elastic1 cleanup

Primary archive collection started at **23:35:02.061 UTC** and completed at **23:35:03.803 UTC**, after final sample 41 and all four cleanup observations. It contains Patroni's explicit successful cleanup messages for [elastic4 at 23:29:57.104](evidence/phase4-20260908T231619712-a9cb57ed/serverlogs/phase4-20260908T231619712-a9cb57ed-primary-20260908T233502061-b9fdb4/docker.stderr.log#L2555), [elastic3 at 23:31:31.851](evidence/phase4-20260908T231619712-a9cb57ed/serverlogs/phase4-20260908T231619712-a9cb57ed-primary-20260908T233502061-b9fdb4/docker.stderr.log#L2632), [elastic2 at 23:33:16.850](evidence/phase4-20260908T231619712-a9cb57ed/serverlogs/phase4-20260908T231619712-a9cb57ed-primary-20260908T233502061-b9fdb4/docker.stderr.log#L2655) and **[elastic1 at 23:34:31.865](evidence/phase4-20260908T231619712-a9cb57ed/serverlogs/phase4-20260908T231619712-a9cb57ed-primary-20260908T233502061-b9fdb4/docker.stderr.log#L2700)**. These corroborate the returned rows; conditional SQL statement logs alone are not the verification basis. Baseline log copying remains live/non-atomic, but the missing elastic1 outcome window is closed for this new run.

## Demand, data, WAL and integrity

| Action | Target | Decision UTC | Measured completed TPS | Admission / fully verified removal UTC |
|---|---|---|---:|---|
| Out | elastic1 | 23:18:59.803 | 23.7 | 23:20:05.895 |
| Out | elastic2 | 23:21:17.292 | 27.0 | 23:21:55.300 |
| Out | elastic3 | 23:22:24.726 | 33.4 | 23:23:00.098 |
| Out | elastic4 | 23:25:49.115 | 28.8 | 23:26:42.784 |
| In | elastic4 | 23:28:47.478 | 2.6 | 23:30:18.918 |
| In | elastic3 | 23:30:34.153 | 1.5 | 23:31:43.727 |
| In | elastic2 | 23:32:04.164 | 1.9 | 23:33:28.699 |
| In | elastic1 | 23:33:47.533 | 1.5 | 23:34:39.029 |

Each action had the required consecutive measured thresholds and cooldown evidence; no offered-rate or stage value was substituted. Fully verified removal includes absence observation and remaining-node data agreement, not just Docker removal. All five replicas served traffic at peak.

- **59 acknowledged tokens** and **100,000 fixture rows** agreed on final primary/base; all active replicas agreed before their removals. Fixture MD5: `0f42f18a2baad7f892d29c774a09d284` (data equality, not cryptographic artifact integrity).
- **14,828 complete pgbench records**: baseline 52, high 13,762, low-final 1,014. Zero invalid final transaction records and zero detected client error signatures; all three traffic containers exited 0.
- WAL-distance observations: pre-stop retained bytes were **0 for all four**; post-stop values were elastic4 **0**, elastic3 **56**, elastic2 **0**, elastic1 **0**. Across all captured appearances, their maxima were respectively **0 / 56 / 0 / 0 bytes**. `safe_wal_size` remained explicitly null, not zero. This low-write/read-heavy workload did not demonstrate significant abandoned-slot disk pressure or disk reclamation.
- **1,197 recorded commands**, **zero command timeouts**, **zero controller SQL errors during the measured experiment**. All 20 nonzero commands remain visible: eight REST readiness failures and twelve expected absent-container inspections. Errors are not recast as successful empty slot inventories.
- [Manifest](evidence/phase4-20260908T231619712-a9cb57ed/manifest.json): **291 files, 86,851,253 bytes**, all hashes, lengths and coverage passed. Manifest SHA-256: **`DC88842813AB27996A0DDE7BC90472C7CE5D73759BDDF4FF6718F2DA896DDEB0`**.
- [Raw SQL returns](evidence/phase4-20260908T231619712-a9cb57ed/sql.jsonl), [command results](evidence/phase4-20260908T231619712-a9cb57ed/commands.jsonl), [slot samples](evidence/phase4-20260908T231619712-a9cb57ed/slot-samples.jsonl), [data snapshots](evidence/phase4-20260908T231619712-a9cb57ed/snapshots.jsonl), [events](evidence/phase4-20260908T231619712-a9cb57ed/events.jsonl), [metrics](evidence/phase4-20260908T231619712-a9cb57ed/metrics.jsonl), [policy decisions](evidence/phase4-20260908T231619712-a9cb57ed/decisions.jsonl), [retained resources](evidence/phase4-20260908T231619712-a9cb57ed/resources.json).

## Tests and retention

- [Static suite](validate-static.ps1): passed parser/config, threshold/hysteresis/cooldown/bounds, live-file sharing, TPS parsing, process pipes, redaction, partial timeout output and HAProxy acknowledgement tests.
- [Slot/mutation suite](test-slot-observation.ps1): **23 tests passed** with the completed evidence. Coverage includes exact observed mapping, case-insensitive DNS, unknown active/lag, wrong sender/receiver, primary changes, SQL errors/timeouts, bounded absence, missing lifecycle captures, forged returned rows, missing SQL, overdue absence, token disagreement and truncated primary archive. Synthetic same-length hash corruption and extra unmanifested files were rejected. Mutations were in memory or a test-only temporary directory, never the retained evidence.
- Full [independent verifier](verify-evidence.ps1) with `-Live` passed. It reconstructed the slot transitions from raw returns; checked pre/post data tokens and intervals; verified all artifact hashes; confirmed final baseline-only active slots, clean client exits and retained elastic volumes. **26 pre-existing running containers** still had the same IDs and remained running. This is a point-in-time identity/state check, not a continuous uptime proof.
- Final recheck passed: all 291 artifact hashes still matched after mutation tests/documentation; current runner and observer matched their executed source snapshots after LF normalization; all **84 local documentation links** resolved; `git diff --check` passed. The independent-verifier report remains separate from immutable evidence.
- Success retains the new primary/base/etcd/proxy running, three stopped traffic containers, all named volumes and the network. Only the new run's four elastic containers were removed, without volume deletion. The failed attempt and all earlier stacks remain retained. No commit or push was performed by the assistant.

## Headroom and isolation

Initial Docker VM: 8 CPUs, 8,210,579,456 bytes RAM; `/proc/meminfo` reported 5,637,004 KiB available (about 5.38 GiB). Host C: had 68.37 GiB free. Before the second attempt: 5,449,696 KiB available (about 5.20 GiB) and host 67.40 GiB free. Docker's data filesystem reported over 967 million KiB available, but its thin virtual disk is also constrained by host free space.

Existing stacks were retained. No broad cleanup, image build/pull, host Python, WSL, manual replication-slot deletion or manual DCS-member deletion was used. Each attempt creates only uniquely named resources on its own network/Patroni scope, without published ports. Named data volumes survive removal.

## Preserved failed attempt

`phase4-20260908T231405769-1a1f40a4` stopped at baseline, before traffic/admissions. The receiver's `sender_host` was the lowercase DNS form of the primary name; an overly strict case-sensitive hostname comparison rejected it even though the actual slot/sender/receiver rows matched. DNS comparison is now case-insensitive, while slot/member correlation remains exact. A regression test covers that distinction.

- [Failure result](evidence/phase4-20260908T231405769-1a1f40a4/result.json), [returned baseline rows including the failed validation](evidence/phase4-20260908T231405769-1a1f40a4/slot-samples.jsonl), [raw SQL](evidence/phase4-20260908T231405769-1a1f40a4/sql.jsonl).
- Integrity-only verification passed: **35 files, 846,831 bytes**, manifest SHA-256 `2467DC09F2BA3AC67F28EB0021B96DB73EEE3C0270D567B5CAD67D12ACBCAFD4`. This is **not** a successful lifecycle/slot experiment.
- Its primary, base, etcd, network, volumes and immutable evidence were retained; no historical resources were changed.

An offline process-timeout test also initially failed when cold PowerShell startup consumed its two-second allowance before producing stdout. Its child-process allowance was increased to five seconds; the test still requires timeout and retained partial output. This was a test harness failure, not a manufactured slot outcome.

## Historical compatibility

The original successful container-lifecycle run `phase4-20260908T173358240-1efd4a87` remains **slot unavailable/not verified**. Its 144 files / 53,572,758 bytes passed the extended manifest verifier. Original manifest SHA-256 remains `B875BCEBCA5546E137B9E190D8917DCA3EF055DE771C467B09925CA99F35B38A`. The [separate compatibility audit](reports/phase4-20260908T173358240-1efd4a87-slot-audit.json) does not overwrite the original report or raw evidence.

The original report also retained SHA-256 `E469E534C0FF8770F24DB5878BF4C5C2E6627568BBF3B5CF3BC44D8ADAC85AB9`. The historical results document was left unchanged.

The historical three conditional Patroni cleanup statements and missing elastic1 outcome are not retroactively upgraded. See the [historical investigation](SCALING_REPLICATION_INVESTIGATION.md) and [original results](RESULTS.md).

## What is measured, and who owns cleanup?

The runner samples the **current Patroni leader** and requires it to remain the original isolated primary. Primary SQL records system identifier, server address, postmaster start, timeline and recovery role; REST roles bracket each capture. A role/identity change, missing row set or SQL error fails the experiment rather than becoming evidence of absence.

Actual slot names are learned by joining `pg_replication_slots.active_pid` to the streaming sender PID and exact Patroni `application_name`, then checking the replica's returned receiver `slot_name`, sender hostname, received timeline and address. Every observation also requires the permanent replica's original physical slot to remain active with a matching streaming sender/receiver, healthy role and known zero reported lag. Captures preserve nulls, including `safe_wal_size`; null is not zero.

For each removal, fixture hash, 100,000-row count and the then-current token set must agree before drain. After graceful stop and log archive, only the container is removed. The observer waits for the **exact learned slot name** to be absent in a successful returned inventory and then verifies remaining-node data agreement. Removed volumes are not claimed to contain tokens written later in the experiment.

Installed **Patroni 3.3.2** source, captured from the run's actual node image, explains separate reconciliation ownership:

- The [HA loop invokes slot synchronization](evidence/phase4-20260908T231619712-a9cb57ed/source/patroni-ha.py#L1909-L1916); [the wrapper passes cluster state to the slot handler](evidence/phase4-20260908T231619712-a9cb57ed/source/patroni-ha.py#L1961-L1984).
- [Slot synchronization](evidence/phase4-20260908T231619712-a9cb57ed/source/patroni-postgresql-slots.py#L500-L535) loads actual slots, computes desired slots from cluster state and reconciles differences.
- [Conditional cleanup and its result handling](evidence/phase4-20260908T231619712-a9cb57ed/source/patroni-postgresql-slots.py#L311-L352) drops only inactive extraneous slots and logs confirmed success separately from failures/active slots.
- [Name conversion](evidence/phase4-20260908T231619712-a9cb57ed/source/patroni-dcs-__init__.py#L35-L54) lowercases names, maps punctuation/other characters and truncates to 63 characters. The observer does **not** blindly implement hyphen replacement: it verifies the actual runtime mapping through sender and receiver rows.

The [captured configuration](evidence/phase4-20260908T231619712-a9cb57ed/source/patroni-template.yml) uses a 30-second TTL and 5-second HA loop. An observed delay supports asynchronous reconciliation, but does not isolate a single timer's contribution, establish an exact deletion timestamp or prove a fixed 30-second SLA.

Elapsed times are measured from completed stop/removal operations to **first absence observation**, with the previous presence and first absence observations retained. The inventory query and completion of the full health sample are separate timestamps. Sampling is discrete/non-atomic across hosts; small clock differences are allowed only for host/server timestamp bounds. PowerShell can deserialize offset timestamps as local times, so the independent verifier normalizes them to UTC; original SQL stdout remains unchanged.

`retained_wal_bytes` measures an LSN distance associated with a slot, not filesystem usage. Slot disappearance and an active baseline slot do **not** prove immediate physical WAL-file/disk reclamation. No checkpoint, manual drop or filesystem reclamation experiment is used to manufacture that claim.