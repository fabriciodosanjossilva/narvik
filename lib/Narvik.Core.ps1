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
        # All files written by Narvik are UTF-8 with a byte order mark.
        $encoding = New-Object System.Text.UTF8Encoding -ArgumentList $true
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
    $exception = [System.Exception]::new($Message)
    # Marks the exception as an anticipated fatal error, so the top-level handler
    # omits the stack trace for it. Unanticipated exceptions do not carry this marker.
    $exception.Data['NarvikFatal'] = $true
    throw $exception
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
