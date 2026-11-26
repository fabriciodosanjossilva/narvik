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
        foreach ($vm in $pending) {
            if (Test-NarvikVmActive -VmName $vm.Name) {
                Write-NarvikLog -Level DEBUG -Message "VM '$($vm.Name)' already has an active backup; skipping."
                continue
            }

            if ([string]::IsNullOrWhiteSpace($vm.HostName)) {
                Write-NarvikLog -Level DEBUG -Message "VM '$($vm.Name)' has no host information; backup will not be started."
                continue
            }

            if (Test-NarvikBackoffActive -VmName $vm.Name -Now $now) {
                Write-NarvikLog -Level DEBUG -Message "VM '$($vm.Name)' is in failure backoff until $((Get-NarvikBackoffUntil -VmName $vm.Name).ToString('yyyy-MM-dd HH:mm:ss')); skipping."
                continue
            }

            if (Test-NarvikHostActive -HostName $vm.HostName) {
                Write-NarvikLog -Level DEBUG -Message "VM '$($vm.Name)' shares host '$($vm.HostName)' with an active backup; skipping."
                continue
            }

            if (Test-NarvikClusterAtCapacity -Vm $vm) {
                Write-NarvikLog -Level DEBUG -Message "VM '$($vm.Name)' is in cluster '$($vm.ClusterName)', which already has $(Get-NarvikClusterMaxThreadsSetting -ClusterName $vm.ClusterName) active backup(s); skipping."
                continue
            }

            $forceFull = $script:DuplicateGuid.ContainsKey($vm.Name)
            if ($forceFull) {
                Write-NarvikLog -Level DEBUG -Message "VM '$($vm.Name)' has the duplicate GUID flag; the next backup will use -VMBACKUPUPDATEGUID and -mode IFFull."
            }
            return [pscustomobject]@{
                VM        = $vm
                Mode      = 'Incremental'
                IsFull    = [bool]$forceFull
                ForceFull = [bool]$forceFull
            }
        }

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

    $fullCandidates = [System.Collections.Generic.List[object]]::new()
    foreach ($vm in @($script:EligibleVMs)) {
        if (Test-NarvikVmActive -VmName $vm.Name) {
            Write-NarvikLog -Level DEBUG -Message "VM '$($vm.Name)' already has an active backup; full backup skipped."
            continue
        }

        if ([string]::IsNullOrWhiteSpace($vm.HostName)) {
            Write-NarvikLog -Level DEBUG -Message "VM '$($vm.Name)' has no host information; full backup will not be started."
            continue
        }

        if (Test-NarvikBackoffActive -VmName $vm.Name -Now $now) {
            Write-NarvikLog -Level DEBUG -Message "VM '$($vm.Name)' is in failure backoff until $((Get-NarvikBackoffUntil -VmName $vm.Name).ToString('yyyy-MM-dd HH:mm:ss')); full backup skipped."
            continue
        }

        if (Test-NarvikHostActive -HostName $vm.HostName) {
            Write-NarvikLog -Level DEBUG -Message "VM '$($vm.Name)' shares host '$($vm.HostName)' with an active backup; full backup skipped."
            continue
        }

        if (Test-NarvikClusterAtCapacity -Vm $vm) {
            Write-NarvikLog -Level DEBUG -Message "VM '$($vm.Name)' is in cluster '$($vm.ClusterName)', which already has $(Get-NarvikClusterMaxThreadsSetting -ClusterName $vm.ClusterName) active backup(s); full backup skipped."
            continue
        }

        $lastFull = $null
        if ($script:LastFull.ContainsKey($vm.Name)) {
            $lastFull = $script:LastFull[$vm.Name]
        }
        if ($null -eq $lastFull) {
            $lastFull = $now.AddYears(-1)
        }

        if ($lastFull -lt $now.AddDays(-30)) {
            [void]$fullCandidates.Add([pscustomobject]@{
                VM       = $vm
                LastFull = $lastFull
            })
        }
    }

    if ($fullCandidates.Count -eq 0) {
        Write-NarvikLog -Level DEBUG -Message 'No eligible VM is due for a full backup; every recorded full backup is newer than 30 days.'
        return $null
    }

    # Priority is the primary criterion for full backups too; resource pool
    # priority comes next and the oldest full backup breaks ties before the
    # folder path and the name.
    $selected = @($fullCandidates | Sort-Object -Property @{ Expression = { [int]$_.VM.ClusterPriority }; Descending = $true }, @{ Expression = { [int]$_.VM.ResourcePoolPriority }; Descending = $true }, LastFull, @{ Expression = { $_.VM.FolderPath } }, @{ Expression = { $_.VM.Name } } | Select-Object -First 1)[0]

    return [pscustomobject]@{
        VM        = $selected.VM
        Mode      = 'Full'
        IsFull    = $true
        ForceFull = $true
    }
}
