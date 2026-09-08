#Requires -Version 7.2
param([string]$EvidencePath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
foreach ($file in @('run-lab.ps1','slot-observation.ps1','verify-evidence.ps1','verify-slot-evidence.ps1')) {
    $t=$null; $e=$null
    $null=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $file),[ref]$t,[ref]$e)
    if ($e.Count) { throw ($e | Out-String) }
}
. (Join-Path $PSScriptRoot 'slot-observation.ps1')
function Assert([bool]$Ok,[string]$Message) { if (-not $Ok) { throw $Message } }
$script:tests=0
function Reject([scriptblock]$Action,[string]$Pattern) {
    $caught=$null
    try { & $Action } catch { $caught=$_.Exception.Message }
    Assert ($null -ne $caught -and $caught -match $Pattern) "Expected rejection /$Pattern/, got: $caught"
    $script:tests++
}
$runId='test-run'; $primary='test-run-primary'
$script:slotPrimaryIdentity=$null; $script:slotMappings=[ordered]@{}
function HealthySample {
    $rest=[pscustomobject]@{role='primary';state='running';timeline=1;patroni=@{name=$primary}}
    $r=[pscustomobject]@{role='replica';state='running';patroni=@{name='test-run-base'}}
    return [ordered]@{primaryHost=$primary; before=$rest;after=$rest;
        primary=[pscustomobject]@{replica=$false;systemIdentifier='123';server='172.1.0.2';timeline=1;postmasterStarted='2026-09-09T00:00:00Z';
            slots=@([pscustomobject]@{slot_name='actual_name_not_assumed';slot_type='physical';active=$true;active_pid=10;safe_wal_size=$null});
            senders=@([pscustomobject]@{pid=10;application_name='test-run-base';state='streaming';client_addr='172.1.0.3'})};
        replicas=@{base=@{rest=$r; rows=@{replica=$true;server='172.1.0.3';receivers=@(@{status='streaming';slot_name='actual_name_not_assumed';received_tli=1;sender_host=$primary})}}};
        cluster=@{members=@(@{name='test-run-base';role='replica';state='streaming';lag=0})}}
}
$s=HealthySample
$s.replicas.base.rows.receivers[0].sender_host=$primary.ToUpperInvariant() # DNS is case-insensitive; slot/member matching is not.
Assert-SlotState $s @('base')
Assert ($script:slotMappings.base -ceq 'actual_name_not_assumed') 'Mapping must come from SQL, not hyphen normalization'
$script:tests++
$s=HealthySample; $s.primary.slots[0].active=$null
Reject { Assert-SlotState $s @('base') } 'correlation failed'
$s=HealthySample; $s.primary.senders[0].application_name='some-other-member'
Reject { Assert-SlotState $s @('base') } 'No unique streaming sender'
$s=HealthySample; $s.replicas.base.rows.receivers[0].slot_name='wrong-slot'
Reject { Assert-SlotState $s @('base') } 'correlation failed'
$s=HealthySample; $s.cluster.members[0].lag=$null
Reject { Assert-SlotState $s @('base') } 'correlation failed'
$s=HealthySample; $s.primary.systemIdentifier='changed'
Reject { Assert-SlotState $s @('base') } 'Primary changed'
$s=HealthySample; $s.primary.replica=$true
Reject { Assert-SlotState $s @('base') } 'identity/role/timeline'
# A real capture function with mocked network I/O must record failure, not empty slot success.
$script:slotSequence=0; $script:captured=$null
function Http { param($Alias,$Path) return @{members=@(@{name=$primary;role='leader'})} }
function SQL { param($HostName,$Port,$Text) throw 'synthetic SQL timeout' }
function Record { param($File,$Data) $script:captured=$Data }
Reject { $null=Slot-Snapshot 'post-remove' 'elastic1' } 'synthetic SQL timeout'
Assert ($script:captured.valid -ceq $false -and $script:captured.error -match 'timeout' -and $null -eq $script:captured.primary) 'Failed query must remain unknown'
function Outcome {
    return [ordered]@{alias='elastic1';slotName='exact-slot';removeCompletedUTC=[datetime]::UtcNow.ToString('o');stopCompletedUTC=[datetime]::UtcNow.AddSeconds(-2).ToString('o');
        sampleIds=[Collections.Generic.List[int]]::new();slotAbsentVerified=$false;firstAbsentSample=$null;firstAbsentObservedUTC=$null;
        firstAbsentCompletedUTC=$null;secondsFromStopCompletion=$null;secondsFromRemovalCompletion=$null;lastPresentSample=$null;error=$null}
}
$SlotAbsenceTimeoutSeconds=120
$script:mode='absent'; $script:calls=0; $script:ticks=0
function Tick { $script:ticks++ }
function Slot-Snapshot {
    param($Stage,$Target)
    $script:calls++
    if ($script:mode -eq 'error') { throw 'synthetic observation SQL error' }
    $slots=if ($script:mode -eq 'present' -or $script:calls -eq 1) { @(@{slot_name='exact-slot'}) } else { @(@{slot_name='baseline'}) }
    $completed=if ($script:mode -eq 'present') { [datetime]::UtcNow.AddSeconds(121) } else { [datetime]::UtcNow }
    return @{id=$script:calls;completedUTC=$completed.ToString('o');primary=@{observedUTC=$completed.ToString('o');slots=$slots}}
}
$o=Outcome; Observe-SlotAbsence $o
Assert ($o.slotAbsentVerified -and $o.sampleIds.Count -eq 2 -and $script:ticks -eq 1) 'Must sample present then absent and perform useful observation'
$script:tests++
$script:mode='present'; $o=Outcome
Reject { Observe-SlotAbsence $o } 'timed out'
Assert (-not $o.slotAbsentVerified) 'Timeout falsely verified absence'
$script:mode='error'; $o=Outcome
Reject { Observe-SlotAbsence $o } 'SQL error'
Assert (-not $o.slotAbsentVerified) 'SQL error falsely verified absence'

if ($EvidencePath) {
    # Mutation tests are entirely in memory; no historical or new raw artifacts are edited.
    . (Join-Path $PSScriptRoot 'verify-slot-evidence.ps1')
    function Load([string]$Name) { @(Get-Content (Join-Path $EvidencePath "$Name.jsonl") | ForEach-Object { $_ | ConvertFrom-Json }) }
    $result=Get-Content -Raw (Join-Path $EvidencePath 'result.json') | ConvertFrom-Json
    $samples=Load 'slot-samples'; $sql=Load 'sql'; $commands=Load 'commands'; $snapshots=Load 'snapshots'; $events=Load 'events'
    function Verify { $null=Verify-SlotEvidence $result $samples $sql $commands $snapshots $events }
    Verify; $script:tests++
    $original=$samples
    $samples=@($original | Where-Object stage -NE 'pre-stop')
    Reject { Verify } 'Missing lifecycle sample'
    $samples=$original
    $samples[0].valid=$false
    Reject { Verify } 'Unknown/failed'
    $samples[0].valid=$true
    $samples[0].primary.slots[0].active=$false
    Reject { Verify } 'Returned rows differ'
    $samples[0].primary.slots[0].active=$true
    $originalSql=$sql
    $sql=@($sql | Where-Object command -NE $samples[0].primaryCommand)
    Reject { Verify } 'Missing SQL/command'
    $sql=$originalSql
    $q=@($sql | Where-Object command -EQ $samples[0].primaryCommand)[0]
    $q.exit=1
    Reject { Verify } 'SQL failed'
    $q.exit=0
    $originalTimeout=$result.slotOutcomes[0].timeoutSeconds
    $result.slotOutcomes[0].timeoutSeconds=0
    Reject { Verify } 'outside bounded window'
    $result.slotOutcomes[0].timeoutSeconds=$originalTimeout
    $originalToken=$snapshots[-1].primary.tokens[0]
    $snapshots[-1].primary.tokens[0]='missing-token'
    Reject { Verify } 'Primary data mismatch'
    $snapshots[-1].primary.tokens[0]=$originalToken
    $filtered=@($events | Where-Object { $_.kind -ne 'logs-archived' -or $_.data.name -ne "$($result.run)-primary" })
    $originalEvents=$events; $events=$filtered
    Reject { Verify } 'archive predates'
    $events=$originalEvents
    Verify
}
"PASS: $script:tests slot observation/mutation tests; no Docker, no host Python, no evidence changes."