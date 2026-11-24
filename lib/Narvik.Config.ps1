function Import-NarvikConfig {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Join-Path $script:RootPath 'config.json'
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw [System.Exception]::new("Configuration file not found: '$Path'.")
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        $config = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw [System.Exception]::new("Failed to parse configuration file '$Path': $($_.Exception.Message)")
    }

    if ($null -eq $config -or $config -is [array]) {
        throw [System.Exception]::new("Configuration file '$Path' must contain a JSON object.")
    }

    $knownKeys = @(
        'debug',
        'check_administrator_privilege',
        'bypass_security',
        'dsmc_path',
        'dsmc_opt_file',
        'dsmc_asnodename',
        'dsmc_use_preview',
        'vcenter_server',
        'vcenter_port',
        'vcenter_user',
        'vcenter_password_file',
        'vcenter_ignore_certificate',
        'dont_backup_by_snapshot_tag_name',
        'datastore_cluster_to_management_class',
        'priority_clusters',
        'priority_resource_pools',
        'cluster_max_threads',
        'smtp_server',
        'smtp_port',
        'smtp_use_ssl',
        'smtp_username',
        'smtp_password_file',
        'mail_from',
        'mail_to',
        'max_backup_threads'
    )

    foreach ($propertyName in $config.PSObject.Properties.Name) {
        if ($knownKeys -notcontains $propertyName) {
            if ($propertyName -eq 'log_level') {
                Write-NarvikLog -Level WARNING -Message "Configuration key 'log_level' was renamed to 'debug' and will be ignored."
            }
            else {
                Write-NarvikLog -Level WARNING -Message "Unknown configuration key '$propertyName' will be ignored."
            }
        }
    }

    $debug = ConvertTo-NarvikBoolean -Value (Get-NarvikConfigValue -Config $config -Key 'debug' -Default $false) -KeyName 'debug'

    $dsmcPathValue = [string](Get-NarvikConfigValue -Config $config -Key 'dsmc_path' -Required)
    if ([string]::IsNullOrWhiteSpace($dsmcPathValue)) {
        throw [System.Exception]::new("Configuration key 'dsmc_path' must not be empty.")
    }
    $dsmcPath = Resolve-NarvikPath -Path $dsmcPathValue -BasePath $script:RootPath
    if (-not (Test-Path -LiteralPath $dsmcPath -PathType Leaf)) {
        throw [System.Exception]::new("dsmc executable not found: '$dsmcPath'.")
    }

    $dsmcOptFile = $null
    $dsmcOptFileValue = [string](Get-NarvikConfigValue -Config $config -Key 'dsmc_opt_file' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($dsmcOptFileValue)) {
        $dsmcOptFile = Resolve-NarvikPath -Path $dsmcOptFileValue -BasePath $script:RootPath
        if (-not (Test-Path -LiteralPath $dsmcOptFile -PathType Leaf)) {
            throw [System.Exception]::new("dsmc option file not found: '$dsmcOptFile'.")
        }
    }

    $dsmcAsnodename = [string](Get-NarvikConfigValue -Config $config -Key 'dsmc_asnodename' -Default '')

    $checkAdministratorPrivilege = ConvertTo-NarvikBoolean -Value (Get-NarvikConfigValue -Config $config -Key 'check_administrator_privilege' -Default $false) -KeyName 'check_administrator_privilege'

    $bypassSecurity = ConvertTo-NarvikBoolean -Value (Get-NarvikConfigValue -Config $config -Key 'bypass_security' -Default $false) -KeyName 'bypass_security'

    $dsmcUsePreview = ConvertTo-NarvikBoolean -Value (Get-NarvikConfigValue -Config $config -Key 'dsmc_use_preview' -Default $true) -KeyName 'dsmc_use_preview'

    $vcenterServer = [string](Get-NarvikConfigValue -Config $config -Key 'vcenter_server' -Required)
    if ([string]::IsNullOrWhiteSpace($vcenterServer)) {
        throw [System.Exception]::new("Configuration key 'vcenter_server' must not be empty.")
    }
    if ([Uri]::CheckHostName($vcenterServer) -eq [UriHostNameType]::Unknown) {
        throw [System.Exception]::new("Configuration key 'vcenter_server' must be a hostname or IP address without scheme, port or path; configure the port with 'vcenter_port'.")
    }

    $vcenterPortValue = Get-NarvikConfigValue -Config $config -Key 'vcenter_port' -Default 443
    $vcenterPort = 443
    try {
        $vcenterPort = [int]$vcenterPortValue
    }
    catch {
        throw [System.Exception]::new("Configuration key 'vcenter_port' must be an integer.")
    }
    if ($vcenterPort -lt 1 -or $vcenterPort -gt 65535) {
        throw [System.Exception]::new("Configuration key 'vcenter_port' must be between 1 and 65535.")
    }

    $vcenterUser = [string](Get-NarvikConfigValue -Config $config -Key 'vcenter_user' -Required)
    if ([string]::IsNullOrWhiteSpace($vcenterUser)) {
        throw [System.Exception]::new("Configuration key 'vcenter_user' must not be empty.")
    }

    $passwordFileValue = [string](Get-NarvikConfigValue -Config $config -Key 'vcenter_password_file' -Required)
    if ([string]::IsNullOrWhiteSpace($passwordFileValue)) {
        throw [System.Exception]::new("Configuration key 'vcenter_password_file' must not be empty.")
    }
    $vcenterPasswordFile = Resolve-NarvikPath -Path $passwordFileValue -BasePath $script:RootPath
    if (-not (Test-Path -LiteralPath $vcenterPasswordFile -PathType Leaf)) {
        throw [System.Exception]::new("vCenter password file not found: '$vcenterPasswordFile'.")
    }

    $vcenterIgnoreCertificate = ConvertTo-NarvikBoolean -Value (Get-NarvikConfigValue -Config $config -Key 'vcenter_ignore_certificate' -Default $false) -KeyName 'vcenter_ignore_certificate'

    $dontBackupBySnapshotTagName = [string](Get-NarvikConfigValue -Config $config -Key 'dont_backup_by_snapshot_tag_name')

    $datastoreClusterToManagementClass = @{}
    $managementClassValue = Get-NarvikConfigValue -Config $config -Key 'datastore_cluster_to_management_class'
    if ($null -ne $managementClassValue) {
        if ($managementClassValue -is [string] -or $managementClassValue -is [array] -or $managementClassValue -is [ValueType]) {
            throw [System.Exception]::new("Configuration key 'datastore_cluster_to_management_class' must be an object mapping datastore cluster names to management class names.")
        }
        foreach ($property in $managementClassValue.PSObject.Properties) {
            $clusterName = ([string]$property.Name).Trim()
            $managementClass = ([string]$property.Value).Trim()
            if ([string]::IsNullOrWhiteSpace($clusterName)) {
                throw [System.Exception]::new("Configuration key 'datastore_cluster_to_management_class' contains an empty datastore cluster name.")
            }
            if ([string]::IsNullOrWhiteSpace($managementClass)) {
                throw [System.Exception]::new("Configuration key 'datastore_cluster_to_management_class' contains an empty management class for datastore cluster '$clusterName'.")
            }
            $datastoreClusterToManagementClass[$clusterName.ToLowerInvariant()] = $managementClass
        }
    }

    # Per-cluster backup priority. The list is optional: clusters that are not
    # listed keep priority 0.
    $priorityClusters = @{}
    $priorityClustersValue = Get-NarvikConfigValue -Config $config -Key 'priority_clusters'
    if ($null -ne $priorityClustersValue) {
        $priorityClusterItems = @()
        if ($priorityClustersValue -is [array]) {
            $priorityClusterItems = @($priorityClustersValue)
        }
        elseif (-not ($priorityClustersValue -is [string]) -and -not ($priorityClustersValue -is [ValueType])) {
            # ConvertFrom-Json unwraps a JSON array with a single object, so a
            # one-entry 'priority_clusters' list arrives here as one object.
            $priorityClusterItems = @($priorityClustersValue)
        }
        else {
            throw [System.Exception]::new("Configuration key 'priority_clusters' must be an array of objects with 'cluster' and 'priority'.")
        }
        foreach ($item in $priorityClusterItems) {
            if ($null -eq $item -or $item -is [string] -or $item -is [array] -or $item -is [ValueType]) {
                throw [System.Exception]::new("Configuration key 'priority_clusters' must contain objects with 'cluster' and 'priority'.")
            }

            $clusterName = ''
            if ($null -ne $item.cluster) {
                $clusterName = ([string]$item.cluster).Trim()
            }
            if ([string]::IsNullOrWhiteSpace($clusterName)) {
                throw [System.Exception]::new("Configuration key 'priority_clusters' contains an entry without a non-empty 'cluster'.")
            }

            $clusterKey = $clusterName.ToLowerInvariant()
            if ($priorityClusters.ContainsKey($clusterKey)) {
                throw [System.Exception]::new("Configuration key 'priority_clusters' contains the cluster '$clusterName' more than once.")
            }

            if ($null -eq $item.priority) {
                throw [System.Exception]::new("Configuration key 'priority_clusters' requires a 'priority' for cluster '$clusterName'.")
            }
            $priorityText = ([string]$item.priority).Trim()
            if ($priorityText -notmatch '^-?[0-9]+$') {
                throw [System.Exception]::new("Configuration key 'priority_clusters' contains a non-integer priority for cluster '$clusterName'.")
            }
            $priority = 0
            try {
                $priority = [int]$priorityText
            }
            catch {
                throw [System.Exception]::new("Configuration key 'priority_clusters' contains a priority outside the supported integer range for cluster '$clusterName'.")
            }
            if ($priority -lt -100 -or $priority -gt 100) {
                throw [System.Exception]::new("Configuration key 'priority_clusters' contains priority $priority for cluster '$clusterName'; it must be between -100 and 100.")
            }

            $priorityClusters[$clusterKey] = [pscustomobject]@{
                cluster  = $clusterName
                priority = $priority
            }
        }
    }

    # Per-resource-pool backup priority, keyed by the cluster that owns the
    # resource pool. The list is optional: resource pools that are not listed,
    # and VMs outside a resource pool, keep priority 0.
    $priorityResourcePools = @{}
    $priorityResourcePoolsValue = Get-NarvikConfigValue -Config $config -Key 'priority_resource_pools'
    if ($null -ne $priorityResourcePoolsValue) {
        $priorityResourcePoolItems = @()
        if ($priorityResourcePoolsValue -is [array]) {
            $priorityResourcePoolItems = @($priorityResourcePoolsValue)
        }
        elseif (-not ($priorityResourcePoolsValue -is [string]) -and -not ($priorityResourcePoolsValue -is [ValueType])) {
            # ConvertFrom-Json unwraps a JSON array with a single object, so a
            # one-entry 'priority_resource_pools' list arrives here as one object.
            $priorityResourcePoolItems = @($priorityResourcePoolsValue)
        }
        else {
            throw [System.Exception]::new("Configuration key 'priority_resource_pools' must be an array of objects with 'cluster', 'resource_pool' and 'priority'.")
        }
        foreach ($item in $priorityResourcePoolItems) {
            if ($null -eq $item -or $item -is [string] -or $item -is [array] -or $item -is [ValueType]) {
                throw [System.Exception]::new("Configuration key 'priority_resource_pools' must contain objects with 'cluster', 'resource_pool' and 'priority'.")
            }

            $clusterName = ''
            if ($null -ne $item.cluster) {
                $clusterName = ([string]$item.cluster).Trim()
            }
            if ([string]::IsNullOrWhiteSpace($clusterName)) {
                throw [System.Exception]::new("Configuration key 'priority_resource_pools' contains an entry without a non-empty 'cluster'.")
            }

            $resourcePoolName = ''
            if ($null -ne $item.resource_pool) {
                $resourcePoolName = ([string]$item.resource_pool).Trim()
            }
            if ([string]::IsNullOrWhiteSpace($resourcePoolName)) {
                throw [System.Exception]::new("Configuration key 'priority_resource_pools' contains an entry without a non-empty 'resource_pool' for cluster '$clusterName'.")
            }

            $clusterKey = $clusterName.ToLowerInvariant()
            $resourcePoolKey = $resourcePoolName.ToLowerInvariant()
            if (-not $priorityResourcePools.ContainsKey($clusterKey)) {
                $priorityResourcePools[$clusterKey] = @{}
            }
            $clusterResourcePools = $priorityResourcePools[$clusterKey]
            if ($clusterResourcePools.ContainsKey($resourcePoolKey)) {
                throw [System.Exception]::new("Configuration key 'priority_resource_pools' contains resource pool '$resourcePoolName' in cluster '$clusterName' more than once.")
            }

            if ($null -eq $item.priority) {
                throw [System.Exception]::new("Configuration key 'priority_resource_pools' requires a 'priority' for resource pool '$resourcePoolName' in cluster '$clusterName'.")
            }
            $priorityText = ([string]$item.priority).Trim()
            if ($priorityText -notmatch '^-?[0-9]+$') {
                throw [System.Exception]::new("Configuration key 'priority_resource_pools' contains a non-integer priority for resource pool '$resourcePoolName' in cluster '$clusterName'.")
            }
            $priority = 0
            try {
                $priority = [int]$priorityText
            }
            catch {
                throw [System.Exception]::new("Configuration key 'priority_resource_pools' contains a priority outside the supported integer range for resource pool '$resourcePoolName' in cluster '$clusterName'.")
            }
            if ($priority -lt -100 -or $priority -gt 100) {
                throw [System.Exception]::new("Configuration key 'priority_resource_pools' contains priority $priority for resource pool '$resourcePoolName' in cluster '$clusterName'; it must be between -100 and 100.")
            }

            $clusterResourcePools[$resourcePoolKey] = [pscustomobject]@{
                cluster       = $clusterName
                resource_pool = $resourcePoolName
                priority      = $priority
            }
        }
    }

    # Per-cluster concurrency cap. The list is optional: clusters that are not
    # listed keep max_threads 1000, which means no practical cap beyond the
    # global one and the one-per-host rule.
    $clusterMaxThreads = @{}
    $clusterMaxThreadsValue = Get-NarvikConfigValue -Config $config -Key 'cluster_max_threads'
    if ($null -ne $clusterMaxThreadsValue) {
        $clusterMaxThreadItems = @()
        if ($clusterMaxThreadsValue -is [array]) {
            $clusterMaxThreadItems = @($clusterMaxThreadsValue)
        }
        elseif (-not ($clusterMaxThreadsValue -is [string]) -and -not ($clusterMaxThreadsValue -is [ValueType])) {
            # ConvertFrom-Json unwraps a JSON array with a single object, so a
            # one-entry 'cluster_max_threads' list arrives here as one object.
            $clusterMaxThreadItems = @($clusterMaxThreadsValue)
        }
        else {
            throw [System.Exception]::new("Configuration key 'cluster_max_threads' must be an array of objects with 'cluster' and 'max_threads'.")
        }
        foreach ($item in $clusterMaxThreadItems) {
            if ($null -eq $item -or $item -is [string] -or $item -is [array] -or $item -is [ValueType]) {
                throw [System.Exception]::new("Configuration key 'cluster_max_threads' must contain objects with 'cluster' and 'max_threads'.")
            }

            $clusterName = ''
            if ($null -ne $item.cluster) {
                $clusterName = ([string]$item.cluster).Trim()
            }
            if ([string]::IsNullOrWhiteSpace($clusterName)) {
                throw [System.Exception]::new("Configuration key 'cluster_max_threads' contains an entry without a non-empty 'cluster'.")
            }

            $clusterKey = $clusterName.ToLowerInvariant()
            if ($clusterMaxThreads.ContainsKey($clusterKey)) {
                throw [System.Exception]::new("Configuration key 'cluster_max_threads' contains the cluster '$clusterName' more than once.")
            }

            if ($null -eq $item.max_threads) {
                throw [System.Exception]::new("Configuration key 'cluster_max_threads' requires a 'max_threads' for cluster '$clusterName'.")
            }
            $maxThreadsText = ([string]$item.max_threads).Trim()
            if ($maxThreadsText -notmatch '^[0-9]+$') {
                throw [System.Exception]::new("Configuration key 'cluster_max_threads' contains a non-integer max_threads for cluster '$clusterName'.")
            }
            $maxThreads = 0
            try {
                $maxThreads = [int]$maxThreadsText
            }
            catch {
                throw [System.Exception]::new("Configuration key 'cluster_max_threads' contains max_threads outside the supported integer range for cluster '$clusterName'.")
            }
            if ($maxThreads -lt 1) {
                throw [System.Exception]::new("Configuration key 'cluster_max_threads' contains max_threads $maxThreads for cluster '$clusterName'; it must be at least 1.")
            }

            $clusterMaxThreads[$clusterKey] = [pscustomobject]@{
                cluster     = $clusterName
                max_threads = $maxThreads
            }
        }
    }

    $smtpServer = [string](Get-NarvikConfigValue -Config $config -Key 'smtp_server' -Default '')
    $smtpPort = 25
    $smtpUseSsl = $false
    $smtpUsername = ''
    $smtpPasswordFile = $null
    $mailFrom = ''
    $mailTo = @()

    if (-not [string]::IsNullOrWhiteSpace($smtpServer)) {
        $smtpPortValue = Get-NarvikConfigValue -Config $config -Key 'smtp_port' -Default 25
        try {
            $smtpPort = [int]$smtpPortValue
        }
        catch {
            throw [System.Exception]::new("Configuration key 'smtp_port' must be an integer.")
        }
        if ($smtpPort -lt 1 -or $smtpPort -gt 65535) {
            throw [System.Exception]::new("Configuration key 'smtp_port' must be between 1 and 65535.")
        }

        $smtpUseSsl = ConvertTo-NarvikBoolean -Value (Get-NarvikConfigValue -Config $config -Key 'smtp_use_ssl' -Default $false) -KeyName 'smtp_use_ssl'
        $smtpUsername = [string](Get-NarvikConfigValue -Config $config -Key 'smtp_username' -Default '')
        $smtpPasswordFileValue = [string](Get-NarvikConfigValue -Config $config -Key 'smtp_password_file' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($smtpPasswordFileValue)) {
            $smtpPasswordFile = Resolve-NarvikPath -Path $smtpPasswordFileValue -BasePath $script:RootPath
            if (-not (Test-Path -LiteralPath $smtpPasswordFile -PathType Leaf)) {
                throw [System.Exception]::new("SMTP password file not found: '$smtpPasswordFile'.")
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($smtpUsername) -and [string]::IsNullOrWhiteSpace($smtpPasswordFileValue)) {
            throw [System.Exception]::new("Configuration key 'smtp_password_file' is required when 'smtp_username' is set.")
        }

        $mailFrom = [string](Get-NarvikConfigValue -Config $config -Key 'mail_from' -Required)
        if ([string]::IsNullOrWhiteSpace($mailFrom)) {
            throw [System.Exception]::new("Configuration key 'mail_from' must not be empty.")
        }

        $mailToValue = Get-NarvikConfigValue -Config $config -Key 'mail_to' -Required
        $mailTo = @($mailToValue | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($mailTo.Count -eq 0) {
            throw [System.Exception]::new("Configuration key 'mail_to' must contain at least one email address.")
        }

        $emailPattern = '^[^@\s]+@[^@\s]+\.[^@\s]+$'
        if ($mailFrom -notmatch $emailPattern) {
            throw [System.Exception]::new("Configuration key 'mail_from' is not a valid email address: '$mailFrom'.")
        }
        foreach ($address in $mailTo) {
            if ($address -notmatch $emailPattern) {
                throw [System.Exception]::new("Configuration key 'mail_to' contains an invalid email address: '$address'.")
            }
        }
    }

    $maxThreadsValue = Get-NarvikConfigValue -Config $config -Key 'max_backup_threads' -Required
    $maxThreads = 0
    try {
        $maxThreads = [int]$maxThreadsValue
    }
    catch {
        throw [System.Exception]::new("Configuration key 'max_backup_threads' must be an integer.")
    }
    if ($maxThreads -lt 1) {
        throw [System.Exception]::new("Configuration key 'max_backup_threads' must be at least 1.")
    }

    return [pscustomobject]@{
        debug                                 = $debug
        check_administrator_privilege         = $checkAdministratorPrivilege
        bypass_security                       = $bypassSecurity
        dsmc_path                             = $dsmcPath
        dsmc_opt_file                         = $dsmcOptFile
        dsmc_asnodename                       = $dsmcAsnodename
        dsmc_use_preview                      = $dsmcUsePreview
        vcenter_server                        = $vcenterServer
        vcenter_port                          = $vcenterPort
        vcenter_user                          = $vcenterUser
        vcenter_password_file                 = $vcenterPasswordFile
        vcenter_ignore_certificate            = $vcenterIgnoreCertificate
        dont_backup_by_snapshot_tag_name      = $dontBackupBySnapshotTagName
        datastore_cluster_to_management_class = $datastoreClusterToManagementClass
        priority_clusters                     = $priorityClusters
        priority_resource_pools               = $priorityResourcePools
        cluster_max_threads                   = $clusterMaxThreads
        smtp_server                           = $smtpServer
        smtp_port                             = $smtpPort
        smtp_use_ssl                          = $smtpUseSsl
        smtp_username                         = $smtpUsername
        smtp_password_file                    = $smtpPasswordFile
        mail_from                             = $mailFrom
        mail_to                               = $mailTo
        max_backup_threads                    = $maxThreads
    }
}

function Get-NarvikVCenterFingerprint {
    param(
        [Parameter(Mandatory = $true)]
        $Config
    )

    $passwordWriteTime = ''
    if (-not [string]::IsNullOrWhiteSpace($Config.vcenter_password_file) -and (Test-Path -LiteralPath $Config.vcenter_password_file -PathType Leaf)) {
        $passwordWriteTime = (Get-Item -LiteralPath $Config.vcenter_password_file).LastWriteTimeUtc.ToString('o')
    }

    return "$($Config.vcenter_server)|$($Config.vcenter_port)|$($Config.vcenter_user)|$($Config.vcenter_password_file)|$passwordWriteTime"
}

function Update-NarvikRuntimeConfig {
    $configPath = Join-Path $script:RootPath 'config.json'

    try {
        $newConfig = Import-NarvikConfig -Path $configPath

        if (-not $newConfig.bypass_security) {
            Assert-NarvikPathAcl -Path $configPath -Mode Write -Description 'Configuration file'
            Assert-NarvikPathAcl -Path (Split-Path -Parent $configPath) -Mode Write -Description 'Configuration directory'
            Assert-NarvikPathAcl -Path $newConfig.vcenter_password_file -Mode Read -Description 'vCenter password file'

            if (-not [string]::IsNullOrWhiteSpace($newConfig.smtp_password_file)) {
                Assert-NarvikPathAcl -Path $newConfig.smtp_password_file -Mode Read -Description 'SMTP password file'
            }
        }

        $oldFingerprint = $script:VCenterFingerprint
        $newFingerprint = Get-NarvikVCenterFingerprint -Config $newConfig

        $script:Config = $newConfig
        $newLogLevel = 'INFO'
        if ($newConfig.debug) {
            $newLogLevel = 'DEBUG'
        }
        $logLevelChanged = ($newLogLevel -ne $script:LogLevel)
        $script:LogLevel = $newLogLevel
        if ($logLevelChanged) {
            if ($newLogLevel -eq 'DEBUG') {
                Write-NarvikLog -Level INFO -Message 'Debug logging enabled by configuration.'
            }
            else {
                Write-NarvikLog -Level INFO -Message 'Debug logging disabled by configuration.'
            }
        }

        if ($null -ne $oldFingerprint -and $oldFingerprint -ne $newFingerprint) {
            Write-NarvikLog -Level INFO -Message 'vCenter connection settings changed; invalidating cached inventory.'
            $script:VCache = $null
        }

        $script:VCenterFingerprint = $newFingerprint
        $script:LastConfigError = ''
    }
    catch [System.UnauthorizedAccessException] {
        throw
    }
    catch {
        if ($null -eq $script:Config) {
            throw
        }

        $errorMessage = $_.Exception.Message
        if ($errorMessage -ne $script:LastConfigError) {
            Write-NarvikLog -Level ERROR -Message "Configuration reload failed; keeping the previous configuration: $errorMessage"
            $script:LastConfigError = $errorMessage
        }
    }
}
