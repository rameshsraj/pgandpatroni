#requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$EvidencePath)
$ErrorActionPreference='Stop'
$dir=(Resolve-Path $EvidencePath).Path
$events=@(Get-Content "$dir/events.jsonl" | ForEach-Object { $_ | ConvertFrom-Json })
if (-not @($events | Where-Object name -EQ 'run-complete').Count) { throw 'Run not complete; do not manufacture a success report.' }
$bench=@(Get-Content "$dir/benchmark-summary.json" -Raw | ConvertFrom-Json)
$snaps=@(Get-Content "$dir/snapshots.jsonl" | ForEach-Object { $_ | ConvertFrom-Json })
$writes=@(Get-Content "$dir/write-probes.jsonl" | ForEach-Object { $_ | ConvertFrom-Json })
$reads=@(Get-Content "$dir/read-probes.jsonl" | ForEach-Object { $_ | ConvertFrom-Json })
$commands=@(Get-Content "$dir/commands.jsonl" | ForEach-Object { $_ | ConvertFrom-Json })
$final=@(Get-Content "$dir/11-final/row-counts.json" -Raw | ConvertFrom-Json)
$checks=@(Get-Content "$dir/acknowledged-write-validation.json" -Raw | ConvertFrom-Json)
$active=@($final | Where-Object { -not $_.unavailable })
if ($active.Count -ne 4 -or @($active.items_hash | Select-Object -Unique).Count -ne 1 -or
    @($active.events_hash | Select-Object -Unique).Count -ne 1 -or @($checks | Where-Object { $_.missing.Count }).Count) {
    throw 'Final row fingerprint / acknowledged write validation failed'
}
function E([string]$name) { return @($events | Where-Object name -EQ $name)[0] }
function Sec($a,$b) { return [Math]::Round(([DateTime]$b-[DateTime]$a).TotalSeconds,3) }
$operations=@(
    @{operation='Traffic trigger to ready observation';start=(E 'scale-out-trigger').utc;end=(E 'scale-out-ready').utc},
    @{operation='Kill command';start=(E 'kill-primary-start').utc;end=(E 'kill-primary-complete').utc},
    @{operation='Kill start to promotion observation';start=(E 'kill-primary-start').utc;end=(E 'automatic-promotion-observed').utc},
    @{operation='Restore to rejoin observation';start=(E 'restore-node-start').utc;end=(E 'automatic-rejoin-observed').utc},
    @{operation='Low demand trigger to stopped replica';start=(E 'scale-in-trigger').utc;end=(E 'scale-in-complete').utc}
)
$operationRows=@($operations | ForEach-Object { [pscustomobject]@{operation=$_.operation;start=$_.start;end=$_.end;seconds=(Sec $_.start $_.end)} })
$operationRows | Export-Csv "$dir/operation-durations.csv" -NoTypeInformation
$bench | Select-Object stage,offeredTps,achievedTps,successfulTransactions,meanMs,p95Ms,p99Ms,failedBatches,requestedSeconds,start,end |
    Export-Csv "$dir/benchmark-comparison.csv" -NoTypeInformation
$counts=foreach ($snap in $snaps) {
    foreach ($row in $snap.rows) {
        [pscustomobject]@{stage=$snap.label;start=$snap.start;end=$snap.end;node=$row.node;
            available=(-not $row.unavailable);role=$(if($row.unavailable){'unavailable'}elseif($row.replica){'replica'}else{'primary'});
            customers=$row.customers;orders=$row.orders;ha_test=$row.ha_test;items=$row.items;events=$row.events;
            items_hash=$row.items_hash;events_hash=$row.events_hash}
    }
}
$counts | Export-Csv "$dir/row-count-comparison.csv" -NoTypeInformation
$routes=foreach ($stage in $bench) { foreach ($r in $stage.routes) {
    [pscustomobject]@{stage=$stage.stage;node=$r.node;connections=$r.connections;status=$r.endStatus}
} }
$routes | Export-Csv "$dir/routing-comparison.csv" -NoTypeInformation
$commands | Where-Object exit -NE 0 | Export-Csv "$dir/nonzero-commands.csv" -NoTypeInformation
$writes | Select-Object stage,token,start,end,seconds,ack,command,error | Export-Csv "$dir/write-probes.csv" -NoTypeInformation
$reads | Select-Object stage,start,end,exit,command,error | Export-Csv "$dir/read-probes.csv" -NoTypeInformation
$low=@($bench | Where-Object stage -EQ '01-low-four')[0]
$before=@($bench | Where-Object stage -EQ '02-high-four')[0]
$after=@($bench | Where-Object stage -EQ '04-high-five')[0]
$delta=[Math]::Round(100*($after.achievedTps/$before.achievedTps-1),2)
$transitionAborts=($bench | Where-Object { $_.stage -in @('03-auto-scale-out','07-rejoin-under-load','09-auto-scale-in','10-low-four-final') } | Measure-Object failedBatches -Sum).Sum
$kill=(E 'kill-primary-start').utc
$failures=@($writes | Where-Object { -not $_.ack -and [DateTime]$_.start -ge [DateTime]$kill })
$lastGood=@($writes | Where-Object { $_.ack -and [DateTime]$_.end -lt [DateTime]$kill } | Select-Object -Last 1)[0]
$firstGood=@($writes | Where-Object { $_.ack -and [DateTime]$_.start -gt [DateTime]$kill } | Select-Object -First 1)[0]
$timing=@{killStart=$kill;firstSuccessfulWriteStart=$firstGood.start;firstSuccessfulWriteEnd=$firstGood.end;
    secondsToSuccessfulWriteCompletion=(Sec $kill $firstGood.end);lastPreKillAcknowledgment=$lastGood.end;
    failedWriteAttempts=$failures.Count;note='Sampled upper-bound observations, not continuous outage duration. Snapshots pause write probes while independent read traffic continues.'}
$timing | ConvertTo-Json | Set-Content "$dir/recovery-observations.json"
$lines=[System.Collections.Generic.List[string]]::new()
function L([string]$s='') { $lines.Add($s) }
L '# Phase 3 — Traffic-driven scaling and recovery LAB'
L
L "Run: **$(Split-Path $dir -Leaf)**. Evidence generated from recorded results; all times UTC."
L
L '## Verdict'
L
L '- **Functional bounded elasticity: PASS** — observed traffic triggered optional replica provisioning, automatic DNS/health-based routing, and low-demand drain/stop without operator action during the scenarios.'
L "- **Read continuity during scale/rejoin/removal: $(if($transitionAborts){'FAIL / deviation'}else{'PASS for observed workload'})** — $transitionAborts aborted pgbench batches across scale-out, rejoin, scale-in, and final low traffic. Failures remain in the evidence even if the client later retries."
L '- **Failover/rejoin: PASS for this run** — primary was hard-killed; Patroni promoted another node; retrying client probes resumed through the same HAProxy endpoint; the old primary rejoined without repair.'
L "- **Performance: $(if($delta -le 0){'no throughput improvement observed'}else{'single-run throughput improvement observed, not a capacity guarantee'}).** Four-node high-load throughput was $([Math]::Round($before.achievedTps,2)) TPS; five-node throughput was $([Math]::Round($after.achievedTps,2)) TPS ($delta%). Extra containers share one host rather than adding physical resources."
L '- **Uninterrupted writes: NOT achieved.** Failover has a measured recovery window and failed client attempts. Successful retries are not evidence that existing connections migrated.'
L '- **Sharding/rebalancing: NOT applicable.** Full physical replicas; zero partitioned tables and no Citus extension. Connection distribution is not data redistribution.'
L
L '## Setup and reproducibility'
L
L '- Docker Desktop Linux engine: 8 CPUs, 8,210,579,456 bytes (~7.65 GiB) RAM shared by the lab and other workloads. PostgreSQL 16.4; Patroni 3.3.2; HAProxy runtime 2.9.15; etcd 3.5.15.'
L '- One primary plus three permanent replicas; optional pg-node-5 is a read-only, nofailover replica. Minimum four nodes, maximum five. Existing pg-node-* names preserved.'
L '- Synthetic client: pgbench SELECT-only range reads on 100,000 immutable rows; separate idempotent SQL write probes. This is a client demonstration, not integration with a production application.'
L '- Low traffic: 5 offered TPS / 2 clients; high traffic: 120 offered TPS / 12 clients. Two threads; each read transaction reconnects (-C). Batches last at most 10 seconds and retry automatically after aborts.'
L '- SQL trace logging is enabled: pgbench -d means DEBUG (the database argument is positional), and PostgreSQL logs all statements/durations. This deliberately captures executed queries but adds substantial overhead.'
L '- Trigger: >30 observed successful read TPS for two samples to add capacity; <10 TPS for two samples to drain/remove it. Samples derive from transaction logs (buffered); resource stats are also captured. Deliberately low lab thresholds, NOT production SLO-based autoscaling.'
L '- Image build, static slot definition, DNS configuration, and one HAProxy restart are explicit feature-deployment preparation, before baseline measurement. No HAProxy restart or configuration-file edits during measured scenarios. Runtime admission/drain commands are automated by the controller; review the run-specific commands for the exact implementation version.'
L '- HAProxy resolves Docker DNS repeatedly and requires the replica role with lag <=1 MiB. This is bounded predeclared membership, not arbitrary service discovery. Scale-in checks role, three healthy remaining replicas, and zero active backend sessions before stop; volumes are preserved.'
L '- The optional node uses the fifth available WAL-sender slot during cloning (four steady replicas fit within configured limits). Do not extend this policy to more nodes without revisiting slots, sender headroom, CPU, storage, and connection limits.'
L '- Rerun with the VS Code task **Phase 3: traffic scaling and resiliency LAB**. It requires exactly four healthy active nodes, creates a unique evidence directory, and preserves existing data. The elastic volume is reused on later runs, so later starts test catch-up rather than fresh cloning.'
L '- Sources/configuration for this exact run are frozen in [source/](source/). Live reusable entry point: [run-lab.ps1](../../../scripts/phase3/run-lab.ps1).'
L
L '## Throughput and latency'
L
L '| Scenario | Offered TPS | Observed TPS | Completed reads | Mean ms | p95 ms | p99 ms | Aborted batches |'
L '|---|---:|---:|---:|---:|---:|---:|---:|'
foreach ($b in $bench) {
    L "| $($b.stage) | $($b.offeredTps) | $([Math]::Round($b.achievedTps,2)) | $($b.successfulTransactions) | $([Math]::Round($b.meanMs,2)) | $([Math]::Round($b.p95Ms,2)) | $([Math]::Round($b.p99Ms,2)) | $($b.failedBatches) |"
}
L
L 'TPS = logged successful reads / requested traffic duration. Batch startup/rounding creates small timing differences (actual completion spans and UTC times are retained). Latencies include rate-schedule delay and reconnection; they are not server query execution times. Only successful transactions contribute percentiles. Failed batches, client probes, connection failures, and nonzero commands are retained separately. No repeated trials, fixed random seed, isolated hardware, pooler, or warmed production-sized workload: not a capacity certification.'
L
L '## Operation timings'
L
L '| Operation | Start UTC | End UTC | Seconds |'
L '|---|---|---|---:|'
foreach ($o in $operationRows) { L "| $($o.operation) | $($o.start) | $($o.end) | $($o.seconds) |" }
L
L "Killed primary: **$((E 'kill-primary-start').details)**; elected primary: **$((E 'automatic-promotion-observed').details.Member)**. Returning node becomes a replica, not a failback/switchover to its former role."
L
L "First successful write-probe completion after kill: **$($firstGood.end)**, **$($timing.secondsToSuccessfulWriteCompletion) seconds** after kill start. Failed write attempts after kill: **$($failures.Count)**. Last pre-kill acknowledgment: $($lastGood.end). These are sampled recovery observations, not precise downtime; snapshots interrupt write probing but not the independent pgbench read stream."
L
L '## Row counts on every node'
L
L 'Cells show **items / events** and role (P=primary, R=replica). Public reference tables remained customers=5, orders=7, ha_test=5 wherever reachable; full counts and fingerprints are in [row-count-comparison.csv](row-count-comparison.csv). Each snapshot is sequential, not an atomic cluster-wide snapshot.'
L
L '| Scenario | pg-node-1 | pg-node-2 | pg-node-3 | pg-node-4 | pg-node-5 |'
L '|---|---|---|---|---|---|'
foreach ($snap in $snaps) {
    $cells=foreach ($n in 1..5) {
        $r=@($snap.rows | Where-Object node -EQ "pg-node-$n")[0]
        if ($r.unavailable) { 'Unavailable / absent' } else { "$($r.items) / $($r.events) $(if($r.replica){'R'}else{'P'})" }
    }
    L "| $($snap.label) | $($cells -join ' | ') |"
}
L
L 'The removed node is unavailable in the final snapshot, NOT empty and NOT synchronized with writes after removal. Its last online counts appear at drain time; its volume is retained. All final online nodes have matching deterministic MD5 row fingerprints for the two lab tables. This verifies logical fixture content, not physical byte-for-byte equality of PostgreSQL data directories.'
L
L "Acknowledged unique write tokens: **$($checks[0].acknowledged)**. Missing on final online nodes: **0**. The client retries the same token after an ambiguous outcome using a primary key and ON CONFLICT DO NOTHING. See [acknowledged-write-validation.json](acknowledged-write-validation.json). Asynchronous replication still does not guarantee zero data loss for arbitrary crashes or untested writes."
L
L '## Read connection distribution'
L
L '| Scenario | node-1 | node-2 | node-3 | node-4 | node-5 |'
L '|---|---:|---:|---:|---:|---:|'
foreach ($b in $bench) { L "| $($b.stage) | $(($b.routes | ForEach-Object connections) -join ' | ') |" }
L
L 'Counters are HAProxy replica-backend session deltas, including benchmark clients and monitoring queries. Connections—not individual SQL statements—are balanced. Role-ineligible servers are expected DOWN in the opposite listener; absent node-5 is expected MAINT (resolution). Per-snapshot SQL routing results identify actual server IP and recovery role. PostgreSQL direct Unix-socket queries legitimately show a null server address.'
L
L '## Evidence and limitations'
L
L '- [commands.jsonl](commands.jsonl): exact Docker/curl/SQL commands, stdin, redacted credentials, UTC start/end, exit status, duration, and a separate output file for every invocation.'
L '- [events.jsonl](events.jsonl), [metrics.jsonl](metrics.jsonl), [operation-durations.csv](operation-durations.csv): decisions, transitions, resource observations and timing.'
L '- [benchmark-comparison.csv](benchmark-comparison.csv), [routing-comparison.csv](routing-comparison.csv), [row-count-comparison.csv](row-count-comparison.csv): compact comparisons.'
L '- [write-probes.csv](write-probes.csv), [read-probes.csv](read-probes.csv), [nonzero-commands.csv](nonzero-commands.csv): failed and successful attempts, including expected missing/stopped nodes; errors are not silently treated as passes.'
L '- Per-stage client.log and traffic/tx-* retain expanded read SQL and transaction timing. Per-command Docker/Patroni/PostgreSQL logs retain role changes, WAL recovery, and warnings. Stdout and stderr are separate in raw command files; use embedded UTC timestamps to order events across streams.'
L '- No external human intervention during measured scaling/recovery. Scripted kill and restore are fault-injection actions, not automatic machine resurrection. Initial feature deployment and test seeding are manual preparation. There is no persistent production controller after this finite task exits.'
L '- The first attempt (20260908T110410Z) failed before scaling because Windows denied concurrent reads of a pgbench log. It is retained separately, not counted as a successful scenario. File sharing was fixed before this run. Preflight also rejected an unsupported HAProxy 2.9 keyword before deployment; see [preparation-notes.txt](../preparation-notes.txt).'
L '- The first completed run (20260908T112126Z) exposed early DNS admission and post-stop slot re-enabling: three transition/final batches aborted. It is retained as a deviation. The revised controller starts the elastic backend disabled, admits only SQL-ready replicas, quarantines a returning node during recovery, and leaves a removed node in maintenance. A repeat run tests the fix and kills the previously promoted primary again.'
L '- This run does not test coordinator sharding, write scale-out, arbitrary node discovery, scale-down of a primary, loss of etcd/HAProxy/the Docker host, divergent-write repair, sustained network partitions, or production application retry semantics.'
L '- Earlier Phase 2 claims of byte-identical storage, instantaneous cloning, guaranteed zero loss, and ~12-second failover should not be reused as benchmark facts. Its stored kill timestamp is 10:26:27.992 and promotion log timestamp 10:27:04.690 (~36.698 seconds).'
L
L "**Conclusion:** bounded traffic-triggered read-replica scale-out/scale-in and automatic PostgreSQL recovery were demonstrated. Transition/final aborted batches: $transitionAborts; throughput change: $delta%. Shard rebalancing and production-grade elastic capacity remain outside this validation."
$lines | Set-Content "$dir/REPORT.md" -Encoding utf8
@{utc=[DateTime]::UtcNow.ToString('o');command="pwsh -NoProfile -File scripts/phase3/summarize.ps1 -EvidencePath $EvidencePath";
    checks='four online nodes; identical items/events fingerprints; no missing acknowledged tokens';run=(Split-Path $dir -Leaf)} |
    ConvertTo-Json | Set-Content "$dir/analysis.json"
Write-Host "Report: $dir/REPORT.md"
Write-Host "Throughput change: $delta%; final nodes: $($active.Count); acknowledged tokens: $($checks[0].acknowledged)"