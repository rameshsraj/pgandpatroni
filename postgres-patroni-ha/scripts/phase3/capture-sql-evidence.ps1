#requires -Version 7.2
<# Preserve retained evidence without rerunning SQL or changing cluster state.
   Raw server logs can contain sensitive data: output remains Git-ignored.
   This is a point-in-time capture, not a guarantee of historical completeness. #>
[CmdletBinding()]
param([switch]$IncludeRetainedServerLogs,
    [string]$CaptureId = (Get-Date -AsUTC -Format 'yyyyMMddTHHmmssZ'))
$ErrorActionPreference = 'Stop'
if ($CaptureId -notmatch '^[A-Za-z0-9_-]+$') { throw 'Unsafe CaptureId' }
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$out = Join-Path $root "test-results/sql-capture/$CaptureId"
if (Test-Path $out) { throw "Capture already exists: $out" }
New-Item -ItemType Directory $out | Out-Null
$secrets = @(Get-Content "$root/.env" | ForEach-Object {
    if ($_ -match '^[A-Z_]*PASSWORD=(.*)$') { $matches[1].Trim('"', "'") }
} | Where-Object { $_ })
function Redact([string]$text) {
    foreach ($secret in $secrets) { $text = $text.Replace($secret, '[REDACTED]') }
    return $text
}
function JsonLine([string]$path, $value) {
    Redact ($value | ConvertTo-Json -Depth 15 -Compress) | Add-Content $path -Encoding utf8
}
$index = [System.Collections.Generic.List[object]]::new()
# Preserve whole records, including multiline SQL, errors and output. Do not
# split SQL on semicolons or deduplicate repeated executions.
foreach ($file in Get-ChildItem "$root/test-results/phase3" -Recurse -File) {
    $relative = [IO.Path]::GetRelativePath("$root/test-results/phase3", $file.FullName)
    if ($file.Name -in @('commands.jsonl','post-benchmark-healthcheck.jsonl') -or
        $relative -match '[/\\]commands[/\\].*\.txt$' -or $file.Name -eq 'client.log') {
        $destination = Join-Path "$out/historical" $relative
        New-Item -ItemType Directory (Split-Path $destination) -Force | Out-Null
        Redact ([IO.File]::ReadAllText($file.FullName)) | Set-Content $destination -Encoding utf8
        $index.Add(@{kind='historical-record';source=$relative;file=[IO.Path]::GetRelativePath($out,$destination)})
        if ($file.Extension -eq '.jsonl') {
            foreach ($line in Get-Content $file.FullName) {
                $record = $line | ConvertFrom-Json
                JsonLine "$out/all-commands.jsonl" @{source=$relative;record=$record}
                if ($record.command -match '\bpsql\b') {
                    # Full invocation plus stdin is authoritative; this is an
                    # attempted SQL command, not proof it committed.
                    JsonLine "$out/sql-command-records.jsonl" @{source=$relative;record=$record}
                }
            }
        }
    }
}
if ($IncludeRetainedServerLogs) {
    foreach ($node in @('pg-node-1','pg-node-2','pg-node-3','pg-node-4','pg-node-5')) {
        $destination = "$out/server/$node"
        New-Item -ItemType Directory $destination -Force | Out-Null
        $arguments = @('cp',"${node}:/var/lib/postgresql/data/pgdata/pg_log/.",$destination)
        $start = [DateTime]::UtcNow.ToString('o')
        $response = & docker @arguments 2>&1 | Out-String
        $code = $LASTEXITCODE
        JsonLine "$out/collection-commands.jsonl" @{start=$start;end=[DateTime]::UtcNow.ToString('o');arguments=$arguments;exit=$code;output=(Redact $response)}
        $index.Add(@{kind='retained-server-logs';node=$node;exit=$code;file="server/$node"})
        foreach ($file in Get-ChildItem $destination -Recurse -File) {
            $text = [IO.File]::ReadAllText($file.FullName)
            [IO.File]::WriteAllText($file.FullName, (Redact $text))
        }
    }
}
$index | ConvertTo-Json -Depth 10 | Set-Content "$out/index.json"
@'
# SQL evidence capture

- historical/: full archived command outputs and pgbench client traces, retaining multiline queries.
- all-commands.jsonl: main command records AND separate post-benchmark maintenance records.
- sql-command-records.jsonl: psql invocations, SQL stdin, timestamps, exit status and original output references (relative to each source run).
- server/: all currently retained PostgreSQL log files, including the stopped elastic node, when requested.
- collection-commands.jsonl: collection times, commands and failures; nonzero exit means missing coverage.
- index.json and SHA256SUMS.csv: source inventory and capture integrity.

No SQL was replayed. Attempted statements are not proof of successful commit.
Client traces contain expanded pgbench SQL; transaction timing logs alone do not.
Server logs are retained text, not a deduplicated query count. Multiline records are preserved.
Collection of live files is not atomic; buffered statements or later writes may be absent.
Rotated/deleted logs and commands never recorded cannot be reconstructed.
Known configured passwords are redacted; other sensitive SQL literals may remain.
This directory is intentionally Git-ignored. Store it in an access-controlled evidence archive.
'@ | Set-Content "$out/README.md"
Get-ChildItem $out -Recurse -File | Where-Object Name -NE 'SHA256SUMS.csv' | ForEach-Object {
    [pscustomobject]@{file=[IO.Path]::GetRelativePath($out,$_.FullName);sha256=(Get-FileHash $_.FullName -Algorithm SHA256).Hash;bytes=$_.Length}
} | Export-Csv "$out/SHA256SUMS.csv" -NoTypeInformation
Write-Host "SQL evidence captured: $out"