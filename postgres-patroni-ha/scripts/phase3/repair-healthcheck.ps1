#requires -Version 7.2
# Post-benchmark deployment only. Kept separate from measured scenario timings.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$EvidencePath,[switch]$Deploy)
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$dir=(Resolve-Path $EvidencePath).Path
function Record([string[]]$Arguments) {
    $start=[DateTime]::UtcNow
    $output=(& docker @Arguments 2>&1 | Out-String)
    $code=$LASTEXITCODE
    @{start=$start.ToString('o');end=[DateTime]::UtcNow.ToString('o');
        command=('docker '+(($Arguments | ForEach-Object {'"'+$_+'"'}) -join ' '));exit=$code;output=$output} |
        ConvertTo-Json -Depth 10 -Compress | Add-Content "$dir/post-benchmark-healthcheck.jsonl"
    Write-Host $output
    if($code){throw 'Healthcheck diagnostic/deployment command failed'}
}
Push-Location $root
try {
    Record @('inspect','--format','{{json .State.Health}}','haproxy')
    Record @('exec','haproxy','sh','-c','command -v wget; wget -q -O /dev/null http://127.0.0.1:7000/')
    if($Deploy) {
        Record @('compose','config','--quiet')
        Record @('compose','up','-d','--no-deps','--no-build','--force-recreate','--wait','--wait-timeout','60','haproxy')
        Record @('compose','--profile','elastic','ps','-a')
        Record @('inspect','--format','{{json .State.Health}}','haproxy')
        Record @('exec','pg-node-1','bash','-c','PGPASSWORD="$POSTGRES_APP_PASSWORD" psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_APP_USER" -d "$POSTGRES_APP_DATABASE" -h haproxy -p 5000 -c "SELECT inet_server_addr(),pg_is_in_recovery(),count(*) FROM phase3_lab.items;"')
        Copy-Item "$root/docker-compose.yml" "$dir/source/docker-compose-post-benchmark-healthcheck.yml"
    }
    Copy-Item $PSCommandPath "$dir/source/repair-healthcheck.ps1"
} finally { Pop-Location }