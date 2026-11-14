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
    Mandatory root directory. When it is omitted, Narvik writes an error to
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
$script:IndependentDisks = @()
$script:DuplicateGuid = @{}
$script:State = @{
    failed_attempts = @{}
    duplicate_guid = @()
    last_idle = $null
    duplicate_name_alerts = @{}
    inventory_rule_alerts = @{}
    disk_size_alerts = @{}
}
$script:ProcessLockStream = $null
$script:ProcessLockFile = $null
$script:StopRequested = $false
$script:AbortRequested = $false
$script:LastStatsLog = [datetime]::MinValue
$script:LastStatsSignature = ''
$script:FatalExitCode = 0
$script:Initialized = $false
$script:ExitCode = 0
$script:NonEligibleSignature = ''
$script:LastConfigError = ''

function Write-NarvikLog {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Message,

        [ValidateSet('DEBUG', 'INFO', 'WARNING', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $levelOrder = @{ DEBUG = 0; INFO = 1; WARNING = 2; ERROR = 3 }
    $configured = 'INFO'
    if ($null -ne $script:LogLevel -and $levelOrder.ContainsKey($script:LogLevel)) {
        $configured = $script:LogLevel
    }

    if ($levelOrder[$Level] -lt $levelOrder[$configured]) {
        return
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $messageLines = @($Message -split "\r?\n")
    foreach ($messageLine in $messageLines) {
        $entry = "$timestamp [$Level] $messageLine"

        if ($script:LogToStdout -or $null -eq $script:LogWriter) {
            try {
                [Console]::WriteLine($entry)
            }
            catch {
                Write-Host $entry
            }

            if ($null -ne $script:StartupLog -and $script:StartupLog.Count -lt 5000) {
                [void]$script:StartupLog.Add($entry)
            }
        }
        else {
            try {
                $script:LogWriter.WriteLine($entry)
                $script:LogWriter.Flush()
            }
            catch {
                try { [Console]::WriteLine($entry) } catch { Write-Host $entry }
            }
        }
    }
}

function Write-NarvikAtomicText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content
    )

    $directory = Split-Path -Parent $Path
    $tempPath = $null

    try {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $directory -ErrorAction Stop | Out-Null
        }

        $tempPath = Join-Path $directory ('.narvik_' + [System.IO.Path]::GetRandomFileName())
        $encoding = New-Object System.Text.UTF8Encoding -ArgumentList $false
        [System.IO.File]::WriteAllText($tempPath, $Content, $encoding)

        try {
            Move-Item -LiteralPath $tempPath -Destination $Path -Force -ErrorAction Stop
            $tempPath = $null
        }
        catch {
            [System.IO.File]::WriteAllText($Path, $Content, $encoding)
        }
    }
    catch {
        Write-NarvikLog -Level ERROR -Message "Failed to write file '$Path': $($_.Exception.Message)"
    }
    finally {
        if (-not [string]::IsNullOrWhiteSpace($tempPath) -and (Test-Path -LiteralPath $tempPath -PathType Leaf)) {
            try { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
}

function Resolve-NarvikPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$BasePath
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}

function ConvertTo-NarvikBoolean {
    param(
        [Parameter(Mandatory = $true)]
        $Value,

        [Parameter(Mandatory = $true)]
        [string]$KeyName
    )

    if ($Value -is [bool]) {
        return $Value
    }

    if ($Value -is [string]) {
        if ($Value -ieq 'true') { return $true }
        if ($Value -ieq 'false') { return $false }
    }

    throw [System.Exception]::new("Configuration key '$KeyName' must be true or false.")
}

function Get-NarvikConfigValue {
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        [string]$Key,

        $Default = $null,

        [switch]$Required
    )

    if ($null -ne $Config -and $Config.PSObject.Properties.Name -contains $Key) {
        return $Config.$Key
    }

    if ($Required) {
        throw [System.Exception]::new("Missing required configuration key '$Key'.")
    }

    return $Default
}

function Get-NarvikAdminSids {
    return @(
        'S-1-5-18',
        'S-1-5-32-544',
        'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
    )
}

function Get-NarvikSidFromName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    try {
        $account = New-Object System.Security.Principal.NTAccount -ArgumentList $Name
        return $account.Translate([System.Security.Principal.SecurityIdentifier]).Value
    }
    catch {
        return $null
    }
}

function Get-NarvikCurrentSid {
    try {
        return [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    }
    catch {
        return $null
    }
}

function Assert-NarvikPathAcl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Write', 'Read')]
        [string]$Mode,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    try {
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    }
    catch {
        throw [System.UnauthorizedAccessException]::new("Unable to read ACL for $Description '$Path': $($_.Exception.Message)")
    }

    $adminSids = Get-NarvikAdminSids
    $currentSid = Get-NarvikCurrentSid
    $ownerSid = Get-NarvikSidFromName -Name $acl.Owner

    if ($ownerSid -and ($adminSids -notcontains $ownerSid) -and $ownerSid -ne $currentSid) {
        Write-NarvikLog -Level WARNING -Message "File or directory '$Path' is owned by '$($acl.Owner)'; verify that this principal is an administrator."
    }

    $writeMask = [System.Security.AccessControl.FileSystemRights]::Write -bor `
        [System.Security.AccessControl.FileSystemRights]::Modify -bor `
        [System.Security.AccessControl.FileSystemRights]::FullControl -bor `
        [System.Security.AccessControl.FileSystemRights]::Delete -bor `
        [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor `
        [System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor `
        [System.Security.AccessControl.FileSystemRights]::TakeOwnership -bor `
        [System.Security.AccessControl.FileSystemRights]::WriteData -bor `
        [System.Security.AccessControl.FileSystemRights]::AppendData -bor `
        [System.Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor `
        [System.Security.AccessControl.FileSystemRights]::WriteAttributes

    $readMask = [System.Security.AccessControl.FileSystemRights]::Read -bor `
        [System.Security.AccessControl.FileSystemRights]::ReadAndExecute -bor `
        [System.Security.AccessControl.FileSystemRights]::Modify -bor `
        [System.Security.AccessControl.FileSystemRights]::FullControl -bor `
        [System.Security.AccessControl.FileSystemRights]::ReadData -bor `
        [System.Security.AccessControl.FileSystemRights]::ReadAttributes -bor `
        [System.Security.AccessControl.FileSystemRights]::ReadExtendedAttributes -bor `
        [System.Security.AccessControl.FileSystemRights]::ReadPermissions

    foreach ($rule in $acl.Access) {
        if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) {
            continue
        }

        $ruleSid = $null
        try {
            $ruleSid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
        }
        catch {
            continue
        }

        if ($adminSids -contains $ruleSid) {
            continue
        }

        if ($ruleSid -eq $currentSid) {
            continue
        }

        if ($ruleSid -eq 'S-1-3-0' -and $ownerSid -and ($adminSids -contains $ownerSid -or $ownerSid -eq $currentSid)) {
            continue
        }

        $hasRight = $false
        if ($Mode -eq 'Write') {
            $hasRight = (($rule.FileSystemRights -band $writeMask) -ne 0)
        }
        else {
            $hasRight = (($rule.FileSystemRights -band $readMask) -ne 0)
        }

        if ($hasRight) {
            throw [System.UnauthorizedAccessException]::new("$Description '$Path' grants $Mode access to non-administrator principal '$($rule.IdentityReference.Value)'.")
        }
    }
}

function Test-NarvikIsAdministrator {
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal -ArgumentList $identity
        $isAdmin = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
        $isSystem = $identity.Name -eq 'NT AUTHORITY\SYSTEM' -or $identity.Name -eq 'SYSTEM'
        return ($isAdmin -or $isSystem)
    }
    catch {
        return $false
    }
}

function Throw-NarvikFatal {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [int]$Code = 1
    )

    $script:FatalExitCode = $Code
    throw [System.Exception]::new($Message)
}

function Read-NarvikPasswordFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw [System.Exception]::new("Password file not found: '$Path'.")
    }

    $value = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    return $value.TrimEnd([char]13, [char]10)
}

function Test-NarvikMailEnabled {
    if ($null -eq $script:Config) {
        return $false
    }

    return -not [string]::IsNullOrWhiteSpace([string]$script:Config.smtp_server)
}

function Send-NarvikMail {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Subject,

        [Parameter(Mandatory = $true)]
        [string]$Body,

        [string[]]$Attachments = @()
    )

    if (-not (Test-NarvikMailEnabled)) {
        Write-NarvikLog -Level DEBUG -Message "SMTP server is not configured; email '$Subject' skipped."
        return $false
    }

    try {
        $parameters = @{
            SmtpServer = $script:Config.smtp_server
            Port       = $script:Config.smtp_port
            From       = $script:Config.mail_from
            To         = $script:Config.mail_to
            Subject    = $Subject
            Body       = $Body
            Encoding   = [System.Text.Encoding]::UTF8
            ErrorAction = 'Stop'
        }

        if ($script:Config.smtp_use_ssl) {
            $parameters.UseSsl = $true
        }

        if (-not [string]::IsNullOrWhiteSpace($script:Config.smtp_username)) {
            $password = Read-NarvikPasswordFile -Path $script:Config.smtp_password_file
            $secure = ConvertTo-SecureString -String $password -AsPlainText -Force
            $parameters.Credential = New-Object System.Management.Automation.PSCredential -ArgumentList $script:Config.smtp_username, $secure
        }

        if ($null -ne $Attachments -and $Attachments.Count -gt 0) {
            $parameters.Attachments = $Attachments
        }

        Send-MailMessage @parameters
        return $true
    }
    catch {
        Write-NarvikLog -Level ERROR -Message "Failed to send email '$Subject': $($_.Exception.Message)"
        return $false
    }
}

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
        'log_level',
        'check_administrator_privilege',
        'bypass_security',
        'dsmc_path',
        'dsmc_use_preview',
        'vcenter_server',
        'vcenter_port',
        'vcenter_user',
        'vcenter_password_file',
        'vcenter_ignore_certificate',
        'dont_backup_by_snapshot_tag_name',
        'datastore_cluster_to_management_class',
        'priority_clusters',
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
            Write-NarvikLog -Level WARNING -Message "Unknown configuration key '$propertyName' will be ignored."
        }
    }

    $logLevel = [string](Get-NarvikConfigValue -Config $config -Key 'log_level' -Required)
    $logLevel = $logLevel.ToUpperInvariant()
    if (@('DEBUG', 'INFO', 'WARNING', 'ERROR') -notcontains $logLevel) {
        throw [System.Exception]::new("Configuration key 'log_level' must be Debug, Info, Warning or Error.")
    }

    $dsmcPathValue = [string](Get-NarvikConfigValue -Config $config -Key 'dsmc_path' -Required)
    if ([string]::IsNullOrWhiteSpace($dsmcPathValue)) {
        throw [System.Exception]::new("Configuration key 'dsmc_path' must not be empty.")
    }
    $dsmcPath = Resolve-NarvikPath -Path $dsmcPathValue -BasePath $script:RootPath
    if (-not (Test-Path -LiteralPath $dsmcPath -PathType Leaf)) {
        throw [System.Exception]::new("dsmc executable not found: '$dsmcPath'.")
    }

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

    # Per-cluster backup priority and concurrency cap. The list is optional:
    # clusters that are not listed keep priority 0 and max_threads 1000, which
    # means no practical cap beyond the global one and the one-per-host rule.
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
            throw [System.Exception]::new("Configuration key 'priority_clusters' must be an array of objects with 'name', 'priority' and optional 'max_threads'.")
        }
        foreach ($item in $priorityClusterItems) {
            if ($null -eq $item -or $item -is [string] -or $item -is [array] -or $item -is [ValueType]) {
                throw [System.Exception]::new("Configuration key 'priority_clusters' must contain objects with 'name', 'priority' and optional 'max_threads'.")
            }

            $clusterName = ''
            if ($null -ne $item.name) {
                $clusterName = ([string]$item.name).Trim()
            }
            if ([string]::IsNullOrWhiteSpace($clusterName)) {
                throw [System.Exception]::new("Configuration key 'priority_clusters' contains an entry without a non-empty 'name'.")
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

            $maxThreads = 1000
            if ($null -ne $item.max_threads) {
                $maxThreadsText = ([string]$item.max_threads).Trim()
                if ($maxThreadsText -notmatch '^[0-9]+$') {
                    throw [System.Exception]::new("Configuration key 'priority_clusters' contains a non-integer max_threads for cluster '$clusterName'.")
                }
                try {
                    $maxThreads = [int]$maxThreadsText
                }
                catch {
                    throw [System.Exception]::new("Configuration key 'priority_clusters' contains max_threads outside the supported integer range for cluster '$clusterName'.")
                }
                if ($maxThreads -lt 1) {
                    throw [System.Exception]::new("Configuration key 'priority_clusters' contains max_threads $maxThreads for cluster '$clusterName'; it must be at least 1.")
                }
            }

            $priorityClusters[$clusterKey] = [pscustomobject]@{
                name        = $clusterName
                priority    = $priority
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
        log_level                             = $logLevel
        check_administrator_privilege         = $checkAdministratorPrivilege
        bypass_security                       = $bypassSecurity
        dsmc_path                             = $dsmcPath
        dsmc_use_preview                      = $dsmcUsePreview
        vcenter_server                        = $vcenterServer
        vcenter_port                          = $vcenterPort
        vcenter_user                          = $vcenterUser
        vcenter_password_file                 = $vcenterPasswordFile
        vcenter_ignore_certificate            = $vcenterIgnoreCertificate
        dont_backup_by_snapshot_tag_name      = $dontBackupBySnapshotTagName
        datastore_cluster_to_management_class = $datastoreClusterToManagementClass
        priority_clusters                     = $priorityClusters
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

function ConvertFrom-NarvikIsoDate {
    param(
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    try {
        return [datetime]::Parse($Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
    }
    catch {
        return $null
    }
}

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

function ConvertFrom-NarvikVmNotes {
    param(
        [string]$Notes
    )

    if ([string]::IsNullOrWhiteSpace($Notes)) {
        return $null
    }

    # dsmc writes exactly one of these tags after a successful backup:
    #   <Backup incremental successful in dd/MM/yyyy HH:mm:ss>
    #   <Backup full successful in dd/MM/yyyy HH:mm:ss>
    # The timestamp format and the word 'successful' are mandatory. Anything
    # that does not match this fixed shape is ignored.
    $pattern = '(?i)<Backup (incremental|full) successful in (\d{2}/\d{2}/\d{4} \d{2}:\d{2}:\d{2})>'
    $incrementalDate = $null
    $fullDate = $null

    foreach ($match in [regex]::Matches($Notes, $pattern)) {
        $mode = $match.Groups[1].Value.ToLowerInvariant()
        $timestampText = $match.Groups[2].Value
        $parsed = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($timestampText, 'dd/MM/yyyy HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
            continue
        }

        if ($mode -eq 'incremental') {
            if ($null -eq $incrementalDate -or $parsed -gt $incrementalDate) {
                $incrementalDate = $parsed
            }
        }
        elseif ($null -eq $fullDate -or $parsed -gt $fullDate) {
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

function Get-NarvikUniquePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $Path
    }

    $directory = Split-Path -Parent $Path
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $extension = [System.IO.Path]::GetExtension($Path)

    for ($index = 1; $index -lt 10000; $index++) {
        $candidate = Join-Path $directory ("${baseName}_$index$extension")
        if (-not (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    return $Path
}

function Initialize-NarvikLog {
    $logDirectory = Join-Path $script:RootPath 'log/narvik'
    $oldDirectory = Join-Path $logDirectory 'old'
    New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
    New-Item -ItemType Directory -Force -Path $oldDirectory | Out-Null

    $logFile = Join-Path $logDirectory 'log.txt'
    if (Test-Path -LiteralPath $logFile -PathType Leaf) {
        $lastWrite = (Get-Item -LiteralPath $logFile).LastWriteTime
        $dateDirectory = Join-Path $oldDirectory $lastWrite.ToString('yyyy_MM_dd')
        New-Item -ItemType Directory -Force -Path $dateDirectory | Out-Null

        $destination = Join-Path $dateDirectory ('log_' + $lastWrite.ToString('HH_mm_ss') + '.txt')
        $destination = Get-NarvikUniquePath -Path $destination

        try {
            Move-Item -LiteralPath $logFile -Destination $destination -Force -ErrorAction Stop
        }
        catch {
            throw [System.Exception]::new("Failed to rotate existing log file '$logFile': $($_.Exception.Message)")
        }
    }

    $script:LogFilePath = $logFile
    $script:LogWriter = [System.IO.File]::CreateText($logFile)
    $script:LogWriter.AutoFlush = $true
    $script:LogToStdout = $false
}

function Rotate-NarvikLog {
    if ($null -eq $script:LogWriter -or [string]::IsNullOrWhiteSpace($script:LogFilePath)) {
        return
    }

    $currentLog = $script:LogFilePath
    $lastWrite = Get-Date
    try {
        if (Test-Path -LiteralPath $currentLog -PathType Leaf) {
            $lastWrite = (Get-Item -LiteralPath $currentLog).LastWriteTime
        }
    }
    catch {
    }

    try {
        $script:LogWriter.Flush()
        $script:LogWriter.Close()
    }
    catch {
    }
    $script:LogWriter = $null

    $oldDirectory = Join-Path $script:RootPath ('log/narvik/old/' + $lastWrite.ToString('yyyy_MM_dd'))
    New-Item -ItemType Directory -Force -Path $oldDirectory | Out-Null
    $destination = Join-Path $oldDirectory ('log_' + $lastWrite.ToString('HH_mm_ss') + '.txt')
    $destination = Get-NarvikUniquePath -Path $destination

    try {
        Move-Item -LiteralPath $currentLog -Destination $destination -Force -ErrorAction Stop
    }
    catch {
        try {
            $script:LogWriter = [System.IO.File]::AppendText($currentLog)
            $script:LogWriter.AutoFlush = $true
        }
        catch {
        }
        Write-NarvikLog -Level ERROR -Message "Failed to rotate log file '$currentLog': $($_.Exception.Message)"
        return
    }

    try {
        $script:LogWriter = [System.IO.File]::CreateText($currentLog)
        $script:LogWriter.AutoFlush = $true
    }
    catch {
        $script:LogWriter = $null
        $script:LogToStdout = $true
        Write-NarvikLog -Level ERROR -Message "Failed to create new log file '$currentLog': $($_.Exception.Message)"
        return
    }

    Write-NarvikLog -Level INFO -Message "Log rotated to '$destination'."
}

function Close-NarvikLogWriter {
    if ($null -ne $script:LogWriter) {
        try {
            $script:LogWriter.Flush()
            $script:LogWriter.Close()
        }
        catch {
        }
        $script:LogWriter = $null
    }
}

function Initialize-NarvikDirectories {
    $script:ControlDir = Join-Path $script:RootPath 'control'
    $script:LogDir = Join-Path $script:RootPath 'log/narvik'
    $script:VmLogDir = Join-Path $script:RootPath 'log/vm'
    $script:MonitoringDir = Join-Path $script:RootPath 'monitoring'

    New-Item -ItemType Directory -Force -Path $script:ControlDir | Out-Null
    New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $script:LogDir 'old') | Out-Null
    New-Item -ItemType Directory -Force -Path $script:VmLogDir | Out-Null
    New-Item -ItemType Directory -Force -Path $script:MonitoringDir | Out-Null
}

function Acquire-NarvikProcessLock {
    $processFile = Join-Path $script:ControlDir 'process.txt'
    $script:ProcessLockFile = $processFile

    $currentProcess = [System.Diagnostics.Process]::GetCurrentProcess()
    $currentName = $currentProcess.ProcessName
    $currentStart = $currentProcess.StartTime.ToString('o')

    $processInfo = [pscustomobject]@{
        pid        = $PID
        name       = $currentName
        started_at = $currentStart
    }
    $json = $processInfo | ConvertTo-Json -Depth 5

    if (Test-Path -LiteralPath $processFile -PathType Leaf) {
        $stale = $true
        try {
            $existing = Get-Content -LiteralPath $processFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $existing -and $null -ne $existing.pid) {
                $existingPid = [int]$existing.pid
                $existingName = [string]$existing.name
                $existingStart = $null
                if ($null -ne $existing.started_at) {
                    $existingStart = ConvertFrom-NarvikIsoDate -Value ([string]$existing.started_at)
                }

                $alive = Get-Process -Id $existingPid -ErrorAction SilentlyContinue
                if ($null -ne $alive) {
                    $nameMatches = ($alive.ProcessName -ieq $existingName)
                    $startMatches = $true
                    if ($null -ne $existingStart) {
                        try {
                            $startMatches = ([math]::Abs(($alive.StartTime - $existingStart).TotalSeconds) -lt 5)
                        }
                        catch {
                            $startMatches = $true
                        }
                    }

                    if ($nameMatches -and $startMatches) {
                        Throw-NarvikFatal -Message "Another Narvik instance is already running with PID $existingPid and executable '$existingName'." -Code 3
                    }
                }
            }
        }
        catch [System.Exception] {
            if ($_.Exception.Message -like 'Another Narvik instance*') {
                throw
            }
            Write-NarvikLog -Level WARNING -Message "Existing process control file '$processFile' is invalid and will be replaced."
        }

        if ($stale) {
            try {
                Remove-Item -LiteralPath $processFile -Force -ErrorAction Stop
            }
            catch {
                Throw-NarvikFatal -Message "Cannot remove stale process control file '$processFile': $($_.Exception.Message)" -Code 1
            }
        }
    }

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $stream = [System.IO.File]::Open($processFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
            $script:ProcessLockStream = $stream
            return
        }
        catch {
            if ($attempt -eq 3) {
                Throw-NarvikFatal -Message "Cannot create process control file '$processFile': $($_.Exception.Message)" -Code 3
            }
            Start-Sleep -Milliseconds 200
        }
    }
}

function Release-NarvikProcessLock {
    if ($null -ne $script:ProcessLockStream) {
        try {
            $script:ProcessLockStream.Close()
        }
        catch {
        }
        $script:ProcessLockStream = $null
    }

    if ($null -eq $script:ProcessLockFile -or -not (Test-Path -LiteralPath $script:ProcessLockFile -PathType Leaf)) {
        return
    }

    try {
        $existing = Get-Content -LiteralPath $script:ProcessLockFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($null -ne $existing -and [int]$existing.pid -eq $PID) {
            Remove-Item -LiteralPath $script:ProcessLockFile -Force -ErrorAction Stop
        }
    }
    catch {
    }
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
        $script:LogLevel = $newConfig.log_level.ToUpperInvariant()

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

function Initialize-Narvik {
    $rootValue = $script:RootPathArgument
    if ([string]::IsNullOrWhiteSpace($rootValue)) {
        Throw-NarvikFatal -Message 'The root directory parameter is required. Usage: Narvik.ps1 -RootPath <directory>.' -Code 1
    }

    if ($PSVersionTable.PSVersion -lt [Version]'5.1') {
        Throw-NarvikFatal -Message "Narvik requires PowerShell 5.1 or later; detected version $($PSVersionTable.PSVersion)." -Code 1
    }

    try {
        $script:RootPath = [System.IO.Path]::GetFullPath($rootValue)
    }
    catch {
        Throw-NarvikFatal -Message "Invalid root directory '$rootValue': $($_.Exception.Message)" -Code 1
    }

    if (-not (Test-Path -LiteralPath $script:RootPath -PathType Container)) {
        try {
            New-Item -ItemType Directory -Force -Path $script:RootPath -ErrorAction Stop | Out-Null
        }
        catch {
            Throw-NarvikFatal -Message "Cannot create root directory '$($script:RootPath)': $($_.Exception.Message)" -Code 1
        }
    }

    try {
        $probe = Join-Path $script:RootPath ('.narvik_write_test_' + [System.IO.Path]::GetRandomFileName())
        [System.IO.File]::WriteAllText($probe, 'test')
        Remove-Item -LiteralPath $probe -Force -ErrorAction Stop
    }
    catch {
        Throw-NarvikFatal -Message "Root directory '$($script:RootPath)' is not writable: $($_.Exception.Message)" -Code 1
    }

    Initialize-NarvikDirectories
    Acquire-NarvikProcessLock
    Initialize-NarvikLog

    Load-NarvikState
    Load-NarvikLastFull
    Load-NarvikIndependentDisks

    Update-NarvikRuntimeConfig

    if ($script:Config.check_administrator_privilege) {
        if (-not (Test-NarvikIsAdministrator)) {
            Throw-NarvikFatal -Message 'Narvik must run as NT AUTHORITY\SYSTEM or as a member of the Administrators group.' -Code 1
        }
    }
    else {
        Write-NarvikLog -Level INFO -Message 'Administrator privilege check is disabled by configuration.'
    }

    if ($script:Config.bypass_security) {
        Write-NarvikLog -Level WARNING -Message 'File ACL checks are disabled by configuration (bypass_security).'
    }

    $powerCliModule = Get-Module -ListAvailable -Name 'VMware.VimAutomation.Core' | Select-Object -First 1
    if ($null -eq $powerCliModule) {
        Throw-NarvikFatal -Message "VMware PowerCLI module 'VMware.VimAutomation.Core' is not installed." -Code 1
    }

    try {
        Import-Module 'VMware.VimAutomation.Core' -ErrorAction Stop
    }
    catch {
        Throw-NarvikFatal -Message "Failed to import VMware PowerCLI: $($_.Exception.Message)" -Code 1
    }

    Write-NarvikLog -Level INFO -Message "Narvik $($script:ScriptVersion) starting."
    Write-NarvikLog -Level INFO -Message "Root directory: '$($script:RootPath)'."
    Write-NarvikLog -Level INFO -Message "Process ID: $PID."
    Write-NarvikLog -Level INFO -Message "Log level: $($script:Config.log_level)."
    Write-NarvikLog -Level INFO -Message "vCenter: '$($script:Config.vcenter_server):$($script:Config.vcenter_port)' as '$($script:Config.vcenter_user)'."
    Write-NarvikLog -Level INFO -Message "dsmc: '$($script:Config.dsmc_path)'; preview mode: $($script:Config.dsmc_use_preview)."
    Write-NarvikLog -Level INFO -Message "Maximum concurrent backups: $($script:Config.max_backup_threads)."

    if ($script:Config.vcenter_ignore_certificate) {
        Write-NarvikLog -Level WARNING -Message 'vCenter certificate validation is disabled by configuration.'
    }
}

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

function Get-NarvikMoRefTags {
    param(
        [AllowEmptyString()]
        [string]$MoRefValue,
        [hashtable]$TagMap
    )

    if ([string]::IsNullOrWhiteSpace($MoRefValue) -or $null -eq $TagMap) {
        return @()
    }

    if ($TagMap.ContainsKey($MoRefValue)) {
        return @($TagMap[$MoRefValue])
    }

    return @()
}

function Get-NarvikViewTags {
    param(
        $View,
        [hashtable]$TagMap
    )

    if ($null -eq $View -or $null -eq $View.MoRef) {
        return @()
    }

    return @(Get-NarvikMoRefTags -MoRefValue ([string]$View.MoRef.Value) -TagMap $TagMap)
}

function Get-NarvikFolderPath {
    param(
        [string]$FolderId,
        [hashtable]$FolderMap
    )

    if ([string]::IsNullOrWhiteSpace($FolderId)) {
        return ''
    }

    $parts = New-Object 'System.Collections.Generic.List[string]'
    $seen = @{}
    $current = $FolderId

    while (-not [string]::IsNullOrWhiteSpace($current) -and $FolderMap.ContainsKey($current) -and -not $seen.ContainsKey($current)) {
        $seen[$current] = $true
        $folder = $FolderMap[$current]
        $name = [string]$folder.Name
        if (-not [string]::IsNullOrWhiteSpace($name) -and @('vm', 'Datacenters', 'VMs') -notcontains $name) {
            $parts.Insert(0, $name)
        }

        if ($null -ne $folder.Parent) {
            $current = [string]$folder.Parent.Value
        }
        else {
            $current = $null
        }
    }

    return ($parts -join '/')
}

function Test-NarvikSiteRecoveryPlaceholder {
    param(
        $View
    )

    # VMware Live Site Recovery (formerly Site Recovery Manager) creates placeholder
    # VMs at the recovery site. They are marked in vCenter through Config.ManagedBy
    # with an extension key starting with 'com.vmware.vcDr' and type 'placeholderVm'.
    if ($null -eq $View -or $null -eq $View.Config) {
        return $false
    }

    $managedBy = $View.Config.ManagedBy
    if ($null -eq $managedBy) {
        return $false
    }

    if ([string]$managedBy.ExtensionKey -like 'com.vmware.vcDr*' -and [string]$managedBy.Type -ieq 'placeholderVm') {
        return $true
    }

    return $false
}

function Get-NarvikVCenterData {
    $collectStart = Get-Date
    $connection = $null

    try {
        $connection = Connect-NarvikVCenter

        $vmViews = @(Get-View -ViewType VirtualMachine -Property Name, Config, Runtime.Host, Parent, ResourcePool -ErrorAction Stop | Where-Object { $null -ne $_ })
        $dsViews = @(Get-View -ViewType Datastore -Property Name -ErrorAction Stop | Where-Object { $null -ne $_ })
        $podViews = @(Get-View -ViewType StoragePod -Property Name, ChildEntity -ErrorAction Stop | Where-Object { $null -ne $_ })
        $folderViews = @(Get-View -ViewType Folder -Property Name, Parent -ErrorAction Stop | Where-Object { $null -ne $_ })
        $hostViews = @(Get-View -ViewType HostSystem -Property Name, Parent -ErrorAction Stop | Where-Object { $null -ne $_ })
        $rpViews = @(Get-View -ViewType ResourcePool -Property Name -ErrorAction Stop | Where-Object { $null -ne $_ })

        # Tag assignments are a separate vAPI call, and the snapshot tag rule
        # reads them for the inventory it caches, so they are always collected:
        # enabling the rule later must not have to wait for the cache to expire.
        # A failure is tolerated only while the rule is unused, because then no
        # backup decision depends on tags. With the rule configured the
        # collection aborts, so a cached inventory without tags can never be
        # mistaken for an inventory of untagged VMs.
        $tagDataAvailable = $true
        $tagAssignments = @()
        try {
            $tagAssignments = @(Get-TagAssignment -ErrorAction Stop | Where-Object { $null -ne $_ })
        }
        catch {
            if (-not [string]::IsNullOrWhiteSpace([string]$script:Config.dont_backup_by_snapshot_tag_name)) {
                throw
            }
            $tagDataAvailable = $false
            Write-NarvikLog -Level WARNING -Message "vCenter tag assignments are unavailable; continuing without tags: $($_.Exception.Message)"
        }

        $folderMap = @{}
        foreach ($folder in $folderViews) {
            # StoragePod derives from Folder, so datastore clusters also show up
            # in a Folder view. They are not VM folders and cannot be a VM's
            # parent, so keep the map limited to real folders.
            if ($folder.GetType().Name -eq 'StoragePod') {
                continue
            }
            $folderMap[[string]$folder.MoRef.Value] = $folder
        }

        $hostMap = @{}
        $hostParentMap = @{}
        foreach ($hostView in $hostViews) {
            $hostId = [string]$hostView.MoRef.Value
            $hostMap[$hostId] = [string]$hostView.Name
            if ($null -ne $hostView.Parent) {
                $hostParentMap[$hostId] = $hostView.Parent
            }
        }

        $resourcePoolMap = @{}
        foreach ($resourcePool in $rpViews) {
            $resourcePoolMap[[string]$resourcePool.MoRef.Value] = [string]$resourcePool.Name
        }

        # A host's parent is a ClusterComputeResource only when the host is in a
        # real cluster; standalone hosts sit under a ComputeResource, where the
        # cluster tag rule never applies. All compute clusters are read, not
        # only those that host a VM, so a configured name is reported as
        # unknown only when no cluster with that name exists at all.
        $clusterViews = @(Get-View -ViewType ClusterComputeResource -Property Name -ErrorAction Stop | Where-Object { $null -ne $_ })
        $clusterNames = @{}
        $environmentClusterNames = @{}
        foreach ($clusterView in $clusterViews) {
            $clusterNames[[string]$clusterView.MoRef.Value] = [string]$clusterView.Name
            $environmentClusterNames[[string]$clusterView.Name] = $true
        }

        $unknownPriorityClusters = New-Object 'System.Collections.Generic.List[string]'
        if ($null -ne $script:Config -and $null -ne $script:Config.priority_clusters) {
            foreach ($clusterKey in @($script:Config.priority_clusters.Keys)) {
                $configuredCluster = $script:Config.priority_clusters[$clusterKey]
                $configuredName = [string]$configuredCluster.name
                if ([string]::IsNullOrWhiteSpace($configuredName)) {
                    continue
                }
                if (-not $environmentClusterNames.ContainsKey($configuredName) -and -not $unknownPriorityClusters.Contains($configuredName)) {
                    [void]$unknownPriorityClusters.Add($configuredName)
                }
            }
        }
        foreach ($unknownCluster in $unknownPriorityClusters) {
            Write-NarvikLog -Level WARNING -Message "Cluster '$unknownCluster' from 'priority_clusters' was not found in the environment."
        }

        $datastoreMap = @{}
        foreach ($datastore in $dsViews) {
            $datastoreMap[[string]$datastore.MoRef.Value] = $datastore
        }

        $podByDatastore = @{}
        foreach ($pod in $podViews) {
            foreach ($child in @($pod.ChildEntity)) {
                if ($null -ne $child) {
                    $podByDatastore[[string]$child.Value] = $pod
                }
            }
        }

        $tagMap = @{}
        foreach ($assignment in $tagAssignments) {
            if ($null -eq $assignment.Entity -or $null -eq $assignment.Tag) {
                continue
            }

            $keys = New-Object 'System.Collections.Generic.List[string]'

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
                if (-not $tagMap.ContainsKey($key)) {
                    $tagMap[$key] = New-Object 'System.Collections.Generic.List[string]'
                }
                [void]$tagMap[$key].Add([string]$assignment.Tag.Name)
            }
        }

        $datastores = [System.Collections.Generic.List[object]]::new()
        foreach ($datastore in $dsViews) {
            [void]$datastores.Add([pscustomobject]@{
                Name  = [string]$datastore.Name
                MoRef = [string]$datastore.MoRef.Value
                Tags  = @(Get-NarvikViewTags -View $datastore -TagMap $tagMap)
            })
        }

        $datastoreClusters = [System.Collections.Generic.List[object]]::new()
        foreach ($pod in $podViews) {
            $memberNames = New-Object 'System.Collections.Generic.List[string]'
            foreach ($child in @($pod.ChildEntity)) {
                if ($null -ne $child -and $datastoreMap.ContainsKey([string]$child.Value)) {
                    [void]$memberNames.Add([string]$datastoreMap[[string]$child.Value].Name)
                }
            }

            [void]$datastoreClusters.Add([pscustomobject]@{
                Name       = [string]$pod.Name
                MoRef      = [string]$pod.MoRef.Value
                Tags       = @(Get-NarvikViewTags -View $pod -TagMap $tagMap)
                Datastores = @($memberNames)
            })
        }

        $vms = [System.Collections.Generic.List[object]]::new()
        $notesParseWarnings = 0
        $lastFullChanged = $false

        foreach ($vmView in $vmViews) {
            if ($null -eq $vmView.Config) {
                continue
            }

            # VMware Live Site Recovery placeholders are ignored silently. Templates are
            # kept in the inventory and remain subject to the normal eligibility rules.
            if (Test-NarvikSiteRecoveryPlaceholder -View $vmView) {
                continue
            }

            $vmName = [string]$vmView.Name
            if ([string]::IsNullOrWhiteSpace($vmName)) {
                continue
            }

            $folderId = ''
            if ($null -ne $vmView.Parent) {
                $folderId = [string]$vmView.Parent.Value
            }

            $folderName = ''
            if (-not [string]::IsNullOrWhiteSpace($folderId) -and $folderMap.ContainsKey($folderId)) {
                $folderName = [string]$folderMap[$folderId].Name
            }

            $resourcePoolId = ''
            if ($null -ne $vmView.ResourcePool) {
                $resourcePoolId = [string]$vmView.ResourcePool.Value
            }

            $resourcePoolName = ''
            if (-not [string]::IsNullOrWhiteSpace($resourcePoolId) -and $resourcePoolMap.ContainsKey($resourcePoolId)) {
                $resourcePoolName = $resourcePoolMap[$resourcePoolId]
            }

            $hostId = ''
            $hostName = ''
            if ($null -ne $vmView.Runtime -and $null -ne $vmView.Runtime.Host) {
                $hostId = [string]$vmView.Runtime.Host.Value
                if ($hostMap.ContainsKey($hostId)) {
                    $hostName = [string]$hostMap[$hostId]
                }
            }

            $hostClusterId = ''
            $hostClusterName = ''
            if (-not [string]::IsNullOrWhiteSpace($hostId) -and $hostParentMap.ContainsKey($hostId)) {
                $hostParent = $hostParentMap[$hostId]
                if ($null -ne $hostParent -and [string]$hostParent.Type -eq 'ClusterComputeResource') {
                    $hostClusterId = [string]$hostParent.Value
                    if ($clusterNames.ContainsKey($hostClusterId)) {
                        $hostClusterName = [string]$clusterNames[$hostClusterId]
                    }
                }
            }

            $notes = ''
            if ($null -ne $vmView.Config.Annotation) {
                $notes = [string]$vmView.Config.Annotation
            }

            $lastBackup = $null
            $noteBackups = ConvertFrom-NarvikVmNotes -Notes $notes
            if ($null -ne $noteBackups) {
                # The tag for an incremental backup is the authoritative value
                # for the last incremental; the full tag is authoritative for
                # the last full only. They never overwrite each other.
                $lastBackup = $noteBackups.Incremental
                if ($null -ne $noteBackups.Full) {
                    $currentLastFull = $null
                    if ($script:LastFull.ContainsKey($vmName)) {
                        $currentLastFull = $script:LastFull[$vmName]
                    }
                    if ($null -eq $currentLastFull -or $currentLastFull -ne $noteBackups.Full) {
                        $script:LastFull[$vmName] = $noteBackups.Full
                        $lastFullChanged = $true
                        Write-NarvikLog -Level INFO -Message "VM '$vmName' Notes report a full backup at $($noteBackups.Full.ToString('yyyy-MM-dd HH:mm:ss')); last full control updated."
                    }
                }
            }
            elseif (-not [string]::IsNullOrWhiteSpace($notes)) {
                $notesParseWarnings++
            }

            $disks = [System.Collections.Generic.List[object]]::new()
            $totalSizeGb = 0.0

            if ($null -ne $vmView.Config.Hardware -and $null -ne $vmView.Config.Hardware.Device) {
                foreach ($device in @($vmView.Config.Hardware.Device)) {
                    if ($null -eq $device -or $device.GetType().Name -ne 'VirtualDisk') {
                        continue
                    }

                    $backing = $device.Backing
                    $backingType = ''
                    if ($null -ne $backing) {
                        $backingType = $backing.GetType().Name
                    }

                    $isRdm = ($backingType -match 'RawDiskMapping')
                    $diskMode = [string]$device.DiskMode
                    $isIndependent = ($diskMode -match 'independent')

                    $capacityKb = 0L
                    $sizeGb = 0.0
                    try {
                        $capacityKb = [long]$device.CapacityInKB
                        $sizeGb = [math]::Round(([double]$capacityKb / 1048576.0), 2)
                    }
                    catch {
                        $capacityKb = 0L
                        $sizeGb = 0.0
                    }
                    $totalSizeGb += $sizeGb

                    $datastoreId = $null
                    if ($null -ne $backing -and $null -ne $backing.Datastore) {
                        $datastoreId = [string]$backing.Datastore.Value
                    }

                    $datastoreName = ''
                    if (-not [string]::IsNullOrWhiteSpace($datastoreId) -and $datastoreMap.ContainsKey($datastoreId)) {
                        $datastoreName = [string]$datastoreMap[$datastoreId].Name
                    }

                    $clusterName = ''
                    $datastoreClusterId = ''
                    if (-not [string]::IsNullOrWhiteSpace($datastoreId) -and $podByDatastore.ContainsKey($datastoreId)) {
                        $clusterName = [string]$podByDatastore[$datastoreId].Name
                        $datastoreClusterId = [string]$podByDatastore[$datastoreId].MoRef.Value
                    }

                    $label = ''
                    if ($null -ne $device.DeviceInfo -and $null -ne $device.DeviceInfo.Label) {
                        $label = [string]$device.DeviceInfo.Label
                    }
                    if ([string]::IsNullOrWhiteSpace($label)) {
                        $label = 'Disk ' + [string]$device.Key
                    }

                    $provisioning = ''
                    if ($null -ne $backing -and $backing.PSObject.Properties.Name -contains 'ThinProvisioned') {
                        if ($backing.ThinProvisioned) {
                            $provisioning = 'Thin'
                        }
                        else {
                            $provisioning = 'Thick'
                        }
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
                        DatastoreCluster     = $clusterName
                        DatastoreTags        = @(Get-NarvikMoRefTags -MoRefValue $datastoreId -TagMap $tagMap)
                        DatastoreClusterTags = @(Get-NarvikMoRefTags -MoRefValue $datastoreClusterId -TagMap $tagMap)
                        DiskMode             = $diskMode
                        BackingType          = $backingType
                    })
                }
            }

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

            [void]$vms.Add([pscustomobject]@{
                Name              = $vmName
                MoRef             = [string]$vmView.MoRef.Value
                FolderPath        = Get-NarvikFolderPath -FolderId $folderId -FolderMap $folderMap
                FolderMoRef       = $folderId
                FolderName        = $folderName
                FolderTags        = @(Get-NarvikMoRefTags -MoRefValue $folderId -TagMap $tagMap)
                ClusterMoRef      = $hostClusterId
                ClusterName       = $hostClusterName
                ClusterTags       = @(Get-NarvikMoRefTags -MoRefValue $hostClusterId -TagMap $tagMap)
                ClusterPriority   = [int]$priorityClusterSetting.Priority
                ClusterMaxThreads = [int]$priorityClusterSetting.MaxThreads
                ResourcePoolMoRef = $resourcePoolId
                ResourcePoolName  = $resourcePoolName
                ResourcePoolTags  = @(Get-NarvikMoRefTags -MoRefValue $resourcePoolId -TagMap $tagMap)
                HostName          = $hostName
                Tags              = @(Get-NarvikViewTags -View $vmView -TagMap $tagMap)
                Notes             = $notes
                LastBackup        = $lastBackup
                TotalSizeGB       = [math]::Round($totalSizeGb, 2)
                DatastoreClusters = @($vmClusterNames | Sort-Object)
                ManagementClass   = ''
                Disks             = @($disks)
            })
        }

        if ($lastFullChanged) {
            Save-NarvikLastFull
        }

        if ($notesParseWarnings -gt 0) {
            Write-NarvikLog -Level WARNING -Message "$notesParseWarnings VM(s) have notes but no valid backup tag; their last incremental backup is unknown."
        }

        $sortedVms = @($vms | Sort-Object -Property FolderPath, Name)

        return [pscustomobject]@{
            CollectedAt          = $collectStart
            VMs                  = $sortedVms
            Datastores           = @($datastores)
            DatastoreClusters    = @($datastoreClusters)
            TagDataAvailable     = [bool]$tagDataAvailable
            UnknownPriorityClusters = @($unknownPriorityClusters)
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
            return $true
        }
    }

    if ($null -ne $script:LastVCenterAttempt -and $script:LastVCenterAttempt -ne [datetime]::MinValue) {
        $sinceAttempt = ($now - $script:LastVCenterAttempt).TotalSeconds
        if ($sinceAttempt -lt 60) {
            if ($null -ne $script:VCache) {
                return $true
            }
            return $false
        }
    }

    $script:LastVCenterAttempt = $now

    try {
        $cache = Get-NarvikVCenterData
        $script:VCache = $cache
        $script:VCacheRefreshedThisLoop = $true
        Write-NarvikLog -Level INFO -Message "vCenter inventory collected: $($cache.VmCount) VM(s), $($cache.DatastoreCount) datastore(s), $($cache.DatastoreClusterCount) datastore cluster(s)."
        return $true
    }
    catch {
        Write-NarvikLog -Level WARNING -Message "vCenter inventory collection failed: $($_.Exception.Message)"
        if ($null -ne $script:VCache) {
            return $true
        }
        return $false
    }
}

function Get-NarvikBaseline {
    param(
        [datetime]$Now
    )

    if ($Now.TimeOfDay -lt [TimeSpan]'20:00:00') {
        return $Now.Date.AddDays(-1).AddHours(20)
    }

    return $Now.Date.AddHours(20)
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
    # is the datastores that back the VM's disks, and the folder scope is the
    # VM's direct folder only: a tag on an ancestor folder does not apply.
    $scopes = New-Object 'System.Collections.Generic.List[object]'
    [void]$scopes.Add([pscustomobject]@{ Label = 'VM'; Name = ''; Tags = @($Vm.Tags) })
    [void]$scopes.Add([pscustomobject]@{ Label = 'Cluster'; Name = [string]$Vm.ClusterName; Tags = @($Vm.ClusterTags) })
    [void]$scopes.Add([pscustomobject]@{ Label = 'Resource pool'; Name = [string]$Vm.ResourcePoolName; Tags = @($Vm.ResourcePoolTags) })
    [void]$scopes.Add([pscustomobject]@{ Label = 'Folder'; Name = [string]$Vm.FolderName; Tags = @($Vm.FolderTags) })

    foreach ($disk in @($Vm.Disks)) {
        if ($null -eq $disk) {
            continue
        }

        [void]$scopes.Add([pscustomobject]@{ Label = 'Datastore'; Name = [string]$disk.Datastore; Tags = @($disk.DatastoreTags) })
        [void]$scopes.Add([pscustomobject]@{ Label = 'Datastore cluster'; Name = [string]$disk.DatastoreCluster; Tags = @($disk.DatastoreClusterTags) })
    }

    $violations = New-Object 'System.Collections.Generic.List[string]'
    foreach ($scope in $scopes) {
        if (-not (Test-NarvikTagPresent -Tags @($scope.Tags) -TagName $TagName)) {
            continue
        }

        $name = [string]$scope.Name
        if ($scope.Label -eq 'VM') {
            $reason = "VM tag '$TagName'"
        }
        elseif ([string]::IsNullOrWhiteSpace($name)) {
            $reason = "$($scope.Label) tag '$TagName'"
        }
        else {
            $reason = "$($scope.Label) '$name' tag '$TagName'"
        }

        if (-not $violations.Contains($reason)) {
            [void]$violations.Add($reason)
        }
    }

    return @($violations)
}

function Format-NarvikDiskSizeMiB {
    param(
        [Parameter(Mandatory = $true)]
        [long]$CapacityInKB
    )

    return ([double]$CapacityInKB / 1024.0).ToString('0.##########', [System.Globalization.CultureInfo]::InvariantCulture)
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
    # is not in a cluster, keep priority 0 and max_threads 1000: the global
    # thread limit and the one-per-host rule still apply.
    $displayName = ''
    if (-not [string]::IsNullOrWhiteSpace($ClusterName)) {
        $displayName = $ClusterName.Trim()
    }

    $setting = [pscustomobject]@{
        Name       = $displayName
        Priority   = 0
        MaxThreads = 1000
        Listed     = $false
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
        Name       = [string]$entry.name
        Priority   = [int]$entry.priority
        MaxThreads = [int]$entry.max_threads
        Listed     = $true
    }
}

function Update-NarvikEligibility {
    param(
        [switch]$SendAlerts
    )

    $snapshotTagName = [string]$script:Config.dont_backup_by_snapshot_tag_name
    # Characters that cannot be used in a VM name for the dsmc backup command.
    $unsupportedNamePattern = '[:;''"*?,<>/\\|\[\]}{]'

    if ($null -eq $script:VCache) {
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

    foreach ($vm in @($script:VCache.VMs)) {
        $reasons = New-Object 'System.Collections.Generic.List[string]'

        if ($tagDataUnavailable) {
            Add-NarvikReason -Reasons $reasons -Reason 'Tag assignments are unavailable while the snapshot tag rule is configured'
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

        if ($vm.PSObject.Properties.Name -contains 'ManagementClass') {
            $vm.ManagementClass = $managementClass
        }
        else {
            Add-Member -InputObject $vm -NotePropertyName 'ManagementClass' -NotePropertyValue $managementClass
        }

        $invalidSizeDisks = [System.Collections.Generic.List[object]]::new()
        foreach ($disk in @($vm.Disks)) {
            if ($disk.RDM) {
                Add-NarvikReason -Reasons $reasons -Reason "RDM disk '$($disk.Label)'"
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
                $sizeMiBText = Format-NarvikDiskSizeMiB -CapacityInKB $capacityKb
                Add-NarvikReason -Reasons $reasons -Reason "Disk '$($disk.Label)' size $sizeMiBText MiB is not a multiple of 1 MiB"
                [void]$invalidSizeDisks.Add($disk)
            }
        }

        if ($invalidSizeDisks.Count -gt 0) {
            [void]$diskSizeCases.Add([pscustomobject]@{
                VM    = $vm
                Disks = @($invalidSizeDisks)
            })
        }

        foreach ($violation in @(Get-NarvikVmTagViolations -Vm $vm -TagName $snapshotTagName)) {
            Add-NarvikReason -Reasons $reasons -Reason $violation
        }

        foreach ($disk in @($vm.Disks)) {
            $datastoreName = [string]$disk.Datastore
            if ([string]::IsNullOrWhiteSpace($datastoreName)) {
                Add-NarvikReason -Reasons $reasons -Reason "Unknown datastore for disk '$($disk.Label)'"
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
    $duplicateGroups = @($initialEligible | Group-Object -Property { $_.Name.ToLowerInvariant() } | Where-Object { $_.Count -gt 1 })
    $duplicateMorefs = @{}

    foreach ($group in $duplicateGroups) {
        $groupVms = @($group.Group)
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

    $script:EligibleVMs = @($finalEligible)
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
        $script:NonEligibleSignature = $signature
    }

    Write-NarvikMonitoringFiles

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

function Send-NarvikDuplicateNameAlerts {
    if ($null -eq $script:DuplicateNameCases -or @($script:DuplicateNameCases).Count -eq 0) {
        return
    }

    if (-not (Test-NarvikMailEnabled)) {
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
            $sizeMiBText = Format-NarvikDiskSizeMiB -CapacityInKB $capacityKb
            [void]$body.AppendLine("  - Disk: '$($disk.Label)' | Size: $sizeMiBText MiB")
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
    $unknownClusters = @()
    if ($null -ne $script:VCache -and $script:VCache.PSObject.Properties.Name -contains 'UnknownPriorityClusters') {
        $unknownClusters = @($script:VCache.UnknownPriorityClusters)
    }

    if ($unknownClusters.Count -eq 0) {
        return
    }

    if (-not (Test-NarvikMailEnabled)) {
        return
    }

    $now = Get-Date
    $dueClusters = New-Object 'System.Collections.Generic.List[string]'

    foreach ($name in $unknownClusters) {
        $clusterName = ([string]$name).Trim()
        if ([string]::IsNullOrWhiteSpace($clusterName)) {
            continue
        }

        $key = $clusterName.ToLowerInvariant()
        $lastAlert = $null
        if ($script:State.priority_cluster_alerts.ContainsKey($key)) {
            $lastAlert = $script:State.priority_cluster_alerts[$key]
        }

        if ($null -ne $lastAlert) {
            $ageHours = ($now - $lastAlert).TotalHours
            if ($ageHours -lt 24) {
                Write-NarvikLog -Level INFO -Message "Cluster '$clusterName' from 'priority_clusters' was already reported at $($lastAlert.ToString('yyyy-MM-dd HH:mm:ss')); alert suppressed for 24 hours."
                continue
            }
        }

        if (-not $dueClusters.Contains($clusterName)) {
            [void]$dueClusters.Add($clusterName)
        }
    }

    if ($dueClusters.Count -eq 0) {
        return
    }

    $body = New-Object System.Text.StringBuilder
    [void]$body.AppendLine("Narvik did not find the following cluster name(s) from 'priority_clusters' in vCenter.")
    [void]$body.AppendLine('Their priority and max_threads settings are not being applied to any VM.')
    [void]$body.AppendLine('Fix the name in config.json or remove the entry.')
    [void]$body.AppendLine('')
    foreach ($clusterName in $dueClusters) {
        [void]$body.AppendLine("Cluster: '$clusterName'")
    }

    $subject = '[Narvik] Cluster names in priority_clusters not found in vCenter - action required'
    $sent = Send-NarvikMail -Subject $subject -Body $body.ToString()

    if ($sent) {
        foreach ($clusterName in $dueClusters) {
            $key = $clusterName.ToLowerInvariant()
            $script:State.priority_cluster_alerts[$key] = $now
        }
        Save-NarvikState
        Write-NarvikLog -Level INFO -Message "Priority cluster alert sent for $($dueClusters.Count) cluster name(s)."
    }
    else {
        Write-NarvikLog -Level ERROR -Message 'Priority cluster alert could not be sent; it will be retried on the next inventory collection.'
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

function Get-NarvikActiveJobCount {
    return $script:ActiveJobs.Count
}

function Test-NarvikVmActive {
    param(
        [string]$VmName
    )

    foreach ($job in $script:ActiveJobs) {
        if ($job.VmName -ieq $VmName) {
            return $true
        }
    }

    return $false
}

function Test-NarvikHostActive {
    param(
        [string]$HostName
    )

    if ([string]::IsNullOrWhiteSpace($HostName)) {
        return $false
    }

    foreach ($job in $script:ActiveJobs) {
        if ($job.HostName -ieq $HostName) {
            return $true
        }
    }

    return $false
}

function Test-NarvikClusterAtCapacity {
    param(
        [Parameter(Mandatory = $true)]
        $Vm
    )

    $clusterName = [string]$Vm.ClusterName
    if ([string]::IsNullOrWhiteSpace($clusterName)) {
        return $false
    }

    $maxThreads = 1000
    if ($Vm.PSObject.Properties.Name -contains 'ClusterMaxThreads') {
        try {
            $maxThreads = [int]$Vm.ClusterMaxThreads
        }
        catch {
            $maxThreads = 1000
        }
    }
    if ($maxThreads -lt 1) {
        $maxThreads = 1
    }

    $activeCount = 0
    foreach ($job in $script:ActiveJobs) {
        if ([string]$job.ClusterName -ieq $clusterName) {
            $activeCount++
        }
    }

    return ($activeCount -ge $maxThreads)
}

function Test-NarvikBackoffActive {
    param(
        [string]$VmName,
        [datetime]$Now
    )

    if (-not $script:State.failed_attempts.ContainsKey($VmName)) {
        return $false
    }

    $entry = $script:State.failed_attempts[$VmName]
    if ($null -eq $entry.last_attempt) {
        return $false
    }

    $count = [int]$entry.count
    if ($count -lt 1) {
        $count = 1
    }

    $exponent = $count - 1

    # The first retry comes after one minute and quadruples on every further
    # failure.
    $minutes = [math]::Pow(4, $exponent)

    # Cap the backoff at 12 hours (720 minutes) so a VM that keeps failing
    # is still retried at least twice a day.
    if ($minutes -gt 720) {
        $minutes = 720
    }

    $nextAttempt = $entry.last_attempt.AddMinutes($minutes)
    return ($Now -lt $nextAttempt)
}

function Select-NarvikNextBackup {
    if ($null -eq $script:VCache -or @($script:EligibleVMs).Count -eq 0) {
        return $null
    }

    $now = Get-Date
    # The cluster priority is the primary ordering criterion; the VM folder is
    # the secondary one, as before. Higher priority comes first, so a negative
    # priority leaves the cluster at the end of the queue.
    $pending = @(Get-NarvikPendingVMs -Now $now |
            Sort-Object -Property @{ Expression = { [int]$_.ClusterPriority }; Descending = $true }, FolderPath, Name)
    $script:PendingVMs = $pending

    if ($pending.Count -gt 0) {
        foreach ($vm in $pending) {
            if (Test-NarvikVmActive -VmName $vm.Name) {
                continue
            }

            if ([string]::IsNullOrWhiteSpace($vm.HostName)) {
                Write-NarvikLog -Level DEBUG -Message "VM '$($vm.Name)' has no host information; backup will not be started."
                continue
            }

            if (Test-NarvikBackoffActive -VmName $vm.Name -Now $now) {
                Write-NarvikLog -Level DEBUG -Message "VM '$($vm.Name)' is in failure backoff; skipping."
                continue
            }

            if (Test-NarvikHostActive -HostName $vm.HostName) {
                Write-NarvikLog -Level DEBUG -Message "VM '$($vm.Name)' shares host '$($vm.HostName)' with an active backup; skipping."
                continue
            }

            if (Test-NarvikClusterAtCapacity -Vm $vm) {
                Write-NarvikLog -Level DEBUG -Message "VM '$($vm.Name)' is in cluster '$($vm.ClusterName)', which already has $($vm.ClusterMaxThreads) active backup(s); skipping."
                continue
            }

            $forceFull = $script:DuplicateGuid.ContainsKey($vm.Name)
            return [pscustomobject]@{
                VM        = $vm
                Mode      = 'Incremental'
                IsFull    = [bool]$forceFull
                ForceFull = [bool]$forceFull
            }
        }

        return $null
    }

    $isWeekend = ($now.DayOfWeek -eq [System.DayOfWeek]::Saturday -or $now.DayOfWeek -eq [System.DayOfWeek]::Sunday)
    $isBeforeEight = ($now.TimeOfDay -lt [TimeSpan]'08:00:00')
    if (-not $isWeekend -and -not $isBeforeEight) {
        return $null
    }

    $fullCandidates = [System.Collections.Generic.List[object]]::new()
    foreach ($vm in @($script:EligibleVMs)) {
        if (Test-NarvikVmActive -VmName $vm.Name) {
            continue
        }

        if ([string]::IsNullOrWhiteSpace($vm.HostName)) {
            continue
        }

        if (Test-NarvikBackoffActive -VmName $vm.Name -Now $now) {
            continue
        }

        if (Test-NarvikHostActive -HostName $vm.HostName) {
            continue
        }

        if (Test-NarvikClusterAtCapacity -Vm $vm) {
            Write-NarvikLog -Level DEBUG -Message "VM '$($vm.Name)' is in cluster '$($vm.ClusterName)', which already has $($vm.ClusterMaxThreads) active backup(s); full backup skipped."
            continue
        }

        $lastFull = $null
        if ($script:LastFull.ContainsKey($vm.Name)) {
            $lastFull = $script:LastFull[$vm.Name]
        }
        if ($null -eq $lastFull) {
            $lastFull = $now.AddYears(-1)
        }

        if ($lastFull -lt $now.AddDays(-30)) {
            [void]$fullCandidates.Add([pscustomobject]@{
                VM       = $vm
                LastFull = $lastFull
            })
        }
    }

    if ($fullCandidates.Count -eq 0) {
        return $null
    }

    # Priority is the primary criterion for full backups too; the oldest full
    # backup only breaks ties inside the same cluster priority.
    $selected = @($fullCandidates | Sort-Object -Property @{ Expression = { [int]$_.VM.ClusterPriority }; Descending = $true }, LastFull, @{ Expression = { $_.VM.FolderPath } }, @{ Expression = { $_.VM.Name } } | Select-Object -First 1)[0]

    return [pscustomobject]@{
        VM        = $selected.VM
        Mode      = 'Full'
        IsFull    = $true
        ForceFull = $true
    }
}

function ConvertTo-NarvikDsmcVmName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return [regex]::Replace($Name, '[,./]+', '*')
}

function ConvertTo-NarvikFileName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
    $builder = New-Object System.Text.StringBuilder

    foreach ($character in $Name.ToCharArray()) {
        if ($invalidChars -contains $character -or [int][char]$character -lt 32) {
            [void]$builder.Append('_')
        }
        else {
            [void]$builder.Append($character)
        }
    }

    $value = $builder.ToString().Trim()
    $value = $value.TrimEnd([char[]]'.')
    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = 'VM'
    }
    if ($value.Length -gt 120) {
        $value = $value.Substring(0, 120)
    }

    return $value
}

function Quote-NarvikWindowsArgument {
    param(
        [AllowEmptyString()]
        [string]$Argument
    )

    if ($null -eq $Argument) {
        return '""'
    }

    if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') {
        return $Argument
    }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0

    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes++
            continue
        }

        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($backslashes * 2) + 1)))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }

        if ($backslashes -gt 0) {
            [void]$builder.Append(('\' * $backslashes))
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }

    if ($backslashes -gt 0) {
        [void]$builder.Append(('\' * ($backslashes * 2)))
    }

    [void]$builder.Append('"')
    return $builder.ToString()
}

function Read-NarvikTextFileShared {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ''
    }

    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $reader = New-Object System.IO.StreamReader -ArgumentList $stream, ([System.Text.Encoding]::Default), $true
        try {
            return $reader.ReadToEnd()
        }
        finally {
            $reader.Close()
        }
    }
    catch {
        return ''
    }
    finally {
        if ($null -ne $stream) {
            try { $stream.Close() } catch { }
        }
    }
}

function Read-NarvikFileChunk {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [long]$Offset = 0,

        [int]$MaxBytes = 65536
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{
            Text   = ''
            Offset = $Offset
        }
    }

    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        if ($Offset -lt 0 -or $Offset -gt $stream.Length) {
            $Offset = 0
        }

        $stream.Position = $Offset
        $remaining = $stream.Length - $Offset
        if ($remaining -le 0) {
            return [pscustomobject]@{
                Text   = ''
                Offset = $stream.Length
            }
        }

        $count = [int][math]::Min([long]$MaxBytes, $remaining)
        $buffer = New-Object byte[] $count
        $read = $stream.Read($buffer, 0, $count)
        if ($read -le 0) {
            return [pscustomobject]@{
                Text   = ''
                Offset = $Offset
            }
        }

        return [pscustomobject]@{
            Text   = [System.Text.Encoding]::Default.GetString($buffer, 0, $read)
            Offset = ($Offset + $read)
        }
    }
    catch {
        return [pscustomobject]@{
            Text   = ''
            Offset = $Offset
        }
    }
    finally {
        if ($null -ne $stream) {
            try { $stream.Close() } catch { }
        }
    }
}

function Add-NarvikJobOutput {
    param(
        [Parameter(Mandatory = $true)]
        $Job,

        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return
    }

    $combined = $Job.OutputTail + $Text
    if ($combined.Length -gt 131072) {
        $combined = $combined.Substring($combined.Length - 131072)
    }
    $Job.OutputTail = $combined
}

function Read-NarvikJobOutput {
    foreach ($job in @($script:ActiveJobs)) {
        $stdout = Read-NarvikFileChunk -Path $job.LogPath -Offset ([long]$job.ReadOffset)
        if (-not [string]::IsNullOrEmpty($stdout.Text)) {
            Add-NarvikJobOutput -Job $job -Text $stdout.Text
        }
        $job.ReadOffset = [long]$stdout.Offset

        $stderr = Read-NarvikFileChunk -Path $job.ErrorPath -Offset ([long]$job.ErrorReadOffset)
        if (-not [string]::IsNullOrEmpty($stderr.Text)) {
            Add-NarvikJobOutput -Job $job -Text $stderr.Text
        }
        $job.ErrorReadOffset = [long]$stderr.Offset
    }
}

function Merge-NarvikJobErrorLog {
    param(
        [Parameter(Mandatory = $true)]
        $Job
    )

    if (-not (Test-Path -LiteralPath $Job.ErrorPath -PathType Leaf)) {
        return
    }

    $errorText = Read-NarvikTextFileShared -Path $Job.ErrorPath
    if ([string]::IsNullOrEmpty($errorText)) {
        try { Remove-Item -LiteralPath $Job.ErrorPath -Force -ErrorAction SilentlyContinue } catch { }
        return
    }

    try {
        [System.IO.File]::AppendAllText($Job.LogPath, $errorText, [System.Text.Encoding]::Default)
        try { Remove-Item -LiteralPath $Job.ErrorPath -Force -ErrorAction SilentlyContinue } catch { }
    }
    catch {
        Write-NarvikLog -Level WARNING -Message "Could not merge stderr output into VM log '$($Job.LogPath)': $($_.Exception.Message)"
    }
}

function Record-NarvikFailure {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName,

        [datetime]$When = (Get-Date)
    )

    $entry = @{
        last_attempt = $When
        count        = 1
    }

    if ($script:State.failed_attempts.ContainsKey($VmName)) {
        $previous = $script:State.failed_attempts[$VmName]
        $entry.count = [int]$previous.count + 1
    }

    $script:State.failed_attempts[$VmName] = $entry
    Save-NarvikState

    Write-NarvikLog -Level WARNING -Message "Recorded failed attempt $($entry.count) for VM '$VmName' at $($When.ToString('yyyy-MM-dd HH:mm:ss'))."
}

function Clear-NarvikFailure {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName
    )

    if ($script:State.failed_attempts.ContainsKey($VmName)) {
        [void]$script:State.failed_attempts.Remove($VmName)
        Save-NarvikState
    }
}

function Set-NarvikDuplicateGuid {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName
    )

    if ($script:DuplicateGuid.ContainsKey($VmName)) {
        return
    }

    $script:DuplicateGuid[$VmName] = $true
    Save-NarvikState
    Write-NarvikLog -Level WARNING -Message "VM '$VmName' reported ANS1715E; the next backup will use -VMBACKUPUPDATEGUID and -mode IFFull."
}

function Clear-NarvikDuplicateGuid {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName
    )

    if (-not $script:DuplicateGuid.ContainsKey($VmName)) {
        return
    }

    [void]$script:DuplicateGuid.Remove($VmName)
    Save-NarvikState
    Write-NarvikLog -Level INFO -Message "VM '$VmName' completed successfully; duplicate GUID flag cleared."
}

function Start-NarvikBackupJob {
    param(
        [Parameter(Mandatory = $true)]
        $Selection
    )

    $vm = $Selection.VM
    $now = Get-Date
    $dateDirectory = Join-Path $script:VmLogDir $now.ToString('yyyy_MM_dd')
    New-Item -ItemType Directory -Force -Path $dateDirectory | Out-Null

    $safeName = ConvertTo-NarvikFileName -Name $vm.Name
    $logPath = Join-Path $dateDirectory ($now.ToString('HH_mm_ss') + '_' + $safeName + '.txt')
    $logPath = Get-NarvikUniquePath -Path $logPath
    $errorPath = $logPath + '.stderr'

    $sanitizedName = ConvertTo-NarvikDsmcVmName -Name $vm.Name
    $duplicateGuid = $script:DuplicateGuid.ContainsKey($vm.Name)
    $isFull = [bool]$Selection.IsFull -or $duplicateGuid

    $managementClass = ''
    $vmDatastoreClusters = @($vm.DatastoreClusters)
    if ($vmDatastoreClusters.Count -eq 1) {
        $managementClass = Get-NarvikManagementClass -DatastoreClusterName ([string]$vmDatastoreClusters[0])
    }
    if ([string]::IsNullOrWhiteSpace($managementClass)) {
        Write-NarvikLog -Level ERROR -Message "VM '$($vm.Name)' has no management class mapped from its datastore cluster; backup will not be started."
        return $null
    }

    $arguments = New-Object 'System.Collections.Generic.List[string]'
    [void]$arguments.Add('backup')
    [void]$arguments.Add('vm')
    [void]$arguments.Add((Quote-NarvikWindowsArgument -Argument $sanitizedName))
    [void]$arguments.Add('-vmmc=' + (Quote-NarvikWindowsArgument -Argument $managementClass))

    if ($duplicateGuid) {
        [void]$arguments.Add('-VMBACKUPUPDATEGUID')
    }

    if ($isFull) {
        [void]$arguments.Add('-mode')
        [void]$arguments.Add('IFFull')
    }

    if ($script:Config.dsmc_use_preview) {
        [void]$arguments.Add('-preview')
    }

    $argumentString = $arguments -join ' '
    $modeText = 'Incremental'
    if ($isFull) {
        $modeText = 'Full'
    }

    $startParameters = @{
        FilePath               = $script:Config.dsmc_path
        ArgumentList           = $argumentString
        RedirectStandardOutput = $logPath
        RedirectStandardError  = $errorPath
        PassThru               = $true
        ErrorAction            = 'Stop'
    }
    # -WindowStyle is only supported by Start-Process on Windows.
    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        $startParameters['WindowStyle'] = 'Hidden'
    }

    try {
        $process = Start-Process @startParameters
    }
    catch {
        Write-NarvikLog -Level ERROR -Message "Failed to start $modeText backup for VM '$($vm.Name)': $($_.Exception.Message)"
        Record-NarvikFailure -VmName $vm.Name -When $now
        return $null
    }

    $job = [pscustomobject]@{
        VmName          = [string]$vm.Name
        VM              = $vm
        HostName        = [string]$vm.HostName
        ClusterName     = [string]$vm.ClusterName
        ClusterPriority = [int]$vm.ClusterPriority
        Mode            = $modeText
        IsFull          = [bool]$isFull
        Process         = $process
        LogPath         = $logPath
        ErrorPath       = $errorPath
        StartTime       = $now
        ReadOffset      = [long]0
        ErrorReadOffset = [long]0
        OutputTail      = ''
        SanitizedName   = $sanitizedName
        ArgumentString  = $argumentString
    }

    [void]$script:ActiveJobs.Add($job)
    Write-NarvikLog -Level INFO -Message "Started $modeText backup for VM '$($vm.Name)' (PID $($process.Id), host '$($vm.HostName)', cluster '$($vm.ClusterName)', size $($vm.TotalSizeGB) GB). Command: dsmc $argumentString"
    return $job
}

function Update-NarvikPendingMonitoring {
    $pending = @()
    if ($null -ne $script:VCache) {
        $pending = @(Get-NarvikPendingVMs -Now (Get-Date))
    }
    $script:PendingVMs = $pending

    $content = [string]$pending.Count + "`r`n"
    Write-NarvikAtomicText -Path (Join-Path $script:MonitoringDir 'pending_count.txt') -Content $content
}

function Complete-NarvikJobs {
    $completedAny = $false
    $now = Get-Date

    foreach ($job in @($script:ActiveJobs)) {
        $hasExited = $false
        try {
            $hasExited = [bool]$job.Process.HasExited
        }
        catch {
            $hasExited = $true
        }

        if (-not $hasExited) {
            continue
        }

        $completedAny = $true
        Merge-NarvikJobErrorLog -Job $job
        $content = Read-NarvikTextFileShared -Path $job.LogPath
        $remainingError = Read-NarvikTextFileShared -Path $job.ErrorPath
        if (-not [string]::IsNullOrEmpty($remainingError)) {
            $content = $content + "`r`n" + $remainingError
        }

        $exitCode = $null
        try {
            $exitCode = [int]$job.Process.ExitCode
        }
        catch {
            $exitCode = $null
        }

        $success = ($null -ne $exitCode -and $exitCode -eq 0 -and $content -match 'Total number of objects backed up: +1')
        $logWriteTime = $now
        try {
            if (Test-Path -LiteralPath $job.LogPath -PathType Leaf) {
                $logWriteTime = (Get-Item -LiteralPath $job.LogPath).LastWriteTime
            }
        }
        catch {
            $logWriteTime = $now
        }

        if ($success) {
            Write-NarvikLog -Level INFO -Message "Backup completed successfully for VM '$($job.VmName)' (PID $($job.Process.Id), exit code 0)."

            try {
                $job.VM.LastBackup = $logWriteTime
            }
            catch {
            }

            if ($content -match 'Incremental Forever - Full') {
                $script:LastFull[$job.VmName] = $now
                Save-NarvikLastFull
                Write-NarvikLog -Level INFO -Message "Full backup recorded for VM '$($job.VmName)'."
            }

            Clear-NarvikFailure -VmName $job.VmName
            Clear-NarvikDuplicateGuid -VmName $job.VmName
        }
        else {
            $exitText = 'unknown'
            if ($null -ne $exitCode) {
                $exitText = [string]$exitCode
            }
            Write-NarvikLog -Level ERROR -Message "Backup failed for VM '$($job.VmName)' (PID $($job.Process.Id), exit code $exitText)."

            $tailLines = @($content -split "\r?\n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($tailLines.Count -gt 0) {
                $tailStart = [math]::Max(0, $tailLines.Count - 15)
                for ($index = $tailStart; $index -lt $tailLines.Count; $index++) {
                    Write-NarvikLog -Level ERROR -Message "VM '$($job.VmName)' output: $($tailLines[$index])"
                }
            }

            Record-NarvikFailure -VmName $job.VmName -When $now

            if ($content -match 'ANS1715E') {
                Set-NarvikDuplicateGuid -VmName $job.VmName
            }
        }

        [void]$script:ActiveJobs.Remove($job)
        Update-NarvikPendingMonitoring
    }

    return $completedAny
}

function Get-NarvikLastLines {
    param(
        [AllowEmptyString()]
        [string]$Text,

        [int]$Count = 10
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @()
    }

    $lines = @($Text -split "\r?\n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -le $Count) {
        return $lines
    }

    return @($lines[($lines.Count - $Count)..($lines.Count - 1)])
}

function Write-NarvikStats {
    param(
        [switch]$Force
    )

    $now = Get-Date
    $pending = @()
    if ($null -ne $script:VCache) {
        $pending = @(Get-NarvikPendingVMs -Now $now)
    }
    $script:PendingVMs = $pending

    $activeNames = @{}
    foreach ($job in @($script:ActiveJobs)) {
        $activeNames[[string]$job.VmName] = $true
    }

    $waiting = @($pending | Where-Object { -not $activeNames.ContainsKey([string]$_.Name) })
    $waitingSize = 0.0
    foreach ($vm in $waiting) {
        $waitingSize += [double]$vm.TotalSizeGB
    }

    $activeIncremental = @($script:ActiveJobs | Where-Object { -not $_.IsFull })
    $activeFull = @($script:ActiveJobs | Where-Object { $_.IsFull })

    $signatureParts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($job in @($script:ActiveJobs | Sort-Object -Property VmName)) {
        [void]$signatureParts.Add("$($job.VmName)|$($job.Mode)|$($job.Process.Id)")
    }
    [void]$signatureParts.Add("waiting=$($waiting.Count)|size=$([math]::Round($waitingSize, 2))")
    $signature = $signatureParts -join ';'

    $elapsed = ($now - $script:LastStatsLog).TotalSeconds
    if (-not $Force -and $signature -eq $script:LastStatsSignature -and $elapsed -lt 60) {
        return
    }

    $script:LastStatsLog = $now
    $script:LastStatsSignature = $signature

    Write-NarvikLog -Level INFO -Message "Pending waiting: $($waiting.Count) VM(s), $([math]::Round($waitingSize, 2)) GB."

    foreach ($job in @($activeIncremental | Sort-Object -Property VmName)) {
        $elapsedMinutes = [math]::Round(($now - $job.StartTime).TotalMinutes, 1)
        Write-NarvikLog -Level INFO -Message "Active pending backup: VM '$($job.VmName)', size $($job.VM.TotalSizeGB) GB, started $($job.StartTime.ToString('yyyy-MM-dd HH:mm:ss')), elapsed $elapsedMinutes minute(s), PID $($job.Process.Id)."
    }

    foreach ($job in @($activeFull | Sort-Object -Property VmName)) {
        $elapsedMinutes = [math]::Round(($now - $job.StartTime).TotalMinutes, 1)
        Write-NarvikLog -Level INFO -Message "Active full backup: VM '$($job.VmName)', size $($job.VM.TotalSizeGB) GB, started $($job.StartTime.ToString('yyyy-MM-dd HH:mm:ss')), elapsed $elapsedMinutes minute(s), PID $($job.Process.Id)."
    }

    if ($script:ActiveJobs.Count -eq 0) {
        Write-NarvikLog -Level INFO -Message 'No active backups.'
    }
}

function Invoke-NarvikIdleMaintenance {
    if ($null -eq $script:VCache) {
        return
    }

    $now = Get-Date
    if ($null -ne $script:State.last_idle -and ($now - $script:State.last_idle).TotalHours -lt 20) {
        return
    }

    Write-NarvikLog -Level INFO -Message 'Idle maintenance started: no backup will be started in this cycle.'

    Write-NarvikLog -Level INFO -Message "Eligible VMs: $(@($script:EligibleVMs).Count)."
    foreach ($vm in @($script:EligibleVMs | Sort-Object -Property @{ Expression = { [int]$_.ClusterPriority }; Descending = $true }, FolderPath, Name)) {
        $lastBackupText = 'never'
        if ($null -ne $vm.LastBackup) {
            $lastBackupText = $vm.LastBackup.ToString('yyyy-MM-dd HH:mm:ss')
        }
        $lastFullText = 'never'
        if ($script:LastFull.ContainsKey($vm.Name)) {
            $lastFullText = $script:LastFull[$vm.Name].ToString('yyyy-MM-dd HH:mm:ss')
        }
        Write-NarvikLog -Level INFO -Message "Eligible VM '$($vm.Name)': folder '$($vm.FolderPath)', host '$($vm.HostName)', cluster '$($vm.ClusterName)' (priority $($vm.ClusterPriority), max_threads $($vm.ClusterMaxThreads)), size $($vm.TotalSizeGB) GB, last incremental $lastBackupText, last full $lastFullText."
    }

    Write-NarvikLog -Level INFO -Message "Non-eligible VMs: $(@($script:NonEligibleVMs).Count)."
    foreach ($entry in @($script:NonEligibleVMs | Sort-Object -Property { $_.VM.Name })) {
        Write-NarvikLog -Level INFO -Message "Non-eligible VM '$($entry.VM.Name)': $(@($entry.Reasons) -join '; ')."
    }

    Write-NarvikLog -Level INFO -Message 'No backup action was taken during idle maintenance.'

    $script:State.last_idle = $now
    Save-NarvikState
    Rotate-NarvikLog
}

function Stop-NarvikActiveJobs {
    param(
        [switch]$Force
    )

    foreach ($job in @($script:ActiveJobs)) {
        if ($null -eq $job.Process) {
            continue
        }

        try {
            if (-not $job.Process.HasExited) {
                if ($Force) {
                    Write-NarvikLog -Level WARNING -Message "Terminating backup process for VM '$($job.VmName)' (PID $($job.Process.Id))."
                    $job.Process.Kill()
                    [void]$job.Process.WaitForExit(30000)
                }
            }
        }
        catch {
            Write-NarvikLog -Level ERROR -Message "Could not terminate backup process for VM '$($job.VmName)': $($_.Exception.Message)"
        }
    }
}

function Invoke-NarvikControlFiles {
    $abortFile = Join-Path $script:RootPath 'abort.txt'
    $stopFile = Join-Path $script:RootPath 'stop.txt'

    if (Test-Path -LiteralPath $abortFile -PathType Leaf) {
        $script:AbortRequested = $true
        Write-NarvikLog -Level WARNING -Message "Abort control file detected; active backups will be terminated and Narvik will exit."
        try {
            Remove-Item -LiteralPath $abortFile -Force -ErrorAction Stop
        }
        catch {
            Write-NarvikLog -Level WARNING -Message "Could not remove abort control file '$abortFile': $($_.Exception.Message)"
        }
        Stop-NarvikActiveJobs -Force
        return
    }

    if (Test-Path -LiteralPath $stopFile -PathType Leaf) {
        if (-not $script:StopRequested) {
            $script:StopRequested = $true
            Write-NarvikLog -Level INFO -Message 'Stop control file detected; no new backups will be started. Waiting for active backups to finish.'
        }
        try {
            Remove-Item -LiteralPath $stopFile -Force -ErrorAction Stop
        }
        catch {
            Write-NarvikLog -Level WARNING -Message "Could not remove stop control file '$stopFile': $($_.Exception.Message)"
        }
    }
}

function Invoke-NarvikMain {
    Write-NarvikLog -Level INFO -Message 'Main loop started.'

    while ($true) {
        Invoke-NarvikControlFiles
        if ($script:AbortRequested) {
            break
        }

        Update-NarvikRuntimeConfig

        $cacheAvailable = Update-NarvikVCenterCache
        if ($script:VCacheRefreshedThisLoop) {
            Update-NarvikEligibility -SendAlerts
        }

        [void](Complete-NarvikJobs)
        Read-NarvikJobOutput

        if ($script:StopRequested) {
            if ($script:ActiveJobs.Count -eq 0) {
                Write-NarvikLog -Level INFO -Message 'Stop request completed; no active backups remain.'
                break
            }

            Write-NarvikStats
            Start-Sleep -Seconds 10
            continue
        }

        if (-not $cacheAvailable -and $null -eq $script:VCache) {
            Write-NarvikLog -Level DEBUG -Message 'vCenter inventory is unavailable; backup scheduling is paused until the next collection attempt.'
        }
        else {
            $startedAny = $false
            while ($script:ActiveJobs.Count -lt $script:Config.max_backup_threads) {
                $selection = Select-NarvikNextBackup
                if ($null -eq $selection) {
                    break
                }

                $job = Start-NarvikBackupJob -Selection $selection
                if ($null -eq $job) {
                    break
                }

                $startedAny = $true
            }

            Update-NarvikPendingMonitoring
            Write-NarvikStats

            if (-not $startedAny -and $script:ActiveJobs.Count -eq 0) {
                Invoke-NarvikIdleMaintenance
            }
        }

        Start-Sleep -Seconds 10
    }

    if ($script:AbortRequested) {
        Write-NarvikLog -Level WARNING -Message 'Narvik was aborted by the operator.'
    }
    else {
        Write-NarvikLog -Level INFO -Message 'Narvik stopped normally.'
    }
}

function Get-NarvikFallbackSmtpConfig {
    if ([string]::IsNullOrWhiteSpace($script:RootPath)) {
        return $null
    }

    $path = Join-Path $script:RootPath 'config.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }

    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        $object = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return $null
    }

    if ($null -eq $object) {
        return $null
    }

    $smtpServer = [string]$object.smtp_server
    $mailFrom = [string]$object.mail_from
    $mailTo = @($object.mail_to | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ([string]::IsNullOrWhiteSpace($smtpServer) -or [string]::IsNullOrWhiteSpace($mailFrom) -or $mailTo.Count -eq 0) {
        return $null
    }

    $port = 25
    if ($null -ne $object.smtp_port) {
        try { $port = [int]$object.smtp_port } catch { $port = 25 }
    }

    $useSsl = $false
    if ($object.smtp_use_ssl -is [bool]) {
        $useSsl = [bool]$object.smtp_use_ssl
    }
    elseif ([string]$object.smtp_use_ssl -ieq 'true') {
        $useSsl = $true
    }

    $username = [string]$object.smtp_username
    $passwordFileValue = [string]$object.smtp_password_file
    $passwordFile = $null
    if (-not [string]::IsNullOrWhiteSpace($passwordFileValue)) {
        if ([System.IO.Path]::IsPathRooted($passwordFileValue)) {
            $passwordFile = $passwordFileValue
        }
        else {
            $passwordFile = [System.IO.Path]::GetFullPath((Join-Path $script:RootPath $passwordFileValue))
        }
    }

    return [pscustomobject]@{
        smtp_server        = $smtpServer
        smtp_port          = $port
        smtp_use_ssl       = $useSsl
        smtp_username      = $username
        smtp_password_file = $passwordFile
        mail_from          = $mailFrom
        mail_to            = $mailTo
    }
}

function Send-NarvikFatalEmail {
    param(
        [Parameter(Mandatory = $true)]
        [int]$ExitCode,

        [AllowEmptyString()]
        [string]$ErrorMessage
    )

    $config = $script:Config
    if ($null -eq $config) {
        $config = Get-NarvikFallbackSmtpConfig
    }
    if ($null -eq $config) {
        return
    }

    $oldConfig = $script:Config
    $temporaryAttachment = $null

    try {
        $script:Config = $config

        $body = New-Object System.Text.StringBuilder
        [void]$body.AppendLine('Narvik terminated because of a fatal error.')
        [void]$body.AppendLine('')
        [void]$body.AppendLine("Exit code: $ExitCode")
        [void]$body.AppendLine("Error: $ErrorMessage")
        [void]$body.AppendLine('')
        if (-not [string]::IsNullOrWhiteSpace($script:LogFilePath)) {
            [void]$body.AppendLine("Log file: $($script:LogFilePath)")
        }
        [void]$body.AppendLine("Host: $env:COMPUTERNAME")
        [void]$body.AppendLine("Process ID: $PID")
        [void]$body.AppendLine("Time: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))")

        $attachments = @()
        if (-not [string]::IsNullOrWhiteSpace($script:LogFilePath) -and (Test-Path -LiteralPath $script:LogFilePath -PathType Leaf)) {
            $attachments = @($script:LogFilePath)
        }
        elseif ($null -ne $script:StartupLog -and $script:StartupLog.Count -gt 0) {
            $temporaryAttachment = Join-Path ([System.IO.Path]::GetTempPath()) ("narvik_fatal_$PID.log")
            try {
                [System.IO.File]::WriteAllLines($temporaryAttachment, @($script:StartupLog))
                $attachments = @($temporaryAttachment)
            }
            catch {
                $temporaryAttachment = $null
            }
        }

        [void](Send-NarvikMail -Subject "[Narvik] Fatal error - exit code $ExitCode" -Body $body.ToString() -Attachments $attachments)
    }
    finally {
        $script:Config = $oldConfig
        if ($null -ne $temporaryAttachment -and (Test-Path -LiteralPath $temporaryAttachment -PathType Leaf)) {
            try { Remove-Item -LiteralPath $temporaryAttachment -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
}

function Stop-NarvikChildProcesses {
    foreach ($job in @($script:ActiveJobs)) {
        if ($null -eq $job.Process) {
            continue
        }

        try {
            if (-not $job.Process.HasExited) {
                $job.Process.Kill()
                [void]$job.Process.WaitForExit(10000)
            }
        }
        catch {
        }
    }

    $script:ActiveJobs.Clear()
}

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
        if (-not [string]::IsNullOrWhiteSpace($_.ScriptStackTrace)) {
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
