function Move-NarvikCorruptFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }

    $backup = $Path + '.corrupt.' + (Get-Date -Format 'yyyyMMddHHmmss')
    try {
        Move-Item -LiteralPath $Path -Destination $backup -Force
        Write-NarvikLog -Level WARNING -Message "Moved invalid file '$Path' to '$backup'."
    }
    catch {
        Write-NarvikLog -Level ERROR -Message "Failed to move invalid file '$Path': $($_.Exception.Message)"
    }
}

function Load-NarvikState {
    $script:State = @{
        failed_attempts       = @{}
        duplicate_guid        = @()
        last_idle             = $null
        duplicate_name_alerts = @{}
        inventory_rule_alerts = @{}
        disk_size_alerts      = @{}
        priority_cluster_alerts = @{}
        critical_error_alerts = @{}
    }

    $path = Join-Path $script:ControlDir 'state.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return
    }

    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        $object = $raw | ConvertFrom-Json -ErrorAction Stop

        if ($null -ne $object.failed_attempts) {
            foreach ($property in $object.failed_attempts.PSObject.Properties) {
                $entry = $property.Value
                $lastAttempt = $null
                if ($null -ne $entry.last_attempt) {
                    $lastAttempt = ConvertFrom-NarvikIsoDate -Value ([string]$entry.last_attempt)
                }
                $script:State.failed_attempts[$property.Name] = @{
                    last_attempt = $lastAttempt
                    count        = [int]$entry.count
                }
            }
        }

        if ($null -ne $object.duplicate_guid) {
            $script:State.duplicate_guid = @($object.duplicate_guid)
        }

        if ($null -ne $object.last_idle) {
            $script:State.last_idle = ConvertFrom-NarvikIsoDate -Value ([string]$object.last_idle)
        }

        if ($null -ne $object.duplicate_name_alerts) {
            foreach ($property in $object.duplicate_name_alerts.PSObject.Properties) {
                $parsed = ConvertFrom-NarvikIsoDate -Value ([string]$property.Value)
                if ($null -ne $parsed) {
                    $script:State.duplicate_name_alerts[$property.Name] = $parsed
                }
            }
        }

        if ($null -ne $object.inventory_rule_alerts) {
            foreach ($property in $object.inventory_rule_alerts.PSObject.Properties) {
                $parsed = ConvertFrom-NarvikIsoDate -Value ([string]$property.Value)
                if ($null -ne $parsed) {
                    $script:State.inventory_rule_alerts[$property.Name] = $parsed
                }
            }
        }

        if ($null -ne $object.disk_size_alerts) {
            foreach ($property in $object.disk_size_alerts.PSObject.Properties) {
                $parsed = ConvertFrom-NarvikIsoDate -Value ([string]$property.Value)
                if ($null -ne $parsed) {
                    $script:State.disk_size_alerts[$property.Name] = $parsed
                }
            }
        }

        if ($null -ne $object.priority_cluster_alerts) {
            foreach ($property in $object.priority_cluster_alerts.PSObject.Properties) {
                $parsed = ConvertFrom-NarvikIsoDate -Value ([string]$property.Value)
                if ($null -ne $parsed) {
                    $script:State.priority_cluster_alerts[$property.Name] = $parsed
                }
            }
        }

        if ($null -ne $object.critical_error_alerts) {
            foreach ($property in $object.critical_error_alerts.PSObject.Properties) {
                $parsed = ConvertFrom-NarvikIsoDate -Value ([string]$property.Value)
                if ($null -ne $parsed) {
                    $script:State.critical_error_alerts[$property.Name] = $parsed
                }
            }
        }
    }
    catch {
        Write-NarvikLog -Level WARNING -Message "State file '$path' is invalid: $($_.Exception.Message)"
        Move-NarvikCorruptFile -Path $path
    }

    $script:DuplicateGuid = @{}
    foreach ($name in @($script:State.duplicate_guid)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$name)) {
            $script:DuplicateGuid[[string]$name] = $true
        }
    }
}

function Save-NarvikState {
    if ($null -eq $script:ControlDir) {
        return
    }

    $failedAttempts = @{}
    foreach ($name in $script:State.failed_attempts.Keys) {
        $entry = $script:State.failed_attempts[$name]
        $lastAttempt = $null
        if ($null -ne $entry.last_attempt) {
            $lastAttempt = $entry.last_attempt.ToString('o')
        }
        $failedAttempts[$name] = @{
            last_attempt = $lastAttempt
            count        = [int]$entry.count
        }
    }

    $duplicateAlerts = @{}
    foreach ($name in $script:State.duplicate_name_alerts.Keys) {
        $duplicateAlerts[$name] = $script:State.duplicate_name_alerts[$name].ToString('o')
    }

    $inventoryAlerts = @{}
    foreach ($name in $script:State.inventory_rule_alerts.Keys) {
        $inventoryAlerts[$name] = $script:State.inventory_rule_alerts[$name].ToString('o')
    }

    $diskSizeAlerts = @{}
    foreach ($name in $script:State.disk_size_alerts.Keys) {
        $diskSizeAlerts[$name] = $script:State.disk_size_alerts[$name].ToString('o')
    }

    $priorityClusterAlerts = @{}
    foreach ($name in $script:State.priority_cluster_alerts.Keys) {
        $priorityClusterAlerts[$name] = $script:State.priority_cluster_alerts[$name].ToString('o')
    }

    $criticalErrorAlerts = @{}
    foreach ($name in $script:State.critical_error_alerts.Keys) {
        $criticalErrorAlerts[$name] = $script:State.critical_error_alerts[$name].ToString('o')
    }

    $lastIdle = $null
    if ($null -ne $script:State.last_idle) {
        $lastIdle = $script:State.last_idle.ToString('o')
    }

    $object = @{
        failed_attempts       = $failedAttempts
        duplicate_guid        = @($script:DuplicateGuid.Keys | Sort-Object)
        last_idle             = $lastIdle
        duplicate_name_alerts = $duplicateAlerts
        inventory_rule_alerts = $inventoryAlerts
        disk_size_alerts      = $diskSizeAlerts
        priority_cluster_alerts = $priorityClusterAlerts
        critical_error_alerts = $criticalErrorAlerts
    }

    $json = $object | ConvertTo-Json -Depth 10
    Write-NarvikAtomicText -Path (Join-Path $script:ControlDir 'state.json') -Content $json
}

function Load-NarvikLastFull {
    $script:LastFull = @{}
    $path = Join-Path $script:ControlDir 'last_full.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return
    }

    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        $object = $raw | ConvertFrom-Json -ErrorAction Stop
        foreach ($property in $object.PSObject.Properties) {
            $parsed = ConvertFrom-NarvikIsoDate -Value ([string]$property.Value)
            if ($null -ne $parsed) {
                $script:LastFull[$property.Name] = $parsed
            }
        }
    }
    catch {
        Write-NarvikLog -Level WARNING -Message "Last full backup file '$path' is invalid: $($_.Exception.Message)"
        Move-NarvikCorruptFile -Path $path
    }
}

function Save-NarvikLastFull {
    $object = @{}
    foreach ($name in $script:LastFull.Keys) {
        $object[$name] = $script:LastFull[$name].ToString('o')
    }

    $json = $object | ConvertTo-Json -Depth 5
    Write-NarvikAtomicText -Path (Join-Path $script:ControlDir 'last_full.json') -Content $json
}

function Load-NarvikIndependentDisks {
    $script:IndependentDisks = @()
    $path = Join-Path $script:ControlDir 'independent.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return
    }

    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        $object = $raw | ConvertFrom-Json -ErrorAction Stop
        foreach ($item in @($object)) {
            if ($null -eq $item) { continue }
            $vmName = [string]$item.vm
            $diskName = [string]$item.disk
            if ([string]::IsNullOrWhiteSpace($vmName) -or [string]::IsNullOrWhiteSpace($diskName)) {
                continue
            }
            $firstSeen = $null
            if ($null -ne $item.first_seen) {
                $firstSeen = [string]$item.first_seen
            }
            $script:IndependentDisks += [pscustomobject]@{
                vm         = $vmName
                disk       = $diskName
                first_seen = $firstSeen
            }
        }
    }
    catch {
        Write-NarvikLog -Level WARNING -Message "Independent disk control file '$path' is invalid: $($_.Exception.Message)"
        Move-NarvikCorruptFile -Path $path
        $script:IndependentDisks = @()
    }
}

function Save-NarvikIndependentDisks {
    $items = @()
    foreach ($item in $script:IndependentDisks) {
        $items += [pscustomobject]@{
            vm         = $item.vm
            disk       = $item.disk
            first_seen = $item.first_seen
        }
    }

    if ($items.Count -eq 0) {
        $json = '[]'
    }
    else {
        $json = ConvertTo-Json -InputObject @($items) -Depth 5
    }

    Write-NarvikAtomicText -Path (Join-Path $script:ControlDir 'independent.json') -Content $json
}
