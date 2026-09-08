#Requires -Version 7.2
# Offline tests only: NEVER dot-source the runner, start Docker, or execute a lab.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot 'run-lab.ps1'
$t = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path,[ref]$t,[ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
$functions = $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)
foreach ($name in @('Controller','Measured-TPS','Redact','Save-Text','Record','Cmd')) {
    $text = ($functions | Where-Object Name -EQ $name).Extent.Text
    Assert (-not [string]::IsNullOrEmpty($text)) "Missing function $name"
    if ($name -eq 'Cmd') {
        # ONLY the extracted process wrapper is tested, replacing the executable with this pwsh.
        Assert ($text.Contains("FileName = 'docker'")) 'Cannot safely replace process test executable'
        $text = $text.Replace("FileName = 'docker'", 'FileName = (Get-Process -Id $PID).Path')
    }
    . ([scriptblock]::Create($text))
}
$source = [IO.File]::ReadAllText($path)
Assert ($source -notmatch '(?im)^\s*(Start-Sleep|sleep|timeout)\b') 'Artificial sleep in runner'
Assert ($source -notmatch "'compose'|'--env-file'|'--publish'|'--publish-all'") 'Unexpected shared infrastructure or plaintext env source'
$template = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'patroni-template.yml'))
$entrypoint = [IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot -Parent) 'postgres-patroni-ha/patroni/entrypoint.sh'))
foreach ($placeholder in [regex]::Matches($template,'[A-Z_]+PLACEHOLDER').Value | Select-Object -Unique) {
    Assert ($entrypoint.Contains($placeholder)) "Unsupported template placeholder $placeholder"
}
$haproxy = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'haproxy.cfg'))
Assert (([regex]::Matches($haproxy,'server elastic[1-4] 127.0.0.1:5432 disabled check port 8008')).Count -eq 4) 'Invalid elastic slots'
$trafficSource = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'traffic.sh'))
Assert ($trafficSource.Contains('--debug') -and $trafficSource -notmatch '\s-d\s') 'Ambiguous pgbench database/debug flag'
Assert ($trafficSource.Contains("trap 'stop=1' TERM INT") -and $trafficSource.Contains('segment=10') -and
    -not $trafficSource.Contains('exec pgbench')) 'Traffic shutdown must finish a bounded foreground batch'
Assert ($source.Contains('.TrimEnd("`n") + "`n"')) 'Captured HAProxy config must end with LF'

$evidence = Join-Path ([IO.Path]::GetTempPath()) ('phase4-static-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($evidence)
$utf8 = [Text.UTF8Encoding]::new($false)
$secrets = @('TESTSECRETABC123')
$script:commandSequence=0
$CommandTimeoutSeconds=10
$CooldownSeconds=15
$script:highSamples=0; $script:lowSamples=0; $script:lastDecision=[DateTime]::MinValue
$active = [Collections.Generic.List[string]]::new()
$script:actions = [Collections.Generic.List[string]]::new()
function Add-Elastic { $active.Add("elastic$($active.Count+1)"); $script:actions.Add('out') }
function Remove-Elastic { $active.RemoveAt($active.Count-1); $script:actions.Add('in') }
try {
    Controller @{tps=20}
    Controller @{tps=100}
    Assert ($active.Count -eq 0) 'One high sample incorrectly scales'
    Controller @{tps=100}
    Assert ($active.Count -eq 1) 'Two high samples must scale'
    Controller @{tps=100}; Controller @{tps=100}
    Assert ($active.Count -eq 1) 'Cooldown did not suppress hot decisions'
    foreach ($i in 2..4) {
        $script:lastDecision=[DateTime]::MinValue
        Controller @{tps=100}; Controller @{tps=100}
    }
    Assert ($active.Count -eq 4) 'Four sequential scale-outs failed'
    $script:lastDecision=[DateTime]::MinValue
    Controller @{tps=100}; Controller @{tps=100}
    Assert ($active.Count -eq 4) 'Exceeded four slots'
    Controller @{tps=5}; Controller @{tps=5}
    Assert ($active.Count -eq 4) 'Thresholds must be strict'
    foreach ($i in 1..4) {
        $script:lastDecision=[DateTime]::MinValue
        Controller @{tps=2}; Controller @{tps=2}
    }
    $script:lastDecision=[DateTime]::MinValue
    Controller @{tps=0}; Controller @{tps=0}
    Assert ($active.Count -eq 0 -and $script:actions.Count -eq 8) 'Scale-in crossed baseline or missed removals'

    # Reproduce a concurrently open bind-mounted transaction log with native six/seven-field rows.
    $script:trafficDir=$evidence
    $log = Join-Path $evidence 'tx.1234'
    $stream = [IO.File]::Open($log,[IO.FileMode]::Create,[IO.FileAccess]::Write,
        ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    $writer = [IO.StreamWriter]::new($stream,$utf8)
    try {
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        foreach ($i in 1..250) { $writer.WriteLine("0 $i 1200 0 $($now-5) 123456 20") }
        $writer.WriteLine("0 251 failed 0 $($now-5) 123456 20")
        $writer.WriteLine("0 252 1000 0 $($now-100) 123456 20")
        $writer.WriteLine('incomplete')
        $writer.Flush()
        $metric=Measured-TPS
        Assert ($metric.completed -eq 250 -and $metric.tps -eq 25 -and $metric.ignoredRecords -eq 2) 'Transaction parsing/window/share-mode regression'
    } finally { $writer.Dispose() }

    # Large writes to BOTH pipes verify async drain, stdin capture, exit handling and redaction.
    $r = Cmd -Argv @('-NoProfile','-Command', '[Console]::Out.Write([Console]::In.ReadToEnd()); [Console]::Error.Write("e" * 100000); [Console]::Out.Write("x" * 100000); exit 7') -InputText 'TESTSECRETABC123' -AllowFailure
    Assert ($r.exit -eq 7 -and $r.stdout.Length -gt 100000 -and $r.stderr.Length -ge 100000) 'Concurrent pipe/exit capture failed'
    $commandLog = [IO.File]::ReadAllText((Join-Path $evidence 'commands.jsonl'))
    Assert (-not $commandLog.Contains($secrets[0]) -and $commandLog.Contains('[REDACTED]')) 'Evidence contains plaintext test secret'
    # No sleep: this child prints once and computes until the wrapper enforces its deadline.
    $r = Cmd -Argv @('-NoProfile','-Command','[Console]::Out.WriteLine("partial-evidence"); [Console]::Out.Flush(); while ($true) { $n = 1 + 1 }') -TimeoutSeconds 2 -AllowFailure
    Assert ($r.timeout -and $r.stdout.Contains('partial-evidence')) 'Timeout did not retain partial stdout'
    . ([scriptblock]::Create(($functions | Where-Object Name -EQ 'Runtime').Extent.Text))
    $proxy='test-proxy'
    $script:runtimeReply="IP changed from '127.0.0.1' to '172.21.0.7', no need to change the port by 'stats socket command'`n"
    function Cmd { param($Argv,$InputText) return @{stdout=$script:runtimeReply} }
    $null = Runtime 'set server replicas/elastic1 addr 172.21.0.7 port 5432'
    $script:runtimeReply='No such server.'
    $rejected=$false
    try { $null = Runtime 'set server replicas/elastic1 state ready' } catch { $rejected=$true }
    Assert $rejected 'Runtime errors must not be treated as acknowledgements'
    'PASS: syntax, placeholders, config invariants, policy hysteresis/cooldown/bounds, native TPS/shared readers, concurrent pipes, redaction and timeout partial capture. No Docker or lab executed.'
} finally {
    # Only this test-generated temporary directory is removed.
    Remove-Item -LiteralPath $evidence -Recurse -Force
}