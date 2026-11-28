function ConvertTo-NarvikDsmcVmName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    # Non-ASCII characters (accents and other Unicode) are written as \u escapes so the
    # file stays pure ASCII regardless of how Windows PowerShell 5.1 decodes the script.
    return [regex]::Replace($Name, '[/\u0080-\uFFFF]+', '*')
}

function ConvertTo-NarvikFileName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
    $builder = New-Object System.Text.StringBuilder

    foreach ($character in $Name.ToCharArray()) {
        if ($invalidChars -contains $character -or [int][char]$character -lt 32) {
            [void]$builder.Append('_')
        }
        else {
            [void]$builder.Append($character)
        }
    }

    $value = $builder.ToString().Trim()
    $value = $value.TrimEnd([char[]]'.')
    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = 'VM'
    }
    if ($value.Length -gt 120) {
        $value = $value.Substring(0, 120)
    }

    return $value
}

function Quote-NarvikWindowsArgument {
    param(
        [AllowEmptyString()]
        [string]$Argument
    )

    if ($null -eq $Argument) {
        return '""'
    }

    if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') {
        return $Argument
    }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0

    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes++
            continue
        }

        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($backslashes * 2) + 1)))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }

        if ($backslashes -gt 0) {
            [void]$builder.Append(('\' * $backslashes))
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }

    if ($backslashes -gt 0) {
        [void]$builder.Append(('\' * ($backslashes * 2)))
    }

    [void]$builder.Append('"')
    return $builder.ToString()
}

function Read-NarvikTextFileShared {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ''
    }

    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $reader = New-Object System.IO.StreamReader -ArgumentList $stream, ([System.Text.Encoding]::Default), $true
        try {
            return $reader.ReadToEnd()
        }
        finally {
            $reader.Close()
        }
    }
    catch {
        return ''
    }
    finally {
        if ($null -ne $stream) {
            try { $stream.Close() } catch { }
        }
    }
}

function Read-NarvikFileChunk {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [long]$Offset = 0,

        [int]$MaxBytes = 65536
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{
            Text   = ''
            Offset = $Offset
        }
    }

    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        if ($Offset -lt 0 -or $Offset -gt $stream.Length) {
            $Offset = 0
        }

        $stream.Position = $Offset
        $remaining = $stream.Length - $Offset
        if ($remaining -le 0) {
            return [pscustomobject]@{
                Text   = ''
                Offset = $stream.Length
            }
        }

        $count = [int][math]::Min([long]$MaxBytes, $remaining)
        $buffer = New-Object byte[] $count
        $read = $stream.Read($buffer, 0, $count)
        if ($read -le 0) {
            return [pscustomobject]@{
                Text   = ''
                Offset = $Offset
            }
        }

        return [pscustomobject]@{
            Text   = [System.Text.Encoding]::Default.GetString($buffer, 0, $read)
            Offset = ($Offset + $read)
        }
    }
    catch {
        return [pscustomobject]@{
            Text   = ''
            Offset = $Offset
        }
    }
    finally {
        if ($null -ne $stream) {
            try { $stream.Close() } catch { }
        }
    }
}

function Add-NarvikJobOutput {
    param(
        [Parameter(Mandatory = $true)]
        $Job,

        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return
    }

    $combined = $Job.OutputTail + $Text
    if ($combined.Length -gt 131072) {
        $combined = $combined.Substring($combined.Length - 131072)
    }
    $Job.OutputTail = $combined
}

function Read-NarvikJobOutput {
    foreach ($job in @($script:ActiveJobs)) {
        $stdout = Read-NarvikFileChunk -Path $job.LogPath -Offset ([long]$job.ReadOffset)
        if (-not [string]::IsNullOrEmpty($stdout.Text)) {
            Add-NarvikJobOutput -Job $job -Text $stdout.Text
        }
        $job.ReadOffset = [long]$stdout.Offset

        $stderr = Read-NarvikFileChunk -Path $job.ErrorPath -Offset ([long]$job.ErrorReadOffset)
        if (-not [string]::IsNullOrEmpty($stderr.Text)) {
            Add-NarvikJobOutput -Job $job -Text $stderr.Text
        }
        $job.ErrorReadOffset = [long]$stderr.Offset
    }
}

function Merge-NarvikJobErrorLog {
    param(
        [Parameter(Mandatory = $true)]
        $Job
    )

    if (-not (Test-Path -LiteralPath $Job.ErrorPath -PathType Leaf)) {
        return
    }

    $errorText = Read-NarvikTextFileShared -Path $Job.ErrorPath
    if ([string]::IsNullOrEmpty($errorText)) {
        try { Remove-Item -LiteralPath $Job.ErrorPath -Force -ErrorAction SilentlyContinue } catch { }
        return
    }

    try {
        [System.IO.File]::AppendAllText($Job.LogPath, $errorText, [System.Text.Encoding]::Default)
        try { Remove-Item -LiteralPath $Job.ErrorPath -Force -ErrorAction SilentlyContinue } catch { }
    }
    catch {
        Write-NarvikLog -Level WARNING -Message "Could not merge stderr output into VM log '$($Job.LogPath)': $($_.Exception.Message)"
    }
}

function Record-NarvikFailure {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName,

        [datetime]$When = (Get-Date)
    )

    $entry = @{
        last_attempt = $When
        count        = 1
    }

    if ($script:State.failed_attempts.ContainsKey($VmName)) {
        $previous = $script:State.failed_attempts[$VmName]
        $entry.count = [int]$previous.count + 1
    }

    $script:State.failed_attempts[$VmName] = $entry
    Save-NarvikState

    Write-NarvikLog -Level WARNING -Message "Recorded failed attempt $($entry.count) for VM '$VmName' at $($When.ToString('yyyy-MM-dd HH:mm:ss'))."
}

function Clear-NarvikFailure {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName
    )

    if ($script:State.failed_attempts.ContainsKey($VmName)) {
        [void]$script:State.failed_attempts.Remove($VmName)
        Save-NarvikState
    }
}

function Set-NarvikDuplicateGuid {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName
    )

    if ($script:DuplicateGuid.ContainsKey($VmName)) {
        return
    }

    $script:DuplicateGuid[$VmName] = $true
    Save-NarvikState
    Write-NarvikLog -Level WARNING -Message "VM '$VmName' reported ANS1715E; the next backup will use -VMBACKUPUPDATEGUID and -mode IFFull."
}

function Clear-NarvikDuplicateGuid {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName
    )

    if (-not $script:DuplicateGuid.ContainsKey($VmName)) {
        return
    }

    [void]$script:DuplicateGuid.Remove($VmName)
    Save-NarvikState
    Write-NarvikLog -Level INFO -Message "VM '$VmName' completed successfully; duplicate GUID flag cleared."
}

function Start-NarvikBackupJob {
    param(
        [Parameter(Mandatory = $true)]
        $Selection
    )

    $vm = $Selection.VM
    $now = Get-Date
    $dateDirectory = Join-Path $script:VmLogDir $now.ToString('yyyy_MM_dd')
    New-Item -ItemType Directory -Force -Path $dateDirectory | Out-Null

    $safeName = ConvertTo-NarvikFileName -Name $vm.Name
    $logPath = Join-Path $dateDirectory ($now.ToString('HH_mm_ss') + '_' + $safeName + '.txt')
    $logPath = Get-NarvikUniquePath -Path $logPath
    $errorPath = [System.IO.Path]::ChangeExtension($logPath, '.stderr.txt')

    $sanitizedName = ConvertTo-NarvikDsmcVmName -Name $vm.Name
    $duplicateGuid = $script:DuplicateGuid.ContainsKey($vm.Name)
    $isFull = [bool]$Selection.IsFull -or $duplicateGuid

    $managementClass = ''
    $vmDatastoreClusters = @($vm.DatastoreClusters)
    if ($vmDatastoreClusters.Count -eq 1) {
        $managementClass = Get-NarvikManagementClass -DatastoreClusterName ([string]$vmDatastoreClusters[0])
    }
    if ([string]::IsNullOrWhiteSpace($managementClass)) {
        Write-NarvikLog -Level ERROR -Message "VM '$($vm.Name)' has no management class mapped from its datastore cluster; backup will not be started."
        return $null
    }

    $arguments = New-Object 'System.Collections.Generic.List[string]'
    [void]$arguments.Add('backup')
    [void]$arguments.Add('vm')
    [void]$arguments.Add((Quote-NarvikWindowsArgument -Argument $sanitizedName))
    [void]$arguments.Add('-vmmc=' + (Quote-NarvikWindowsArgument -Argument $managementClass))

    if ($duplicateGuid) {
        [void]$arguments.Add('-VMBACKUPUPDATEGUID')
    }

    if ($isFull) {
        [void]$arguments.Add('-mode')
        [void]$arguments.Add('IFFull')
    }

    if ($script:Config.dsmc_use_preview) {
        [void]$arguments.Add('-preview')
    }

    [void]$arguments.Add('-optfile=' + (Quote-NarvikWindowsArgument -Argument $script:Config.dsmc_opt_file))
    [void]$arguments.Add('-asnodename=' + (Quote-NarvikWindowsArgument -Argument $script:Config.dsmc_asnodename))

    $argumentString = $arguments -join ' '
    $commandLine = (Quote-NarvikWindowsArgument -Argument ([string]$script:Config.dsmc_path)) + ' ' + $argumentString
    $modeText = 'Incremental'
    if ($isFull) {
        $modeText = 'Full'
    }

    Write-NarvikLog -Level DEBUG -Message "Executing dsmc in $modeText backup mode for VM '$($vm.Name)' with working directory '$($script:Config.dsmc_dir)': $commandLine"

    # WorkingDirectory applies only to this child process; the daemon's own location is unchanged.
    $startParameters = @{
        FilePath               = $script:Config.dsmc_path
        WorkingDirectory       = $script:Config.dsmc_dir
        ArgumentList           = $argumentString
        RedirectStandardOutput = $logPath
        RedirectStandardError  = $errorPath
        WindowStyle            = 'Hidden'
        PassThru               = $true
        ErrorAction            = 'Stop'
    }

    try {
        $process = Start-Process @startParameters
    }
    catch {
        Write-NarvikLog -Level ERROR -Message "Failed to start $modeText backup for VM '$($vm.Name)': $($_.Exception.Message). Command: $commandLine; working directory: '$($script:Config.dsmc_dir)'"
        Record-NarvikFailure -VmName $vm.Name -When $now
        return $null
    }

    $job = [pscustomobject]@{
        VmName          = [string]$vm.Name
        VM              = $vm
        HostName        = [string]$vm.HostName
        ClusterName     = [string]$vm.ClusterName
        ClusterPriority = [int]$vm.ClusterPriority
        ResourcePoolPriority = [int]$vm.ResourcePoolPriority
        Mode            = $modeText
        IsFull          = [bool]$isFull
        Process         = $process
        LogPath         = $logPath
        ErrorPath       = $errorPath
        StartTime       = $now
        ReadOffset      = [long]0
        ErrorReadOffset = [long]0
        OutputTail      = ''
        SanitizedName   = $sanitizedName
        ArgumentString  = $argumentString
    }

    [void]$script:ActiveJobs.Add($job)
    Write-NarvikLog -Level INFO -Message "Started $modeText backup for VM '$($vm.Name)' (PID $($process.Id), host '$($vm.HostName)', cluster '$($vm.ClusterName)', size $($vm.TotalSizeGB) GB)."
    return $job
}

function Update-NarvikPendingMonitoring {
    $pending = @()
    if ($null -ne $script:VCache) {
        $pending = @(Get-NarvikPendingVMs -Now (Get-Date))
    }
    $script:PendingVMs = $pending

    $content = [string]$pending.Count + "`r`n"
    Write-NarvikAtomicText -Path (Join-Path $script:MonitoringDir 'pending_count.txt') -Content $content
}

function Invoke-NarvikAnsErrorScan {
    param(
        [Parameter(Mandatory = $true)]
        $Job,

        [AllowEmptyString()]
        [string]$Content
    )

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return
    }

    $criticalHits = @{}
    foreach ($line in @($Content -split "\r?\n")) {
        $lineMatches = [regex]::Matches($line, 'ANS\d+E')
        if ($lineMatches.Count -eq 0) {
            continue
        }

        # One warning per matching line, starting at the first code.
        Write-NarvikLog -Level WARNING -Message "VM '$($Job.VmName)' output: $($line.Substring([int]$lineMatches[0].Index))"

        foreach ($found in $lineMatches) {
            $code = [string]$found.Value
            if ($script:CriticalAnsErrors -contains $code) {
                if (-not $criticalHits.ContainsKey($code)) {
                    $criticalHits[$code] = New-Object 'System.Collections.Generic.List[string]'
                }
                [void]$criticalHits[$code].Add($line.Substring([int]$found.Index))
            }
        }
    }

    if ($criticalHits.Count -eq 0) {
        return
    }

    if (-not (Test-NarvikMailEnabled)) {
        Write-NarvikLog -Level DEBUG -Message "SMTP server is not configured; critical dsmc error alert for VM '$($Job.VmName)' skipped."
        return
    }

    $now = Get-Date
    $dueCodes = New-Object 'System.Collections.Generic.List[string]'
    foreach ($code in @($criticalHits.Keys | Sort-Object)) {
        $lastAlert = $null
        if ($script:State.critical_error_alerts.ContainsKey($code)) {
            $lastAlert = $script:State.critical_error_alerts[$code]
        }

        if ($null -ne $lastAlert) {
            $ageHours = ($now - $lastAlert).TotalHours
            if ($ageHours -lt 6) {
                Write-NarvikLog -Level INFO -Message "Critical dsmc error $code was already reported at $($lastAlert.ToString('yyyy-MM-dd HH:mm:ss')); alert suppressed for 6 hours."
                continue
            }
        }

        [void]$dueCodes.Add($code)
    }

    if ($dueCodes.Count -eq 0) {
        return
    }

    $sentCodes = New-Object 'System.Collections.Generic.List[string]'
    foreach ($code in $dueCodes) {
        $body = New-Object System.Text.StringBuilder
        [void]$body.AppendLine("Narvik detected critical dsmc error $code while backing up a VM.")
        [void]$body.AppendLine('')
        [void]$body.AppendLine("VM: '$($Job.VmName)'")
        [void]$body.AppendLine("Host: '$($Job.HostName)'")
        [void]$body.AppendLine("Mode: $($Job.Mode)")
        [void]$body.AppendLine("Backup started: $($Job.StartTime.ToString('yyyy-MM-dd HH:mm:ss'))")
        [void]$body.AppendLine("Reported at: $($now.ToString('yyyy-MM-dd HH:mm:ss'))")
        [void]$body.AppendLine('')
        [void]$body.AppendLine('Error message(s):')
        foreach ($message in @($criticalHits[$code])) {
            [void]$body.AppendLine("  - $message")
        }

        $subject = "[Narvik] Critical dsmc error $code on VM '$($Job.VmName)'"
        $sent = Send-NarvikMail -Subject $subject -Body $body.ToString()
        if ($sent) {
            [void]$sentCodes.Add($code)
            $script:State.critical_error_alerts[$code] = $now
        }
    }

    if ($sentCodes.Count -gt 0) {
        Save-NarvikState
        Write-NarvikLog -Level INFO -Message "Critical dsmc error alert sent for $($sentCodes.Count) error type(s) on VM '$($Job.VmName)'."
    }
}

function Get-NarvikAnsFragments {
    # Returns, for every line containing an ANS<digits>E or ANS<digits>W code,
    # the text from the first code match onward. Used to summarize dsmc failures.
    param(
        [string]$Content
    )

    $fragments = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrEmpty($Content)) {
        return ,$fragments.ToArray()
    }

    foreach ($line in ($Content -split "\r?\n")) {
        $match = [regex]::Match($line, 'ANS\d+[EW]')
        if ($match.Success) {
            $fragments.Add($line.Substring($match.Index))
        }
    }

    return ,$fragments.ToArray()
}

function Complete-NarvikJobs {
    $completedAny = $false
    $now = Get-Date

    foreach ($job in @($script:ActiveJobs)) {
        $hasExited = $false
        try {
            $hasExited = [bool]$job.Process.HasExited
        }
        catch {
            $hasExited = $true
        }

        if (-not $hasExited) {
            continue
        }

        $completedAny = $true
        Merge-NarvikJobErrorLog -Job $job
        $content = Read-NarvikTextFileShared -Path $job.LogPath
        $remainingError = Read-NarvikTextFileShared -Path $job.ErrorPath
        if (-not [string]::IsNullOrEmpty($remainingError)) {
            $content = $content + "`r`n" + $remainingError
        }

        Invoke-NarvikAnsErrorScan -Job $job -Content $content

        $exitCode = $null
        try {
            $exitCode = [int]$job.Process.ExitCode
        }
        catch {
            $exitCode = $null
        }

        $objectsBackedUp = ($content -match 'Total number of objects backed up: +1')
        $success = ($null -ne $exitCode -and $exitCode -eq 0 -and $objectsBackedUp)
        if ($success) {
            Write-NarvikLog -Level INFO -Message "Backup completed successfully for VM '$($job.VmName)' (PID $($job.Process.Id), exit code 0)."

            # The last backup is the time the backup started, not when it finished.
            # The value is also recorded by VM name so that a vCenter snapshot that
            # was being collected while this job ran still receives it after the swap.
            $script:RecentCompletions[$job.VmName] = $job.StartTime
            try {
                $job.VM.LastBackup = $job.StartTime
            }
            catch {
            }

            if ($content -match 'Incremental Forever - Full') {
                # Same rule as the last backup: the start time, not the completion time.
                $script:LastFull[$job.VmName] = $job.StartTime
                Save-NarvikLastFull
                Write-NarvikLog -Level INFO -Message "Full backup recorded for VM '$($job.VmName)'."
            }

            Clear-NarvikFailure -VmName $job.VmName
            Clear-NarvikDuplicateGuid -VmName $job.VmName
        }
        else {
            $failureDetail = 'exit code unavailable'
            if ($null -ne $exitCode -and $exitCode -ne 0) {
                $failureDetail = "exit code $exitCode"
            }
            elseif ($null -ne $exitCode -and -not $objectsBackedUp) {
                $failureDetail = 'exit code 0 but output did not report a backed-up object'
            }
            Write-NarvikLog -Level ERROR -Message "Backup failed for VM '$($job.VmName)' (PID $($job.Process.Id), $failureDetail)."

            foreach ($fragment in @(Get-NarvikAnsFragments -Content $content)) {
                Write-NarvikLog -Level INFO -Message "VM '$($job.VmName)' dsmc match: $fragment"
            }

            foreach ($contentLine in @($content -split "\r?\n")) {
                Write-NarvikLog -Level DEBUG -Message "VM '$($job.VmName)' log: $contentLine"
            }

            Record-NarvikFailure -VmName $job.VmName -When $now

            if ($content -match 'ANS1715E') {
                Set-NarvikDuplicateGuid -VmName $job.VmName
            }
        }

        [void]$script:ActiveJobs.Remove($job)
        Update-NarvikPendingMonitoring
    }

    return $completedAny
}

function Write-NarvikStats {
    param(
        [switch]$Force
    )

    $now = Get-Date
    $pending = @()
    if ($null -ne $script:VCache) {
        $pending = @(Get-NarvikPendingVMs -Now $now)
    }
    $script:PendingVMs = $pending

    $activeNames = @{}
    foreach ($job in @($script:ActiveJobs)) {
        $activeNames[[string]$job.VmName] = $true
    }

    $waiting = @($pending | Where-Object { -not $activeNames.ContainsKey([string]$_.Name) })
    $waitingSize = 0.0
    foreach ($vm in $waiting) {
        $waitingSize += [double]$vm.TotalSizeGB
    }

    $activeIncremental = @($script:ActiveJobs | Where-Object { -not $_.IsFull })
    $activeFull = @($script:ActiveJobs | Where-Object { $_.IsFull })

    $signatureParts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($job in @($script:ActiveJobs | Sort-Object -Property VmName)) {
        [void]$signatureParts.Add("$($job.VmName)|$($job.Mode)|$($job.Process.Id)")
    }
    [void]$signatureParts.Add("waiting=$($waiting.Count)|size=$([math]::Round($waitingSize, 2))")
    $signature = $signatureParts -join ';'

    $elapsed = ($now - $script:LastStatsLog).TotalSeconds
    if (-not $Force -and $signature -eq $script:LastStatsSignature -and $elapsed -lt 60) {
        return
    }

    $script:LastStatsLog = $now
    $script:LastStatsSignature = $signature

    if ($null -ne $script:VCache) {
        $cacheAgeMinutes = [math]::Round(($now - $script:VCache.CollectedAt).TotalMinutes, 1)
        $baselineText = (Get-NarvikBaseline -Now $now).ToString('yyyy-MM-dd HH:mm:ss')
        Write-NarvikLog -Level DEBUG -Message "Inventory cache collected at $($script:VCache.CollectedAt.ToString('yyyy-MM-dd HH:mm:ss')) (age $cacheAgeMinutes minute(s)); incremental baseline $baselineText; pending $($pending.Count) VM(s)."
    }

    foreach ($vm in @($waiting | Sort-Object -Property Name)) {
        Write-NarvikLog -Level INFO -Message "Pending VM: $($vm.Name), $([math]::Round([double]$vm.TotalSizeGB, 2)) GB"
    }
    Write-NarvikLog -Level INFO -Message "Pending waiting: $($waiting.Count) VM(s), $([math]::Round($waitingSize, 2)) GB."

    foreach ($job in @($activeIncremental | Sort-Object -Property StartTime)) {
        $elapsedMinutes = [math]::Round(($now - $job.StartTime).TotalMinutes, 1)
        Write-NarvikLog -Level INFO -Message "Active pending backup: VM '$($job.VmName)', size $($job.VM.TotalSizeGB) GB, started $($job.StartTime.ToString('yyyy-MM-dd HH:mm:ss')), elapsed $elapsedMinutes minute(s), PID $($job.Process.Id)."
    }

    foreach ($job in @($activeFull | Sort-Object -Property StartTime)) {
        $elapsedMinutes = [math]::Round(($now - $job.StartTime).TotalMinutes, 1)
        Write-NarvikLog -Level INFO -Message "Active full backup: VM '$($job.VmName)', size $($job.VM.TotalSizeGB) GB, started $($job.StartTime.ToString('yyyy-MM-dd HH:mm:ss')), elapsed $elapsedMinutes minute(s), PID $($job.Process.Id)."
    }

    if ($script:ActiveJobs.Count -eq 0) {
        Write-NarvikLog -Level INFO -Message 'No active backups.'
    }
}

function Invoke-NarvikIdleMaintenance {
    if ($null -eq $script:VCache) {
        return
    }

    $now = Get-Date
    if ($null -ne $script:State.last_idle -and ($now - $script:State.last_idle).TotalHours -lt 20) {
        return
    }

    Write-NarvikLog -Level INFO -Message 'Idle maintenance started: no backup will be started in this cycle.'

    Write-NarvikLog -Level INFO -Message "Eligible VMs: $(@($script:EligibleVMs).Count)."
    foreach ($vm in @($script:EligibleVMs | Sort-Object -Property @{ Expression = { [int]$_.ClusterPriority }; Descending = $true }, @{ Expression = { [int]$_.ResourcePoolPriority }; Descending = $true }, FolderPath, Name)) {
        $lastBackupText = 'never'
        if ($null -ne $vm.LastBackup) {
            $lastBackupText = $vm.LastBackup.ToString('yyyy-MM-dd HH:mm:ss')
        }
        $lastFullText = 'never'
        if ($script:LastFull.ContainsKey($vm.Name)) {
            $lastFullText = $script:LastFull[$vm.Name].ToString('yyyy-MM-dd HH:mm:ss')
        }
        Write-NarvikLog -Level INFO -Message "Eligible VM '$($vm.Name)': folder '$($vm.FolderPath)', host '$($vm.HostName)', cluster '$($vm.ClusterName)' (priority $($vm.ClusterPriority), max_threads $(Get-NarvikClusterMaxThreadsSetting -ClusterName $vm.ClusterName)), resource pool '$($vm.ResourcePoolName)' (priority $($vm.ResourcePoolPriority)), size $($vm.TotalSizeGB) GB, last incremental $lastBackupText, last full $lastFullText."
    }

    Write-NarvikLog -Level INFO -Message "Non-eligible VMs: $(@($script:NonEligibleVMs).Count)."
    foreach ($entry in @($script:NonEligibleVMs | Sort-Object -Property { $_.VM.Name })) {
        Write-NarvikLog -Level INFO -Message "Non-eligible VM '$($entry.VM.Name)': $(@($entry.Reasons) -join '; ')."
    }

    Write-NarvikLog -Level INFO -Message 'No backup action was taken during idle maintenance.'

    $script:State.last_idle = $now
    Save-NarvikState
    Rotate-NarvikLog
}

function Stop-NarvikActiveJobs {
    param(
        [switch]$Force
    )

    foreach ($job in @($script:ActiveJobs)) {
        if ($null -eq $job.Process) {
            continue
        }

        try {
            if (-not $job.Process.HasExited) {
                if ($Force) {
                    Write-NarvikLog -Level WARNING -Message "Terminating backup process for VM '$($job.VmName)' (PID $($job.Process.Id))."
                    $job.Process.Kill()
                    [void]$job.Process.WaitForExit(30000)
                }
            }
        }
        catch {
            Write-NarvikLog -Level ERROR -Message "Could not terminate backup process for VM '$($job.VmName)': $($_.Exception.Message)"
        }
    }
}

function Stop-NarvikChildProcesses {
    foreach ($job in @($script:ActiveJobs)) {
        if ($null -eq $job.Process) {
            continue
        }

        try {
            if (-not $job.Process.HasExited) {
                $job.Process.Kill()
                [void]$job.Process.WaitForExit(10000)
            }
        }
        catch {
        }
    }

    $script:ActiveJobs.Clear()
}
