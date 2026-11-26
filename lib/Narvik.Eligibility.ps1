function Get-NarvikBaseline {
    param(
        [datetime]$Now
    )

    $baselineTime = $script:Config.incremental_baseline_time

    if ($Now.TimeOfDay -lt $baselineTime) {
        return $Now.Date.AddDays(-1).Add($baselineTime)
    }

    return $Now.Date.Add($baselineTime)
}

function Get-NarvikPendingVMs {
    param(
        [datetime]$Now = (Get-Date)
    )

    $baseline = Get-NarvikBaseline -Now $Now
    return @($script:EligibleVMs | Where-Object { $null -eq $_.LastBackup -or $_.LastBackup -lt $baseline })
}

function Test-NarvikTagPresent {
    param(
        [object[]]$Tags,
        [string]$TagName
    )

    foreach ($tag in @($Tags)) {
        if ([string]$tag -ieq $TagName) {
            return $true
        }
    }

    return $false
}

function Get-NarvikVmTagViolations {
    param(
        [Parameter(Mandatory = $true)]
        $Vm,
        [AllowEmptyString()]
        [string]$TagName
    )

    if ([string]::IsNullOrWhiteSpace($TagName)) {
        return @()
    }

    # Entities whose tag opts a VM out of snapshot backups. The datastore scope
    # is the VMFS datastores that back the VM's disks, the folder scope is the
    # VM's direct VM folder only (a tag on an ancestor folder does not apply),
    # and the host scope is the host running the VM.
    $violations = New-Object 'System.Collections.Generic.List[string]'

    if (Test-NarvikTagPresent -Tags @($Vm.Tags) -TagName $TagName) {
        [void]$violations.Add("VM tag '$TagName'")
    }

    $namedScopes = @(
        [pscustomobject]@{ Label = 'Cluster'; Name = [string]$Vm.ClusterName; Tags = @($Vm.ClusterTags) },
        [pscustomobject]@{ Label = 'Resource pool'; Name = [string]$Vm.ResourcePoolName; Tags = @($Vm.ResourcePoolTags) },
        [pscustomobject]@{ Label = 'Folder'; Name = [string]$Vm.FolderName; Tags = @($Vm.FolderTags) },
        [pscustomobject]@{ Label = 'Host'; Name = [string]$Vm.HostName; Tags = @($Vm.HostTags) }
    )

    foreach ($scope in $namedScopes) {
        if (-not (Test-NarvikTagPresent -Tags @($scope.Tags) -TagName $TagName)) {
            continue
        }

        $name = [string]$scope.Name
        if ([string]::IsNullOrWhiteSpace($name)) {
            $reason = "$($scope.Label) tag '$TagName'"
        }
        else {
            $reason = "$($scope.Label) '$name' tag '$TagName'"
        }

        if (-not $violations.Contains($reason)) {
            [void]$violations.Add($reason)
        }
    }

    foreach ($disk in @($Vm.Disks)) {
        if ($null -eq $disk) {
            continue
        }

        $diskScopes = @(
            [pscustomobject]@{ Label = 'Datastore'; Name = [string]$disk.Datastore; Tags = @($disk.DatastoreTags) },
            [pscustomobject]@{ Label = 'Datastore cluster'; Name = [string]$disk.DatastoreCluster; Tags = @($disk.DatastoreClusterTags) }
        )

        foreach ($scope in $diskScopes) {
            if (-not (Test-NarvikTagPresent -Tags @($scope.Tags) -TagName $TagName)) {
                continue
            }

            $name = [string]$scope.Name
            if ([string]::IsNullOrWhiteSpace($name)) {
                $reason = "$($scope.Label) tag '$TagName'"
            }
            else {
                $reason = "$($scope.Label) '$name' tag '$TagName'"
            }

            if (-not $violations.Contains($reason)) {
                [void]$violations.Add($reason)
            }
        }
    }

    return @($violations)
}

function Get-NarvikDiskRoundedCapacityKB {
    param(
        [Parameter(Mandatory = $true)]
        [long]$CapacityInKB
    )

    # Next multiple of 1 MiB (1024 KiB) above the current size.
    return ($CapacityInKB - ($CapacityInKB % 1024) + 1024)
}

function Get-NarvikDiskFixCommand {
    param(
        [string]$VMName,
        [string]$DiskName,
        [long]$CapacityInKB
    )

    # Double single quotes so the generated command stays valid PowerShell.
    $vmArgument = ([string]$VMName) -replace "'", "''"
    $diskArgument = ([string]$DiskName) -replace "'", "''"

    return "Get-HardDisk -vm '$vmArgument' | where {`$_.name -eq '$diskArgument'} | Set-HardDisk -capacityKB $CapacityInKB"
}

function Add-NarvikReason {
    param(
        [System.Collections.Generic.List[string]]$Reasons,
        [string]$Reason
    )

    if (-not $Reasons.Contains($Reason)) {
        [void]$Reasons.Add($Reason)
    }
}

function Get-NarvikManagementClass {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$DatastoreClusterName
    )

    if ([string]::IsNullOrWhiteSpace($DatastoreClusterName)) {
        return ''
    }

    if ($null -eq $script:Config -or $null -eq $script:Config.datastore_cluster_to_management_class) {
        return ''
    }

    $mapping = $script:Config.datastore_cluster_to_management_class
    $key = $DatastoreClusterName.Trim().ToLowerInvariant()
    if (-not $mapping.ContainsKey($key)) {
        return ''
    }

    return [string]$mapping[$key]
}

function Get-NarvikPriorityClusterSetting {
    param(
        [AllowEmptyString()]
        [string]$ClusterName
    )

    # Clusters that are not listed in 'priority_clusters', and VMs whose host
    # is not in a cluster, keep priority 0.
    $displayName = ''
    if (-not [string]::IsNullOrWhiteSpace($ClusterName)) {
        $displayName = $ClusterName.Trim()
    }

    $setting = [pscustomobject]@{
        Cluster  = $displayName
        Priority = 0
        Listed   = $false
    }

    if ([string]::IsNullOrWhiteSpace($displayName)) {
        return $setting
    }

    if ($null -eq $script:Config -or $null -eq $script:Config.priority_clusters) {
        return $setting
    }

    $mapping = $script:Config.priority_clusters
    $key = $displayName.ToLowerInvariant()
    if (-not $mapping.ContainsKey($key)) {
        return $setting
    }

    $entry = $mapping[$key]
    return [pscustomobject]@{
        Cluster  = [string]$entry.cluster
        Priority = [int]$entry.priority
        Listed   = $true
    }
}

function Get-NarvikPriorityResourcePoolSetting {
    param(
        [AllowEmptyString()]
        [string]$ClusterName,
        [AllowEmptyString()]
        [string]$ResourcePoolName
    )

    # VMs outside a resource pool, resource pools that are not listed in
    # 'priority_resource_pools', and VMs whose host is not in a cluster keep
    # priority 0.
    if ([string]::IsNullOrWhiteSpace($ClusterName) -or [string]::IsNullOrWhiteSpace($ResourcePoolName)) {
        return 0
    }

    if ($null -eq $script:Config -or $null -eq $script:Config.priority_resource_pools) {
        return 0
    }

    $clusterKey = $ClusterName.Trim().ToLowerInvariant()
    $resourcePoolKey = $ResourcePoolName.Trim().ToLowerInvariant()
    $mapping = $script:Config.priority_resource_pools
    if (-not $mapping.ContainsKey($clusterKey)) {
        return 0
    }

    $clusterPools = $mapping[$clusterKey]
    if (-not $clusterPools.ContainsKey($resourcePoolKey)) {
        return 0
    }

    return [int]$clusterPools[$resourcePoolKey].priority
}

function Get-NarvikClusterMaxThreadsSetting {
    param(
        [AllowEmptyString()]
        [string]$ClusterName
    )

    # Clusters that are not listed in 'cluster_max_threads' keep max_threads
    # 1000, which means no practical cap beyond the global one and the
    # one-per-host rule.
    if ([string]::IsNullOrWhiteSpace($ClusterName)) {
        return 1000
    }

    if ($null -eq $script:Config -or $null -eq $script:Config.cluster_max_threads) {
        return 1000
    }

    $mapping = $script:Config.cluster_max_threads
    $key = $ClusterName.Trim().ToLowerInvariant()
    if (-not $mapping.ContainsKey($key)) {
        return 1000
    }

    return [int]$mapping[$key].max_threads
}

function Update-NarvikEligibility {
    param(
        [switch]$SendAlerts
    )

    $snapshotTagName = [string]$script:Config.dont_backup_by_snapshot_tag_name
    # Characters that cannot be used in a VM name for the dsmc backup command.
    $unsupportedNamePattern = '[:;''"*?,<>/\\|\[\]}{]'

    if ($null -eq $script:VCache) {
        Write-NarvikLog -Level DEBUG -Message 'No vCenter inventory is cached; eligibility and backup scheduling are paused.'
        $script:EligibleVMs = @()
        $script:NonEligibleVMs = @()
        $script:DuplicateNameCases = @()
        $script:UnsupportedNameCases = @()
        $script:DatastoreClusterCases = @()
        $script:ManagementClassCases = @()
        $script:DiskSizeCases = @()
        Write-NarvikMonitoringFiles
        return
    }

    $initialEligible = [System.Collections.Generic.List[object]]::new()
    $nonEligible = [System.Collections.Generic.List[object]]::new()
    $unsupportedNameCases = [System.Collections.Generic.List[object]]::new()
    $datastoreClusterCases = [System.Collections.Generic.List[object]]::new()
    $managementClassCases = [System.Collections.Generic.List[object]]::new()
    $diskSizeCases = [System.Collections.Generic.List[object]]::new()

    # With the snapshot tag rule configured, an inventory collected without tag
    # data cannot prove that a VM is untagged. Skipping the backup is the only
    # safe choice: silently ignoring the operator's exclusion is not an option.
    $tagDataUnavailable = (-not [string]::IsNullOrWhiteSpace($snapshotTagName)) -and (-not [bool]$script:VCache.TagDataAvailable)

    $eligibilityStart = Get-Date
    foreach ($vm in @($script:VCache.VMs)) {
        $reasons = New-Object 'System.Collections.Generic.List[string]'

        # Tag exclusion comes first: a VM related to a tagged entity is not
        # eligible, and its own characteristics are not checked or reported.
        if ($tagDataUnavailable) {
            Add-NarvikReason -Reasons $reasons -Reason 'Tag assignments are unavailable while the snapshot tag rule is configured'
            [void]$nonEligible.Add([pscustomobject]@{
                VM      = $vm
                Reasons = @($reasons)
            })
            continue
        }

        $tagViolations = @()
        if (-not [string]::IsNullOrWhiteSpace($snapshotTagName)) {
            $tagViolations = @(Get-NarvikVmTagViolations -Vm $vm -TagName $snapshotTagName)
        }
        if ($tagViolations.Count -gt 0) {
            foreach ($violation in $tagViolations) {
                Add-NarvikReason -Reasons $reasons -Reason $violation
            }
            [void]$nonEligible.Add([pscustomobject]@{
                VM      = $vm
                Reasons = @($reasons)
            })
            continue
        }

        if ([string]$vm.Name -match $unsupportedNamePattern) {
            Add-NarvikReason -Reasons $reasons -Reason 'VM name contains characters not supported by the backup command'
            [void]$unsupportedNameCases.Add($vm)
        }

        # A VM without disks has no backup data worth protecting and no
        # datastore cluster association, so it can never be eligible.
        if (@($vm.Disks).Count -eq 0) {
            Add-NarvikReason -Reasons $reasons -Reason 'VM has no disks'
        }

        $vmDatastoreClusters = @($vm.DatastoreClusters)
        $managementClass = ''
        # Datastores used by the VM's disks that belong to no datastore cluster.
        $standaloneDatastores = New-Object 'System.Collections.Generic.List[string]'
        if ($vmDatastoreClusters.Count -ne 1) {
            if ($vmDatastoreClusters.Count -eq 0) {
                Add-NarvikReason -Reasons $reasons -Reason 'VM is not associated with any datastore cluster (exactly one is required)'
            }
            else {
                Add-NarvikReason -Reasons $reasons -Reason "VM is associated with $($vmDatastoreClusters.Count) datastore clusters ($($vmDatastoreClusters -join ', ')); exactly one is required"
            }
        }
        else {
            $datastoreClusterName = [string]$vmDatastoreClusters[0]
            $managementClass = Get-NarvikManagementClass -DatastoreClusterName $datastoreClusterName
            if ([string]::IsNullOrWhiteSpace($managementClass)) {
                Add-NarvikReason -Reasons $reasons -Reason "Datastore cluster '$datastoreClusterName' has no management class mapping in 'datastore_cluster_to_management_class'"
                [void]$managementClassCases.Add([pscustomobject]@{
                    VM               = $vm
                    DatastoreCluster = $datastoreClusterName
                })
            }
        }

        $vm.ManagementClass = $managementClass

        $invalidSizeDisks = [System.Collections.Generic.List[object]]::new()
        foreach ($disk in @($vm.Disks)) {
            if ($disk.RDM) {
                Add-NarvikReason -Reasons $reasons -Reason "RDM disk '$($disk.Label)'"
            }

            # Independent disks are exempt from the 1 MiB size rule.
            if ($disk.Independent) {
                continue
            }

            $capacityKb = 0L
            if ($disk.PSObject.Properties.Name -contains 'CapacityInKB') {
                try {
                    $capacityKb = [long]$disk.CapacityInKB
                }
                catch {
                    $capacityKb = 0L
                }
            }

            if (($capacityKb % 1024) -ne 0) {
                $roundedKb = Get-NarvikDiskRoundedCapacityKB -CapacityInKB $capacityKb
                Add-NarvikReason -Reasons $reasons -Reason "Disk '$($disk.Label)' size $capacityKb KiB is not a multiple of 1 MiB; corrected size is $roundedKb KiB"
                Add-NarvikReason -Reasons $reasons -Reason "To fix, run manually: $(Get-NarvikDiskFixCommand -VMName $vm.Name -DiskName $disk.Label -CapacityInKB $roundedKb)"
                [void]$invalidSizeDisks.Add($disk)
            }
        }

        if ($invalidSizeDisks.Count -gt 0) {
            [void]$diskSizeCases.Add([pscustomobject]@{
                VM    = $vm
                Disks = @($invalidSizeDisks)
            })
        }

        foreach ($disk in @($vm.Disks)) {
            $datastoreName = [string]$disk.Datastore
            if ([string]::IsNullOrWhiteSpace($datastoreName)) {
                Add-NarvikReason -Reasons $reasons -Reason "Unknown datastore for disk '$($disk.Label)'"
                continue
            }

            $datastoreType = [string]$disk.DatastoreType
            if (-not [string]::IsNullOrWhiteSpace($datastoreType) -and $datastoreType -ne 'VMFS') {
                Add-NarvikReason -Reasons $reasons -Reason "Disk '$($disk.Label)' is on datastore '$datastoreName' of type '$datastoreType'; only VMFS datastores are supported"
                continue
            }

            # A disk on a datastore that belongs to no datastore cluster breaks
            # the placement rule even when the other disks sit in one cluster.
            if ([string]::IsNullOrWhiteSpace([string]$disk.DatastoreCluster)) {
                Add-NarvikReason -Reasons $reasons -Reason "Disk '$($disk.Label)' is on datastore '$datastoreName' which is not in any datastore cluster"
                if (-not $standaloneDatastores.Contains($datastoreName)) {
                    [void]$standaloneDatastores.Add($datastoreName)
                }
            }
        }

        if ($vmDatastoreClusters.Count -ne 1 -or $standaloneDatastores.Count -gt 0) {
            [void]$datastoreClusterCases.Add([pscustomobject]@{
                VM                   = $vm
                DatastoreClusters    = $vmDatastoreClusters
                StandaloneDatastores = @($standaloneDatastores | Sort-Object)
            })
        }

        if ($reasons.Count -gt 0) {
            [void]$nonEligible.Add([pscustomobject]@{
                VM      = $vm
                Reasons = @($reasons)
            })
        }
        else {
            [void]$initialEligible.Add($vm)
        }
    }

    $duplicateCases = [System.Collections.Generic.List[object]]::new()
    $duplicateMorefs = @{}
    $nameGroups = @{}
    $nameGroupOrder = [System.Collections.Generic.List[string]]::new()
    foreach ($vm in $initialEligible) {
        $nameKey = ([string]$vm.Name).ToLowerInvariant()
        if (-not $nameGroups.ContainsKey($nameKey)) {
            $nameGroups[$nameKey] = [System.Collections.Generic.List[object]]::new()
            [void]$nameGroupOrder.Add($nameKey)
        }
        [void]$nameGroups[$nameKey].Add($vm)
    }

    foreach ($nameKey in $nameGroupOrder) {
        $groupVms = @($nameGroups[$nameKey])
        if ($groupVms.Count -lt 2) {
            continue
        }

        $duplicateName = [string]$groupVms[0].Name
        [void]$duplicateCases.Add([pscustomobject]@{
            Name = $duplicateName
            VMs  = $groupVms
        })

        foreach ($vm in $groupVms) {
            $duplicateMorefs[[string]$vm.MoRef] = $true
            $reason = "Duplicate VM name '$duplicateName' among eligible VMs (not supported)"
            [void]$nonEligible.Add([pscustomobject]@{
                VM      = $vm
                Reasons = @($reason)
            })
        }
    }

    $finalEligible = @($initialEligible | Where-Object { -not $duplicateMorefs.ContainsKey([string]$_.MoRef) })

    # Sorted once here; the scheduler only filters pending VMs in this order.
    # Higher cluster priority comes first, then higher resource pool priority,
    # then the full VM folder path (including the datacenter) and the name.
    $script:EligibleVMs = @($finalEligible | Sort-Object -Property @{ Expression = { [int]$_.ClusterPriority }; Descending = $true }, @{ Expression = { [int]$_.ResourcePoolPriority }; Descending = $true }, FolderPath, Name)
    $script:NonEligibleVMs = @($nonEligible)
    $script:DuplicateNameCases = @($duplicateCases)
    $script:UnsupportedNameCases = @($unsupportedNameCases)
    $script:DatastoreClusterCases = @($datastoreClusterCases)
    $script:ManagementClassCases = @($managementClassCases)
    $script:DiskSizeCases = @($diskSizeCases)

    $signatureParts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($entry in $script:NonEligibleVMs) {
        [void]$signatureParts.Add("$($entry.VM.Name)|$(@($entry.Reasons) -join ';')")
    }
    $signatureParts.Sort()
    $signature = $signatureParts -join "`n"

    if ($signature -ne $script:NonEligibleSignature) {
        foreach ($entry in $script:NonEligibleVMs) {
            Write-NarvikLog -Level INFO -Message "VM '$($entry.VM.Name)' is not eligible: $(@($entry.Reasons) -join '; ')."
        }
        Write-NarvikLog -Level INFO -Message "Eligibility updated: $(@($script:EligibleVMs).Count) VM(s) eligible, $(@($script:NonEligibleVMs).Count) non-eligible."
        $script:NonEligibleSignature = $signature
    }

    Write-NarvikMonitoringFiles

    $eligibilityMs = [math]::Round(((Get-Date) - $eligibilityStart).TotalMilliseconds)
    Write-NarvikLog -Level DEBUG -Message "Eligibility processing took $eligibilityMs ms."
    Write-NarvikLog -Level DEBUG -Message "Eligible VMs:"
    foreach ($vm in $script:EligibleVMs) {
        Write-NarvikLog -Level DEBUG -Message "$($vm.Name)"
    }

    $pendingVMs = @(Get-NarvikPendingVMs -Now (Get-Date))
    Write-NarvikLog -Level DEBUG -Message "Pending VMs:"
    foreach ($vm in $pendingVMs) {
        Write-NarvikLog -Level DEBUG -Message "$($vm.Name)"
    }

    if ($SendAlerts) {
        Send-NarvikDuplicateNameAlerts
        Send-NarvikInventoryRuleAlerts
        Send-NarvikDiskSizeAlerts
        Send-NarvikPriorityClusterAlerts
        Update-NarvikIndependentDiskControl -SendAlerts
    }
}

function Write-NarvikMonitoringFiles {
    $eligibleCount = @($script:EligibleVMs).Count
    $eligibleNames = @($script:EligibleVMs | ForEach-Object { [string]$_.Name })

    Write-NarvikAtomicText -Path (Join-Path $script:MonitoringDir 'eligible_count.txt') -Content ($eligibleCount.ToString() + "`r`n")
    Write-NarvikAtomicText -Path (Join-Path $script:MonitoringDir 'eligible_vms.txt') -Content (($eligibleNames -join "`r`n") + $(if ($eligibleNames.Count -gt 0) { "`r`n" } else { '' }))
}
