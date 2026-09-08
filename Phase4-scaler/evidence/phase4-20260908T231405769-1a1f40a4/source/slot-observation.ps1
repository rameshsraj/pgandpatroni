# Read-only replication evidence. SQL/Http/Cmd/Record/Tick are supplied by the runner.
function Assert-SlotState($Sample, [string[]]$LiveAliases) {
    $p = $Sample.primary
    if ($p.replica -cne $false -or $Sample.before.role -notin @('primary','master') -or
        $Sample.after.role -notin @('primary','master') -or $Sample.before.state -ne 'running' -or
        $Sample.after.state -ne 'running' -or $Sample.before.patroni.name -ne $primary -or
        $Sample.after.patroni.name -ne $primary -or $p.timeline -ne $Sample.before.timeline -or
        $p.timeline -ne $Sample.after.timeline) { throw 'Slot observation primary identity/role/timeline unknown or changed' }
    $identity = "$($Sample.primaryHost)|$($p.systemIdentifier)|$($p.server)|$($p.timeline)|$($p.postmasterStarted)"
    if ($null -eq $script:slotPrimaryIdentity) { $script:slotPrimaryIdentity = $identity }
    if ($identity -ne $script:slotPrimaryIdentity) { throw 'Primary changed during slot observation' }
    foreach ($alias in $LiveAliases) {
        $member = "$runId-$alias"
        $sender = @($p.senders | Where-Object { $_.application_name -ceq $member -and $_.state -eq 'streaming' })
        if ($sender.Count -ne 1) { throw "No unique streaming sender for $member" }
        $slot = @($p.slots | Where-Object { $_.slot_type -eq 'physical' -and $_.active -ceq $true -and $_.active_pid -eq $sender[0].pid })
        $replica = $Sample.replicas[$alias]
        $receiver = @($replica.rows.receivers)
        $membership = @($Sample.cluster.members | Where-Object name -CEQ $member)
        if ($slot.Count -ne 1 -or $receiver.Count -ne 1 -or $replica.rows.replica -cne $true -or
            $receiver[0].status -ne 'streaming' -or $receiver[0].slot_name -cne $slot[0].slot_name -or
            $receiver[0].received_tli -ne $p.timeline -or $receiver[0].sender_host -cne $primary -or
            $replica.rows.server -ne $sender[0].client_addr -or $replica.rest.role -ne 'replica' -or
            $replica.rest.state -ne 'running' -or $replica.rest.patroni.name -cne $member -or
            $membership.Count -ne 1 -or $membership[0].state -ne 'streaming' -or
            $membership[0].role -ne 'replica' -or $null -eq $membership[0].lag -or
            "$($membership[0].lag)" -notmatch '^\d+$' -or [long]$membership[0].lag -ne 0) {
            throw "Slot/sender/receiver/membership correlation failed: $member"
        }
        if ($alias -ne 'base' -and $replica.rest.tags.nofailover -cne $true) { throw 'Elastic member is not protected from promotion' }
        # Learn the exact name from PostgreSQL, NOT by normalizing the member name.
        if ($script:slotMappings.Contains($alias) -and $script:slotMappings[$alias] -cne $slot[0].slot_name) {
            throw "Actual slot mapping changed: $member"
        }
        $script:slotMappings[$alias] = $slot[0].slot_name
    }
}

function Slot-Snapshot([string]$Stage, [string]$Target = '', [string[]]$LiveAliases = @('base')) {
    $sample = [ordered]@{id=($script:slotSequence + 1); stage=$Stage; target=$Target;
        startedUTC=[datetime]::UtcNow.ToString('o'); completedUTC=$null; valid=$false; error=$null;
        primaryHost=$null; primaryCommand=$null; primary=$null; before=$null; after=$null;
        cluster=$null; replicas=@{}; mappings=@{}}
    $script:slotSequence++
    try {
        $cluster = Http 'primary' 'cluster'
        $leader = @($cluster.members | Where-Object role -In @('leader','primary','master'))
        if ($leader.Count -ne 1 -or $leader[0].name -cne $primary) { throw 'Current Patroni leader is not the expected isolated primary' }
        $sample.primaryHost = $leader[0].name
        $sample.before = Http $sample.primaryHost
        $q = @'
SELECT json_build_object('observedUTC',clock_timestamp(),'server',inet_server_addr(),
 'replica',pg_is_in_recovery(),'postmasterStarted',pg_postmaster_start_time(),
 'systemIdentifier',(SELECT system_identifier::text FROM pg_control_system()),
 'timeline',(SELECT timeline_id FROM pg_control_checkpoint()),'currentWalLSN',pg_current_wal_lsn(),
 'slots',COALESCE((SELECT json_agg(s ORDER BY slot_name) FROM
   (SELECT slot_name,slot_type,active,active_pid,restart_lsn,wal_status,safe_wal_size,
    pg_wal_lsn_diff(pg_current_wal_lsn(),restart_lsn) AS retained_wal_bytes FROM pg_replication_slots) s),'[]'::json),
 'senders',COALESCE((SELECT json_agg(s ORDER BY application_name) FROM
   (SELECT pid,application_name,client_addr,state,sync_state,sent_lsn,write_lsn,flush_lsn,replay_lsn,
    write_lag,flush_lag,replay_lag FROM pg_stat_replication) s),'[]'::json));
'@
        $r = SQL $sample.primaryHost 5432 $q
        $sample.primaryCommand = $r.id
        $sample.primary = $r.stdout | ConvertFrom-Json
        foreach ($alias in $LiveAliases) {
            $r = SQL $alias 5432 @'
SELECT json_build_object('observedUTC',clock_timestamp(),'server',inet_server_addr(),
 'replica',pg_is_in_recovery(),'replayLSN',pg_last_wal_replay_lsn(),
 'receivers',COALESCE((SELECT json_agg(r) FROM
  (SELECT pid,status,receive_start_lsn,receive_start_tli,written_lsn,flushed_lsn,
   received_tli,latest_end_lsn,latest_end_time,slot_name,sender_host,sender_port FROM pg_stat_wal_receiver) r),'[]'::json));
'@
            $sample.replicas[$alias] = @{command=$r.id; rows=($r.stdout | ConvertFrom-Json); rest=(Http $alias)}
        }
        $sample.cluster = Http 'primary' 'cluster'
        $sample.after = Http $sample.primaryHost
        Assert-SlotState $sample $LiveAliases
        foreach ($key in $script:slotMappings.Keys) { $sample.mappings[$key] = $script:slotMappings[$key] }
        $sample.valid = $true
    } catch {
        $sample.error = $_.Exception.Message
        throw
    } finally {
        $sample.completedUTC = [datetime]::UtcNow.ToString('o')
        Record 'slot-samples' $sample
    }
    return [pscustomobject]$sample
}

function Observe-SlotAbsence($Outcome) {
    $deadline = ([datetime]$Outcome.removeCompletedUTC).AddSeconds($SlotAbsenceTimeoutSeconds)
    $sample = Slot-Snapshot 'post-remove' $Outcome.alias
    do {
        $Outcome.sampleIds.Add($sample.id)
        if ([datetime]$sample.completedUTC -gt $deadline) { break }
        $rows = @($sample.primary.slots | Where-Object slot_name -CEQ $Outcome.slotName)
        if ($rows.Count -eq 0) {
            $Outcome.slotAbsentVerified = $true
            $Outcome.firstAbsentSample = $sample.id
            $Outcome.firstAbsentObservedUTC = $sample.primary.observedUTC
            $Outcome.firstAbsentCompletedUTC = $sample.completedUTC
            $Outcome.secondsFromStopCompletion = ([datetime]$sample.completedUTC - [datetime]$Outcome.stopCompletedUTC).TotalSeconds
            $Outcome.secondsFromRemovalCompletion = ([datetime]$sample.completedUTC - [datetime]$Outcome.removeCompletedUTC).TotalSeconds
            return
        }
        $Outcome.lastPresentSample = $sample.id
        Tick # Useful bounded resource/driver liveness observation, not an artificial delay.
        if ([datetime]::UtcNow -ge $deadline) { break }
        $sample = Slot-Snapshot 'reconcile' $Outcome.alias
    } while ($true)
    $Outcome.error = 'Slot absence observation timed out; absence NOT verified'
    throw $Outcome.error
}
