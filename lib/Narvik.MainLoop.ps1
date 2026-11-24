function Invoke-NarvikControlFiles {
    $abortFile = Join-Path $script:RootPath 'abort.txt'
    $stopFile = Join-Path $script:RootPath 'stop.txt'

    if (Test-Path -LiteralPath $abortFile -PathType Leaf) {
        $script:AbortRequested = $true
        Write-NarvikLog -Level WARNING -Message "Abort control file detected; active backups will be terminated and Narvik will exit."
        try {
            Remove-Item -LiteralPath $abortFile -Force -ErrorAction Stop
        }
        catch {
            Write-NarvikLog -Level WARNING -Message "Could not remove abort control file '$abortFile': $($_.Exception.Message)"
        }
        Stop-NarvikActiveJobs -Force
        return
    }

    if (Test-Path -LiteralPath $stopFile -PathType Leaf) {
        if (-not $script:StopRequested) {
            $script:StopRequested = $true
            Write-NarvikLog -Level INFO -Message 'Stop control file detected; no new backups will be started. Waiting for active backups to finish.'
        }
        try {
            Remove-Item -LiteralPath $stopFile -Force -ErrorAction Stop
        }
        catch {
            Write-NarvikLog -Level WARNING -Message "Could not remove stop control file '$stopFile': $($_.Exception.Message)"
        }
    }
}

function Invoke-NarvikMain {
    Write-NarvikLog -Level INFO -Message 'Main loop started.'

    while ($true) {
        Invoke-NarvikControlFiles
        if ($script:AbortRequested) {
            break
        }

        Update-NarvikRuntimeConfig

        $cacheAvailable = Update-NarvikVCenterCache
        if ($script:VCacheRefreshedThisLoop) {
            Update-NarvikEligibility -SendAlerts
        }

        [void](Complete-NarvikJobs)
        Read-NarvikJobOutput

        if ($script:StopRequested) {
            if ($script:ActiveJobs.Count -eq 0) {
                Write-NarvikLog -Level INFO -Message 'Stop request completed; no active backups remain.'
                break
            }

            Write-NarvikStats
            Start-Sleep -Seconds 10
            continue
        }

        if (-not $cacheAvailable -and $null -eq $script:VCache) {
            Write-NarvikLog -Level DEBUG -Message 'vCenter inventory is unavailable; backup scheduling is paused until the next collection attempt.'
        }
        else {
            $startedAny = $false
            if ($script:ActiveJobs.Count -ge $script:Config.max_backup_threads) {
                Write-NarvikLog -Level DEBUG -Message "Global backup limit reached ($($script:ActiveJobs.Count) of $($script:Config.max_backup_threads) active); no new backup will be started this cycle."
            }
            while ($script:ActiveJobs.Count -lt $script:Config.max_backup_threads) {
                $selection = Select-NarvikNextBackup
                if ($null -eq $selection) {
                    break
                }

                $job = Start-NarvikBackupJob -Selection $selection
                if ($null -eq $job) {
                    break
                }

                $startedAny = $true
            }

            Update-NarvikPendingMonitoring
            Write-NarvikStats

            if (-not $startedAny -and $script:ActiveJobs.Count -eq 0) {
                Invoke-NarvikIdleMaintenance
            }
        }

        Start-Sleep -Seconds 10
    }

    if ($script:AbortRequested) {
        Write-NarvikLog -Level WARNING -Message 'Narvik was aborted by the operator.'
    }
    else {
        Write-NarvikLog -Level INFO -Message 'Narvik stopped normally.'
    }
}
