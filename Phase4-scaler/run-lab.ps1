#Requires -Version 7.2
[CmdletBinding()]
param(
    [string]$NodeImage = 'postgres-patroni-ha-pg-node-1:latest',
    [string]$EtcdImage = 'quay.io/coreos/etcd:v3.5.15',
    [string]$ProxyImage = 'haproxy:2.9-alpine',
    [ValidateRange(120,1800)][int]$TrafficDurationSeconds = 360,
    [ValidateRange(30,600)][int]$ReadyTimeoutSeconds = 180,
    [ValidateRange(10,120)][int]$CommandTimeoutSeconds = 60,
    [ValidateRange(15,120)][int]$CooldownSeconds = 15,
    [ValidateRange(300,3600)][int]$LabTimeoutSeconds = 1200,
    [ValidateRange(256,1024)][int]$NodeMemoryMB = 512
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$runId = 'phase4-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfff') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
$evidence = Join-Path $root "evidence/$runId"
if (Test-Path $evidence) { throw 'Refusing to overwrite evidence' }
[void][IO.Directory]::CreateDirectory($evidence)
foreach ($dir in @('source','traffic','serverlogs')) { [void][IO.Directory]::CreateDirectory((Join-Path $evidence $dir)) }
$source = Join-Path $evidence 'source'
$utf8 = [Text.UTF8Encoding]::new($false)
$secrets = @()
foreach ($i in 1..3) {
    # Hex is a cryptographically random alphanumeric subset, safe for the existing sed template.
    $bytes = [byte[]]::new(24)
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $secrets += [Convert]::ToHexString($bytes)
}
$adminPassword, $replicationPassword, $appPassword = $secrets
$network = "$runId-net"
$primary = "$runId-primary"
$proxy = "$runId-proxy"
$containers = [Collections.Generic.List[string]]::new()
$nodes = [Collections.Generic.List[string]]::new()
$volumes = [Collections.Generic.List[string]]::new()
$active = [Collections.Generic.List[string]]::new()
$tokens = [Collections.Generic.List[string]]::new()
$script:traffic = $null
$script:trafficDir = $null
$script:trafficSequence = 0
$script:commandSequence = 0
$script:highSamples = 0
$script:lowSamples = 0
$script:lastDecision = [DateTime]::MinValue
$script:fixtureHash = $null
$script:phase = 'setup'
$script:phaseStarted = [DateTime]::UtcNow
$script:steadyStarted = $null
$script:finished = $false
$success = $false
$failure = $null
$cleanupErrors = [Collections.Generic.List[string]]::new()
$labDeadline = [DateTime]::UtcNow.AddSeconds($LabTimeoutSeconds)

function Redact([string]$Text) {
    if ($null -eq $Text) { return '' }
    foreach ($secret in $secrets) { $Text = $Text.Replace($secret, '[REDACTED]') }
    return $Text
}
function Save-Text([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, (Redact $Text), $utf8)
}
function Record([string]$File, $Data) {
    $json = Redact ($Data | ConvertTo-Json -Depth 30 -Compress)
    [IO.File]::AppendAllText((Join-Path $evidence "$File.jsonl"), "$json`n", $utf8)
}
function Event([string]$Kind, $Data) {
    Record 'events' @{ utc=[DateTime]::UtcNow.ToString('o'); phase=$script:phase; kind=$Kind; data=$Data }
}
function Cmd {
    param([string[]]$Argv, [string]$InputText = '', [int]$TimeoutSeconds = $CommandTimeoutSeconds,
          [switch]$AllowFailure)
    $script:commandSequence++
    $id = $script:commandSequence
    $start = [DateTime]::UtcNow
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $p = [Diagnostics.Process]::new()
    $p.StartInfo.FileName = 'docker'
    $p.StartInfo.UseShellExecute = $false
    $p.StartInfo.RedirectStandardInput = $true
    $p.StartInfo.RedirectStandardOutput = $true
    $p.StartInfo.RedirectStandardError = $true
    foreach ($arg in $Argv) { $p.StartInfo.ArgumentList.Add($arg) }
    $stdout = ''; $stderr = ''; $code = -1; $timedOut = $false
    $outTask = $null; $errTask = $null
    try {
        if (-not $p.Start()) { throw 'Cannot start docker CLI' }
        # Both pipes drain concurrently, including while stdin is being sent.
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        $inputTask = $p.StandardInput.WriteAsync($InputText)
        if (-not $inputTask.Wait($TimeoutSeconds * 1000)) { throw 'stdin write timeout' }
        $p.StandardInput.Close()
        $remaining = [Math]::Max(1, $TimeoutSeconds * 1000 - [int]$watch.ElapsedMilliseconds)
        if (-not $p.WaitForExit($remaining)) {
            $timedOut = $true
            $p.Kill($true)
            if (-not $p.WaitForExit(5000)) { throw 'CLI did not terminate after timeout' }
        }
        $code = $p.ExitCode
    } catch {
        $stderr = $_.Exception.Message
        try { if (-not $p.HasExited) { $p.Kill($true); [void]$p.WaitForExit(5000) } } catch { }
    } finally {
        # Killing the CLI closes its pipes, retaining output received before timeout.
        foreach ($pair in @(@('out',$outTask), @('err',$errTask))) {
            if ($null -ne $pair[1]) {
                try {
                    if ($pair[1].Wait(5000)) {
                        if ($pair[0] -eq 'out') { $stdout = $pair[1].Result }
                        else { $stderr += $pair[1].Result }
                    } else { $stderr += "`nOutput reader did not close; capture incomplete."; $code = -1 }
                } catch { $stderr += "`n$($_.Exception.Message)"; $code = -1 }
            }
        }
        $watch.Stop()
        $result = [pscustomobject]@{ id=$id; utc=$start.ToString('o'); executable='docker'; args=$Argv;
            input=$InputText; exit=$code; timeout=$timedOut; stdout=$stdout; stderr=$stderr;
            durationMs=$watch.ElapsedMilliseconds }
        Record 'commands' $result
        $p.Dispose()
    }
    if (($code -ne 0 -or $timedOut) -and -not $AllowFailure) {
        throw (Redact "Docker command $id failed (exit=$code timeout=$timedOut): $stderr")
    }
    return $result
}
function Tick {
    if ([DateTime]::UtcNow -gt $labDeadline) { throw 'Overall lab deadline exceeded' }
    # This blocking observation provides the polling interval; there are no artificial sleeps.
    $r = Cmd -Argv @('stats','--no-stream','--format','{{json .}}',$primary) -AllowFailure
    Record 'resources' @{ utc=[DateTime]::UtcNow.ToString('o'); command=$r.id; output=$r.stdout }
    if ($null -ne $script:traffic) {
        $state = (Cmd -Argv @('inspect','--format','{{json .State}}',$script:traffic)).stdout | ConvertFrom-Json
        if (-not $state.Running) { throw "Traffic exited prematurely (exit $($state.ExitCode)); refusing to treat driver failure as low demand" }
    }
}
function Await([string]$Label, [scriptblock]$Test, [int]$Seconds = $ReadyTimeoutSeconds, [switch]$Probe) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        if ([DateTime]::UtcNow -gt $labDeadline) { throw 'Overall lab deadline exceeded' }
        try {
            if (& $Test) { Event 'ready' @{check=$Label}; return }
        } catch { Event 'readiness-retry' @{check=$Label; error=$_.Exception.Message} }
        Tick
        if ($Probe) { $null = Measured-TPS; Write-Probe }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Readiness timeout: $Label"
}
function SQL([string]$HostName, [int]$Port, [string]$Text, [switch]$AllowFailure) {
    $r = Cmd -Argv @('exec','-i','-e',"PGPASSWORD=$adminPassword",'-e','PGDATABASE=postgres',
        '-e','PGCONNECT_TIMEOUT=5','-e','PGOPTIONS=-c statement_timeout=10000 -c lock_timeout=5000',
        '-e','PGAPPNAME=phase4-evidence',$primary,'psql','-X','-q','-A','-t','-v','ON_ERROR_STOP=1',
        '-h',$HostName,'-p',"$Port",'-U','postgres') -InputText $Text -AllowFailure
    Record 'sql' @{ utc=$r.utc; command=$r.id; host=$HostName; port=$Port; database='postgres';
        input=$Text; exit=$r.exit; timeout=$r.timeout; stdout=$r.stdout; stderr=$r.stderr; durationMs=$r.durationMs }
    if (($r.exit -ne 0 -or $r.timeout) -and -not $AllowFailure) { throw "SQL failed; see command $($r.id) and sql.jsonl" }
    return $r
}
function Http([string]$Alias, [string]$Path = 'patroni') {
    $r = Cmd -Argv @('exec',$primary,'curl','--fail','--silent','--show-error','--max-time','4',"http://${Alias}:8008/$Path")
    return ($r.stdout | ConvertFrom-Json)
}
function Runtime([string]$Line) {
    $r = Cmd -Argv @('exec','-i',$proxy,'sh','-c','nc -w 1 127.0.0.1 9999') -InputText "$Line`n"
    # HAProxy 2.9 emits a positive acknowledgement for address changes, unlike state changes.
    $addressAcknowledged = $Line -match '^set server replicas/elastic[1-4] addr ([0-9.]+) port 5432$' -and
        $r.stdout.Trim() -eq "IP changed from '127.0.0.1' to '$($Matches[1])', no need to change the port by 'stats socket command'"
    if ($Line -ne 'show stat' -and -not $addressAcknowledged -and -not [string]::IsNullOrWhiteSpace($r.stdout)) {
        throw "HAProxy rejected runtime operation: $($r.stdout)"
    }
    return $r.stdout
}
function Proxy-Stats {
    $text = Runtime 'show stat'
    $rows = @((($text.Trim() -replace '^#\s*','') | ConvertFrom-Csv))
    Record 'routing' @{utc=[DateTime]::UtcNow.ToString('o'); rows=$rows}
    return $rows
}
function New-Volume([string]$Name) {
    $volumes.Add($Name)
    $null = Cmd -Argv @('volume','create','--label',"phase4.run=$runId",$Name)
}
function New-Node([string]$Alias, [bool]$Elastic) {
    $name = "$runId-$Alias"
    if ($containers.Contains($name)) { throw "Unexpected repeated slot creation in one-cycle demo: $Alias; refusing volume reuse" }
    $volume = "$name-data"
    New-Volume $volume
    $containers.Add($name); $nodes.Add($name)
    $nofailover = if ($Elastic) { 'true' } else { 'false' }
    $null = Cmd -Argv @('run','-d','--pull','never','--name',$name,'--hostname',$name,
        '--label',"phase4.run=$runId",'--network',$network,'--network-alias',$Alias,
        '--memory',"${NodeMemoryMB}m",'--stop-signal','SIGTERM',
        '--mount',"type=volume,source=$volume,target=/var/lib/postgresql/data",
        '--mount',"type=bind,source=$source/entrypoint.sh,target=/entrypoint.sh,readonly",
        '--mount',"type=bind,source=$source/patroni-template.yml,target=/etc/patroni/patroni-template.yml,readonly",
        '-e',"PATRONI_NAME=$name",'-e',"PATRONI_SCOPE=$runId",'-e','PATRONI_ETCD3_HOSTS=etcd:2379',
        '-e','PATRONI_SUPERUSER_USERNAME=postgres','-e',"PATRONI_SUPERUSER_PASSWORD=$adminPassword",
        '-e','PATRONI_REPLICATION_USERNAME=replicator','-e',"PATRONI_REPLICATION_PASSWORD=$replicationPassword",
        '-e','POSTGRES_APP_USER=phase4_unused','-e',"POSTGRES_APP_PASSWORD=$appPassword",
        '-e',"PATRONI_NOFAILOVER=$nofailover",'--entrypoint','/bin/bash',$NodeImage,'/entrypoint.sh')
    Event 'node-created' @{name=$name; alias=$Alias; volume=$volume; nofailover=$Elastic}
}
function Fixture([string]$Alias) {
    $q = @'
SELECT json_build_object(
 'server',inet_server_addr(),'replica',pg_is_in_recovery(),
 'count',(SELECT count(*) FROM phase4_lab.items),
 'hash',(SELECT md5(string_agg(id::text || ':' || payload, ',' ORDER BY id)) FROM phase4_lab.items),
 'tokens',COALESCE((SELECT json_agg(token ORDER BY token) FROM phase4_lab.events),'[]'::json));
'@
    return ((SQL $Alias 5432 $q).stdout | ConvertFrom-Json)
}
function Replica-Ready([string]$Alias, [bool]$Elastic = $false) {
    $p = Http $Alias
    if ($p.role -ne 'replica' -or $p.state -ne 'running') { return $false }
    if ($Elastic -and (-not $p.tags.nofailover)) { return $false }
    $cluster = Http 'primary' 'cluster'
    $member = @($cluster.members | Where-Object name -EQ "$runId-$Alias")
    if ($member.Count -ne 1) { return $false }
    if ($member[0].role -ne 'replica' -or $member[0].state -ne 'streaming') { return $false }
    # Patroni REST cluster lag is bytes; missing/unknown is NOT coerced to zero.
    if ($null -eq $member[0].lag -or "$($member[0].lag)" -notmatch '^\d+$' -or [long]$member[0].lag -ne 0) { return $false }
    $f = Fixture $Alias
    return ($f.replica -eq $true -and $f.count -eq 100000 -and $f.hash -eq $script:fixtureHash)
}
function Write-Probe {
    $token = [guid]::NewGuid().ToString('N')
    $tokens.Add($token)
    # Same token for every retry, including a timeout after a possible commit.
    Await "write-token-$token" {
        $q = "INSERT INTO phase4_lab.events(token) VALUES ('$token') ON CONFLICT(token) DO NOTHING;`nSELECT json_build_object('token',token,'replica',pg_is_in_recovery(),'server',inet_server_addr()) FROM phase4_lab.events WHERE token='$token';"
        $r = SQL 'proxy' 5000 $q -AllowFailure
        if ($r.exit -ne 0 -or $r.timeout) { return $false }
        $v = $r.stdout | ConvertFrom-Json
        return ($v.token -eq $token -and $v.replica -eq $false)
    } 30
    Event 'write-acknowledged' @{token=$token}
}
function Snapshot([string]$Label, [switch]$RequireAgreement) {
    $reference = Fixture 'primary'
    if ($reference.replica -or $reference.count -ne 100000 -or $reference.hash -ne $script:fixtureHash) { throw 'Primary fixture changed or role changed' }
    $wanted = (@($tokens | Sort-Object) | ConvertTo-Json -Compress -AsArray)
    $actual = (@($reference.tokens) | ConvertTo-Json -Compress -AsArray)
    if ($wanted -ne $actual) { throw 'Primary does not contain exactly all acknowledged/attempted tokens' }
    $samples = @{}
    foreach ($alias in @('base') + @($active)) {
        if ($RequireAgreement) {
            Await "token-agreement-$alias" {
                $f = Fixture $alias
                return ($f.replica -and $f.count -eq 100000 -and $f.hash -eq $script:fixtureHash -and
                    ((@($f.tokens) | ConvertTo-Json -Compress -AsArray) -eq $wanted))
            }
        }
        $samples[$alias] = Fixture $alias
    }
    $roles = Http 'primary' 'cluster'
    $routing = @(Proxy-Stats)
    Record 'snapshots' @{utc=[DateTime]::UtcNow.ToString('o'); label=$Label; primary=$reference;
        replicas=$samples; expectedTokens=@($tokens); roles=$roles; routing=$routing; elasticCount=$active.Count}
}
function Redact-Tree([string]$Directory) {
    foreach ($file in Get-ChildItem -LiteralPath $Directory -File -Recurse) {
        # PostgreSQL CSV/stderr logs and Docker logs are UTF-8 text; never copy PGDATA/config.
        $text = [IO.File]::ReadAllText($file.FullName)
        $clean = Redact $text
        if ($clean -cne $text) { [IO.File]::WriteAllText($file.FullName,$clean,$utf8) }
    }
}
function Archive([string]$Name, [switch]$PostgresLogs) {
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfff') + '-' + [guid]::NewGuid().ToString('N').Substring(0,6)
    $dir = Join-Path $evidence "serverlogs/$Name-$stamp"
    [void][IO.Directory]::CreateDirectory($dir)
    $r = Cmd -Argv @('logs','--timestamps',$Name) -TimeoutSeconds 120 -AllowFailure
    Save-Text (Join-Path $dir 'docker.stdout.log') $r.stdout
    Save-Text (Join-Path $dir 'docker.stderr.log') $r.stderr
    $cp = $null
    try {
        if ($PostgresLogs) {
            $cp = Cmd -Argv @('cp',"${Name}:/var/lib/postgresql/data/pgdata/pg_log",$dir) -TimeoutSeconds 120 -AllowFailure
        }
    } finally { Redact-Tree $dir }
    if ($r.exit -ne 0 -or $r.timeout -or ($PostgresLogs -and ($cp.exit -ne 0 -or $cp.timeout))) {
        throw "Log archive incomplete for $Name; container retained"
    }
    Event 'logs-archived' @{name=$Name; directory=$dir; postgres=[bool]$PostgresLogs}
}
function Add-Elastic {
    $alias = 'elastic' + ($active.Count + 1)
    Event 'decision' @{action='out'; slot=$alias; highSamples=$script:highSamples; basis='completed transaction TPS only'}
    New-Node $alias $true
    Await "replica-$alias" { Replica-Ready $alias $true } -Probe
    $name = "$runId-$alias"
    $ip = (Cmd -Argv @('inspect','--format',"{{(index .NetworkSettings.Networks `"$network`").IPAddress}}",$name)).stdout.Trim()
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($ip,[ref]$parsed) -or $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw "Invalid inspected container IP: $ip" }
    $null = Runtime "set server replicas/$alias addr $ip port 5432"
    $null = Runtime "set server replicas/$alias state ready"
    Await "proxy-UP-$alias" {
        $row = @(Proxy-Stats | Where-Object { $_.pxname -eq 'replicas' -and $_.svname -eq $alias })
        return ($row.Count -eq 1 -and $row[0].status -eq 'UP')
    } 30
    $active.Add($alias)
    Event 'elastic-admitted' @{slot=$alias; ip=$ip; active=$active.Count}
    Snapshot "admitted-$alias" -RequireAgreement
}
function Remove-Elastic {
    $alias = $active[$active.Count - 1]
    $name = "$runId-$alias"
    Event 'decision' @{action='in'; slot=$alias; lowSamples=$script:lowSamples; basis='completed transaction TPS only'}
    Await 'baseline-ready-before-drain' { Replica-Ready 'base' }
    Await "elastic-safe-before-drain-$alias" { Replica-Ready $alias $true }
    Snapshot "before-remove-$alias" -RequireAgreement
    $null = Runtime "set server replicas/$alias state drain"
    Await "drained-$alias" {
        $row = @(Proxy-Stats | Where-Object { $_.pxname -eq 'replicas' -and $_.svname -eq $alias })
        return ($row.Count -eq 1 -and $row[0].scur -eq '0')
    } 30
    $null = Runtime "set server replicas/$alias state maint"
    # Revalidate after drain, immediately before termination, never remove a promoted member.
    if (-not (Replica-Ready 'base') -or -not (Replica-Ready $alias $true)) { throw 'Scale-in safety recheck failed' }
    $null = Cmd -Argv @('stop','--signal','SIGTERM','--time','30',$name)
    $state = (Cmd -Argv @('inspect','--format','{{json .State}}',$name)).stdout | ConvertFrom-Json
    if ($state.Running -or $state.OOMKilled -or $state.ExitCode -ne 0) { throw 'Replica shutdown was not graceful; preserving container' }
    Archive $name -PostgresLogs
    $null = Cmd -Argv @('rm',$name) # Deliberately NO -v; unique named volume survives.
    $absent = Cmd -Argv @('inspect','--format','{{.Name}}',$name) -AllowFailure
    if ($absent.exit -ne 1 -or $absent.stderr -notmatch 'No such (object|container)') { throw 'Container removal was not confirmed' }
    $null = Cmd -Argv @('volume','inspect','--format','{{.Name}} {{.Mountpoint}}',"$name-data")
    [void]$active.Remove($alias)
    Event 'elastic-removed' @{slot=$alias; retainedVolume="$name-data"; active=$active.Count}
    Snapshot "removed-$alias" -RequireAgreement
}
function Stop-Traffic {
    if ($null -eq $script:traffic) { return }
    $name = $script:traffic
    $r = Cmd -Argv @('stop','--signal','SIGTERM','--time','30',$name) -AllowFailure
    if ($r.exit -ne 0 -or $r.timeout) { throw "Cannot stop traffic $name" }
    $state = (Cmd -Argv @('inspect','--format','{{json .State}}',$name)).stdout | ConvertFrom-Json
    if ($state.Running -or $state.OOMKilled -or $state.ExitCode -ne 0) { throw "Traffic shutdown did not flush cleanly: $name" }
    Archive $name
    Event 'traffic-stopped' @{name=$name}
    $script:traffic = $null
}
function Start-Traffic([string]$Label, [int]$OfferedRate) {
    Stop-Traffic
    $script:trafficSequence++
    $script:traffic = "$runId-traffic-$($script:trafficSequence)-$Label"
    $script:trafficDir = Join-Path $evidence "traffic/$($script:trafficSequence)-$Label"
    [void][IO.Directory]::CreateDirectory($script:trafficDir)
    $containers.Add($script:traffic)
    $null = Cmd -Argv @('run','-d','--pull','never','--name',$script:traffic,'--label',"phase4.run=$runId",
        '--network',$network,'--memory','256m','--stop-signal','SIGTERM',
        '--mount',"type=bind,source=$source,target=/work,readonly",
        '--mount',"type=bind,source=$($script:trafficDir),target=/evidence",
        '-e','PGHOST=proxy','-e','PGPORT=5001','-e','PGUSER=postgres','-e','PGDATABASE=postgres',
        '-e','PGCONNECT_TIMEOUT=5',
        '-e',"PGPASSWORD=$adminPassword",'-e','PGAPPNAME=phase4-traffic',
        '--entrypoint','/bin/bash',$NodeImage,'/work/traffic.sh',"$TrafficDurationSeconds","$OfferedRate",'8')
    Event 'traffic-started' @{name=$script:traffic; offeredTPS=$OfferedRate; duration=$TrafficDurationSeconds;
        clients=8; label=$Label; controllerInput=$false; transactionLogDirectory=$script:trafficDir}
}
function Measured-TPS {
    # Native pgbench non-aggregated log: client, txn, latency-us, script, epoch-sec, epoch-us, [schedule-lag].
    # A 2s trailing delay reduces live stdio-buffer effects. Failed/skipped records are not completions.
    $end = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0 - 2
    $start = $end - 10
    $count = 0; $malformed = 0
    foreach ($file in Get-ChildItem -LiteralPath $script:trafficDir -Filter 'tx.*' -File) {
        $stream = [IO.File]::Open($file.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,
            ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $reader = [IO.StreamReader]::new($stream)
        try {
            while ($null -ne ($line = $reader.ReadLine())) {
                $p = $line.Trim() -split '\s+'
                if ($p.Count -lt 6 -or $p[2] -notmatch '^\d+$' -or $p[4] -notmatch '^\d+$' -or $p[5] -notmatch '^\d+$') {
                    $malformed++; continue
                }
                $ts = [double]$p[4] + [double]$p[5] / 1000000.0
                if ($ts -gt $start -and $ts -le $end) { $count++ }
            }
        } finally { $reader.Dispose() }
    }
    $metric = [pscustomobject]@{utc=[DateTime]::UtcNow.ToString('o'); windowStartEpoch=$start; windowEndEpoch=$end;
        completed=$count; seconds=10; tps=($count / 10.0); ignoredRecords=$malformed;
        source=$script:trafficDir; active=$active.Count}
    Record 'metrics' $metric
    return $metric
}
function Controller($Metric) {
    # No phase or offered-rate input: ONLY measured completions, active count, hysteresis and cooldown.
    if ($Metric.tps -gt 20) { $script:highSamples++ } else { $script:highSamples=0 }
    if ($Metric.tps -lt 5) { $script:lowSamples++ } else { $script:lowSamples=0 }
    $cool = ([DateTime]::UtcNow - $script:lastDecision).TotalSeconds -ge $CooldownSeconds
    Record 'decisions' @{utc=[DateTime]::UtcNow.ToString('o'); measuredTPS=$Metric.tps;
        highSamples=$script:highSamples; lowSamples=$script:lowSamples; cooldownSatisfied=$cool; active=$active.Count}
    if (-not $cool) { return }
    if ($script:highSamples -ge 2 -and $active.Count -lt 4) { Add-Elastic }
    elseif ($script:lowSamples -ge 2 -and $active.Count -gt 0) { Remove-Elastic }
    else { return }
    $script:lastDecision = [DateTime]::UtcNow
    $script:highSamples=0; $script:lowSamples=0
}
function Traffic-Driver {
    # Orchestrates the bounded experiment; never supplies a rate to Controller.
    $now = [DateTime]::UtcNow
    switch ($script:phase) {
        'low-baseline' {
            if (($now - $script:phaseStarted).TotalSeconds -ge 15) {
                Start-Traffic 'high' 100
                $script:phase='high'; $script:phaseStarted=[DateTime]::UtcNow
            }
        }
        'high' {
            if ($active.Count -eq 4) {
                if ($null -eq $script:steadyStarted) {
                    Await 'all-five-replicas-served-proxy-traffic' {
                        $rows = @(Proxy-Stats | Where-Object { $_.pxname -eq 'replicas' -and $_.svname -in (@('base') + @($active)) })
                        return ($rows.Count -eq 5 -and @($rows | Where-Object { $_.status -ne 'UP' -or [long]$_.stot -lt 1 }).Count -eq 0)
                    } 30
                    foreach ($alias in @($active)) { Await "four-confirmed-$alias" { Replica-Ready $alias $true } }
                    Snapshot 'four-active-confirmed' -RequireAgreement
                    $script:steadyStarted=[DateTime]::UtcNow
                    Event 'four-active-steady-start' @{active=4}
                } elseif (($now - $script:steadyStarted).TotalSeconds -ge 20) {
                    Snapshot 'four-active-steady-end' -RequireAgreement
                    Start-Traffic 'low-final' 2
                    $script:phase='low-final'; $script:phaseStarted=[DateTime]::UtcNow; $script:steadyStarted=$null
                }
            } else { $script:steadyStarted=$null }
        }
        'low-final' {
            if ($active.Count -eq 0) {
                if ($null -eq $script:steadyStarted) { $script:steadyStarted=$now; Event 'baseline-restored-steady-start' @{} }
                elseif (($now - $script:steadyStarted).TotalSeconds -ge 10) { $script:finished=$true }
            } else { $script:steadyStarted=$null }
        }
    }
}

try {
    # Capture immutable, LF-normalized source copies (including the EXISTING entrypoint), never env/config renders.
    foreach ($file in @('run-lab.ps1','traffic.sh','read.sql','seed.sql','haproxy.cfg','patroni-template.yml','README.md')) {
        Save-Text (Join-Path $source $file) ([IO.File]::ReadAllText((Join-Path $root $file)).Replace("`r`n","`n").TrimEnd("`n") + "`n")
    }
    $entrypoint = Join-Path (Split-Path $root -Parent) 'postgres-patroni-ha/patroni/entrypoint.sh'
    Save-Text (Join-Path $source 'entrypoint.sh') ([IO.File]::ReadAllText($entrypoint).Replace("`r`n","`n"))
    Event 'run-start' @{run=$runId; network=$network; parameters=$PSBoundParameters; defaults=@{
        trafficDuration=$TrafficDurationSeconds; readyTimeout=$ReadyTimeoutSeconds; commandTimeout=$CommandTimeoutSeconds;
        cooldown=$CooldownSeconds; labTimeout=$LabTimeoutSeconds; nodeMemoryMB=$NodeMemoryMB}; credentialPersistence='none'}
    $null = Cmd -Argv @('version','--format','{{json .}}')
    foreach ($image in @($NodeImage,$EtcdImage,$ProxyImage)) {
        $null = Cmd -Argv @('image','inspect','--format','{{.Id}} {{json .RepoTags}}',$image)
    }
    $null = Cmd -Argv @('network','create','--label',"phase4.run=$runId",$network)
    $etcd = "$runId-etcd"
    New-Volume "$etcd-data"
    $containers.Add($etcd)
    $null = Cmd -Argv @('run','-d','--pull','never','--name',$etcd,'--label',"phase4.run=$runId",
        '--network',$network,'--network-alias','etcd','--memory','256m',
        '--mount',"type=volume,source=$etcd-data,target=/etcd-data",$EtcdImage,'/usr/local/bin/etcd',
        '--name','etcd','--data-dir','/etcd-data','--listen-client-urls','http://0.0.0.0:2379',
        '--advertise-client-urls','http://etcd:2379','--listen-peer-urls','http://0.0.0.0:2380',
        '--initial-advertise-peer-urls','http://etcd:2380','--initial-cluster','etcd=http://etcd:2380',
        '--initial-cluster-token',$runId)
    New-Node 'primary' $false
    Await 'primary-leader-before-baseline-creation' {
        $p = Http 'primary'
        if ($p.role -notin @('master','primary') -or $p.state -ne 'running') { return $false }
        return ((SQL 'primary' 5432 'SELECT NOT pg_is_in_recovery();' -AllowFailure).stdout.Trim() -eq 't')
    }
    $null = SQL 'primary' 5432 ([IO.File]::ReadAllText((Join-Path $source 'seed.sql')))
    $fixture = Fixture 'primary'
    if ($fixture.count -ne 100000 -or $fixture.replica) { throw 'Invalid primary fixture' }
    $script:fixtureHash=$fixture.hash
    New-Node 'base' $false
    Await 'baseline-replica' { Replica-Ready 'base' }
    # Validate using the same pinned image, with a run-specific transient container, no host tools.
    $null = Cmd -Argv @('run','--rm','--pull','never','--name',"$runId-proxy-check",'--network',$network,
        '--mount',"type=bind,source=$source/haproxy.cfg,target=/usr/local/etc/haproxy/haproxy.cfg,readonly",
        $ProxyImage,'haproxy','-c','-f','/usr/local/etc/haproxy/haproxy.cfg')
    $containers.Add($proxy)
    $null = Cmd -Argv @('run','-d','--pull','never','--name',$proxy,'--label',"phase4.run=$runId",
        '--network',$network,'--network-alias','proxy','--memory','128m',
        '--mount',"type=bind,source=$source/haproxy.cfg,target=/usr/local/etc/haproxy/haproxy.cfg,readonly",$ProxyImage)
    Await 'proxy-read-and-write-routes' {
        $w = SQL 'proxy' 5000 'SELECT NOT pg_is_in_recovery();' -AllowFailure
        $r = SQL 'proxy' 5001 'SELECT pg_is_in_recovery();' -AllowFailure
        return ($w.exit -eq 0 -and $r.exit -eq 0 -and $w.stdout.Trim() -eq 't' -and $r.stdout.Trim() -eq 't')
    } 30
    Write-Probe
    Snapshot 'initial-baseline' -RequireAgreement
    Start-Traffic 'low-baseline' 2
    $script:phase='low-baseline'; $script:phaseStarted=[DateTime]::UtcNow
    while (-not $script:finished) {
        Tick
        $metric = Measured-TPS
        Write-Probe
        Snapshot 'observation'
        Controller $metric
        Traffic-Driver
    }
    Stop-Traffic
    Write-Probe
    Await 'final-base-readiness' { Replica-Ready 'base' }
    Snapshot 'final-all-tokens-and-fixture-agree' -RequireAgreement
    $success=$true
    Event 'experiment-complete' @{active=0; tokens=$tokens.Count}
} catch {
    $failure = Redact ($_ | Out-String)
    Event 'failure' @{error=$failure; preservation='No database, proxy, etcd, network or volume cleanup on failure'}
} finally {
    try { Stop-Traffic } catch { $cleanupErrors.Add((Redact $_.Exception.Message)) }
    # On failure, archive live DB logs WITHOUT stopping database resources. Successful elastic archives are stopped/full.
    foreach ($name in $containers) {
        try {
            $present = Cmd -Argv @('inspect','--format','{{.Name}} {{json .State}}',$name) -AllowFailure
            if ($present.exit -eq 0) { Archive $name -PostgresLogs:($nodes.Contains($name)) }
        } catch { $cleanupErrors.Add((Redact $_.Exception.Message)) }
    }
    try {
        $inventory = @()
        foreach ($name in $containers) {
            $r = Cmd -Argv @('inspect','--format','{{.Name}} {{json .State}}',$name) -AllowFailure
            $inventory += @{name=$name; exit=$r.exit; state=$r.stdout; stderr=$r.stderr}
        }
        $volumeInventory = @()
        foreach ($volume in $volumes) {
            $r = Cmd -Argv @('volume','inspect','--format','{{.Name}} {{.Mountpoint}}',$volume) -AllowFailure
            $volumeInventory += @{name=$volume; exit=$r.exit; result=$r.stdout}
        }
        Save-Text (Join-Path $evidence 'resources.json') (@{network=$network; containers=$inventory; volumes=$volumeInventory} | ConvertTo-Json -Depth 20)
    } catch { $cleanupErrors.Add((Redact $_.Exception.Message)) }
    if ($cleanupErrors.Count -gt 0) { $success=$false }
    Save-Text (Join-Path $evidence 'result.json') (@{run=$runId; success=$success; failure=$failure;
        cleanupErrors=@($cleanupErrors); finalElasticCount=$active.Count; tokens=@($tokens);
        baseline=@($primary,"$runId-base","$runId-etcd",$proxy); network=$network;
        preservation='Baseline remains running on success; elastic containers removed without -v; volumes and stopped traffic containers retained. On failure DB resources remain in their last state, including drained/maintenance slots.';
        credentials='Random credentials held only in this process and Docker metadata; not persisted in evidence. Local trust permits later docker exec psql as postgres.'
    } | ConvertTo-Json -Depth 20)
    # Final exact-secret scrub includes any partially copied log files. Manifest excludes itself.
    Redact-Tree $evidence
    $manifest = @(Get-ChildItem -LiteralPath $evidence -File -Recurse | Where-Object Name -NE 'manifest.json' | ForEach-Object {
        @{path=[IO.Path]::GetRelativePath($evidence,$_.FullName).Replace('\','/'); bytes=$_.Length;
          sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}
    })
    Save-Text (Join-Path $evidence 'manifest.json') ($manifest | ConvertTo-Json -Depth 5)
    Write-Host "Evidence: $evidence"
    Write-Host "Baseline names: $primary, $runId-base, $runId-etcd, $proxy"
}
if (-not $success) { throw "Phase4 demo failed or evidence capture was incomplete. Review $evidence/result.json; resources preserved." }
Write-Host 'Phase4 demo completed; four elastic volumes retained, baseline running.'