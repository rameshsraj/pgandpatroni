#requires -Version 7.2
<#!
Bounded, destructive-to-availability LAB demonstration (never a production autoscaler).
Uses existing Docker Desktop/PostgreSQL tools. No sleeps, host Python, or WSL.
Changes only the dedicated phase3_lab schema; never deletes database volumes.
Every external command, SQL input, output, exit code and duration is recorded.
#>
[CmdletBinding()]
param([string]$RunId = (Get-Date -AsUTC -Format 'yyyyMMddTHHmmssZ'))
$ErrorActionPreference = 'Stop'
if ($RunId -notmatch '^[A-Za-z0-9_-]+$') { throw 'Unsafe RunId' }
$Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Set-Location $Root
$Out = Join-Path $Root "test-results/phase3/$RunId"
if (Test-Path $Out) { throw "Evidence already exists: $Out (never overwrite a run)" }
New-Item -ItemType Directory -Path "$Out/commands", "$Out/source" -Force | Out-Null
$EnvValues = @{}
foreach ($line in Get-Content "$Root/.env") {
    if ($line -match '^([A-Z_]+)=(.*)$') { $EnvValues[$matches[1]] = $matches[2].Trim('"', "'") }
}
$Secrets = @($EnvValues.GetEnumerator() | Where-Object Key -Match 'PASSWORD' | ForEach-Object Value)
$AppUser = $EnvValues.POSTGRES_APP_USER
$AppDb = $EnvValues.POSTGRES_APP_DATABASE
$Su = $EnvValues.POSTGRES_SUPERUSER
$script:Sequence = 0
$script:ProbeNumber = 0
$script:Pending = $null
$script:ProbeNode = 'pg-node-1'
$script:Killed = $null
$script:Loads = [System.Collections.Generic.List[string]]::new()
$script:Stages = [System.Collections.Generic.List[object]]::new()
$StartUtc = [DateTime]::UtcNow
$Nodes = @('pg-node-1', 'pg-node-2', 'pg-node-3', 'pg-node-4', 'pg-node-5')
function Redact([string]$Text) {
    foreach ($secret in $Secrets) { if ($secret) { $Text = $Text.Replace($secret, '[REDACTED]') } }
    return $Text
}
function JsonLine([string]$File, $Value) {
    $Value | ConvertTo-Json -Depth 30 -Compress | Add-Content -LiteralPath $File -Encoding utf8
}
function Event([string]$Name, $Details) {
    $entry = @{utc=[DateTime]::UtcNow.ToString('o'); name=$Name; details=$Details}
    JsonLine "$Out/events.jsonl" $entry
    Write-Host "$($entry.utc) $Name $($Details | ConvertTo-Json -Compress -Depth 5)"
}
function Cmd([string[]]$Arguments, [string]$InputText = '', [switch]$AllowFailure, [string]$Exe = 'docker') {
    $script:Sequence++
    $id = '{0:d5}' -f $script:Sequence
    $began = [DateTime]::UtcNow
    $display = Redact ($Exe + ' ' + (($Arguments | ForEach-Object { '"' + $_.Replace('"','\"') + '"' }) -join ' '))
    $info = [System.Diagnostics.ProcessStartInfo]::new($Exe)
    $info.WorkingDirectory = $Root
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.RedirectStandardInput = $true
    foreach ($arg in $Arguments) { $info.ArgumentList.Add($arg) }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $info
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if ($InputText) { $process.StandardInput.Write($InputText) }
    $process.StandardInput.Close()
    # This joins the actual command, rather than introducing an observation delay.
    if (-not $process.WaitForExit(180000)) { $process.Kill($true); throw "Command exceeded 180s: $display" }
    $result = @{id=$id; start=$began.ToString('o'); end=[DateTime]::UtcNow.ToString('o');
        seconds=([DateTime]::UtcNow-$began).TotalSeconds; command=$display; exit=$process.ExitCode;
        stdout=$stdout.GetAwaiter().GetResult(); stderr=$stderr.GetAwaiter().GetResult()}
    $body = "START $($result.start)`nCOMMAND $display`nSTDIN`n$InputText`nSTDOUT`n$($result.stdout)`nSTDERR`n$($result.stderr)`nEND $($result.end)`nEXIT $($result.exit)`nSECONDS $($result.seconds)"
    Redact $body | Set-Content "$Out/commands/$id.txt" -Encoding utf8
    JsonLine "$Out/commands.jsonl" @{id=$id;start=$result.start;end=$result.end;seconds=$result.seconds;exit=$result.exit;command=$display;input=(Redact $InputText);output="commands/$id.txt"}
    $process.Dispose()
    if ($result.exit -ne 0 -and -not $AllowFailure) { throw "Command $id failed: $display : $(Redact $result.stderr)" }
    return [pscustomobject]$result
}
function Sql([string]$Node, [string]$Query, [int]$Port = 0, [switch]$Admin, [switch]$AllowFailure) {
    $user = if ($Admin) { $Su } else { $AppUser }
    $pass = if ($Admin) { $EnvValues.POSTGRES_SUPERUSER_PASSWORD } else { $EnvValues.POSTGRES_APP_PASSWORD }
    $args = @('exec','-e',"PGPASSWORD=$pass",'-e','PGCONNECT_TIMEOUT=3','-e','PGOPTIONS=-c statement_timeout=5000', $Node,
        'psql','-X','-A','-t','-v','ON_ERROR_STOP=1','-U',$user,'-d',$AppDb)
    if ($Port) { $args += @('-h','haproxy','-p',"$Port") }
    return Cmd ($args + @('-c',$Query)) -AllowFailure:$AllowFailure
}
function Cluster {
    $r = Cmd @('exec',$script:ProbeNode,'patronictl','-c','/etc/patroni/patroni.yml','list','-f','json')
    return @($r.stdout | ConvertFrom-Json)
}
function ProxyStats {
    $r = Cmd @('-fsS','--max-time','4','http://localhost:7000/;csv') -Exe 'curl.exe' -AllowFailure
    if ($r.exit) { return @() }
    return @($r.stdout.Replace('# pxname','pxname') | ConvertFrom-Csv)
}
function Runtime([string]$Instruction) {
    $r = Cmd @('exec','haproxy','sh','-c',"printf '%s\n' '$Instruction' | nc -w 2 127.0.0.1 9999")
    if ($r.stdout.Trim()) { throw "HAProxy runtime command rejected: $($r.stdout)" }
}
function Probe([string]$Stage) {
    if (-not $script:Pending) {
        $script:ProbeNumber++
        $script:Pending = "$RunId-$('{0:d5}' -f $script:ProbeNumber)"
    }
    $token = $script:Pending
    # Same token is retried after an ambiguous outcome; PK prevents duplicate writes.
    $q = "INSERT INTO phase3_lab.events(token,stage) VALUES ('$token','$Stage') ON CONFLICT(token) DO NOTHING; SELECT json_build_object('token',token,'server',inet_server_addr(),'replica',pg_is_in_recovery()) FROM phase3_lab.events WHERE token='$token';"
    $r = Sql $script:ProbeNode $q 5000 -AllowFailure
    $ack = $r.exit -eq 0 -and $r.stdout.Contains($token)
    JsonLine "$Out/write-probes.jsonl" @{stage=$Stage;token=$token;start=$r.start;end=$r.end;seconds=$r.seconds;ack=$ack;command=$r.id;response=$r.stdout;error=$r.stderr}
    if ($ack) { $script:Pending = $null }
    $read = Sql $script:ProbeNode "SELECT json_build_object('server',inet_server_addr(),'replica',pg_is_in_recovery(),'rows',(SELECT count(*) FROM phase3_lab.items));" 5001 -AllowFailure
    JsonLine "$Out/read-probes.jsonl" @{stage=$Stage;start=$read.start;end=$read.end;exit=$read.exit;command=$read.id;response=$read.stdout;error=$read.stderr}
    return $ack
}
function Snapshot([string]$Label) {
    $dir = "$Out/$Label"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $begin = [DateTime]::UtcNow
    Event snapshot-start $Label
    $c = @(Cluster)
    $c | ConvertTo-Json -Depth 10 | Set-Content "$dir/cluster.json"
    $ps = Cmd @('compose','--profile','elastic','ps','-a')
    $ps.stdout | Set-Content "$dir/containers.txt"
    $health = Cmd @('exec','etcd','etcdctl','endpoint','health','--endpoints=http://localhost:2379')
    $health.stdout + $health.stderr | Set-Content "$dir/etcd-health.txt"
    $stats = @(ProxyStats)
    $stats | ConvertTo-Json -Depth 5 | Set-Content "$dir/routing.json"
    $rows = @()
    foreach ($node in $Nodes) {
        $q = @"
SELECT json_build_object('node','$node','replica',pg_is_in_recovery(),'server',inet_server_addr(),
 'items',(SELECT count(*) FROM phase3_lab.items),
 'items_hash',(SELECT md5(string_agg(md5(id::text || payload),'' ORDER BY id)) FROM phase3_lab.items),
 'events',(SELECT count(*) FROM phase3_lab.events),
 'events_hash',(SELECT md5(coalesce(string_agg(token || ':' || stage,'' ORDER BY token),'')) FROM phase3_lab.events),
 'customers',(SELECT count(*) FROM customers),'orders',(SELECT count(*) FROM orders),'ha_test',(SELECT count(*) FROM ha_test),
 'databases',(SELECT json_agg(datname) FROM pg_database WHERE NOT datistemplate),
 'tables',(SELECT json_agg(schemaname || '.' || tablename) FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema')),
 'partitions',(SELECT count(*) FROM pg_partitioned_table),
 'citus',(SELECT count(*) FROM pg_extension WHERE extname='citus'));
"@
        $r = Sql $node $q -AllowFailure
        if ($r.exit -eq 0) { $rows += $r.stdout | ConvertFrom-Json }
        else { $rows += [pscustomobject]@{node=$node;unavailable=$true;command=$r.id} }
        $rep = Sql $node "SELECT json_build_object('senders',(SELECT json_agg(t) FROM (SELECT application_name,state,sync_state,sent_lsn,replay_lsn,pg_wal_lsn_diff(sent_lsn,replay_lsn) lag_bytes FROM pg_stat_replication) t),'receiver',(SELECT json_agg(t) FROM (SELECT status,sender_host,received_tli,written_lsn,flushed_lsn FROM pg_stat_wal_receiver) t));" -Admin -AllowFailure
        $rep.stdout + $rep.stderr | Set-Content "$dir/$node-replication.txt"
    }
    $rows | ConvertTo-Json -Depth 10 | Set-Content "$dir/row-counts.json"
    # New connections demonstrate actual backend selection, not only health flags.
    $routes = @()
    foreach ($port in @(5000,5001,5001,5001,5001,5001,5001,5001,5001)) {
        $r = Sql $script:ProbeNode "SELECT json_build_object('port',$port,'server',inet_server_addr(),'replica',pg_is_in_recovery());" $port -AllowFailure
        $routes += @{exit=$r.exit;command=$r.id;response=$r.stdout}
    }
    $routes | ConvertTo-Json -Depth 5 | Set-Content "$dir/client-routing.json"
    JsonLine "$Out/snapshots.jsonl" @{label=$Label;start=$begin.ToString('o');end=[DateTime]::UtcNow.ToString('o');rows=$rows}
    Event snapshot-end $Label
}
function ArchiveLogs([string]$Label, [string[]]$Names = $Nodes) {
    foreach ($node in $Names) {
        [void](Cmd @('logs','--timestamps','--since',$StartUtc.ToString('o'),$node) -AllowFailure)
        if ($node -like 'pg-node-*') {
            # PostgreSQL's logging_collector stores expanded SQL separately from Docker logs.
            [void](Cmd @('exec',$node,'bash','-c','find "$PATRONI_POSTGRESQL_DATA_DIR/pg_log" -type f -name "*.log" -exec cat {} +') -AllowFailure)
        }
    }
    Event logs-archived $Label
}
function Transactions([string]$Directory) {
    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($file in Get-ChildItem $Directory -Filter 'tx-*' -File) {
        # Docker Desktop is concurrently writing bind-mounted logs. ReadLines
        # denies write sharing on Windows and fails while a batch is active.
        $stream = [System.IO.File]::Open($file.FullName, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        $reader = [System.IO.StreamReader]::new($stream)
        try {
            while ($null -ne ($line = $reader.ReadLine())) {
                $p = $line.Trim() -split '\s+'
                if ($p.Count -ge 6 -and $p[2] -match '^\d+$' -and $p[4] -match '^\d+$' -and $p[5] -match '^\d+$') {
                    $records.Add([pscustomobject]@{ms=([double]$p[2]/1000);epoch=([double]$p[4]+[double]$p[5]/1000000)})
                }
            }
        } finally { $reader.Dispose(); $stream.Dispose() }
    }
    return $records.ToArray()
}
function RunStage([string]$Label,[int]$Duration,[int]$Rate,[int]$Clients,[scriptblock]$Action = {}) {
    $dir = "$Out/$Label/traffic"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $name = "phase3-$RunId-$Label".ToLower()
    $started = [DateTime]::UtcNow
    $proxyStart = @(ProxyStats)
    $args = @('run','-d','--name',$name,'--network','postgres-patroni-ha_patroni-net',
        '--mount',"type=bind,source=$PSScriptRoot,target=/work,readonly",'--mount',"type=bind,source=$dir,target=/evidence",
        '-e',"PGUSER=$AppUser",'-e',"PGDATABASE=$AppDb",'-e',"PGPASSWORD=$($EnvValues.POSTGRES_APP_PASSWORD)",
        '-e','PGCONNECT_TIMEOUT=3','--entrypoint','/bin/bash','postgres-patroni-ha-pg-node-1',
        '/work/traffic.sh',"$Duration","$Rate","$Clients")
    [void](Cmd $args)
    $script:Loads.Add($name)
    Event stage-start @{stage=$Label;duration=$Duration;offeredTps=$Rate;clients=$Clients;container=$name}
    $lastCount = 0
    $lastTime = [DateTime]::UtcNow
    $deadline = $lastTime.AddSeconds($Duration)
    while ([DateTime]::UtcNow -lt $deadline) {
        # Useful resource observation naturally spaces samples; no blind delay loops.
        $resources = Cmd (@('stats','--no-stream','--format','{{json .}}') + $Nodes + @('haproxy')) -AllowFailure
        $now = [DateTime]::UtcNow
        $tx = @(Transactions $dir)
        $measured = ($tx.Count-$lastCount)/[Math]::Max(0.001,($now-$lastTime).TotalSeconds)
        $metric = [pscustomobject]@{utc=$now.ToString('o');stage=$Label;tps=$measured;transactions=$tx.Count;resourcesCommand=$resources.id;elapsed=($now-$started).TotalSeconds}
        JsonLine "$Out/metrics.jsonl" $metric
        $lastCount = $tx.Count
        $lastTime = $now
        [void](Probe $Label)
        & $Action $metric
    }
    [void](Cmd @('wait',$name))
    $logs = Cmd @('logs','--timestamps',$name)
    $logs.stdout + $logs.stderr | Set-Content "$Out/$Label/client.log"
    $all = @(Transactions $dir)
    $times = @($all | ForEach-Object ms | Sort-Object)
    $proxyEnd = @(ProxyStats)
    $routes = @()
    foreach ($node in $Nodes) {
        $b = @($proxyStart | Where-Object { $_.pxname -eq 'pg-replicas' -and $_.svname -eq $node })
        $e = @($proxyEnd | Where-Object { $_.pxname -eq 'pg-replicas' -and $_.svname -eq $node })
        if ($b.Count -and $e.Count) { $routes += @{node=$node;connections=([long]$e[0].stot-[long]$b[0].stot);endStatus=$e[0].status} }
    }
    $span = if ($all.Count -gt 1) { ($all.epoch | Measure-Object -Maximum).Maximum - ($all.epoch | Measure-Object -Minimum).Minimum } else { 0 }
    $summary = @{stage=$Label;start=$started.ToString('o');end=[DateTime]::UtcNow.ToString('o');offeredTps=$Rate;clients=$Clients;
        requestedSeconds=$Duration;successfulTransactions=$all.Count;observedCompletionSpanSeconds=$span;
        achievedTps=($all.Count/[Math]::Max(1,$Duration));meanMs=($times | Measure-Object -Average).Average;
        p95Ms=$(if ($times.Count) {$times[[Math]::Max(0,[int][Math]::Ceiling($times.Count*0.95)-1)]} else {$null});
        p99Ms=$(if ($times.Count) {$times[[Math]::Max(0,[int][Math]::Ceiling($times.Count*0.99)-1)]} else {$null});
        failedBatches=([regex]::Matches($logs.stdout,'END batch=\d+ exit=[1-9]\d*').Count);routes=$routes}
    $script:Stages.Add($summary)
    $summary | ConvertTo-Json -Depth 10 | Set-Content "$Out/$Label/summary.json"
    Event stage-end $summary
}
try {
    foreach ($f in @('docker-compose.yml','haproxy/haproxy.cfg','patroni/patroni-template.yml','patroni/entrypoint.sh')) {
        Copy-Item "$Root/$f" "$Out/source/$($f.Replace('/','-'))"
    }
    Copy-Item "$PSScriptRoot/*" "$Out/source/"
    Event preparation-start @{run=$RunId;output=$Out;policy='4..5 nodes, high>30 successful read TPS x2 samples; low<10 x2; pg-node-5 excluded from elections'}
    [void](Cmd @('context','show'))
    [void](Cmd @('info','--format','CPUs={{.NCPU}} Memory={{.MemTotal}}'))
    [void](Cmd @('compose','--profile','elastic','config'))
    [void](Cmd @('exec','pg-node-1','pgbench','--version'))
    [void](Cmd @('exec','haproxy','sh','-c','command -v nc'))
    $c = @(Cluster)
    if ($c.Count -ne 4 -or @($c | Where-Object Role -EQ 'Leader').Count -ne 1 -or @($c | Where-Object State -EQ 'streaming').Count -ne 3) {
        throw 'Precondition: exactly four nodes, one primary and three streaming replicas required.'
    }
    # One-time feature deployment, BEFORE measured scenarios; never reload on scaling/failover.
    [void](Cmd @('exec','haproxy','haproxy','-c','-f','/usr/local/etc/haproxy/haproxy.cfg'))
    [void](Cmd @('compose','restart','--no-deps','haproxy'))
    $until = [DateTime]::UtcNow.AddSeconds(45)
    do {
        $s = @(ProxyStats)
        $up = @($s | Where-Object { $_.pxname -eq 'pg-primary' -and $_.svname -like 'pg-node-*' -and $_.status -eq 'UP' }).Count
        if ($up -eq 1) { break }
        [void](Cmd @('stats','--no-stream','haproxy'))
    } while ([DateTime]::UtcNow -lt $until)
    if ($up -ne 1) { throw 'Primary endpoint did not become ready' }
    [void](Cmd @('compose','--profile','elastic','build','pg-node-5'))
    $seed = Get-Content "$PSScriptRoot/seed.sql" -Raw
    [void](Cmd @('exec','-i','-e',"PGPASSWORD=$($EnvValues.POSTGRES_APP_PASSWORD)",'pg-node-1','psql','-X','-v','ON_ERROR_STOP=1','-h','haproxy','-p','5000','-U',$AppUser,'-d',$AppDb) -InputText $seed)
    [void](Sql 'pg-node-1' "SELECT name,setting FROM pg_settings WHERE name IN ('max_connections','max_wal_senders','max_replication_slots','synchronous_commit','synchronous_standby_names','log_statement','log_min_duration_statement');" 5000 -Admin)
    Snapshot '00-baseline'
    Event preparation-end 'Topology remains four nodes; elastic image prebuilt, volume not initialized.'
    RunStage '01-low-four' 20 5 2
    RunStage '02-high-four' 30 120 12
    Snapshot '02-high-four-end'
    $script:HighCount = 0
    $script:ScaleStarted = $false
    $script:ScaleReady = $false
    RunStage '03-auto-scale-out' 65 120 12 {
        param($m)
        if (-not $script:ScaleStarted) {
            if ($m.tps -gt 30) { $script:HighCount++ } else { $script:HighCount=0 }
            if ($script:HighCount -ge 2) {
                Event scale-out-trigger @{measuredTps=$m.tps;samples=$script:HighCount}
                $script:ScaleStarted=$true
                [void](Cmd @('compose','--profile','elastic','up','-d','--no-deps','pg-node-5'))
                Snapshot '03-during-node-join'
            }
        } elseif (-not $script:ScaleReady) {
            $c = @(Cluster)
            $n = @($c | Where-Object Member -EQ 'pg-node-5')
            $s = @(ProxyStats)
            if ($n.Count -and $n[0].State -eq 'streaming' -and $n[0].'Lag in MB' -eq 0 -and
                @($s | Where-Object { $_.pxname -eq 'pg-replicas' -and $_.svname -eq 'pg-node-5' -and $_.status -eq 'UP' }).Count) {
                $script:ScaleReady=$true
                Event scale-out-ready @{node='pg-node-5';measuredTps=$m.tps}
            }
        }
    }
    if (-not $script:ScaleReady) { throw 'Traffic-driven scale-out or readiness was not demonstrated' }
    Snapshot '04-five-ready'
    RunStage '04-high-five' 30 120 12
    $script:Injected = $false
    $script:Promoted = $false
    $script:OriginalLeader = (@(Cluster) | Where-Object Role -EQ 'Leader').Member
    $script:ProbeNode = @($Nodes | Where-Object { $_ -ne $script:OriginalLeader -and $_ -ne 'pg-node-5' })[0]
    RunStage '05-failover-under-load' 90 120 12 {
        param($m)
        if (-not $script:Injected -and $m.elapsed -gt 8) {
            Event kill-primary-start $script:OriginalLeader
            $script:Killed=$script:OriginalLeader
            [void](Cmd @('kill',$script:Killed))
            $script:Injected=$true
            Event kill-primary-complete $script:Killed
            Snapshot '05-during-primary-failure'
        } elseif ($script:Injected -and -not $script:Promoted) {
            $c = @(Cluster)
            $leader = @($c | Where-Object { $_.Role -eq 'Leader' -and $_.Member -ne $script:OriginalLeader })
            if ($leader.Count -eq 1) {
                $script:Promoted=$true
                Event automatic-promotion-observed $leader[0]
            }
        }
    }
    if (-not $script:Promoted) { throw 'Automatic promotion not observed' }
    Snapshot '06-after-failover'
    $script:Restored=$false
    $script:Rejoined=$false
    RunStage '07-rejoin-under-load' 60 120 12 {
        param($m)
        if (-not $script:Restored) {
            Event restore-node-start $script:Killed
            [void](Cmd @('start',$script:Killed))
            $script:Restored=$true
            Event restore-node-complete $script:Killed
            Snapshot '07-during-rejoin'
        } elseif (-not $script:Rejoined) {
            $c = @(Cluster)
            $n = @($c | Where-Object Member -EQ $script:Killed)
            if ($n.Count -and $n[0].Role -eq 'Replica' -and $n[0].State -eq 'streaming' -and $n[0].'Lag in MB' -eq 0) {
                $script:Rejoined=$true
                Event automatic-rejoin-observed $n[0]
                $script:Killed=$null
            }
        }
    }
    if (-not $script:Rejoined) { throw 'Automatic rejoin not observed' }
    Snapshot '08-after-rejoin'
    $script:LowCount=0
    $script:ScaledIn=$false
    RunStage '09-auto-scale-in' 40 5 2 {
        param($m)
        if (-not $script:ScaledIn) {
            if ($m.tps -lt 10) { $script:LowCount++ } else { $script:LowCount=0 }
            if ($script:LowCount -ge 2) {
                $c = @(Cluster)
                $target = @($c | Where-Object Member -EQ 'pg-node-5')
                $remaining = @($c | Where-Object { $_.Member -ne 'pg-node-5' -and $_.Role -eq 'Replica' -and $_.State -eq 'streaming' -and $_.'Lag in MB' -eq 0 })
                if ($target.Count -ne 1 -or $target[0].Role -ne 'Replica' -or $remaining.Count -lt 3) { throw 'Scale-in safety guard rejected removal' }
                Event scale-in-trigger @{measuredTps=$m.tps;remainingReplicas=$remaining.Count}
                Runtime 'set server pg-replicas/pg-node-5 state drain'
                Runtime 'set server pg-primary/pg-node-5 state maint'
                $deadline = [DateTime]::UtcNow.AddSeconds(30)
                do {
                    $s = @(ProxyStats)
                    $targetStats = @($s | Where-Object { $_.svname -eq 'pg-node-5' -and $_.pxname -eq 'pg-replicas' })
                    if ($targetStats.Count -and [int]$targetStats[0].scur -eq 0) { break }
                } while ([DateTime]::UtcNow -lt $deadline)
                if (-not $targetStats.Count -or [int]$targetStats[0].scur -ne 0) { throw 'Drain did not finish; volume and node retained' }
                Event drained @{node='pg-node-5';activeConnections=$targetStats[0].scur}
                Snapshot '09-drained-before-stop'
                ArchiveLogs 'elastic-before-stop' @('pg-node-5')
                # Recheck immediately before stopping; the elastic node is also nofailover.
                if ((@(Cluster) | Where-Object Member -EQ 'pg-node-5').Role -ne 'Replica') { throw 'Target became primary; refusing stop' }
                [void](Cmd @('stop','--time','30','pg-node-5'))
                # Return predeclared slot to health-check control for future automatic starts.
                Runtime 'set server pg-replicas/pg-node-5 state ready'
                Runtime 'set server pg-primary/pg-node-5 state ready'
                $script:ScaledIn=$true
                Event scale-in-complete 'pg-node-5 stopped; volume preserved; no proxy restart'
            }
        }
    }
    if (-not $script:ScaledIn) { throw 'Automatic scale-in was not demonstrated' }
    RunStage '10-low-four-final' 20 5 2
    [void](Probe 'final-watermark')
    if ($script:Pending) { throw 'Final write probe remains unacknowledged' }
    Snapshot '11-final'
    $acks = @(Get-Content "$Out/write-probes.jsonl" | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object ack | Select-Object -ExpandProperty token -Unique | Sort-Object)
    $checks = @()
    foreach ($node in $Nodes[0..3]) {
        $r = Sql $node "SELECT token FROM phase3_lab.events WHERE token LIKE '$RunId-%' ORDER BY token;"
        $present = @($r.stdout.Trim() -split '\r?\n' | Where-Object { $_ } | Sort-Object)
        $missing = @($acks | Where-Object { $_ -notin $present })
        $checks += @{node=$node;acknowledged=$acks.Count;present=$present.Count;missing=$missing}
        if ($missing.Count) { throw "Acknowledged tokens missing on $node" }
    }
    $checks | ConvertTo-Json -Depth 10 | Set-Content "$Out/acknowledged-write-validation.json"
    $script:Stages | ConvertTo-Json -Depth 10 | Set-Content "$Out/benchmark-summary.json"
    ArchiveLogs 'final' ($Nodes[0..3] + @('haproxy','etcd'))
    Event run-complete @{acknowledgedTokens=$acks.Count;finalNodes=4;elasticVolumePreserved=$true}
} catch {
    Event run-failed @{error=$_.Exception.Message;stack=$_.ScriptStackTrace}
    throw
} finally {
    if ($script:Killed) {
        Event safety-cleanup-restore $script:Killed
        [void](Cmd @('start',$script:Killed) -AllowFailure)
    }
    foreach ($name in $script:Loads) {
        [void](Cmd @('logs','--timestamps',$name) -AllowFailure)
        # These are client-only containers; no database containers or volumes removed.
        [void](Cmd @('rm','-f',$name) -AllowFailure)
    }
    Event evidence-location $Out
}