<#
.SYNOPSIS
    Narvik - VMware VM snapshot backup coordinator for IBM Storage Protect.

.DESCRIPTION
    Narvik runs continuously on Windows Server 2019. It collects inventory from
    vCenter with PowerCLI, decides which VMs need a snapshot backup, starts
    dsmc.exe processes and monitors their output.

    The script is intentionally self-contained. It creates its runtime folders
    and control files below the selected root directory.

.PARAMETER RootPath
    Mandatory root directory, passed as the first positional argument:
    Narvik.ps1 <directory>. Relative paths are resolved from the current
    PowerShell location. When it is omitted, Narvik writes an error to
    standard output and exits with code 1.

.NOTES
    Target: Windows PowerShell 5.1 or later on Windows Server 2019.
#>
[CmdletBinding()]
param(
    # Not marked Mandatory on purpose: a missing value must be reported on stdout
    # through the normal fatal-error path instead of PowerShell's interactive prompt.
    [Parameter(Position = 0)]
    [string]$RootPath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:ScriptVersion = '1.0.0'
# The param variable lives in the script scope; save it before it is replaced.
$script:RootPathArgument = $RootPath
$script:RootPath = $null
$script:ControlDir = $null
$script:LogDir = $null
$script:VmLogDir = $null
$script:MonitoringDir = $null
$script:LogFilePath = $null
$script:LogWriter = $null
$script:LogToStdout = $true
$script:LogLevel = 'INFO'
$script:StartupLog = New-Object 'System.Collections.Generic.List[string]'
$script:Config = $null
$script:VCenterFingerprint = $null
$script:VCache = $null
$script:VCacheRefreshedThisLoop = $false
$script:LastVCenterAttempt = [datetime]::MinValue
# Windows PowerShell 5.1 wraps the output of New-Object in a PSObject; '@(...)' over a
# wrapped List[object] then fails with "Argument types do not match". ::new() avoids that.
$script:ActiveJobs = [System.Collections.Generic.List[object]]::new()
$script:EligibleVMs = @()
$script:NonEligibleVMs = @()
$script:PendingVMs = @()
$script:DuplicateNameCases = @()
$script:UnsupportedNameCases = @()
$script:DatastoreClusterCases = @()
$script:ManagementClassCases = @()
$script:DiskSizeCases = @()
$script:LastFull = @{}
# Successful incremental backups by VM name: the backup start time. Applied to the next
# vCenter snapshot so a refresh that was running during the backup keeps the value.
# Entries are removed once the Notes timestamp is at least as new.
$script:RecentCompletions = @{}
$script:IndependentDisks = @()
$script:DuplicateGuid = @{}
# Maximum simultaneous backups on one ESXi host when the one-per-host rule is
# relaxed as a fallback (see Test-NarvikVmAllocable). Counts the running ones.
$script:SharedHostMaxBackups = 4
# Error codes that are always reported by email when found in dsmc output.
$script:CriticalAnsErrors = @('ANS1030E', 'ANS1706E', 'ANS4169E', 'ANS4200E')
$script:State = @{
    failed_attempts = @{}
    duplicate_guid = @()
    last_idle = $null
    duplicate_name_alerts = @{}
    inventory_rule_alerts = @{}
    disk_size_alerts = @{}
    critical_error_alerts = @{}
}
$script:ProcessLockStream = $null
$script:ProcessLockFile = $null
$script:StopRequested = $false
$script:SuspendRequested = $false
$script:FullWindowClosedLogged = $false
$script:AbortRequested = $false
$script:LastStatsLog = [datetime]::MinValue
$script:LastStatsSignature = ''
$script:FatalExitCode = 0
$script:Initialized = $false
$script:ExitCode = 0
$script:NonEligibleSignature = ''
$script:LastConfigError = ''
# Last-write time of the config.json that was accepted; a change triggers the INFO log.
$script:AcceptedConfigWriteTime = $null
# Time of the last configuration-error email; a new one is sent at most once per hour.
$script:LastConfigErrorMailTime = $null
# Set when tag collection aborted the inventory because the snapshot tag rule is
# configured; the cache refresh consumes it and discards cached tag data.
$script:TagRuleFailure = $false
$script:LastTagRuleErrorLogged = [datetime]::MinValue


$script:LibDir = Join-Path $PSScriptRoot 'lib'
. (Join-Path $script:LibDir 'Narvik.Core.ps1')
. (Join-Path $script:LibDir 'Narvik.Config.ps1')
. (Join-Path $script:LibDir 'Narvik.State.ps1')
. (Join-Path $script:LibDir 'Narvik.Startup.ps1')
. (Join-Path $script:LibDir 'Narvik.Mail.ps1')
. (Join-Path $script:LibDir 'Narvik.VCenter.ps1')
. (Join-Path $script:LibDir 'Narvik.Eligibility.ps1')
. (Join-Path $script:LibDir 'Narvik.Alerts.ps1')
. (Join-Path $script:LibDir 'Narvik.Scheduling.ps1')
. (Join-Path $script:LibDir 'Narvik.Backup.ps1')
. (Join-Path $script:LibDir 'Narvik.MainLoop.ps1')

$script:ExitCode = 0
$fatalMessage = ''

try {
    Initialize-Narvik
    $script:Initialized = $true
    Invoke-NarvikMain
    $script:ExitCode = 0
}
catch {
    $fatalMessage = $_.Exception.Message
    $code = 2
    if (-not $script:Initialized) {
        $code = 1
    }
    if ($script:FatalExitCode -gt 0) {
        $code = $script:FatalExitCode
    }
    $script:ExitCode = $code

    try {
        Write-NarvikLog -Level ERROR -Message "Fatal error: $fatalMessage"
        # Anticipated fatal errors (Throw-NarvikFatal) already carry a clear message;
        # the stack trace is only logged for unexpected exceptions.
        $isAnticipated = $_.Exception.Data.Contains('NarvikFatal')
        if (-not $isAnticipated -and -not [string]::IsNullOrWhiteSpace($_.ScriptStackTrace)) {
            Write-NarvikLog -Level ERROR -Message "Stack trace: $($_.ScriptStackTrace)"
        }
    }
    catch {
    }

    try {
        Stop-NarvikActiveJobs -Force
    }
    catch {
    }

    Close-NarvikLogWriter
    Send-NarvikFatalEmail -ExitCode $code -ErrorMessage $fatalMessage
}
finally {
    try {
        Stop-NarvikChildProcesses
    }
    catch {
    }

    Close-NarvikLogWriter

    try {
        Release-NarvikProcessLock
    }
    catch {
    }
}

exit $script:ExitCode
