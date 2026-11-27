function Set-NarvikPowerCliCertificateAction {
    $action = 'Fail'
    if ($script:Config.vcenter_ignore_certificate) {
        $action = 'Ignore'
    }

    try {
        Set-PowerCLIConfiguration -Scope Session -InvalidCertificateAction $action -Confirm:$false -ErrorAction Stop | Out-Null
    }
    catch {
        try {
            Set-PowerCLIConfiguration -InvalidCertificateAction $action -Confirm:$false -ErrorAction Stop | Out-Null
        }
        catch {
            throw [System.Exception]::new("Could not set PowerCLI certificate action to '$action': $($_.Exception.Message)")
        }
    }
}

function Connect-NarvikVCenter {
    Set-NarvikPowerCliCertificateAction

    $password = Read-NarvikPasswordFile -Path $script:Config.vcenter_password_file
    if ([string]::IsNullOrEmpty($password)) {
        throw [System.Exception]::new("vCenter password file '$($script:Config.vcenter_password_file)' is empty.")
    }

    $secure = ConvertTo-SecureString -String $password -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential -ArgumentList $script:Config.vcenter_user, $secure

    $connection = Connect-VIServer -Server $script:Config.vcenter_server -Port $script:Config.vcenter_port -Credential $credential -ErrorAction Stop -WarningAction SilentlyContinue
    return $connection
}

function Disconnect-NarvikVCenter {
    try {
        Disconnect-VIServer -Server * -Confirm:$false -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null
    }
    catch {
    }
}

function Get-NarvikMoRefValue {
    param(
        $Object
    )

    # PowerCLI objects expose their identifier as '<type>-<moRef>' (for example
    # 'VirtualMachine-vm-1018'), and the *Id properties such as FolderId use
    # the same shape. The managed object reference is the part after the first
    # hyphen: it is the key shared by the inventory maps and the tag
    # assignments. Reading .Id also avoids the lazy full-object retrieval that
    # .ExtensionData triggers.
    if ($null -eq $Object) {
        return ''
    }

    if ($Object -is [string]) {
        $id = [string]$Object
    }
    else {
        $id = [string]$Object.Id
    }

    if ([string]::IsNullOrWhiteSpace($id)) {
        return ''
    }

    $separatorIndex = $id.IndexOf('-')
    if ($separatorIndex -lt 0 -or $separatorIndex -eq ($id.Length - 1)) {
        return ''
    }

    return $id.Substring($separatorIndex + 1)
}

function Get-NarvikFolderPath {
    param(
        [string]$FolderId,
        [hashtable]$FolderMap,
        [hashtable]$DatacenterMap = @{}
    )

    if ([string]::IsNullOrWhiteSpace($FolderId)) {
        return ''
    }

    $parts = New-Object 'System.Collections.Generic.List[string]'
    $seen = @{}
    $current = $FolderId

    while (-not [string]::IsNullOrWhiteSpace($current) -and -not $seen.ContainsKey($current)) {
        $seen[$current] = $true

        if ($FolderMap.ContainsKey($current)) {
            $folder = $FolderMap[$current]
            $name = [string]$folder.Name
            if (-not [string]::IsNullOrWhiteSpace($name) -and @('vm', 'Datacenters', 'VMs') -notcontains $name) {
                $parts.Insert(0, $name)
            }

            # ParentId is the plain identifier of the parent. Reading Parent returns
            # the parent object, which PowerCLI loads lazily (one vCenter round trip
            # per folder); both give the same MoRef.
            $current = Get-NarvikMoRefValue -Object ([string]$folder.ParentId)
            continue
        }

        # The VM folder tree stops at the datacenter. Include the datacenter
        # name as the first component of the full path.
        if ($DatacenterMap.ContainsKey($current)) {
            $datacenterName = [string]$DatacenterMap[$current]
            if (-not [string]::IsNullOrWhiteSpace($datacenterName)) {
                $parts.Insert(0, $datacenterName)
            }
        }

        break
    }

    return ($parts -join '/')
}

function Get-NarvikSnapshotTagRuleName {
    if ($null -eq $script:Config) {
        return ''
    }

    return ([string]$script:Config.dont_backup_by_snapshot_tag_name).Trim()
}

function Write-NarvikTagRuleError {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    # The collection is retried about once a minute while the rule stays broken,
    # so the error is repeated at most once an hour and kept at DEBUG otherwise.
    $now = Get-Date
    if ($script:LastTagRuleErrorLogged -ne [datetime]::MinValue -and ($now - $script:LastTagRuleErrorLogged).TotalHours -lt 1.0) {
        Write-NarvikLog -Level DEBUG -Message $Message
        return
    }

    $script:LastTagRuleErrorLogged = $now
    Write-NarvikLog -Level ERROR -Message $Message
}

function Test-NarvikVCacheTagRuleCurrent {
    param(
        $Cache
    )

    if ($null -eq $Cache) {
        return $false
    }

    $tagRuleName = Get-NarvikSnapshotTagRuleName

    $cachedRuleName = ''
    if ($null -ne $Cache.PSObject.Properties['TagRuleName']) {
        $cachedRuleName = [string]$Cache.TagRuleName
    }

    # Enabling, changing or clearing the rule makes the cache stale: with the
    # rule configured a cache collected with another tag (or with no tag data,
    # as older caches are) cannot say whether that tag is present, and clearing
    # the rule has to release an inventory whose tag data was discarded.
    if ($cachedRuleName -ne $tagRuleName) {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($tagRuleName)) {
        return $true
    }

    return [bool]$Cache.TagDataAvailable
}

function Test-NarvikSiteRecoveryPlaceholder {
    param(
        $VMConfig
    )

    # VMware Live Site Recovery (formerly Site Recovery Manager) creates placeholder
    # VMs at the recovery site. They are marked in vCenter through Config.ManagedBy
    # with an extension key starting with 'com.vmware.vcDr' and type 'placeholderVm'.
    if ($null -eq $VMConfig) {
        return $false
    }

    $managedBy = $VMConfig.ManagedBy
    if ($null -eq $managedBy) {
        return $false
    }

    if ([string]$managedBy.ExtensionKey -like 'com.vmware.vcDr*' -and [string]$managedBy.Type -ieq 'placeholderVm') {
        return $true
    }

    return $false
}

function Get-NarvikTaggedMoRefs {
    param(
        [object[]]$Vms = @(),
        [object[]]$Datastores = @(),
        [object[]]$DatastoreClusters = @(),
        [object[]]$Folders = @(),
        [object[]]$Hosts = @(),
        [object[]]$ResourcePools = @(),
        [object[]]$Clusters = @(),
        [object[]]$TagViews = @()
    )

    $taggedMoRefs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if (@($TagViews).Count -eq 0) {
        return ,$taggedMoRefs
    }

    # One Get-TagAssignment call per entity type, with -Entity, instead of one
    # global query that returns every assignment of the tag. The entities were
    # already collected by the inventory cmdlets, so they are passed as they
    # are: no conversion is needed and only the collected objects are queried.
    $typeSets = @(
        [pscustomobject]@{ Label = 'VM'; Entities = @($Vms) },
        [pscustomobject]@{ Label = 'Datastore'; Entities = @($Datastores) },
        [pscustomobject]@{ Label = 'Datastore cluster'; Entities = @($DatastoreClusters) },
        [pscustomobject]@{ Label = 'Folder'; Entities = @($Folders) },
        [pscustomobject]@{ Label = 'Host'; Entities = @($Hosts) },
        [pscustomobject]@{ Label = 'Resource pool'; Entities = @($ResourcePools) },
        [pscustomobject]@{ Label = 'Cluster'; Entities = @($Clusters) }
    )

    $tagLabel = 'the snapshot tag rule'
    if ($TagViews.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$TagViews[0].Name)) {
        $tagLabel = [string]$TagViews[0].Name
    }

    foreach ($typeSet in $typeSets) {
        $entities = @($typeSet.Entities)
        if ($entities.Count -eq 0) {
            continue
        }

        Write-NarvikLog -Level INFO -Message "Collecting assignments of tag '$tagLabel' for $($entities.Count) $($typeSet.Label) object(s) (Get-TagAssignment)."
        $typeTimer = [System.Diagnostics.Stopwatch]::StartNew()
        $assignments = @(Get-TagAssignment -Entity $entities -Tag $TagViews -ErrorAction Stop | Where-Object { $null -ne $_ })
        Write-NarvikLog -Level DEBUG -Message "Get-TagAssignment for $($typeSet.Label): $($assignments.Count) assignment(s) for $($entities.Count) object(s) in $($typeTimer.ElapsedMilliseconds) ms."
        foreach ($assignment in $assignments) {
            if ($null -eq $assignment.Entity) {
                continue
            }

            $morefValue = Get-NarvikMoRefValue -Object $assignment.Entity
            if (-not [string]::IsNullOrWhiteSpace($morefValue)) {
                [void]$taggedMoRefs.Add($morefValue)
            }
        }
    }

    return ,$taggedMoRefs
}

function Get-NarvikVCenterData {
    $collectStart = Get-Date
    $collectionTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $connection = $null

    try {
        $connection = Connect-NarvikVCenter
        Write-NarvikLog -Level DEBUG -Message "vCenter connected in $($collectionTimer.ElapsedMilliseconds) ms."
        $stepTimer = [System.Diagnostics.Stopwatch]::StartNew()

        # One inventory cmdlet per entity type, instead of a single virtual
        # machine view: the collected objects are also what Get-TagAssignment
        # receives later. Get-VM does not return templates, so Get-Template is
        # read as well and both keep their current place in the inventory.
        Write-NarvikLog -Level INFO -Message 'Collecting vCenter inventory: virtual machines (Get-VM).'
        $vmObjects = @(Get-VM -ErrorAction Stop | Where-Object { $null -ne $_ })
        Write-NarvikLog -Level DEBUG -Message "Get-VM returned $($vmObjects.Count) object(s) in $($stepTimer.ElapsedMilliseconds) ms."
        $stepTimer.Restart()
        Write-NarvikLog -Level INFO -Message 'Collecting vCenter inventory: templates (Get-Template).'
        $templateObjects = @(Get-Template -ErrorAction Stop | Where-Object { $null -ne $_ })
        Write-NarvikLog -Level DEBUG -Message "Get-Template returned $($templateObjects.Count) object(s) in $($stepTimer.ElapsedMilliseconds) ms."
        $stepTimer.Restart()
        Write-NarvikLog -Level INFO -Message 'Collecting vCenter inventory: datastores (Get-Datastore).'
        $datastoreObjects = @(Get-Datastore -ErrorAction Stop | Where-Object { $null -ne $_ })
        Write-NarvikLog -Level DEBUG -Message "Get-Datastore returned $($datastoreObjects.Count) object(s) in $($stepTimer.ElapsedMilliseconds) ms."
        $stepTimer.Restart()
        Write-NarvikLog -Level INFO -Message 'Collecting vCenter inventory: datastore clusters (Get-DatastoreCluster).'
        $datastoreClusterObjects = @(Get-DatastoreCluster -ErrorAction Stop | Where-Object { $null -ne $_ })
        Write-NarvikLog -Level DEBUG -Message "Get-DatastoreCluster returned $($datastoreClusterObjects.Count) object(s) in $($stepTimer.ElapsedMilliseconds) ms."
        $stepTimer.Restart()
        # Only VM folders are relevant: they build the VM folder path and are
        # the only folder scope of the opt-out rule. Datastore, host, network
        # and other folder types are never read.
        Write-NarvikLog -Level INFO -Message 'Collecting vCenter inventory: VM folders (Get-Folder -Type VM).'
        $folderObjects = @(Get-Folder -Type VM -ErrorAction Stop | Where-Object { $null -ne $_ })
        Write-NarvikLog -Level DEBUG -Message "Get-Folder -Type VM returned $($folderObjects.Count) object(s) in $($stepTimer.ElapsedMilliseconds) ms."
        $stepTimer.Restart()
        Write-NarvikLog -Level INFO -Message 'Collecting vCenter inventory: datacenters (Get-Datacenter).'
        $datacenterObjects = @(Get-Datacenter -ErrorAction Stop | Where-Object { $null -ne $_ })
        Write-NarvikLog -Level DEBUG -Message "Get-Datacenter returned $($datacenterObjects.Count) object(s) in $($stepTimer.ElapsedMilliseconds) ms."
        $stepTimer.Restart()
        Write-NarvikLog -Level INFO -Message 'Collecting vCenter inventory: hosts (Get-VMHost).'
        $hostObjects = @(Get-VMHost -ErrorAction Stop | Where-Object { $null -ne $_ })
        Write-NarvikLog -Level DEBUG -Message "Get-VMHost returned $($hostObjects.Count) object(s) in $($stepTimer.ElapsedMilliseconds) ms."
        $stepTimer.Restart()
        Write-NarvikLog -Level INFO -Message 'Collecting vCenter inventory: resource pools (Get-ResourcePool).'
        $resourcePoolObjects = @(Get-ResourcePool -ErrorAction Stop | Where-Object { $null -ne $_ })
        Write-NarvikLog -Level DEBUG -Message "Get-ResourcePool returned $($resourcePoolObjects.Count) object(s) in $($stepTimer.ElapsedMilliseconds) ms."
        $stepTimer.Restart()
        Write-NarvikLog -Level INFO -Message 'Collecting vCenter inventory: clusters (Get-Cluster).'
        $clusterObjects = @(Get-Cluster -ErrorAction Stop | Where-Object { $null -ne $_ })
        Write-NarvikLog -Level DEBUG -Message "Get-Cluster returned $($clusterObjects.Count) object(s) in $($stepTimer.ElapsedMilliseconds) ms."
        $stepTimer.Restart()

        # Get-HardDisk is issued once per virtual machine collection and once
        # per template collection, and the disks are grouped by their parent.
        $diskObjects = [System.Collections.Generic.List[object]]::new()
        if ($vmObjects.Count -gt 0) {
            Write-NarvikLog -Level INFO -Message "Collecting virtual machine disks (Get-HardDisk -VM) for $($vmObjects.Count) virtual machine(s)."
            $vmDisks = @(Get-HardDisk -VM $vmObjects -ErrorAction Stop)
            Write-NarvikLog -Level DEBUG -Message "Get-HardDisk -VM returned $($vmDisks.Count) disk(s) in $($stepTimer.ElapsedMilliseconds) ms."
            $stepTimer.Restart()
            foreach ($disk in $vmDisks) {
                if ($null -ne $disk) {
                    [void]$diskObjects.Add($disk)
                }
            }
        }
        if ($templateObjects.Count -gt 0) {
            Write-NarvikLog -Level INFO -Message "Collecting template disks (Get-HardDisk -Template) for $($templateObjects.Count) template(s)."
            $templateDisks = @(Get-HardDisk -Template $templateObjects -ErrorAction Stop)
            Write-NarvikLog -Level DEBUG -Message "Get-HardDisk -Template returned $($templateDisks.Count) disk(s) in $($stepTimer.ElapsedMilliseconds) ms."
            $stepTimer.Restart()
            foreach ($disk in $templateDisks) {
                if ($null -ne $disk) {
                    [void]$diskObjects.Add($disk)
                }
            }
        }

        $disksByParent = @{}
        $disksWithoutParent = 0
        foreach ($disk in $diskObjects) {
            $parentId = Get-NarvikMoRefValue -Object $disk.ParentId
            if ([string]::IsNullOrWhiteSpace($parentId)) {
                $disksWithoutParent++
                continue
            }
            if (-not $disksByParent.ContainsKey($parentId)) {
                $disksByParent[$parentId] = [System.Collections.Generic.List[object]]::new()
            }
            [void]$disksByParent[$parentId].Add($disk)
        }
        Write-NarvikLog -Level DEBUG -Message "Grouped $($diskObjects.Count) disk(s) by parent into $($disksByParent.Count) parent(s) in $($stepTimer.ElapsedMilliseconds) ms ($disksWithoutParent without parent)."
        $stepTimer.Restart()

        $readMs = $collectionTimer.ElapsedMilliseconds

        $datastoreMap = @{}
        $vmfsDatastores = [System.Collections.Generic.List[object]]::new()
        $ignoredDatastoreTypes = @{}
        foreach ($datastore in $datastoreObjects) {
            $datastoreId = Get-NarvikMoRefValue -Object $datastore
            $datastoreType = [string]$datastore.Type

            $datastoreMap[$datastoreId] = [pscustomobject]@{
                Name = [string]$datastore.Name
                Type = $datastoreType
            }

            if ($datastoreType -eq 'VMFS') {
                [void]$vmfsDatastores.Add($datastore)
            }
            else {
                if (-not $ignoredDatastoreTypes.ContainsKey($datastoreType)) {
                    $ignoredDatastoreTypes[$datastoreType] = 0
                }
                $ignoredDatastoreTypes[$datastoreType] = [int]$ignoredDatastoreTypes[$datastoreType] + 1
            }
        }

        if ($ignoredDatastoreTypes.Count -gt 0) {
            $ignoredParts = New-Object 'System.Collections.Generic.List[string]'
            foreach ($ignoredType in @($ignoredDatastoreTypes.Keys | Sort-Object)) {
                [void]$ignoredParts.Add("$ignoredType=$($ignoredDatastoreTypes[$ignoredType])")
            }
            Write-NarvikLog -Level DEBUG -Message "Ignored non-VMFS datastore(s) for tag collection and inventory listing: $($ignoredParts -join ', ')."
        }

        Write-NarvikLog -Level DEBUG -Message "Datastore classification of $($datastoreObjects.Count) datastore(s) took $($stepTimer.ElapsedMilliseconds) ms."
        $stepTimer.Restart()
        $collectionTimer.Restart()

        # Tag assignments are read only for the tag named by the snapshot tag
        # rule, and only while that rule is configured: the session needs read
        # on that one tag instead of on the whole tag catalog. Assignments are
        # queried per entity type with -Entity, limited to the entities already
        # collected. With the rule configured any failure aborts the collection,
        # so a cached inventory without tags can never be mistaken for an
        # inventory of untagged VMs.
        $tagRuleName = Get-NarvikSnapshotTagRuleName
        $tagDataAvailable = $true
        $taggedMoRefs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ([string]::IsNullOrWhiteSpace($tagRuleName)) {
            Write-NarvikLog -Level DEBUG -Message 'Snapshot tag rule is not configured; vCenter tag assignments were not collected.'
        }
        else {
            $tagViews = @()
            $tagLookupErrors = @()
            try {
                Write-NarvikLog -Level INFO -Message "Collecting vCenter tag '$tagRuleName' (Get-Tag)."
                $tagViews = @(Get-Tag -Name $tagRuleName -ErrorAction SilentlyContinue -ErrorVariable tagLookupErrors | Where-Object { $null -ne $_ })
                Write-NarvikLog -Level DEBUG -Message "Get-Tag returned $($tagViews.Count) view(s) in $($stepTimer.ElapsedMilliseconds) ms."
                $stepTimer.Restart()
            }
            catch {
                $script:TagRuleFailure = $true
                $message = "vCenter tag '$tagRuleName' could not be read while the snapshot tag rule is configured; backups are blocked: $($_.Exception.Message)"
                Write-NarvikTagRuleError -Message $message
                throw [System.Exception]::new($message)
            }

            if ($tagViews.Count -eq 0) {
                $detail = ''
                if (@($tagLookupErrors).Count -gt 0) {
                    $detail = ": $([string]$tagLookupErrors[0])"
                }
                $script:TagRuleFailure = $true
                $message = "Snapshot tag rule is configured but vCenter has no readable tag named '$tagRuleName'; backups are blocked until the tag exists or the rule is cleared$detail"
                Write-NarvikTagRuleError -Message $message
                throw [System.Exception]::new($message)
            }

            try {
                $taggedMoRefs = Get-NarvikTaggedMoRefs -Vms (@($vmObjects) + @($templateObjects)) -Datastores $vmfsDatastores -DatastoreClusters $datastoreClusterObjects -Folders $folderObjects -Hosts $hostObjects -ResourcePools $resourcePoolObjects -Clusters $clusterObjects -TagViews $tagViews
                Write-NarvikLog -Level DEBUG -Message "Tag assignment lookup finished in $($stepTimer.ElapsedMilliseconds) ms."
                $stepTimer.Restart()
            }
            catch {
                $script:TagRuleFailure = $true
                $message = "vCenter assignments of tag '$tagRuleName' could not be read while the snapshot tag rule is configured; backups are blocked: $($_.Exception.Message)"
                Write-NarvikTagRuleError -Message $message
                throw [System.Exception]::new($message)
            }

            $script:LastTagRuleErrorLogged = [datetime]::MinValue
            Write-NarvikLog -Level DEBUG -Message "Collected tag data for $($taggedMoRefs.Count) tagged object(s) of tag '$tagRuleName'."
        }

        $tagReadMs = $collectionTimer.ElapsedMilliseconds
        $collectionTimer.Restart()
        # Times every step after the tag collection, so the gap before the first
        # VM Notes line can be split into its parts in the DEBUG log.
        $postTagTimer = [System.Diagnostics.Stopwatch]::StartNew()

        $folderMap = @{}
        foreach ($folder in $folderObjects) {
            $folderMap[(Get-NarvikMoRefValue -Object $folder)] = $folder
        }

        $datacenterMap = @{}
        foreach ($datacenter in $datacenterObjects) {
            $datacenterMap[(Get-NarvikMoRefValue -Object $datacenter)] = [string]$datacenter.Name
        }

        $hostMap = @{}
        $hostParentMap = @{}
        foreach ($hostObject in $hostObjects) {
            $hostId = Get-NarvikMoRefValue -Object $hostObject
            $hostMap[$hostId] = [string]$hostObject.Name
            $parentId = Get-NarvikMoRefValue -Object $hostObject.Parent
            if (-not [string]::IsNullOrWhiteSpace($parentId)) {
                $hostParentMap[$hostId] = $parentId
            }
        }

        $resourcePoolMap = @{}
        foreach ($resourcePool in $resourcePoolObjects) {
            $resourcePoolMap[(Get-NarvikMoRefValue -Object $resourcePool)] = [string]$resourcePool.Name
        }

        # A host's parent is a real cluster only when its MoRef is in the
        # Get-Cluster result; standalone hosts sit under a ComputeResource,
        # where the cluster tag rule never applies. All compute clusters are
        # read, not only those that host a VM, so a configured name is reported
        # as unknown only when no cluster with that name exists at all.
        $clusterNames = @{}
        $environmentClusterNames = @{}
        foreach ($clusterObject in $clusterObjects) {
            $clusterNames[(Get-NarvikMoRefValue -Object $clusterObject)] = [string]$clusterObject.Name
            $environmentClusterNames[[string]$clusterObject.Name] = $true
        }

        # Map each resource pool to the cluster that owns it, following parent
        # resource pools when the pool is nested. The priority entries name the
        # cluster explicitly, so a missing cluster and a missing resource pool
        # are reported separately.
        $resourcePoolParentMap = @{}
        foreach ($resourcePool in $resourcePoolObjects) {
            $resourcePoolParentMap[(Get-NarvikMoRefValue -Object $resourcePool)] = Get-NarvikMoRefValue -Object $resourcePool.ParentId
        }

        $resourcePoolsByCluster = @{}
        foreach ($resourcePool in $resourcePoolObjects) {
            $poolId = Get-NarvikMoRefValue -Object $resourcePool
            $ownerClusterId = ''
            $cursorId = $poolId
            $guard = 0
            while (-not [string]::IsNullOrWhiteSpace($cursorId) -and $guard -lt 100) {
                $guard++
                $parentId = ''
                if ($resourcePoolParentMap.ContainsKey($cursorId)) {
                    $parentId = [string]$resourcePoolParentMap[$cursorId]
                }
                if ([string]::IsNullOrWhiteSpace($parentId)) {
                    break
                }
                if ($clusterNames.ContainsKey($parentId)) {
                    $ownerClusterId = $parentId
                    break
                }
                if (-not $resourcePoolParentMap.ContainsKey($parentId)) {
                    break
                }
                $cursorId = $parentId
            }

            if ([string]::IsNullOrWhiteSpace($ownerClusterId)) {
                continue
            }

            $ownerClusterName = [string]$clusterNames[$ownerClusterId]
            $ownerClusterKey = $ownerClusterName.ToLowerInvariant()
            if (-not $resourcePoolsByCluster.ContainsKey($ownerClusterKey)) {
                $resourcePoolsByCluster[$ownerClusterKey] = @{}
            }
            $resourcePoolsByCluster[$ownerClusterKey][([string]$resourcePool.Name).ToLowerInvariant()] = $true
        }

        # Configured names that do not exist are not a collection failure: the
        # entry simply does not apply, is logged here and reported by email.
        $unknownPriorityEntries = New-Object 'System.Collections.Generic.List[object]'
        $unknownPriorityKeys = @{}
        if ($null -ne $script:Config) {
            if ($null -ne $script:Config.priority_clusters) {
                foreach ($clusterKey in @($script:Config.priority_clusters.Keys)) {
                    $configured = $script:Config.priority_clusters[$clusterKey]
                    $configuredName = [string]$configured.cluster
                    if ([string]::IsNullOrWhiteSpace($configuredName)) {
                        continue
                    }
                    if ($environmentClusterNames.ContainsKey($configuredName)) {
                        continue
                    }

                    $entryKey = 'priority_clusters|' + $configuredName.ToLowerInvariant()
                    if ($unknownPriorityKeys.ContainsKey($entryKey)) {
                        continue
                    }
                    $unknownPriorityKeys[$entryKey] = $true
                    [void]$unknownPriorityEntries.Add([pscustomobject]@{
                        Source       = 'priority_clusters'
                        Cluster      = $configuredName
                        ResourcePool = ''
                        Key          = $entryKey
                        Message      = "Cluster '$configuredName' from 'priority_clusters' was not found in the environment."
                    })
                }
            }

            if ($null -ne $script:Config.priority_resource_pools) {
                foreach ($clusterKey in @($script:Config.priority_resource_pools.Keys)) {
                    $clusterPools = $script:Config.priority_resource_pools[$clusterKey]
                    foreach ($resourcePoolKey in @($clusterPools.Keys)) {
                        $configured = $clusterPools[$resourcePoolKey]
                        $configuredCluster = [string]$configured.cluster
                        $configuredPool = [string]$configured.resource_pool
                        if ([string]::IsNullOrWhiteSpace($configuredCluster) -or [string]::IsNullOrWhiteSpace($configuredPool)) {
                            continue
                        }

                        $entryKey = 'priority_resource_pools|' + $configuredCluster.ToLowerInvariant() + '|' + $configuredPool.ToLowerInvariant()
                        if ($unknownPriorityKeys.ContainsKey($entryKey)) {
                            continue
                        }

                        if (-not $environmentClusterNames.ContainsKey($configuredCluster)) {
                            $unknownPriorityKeys[$entryKey] = $true
                            [void]$unknownPriorityEntries.Add([pscustomobject]@{
                                Source       = 'priority_resource_pools'
                                Cluster      = $configuredCluster
                                ResourcePool = $configuredPool
                                Key          = $entryKey
                                Message      = "Cluster '$configuredCluster' from 'priority_resource_pools' was not found in the environment."
                            })
                            continue
                        }

                        $clusterKeyForPool = $configuredCluster.ToLowerInvariant()
                        if (-not $resourcePoolsByCluster.ContainsKey($clusterKeyForPool) -or -not $resourcePoolsByCluster[$clusterKeyForPool].ContainsKey($configuredPool.ToLowerInvariant())) {
                            $unknownPriorityKeys[$entryKey] = $true
                            [void]$unknownPriorityEntries.Add([pscustomobject]@{
                                Source       = 'priority_resource_pools'
                                Cluster      = $configuredCluster
                                ResourcePool = $configuredPool
                                Key          = $entryKey
                                Message      = "Resource pool '$configuredPool' in cluster '$configuredCluster' from 'priority_resource_pools' was not found in the environment."
                            })
                        }
                    }
                }
            }

            if ($null -ne $script:Config.cluster_max_threads) {
                foreach ($clusterKey in @($script:Config.cluster_max_threads.Keys)) {
                    $configured = $script:Config.cluster_max_threads[$clusterKey]
                    $configuredName = [string]$configured.cluster
                    if ([string]::IsNullOrWhiteSpace($configuredName)) {
                        continue
                    }
                    if ($environmentClusterNames.ContainsKey($configuredName)) {
                        continue
                    }

                    $entryKey = 'cluster_max_threads|' + $configuredName.ToLowerInvariant()
                    if ($unknownPriorityKeys.ContainsKey($entryKey)) {
                        continue
                    }
                    $unknownPriorityKeys[$entryKey] = $true
                    [void]$unknownPriorityEntries.Add([pscustomobject]@{
                        Source       = 'cluster_max_threads'
                        Cluster      = $configuredName
                        ResourcePool = ''
                        Key          = $entryKey
                        Message      = "Cluster '$configuredName' from 'cluster_max_threads' was not found in the environment."
                    })
                }
            }
        }

        foreach ($unknownEntry in $unknownPriorityEntries) {
            Write-NarvikLog -Level WARNING -Message ([string]$unknownEntry.Message)
        }
        Write-NarvikLog -Level DEBUG -Message "Host, cluster and resource pool maps built in $($postTagTimer.ElapsedMilliseconds) ms."

        # Datastore name -> MoRef. Disks name their datastore in Filename
        # ('[name] folder/disk.vmdk'), so this map resolves it without reading
        # each disk's backing. A name shared by two datastores is ambiguous and
        # resolves to nothing, so its disks are reported as unknown datastores.
        $datastoreIdByName = @{}
        $ambiguousDatastoreNames = @{}
        foreach ($datastore in $datastoreObjects) {
            $datastoreName = [string]$datastore.Name
            $datastoreIdValue = Get-NarvikMoRefValue -Object $datastore
            if ($datastoreIdByName.ContainsKey($datastoreName) -and $datastoreIdByName[$datastoreName] -ne $datastoreIdValue) {
                if (-not $ambiguousDatastoreNames.ContainsKey($datastoreName)) {
                    $ambiguousDatastoreNames[$datastoreName] = $true
                    Write-NarvikLog -Level WARNING -Message "Datastore name '$datastoreName' is used by more than one datastore; disks on it are treated as unknown datastore."
                }
                $datastoreIdByName[$datastoreName] = ''
            }
            else {
                $datastoreIdByName[$datastoreName] = $datastoreIdValue
            }
        }

        # One batched read for all datastore clusters: their member datastores.
        # Replaces one ExtensionData round trip per cluster.
        $podChildren = @{}
        if ($datastoreClusterObjects.Count -gt 0) {
            foreach ($podView in @(Get-View -ViewType StoragePod -Property ChildEntity -ErrorAction Stop)) {
                $podChildren[[string]$podView.MoRef.Value] = @($podView.ChildEntity | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.Value })
            }
        }

        $podByDatastore = @{}
        foreach ($pod in $datastoreClusterObjects) {
            $podId = Get-NarvikMoRefValue -Object $pod
            foreach ($childId in @($podChildren[$podId] | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
                $podByDatastore[$childId] = [pscustomobject]@{
                    Name  = [string]$pod.Name
                    MoRef = $podId
                }
            }
        }

        $datastores = [System.Collections.Generic.List[object]]::new()
        foreach ($datastore in $vmfsDatastores) {
            $datastoreId = Get-NarvikMoRefValue -Object $datastore
            $datastoreTags = @()
            if ($taggedMoRefs.Contains($datastoreId)) {
                $datastoreTags = @($tagRuleName)
            }

            [void]$datastores.Add([pscustomobject]@{
                Name  = [string]$datastore.Name
                MoRef = $datastoreId
                Tags  = $datastoreTags
            })
        }

        $datastoreClusters = [System.Collections.Generic.List[object]]::new()
        foreach ($pod in $datastoreClusterObjects) {
            $memberNames = New-Object 'System.Collections.Generic.List[string]'
            $podId = Get-NarvikMoRefValue -Object $pod
            foreach ($childId in @($podChildren[$podId] | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
                if ($datastoreMap.ContainsKey($childId)) {
                    $member = $datastoreMap[$childId]
                    if ($member.Type -eq 'VMFS') {
                        [void]$memberNames.Add([string]$member.Name)
                    }
                }
            }

            $podTags = @()
            if ($taggedMoRefs.Contains($podId)) {
                $podTags = @($tagRuleName)
            }

            [void]$datastoreClusters.Add([pscustomobject]@{
                Name       = [string]$pod.Name
                MoRef      = $podId
                Tags       = $podTags
                Datastores = @($memberNames)
            })
        }

        Write-NarvikLog -Level DEBUG -Message "Datastore clusters mapped in $($postTagTimer.ElapsedMilliseconds) ms ($($datastoreClusterObjects.Count) cluster(s))."
        # One batched read for every VM and template (Get-View returns both): the
        # placeholder flag (Config.ManagedBy), the template Notes (Config.Annotation)
        # and the template resource pool. Replaces one ExtensionData round trip per
        # object, which was the slow part of the inventory.
        # Config.Name is always set, so vCenter always returns the config object.
        # Without it, a VM with no ManagedBy and no Annotation comes back with
        # Config = null (it was skipped as "no configuration data").
        $viewTimer = [System.Diagnostics.Stopwatch]::StartNew()
        $vmViews = @{}
        foreach ($view in @(Get-View -ViewType VirtualMachine -Property 'Name', 'Config.Name', 'Config.ManagedBy', 'Config.Annotation', 'ResourcePool' -ErrorAction Stop)) {
            $vmViews[[string]$view.MoRef.Value] = $view
        }
        Write-NarvikLog -Level DEBUG -Message "Get-View (VirtualMachine) returned $($vmViews.Count) view(s) in $($viewTimer.ElapsedMilliseconds) ms."

        $vmCandidates = [System.Collections.Generic.List[object]]::new()
        $candidateTimer = [System.Diagnostics.Stopwatch]::StartNew()
        foreach ($vm in $vmObjects) {
            $vmId = Get-NarvikMoRefValue -Object $vm
            $config = $null
            if ($vmViews.ContainsKey($vmId)) {
                $config = $vmViews[$vmId].Config
            }

            # The VM object already answered Notes, FolderId, ResourcePoolId and
            # VMHostId during the inventory reads; only Config needs the extra
            # retrieval, and it is reused by the placeholder check.
            $vmDisks = @()
            if ($disksByParent.ContainsKey($vmId)) {
                $vmDisks = @($disksByParent[$vmId])
            }

            [void]$vmCandidates.Add([pscustomobject]@{
                Name           = [string]$vm.Name
                MoRef          = $vmId
                Notes          = [string]$vm.Notes
                FolderId       = Get-NarvikMoRefValue -Object $vm.FolderId
                ResourcePoolId = Get-NarvikMoRefValue -Object $vm.ResourcePoolId
                HostId         = Get-NarvikMoRefValue -Object $vm.VMHostId
                Config         = $config
                Disks          = $vmDisks
            })
        }
        Write-NarvikLog -Level DEBUG -Message "VM candidates read: $($vmObjects.Count) VM(s) in $($candidateTimer.ElapsedMilliseconds) ms (from Get-View)."
        $candidateTimer.Restart()

        # A template has no V1 Notes or resource pool properties, so both come
        # from its view. Templates never run on a host, which keeps the host and
        # cluster rules from applying to them.
        foreach ($template in $templateObjects) {
            $templateId = Get-NarvikMoRefValue -Object $template
            $config = $null
            $templateView = $null
            if ($vmViews.ContainsKey($templateId)) {
                $templateView = $vmViews[$templateId]
                $config = $templateView.Config
            }

            $notes = ''
            if ($null -ne $config -and $null -ne $config.Annotation) {
                $notes = [string]$config.Annotation
            }

            $resourcePoolId = ''
            if ($null -ne $templateView -and $null -ne $templateView.ResourcePool) {
                $resourcePoolId = [string]$templateView.ResourcePool.Value
            }

            $templateDisks = @()
            if ($disksByParent.ContainsKey($templateId)) {
                $templateDisks = @($disksByParent[$templateId])
            }

            [void]$vmCandidates.Add([pscustomobject]@{
                Name           = [string]$template.Name
                MoRef          = $templateId
                Notes          = $notes
                FolderId       = Get-NarvikMoRefValue -Object $template.FolderId
                ResourcePoolId = $resourcePoolId
                HostId         = ''
                Config         = $config
                Disks          = $templateDisks
            })
        }
        Write-NarvikLog -Level DEBUG -Message "Template candidates read: $($templateObjects.Count) template(s) in $($candidateTimer.ElapsedMilliseconds) ms (from Get-View)."

        $vms = [System.Collections.Generic.List[object]]::new()
        $folderPathCache = @{}
        $notesParseWarnings = 0
        $lastFullChanged = $false

        # Last incremental values already known from the previous snapshot (the
        # snapshot still in $script:VCache during this call). A Notes timestamp
        # only replaces them when it is newer.
        $knownLastBackupByName = @{}
        if ($null -ne $script:VCache) {
            foreach ($knownVm in @($script:VCache.VMs)) {
                if ($null -ne $knownVm -and $null -ne $knownVm.LastBackup) {
                    $knownLastBackupByName[[string]$knownVm.Name] = $knownVm.LastBackup
                }
            }
        }

        Write-NarvikLog -Level DEBUG -Message "Starting VM processing for $($vmCandidates.Count) candidate(s) after $($postTagTimer.ElapsedMilliseconds) ms."
        $vmProcessTimer = [System.Diagnostics.Stopwatch]::StartNew()
        $diskTimer = [System.Diagnostics.Stopwatch]::new()
        $vmProcessed = 0
        foreach ($vmCandidate in $vmCandidates) {
            $vmProcessed++

            if ($null -eq $vmCandidate.Config) {
                Write-NarvikLog -Level DEBUG -Message "VM '$([string]$vmCandidate.Name)' has no configuration data; skipped."
                continue
            }

            # VMware Live Site Recovery placeholders are ignored silently. Templates are
            # kept in the inventory and remain subject to the normal eligibility rules.
            if (Test-NarvikSiteRecoveryPlaceholder -VMConfig $vmCandidate.Config) {
                continue
            }

            $vmName = [string]$vmCandidate.Name
            if ([string]::IsNullOrWhiteSpace($vmName)) {
                Write-NarvikLog -Level DEBUG -Message 'A VM without a name was skipped during inventory collection.'
                continue
            }

            $vmMoref = [string]$vmCandidate.MoRef
            $vmTags = @()
            if ($taggedMoRefs.Contains($vmMoref)) {
                $vmTags = @($tagRuleName)
            }

            $folderId = [string]$vmCandidate.FolderId
            $folderName = ''
            $folderTags = @()
            if (-not [string]::IsNullOrWhiteSpace($folderId) -and $folderMap.ContainsKey($folderId)) {
                $folderName = [string]$folderMap[$folderId].Name
                if ($taggedMoRefs.Contains($folderId)) {
                    $folderTags = @($tagRuleName)
                }
            }

            $folderPath = ''
            if (-not [string]::IsNullOrWhiteSpace($folderId)) {
                if (-not $folderPathCache.ContainsKey($folderId)) {
                    $folderPathCache[$folderId] = Get-NarvikFolderPath -FolderId $folderId -FolderMap $folderMap -DatacenterMap $datacenterMap
                }
                $folderPath = [string]$folderPathCache[$folderId]
            }

            $resourcePoolId = [string]$vmCandidate.ResourcePoolId
            $resourcePoolName = ''
            $resourcePoolTags = @()
            if (-not [string]::IsNullOrWhiteSpace($resourcePoolId) -and $resourcePoolMap.ContainsKey($resourcePoolId)) {
                $resourcePoolName = $resourcePoolMap[$resourcePoolId]
                if ($taggedMoRefs.Contains($resourcePoolId)) {
                    $resourcePoolTags = @($tagRuleName)
                }
            }

            $hostId = [string]$vmCandidate.HostId
            $hostName = ''
            $hostTags = @()
            if (-not [string]::IsNullOrWhiteSpace($hostId)) {
                if ($hostMap.ContainsKey($hostId)) {
                    $hostName = [string]$hostMap[$hostId]
                }
                if ($taggedMoRefs.Contains($hostId)) {
                    $hostTags = @($tagRuleName)
                }
            }

            $hostClusterId = ''
            $hostClusterName = ''
            $clusterTags = @()
            if (-not [string]::IsNullOrWhiteSpace($hostId) -and $hostParentMap.ContainsKey($hostId)) {
                $hostParentId = [string]$hostParentMap[$hostId]
                if (-not [string]::IsNullOrWhiteSpace($hostParentId) -and $clusterNames.ContainsKey($hostParentId)) {
                    $hostClusterId = $hostParentId
                    $hostClusterName = [string]$clusterNames[$hostClusterId]
                    if ($taggedMoRefs.Contains($hostClusterId)) {
                        $clusterTags = @($tagRuleName)
                    }
                }
            }

            $notes = [string]$vmCandidate.Notes

            $lastBackup = $null
            $noteBackups = ConvertFrom-NarvikVmNotes -Notes $notes
            if ($null -ne $noteBackups) {
                $notesTimestampText = $noteBackups.Incremental.ToString('yyyy-MM-dd HH:mm:ss')
                $notesTimestampDetail = ''
                if ($null -ne $noteBackups.Full) {
                    $notesTimestampDetail = " (full $($noteBackups.Full.ToString('yyyy-MM-dd HH:mm:ss')))"
                }
                Write-NarvikLog -Level DEBUG -Message "Notes last backup timestamp: '$vmName': $notesTimestampText$notesTimestampDetail."
                # The Notes block is the source for the last incremental, but it
                # is only taken when it is newer than the value already known; an
                # older Notes timestamp never moves the last backup backwards. Only
                # a Full block updates the last full, and only when it is newer.
                # An incremental backup never overwrites the last full control.
                $knownLastBackup = $null
                if ($knownLastBackupByName.ContainsKey($vmName)) {
                    $knownLastBackup = $knownLastBackupByName[$vmName]
                }
                $lastBackup = $noteBackups.Incremental
                if ($null -ne $knownLastBackup -and $noteBackups.Incremental -le $knownLastBackup) {
                    $lastBackup = $knownLastBackup
                    Write-NarvikLog -Level DEBUG -Message "Notes last backup timestamp: '$vmName': ignoring $notesTimestampText because it is not newer than the known last backup $($knownLastBackup.ToString('yyyy-MM-dd HH:mm:ss'))."
                }
                if ($null -ne $noteBackups.Full) {
                    $currentLastFull = $null
                    if ($script:LastFull.ContainsKey($vmName)) {
                        $currentLastFull = $script:LastFull[$vmName]
                    }
                    if ($null -eq $currentLastFull -or $noteBackups.Full -gt $currentLastFull) {
                        $script:LastFull[$vmName] = $noteBackups.Full
                        $lastFullChanged = $true
                        Write-NarvikLog -Level DEBUG -Message "Notes last backup timestamp: '$vmName' : full backup at $($noteBackups.Full.ToString('yyyy-MM-dd HH:mm:ss'))."
                    }
                }
            }
            elseif (-not [string]::IsNullOrWhiteSpace($notes)) {
                $notesParseWarnings++
                Write-NarvikLog -Level DEBUG -Message "Notes last backup timestamp: '$vmName': no valid <Last Backup> block, so its last backup is unknown."
            }
            else {
                Write-NarvikLog -Level DEBUG -Message "Notes last backup timestamp: '$vmName': no Notes."
            }

            $disks = [System.Collections.Generic.List[object]]::new()
            $totalSizeGb = 0.0

            $diskTimer.Start()
            foreach ($diskObject in @($vmCandidate.Disks)) {
                if ($null -eq $diskObject) {
                    continue
                }

                # The backing details come from the V1 Get-HardDisk object itself:
                # DiskType (raw device mapping), Persistence (independent mode),
                # StorageFormat (provisioning) and Filename (datastore name). Reading
                # the managed object's backing (ExtensionData) costs one round trip
                # per disk. The values are mapped to the same strings the backing
                # used to give (DiskMode, BackingType).
                $rawDiskType = [string]$diskObject.DiskType
                $isRdm = ($rawDiskType -match '^Raw')
                $backingType = ''
                if ($isRdm) {
                    $backingType = 'VirtualDiskRawDiskMappingVer1BackingInfo'
                }
                elseif (-not [string]::IsNullOrWhiteSpace($rawDiskType)) {
                    $backingType = 'VirtualDiskFlatVer2BackingInfo'
                }

                $persistence = [string]$diskObject.Persistence
                $diskMode = switch ($persistence) {
                    'Persistent' { 'persistent' }
                    'IndependentPersistent' { 'independent_persistent' }
                    'IndependentNonPersistent' { 'independent_nonpersistent' }
                    'NonPersistent' { 'nonpersistent' }
                    default { '' }
                }
                $isIndependent = ($persistence -match 'Independent')

                $capacityKb = 0L
                $sizeGb = 0.0
                try {
                    $capacityKb = [long]$diskObject.CapacityKB
                    $sizeGb = [math]::Round(([double]$capacityKb / 1048576.0), 2)
                }
                catch {
                    $capacityKb = 0L
                    $sizeGb = 0.0
                }
                $totalSizeGb += $sizeGb

                # Filename is '[datastore name] folder/disk.vmdk'.
                $filenameDatastore = ''
                if ([string]$diskObject.Filename -match '^\[(.+?)\]') {
                    $filenameDatastore = $matches[1]
                }

                $datastoreId = ''
                if (-not [string]::IsNullOrWhiteSpace($filenameDatastore) -and $datastoreIdByName.ContainsKey($filenameDatastore)) {
                    $datastoreId = [string]$datastoreIdByName[$filenameDatastore]
                }

                $datastoreName = ''
                $datastoreType = ''
                if (-not [string]::IsNullOrWhiteSpace($datastoreId) -and $datastoreMap.ContainsKey($datastoreId)) {
                    $datastoreName = [string]$datastoreMap[$datastoreId].Name
                    $datastoreType = [string]$datastoreMap[$datastoreId].Type
                }

                $clusterName = ''
                $datastoreClusterId = ''
                if (-not [string]::IsNullOrWhiteSpace($datastoreId) -and $podByDatastore.ContainsKey($datastoreId)) {
                    $clusterName = [string]$podByDatastore[$datastoreId].Name
                    $datastoreClusterId = [string]$podByDatastore[$datastoreId].MoRef
                }

                $datastoreTags = @()
                if (-not [string]::IsNullOrWhiteSpace($datastoreId) -and $taggedMoRefs.Contains($datastoreId)) {
                    $datastoreTags = @($tagRuleName)
                }

                $datastoreClusterTags = @()
                if (-not [string]::IsNullOrWhiteSpace($datastoreClusterId) -and $taggedMoRefs.Contains($datastoreClusterId)) {
                    $datastoreClusterTags = @($tagRuleName)
                }

                $label = [string]$diskObject.Name
                if ([string]::IsNullOrWhiteSpace($label)) {
                    $label = 'Disk ' + [string]$diskObject.Id
                }

                # Thin for 'Thin'; Thick for 'Thick' and 'EagerZeroedThick' (as the
                # backing's ThinProvisioned flag reported). RDM disks have no format.
                $provisioning = ''
                $storageFormat = [string]$diskObject.StorageFormat
                if ($storageFormat -eq 'Thin') {
                    $provisioning = 'Thin'
                }
                elseif ($storageFormat -eq 'Thick' -or $storageFormat -eq 'EagerZeroedThick') {
                    $provisioning = 'Thick'
                }

                $diskType = $backingType
                if ($isRdm) {
                    $diskType = 'RDM'
                }
                elseif (-not [string]::IsNullOrWhiteSpace($provisioning)) {
                    $diskType = $provisioning
                }

                [void]$disks.Add([pscustomobject]@{
                    Label                = $label
                    Type                 = $diskType
                    Independent          = [bool]$isIndependent
                    RDM                  = [bool]$isRdm
                    SizeGB               = [double]$sizeGb
                    CapacityInKB         = [long]$capacityKb
                    Datastore            = $datastoreName
                    DatastoreType        = $datastoreType
                    DatastoreCluster     = $clusterName
                    DatastoreTags        = $datastoreTags
                    DatastoreClusterTags = $datastoreClusterTags
                    DiskMode             = $diskMode
                    BackingType          = $backingType
                })
            }

            $diskTimer.Stop()

            # The datastore cluster association comes from the VM's disks only.
            # Datastores used by other devices (for example ISO images attached
            # to CD/DVD drives) and the datastore holding the VM home files are
            # not part of the placement rule. A VM without disks gets no
            # association, which makes it ineligible.
            $vmClusterNames = New-Object 'System.Collections.Generic.List[string]'
            $vmClusterKeys = @{}
            foreach ($disk in @($disks)) {
                $podName = [string]$disk.DatastoreCluster
                if ([string]::IsNullOrWhiteSpace($podName)) {
                    continue
                }

                $podKey = $podName.ToLowerInvariant()
                if (-not $vmClusterKeys.ContainsKey($podKey)) {
                    $vmClusterKeys[$podKey] = $true
                    [void]$vmClusterNames.Add($podName)
                }
            }

            $priorityClusterSetting = Get-NarvikPriorityClusterSetting -ClusterName $hostClusterName
            $resourcePoolPriority = Get-NarvikPriorityResourcePoolSetting -ClusterName $hostClusterName -ResourcePoolName $resourcePoolName

            [void]$vms.Add([pscustomobject]@{
                Name              = $vmName
                MoRef             = $vmMoref
                FolderPath        = $folderPath
                FolderMoRef       = $folderId
                FolderName        = $folderName
                FolderTags        = $folderTags
                ClusterMoRef      = $hostClusterId
                ClusterName       = $hostClusterName
                ClusterTags       = $clusterTags
                ClusterPriority   = [int]$priorityClusterSetting.Priority
                ResourcePoolMoRef = $resourcePoolId
                ResourcePoolName  = $resourcePoolName
                ResourcePoolPriority = [int]$resourcePoolPriority
                ResourcePoolTags  = $resourcePoolTags
                HostMoRef         = $hostId
                HostName          = $hostName
                HostTags          = $hostTags
                Tags              = $vmTags
                Notes             = $notes
                LastBackup        = $lastBackup
                TotalSizeGB       = [math]::Round($totalSizeGb, 2)
                DatastoreClusters = @($vmClusterNames | Sort-Object)
                ManagementClass   = ''
                Disks             = @($disks)
            })
        }
        Write-NarvikLog -Level DEBUG -Message "VM processing finished: $vmProcessed candidate(s) in $($vmProcessTimer.ElapsedMilliseconds) ms (disk processing $($diskTimer.ElapsedMilliseconds) ms)."

        if ($lastFullChanged) {
            Save-NarvikLastFull
        }

        if ($notesParseWarnings -gt 0) {
            Write-NarvikLog -Level WARNING -Message "$notesParseWarnings VM(s) have notes but no valid Last Backup block; their last incremental backup is unknown."
        }

        $sortedVms = @($vms | Sort-Object -Property FolderPath, Name)
        $buildMs = $collectionTimer.ElapsedMilliseconds
        Write-NarvikLog -Level DEBUG -Message "vCenter inventory timing: inventory reads $readMs ms, tag collection $tagReadMs ms, inventory build $buildMs ms."
        Write-NarvikLog -Level DEBUG -Message "vCenter inventory collection total: $([math]::Round(((Get-Date) - $collectStart).TotalSeconds, 1)) s."

        return [pscustomobject]@{
            CollectedAt          = $collectStart
            VMs                  = $sortedVms
            Datastores           = @($datastores)
            DatastoreClusters    = @($datastoreClusters)
            TagRuleName          = $tagRuleName
            TagDataAvailable     = [bool]$tagDataAvailable
            UnknownPriorityEntries = $unknownPriorityEntries.ToArray()
            VmCount              = $sortedVms.Count
            DatastoreCount       = $datastores.Count
            DatastoreClusterCount = $datastoreClusters.Count
        }
    }
    finally {
        Disconnect-NarvikVCenter
    }
}

function Update-NarvikVCenterCache {
    $script:VCacheRefreshedThisLoop = $false
    $now = Get-Date

    if ($null -ne $script:VCache) {
        $age = $now - $script:VCache.CollectedAt
        if ($age.TotalHours -lt 1.0) {
            if (Test-NarvikVCacheTagRuleCurrent -Cache $script:VCache) {
                return $true
            }

            Write-NarvikLog -Level DEBUG -Message 'The cached vCenter inventory was collected with a different snapshot tag rule; refreshing it.'
        }
    }

    if ($null -ne $script:LastVCenterAttempt -and $script:LastVCenterAttempt -ne [datetime]::MinValue) {
        $sinceAttempt = ($now - $script:LastVCenterAttempt).TotalSeconds
        if ($sinceAttempt -lt 60) {
            $remainingSeconds = [math]::Ceiling(60 - $sinceAttempt)
            Write-NarvikLog -Level DEBUG -Message "vCenter inventory refresh delayed for $remainingSeconds more second(s) after the last collection attempt."
            if ($null -ne $script:VCache) {
                return $true
            }
            return $false
        }
    }

    $script:LastVCenterAttempt = $now
    $script:TagRuleFailure = $false

    try {
        $cache = Get-NarvikVCenterData
        $script:VCache = $cache
        $script:VCacheRefreshedThisLoop = $true
        Write-NarvikLog -Level INFO -Message "vCenter inventory collected: $($cache.VmCount) VM(s), $($cache.DatastoreCount) VMFS datastore(s), $($cache.DatastoreClusterCount) datastore cluster(s)."
        return $true
    }
    catch {
        if ($script:TagRuleFailure) {
            $script:TagRuleFailure = $false
            # Get-NarvikVCenterData already logged this failure, and it can
            # repeat on every retry. What is left here is the cached inventory:
            # its tag data is not trustworthy any more, and eligibility uses it
            # to decide, so the cache must not keep backups running.
            if ($null -ne $script:VCache) {
                $wasAvailable = [bool]$script:VCache.TagDataAvailable
                if ($null -ne $script:VCache.PSObject.Properties['TagDataAvailable']) {
                    $script:VCache.TagDataAvailable = $false
                }
                else {
                    Add-Member -InputObject $script:VCache -NotePropertyName 'TagDataAvailable' -NotePropertyValue $false
                }

                if ($wasAvailable) {
                    Write-NarvikLog -Level WARNING -Message 'Cached tag data was discarded because the snapshot tag rule could not be collected; no VM is eligible while the rule is configured and tags cannot be read.'
                }

                # Eligibility is only recomputed after a successful collection,
                # so the discarded tag data has to be applied here: otherwise a
                # VM that was eligible a moment ago would keep being scheduled.
                Update-NarvikEligibility
            }
        }
        else {
            Write-NarvikLog -Level WARNING -Message "vCenter inventory collection failed: $($_.Exception.Message)"
        }

        if ($null -ne $script:VCache) {
            return $true
        }
        return $false
    }
}

function ConvertFrom-NarvikVmNotes {
    param(
        [string]$Notes
    )

    if ([string]::IsNullOrWhiteSpace($Notes)) {
        return $null
    }

    # dsmc reports the last backup inside a single Notes block:
    #   <Last Backup (IBM Spectrum Protect)>
    #   Status='Successful'
    #   Last Run Time='MM/DD/YYYY HH:MM:SS'
    #   Type='Incremental Forever - Incremental|Full'
    #   </Last Backup>
    # Line endings are normalized to spaces before parsing, so the values may
    # span several lines. The status, the date format and the type suffix are
    # mandatory; anything that does not match this fixed shape is ignored.
    $normalized = [regex]::Replace($Notes, '\r\n|\r|\n', ' ')
    $blockPattern = '<Last Backup \(IBM Spectrum Protect\)>([^<>]*)</Last Backup>'
    $timePattern = 'Last Run Time=''(\d{2}/\d{2}/\d{4} \d{2}:\d{2}:\d{2})'''
    $typePattern = 'Type=''([^'']*)'''
    $incrementalDate = $null
    $fullDate = $null

    foreach ($block in [regex]::Matches($normalized, $blockPattern)) {
        $body = $block.Groups[1].Value
        if (-not $body.Contains("Status='Successful'")) {
            continue
        }

        $timeMatch = [regex]::Match($body, $timePattern)
        if (-not $timeMatch.Success) {
            continue
        }

        $timestampText = $timeMatch.Groups[1].Value
        $parsed = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($timestampText, 'MM/dd/yyyy HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
            continue
        }

        $typeMatch = [regex]::Match($body, $typePattern)
        if (-not $typeMatch.Success) {
            continue
        }

        $modeMatch = [regex]::Match($typeMatch.Groups[1].Value, '^Incremental Forever - (Incremental|Full)$')
        if (-not $modeMatch.Success) {
            continue
        }

        # A Full backup also counts as the last incremental; an incremental
        # backup never changes the last full.
        if ($null -eq $incrementalDate -or $parsed -gt $incrementalDate) {
            $incrementalDate = $parsed
        }
        if ($modeMatch.Groups[1].Value -eq 'Full' -and ($null -eq $fullDate -or $parsed -gt $fullDate)) {
            $fullDate = $parsed
        }
    }

    if ($null -eq $incrementalDate -and $null -eq $fullDate) {
        return $null
    }

    return [pscustomobject]@{
        Incremental = $incrementalDate
        Full        = $fullDate
    }
}
