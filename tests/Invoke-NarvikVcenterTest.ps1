#Requires -Version 5.1
<#
.SYNOPSIS
    End-to-end tests for Narvik against a real vCenter.

.DESCRIPTION
    Runs Narvik.ps1 against a live vCenter with dsmc_fake.ps1 standing in for
    dsmc. Every phase is independent and writes to its own runtime root outside
    this repository, so the repository is never used as a runtime directory.

    Phases:

      Preconditions  Parser, unit tests, dsmc fake, read-only source audit,
                     vCenter connection, lab guard rails, storage policy check.
      Inventory      Read-only inventory, tag rule against live entities,
                     eligibility consistency, read-only proof.
      Control        stop.txt, abort.txt, second instance exit code 3,
                     configuration reload failure handling.
      Config         Configuration validation errors (a valid config is not
                     required; these runs abort before connecting).
      Fixtures       Creates the nk- test VMs and folders (needs the vCenter
                     storage policy service).
      Tags           Tag opt-out rule for resource pool, datastore, datastore
                     cluster and folder, using fixtures and live tags.
      Backup         Incremental backup, dsmc command line, preview on and off.
      Full           Full backup inside the weekend window, last_full.json.
      Retry          ANS1715E duplicate GUID retry, failure backoff.
      Teardown       Deletes only nk- test objects and the runtime roots.

.SAFETY
    The suite may only create, modify and delete VMs and folders. Every object
    it creates is named with the nk- prefix and Teardown refuses to delete
    anything without that prefix. It never powers a VM on or off, and it never
    creates, modifies or deletes any other entity type (clusters, datastores,
    datastore clusters, resource pools, networks, tags, permissions, ...).

    The daemon is read only: Preconditions greps Narvik.ps1 for vCenter write
    cmdlets and methods and fails if any are present.

.PARAMETER Phase
    One or more phase names, or All (default). Phases always run in the order
    documented above, regardless of the order given here.

.PARAMETER VcenterServer
    vCenter host name or address. Defaults to the documented lab vCenter.

.PARAMETER VcenterPort
    vCenter port. Defaults to 443.

.PARAMETER VcenterUser
    vCenter user. Defaults to the documented lab user.

.PARAMETER PasswordFile
    File containing the vCenter password. Defaults to
    ../narvik_temp/vcenter_password.txt relative to this repository, which is
    the documented runtime root of the lab. The password is never stored in
    this repository and never printed by this script.

.PARAMETER RunRoot
    Directory that holds the per-phase runtime roots and the fixture manifest.
    Defaults to ../narvik_test/run relative to this repository, which is
    outside the repository.

.PARAMETER TagName
    Tag name used for the snapshot opt-out rule. When omitted, the tag with the
    most assignments in the lab is used. When the lab has no tags, the tag rule
    tests are skipped.

.PARAMETER DsmcPath
    Path to the dsmc stand-in. Defaults to dsmc_fake.ps1 in this repository.

.PARAMETER TimeoutSeconds
    Timeout for a single daemon wait (startup, log line, exit). Defaults to 300.

.PARAMETER Keep
    Keeps the runtime roots and the fixtures instead of deleting them. The next
    run then fails Preconditions while the leftovers exist; run Teardown without
    -Keep to remove them.

.PARAMETER List
    Prints the phases and exits without running anything.

.EXAMPLE
    pwsh -NoProfile -File tests/Invoke-NarvikVcenterTest.ps1 -List

.EXAMPLE
    pwsh -NoProfile -File tests/Invoke-NarvikVcenterTest.ps1 -Phase Preconditions,Inventory,Control,Config,Teardown

.EXAMPLE
    pwsh -NoProfile -File tests/Invoke-NarvikVcenterTest.ps1 -Phase All

.NOTES
    Exit codes: 0 all selected phases passed, 1 at least one check failed,
    2 no check failed but at least one phase was blocked (for example the
    vCenter storage policy service is down, so VMs cannot be created).
    Skipped checks are intentional gaps and do not change the exit code.
#>
[CmdletBinding()]
param(
    [string[]]$Phase = @('All'),

    [string]$VcenterServer = '192.168.122.234',

    [int]$VcenterPort = 443,

    [string]$VcenterUser = 'administrator@vsphere.local',

    [string]$PasswordFile,

    [string]$RunRoot,

    [string]$TagName,

    [string]$DsmcPath,

    [int]$TimeoutSeconds = 300,

    [switch]$Keep,

    [switch]$List
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:NarvikPath = Join-Path $script:RepoRoot 'Narvik.ps1'
$script:UnitTestPath = Join-Path $PSScriptRoot 'Invoke-NarvikUnitTest.ps1'
$script:FakeDsmcPath = Join-Path $script:RepoRoot 'dsmc_fake.ps1'

$script:PhaseOrder = @(
    'Preconditions',
    'Inventory',
    'Control',
    'Config',
    'Fixtures',
    'Tags',
    'Backup',
    'Full',
    'Retry',
    'Teardown'
)

if ([string]::IsNullOrWhiteSpace($PasswordFile)) {
    $PasswordFile = Join-Path (Split-Path -Parent $script:RepoRoot) 'narvik_temp/vcenter_password.txt'
}

if ([string]::IsNullOrWhiteSpace($DsmcPath)) {
    $DsmcPath = $script:FakeDsmcPath
}

if ([string]::IsNullOrWhiteSpace($RunRoot)) {
    $RunRoot = Join-Path (Split-Path -Parent $script:RepoRoot) 'narvik_test/run'
}

$script:PasswordFile = [System.IO.Path]::GetFullPath($PasswordFile)
$script:DsmcPath = [System.IO.Path]::GetFullPath($DsmcPath)
$script:RunRootBase = [System.IO.Path]::GetFullPath($RunRoot)
$script:ManifestPath = Join-Path $script:RunRootBase 'fixtures.json'
$script:FixturePrefix = 'nk-e2e'
$script:TagNameRequested = $TagName
$script:UseTagName = ''
$script:TimeoutSeconds = $TimeoutSeconds
$script:KeepRequested = [bool]$Keep

$script:Connection = $null
$script:TagAssignments = @()
$script:TagMap = @{}
$script:VmInfo = @()
$script:FolderMap = @{}
$script:HostMap = @{}
$script:HostParentMap = @{}
$script:ResourcePoolMap = @{}
$script:DatastoreMap = @{}
$script:PodByDatastore = @{}
$script:Pods = @()
$script:Datastores = @()
$script:Clusters = @()
$script:ManagementClassMap = @{}
$script:PbmAvailable = $false
$script:PbmMessage = ''
$script:VmHost = $null
$script:Datacenter = $null
$script:VmFolder = $null
$script:NormalPod = $null
$script:NormalDatastore = $null
$script:ActiveRuns = [System.Collections.Generic.List[object]]::new()

$script:Passed = 0
$script:Failed = 0
$script:Skipped = 0
$script:Blocked = 0
$script:FailureMessages = [System.Collections.Generic.List[string]]::new()
$script:BlockedMessages = [System.Collections.Generic.List[string]]::new()

# ---------------------------------------------------------------------------
# Result reporting
# ---------------------------------------------------------------------------

function Write-NkBanner {
    param([string]$Text)

    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor Cyan
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ('=' * 78) -ForegroundColor Cyan
}

function Add-NkResult {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('PASS', 'FAIL', 'SKIP', 'BLOCK')]
        [string]$Status,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowEmptyString()]
        [string]$Detail = ''
    )

    $suffix = ''
    if (-not [string]::IsNullOrWhiteSpace($Detail)) {
        $suffix = " - $Detail"
    }

    switch ($Status) {
        'PASS' {
            $script:Passed++
            Write-Host ("[PASS] {0}{1}" -f $Name, $suffix) -ForegroundColor Green
        }
        'FAIL' {
            $script:Failed++
            [void]$script:FailureMessages.Add("$Name$suffix")
            Write-Host ("[FAIL] {0}{1}" -f $Name, $suffix) -ForegroundColor Red
        }
        'SKIP' {
            $script:Skipped++
            Write-Host ("[SKIP] {0}{1}" -f $Name, $suffix) -ForegroundColor Yellow
        }
        'BLOCK' {
            $script:Blocked++
            [void]$script:BlockedMessages.Add("$Name$suffix")
            Write-Host ("[BLOCK] {0}{1}" -f $Name, $suffix) -ForegroundColor Magenta
        }
    }
}

function Assert-NkTrue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [AllowEmptyString()]
        [string]$Detail = ''
    )

    if ($Condition) {
        Add-NkResult -Status PASS -Name $Name
    }
    else {
        Add-NkResult -Status FAIL -Name $Name -Detail $Detail
    }
}

function Assert-NkEqual {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowNull()]
        $Expected,

        [AllowNull()]
        $Actual
    )

    $expectedText = if ($null -eq $Expected) { '<null>' } else { [string]$Expected }
    $actualText = if ($null -eq $Actual) { '<null>' } else { [string]$Actual }
    Assert-NkTrue -Name $Name -Condition ($expectedText -ceq $actualText) -Detail ("expected '{0}', got '{1}'" -f $expectedText, $actualText)
}

function Assert-NkMatch {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowEmptyString()]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string]$Pattern
    )

    Assert-NkTrue -Name $Name -Condition ($Text -match $Pattern) -Detail ("'{0}' not found in output" -f $Pattern)
}

function Test-NkContains {
    param(
        [AllowEmptyString()]
        [string]$Text,

        [AllowEmptyString()]
        [string]$Needle
    )

    if ([string]::IsNullOrEmpty($Needle)) {
        return $false
    }

    return ($Text.IndexOf($Needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
}

# ---------------------------------------------------------------------------
# General helpers
# ---------------------------------------------------------------------------

function Get-NkHostExecutable {
    $current = Get-Process -Id $PID -ErrorAction SilentlyContinue
    if ($null -ne $current -and -not [string]::IsNullOrWhiteSpace([string]$current.Path)) {
        return [string]$current.Path
    }

    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        return 'powershell.exe'
    }

    return 'pwsh'
}

$script:HostExecutable = Get-NkHostExecutable

function Test-NkIsWindows {
    return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
}

function Read-NkTextShared {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ''
    }

    $stream = $null
    $reader = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $reader = New-Object System.IO.StreamReader -ArgumentList $stream
        return $reader.ReadToEnd()
    }
    catch {
        return ''
    }
    finally {
        if ($null -ne $reader) {
            try { $reader.Close() } catch { }
        }
        elseif ($null -ne $stream) {
            try { $stream.Close() } catch { }
        }
    }
}

function Read-NkLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $parts = [System.Collections.Generic.List[string]]::new()

    # Archived logs come first so the concatenation is chronological; the
    # current log.txt is the newest part. Callers rely on this order for
    # tailing and for picking the first or second attempt of a VM.
    $old = Join-Path $Root 'log/narvik/old'
    if (Test-Path -LiteralPath $old -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $old -Recurse -Filter '*.txt' -File -ErrorAction SilentlyContinue | Sort-Object -Property LastWriteTime)) {
            $archived = Read-NkTextShared -Path $file.FullName
            if (-not [string]::IsNullOrEmpty($archived)) {
                [void]$parts.Add($archived)
            }
        }
    }

    $current = Join-Path $Root 'log/narvik/log.txt'
    $text = Read-NkTextShared -Path $current
    if (-not [string]::IsNullOrEmpty($text)) {
        [void]$parts.Add($text)
    }

    return ($parts -join "`n")
}

function Get-NkLogTail {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [int]$Lines = 25
    )

    $text = Read-NkLog -Root $Root
    $all = @($text -split "\r?\n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $start = [math]::Max(0, $all.Count - $Lines)
    return (@($all[$start..($all.Count - 1)]) -join "`n")
}

function Write-NkAtomicText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $directory -ErrorAction Stop | Out-Null
    }

    $tempPath = Join-Path $directory ('.nk_' + [System.IO.Path]::GetRandomFileName())
    $encoding = New-Object System.Text.UTF8Encoding -ArgumentList $false
    [System.IO.File]::WriteAllText($tempPath, $Content, $encoding)
    Move-Item -LiteralPath $tempPath -Destination $Path -Force -ErrorAction Stop
}

function Get-NkConfigValue {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    if ($Config.ContainsKey($Key)) {
        return $Config[$Key]
    }

    return $null
}

function Assert-NkSafeName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Kind
    )

    if ($Name -notlike 'nk-*') {
        throw "Refusing to touch $Kind '$Name': only objects whose name starts with 'nk-' may be created or deleted by this suite."
    }
}

function Get-NkSessionRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return (Join-Path $script:RunRootBase $Name)
}

function New-NkRuntimeRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [hashtable]$Overrides = @{}
    )

    $root = Get-NkSessionRoot -Name $Name
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop
    }

    New-Item -ItemType Directory -Force -Path $root -ErrorAction Stop | Out-Null

    $passwordTarget = Join-Path $root 'vcenter_password.txt'
    if (-not (Test-Path -LiteralPath $script:PasswordFile -PathType Leaf)) {
        throw "vCenter password file '$($script:PasswordFile)' not found."
    }
    Copy-Item -LiteralPath $script:PasswordFile -Destination $passwordTarget -Force -ErrorAction Stop
    if (-not (Test-NkIsWindows)) {
        try { & chmod 600 $passwordTarget 2>$null | Out-Null } catch { }
    }

    $config = Get-NkBaseConfig
    foreach ($key in $Overrides.Keys) {
        $config[$key] = $Overrides[$key]
    }

    Write-NkAtomicText -Path (Join-Path $root 'config.json') -Content ($config | ConvertTo-Json -Depth 10)
    return $root
}

function Get-NkBaseConfig {
    $map = @{}
    foreach ($key in $script:ManagementClassMap.Keys) {
        $map[$key] = $script:ManagementClassMap[$key]
    }

    return @{
        log_level                             = 'Info'
        check_administrator_privilege         = $false
        bypass_security                       = $true
        dsmc_path                             = $script:DsmcPath
        dsmc_use_preview                      = $true
        vcenter_server                        = $VcenterServer
        vcenter_port                          = $VcenterPort
        vcenter_user                          = $VcenterUser
        vcenter_password_file                 = 'vcenter_password.txt'
        vcenter_ignore_certificate            = $true
        dont_backup_by_snapshot_tag_name      = $script:UseTagName
        datastore_cluster_to_management_class = $map
        smtp_server                           = ''
        smtp_port                             = 25
        smtp_use_ssl                          = $false
        smtp_username                         = ''
        smtp_password_file                    = ''
        mail_from                             = 'narvik@example.local'
        mail_to                               = @('backup-admins@example.local')
        max_backup_threads                    = 2
    }
}

# ---------------------------------------------------------------------------
# Daemon and dsmc stand-in
# ---------------------------------------------------------------------------

function Start-NkDaemon {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [AllowEmptyString()]
        [string]$TimeZone = '',

        [hashtable]$Environment = @{},

        [AllowEmptyString()]
        [string]$ArgumentOverride = ''
    )

    $harnessDir = Join-Path $Root 'harness'
    New-Item -ItemType Directory -Force -Path $harnessDir -ErrorAction Stop | Out-Null

    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $stdoutPath = Join-Path $harnessDir ("daemon-$suffix.stdout.txt")
    $stderrPath = Join-Path $harnessDir ("daemon-$suffix.stderr.txt")

    $variables = @{
        DSMC_FAKE_PAUSE_SCALE            = '0.01'
        DSMC_FAKE_RANDOM_FAILURE_PERCENT = '0'
    }
    foreach ($key in $Environment.Keys) {
        $variables[$key] = $Environment[$key]
    }
    if (-not [string]::IsNullOrWhiteSpace($TimeZone)) {
        $variables['TZ'] = $TimeZone
    }

    $saved = @{}
    foreach ($key in $variables.Keys) {
        $saved[$key] = [System.Environment]::GetEnvironmentVariable($key, [System.EnvironmentVariableTarget]::Process)
        [System.Environment]::SetEnvironmentVariable($key, [string]$variables[$key], [System.EnvironmentVariableTarget]::Process)
    }

    $startParameters = @{
        FilePath               = $script:HostExecutable
        ArgumentList           = ('-NoProfile -NonInteractive -File "{0}" "{1}"' -f $script:NarvikPath, $Root)
        RedirectStandardOutput = $stdoutPath
        RedirectStandardError  = $stderrPath
        PassThru               = $true
        ErrorAction            = 'Stop'
    }

    if (-not [string]::IsNullOrWhiteSpace($ArgumentOverride)) {
        $startParameters['ArgumentList'] = $ArgumentOverride
    }

    try {
        $process = Start-Process @startParameters
    }
    finally {
        foreach ($key in $saved.Keys) {
            [System.Environment]::SetEnvironmentVariable($key, $saved[$key], [System.EnvironmentVariableTarget]::Process)
        }
    }

    $run = [pscustomobject]@{
        Root        = $Root
        Process     = $process
        StdOutPath  = $stdoutPath
        StdErrPath  = $stderrPath
        LogPath     = (Join-Path $Root 'log/narvik/log.txt')
        StartTime   = (Get-Date)
    }

    [void]$script:ActiveRuns.Add($run)
    return $run
}

function Wait-NkLogMatch {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$Pattern,

        [int]$TimeoutSeconds = 0,

        $Process
    )

    if ($TimeoutSeconds -le 0) {
        $TimeoutSeconds = $script:TimeoutSeconds
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $text = Read-NkLog -Root $Root
        if ($text -match $Pattern) {
            return $true
        }

        if ($null -ne $Process) {
            try {
                if ($Process.HasExited) {
                    $text = Read-NkLog -Root $Root
                    return ($text -match $Pattern)
                }
            }
            catch {
            }
        }

        Start-Sleep -Milliseconds 500
    }

    return $false
}

function Wait-NkFileContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Content,

        [int]$TimeoutSeconds = 0,

        $Process
    )

    if ($TimeoutSeconds -le 0) {
        $TimeoutSeconds = $script:TimeoutSeconds
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $text = (Read-NkTextShared -Path $Path).Trim()
        if ($text -eq $Content) {
            return $true
        }

        if ($null -ne $Process) {
            try {
                if ($Process.HasExited) {
                    $text = (Read-NkTextShared -Path $Path).Trim()
                    return ($text -eq $Content)
                }
            }
            catch {
            }
        }

        Start-Sleep -Milliseconds 500
    }

    return $false
}

function Stop-NkDaemon {
    param(
        [Parameter(Mandatory = $true)]
        $Run,

        [ValidateSet('Stop', 'Abort')]
        [string]$Mode = 'Stop',

        [int]$TimeoutSeconds = 0,

        [switch]$Force
    )

    if ($TimeoutSeconds -le 0) {
        $TimeoutSeconds = $script:TimeoutSeconds
    }

    if ($Mode -eq 'Abort') {
        Write-NkAtomicText -Path (Join-Path $Run.Root 'abort.txt') -Content "test`n"
    }
    else {
        Write-NkAtomicText -Path (Join-Path $Run.Root 'stop.txt') -Content "test`n"
    }

    $exited = $false
    try {
        $exited = $Run.Process.WaitForExit($TimeoutSeconds * 1000)
    }
    catch {
        $exited = $false
    }

    if (-not $exited) {
        if ($Force) {
            try { $Run.Process.Kill() } catch { }
            try { [void]$Run.Process.WaitForExit(30000) } catch { }
            return $null
        }

        return $null
    }

    try {
        return [int]$Run.Process.ExitCode
    }
    catch {
        return $null
    }
}

function Stop-NkAllActiveRuns {
    # @($list) throws "Argument types do not match" on PowerShell 7 when the
    # list holds Process objects, so snapshot it with ToArray() instead.
    $runs = $script:ActiveRuns.ToArray()
    foreach ($run in $runs) {
        try {
            $process = $null
            try { $process = $run.Process } catch { $process = $null }
            if ($null -eq $process) {
                continue
            }

            $hasExited = $true
            try { $hasExited = [bool]$process.HasExited } catch { $hasExited = $true }
            if ($hasExited) {
                continue
            }

            try { $process.Kill() } catch { }
            try { [void]$process.WaitForExit(30000) } catch { }
        }
        catch {
            Write-Host ("[WARN] could not stop a leftover process: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        }
    }
}

function Get-NkRunOutput {
    param(
        [Parameter(Mandatory = $true)]
        $Run
    )

    $stdout = Read-NkTextShared -Path $Run.StdOutPath
    $stderr = Read-NkTextShared -Path $Run.StdErrPath
    $log = Read-NkLog -Root $Run.Root
    return ($stdout + "`n" + $stderr + "`n" + $log)
}

# ---------------------------------------------------------------------------
# vCenter access
# ---------------------------------------------------------------------------

function Connect-NkVCenter {
    if (-not (Test-Path -LiteralPath $script:PasswordFile -PathType Leaf)) {
        throw "vCenter password file '$($script:PasswordFile)' not found."
    }

    $password = (Read-NkTextShared -Path $script:PasswordFile).Trim()
    if ([string]::IsNullOrWhiteSpace($password)) {
        throw "vCenter password file '$($script:PasswordFile)' is empty."
    }

    Import-Module 'VMware.VimAutomation.Core' -ErrorAction Stop

    try {
        Set-PowerCLIConfiguration -Scope Session -InvalidCertificateAction Ignore -Confirm:$false -ErrorAction Stop | Out-Null
    }
    catch {
        try {
            Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -ErrorAction Stop | Out-Null
        }
        catch {
            throw "Could not set the PowerCLI certificate action: $($_.Exception.Message)"
        }
    }

    $credential = New-Object System.Management.Automation.PSCredential(
        $VcenterUser,
        (ConvertTo-SecureString -String $password -AsPlainText -Force)
    )

    $script:Connection = Connect-VIServer -Server $VcenterServer -Port $VcenterPort -Credential $credential -ErrorAction Stop -WarningAction SilentlyContinue
    if ($null -eq $script:Connection) {
        throw "Could not connect to vCenter '$VcenterServer'."
    }
}

function Disconnect-NkVCenter {
    try {
        Disconnect-VIServer -Server * -Confirm:$false -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null
    }
    catch {
    }
    $script:Connection = $null
}

function Get-NkTagMap {
    $map = @{}
    foreach ($assignment in @($script:TagAssignments)) {
        if ($null -eq $assignment.Entity -or $null -eq $assignment.Tag) {
            continue
        }

        $keys = [System.Collections.Generic.List[string]]::new()

        try {
            if ($null -ne $assignment.Entity.ExtensionData -and $null -ne $assignment.Entity.ExtensionData.MoRef) {
                $morefValue = [string]$assignment.Entity.ExtensionData.MoRef.Value
                if (-not [string]::IsNullOrWhiteSpace($morefValue) -and -not $keys.Contains($morefValue)) {
                    [void]$keys.Add($morefValue)
                }
            }
        }
        catch {
        }

        try {
            if ($null -ne $assignment.Entity.MoRef) {
                $morefValue = [string]$assignment.Entity.MoRef.Value
                if (-not [string]::IsNullOrWhiteSpace($morefValue) -and -not $keys.Contains($morefValue)) {
                    [void]$keys.Add($morefValue)
                }
            }
        }
        catch {
        }

        $entityId = ''
        try {
            $entityId = [string]$assignment.Entity.Id
        }
        catch {
        }

        if (-not [string]::IsNullOrWhiteSpace($entityId)) {
            if (-not $keys.Contains($entityId)) {
                [void]$keys.Add($entityId)
            }

            if ($entityId -match '^(?:VirtualMachine|Datastore|StoragePod|Folder|HostSystem|ClusterComputeResource|Datacenter|ResourcePool|Network|DistributedVirtualPortgroup|VirtualApp)-(.+)$') {
                $normalized = $matches[1]
                if (-not [string]::IsNullOrWhiteSpace($normalized) -and -not $keys.Contains($normalized)) {
                    [void]$keys.Add($normalized)
                }
            }
        }

        foreach ($key in $keys) {
            if (-not $map.ContainsKey($key)) {
                $map[$key] = [System.Collections.Generic.List[string]]::new()
            }
            [void]$map[$key].Add([string]$assignment.Tag.Name)
        }
    }

    return $map
}

function Get-NkTagsForId {
    param(
        [AllowEmptyString()]
        [string]$Id
    )

    if ([string]::IsNullOrWhiteSpace($Id) -or -not $script:TagMap.ContainsKey($Id)) {
        return @()
    }

    return @($script:TagMap[$Id])
}

function Get-NkTagAssignmentEntity {
    param(
        [Parameter(Mandatory = $true)]
        $Assignment,

        [Parameter(Mandatory = $true)]
        [ValidateSet('ResourcePool', 'Datastore', 'StoragePod', 'Folder', 'ClusterComputeResource', 'VirtualMachine')]
        [string]$Type
    )

    $entity = $Assignment.Entity
    if ($null -eq $entity) {
        return $null
    }

    $morefType = ''
    $morefValue = ''
    try {
        if ($null -ne $entity.ExtensionData -and $null -ne $entity.ExtensionData.MoRef) {
            $morefType = [string]$entity.ExtensionData.MoRef.Type
            $morefValue = [string]$entity.ExtensionData.MoRef.Value
        }
    }
    catch {
    }

    if ($morefType -ne $Type) {
        return $null
    }

    return [pscustomobject]@{
        Type  = $morefType
        Value = $morefValue
        Name  = [string]$entity.Name
        Entity = $entity
    }
}

function Update-NkInventoryInfo {
    $script:FolderMap = @{}
    $folderViews = @(Get-View -ViewType Folder -Property Name, Parent -ErrorAction Stop | Where-Object { $null -ne $_ })
    foreach ($folder in $folderViews) {
        if ($folder.GetType().Name -eq 'StoragePod') {
            continue
        }
        $script:FolderMap[[string]$folder.MoRef.Value] = $folder
    }

    $script:HostMap = @{}
    $script:HostParentMap = @{}
    foreach ($hostView in @(Get-View -ViewType HostSystem -Property Name, Parent -ErrorAction Stop | Where-Object { $null -ne $_ })) {
        $hostId = [string]$hostView.MoRef.Value
        $script:HostMap[$hostId] = [string]$hostView.Name
        if ($null -ne $hostView.Parent) {
            $script:HostParentMap[$hostId] = $hostView.Parent
        }
    }

    $script:ResourcePoolMap = @{}
    foreach ($pool in @(Get-View -ViewType ResourcePool -Property Name -ErrorAction Stop | Where-Object { $null -ne $_ })) {
        $script:ResourcePoolMap[[string]$pool.MoRef.Value] = [string]$pool.Name
    }

    $script:DatastoreMap = @{}
    foreach ($datastore in @(Get-View -ViewType Datastore -Property Name -ErrorAction Stop | Where-Object { $null -ne $_ })) {
        $script:DatastoreMap[[string]$datastore.MoRef.Value] = [string]$datastore.Name
    }

    $script:Pods = @()
    $script:PodByDatastore = @{}
    foreach ($pod in @(Get-View -ViewType StoragePod -Property Name, ChildEntity -ErrorAction Stop | Where-Object { $null -ne $_ })) {
        $podId = [string]$pod.MoRef.Value
        $podName = [string]$pod.Name
        $datastoreIds = [System.Collections.Generic.List[string]]::new()
        foreach ($child in @($pod.ChildEntity)) {
            if ($null -ne $child) {
                [void]$datastoreIds.Add([string]$child.Value)
            }
        }

        $script:Pods += [pscustomobject]@{
            Id          = $podId
            Name        = $podName
            DatastoreIds = @($datastoreIds)
        }

        foreach ($datastoreId in $datastoreIds) {
            $script:PodByDatastore[$datastoreId] = [pscustomobject]@{ Id = $podId; Name = $podName }
        }
    }

    $script:Clusters = @()
    foreach ($hostId in @($script:HostParentMap.Keys)) {
        $parent = $script:HostParentMap[$hostId]
        if ($null -ne $parent -and [string]$parent.Type -eq 'ClusterComputeResource') {
            $clusterId = [string]$parent.Value
            if (-not (@($script:Clusters) | Where-Object { $_.Id -eq $clusterId })) {
                $clusterName = ''
                try {
                    $clusterView = Get-View -Id $clusterId -Property Name -ErrorAction Stop
                    $clusterName = [string]$clusterView.Name
                }
                catch {
                    $clusterName = ''
                }
                $script:Clusters += [pscustomobject]@{ Id = $clusterId; Name = $clusterName }
            }
        }
    }

    $script:Datastores = @()
    foreach ($view in @(Get-View -ViewType Datastore -Property Name -ErrorAction Stop | Where-Object { $null -ne $_ })) {
        $script:Datastores += [pscustomobject]@{
            Id   = [string]$view.MoRef.Value
            Name = [string]$view.Name
        }
    }

    $vms = [System.Collections.Generic.List[object]]::new()
    foreach ($vmView in @(Get-View -ViewType VirtualMachine -Property Name, Config, Runtime.Host, Runtime.PowerState, Parent, ResourcePool -ErrorAction Stop | Where-Object { $null -ne $_ })) {
        $folderId = ''
        if ($null -ne $vmView.Parent) {
            $folderId = [string]$vmView.Parent.Value
        }
        $folderName = ''
        if (-not [string]::IsNullOrWhiteSpace($folderId) -and $script:FolderMap.ContainsKey($folderId)) {
            $folderName = [string]$script:FolderMap[$folderId].Name
        }

        $poolId = ''
        if ($null -ne $vmView.ResourcePool) {
            $poolId = [string]$vmView.ResourcePool.Value
        }
        $poolName = ''
        if (-not [string]::IsNullOrWhiteSpace($poolId) -and $script:ResourcePoolMap.ContainsKey($poolId)) {
            $poolName = [string]$script:ResourcePoolMap[$poolId]
        }

        $hostId = ''
        $hostName = ''
        if ($null -ne $vmView.Runtime -and $null -ne $vmView.Runtime.Host) {
            $hostId = [string]$vmView.Runtime.Host.Value
            if ($script:HostMap.ContainsKey($hostId)) {
                $hostName = [string]$script:HostMap[$hostId]
            }
        }

        $clusterId = ''
        $clusterName = ''
        if (-not [string]::IsNullOrWhiteSpace($hostId) -and $script:HostParentMap.ContainsKey($hostId)) {
            $parent = $script:HostParentMap[$hostId]
            if ($null -ne $parent -and [string]$parent.Type -eq 'ClusterComputeResource') {
                $clusterId = [string]$parent.Value
                foreach ($cluster in @($script:Clusters)) {
                    if ($cluster.Id -eq $clusterId) {
                        $clusterName = [string]$cluster.Name
                    }
                }
            }
        }

        $disks = [System.Collections.Generic.List[object]]::new()
        $podNames = [System.Collections.Generic.List[string]]::new()
        $podKeys = @{}
        if ($null -ne $vmView.Config -and $null -ne $vmView.Config.Hardware) {
            foreach ($device in @($vmView.Config.Hardware.Device)) {
                if ($null -eq $device -or $device -isnot [VMware.Vim.VirtualDisk]) {
                    continue
                }

                $datastoreId = ''
                try {
                    if ($null -ne $device.Backing -and $null -ne $device.Backing.Datastore) {
                        $datastoreId = [string]$device.Backing.Datastore.Value
                    }
                }
                catch {
                    $datastoreId = ''
                }

                $datastoreName = ''
                if (-not [string]::IsNullOrWhiteSpace($datastoreId) -and $script:DatastoreMap.ContainsKey($datastoreId)) {
                    $datastoreName = [string]$script:DatastoreMap[$datastoreId]
                }

                $podId = ''
                $podName = ''
                if ($script:PodByDatastore.ContainsKey($datastoreId)) {
                    $podId = [string]$script:PodByDatastore[$datastoreId].Id
                    $podName = [string]$script:PodByDatastore[$datastoreId].Name
                    $podKey = $podName.ToLowerInvariant()
                    if (-not $podKeys.ContainsKey($podKey)) {
                        $podKeys[$podKey] = $true
                        [void]$podNames.Add($podName)
                    }
                }

                $label = ''
                try { $label = [string]$device.DeviceInfo.Label } catch { $label = '' }
                $capacityKb = 0L
                try { $capacityKb = [long]$device.CapacityInKB } catch { $capacityKb = 0L }

                [void]$disks.Add([pscustomobject]@{
                    Label                = $label
                    CapacityInKB         = $capacityKb
                    DatastoreId          = $datastoreId
                    Datastore            = $datastoreName
                    DatastoreClusterId   = $podId
                    DatastoreCluster     = $podName
                    DatastoreTags        = @(Get-NkTagsForId -Id $datastoreId)
                    DatastoreClusterTags = @(Get-NkTagsForId -Id $podId)
                })
            }
        }

        $notes = ''
        if ($null -ne $vmView.Config) {
            try { $notes = [string]$vmView.Config.Annotation } catch { $notes = '' }
        }

        $powerState = ''
        try { $powerState = [string]$vmView.Runtime.PowerState } catch { $powerState = '' }

        [void]$vms.Add([pscustomobject]@{
            Name              = [string]$vmView.Name
            MoRef             = [string]$vmView.MoRef.Value
            PowerState        = $powerState
            Notes             = $notes
            FolderMoRef       = $folderId
            FolderName        = $folderName
            FolderTags        = @(Get-NkTagsForId -Id $folderId)
            HostId            = $hostId
            HostName          = $hostName
            ClusterMoRef      = $clusterId
            ClusterName       = $clusterName
            ClusterTags       = @(Get-NkTagsForId -Id $clusterId)
            ResourcePoolMoRef = $poolId
            ResourcePoolName  = $poolName
            ResourcePoolTags  = @(Get-NkTagsForId -Id $poolId)
            Tags              = @(Get-NkTagsForId -Id ([string]$vmView.MoRef.Value))
            DatastoreClusters = @($podNames)
            Disks             = @($disks)
        })
    }

    $script:VmInfo = @($vms)
}

function Initialize-NkHarness {
    if (-not (Test-Path -LiteralPath $script:NarvikPath -PathType Leaf)) {
        throw "Narvik.ps1 not found at '$($script:NarvikPath)'."
    }
    if (-not (Test-Path -LiteralPath $script:DsmcPath -PathType Leaf)) {
        throw "dsmc stand-in not found at '$($script:DsmcPath)'."
    }

    if (Test-Path -LiteralPath $script:ManifestPath -PathType Leaf) {
        try {
            $manifest = Read-NkTextShared -Path $script:ManifestPath | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $manifest -and $null -ne $manifest.TagName -and -not [string]::IsNullOrWhiteSpace([string]$manifest.TagName)) {
                if ([string]::IsNullOrWhiteSpace($script:TagNameRequested)) {
                    $script:UseTagName = [string]$manifest.TagName
                }
            }
        }
        catch {
        }
    }

    Connect-NkVCenter

    $script:TagAssignments = @(Get-TagAssignment -ErrorAction Stop | Where-Object { $null -ne $_ })
    $script:TagMap = Get-NkTagMap

    if (-not [string]::IsNullOrWhiteSpace($script:TagNameRequested)) {
        $script:UseTagName = $script:TagNameRequested
    }
    elseif ([string]::IsNullOrWhiteSpace($script:UseTagName)) {
        $grouped = @($script:TagAssignments | Group-Object -Property { [string]$_.Tag.Name } | Sort-Object -Property @{ Expression = { $_.Count }; Descending = $true }, @{ Expression = { $_.Name } })
        if ($grouped.Count -gt 0) {
            $script:UseTagName = [string]$grouped[0].Name
        }
    }

    foreach ($pod in @(Get-View -ViewType StoragePod -Property Name -ErrorAction Stop | Where-Object { $null -ne $_ })) {
        $name = [string]$pod.Name
        $sanitized = ($name -replace '[^A-Za-z0-9_]', '_')
        if ([string]::IsNullOrWhiteSpace($sanitized)) {
            $sanitized = [string]$pod.MoRef.Value
        }
        $script:ManagementClassMap[$name.ToLowerInvariant()] = "NK_$sanitized"
    }

    try {
        Get-SpbmStoragePolicy -ErrorAction Stop | Out-Null
        $script:PbmAvailable = $true
        $script:PbmMessage = ''
    }
    catch {
        $script:PbmAvailable = $false
        $script:PbmMessage = $_.Exception.Message
    }

    $script:VmHost = @(Get-VMHost -ErrorAction Stop | Select-Object -First 1)[0]
    if ($null -ne $script:VmHost) {
        try {
            $script:Datacenter = @(Get-Datacenter -VMHost $script:VmHost -ErrorAction Stop | Select-Object -First 1)[0]
        }
        catch {
            $script:Datacenter = @(Get-Datacenter -ErrorAction Stop | Select-Object -First 1)[0]
        }

        if ($null -ne $script:Datacenter) {
            try {
                $dcView = Get-View -Id $script:Datacenter.Id -Property VmFolder -ErrorAction Stop
                $script:VmFolder = Get-Folder -Id $dcView.VmFolder -ErrorAction Stop
            }
            catch {
                $script:VmFolder = $null
            }
        }
    }

    Update-NkInventoryInfo
}

# ---------------------------------------------------------------------------
# Expected eligibility (independent oracle for the parts the tests check)
# ---------------------------------------------------------------------------

function Get-NkTagViolations {
    param(
        [Parameter(Mandatory = $true)]
        $Vm
    )

    if ([string]::IsNullOrWhiteSpace($script:UseTagName)) {
        return @()
    }

    return @(Get-NarvikVmTagViolations -Vm $Vm -TagName $script:UseTagName)
}

function Get-NkNonEligibleLogMap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogText
    )

    $map = @{}
    foreach ($line in @($LogText -split "\r?\n")) {
        if ($line -notmatch "VM '(.+)' is not eligible: (.*)\.$") {
            continue
        }
        $map[$matches[1]] = $matches[2]
    }

    return $map
}

function Get-NkEligibleMonitoringNames {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $path = Join-Path $Root 'monitoring/eligible_vms.txt'
    $text = Read-NkTextShared -Path $path
    return @($text -split "\r?\n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-NkPendingCount {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $path = Join-Path $Root 'monitoring/pending_count.txt'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }

    $text = (Read-NkTextShared -Path $path).Trim()
    if ($text -notmatch '^\d+$') {
        return $null
    }

    return [int]$text
}

# ---------------------------------------------------------------------------
# Read-only proof
# ---------------------------------------------------------------------------

function Get-NkStateFingerprint {
    $lines = [System.Collections.Generic.List[string]]::new()

    foreach ($view in @(Get-View -ViewType VirtualMachine -Property Name, Runtime.PowerState, Config.Annotation, Snapshot -ErrorAction Stop | Where-Object { $null -ne $_ })) {
        $snapshots = 0
        try { $snapshots = @($view.Snapshot.RootSnapshotList).Count } catch { $snapshots = 0 }
        $notes = ''
        try { $notes = [string]$view.Config.Annotation } catch { $notes = '' }
        $power = ''
        try { $power = [string]$view.Runtime.PowerState } catch { $power = '' }
        [void]$lines.Add(("vm|{0}|{1}|{2}|{3}" -f $view.MoRef.Value, $view.Name, $power, $notes))
        [void]$lines.Add(("snapshots|{0}|{1}" -f $view.MoRef.Value, $snapshots))
    }

    foreach ($view in @(Get-View -ViewType Folder -Property Name -ErrorAction Stop | Where-Object { $null -ne $_ })) {
        if ($view.GetType().Name -eq 'StoragePod') {
            continue
        }
        [void]$lines.Add(("folder|{0}|{1}" -f $view.MoRef.Value, $view.Name))
    }

    foreach ($view in @(Get-View -ViewType Datastore -Property Name -ErrorAction Stop | Where-Object { $null -ne $_ })) {
        [void]$lines.Add(("datastore|{0}|{1}" -f $view.MoRef.Value, $view.Name))
    }

    foreach ($view in @(Get-View -ViewType StoragePod -Property Name -ErrorAction Stop | Where-Object { $null -ne $_ })) {
        [void]$lines.Add(("pod|{0}|{1}" -f $view.MoRef.Value, $view.Name))
    }

    foreach ($view in @(Get-View -ViewType HostSystem -Property Name -ErrorAction Stop | Where-Object { $null -ne $_ })) {
        [void]$lines.Add(("host|{0}|{1}" -f $view.MoRef.Value, $view.Name))
    }

    $lines.Sort()
    return ($lines -join "`n")
}

function Get-NkTaskIds {
    $ids = @{}
    foreach ($task in @(Get-Task -ErrorAction SilentlyContinue | Where-Object { $null -ne $_ })) {
        $ids[[string]$task.Id] = $true
    }
    return $ids
}

function Get-NkNewMutatingTasks {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Before
    )

    $pattern = '(?i)(create|reconfig|power|suspend|reset|snapshot|destroy|delete|remove|rename|move|clone|migrat|register|unregister|tag|set)$'
    $added = [System.Collections.Generic.List[string]]::new()
    foreach ($task in @(Get-Task -ErrorAction SilentlyContinue | Where-Object { $null -ne $_ })) {
        $id = [string]$task.Id
        if ($Before.ContainsKey($id)) {
            continue
        }
        $name = [string]$task.Name
        if ($name -match $pattern) {
            [void]$added.Add(("{0} ({1})" -f $name, $id))
        }
    }

    return @($added)
}

# ---------------------------------------------------------------------------
# Pure helpers extracted from Narvik.ps1 (same approach as the unit suite)
# ---------------------------------------------------------------------------

function Import-NkPureHelpers {
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:NarvikPath, [ref]$null, [ref]$parseErrors)
    if ($null -ne $parseErrors -and $parseErrors.Count -gt 0) {
        throw "Narvik.ps1 does not parse: $($parseErrors[0].Message)"
    }

    $names = @('Test-NarvikTagPresent', 'Get-NarvikVmTagViolations')
    foreach ($name in $names) {
        $definition = $ast.Find({
                param($node)
                ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($node.Name -eq $name)
            }, $true)

        if ($null -eq $definition) {
            throw "Function '$name' was not found in Narvik.ps1."
        }

        # New-Item puts the function in the script scope: the harness phases run
        # as functions, so a plain dot-source here would only define it inside
        # this function's scope.
        New-Item -Path ("function:script:{0}" -f $name) -Value $definition.Body.GetScriptBlock() -Force -ErrorAction Stop | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Phase: Preconditions
# ---------------------------------------------------------------------------

function Invoke-NkPhasePreconditions {
    Write-NkBanner 'Phase: Preconditions'

    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($script:NarvikPath, [ref]$null, [ref]$parseErrors)
    $parseOk = ($null -eq $parseErrors -or $parseErrors.Count -eq 0)
    $parseDetail = ''
    if (-not $parseOk) {
        $parseDetail = "$($parseErrors[0].Extent.StartLineNumber): $($parseErrors[0].Message)"
    }
    Assert-NkTrue -Name 'PRECOND-01 Narvik.ps1 parses' -Condition $parseOk -Detail $parseDetail

    $bytes = [System.IO.File]::ReadAllBytes($script:NarvikPath)
    $nonAscii = 0
    foreach ($byte in $bytes) {
        if ($byte -gt 127) {
            $nonAscii++
        }
    }
    Assert-NkTrue -Name 'PRECOND-02 Narvik.ps1 is ASCII (required for PowerShell 5.1 without a BOM)' -Condition ($nonAscii -eq 0) -Detail "found $nonAscii non-ASCII byte(s)"

    if (Test-Path -LiteralPath $script:UnitTestPath -PathType Leaf) {
        $unitOutput = & $script:HostExecutable -NoProfile -NonInteractive -File $script:UnitTestPath 2>&1 | Out-String
        $unitCode = $LASTEXITCODE
        $unitTail = @($unitOutput -split "\r?\n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 3) -join ' | '
        Assert-NkTrue -Name 'PRECOND-03 offline unit tests pass' -Condition ($unitCode -eq 0) -Detail "exit code $unitCode; $unitTail"
    }
    else {
        Add-NkResult -Status FAIL -Name 'PRECOND-03 offline unit tests pass' -Detail "missing '$($script:UnitTestPath)'"
    }

    Assert-NkTrue -Name 'PRECOND-04 dsmc stand-in exists' -Condition (Test-Path -LiteralPath $script:DsmcPath -PathType Leaf) -Detail $script:DsmcPath

    if (-not (Test-NkIsWindows)) {
        $execOutput = ''
        try {
            $execOutput = & bash -c ('test -x "{0}"' -f $script:DsmcPath) 2>&1 | Out-String
        }
        catch {
            $execOutput = $_.Exception.Message
        }
        $execOk = ($LASTEXITCODE -eq 0)
        Assert-NkTrue -Name 'PRECOND-05 dsmc stand-in is executable (needed by Start-Process on Linux)' -Condition $execOk -Detail $execOutput

        $firstLine = ''
        try { $firstLine = [string](Get-Content -LiteralPath $script:DsmcPath -TotalCount 1) } catch { $firstLine = '' }
        Assert-NkTrue -Name 'PRECOND-06 dsmc stand-in starts with a shebang' -Condition ($firstLine -match '^#!.*(pwsh|powershell)') -Detail $firstLine
    }

    $source = Read-NkTextShared -Path $script:NarvikPath
    $writeCmdletPattern = '(?i)\b(?:New|Set|Remove|Move|Start|Stop|Restart|Suspend|Reset|Register|Unregister|Clone|Migrate|Rename)-(?:VM|VMHost|Folder|Datastore|DatastoreCluster|Cluster|ResourcePool|Snapshot|Tag|TagAssignment|TagCategory|VirtualSwitch|StandardPortgroup|DistributedPortgroup|Portgroup|Network|Permission|Alarm)\b'
    $writeMethodPattern = '(?i)\.(?:CreateVM|ReconfigVM|PowerOnVM_Task|PowerOffVM_Task|SuspendVM_Task|ResetVM_Task|Destroy_Task|Destroy|CreateSnapshot_Task|RemoveSnapshot_Task|RevertToSnapshot_Task|CreateFolder|MoveIntoFolder_Task|Rename_Task|CloneVM_Task|RelocateVM_Task|CreateTag|UpdateTag|DeleteTag|AssignTag|CreateResourcePool|RemoveResourcePool|Rename)\s*\('
    $writeCmdlets = @([regex]::Matches($source, $writeCmdletPattern) | ForEach-Object { $_.Value } | Sort-Object -Unique)
    $writeMethods = @([regex]::Matches($source, $writeMethodPattern) | ForEach-Object { $_.Value } | Sort-Object -Unique)
    $writeDetail = @($writeCmdlets + $writeMethods) -join ', '
    Assert-NkTrue -Name 'PRECOND-07 Narvik.ps1 contains no vCenter write command' -Condition ($writeCmdlets.Count -eq 0 -and $writeMethods.Count -eq 0) -Detail $writeDetail

    Assert-NkTrue -Name 'PRECOND-08 vCenter connection established' -Condition ($null -ne $script:Connection) -Detail "$VcenterServer`:$VcenterPort"

    # The ServiceInstance.About property is not retrievable through Get-View on
    # this appliance, so read the version and build from the PowerCLI session.
    $version = ''
    $build = ''
    $instanceUuid = ''
    try {
        $version = [string]$script:Connection.Version
        $build = [string]$script:Connection.Build
        $instanceUuid = [string]$script:Connection.InstanceUuid
    }
    catch {
        $version = ''
    }
    if (-not [string]::IsNullOrWhiteSpace($version)) {
        Add-NkResult -Status PASS -Name 'PRECOND-09 vCenter version reported' -Detail ("{0} build {1} (instance {2})" -f $version, $build, $instanceUuid)
    }
    else {
        Add-NkResult -Status FAIL -Name 'PRECOND-09 vCenter version reported' -Detail 'the PowerCLI session reports no version'
    }

    $script:NkVms = @($script:VmInfo | Where-Object { $_.Name -like 'nk-*' })
    if ($script:NkVms.Count -eq 0) {
        Add-NkResult -Status PASS -Name 'PRECOND-10 lab guard rails: no nk- VMs present' -Detail 'clean lab'
    }
    else {
        $badPower = @($script:NkVms | Where-Object { $_.PowerState -ne 'poweredOff' })
        Assert-NkTrue -Name 'PRECOND-10 every nk- VM is powered off' -Condition ($badPower.Count -eq 0) -Detail (@($badPower | ForEach-Object { "$($_.Name)=$($_.PowerState)" }) -join ', ')

        $badDisks = [System.Collections.Generic.List[string]]::new()
        foreach ($vm in $script:NkVms) {
            foreach ($disk in @($vm.Disks)) {
                $capacityKb = [long]$disk.CapacityInKB
                if ($capacityKb -le 0 -or $capacityKb -gt 1048576) {
                    [void]$badDisks.Add("$($vm.Name)/$($disk.Label)=$($disk.CapacityInKB) KB")
                }
            }
        }
        Assert-NkTrue -Name 'PRECOND-11 every nk- VM disk is at most 1 GiB (1048576 KB)' -Condition ($badDisks.Count -eq 0) -Detail ($badDisks -join ', ')

        if (Test-Path -LiteralPath $script:ManifestPath -PathType Leaf) {
            Add-NkResult -Status PASS -Name 'PRECOND-12 leftover nk- fixtures belong to a previous run' -Detail "$($script:NkVms.Count) VM(s); run Teardown to remove them"
        }
        else {
            Add-NkResult -Status FAIL -Name 'PRECOND-12 no unexpected nk- VMs without a fixture manifest' -Detail (@($script:NkVms | ForEach-Object { $_.Name }) -join ', ')
        }
    }

    if ($script:PbmAvailable) {
        Add-NkResult -Status PASS -Name 'PRECOND-13 vCenter storage policy service is available' -Detail 'VM creation can be tested'
    }
    else {
        Add-NkResult -Status BLOCK -Name 'PRECOND-13 vCenter storage policy service is available' -Detail ("VM and folder fixtures cannot be created: {0}" -f $script:PbmMessage)
    }

    Add-NkResult -Status PASS -Name 'PRECOND-14 lab snapshot' -Detail ("{0} VM(s), {1} datastore(s), {2} datastore cluster(s), {3} tag assignment(s), rule tag '{4}'" -f $script:VmInfo.Count, $script:Datastores.Count, $script:Pods.Count, @($script:TagAssignments).Count, $script:UseTagName)

    $runRootOk = -not (Test-NkPathInside -Child $script:RunRootBase -Parent $script:RepoRoot)
    Assert-NkTrue -Name 'PRECOND-15 the runtime root is outside the repository' -Condition $runRootOk -Detail $script:RunRootBase

    $passwordOk = -not (Test-NkPathInside -Child $script:PasswordFile -Parent $script:RepoRoot)
    Assert-NkTrue -Name 'PRECOND-16 the vCenter password file is outside the repository' -Condition $passwordOk -Detail $script:PasswordFile

    if (Test-NkIsWindows -and ($script:DsmcPath -match '\.ps1$')) {
        Add-NkResult -Status FAIL -Name 'PRECOND-17 the dsmc stand-in can be started by Start-Process' -Detail 'on Windows, -DsmcPath must point at a .cmd wrapper; Start-Process cannot run a .ps1 file directly'
    }
    else {
        Add-NkResult -Status PASS -Name 'PRECOND-17 the dsmc stand-in can be started by Start-Process'
    }
}

# ---------------------------------------------------------------------------
# Phase: Inventory
# ---------------------------------------------------------------------------

function Invoke-NkInventoryRun {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    $before = Get-NkStateFingerprint
    $taskIds = Get-NkTaskIds

    $run = Start-NkDaemon -Root $Root
    $collected = Wait-NkLogMatch -Root $Root -Pattern 'vCenter inventory collected: \d+ VM\(s\), \d+ datastore\(s\), \d+ datastore cluster\(s\)' -Process $run.Process

    if (-not $collected) {
        Stop-NkDaemon -Run $run -Mode Abort -Force | Out-Null
        return [pscustomobject]@{
            Collected = $false
            ExitCode  = $null
            Log       = (Read-NkLog -Root $Root)
            Before    = $before
            TaskIds   = $taskIds
            Root      = $Root
        }
    }

    # Give the loop one more cycle so eligibility logging and monitoring files
    # are written before stop.txt is seen.
    Start-Sleep -Seconds 3
    $exitCode = Stop-NkDaemon -Run $run -Mode Stop
    $log = Read-NkLog -Root $Root

    return [pscustomobject]@{
        Collected = $true
        ExitCode  = $exitCode
        Log       = $log
        Before    = $before
        TaskIds   = $taskIds
        Root      = $Root
    }
}

function Invoke-NkPhaseInventory {
    Write-NkBanner 'Phase: Inventory'
    Update-NkInventoryInfo

    $root = New-NkRuntimeRoot -Name 'inventory'
    $result = Invoke-NkInventoryRun -Root $root -Label 'inventory'

    Assert-NkTrue -Name 'INV-01 inventory collection completes' -Condition $result.Collected -Detail (Get-NkLogTail -Root $root -Lines 8)
    if (-not $result.Collected) {
        return
    }

    Assert-NkEqual -Name 'INV-02 the daemon exits normally on stop.txt' -Expected 0 -Actual $result.ExitCode
    Assert-NkTrue -Name 'INV-03 the run logs no error' -Condition ($result.Log -notmatch '\[ERROR\]') -Detail (Get-NkLogTail -Root $root -Lines 8)

    $countMatch = [regex]::Match($result.Log, 'vCenter inventory collected: (\d+) VM\(s\), (\d+) datastore\(s\), (\d+) datastore cluster\(s\)')
    $vmCount = 0
    $datastoreCount = 0
    $podCount = 0
    if ($countMatch.Success) {
        $vmCount = [int]$countMatch.Groups[1].Value
        $datastoreCount = [int]$countMatch.Groups[2].Value
        $podCount = [int]$countMatch.Groups[3].Value
    }

    Assert-NkEqual -Name 'INV-04 collected VM count matches the live inventory' -Expected $script:VmInfo.Count -Actual $vmCount
    Assert-NkEqual -Name 'INV-05 collected datastore count matches the live inventory' -Expected $script:Datastores.Count -Actual $datastoreCount
    Assert-NkEqual -Name 'INV-06 collected datastore cluster count matches the live inventory' -Expected $script:Pods.Count -Actual $podCount

    $eligibleNames = @(Get-NkEligibleMonitoringNames -Root $root)
    $nonEligible = Get-NkNonEligibleLogMap -LogText $result.Log

    $eligibleCountPath = Join-Path $root 'monitoring/eligible_count.txt'
    $eligibleCountText = (Read-NkTextShared -Path $eligibleCountPath).Trim()
    Assert-NkEqual -Name 'INV-07 eligible_count.txt matches eligible_vms.txt' -Expected ([string]$eligibleNames.Count) -Actual $eligibleCountText

    $unclassified = [System.Collections.Generic.List[string]]::new()
    foreach ($vm in @($script:VmInfo)) {
        if ($eligibleNames -contains $vm.Name) {
            continue
        }
        if ($nonEligible.ContainsKey($vm.Name)) {
            continue
        }
        if (@($script:VmInfo | Where-Object { $_.Name -eq $vm.Name }).Count -gt 1) {
            continue
        }
        [void]$unclassified.Add($vm.Name)
    }
    Assert-NkTrue -Name 'INV-08 every VM is either eligible or has a logged reason' -Condition ($unclassified.Count -eq 0) -Detail ($unclassified -join ', ')

    $expectedPairs = [System.Collections.Generic.List[string]]::new()
    foreach ($vm in @($script:VmInfo)) {
        $violations = @(Get-NkTagViolations -Vm $vm)
        if ($violations.Count -eq 0) {
            continue
        }

        if (-not $nonEligible.ContainsKey($vm.Name)) {
            [void]$expectedPairs.Add("$($vm.Name): no non-eligible line")
            continue
        }

        foreach ($violation in $violations) {
            if (-not (Test-NkContains -Text ([string]$nonEligible[$vm.Name]) -Needle $violation)) {
                [void]$expectedPairs.Add("$($vm.Name): missing '$violation'")
            }
        }
    }

    $missingTagReasons = @($expectedPairs)
    Assert-NkTrue -Name 'INV-09 every live tag assignment that applies to a VM is logged' -Condition ($missingTagReasons.Count -eq 0) -Detail (($missingTagReasons | Select-Object -First 3) -join ' | ')

    $after = Get-NkStateFingerprint
    Assert-NkTrue -Name 'INV-10 vCenter state is identical before and after the run' -Condition ($result.Before -ceq $after) -Detail 'VM, folder, datastore, datastore cluster or host state changed'

    $newTasks = @(Get-NkNewMutatingTasks -Before $result.TaskIds)
    Assert-NkTrue -Name 'INV-11 inventory collection started no mutating vCenter task' -Condition ($newTasks.Count -eq 0) -Detail (($newTasks | Select-Object -First 3) -join ', ')

    if ([string]::IsNullOrWhiteSpace($script:UseTagName) -or @($expectedPairs).Count -gt 0) {
        if ([string]::IsNullOrWhiteSpace($script:UseTagName)) {
            Add-NkResult -Status SKIP -Name 'INV-12 disabling the tag rule removes tag reasons' -Detail 'the lab has no tags'
        }
        else {
            Add-NkResult -Status SKIP -Name 'INV-12 disabling the tag rule removes tag reasons' -Detail 'no live tag assignment affected a VM'
        }
    }
    else {
        $rootNoTag = New-NkRuntimeRoot -Name 'inventory-notag' -Overrides @{ dont_backup_by_snapshot_tag_name = '' }
        $resultNoTag = Invoke-NkInventoryRun -Root $rootNoTag -Label 'inventory-notag'
        Assert-NkTrue -Name 'INV-12a inventory collection completes with the tag rule disabled' -Condition $resultNoTag.Collected -Detail (Get-NkLogTail -Root $rootNoTag -Lines 8)

        if ($resultNoTag.Collected) {
            $tagReasonPattern = "tag '" + [regex]::Escape($script:UseTagName) + "'"
            Assert-NkTrue -Name 'INV-12b no tag reason is logged when the rule is disabled' -Condition ($resultNoTag.Log -notmatch $tagReasonPattern) -Detail "found 'tag '$($script:UseTagName)'"
        }
    }

    # An entry in priority_clusters that names no live compute cluster is
    # detected during collection and logged. The email itself needs SMTP,
    # which this lab does not have.
    $missingClusterName = 'nk-priority-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $rootPriority = New-NkRuntimeRoot -Name 'inventory-priority' -Overrides @{
        priority_clusters = @(@{ name = $missingClusterName; priority = 10 })
    }
    $resultPriority = Invoke-NkInventoryRun -Root $rootPriority -Label 'inventory-priority'
    Assert-NkTrue -Name 'INV-13 inventory collection completes with priority_clusters configured' -Condition $resultPriority.Collected -Detail (Get-NkLogTail -Root $rootPriority -Lines 8)
    if ($resultPriority.Collected) {
        $expectedWarning = "Cluster '$missingClusterName' from 'priority_clusters' was not found in the environment."
        Assert-NkTrue -Name 'INV-14 an unknown priority cluster is logged during collection' -Condition (Test-NkContains -Text $resultPriority.Log -Needle $expectedWarning) -Detail (Get-NkLogTail -Root $rootPriority -Lines 8)
    }
}

# ---------------------------------------------------------------------------
# Phase: Control
# ---------------------------------------------------------------------------

function Invoke-NkPhaseControl {
    Write-NkBanner 'Phase: Control'

    # Normal stop
    $stopRoot = New-NkRuntimeRoot -Name 'control-stop'
    $stopRun = Start-NkDaemon -Root $stopRoot
    $started = Wait-NkLogMatch -Root $stopRoot -Pattern 'Main loop started' -Process $stopRun.Process
    Assert-NkTrue -Name 'CTL-01 daemon starts' -Condition $started -Detail (Get-NkLogTail -Root $stopRoot -Lines 8)
    if ($started) {
        $stopExit = Stop-NkDaemon -Run $stopRun -Mode Stop
        $stopLog = Read-NkLog -Root $stopRoot
        Assert-NkEqual -Name 'CTL-02 stop.txt stops the daemon with exit code 0' -Expected 0 -Actual $stopExit
        Assert-NkTrue -Name 'CTL-03 stop.txt is logged and removed' -Condition ((Test-NkContains -Text $stopLog -Needle 'Narvik stopped normally.') -and -not (Test-Path -LiteralPath (Join-Path $stopRoot 'stop.txt'))) -Detail (Get-NkLogTail -Root $stopRoot -Lines 5)
        Assert-NkTrue -Name 'CTL-04 the process lock file is removed on exit' -Condition (-not (Test-Path -LiteralPath (Join-Path $stopRoot 'control/process.txt'))) -Detail 'control/process.txt still exists'
    }
    else {
        Stop-NkDaemon -Run $stopRun -Mode Abort -Force | Out-Null
        Add-NkResult -Status SKIP -Name 'CTL-02..04 stop.txt behaviour' -Detail 'daemon did not start'
    }

    # Abort
    $abortRoot = New-NkRuntimeRoot -Name 'control-abort'
    $abortRun = Start-NkDaemon -Root $abortRoot
    $abortStarted = Wait-NkLogMatch -Root $abortRoot -Pattern 'Main loop started' -Process $abortRun.Process
    Assert-NkTrue -Name 'CTL-05 daemon starts for the abort test' -Condition $abortStarted -Detail (Get-NkLogTail -Root $abortRoot -Lines 8)
    if ($abortStarted) {
        $abortExit = Stop-NkDaemon -Run $abortRun -Mode Abort
        $abortLog = Read-NkLog -Root $abortRoot
        Assert-NkEqual -Name 'CTL-06 abort.txt exits with code 0' -Expected 0 -Actual $abortExit
        Assert-NkTrue -Name 'CTL-07 abort.txt is logged and removed' -Condition ((Test-NkContains -Text $abortLog -Needle 'Narvik was aborted by the operator.') -and -not (Test-Path -LiteralPath (Join-Path $abortRoot 'abort.txt'))) -Detail (Get-NkLogTail -Root $abortRoot -Lines 5)
    }
    else {
        Stop-NkDaemon -Run $abortRun -Mode Abort -Force | Out-Null
        Add-NkResult -Status SKIP -Name 'CTL-06..07 abort.txt behaviour' -Detail 'daemon did not start'
    }

    # Second instance
    $lockRoot = New-NkRuntimeRoot -Name 'control-lock'
    $firstRun = Start-NkDaemon -Root $lockRoot
    $lockStarted = Wait-NkLogMatch -Root $lockRoot -Pattern 'Main loop started' -Process $firstRun.Process
    Assert-NkTrue -Name 'CTL-08 first instance starts for the lock test' -Condition $lockStarted -Detail (Get-NkLogTail -Root $lockRoot -Lines 8)
    if ($lockStarted) {
        $secondRun = Start-NkDaemon -Root $lockRoot
        $secondExited = $false
        try { $secondExited = $secondRun.Process.WaitForExit(60000) } catch { $secondExited = $false }

        Assert-NkTrue -Name 'CTL-09 a second instance exits on its own' -Condition $secondExited -Detail 'the second instance did not exit within 60 seconds'
        if ($secondExited) {
            $secondExit = $null
            try { $secondExit = [int]$secondRun.Process.ExitCode } catch { $secondExit = $null }
            $secondOutput = Get-NkRunOutput -Run $secondRun
            Assert-NkEqual -Name 'CTL-10 a second instance exits with code 3' -Expected 3 -Actual $secondExit
            Assert-NkTrue -Name 'CTL-11 a second instance reports the running process' -Condition (Test-NkContains -Text $secondOutput -Needle 'Another Narvik instance is already running') -Detail (@($secondOutput -split "\r?\n" | Select-Object -First 3) -join ' | ')
        }
        else {
            Stop-NkDaemon -Run $secondRun -Mode Abort -Force | Out-Null
        }

        $firstExit = Stop-NkDaemon -Run $firstRun -Mode Stop
        Assert-NkEqual -Name 'CTL-12 the first instance still stops normally' -Expected 0 -Actual $firstExit
    }
    else {
        Stop-NkDaemon -Run $firstRun -Mode Abort -Force | Out-Null
        Add-NkResult -Status SKIP -Name 'CTL-09..12 second instance behaviour' -Detail 'first instance did not start'
    }

    # Configuration reload failure
    $reloadRoot = New-NkRuntimeRoot -Name 'control-reload'
    $configPath = Join-Path $reloadRoot 'config.json'
    $validConfigText = Read-NkTextShared -Path $configPath
    $reloadRun = Start-NkDaemon -Root $reloadRoot
    $reloadStarted = Wait-NkLogMatch -Root $reloadRoot -Pattern 'Main loop started' -Process $reloadRun.Process
    Assert-NkTrue -Name 'CTL-13 daemon starts for the reload test' -Condition $reloadStarted -Detail (Get-NkLogTail -Root $reloadRoot -Lines 8)
    if ($reloadStarted) {
        Write-NkAtomicText -Path $configPath -Content '{ "this": is not valid json'
        $reloadLogged = Wait-NkLogMatch -Root $reloadRoot -Pattern 'Configuration reload failed; keeping the previous configuration' -TimeoutSeconds 60 -Process $reloadRun.Process
        Assert-NkTrue -Name 'CTL-14 an invalid configuration reload is logged' -Condition $reloadLogged -Detail (Get-NkLogTail -Root $reloadRoot -Lines 8)

        $alive = $true
        try { $alive = -not $reloadRun.Process.HasExited } catch { $alive = $false }
        Assert-NkTrue -Name 'CTL-15 the daemon keeps running with the previous configuration' -Condition $alive -Detail 'the daemon exited after a bad reload'

        Write-NkAtomicText -Path $configPath -Content $validConfigText
        Start-Sleep -Seconds 2

        $reloadExit = Stop-NkDaemon -Run $reloadRun -Mode Stop
        $reloadLog = Read-NkLog -Root $reloadRoot
        Assert-NkEqual -Name 'CTL-16 the daemon still stops normally after a bad reload' -Expected 0 -Actual $reloadExit
        Assert-NkEqual -Name 'CTL-17 the bad reload is logged once, not every loop' -Expected 1 -Actual ([regex]::Matches($reloadLog, 'Configuration reload failed; keeping the previous configuration').Count)
    }
    else {
        Stop-NkDaemon -Run $reloadRun -Mode Abort -Force | Out-Null
        Add-NkResult -Status SKIP -Name 'CTL-14..17 configuration reload behaviour' -Detail 'daemon did not start'
    }

    # Missing root argument
    $argRoot = Get-NkSessionRoot -Name 'control-no-root'
    New-Item -ItemType Directory -Force -Path $argRoot -ErrorAction Stop | Out-Null
    $argRun = Start-NkDaemon -Root $argRoot -ArgumentOverride ('-NoProfile -NonInteractive -File "{0}"' -f $script:NarvikPath)
    $argExited = $false
    try { $argExited = $argRun.Process.WaitForExit(60000) } catch { $argExited = $false }
    Assert-NkTrue -Name 'CTL-18 a missing root argument exits on its own' -Condition $argExited -Detail 'the process did not exit within 60 seconds'
    if ($argExited) {
        $argExit = $null
        try { $argExit = [int]$argRun.Process.ExitCode } catch { $argExit = $null }
        $argOutput = Get-NkRunOutput -Run $argRun
        Assert-NkEqual -Name 'CTL-19 a missing root argument exits with code 1' -Expected 1 -Actual $argExit
        Assert-NkTrue -Name 'CTL-20 a missing root argument prints the usage message' -Condition (Test-NkContains -Text $argOutput -Needle 'The root directory parameter is required') -Detail (@($argOutput -split "\r?\n" | Select-Object -First 3) -join ' | ')
    }
    else {
        try { $argRun.Process.Kill() } catch { }
    }

    Add-NkResult -Status SKIP -Name 'CTL-21 stop.txt waits for an active backup to finish' -Detail 'needs the VM fixtures created by the Fixtures phase'
}

# ---------------------------------------------------------------------------
# Phase: Config
# ---------------------------------------------------------------------------

function Invoke-NkConfigCase {
    param(
        [Parameter(Mandatory = $true)]
        $Case
    )

    $root = New-NkRuntimeRoot -Name ("config-" + $Case.Id.ToLowerInvariant())
    $configPath = Join-Path $root 'config.json'

    switch ($Case.Kind) {
        'RemoveConfig' {
            Remove-Item -LiteralPath $configPath -Force -ErrorAction Stop
        }
        'RawText' {
            Write-NkAtomicText -Path $configPath -Content $Case.Text
        }
        'Overrides' {
            $config = Get-NkBaseConfig
            foreach ($key in $Case.Overrides.Keys) {
                $config[$key] = $Case.Overrides[$key]
            }
            Write-NkAtomicText -Path $configPath -Content ($config | ConvertTo-Json -Depth 10)
        }
        'RemovePassword' {
            Remove-Item -LiteralPath (Join-Path $root 'vcenter_password.txt') -Force -ErrorAction Stop
        }
    }

    $argument = $null
    if ($null -ne $Case.ArgumentOverride) {
        $argument = [string]$Case.ArgumentOverride
    }
    else {
        $argument = ('-NoProfile -NonInteractive -File "{0}" "{1}"' -f $script:NarvikPath, $root)
    }

    $run = Start-NkDaemon -Root $root -ArgumentOverride $argument
    $exited = $false
    try { $exited = $run.Process.WaitForExit(60000) } catch { $exited = $false }

    if (-not $exited) {
        try { $run.Process.Kill() } catch { }
        Add-NkResult -Status FAIL -Name ("$($Case.Id) $($Case.Name)") -Detail 'the process did not exit within 60 seconds'
        return
    }

    $exitCode = $null
    try { $exitCode = [int]$run.Process.ExitCode } catch { $exitCode = $null }
    $output = Get-NkRunOutput -Run $run

    $ok = ($exitCode -eq 1 -and (Test-NkContains -Text $output -Needle $Case.Expect))
    $detail = "exit $exitCode; expected message '$($Case.Expect)'"
    if (-not $ok) {
        $tail = @($output -split "\r?\n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 3) -join ' | '
        $detail = "$detail; output: $tail"
    }
    if ($ok) {
        Add-NkResult -Status PASS -Name ("$($Case.Id) $($Case.Name)")
    }
    else {
        Add-NkResult -Status FAIL -Name ("$($Case.Id) $($Case.Name)") -Detail $detail
    }
}

function Invoke-NkPhaseConfig {
    Write-NkBanner 'Phase: Config'

    $cases = @(
        @{ Id = 'CFG-01'; Name = 'missing root argument'; Kind = 'Overrides'; ArgumentOverride = ('-NoProfile -NonInteractive -File "{0}"' -f $script:NarvikPath); Expect = 'The root directory parameter is required' },
        @{ Id = 'CFG-02'; Name = 'missing config.json'; Kind = 'RemoveConfig'; Expect = 'Configuration file not found' },
        @{ Id = 'CFG-03'; Name = 'invalid JSON'; Kind = 'RawText'; Text = '{ "log_level": '; Expect = 'Failed to parse configuration file' },
        @{ Id = 'CFG-04'; Name = 'config is a JSON array'; Kind = 'RawText'; Text = '[]'; Expect = 'must contain a JSON object' },
        @{ Id = 'CFG-05'; Name = 'invalid log_level'; Kind = 'Overrides'; Overrides = @{ log_level = 'Chatty' }; Expect = "'log_level' must be Debug, Info, Warning or Error" },
        @{ Id = 'CFG-06'; Name = 'empty dsmc_path'; Kind = 'Overrides'; Overrides = @{ dsmc_path = '' }; Expect = "'dsmc_path' must not be empty" },
        @{ Id = 'CFG-07'; Name = 'missing dsmc executable'; Kind = 'Overrides'; Overrides = @{ dsmc_path = 'does-not-exist.exe' }; Expect = 'dsmc executable not found' },
        @{ Id = 'CFG-08'; Name = 'empty vcenter_server'; Kind = 'Overrides'; Overrides = @{ vcenter_server = '' }; Expect = "'vcenter_server' must not be empty" },
        @{ Id = 'CFG-09'; Name = 'vcenter_server with a scheme'; Kind = 'Overrides'; Overrides = @{ vcenter_server = 'https://192.168.122.234' }; Expect = "'vcenter_server' must be a hostname or IP address without scheme" },
        @{ Id = 'CFG-10'; Name = 'vcenter_port out of range'; Kind = 'Overrides'; Overrides = @{ vcenter_port = 70000 }; Expect = "'vcenter_port' must be between 1 and 65535" },
        @{ Id = 'CFG-11'; Name = 'non-integer vcenter_port'; Kind = 'Overrides'; Overrides = @{ vcenter_port = 'abc' }; Expect = "'vcenter_port' must be an integer" },
        @{ Id = 'CFG-12'; Name = 'empty vcenter_password_file'; Kind = 'Overrides'; Overrides = @{ vcenter_password_file = '' }; Expect = "'vcenter_password_file' must not be empty" },
        @{ Id = 'CFG-13'; Name = 'missing password file'; Kind = 'RemovePassword'; Expect = 'vCenter password file not found' },
        @{ Id = 'CFG-14'; Name = 'max_backup_threads below one'; Kind = 'Overrides'; Overrides = @{ max_backup_threads = 0 }; Expect = "'max_backup_threads' must be at least 1" },
        @{ Id = 'CFG-15'; Name = 'management class map is a string'; Kind = 'Overrides'; Overrides = @{ datastore_cluster_to_management_class = 'DSC1=CLASS' }; Expect = "must be an object mapping datastore cluster names" },
        @{ Id = 'CFG-16'; Name = 'management class map has an empty value'; Kind = 'Overrides'; Overrides = @{ datastore_cluster_to_management_class = @{ DSC1 = '' } }; Expect = 'contains an empty management class' },
        @{ Id = 'CFG-17'; Name = 'management class map with an empty key cannot be parsed'; Kind = 'RawText'; Text = '{ "datastore_cluster_to_management_class": { "": "CLASS" } }'; Expect = 'Failed to parse configuration file' },
        @{ Id = 'CFG-18'; Name = 'invalid bypass_security value'; Kind = 'Overrides'; Overrides = @{ bypass_security = 'maybe' }; Expect = 'bypass_security' },
        @{ Id = 'CFG-19'; Name = 'SMTP user without a password file'; Kind = 'Overrides'; Overrides = @{ smtp_server = 'smtp.example.local'; smtp_username = 'user'; smtp_password_file = '' }; Expect = "'smtp_password_file' is required" },
        @{ Id = 'CFG-20'; Name = 'invalid mail_from address'; Kind = 'Overrides'; Overrides = @{ smtp_server = 'smtp.example.local'; mail_from = 'not-an-address' }; Expect = "'mail_from' is not a valid email address" },
        @{ Id = 'CFG-21'; Name = 'unknown key is warned about'; Kind = 'Overrides'; Overrides = @{ bogus_key = 1; vcenter_server = 'https://bad' }; Expect = "Unknown configuration key 'bogus_key'" },
        @{ Id = 'CFG-22'; Name = 'priority_clusters is not an array'; Kind = 'Overrides'; Overrides = @{ priority_clusters = 'CL1' }; Expect = "'priority_clusters' must be an array" },
        @{ Id = 'CFG-23'; Name = 'priority_clusters contains a bare string'; Kind = 'Overrides'; Overrides = @{ priority_clusters = @('CL1', 'CL2') }; Expect = "'priority_clusters' must contain objects" },
        @{ Id = 'CFG-24'; Name = 'priority cluster entry without a name'; Kind = 'Overrides'; Overrides = @{ priority_clusters = @(@{ priority = 0 }) }; Expect = "without a non-empty 'name'" },
        @{ Id = 'CFG-25'; Name = 'priority cluster entry with an empty name'; Kind = 'Overrides'; Overrides = @{ priority_clusters = @(@{ name = ''; priority = 0 }) }; Expect = "without a non-empty 'name'" },
        @{ Id = 'CFG-26'; Name = 'non-integer cluster priority'; Kind = 'Overrides'; Overrides = @{ priority_clusters = @(@{ name = 'CL1'; priority = 'abc' }) }; Expect = 'contains a non-integer priority' },
        @{ Id = 'CFG-27'; Name = 'cluster priority below -100'; Kind = 'Overrides'; Overrides = @{ priority_clusters = @(@{ name = 'CL1'; priority = -101 }) }; Expect = 'it must be between -100 and 100' },
        @{ Id = 'CFG-28'; Name = 'cluster priority above 100'; Kind = 'Overrides'; Overrides = @{ priority_clusters = @(@{ name = 'CL1'; priority = 101 }) }; Expect = 'it must be between -100 and 100' },
        @{ Id = 'CFG-29'; Name = 'cluster max_threads below one'; Kind = 'Overrides'; Overrides = @{ priority_clusters = @(@{ name = 'CL1'; priority = 0; max_threads = 0 }) }; Expect = 'it must be at least 1' },
        @{ Id = 'CFG-30'; Name = 'duplicate cluster name ignoring case'; Kind = 'Overrides'; Overrides = @{ priority_clusters = @(@{ name = 'CL1'; priority = 1 }, @{ name = 'cl1'; priority = 2 }) }; Expect = 'more than once' },
        @{ Id = 'CFG-31'; Name = 'non-integer cluster max_threads'; Kind = 'Overrides'; Overrides = @{ priority_clusters = @(@{ name = 'CL1'; priority = 0; max_threads = 'abc' }) }; Expect = 'non-integer max_threads' }
    )

    foreach ($case in $cases) {
        Invoke-NkConfigCase -Case $case
    }
}

# ---------------------------------------------------------------------------
# Phase: Fixtures
# ---------------------------------------------------------------------------

function Get-NkManifest {
    if (-not (Test-Path -LiteralPath $script:ManifestPath -PathType Leaf)) {
        return $null
    }

    try {
        return (Read-NkTextShared -Path $script:ManifestPath | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        return $null
    }
}

function Save-NkManifest {
    param(
        [Parameter(Mandatory = $true)]
        $Manifest
    )

    $directory = Split-Path -Parent $script:ManifestPath
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $directory -ErrorAction Stop | Out-Null
    }

    Write-NkAtomicText -Path $script:ManifestPath -Content ($Manifest | ConvertTo-Json -Depth 10)
}

function Add-NkFixtureVm {
    param(
        [Parameter(Mandatory = $true)]
        $Manifest,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$Created,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (-not $Created.Contains($Name)) {
        [void]$Created.Add($Name)
    }

    # Save after every VM so an interrupted phase still leaves a manifest that
    # Teardown can use to delete the fixtures it already created.
    $Manifest.VMs = @($Created)
    Save-NkManifest -Manifest $Manifest
}

function Get-NkFixtureVm {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return @($script:VmInfo | Where-Object { $_.Name -ceq $Name })
}

function New-NkFolderObject {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        $Parent
    )

    Assert-NkSafeName -Name $Name -Kind 'folder'

    foreach ($folder in @(Get-Folder -ErrorAction Stop | Where-Object { $_.Name -eq $Name })) {
        try {
            if ($folder.Parent.Id -eq $Parent.Id) {
                return $folder
            }
        }
        catch {
        }
    }

    return (New-Folder -Name $Name -Location $Parent -Confirm:$false -ErrorAction Stop)
}

function New-NkFixtureVmObject {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$DatastoreName,

        [Parameter(Mandatory = $true)]
        $Folder,

        [string]$ResourcePoolName = '',

        [switch]$NoDisk,

        [long]$DiskCapacityKB = 0,

        [string[]]$ExtraDatastoreNames = @(),

        [string]$Notes = ''
    )

    Assert-NkSafeName -Name $Name -Kind 'VM'

    $existing = @(Get-View -ViewType VirtualMachine -Property Name -ErrorAction Stop | Where-Object { $_.Name -ceq $Name })
    if ($existing.Count -gt 0) {
        return (Get-VM -Id ("VirtualMachine-{0}" -f $existing[0].MoRef.Value) -ErrorAction Stop)
    }

    $datastore = Get-Datastore -Name $DatastoreName -ErrorAction Stop | Select-Object -First 1
    if ($null -eq $datastore) {
        throw "Datastore '$DatastoreName' not found."
    }

    $pool = $null
    if (-not [string]::IsNullOrWhiteSpace($ResourcePoolName)) {
        $pool = Get-ResourcePool -Name $ResourcePoolName -ErrorAction Stop | Select-Object -First 1
    }
    if ($null -eq $pool) {
        $pool = Get-ResourcePool -Name 'Resources' -ErrorAction Stop | Select-Object -First 1
    }
    if ($null -eq $pool) {
        $pool = Get-ResourcePool -ErrorAction Stop | Select-Object -First 1
    }

    $parameters = @{
        Name        = $Name
        Location    = $Folder
        VMHost      = $script:VmHost
        ResourcePool = $pool
        Datastore   = $datastore
        GuestId     = 'otherGuest'
        DiskGB      = 1
        DiskStorageFormat = 'Thin'
        Confirm     = $false
        ErrorAction = 'Stop'
    }

    $vm = New-VM @parameters

    if ($NoDisk -or $DiskCapacityKB -gt 0) {
        # New-VM cannot create a diskless VM here: -SkipHardDisks requires a
        # key provider or storage policy and the lab has no policy the
        # datastores accept. It also only takes whole GB/MB. So create the VM
        # with a 1 GiB disk and replace that disk with the exact capacity the
        # fixture needs. A capacity that is not a multiple of 1 MiB is how the
        # end-to-end disk size rule is exercised.
        foreach ($disk in @(Get-HardDisk -VM $vm -ErrorAction Stop)) {
            Remove-HardDisk -HardDisk $disk -Confirm:$false -ErrorAction Stop | Out-Null
        }
    }

    if (-not $NoDisk -and $DiskCapacityKB -gt 0) {
        New-HardDisk -VM $vm -CapacityKB $DiskCapacityKB -StorageFormat Thin -Datastore $datastore -Confirm:$false -ErrorAction Stop | Out-Null
    }

    foreach ($extraName in @($ExtraDatastoreNames)) {
        $extra = Get-Datastore -Name $extraName -ErrorAction Stop | Select-Object -First 1
        New-HardDisk -VM $vm -CapacityGB 1 -StorageFormat Thin -Datastore $extra -Confirm:$false -ErrorAction Stop | Out-Null
    }

    if (-not [string]::IsNullOrWhiteSpace($Notes)) {
        Set-VM -VM $vm -Notes $Notes -Confirm:$false -ErrorAction Stop | Out-Null
    }

    return $vm
}

function Get-NkDatastoreFreeGB {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    try {
        $datastore = Get-Datastore -Name $Name -ErrorAction Stop | Select-Object -First 1
        if ($null -eq $datastore) {
            return -1
        }
        return [double]$datastore.FreeSpaceGB
    }
    catch {
        return -1
    }
}

function Select-NkDatastoreForPod {
    param(
        [Parameter(Mandatory = $true)]
        $Pod
    )

    $candidates = [System.Collections.Generic.List[object]]::new()
    foreach ($datastoreId in @($Pod.DatastoreIds)) {
        $name = ''
        if ($script:DatastoreMap.ContainsKey($datastoreId)) {
            $name = [string]$script:DatastoreMap[$datastoreId]
        }
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }

        $free = Get-NkDatastoreFreeGB -Name $name
        if ($free -lt 3) {
            continue
        }

        [void]$candidates.Add([pscustomobject]@{ Name = $name; FreeGB = $free })
    }

    $selected = @($candidates | Sort-Object -Property @{ Expression = { $_.FreeGB }; Descending = $true } | Select-Object -First 1)
    if ($selected.Count -eq 0) {
        return ''
    }

    return [string]$selected[0].Name
}

function Get-NkTaggedEntityNames {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('ResourcePool', 'Datastore', 'StoragePod', 'Folder', 'ClusterComputeResource')]
        [string]$Type
    )

    if ([string]::IsNullOrWhiteSpace($script:UseTagName)) {
        return @()
    }

    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($assignment in @($script:TagAssignments)) {
        if ([string]$assignment.Tag.Name -ine $script:UseTagName) {
            continue
        }

        $entity = Get-NkTagAssignmentEntity -Assignment $assignment -Type $Type
        if ($null -eq $entity) {
            continue
        }

        if (-not $names.Contains($entity.Name)) {
            [void]$names.Add($entity.Name)
        }
    }

    return @($names)
}

function Get-NkVmFolderNames {
    $vmFolderIds = @{}
    foreach ($view in @(Get-View -ViewType Datacenter -Property Name, VmFolder -ErrorAction Stop | Where-Object { $null -ne $_ })) {
        $vmFolderIds[[string]$view.VmFolder.Value] = $true
    }

    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($folderId in $script:FolderMap.Keys) {
        $folder = $script:FolderMap[$folderId]
        $current = $folder
        $isVmFolder = $true
        $guard = 0
        while ($null -ne $current -and $guard -lt 64) {
            $guard++
            $parent = $null
            try { $parent = $current.Parent } catch { $parent = $null }
            if ($null -eq $parent) {
                $isVmFolder = $false
                break
            }
            if ([string]$parent.Type -eq 'Datacenter' -or $vmFolderIds.ContainsKey([string]$parent.Value)) {
                $isVmFolder = $true
                break
            }
            if (-not $script:FolderMap.ContainsKey([string]$parent.Value)) {
                $isVmFolder = $false
                break
            }
            $current = $script:FolderMap[[string]$parent.Value]
        }

        if ($isVmFolder -and -not $names.Contains([string]$folder.Name)) {
            [void]$names.Add([string]$folder.Name)
        }
    }

    return @($names)
}

function Invoke-NkPhaseFixtures {
    Write-NkBanner 'Phase: Fixtures'
    Update-NkInventoryInfo

    if (-not $script:PbmAvailable) {
        Add-NkResult -Status BLOCK -Name 'FIX-01 fixtures can be created' -Detail ("vCenter storage policy service is unavailable: {0}" -f $script:PbmMessage)
        return
    }

    if ($null -eq $script:VmHost -or $null -eq $script:VmFolder) {
        Add-NkResult -Status BLOCK -Name 'FIX-01 fixtures can be created' -Detail 'no usable host or VM folder was found'
        return
    }

    $taggedPods = @(Get-NkTaggedEntityNames -Type StoragePod)
    $normalPod = $null
    foreach ($pod in @($script:Pods)) {
        if ($taggedPods -notcontains $pod.Name) {
            $normalPod = $pod
            break
        }
    }
    if ($null -eq $normalPod -and @($script:Pods).Count -gt 0) {
        $normalPod = @($script:Pods)[0]
    }

    if ($null -eq $normalPod) {
        Add-NkResult -Status BLOCK -Name 'FIX-01 fixtures can be created' -Detail 'the lab has no datastore cluster'
        return
    }

    $normalDatastore = Select-NkDatastoreForPod -Pod $normalPod
    if ([string]::IsNullOrWhiteSpace($normalDatastore)) {
        Add-NkResult -Status BLOCK -Name 'FIX-01 fixtures can be created' -Detail "no datastore in '$($normalPod.Name)' has at least 3 GB free"
        return
    }

    $script:NormalPod = $normalPod
    $script:NormalDatastore = $normalDatastore

    $manifest = @{
        CreatedAt  = (Get-Date).ToString('o')
        TagName    = $script:UseTagName
        FolderId   = ''
        FolderName = ''
        VMs        = @()
        Folders    = @()
        TagSources = @()
    }

    $fixtureFolder = New-NkFolderObject -Name "$($script:FixturePrefix)-fixtures" -Parent $script:VmFolder
    $manifest.FolderId = [string]$fixtureFolder.ExtensionData.MoRef.Value
    $manifest.FolderName = [string]$fixtureFolder.Name
    if (-not (@($manifest.Folders) -contains $manifest.FolderId)) {
        $manifest.Folders = @($manifest.Folders) + @($manifest.FolderId)
    }
    # Persist the folder before creating VMs: if creation fails midway, Teardown
    # still knows what to clean up.
    Save-NkManifest -Manifest $manifest

    $createdVms = [System.Collections.Generic.List[string]]::new()

    # Core fixtures. The notes are empty so the VM is pending; later phases
    # write or clear notes to put a VM on the other side of the baseline.
    # The "_dup" and "_err" suffixes are dsmc_fake.ps1 hooks, not Narvik
    # behaviour: the stand-in fails the first incremental backup of a VM whose
    # name contains "_dup" with ANS1715E and always fails one containing
    # "_err".
    $coreDefinitions = @(
        @{ Name = "$($script:FixturePrefix)-inc"; NoDisk = $false; DiskCapacityKB = 0; Extra = @(); Notes = '' },
        @{ Name = "$($script:FixturePrefix)-full"; NoDisk = $false; DiskCapacityKB = 0; Extra = @(); Notes = '' },
        @{ Name = "$($script:FixturePrefix)-dup_dup"; NoDisk = $false; DiskCapacityKB = 0; Extra = @(); Notes = '' },
        @{ Name = "$($script:FixturePrefix)-err_err"; NoDisk = $false; DiskCapacityKB = 0; Extra = @(); Notes = '' },
        @{ Name = "$($script:FixturePrefix)-nodisk"; NoDisk = $true; DiskCapacityKB = 0; Extra = @(); Notes = '' },
        # 1048064 KB = 1023.5 MiB: at most 1 GiB but not a multiple of 1 MiB,
        # which the backup command does not accept.
        @{ Name = "$($script:FixturePrefix)-size"; NoDisk = $false; DiskCapacityKB = 1048064; Extra = @(); Notes = '' }
    )

    $otherPod = $null
    foreach ($pod in @($script:Pods)) {
        if ($pod.Name -ne $normalPod.Name) {
            $otherPod = $pod
            break
        }
    }
    $otherDatastore = ''
    if ($null -ne $otherPod) {
        $otherDatastore = Select-NkDatastoreForPod -Pod $otherPod
    }

    foreach ($definition in $coreDefinitions) {
        $extra = @($definition.Extra)
        if ($definition.Name -eq "$($script:FixturePrefix)-multi" -and -not [string]::IsNullOrWhiteSpace($otherDatastore)) {
            $extra = @($otherDatastore)
        }

        try {
            $vm = New-NkFixtureVmObject -Name $definition.Name -DatastoreName $normalDatastore -Folder $fixtureFolder -NoDisk:$definition.NoDisk -DiskCapacityKB ([long]$definition.DiskCapacityKB) -ExtraDatastoreNames $extra -Notes $definition.Notes
            Add-NkFixtureVm -Manifest $manifest -Created $createdVms -Name $definition.Name
            Assert-NkTrue -Name ("FIX-02 created VM '{0}'" -f $definition.Name) -Condition ($null -ne $vm)
        }
        catch {
            Add-NkResult -Status FAIL -Name ("FIX-02 created VM '{0}'" -f $definition.Name) -Detail $_.Exception.Message
        }
    }

    # A VM with two disks in two different datastore clusters.
    if (-not [string]::IsNullOrWhiteSpace($otherDatastore)) {
        try {
            $multiVm = New-NkFixtureVmObject -Name "$($script:FixturePrefix)-multi" -DatastoreName $normalDatastore -Folder $fixtureFolder -ExtraDatastoreNames @($otherDatastore)
            Add-NkFixtureVm -Manifest $manifest -Created $createdVms -Name "$($script:FixturePrefix)-multi"
            Assert-NkTrue -Name 'FIX-03 created a VM with two disks in different datastore clusters' -Condition ($null -ne $multiVm)
        }
        catch {
            Add-NkResult -Status FAIL -Name 'FIX-03 created a VM with two disks in different datastore clusters' -Detail $_.Exception.Message
        }
    }
    else {
        Add-NkResult -Status SKIP -Name 'FIX-03 created a VM with two disks in different datastore clusters' -Detail 'the lab has only one datastore cluster'
    }

    # A VM whose name contains a character dsmc cannot use.
    try {
        $badNameVm = New-NkFixtureVmObject -Name "$($script:FixturePrefix)-name[01]" -DatastoreName $normalDatastore -Folder $fixtureFolder
        Add-NkFixtureVm -Manifest $manifest -Created $createdVms -Name "$($script:FixturePrefix)-name[01]"
        Assert-NkTrue -Name 'FIX-04 created a VM with an unsupported name character' -Condition ($null -ne $badNameVm)
    }
    catch {
        Add-NkResult -Status SKIP -Name 'FIX-04 created a VM with an unsupported name character' -Detail $_.Exception.Message
    }

    # Tag sources: only use assignments that already exist in the lab. The
    # suite never creates or assigns tags.
    $taggedPools = @(Get-NkTaggedEntityNames -Type ResourcePool)
    foreach ($poolName in $taggedPools) {
        try {
            $vm = New-NkFixtureVmObject -Name "$($script:FixturePrefix)-rp" -DatastoreName $normalDatastore -Folder $fixtureFolder -ResourcePoolName $poolName
            Add-NkFixtureVm -Manifest $manifest -Created $createdVms -Name "$($script:FixturePrefix)-rp"
            $manifest.TagSources = @($manifest.TagSources) + @([pscustomobject]@{ Kind = 'ResourcePool'; Name = $poolName; VM = "$($script:FixturePrefix)-rp"; Reason = "Resource pool '$poolName' tag '$($script:UseTagName)'" })
            Add-NkResult -Status PASS -Name 'FIX-05 created the resource pool tag fixture' -Detail "pool '$poolName'"
            break
        }
        catch {
            Add-NkResult -Status SKIP -Name 'FIX-05 created the resource pool tag fixture' -Detail $_.Exception.Message
        }
    }
    if ($taggedPools.Count -eq 0) {
        Add-NkResult -Status SKIP -Name 'FIX-05 created the resource pool tag fixture' -Detail 'no tagged resource pool exists in the lab'
    }

    $taggedDatastores = @(Get-NkTaggedEntityNames -Type Datastore)
    $safeTaggedDatastore = ''
    foreach ($name in $taggedDatastores) {
        if ($name -eq $normalDatastore) {
            continue
        }
        if ((Get-NkDatastoreFreeGB -Name $name) -lt 3) {
            continue
        }
        $safeTaggedDatastore = $name
        break
    }
    if (-not [string]::IsNullOrWhiteSpace($safeTaggedDatastore)) {
        try {
            $vm = New-NkFixtureVmObject -Name "$($script:FixturePrefix)-ds" -DatastoreName $safeTaggedDatastore -Folder $fixtureFolder
            Add-NkFixtureVm -Manifest $manifest -Created $createdVms -Name "$($script:FixturePrefix)-ds"
            $manifest.TagSources = @($manifest.TagSources) + @([pscustomobject]@{ Kind = 'Datastore'; Name = $safeTaggedDatastore; VM = "$($script:FixturePrefix)-ds"; Reason = "Datastore '$safeTaggedDatastore' tag '$($script:UseTagName)'" })
            Add-NkResult -Status PASS -Name 'FIX-06 created the datastore tag fixture' -Detail "datastore '$safeTaggedDatastore'"
        }
        catch {
            Add-NkResult -Status SKIP -Name 'FIX-06 created the datastore tag fixture' -Detail $_.Exception.Message
        }
    }
    else {
        Add-NkResult -Status SKIP -Name 'FIX-06 created the datastore tag fixture' -Detail 'no tagged datastore with free space exists outside the normal datastore'
    }

    $taggedPodNames = @(Get-NkTaggedEntityNames -Type StoragePod)
    $taggedPodDatastore = ''
    $taggedPodName = ''
    foreach ($pod in @($script:Pods)) {
        if ($taggedPodNames -notcontains $pod.Name) {
            continue
        }
        $candidate = Select-NkDatastoreForPod -Pod $pod
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $taggedPodName = $pod.Name
            $taggedPodDatastore = $candidate
            break
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($taggedPodDatastore)) {
        try {
            $vm = New-NkFixtureVmObject -Name "$($script:FixturePrefix)-pod" -DatastoreName $taggedPodDatastore -Folder $fixtureFolder
            Add-NkFixtureVm -Manifest $manifest -Created $createdVms -Name "$($script:FixturePrefix)-pod"
            $manifest.TagSources = @($manifest.TagSources) + @([pscustomobject]@{ Kind = 'DatastoreCluster'; Name = $taggedPodName; VM = "$($script:FixturePrefix)-pod"; Reason = "Datastore cluster '$taggedPodName' tag '$($script:UseTagName)'" })
            Add-NkResult -Status PASS -Name 'FIX-07 created the datastore cluster tag fixture' -Detail "datastore cluster '$taggedPodName'"
        }
        catch {
            Add-NkResult -Status SKIP -Name 'FIX-07 created the datastore cluster tag fixture' -Detail $_.Exception.Message
        }
    }
    else {
        $debugPods = @($script:Pods | ForEach-Object { "{0} ({1} datastore(s))" -f $_.Name, @($_.DatastoreIds).Count }) -join ', '
        Add-NkResult -Status SKIP -Name 'FIX-07 created the datastore cluster tag fixture' -Detail ("no tagged datastore cluster with free space exists; tagged: [{0}]; pods: [{1}]" -f (@($taggedPodNames) -join ', '), $debugPods)
    }

    $taggedFolders = @(Get-NkTaggedEntityNames -Type Folder)
    $vmFolderNames = @(Get-NkVmFolderNames)
    $taggedVmFolder = ''
    foreach ($name in $taggedFolders) {
        if ($vmFolderNames -contains $name) {
            $taggedVmFolder = $name
            break
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($taggedVmFolder)) {
        try {
            $folderObject = Get-Folder -Name $taggedVmFolder -ErrorAction Stop | Select-Object -First 1
            $vm = New-NkFixtureVmObject -Name "$($script:FixturePrefix)-folder" -DatastoreName $normalDatastore -Folder $folderObject
            Add-NkFixtureVm -Manifest $manifest -Created $createdVms -Name "$($script:FixturePrefix)-folder"
            $manifest.TagSources = @($manifest.TagSources) + @([pscustomobject]@{ Kind = 'Folder'; Name = $taggedVmFolder; VM = "$($script:FixturePrefix)-folder"; Reason = "Folder '$taggedVmFolder' tag '$($script:UseTagName)'" })

            $childFolder = New-NkFolderObject -Name "$($script:FixturePrefix)-child" -Parent $folderObject
            $manifest.Folders = @($manifest.Folders) + @([string]$childFolder.ExtensionData.MoRef.Value)
            Save-NkManifest -Manifest $manifest
            $childVm = New-NkFixtureVmObject -Name "$($script:FixturePrefix)-folderchild" -DatastoreName $normalDatastore -Folder $childFolder
            Add-NkFixtureVm -Manifest $manifest -Created $createdVms -Name "$($script:FixturePrefix)-folderchild"
            Add-NkResult -Status PASS -Name 'FIX-08 created the folder tag fixtures' -Detail "folder '$taggedVmFolder'"
        }
        catch {
            Add-NkResult -Status SKIP -Name 'FIX-08 created the folder tag fixtures' -Detail $_.Exception.Message
        }
    }
    else {
        Add-NkResult -Status SKIP -Name 'FIX-08 created the folder tag fixtures' -Detail 'no tagged VM folder exists in the lab (creating or assigning tags is not allowed)'
    }

    Add-NkResult -Status SKIP -Name 'FIX-09 created the VM tag fixture' -Detail 'creating tags or tag assignments is not allowed'
    Add-NkResult -Status SKIP -Name 'FIX-10 created the cluster tag fixture' -Detail 'the lab has no ClusterComputeResource and creating one needs operator approval'

    Update-NkInventoryInfo

    $createdObjects = @($script:VmInfo | Where-Object { $createdVms -contains $_.Name })
    foreach ($vm in $createdObjects) {
        Assert-NkTrue -Name ("FIX-11 VM '{0}' is powered off" -f $vm.Name) -Condition ($vm.PowerState -eq 'poweredOff') -Detail $vm.PowerState
        if (@($vm.Disks).Count -gt 0) {
            $wrong = @($vm.Disks | Where-Object { [long]$_.CapacityInKB -le 0 -or [long]$_.CapacityInKB -gt 1048576 })
            Assert-NkTrue -Name ("FIX-12 every disk of '{0}' is at most 1 GiB" -f $vm.Name) -Condition ($wrong.Count -eq 0) -Detail (@($wrong | ForEach-Object { "$($_.Label)=$($_.CapacityInKB) KB" }) -join ', ')
        }
    }

    $sizeVm = @($createdObjects | Where-Object { $_.Name -eq "$($script:FixturePrefix)-size" } | Select-Object -First 1)
    if ($sizeVm.Count -eq 0 -or @($sizeVm[0].Disks).Count -eq 0) {
        Add-NkResult -Status SKIP -Name 'FIX-14 the size fixture keeps a capacity that is not a multiple of 1 MiB' -Detail 'the size fixture or its disk was not created'
    }
    else {
        $sizeKb = [long]$sizeVm[0].Disks[0].CapacityInKB
        Assert-NkTrue -Name 'FIX-14 the size fixture keeps a capacity that is not a multiple of 1 MiB' -Condition ($sizeKb -eq 1048064) -Detail ("{0} KB; vCenter may have rounded the requested 1048064 KB" -f $sizeKb)
    }

    $manifest.VMs = @($createdVms)
    Save-NkManifest -Manifest $manifest

    Add-NkResult -Status PASS -Name 'FIX-13 fixture manifest saved' -Detail ("{0} VM(s), {1} folder(s), {2} tag source(s)" -f @($manifest.VMs).Count, @($manifest.Folders).Count, @($manifest.TagSources).Count)
}

# ---------------------------------------------------------------------------
# Fixture state and run inspection helpers
# ---------------------------------------------------------------------------

function Read-NkJsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        return (Read-NkTextShared -Path $Path | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        return $null
    }
}

function Get-NkManifestVmNames {
    $manifest = Get-NkManifest
    if ($null -eq $manifest) {
        return @()
    }

    return @($manifest.VMs | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
}

function Get-NkLiveVm {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $views = @(Get-View -ViewType VirtualMachine -Property Name -ErrorAction Stop | Where-Object { $_.Name -ceq $Name })
    if ($views.Count -eq 0) {
        return $null
    }

    try {
        return (Get-VM -Id ("VirtualMachine-{0}" -f $views[0].MoRef.Value) -ErrorAction Stop)
    }
    catch {
        # The view can be a moment behind a VM that was just deleted; for
        # cleanup that simply means there is nothing left to delete.
        return $null
    }
}

function Get-NkLiveNotes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $views = @(Get-View -ViewType VirtualMachine -Property Name, Config.Annotation -ErrorAction Stop | Where-Object { $_.Name -ceq $Name })
    if ($views.Count -eq 0) {
        return ''
    }

    $notes = ''
    try { $notes = [string]$views[0].Config.Annotation } catch { $notes = '' }
    return $notes
}

function Set-NkFixtureNotes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowEmptyString()]
        [string]$Notes = ''
    )

    # The lab host occasionally drops a request for a moment (the VM briefly
    # reports "disconnected"); retry so one transient error does not fail a
    # whole phase.
    $lastError = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $vm = Get-NkLiveVm -Name $Name
        if ($null -eq $vm) {
            throw "VM '$Name' not found; cannot set its notes."
        }

        try {
            Set-VM -VM $vm -Notes $Notes -Confirm:$false -ErrorAction Stop | Out-Null
            return
        }
        catch {
            $lastError = $_
            if ($attempt -lt 3) {
                Start-Sleep -Seconds 5
            }
        }
    }

    throw $lastError
}

function Set-NkPendingSelection {
    param(
        [string[]]$Pending = @(),

        [string[]]$All = @()
    )

    # Narvik's baseline is the last 20:00 local time and a VM is pending while
    # its Notes timestamp is older than that. Writing the current time is
    # always fresh enough, and clearing the note makes the VM pending.
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $changed = 0
    foreach ($name in @($All)) {
        $cleanName = [string]$name
        if ([string]::IsNullOrWhiteSpace($cleanName)) {
            continue
        }

        if (@($Pending) -contains $cleanName) {
            Set-NkFixtureNotes -Name $cleanName -Notes ''
        }
        else {
            Set-NkFixtureNotes -Name $cleanName -Notes ('Last backup: ' + $stamp)
        }
        $changed++
    }

    return $changed
}

function Get-NkStartedBackupLine {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Log,

        [Parameter(Mandatory = $true)]
        [string]$VmName
    )

    $pattern = "Started (?:Incremental|Full) backup for VM '" + [regex]::Escape($VmName) + "'[^\r\n]*"
    $found = @([regex]::Matches($Log, $pattern))
    if ($found.Count -eq 0) {
        return @()
    }

    return @($found | ForEach-Object { $_.Value })
}

function Get-NkStateObject {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    return (Read-NkJsonFile -Path (Join-Path $Root 'control/state.json'))
}

function Get-NkLastFullObject {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    return (Read-NkJsonFile -Path (Join-Path $Root 'control/last_full.json'))
}

function Test-NkStateHasDuplicateGuid {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$VmName
    )

    $state = Get-NkStateObject -Root $Root
    if ($null -eq $state -or $null -eq $state.duplicate_guid) {
        return $false
    }

    foreach ($name in @($state.duplicate_guid)) {
        if ([string]$name -ceq $VmName) {
            return $true
        }
    }

    return $false
}

function Get-NkFailedAttemptCount {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$VmName
    )

    $state = Get-NkStateObject -Root $Root
    if ($null -eq $state -or $null -eq $state.failed_attempts) {
        return 0
    }

    foreach ($property in $state.failed_attempts.PSObject.Properties) {
        if ($property.Name -ceq $VmName) {
            try { return [int]$property.Value.count } catch { return 0 }
        }
    }

    return 0
}

# ---------------------------------------------------------------------------
# Phase: Tags
# ---------------------------------------------------------------------------

function Get-NkNonEligibleReasonText {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Map,

        [Parameter(Mandatory = $true)]
        [string]$VmName
    )

    if (-not $Map.ContainsKey($VmName)) {
        return ''
    }

    return [string]$Map[$VmName]
}

function Invoke-NkPhaseTags {
    Write-NkBanner 'Phase: Tags'

    if ([string]::IsNullOrWhiteSpace($script:UseTagName)) {
        Add-NkResult -Status SKIP -Name 'TAGS-01 tag opt-out rule' -Detail 'the lab has no tag assignment, so no rule tag can be chosen'
        return
    }

    $fixtureNames = @(Get-NkManifestVmNames)
    if (-not $script:PbmAvailable) {
        Add-NkResult -Status BLOCK -Name 'TAGS-01 tag opt-out rule' -Detail ("fixtures cannot be created: vCenter storage policy service is unavailable: {0}" -f $script:PbmMessage)
        return
    }
    if ($fixtureNames.Count -eq 0) {
        Add-NkResult -Status BLOCK -Name 'TAGS-01 tag opt-out rule' -Detail 'no fixture VMs exist; run the Fixtures phase first'
        return
    }

    $manifest = Get-NkManifest
    $tagSources = @()
    if ($null -ne $manifest -and $null -ne $manifest.TagSources) {
        $tagSources = @($manifest.TagSources)
    }

    Update-NkInventoryInfo

    # Keep the fixture VMs fresh so the daemons do not spend time on backups
    # that other phases test; the tag rule is what this phase measures.
    Set-NkPendingSelection -Pending @() -All $fixtureNames | Out-Null

    $root = New-NkRuntimeRoot -Name 'tags-on'
    $result = Invoke-NkInventoryRun -Root $root -Label 'inventory-tag'
    Assert-NkTrue -Name 'TAGS-02 inventory collection completes with the tag rule enabled' -Condition $result.Collected -Detail (Get-NkLogTail -Root $root -Lines 8)
    if (-not $result.Collected) {
        return
    }

    $eligible = @(Get-NkEligibleMonitoringNames -Root $root)
    $reasons = Get-NkNonEligibleLogMap -LogText $result.Log

    if ($tagSources.Count -eq 0) {
        Add-NkResult -Status SKIP -Name 'TAGS-03 fixture tag sources are excluded' -Detail 'the lab has no tag assignment that can back a fixture (resource pool, datastore with free space, datastore cluster or VM folder)'
    }

    $sourceIndex = 0
    foreach ($source in @($tagSources)) {
        $sourceIndex++
        $name = [string]$source.VM
        $expected = [string]$source.Reason
        $reasonText = Get-NkNonEligibleReasonText -Map $reasons -VmName $name
        $logged = ($reasonText.Length -gt 0) -and (Test-NkContains -Text $reasonText -Needle $expected)
        Assert-NkTrue -Name (("TAGS-03.{0} {1} source excludes '{2}'" -f $sourceIndex, $source.Kind, $name)) -Condition $logged -Detail ("expected '{0}', got '{1}'" -f $expected, $reasonText)
        Assert-NkTrue -Name (("TAGS-04.{0} '{1}' is not eligible ({2} tag)" -f $sourceIndex, $name, $source.Kind)) -Condition ($eligible -notcontains $name) -Detail 'the VM is in eligible_vms.txt'
    }

    Assert-NkTrue -Name 'TAGS-05 an untagged fixture VM stays eligible' -Condition ($eligible -contains "$($script:FixturePrefix)-inc") -Detail ("eligible: " + ($eligible -join ', '))

    $noDiskReason = Get-NkNonEligibleReasonText -Map $reasons -VmName "$($script:FixturePrefix)-nodisk"
    Assert-NkTrue -Name 'TAGS-06 a VM without disks is excluded' -Condition ($noDiskReason -match 'no disks') -Detail $noDiskReason

    if ($fixtureNames -contains "$($script:FixturePrefix)-multi") {
        $multiReason = Get-NkNonEligibleReasonText -Map $reasons -VmName "$($script:FixturePrefix)-multi"
        Assert-NkTrue -Name 'TAGS-07 a VM whose disks span two datastore clusters is excluded' -Condition ($multiReason -match 'exactly one is required') -Detail $multiReason
    }
    else {
        Add-NkResult -Status SKIP -Name 'TAGS-07 a VM whose disks span two datastore clusters is excluded' -Detail 'the lab has only one datastore cluster'
    }

    if ($fixtureNames -contains "$($script:FixturePrefix)-name[01]") {
        $nameReason = Get-NkNonEligibleReasonText -Map $reasons -VmName "$($script:FixturePrefix)-name[01]"
        Assert-NkTrue -Name 'TAGS-08 a VM name with characters dsmc cannot use is excluded' -Condition ($nameReason -match 'characters not supported') -Detail $nameReason
    }
    else {
        Add-NkResult -Status SKIP -Name 'TAGS-08 a VM name with characters dsmc cannot use is excluded' -Detail 'the fixture could not be created'
    }

    if ($fixtureNames -contains "$($script:FixturePrefix)-size") {
        $sizeReason = Get-NkNonEligibleReasonText -Map $reasons -VmName "$($script:FixturePrefix)-size"
        $sizeRuleOk = ($sizeReason -match 'not a multiple of 1 MiB') -and ($sizeReason -match '1023\.5 MiB')
        Assert-NkTrue -Name 'TAGS-18 a disk whose size is not a multiple of 1 MiB is excluded' -Condition $sizeRuleOk -Detail $sizeReason
        Assert-NkTrue -Name 'TAGS-19 the size fixture is not eligible' -Condition ($eligible -notcontains "$($script:FixturePrefix)-size") -Detail 'the VM is in eligible_vms.txt'
    }
    else {
        Add-NkResult -Status SKIP -Name 'TAGS-18 a disk whose size is not a multiple of 1 MiB is excluded' -Detail 'the size fixture could not be created'
    }

    # Cross-check the harness' own six-source computation against the daemon
    # reason for every fixture VM in the live inventory.
    $mismatches = [System.Collections.Generic.List[string]]::new()
    foreach ($vm in @($script:VmInfo | Where-Object { $fixtureNames -contains $_.Name })) {
        $reasonText = Get-NkNonEligibleReasonText -Map $reasons -VmName $vm.Name
        foreach ($violation in @(Get-NkTagViolations -Vm $vm)) {
            if (-not (Test-NkContains -Text $reasonText -Needle $violation)) {
                [void]$mismatches.Add("$($vm.Name): missing '$violation'")
            }
        }
    }
    Assert-NkTrue -Name 'TAGS-09 the daemon logs every tag reason the six-source rule finds' -Condition ($mismatches.Count -eq 0) -Detail (($mismatches | Select-Object -First 3) -join ' | ')

    # Live entities: every VM whose record already carries the tag on one of
    # its six sources must be non-eligible, even without fixtures.
    $liveMismatches = [System.Collections.Generic.List[string]]::new()
    foreach ($vm in @($script:VmInfo)) {
        if ($fixtureNames -contains $vm.Name) {
            continue
        }
        $violations = @(Get-NkTagViolations -Vm $vm)
        if ($violations.Count -eq 0) {
            continue
        }
        if ($eligible -contains $vm.Name) {
            [void]$liveMismatches.Add("$($vm.Name) is eligible: $($violations -join '; ')")
            continue
        }
        $reasonText = Get-NkNonEligibleReasonText -Map $reasons -VmName $vm.Name
        foreach ($violation in $violations) {
            if (-not (Test-NkContains -Text $reasonText -Needle $violation)) {
                [void]$liveMismatches.Add("$($vm.Name): missing '$violation'")
            }
        }
    }

    if (@($script:VmInfo | Where-Object { $fixtureNames -notcontains $_.Name -and @(Get-NkTagViolations -Vm $_).Count -gt 0 }).Count -eq 0) {
        Add-NkResult -Status SKIP -Name 'TAGS-10 live tag assignments exclude the affected VMs' -Detail 'no non-fixture VM is affected by the rule tag in this lab'
    }
    else {
        Assert-NkTrue -Name 'TAGS-10 live tag assignments exclude the affected VMs' -Condition ($liveMismatches.Count -eq 0) -Detail (($liveMismatches | Select-Object -First 3) -join ' | ')
    }

    # Rule disabled: the same VMs must no longer be excluded by the tag.
    $rootOff = New-NkRuntimeRoot -Name 'tags-off' -Overrides @{ dont_backup_by_snapshot_tag_name = '' }
    $resultOff = Invoke-NkInventoryRun -Root $rootOff -Label 'inventory-notag'
    Assert-NkTrue -Name 'TAGS-11 inventory collection completes with the tag rule disabled' -Condition $resultOff.Collected -Detail (Get-NkLogTail -Root $rootOff -Lines 8)
    if (-not $resultOff.Collected) {
        return
    }

    $tagReasonPattern = "tag '" + [regex]::Escape($script:UseTagName) + "'"
    Assert-NkTrue -Name 'TAGS-12 no tag reason is logged when the rule is disabled' -Condition ($resultOff.Log -notmatch $tagReasonPattern) -Detail "found 'tag '$($script:UseTagName)' in the log"

    $eligibleOff = @(Get-NkEligibleMonitoringNames -Root $rootOff)
    $expectedEligibleAgain = @()
    foreach ($kind in @('ResourcePool', 'DatastoreCluster')) {
        foreach ($source in @($tagSources | Where-Object { [string]$_.Kind -eq $kind })) {
            $expectedEligibleAgain += [string]$source.VM
        }
    }

    if ($expectedEligibleAgain.Count -eq 0) {
        Add-NkResult -Status SKIP -Name 'TAGS-13 tag fixtures become eligible with the rule disabled' -Detail 'no resource pool or datastore cluster tag fixture exists'
    }
    else {
        $stillExcluded = @($expectedEligibleAgain | Where-Object { $eligibleOff -notcontains $_ })
        Assert-NkTrue -Name 'TAGS-13 tag fixtures become eligible with the rule disabled' -Condition ($stillExcluded.Count -eq 0) -Detail ("still not eligible: " + ($stillExcluded -join ', '))
    }

    Add-NkResult -Status SKIP -Name 'TAGS-14 VM tag opt-out' -Detail 'creating tags or tag assignments is not allowed in this lab'
    Add-NkResult -Status SKIP -Name 'TAGS-15 folder tag opt-out (direct folder only)' -Detail 'no tagged VM folder exists and assigning tags is not allowed'
    Add-NkResult -Status SKIP -Name 'TAGS-16 cluster tag opt-out' -Detail 'the lab has no ClusterComputeResource; creating one needs operator approval'
    Add-NkResult -Status SKIP -Name 'TAGS-17 tag data unavailable fails safe' -Detail 'breaking the vAPI tag query reliably needs a vCenter change'
}

# ---------------------------------------------------------------------------
# Phase: Backup
# ---------------------------------------------------------------------------

function Get-NkPodForDatastore {
    param(
        [AllowEmptyString()]
        [string]$DatastoreName
    )

    foreach ($datastore in @($script:Datastores)) {
        if ([string]$datastore.Name -cne $DatastoreName) {
            continue
        }
        if ($script:PodByDatastore.ContainsKey([string]$datastore.Id)) {
            return [string]$script:PodByDatastore[[string]$datastore.Id].Name
        }
    }

    return ''
}

function Get-NkExpectedManagementClass {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName
    )

    $vm = @($script:VmInfo | Where-Object { $_.Name -ceq $VmName } | Select-Object -First 1)
    if ($vm.Count -eq 0 -or @($vm[0].Disks).Count -eq 0) {
        return ''
    }

    $pod = [string]$vm[0].DatastoreClusters[0]
    if ([string]::IsNullOrWhiteSpace($pod)) {
        return ''
    }

    $key = $pod.ToLowerInvariant()
    if (-not $script:ManagementClassMap.ContainsKey($key)) {
        return ''
    }

    return [string]$script:ManagementClassMap[$key]
}

function Get-NkVmJobLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$VmName,

        [int]$Index = 0
    )

    $directory = Join-Path $Root 'log/vm'
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        return ''
    }

    $files = @(Get-ChildItem -LiteralPath $directory -Recurse -File -Filter ("*_" + $VmName + ".txt") -ErrorAction SilentlyContinue | Sort-Object -Property LastWriteTime -Descending)
    if ($files.Count -le $Index) {
        return ''
    }

    return (Read-NkTextShared -Path $files[$Index].FullName)
}

function Invoke-NkPhaseBackup {
    Write-NkBanner 'Phase: Backup'

    if (-not $script:PbmAvailable) {
        Add-NkResult -Status BLOCK -Name 'BAK-01 incremental backup' -Detail ("fixtures cannot be created: vCenter storage policy service is unavailable: {0}" -f $script:PbmMessage)
        return
    }

    $fixtureNames = @(Get-NkManifestVmNames)
    $target = "$($script:FixturePrefix)-inc"
    if ($fixtureNames -notcontains $target) {
        Add-NkResult -Status BLOCK -Name 'BAK-01 incremental backup' -Detail "fixture '$target' does not exist; run the Fixtures phase first"
        return
    }

    try {
        Set-NkPendingSelection -Pending @($target) -All $fixtureNames | Out-Null
    }
    catch {
        Add-NkResult -Status FAIL -Name 'BAK-01 fixture notes can be prepared' -Detail $_.Exception.Message
        return
    }

    $notesBefore = Get-NkLiveNotes -Name $target
    $taskIds = Get-NkTaskIds
    $root = New-NkRuntimeRoot -Name 'backup-incremental' -Overrides @{
        dsmc_use_preview                 = $false
        dont_backup_by_snapshot_tag_name = ''
        max_backup_threads               = 1
    }

    $run = Start-NkDaemon -Root $root
    $started = Wait-NkLogMatch -Root $root -Pattern ("Started Incremental backup for VM '" + [regex]::Escape($target) + "'") -Process $run.Process
    Assert-NkTrue -Name 'BAK-01 the daemon starts an incremental backup' -Condition $started -Detail (Get-NkLogTail -Root $root -Lines 8)

    $completed = $false
    if ($started) {
        $completed = Wait-NkLogMatch -Root $root -Pattern ("Backup completed successfully for VM '" + [regex]::Escape($target) + "'") -Process $run.Process
    }
    Assert-NkTrue -Name 'BAK-02 the backup completes successfully' -Condition $completed -Detail (Get-NkLogTail -Root $root -Lines 8)

    $pendingPath = Join-Path $root 'monitoring/pending_count.txt'
    $pendingZero = $false
    if ($completed) {
        $pendingZero = Wait-NkFileContent -Path $pendingPath -Content '0' -TimeoutSeconds 60 -Process $run.Process
    }
    Assert-NkTrue -Name 'BAK-03 pending_count.txt drops to 0 after the backup' -Condition $pendingZero -Detail ("pending_count.txt = '{0}'" -f (Read-NkTextShared -Path $pendingPath).Trim())

    $exitCode = Stop-NkDaemon -Run $run -Mode Stop
    Assert-NkEqual -Name 'BAK-04 the daemon still exits normally' -Expected 0 -Actual $exitCode

    $log = Read-NkLog -Root $root
    $startLines = @(Get-NkStartedBackupLine -Log $log -VmName $target)
    Assert-NkTrue -Name 'BAK-05 exactly one start line was logged for the VM' -Condition ($startLines.Count -eq 1) -Detail ("{0} start line(s)" -f $startLines.Count)

    $startLine = ''
    if ($startLines.Count -gt 0) {
        $startLine = [string]$startLines[0]
    }

    $modeIncremental = $startLine -match 'Started Incremental backup'
    Assert-NkTrue -Name 'BAK-06 the selection was Incremental' -Condition $modeIncremental -Detail $startLine

    $expectedClass = Get-NkExpectedManagementClass -VmName $target
    $classOk = (-not [string]::IsNullOrWhiteSpace($expectedClass)) -and (Test-NkContains -Text $startLine -Needle ('-vmmc=' + $expectedClass))
    Assert-NkTrue -Name 'BAK-07 the command uses the management class mapped to the datastore cluster' -Condition $classOk -Detail ("expected '-vmmc=$expectedClass'; " + $startLine)

    Assert-NkTrue -Name 'BAK-08 preview is off when dsmc_use_preview is false' -Condition ($startLine -notmatch '\s-preview\b') -Detail $startLine
    Assert-NkTrue -Name 'BAK-09 an incremental backup passes neither -mode IFFull nor -VMBACKUPUPDATEGUID' -Condition (($startLine -notmatch '-mode\s+IFFull') -and ($startLine -notmatch '-VMBACKUPUPDATEGUID')) -Detail $startLine

    $jobLog = Get-NkVmJobLog -Root $root -VmName $target
    $modeOutput = $jobLog -match 'Incremental Forever - Incremental'
    Assert-NkTrue -Name 'BAK-10 the dsmc output reports an incremental backup' -Condition $modeOutput -Detail (Get-NkLogTail -Root $root -Lines 3)

    $lastFull = Get-NkLastFullObject -Root $root
    $recordedFull = ($null -ne $lastFull) -and ($lastFull.PSObject.Properties.Name -contains $target)
    Assert-NkTrue -Name 'BAK-11 an incremental backup does not create a last_full.json entry' -Condition (-not $recordedFull) -Detail "last_full.json contains '$target'"

    $notesAfter = Get-NkLiveNotes -Name $target
    Assert-NkTrue -Name 'BAK-12 the daemon did not change the VM Notes' -Condition ($notesAfter -ceq $notesBefore) -Detail ("before '{0}', after '{1}'" -f $notesBefore, $notesAfter)

    $newTasks = @(Get-NkNewMutatingTasks -Before $taskIds)
    Assert-NkTrue -Name 'BAK-13 the backup started no mutating vCenter task' -Condition ($newTasks.Count -eq 0) -Detail (($newTasks | Select-Object -First 3) -join ', ')

    # Preview on: the same incremental selection must pass -preview.
    $rootPreview = New-NkRuntimeRoot -Name 'backup-preview' -Overrides @{
        dsmc_use_preview                 = $true
        dont_backup_by_snapshot_tag_name = ''
        max_backup_threads               = 1
    }

    $previewRun = Start-NkDaemon -Root $rootPreview
    $previewStarted = Wait-NkLogMatch -Root $rootPreview -Pattern ("Started Incremental backup for VM '" + [regex]::Escape($target) + "'") -Process $previewRun.Process
    Assert-NkTrue -Name 'BAK-14 a preview run starts the backup' -Condition $previewStarted -Detail (Get-NkLogTail -Root $rootPreview -Lines 8)

    $previewExit = Stop-NkDaemon -Run $previewRun -Mode Stop
    $previewLog = Read-NkLog -Root $rootPreview
    $previewLines = @(Get-NkStartedBackupLine -Log $previewLog -VmName $target)
    $previewLine = ''
    if ($previewLines.Count -gt 0) {
        $previewLine = [string]$previewLines[0]
    }

    Assert-NkTrue -Name 'BAK-15 preview is on when dsmc_use_preview is true' -Condition ($previewLine -match '\s-preview\b') -Detail $previewLine
    Assert-NkEqual -Name 'BAK-16 the preview run still exits normally' -Expected 0 -Actual $previewExit
}

# ---------------------------------------------------------------------------
# Phase: Full
# ---------------------------------------------------------------------------

function Get-NkFullWindowZone {
    # Narvik only runs a Full backup outside pending increments, on a weekend
    # or before 08:00 local time. The daemon is started with TZ set to a zone
    # in that window so the test does not depend on the host clock.
    $utcNow = [DateTime]::UtcNow
    foreach ($zone in @([TimeZoneInfo]::GetSystemTimeZones())) {
        try {
            $local = [TimeZoneInfo]::ConvertTimeFromUtc($utcNow, $zone)
        }
        catch {
            continue
        }

        $weekend = ($local.DayOfWeek -eq [System.DayOfWeek]::Saturday) -or ($local.DayOfWeek -eq [System.DayOfWeek]::Sunday)
        if ($weekend -or ($local.TimeOfDay -lt [TimeSpan]'08:00:00')) {
            return $zone
        }
    }

    return $null
}

function Invoke-NkPhaseFull {
    Write-NkBanner 'Phase: Full'

    if (-not $script:PbmAvailable) {
        Add-NkResult -Status BLOCK -Name 'FUL-01 full backup in the full window' -Detail ("fixtures cannot be created: vCenter storage policy service is unavailable: {0}" -f $script:PbmMessage)
        return
    }

    $fixtureNames = @(Get-NkManifestVmNames)
    $target = "$($script:FixturePrefix)-full"
    if ($fixtureNames -notcontains $target) {
        Add-NkResult -Status BLOCK -Name 'FUL-01 full backup in the full window' -Detail "fixture '$target' does not exist; run the Fixtures phase first"
        return
    }

    $zone = Get-NkFullWindowZone
    if ($null -eq $zone) {
        Add-NkResult -Status SKIP -Name 'FUL-01 full backup in the full window' -Detail 'no system time zone is currently inside the full window'
        return
    }

    $detailZone = ''
    $utcNow = [DateTime]::UtcNow
    try {
        $detailZone = [TimeZoneInfo]::ConvertTimeFromUtc($utcNow, $zone).ToString('yyyy-MM-dd HH:mm:ss')
    }
    catch {
        $detailZone = ''
    }
    Add-NkResult -Status PASS -Name 'FUL-00 a time zone inside the full window is available' -Detail ("{0} ({1})" -f $zone.Id, $detailZone)

    try {
        Set-NkPendingSelection -Pending @($target) -All $fixtureNames | Out-Null
    }
    catch {
        Add-NkResult -Status FAIL -Name 'FUL-01 fixture notes can be prepared' -Detail $_.Exception.Message
        return
    }

    $root = New-NkRuntimeRoot -Name 'full-window' -Overrides @{
        dsmc_use_preview                 = $false
        dont_backup_by_snapshot_tag_name = ''
        max_backup_threads               = 1
    }

    $run = Start-NkDaemon -Root $root -TimeZone $zone.Id
    $recorded = Wait-NkLogMatch -Root $root -Pattern ("Full backup recorded for VM '" + [regex]::Escape($target) + "'") -Process $run.Process
    $completed = Wait-NkLogMatch -Root $root -Pattern ("Backup completed successfully for VM '" + [regex]::Escape($target) + "'") -Process $run.Process -TimeoutSeconds 60
    if (-not $recorded -and -not $completed) {
        $onWindows = Test-NkIsWindows
        $exitCode = Stop-NkDaemon -Run $run -Mode Stop
        $log = Read-NkLog -Root $root
        if ($onWindows -and ($log -notmatch 'Started (?:Incremental|Full) backup')) {
            Add-NkResult -Status SKIP -Name 'FUL-01 full backup in the full window' -Detail 'the TZ override is not honored on this platform; run on Linux or wait for the real window'
        }
        else {
            Assert-NkTrue -Name 'FUL-01 full backup in the full window' -Condition $false -Detail (Get-NkLogTail -Root $root -Lines 8)
        }
        return
    }

    $exitCode = Stop-NkDaemon -Run $run -Mode Stop
    Assert-NkEqual -Name 'FUL-01 the daemon exits normally after the full backup' -Expected 0 -Actual $exitCode

    $log = Read-NkLog -Root $root
    $fullLines = @(Get-NkStartedBackupLine -Log $log -VmName $target | Where-Object { $_ -match 'Started Full backup' })
    Assert-NkTrue -Name 'FUL-02 exactly one Full backup was started for the VM' -Condition ($fullLines.Count -eq 1) -Detail ("{0} Full start line(s)" -f $fullLines.Count)

    $fullLine = ''
    if ($fullLines.Count -gt 0) {
        $fullLine = [string]$fullLines[0]
    }

    Assert-NkTrue -Name 'FUL-03 the Full command passes -mode IFFull' -Condition ($fullLine -match '-mode\s+IFFull') -Detail $fullLine
    Assert-NkTrue -Name 'FUL-04 a scheduled Full does not pass -VMBACKUPUPDATEGUID' -Condition ($fullLine -notmatch '-VMBACKUPUPDATEGUID') -Detail $fullLine
    Assert-NkTrue -Name 'FUL-05 the Full backup is recorded in the log' -Condition ($recorded -or ($log -match ("Full backup recorded for VM '" + [regex]::Escape($target) + "'"))) -Detail (Get-NkLogTail -Root $root -Lines 5)

    $jobLog = Get-NkVmJobLog -Root $root -VmName $target
    Assert-NkTrue -Name 'FUL-06 the dsmc output reports a Full backup' -Condition ($jobLog -match 'Incremental Forever - Full') -Detail 'the VM log does not contain "Incremental Forever - Full"'

    $lastFull = Get-NkLastFullObject -Root $root
    $lastFullValue = $null
    if ($null -ne $lastFull -and ($lastFull.PSObject.Properties.Name -contains $target)) {
        $lastFullValue = [string]$lastFull.$target
    }

    Assert-NkTrue -Name 'FUL-07 control/last_full.json records the Full backup' -Condition (-not [string]::IsNullOrWhiteSpace($lastFullValue)) -Detail "last_full.json has no entry for '$target'"

    $lastFullOk = $false
    if (-not [string]::IsNullOrWhiteSpace($lastFullValue)) {
        try {
            $parsed = [datetime]::Parse($lastFullValue, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
            $lastFullOk = ([math]::Abs(((Get-Date) - $parsed).TotalMinutes) -lt 15)
        }
        catch {
            $lastFullOk = $false
        }
    }
    Assert-NkTrue -Name 'FUL-08 the recorded Full timestamp is the current run' -Condition $lastFullOk -Detail $lastFullValue

    # A Full backup must not repeat while last_full.json is newer than 30 days,
    # and the same VM must fall back to an incremental selection.
    Set-NkPendingSelection -Pending @($target) -All $fixtureNames | Out-Null
    $secondRun = Start-NkDaemon -Root $root -TimeZone $zone.Id
    $incremental = Wait-NkLogMatch -Root $secondRun.Root -Pattern ("Started Incremental backup for VM '" + [regex]::Escape($target) + "'") -Process $secondRun.Process
    $secondExit = Stop-NkDaemon -Run $secondRun -Mode Stop

    $secondLog = Read-NkLog -Root $root
    $allFullLines = @(Get-NkStartedBackupLine -Log $secondLog -VmName $target | Where-Object { $_ -match 'Started Full backup' })
    Assert-NkTrue -Name 'FUL-09 a recent Full is not repeated' -Condition ($allFullLines.Count -eq 1) -Detail ("{0} Full start line(s) for '$target'" -f $allFullLines.Count)
    Assert-NkTrue -Name 'FUL-10 the VM falls back to an incremental selection' -Condition $incremental -Detail (Get-NkLogTail -Root $root -Lines 8)
    Assert-NkEqual -Name 'FUL-11 the second run exits normally' -Expected 0 -Actual $secondExit
}

# ---------------------------------------------------------------------------
# Phase: Retry
# ---------------------------------------------------------------------------

function Wait-NkStateCondition {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Condition,

        [int]$TimeoutSeconds = 60,

        $Process
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (& $Condition) {
            return $true
        }

        if ($null -ne $Process) {
            try {
                if ($Process.HasExited) {
                    return [bool](& $Condition)
                }
            }
            catch {
            }
        }

        Start-Sleep -Milliseconds 500
    }

    return [bool](& $Condition)
}

function Invoke-NkPhaseRetry {
    Write-NkBanner 'Phase: Retry'

    if (-not $script:PbmAvailable) {
        Add-NkResult -Status BLOCK -Name 'RET-01 duplicate GUID retry' -Detail ("fixtures cannot be created: vCenter storage policy service is unavailable: {0}" -f $script:PbmMessage)
        return
    }

    $fixtureNames = @(Get-NkManifestVmNames)
    $dupTarget = "$($script:FixturePrefix)-dup_dup"
    $errTarget = "$($script:FixturePrefix)-err_err"
    if (($fixtureNames -notcontains $dupTarget) -or ($fixtureNames -notcontains $errTarget)) {
        Add-NkResult -Status BLOCK -Name 'RET-01 duplicate GUID retry' -Detail "fixtures '$dupTarget' and '$errTarget' must exist; run the Fixtures phase first"
        return
    }

    try {
        Set-NkPendingSelection -Pending @($dupTarget) -All $fixtureNames | Out-Null
    }
    catch {
        Add-NkResult -Status FAIL -Name 'RET-01 fixture notes can be prepared' -Detail $_.Exception.Message
        return
    }

    $root = New-NkRuntimeRoot -Name 'retry-duplicate' -Overrides @{
        dsmc_use_preview                 = $false
        dont_backup_by_snapshot_tag_name = ''
        max_backup_threads               = 1
    }

    $run = Start-NkDaemon -Root $root
    $reported = Wait-NkLogMatch -Root $root -Pattern ("VM '" + [regex]::Escape($dupTarget) + "' reported ANS1715E") -Process $run.Process
    Assert-NkTrue -Name 'RET-01 the first attempt reports ANS1715E' -Condition $reported -Detail (Get-NkLogTail -Root $root -Lines 8)

    if ($reported) {
        $flagSet = Wait-NkStateCondition -Root $root -Condition { Test-NkStateHasDuplicateGuid -Root $root -VmName $dupTarget } -TimeoutSeconds 30 -Process $run.Process
        Assert-NkTrue -Name 'RET-02 the duplicate GUID flag is stored in control/state.json' -Condition $flagSet -Detail 'duplicate_guid does not contain the VM'

        $failedCount = Get-NkFailedAttemptCount -Root $root -VmName $dupTarget
        Assert-NkEqual -Name 'RET-03 the failed attempt is recorded' -Expected 1 -Actual $failedCount
    }

    # The first retry waits one minute of backoff, so this wait is deliberately
    # longer than the default.
    $retryTimeout = [math]::Max($script:TimeoutSeconds, 180)
    $succeeded = Wait-NkLogMatch -Root $root -Pattern ("Backup completed successfully for VM '" + [regex]::Escape($dupTarget) + "'") -TimeoutSeconds $retryTimeout -Process $run.Process
    Assert-NkTrue -Name 'RET-04 the retry succeeds' -Condition $succeeded -Detail (Get-NkLogTail -Root $root -Lines 8)

    $exitCode = Stop-NkDaemon -Run $run -Mode Stop
    Assert-NkEqual -Name 'RET-05 the daemon exits normally after the retry' -Expected 0 -Actual $exitCode

    $log = Read-NkLog -Root $root
    $startLines = @(Get-NkStartedBackupLine -Log $log -VmName $dupTarget)
    Assert-NkTrue -Name 'RET-06 the VM was attempted twice' -Condition ($startLines.Count -ge 2) -Detail ("{0} attempt(s)" -f $startLines.Count)

    $retryLine = ''
    if ($startLines.Count -ge 2) {
        $retryLine = [string]$startLines[1]
    }

    Assert-NkTrue -Name 'RET-07 the retry passes -VMBACKUPUPDATEGUID' -Condition ($retryLine -match '-VMBACKUPUPDATEGUID') -Detail $retryLine
    Assert-NkTrue -Name 'RET-08 the retry passes -mode IFFull' -Condition ($retryLine -match '-mode\s+IFFull') -Detail $retryLine

    if ($succeeded) {
        $flagCleared = Wait-NkStateCondition -Root $root -Condition { -not (Test-NkStateHasDuplicateGuid -Root $root -VmName $dupTarget) } -TimeoutSeconds 30
        Assert-NkTrue -Name 'RET-09 a successful retry clears the duplicate GUID flag' -Condition $flagCleared -Detail 'duplicate_guid still contains the VM'

        $failedAfter = Get-NkFailedAttemptCount -Root $root -VmName $dupTarget
        Assert-NkEqual -Name 'RET-10 a successful retry clears the failed attempt counter' -Expected 0 -Actual $failedAfter
    }

    # A plain failure is recorded with backoff and no duplicate GUID flag.
    try {
        Set-NkPendingSelection -Pending @($errTarget) -All $fixtureNames | Out-Null
    }
    catch {
        Add-NkResult -Status FAIL -Name 'RET-11 fixture notes can be prepared for the failure test' -Detail $_.Exception.Message
        return
    }

    $errRoot = New-NkRuntimeRoot -Name 'retry-failure' -Overrides @{
        dsmc_use_preview                 = $false
        dont_backup_by_snapshot_tag_name = ''
        max_backup_threads               = 1
    }

    $errRun = Start-NkDaemon -Root $errRoot
    $errFailed = Wait-NkLogMatch -Root $errRoot -Pattern ("Backup failed for VM '" + [regex]::Escape($errTarget) + "'") -Process $errRun.Process
    Assert-NkTrue -Name 'RET-11 a plain dsmc failure is logged' -Condition $errFailed -Detail (Get-NkLogTail -Root $errRoot -Lines 8)

    if ($errFailed) {
        $errCount = Get-NkFailedAttemptCount -Root $errRoot -VmName $errTarget
        Assert-NkEqual -Name 'RET-12 the plain failure is recorded once' -Expected 1 -Actual $errCount
        $errFlag = Test-NkStateHasDuplicateGuid -Root $errRoot -VmName $errTarget
        Assert-NkTrue -Name 'RET-13 a plain failure does not set the duplicate GUID flag' -Condition (-not $errFlag) -Detail 'duplicate_guid contains the VM'

        Start-Sleep -Seconds 11
        $errStartLines = @(Get-NkStartedBackupLine -Log (Read-NkLog -Root $errRoot) -VmName $errTarget)
        if ($errStartLines.Count -eq 1) {
            Add-NkResult -Status PASS -Name 'RET-14 the failed VM is not retried before the backoff expires'
        }
        else {
            Add-NkResult -Status FAIL -Name 'RET-14 the failed VM is not retried before the backoff expires' -Detail ("{0} attempt(s) within 11 seconds" -f $errStartLines.Count)
        }
    }

    $errExit = Stop-NkDaemon -Run $errRun -Mode Stop
    Assert-NkEqual -Name 'RET-15 the daemon exits normally after a failed backup' -Expected 0 -Actual $errExit

    # One backup per host: a slow backup on the only host must hold the second
    # pending VM back. dsmc_fake's unmodified 45 second timing makes the first
    # backup long enough to observe the scheduling rule.
    $hostRoot = New-NkRuntimeRoot -Name 'host-concurrency' -Overrides @{
        dsmc_use_preview                 = $false
        dont_backup_by_snapshot_tag_name = ''
        max_backup_threads               = 2
    }

    try {
        Set-NkPendingSelection -Pending @($dupTarget, $errTarget) -All $fixtureNames | Out-Null
    }
    catch {
        Add-NkResult -Status FAIL -Name 'HOST-01 one backup per host' -Detail $_.Exception.Message
        return
    }

    $hostRun = Start-NkDaemon -Root $hostRoot -Environment @{ DSMC_FAKE_PAUSE_SCALE = '1' }
    $firstStarted = Wait-NkLogMatch -Root $hostRoot -Pattern 'Started (?:Incremental|Full) backup for VM' -Process $hostRun.Process
    Assert-NkTrue -Name 'HOST-01 the first backup starts' -Condition $firstStarted -Detail (Get-NkLogTail -Root $hostRoot -Lines 8)

    if ($firstStarted) {
        Start-Sleep -Seconds 4
        $hostLog = Read-NkLog -Root $hostRoot
        $hostStartLines = @([regex]::Matches($hostLog, "Started (?:Incremental|Full) backup for VM '"))
        Assert-NkTrue -Name 'HOST-02 only one backup runs at a time on the same host' -Condition ($hostStartLines.Count -eq 1) -Detail ("{0} backup(s) started while the first was active" -f $hostStartLines.Count)
    }

    $hostStop = Stop-NkDaemon -Run $hostRun -Mode Abort -TimeoutSeconds 120
    Assert-NkEqual -Name 'HOST-03 abort.txt stops the daemon while a backup is running' -Expected 0 -Actual $hostStop
}

# ---------------------------------------------------------------------------
# Phase: Teardown
# ---------------------------------------------------------------------------

function Test-NkPathInside {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Child,

        [Parameter(Mandatory = $true)]
        [string]$Parent
    )

    $childPath = [System.IO.Path]::GetFullPath($Child).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $parentPath = [System.IO.Path]::GetFullPath($Parent).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)

    if ($childPath -eq $parentPath) {
        return $true
    }

    return $childPath.StartsWith($parentPath + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
}

function Remove-NkFixtureVm {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$Errors,

        [ref]$Deleted
    )

    if ($Name -notlike 'nk-*') {
        [void]$Errors.Add("refusing to delete non-nk- VM '$Name'")
        return
    }

    $vm = Get-NkLiveVm -Name $Name
    if ($null -eq $vm) {
        return
    }

    $powerState = ''
    try { $powerState = [string]$vm.PowerState } catch { $powerState = '' }
    if ($powerState -ne 'PoweredOff') {
        [void]$Errors.Add("VM '$Name' is '$powerState'; refusing to delete a VM that is not powered off")
        return
    }

    try {
        Remove-VM -VM $vm -DeletePermanently -Confirm:$false -ErrorAction Stop | Out-Null
        $Deleted.Value = [int]$Deleted.Value + 1
    }
    catch {
        [void]$Errors.Add("VM '$Name': $($_.Exception.Message)")
    }
}

function Invoke-NkPhaseTeardown {
    Write-NkBanner 'Phase: Teardown'

    Stop-NkAllActiveRuns
    Start-Sleep -Seconds 1

    $manifest = Get-NkManifest
    $vmNames = @()
    $folderIds = @()
    if ($null -ne $manifest) {
        if ($null -ne $manifest.VMs) { $vmNames = @($manifest.VMs) }
        if ($null -ne $manifest.Folders) { $folderIds = @($manifest.Folders) }
    }

    $errors = [System.Collections.Generic.List[string]]::new()
    $deletedVms = 0

    foreach ($name in $vmNames) {
        $clean = [string]$name
        if ([string]::IsNullOrWhiteSpace($clean)) {
            continue
        }
        Remove-NkFixtureVm -Name $clean -Errors $errors -Deleted ([ref]$deletedVms)
    }

    # Sweep fixtures that an interrupted run created before it could record
    # them in the manifest (for example when creation succeeds but saving the
    # manifest fails). Only objects carrying the nk- prefix are ever deleted.
    $sweepVmNames = @()
    try {
        $sweepVmNames = @(Get-VM -ErrorAction Stop | Where-Object { $_.Name -like "$($script:FixturePrefix)-*" } | ForEach-Object { [string]$_.Name })
    }
    catch {
        [void]$errors.Add("could not list VMs for the cleanup sweep: $($_.Exception.Message)")
    }
    foreach ($name in $sweepVmNames) {
        if ($vmNames -contains $name) {
            continue
        }
        Remove-NkFixtureVm -Name $name -Errors $errors -Deleted ([ref]$deletedVms)
    }

    # Include any leftover nk- folder, even one the manifest does not know
    # about, so an interrupted run cannot leave fixtures behind.
    $knownFolderIds = [System.Collections.Generic.List[string]]::new()
    foreach ($id in @($folderIds)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$id)) {
            [void]$knownFolderIds.Add([string]$id)
        }
    }
    try {
        foreach ($folder in @(Get-Folder -ErrorAction Stop | Where-Object { $_.Name -like "$($script:FixturePrefix)-*" })) {
            $folderId = [string]$folder.Id
            if (-not $knownFolderIds.Contains($folderId)) {
                [void]$knownFolderIds.Add($folderId)
            }
        }
    }
    catch {
        [void]$errors.Add("could not list folders for the cleanup sweep: $($_.Exception.Message)")
    }
    $folderIds = @($knownFolderIds)

    $deletedFolders = 0
    if ($folderIds.Count -gt 0) {
        $folderObjects = [System.Collections.Generic.List[object]]::new()
        foreach ($id in $folderIds) {
            $folderRef = [string]$id
            if ($folderRef -notlike 'Folder-*') {
                $folderRef = "Folder-$folderRef"
            }
            try {
                $folderObject = Get-Folder -Id $folderRef -ErrorAction Stop | Select-Object -First 1
            }
            catch {
                $folderObject = $null
            }
            if ($null -ne $folderObject) {
                [void]$folderObjects.Add($folderObject)
            }
        }

        for ($pass = 0; $pass -lt 5; $pass++) {
            $stillPresent = [System.Collections.Generic.List[object]]::new()
            $progress = $false
            foreach ($folderObject in @($folderObjects)) {
                $live = $null
                try {
                    $live = Get-Folder -Id ("Folder-{0}" -f $folderObject.ExtensionData.MoRef.Value) -ErrorAction Stop | Select-Object -First 1
                }
                catch {
                    $live = $null
                }
                if ($null -eq $live) {
                    continue
                }

                $liveName = [string]$live.Name
                if ($liveName -notlike 'nk-*') {
                    [void]$errors.Add("refusing to delete non-nk- folder '$liveName'")
                    continue
                }

                try {
                    Remove-Folder -Folder $live -Confirm:$false -ErrorAction Stop | Out-Null
                    $deletedFolders++
                    $progress = $true
                }
                catch {
                    [void]$stillPresent.Add($folderObject)
                }
            }

            $folderObjects = $stillPresent
            if (-not $progress -or $folderObjects.Count -eq 0) {
                break
            }
        }

        foreach ($folderObject in @($folderObjects)) {
            $live = $null
            try {
                $live = Get-Folder -Id ("Folder-{0}" -f $folderObject.ExtensionData.MoRef.Value) -ErrorAction Stop | Select-Object -First 1
            }
            catch {
                $live = $null
            }
            if ($null -ne $live) {
                [void]$errors.Add("folder '$($live.Name)' could not be deleted")
            }
        }
    }

    if ($errors.Count -eq 0) {
        Add-NkResult -Status PASS -Name 'TD-01 the nk- fixture VMs and folders are deleted' -Detail ("{0} VM(s), {1} folder(s)" -f $deletedVms, $deletedFolders)
    }
    else {
        Add-NkResult -Status FAIL -Name 'TD-01 the nk- fixture VMs and folders are deleted' -Detail (($errors | Select-Object -First 3) -join ' | ')
    }

    if ($script:KeepRequested) {
        Add-NkResult -Status SKIP -Name 'TD-02 the runtime roots are removed' -Detail "-Keep was requested"
        Add-NkResult -Status SKIP -Name 'TD-03 the fixture manifest is removed' -Detail "-Keep was requested"
        return
    }

    if (Test-Path -LiteralPath $script:ManifestPath -PathType Leaf) {
        try {
            Remove-Item -LiteralPath $script:ManifestPath -Force -ErrorAction Stop | Out-Null
            Add-NkResult -Status PASS -Name 'TD-03 the fixture manifest is removed'
        }
        catch {
            Add-NkResult -Status FAIL -Name 'TD-03 the fixture manifest is removed' -Detail $_.Exception.Message
        }
    }

    if (Test-NkPathInside -Child $script:RunRootBase -Parent $script:RepoRoot) {
        Add-NkResult -Status FAIL -Name 'TD-02 the runtime roots are removed' -Detail "refusing to delete '$($script:RunRootBase)' because it is inside the repository"
        return
    }

    $removedRoots = 0
    if (Test-Path -LiteralPath $script:RunRootBase -PathType Container) {
        foreach ($item in @(Get-ChildItem -LiteralPath $script:RunRootBase -Force -ErrorAction SilentlyContinue)) {
            try {
                Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
                $removedRoots++
            }
            catch {
                [void]$errors.Add("$($item.FullName): $($_.Exception.Message)")
            }
        }
    }

    if ($errors.Count -eq 0) {
        Add-NkResult -Status PASS -Name 'TD-02 the runtime roots are removed' -Detail ("{0} item(s) under '{1}'" -f $removedRoots, $script:RunRootBase)
    }
    else {
        Add-NkResult -Status FAIL -Name 'TD-02 the runtime roots are removed' -Detail (($errors | Select-Object -First 3) -join ' | ')
    }

    # Leftover nk- objects outside the manifest would belong to another run.
    Update-NkInventoryInfo
    $leftoverVms = @($script:VmInfo | Where-Object { $_.Name -like 'nk-*' } | ForEach-Object { $_.Name })
    if ($leftoverVms.Count -eq 0) {
        Add-NkResult -Status PASS -Name 'TD-04 no nk- VM is left in the lab'
    }
    else {
        Add-NkResult -Status FAIL -Name 'TD-04 no nk- VM is left in the lab' -Detail ($leftoverVms -join ', ')
    }
}

# ---------------------------------------------------------------------------
# Phase selection and reporting
# ---------------------------------------------------------------------------

function Resolve-NkPhases {
    param(
        [string[]]$Requested
    )

    $unknown = [System.Collections.Generic.List[string]]::new()
    $wanted = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in @($Requested)) {
        foreach ($part in @(([string]$entry) -split ',')) {
            $clean = $part.Trim()
            if ([string]::IsNullOrWhiteSpace($clean)) {
                continue
            }

            $nameMatches = @($script:PhaseOrder | Where-Object { $_ -ieq $clean })
            if ($clean -ieq 'All') {
                foreach ($name in @($script:PhaseOrder)) {
                    if (-not $wanted.Contains($name)) {
                        [void]$wanted.Add($name)
                    }
                }
                continue
            }

            if ($nameMatches.Count -eq 0) {
                [void]$unknown.Add($clean)
                continue
            }

            if (-not $wanted.Contains($nameMatches[0])) {
                [void]$wanted.Add($nameMatches[0])
            }
        }
    }

    $ordered = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @($script:PhaseOrder)) {
        if ($wanted.Contains($name)) {
            [void]$ordered.Add($name)
        }
    }

    return [pscustomobject]@{
        Names   = @($ordered)
        Unknown = @($unknown)
    }
}

function Write-NkPhaseList {
    Write-NkBanner 'Narvik end-to-end phases'

    $descriptions = @{
        Preconditions = 'Parser, unit tests, dsmc stand-in, read-only source audit, vCenter connection, guard rails, storage policy'
        Inventory     = 'Read-only inventory, tag rule, eligibility consistency, read-only proof'
        Control       = 'stop.txt, abort.txt, second instance, configuration reload failure'
        Config        = 'Configuration validation errors'
        Fixtures      = 'Create the nk- test VMs and folders (needs the storage policy service)'
        Tags          = 'Tag opt-out rule on the fixtures and the live lab entities'
        Backup        = 'Incremental backup, dsmc command line, preview on and off'
        Full          = 'Full backup inside the full window, last_full.json'
        Retry         = 'ANS1715E retry, failure backoff, one backup per host'
        Teardown      = 'Delete only nk- test objects and the runtime roots'
    }

    foreach ($name in @($script:PhaseOrder)) {
        Write-Host ("  {0,-14} {1}" -f $name, $descriptions[$name])
    }

    Write-Host ''
    Write-Host ("Repository:     {0}" -f $script:RepoRoot)
    Write-Host ("Runtime roots:  {0}" -f $script:RunRootBase)
    Write-Host ("Password file:  {0}" -f $script:PasswordFile)
    Write-Host ("dsmc stand-in:  {0}" -f $script:DsmcPath)
}

function Write-NkSummary {
    Write-NkBanner 'Summary'

    Write-Host ("Passed:  {0}" -f $script:Passed) -ForegroundColor Green
    Write-Host ("Failed:  {0}" -f $script:Failed) -ForegroundColor Red
    Write-Host ("Blocked: {0}" -f $script:Blocked) -ForegroundColor Magenta
    Write-Host ("Skipped: {0}" -f $script:Skipped) -ForegroundColor Yellow

    if ($script:FailureMessages.Count -gt 0) {
        Write-Host ''
        Write-Host 'Failures:' -ForegroundColor Red
        foreach ($message in @($script:FailureMessages)) {
            Write-Host ("  - {0}" -f $message) -ForegroundColor Red
        }
    }

    if ($script:BlockedMessages.Count -gt 0) {
        Write-Host ''
        Write-Host 'Blocked (needs a change on the lab vCenter or an operator decision):' -ForegroundColor Magenta
        foreach ($message in @($script:BlockedMessages)) {
            Write-Host ("  - {0}" -f $message) -ForegroundColor Magenta
        }
    }
}

# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------

$resolved = Resolve-NkPhases -Requested $Phase

if ($List) {
    Write-NkPhaseList
    exit 0
}

if ($resolved.Unknown.Count -gt 0) {
    Write-Host ("Unknown phase(s): {0}" -f ($resolved.Unknown -join ', ')) -ForegroundColor Red
    Write-Host ("Valid phases: {0}, All" -f ($script:PhaseOrder -join ', ')) -ForegroundColor Yellow
    exit 1
}

if ($resolved.Names.Count -eq 0) {
    Write-Host 'No phase selected.' -ForegroundColor Red
    exit 1
}

$selectedPhases = @($resolved.Names)
$exitCode = 0
$initFailed = $false

Write-NkBanner 'Narvik end-to-end tests'
Write-Host ("Phases: {0}" -f ($selectedPhases -join ', '))
Write-Host ("Repository: {0}" -f $script:RepoRoot)
Write-Host ("Runtime roots: {0}" -f $script:RunRootBase)
Write-Host ("vCenter: {0}:{1} as {2}" -f $VcenterServer, $VcenterPort, $VcenterUser)

try {
    Import-NkPureHelpers

    if (-not (Test-NkPathInside -Child $script:RunRootBase -Parent $script:RepoRoot)) {
        New-Item -ItemType Directory -Force -Path $script:RunRootBase -ErrorAction Stop | Out-Null
    }
    else {
        throw "The runtime root '$($script:RunRootBase)' is inside the repository '$($script:RepoRoot)'; use -RunRoot to point outside the repository."
    }

    $needsVCenter = @($selectedPhases | Where-Object { $_ -ne 'Config' })
    if ($needsVCenter.Count -gt 0) {
        try {
            Initialize-NkHarness
        }
        catch {
            Add-NkResult -Status FAIL -Name 'HARNESS-01 vCenter initialization' -Detail $_.Exception.Message
            $initFailed = $true
        }
    }

    foreach ($name in $selectedPhases) {
        if ($initFailed -and $name -ne 'Config') {
            Add-NkResult -Status FAIL -Name ("{0} phase" -f $name) -Detail 'skipped because harness initialization failed'
            continue
        }

        $functionName = 'Invoke-NkPhase' + $name
        try {
            & $functionName
        }
        catch {
            Add-NkResult -Status FAIL -Name ("{0} phase completed without an unhandled error" -f $name) -Detail $_.Exception.Message
        }
    }
}
catch {
    Add-NkResult -Status FAIL -Name 'HARNESS-02 harness setup' -Detail $_.Exception.Message
}
finally {
    Stop-NkAllActiveRuns
    Disconnect-NkVCenter
}

Write-NkSummary

if ($script:Failed -gt 0) {
    $exitCode = 1
}
elseif ($script:Blocked -gt 0) {
    $exitCode = 2
}

exit $exitCode




