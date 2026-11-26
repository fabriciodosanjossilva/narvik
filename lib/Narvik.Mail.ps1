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

        # Send-MailMessage only exposes certificate validation through the process-wide
        # ServicePointManager callback, so it is replaced just for this send and restored
        # right after (the PowerCLI connection uses the same callback).
        if ($script:Config.smtp_ignore_certificate) {
            $previousCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = [System.Net.Security.RemoteCertificateValidationCallback]{ param($sender, $certificate, $chain, $errors) return $true }
            try {
                Send-MailMessage @parameters
            }
            finally {
                [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $previousCallback
            }
        }
        else {
            Send-MailMessage @parameters
        }
        return $true
    }
    catch {
        Write-NarvikLog -Level ERROR -Message "Failed to send email '$Subject': $($_.Exception.Message)"
        return $false
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

    $ignoreCertificate = $false
    if ($object.smtp_ignore_certificate -is [bool]) {
        $ignoreCertificate = [bool]$object.smtp_ignore_certificate
    }
    elseif ([string]$object.smtp_ignore_certificate -ieq 'true') {
        $ignoreCertificate = $true
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
        smtp_use_ssl           = $useSsl
        smtp_ignore_certificate = $ignoreCertificate
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
