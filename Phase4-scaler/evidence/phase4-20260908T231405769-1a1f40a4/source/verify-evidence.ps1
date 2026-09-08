#Requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$EvidencePath, [switch]$Live, [string]$ReportPath)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$EvidencePath=(Resolve-Path -LiteralPath $EvidencePath).Path
function Read-JsonLines([string]$Name) {
    @(Get-Content -LiteralPath (Join-Path $EvidencePath "$Name.jsonl") | ForEach-Object { $_ | ConvertFrom-Json })
}
function Assert([bool]$Test,[string]$Message) { if (-not $Test) { throw $Message } }
$result=Get-Content -Raw (Join-Path $EvidencePath 'result.json') | ConvertFrom-Json
$manifest=@(Get-Content -Raw (Join-Path $EvidencePath 'manifest.json') | ConvertFrom-Json)
foreach ($entry in $manifest) {
    $path=Join-Path $EvidencePath $entry.path
    Assert (Test-Path -LiteralPath $path -PathType Leaf) "Missing artifact: $($entry.path)"
    Assert ((Get-Item -LiteralPath $path).Length -eq $entry.bytes) "Length mismatch: $($entry.path)"
    Assert ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq $entry.sha256) "Hash mismatch: $($entry.path)"
    # Runner credentials are exactly 48 hex characters. Do not print any matching content.
    Assert (-not [regex]::IsMatch([IO.File]::ReadAllText($path),'(?<![A-Za-z0-9])[A-F0-9]{48}(?![A-Za-z0-9])')) "Possible unredacted credential: $($entry.path)"
}
$files=@(Get-ChildItem -LiteralPath $EvidencePath -File -Recurse | Where-Object Name -NE 'manifest.json')
Assert ($files.Count -eq $manifest.Count) 'Unmanifested evidence files'
Assert $result.success 'Run reported failure; manifest verified but scaling is not successful'
$events=Read-JsonLines 'events'
$metrics=Read-JsonLines 'metrics'
$decisions=Read-JsonLines 'decisions'
$snapshots=Read-JsonLines 'snapshots'
$commands=Read-JsonLines 'commands'
$out=@($events | Where-Object kind -EQ 'elastic-admitted')
$in=@($events | Where-Object kind -EQ 'elastic-removed')
Assert ($out.Count -eq 4 -and $in.Count -eq 4 -and $result.finalElasticCount -eq 0) 'Incomplete scaling cycle'
Assert (@($metrics | Where-Object { $_.active -lt 0 -or $_.active -gt 4 }).Count -eq 0) 'Scaling bounds violated'
$actions=@($events | Where-Object kind -EQ 'decision')
$timings=@(foreach ($action in $actions) {
    $d=@($decisions | Where-Object { [datetime]$_.utc -le [datetime]$action.utc })[-1]
    $isOut=$action.data.action -eq 'out'
    Assert ($d.cooldownSatisfied -and (($isOut -and $d.measuredTPS -gt 20 -and $d.highSamples -ge 2) -or
        (-not $isOut -and $d.measuredTPS -lt 5 -and $d.lowSamples -ge 2))) 'Action lacks measured threshold/cooldown evidence'
    $kind=if ($isOut) {'elastic-admitted'} else {'elastic-removed'}
    $end=@($events | Where-Object { $_.kind -eq $kind -and $_.data.slot -eq $action.data.slot })[0]
    [pscustomobject]@{action=$action.data.action; slot=$action.data.slot; decisionUTC=$action.utc;
        completedUTC=$end.utc; measuredTPS=$d.measuredTPS; seconds=[math]::Round(([datetime]$end.utc-[datetime]$action.utc).TotalSeconds,3)}
})
$peak=@($snapshots | Where-Object label -EQ 'four-active-steady-end')[0]
$final=@($snapshots | Where-Object label -EQ 'final-all-tokens-and-fixture-agree')[0]
Assert ($peak.elasticCount -eq 4 -and $peak.roles.members.Count -eq 6) 'Six-node peak topology missing'
$served=@($peak.routing | Where-Object { $_.pxname -eq 'replicas' -and $_.svname -in @('base','elastic1','elastic2','elastic3','elastic4') })
Assert ($served.Count -eq 5 -and @($served | Where-Object { $_.status -ne 'UP' -or [long]$_.stot -lt 1 }).Count -eq 0) 'Not all replicas served traffic'
Assert ($final.primary.count -eq 100000 -and $final.replicas.base.count -eq 100000 -and
    $final.primary.hash -eq $final.replicas.base.hash -and -not $final.primary.replica -and $final.replicas.base.replica) 'Final fixture/role mismatch'
$expected=($result.tokens | Sort-Object) -join ','
Assert ((($final.primary.tokens | Sort-Object) -join ',') -eq $expected -and
    (($final.replicas.base.tokens | Sort-Object) -join ',') -eq $expected) 'Final acknowledged tokens disagree'
foreach ($slot in 1..4) {
    $alias="elastic$slot"
    Assert (@($events | Where-Object { $_.kind -eq 'ready' -and $_.data.check -eq "drained-$alias" }).Count -eq 1) "Missing drain evidence: $alias"
    $row=@($final.routing | Where-Object { $_.pxname -eq 'replicas' -and $_.svname -eq $alias })[0]
    Assert ($row.status -eq 'MAINT' -and [int]$row.scur -eq 0) "Removed slot not safely maintained: $alias"
}
$traffic=@(foreach ($dir in Get-ChildItem (Join-Path $EvidencePath 'traffic') -Directory) {
    $count=0; $invalid=0; $min=[double]::PositiveInfinity; $max=0.0; $latency=0.0
    foreach ($file in Get-ChildItem $dir.FullName -Filter 'tx.*' -File) {
        foreach ($line in [IO.File]::ReadLines($file.FullName)) {
            $p=$line -split '\s+'
            if ($p.Count -lt 6 -or $p[2] -notmatch '^\d+$') { $invalid++; continue }
            $ts=[double]$p[4]+[double]$p[5]/1000000
            $min=[math]::Min($min,$ts); $max=[math]::Max($max,$ts); $count++; $latency += [double]$p[2]/1000
        }
    }
    Assert ($count -gt 0 -and $invalid -eq 0) "Missing/failed transaction records: $($dir.Name)"
    [pscustomobject]@{stage=$dir.Name; transactions=$count; invalid=$invalid;
        observedSpanSeconds=[math]::Round($max-$min,3); meanLatencyMs=[math]::Round($latency/$count,3)}
})
$clientErrors=@(foreach ($c in $commands | Where-Object { $_.args[0] -eq 'logs' -and $_.args[-1] -match '-traffic-' }) {
    foreach ($match in [regex]::Matches(($c.stdout+$c.stderr),'(?im)^.*(?:error:|fatal:|client \d+ aborted|could not connect|connection to server.*failed).*$')) { $match.Value }
})
Assert ($clientErrors.Count -eq 0) 'Client error signatures found in archived logs'
$slotVerification = [pscustomobject]@{status='unavailable/not verified (historical evidence)'; removed=$null; physicalDiskReclamationVerified=$false}
if ($null -ne $result.PSObject.Properties['slotEvidenceVersion']) {
    Assert ($result.slotEvidenceVersion -eq 1) 'Unknown slot evidence schema'
    . (Join-Path $PSScriptRoot 'verify-slot-evidence.ps1')
    $slotVerification = Verify-SlotEvidence $result (Read-JsonLines 'slot-samples') (Read-JsonLines 'sql') $commands $snapshots $events
}
$summary=[ordered]@{run=$result.run; verifiedUTC=[datetime]::UtcNow.ToString('o'); manifestFiles=$manifest.Count;
    slotVerification=$slotVerification;
    clientErrorSignatures=$clientErrors.Count;
    evidenceBytes=($files | Measure-Object Length -Sum).Sum; admitted=4; removed=4; peakDatabaseNodes=6;
    finalDatabaseNodes=2; acknowledgedTokens=$result.tokens.Count; fixtureRows=100000; fixtureHash=$final.primary.hash;
    actions=$timings; traffic=$traffic; peakRouting=@($served | Select-Object svname,status,stot,econ,eresp);
    recordedCommands=$commands.Count; nonzeroCommands=@($commands | Where-Object exit -NE 0).Count;
    commandTimeouts=@($commands | Where-Object timeout).Count;
    durationSeconds=[math]::Round(([datetime](@($events | Where-Object kind -EQ 'experiment-complete')[0].utc)-[datetime]$events[0].utc).TotalSeconds,3)}
if ($Live) {
    # Docker configuration must be checked by the caller before requesting live verification.
    $liveCommands=[Collections.Generic.List[object]]::new()
    function Docker-Check([string[]]$Argv) {
        $start=[datetime]::UtcNow
        $watch=[Diagnostics.Stopwatch]::StartNew()
        $text=(& docker @Argv 2>&1 | Out-String)
        $code=$LASTEXITCODE
        $liveCommands.Add(@{utc=$start.ToString('o'); args=$Argv; output=$text; exit=$code; durationMs=$watch.ElapsedMilliseconds})
        Assert ($code -eq 0) 'Live Docker verification failed'
        return $text
    }
    $inventory=(Docker-Check @('ps','-a','--filter',"label=phase4.run=$($result.run)",'--format','{{json .}}')) -split "`n" |
        Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json }
    Assert (@($inventory | Where-Object Names -Match '-elastic[1-4]$').Count -eq 0) 'Elastic container still exists'
    foreach ($name in $result.baseline) {
        $state=(Docker-Check @('inspect','--format','{{json .State}}',$name)) | ConvertFrom-Json
        Assert ($state.Running -and -not $state.OOMKilled) "Baseline not running: $name"
    }
    foreach ($slot in 1..4) { $null=Docker-Check @('volume','inspect','--format','{{.Name}}',"$($result.run)-elastic$slot-data") }
    foreach ($node in @('primary','base')) {
        $q="SELECT json_build_object('replica',pg_is_in_recovery(),'rows',(SELECT count(*) FROM phase4_lab.items),'events',(SELECT count(*) FROM phase4_lab.events));"
        $data=(Docker-Check @('exec',"$($result.run)-$node",'psql','-X','-A','-t','-U','postgres','-d','postgres','-c',$q)) | ConvertFrom-Json
        Assert ($data.rows -eq 100000 -and $data.events -eq $result.tokens.Count -and $data.replica -eq ($node -eq 'base')) 'Live SQL disagreement'
    }
    foreach ($client in @($inventory | Where-Object Names -Match '-traffic-')) {
        $state=(Docker-Check @('inspect','--format','{{json .State}}',$client.Names)) | ConvertFrom-Json
        Assert (-not $state.Running -and $state.ExitCode -eq 0 -and -not $state.OOMKilled) 'Traffic did not finish cleanly'
    }
    $summary.liveCommands=$liveCommands.ToArray()
}
$reportDir=Join-Path $PSScriptRoot 'reports'
[void][IO.Directory]::CreateDirectory($reportDir)
if (-not $ReportPath) {
    # Never overwrite the original historical report when adding this explicitly unverified slot status.
    $suffix = if ($null -eq $result.PSObject.Properties['slotEvidenceVersion']) { '-slot-audit' } else { '' }
    $ReportPath = Join-Path $reportDir "$($result.run)$suffix.json"
}
$summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ReportPath -Encoding utf8
$summary | ConvertTo-Json -Depth 12
