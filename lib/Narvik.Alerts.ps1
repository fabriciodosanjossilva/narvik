function Send-NarvikDuplicateNameAlerts {
    if ($null -eq $script:DuplicateNameCases -or @($script:DuplicateNameCases).Count -eq 0) {
        return
    }

    if (-not (Test-NarvikMailEnabled)) {
        Write-NarvikLog -Level DEBUG -Message 'SMTP server is not configured; duplicate VM name alert skipped.'
        return
    }

    $now = Get-Date
    $dueCases = [System.Collections.Generic.List[object]]::new()

    foreach ($case in @($script:DuplicateNameCases)) {
        $key = ([string]$case.Name).ToLowerInvariant()
        $lastAlert = $null
        if ($script:State.duplicate_name_alerts.ContainsKey($key)) {
            $lastAlert = $script:State.duplicate_name_alerts[$key]
        }

        if ($null -ne $lastAlert) {
            $ageHours = ($now - $lastAlert).TotalHours
            if ($ageHours -lt 24) {
                Write-NarvikLog -Level INFO -Message "Duplicate VM name '$($case.Name)' was already reported at $($lastAlert.ToString('yyyy-MM-dd HH:mm:ss')); alert suppressed for 24 hours."
                continue
            }
        }

        [void]$dueCases.Add($case)
    }

    if ($dueCases.Count -eq 0) {
        return
    }

    $body = New-Object System.Text.StringBuilder
    [void]$body.AppendLine('Narvik detected multiple eligible VMs with the same name.')
    [void]$body.AppendLine('This is not supported by the backup command and must be resolved.')
    [void]$body.AppendLine('')
    [void]$body.AppendLine('The following VMs were excluded from backup:')
    [void]$body.AppendLine('')

    foreach ($case in $dueCases) {
        [void]$body.AppendLine("Name: '$($case.Name)'")
        foreach ($vm in @($case.VMs)) {
            [void]$body.AppendLine("  - Folder: '$($vm.FolderPath)' | Host: '$($vm.HostName)' | MoRef: '$($vm.MoRef)'")
        }
        [void]$body.AppendLine('')
    }

    $subject = '[Narvik] Duplicate VM names detected - action required'
    $sent = Send-NarvikMail -Subject $subject -Body $body.ToString()

    if ($sent) {
        foreach ($case in $dueCases) {
            $key = ([string]$case.Name).ToLowerInvariant()
            $script:State.duplicate_name_alerts[$key] = $now
        }
        Save-NarvikState
        Write-NarvikLog -Level INFO -Message "Duplicate VM name alert sent for $($dueCases.Count) name(s)."
    }
    else {
        Write-NarvikLog -Level ERROR -Message 'Duplicate VM name alert could not be sent; it will be retried on the next inventory collection.'
    }
}

function Send-NarvikInventoryRuleAlerts {
    $nameCases = @($script:UnsupportedNameCases)
    $clusterCases = @($script:DatastoreClusterCases)
    $managementClassCases = @($script:ManagementClassCases)
    if ($nameCases.Count -eq 0 -and $clusterCases.Count -eq 0 -and $managementClassCases.Count -eq 0) {
        return
    }

    if (-not (Test-NarvikMailEnabled)) {
        Write-NarvikLog -Level DEBUG -Message 'SMTP server is not configured; inventory rule alert skipped.'
        return
    }

    $now = Get-Date
    $dueNameCases = [System.Collections.Generic.List[object]]::new()
    $dueClusterCases = [System.Collections.Generic.List[object]]::new()
    $dueManagementClassCases = [System.Collections.Generic.List[object]]::new()

    foreach ($vm in $nameCases) {
        $key = ([string]$vm.Name).ToLowerInvariant()
        $lastAlert = $null
        if ($script:State.inventory_rule_alerts.ContainsKey($key)) {
            $lastAlert = $script:State.inventory_rule_alerts[$key]
        }

        if ($null -ne $lastAlert) {
            $ageHours = ($now - $lastAlert).TotalHours
            if ($ageHours -lt 24) {
                Write-NarvikLog -Level INFO -Message "VM '$($vm.Name)' with an unsupported name was already reported at $($lastAlert.ToString('yyyy-MM-dd HH:mm:ss')); alert suppressed for 24 hours."
                continue
            }
        }

        [void]$dueNameCases.Add($vm)
    }

    foreach ($case in $clusterCases) {
        $vm = $case.VM
        $key = ([string]$vm.Name).ToLowerInvariant()
        $lastAlert = $null
        if ($script:State.inventory_rule_alerts.ContainsKey($key)) {
            $lastAlert = $script:State.inventory_rule_alerts[$key]
        }

        if ($null -ne $lastAlert) {
            $ageHours = ($now - $lastAlert).TotalHours
            if ($ageHours -lt 24) {
                Write-NarvikLog -Level INFO -Message "VM '$($vm.Name)' with an invalid datastore cluster association was already reported at $($lastAlert.ToString('yyyy-MM-dd HH:mm:ss')); alert suppressed for 24 hours."
                continue
            }
        }

        [void]$dueClusterCases.Add($case)
    }

    foreach ($case in $managementClassCases) {
        $vm = $case.VM
        $key = ([string]$vm.Name).ToLowerInvariant()
        $lastAlert = $null
        if ($script:State.inventory_rule_alerts.ContainsKey($key)) {
            $lastAlert = $script:State.inventory_rule_alerts[$key]
        }

        if ($null -ne $lastAlert) {
            $ageHours = ($now - $lastAlert).TotalHours
            if ($ageHours -lt 24) {
                Write-NarvikLog -Level INFO -Message "VM '$($vm.Name)' with an unmapped datastore cluster was already reported at $($lastAlert.ToString('yyyy-MM-dd HH:mm:ss')); alert suppressed for 24 hours."
                continue
            }
        }

        [void]$dueManagementClassCases.Add($case)
    }

    if ($dueNameCases.Count -eq 0 -and $dueClusterCases.Count -eq 0 -and $dueManagementClassCases.Count -eq 0) {
        return
    }

    $body = New-Object System.Text.StringBuilder
    [void]$body.AppendLine('Narvik detected VMs that cannot be backed up because of their name, datastore cluster association or missing management class mapping.')
    [void]$body.AppendLine('The following VMs were excluded from backup:')
    [void]$body.AppendLine('')

    if ($dueNameCases.Count -gt 0) {
        [void]$body.AppendLine('VMs with names not supported by the backup command:')
        [void]$body.AppendLine('')
        foreach ($vm in $dueNameCases) {
            [void]$body.AppendLine("Name: '$($vm.Name)'")
            [void]$body.AppendLine("  - Folder: '$($vm.FolderPath)' | Host: '$($vm.HostName)' | MoRef: '$($vm.MoRef)'")
            [void]$body.AppendLine('')
        }
    }

    if ($dueClusterCases.Count -gt 0) {
        [void]$body.AppendLine('VMs not associated with exactly one datastore cluster:')
        [void]$body.AppendLine('')
        foreach ($case in $dueClusterCases) {
            $vm = $case.VM
            $clusters = @($case.DatastoreClusters)
            $clusterText = 'none'
            if ($clusters.Count -gt 0) {
                $clusterText = "'" + ($clusters -join "', '") + "'"
            }
            [void]$body.AppendLine("Name: '$($vm.Name)'")
            [void]$body.AppendLine("  - Folder: '$($vm.FolderPath)' | Host: '$($vm.HostName)' | MoRef: '$($vm.MoRef)'")
            [void]$body.AppendLine("  - Datastore clusters: $clusterText")
            $standaloneNames = @()
            if ($case.PSObject.Properties.Name -contains 'StandaloneDatastores') {
                $standaloneNames = @($case.StandaloneDatastores)
            }
            if ($standaloneNames.Count -gt 0) {
                [void]$body.AppendLine("  - Datastores outside a datastore cluster: '" + ($standaloneNames -join "', '") + "'")
            }
            [void]$body.AppendLine('')
        }
    }

    if ($dueManagementClassCases.Count -gt 0) {
        [void]$body.AppendLine('VMs whose datastore cluster has no management class mapping:')
        [void]$body.AppendLine('')
        foreach ($case in $dueManagementClassCases) {
            $vm = $case.VM
            [void]$body.AppendLine("Name: '$($vm.Name)'")
            [void]$body.AppendLine("  - Folder: '$($vm.FolderPath)' | Host: '$($vm.HostName)' | MoRef: '$($vm.MoRef)'")
            [void]$body.AppendLine("  - Datastore cluster: '$($case.DatastoreCluster)'")
            [void]$body.AppendLine('')
        }
    }

    $subject = '[Narvik] VMs with unsupported names, datastore cluster associations or management class mappings - action required'
    $sent = Send-NarvikMail -Subject $subject -Body $body.ToString()

    if ($sent) {
        $reportedKeys = @{}
        foreach ($vm in $dueNameCases) {
            $key = ([string]$vm.Name).ToLowerInvariant()
            $script:State.inventory_rule_alerts[$key] = $now
            $reportedKeys[$key] = $true
        }
        foreach ($case in $dueClusterCases) {
            $key = ([string]$case.VM.Name).ToLowerInvariant()
            $script:State.inventory_rule_alerts[$key] = $now
            $reportedKeys[$key] = $true
        }
        foreach ($case in $dueManagementClassCases) {
            $key = ([string]$case.VM.Name).ToLowerInvariant()
            $script:State.inventory_rule_alerts[$key] = $now
            $reportedKeys[$key] = $true
        }
        Save-NarvikState
        Write-NarvikLog -Level INFO -Message "Unsupported name/datastore cluster/management class alert sent for $($reportedKeys.Count) VM(s)."
    }
    else {
        Write-NarvikLog -Level ERROR -Message 'Unsupported name/datastore cluster/management class alert could not be sent; it will be retried on the next inventory collection.'
    }
}

function Send-NarvikDiskSizeAlerts {
    $cases = @($script:DiskSizeCases)
    if ($cases.Count -eq 0) {
        return
    }

    if (-not (Test-NarvikMailEnabled)) {
        Write-NarvikLog -Level DEBUG -Message 'SMTP server is not configured; disk size alert skipped.'
        return
    }

    $now = Get-Date
    $dueCases = [System.Collections.Generic.List[object]]::new()

    foreach ($case in $cases) {
        $key = ([string]$case.VM.Name).ToLowerInvariant()
        $lastAlert = $null
        if ($script:State.disk_size_alerts.ContainsKey($key)) {
            $lastAlert = $script:State.disk_size_alerts[$key]
        }

        if ($null -ne $lastAlert) {
            $ageHours = ($now - $lastAlert).TotalHours
            if ($ageHours -lt 24) {
                Write-NarvikLog -Level INFO -Message "VM '$($case.VM.Name)' with a disk size that is not a multiple of 1 MiB was already reported at $($lastAlert.ToString('yyyy-MM-dd HH:mm:ss')); alert suppressed for 24 hours."
                continue
            }
        }

        [void]$dueCases.Add($case)
    }

    if ($dueCases.Count -eq 0) {
        return
    }

    $body = New-Object System.Text.StringBuilder
    [void]$body.AppendLine('Narvik detected VMs with disks whose size is not a multiple of 1 MiB.')
    [void]$body.AppendLine('The backup command requires disk sizes that are a multiple of 1 MiB.')
    [void]$body.AppendLine('')
    [void]$body.AppendLine('The following VMs were excluded from backup:')
    [void]$body.AppendLine('')

    foreach ($case in $dueCases) {
        $vm = $case.VM
        [void]$body.AppendLine("Name: '$($vm.Name)'")
        [void]$body.AppendLine("  - Folder: '$($vm.FolderPath)' | Host: '$($vm.HostName)' | MoRef: '$($vm.MoRef)'")
        foreach ($disk in @($case.Disks)) {
            $capacityKb = 0L
            if ($disk.PSObject.Properties.Name -contains 'CapacityInKB') {
                $capacityKb = [long]$disk.CapacityInKB
            }
            $roundedKb = Get-NarvikDiskRoundedCapacityKB -CapacityInKB $capacityKb
            [void]$body.AppendLine("  - Disk: '$($disk.Label)' | Size: $capacityKb KiB | Corrected size: $roundedKb KiB")
            [void]$body.AppendLine("    To fix, run manually: $(Get-NarvikDiskFixCommand -VMName $vm.Name -DiskName $disk.Label -CapacityInKB $roundedKb)")
        }
        [void]$body.AppendLine('')
    }

    $subject = '[Narvik] VM disks whose size is not a multiple of 1 MiB - action required'
    $sent = Send-NarvikMail -Subject $subject -Body $body.ToString()

    if ($sent) {
        foreach ($case in $dueCases) {
            $key = ([string]$case.VM.Name).ToLowerInvariant()
            $script:State.disk_size_alerts[$key] = $now
        }
        Save-NarvikState
        Write-NarvikLog -Level INFO -Message "Disk size alert sent for $($dueCases.Count) VM(s)."
    }
    else {
        Write-NarvikLog -Level ERROR -Message 'Disk size alert could not be sent; it will be retried on the next inventory collection.'
    }
}

function Send-NarvikPriorityClusterAlerts {
    $unknownEntries = @()
    if ($null -ne $script:VCache -and $script:VCache.PSObject.Properties.Name -contains 'UnknownPriorityEntries') {
        $unknownEntries = @($script:VCache.UnknownPriorityEntries)
    }

    if ($unknownEntries.Count -eq 0) {
        return
    }

    if (-not (Test-NarvikMailEnabled)) {
        Write-NarvikLog -Level DEBUG -Message 'SMTP server is not configured; backup priority name alert skipped.'
        return
    }

    $now = Get-Date
    $dueEntries = New-Object 'System.Collections.Generic.List[object]'

    foreach ($entry in $unknownEntries) {
        $key = ''
        if ($null -ne $entry.PSObject.Properties['Key']) {
            $key = [string]$entry.Key
        }
        if ([string]::IsNullOrWhiteSpace($key)) {
            continue
        }

        $lastAlert = $null
        if ($script:State.priority_cluster_alerts.ContainsKey($key)) {
            $lastAlert = $script:State.priority_cluster_alerts[$key]
        }

        if ($null -ne $lastAlert) {
            $ageHours = ($now - $lastAlert).TotalHours
            if ($ageHours -lt 24) {
                Write-NarvikLog -Level INFO -Message "Backup priority entry '$key' was already reported at $($lastAlert.ToString('yyyy-MM-dd HH:mm:ss')); alert suppressed for 24 hours."
                continue
            }
        }

        [void]$dueEntries.Add($entry)
    }

    if ($dueEntries.Count -eq 0) {
        return
    }

    $body = New-Object System.Text.StringBuilder
    [void]$body.AppendLine('Narvik did not find the following names from the backup priority configuration in vCenter.')
    [void]$body.AppendLine('Their priority and max_threads settings are not being applied to any VM.')
    [void]$body.AppendLine('Fix the names in config.json or remove the entries.')
    [void]$body.AppendLine('')
    foreach ($entry in $dueEntries) {
        [void]$body.AppendLine('- ' + [string]$entry.Message)
    }

    $subject = '[Narvik] Names in the backup priority configuration not found in vCenter - action required'
    $sent = Send-NarvikMail -Subject $subject -Body $body.ToString()

    if ($sent) {
        foreach ($entry in $dueEntries) {
            $script:State.priority_cluster_alerts[[string]$entry.Key] = $now
        }
        Save-NarvikState
        Write-NarvikLog -Level INFO -Message "Backup priority name alert sent for $($dueEntries.Count) entr(y/ies)."
    }
    else {
        Write-NarvikLog -Level ERROR -Message 'Backup priority name alert could not be sent; it will be retried on the next inventory collection.'
    }
}

function Update-NarvikIndependentDiskControl {
    param(
        [switch]$SendAlerts
    )

    if ($null -eq $script:VCache) {
        return
    }

    $allDiskKeys = @{}
    $allDisksByKey = @{}

    foreach ($vm in @($script:VCache.VMs)) {
        foreach ($disk in @($vm.Disks)) {
            if (-not $disk.Independent) {
                continue
            }
            $key = "$($vm.Name)|$($disk.Label)"
            $allDiskKeys[$key] = $true
            $allDisksByKey[$key] = [pscustomobject]@{
                VM   = $vm
                Disk = $disk
            }
        }
    }

    $existingKeys = @{}
    foreach ($entry in @($script:IndependentDisks)) {
        $existingKeys["$($entry.vm)|$($entry.disk)"] = $true
    }

    $kept = @()
    $changed = $false
    foreach ($entry in @($script:IndependentDisks)) {
        $key = "$($entry.vm)|$($entry.disk)"
        if ($allDiskKeys.ContainsKey($key)) {
            $kept += $entry
        }
        else {
            $changed = $true
            Write-NarvikLog -Level INFO -Message "Removed stale independent disk control entry for VM '$($entry.vm)', disk '$($entry.disk)'."
        }
    }
    $script:IndependentDisks = @($kept)

    if ($SendAlerts -and -not (Test-NarvikMailEnabled)) {
        Write-NarvikLog -Level DEBUG -Message 'SMTP server is not configured; independent disk alert skipped.'
    }

    if ($SendAlerts -and (Test-NarvikMailEnabled)) {
        $now = Get-Date
        $eligibleKeys = @{}
        foreach ($vm in @($script:EligibleVMs)) {
            foreach ($disk in @($vm.Disks)) {
                if ($disk.Independent) {
                    $eligibleKeys["$($vm.Name)|$($disk.Label)"] = $true
                }
            }
        }

        foreach ($key in $eligibleKeys.Keys) {
            if ($existingKeys.ContainsKey($key)) {
                continue
            }

            $item = $allDisksByKey[$key]
            if ($null -eq $item) {
                continue
            }

            $vm = $item.VM
            $disk = $item.Disk
            Write-NarvikLog -Level WARNING -Message "Independent disk detected on VM '$($vm.Name)': '$($disk.Label)', $($disk.SizeGB) GB, datastore '$($disk.Datastore)'."

            $body = New-Object System.Text.StringBuilder
            [void]$body.AppendLine('Narvik detected an independent disk on an eligible VM.')
            [void]$body.AppendLine('Independent disks may not be handled correctly by snapshot backups.')
            [void]$body.AppendLine('')
            [void]$body.AppendLine("VM: '$($vm.Name)'")
            [void]$body.AppendLine("Folder: '$($vm.FolderPath)'")
            [void]$body.AppendLine("Host: '$($vm.HostName)'")
            [void]$body.AppendLine("Disk: '$($disk.Label)'")
            [void]$body.AppendLine("Type: '$($disk.Type)'")
            [void]$body.AppendLine("Size: $($disk.SizeGB) GB")
            [void]$body.AppendLine("Datastore: '$($disk.Datastore)'")
            [void]$body.AppendLine("Datastore cluster: '$($disk.DatastoreCluster)'")

            $sent = Send-NarvikMail -Subject "[Narvik] Independent disk detected on VM '$($vm.Name)'" -Body $body.ToString()
            if ($sent) {
                $script:IndependentDisks += [pscustomobject]@{
                    vm         = [string]$vm.Name
                    disk       = [string]$disk.Label
                    first_seen = $now.ToString('o')
                }
                $existingKeys[$key] = $true
                $changed = $true
            }
            else {
                Write-NarvikLog -Level ERROR -Message "Independent disk alert for VM '$($vm.Name)' could not be sent; it will be retried on the next inventory collection."
            }
        }
    }

    if ($changed) {
        Save-NarvikIndependentDisks
    }
}
