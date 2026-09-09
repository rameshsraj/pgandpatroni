# Independent verifier: derives slot outcomes from raw SQL and command results, not runner flags.
function Verify-SlotEvidence($Result, $Samples, $Sql, $Commands, $Snapshots, $Events) {
    function Check([bool]$Ok, [string]$Why) { if (-not $Ok) { throw "Slot evidence: $Why" } }
    function Json($Value) { ConvertTo-Json -InputObject $Value -Depth 40 -Compress }
    function Fields($Object, [string[]]$Names) {
        foreach ($name in $Names) { Check ($null -ne $Object.PSObject.Properties[$name]) "Missing column $name (null must remain explicit)" }
    }
    function Returned($CommandId, $Rows, $Sample, [string]$View) {
        $q = @($Sql | Where-Object command -EQ $CommandId)
        $c = @($Commands | Where-Object id -EQ $CommandId)
        Check ($q.Count -eq 1 -and $c.Count -eq 1) "Missing SQL/command $CommandId"
        Check ($q[0].exit -eq 0 -and -not $q[0].timeout -and $c[0].exit -eq 0 -and -not $c[0].timeout) "SQL failed $CommandId"
        Check ($q[0].input -match $View -and $q[0].input -ceq $c[0].input -and $q[0].stdout -ceq $c[0].stdout) "Raw SQL chain broken $CommandId"
        Check ((Json ($q[0].stdout | ConvertFrom-Json)) -ceq (Json $Rows)) "Returned rows differ from sample $CommandId"
        Check ([datetime]$q[0].utc -ge [datetime]$Sample.startedUTC -and
            ([datetime]$q[0].utc).AddMilliseconds($q[0].durationMs) -le [datetime]$Sample.completedUTC) "SQL outside sample interval $CommandId"
        # ConvertFrom-Json can materialize offset dates as Local and Z dates as Utc.
        # DateTime comparisons otherwise compare wall-clock ticks, not the same instant.
        Check (([datetime]$Rows.observedUTC).ToUniversalTime() -ge ([datetime]$q[0].utc).ToUniversalTime().AddSeconds(-2) -and
            ([datetime]$Rows.observedUTC).ToUniversalTime() -le ([datetime]$Sample.completedUTC).ToUniversalTime().AddSeconds(2)) 'Server/host observation clock inconsistency'
    }
    function RestReturned($Rows, $Sample) {
        $hits = @($Commands | Where-Object { $_.exit -eq 0 -and -not $_.timeout -and $_.args -contains 'curl' -and
            [datetime]$_.utc -ge [datetime]$Sample.startedUTC -and [datetime]$_.utc -le [datetime]$Sample.completedUTC -and
            $_.stdout.Trim() -and (Json ($_.stdout | ConvertFrom-Json)) -ceq (Json $Rows) })
        Check ($hits.Count -gt 0) 'REST state has no successful raw command result in sample interval'
    }
    function CorrelatedSlot($Sample, [string]$Alias) {
        $member = "$($Result.run)-$Alias"
        $r = $Sample.replicas.PSObject.Properties[$Alias]
        Check ($null -ne $r) "Missing live receiver $Alias"
        $r = $r.Value
        Returned $r.command $r.rows $Sample 'pg_stat_wal_receiver'
        RestReturned $r.rest $Sample
        $sender = @($Sample.primary.senders | Where-Object { $_.application_name -ceq $member -and $_.state -eq 'streaming' })
        Check ($sender.Count -eq 1) "No matching streaming sender $Alias"
        $slots = @($Sample.primary.slots | Where-Object { $_.slot_type -eq 'physical' -and $_.active -ceq $true -and $_.active_pid -eq $sender[0].pid })
        $receivers = @($r.rows.receivers)
        Check ($slots.Count -eq 1 -and $receivers.Count -eq 1) "No unique active physical slot/receiver $Alias"
        Check ($receivers[0].slot_name -ceq $slots[0].slot_name -and $receivers[0].status -eq 'streaming' -and
            $r.rows.replica -ceq $true -and $r.rows.server -eq $sender[0].client_addr -and
            $receivers[0].received_tli -eq $Sample.primary.timeline -and
            $receivers[0].sender_host -eq "$($Result.run)-primary") "Receiver-to-sender mapping/role/timeline disagrees $Alias"
        Check ($r.rest.role -eq 'replica' -and $r.rest.state -eq 'running' -and $r.rest.patroni.name -ceq $member) "Replica REST identity/health $Alias"
        if ($Alias -ne 'base') { Check ($r.rest.tags.nofailover -ceq $true) 'Elastic nofailover missing' }
        $m = @($Sample.cluster.members | Where-Object name -CEQ $member)
        Check ($m.Count -eq 1 -and $m[0].state -eq 'streaming' -and $m[0].role -eq 'replica' -and
            $null -ne $m[0].lag -and "$($m[0].lag)" -match '^\d+$' -and [long]$m[0].lag -eq 0) "Membership/known zero lag $Alias"
        return $slots[0].slot_name
    }
    function Agreement([string]$Label) {
        $snap = @($Snapshots | Where-Object label -EQ $Label)
        Check ($snap.Count -eq 1) "Missing agreement snapshot $Label"
        $snap = $snap[0]
        $wanted = (@($snap.expectedTokens | Sort-Object) -join ',')
        Check ($snap.primary.replica -ceq $false -and $snap.primary.count -eq 100000 -and
            (@($snap.primary.tokens | Sort-Object) -join ',') -ceq $wanted) "Primary data mismatch $Label"
        foreach ($prop in $snap.replicas.PSObject.Properties) {
            $v = $prop.Value
            Check ($v.replica -ceq $true -and $v.count -eq 100000 -and $v.hash -ceq $snap.primary.hash -and
                (@($v.tokens | Sort-Object) -join ',') -ceq $wanted) "Replica data mismatch $Label/$($prop.Name)"
        }
        # Fixture snapshots must correspond to actual successful SELECT return objects.
        foreach ($v in @($snap.primary) + @($snap.replicas.PSObject.Properties | ForEach-Object Value)) {
            $hits = @($Sql | Where-Object { $_.exit -eq 0 -and -not $_.timeout -and $_.input -match 'string_agg' -and
                [datetime]$_.utc -le [datetime]$snap.utc -and [datetime]$_.utc -ge ([datetime]$snap.utc).AddSeconds(-120) -and
                (Json ($_.stdout | ConvertFrom-Json)) -ceq (Json $v) })
            Check ($hits.Count -gt 0) "Data agreement has no returned SQL rows $Label"
        }
        return $snap
    }
    Check ($Samples.Count -gt 0) 'No captured slot samples'
    $baseline = @($Samples | Where-Object stage -EQ 'baseline')
    Check ($baseline.Count -eq 1) 'No unique baseline'
    $baseline = $baseline[0]
    $identity = $null; $baseSlot = $null; $previous = [datetime]::MinValue
    $ids = @{}
    foreach ($s in $Samples) {
        Check ($s.valid -ceq $true -and $null -eq $s.error) 'Unknown/failed slot sample'
        Check (-not $ids.ContainsKey([int]$s.id)) 'Duplicate sample ID'
        $ids[[int]$s.id] = $s
        Check ([datetime]$s.startedUTC -ge $previous -and [datetime]$s.completedUTC -ge [datetime]$s.startedUTC) 'Sample intervals not ordered'
        $previous = [datetime]$s.completedUTC
        Returned $s.primaryCommand $s.primary $s 'pg_replication_slots'
        RestReturned $s.before $s; RestReturned $s.after $s; RestReturned $s.cluster $s
        Fields $s.primary @('slots','senders','replica','systemIdentifier','timeline','server','postmasterStarted','observedUTC','currentWalLSN')
        Check ($s.primary.replica -ceq $false -and $s.primaryHost -ceq "$($Result.run)-primary") 'Unexpected primary'
        foreach ($rest in @($s.before,$s.after)) {
            Check ($rest.role -in @('master','primary') -and $rest.state -eq 'running' -and
                $rest.patroni.name -ceq $s.primaryHost -and $rest.timeline -eq $s.primary.timeline) 'Primary REST role/identity/timeline'
        }
        $leader = @($s.cluster.members | Where-Object role -In @('leader','primary','master'))
        Check ($leader.Count -eq 1 -and $leader[0].name -ceq $s.primaryHost) 'Cluster leader changed'
        $key = "$($s.primaryHost)|$($s.primary.systemIdentifier)|$($s.primary.server)|$($s.primary.timeline)|$($s.primary.postmasterStarted)"
        if ($null -eq $identity) { $identity = $key }
        Check ($key -ceq $identity) 'Primary identity changed across observations'
        foreach ($slot in $s.primary.slots) {
            Fields $slot @('slot_name','slot_type','active','active_pid','restart_lsn','wal_status','safe_wal_size','retained_wal_bytes')
            Check ($slot.active -is [bool]) 'Unknown slot active state'
            if ($null -eq $slot.restart_lsn) { Check ($null -eq $slot.retained_wal_bytes) 'Null WAL retention coerced to zero' }
            else { Check ($null -ne $slot.retained_wal_bytes -and $slot.retained_wal_bytes -ge 0) 'Unknown/negative retained WAL' }
        }
        $mapped = CorrelatedSlot $s 'base'
        if ($null -eq $baseSlot) { $baseSlot = $mapped }
        Check ($mapped -ceq $baseSlot) 'Permanent baseline slot changed'
    }
    $failedSql = @($Sql | Where-Object { [datetime]$_.utc -ge [datetime]$baseline.startedUTC -and
        ($_.exit -ne 0 -or $_.timeout -or $_.stderr -match '(?im)\b(ERROR|FATAL|PANIC):') })
    Check ($failedSql.Count -eq 0) 'SQL errors/timeouts during measured experiment (not hidden as absence)'
    foreach ($q in $Sql) {
        $c = @($Commands | Where-Object id -EQ $q.command)
        Check ($c.Count -eq 1 -and $c[0].input -ceq $q.input -and $c[0].stdout -ceq $q.stdout -and
            $c[0].exit -eq $q.exit -and $c[0].timeout -eq $q.timeout) 'SQL command chain mismatch'
        Check ($q.input -notmatch 'pg_drop_replication_slot') 'Manual slot deletion forbidden'
    }
    Check (@($Commands | Where-Object { $_.args -contains 'psql' -and $_.id -notin @($Sql.command) }).Count -eq 0) 'Unrecorded SQL command'
    Check (@($Commands | Where-Object { ($_.args -join ' ') -match '(etcdctl.*\bdel\b|patronictl.*\bremove\b)' }).Count -eq 0) 'Manual DCS removal forbidden'
    $ack = @($Events | Where-Object kind -EQ 'write-acknowledged' | ForEach-Object { $_.data.token } | Sort-Object)
    Check (($ack -join ',') -ceq (@($Result.tokens | Sort-Object) -join ',')) 'Acknowledged token/result mismatch'
    foreach ($token in $ack) {
        $hits = @($Sql | Where-Object { $_.exit -eq 0 -and -not $_.timeout -and $_.input -match 'ON CONFLICT' -and
            $_.stdout -match $token -and ($_.stdout | ConvertFrom-Json).replica -ceq $false })
        Check ($hits.Count -gt 0) 'Write token lacks successful returned acknowledgement'
    }
    $rows = @(foreach ($alias in @('elastic4','elastic3','elastic2','elastic1')) {
        $o = @($Result.slotOutcomes | Where-Object alias -EQ $alias)
        Check ($o.Count -eq 1) "Missing removal outcome $alias"
        $o = $o[0]
        $ready = @($Samples | Where-Object { $_.stage -eq 'admission-ready' -and $_.target -eq $alias })
        Check ($ready.Count -eq 1) "Missing admission readiness $alias"
        $slotName = CorrelatedSlot $ready[0] $alias
        Check ($o.slotName -ceq $slotName -and $o.member -ceq "$($Result.run)-$alias") 'Reported mapping differs from observed mapping'
        $stages = @{}
        foreach ($stage in @('pre-drain','pre-stop','post-stop','post-remove')) {
            $found = @($Samples | Where-Object { $_.stage -eq $stage -and $_.target -eq $alias })
            Check ($found.Count -eq 1) "Missing lifecycle sample $stage/$alias"
            $stages[$stage] = $found[0]
        }
        foreach ($stage in @('pre-drain','pre-stop')) {
            Check ((CorrelatedSlot $stages[$stage] $alias) -ceq $slotName) 'Target slot not active with matching streaming sender before stop'
        }
        $before = Agreement "before-remove-$alias"
        Check ($null -ne $before.replicas.PSObject.Properties[$alias]) 'Target absent from pre-removal agreement'
        $after = Agreement "removed-$alias"
        Check ($null -eq $after.replicas.PSObject.Properties[$alias]) 'Removed target still in data snapshot'
        Check ($o.preDrainSample -eq $stages['pre-drain'].id -and $o.preStopSample -eq $stages['pre-stop'].id -and
            $o.postStopSample -eq $stages['post-stop'].id) 'Outcome lifecycle sample references disagree'
        Check ([datetime]$ready[0].completedUTC -le [datetime]$stages['pre-drain'].startedUTC -and
            [datetime]$before.utc -le [datetime]$stages['pre-drain'].startedUTC -and
            [datetime]$stages['pre-drain'].completedUTC -le [datetime]$stages['pre-stop'].startedUTC) 'Readiness/agreement/pre-drain order'
        Check ([datetime]$stages['pre-stop'].completedUTC -le [datetime]$o.stopStartedUTC -and
            [datetime]$o.stopStartedUTC -le [datetime]$o.stopCompletedUTC -and
            [datetime]$o.stopCompletedUTC -le [datetime]$stages['post-stop'].startedUTC -and
            [datetime]$stages['post-stop'].completedUTC -le [datetime]$o.removeStartedUTC -and
            [datetime]$o.removeStartedUTC -le [datetime]$o.removeCompletedUTC -and
            [datetime]$o.removeCompletedUTC -le [datetime]$stages['post-remove'].startedUTC) 'Lifecycle interval ordering'
        foreach ($op in @('stop','rm')) {
            $cs = @($Commands | Where-Object { $_.args[0] -eq $op -and $_.args[-1] -eq $o.member })
            Check ($cs.Count -eq 1 -and $cs[0].exit -eq 0 -and -not $cs[0].timeout -and $cs[0].args -notcontains '-v') 'Stop/remove command missing or failed'
            $begin = if ($op -eq 'stop') { $o.stopStartedUTC } else { $o.removeStartedUTC }
            $end = if ($op -eq 'stop') { $o.stopCompletedUTC } else { $o.removeCompletedUTC }
            Check ([datetime]$cs[0].utc -ge [datetime]$begin -and
                ([datetime]$cs[0].utc).AddMilliseconds($cs[0].durationMs) -le [datetime]$end) 'Operation timestamp differs from command'
        }
        $absentContainer = @($Commands | Where-Object { $_.args[0] -eq 'inspect' -and $_.args[-1] -eq $o.member -and
            $_.exit -eq 1 -and -not $_.timeout -and $_.stderr -match 'No such (object|container)' -and
            [datetime]$_.utc -ge [datetime]$o.removeCompletedUTC })
        $volume = @($Commands | Where-Object { $_.args[0] -eq 'volume' -and $_.args[1] -eq 'inspect' -and
            $_.args[-1] -eq "$($o.member)-data" -and $_.exit -eq 0 -and -not $_.timeout })
        Check ($absentContainer.Count -gt 0 -and $volume.Count -gt 0) 'Container absence/retained volume not captured'
        $observations = @($Samples | Where-Object { $_.target -eq $alias -and $_.stage -in @('post-remove','reconcile') })
        $first = @($observations | Where-Object { @($_.primary.slots | Where-Object slot_name -CEQ $slotName).Count -eq 0 })
        Check ($first.Count -gt 0) "Timeout/slot still present: $alias"
        $first = $first[0]
        Check ([datetime]$first.completedUTC -le ([datetime]$o.removeCompletedUTC).AddSeconds($o.timeoutSeconds)) 'Absence outside bounded window'
        $delay = ([datetime]$first.completedUTC - [datetime]$o.removeCompletedUTC).TotalSeconds
        Check ($o.firstAbsentSample -eq $first.id -and [datetime]$o.firstAbsentCompletedUTC -eq [datetime]$first.completedUTC -and
            [math]::Abs($o.secondsFromRemovalCompletion - $delay) -lt 0.001) 'First absence timestamp/delay not derived from samples'
        Check (([datetime]$o.firstAbsentObservedUTC).ToUniversalTime() -eq ([datetime]$first.primary.observedUTC).ToUniversalTime() -and
            [math]::Abs($o.secondsFromStopCompletion - ([datetime]$first.completedUTC-[datetime]$o.stopCompletedUTC).TotalSeconds) -lt 0.001 -and
            [datetime]$after.utc -ge [datetime]$first.completedUTC) 'Absence/stop delay/data agreement interval mismatch'
        Check (($o.sampleIds -join ',') -eq ($observations.id -join ',')) 'Observation IDs omit samples'
        Check ($o.containerRemoved -and $o.dataAgreementVerified -and $o.slotAbsentVerified -and $o.preconditionsVerified -and $null -eq $o.error) 'Outcome not fully verified'
        $later = @($Samples | Where-Object { [datetime]$_.startedUTC -ge [datetime]$first.completedUTC })
        Check (@($later | Where-Object { @($_.primary.slots | Where-Object slot_name -CEQ $slotName).Count -gt 0 }).Count -eq 0) 'Removed slot reappeared'
        $present = @($Samples | Where-Object { [datetime]$_.completedUTC -lt [datetime]$first.completedUTC -and
            @($_.primary.slots | Where-Object slot_name -CEQ $slotName).Count -gt 0 })[-1]
        $afterStopAbsent = @($Samples | Where-Object { $_.target -eq $alias -and $_.stage -in @('post-stop','post-remove','reconcile') -and
            @($_.primary.slots | Where-Object slot_name -CEQ $slotName).Count -eq 0 })[0]
        [pscustomobject]@{alias=$alias; slotName=$slotName; containerRemoved=$true; dataAgreementVerified=$true; slotAbsentVerified=$true;
            stopStartedUTC=$o.stopStartedUTC; stopCompletedUTC=$o.stopCompletedUTC; removeCompletedUTC=$o.removeCompletedUTC;
            lastPresentObservedUTC=([datetime]$present.primary.observedUTC).ToUniversalTime().ToString('o');
            firstAbsentObservedUTC=([datetime]$afterStopAbsent.primary.observedUTC).ToUniversalTime().ToString('o');
            firstAbsentAfterRemovalCompletedUTC=$first.completedUTC; secondsStopToFirstAbsence=([datetime]$afterStopAbsent.completedUTC-[datetime]$o.stopCompletedUTC).TotalSeconds;
            secondsRemovalToFirstAbsence=$delay; observationIntervalSeconds=([datetime]$afterStopAbsent.primary.observedUTC-[datetime]$present.primary.observedUTC).TotalSeconds;
            preStopRetainedWalBytes=(@($stages['pre-stop'].primary.slots | Where-Object slot_name -CEQ $slotName)[0]).retained_wal_bytes;
            postStopRetainedWalBytes=(@($stages['post-stop'].primary.slots | Where-Object slot_name -CEQ $slotName) | Select-Object -ExpandProperty retained_wal_bytes);
            sampleIds=@($observations.id)}
    })
    $final = @($Samples | Where-Object stage -EQ 'final')
    Check ($final.Count -eq 1 -and $final[0].primary.slots.Count -eq 1 -and $final[0].primary.slots[0].slot_name -ceq $baseSlot) 'Final inventory not baseline slot only'
    $null = Agreement 'final-all-tokens-and-fixture-agree'
    $archives = @($Events | Where-Object { $_.kind -eq 'logs-archived' -and $_.data.name -eq "$($Result.run)-primary" -and
        $_.data.postgres -and [datetime]$_.utc -gt [datetime]$final[0].completedUTC })
    Check ($archives.Count -gt 0) 'Primary archive predates final cleanup observation'
    foreach ($op in @('logs','cp')) {
        $copied=@($Commands | Where-Object { $_.args[0] -eq $op -and $_.exit -eq 0 -and -not $_.timeout -and
            [datetime]$_.utc -ge [datetime]$final[0].completedUTC -and
            ($_.args -contains "$($Result.run)-primary" -or $_.args -contains "$($Result.run)-primary`:/var/lib/postgresql/data/pgdata/pg_log") })
        Check ($copied.Count -gt 0) 'Final primary log archive has no successful command evidence'
    }
    return [pscustomobject]@{status='verified'; removed=4; baselineSlot=$baseSlot; primaryIdentity=$identity; samples=$Samples.Count;
        sqlErrorsDuringObservation=$failedSql.Count; physicalDiskReclamationVerified=$false; outcomes=$rows}
}