function Initialize-NarvikLog {
    $logDirectory = Join-Path $script:RootPath 'log/narvik'
    $oldDirectory = Join-Path $logDirectory 'old'
    New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
    New-Item -ItemType Directory -Force -Path $oldDirectory | Out-Null

    $logFile = Join-Path $logDirectory 'log.txt'
    if (Test-Path -LiteralPath $logFile -PathType Leaf) {
        $lastWrite = (Get-Item -LiteralPath $logFile).LastWriteTime
        $dateDirectory = Join-Path $oldDirectory $lastWrite.ToString('yyyy_MM_dd')
        New-Item -ItemType Directory -Force -Path $dateDirectory | Out-Null

        $destination = Join-Path $dateDirectory ('log_' + $lastWrite.ToString('HH_mm_ss') + '.txt')
        $destination = Get-NarvikUniquePath -Path $destination

        try {
            Move-Item -LiteralPath $logFile -Destination $destination -Force -ErrorAction Stop
        }
        catch {
            throw [System.Exception]::new("Failed to rotate existing log file '$logFile': $($_.Exception.Message)")
        }
    }

    $script:LogFilePath = $logFile
    try {
        $script:LogWriter = [System.IO.File]::CreateText($logFile)
        $script:LogWriter.AutoFlush = $true

        # Confirm the log file is really writable before stdout is turned off.
        # Lines written to stdout before the log was open (for example, configuration
        # warnings) are copied into the log file first. StartupLog is kept, because the
        # fatal e-mail uses it as its attachment when the log file is not available.
        foreach ($startupEntry in $script:StartupLog) {
            $script:LogWriter.WriteLine($startupEntry)
        }

        $probeLine = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' [INFO] Log file opened.'
        $script:LogWriter.WriteLine($probeLine)
        $script:LogWriter.Flush()
    }
    catch {
        $writeError = $_.Exception.Message
        try {
            if ($null -ne $script:LogWriter) {
                $script:LogWriter.Close()
            }
        }
        catch {
        }
        $script:LogWriter = $null
        throw [System.Exception]::new("Failed to write log file '$logFile': $writeError")
    }

    $script:LogToStdout = $false
}

function Rotate-NarvikLog {
    if ($null -eq $script:LogWriter -or [string]::IsNullOrWhiteSpace($script:LogFilePath)) {
        return
    }

    $currentLog = $script:LogFilePath
    $lastWrite = Get-Date
    try {
        if (Test-Path -LiteralPath $currentLog -PathType Leaf) {
            $lastWrite = (Get-Item -LiteralPath $currentLog).LastWriteTime
        }
    }
    catch {
    }

    try {
        $script:LogWriter.Flush()
        $script:LogWriter.Close()
    }
    catch {
    }
    $script:LogWriter = $null

    $oldDirectory = Join-Path $script:RootPath ('log/narvik/old/' + $lastWrite.ToString('yyyy_MM_dd'))
    New-Item -ItemType Directory -Force -Path $oldDirectory | Out-Null
    $destination = Join-Path $oldDirectory ('log_' + $lastWrite.ToString('HH_mm_ss') + '.txt')
    $destination = Get-NarvikUniquePath -Path $destination

    try {
        Move-Item -LiteralPath $currentLog -Destination $destination -Force -ErrorAction Stop
    }
    catch {
        try {
            $script:LogWriter = [System.IO.File]::AppendText($currentLog)
            $script:LogWriter.AutoFlush = $true
        }
        catch {
        }
        Write-NarvikLog -Level ERROR -Message "Failed to rotate log file '$currentLog': $($_.Exception.Message)"
        return
    }

    try {
        $script:LogWriter = [System.IO.File]::CreateText($currentLog)
        $script:LogWriter.AutoFlush = $true
    }
    catch {
        $script:LogWriter = $null
        $script:LogToStdout = $true
        Write-NarvikLog -Level ERROR -Message "Failed to create new log file '$currentLog': $($_.Exception.Message)"
        return
    }

    Write-NarvikLog -Level INFO -Message "Log rotated to '$destination'."
}

function Close-NarvikLogWriter {
    if ($null -ne $script:LogWriter) {
        try {
            $script:LogWriter.Flush()
            $script:LogWriter.Close()
        }
        catch {
        }
        $script:LogWriter = $null
    }
}

function Initialize-NarvikDirectories {
    $script:ControlDir = Join-Path $script:RootPath 'control'
    $script:LogDir = Join-Path $script:RootPath 'log/narvik'
    $script:VmLogDir = Join-Path $script:RootPath 'log/vm'
    $script:MonitoringDir = Join-Path $script:RootPath 'monitoring'

    New-Item -ItemType Directory -Force -Path $script:ControlDir | Out-Null
    New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $script:LogDir 'old') | Out-Null
    New-Item -ItemType Directory -Force -Path $script:VmLogDir | Out-Null
    New-Item -ItemType Directory -Force -Path $script:MonitoringDir | Out-Null
}

function Acquire-NarvikProcessLock {
    $processFile = Join-Path $script:ControlDir 'process.txt'
    $script:ProcessLockFile = $processFile

    $currentProcess = [System.Diagnostics.Process]::GetCurrentProcess()
    $currentName = $currentProcess.ProcessName
    $currentStart = $currentProcess.StartTime.ToString('o')

    $processInfo = [pscustomobject]@{
        pid        = $PID
        name       = $currentName
        started_at = $currentStart
    }
    $json = $processInfo | ConvertTo-Json -Depth 5

    if (Test-Path -LiteralPath $processFile -PathType Leaf) {
        $stale = $true
        try {
            $existing = Get-Content -LiteralPath $processFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $existing -and $null -ne $existing.pid) {
                $existingPid = [int]$existing.pid
                $existingName = [string]$existing.name
                $existingStart = $null
                if ($null -ne $existing.started_at) {
                    $existingStart = ConvertFrom-NarvikIsoDate -Value ([string]$existing.started_at)
                }

                $alive = Get-Process -Id $existingPid -ErrorAction SilentlyContinue
                if ($null -ne $alive) {
                    $nameMatches = ($alive.ProcessName -ieq $existingName)
                    $startMatches = $true
                    if ($null -ne $existingStart) {
                        try {
                            $startMatches = ([math]::Abs(($alive.StartTime - $existingStart).TotalSeconds) -lt 5)
                        }
                        catch {
                            $startMatches = $true
                        }
                    }

                    if ($nameMatches -and $startMatches) {
                        Throw-NarvikFatal -Message "Another Narvik instance is already running with PID $existingPid and executable '$existingName'." -Code 3
                    }
                }
            }
        }
        catch [System.Exception] {
            if ($_.Exception.Message -like 'Another Narvik instance*') {
                throw
            }
            Write-NarvikLog -Level WARNING -Message "Existing process control file '$processFile' is invalid and will be replaced."
        }

        if ($stale) {
            try {
                Remove-Item -LiteralPath $processFile -Force -ErrorAction Stop
            }
            catch {
                Throw-NarvikFatal -Message "Cannot remove stale process control file '$processFile': $($_.Exception.Message)" -Code 1
            }
        }
    }

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $stream = [System.IO.File]::Open($processFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
            $script:ProcessLockStream = $stream
            return
        }
        catch {
            if ($attempt -eq 3) {
                Throw-NarvikFatal -Message "Cannot create process control file '$processFile': $($_.Exception.Message)" -Code 3
            }
            Start-Sleep -Milliseconds 200
        }
    }
}

function Release-NarvikProcessLock {
    if ($null -ne $script:ProcessLockStream) {
        try {
            $script:ProcessLockStream.Close()
        }
        catch {
        }
        $script:ProcessLockStream = $null
    }

    if ($null -eq $script:ProcessLockFile -or -not (Test-Path -LiteralPath $script:ProcessLockFile -PathType Leaf)) {
        return
    }

    try {
        $existing = Get-Content -LiteralPath $script:ProcessLockFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($null -ne $existing -and [int]$existing.pid -eq $PID) {
            Remove-Item -LiteralPath $script:ProcessLockFile -Force -ErrorAction Stop
        }
    }
    catch {
    }
}

function Initialize-Narvik {
    $rootValue = $script:RootPathArgument
    if ([string]::IsNullOrWhiteSpace($rootValue)) {
        Throw-NarvikFatal -Message 'The root directory is required. Usage: Narvik.ps1 <directory>.' -Code 1
    }

    if ($PSVersionTable.PSVersion -lt [Version]'5.1') {
        Throw-NarvikFatal -Message "Narvik requires PowerShell 5.1 or later; detected version $($PSVersionTable.PSVersion)." -Code 1
    }

    try {
        # GetFullPath resolves relative paths against the .NET process directory, which
        # does not follow PowerShell's current location. Resolve against that instead.
        $basePath = (Get-Location -PSProvider FileSystem).ProviderPath
        $script:RootPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($basePath, $rootValue))
    }
    catch {
        Throw-NarvikFatal -Message "Invalid root directory '$rootValue': $($_.Exception.Message)" -Code 1
    }

    if (-not (Test-Path -LiteralPath $script:RootPath -PathType Container)) {
        try {
            New-Item -ItemType Directory -Force -Path $script:RootPath -ErrorAction Stop | Out-Null
        }
        catch {
            Throw-NarvikFatal -Message "Cannot create root directory '$($script:RootPath)': $($_.Exception.Message)" -Code 1
        }
    }

    try {
        $probe = Join-Path $script:RootPath ('.narvik_write_test_' + [System.IO.Path]::GetRandomFileName())
        [System.IO.File]::WriteAllText($probe, 'test')
        Remove-Item -LiteralPath $probe -Force -ErrorAction Stop
    }
    catch {
        Throw-NarvikFatal -Message "Root directory '$($script:RootPath)' is not writable: $($_.Exception.Message)" -Code 1
    }

    Initialize-NarvikDirectories
    Acquire-NarvikProcessLock

    # The configuration is read before the log is opened: an invalid configuration
    # is a fatal error reported on stdout, and it must not rotate the existing log.
    # Until the log is open, Write-NarvikLog keeps writing to stdout and buffers the lines.
    Update-NarvikRuntimeConfig

    Initialize-NarvikLog

    Load-NarvikState
    Load-NarvikLastFull
    Load-NarvikIndependentDisks

    if ($script:Config.check_administrator_privilege) {
        if (-not (Test-NarvikIsAdministrator)) {
            Throw-NarvikFatal -Message 'Narvik must run as NT AUTHORITY\SYSTEM or as a member of the Administrators group.' -Code 1
        }
    }
    else {
        Write-NarvikLog -Level INFO -Message 'Administrator privilege check is disabled by configuration.'
    }

    if ($script:Config.bypass_security) {
        Write-NarvikLog -Level WARNING -Message 'File ACL checks are disabled by configuration (bypass_security).'
    }

    $powerCliModule = Get-Module -ListAvailable -Name 'VMware.VimAutomation.Core' | Select-Object -First 1
    if ($null -eq $powerCliModule) {
        Throw-NarvikFatal -Message "VMware PowerCLI module 'VMware.VimAutomation.Core' is not installed." -Code 1
    }

    try {
        Import-Module 'VMware.VimAutomation.Core' -ErrorAction Stop
    }
    catch {
        Throw-NarvikFatal -Message "Failed to import VMware PowerCLI: $($_.Exception.Message)" -Code 1
    }

    Write-NarvikLog -Level INFO -Message "Narvik $($script:ScriptVersion) starting."
    Write-NarvikLog -Level INFO -Message "Root directory: '$($script:RootPath)'."
    Write-NarvikLog -Level INFO -Message "Process ID: $PID."
    Write-NarvikLog -Level INFO -Message "Debug logging: $($script:Config.debug)."
    Write-NarvikLog -Level INFO -Message "vCenter: '$($script:Config.vcenter_server):$($script:Config.vcenter_port)' as '$($script:Config.vcenter_user)'."
    Write-NarvikLog -Level INFO -Message "dsmc: '$($script:Config.dsmc_path)'; optfile: '$($script:Config.dsmc_opt_file)'; asnodename: '$($script:Config.dsmc_asnodename)'; preview mode: $($script:Config.dsmc_use_preview)."
    Write-NarvikLog -Level INFO -Message "Maximum concurrent backups: $($script:Config.max_backup_threads)."

    if ($script:Config.vcenter_ignore_certificate) {
        Write-NarvikLog -Level WARNING -Message 'vCenter certificate validation is disabled by configuration.'
    }
}
