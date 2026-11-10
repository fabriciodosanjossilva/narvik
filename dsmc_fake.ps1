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
#   - If the VM name contains "_err", the backup fails: the template is
#     printed only down to its _ERR_ marker, where an ANS1715E error line is
#     printed and the script stops with exit code 8. ANS1715E is the error
#     Narvik uses to flag a duplicate VM GUID, so the next attempt for that
#     VM runs with -VMBACKUPUPDATEGUID and -mode IFFull. Change
#     $ErrorAnsCode below if a plain failure is wanted instead.
#   - Otherwise the backup succeeds: the whole template is printed, _RES_
#     becomes 1 and the exit code is 0.
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
#       _ERR_       -> line removed; on a failing backup the ANS1715E error
#                      line is printed here and the script stops
#   - -vmmc and -preview are accepted and ignored.
#
# Exit codes (same convention as dsmc):
#   0  backup succeeded
#   8  backup failed
#   12 usage / command line error
#
# Examples:
#   powershell -NoProfile -ExecutionPolicy Bypass -File dsmc_fake.ps1 backup vm SRV-APP01 -vmmc=GOLD -preview
#   powershell -NoProfile -ExecutionPolicy Bypass -File dsmc_fake.ps1 backup vm SRV-DB01_err -vmmc=GOLD -VMBACKUPUPDATEGUID -mode IFFull
#
# Notes:
#   - Compatible with Windows PowerShell 5.1 (no PowerShell 7 syntax).
#   - Narvik starts dsmc with Start-Process, which cannot run a .ps1 file
#     directly; on Windows, point dsmc_path at a wrapper (for example a
#     .cmd file) that invokes this script through powershell.exe.

$ErrorActionPreference = 'Stop'

# Error reported when the VM name contains "_err".
$ErrorAnsCode = 'ANS1715E'
$ErrorExitCode = 8
$UsageExitCode = 12

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

$isError = $vmName -like '*_err*'

$result = '1'
if ($isError) {
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
    # many seconds.
    if ($line -match '_PAUSE_([0-9]+)_') {
        Start-Sleep -Seconds ([int]$Matches[1])
        continue
    }

    # "_ERR_" marks where a failing backup reports its error and stops; on a
    # successful backup the marker line is simply removed.
    if ($line -match '_ERR_') {
        if ($isError) {
            Write-Output ($ErrorAnsCode + ' The backup of virtual machine failed because a duplicate virtual machine GUID was detected.')
            exit $ErrorExitCode
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
# above has no _ERR_ marker.
if ($isError) {
    exit $ErrorExitCode
}

exit 0
