<#
.SYNOPSIS
    Setup helper for the N-central to IT Glue device sync: saves secrets (encrypted) and
    registers the Windows scheduled task.

.DESCRIPTION
    Run from an elevated (Run as administrator) PowerShell on the computer that runs the sync.
    Same pattern as Register-ITGlueHealthMonitorTask.ps1.

    -SetSecret saves one or more secrets to <DataFolder>\secrets.json, encrypted with Windows
    DPAPI (LocalMachine scope by default, so a SYSTEM task can read it; CurrentUser when the
    task runs as a service account and you run this as that account). The file is locked so
    only SYSTEM, Administrators (and -TaskUser / the saving account) can read it.
        NCentralApiToken  N-central user API token (JWT) for a read-only N-central user
        ITGlueApiKey      IT Glue API key for this sync (Password Access OFF). Use a separate
                          key from the health monitor's, so it can be revoked on its own.
        SmtpPassword      only if Smtp.Username is set
        WebhookSecret     only if Webhook.SecretHeaderName is set

    Without -SetSecret or -Unregister it registers (or updates) the scheduled task:
      - runs Invoke-NCentralITGlueDeviceSync.ps1 every -IntervalMinutes (default 60)
      - in REPORT mode unless you add -Apply (then the task creates/updates IT Glue configurations)
      - as SYSTEM by default, or as -TaskUser (you'll be asked for its password)
      - never two runs at once; a run is stopped after IntervalMinutes - 1 minutes

.EXAMPLE
    .\Register-NCentralITGlueDeviceSyncTask.ps1 -SetSecret NCentralApiToken, ITGlueApiKey

.EXAMPLE
    # Report-only task first (alerts, changes nothing in IT Glue)
    .\Register-NCentralITGlueDeviceSyncTask.ps1 -TaskUser 'LTI-DT-AI\svc-itgmonitor'

.EXAMPLE
    # Later, after checking sync-preview.json: let the task make changes
    .\Register-NCentralITGlueDeviceSyncTask.ps1 -TaskUser 'LTI-DT-AI\svc-itgmonitor' -Apply

.EXAMPLE
    .\Register-NCentralITGlueDeviceSyncTask.ps1 -Unregister
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [ValidateSet('NCentralApiToken', 'ITGlueApiKey', 'SmtpPassword', 'WebhookSecret')]
    [string[]]$SetSecret,

    [ValidateSet('LocalMachine', 'CurrentUser')]
    [string]$SecretScope = 'LocalMachine',

    [string]$ScriptPath = (Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-NCentralITGlueDeviceSync.ps1'),
    [string]$ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath 'NCentralITGlueDeviceSync.config.json'),
    [string]$TaskName = 'N-central to IT Glue Device Sync',

    [ValidateRange(15, 1440)]
    [int]$IntervalMinutes = 60,

    [string]$TaskUser,
    [switch]$UsePwsh,

    # The task makes changes in IT Glue. Leave out for a report-only task.
    [switch]$Apply,

    [switch]$Unregister
)

$ErrorActionPreference = 'Stop'

$DataFolder = Join-Path -Path $env:ProgramData -ChildPath 'NCentralITGlueDeviceSync'
$SecretsFile = ''
if (Test-Path -LiteralPath $ConfigPath) {
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    if ($cfg.PSObject.Properties['DataFolder'] -and $cfg.DataFolder) { $DataFolder = [string]$cfg.DataFolder }
    if ($cfg.PSObject.Properties['SecretsFile'] -and $cfg.SecretsFile) { $SecretsFile = [string]$cfg.SecretsFile }
}
if (-not $SecretsFile) { $SecretsFile = Join-Path $DataFolder 'secrets.json' }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not ($SetSecret -and $SecretScope -eq 'CurrentUser')) {
    throw 'Run this from an elevated PowerShell (Run as administrator). Only -SetSecret ... -SecretScope CurrentUser works without it.'
}

if ($Unregister) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Removed scheduled task '$TaskName'. Data in $DataFolder was left in place." -ForegroundColor Green
    } else { Write-Host "No scheduled task named '$TaskName'." }
    return
}

if ($SetSecret) {
    Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
    $entropy = [Text.Encoding]::UTF8.GetBytes('LTI-NCentralITGlueDeviceSync-v1')
    $scope = [Security.Cryptography.DataProtectionScope]::$SecretScope
    $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $SecretsFile))
    $store = [ordered]@{}
    if (Test-Path -LiteralPath $SecretsFile) {
        $existing = Get-Content -LiteralPath $SecretsFile -Raw | ConvertFrom-Json
        foreach ($p in $existing.PSObject.Properties) { $store[$p.Name] = $p.Value }
    }
    foreach ($name in $SetSecret) {
        $secure = Read-Host -Prompt "Enter $name (input is hidden)" -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        if (-not $plain) { throw "Nothing entered for $name." }
        $enc = [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($plain.Trim()), $entropy, $scope)
        $plain = $null
        $store[$name] = [ordered]@{ scope = $SecretScope; data = [Convert]::ToBase64String($enc); saved = (Get-Date).ToString('yyyy-MM-dd HH:mm') }
        Write-Host "Saved $name." -ForegroundColor Green
    }
    [IO.File]::WriteAllText($SecretsFile, (ConvertTo-Json -InputObject $store -Depth 4), (New-Object Text.UTF8Encoding($false)))

    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    $ids = @(
        (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')),       # SYSTEM
        (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544'))    # Administrators
    )
    if ($TaskUser) { $ids += (New-Object System.Security.Principal.NTAccount($TaskUser)) }
    if ($SecretScope -eq 'CurrentUser') { $ids += [Security.Principal.WindowsIdentity]::GetCurrent().User }
    foreach ($id in $ids) {
        $right = 'FullControl'; if ($id -is [System.Security.Principal.NTAccount]) { $right = 'Read' }
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($id, $right, 'Allow')))
    }
    # SetAccessControl writes only the DACL (Set-Acl needs SeSecurityPrivilege, which a non-admin lacks).
    [IO.File]::SetAccessControl($SecretsFile, $acl)
    Write-Host "Secrets file: $SecretsFile (scope $SecretScope)."
    if ($SecretScope -eq 'CurrentUser') { Write-Host "Only $([Security.Principal.WindowsIdentity]::GetCurrent().Name) can decrypt these secrets, so the task must run as this account (-TaskUser)." -ForegroundColor Yellow }
    return
}

if (-not (Test-Path -LiteralPath $ScriptPath)) { throw "Sync script not found: $ScriptPath" }
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Config file not found: $ConfigPath. Copy NCentralITGlueDeviceSync.config.example.json to that name and fill it in first." }
$ScriptPath = (Resolve-Path -LiteralPath $ScriptPath).Path
$ConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path

if ($UsePwsh) {
    $exe = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    if (-not $exe) { throw 'pwsh.exe (PowerShell 7) was not found. Install it or leave out -UsePwsh.' }
} else { $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
$arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`" -ConfigPath `"$ConfigPath`""
if ($Apply) { $arguments += ' -Apply' }

$action = New-ScheduledTaskAction -Execute $exe -Argument $arguments -WorkingDirectory (Split-Path -Parent $ScriptPath)
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes ($IntervalMinutes - 1)) `
    -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

$null = [IO.Directory]::CreateDirectory($DataFolder)
if ($TaskUser) {
    $dacl = Get-Acl -LiteralPath $DataFolder
    $dacl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($TaskUser, 'Modify', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
    Set-Acl -LiteralPath $DataFolder -AclObject $dacl
}

$modeText = 'REPORT ONLY'; if ($Apply) { $modeText = 'APPLY (creates/updates IT Glue configurations)' }
$description = "N-central devices to IT Glue configurations, $modeText. Script: $ScriptPath"
if ($TaskUser) {
    $cred = Get-Credential -UserName $TaskUser -Message "Password for $TaskUser (the account the task runs as; needs 'Log on as a batch job')"
    Register-ScheduledTask -TaskName $TaskName -Description $description -Action $action -Trigger $trigger -Settings $settings `
        -User $cred.UserName -Password $cred.GetNetworkCredential().Password -RunLevel Limited -Force | Out-Null
} else {
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Description $description -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
}

Write-Host "Scheduled task '$TaskName' registered ($modeText): every $IntervalMinutes minutes, first run at $((Get-Date).AddMinutes(2).ToString('HH:mm'))." -ForegroundColor Green
Write-Host "Runs: $exe $arguments"
Write-Host "Logs and state: $DataFolder"
