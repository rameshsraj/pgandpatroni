#requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$EvidencePath, [switch]$CheckLive)
$ErrorActionPreference='Stop'
$dir=(Resolve-Path $EvidencePath).Path
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$secrets=@(Get-Content "$root/.env" | Where-Object { $_ -match '^\w*PASSWORD=' } | ForEach-Object { ($_ -split '=',2)[1].Trim('"',"'") })
function Clean([string]$text) { foreach($s in $secrets) { if($s){$text=$text.Replace($s,'[REDACTED]')} }; return $text }
function Capture([string[]]$Arguments) {
    $start=[DateTime]::UtcNow
    $output=(& docker @Arguments 2>&1 | Out-String)
    $exit=$LASTEXITCODE
    @{start=$start.ToString('o');end=[DateTime]::UtcNow.ToString('o');
        command=('docker '+(($Arguments | ForEach-Object { '"'+$_+'"' }) -join ' '));exit=$exit;output=(Clean $output)} |
        ConvertTo-Json -Depth 10 -Compress | Add-Content "$dir/live-verification.jsonl"
    if($exit){throw 'Live verification command failed; see live-verification.jsonl'}
    return $output
}
if($CheckLive) {
    Push-Location $root
    try {
        [void](Capture @('compose','--profile','elastic','ps','-a'))
        $cluster=@((Capture @('exec','pg-node-1','patronictl','-c','/etc/patroni/patroni.yml','list','-f','json')) | ConvertFrom-Json)
        if($cluster.Count -ne 4 -or @($cluster | Where-Object Role -EQ 'Leader').Count -ne 1 -or @($cluster | Where-Object State -EQ 'streaming').Count -ne 3) {
            throw 'Live topology is not one primary plus three streaming replicas'
        }
        [void](Capture @('exec','etcd','etcdctl','endpoint','health','--endpoints=http://localhost:2379'))
        [void](Capture @('inspect','--format','{{.Name}} status={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{end}} restarts={{.RestartCount}} stopSignal={{.Config.StopSignal}}','pg-node-1','pg-node-2','pg-node-3','pg-node-4','pg-node-5','haproxy','etcd'))
        $stateText=Capture @('inspect','--format','{{json .State}}','pg-node-1','pg-node-2','pg-node-3','pg-node-4','haproxy','etcd')
        $states=@($stateText -split '\r?\n' | Where-Object { $_.Trim().StartsWith('{') } | ForEach-Object { $_ | ConvertFrom-Json })
        if($states.Count -ne 6 -or @($states | Where-Object { -not $_.Running -or $_.Health.Status -ne 'healthy' }).Count) {
            throw 'An active service is unhealthy; do not report final live verification success'
        }
        foreach($n in 1..4) {
            $q="SELECT json_build_object('node','pg-node-$n','replica',pg_is_in_recovery(),'items',(SELECT count(*) FROM phase3_lab.items),'events',(SELECT count(*) FROM phase3_lab.events),'customers',(SELECT count(*) FROM customers),'orders',(SELECT count(*) FROM orders),'ha_test',(SELECT count(*) FROM ha_test));"
            [void](Capture @('exec',"pg-node-$n",'psql','-X','-A','-t','-v','ON_ERROR_STOP=1','-U','postgres','-d','appdb','-c',$q))
        }
        [void](Capture @('exec','haproxy','sh','-c',"printf 'show stat\n' | nc -w 2 127.0.0.1 9999"))
        [void](Capture @('compose','--profile','elastic','config','--quiet'))
        [void](Capture @('exec','haproxy','haproxy','-c','-f','/usr/local/etc/haproxy/haproxy.cfg'))
    } finally { Pop-Location }
}
# Refuse to publish newly captured lab credentials. Print only counts/file names.
$leaks=[System.Collections.Generic.List[string]]::new()
foreach($file in Get-ChildItem $dir -Recurse -File) {
    foreach($line in [System.IO.File]::ReadLines($file.FullName)) {
        if(@($secrets | Where-Object { $_ -and $line.Contains($_) }).Count) { $leaks.Add($file.FullName); break }
    }
}
if($leaks.Count){throw "Credential scan failed in $($leaks.Count) files; values not displayed"}
$commands=@(Get-Content "$dir/commands.jsonl" | ForEach-Object { $_ | ConvertFrom-Json })
foreach($c in $commands){if(-not(Test-Path "$dir/$($c.output)")){throw "Missing raw output $($c.output)"}}
$final=@(Get-Content "$dir/11-final/row-counts.json" -Raw | ConvertFrom-Json | Where-Object {-not $_.unavailable})
$acks=@(Get-Content "$dir/acknowledged-write-validation.json" -Raw | ConvertFrom-Json)
if($final.Count -ne 4 -or @($final.items_hash | Select-Object -Unique).Count -ne 1 -or @($final.events_hash | Select-Object -Unique).Count -ne 1 -or @($acks | Where-Object {$_.missing.Count}).Count){throw 'Data validation failed'}
$failures=@($commands | Where-Object exit -NE 0)
$errors=foreach($f in Get-ChildItem $dir -Recurse -Filter '*.log') {
    $patterns='pgbench: error:|ConnectionResetError|WARNING:|ERROR:|FATAL:'
    foreach($m in Select-String -Path $f.FullName -Pattern $patterns){[pscustomobject]@{file=$f.FullName.Substring($dir.Length+1);line=$m.LineNumber;message=(Clean $m.Line)}}
}
$errors | Export-Csv "$dir/client-warning-index.csv" -NoTypeInformation
$serverWarnings=foreach($f in Get-ChildItem "$dir/commands" -Filter '*.txt') {
    foreach($m in Select-String -Path $f.FullName -Pattern 'WARNING:|ERROR:|FATAL:|\[WARNING\]|\[ALERT\]|ConnectionResetError|Health check exceeded timeout') {
        [pscustomobject]@{file="commands/$($f.Name)";line=$m.LineNumber;message=(Clean $m.Line)}
    }
}
$serverWarnings | Export-Csv "$dir/server-warning-index.csv" -NoTypeInformation
$summary=@{utc=[DateTime]::UtcNow.ToString('o');rawCommandOutputs=$commands.Count;nonzeroCommands=$failures.Count;
    credentialLeaks=0;onlineNodeFingerprintsMatch=$true;acknowledgedTokens=$acks[0].acknowledged;
    missingAcknowledgedTokens=0;liveChecked=[bool]$CheckLive;note='Expected nonzero commands include observing absent/killed/scaled-in nodes; examine nonzero-commands.csv and raw outputs.'}
$summary | ConvertTo-Json | Set-Content "$dir/verification.json"
Copy-Item $PSCommandPath "$dir/source/verify-evidence.ps1" -Force
$manifest=foreach($f in Get-ChildItem $dir -Recurse -File | Where-Object Name -NE 'SHA256SUMS.csv') {
    [pscustomobject]@{path=$f.FullName.Substring($dir.Length+1).Replace('\','/');bytes=$f.Length;sha256=(Get-FileHash $f.FullName -Algorithm SHA256).Hash}
}
$manifest | Export-Csv "$dir/SHA256SUMS.csv" -NoTypeInformation
$summary | ConvertTo-Json