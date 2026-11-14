#Requires -Version 5.1
<#
.SYNOPSIS
    Offline unit tests for the pure helpers in Narvik.ps1.

.DESCRIPTION
    Narvik.ps1 is a single daemon script whose entrypoint runs on load, so it
    cannot be dot-sourced. This suite parses the script with the PowerShell
    AST, extracts the helper functions by name and tests them in isolation.

    Nothing here talks to vCenter, dsmc or the file system, so the suite runs
    anywhere PowerShell 5.1 or later is available. The tag rule and the backup
    selection logic are exercised with synthetic data; the end-to-end suite in
    Invoke-NarvikVcenterTest.ps1 covers the rest against a real vCenter.

.PARAMETER Verbose
    Prints the extracted function names.

.EXAMPLE
    pwsh -NoProfile -File tests/Invoke-NarvikUnitTest.ps1

.NOTES
    Exit codes: 0 all tests passed, 1 at least one test failed.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$script:NarvikPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Narvik.ps1'
if (-not (Test-Path -LiteralPath $script:NarvikPath -PathType Leaf)) {
    Write-Host "Narvik.ps1 not found at '$script:NarvikPath'." -ForegroundColor Red
    exit 1
}

$parseErrors = $null
$script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:NarvikPath, [ref]$null, [ref]$parseErrors)
if ($null -ne $parseErrors -and $parseErrors.Count -gt 0) {
    Write-Host 'Narvik.ps1 does not parse:' -ForegroundColor Red
    $parseErrors | ForEach-Object { Write-Host ("  $($_.Extent.StartLineNumber): $($_.Message)") }
    exit 1
}

function Get-NarvikFunctionText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $definition = $script:Ast.Find({
            param($node)
            ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($node.Name -eq $Name)
        }, $true)

    if ($null -eq $definition) {
        throw "Function '$Name' was not found in Narvik.ps1."
    }

    Write-Verbose "Extracting function '$Name'."
    return $definition.Extent.Text
}

# Helpers under test, in dependency order. Dot-sourcing at script scope (not
# inside a function) is what makes the extracted functions callable here.
foreach ($name in @(
        'Test-NarvikTagPresent',
        'Get-NarvikVmTagViolations',
        'Get-NarvikDatesFromText',
        'ConvertFrom-NarvikVmNotes',
        'Get-NarvikBaseline',
        'Get-NarvikPendingVMs',
        'Format-NarvikDiskSizeMiB',
        'Get-NarvikManagementClass',
        'Get-NarvikPriorityClusterSetting',
        'Add-NarvikReason',
        'Update-NarvikEligibility',
        'Get-NarvikFolderPath',
        'Get-NarvikMoRefTags',
        'Get-NarvikViewTags',
        'ConvertTo-NarvikDsmcVmName',
        'Test-NarvikSiteRecoveryPlaceholder',
        'Test-NarvikVmActive',
        'Test-NarvikHostActive',
        'Test-NarvikClusterAtCapacity',
        'Test-NarvikBackoffActive',
        'Select-NarvikNextBackup')) {
    . ([scriptblock]::Create((Get-NarvikFunctionText -Name $name)))
}

# Select-NarvikNextBackup reads the clock directly. Shadowing Get-Date in this
# scope lets the window tests pin the time without touching the system clock.
function Get-Date {
    return $script:FakeNow
}

# Write-NarvikLog is only reached on the skip paths of Select-NarvikNextBackup;
# a stub keeps the pure functions free of logging side effects.
function Write-NarvikLog {
    param(
        [string]$Level,
        [string]$Message
    )
}

$script:Passed = 0
$script:Failed = 0
$script:FailureMessages = New-Object 'System.Collections.Generic.List[string]'

function Add-NkResult {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Ok,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowEmptyString()]
        [string]$Detail = ''
    )

    if ($Ok) {
        $script:Passed++
        Write-Host ("[PASS] {0}" -f $Name)
        return
    }

    $script:Failed++
    $message = if ([string]::IsNullOrWhiteSpace($Detail)) { $Name } else { "$Name - $Detail" }
    [void]$script:FailureMessages.Add($message)
    Write-Host ("[FAIL] {0}" -f $message) -ForegroundColor Red
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
    Add-NkResult -Ok ($expectedText -ceq $actualText) -Name $Name -Detail ("expected '{0}', got '{1}'" -f $expectedText, $actualText)
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

    Add-NkResult -Ok $Condition -Name $Name -Detail $Detail
}

function New-NkSyntheticDisk {
    param(
        [string]$Label = 'Hard disk 1',
        [string]$Datastore = 'DS1',
        [string]$DatastoreCluster = 'DSC1',
        [string[]]$DatastoreTags = @(),
        [string[]]$DatastoreClusterTags = @(),
        [bool]$RDM = $false,
        [bool]$Independent = $false,
        [long]$CapacityInKB = 1048576
    )

    return [pscustomobject]@{
        Label                = $Label
        Type                 = 'Thin'
        Independent          = $Independent
        RDM                  = $RDM
        SizeGB               = 1.0
        CapacityInKB         = $CapacityInKB
        Datastore            = $Datastore
        DatastoreCluster     = $DatastoreCluster
        DatastoreTags        = @($DatastoreTags)
        DatastoreClusterTags = @($DatastoreClusterTags)
        DiskMode             = 'persistent'
        BackingType          = 'FlatVer2'
    }
}

function New-NkSyntheticVm {
    param(
        [string]$Name = 'nk-vm01',
        [string]$HostName = 'esx01',
        [string]$FolderName = 'nk-vms',
        [string]$ClusterName = '',
        [string]$ResourcePoolName = 'Resources',
        [string[]]$Tags = @(),
        [string[]]$FolderTags = @(),
        [string[]]$ClusterTags = @(),
        [string[]]$ResourcePoolTags = @(),
        [object[]]$Disks = @(),
        $LastBackup = $null,
        [string]$FolderPath = '',
        [int]$ClusterPriority = 0,
        [int]$ClusterMaxThreads = 1000
    )

    return [pscustomobject]@{
        Name              = $Name
        MoRef             = 'vm-100'
        FolderPath        = $FolderPath
        FolderMoRef       = 'group-v100'
        FolderName        = $FolderName
        FolderTags        = @($FolderTags)
        ClusterMoRef      = $ClusterName
        ClusterName       = $ClusterName
        ClusterTags       = @($ClusterTags)
        ClusterPriority   = $ClusterPriority
        ClusterMaxThreads = $ClusterMaxThreads
        ResourcePoolMoRef = 'resgroup-101'
        ResourcePoolName  = $ResourcePoolName
        ResourcePoolTags  = @($ResourcePoolTags)
        HostName          = $HostName
        Tags              = @($Tags)
        Notes             = ''
        LastBackup        = $LastBackup
        TotalSizeGB       = 1.0
        DatastoreClusters = @()
        ManagementClass   = ''
        Disks             = @($Disks)
    }
}

$script:TagName = 'NAO_FAZER_BACKUP_POR_SNAPSHOT'

# ---------------------------------------------------------------------------
# Tag rule: the opt-out tag applies to the VM, its cluster, its resource pool,
# its direct folder, the datastores of its disks and those datastores' cluster.
# ---------------------------------------------------------------------------

$tagCases = @(
    @{ Id = 'TAG-01'; Source = 'VM'; Expected = "VM tag '$($script:TagName)'" },
    @{ Id = 'TAG-02'; Source = 'Cluster'; Expected = "Cluster 'CL1' tag '$($script:TagName)'" },
    @{ Id = 'TAG-03'; Source = 'ResourcePool'; Expected = "Resource pool 'RP1' tag '$($script:TagName)'" },
    @{ Id = 'TAG-04'; Source = 'Folder'; Expected = "Folder 'nk-vms' tag '$($script:TagName)'" },
    @{ Id = 'TAG-05'; Source = 'Datastore'; Expected = "Datastore 'DS1' tag '$($script:TagName)'" },
    @{ Id = 'TAG-06'; Source = 'DatastoreCluster'; Expected = "Datastore cluster 'DSC1' tag '$($script:TagName)'" }
)

foreach ($case in $tagCases) {
    $diskTags = @()
    $diskClusterTags = @()
    if ($case.Source -eq 'Datastore') {
        $diskTags = @($script:TagName)
    }
    if ($case.Source -eq 'DatastoreCluster') {
        $diskClusterTags = @($script:TagName)
    }

    $vm = New-NkSyntheticVm `
        -ClusterName 'CL1' `
        -ResourcePoolName 'RP1' `
        -Tags $(if ($case.Source -eq 'VM') { @($script:TagName) } else { @() }) `
        -FolderTags $(if ($case.Source -eq 'Folder') { @($script:TagName) } else { @() }) `
        -ClusterTags $(if ($case.Source -eq 'Cluster') { @($script:TagName) } else { @() }) `
        -ResourcePoolTags $(if ($case.Source -eq 'ResourcePool') { @($script:TagName) } else { @() }) `
        -Disks @(New-NkSyntheticDisk -DatastoreTags $diskTags -DatastoreClusterTags $diskClusterTags)

    $violations = @(Get-NarvikVmTagViolations -Vm $vm -TagName $script:TagName)
    Assert-NkEqual -Name ("{0} tag on {1} excludes the VM" -f $case.Id, $case.Source) -Expected 1 -Actual $violations.Count
    Assert-NkEqual -Name ("{0} tag on {1} reason" -f $case.Id, $case.Source) -Expected $case.Expected -Actual $violations[0]
}

$allSourcesVm = New-NkSyntheticVm `
    -ClusterName 'CL1' `
    -ResourcePoolName 'RP1' `
    -Tags @($script:TagName) `
    -FolderTags @($script:TagName) `
    -ClusterTags @($script:TagName) `
    -ResourcePoolTags @($script:TagName) `
    -Disks @(New-NkSyntheticDisk -DatastoreTags @($script:TagName) -DatastoreClusterTags @($script:TagName))
Assert-NkEqual -Name 'TAG-07 tag on all six sources reports six reasons' -Expected 6 -Actual @(Get-NarvikVmTagViolations -Vm $allSourcesVm -TagName $script:TagName).Count

$caseInsensitiveVm = New-NkSyntheticVm -Tags @($script:TagName.ToLowerInvariant())
Assert-NkEqual -Name 'TAG-08 tag name matching is case-insensitive' -Expected 1 -Actual @(Get-NarvikVmTagViolations -Vm $caseInsensitiveVm -TagName $script:TagName).Count

$otherTagVm = New-NkSyntheticVm -Tags @('SOME_OTHER_TAG')
Assert-NkEqual -Name 'TAG-09 a different tag name does not exclude the VM' -Expected 0 -Actual @(Get-NarvikVmTagViolations -Vm $otherTagVm -TagName $script:TagName).Count

$allSourcesVm2 = New-NkSyntheticVm -ClusterName 'CL1' -Tags @($script:TagName) -FolderTags @($script:TagName) -Disks @(New-NkSyntheticDisk -DatastoreTags @($script:TagName))
Assert-NkEqual -Name 'TAG-10 an empty configured tag name disables the rule' -Expected 0 -Actual @(Get-NarvikVmTagViolations -Vm $allSourcesVm2 -TagName '').Count

# The helper only receives the tags of the VM's direct folder, so a tag on an
# ancestor folder cannot reach it. This mirrors the collector, which reads
# Runtime.Host/Parent and the VM's own Parent only.
$ancestorTagVm = New-NkSyntheticVm -FolderName 'child' -FolderTags @()
Assert-NkEqual -Name 'TAG-11 a tagged ancestor folder does not exclude the VM' -Expected 0 -Actual @(Get-NarvikVmTagViolations -Vm $ancestorTagVm -TagName $script:TagName).Count

$homeOnlyVm = New-NkSyntheticVm -Disks @()
Assert-NkEqual -Name 'TAG-12 a tagged VM home datastore without disks does not exclude the VM' -Expected 0 -Actual @(Get-NarvikVmTagViolations -Vm $homeOnlyVm -TagName $script:TagName).Count

$mixedDiskVm = New-NkSyntheticVm -Disks @(
    (New-NkSyntheticDisk -Label 'Hard disk 1' -Datastore 'DS1' -DatastoreCluster 'DSC1'),
    (New-NkSyntheticDisk -Label 'Hard disk 2' -Datastore 'DS2' -DatastoreCluster 'DSC2' -DatastoreTags @($script:TagName))
)
$mixedViolations = @(Get-NarvikVmTagViolations -Vm $mixedDiskVm -TagName $script:TagName)
Assert-NkEqual -Name 'TAG-13 only the tagged datastore of the VM is reported' -Expected 1 -Actual $mixedViolations.Count
Assert-NkEqual -Name 'TAG-13 tagged datastore reason' -Expected "Datastore 'DS2' tag '$($script:TagName)'" -Actual $mixedViolations[0]

$sameDatastoreVm = New-NkSyntheticVm -Disks @(
    (New-NkSyntheticDisk -Label 'Hard disk 1' -DatastoreTags @($script:TagName)),
    (New-NkSyntheticDisk -Label 'Hard disk 2' -DatastoreTags @($script:TagName))
)
Assert-NkEqual -Name 'TAG-14 two disks on the same tagged datastore report one reason' -Expected 1 -Actual @(Get-NarvikVmTagViolations -Vm $sameDatastoreVm -TagName $script:TagName).Count

$noDisksPropertyVm = [pscustomobject]@{ Name = 'nk-bare'; Tags = @() }
Assert-NkEqual -Name 'TAG-15 a VM record without disks or scope data reports nothing' -Expected 0 -Actual @(Get-NarvikVmTagViolations -Vm $noDisksPropertyVm -TagName $script:TagName).Count

$untaggedVm = New-NkSyntheticVm -ClusterName 'CL1' -Disks @(New-NkSyntheticDisk)
Assert-NkEqual -Name 'TAG-16 an untagged VM with one clustered disk is not excluded' -Expected 0 -Actual @(Get-NarvikVmTagViolations -Vm $untaggedVm -TagName $script:TagName).Count

# ---------------------------------------------------------------------------
# VM Notes: the backup timestamp is the newest date on a "backup" line, else
# the newest date anywhere in the notes.
# ---------------------------------------------------------------------------

Assert-NkEqual -Name 'NOTE-01 ISO timestamp on a backup line' -Expected '2026-11-12 20:15:00' -Actual ((ConvertFrom-NarvikVmNotes -Notes 'Backup 2026-11-12 20:15:00 completed') | ForEach-Object { $_.ToString('yyyy-MM-dd HH:mm:ss') })
Assert-NkEqual -Name 'NOTE-02 newest of several backup dates wins' -Expected '2026-11-13 01:00:00' -Actual ((ConvertFrom-NarvikVmNotes -Notes "Backup 2026-11-12T20:15:00Z done`nBackup 2026-11-13T01:00:00Z done") | ForEach-Object { $_.ToString('yyyy-MM-dd HH:mm:ss') })
# Month-first wins because MM/dd/yyyy is tried before dd/MM/yyyy, matching
# the date format dsmc writes in the VM Notes.
Assert-NkEqual -Name 'NOTE-03 a slash timestamp outside a backup line is parsed month-first' -Expected '2026-01-11 03:04:05' -Actual ((ConvertFrom-NarvikVmNotes -Notes 'last run 01/11/2026 03:04:05') | ForEach-Object { $_.ToString('yyyy-MM-dd HH:mm:ss') })
Assert-NkTrue -Name 'NOTE-04 notes without a date return null' -Condition ($null -eq (ConvertFrom-NarvikVmNotes -Notes 'no timestamp here'))
Assert-NkTrue -Name 'NOTE-05 empty notes return null' -Condition ($null -eq (ConvertFrom-NarvikVmNotes -Notes ''))
Assert-NkEqual -Name 'NOTE-06 ISO timestamp with milliseconds' -Expected '2026-11-12 20:15:00' -Actual ((ConvertFrom-NarvikVmNotes -Notes 'Backup 2026-11-12T20:15:00.123Z') | ForEach-Object { $_.ToString('yyyy-MM-dd HH:mm:ss') })

# ---------------------------------------------------------------------------
# Names sent to dsmc: [,./]+ becomes *.
# ---------------------------------------------------------------------------

Assert-NkEqual -Name 'NAME-01 dot becomes a wildcard' -Expected 'nk-name*01' -Actual (ConvertTo-NarvikDsmcVmName -Name 'nk-name.01')
Assert-NkEqual -Name 'NAME-02 every separator becomes one wildcard' -Expected 'a*b*c*d' -Actual (ConvertTo-NarvikDsmcVmName -Name 'a.b/c,d')
Assert-NkEqual -Name 'NAME-03 a plain name is unchanged' -Expected 'nk-inc01' -Actual (ConvertTo-NarvikDsmcVmName -Name 'nk-inc01')

# ---------------------------------------------------------------------------
# Backup baseline: 20:00 of the current or previous day.
# ---------------------------------------------------------------------------

Assert-NkEqual -Name 'BASE-01 before 20:00 the baseline is yesterday 20:00' -Expected '2026-11-12 20:00:00' -Actual ((Get-NarvikBaseline -Now ([datetime]'2026-11-13 10:00:00')).ToString('yyyy-MM-dd HH:mm:ss'))
Assert-NkEqual -Name 'BASE-02 after 20:00 the baseline is today 20:00' -Expected '2026-11-13 20:00:00' -Actual ((Get-NarvikBaseline -Now ([datetime]'2026-11-13 21:30:00')).ToString('yyyy-MM-dd HH:mm:ss'))

$script:VCache = [pscustomobject]@{ VMs = @() }
$script:EligibleVMs = @(
    (New-NkSyntheticVm -Name 'nk-never' -LastBackup $null),
    (New-NkSyntheticVm -Name 'nk-done' -LastBackup ([datetime]'2026-11-12 21:00:00')),
    (New-NkSyntheticVm -Name 'nk-stale' -LastBackup ([datetime]'2026-11-12 19:00:00'))
)
$pendingNames = @(Get-NarvikPendingVMs -Now ([datetime]'2026-11-13 10:00:00') | ForEach-Object { $_.Name } | Sort-Object)
Assert-NkEqual -Name 'PEND-01 never backed up and pre-baseline VMs are pending' -Expected 'nk-never,nk-stale' -Actual ($pendingNames -join ',')
$pendingNamesAfter = @(Get-NarvikPendingVMs -Now ([datetime]'2026-11-13 22:00:00') | ForEach-Object { $_.Name } | Sort-Object)
$script:EligibleVMs = @(
    (New-NkSyntheticVm -Name 'nk-never' -LastBackup $null),
    (New-NkSyntheticVm -Name 'nk-fresh' -LastBackup ([datetime]'2026-11-13 20:30:00')),
    (New-NkSyntheticVm -Name 'nk-stale' -LastBackup ([datetime]'2026-11-13 19:00:00'))
)
$pendingNamesAfter = @(Get-NarvikPendingVMs -Now ([datetime]'2026-11-13 22:00:00') | ForEach-Object { $_.Name } | Sort-Object)
Assert-NkEqual -Name 'PEND-02 after 20:00 only VMs without a backup since 20:00 are pending' -Expected 'nk-never,nk-stale' -Actual ($pendingNamesAfter -join ',')

# ---------------------------------------------------------------------------
# Management class mapping from the datastore cluster.
# ---------------------------------------------------------------------------

$script:Config = [pscustomobject]@{
    datastore_cluster_to_management_class = @{
        'dsc1' = 'MGMT_CLASS_1'
    }
}
Assert-NkEqual -Name 'MGMT-01 mapping is case-insensitive' -Expected 'MGMT_CLASS_1' -Actual (Get-NarvikManagementClass -DatastoreClusterName 'DSC1')
Assert-NkEqual -Name 'MGMT-02 an unmapped cluster has no management class' -Expected '' -Actual (Get-NarvikManagementClass -DatastoreClusterName 'DSC2')
Assert-NkEqual -Name 'MGMT-03 an empty cluster has no management class' -Expected '' -Actual (Get-NarvikManagementClass -DatastoreClusterName '')

# ---------------------------------------------------------------------------
# Disk size formatting and folder paths.
# ---------------------------------------------------------------------------

Assert-NkEqual -Name 'MISC-01 1 GiB is formatted as 1024 MiB' -Expected '1024' -Actual (Format-NarvikDiskSizeMiB -CapacityInKB 1048576)
Assert-NkEqual -Name 'MISC-02 a fractional size keeps its decimals' -Expected '1.5' -Actual (Format-NarvikDiskSizeMiB -CapacityInKB 1536)
Assert-NkEqual -Name 'MISC-03 zero is formatted as 0' -Expected '0' -Actual (Format-NarvikDiskSizeMiB -CapacityInKB 0)

$folderMap = @{
    'group-v1' = [pscustomobject]@{ Name = 'vm'; Parent = $null }
    'group-v2' = [pscustomobject]@{ Name = 'nk-vms'; Parent = [pscustomobject]@{ Value = 'group-v1' } }
    'group-v3' = [pscustomobject]@{ Name = 'deep'; Parent = [pscustomobject]@{ Value = 'group-v2' } }
    'group-v4' = [pscustomobject]@{ Name = 'child'; Parent = [pscustomobject]@{ Value = 'group-v3' } }
}
Assert-NkEqual -Name 'FOLDER-01 path skips the datacenter root folders' -Expected 'nk-vms/deep/child' -Actual (Get-NarvikFolderPath -FolderId 'group-v4' -FolderMap $folderMap)
Assert-NkEqual -Name 'FOLDER-02 an unknown folder id has no path' -Expected '' -Actual (Get-NarvikFolderPath -FolderId 'group-unknown' -FolderMap $folderMap)
Assert-NkEqual -Name 'FOLDER-03 an empty folder id has no path' -Expected '' -Actual (Get-NarvikFolderPath -FolderId '' -FolderMap $folderMap)

$cyclicMap = @{
    'group-x' = [pscustomobject]@{ Name = 'x'; Parent = [pscustomobject]@{ Value = 'group-y' } }
    'group-y' = [pscustomobject]@{ Name = 'y'; Parent = [pscustomobject]@{ Value = 'group-x' } }
}
# The map is malformed on purpose: the walk must stop instead of looping.
Assert-NkEqual -Name 'FOLDER-04 a parent cycle terminates' -Expected 'y/x' -Actual (Get-NarvikFolderPath -FolderId 'group-x' -FolderMap $cyclicMap)

# ---------------------------------------------------------------------------
# Tag lookups by MoRef (including the normalized ids Get-TagAssignment emits).
# ---------------------------------------------------------------------------

$tagMap = @{
    'datastore-101' = @('tag-a')
    '101'           = @('tag-a')
    'folder-group-v9' = @('tag-b')
}
Assert-NkEqual -Name 'VIEWTAG-01 tags are found by MoRef value' -Expected 'tag-a' -Actual ((Get-NarvikMoRefTags -MoRefValue 'datastore-101' -TagMap $tagMap) -join ',')
Assert-NkEqual -Name 'VIEWTAG-02 normalized ids resolve to the same entity' -Expected 'tag-a' -Actual ((Get-NarvikMoRefTags -MoRefValue '101' -TagMap $tagMap) -join ',')
Assert-NkEqual -Name 'VIEWTAG-03 an untagged MoRef yields an empty list' -Expected 0 -Actual @(Get-NarvikMoRefTags -MoRefValue 'datastore-999' -TagMap $tagMap).Count
$viewWithoutTags = [pscustomobject]@{ MoRef = [pscustomobject]@{ Value = 'datastore-999' } }
Assert-NkEqual -Name 'VIEWTAG-04 a view without assignments yields an empty list' -Expected 0 -Actual @(Get-NarvikViewTags -View $viewWithoutTags -TagMap $tagMap).Count

# ---------------------------------------------------------------------------
# Failure backoff: one minute, quadrupling, capped at 12 hours.
# ---------------------------------------------------------------------------

$script:State = @{ failed_attempts = @{} }
Assert-NkTrue -Name 'BACKOFF-01 a VM without failures has no backoff' -Condition (-not (Test-NarvikBackoffActive -VmName 'nk-a' -Now ([datetime]'2026-11-13 10:00:00')))
$script:State.failed_attempts['nk-a'] = @{ last_attempt = [datetime]'2026-11-13 09:59:30'; count = 1 }
Assert-NkTrue -Name 'BACKOFF-02 the first retry waits one minute' -Condition (Test-NarvikBackoffActive -VmName 'nk-a' -Now ([datetime]'2026-11-13 10:00:00'))
$script:State.failed_attempts['nk-a'] = @{ last_attempt = [datetime]'2026-11-13 09:58:00'; count = 1 }
Assert-NkTrue -Name 'BACKOFF-03 the backoff expires after one minute' -Condition (-not (Test-NarvikBackoffActive -VmName 'nk-a' -Now ([datetime]'2026-11-13 10:00:00')))
$script:State.failed_attempts['nk-a'] = @{ last_attempt = [datetime]'2026-11-13 09:59:00'; count = 3 }
Assert-NkTrue -Name 'BACKOFF-04 the third failure waits sixteen minutes' -Condition (Test-NarvikBackoffActive -VmName 'nk-a' -Now ([datetime]'2026-11-13 10:14:00'))
Assert-NkTrue -Name 'BACKOFF-05 the sixteen-minute backoff expires' -Condition (-not (Test-NarvikBackoffActive -VmName 'nk-a' -Now ([datetime]'2026-11-13 10:16:00')))
$script:State.failed_attempts['nk-a'] = @{ last_attempt = [datetime]'2026-11-12 10:00:00'; count = 20 }
Assert-NkTrue -Name 'BACKOFF-06 the backoff is capped at twelve hours' -Condition ((Test-NarvikBackoffActive -VmName 'nk-a' -Now ([datetime]'2026-11-13 10:00:00')) -eq $false)

# ---------------------------------------------------------------------------
# VMware Live Site Recovery placeholders use Config.ManagedBy.
# ---------------------------------------------------------------------------

$placeholderView = [pscustomobject]@{ Config = [pscustomobject]@{ ManagedBy = [pscustomobject]@{ ExtensionKey = 'com.vmware.vcDr'; Type = 'placeholderVm' } } }
$normalView = [pscustomobject]@{ Config = [pscustomobject]@{ ManagedBy = $null } }
$otherExtensionView = [pscustomobject]@{ Config = [pscustomobject]@{ ManagedBy = [pscustomobject]@{ ExtensionKey = 'com.example.other'; Type = 'placeholderVm' } } }
Assert-NkTrue -Name 'SRM-01 a Site Recovery placeholder is detected' -Condition (Test-NarvikSiteRecoveryPlaceholder -View $placeholderView)
Assert-NkTrue -Name 'SRM-02 a normal VM is not a placeholder' -Condition (-not (Test-NarvikSiteRecoveryPlaceholder -View $normalView))
Assert-NkTrue -Name 'SRM-03 another extension is not a placeholder' -Condition (-not (Test-NarvikSiteRecoveryPlaceholder -View $otherExtensionView))

# ---------------------------------------------------------------------------
# Backup selection: pending first, full only inside the window, oldest full
# first, one backup per host, failure backoff.
# ---------------------------------------------------------------------------

$script:VCache = [pscustomobject]@{ VMs = @() }
$script:ActiveJobs = @()
$script:State = @{ failed_attempts = @{} }
$script:DuplicateGuid = @{}
$script:LastFull = @{}

$script:FakeNow = [datetime]'2026-11-13 10:00:00'   # Friday, outside the full window
$script:EligibleVMs = @(New-NkSyntheticVm -Name 'nk-inc' -LastBackup $null)
Assert-NkEqual -Name 'SEL-01 a pending VM is selected as an incremental backup' -Expected 'nk-inc|Incremental|False' -Actual ((Select-NarvikNextBackup) | ForEach-Object { "$($_.VM.Name)|$($_.Mode)|$($_.IsFull)" })

$script:ActiveJobs = @([pscustomobject]@{ VmName = 'nk-other'; HostName = 'esx01' })
Assert-NkTrue -Name 'SEL-02 a VM sharing a host with an active backup is skipped' -Condition ($null -eq (Select-NarvikNextBackup))
$script:ActiveJobs = @()

$script:State.failed_attempts['nk-inc'] = @{ last_attempt = [datetime]'2026-11-13 09:59:45'; count = 1 }
Assert-NkTrue -Name 'SEL-03 a VM in failure backoff is skipped' -Condition ($null -eq (Select-NarvikNextBackup))
$script:State.failed_attempts = @{}

# Mode stays 'Incremental' for a pending VM; the duplicate GUID flag is what
# makes Start-NarvikBackupJob send -mode IFFull, and it travels in IsFull.
$script:DuplicateGuid['nk-inc'] = $true
Assert-NkEqual -Name 'SEL-04 a duplicate GUID forces a full backup' -Expected 'nk-inc|True' -Actual ((Select-NarvikNextBackup) | ForEach-Object { "$($_.VM.Name)|$($_.IsFull)" })
$script:DuplicateGuid = @{}

$script:EligibleVMs = @(New-NkSyntheticVm -Name 'nk-done' -LastBackup ([datetime]'2026-11-13 09:00:00'))
Assert-NkTrue -Name 'SEL-05 no full backup outside the window' -Condition ($null -eq (Select-NarvikNextBackup))

$script:FakeNow = [datetime]'2026-11-14 02:00:00'   # Saturday, inside the full window
Assert-NkTrue -Name 'SEL-06 a full backup is selected inside the weekend window' -Condition ($null -ne (Select-NarvikNextBackup))

$script:EligibleVMs = @(
    (New-NkSyntheticVm -Name 'nk-recent' -LastBackup ([datetime]'2026-11-14 01:00:00') -FolderPath 'a'),
    (New-NkSyntheticVm -Name 'nk-oldest' -LastBackup ([datetime]'2026-11-14 01:00:00') -FolderPath 'b')
)
$script:LastFull = @{
    'nk-recent' = [datetime]'2026-09-01 00:00:00'
    'nk-oldest' = [datetime]'2026-08-01 00:00:00'
}
Assert-NkEqual -Name 'SEL-07 the oldest full backup is selected first' -Expected 'nk-oldest' -Actual ((Select-NarvikNextBackup).VM.Name)

$script:FakeNow = [datetime]'2026-11-14 09:00:00'   # Saturday, any hour
Assert-NkTrue -Name 'SEL-08 the whole weekend is inside the full window' -Condition ($null -ne (Select-NarvikNextBackup))

$script:FakeNow = [datetime]'2026-11-16 07:30:00'   # Monday before 08:00
Assert-NkTrue -Name 'SEL-09 the full window is open before 08:00 on a weekday' -Condition ($null -ne (Select-NarvikNextBackup))

# ---------------------------------------------------------------------------
# Cluster priority and per-cluster concurrency cap.
# ---------------------------------------------------------------------------

$script:VCache = [pscustomobject]@{ VMs = @() }
$script:ActiveJobs = @()
$script:State = @{ failed_attempts = @{} }
$script:DuplicateGuid = @{}
$script:LastFull = @{}
$script:FakeNow = [datetime]'2026-11-13 10:00:00'

# Resolution: a listed cluster, an unlisted cluster and a VM outside a cluster.
$script:Config = [pscustomobject]@{
    priority_clusters = @{
        'cluster-a' = [pscustomobject]@{ name = 'Cluster-A'; priority = 7; max_threads = 3 }
    }
}
$setting = Get-NarvikPriorityClusterSetting -ClusterName 'cluster-a'
Assert-NkEqual -Name 'PRIO-01 a listed cluster returns its configured values' -Expected '7|3|True' -Actual "$($setting.Priority)|$($setting.MaxThreads)|$($setting.Listed)"
$setting = Get-NarvikPriorityClusterSetting -ClusterName 'Cluster-B'
Assert-NkEqual -Name 'PRIO-02 an unlisted cluster keeps priority 0 and max_threads 1000' -Expected '0|1000|False' -Actual "$($setting.Priority)|$($setting.MaxThreads)|$($setting.Listed)"
$setting = Get-NarvikPriorityClusterSetting -ClusterName ''
Assert-NkEqual -Name 'PRIO-03 a VM outside a cluster keeps the defaults' -Expected '0|1000|False' -Actual "$($setting.Priority)|$($setting.MaxThreads)|$($setting.Listed)"

$script:EligibleVMs = @(
    (New-NkSyntheticVm -Name 'nk-negative' -HostName 'esx-neg' -FolderPath 'a' -ClusterName 'CL-NEG' -ClusterPriority -100 -LastBackup $null),
    (New-NkSyntheticVm -Name 'nk-zero' -HostName 'esx-zero' -FolderPath 'a' -ClusterName 'CL-ZERO' -LastBackup $null),
    (New-NkSyntheticVm -Name 'nk-positive' -HostName 'esx-pos' -FolderPath 'z' -ClusterName 'CL-POS' -ClusterPriority 100 -LastBackup $null)
)
Assert-NkEqual -Name 'PRIO-04 the highest cluster priority is selected first' -Expected 'nk-positive' -Actual ((Select-NarvikNextBackup).VM.Name)

$script:EligibleVMs = @(
    (New-NkSyntheticVm -Name 'nk-z' -HostName 'esx-z' -FolderPath 'z' -ClusterPriority 10 -LastBackup $null),
    (New-NkSyntheticVm -Name 'nk-a' -HostName 'esx-a' -FolderPath 'a' -ClusterPriority 10 -LastBackup $null)
)
Assert-NkEqual -Name 'PRIO-05 the folder is the secondary criterion inside a priority' -Expected 'nk-a' -Actual ((Select-NarvikNextBackup).VM.Name)

$script:EligibleVMs = @(
    (New-NkSyntheticVm -Name 'nk-lowest' -HostName 'esx-low' -FolderPath 'a' -ClusterPriority -100 -LastBackup $null),
    (New-NkSyntheticVm -Name 'nk-default' -HostName 'esx-default' -FolderPath 'z' -ClusterPriority 0 -LastBackup $null)
)
Assert-NkEqual -Name 'PRIO-06 a negative priority comes after the default priority' -Expected 'nk-default' -Actual ((Select-NarvikNextBackup).VM.Name)

$script:FakeNow = [datetime]'2026-11-14 02:00:00'   # Saturday, inside the full window
$script:EligibleVMs = @(
    (New-NkSyntheticVm -Name 'nk-old-low' -HostName 'esx-old' -FolderPath 'a' -ClusterPriority -100 -LastBackup ([datetime]'2026-11-14 01:00:00')),
    (New-NkSyntheticVm -Name 'nk-new-high' -HostName 'esx-new' -FolderPath 'z' -ClusterPriority 100 -LastBackup ([datetime]'2026-11-14 01:00:00'))
)
$script:LastFull = @{
    'nk-old-low'  = [datetime]'2026-06-01 00:00:00'
    'nk-new-high' = [datetime]'2026-10-01 00:00:00'
}
Assert-NkEqual -Name 'PRIO-07 a full backup honors cluster priority before the oldest full' -Expected 'nk-new-high' -Actual ((Select-NarvikNextBackup).VM.Name)

$script:FakeNow = [datetime]'2026-11-13 10:00:00'
$script:LastFull = @{}
$script:ActiveJobs = @([pscustomobject]@{ VmName = 'nk-running'; HostName = 'esx-running'; ClusterName = 'CL-FULL' })
$script:EligibleVMs = @(
    (New-NkSyntheticVm -Name 'nk-blocked' -HostName 'esx-01' -FolderPath 'a' -ClusterName 'CL-FULL' -ClusterPriority 100 -ClusterMaxThreads 1 -LastBackup $null),
    (New-NkSyntheticVm -Name 'nk-allowed' -HostName 'esx-02' -FolderPath 'z' -ClusterName 'CL-OTHER' -ClusterPriority 0 -LastBackup $null)
)
Assert-NkEqual -Name 'PRIO-08 a saturated cluster is skipped while another cluster starts' -Expected 'nk-allowed' -Actual ((Select-NarvikNextBackup).VM.Name)

$script:ActiveJobs = @(
    [pscustomobject]@{ VmName = 'nk-a'; HostName = 'esx-busy-1'; ClusterName = 'CL-OTHER' },
    [pscustomobject]@{ VmName = 'nk-b'; HostName = 'esx-busy-2'; ClusterName = 'CL-OTHER' },
    [pscustomobject]@{ VmName = 'nk-c'; HostName = 'esx-busy-3'; ClusterName = 'CL-OTHER' }
)
$script:EligibleVMs = @(New-NkSyntheticVm -Name 'nk-default-cap' -HostName 'esx-03' -ClusterName 'CL-OTHER' -ClusterMaxThreads 1000 -LastBackup $null)
Assert-NkEqual -Name 'PRIO-09 the default max_threads does not block a small number of jobs' -Expected 'nk-default-cap' -Actual ((Select-NarvikNextBackup).VM.Name)

$script:ActiveJobs = @()

# ---------------------------------------------------------------------------
# Eligibility wiring: the tag rule fail-safe
# ---------------------------------------------------------------------------

# Update-NarvikEligibility writes the monitoring files; the daemon's writer is
# deliberately not extracted so these tests stay free of file-system effects.
function Write-NarvikMonitoringFiles {
}

function New-NkSyntheticCache {
    param(
        [object[]]$Vms = @(),
        [bool]$TagDataAvailable = $true
    )

    return [pscustomobject]@{
        VMs              = @($Vms)
        TagDataAvailable = $TagDataAvailable
    }
}

$script:NonEligibleSignature = ''
$script:Config = [pscustomobject]@{
    dont_backup_by_snapshot_tag_name      = $script:TagName
    datastore_cluster_to_management_class = @{ 'dsc1' = 'NK_DSC1' }
}

$untagged = New-NkSyntheticVm -Name 'nk-untagged' -Disks @(New-NkSyntheticDisk)
$untagged.DatastoreClusters = @('DSC1')

# The rule is configured but the inventory has no tag data: nothing can prove
# the VM is untagged, so the backup must be skipped.
$script:VCache = New-NkSyntheticCache -Vms @($untagged) -TagDataAvailable $false
Update-NarvikEligibility
Assert-NkEqual -Name 'ELIG-01 tag data unavailable excludes every VM' -Expected 0 -Actual @($script:EligibleVMs).Count
Assert-NkTrue -Name 'ELIG-02 tag data unavailable logs the fail-safe reason' -Condition (@($script:NonEligibleVMs)[0].Reasons -contains 'Tag assignments are unavailable while the snapshot tag rule is configured') -Detail (@($script:NonEligibleVMs)[0].Reasons -join '; ')

# Same VM, tag data present: it is eligible.
$script:VCache = New-NkSyntheticCache -Vms @($untagged) -TagDataAvailable $true
Update-NarvikEligibility
Assert-NkEqual -Name 'ELIG-03 an untagged VM is eligible when tag data is available' -Expected 1 -Actual @($script:EligibleVMs).Count

# Rule unset: missing tag data is irrelevant and must not block backups.
$script:Config.dont_backup_by_snapshot_tag_name = ''
$script:VCache = New-NkSyntheticCache -Vms @($untagged) -TagDataAvailable $false
Update-NarvikEligibility
Assert-NkEqual -Name 'ELIG-04 missing tag data does not matter without the rule' -Expected 1 -Actual @($script:EligibleVMs).Count

# Rule set and the tag is on the VM itself.
$script:Config.dont_backup_by_snapshot_tag_name = $script:TagName
$tagged = New-NkSyntheticVm -Name 'nk-tagged' -Tags @($script:TagName) -Disks @(New-NkSyntheticDisk)
$tagged.DatastoreClusters = @('DSC1')
$script:VCache = New-NkSyntheticCache -Vms @($tagged) -TagDataAvailable $true
Update-NarvikEligibility
Assert-NkEqual -Name 'ELIG-05 a tagged VM is excluded' -Expected 0 -Actual @($script:EligibleVMs).Count
Assert-NkTrue -Name 'ELIG-06 the tag reason reaches the non-eligible list' -Condition (@($script:NonEligibleVMs)[0].Reasons -contains "VM tag '$($script:TagName)'") -Detail (@($script:NonEligibleVMs)[0].Reasons -join '; ')

# A cache collected before the rule existed has no TagDataAvailable property;
# it must be treated like missing tag data, never like "no tags".
$legacyCache = [pscustomobject]@{ VMs = @($untagged) }
$script:VCache = $legacyCache
Update-NarvikEligibility
Assert-NkEqual -Name 'ELIG-07 a cache without TagDataAvailable fails safe' -Expected 0 -Actual @($script:EligibleVMs).Count
Assert-NkTrue -Name 'ELIG-08 a cache without TagDataAvailable logs the fail-safe reason' -Condition (@($script:NonEligibleVMs)[0].Reasons -contains 'Tag assignments are unavailable while the snapshot tag rule is configured') -Detail (@($script:NonEligibleVMs)[0].Reasons -join '; ')

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host ("Unit tests: {0} passed, {1} failed." -f $script:Passed, $script:Failed)

if ($script:Failed -gt 0) {
    Write-Host 'Failed tests:' -ForegroundColor Red
    foreach ($message in $script:FailureMessages) {
        Write-Host ("  - {0}" -f $message) -ForegroundColor Red
    }
    exit 1
}

exit 0
