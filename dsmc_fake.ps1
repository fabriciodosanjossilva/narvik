#!/usr/bin/env pwsh
#
# dsmc_fake.ps1 - fake IBM Storage Protect client (dsmc) used to test Narvik.
#
# It emulates the exact dsmc command Narvik runs:
#
#   dsmc backup vm <VMNAME> -vmmc=<class> [-VMBACKUPUPDATEGUID] [-mode IFFull] [-preview]
#
# Behavior:
#   - The VM name is the argument that follows "backup vm" (surrounding
#     double quotes are stripped).
#   - If the VM name contains "_err", the backup always fails, whatever the
#     mode: the template is printed only down to its _ERR_ marker, where a
#     plain error line ($PlainErrorAnsCode, a code different from
#     $ErrorAnsCode) is printed and the script stops with exit code 8. The
#     failure is certain and carries no duplicate GUID code, so Narvik
#     records it as an ordinary failed attempt; "_err" takes precedence over
#     "_dup" when a name contains both.
#   - If the VM name contains "_crit", the backup always fails with a critical
#     error code ($CriticalErrorAnsCode, one of the codes Narvik emails as a
#     critical dsmc error) printed at the _ERR_ marker, so the critical error
#     email and its 6-hour suppression can be tested end to end. "_err" takes
#     precedence over "_crit", and "_crit" takes precedence over "_dup".
#   - If the VM name contains "_dup" and the backup is not a Full one, the
#     backup fails: the template is printed only down to its _ERR_ marker,
#     where an ANS1715E error line is printed and the script stops with exit
#     code 8. ANS1715E is the error Narvik uses to flag a duplicate VM GUID,
#     so the next attempt for that VM runs with -VMBACKUPUPDATEGUID and
#     -mode IFFull; that attempt is a Full backup, so it succeeds and the
#     whole duplicate GUID flow can be tested end to end.
#   - If the VM name contains "_dup" and the backup is a Full one, the backup
#     always succeeds: the whole template is printed, _RES_ becomes 1 and the
#     exit code is 0.
#   - Any other VM name is treated normally: the whole template is printed,
#     _RES_ becomes 1 and the exit code is 0, but every attempt (preview
#     included) has a $RandomFailurePercent percent chance of failing
#     silently: no output, no error code, the script simply exits with the
#     backup-failure exit code. Narvik records a plain failed attempt and
#     retries the VM later without the duplicate GUID flag.
#   - "-mode IFFull", "-mode=IFFull" or "-VMBACKUPUPDATEGUID" select a Full
#     backup (_MODE_ = Full); anything else is Incremental.
#   - The output template (from out.txt) is embedded below and printed line
#     by line, with live substitutions:
#       _TS_        -> current timestamp, DD/MM/YYYY HH:MM:SS
#       _VMNAME_    -> requested VM name
#       _MODE_      -> Incremental or Full
#       _RES_       -> 1 on success, 0 on error
#       _PAUSE_N_   -> line removed; an N-second pause runs instead (out.txt
#                      currently pauses 5, 5, 3, 30 and 2 seconds, so a
#                      successful backup takes about 45 seconds)
#       _ERR_       -> line removed; on a duplicate-name failing backup the
#                      ANS1715E error line is printed here and the script stops
#   - -vmmc and -preview are accepted and ignored.
#   - When DSMC_FAKE_RUNTIME_ROOT is set, the fake also updates the VM Notes
#     in vCenter, the way real dsmc does. On success it removes every
#     <Backup ...> tag and appends exactly one tag in the fixed format:
#       <Backup incremental successful in dd/MM/yyyy HH:mm:ss>
#       <Backup full successful in dd/MM/yyyy HH:mm:ss>
#     On failure it removes every <Backup ...> tag. Only tags named exactly
#     'Backup' are removed; other angle-bracket tags such as <Owner> or
#     <Note>...</Note> and all remaining text are preserved. The update needs
#     PowerCLI and a reachable vCenter, and only runs when the environment
#     variable points at a runtime root containing config.json.
#
# Environment variables (automated tests only; all default to the behaviour
# documented above):
#   DSMC_FAKE_PAUSE_SCALE             Integer or decimal divisor for every
#                                     _PAUSE_N_ pause. 0.01 finishes a backup in
#                                     about half a second; unset or 1 keeps the
#                                     real timing.
#   DSMC_FAKE_RANDOM_FAILURE_PERCENT  Replacement for the 5 percent random
#                                     failure rate. Set it to 0 for
#                                     deterministic runs.
#   DSMC_FAKE_RUNTIME_ROOT            Runtime root containing config.json and
#                                     the vCenter password file. When set, the
#                                     fake updates the VM Notes as described
#                                     above. Unset leaves the Notes untouched.
#
# Exit codes (same convention as dsmc):
#   0  backup succeeded
#   8  backup failed
#   12 usage / command line error
#
# Examples:
#   powershell -NoProfile -ExecutionPolicy Bypass -File dsmc_fake.ps1 backup vm SRV-APP01 -vmmc=GOLD -preview
#   powershell -NoProfile -ExecutionPolicy Bypass -File dsmc_fake.ps1 backup vm SRV-DB01_err -vmmc=GOLD
#   powershell -NoProfile -ExecutionPolicy Bypass -File dsmc_fake.ps1 backup vm SRV-DB01_dup -vmmc=GOLD
#   powershell -NoProfile -ExecutionPolicy Bypass -File dsmc_fake.ps1 backup vm SRV-DB01_dup -vmmc=GOLD -VMBACKUPUPDATEGUID -mode IFFull
#   powershell -NoProfile -ExecutionPolicy Bypass -File dsmc_fake.ps1 backup vm SRV-DB01_crit -vmmc=GOLD
#
# Notes:
#   - Compatible with Windows PowerShell 5.1 (no PowerShell 7 syntax).
#   - Narvik starts dsmc with Start-Process, which cannot run a .ps1 file
#     directly on Windows; on Windows, point dsmc_path at a wrapper (for
#     example a .cmd file) that invokes this script through powershell.exe.
#   - On Linux the shebang and the executable bit let Start-Process run this
#     file directly through pwsh; this is what the local test environment uses.

$ErrorActionPreference = 'Stop'

# Error reported when the VM name contains "_dup" and the backup is not a
# Full one.
$ErrorAnsCode = 'ANS1715E'

# Error reported when the VM name contains "_err": a plain, certain failure
# that must never look like the duplicate GUID case, so its code differs from
# $ErrorAnsCode.
$PlainErrorAnsCode = 'ANS1512E'

# Error reported when the VM name contains "_crit": a critical failure Narvik
# reports by email (one of its critical dsmc error codes).
$CriticalErrorAnsCode = 'ANS1030E'

# Exit code for a failed backup (dsmc convention); shared by the duplicate
# GUID error, the "_err" forced failure and the random silent failure.
$FailureExitCode = 8
$UsageExitCode = 12

# Chance, in percent, that a backup of a VM whose name contains neither
# "_err" nor "_dup" fails silently (no output, no error code, just exits).
# DSMC_FAKE_RANDOM_FAILURE_PERCENT overrides it so automated tests can remove
# the randomness; the default keeps the documented behaviour.
$RandomFailurePercent = 5
if (-not [string]::IsNullOrWhiteSpace($env:DSMC_FAKE_RANDOM_FAILURE_PERCENT)) {
    try { $RandomFailurePercent = [int]$env:DSMC_FAKE_RANDOM_FAILURE_PERCENT } catch { $RandomFailurePercent = 5 }
}
if ($RandomFailurePercent -lt 0) { $RandomFailurePercent = 0 }
if ($RandomFailurePercent -gt 100) { $RandomFailurePercent = 100 }

# Every _PAUSE_<seconds>_ line pauses for that many seconds, which makes a
# successful backup take about 47 seconds. DSMC_FAKE_PAUSE_SCALE divides those
# pauses so automated tests can run quickly; 1 keeps the documented timing.
$PauseScale = 1.0
if (-not [string]::IsNullOrWhiteSpace($env:DSMC_FAKE_PAUSE_SCALE)) {
    try { $PauseScale = [double]::Parse($env:DSMC_FAKE_PAUSE_SCALE, [System.Globalization.CultureInfo]::InvariantCulture) } catch { $PauseScale = 1.0 }
}
if ($PauseScale -le 0) { $PauseScale = 1.0 }

# ---------------------------------------------------------------------------
# VM Notes support (only when DSMC_FAKE_RUNTIME_ROOT is set).
# ---------------------------------------------------------------------------

function Resolve-NkFakePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$BasePath
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}

function Remove-NkFakeBackupTags {
    param(
        [AllowEmptyString()]
        [string]$Notes
    )

    return [regex]::Replace($Notes, '(?is)<Backup(?:\s[^>]*)?>', '')
}

function New-NkFakeBackupTag {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Full,

        [Parameter(Mandatory = $true)]
        [datetime]$Timestamp
    )

    $mode = 'incremental'
    if ($Full) {
        $mode = 'full'
    }

    $stamp = $Timestamp.ToString('dd/MM/yyyy HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
    return '<Backup ' + $mode + ' successful in ' + $stamp + '>'
}

function Update-NkFakeVmNotes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName,

        [Parameter(Mandatory = $true)]
        [bool]$Success,

        [Parameter(Mandatory = $true)]
        [bool]$Full
    )

    $runtimeRoot = [string]$env:DSMC_FAKE_RUNTIME_ROOT
    if ([string]::IsNullOrWhiteSpace($runtimeRoot)) {
        return
    }

    $connection = $null

    try {
        if (-not [System.IO.Path]::IsPathRooted($runtimeRoot)) {
            $runtimeRoot = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $runtimeRoot))
        }

        $configPath = Join-Path $runtimeRoot 'config.json'
        if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
            throw [System.Exception]::new("Configuration file not found: '$configPath'.")
        }

        $rawConfig = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop
        $config = $rawConfig | ConvertFrom-Json -ErrorAction Stop

        $passwordFile = Resolve-NkFakePath -Path ([string]$config.vcenter_password_file) -BasePath $runtimeRoot
        if (-not (Test-Path -LiteralPath $passwordFile -PathType Leaf)) {
            throw [System.Exception]::new("vCenter password file not found: '$passwordFile'.")
        }

        $password = (Get-Content -LiteralPath $passwordFile -Raw -ErrorAction Stop).TrimEnd([char]13, [char]10)
        if ([string]::IsNullOrEmpty($password)) {
            throw [System.Exception]::new("vCenter password file '$passwordFile' is empty.")
        }

        $secure = ConvertTo-SecureString -String $password -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential -ArgumentList ([string]$config.vcenter_user), $secure

        Import-Module 'VMware.VimAutomation.Core' -ErrorAction Stop

        $certificateAction = 'Fail'
        if ($null -ne $config.vcenter_ignore_certificate -and [bool]$config.vcenter_ignore_certificate) {
            $certificateAction = 'Ignore'
        }
        try {
            Set-PowerCLIConfiguration -Scope Session -InvalidCertificateAction $certificateAction -Confirm:$false -ErrorAction Stop | Out-Null
        }
        catch {
            Set-PowerCLIConfiguration -InvalidCertificateAction $certificateAction -Confirm:$false -ErrorAction Stop | Out-Null
        }

        $port = 443
        if ($null -ne $config.vcenter_port) {
            $port = [int]$config.vcenter_port
        }

        $connection = Connect-VIServer -Server ([string]$config.vcenter_server) -Port $port -Credential $credential -ErrorAction Stop -WarningAction SilentlyContinue

        $foundVms = @(Get-VM -Name $VmName -ErrorAction Stop)
        if ($foundVms.Count -gt 1) {
            $exactVms = @($foundVms | Where-Object { $_.Name -ceq $VmName })
            if ($exactVms.Count -eq 1) {
                $foundVms = $exactVms
            }
        }
        if ($foundVms.Count -ne 1) {
            throw [System.Exception]::new("Expected exactly one VM named '$VmName', found $($foundVms.Count).")
        }

        $vm = $foundVms[0]
        $notes = ''
        if ($null -ne $vm.Notes) {
            $notes = [string]$vm.Notes
        }
        elseif ($null -ne $vm.ExtensionData -and $null -ne $vm.ExtensionData.Config -and $null -ne $vm.ExtensionData.Config.Annotation) {
            $notes = [string]$vm.ExtensionData.Config.Annotation
        }

        $cleanNotes = Remove-NkFakeBackupTags -Notes $notes
        if ($Success) {
            $tag = New-NkFakeBackupTag -Full $Full -Timestamp (Get-Date)
            if ([string]::IsNullOrWhiteSpace($cleanNotes)) {
                $newNotes = $tag
            }
            elseif ($cleanNotes -match '(\r?\n)$') {
                $newNotes = $cleanNotes + $tag
            }
            else {
                $newNotes = $cleanNotes + "`r`n" + $tag
            }
        }
        else {
            $newNotes = $cleanNotes
            if ([string]::IsNullOrWhiteSpace($newNotes)) {
                $newNotes = ''
            }
        }

        if ($newNotes -cne $notes) {
            Set-VM -VM $vm -Notes $newNotes -Confirm:$false -ErrorAction Stop | Out-Null
        }
    }
    catch {
        [Console]::Error.WriteLine("dsmc_fake: could not update notes for VM '$VmName': $($_.Exception.Message)")
    }
    finally {
        if ($null -ne $connection) {
            Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null
        }
    }
}

# ---------------------------------------------------------------------------
# Parse the command line.
# ---------------------------------------------------------------------------

# Keep the real arguments only ($args may be empty or null).
$arguments = @($args | Where-Object { $null -ne $_ })

$vmName = ''
$isFull = $false

for ($i = 0; $i -lt $arguments.Count; $i++) {
    $argument = [string]$arguments[$i]

    # PowerShell string comparisons are case-insensitive, which matches the
    # way dsmc accepts its options.
    if ($argument -eq 'backup') {
        # The VM name is the argument right after "backup vm".
        if (($i + 2) -lt $arguments.Count -and [string]$arguments[$i + 1] -eq 'vm') {
            $vmName = [string]$arguments[$i + 2]
        }
    }
    elseif ($argument -eq '-mode') {
        if (($i + 1) -lt $arguments.Count -and [string]$arguments[$i + 1] -eq 'IFFull') {
            $isFull = $true
        }
    }
    elseif ($argument -eq '-mode=IFFull') {
        $isFull = $true
    }
    elseif ($argument -eq '-VMBACKUPUPDATEGUID') {
        # Narvik always pairs this flag with -mode IFFull, so treat it as a
        # full backup as well.
        $isFull = $true
    }
}

# Strip surrounding double quotes, e.g. when the name was quoted for Windows.
$vmName = $vmName.Trim('"')

if ([string]::IsNullOrEmpty($vmName)) {
    [Console]::Error.WriteLine('Usage: dsmc_fake.ps1 backup vm <VMNAME> [-vmmc=<management-class>] [-VMBACKUPUPDATEGUID] [-mode IFFull] [-preview]')
    exit $UsageExitCode
}

$mode = 'Incremental'
if ($isFull) {
    $mode = 'Full'
}

# An "_err" VM always fails, whatever the mode, and never with the duplicate
# GUID code: it takes precedence over every other rule below.
$isForcedError = $vmName -like '*_err*'

# A "_crit" VM always fails with the critical error Narvik emails; it also
# takes precedence over the duplicate GUID rule below.
$isCriticalError = (-not $isForcedError) -and ($vmName -like '*_crit*')

# A "_dup" VM fails with the duplicate GUID error only when the backup is not
# a Full one, so the retry Narvik schedules (-VMBACKUPUPDATEGUID with
# -mode IFFull) always succeeds.
$isDuplicate = (-not $isForcedError) -and (-not $isCriticalError) -and ($vmName -like '*_dup*') -and (-not $isFull)

# Every other VM name is backed up normally, but each attempt has a
# $RandomFailurePercent percent chance of failing silently: no output, no
# error code, the script just exits with the backup-failure exit code.
$isRandomFailure = (-not $isForcedError) -and (-not $isCriticalError) -and (-not ($vmName -like '*_dup*')) -and ((Get-Random -Minimum 0 -Maximum 100) -lt $RandomFailurePercent)

if ($isRandomFailure) {
    Update-NkFakeVmNotes -VmName $vmName -Success $false -Full $isFull
    exit $FailureExitCode
}

$result = '1'
if ($isForcedError -or $isCriticalError -or $isDuplicate) {
    $result = '0'
}

# ---------------------------------------------------------------------------
# Print the embedded template (from out.txt).
# ---------------------------------------------------------------------------

$template = @'
Copyright (c) 2010 Codethink Limited. Copyright (c) 2015 Canonical Limited. Copyright (C) 1998, 2019 Free Software Foundation, Inc.
_TS_ Full on-demand BACKUP VM of virtual machines '_VMNAME_'.

_TS_ Backup VM command started.  Total number of virtual machines to process: 1
Accessing as node: VE_PRINCIPAL
_PAUSE_5_

Starting Full VM backup of VMware Virtual Machine '_VMNAME_'
        mode:                        'Incremental Forever - _MODE_'
        target node name:            'VE_PRINCIPAL'
        data mover node name:        'VE_PRINCIPAL_DM'
        application protection type: 'VMware'
        application(s) protected:    'n/a'
_PAUSE_2_
_ERR_

Creating "VMware Tools with file system quiescing and application quiescing (VSS) disabled" snapshot for virtual machine '_VMNAME_'
_PAUSE_5_
Backing up Full VM configuration information for '_VMNAME_'
_TS_          39.336 VM Configuration [Sent]
_PAUSE_3_

Processing snapshot
        disk:         [huawei:inf:02] _VMNAME_/_VMNAME_-000001.vmdk (Hard Disk 1)
        Capacity:     107.374.182.400
        Data to Send: 31.581.798.400
        Transport:     (nbdssl:fastlz)[sending]
_PAUSE_30_
_TS_ Volume --> 31.581.798.400 [huawei:inf:02] _VMNAME_/_VMNAME_-000001.vmdk (Hard Disk 1) [Sent]
_PAUSE_2_

Done VM backup of VMware Virtual Machine '_VMNAME_'
        mode:                 'Incremental Forever - _MODE_'
        target node name:     'VE_PRINCIPAL'
        data mover node name: 'VE_PRINCIPAL_DM'
_TS_ Statistics for Virtual Machine '_VMNAME_'.

_TS_ Total number of objects inspected:            1
_TS_ Total number of objects backed up:            _RES_
_TS_ Total number of objects updated:              0
_TS_ Total number of objects rebound:              0
_TS_ Total number of objects deleted:              0
_TS_ Total number of objects expired:              0
_TS_ Total number of objects failed:               0
_TS_ Total number of objects skipped:              0
_TS_ Total number of objects encrypted:            0
_TS_ Total number of objects grew:                 0
_TS_ Total number of retries:                      0
_TS_ Total number of bytes inspected:         100,00 GB
_TS_ Total number of bytes transferred:        29,46 GB
_TS_ Data transfer time:                       69,81 sec
_TS_ Network data transfer rate:          442.467,63 KB/sec
_TS_ Aggregate data transfer rate:         72.892,32 KB/sec
_TS_ Objects compressed by:                        0%
_TS_ Total data reduction ratio:               70.54%
_TS_ Elapsed processing time:               00:07:03
Removing snapshot for virtual machine '_VMNAME_'
_PAUSE_1_

_TS_ Backup VM command complete
_TS_ Total number of virtual machines backed up successfully: 1
_TS_   virtual machine _VMNAME_ backed up to nodename VE_PRINCIPAL (nbdssl)
_TS_ Total number of virtual machines failed: 0
_TS_ Total number of virtual machines skipped: 0
_TS_ Total number of virtual machines backed up using hotadd: 0
_TS_ Total number of virtual machines backed up using san   : 0
_TS_ Total number of virtual machines backed up using nbdssl: 1
_TS_ Total number of virtual machines backed up using nbd   : 0
_TS_ Total number of virtual machines with no changed data  : 0
_TS_ Total number of virtual machines processed: 1
'@

foreach ($line in ($template -split "`r?`n")) {
    # A "_PAUSE_<seconds>_" line is removed and replaced by a pause of that
    # many seconds (scaled by DSMC_FAKE_PAUSE_SCALE).
    if ($line -match '_PAUSE_([0-9]+)_') {
        $pauseMilliseconds = [int][math]::Round([double]$Matches[1] * $PauseScale * 1000.0)
        if ($pauseMilliseconds -gt 0) {
            Start-Sleep -Milliseconds $pauseMilliseconds
        }
        continue
    }

    # "_ERR_" marks where a failing backup reports its error and stops; on a
    # successful backup the marker line is simply removed. The "_err" forced
    # failure is checked first so it can never be mistaken for the duplicate
    # GUID case.
    if ($line -match '_ERR_') {
        if ($isForcedError) {
            Write-Output ($PlainErrorAnsCode + ' The backup of virtual machine failed.')
            Update-NkFakeVmNotes -VmName $vmName -Success $false -Full $isFull
            exit $FailureExitCode
        }
        if ($isCriticalError) {
            Write-Output ($CriticalErrorAnsCode + ' The backup of virtual machine failed because of a critical storage error.')
            Update-NkFakeVmNotes -VmName $vmName -Success $false -Full $isFull
            exit $FailureExitCode
        }
        if ($isDuplicate) {
            Write-Output ($ErrorAnsCode + ' The backup of virtual machine failed because a duplicate virtual machine GUID was detected.')
            Update-NkFakeVmNotes -VmName $vmName -Success $false -Full $isFull
            exit $FailureExitCode
        }
        continue
    }

    # The timestamp is refreshed on every line so the pauses above also
    # advance the clock in the output.
    $timestamp = [System.DateTime]::Now.ToString('dd/MM/yyyy HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)

    $line = $line.Replace('_TS_', $timestamp)
    $line = $line.Replace('_VMNAME_', $vmName)
    $line = $line.Replace('_MODE_', $mode)
    $line = $line.Replace('_RES_', $result)

    Write-Output $line
}

# Safety net: a failing backup must never exit with 0, even if the template
# above has no _ERR_ marker. (The random silent failure has already exited
# above.)
if ($isForcedError -or $isCriticalError -or $isDuplicate) {
    Update-NkFakeVmNotes -VmName $vmName -Success $false -Full $isFull
    exit $FailureExitCode
}

Update-NkFakeVmNotes -VmName $vmName -Success $true -Full $isFull
exit 0
