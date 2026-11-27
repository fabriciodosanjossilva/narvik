function Test-NarvikVmActive {
    param(
        [string]$VmName
    )

    foreach ($job in $script:ActiveJobs) {
        if ($job.VmName -ieq $VmName) {
            return $true
        }
    }

    return $false
}

function Test-NarvikHostActive {
    param(
        [string]$HostName
    )

    if ([string]::IsNullOrWhiteSpace($HostName)) {
        return $false
    }

    foreach ($job in $script:ActiveJobs) {
        if ($job.HostName -ieq $HostName) {
            return $true
        }
    }

    return $false
}

function Test-NarvikClusterAtCapacity {
    param(
        [Parameter(Mandatory = $true)]
        $Vm
    )

    $clusterName = [string]$Vm.ClusterName
    if ([string]::IsNullOrWhiteSpace($clusterName)) {
        return $false
    }

    $maxThreads = Get-NarvikClusterMaxThreadsSetting -ClusterName $clusterName
    if ($maxThreads -lt 1) {
        $maxThreads = 1
    }

    $activeCount = 0
    foreach ($job in $script:ActiveJobs) {
        if ([string]$job.ClusterName -ieq $clusterName) {
            $activeCount++
        }
    }

    return ($activeCount -ge $maxThreads)
}

function Get-NarvikBackoffUntil {
    param(
        [string]$VmName
    )

    if (-not $script:State.failed_attempts.ContainsKey($VmName)) {
        return $null
    }

    $entry = $script:State.failed_attempts[$VmName]
    if ($null -eq $entry.last_attempt) {
        return $null
    }

    $count = [int]$entry.count
    if ($count -lt 1) {
        $count = 1
    }

    $exponent = $count - 1

    # The first retry comes after one minute and quadruples on every further
    # failure.
    $minutes = [math]::Pow(4, $exponent)

    # Cap the backoff at 12 hours (720 minutes) so a VM that keeps failing
    # is still retried at least twice a day.
    if ($minutes -gt 720) {
        $minutes = 720
    }

    return $entry.last_attempt.AddMinutes($minutes)
}

function Test-NarvikBackoffActive {
    param(
        [string]$VmName,
        [datetime]$Now
    )

    $nextAttempt = Get-NarvikBackoffUntil -VmName $VmName
    if ($null -eq $nextAttempt) {
        return $false
    }

    return ($Now -lt $nextAttempt)
}

function Test-NarvikFullBackupWindow {
    param(
        [Parameter(Mandatory = $true)]
        [datetime]$Now
    )

    # Unrestricted days allow full backups all day; limited days only before
    # 'full_backup_limited_until'. A day in neither list never gets a full backup.
    if ($script:Config.full_backup_unrestricted_days -contains $Now.DayOfWeek) {
        return $true
    }
    if ($script:Config.full_backup_limited_days -contains $Now.DayOfWeek -and $Now.TimeOfDay -lt $script:Config.full_backup_limited_until) {
        return $true
    }
    return $false
}

function Test-NarvikVmAllocable {
    # Checks every rule that decides whether a VM may start a backup now.
    # The one-backup-per-host rule is skipped when -AllowSharedHost is given;
    # that is the fallback pass used once no other VM can be started.
    # -Quiet suppresses the skip messages (used by the fallback pass, which
    # repeats checks the strict pass has already logged).
    param(
        [Parameter(Mandatory = $true)]
        $Vm,
        [Parameter(Mandatory = $true)]
        [datetime]$Now,
        [Parameter(Mandatory = $true)]
        [string]$Kind,
        [switch]$AllowSharedHost,
        [switch]$Quiet
    )

    if (Test-NarvikVmActive -VmName $Vm.Name) {
        if (-not $Quiet) { Write-NarvikLog -Level DEBUG -Message "VM '$($Vm.Name)' already has an active $Kind; skipping." }
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($Vm.HostName)) {
        if (-not $Quiet) { Write-NarvikLog -Level DEBUG -Message "VM '$($Vm.Name)' has no host information; $Kind will not be started." }
        return $false
    }

    if (Test-NarvikBackoffActive -VmName $Vm.Name -Now $Now) {
        if (-not $Quiet) { Write-NarvikLog -Level DEBUG -Message "VM '$($Vm.Name)' is in failure backoff until $((Get-NarvikBackoffUntil -VmName $Vm.Name).ToString('yyyy-MM-dd HH:mm:ss')); $Kind skipped." }
        return $false
    }

    if (-not $AllowSharedHost) {
        if (Test-NarvikHostActive -HostName $Vm.HostName) {
            if (-not $Quiet) { Write-NarvikLog -Level DEBUG -Message "VM '$($Vm.Name)' shares host '$($Vm.HostName)' with an active backup; $Kind skipped." }
            return $false
        }
    }
    else {
        $hostCount = Get-NarvikActiveJobCountForHost -HostName $Vm.HostName
        if ($hostCount -ge $script:SharedHostMaxBackups) {
            if (-not $Quiet) { Write-NarvikLog -Level DEBUG -Message "VM '$($Vm.Name)' is on host '$($Vm.HostName)', which already runs $hostCount backup(s) (limit $($script:SharedHostMaxBackups)); $Kind skipped." }
            return $false
        }
    }

    if (Test-NarvikClusterAtCapacity -Vm $Vm) {
        if (-not $Quiet) { Write-NarvikLog -Level DEBUG -Message "VM '$($Vm.Name)' is in cluster '$($Vm.ClusterName)', which already has $(Get-NarvikClusterMaxThreadsSetting -ClusterName $Vm.ClusterName) active backup(s); $Kind skipped." }
        return $false
    }

    return $true
}

function Get-NarvikActiveJobCountForHost {
    param(
        [string]$HostName
    )

    if ([string]::IsNullOrWhiteSpace($HostName)) {
        return 0
    }

    $count = 0
    foreach ($job in $script:ActiveJobs) {
        if ([string]$job.HostName -ieq $HostName) {
            $count++
        }
    }

    return $count
}

function Write-NarvikSharedHostDebug {
    # Logs, at DEBUG level, a concurrent backup started on a host that already
    # runs another backup: the strict one-per-host pass found no candidate.
    param(
        [Parameter(Mandatory = $true)]
        $Vm,
        [Parameter(Mandatory = $true)]
        [string]$Kind
    )

    $sharing = Get-NarvikActiveJobCountForHost -HostName $Vm.HostName
    Write-NarvikLog -Level DEBUG -Message "Allocating a concurrent backup on the same host because no other option is left. $Kind of VM '$($Vm.Name)' on host '$($Vm.HostName)': active backups on this host $sharing/$($script:SharedHostMaxBackups)."
}

function Get-NarvikFullCandidates {
    param(
        [Parameter(Mandatory = $true)]
        [datetime]$Now,
        [switch]$AllowSharedHost,
        [switch]$Quiet
    )

    $candidates = [System.Collections.Generic.List[object]]::new()
    # Without 'full_backup_max_age_days' no automatic full backup is scheduled.
    if ($null -eq $script:Config.full_backup_max_age_days) {
        return ,@($candidates)
    }
    $maxAgeDays = [int]$script:Config.full_backup_max_age_days

    foreach ($vm in @($script:EligibleVMs)) {
        if (-not (Test-NarvikVmAllocable -Vm $vm -Now $Now -Kind 'full backup' -AllowSharedHost:$AllowSharedHost -Quiet:$Quiet)) {
            continue
        }

        $lastFull = $null
        if ($script:LastFull.ContainsKey($vm.Name)) {
            $lastFull = $script:LastFull[$vm.Name]
        }
        if ($null -eq $lastFull) {
            $lastFull = $Now.AddYears(-1)
        }

        if ($lastFull -lt $Now.AddDays(-$maxAgeDays)) {
            [void]$candidates.Add([pscustomobject]@{
                VM       = $vm
                LastFull = $lastFull
            })
        }
    }

    return ,@($candidates)
}

function Select-NarvikNextBackup {
    if ($null -eq $script:VCache -or @($script:EligibleVMs).Count -eq 0) {
        return $null
    }

    $now = Get-Date
    # EligibleVMs is already ordered by cluster priority, folder and name;
    # filtering keeps that order without re-sorting the queue every cycle.
    $pending = @(Get-NarvikPendingVMs -Now $now)
    $script:PendingVMs = $pending

    if ($pending.Count -gt 0) {
        # Strict pass: one backup per ESXi host.
        $selectedVm = $null
        $shared = $false
        foreach ($vm in $pending) {
            if (Test-NarvikVmAllocable -Vm $vm -Now $now -Kind 'backup') {
                $selectedVm = $vm
                break
            }
        }

        # Fallback pass: only when no pending VM can start under the strict rule.
        # Every other check still applies; only the host rule is relaxed.
        if ($null -eq $selectedVm) {
            foreach ($vm in $pending) {
                if (Test-NarvikVmAllocable -Vm $vm -Now $now -Kind 'backup' -AllowSharedHost -Quiet) {
                    $selectedVm = $vm
                    $shared = Test-NarvikHostActive -HostName $vm.HostName
                    break
                }
            }
        }

        if ($null -eq $selectedVm) {
            return $null
        }

        if ($shared) {
            Write-NarvikSharedHostDebug -Vm $selectedVm -Kind 'Backup'
        }

        $forceFull = $script:DuplicateGuid.ContainsKey($selectedVm.Name)
        if ($forceFull) {
            Write-NarvikLog -Level DEBUG -Message "VM '$($selectedVm.Name)' has the duplicate GUID flag; the next backup will use -VMBACKUPUPDATEGUID and -mode IFFull."
        }
        return [pscustomobject]@{
            VM        = $selectedVm
            Mode      = 'Incremental'
            IsFull    = [bool]$forceFull
            ForceFull = [bool]$forceFull
        }
    }

    # No automatic full backups unless 'full_backup_max_age_days' is configured.
    if ($null -eq $script:Config.full_backup_max_age_days) {
        return $null
    }

    if (-not (Test-NarvikFullBackupWindow -Now $now)) {
        # The main loop calls this every cycle; log the closed window once and
        # stay quiet until the window opens again.
        if (-not $script:FullWindowClosedLogged) {
            Write-NarvikLog -Level INFO -Message "Outside the full backup window for $($now.DayOfWeek) at $($now.ToString('HH:mm')); no full backup will be started."
            $script:FullWindowClosedLogged = $true
        }
        return $null
    }
    $script:FullWindowClosedLogged = $false

    # Strict pass first; the fallback pass only runs when it finds nothing.
    $fullCandidates = Get-NarvikFullCandidates -Now $now
    $shared = $false
    if ($fullCandidates.Count -eq 0) {
        $fullCandidates = Get-NarvikFullCandidates -Now $now -AllowSharedHost -Quiet
        $shared = $true
    }

    if ($fullCandidates.Count -eq 0) {
        Write-NarvikLog -Level DEBUG -Message "No eligible VM is due for a full backup; every recorded full backup is newer than $($script:Config.full_backup_max_age_days) day(s)."
        return $null
    }

    # Priority is the primary criterion for full backups too; resource pool
    # priority comes next and the oldest full backup breaks ties before the
    # folder path and the name.
    $selected = @($fullCandidates | Sort-Object -Property @{ Expression = { [int]$_.VM.ClusterPriority }; Descending = $true }, @{ Expression = { [int]$_.VM.ResourcePoolPriority }; Descending = $true }, LastFull, @{ Expression = { $_.VM.FolderPath } }, @{ Expression = { $_.VM.Name } } | Select-Object -First 1)[0]

    if ($shared -and (Test-NarvikHostActive -HostName $selected.VM.HostName)) {
        Write-NarvikSharedHostDebug -Vm $selected.VM -Kind 'Full backup'
    }

    return [pscustomobject]@{
        VM        = $selected.VM
        Mode      = 'Full'
        IsFull    = $true
        ForceFull = $true
    }
}
