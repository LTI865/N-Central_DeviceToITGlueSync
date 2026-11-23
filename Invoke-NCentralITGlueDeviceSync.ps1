<#
.SYNOPSIS
    Syncs devices (computers and servers) from N-able N-central into IT Glue as Configurations.
    A device whose N-central customer or site doesn't match an IT Glue organization and location
    is NOT synced: it is reported and an alert is sent.

.DESCRIPTION
    Data flow: N-central (devices only) > IT Glue (devices, customers, sites, contacts) > Halo.
    N-central is the source of truth for devices. IT Glue is the source of truth for customers,
    sites and contacts, so this script never creates, renames or changes an IT Glue organization
    or location. It only creates and updates IT Glue Configurations.

    Each run:
      1. Reads N-central (GET only): every device, plus hardware details (serial number, make,
         model, OS, MAC, IP) from /api/devices/{id}/assets, cached for NCentral.AssetRefreshHours.
      2. Reads IT Glue (GET): organizations, locations, configurations, configuration types and
         statuses, manufacturers and models.
      3. Matches every N-central device to an IT Glue organization and location:
           - the N-central Customer name must equal an IT Glue organization name (case and extra
             spaces ignored), or be mapped in CustomerNameMap;
           - if the device is under an N-central Site, the Site name must equal one of that
             organization's location names; a device directly under the customer goes to the
             organization's location if it has exactly one.
         A device that doesn't match is skipped and reported (check 1 or 2). Nothing is created
         for it, and the run alerts by email exactly like the IT Glue health monitor.
      4. Matches the device to an existing IT Glue Configuration: the one it was linked to
         before (sync-state.json), else the same serial number in that organization, else the
         same name/hostname in that organization (only if the serial numbers don't disagree).
         Anything ambiguous is reported (check 3) and left alone. Archived IT Glue
         Configurations are ignored completely: they are never matched, never count as a
         duplicate and are never changed. A device whose only IT Glue record is archived gets
         a new Configuration.
      5. Plans the changes: create missing Configurations, update fields that differ
         (Sync.UpdateFields). A value that is blank in N-central never clears IT Glue.
      6. With -Apply only: makes at most Sync.MaxChangesPerRun changes (the rest go on the
         next runs). Without -Apply nothing in IT Glue is changed.

    Optional local AI model (-UseLocalModel or LocalModel.Enabled, off by default): a model
    running in Ollama on this computer is asked about the devices that step 4 couldn't match by
    serial number or name. It gets one device at a time plus a short list of non-archived IT
    Glue configurations at the same customer, and answers in strict JSON (match id or none,
    confidence, reason). The script checks the answer: the id must be one of the candidates.
    High confidence (LocalModel.AutoLinkConfidence) links the device to that configuration;
    medium confidence (LocalModel.ReviewConfidence) holds the device and reports the possible
    match for a person (check 6); anything else is treated as no match. It can also suggest IT
    Glue configurations that look retired (check 7). Suggestions only: the model never
    creates, archives or deletes anything. Every prompt and answer is written to
    logs\ai-YYYYMMDD.jsonl. If Ollama is unreachable or keeps giving bad answers, the run
    carries on without it (as before) and the report says so.

    Never deletes or archives anything in IT Glue. Devices that were synced before but are no
    longer in N-central are reported (check 5); with Sync.RetiredDeviceAction "SetStatus" their
    Configuration status is set to Sync.RetiredStatus (at most Sync.MaxRetiresPerRun per run;
    above that nothing is changed and it is reported).

    Alerts: a message is sent only when the set of problems changes, plus a reminder every
    ReminderHours while they stay. If N-central or IT Glue can't be read, a "sync can't run"
    alert is sent on the first failed run and then every ReminderHours.

    Exit codes:  0 = everything matched (and, with -Apply, every change was made)
                 1 = one or more devices were skipped because of a problem (alert handled)
                 2 = the sync couldn't run (config, API key, N-central or IT Glue unreachable)
                 3 = a notification could not be sent (it is retried next run)
                 4 = IT Glue refused one or more changes, or the retire limit was hit

    Works in Windows PowerShell 5.1 and PowerShell 7+. No modules needed.
    NOT YET TESTED against live N-central or IT Glue. Start with -DryRun, then report mode,
    then -Apply with -DeviceId for one or two devices.

.PARAMETER ConfigPath
    The JSON config file. Defaults to NCentralITGlueDeviceSync.config.json next to this script.

.PARAMETER Apply
    Actually create and update IT Glue Configurations. Without it the script only reports
    (report mode: it reads, plans, writes sync-preview.json, alerts and saves state).

.PARAMETER DryRun
    Like report mode, but sends no alert and doesn't save any state. Prints what it would do.
    -WhatIf does the same.

.PARAMETER DeviceId
    Only consider these N-central device IDs this run (for a first live test). Other devices
    are still read, so problems are still found, but only these are changed and alerts and the
    removed-device check are not run.

.PARAMETER ChangeLimit
    For this run only, allow up to this many creates/updates instead of Sync.MaxChangesPerRun
    (for the first big import, after checking sync-preview.json).

.PARAMETER RetireLimit
    For this run only, allow up to this many status changes for devices removed from
    N-central instead of Sync.MaxRetiresPerRun.

.PARAMETER RefreshAssets
    Fetch hardware details again for every device (still capped by
    NCentral.MaxAssetLookupsPerRun), ignoring the cache.

.PARAMETER UseLocalModel
    Use the local AI model (Ollama) for this run, as if LocalModel.Enabled were true. See the
    LocalModel settings in the config.

.PARAMETER TestNotification
    Sends a test message through every configured notification method and stops.

.PARAMETER ForceNotify
    Sends the current status even if nothing changed since the last notification.

.EXAMPLE
    .\Invoke-NCentralITGlueDeviceSync.ps1 -DryRun

.EXAMPLE
    .\Invoke-NCentralITGlueDeviceSync.ps1 -Apply -DeviceId 123456789

.EXAMPLE
    .\Invoke-NCentralITGlueDeviceSync.ps1 -Apply -ChangeLimit 600

.EXAMPLE
    .\Invoke-NCentralITGlueDeviceSync.ps1 -DryRun -UseLocalModel
#>
[CmdletBinding(SupportsShouldProcess = $true, PositionalBinding = $false)]
param(
    [string]$ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath 'NCentralITGlueDeviceSync.config.json'),
    [switch]$Apply,
    [switch]$DryRun,
    [string[]]$DeviceId,
    [int]$ChangeLimit = -1,
    [int]$RetireLimit = -1,
    [switch]$RefreshAssets,
    [switch]$UseLocalModel,
    [switch]$TestNotification,
    [switch]$ForceNotify
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '0.4'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$EXIT_OK = 0; $EXIT_FAILED = 1; $EXIT_ERROR = 2; $EXIT_NOTIFY_FAILED = 3; $EXIT_WRITE_FAILED = 4

if ($WhatIfPreference) { $DryRun = [switch]$true; $WhatIfPreference = $false }
if ($DryRun) { $Apply = [switch]$false }
$DeviceId = @($DeviceId | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim() })
$Limited = ($DeviceId.Count -gt 0)

$CheckNames = [ordered]@{
    'CustomerNotInITGlue' = '1. N-central customer with no matching IT Glue organization'
    'SiteNotInITGlue'     = '2. N-central site with no matching IT Glue location'
    'DeviceConflict'      = "3. Devices that can't be matched safely"
    'WriteFailed'         = '4. Changes IT Glue refused'
    'RemovedFromNCentral' = '5. Synced devices no longer in N-central'
    'AiReview'            = '6. Possible matches from the local AI model (a person must check them)'
    'AiArchive'           = '7. IT Glue configurations the local AI model suggests archiving'
}

# =====================================================================================
# Config
# =====================================================================================
function ConvertTo-Hashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-Hashtable $p.Value }
        return $h
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $list = New-Object System.Collections.ArrayList
        foreach ($i in $InputObject) { $null = $list.Add((ConvertTo-Hashtable $i)) }
        return , $list.ToArray()
    }
    return $InputObject
}

$Defaults = [ordered]@{
    ITGlueBaseUrl          = 'https://api.itglue.com'
    DataFolder             = (Join-Path -Path $env:ProgramData -ChildPath 'NCentralITGlueDeviceSync')
    SecretsFile            = ''
    NCentral               = @{
        ServerUrl = ''; PageSize = 500; AssetDetails = $true; AssetRefreshHours = 24; MaxAssetLookupsPerRun = 300
        IncludeProbes = $false; SkipDevicesNotSeenDays = 0
        ExcludeCustomerIds = @(); ExcludeCustomerNames = @(); ExcludeSiteIds = @(); ExcludeDeviceIds = @()
    }
    SkipOrgStatus          = @('Inactive')
    SkipOrgType            = @()
    ExcludeOrganizationIds = @()
    CustomerNameMap        = @{}
    DeviceClassMap         = @(
        @{ Match = 'server'; ConfigurationType = 'Server' },
        @{ Match = 'laptop'; ConfigurationType = 'Laptop' },
        @{ Match = 'workstation|desktop'; ConfigurationType = 'Workstation' }
    )
    IgnoreSerials          = @('To Be Filled By O.E.M.', 'System Serial Number', 'Default string', 'None', 'Not Specified', 'Not Applicable', 'N/A', 'INVALID', 'Chassis Serial Number', 'Base Board Serial Number', '0', '00000000', '0123456789', '123456789')
    Sync                   = @{
        ConfigurationStatus = 'Active'
        UpdateFields = @('name', 'hostname', 'serial-number', 'configuration-type', 'location', 'operating-system-notes', 'manufacturer', 'model')
        MaxChangesPerRun = 100
        MatchByName = $true
        BlockAllOnMismatch = $false
        RetiredDeviceAction = 'Report'
        RetiredStatus = 'Inactive'
        MaxRetiresPerRun = 10
        MaxRetries = 3
        DelayMsBetweenWrites = 250
    }
    LocalModel             = @{
        Enabled = $false; Endpoint = 'http://localhost:11434'; Model = 'gemma4:12b'; AllowRemoteEndpoint = $false
        AutoLink = $true; AutoLinkConfidence = 90; ReviewConfidence = 60; MinNameSimilarity = 0.3; MaxCandidates = 15
        SuggestArchive = $true; TimeoutSec = 180; MaxCallsPerRun = 100; MaxMinutesPerRun = 20; CacheHours = 336
        ContextTokens = 8192; KeepAlive = '15m'
        ApprovedMatches = @{}; RejectedMatches = @{}; KeepConfigurationIds = @()
    }
    ReminderHours          = 24
    NotifyOnResolved       = $true
    MaxItemsPerCheck       = 50
    LogRetentionDays       = 30
    NotificationMethods    = @('Smtp')
    Smtp                   = @{ Server = ''; Port = 587; UseSsl = $true; From = ''; To = @(); Username = ''; SubjectPrefix = '[N-central > IT Glue]' }
    Webhook                = @{ Url = ''; SecretHeaderName = '' }
}

$configFound = Test-Path -LiteralPath $ConfigPath
$userCfg = @{}
if ($configFound) {
    try { $userCfg = ConvertTo-Hashtable (Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json) }
    catch { Write-Error "Config file '$ConfigPath' is not valid JSON: $($_.Exception.Message)"; exit $EXIT_ERROR }
    if ($userCfg -isnot [hashtable]) { Write-Error "Config file '$ConfigPath' must contain a JSON object."; exit $EXIT_ERROR }
} else {
    Write-Error "Config file not found: $ConfigPath. Copy NCentralITGlueDeviceSync.config.example.json to that name and fill it in."
    exit $EXIT_ERROR
}

$Cfg = @{}
$unknownKeys = @()
foreach ($k in $userCfg.Keys) { if (-not $Defaults.Contains($k) -and -not $k.StartsWith('_')) { $unknownKeys += $k } }
foreach ($k in $Defaults.Keys) {
    $d = $Defaults[$k]
    if ($d -is [hashtable] -and $k -ne 'CustomerNameMap') {
        $m = @{}; foreach ($kk in $d.Keys) { $m[$kk] = $d[$kk] }
        if ($userCfg.ContainsKey($k) -and $userCfg[$k] -is [hashtable]) { foreach ($kk in $userCfg[$k].Keys) { if (-not $kk.StartsWith('_')) { $m[$kk] = $userCfg[$k][$kk] } } }
        $Cfg[$k] = $m
    } elseif ($userCfg.ContainsKey($k) -and $null -ne $userCfg[$k]) {
        $Cfg[$k] = $userCfg[$k]
    } else {
        $Cfg[$k] = $d
    }
}
foreach ($k in 'SkipOrgStatus', 'SkipOrgType', 'ExcludeOrganizationIds', 'IgnoreSerials', 'NotificationMethods', 'DeviceClassMap') { $Cfg[$k] = @($Cfg[$k] | Where-Object { $null -ne $_ -and [string]$_ -ne '' }) }
foreach ($k in 'ExcludeCustomerIds', 'ExcludeCustomerNames', 'ExcludeSiteIds', 'ExcludeDeviceIds') { $Cfg.NCentral[$k] = @($Cfg.NCentral[$k] | Where-Object { $null -ne $_ -and [string]$_ -ne '' } | ForEach-Object { [string]$_ }) }
$Cfg.Sync.UpdateFields = @($Cfg.Sync.UpdateFields | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLowerInvariant() })
$Cfg.Smtp.To = @($Cfg.Smtp.To | Where-Object { $_ })
if ($Cfg.CustomerNameMap -isnot [hashtable]) { $Cfg.CustomerNameMap = @{} }
foreach ($k in 'ApprovedMatches', 'RejectedMatches') { if ($Cfg.LocalModel[$k] -isnot [hashtable]) { $Cfg.LocalModel[$k] = @{} } }
$Cfg.LocalModel.KeepConfigurationIds = @($Cfg.LocalModel.KeepConfigurationIds | Where-Object { $null -ne $_ -and [string]$_ -ne '' } | ForEach-Object { ([string]$_).Trim() })
$UseAI = ([bool]$UseLocalModel) -or ($Cfg.LocalModel.Enabled -eq $true)

$DataFolder = [string]$Cfg.DataFolder
$LogFolder = Join-Path $DataFolder 'logs'
$StatePath = Join-Path $DataFolder 'state.json'
$SyncStatePath = Join-Path $DataFolder 'sync-state.json'
$PreviewPath = Join-Path $DataFolder 'sync-preview.json'
$CurrentCsvPath = Join-Path $DataFolder 'current-failures.csv'
$AssetSamplePath = Join-Path $DataFolder 'ncentral-asset-sample.json'
$SecretsFile = [string]$Cfg.SecretsFile
if (-not $SecretsFile) { $SecretsFile = Join-Path $DataFolder 'secrets.json' }
try { $null = [IO.Directory]::CreateDirectory($LogFolder) }
catch { Write-Error "Can't create '$LogFolder'. Set DataFolder in the config to a folder this account can write. ($($_.Exception.Message))"; exit $EXIT_ERROR }

# =====================================================================================
# Logging
# =====================================================================================
$LogPath = Join-Path $LogFolder ("sync-{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
$RunId = Get-Date -Format 'HHmmss'
function Write-Log {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR', 'PROBLEM', 'CHANGE')][string]$Level = 'INFO')
    $line = '{0} [{1}] {2,-7} {3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $RunId, $Level, $Message
    try { [IO.File]::AppendAllText($LogPath, $line + [Environment]::NewLine) } catch { }
    $color = 'Gray'
    switch ($Level) { 'WARN' { $color = 'Yellow' } 'ERROR' { $color = 'Red' } 'PROBLEM' { $color = 'DarkYellow' } 'CHANGE' { $color = 'Cyan' } }
    Write-Host $line -ForegroundColor $color
}
foreach ($k in $unknownKeys) { Write-Log "Unknown setting '$k' in the config file was ignored (check the spelling)." 'WARN' }
try {
    $cutoff = (Get-Date).AddDays(-[int]$Cfg.LogRetentionDays)
    Get-ChildItem -LiteralPath $LogFolder -File | Where-Object { ($_.Name -like 'sync-*.log' -or $_.Name -like 'ai-*.jsonl') -and $_.LastWriteTime -lt $cutoff } | Remove-Item -Force
} catch { Write-Log "Couldn't clean up old logs: $($_.Exception.Message)" 'WARN' }

# =====================================================================================
# Secrets: environment variable first, then the encrypted secrets file
# (written by Register-NCentralITGlueDeviceSyncTask.ps1 -SetSecret, Windows DPAPI).
# =====================================================================================
$SecretEnvNames = @{ NCentralApiToken = 'NCENTRAL_API_TOKEN'; ITGlueApiKey = 'NCITG_ITGLUE_API_KEY'; SmtpPassword = 'NCITG_SMTP_PASSWORD'; WebhookSecret = 'NCITG_WEBHOOK_SECRET' }
$SecretEntropy = [Text.Encoding]::UTF8.GetBytes('LTI-NCentralITGlueDeviceSync-v1')
$script:SecretCache = $null
function Get-Secret {
    param([string]$Name)
    $v = [Environment]::GetEnvironmentVariable($SecretEnvNames[$Name])
    if ($v) { return $v }
    if (-not (Test-Path -LiteralPath $SecretsFile)) { return $null }
    if ($null -eq $script:SecretCache) { $script:SecretCache = Get-Content -LiteralPath $SecretsFile -Raw | ConvertFrom-Json }
    $entry = $script:SecretCache.PSObject.Properties[$Name]
    if (-not $entry) { return $null }
    try { Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue } catch { }
    $scope = [Security.Cryptography.DataProtectionScope]::LocalMachine
    if ($entry.Value.scope -eq 'CurrentUser') { $scope = [Security.Cryptography.DataProtectionScope]::CurrentUser }
    try {
        $plain = [Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($entry.Value.data), $SecretEntropy, $scope)
        return [Text.Encoding]::UTF8.GetString($plain)
    } catch {
        throw "Couldn't decrypt secret '$Name' from $SecretsFile. It must be saved on this computer (and, for CurrentUser scope, by the account the task runs as). Save it again with Register-NCentralITGlueDeviceSyncTask.ps1 -SetSecret $Name. ($($_.Exception.Message))"
    }
}

# =====================================================================================
# Notifications (same as the IT Glue health monitor: Smtp and/or Webhook)
# =====================================================================================
function Get-HtmlText { param($s) return [System.Net.WebUtility]::HtmlEncode([string]$s) }

function Send-SmtpNotification {
    param([string]$Subject, [string]$Html, [string]$AttachmentPath)
    $s = $Cfg.Smtp
    if (-not $s.Server -or -not $s.From -or $s.To.Count -eq 0) { throw 'SMTP is selected but Smtp.Server, Smtp.From or Smtp.To is empty in the config.' }
    $msg = New-Object System.Net.Mail.MailMessage
    $client = $null
    try {
        $msg.From = New-Object System.Net.Mail.MailAddress([string]$s.From)
        foreach ($t in $s.To) { $msg.To.Add([string]$t) }
        $msg.Subject = $Subject
        $msg.Body = $Html
        $msg.IsBodyHtml = $true
        if ($AttachmentPath -and (Test-Path -LiteralPath $AttachmentPath)) {
            $null = $msg.Attachments.Add((New-Object System.Net.Mail.Attachment($AttachmentPath)))
        }
        $client = New-Object System.Net.Mail.SmtpClient([string]$s.Server, [int]$s.Port)
        $client.EnableSsl = [bool]$s.UseSsl
        $client.Timeout = 60000
        if ($s.Username) {
            $pw = Get-Secret 'SmtpPassword'
            if (-not $pw) { throw "Smtp.Username is set but no SMTP password was found (env NCITG_SMTP_PASSWORD or secret 'SmtpPassword')." }
            $client.UseDefaultCredentials = $false
            $client.Credentials = New-Object System.Net.NetworkCredential([string]$s.Username, $pw)
        }
        $client.Send($msg)
    } finally {
        $msg.Dispose()
        if ($client) { $client.Dispose() }
    }
}
function Send-WebhookNotification {
    param([hashtable]$Payload)
    $u = [string]$Cfg.Webhook.Url
    $uri = $null
    if (-not [Uri]::TryCreate($u, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https') { throw "Webhook.Url must be a full https address (got '$u')." }
    $headers = @{}
    if ($Cfg.Webhook.SecretHeaderName) {
        $sec = Get-Secret 'WebhookSecret'
        if (-not $sec) { throw "Webhook.SecretHeaderName is set but no secret was found (env NCITG_WEBHOOK_SECRET or secret 'WebhookSecret')." }
        $headers[[string]$Cfg.Webhook.SecretHeaderName] = $sec
    }
    $json = ConvertTo-Json -InputObject $Payload -Depth 6
    $null = Invoke-RestMethod -Method POST -Uri $u -Headers $headers -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ContentType 'application/json; charset=utf-8' -MaximumRedirection 0
}
function Send-AllNotifications {
    param([string]$Subject, [string]$Html, [hashtable]$Payload, [string]$AttachmentPath)
    if ($Cfg.NotificationMethods.Count -eq 0) { Write-Log 'No NotificationMethods are configured, so nothing was sent.' 'WARN'; return $true }
    $ok = $true
    foreach ($m in $Cfg.NotificationMethods) {
        try {
            switch -Regex ([string]$m) {
                '^smtp$' { Send-SmtpNotification -Subject $Subject -Html $Html -AttachmentPath $AttachmentPath; Write-Log "Email sent to $($Cfg.Smtp.To -join ', ')." }
                '^webhook$' { Send-WebhookNotification -Payload $Payload; Write-Log 'Webhook sent.' }
                default { throw "Unknown notification method '$m' (use Smtp or Webhook)." }
            }
        } catch {
            $ok = $false
            $why = $_.Exception.Message
            $inner = $_.Exception.InnerException
            while ($inner) { $why += " -> $($inner.Message)"; $inner = $inner.InnerException }
            Write-Log "Notification via $m FAILED: $why" 'ERROR'
        }
    }
    return $ok
}

if ($TestNotification) {
    Write-Log "TEST NOTIFICATION (methods: $($Cfg.NotificationMethods -join ', '))"
    $when = Get-Date -Format 'yyyy-MM-dd HH:mm'
    $html = "<p>This is a test message from the N-central to IT Glue device sync on <b>$(Get-HtmlText $env:COMPUTERNAME)</b> at $when.</p><p>No action is needed.</p>"
    $ok = Send-AllNotifications -Subject "$($Cfg.Smtp.SubjectPrefix) Test message" -Html $html -Payload @{ title = 'N-central to IT Glue device sync test'; status = 'test'; html = $html; computer = $env:COMPUTERNAME } -AttachmentPath $null
    if ($ok) { Write-Log 'Test notification finished.'; exit $EXIT_OK }
    exit $EXIT_NOTIFY_FAILED
}

# =====================================================================================
# State files and lock
# =====================================================================================
function ConvertFrom-Utc { param($v) if (-not $v) { return $null } if ($v -is [DateTime]) { return $v.ToUniversalTime() } try { return [DateTime]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal) } catch { return $null } }
function Get-UtcText { return [DateTime]::UtcNow.ToString('o') }
function Save-JsonFile {
    param([string]$Path, $Obj, [int]$Depth = 6, [switch]$Compress)
    $tmp = "$Path.tmp"
    $json = if ($Compress) { ConvertTo-Json -InputObject $Obj -Depth $Depth -Compress } else { ConvertTo-Json -InputObject $Obj -Depth $Depth }
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) } else { [IO.File]::Move($tmp, $Path) }
}
function Read-State {
    $s = @{ ActiveFailures = @{}; LastNotifiedUtc = $null; ConsecutiveErrors = 0; ErrorAlertSent = $false; LastErrorAlertUtc = $null; LastRunUtc = $null; LastRunResult = '' }
    if (-not (Test-Path -LiteralPath $StatePath)) { return $s }
    try {
        $j = ConvertTo-Hashtable (Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json)
        foreach ($k in @($s.Keys)) { if ($j.ContainsKey($k) -and $null -ne $j[$k]) { $s[$k] = $j[$k] } }
        if ($s.ActiveFailures -isnot [hashtable]) { $s.ActiveFailures = @{} }
    } catch { Write-Log "State file $StatePath couldn't be read, starting fresh (every current problem will count as new): $($_.Exception.Message)" 'WARN' }
    return $s
}
# links:  N-central device id -> @{ itg = IT Glue configuration id; org; linkedUtc; diffHash; sends; retiredUtc }
# assets: N-central device id -> @{ fetchedUtc; serial; manufacturer; model; os; mac; ip }
# ai:     hash of a local-model question -> @{ askedUtc; kind; answer } (answers reused until CacheHours)
function Read-SyncState {
    $st = @{ links = @{}; assets = @{}; ai = @{} }
    if (Test-Path -LiteralPath $SyncStatePath) {
        try {
            $j = ConvertTo-Hashtable (Get-Content -LiteralPath $SyncStatePath -Raw | ConvertFrom-Json)
            foreach ($k in 'links', 'assets', 'ai') { if ($j[$k] -is [hashtable]) { $st[$k] = $j[$k] } }
        } catch {
            # Without the links, devices are matched again by serial number and name, so this is safe.
            Write-Log "Sync state $SyncStatePath couldn't be read; devices will be matched again by serial number and name: $($_.Exception.Message)" 'WARN'
        }
    }
    return $st
}

$lockPath = Join-Path $DataFolder 'sync.lock'
$lock = $null
try { $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
catch { Write-Log 'Another run is still in progress (lock file is held). Skipping this run.' 'WARN'; exit $EXIT_OK }

$State = Read-State
$Sync = Read-SyncState
$mode = 'REPORT ONLY (IT Glue is not changed; add -Apply to make changes)'
if ($Apply) { $mode = 'APPLY (creates and updates IT Glue configurations)' }
if ($DryRun) { $mode = 'DRY RUN (nothing changed, nothing sent, state not saved)' }
Write-Log "N-CENTRAL > IT GLUE DEVICE SYNC v$ScriptVersion - $mode"
if ($Limited) { Write-Log "Limited to N-central device id(s): $($DeviceId -join ', ')" }
if ($UseAI) { Write-Log "Local AI model: $($Cfg.LocalModel.Model) at $($Cfg.LocalModel.Endpoint) (suggestions only; auto-link at confidence $($Cfg.LocalModel.AutoLinkConfidence)+$(if ($Cfg.LocalModel.AutoLink -ne $true) { ' is OFF' }))." }

# =====================================================================================
# Shared HTTP helpers
# =====================================================================================
function Get-RetryAfterSeconds {
    param($ErrorRecord)
    $resp = $ErrorRecord.Exception.Response
    if (-not $resp) { return $null }
    try {
        if ($resp.GetType().FullName -eq 'System.Net.Http.HttpResponseMessage') {
            $ra = $resp.Headers.RetryAfter
            if ($ra -and $ra.Delta) { return [int][math]::Ceiling($ra.Delta.Value.TotalSeconds) }
            if ($ra -and $ra.Date) { return [int][math]::Ceiling(($ra.Date.Value - [DateTimeOffset]::UtcNow).TotalSeconds) }
        } else {
            $v = $resp.Headers['Retry-After']
            $n = 0
            if ($v -and [int]::TryParse($v, [ref]$n)) { return $n }
        }
    } catch { }
    return $null
}
function Get-HttpStatus { param($ErrorRecord) if ($ErrorRecord.Exception.Response) { return [int]$ErrorRecord.Exception.Response.StatusCode } return 0 }
function Get-HttpErrorText {
    param($ErrorRecord)
    $t = ''
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) { $t = [string]$ErrorRecord.ErrorDetails.Message }
    if (-not $t) { $t = $ErrorRecord.Exception.Message }
    # IT Glue errors look like {"errors":[{"status":"422","title":"...","detail":"..."}]}
    try {
        $j = $t | ConvertFrom-Json
        if ($j.errors) { return (@($j.errors | ForEach-Object { (@($_.title, $_.detail) | Where-Object { $_ }) -join ': ' }) -join '; ') }
    } catch { }
    if ($t.Length -gt 400) { $t = $t.Substring(0, 400) + '...' }
    return $t
}

# =====================================================================================
# N-central REST API (GET only, plus the token exchange)
#   POST /api/auth/authenticate   with the user API token (JWT) as Bearer -> access token
#   GET  /api/devices             paged (pageNumber, pageSize)
#   GET  /api/org-units           paged, to fill in customer/site names if a device lacks them
#   GET  /api/devices/{id}/assets hardware details (serial number, make, model, OS, NICs)
# =====================================================================================
$NcBase = ([string]$Cfg.NCentral.ServerUrl).Trim().TrimEnd('/')
if ($NcBase -match '/api$') { $NcBase = $NcBase.Substring(0, $NcBase.Length - 4) }
$script:NcHeaders = $null

function Connect-NCentral {
    $u = $null
    if (-not [Uri]::TryCreate($NcBase, [UriKind]::Absolute, [ref]$u) -or $u.Scheme -ne 'https' -or $u.AbsolutePath -ne '/') {
        throw "NCentral.ServerUrl must be just the https address of your N-central server, e.g. https://ncentral.example.com (got '$NcBase')."
    }
    $jwt = Get-Secret 'NCentralApiToken'
    if (-not $jwt) { throw "No N-central API token found (env NCENTRAL_API_TOKEN or secret 'NCentralApiToken'). Create one in N-central under Administration > User Management > Users > (user) > API Access, and save it with Register-NCentralITGlueDeviceSyncTask.ps1 -SetSecret NCentralApiToken." }
    try {
        $r = Invoke-RestMethod -Method POST -Uri "$NcBase/api/auth/authenticate" -Headers @{ Authorization = "Bearer $jwt" } -MaximumRedirection 0 -TimeoutSec 60
    } catch {
        $st = Get-HttpStatus $_
        if ($st -eq 401 -or $st -eq 403) { throw "N-central refused the API token (HTTP $st). The token may have expired or been regenerated, or the user lacks API access." }
        throw "Couldn't sign in to N-central at $NcBase (HTTP $st): $(Get-HttpErrorText $_)"
    }
    $tok = $null
    if ($r.tokens -and $r.tokens.access) { $tok = [string]$r.tokens.access.token }
    if (-not $tok) { throw 'N-central sign-in answered without an access token (tokens.access.token).' }
    $script:NcHeaders = @{ Authorization = "Bearer $tok"; Accept = 'application/json' }
}
function Invoke-NCentralGet {
    param([string]$Path)
    $uri = "$NcBase$Path"
    if (-not $uri.StartsWith("$NcBase/api/", [StringComparison]::Ordinal)) { throw "Refusing to call $uri (not under $NcBase/api/)." }
    $attempt = 0; $reauth = $false
    while ($true) {
        $attempt++
        try { return Invoke-RestMethod -Method GET -Uri $uri -Headers $script:NcHeaders -MaximumRedirection 0 -TimeoutSec 120 }
        catch {
            $status = Get-HttpStatus $_
            if ($status -ge 300 -and $status -lt 400) { throw "N-central answered with a redirect (HTTP $status). The sync does not follow redirects." }
            if ($status -eq 401 -and -not $reauth) { $reauth = $true; Connect-NCentral; continue }   # access token expired mid-run
            if (($status -eq 429 -or $status -ge 500 -or $status -eq 0) -and $attempt -lt 5) {
                $wait = Get-RetryAfterSeconds $_
                if (-not $wait -or $wait -lt 1) { $wait = [math]::Pow(2, $attempt) * 5 }
                $wait = [math]::Min($wait, 120)
                Write-Log "HTTP $status from N-central for $Path, waiting $wait seconds then retrying ($attempt/4)..." 'WARN'
                Start-Sleep -Seconds $wait
                continue
            }
            throw "N-central GET $Path failed (HTTP $status): $(Get-HttpErrorText $_)"
        }
    }
}
# Reads every page and rejects duplicates and short reads, so a partial read can't make
# devices look "removed from N-central".
function Get-NCentralAll {
    param([string]$Path, [string]$IdField)
    $size = [int]$Cfg.NCentral.PageSize
    $results = New-Object System.Collections.ArrayList
    $seen = @{}
    $page = 1; $totalItems = $null; $totalPages = $null
    $sep = '?'; if ($Path.Contains('?')) { $sep = '&' }
    while ($true) {
        $resp = Invoke-NCentralGet -Path "$Path${sep}pageNumber=$page&pageSize=$size"
        $data = @()
        if ($resp.PSObject.Properties['data']) { $data = @($resp.data | Where-Object { $null -ne $_ }) }
        else { throw "N-central response for $Path (page $page) has no 'data' list." }
        if ($null -eq $totalItems -and $resp.PSObject.Properties['totalItems'] -and $null -ne $resp.totalItems) { $totalItems = [int]$resp.totalItems }
        if ($null -eq $totalPages -and $resp.PSObject.Properties['totalPages'] -and $null -ne $resp.totalPages) { $totalPages = [int]$resp.totalPages }
        foreach ($r in $data) {
            $id = [string]$r.$IdField
            if (-not $id) { throw "A record in $Path has no $IdField." }
            if ($seen.ContainsKey($id)) { throw "N-central returned $Path record $id twice while paging. It will be read again next run." }
            $seen[$id] = $true
            $null = $results.Add($r)
        }
        # Stop on N-central's page count when it gives one (it may cap pageSize below what was asked).
        if ($null -ne $totalPages) { if ($page -ge $totalPages) { break } }
        elseif ($data.Count -lt $size) { break }
        if ($data.Count -eq 0) { break }
        $page++
        if ($page -gt 1000) { throw "N-central paging for $Path didn't end after 1000 pages." }
        Start-Sleep -Milliseconds 200
    }
    if ($null -ne $totalItems -and $results.Count -ne $totalItems) { throw "N-central said $Path has $totalItems records but $($results.Count) were received. It will be read again next run." }
    return , $results.ToArray()
}
function Get-PropCI {
    # Case-insensitive property lookup, trying each name in turn.
    param($Obj, [string[]]$Names)
    if ($null -eq $Obj) { return $null }
    foreach ($n in $Names) {
        foreach ($p in $Obj.PSObject.Properties) { if ($p.Name -ieq $n -and $null -ne $p.Value -and [string]$p.Value -ne '') { return $p.Value } }
    }
    return $null
}
function Get-AssetDetails {
    param([string]$Id)
    $r = Invoke-NCentralGet -Path "/api/devices/$Id/assets"
    $a = $r; if ($r.PSObject.Properties['data'] -and $r.data) { $a = $r.data }
    if (-not (Test-Path -LiteralPath $AssetSamplePath)) {
        # One raw example, so the field names can be checked against what this N-central returns.
        try { Save-JsonFile -Path $AssetSamplePath -Obj $a -Depth 6 } catch { }
    }
    $cs = Get-PropCI $a @('computersystem', 'computerSystem')
    $os = Get-PropCI $a @('os')
    $bios = Get-PropCI $a @('bios')
    $dev = Get-PropCI $a @('device')
    $serial = Get-PropCI $cs @('serialnumber', 'serialNumber')
    if (-not $serial) { $serial = Get-PropCI $bios @('serialnumber', 'serialNumber') }
    if (-not $serial) { $serial = Get-PropCI $dev @('serialnumber', 'serialNumber') }
    $osText = Get-PropCI $os @('reportedos', 'reportedOS', 'name', 'caption')
    $osVer = Get-PropCI $os @('version')
    if ($osText -and $osVer -and -not ([string]$osText).Contains([string]$osVer)) { $osText = "$osText ($osVer)" }
    $mac = $null; $ip = $null
    $nics = Get-PropCI $a @('networkadapter', 'networkAdapter', 'networkadapters')
    foreach ($n in @($nics)) {
        if ($null -eq $n) { continue }
        $nip = [string](Get-PropCI $n @('ipaddress', 'ipAddress'))
        $nmac = [string](Get-PropCI $n @('macaddress', 'macAddress'))
        $v4 = @($nip -split '[,;\s]+' | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' -and $_ -notmatch '^(0\.|127\.|169\.254\.)' }) | Select-Object -First 1
        if ($v4 -and $nmac) { $ip = $v4; $mac = $nmac; break }
        if (-not $mac -and $nmac) { $mac = $nmac }
    }
    return @{
        fetchedUtc = Get-UtcText
        serial = [string]$serial
        manufacturer = [string](Get-PropCI $cs @('manufacturer'))
        model = [string](Get-PropCI $cs @('model'))
        os = [string]$osText
        mac = [string]$mac
        ip = [string]$ip
    }
}

# =====================================================================================
# IT Glue API (GET, plus POST/PATCH on /configurations only)
# =====================================================================================
$BaseUrl = ([string]$Cfg.ITGlueBaseUrl).Trim().TrimEnd('/')
$AllowedUrls = @('https://api.itglue.com', 'https://api.eu.itglue.com', 'https://api.au.itglue.com')

function Invoke-ITGlueGet {
    param([string]$Uri)
    if (-not $Uri.StartsWith("$BaseUrl/", [StringComparison]::Ordinal)) { throw "Refusing to call $Uri (not under $BaseUrl)." }
    $attempt = 0
    while ($true) {
        $attempt++
        try { return Invoke-RestMethod -Method GET -Uri $Uri -Headers $script:ITGHeaders -MaximumRedirection 0 -TimeoutSec 120 }
        catch {
            $status = Get-HttpStatus $_
            if ($status -ge 300 -and $status -lt 400) { throw "IT Glue answered with a redirect (HTTP $status). The sync does not follow redirects." }
            if ($status -eq 401 -or $status -eq 403) { throw "IT Glue refused the request (HTTP $status). Check the API key and that ITGlueBaseUrl matches your region." }
            if (($status -eq 429 -or $status -ge 500 -or $status -eq 0) -and $attempt -lt 5) {
                $wait = Get-RetryAfterSeconds $_
                if (-not $wait -or $wait -lt 1) { $wait = [math]::Pow(2, $attempt) * 5 }
                $wait = [math]::Min($wait, 120)
                Write-Log "HTTP $status from IT Glue, waiting $wait seconds then retrying ($attempt/4)..." 'WARN'
                Start-Sleep -Seconds $wait
                continue
            }
            throw
        }
    }
}
function Get-ITGlueAll {
    param([string]$Path)
    $results = New-Object System.Collections.ArrayList
    $seen = @{}
    $page = 1
    $expectedPages = $null; $expectedCount = $null
    while ($true) {
        $sep = '?'; if ($Path.Contains('?')) { $sep = '&' }
        $resp = Invoke-ITGlueGet -Uri "$BaseUrl$Path${sep}page[size]=1000&page[number]=$page"
        if (-not $resp.meta -or
            -not $resp.meta.PSObject.Properties['total-pages'] -or -not $resp.meta.PSObject.Properties['total-count'] -or
            $null -eq $resp.meta.'total-pages' -or $null -eq $resp.meta.'total-count') {
            throw "IT Glue response for $Path (page $page) is missing paging information. Stopping so no records are missed."
        }
        $pages = [int]$resp.meta.'total-pages'
        $count = [int]$resp.meta.'total-count'
        if ($null -eq $expectedPages) { $expectedPages = $pages; $expectedCount = $count }
        elseif ($pages -ne $expectedPages -or $count -ne $expectedCount) {
            throw "IT Glue paging for $Path changed while reading it (was $expectedCount records / $expectedPages pages, now $count / $pages). It will be read again next run."
        }
        foreach ($r in @($resp.data)) {
            if ($null -eq $r) { continue }
            $id = [string]$r.id
            if (-not $id -or $id -notmatch '^\d+$') { throw "A record in $Path has an invalid id ('$id')." }
            if ($seen.ContainsKey($id)) { throw "IT Glue returned $Path record $id twice while paging. It will be read again next run." }
            $seen[$id] = $true
            $null = $results.Add($r)
        }
        if ($page -ge $expectedPages) { break }
        $page++
        Start-Sleep -Milliseconds 200
    }
    if ($results.Count -ne $expectedCount) { throw "IT Glue said $Path has $expectedCount records but $($results.Count) were received." }
    return , $results.ToArray()
}
# The only writes this script makes. POST is not retried after a timeout or 5xx, so a
# configuration can't be created twice; it is reported and the next run matches it by serial.
function Invoke-ITGlueWrite {
    param([ValidateSet('POST', 'PATCH')][string]$Method, [string]$Path, [hashtable]$Attributes)
    if ($Method -eq 'POST' -and $Path -ne '/configurations') { throw "Refusing to POST to $Path." }
    if ($Method -eq 'PATCH' -and $Path -notmatch '^/configurations/\d+$') { throw "Refusing to PATCH $Path." }
    $body = @{ data = @{ type = 'configurations'; attributes = $Attributes } }
    $json = ConvertTo-Json -InputObject $body -Depth 6 -Compress
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            return Invoke-RestMethod -Method $Method -Uri "$BaseUrl$Path" -Headers $script:ITGWriteHeaders -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ContentType 'application/vnd.api+json' -MaximumRedirection 0 -TimeoutSec 120
        } catch {
            $status = Get-HttpStatus $_
            $retry = ($status -eq 429) -or ($Method -eq 'PATCH' -and ($status -ge 500 -or $status -eq 0))
            if ($retry -and $attempt -lt 4) {
                $wait = Get-RetryAfterSeconds $_
                if (-not $wait -or $wait -lt 1) { $wait = [math]::Pow(2, $attempt) * 5 }
                Start-Sleep -Seconds ([math]::Min($wait, 120))
                continue
            }
            throw "HTTP $status $(Get-HttpErrorText $_)"
        }
    }
}
function Get-Attr {
    param($Rec, [string]$Prop)
    if (-not $Rec -or -not $Rec.attributes -or -not $Rec.attributes.PSObject.Properties[$Prop]) { return '' }
    $v = $Rec.attributes.$Prop
    if ($null -eq $v) { return '' }
    return [string]$v
}
# Asks IT Glue directly whether a non-archived configuration with this serial number (any
# organization) or this name/hostname (this organization) exists. Returns '' when none.
# Archived configurations are ignored: N-central is the source of truth for devices.
function Find-ITGlueDuplicateNow {
    param([string]$OrgId, [string]$Name, [string]$Hostname, [string]$Serial)
    $found = @()
    $names = @(@($Name, $Hostname) | Where-Object { $_ } | ForEach-Object { Get-NameKey $_ } | Select-Object -Unique)
    $queries = @()
    if ($Serial) { $queries += "filter[serial_number]=$([Uri]::EscapeDataString($Serial))" }
    foreach ($n in @(@($Name, $Hostname) | Where-Object { $_ } | Select-Object -Unique)) { $queries += "filter[organization_id]=$OrgId&filter[name]=$([Uri]::EscapeDataString($n))" }
    foreach ($q in $queries) {
        $r = Invoke-ITGlueGet -Uri "$BaseUrl/configurations?$q&filter[archived]=false&page[size]=50"
        foreach ($x in @($r.data | Where-Object { $_ })) {
            if ((Get-Attr $x 'archived') -eq 'True') { continue }
            # Compare exactly here, in case IT Glue's filter matches partly.
            $sameSerial = $Serial -and (Get-SerialKey (Get-Attr $x 'serial-number')) -eq (Get-SerialKey $Serial)
            $sameName = (Get-Attr $x 'organization-id') -eq $OrgId -and (($names -contains (Get-NameKey (Get-Attr $x 'name'))) -or ((Get-Attr $x 'hostname') -and $names -contains (Get-NameKey (Get-Attr $x 'hostname'))))
            if ($sameSerial -or $sameName) { $found += "'$(Get-Attr $x 'name')' (id $($x.id), $(Get-Attr $x 'organization-name'))" }
        }
    }
    return ((@($found | Select-Object -Unique)) -join '; ')
}
function Get-NameKey { param([string]$S) return ($S -replace '\s+', ' ').Trim().ToLowerInvariant() }
function Get-SerialKey { param([string]$S) return ($S -replace '\s+', '').ToUpperInvariant() }
function Get-TextHash {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))) -replace '-', '').Substring(0, 16) }
    finally { $sha.Dispose() }
}
# N-central's discovered name is sometimes an IP address; that isn't a hostname.
function Get-HostnameText { param($S) $t = ([string]$S).Trim(); if (($t -match '^\d{1,3}(\.\d{1,3}){3}$') -or ($t.Contains(':') -and $t -match '^[0-9a-f:]+$')) { return '' } return $t }

# =====================================================================================
# Findings
# =====================================================================================
$Failures = New-Object System.Collections.ArrayList
function Add-Failure {
    param([string]$Check, [string]$Key, [string]$Customer, [string]$Item, [string]$Detail, [string]$Link)
    $null = $script:Failures.Add([pscustomobject]@{ Check = $Check; Key = "$Check|$Key"; Customer = $Customer; Item = $Item; Detail = $Detail; Link = $Link })
}
function Get-SectionHtml {
    param([string]$Title, [object[]]$Items, [string]$Color)
    if (-not $Items -or $Items.Count -eq 0) { return '' }
    $max = [int]$Cfg.MaxItemsPerCheck
    $sb = New-Object Text.StringBuilder
    $null = $sb.Append("<h3 style='color:$Color;margin:18px 0 6px'>$(Get-HtmlText $Title) ($($Items.Count))</h3>")
    foreach ($ck in $CheckNames.Keys) {
        $list = @($Items | Where-Object { $_.Check -eq $ck })
        if ($list.Count -eq 0) { continue }
        $null = $sb.Append("<p style='margin:10px 0 4px'><b>$(Get-HtmlText $CheckNames[$ck])</b> ($($list.Count))</p>")
        $null = $sb.Append("<table cellpadding='4' cellspacing='0' style='border-collapse:collapse;font-size:13px'>")
        $null = $sb.Append("<tr style='background:#eee'><th align='left'>N-central customer</th><th align='left'>Item</th><th align='left'>Detail</th></tr>")
        foreach ($f in ($list | Select-Object -First $max)) {
            $item = Get-HtmlText $f.Item
            if ($f.Link) { $item = "<a href='$(Get-HtmlText $f.Link)'>$item</a>" }
            $null = $sb.Append("<tr style='border-top:1px solid #ddd'><td valign='top'>$(Get-HtmlText $f.Customer)</td><td valign='top'>$item</td><td valign='top'>$(Get-HtmlText $f.Detail)</td></tr>")
        }
        $null = $sb.Append('</table>')
        if ($list.Count -gt $max) { $null = $sb.Append("<p style='margin:4px 0'><i>...and $($list.Count - $max) more (see the attached list).</i></p>") }
    }
    return $sb.ToString()
}
function Get-SectionText {
    param([string]$Title, [object[]]$Items)
    if (-not $Items -or $Items.Count -eq 0) { return '' }
    $max = [int]$Cfg.MaxItemsPerCheck
    $lines = New-Object System.Collections.ArrayList
    $null = $lines.Add(''); $null = $lines.Add("== $Title ($($Items.Count)) ==")
    foreach ($ck in $CheckNames.Keys) {
        $list = @($Items | Where-Object { $_.Check -eq $ck })
        if ($list.Count -eq 0) { continue }
        $null = $lines.Add("-- $($CheckNames[$ck]) ($($list.Count))")
        foreach ($f in ($list | Select-Object -First $max)) { $null = $lines.Add("   $($f.Customer) | $($f.Item) | $($f.Detail)") }
        if ($list.Count -gt $max) { $null = $lines.Add("   ...and $($list.Count - $max) more") }
    }
    return ($lines -join "`r`n")
}

# =====================================================================================
# Optional local AI model (Ollama on this computer). It only SUGGESTS. The script checks every
# answer and makes every decision; the model never creates, archives or deletes anything.
# =====================================================================================
$Lm = $Cfg.LocalModel
$LmBase = ([string]$Lm.Endpoint).Trim().TrimEnd('/')
$AiLogPath = Join-Path $LogFolder ("ai-{0}.jsonl" -f (Get-Date -Format 'yyyyMMdd'))
$AiPromptVersion = 'v1'   # change when the prompts change, so cached answers are asked again
$script:AiReady = $false; $script:AiDown = ''; $script:AiCalls = 0; $script:AiBadInRow = 0
$script:AiClock = $null   # started at the first question, so MaxMinutesPerRun counts model time only
$script:AiUsedKeys = @{}

$AiMatchSystem = @'
You help keep IT documentation (IT Glue) in step with an RMM tool (N-central). N-central is the source of truth for devices.
You get ONE device from N-central and a short list of existing IT Glue configurations at the SAME customer.
Decide whether one of those configurations is the SAME physical device, only named or recorded differently
(for example: the computer was renamed, a different naming style, hostname vs. display name, a typo, an
added or missing prefix or suffix, or the IT Glue record has no serial number).
Rules:
- Only choose a configuration from the list, by its id. If none is clearly the same device, set match_id to "".
- A different serial number means a different device. A matching serial number or MAC address is strong evidence.
- Names that are only alike in a pattern (PC-01 vs PC-02, or two users' laptops) are NOT the same device.
- Matching manufacturer, model, type and location support a match; a conflict weakens it.
- confidence is 0 to 100: how sure you are that match_id is the same device. Use 0 when match_id is "".
- reason is one short sentence a technician can check.
Answer only with the JSON object.
'@
$AiArchiveSystem = @'
You help clean up IT documentation (IT Glue). N-central, the RMM tool, monitors every active computer and server at this customer.
You get ONE IT Glue configuration (a computer or server record) that is NOT linked to any device that is in N-central now,
plus the N-central devices at the same customer with the most similar names.
Decide whether this record is most likely a retired, replaced or duplicate device that a technician should archive.
Signs it should be archived: not updated for a long time, status like inactive/retired/decommissioned, the name looks like an
older version of an N-central device (same user or role with an older number or model), or it looks like a duplicate of one.
Signs to keep it: updated recently, a kind of device N-central may not monitor, or no clear replacement and recent activity.
Nothing is archived automatically: a person reviews your answer.
confidence is 0 to 100: how sure you are about your archive answer. reason is one short sentence a technician can check.
Answer only with the JSON object.
'@
$AiMatchSchema = @{
    type = 'object'
    properties = [ordered]@{ match_id = @{ type = 'string' }; confidence = @{ type = 'integer'; minimum = 0; maximum = 100 }; reason = @{ type = 'string' } }
    required = @('match_id', 'confidence', 'reason')
}
$AiArchiveSchema = @{
    type = 'object'
    properties = [ordered]@{ archive = @{ type = 'boolean' }; confidence = @{ type = 'integer'; minimum = 0; maximum = 100 }; reason = @{ type = 'string' } }
    required = @('archive', 'confidence', 'reason')
}

# 0..1, how alike two device names are (letters and digits only, case ignored; Levenshtein).
function Get-NameSimilarity {
    param([string]$First, [string]$Second)
    $x = ([string]$First).ToLowerInvariant() -replace '[^a-z0-9]', ''
    $y = ([string]$Second).ToLowerInvariant() -replace '[^a-z0-9]', ''
    if (-not $x -or -not $y) { return 0.0 }
    if ($x -eq $y) { return 1.0 }
    $n = $x.Length; $m = $y.Length
    $prev = New-Object 'int[]' ($m + 1); $cur = New-Object 'int[]' ($m + 1)
    for ($j = 0; $j -le $m; $j++) { $prev[$j] = $j }
    for ($i = 1; $i -le $n; $i++) {
        $cur[0] = $i
        for ($j = 1; $j -le $m; $j++) {
            $cost = 1; if ($x[$i - 1] -ceq $y[$j - 1]) { $cost = 0 }
            $v = $prev[$j] + 1
            if ($cur[$j - 1] + 1 -lt $v) { $v = $cur[$j - 1] + 1 }
            if ($prev[$j - 1] + $cost -lt $v) { $v = $prev[$j - 1] + $cost }
            $cur[$j] = $v
        }
        $t = $prev; $prev = $cur; $cur = $t
    }
    return 1.0 - ($prev[$m] / [double][math]::Max($n, $m))
}
function Get-MacKey { param([string]$S) $t = ([string]$S -replace '[^0-9A-Fa-f]', '').ToUpperInvariant(); if ($t.Length -ne 12 -or $t -eq '000000000000' -or $t -eq 'FFFFFFFFFFFF') { return '' } return $t }
function Get-ShortText { param($S, [int]$Max = 120) $t = ([string]$S).Trim() -replace '\s+', ' '; if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max) }; return $t }
function Write-AiAudit {
    param([hashtable]$Entry)
    if ($DryRun) { $Entry['dryRun'] = $true }
    $Entry['time'] = Get-UtcText; $Entry['run'] = $RunId
    try { [IO.File]::AppendAllText($AiLogPath, (ConvertTo-Json -InputObject $Entry -Depth 8 -Compress) + [Environment]::NewLine) } catch { }
}
# Checks the settings and that Ollama answers and has the model. A settings mistake stops the run;
# Ollama being down only turns the model off for this run.
function Test-LocalModel {
    $u = $null
    if (-not [Uri]::TryCreate($LmBase, [UriKind]::Absolute, [ref]$u) -or @('http', 'https') -notcontains $u.Scheme) { throw "LocalModel.Endpoint must look like http://localhost:11434 (got '$LmBase')." }
    $isLocal = @('localhost', '127.0.0.1', '::1', '[::1]') -contains $u.Host.ToLowerInvariant()
    if (-not $isLocal -and $Lm.AllowRemoteEndpoint -ne $true) { throw "LocalModel.Endpoint '$LmBase' is not on this computer. Device and customer names would be sent there, so it needs LocalModel.AllowRemoteEndpoint set to true." }
    if (-not [string]$Lm.Model) { throw 'LocalModel.Model is empty (for example "gemma4:12b").' }
    foreach ($k in 'AutoLinkConfidence', 'ReviewConfidence') { $v = [int]$Lm[$k]; if ($v -lt 1 -or $v -gt 100) { throw "LocalModel.$k must be between 1 and 100." } }
    if ([int]$Lm.ReviewConfidence -gt [int]$Lm.AutoLinkConfidence) { throw 'LocalModel.ReviewConfidence must not be higher than LocalModel.AutoLinkConfidence.' }
    try { $tags = Invoke-RestMethod -Method GET -Uri "$LmBase/api/tags" -TimeoutSec 15 -MaximumRedirection 0 }
    catch { $script:AiDown = "Ollama isn't answering at $LmBase ($($_.Exception.Message)). Check that Ollama is running and that this account can reach it."; return }
    $names = @($tags.models | ForEach-Object { [string]$_.name; [string]$_.model } | Where-Object { $_ } | Select-Object -Unique)
    $want = [string]$Lm.Model
    if (-not @($names | Where-Object { $_ -ieq $want -or $_ -ieq "${want}:latest" }).Count) {
        $script:AiDown = "Ollama at $LmBase doesn't have the model '$want' (installed: $(if ($names.Count) { $names -join ', ' } else { 'none' })). Run: ollama pull $want"
        return
    }
    $script:AiReady = $true
    Write-Log "Local AI model '$want' is available at $LmBase."
}
function Invoke-LocalModel {
    param([string]$System, [string]$Prompt, [hashtable]$Schema)
    $body = [ordered]@{
        model = [string]$Lm.Model; stream = $false; format = $Schema
        options = @{ temperature = 0; seed = 7; num_ctx = [int]$Lm.ContextTokens }
        messages = @(@{ role = 'system'; content = $System }, @{ role = 'user'; content = $Prompt })
    }
    if ($Lm.KeepAlive) { $body['keep_alive'] = [string]$Lm.KeepAlive }
    $json = ConvertTo-Json -InputObject $body -Depth 10 -Compress
    $r = Invoke-RestMethod -Method POST -Uri "$LmBase/api/chat" -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ContentType 'application/json; charset=utf-8' -TimeoutSec ([int]$Lm.TimeoutSec) -MaximumRedirection 0
    if (-not $r -or -not $r.message) { throw 'Ollama answered without a message.' }
    return [string]$r.message.content
}
function ConvertFrom-ModelJson {
    param([string]$Text)
    $t = ([string]$Text).Trim()
    $i = $t.IndexOf('{'); $j = $t.LastIndexOf('}')
    if ($i -lt 0 -or $j -le $i) { throw 'the answer has no JSON object' }
    return ($t.Substring($i, $j - $i + 1) | ConvertFrom-Json)
}
function ConvertTo-Confidence {
    param($V)
    $d = 0.0
    if (-not [double]::TryParse(([string]$V), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { throw "confidence '$V' is not a number" }
    if ($d -gt 0 -and $d -lt 1) { $d = $d * 100 }   # some models answer 0.95 instead of 95
    if ($d -lt 0 -or $d -gt 100) { throw "confidence $d is outside 0-100" }
    return [int][math]::Round($d)
}
# Asks the model one question, or reuses the answer to the identical question from an earlier run.
# Returns @{ status = ok|deferred|error; answer; cached; why }. $Validate turns the parsed JSON into
# a checked answer hashtable or throws (it gets the parsed JSON and $Context); only checked answers are cached.
function Get-AiAnswer {
    param([string]$Kind, [string]$Subject, [string]$System, [string]$Prompt, [hashtable]$Schema, [scriptblock]$Validate, $Context)
    $key = Get-TextHash "$AiPromptVersion|$($Lm.Model)|$Kind|$System|$Prompt"
    $script:AiUsedKeys[$key] = $true
    $hit = $Sync.ai[$key]
    if ($hit -is [hashtable] -and $hit.answer -is [hashtable]) {
        $t = ConvertFrom-Utc $hit.askedUtc
        if ($t -and ([DateTime]::UtcNow - $t).TotalHours -lt [double]$Lm.CacheHours) { return @{ status = 'ok'; answer = $hit.answer; cached = $true; key = $key } }
    }
    if ($script:AiDown) { return @{ status = 'error'; why = $script:AiDown } }
    if (-not $script:AiClock) { $script:AiClock = [Diagnostics.Stopwatch]::StartNew() }
    if ($script:AiCalls -ge [int]$Lm.MaxCallsPerRun -or $script:AiClock.Elapsed.TotalMinutes -ge [double]$Lm.MaxMinutesPerRun) { return @{ status = 'deferred' } }
    $script:AiCalls++
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $raw = ''; $answer = $null; $err = ''
    try { $raw = Invoke-LocalModel -System $System -Prompt $Prompt -Schema $Schema }
    catch {
        $err = "Ollama call failed: $($_.Exception.Message)"
        $script:AiDown = "Ollama stopped answering during the run ($($_.Exception.Message)). If this is a timeout, raise LocalModel.TimeoutSec or use a smaller model."
    }
    if (-not $err) {
        try { $answer = & $Validate (ConvertFrom-ModelJson $raw) $Context; $script:AiBadInRow = 0 }
        catch {
            $err = "Invalid answer: $($_.Exception.Message)"
            $script:AiBadInRow++
            if ($script:AiBadInRow -ge 3) { $script:AiDown = "The model '$($Lm.Model)' gave 3 invalid answers in a row (last: $($_.Exception.Message))." }
        }
    }
    $sw.Stop()
    Write-AiAudit @{ type = 'call'; kind = $Kind; subject = $Subject; model = [string]$Lm.Model; key = $key; system = $System; prompt = $Prompt; raw = $raw; answer = $answer; error = $err; ms = $sw.ElapsedMilliseconds }
    if ($err) { return @{ status = 'error'; why = $err } }
    $Sync.ai[$key] = @{ askedUtc = Get-UtcText; kind = $Kind; answer = $answer }
    return @{ status = 'ok'; answer = $answer; cached = $false; key = $key }
}
# Compact facts about an IT Glue configuration for a prompt. Only things that rarely change,
# so the cached answer stays valid.
function Get-ConfFacts {
    param($X)
    $f = [ordered]@{ id = [string]$X.id; name = (Get-Attr $X 'name') }
    foreach ($p in @(@('hostname', 'hostname'), @('serial', 'serial-number'), @('type', 'configuration-type-name'), @('location', 'location-name'),
            @('manufacturer', 'manufacturer-name'), @('model', 'model-name'), @('os', 'operating-system-notes'), @('mac', 'mac-address'), @('status', 'configuration-status-name'))) {
        $v = Get-ShortText (Get-Attr $X $p[1]) 80
        if ($v) { $f[$p[0]] = $v }
    }
    $upd = Get-Attr $X 'updated-at'; if ($upd.Length -ge 10) { $f['last_updated'] = $upd.Substring(0, 10) }
    $cr = Get-Attr $X 'created-at'; if ($cr.Length -ge 10) { $f['created'] = $cr.Substring(0, 10) }
    return $f
}

# =====================================================================================
# The sync
# =====================================================================================
function Invoke-DeviceSync {
    $stats = [ordered]@{ ncDevices = 0; considered = 0; skippedClass = 0; skippedExcluded = 0; skippedStale = 0; skippedProbe = 0; customerMismatch = 0; siteMismatch = 0; conflicts = 0; waitingForDetails = 0; inSync = 0; toCreate = 0; toUpdate = 0; created = 0; updated = 0; writeFailed = 0; deferred = 0; removed = 0; retired = 0
        aiAsked = 0; aiCached = 0; aiLinked = 0; aiReview = 0; aiNoMatch = 0; aiNotAsked = 0; aiArchive = 0; aiDeferred = 0; aiErrors = 0 }

    # ---------- Settings that must be right before anything is read ----------
    if ($AllowedUrls -notcontains $BaseUrl) { throw "ITGlueBaseUrl '$BaseUrl' isn't one of $($AllowedUrls -join ', ')." }
    $key = Get-Secret 'ITGlueApiKey'
    if (-not $key) { throw "No IT Glue API key found (env NCITG_ITGLUE_API_KEY or secret 'ITGlueApiKey')." }
    $script:ITGHeaders = @{ 'x-api-key' = $key; 'Content-Type' = 'application/vnd.api+json' }   # same as the health monitor (works live)
    $script:ITGWriteHeaders = @{ 'x-api-key' = $key }   # Content-Type comes from -ContentType on writes
    $classMap = @()
    foreach ($m in $Cfg.DeviceClassMap) {
        if ($m -isnot [hashtable] -or -not $m.Match -or -not $m.ConfigurationType) { throw 'Every DeviceClassMap entry needs Match (a regular expression) and ConfigurationType (an IT Glue configuration type name).' }
        try { $null = [regex]::new([string]$m.Match, 'IgnoreCase') } catch { throw "DeviceClassMap Match '$($m.Match)' isn't a valid regular expression." }
        $classMap += @{ Match = [string]$m.Match; Type = [string]$m.ConfigurationType }
    }
    if ($UseAI) { Test-LocalModel }   # settings mistakes stop here; Ollama being down only turns the model off
    $ignoreSerial = @{}; foreach ($s in $Cfg.IgnoreSerials) { $ignoreSerial[(Get-SerialKey $s)] = $true }
    $nameMap = @{}; foreach ($k in $Cfg.CustomerNameMap.Keys) { if (-not $k.StartsWith('_')) { $nameMap[(Get-NameKey $k)] = Get-NameKey ([string]$Cfg.CustomerNameMap[$k]) } }

    # ---------- 1. Read N-central ----------
    Write-Log "Reading N-central at $NcBase ..."
    Connect-NCentral
    $ncDevices = Get-NCentralAll -Path '/api/devices' -IdField 'deviceId'
    $stats.ncDevices = $ncDevices.Count
    Write-Log "N-central: $($ncDevices.Count) devices."
    $orgUnits = @{}
    $needUnits = @($ncDevices | Where-Object { -not $_.customerName -and $_.orgUnitId }).Count -gt 0
    if ($needUnits) {
        foreach ($u in (Get-NCentralAll -Path '/api/org-units' -IdField 'orgUnitId')) { $orgUnits[[string]$u.orgUnitId] = $u }
        Write-Log "N-central: $($orgUnits.Count) org units (some devices had no customer name)."
    }

    # ---------- 2. Read IT Glue ----------
    Write-Log "Reading IT Glue at $BaseUrl ..."
    $orgs = Get-ITGlueAll '/organizations'
    $locs = Get-ITGlueAll '/locations'
    # Archived configurations are ignored everywhere (matching, duplicate checks, alerts) and never
    # changed. N-central is the source of truth for devices; an archived IT Glue record doesn't count.
    $confs = @(Get-ITGlueAll '/configurations?filter[archived]=false' | Where-Object { (Get-Attr $_ 'archived') -ne 'True' })
    $types = Get-ITGlueAll '/configuration_types'
    $statuses = Get-ITGlueAll '/configuration_statuses'
    $mfrs = Get-ITGlueAll '/manufacturers'
    $models = Get-ITGlueAll '/models'
    Write-Log "IT Glue: $($orgs.Count) organizations, $($locs.Count) locations, $($confs.Count) configurations (archived ones ignored)."
    # Evidence of another integration already writing configurations (PSA/RMM-linked records).
    $byIntegration = @{}
    foreach ($c in $confs) {
        foreach ($f in 'rmm-integration-type', 'psa-integration-type', 'psa-integration') {
            $v = Get-Attr $c $f
            if ($v) { $k = "$f=$v"; if (-not $byIntegration.ContainsKey($k)) { $byIntegration[$k] = 0 }; $byIntegration[$k]++ }
        }
    }
    if ($byIntegration.Count -gt 0) { Write-Log ("IT Glue configurations linked to another integration: {0}. Make sure that integration isn't also syncing N-central devices." -f ((@($byIntegration.Keys | Sort-Object | ForEach-Object { "$_ ($($byIntegration[$_]))" })) -join ', ')) 'WARN' }
    else { Write-Log 'No IT Glue configurations are linked to an RMM or PSA integration.' }

    $typeIds = @{}; foreach ($t in $types) { $typeIds[(Get-NameKey (Get-Attr $t 'name'))] = [string]$t.id }
    foreach ($m in $classMap) { if (-not $typeIds.ContainsKey((Get-NameKey $m.Type))) { throw "IT Glue has no configuration type named '$($m.Type)' (DeviceClassMap). Types: $((@($types | ForEach-Object { Get-Attr $_ 'name' }) | Sort-Object) -join ', ')" } }
    $statusIds = @{}; foreach ($s in $statuses) { $statusIds[(Get-NameKey (Get-Attr $s 'name'))] = [string]$s.id }
    $newStatusId = $statusIds[(Get-NameKey ([string]$Cfg.Sync.ConfigurationStatus))]
    if (-not $newStatusId) { throw "IT Glue has no configuration status named '$($Cfg.Sync.ConfigurationStatus)' (Sync.ConfigurationStatus). Statuses: $((@($statuses | ForEach-Object { Get-Attr $_ 'name' }) | Sort-Object) -join ', ')" }
    $retiredStatusId = $null
    if ([string]$Cfg.Sync.RetiredDeviceAction -eq 'SetStatus') {
        $retiredStatusId = $statusIds[(Get-NameKey ([string]$Cfg.Sync.RetiredStatus))]
        if (-not $retiredStatusId) { throw "IT Glue has no configuration status named '$($Cfg.Sync.RetiredStatus)' (Sync.RetiredStatus)." }
    } elseif ([string]$Cfg.Sync.RetiredDeviceAction -ne 'Report') { throw "Sync.RetiredDeviceAction must be Report or SetStatus (got '$($Cfg.Sync.RetiredDeviceAction)')." }
    $mfrIds = @{}; foreach ($m in $mfrs) { $mfrIds[(Get-NameKey (Get-Attr $m 'name'))] = [string]$m.id }
    $modelIds = @{}; foreach ($m in $models) { $modelIds["$(Get-Attr $m 'manufacturer-id')|$(Get-NameKey (Get-Attr $m 'name'))"] = [string]$m.id }

    # Organizations (customers) by name, skipping the ones the health monitor skips.
    $orgByName = @{}; $orgById = @{}
    foreach ($o in $orgs) {
        if ($Cfg.SkipOrgStatus -contains (Get-Attr $o 'organization-status-name')) { continue }
        if ($Cfg.SkipOrgType -contains (Get-Attr $o 'organization-type-name')) { continue }
        if ($Cfg.ExcludeOrganizationIds -contains [string]$o.id) { continue }
        $orgById[[string]$o.id] = $o
        $nk = Get-NameKey (Get-Attr $o 'name')
        if (-not $orgByName.ContainsKey($nk)) { $orgByName[$nk] = New-Object System.Collections.ArrayList }
        $null = $orgByName[$nk].Add($o)
    }
    $locsByOrg = @{}
    foreach ($l in $locs) {
        $oid = Get-Attr $l 'organization-id'
        if (-not $locsByOrg.ContainsKey($oid)) { $locsByOrg[$oid] = New-Object System.Collections.ArrayList }
        $null = $locsByOrg[$oid].Add($l)
    }
    # Every non-archived configuration (linked to a device or not) by serial number (any organization)
    # and by organization + name. Used to make sure nothing is created or renamed into a duplicate.
    $anyBySerial = @{}; $anyByOrgName = @{}
    foreach ($c in $confs) {
        $sk = Get-SerialKey (Get-Attr $c 'serial-number')
        if ($sk -and -not $ignoreSerial.ContainsKey($sk)) { if (-not $anyBySerial.ContainsKey($sk)) { $anyBySerial[$sk] = New-Object System.Collections.ArrayList }; $null = $anyBySerial[$sk].Add($c) }
        $oid = Get-Attr $c 'organization-id'
        foreach ($n in @(@((Get-Attr $c 'name'), (Get-Attr $c 'hostname')) | Where-Object { $_ } | ForEach-Object { Get-NameKey $_ } | Select-Object -Unique)) {
            $k = "$oid|$n"
            if (-not $anyByOrgName.ContainsKey($k)) { $anyByOrgName[$k] = New-Object System.Collections.ArrayList }
            $null = $anyByOrgName[$k].Add($c)
        }
    }
    $confById = @{}; $confsBySerial = @{}; $confsByOrgName = @{}; $confsByOrg = @{}
    $orgsHeld = @{}   # organizations with devices that couldn't be matched this run (no archive suggestions there)
    foreach ($c in $confs) {
        if ((Get-Attr $c 'archived') -eq 'True') { continue }
        $confById[[string]$c.id] = $c
        $coid = Get-Attr $c 'organization-id'
        if (-not $confsByOrg.ContainsKey($coid)) { $confsByOrg[$coid] = New-Object System.Collections.ArrayList }
        $null = $confsByOrg[$coid].Add($c)
        $sk = Get-SerialKey (Get-Attr $c 'serial-number')
        if ($sk -and -not $ignoreSerial.ContainsKey($sk)) {
            if (-not $confsBySerial.ContainsKey($sk)) { $confsBySerial[$sk] = New-Object System.Collections.ArrayList }
            $null = $confsBySerial[$sk].Add($c)
        }
        $oid = Get-Attr $c 'organization-id'
        foreach ($n in @(@((Get-Attr $c 'name'), (Get-Attr $c 'hostname')) | Where-Object { $_ } | ForEach-Object { Get-NameKey $_ } | Select-Object -Unique)) {
            $k = "$oid|$n"
            if (-not $confsByOrgName.ContainsKey($k)) { $confsByOrgName[$k] = New-Object System.Collections.ArrayList }
            $null = $confsByOrgName[$k].Add($c)
        }
    }
    # Which IT Glue configuration is already linked to which N-central device.
    $linkedConf = @{}
    foreach ($nid in @($Sync.links.Keys)) {
        $lk = $Sync.links[$nid]
        if ($lk -is [hashtable] -and $lk.itg) { $linkedConf[[string]$lk.itg] = $nid }
    }

    # ---------- 3. Match each device to a customer and site ----------
    $ncById = @{}
    $candidates = New-Object System.Collections.ArrayList
    $customerProblems = @{}; $siteProblems = @{}
    $staleDays = [int]$Cfg.NCentral.SkipDevicesNotSeenDays
    foreach ($d in $ncDevices) {
        $id = [string]$d.deviceId
        $ncById[$id] = $d
        $name = [string]$d.longName
        $class = [string](Get-PropCI $d @('deviceClass', 'deviceClassLabel'))
        if ($d.isProbe -eq $true -and -not $Cfg.NCentral.IncludeProbes) { $stats.skippedProbe++; continue }
        $custId = [string]$d.customerId; $custName = [string]$d.customerName
        $siteId = [string]$d.siteId; $siteName = [string]$d.siteName
        if (-not $custName -and $d.orgUnitId -and $orgUnits.ContainsKey([string]$d.orgUnitId)) {
            # Fill in from the org-unit tree: a site's parent is its customer.
            $u = $orgUnits[[string]$d.orgUnitId]
            if ([string]$u.orgUnitType -match 'site') {
                $siteId = [string]$u.orgUnitId; $siteName = [string]$u.orgUnitName
                $p = $orgUnits[[string]$u.parentId]
                if ($p) { $custId = [string]$p.orgUnitId; $custName = [string]$p.orgUnitName }
            } elseif ([string]$u.orgUnitType -match 'customer') { $custId = [string]$u.orgUnitId; $custName = [string]$u.orgUnitName }
        }
        if ($siteId -in @('', '0', '-1') -or $siteId -eq $custId) { $siteId = ''; $siteName = '' }
        if ($Cfg.NCentral.ExcludeDeviceIds -contains $id -or ($custId -and $Cfg.NCentral.ExcludeCustomerIds -contains $custId) -or
            ($siteId -and $Cfg.NCentral.ExcludeSiteIds -contains $siteId) -or
            ($custName -and @($Cfg.NCentral.ExcludeCustomerNames | Where-Object { (Get-NameKey $_) -eq (Get-NameKey $custName) }).Count -gt 0)) { $stats.skippedExcluded++; continue }
        $type = $null
        foreach ($m in $classMap) { if ($class -match $m.Match) { $type = $m.Type; break } }
        if (-not $type) { $stats.skippedClass++; continue }
        if ($staleDays -gt 0) {
            $seen = ConvertFrom-Utc $d.lastApplianceCheckinTime
            if ($seen -and ([DateTime]::UtcNow - $seen).TotalDays -gt $staleDays) { $stats.skippedStale++; continue }
        }
        $stats.considered++

        if (-not $custName) {
            $stats.customerMismatch++
            Add-Failure 'CustomerNotInITGlue' "device:$id" '(none)' $name "This device isn't under an N-central customer (it's at service-organization level). Move it under a customer in N-central."
            continue
        }
        $ck = Get-NameKey $custName
        $target = $ck; if ($nameMap.ContainsKey($ck)) { $target = $nameMap[$ck] }
        $orgMatches = @(); if ($orgByName.ContainsKey($target)) { $orgMatches = @($orgByName[$target]) }
        if ($orgMatches.Count -ne 1) {
            $stats.customerMismatch++
            if (-not $customerProblems.ContainsKey($custId)) { $customerProblems[$custId] = @{ Name = $custName; Devices = New-Object System.Collections.ArrayList; Count = $orgMatches.Count } }
            $null = $customerProblems[$custId].Devices.Add($name)
            continue
        }
        $org = $orgMatches[0]; $orgId = [string]$org.id
        $orgLocs = @(); if ($locsByOrg.ContainsKey($orgId)) { $orgLocs = @($locsByOrg[$orgId]) }
        $loc = $null; $why = ''
        if ($siteName) {
            $lm = @($orgLocs | Where-Object { (Get-NameKey (Get-Attr $_ 'name')) -eq (Get-NameKey $siteName) })
            if ($lm.Count -eq 1) { $loc = $lm[0] }
            elseif ($lm.Count -gt 1) { $why = "IT Glue organization '$(Get-Attr $org 'name')' has $($lm.Count) locations named '$siteName'." }
            else { $why = "IT Glue organization '$(Get-Attr $org 'name')' has no location named '$siteName'. Its location(s): $((@($orgLocs | ForEach-Object { Get-Attr $_ 'name' })) -join ', ')" }
        } else {
            if ($orgLocs.Count -eq 1) { $loc = $orgLocs[0] }
            else { $why = "The device is directly under the N-central customer (no site) and IT Glue organization '$(Get-Attr $org 'name')' has $($orgLocs.Count) locations, so the location can't be chosen." }
        }
        if (-not $loc) {
            $stats.siteMismatch++
            $orgsHeld[$orgId] = $true
            $sk = "$custId|$siteId"
            if (-not $siteProblems.ContainsKey($sk)) { $siteProblems[$sk] = @{ Customer = $custName; Site = $(if ($siteName) { $siteName } else { '(no site)' }); Why = $why; Devices = New-Object System.Collections.ArrayList; OrgUrl = (Get-Attr $org 'resource-url') } }
            $null = $siteProblems[$sk].Devices.Add($name)
            continue
        }
        $null = $candidates.Add(@{ Id = $id; Name = $name; Hostname = (Get-HostnameText (Get-PropCI $d @('discoveredName'))); Class = $class; Type = $type; CustName = $custName; Org = $org; OrgId = $orgId; Loc = $loc; LocId = [string]$loc.id; OsFallback = [string](Get-PropCI $d @('supportedOsLabel', 'supportedOs')); LastSeen = $d.lastApplianceCheckinTime })
    }
    foreach ($cid in $customerProblems.Keys) {
        $p = $customerProblems[$cid]
        $list = @($p.Devices | Sort-Object)
        $more = ''; if ($list.Count -gt 10) { $more = " and $($list.Count - 10) more" }
        $why = "No IT Glue organization named '$($p.Name)'."
        if ($p.Count -gt 1) { $why = "$($p.Count) IT Glue organizations are named '$($p.Name)', so it's not clear which one." }
        Add-Failure 'CustomerNotInITGlue' "customer:$cid" $p.Name "$($list.Count) device(s) not synced" "$why Devices: $(($list | Select-Object -First 10) -join ', ')$more. Fix the name in N-central or IT Glue, or add it to CustomerNameMap."
    }
    foreach ($sk in $siteProblems.Keys) {
        $p = $siteProblems[$sk]
        $list = @($p.Devices | Sort-Object)
        $more = ''; if ($list.Count -gt 10) { $more = " and $($list.Count - 10) more" }
        Add-Failure 'SiteNotInITGlue' "site:$sk" $p.Customer "Site '$($p.Site)': $($list.Count) device(s) not synced" "$($p.Why) Devices: $(($list | Select-Object -First 10) -join ', ')$more." $p.OrgUrl
    }
    Write-Log ("Devices: {0} in N-central, {1} to sync; skipped {2} probes, {3} excluded, {4} with an unmapped device class, {5} not seen for {6}+ days. Not synced: {7} customer mismatch, {8} site mismatch." -f $stats.ncDevices, $stats.considered, $stats.skippedProbe, $stats.skippedExcluded, $stats.skippedClass, $stats.skippedStale, $staleDays, $stats.customerMismatch, $stats.siteMismatch)

    # ---------- 4. Hardware details (cached) ----------
    $assetFetches = 0
    $maxFetch = [int]$Cfg.NCentral.MaxAssetLookupsPerRun
    $refreshH = [double]$Cfg.NCentral.AssetRefreshHours
    $liveIds = @{}; foreach ($d in $ncDevices) { $liveIds[[string]$d.deviceId] = $true }
    foreach ($k in @($Sync.assets.Keys)) { if (-not $liveIds.ContainsKey($k)) { $Sync.assets.Remove($k) } }
    if ($Cfg.NCentral.AssetDetails) {
        # New (unlinked) devices first: they need a serial number before they can be matched.
        $order = @($candidates | Sort-Object @{ Expression = { if ($Sync.links.ContainsKey($_.Id)) { 1 } else { 0 } } }, @{ Expression = { $_.Id } })
        foreach ($c in $order) {
            if ($Limited -and $DeviceId -notcontains $c.Id) { continue }
            $cached = $Sync.assets[$c.Id]
            $fresh = $false
            if ($cached -is [hashtable] -and -not $RefreshAssets) { $t = ConvertFrom-Utc $cached.fetchedUtc; if ($t -and ([DateTime]::UtcNow - $t).TotalHours -lt $refreshH) { $fresh = $true } }
            if ($fresh) { continue }
            if ($assetFetches -ge $maxFetch) { break }
            $assetFetches++
            try { $Sync.assets[$c.Id] = Get-AssetDetails -Id $c.Id }
            catch { Write-Log "Couldn't read hardware details for N-central device $($c.Id) ($($c.Name)): $($_.Exception.Message)" 'WARN' }
            Start-Sleep -Milliseconds 100
        }
        Write-Log "Hardware details fetched for $assetFetches device(s) this run (cache keeps them $refreshH h; at most $maxFetch per run)."
    }

    # ---------- 5. Duplicate serial numbers inside N-central: newest check-in wins ----------
    $bySerial = @{}
    foreach ($c in $candidates) {
        $a = $Sync.assets[$c.Id]
        $sk = ''; if ($a -is [hashtable]) { $sk = Get-SerialKey ([string]$a.serial) }
        if ($sk.Length -lt 4 -or $ignoreSerial.ContainsKey($sk)) { $sk = '' }
        $c.Serial = ''; if ($sk) { $c.Serial = ([string]$a.serial).Trim() }
        $c.SerialKey = $sk
        if ($sk) { if (-not $bySerial.ContainsKey($sk)) { $bySerial[$sk] = New-Object System.Collections.ArrayList }; $null = $bySerial[$sk].Add($c) }
    }
    $dupLosers = @{}
    foreach ($sk in $bySerial.Keys) {
        $g = @($bySerial[$sk])
        if ($g.Count -lt 2) { continue }
        $sorted = @($g | Sort-Object @{ Expression = { $t = ConvertFrom-Utc $_.LastSeen; if ($t) { $t } else { [DateTime]::MinValue } }; Descending = $true })
        foreach ($l in ($sorted | Select-Object -Skip 1)) {
            $dupLosers[$l.Id] = $true
            Add-Failure 'DeviceConflict' "ncdup:$($l.Id)" $l.CustName $l.Name "Same serial number ($($l.Serial)) as N-central device '$($sorted[0].Name)' (id $($sorted[0].Id)), which checked in more recently and is synced instead. Remove the old device from N-central."
        }
    }

    # ---------- 5b. Duplicate device names in one IT Glue organization: newest check-in wins ----------
    $byName = @{}
    foreach ($c in $candidates) {
        if ($dupLosers.ContainsKey($c.Id)) { continue }
        $k = "$($c.OrgId)|$(Get-NameKey $c.Name)"
        if (-not $byName.ContainsKey($k)) { $byName[$k] = New-Object System.Collections.ArrayList }
        $null = $byName[$k].Add($c)
    }
    foreach ($k in $byName.Keys) {
        $g = @($byName[$k])
        if ($g.Count -lt 2) { continue }
        $sorted = @($g | Sort-Object @{ Expression = { $t = ConvertFrom-Utc $_.LastSeen; if ($t) { $t } else { [DateTime]::MinValue } }; Descending = $true })
        foreach ($l in ($sorted | Select-Object -Skip 1)) {
            $dupLosers[$l.Id] = $true
            Add-Failure 'DeviceConflict' "ncdupname:$($l.Id)" $l.CustName $l.Name "Same name as N-central device id $($sorted[0].Id) in the same customer, which checked in more recently and is synced instead. Remove the old device from N-central or rename one."
        }
    }

    # ---------- 6. Match each device to an IT Glue configuration and plan changes ----------
    $plan = New-Object System.Collections.ArrayList
    $claimed = @{}   # IT Glue configuration id -> N-central id, within this run
    # Plans the create or update for one device, once its IT Glue configuration ($conf, or $null for
    # a new one) is known. $how = linked | approved | serial | name | ai.
    $planDevice = {
        param($c, $conf, [string]$how)
        $a = $Sync.assets[$c.Id]; if ($a -isnot [hashtable]) { $a = @{} }
        $link = $Sync.links[$c.Id]
        # Desired values. Blank values never clear IT Glue.
        $want = [ordered]@{}
        $want['name'] = $c.Name
        $want['hostname'] = $(if ($c.Hostname) { $c.Hostname } else { $c.Name })
        $want['serial-number'] = $c.Serial
        $want['configuration-type-id'] = $typeIds[(Get-NameKey $c.Type)]
        $want['location-id'] = $c.LocId
        $os = [string]$a.os; if (-not $os) { $os = $c.OsFallback }
        $want['operating-system-notes'] = $os
        $want['mac-address'] = [string]$a.mac
        $want['primary-ip'] = [string]$a.ip
        $mid = $null; if ($a.manufacturer) { $mid = $mfrIds[(Get-NameKey ([string]$a.manufacturer))] }
        $want['manufacturer-id'] = $mid
        $want['model-id'] = $(if ($mid -and $a.model) { $modelIds["$mid|$(Get-NameKey ([string]$a.model))"] } else { $null })

        $fieldFor = @{ 'name' = 'name'; 'hostname' = 'hostname'; 'serial-number' = 'serial-number'; 'configuration-type-id' = 'configuration-type'; 'location-id' = 'location'; 'operating-system-notes' = 'operating-system-notes'; 'mac-address' = 'mac-address'; 'primary-ip' = 'primary-ip'; 'manufacturer-id' = 'manufacturer'; 'model-id' = 'model' }
        if (-not $conf) {
            # Never create a duplicate: no non-archived configuration (linked to another device or not)
            # may already have this serial number anywhere, or this name/hostname in this organization.
            $dupWhy = @()
            if ($c.SerialKey -and $anyBySerial.ContainsKey($c.SerialKey)) {
                foreach ($x in $anyBySerial[$c.SerialKey]) { $dupWhy += "serial $($c.Serial) is on '$(Get-Attr $x 'name')' (id $($x.id), $(Get-Attr $x 'organization-name'))" }
            }
            foreach ($n in @(@($c.Name, $want['hostname']) | Where-Object { $_ } | ForEach-Object { Get-NameKey $_ } | Select-Object -Unique)) {
                if ($anyByOrgName.ContainsKey("$($c.OrgId)|$n")) {
                    foreach ($x in $anyByOrgName["$($c.OrgId)|$n"]) { $dupWhy += "name '$n' is on id $($x.id) with serial '$(Get-Attr $x 'serial-number')'" }
                }
            }
            if ($dupWhy.Count -gt 0) {
                $stats.conflicts++
                Add-Failure 'DeviceConflict' "wouldduplicate:$($c.Id)" $c.CustName $c.Name "Not created, it would be a duplicate: $((@($dupWhy | Select-Object -Unique)) -join '; '). Fix the serial/name, or merge or archive the existing one in IT Glue." (Get-Attr $c.Org 'resource-url')
                return
            }
            $attrs = @{ 'organization-id' = [int64]$c.OrgId; 'configuration-status-id' = [int64]$newStatusId }
            foreach ($f in $want.Keys) { if ($want[$f]) { if ($f -like '*-id') { $attrs[$f] = [int64]$want[$f] } else { $attrs[$f] = [string]$want[$f] } } }
            $stats.toCreate++
            $null = $plan.Add([ordered]@{ action = 'create'; ncId = $c.Id; device = $c.Name; customer = $c.CustName; orgId = $c.OrgId; itgId = $null; match = ''; attributes = $attrs; changes = @() })
            return
        }
        $attrs = @{}; $changes = @()
        foreach ($f in $want.Keys) {
            if (-not $want[$f]) { continue }
            if ($Cfg.Sync.UpdateFields -notcontains $fieldFor[$f]) { continue }
            $have = Get-Attr $conf $f
            $same = $false
            if ($f -like '*-id') { $same = ($have -eq [string]$want[$f]) }
            elseif ($f -eq 'serial-number') { $same = ((Get-SerialKey $have) -eq (Get-SerialKey $want[$f])) }
            elseif ($f -in @('hostname', 'mac-address')) { $same = ($have.Trim() -ieq ([string]$want[$f]).Trim()) }
            else { $same = ($have.Trim() -ceq ([string]$want[$f]).Trim()) }
            if (-not $same) {
                if ($f -like '*-id') { $attrs[$f] = [int64]$want[$f] } else { $attrs[$f] = [string]$want[$f] }
                $changes += "$($fieldFor[$f]): '$have' -> '$($want[$f])'"
            }
        }
        # Never rename or re-serial a configuration into a duplicate of another one.
        $dupWhy = @()
        foreach ($f in 'name', 'hostname') {
            if (-not $attrs.ContainsKey($f)) { continue }
            $others = @(); $nk = "$($c.OrgId)|$(Get-NameKey ([string]$attrs[$f]))"
            if ($anyByOrgName.ContainsKey($nk)) { $others = @($anyByOrgName[$nk] | Where-Object { [string]$_.id -ne [string]$conf.id }) }
            if ($others.Count -gt 0) { $dupWhy += "$f '$($attrs[$f])' is already on id $((@($others | ForEach-Object { $_.id })) -join ', ')"; $attrs.Remove($f); $changes = @($changes | Where-Object { -not $_.StartsWith("${f}:") }) }
        }
        if ($attrs.ContainsKey('serial-number')) {
            $others = @(); $sk = Get-SerialKey ([string]$attrs['serial-number'])
            if ($anyBySerial.ContainsKey($sk)) { $others = @($anyBySerial[$sk] | Where-Object { [string]$_.id -ne [string]$conf.id }) }
            if ($others.Count -gt 0) { $dupWhy += "serial $($attrs['serial-number']) is already on id $((@($others | ForEach-Object { $_.id })) -join ', ')"; $attrs.Remove('serial-number'); $changes = @($changes | Where-Object { -not $_.StartsWith('serial-number:') }) }
        }
        if ($dupWhy.Count -gt 0) {
            Add-Failure 'DeviceConflict' "wouldduplicate:$($c.Id)" $c.CustName $c.Name "Not changed, it would make a duplicate: $($dupWhy -join '; ')." (Get-Attr $conf 'resource-url')
        }
        if ($changes.Count -eq 0) {
            $stats.inSync++
            # A link the local AI model suggested is only saved by an -Apply run.
            if (($link -isnot [hashtable] -or [string]$link.itg -ne [string]$conf.id) -and ($how -ne 'ai' -or $Apply)) { $Sync.links[$c.Id] = @{ itg = [string]$conf.id; org = $c.OrgId; linkedUtc = Get-UtcText; how = $how } }
            elseif ($link.diffHash) { $link.diffHash = $null; $link.sends = 0 }
            return
        }
        # A change IT Glue keeps ignoring (e.g. a field locked by another integration) isn't resent forever.
        $diffHash = Get-TextHash (($changes | Sort-Object) -join ';')
        if ($link -is [hashtable] -and [string]$link.itg -eq [string]$conf.id -and $link.diffHash -eq $diffHash -and [int]$link.sends -ge [int]$Cfg.Sync.MaxRetries) {
            $stats.conflicts++
            Add-Failure 'DeviceConflict' "stuck:$($c.Id)" $c.CustName $c.Name "IT Glue still differs after $($link.sends) updates: $($changes -join '; '). Another integration may own these fields." (Get-Attr $conf 'resource-url')
            return
        }
        $stats.toUpdate++
        $null = $plan.Add([ordered]@{ action = 'update'; ncId = $c.Id; device = $c.Name; customer = $c.CustName; orgId = $c.OrgId; itgId = [string]$conf.id; url = (Get-Attr $conf 'resource-url'); match = $how; attributes = $attrs; changes = $changes; diffHash = $diffHash })
    }
    $aiQueue = New-Object System.Collections.ArrayList
    # LocalModel.ApprovedMatches: { "N-central device id": "IT Glue configuration id" } that a person confirmed.
    $approvedMap = @{}; foreach ($k in $Lm.ApprovedMatches.Keys) { if (-not ([string]$k).StartsWith('_')) { $approvedMap[([string]$k).Trim()] = ([string]$Lm.ApprovedMatches[$k]).Trim() } }
    # LocalModel.RejectedMatches: { "N-central device id": "IT Glue id" or ["id", ...] } that a person said are NOT that device.
    $rejectedMap = @{}; foreach ($k in $Lm.RejectedMatches.Keys) { if (-not ([string]$k).StartsWith('_')) { $rejectedMap[([string]$k).Trim()] = @(@($Lm.RejectedMatches[$k]) | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim() }) } }
    foreach ($c in $candidates) {
        if ($dupLosers.ContainsKey($c.Id)) { $stats.conflicts++; continue }
        $a = $Sync.assets[$c.Id]; if ($a -isnot [hashtable]) { $a = @{} }
        $link = $Sync.links[$c.Id]
        $conf = $null; $how = ''
        # a) The configuration it was linked to before.
        if ($link -is [hashtable] -and $link.itg -and $confById.ContainsKey([string]$link.itg)) { $conf = $confById[[string]$link.itg]; $how = 'linked' }
        # a2) A match a person approved (LocalModel.ApprovedMatches).
        if (-not $conf -and $approvedMap.ContainsKey($c.Id)) {
            $aid = $approvedMap[$c.Id]
            if (-not $confById.ContainsKey($aid)) {
                Add-Failure 'AiReview' "approved:$($c.Id)" $c.CustName $c.Name "LocalModel.ApprovedMatches links this device to IT Glue configuration $aid, which doesn't exist or is archived. Fix or remove that entry."
            } elseif ($linkedConf.ContainsKey($aid) -and $linkedConf[$aid] -ne $c.Id -and $liveIds.ContainsKey([string]$linkedConf[$aid])) {
                Add-Failure 'AiReview' "approved:$($c.Id)" $c.CustName $c.Name "LocalModel.ApprovedMatches links this device to IT Glue configuration $aid, but that one is already linked to N-central device $($linkedConf[$aid]). Fix or remove that entry." (Get-Attr $confById[$aid] 'resource-url')
            } else { $conf = $confById[$aid]; $how = 'approved' }
        }
        # b) Same serial number.
        if (-not $conf -and $c.SerialKey -and $confsBySerial.ContainsKey($c.SerialKey)) {
            $all = @($confsBySerial[$c.SerialKey] | Where-Object { -not $linkedConf.ContainsKey([string]$_.id) -or $linkedConf[[string]$_.id] -eq $c.Id })
            $inOrg = @($all | Where-Object { (Get-Attr $_ 'organization-id') -eq $c.OrgId })
            if ($inOrg.Count -eq 1) { $conf = $inOrg[0]; $how = 'serial' }
            elseif ($inOrg.Count -gt 1) {
                $stats.conflicts++
                Add-Failure 'DeviceConflict' "multi:$($c.Id)" $c.CustName $c.Name "$($inOrg.Count) IT Glue configurations in '$(Get-Attr $c.Org 'name')' have serial number $($c.Serial) (ids $((@($inOrg | ForEach-Object { $_.id })) -join ', ')). Archive the extra ones in IT Glue." (Get-Attr $inOrg[0] 'resource-url')
                continue
            } elseif ($all.Count -gt 0) {
                $other = $all[0]
                $stats.conflicts++
                Add-Failure 'DeviceConflict' "othercust:$($c.Id)" $c.CustName $c.Name "Serial number $($c.Serial) is already on IT Glue configuration '$(Get-Attr $other 'name')' under a different organization ('$(Get-Attr $other 'organization-name')'). Not moved automatically: move or archive it in IT Glue, or move the device in N-central." (Get-Attr $other 'resource-url')
                continue
            }
        }
        # c) Same name/hostname in the same organization, when the serial numbers don't disagree.
        if (-not $conf -and $Cfg.Sync.MatchByName) {
            $nm = @()
            foreach ($n in @(@($c.Name, $c.Hostname) | Where-Object { $_ } | ForEach-Object { Get-NameKey $_ } | Select-Object -Unique)) {
                if ($confsByOrgName.ContainsKey("$($c.OrgId)|$n")) { $nm += @($confsByOrgName["$($c.OrgId)|$n"]) }
            }
            $nm = @($nm | Sort-Object id -Unique | Where-Object {
                    (-not $linkedConf.ContainsKey([string]$_.id) -or $linkedConf[[string]$_.id] -eq $c.Id) -and
                    (-not $c.SerialKey -or -not (Get-SerialKey (Get-Attr $_ 'serial-number')) -or (Get-SerialKey (Get-Attr $_ 'serial-number')) -eq $c.SerialKey) })
            if ($nm.Count -eq 1) { $conf = $nm[0]; $how = 'name' }
            elseif ($nm.Count -gt 1) {
                $stats.conflicts++
                Add-Failure 'DeviceConflict' "multiname:$($c.Id)" $c.CustName $c.Name "$($nm.Count) IT Glue configurations in '$(Get-Attr $c.Org 'name')' are named '$($c.Name)' (ids $((@($nm | ForEach-Object { $_.id })) -join ', ')). Archive the extra ones or give them serial numbers." (Get-Attr $c.Org 'resource-url')
                continue
            }
        }
        if ($conf -and $claimed.ContainsKey([string]$conf.id)) {
            $stats.conflicts++
            Add-Failure 'DeviceConflict' "claimed:$($c.Id)" $c.CustName $c.Name "Matches IT Glue configuration $($conf.id), which also matches N-central device $($claimed[[string]$conf.id]). Neither is changed until one is fixed." (Get-Attr $conf 'resource-url')
            continue
        }
        if ($conf -and (Get-Attr $conf 'organization-id') -ne $c.OrgId) {
            # Linked before, but the device has since moved to another customer in N-central.
            $stats.conflicts++
            Add-Failure 'DeviceConflict' "moved:$($c.Id)" $c.CustName $c.Name "Its IT Glue configuration is under '$(Get-Attr $conf 'organization-name')', but in N-central the device is now under '$($c.CustName)'. Not moved automatically: move it in IT Glue." (Get-Attr $conf 'resource-url')
            continue
        }
        if ($conf) { $claimed[[string]$conf.id] = $c.Id }

        # New devices wait for their serial number, so a duplicate isn't created.
        if (-not $conf -and $Cfg.NCentral.AssetDetails -and -not $a.fetchedUtc) { $stats.waitingForDetails++; $orgsHeld[$c.OrgId] = $true; continue }

        # No serial/name match: the local AI model gets a look first, after every exact match is known.
        if (-not $conf -and $script:AiReady -and -not $script:AiDown -and (-not $Limited -or $DeviceId -contains $c.Id)) { $null = $aiQueue.Add($c); continue }
        $null = & $planDevice $c $conf $how
    }


    # ---------- 6b. Optional: ask the local AI model about devices with no serial/name match ----------
    # One device at a time, with a short list of non-archived IT Glue configurations at the same
    # customer that aren't already taken. The script checks the answer and decides.
    $aiDecisions = New-Object System.Collections.ArrayList
    $aiSuggested = @{}   # IT Glue configuration ids held for a person to check this run
    foreach ($c in @($aiQueue | Sort-Object @{ Expression = { [string]$_.Id } })) {
        $a = $Sync.assets[$c.Id]; if ($a -isnot [hashtable]) { $a = @{} }
        $macKey = Get-MacKey ([string]$a.mac)
        $rej = @(); if ($rejectedMap.ContainsKey($c.Id)) { $rej = @($rejectedMap[$c.Id]) }
        $scored = New-Object System.Collections.ArrayList
        $pool = @(); if ($confsByOrg.ContainsKey($c.OrgId)) { $pool = @($confsByOrg[$c.OrgId]) }
        foreach ($x in $pool) {
            $xid = [string]$x.id
            if ($claimed.ContainsKey($xid) -or $rej -contains $xid) { continue }
            # Taken by another device that is still in N-central. (A link to a device that is gone
            # stays a candidate: that is often the same computer with a reinstalled agent.)
            if ($linkedConf.ContainsKey($xid) -and $linkedConf[$xid] -ne $c.Id -and $liveIds.ContainsKey([string]$linkedConf[$xid])) { continue }
            $xs = Get-SerialKey (Get-Attr $x 'serial-number'); if ($ignoreSerial.ContainsKey($xs)) { $xs = '' }
            if ($c.SerialKey -and $xs -and $xs -ne $c.SerialKey) { continue }   # different serial = different device
            $sim = 0.0
            foreach ($dn in @(@($c.Name, $c.Hostname) | Where-Object { $_ })) {
                foreach ($cn in @(@((Get-Attr $x 'name'), (Get-Attr $x 'hostname')) | Where-Object { $_ })) { $sv = Get-NameSimilarity $dn $cn; if ($sv -gt $sim) { $sim = $sv } }
            }
            $mm = [bool]($macKey -and (Get-MacKey (Get-Attr $x 'mac-address')) -eq $macKey)
            $null = $scored.Add(@{ Conf = $x; Sim = $sim; Mac = $mm; Score = ($sim + $(if ($mm) { 1 } else { 0 })) })
        }
        $top = @($scored | Sort-Object @{ Expression = { $_.Score }; Descending = $true }, @{ Expression = { [int64]$_.Conf.id } } | Select-Object -First ([math]::Max(1, [int]$Lm.MaxCandidates)))
        if ($top.Count -eq 0 -or ($top[0].Sim -lt [double]$Lm.MinNameSimilarity -and -not $top[0].Mac)) {
            # Nothing looks remotely like it: a new device. Not worth a question.
            $stats.aiNotAsked++
            $null = & $planDevice $c $null ''
            continue
        }
        $dev = [ordered]@{ name = $c.Name }
        foreach ($p in @(@('hostname', $c.Hostname), @('serial', $c.Serial), @('manufacturer', $a.manufacturer), @('model', $a.model), @('os', $(if ($a.os) { $a.os } else { $c.OsFallback })), @('mac', $a.mac), @('n_central_class', $c.Class), @('it_glue_type', $c.Type), @('site', (Get-Attr $c.Loc 'name')))) {
            $v = Get-ShortText $p[1] 80; if ($v) { $dev[$p[0]] = $v }
        }
        $cl = @($top | ForEach-Object { Get-ConfFacts $_.Conf })
        $prompt = "N-central device:`n$(ConvertTo-Json -InputObject $dev -Depth 3 -Compress)`n`nIT Glue configurations at the same customer ($(Get-Attr $c.Org 'name')), archived ones left out:`n$(ConvertTo-Json -InputObject $cl -Depth 3 -Compress)"
        $ids = @($top | ForEach-Object { [string]$_.Conf.id })
        $validate = {
            param($o, $ids)
            if (-not $o.PSObject.Properties['match_id'] -or -not $o.PSObject.Properties['confidence']) { throw 'match_id or confidence is missing' }
            $mid = ([string]$o.match_id).Trim()
            if (@('none', 'null', '0', 'n/a') -contains $mid.ToLowerInvariant()) { $mid = '' }
            if ($mid -and $ids -notcontains $mid) { throw "match_id '$mid' is not one of the candidates" }
            $cf = ConvertTo-Confidence $o.confidence
            if (-not $mid) { $cf = 0 }
            return @{ match_id = $mid; confidence = $cf; reason = (Get-ShortText $o.reason 300) }
        }
        $r = Get-AiAnswer -Kind 'match' -Subject "N-central $($c.Id) $($c.Name)" -System $AiMatchSystem -Prompt $prompt -Schema $AiMatchSchema -Validate $validate -Context $ids
        if ($r.status -eq 'deferred') {
            # Not created this run, so a duplicate can't slip in; asked on the next run.
            $stats.aiDeferred++; $orgsHeld[$c.OrgId] = $true
            continue
        }
        if ($r.status -eq 'error') {
            $stats.aiErrors++; $orgsHeld[$c.OrgId] = $true
            Write-Log "Local AI couldn't check $($c.CustName) | $($c.Name), so it is matched without it: $($r.why)" 'WARN'
            $null = & $planDevice $c $null ''
            continue
        }
        if ($r.cached) { $stats.aiCached++ } else { $stats.aiAsked++ }
        $ans = $r.answer
        $mid = [string]$ans.match_id; $cf = [int]$ans.confidence
        $pick = $null
        if ($mid) { foreach ($t in $top) { if ([string]$t.Conf.id -eq $mid) { $pick = $t.Conf } } }
        if ($pick -and $claimed.ContainsKey($mid)) { $pick = $null }   # taken by another device meanwhile
        $action = 'none'
        if ($pick -and $Lm.AutoLink -eq $true -and $cf -ge [int]$Lm.AutoLinkConfidence) {
            $action = 'link'; $stats.aiLinked++
            Write-Log "Local AI: $($c.CustName) | $($c.Name) is IT Glue '$(Get-Attr $pick 'name')' (id $mid), confidence $cf. $($ans.reason)"
            $claimed[$mid] = $c.Id
            $null = & $planDevice $c $pick 'ai'
        } elseif ($pick -and $cf -ge [int]$Lm.ReviewConfidence) {
            $action = 'review'; $stats.aiReview++; $aiSuggested[$mid] = $true; $orgsHeld[$c.OrgId] = $true
            Add-Failure 'AiReview' "aimatch:$($c.Id)" $c.CustName $c.Name ("Not created or linked: possibly the same device as IT Glue configuration '{0}' (id {1}), confidence {2}. {3} To accept, add `"{4}`": `"{1}`" to LocalModel.ApprovedMatches in the config. If it's a different device, add the same line to LocalModel.RejectedMatches." -f (Get-Attr $pick 'name'), $mid, $cf, $ans.reason, $c.Id) (Get-Attr $pick 'resource-url')
        } else {
            $stats.aiNoMatch++
            $null = & $planDevice $c $null ''
        }
        $d = [ordered]@{ kind = 'match'; action = $action; ncId = $c.Id; device = $c.Name; customer = $c.CustName; itgId = $mid; itgName = $(if ($pick) { Get-Attr $pick 'name' } else { '' }); confidence = $cf; reason = [string]$ans.reason; cached = [bool]$r.cached }
        $null = $aiDecisions.Add($d)
        Write-AiAudit @{ type = 'decision'; kind = 'match'; action = $action; ncId = $c.Id; device = $c.Name; customer = $c.CustName; itgId = $mid; confidence = $cf; reason = [string]$ans.reason; cached = [bool]$r.cached; key = $r.key; apply = [bool]$Apply }
    }

    # ---------- 6c. Optional: IT Glue configurations the local AI model thinks are retired ----------
    # Only for customers whose devices were all matched this run, only for configuration types
    # this sync manages, and only records no N-central device is linked to or named like. The
    # model only suggests; nothing is archived by this script.
    if ($script:AiReady -and -not $script:AiDown -and $Lm.SuggestArchive -eq $true -and -not $Limited) {
        $deviceTypeIds = @{}; foreach ($m in $classMap) { $deviceTypeIds[[string]$typeIds[(Get-NameKey $m.Type)]] = $true }
        $ncByOrg = @{}
        foreach ($c in $candidates) { if (-not $ncByOrg.ContainsKey($c.OrgId)) { $ncByOrg[$c.OrgId] = New-Object System.Collections.ArrayList }; $null = $ncByOrg[$c.OrgId].Add($c) }
        $month = (Get-Date).ToString('yyyy-MM')
        foreach ($oid in @($ncByOrg.Keys | Sort-Object)) {
            if ($orgsHeld.ContainsKey($oid) -or -not $confsByOrg.ContainsKey($oid)) { continue }
            $ncNames = @{}
            foreach ($c in $ncByOrg[$oid]) { foreach ($n in @(@($c.Name, $c.Hostname) | Where-Object { $_ })) { $ncNames[(Get-NameKey $n)] = $true } }
            foreach ($x in @($confsByOrg[$oid])) {
                $xid = [string]$x.id
                if (-not $deviceTypeIds.ContainsKey((Get-Attr $x 'configuration-type-id'))) { continue }
                if ($claimed.ContainsKey($xid) -or $linkedConf.ContainsKey($xid) -or $aiSuggested.ContainsKey($xid) -or $Lm.KeepConfigurationIds -contains $xid) { continue }
                $xh = Get-Attr $x 'hostname'
                if ($ncNames.ContainsKey((Get-NameKey (Get-Attr $x 'name'))) -or ($xh -and $ncNames.ContainsKey((Get-NameKey $xh)))) { continue }
                $near = @($ncByOrg[$oid] | ForEach-Object {
                        $c = $_; $sim = 0.0
                        foreach ($dn in @(@($c.Name, $c.Hostname) | Where-Object { $_ })) { foreach ($cn in @(@((Get-Attr $x 'name'), $xh) | Where-Object { $_ })) { $sv = Get-NameSimilarity $dn $cn; if ($sv -gt $sim) { $sim = $sv } } }
                        @{ Sim = $sim; C = $c }
                    } | Sort-Object @{ Expression = { $_.Sim }; Descending = $true }, @{ Expression = { [string]$_.C.Name } } | Select-Object -First 10 | ForEach-Object {
                        $f = [ordered]@{ name = $_.C.Name; type = $_.C.Type }
                        if ($_.C.Serial) { $f['serial'] = $_.C.Serial }
                        $f
                    })
                $prompt = "Current month: $month`nCustomer: $(Get-Attr $x 'organization-name') ($($ncByOrg[$oid].Count) computers/servers in N-central)`n`nIT Glue configuration not linked to any N-central device:`n$(ConvertTo-Json -InputObject (Get-ConfFacts $x) -Depth 3 -Compress)`n`nN-central devices at this customer with the most similar names:`n$(ConvertTo-Json -InputObject $near -Depth 3 -Compress)"
                $validate = {
                    param($o, $unused)
                    if (-not $o.PSObject.Properties['archive'] -or -not $o.PSObject.Properties['confidence']) { throw 'archive or confidence is missing' }
                    $arch = $null
                    if ($o.archive -is [bool]) { $arch = $o.archive } elseif (@('true', 'yes') -contains ([string]$o.archive).ToLowerInvariant()) { $arch = $true } elseif (@('false', 'no') -contains ([string]$o.archive).ToLowerInvariant()) { $arch = $false }
                    if ($null -eq $arch) { throw "archive '$($o.archive)' is not true or false" }
                    return @{ archive = $arch; confidence = (ConvertTo-Confidence $o.confidence); reason = (Get-ShortText $o.reason 300) }
                }
                $r = Get-AiAnswer -Kind 'archive' -Subject "IT Glue $xid $(Get-Attr $x 'name')" -System $AiArchiveSystem -Prompt $prompt -Schema $AiArchiveSchema -Validate $validate -Context $null
                if ($r.status -eq 'deferred') { $stats.aiDeferred++; continue }
                if ($r.status -ne 'ok') { $stats.aiErrors++; continue }
                if ($r.cached) { $stats.aiCached++ } else { $stats.aiAsked++ }
                $ans = $r.answer
                $suggest = ($ans.archive -eq $true -and [int]$ans.confidence -ge [int]$Lm.ReviewConfidence)
                if ($suggest) {
                    $stats.aiArchive++
                    Add-Failure 'AiArchive' "aiarchive:$xid" (Get-Attr $x 'organization-name') (Get-Attr $x 'name') ("Consider archiving (confidence {0}). {1} No N-central device is linked to it. Archive it in IT Glue if it's retired, or add {2} to LocalModel.KeepConfigurationIds to stop this suggestion." -f $ans.confidence, $ans.reason, $xid) (Get-Attr $x 'resource-url')
                }
                $null = $aiDecisions.Add([ordered]@{ kind = 'archive'; action = $(if ($suggest) { 'suggest-archive' } else { 'keep' }); itgId = $xid; itgName = (Get-Attr $x 'name'); customer = (Get-Attr $x 'organization-name'); confidence = [int]$ans.confidence; reason = [string]$ans.reason; cached = [bool]$r.cached })
                if (-not $r.cached) { Write-AiAudit @{ type = 'decision'; kind = 'archive'; action = $(if ($suggest) { 'suggest-archive' } else { 'keep' }); itgId = $xid; name = (Get-Attr $x 'name'); customer = (Get-Attr $x 'organization-name'); confidence = [int]$ans.confidence; reason = [string]$ans.reason; key = $r.key } }
            }
        }
    }
    if ($UseAI) {
        if ($script:AiDown) {
            Write-Log "Local AI model not used (or stopped): $($script:AiDown)" 'WARN'
            Add-Failure 'AiReview' 'ai:unavailable' '(all)' 'Local AI model not available' "$($script:AiDown) Devices were matched the usual way (serial number and name only) this run."
        }
        # Forget cached answers to questions that weren't asked this run (the facts changed).
        if ($script:AiReady -and -not $script:AiDown -and -not $Limited) { foreach ($k in @($Sync.ai.Keys)) { if (-not $script:AiUsedKeys.ContainsKey($k)) { $Sync.ai.Remove($k) } } }
        Write-Log ("Local AI: {0} asked, {1} answers reused, {2} linked, {3} held for review, {4} no match, {5} not asked (no similar names), {6} archive suggestions, {7} left for the next run, {8} errors." -f $stats.aiAsked, $stats.aiCached, $stats.aiLinked, $stats.aiReview, $stats.aiNoMatch, $stats.aiNotAsked, $stats.aiArchive, $stats.aiDeferred, $stats.aiErrors)
    }

    # ---------- 7. Devices synced before that are no longer in N-central ----------
    $retire = New-Object System.Collections.ArrayList
    if (-not $Limited) {
        foreach ($nid in @($Sync.links.Keys)) {
            if ($liveIds.ContainsKey($nid)) { continue }
            $lk = $Sync.links[$nid]
            if ($lk -isnot [hashtable] -or -not $confById.ContainsKey([string]$lk.itg)) { $Sync.links.Remove($nid); continue }   # archived or deleted in IT Glue: forget the link (archived records are ignored)
            $conf = $confById[[string]$lk.itg]
            if ($claimed.ContainsKey([string]$lk.itg)) { continue }   # now matched to a live device (e.g. agent reinstalled, new N-central id)
            if ($lk.retiredUtc -and (Get-Attr $conf 'configuration-status-id') -eq [string]$retiredStatusId) { continue }
            $stats.removed++
            if ($retiredStatusId) {
                if ((Get-Attr $conf 'configuration-status-id') -ne [string]$retiredStatusId) { $null = $retire.Add(@{ ncId = $nid; conf = $conf }) }
            } else {
                Add-Failure 'RemovedFromNCentral' "gone:$nid" (Get-Attr $conf 'organization-name') (Get-Attr $conf 'name') "N-central device $nid is gone. Its IT Glue configuration was left as it is: archive it in IT Glue if the device is retired." (Get-Attr $conf 'resource-url')
            }
        }
    }
    $retireMax = [int]$Cfg.Sync.MaxRetiresPerRun; if ($RetireLimit -ge 0) { $retireMax = $RetireLimit }
    $retireBlocked = $retire.Count -gt $retireMax
    if ($retireBlocked) {
        foreach ($r in $retire) { Add-Failure 'RemovedFromNCentral' "gone:$($r.ncId)" (Get-Attr $r.conf 'organization-name') (Get-Attr $r.conf 'name') "N-central device $($r.ncId) is gone. Not changed: $($retire.Count) devices would be set to '$($Cfg.Sync.RetiredStatus)', more than Sync.MaxRetiresPerRun ($retireMax). Check, then run once with -RetireLimit $($retire.Count)." (Get-Attr $r.conf 'resource-url') }
    }

    # ---------- 8. Preview ----------
    $limit = [int]$Cfg.Sync.MaxChangesPerRun; if ($ChangeLimit -ge 0) { $limit = $ChangeLimit }
    $work = @($plan | Where-Object { -not $Limited -or $DeviceId -contains $_.ncId } | Sort-Object @{ Expression = { if ($_.action -eq 'create') { 0 } else { 1 } } }, @{ Expression = { $_.customer } }, @{ Expression = { $_.device } })
    $blocked = ($Cfg.Sync.BlockAllOnMismatch -and ($stats.customerMismatch + $stats.siteMismatch) -gt 0)
    try {
        Save-JsonFile -Path $PreviewPath -Depth 6 -Obj ([ordered]@{
                generatedUtc = Get-UtcText; mode = $mode; stats = $stats; changeLimit = $limit; blockedByMismatch = $blocked
                creates = @($work | Where-Object { $_.action -eq 'create' }); updates = @($work | Where-Object { $_.action -eq 'update' })
                retire = @($retire | ForEach-Object { @{ ncId = $_.ncId; itgId = $_.conf.id; name = (Get-Attr $_.conf 'name'); organization = (Get-Attr $_.conf 'organization-name') } })
                retireBlocked = $retireBlocked
                localModel = [ordered]@{ enabled = $UseAI; model = [string]$Lm.Model; available = [bool]($script:AiReady -and -not $script:AiDown); problem = $script:AiDown; decisions = @($aiDecisions) }
            })
    } catch { Write-Log "Couldn't write $PreviewPath : $($_.Exception.Message)" 'WARN' }
    Write-Log ("Plan: {0} to create, {1} to update, {2} already match, {3} new devices waiting for hardware details, {4} conflicts, {5} removed from N-central, {6} held for a local AI check or review. Details: {7}" -f $stats.toCreate, $stats.toUpdate, $stats.inSync, $stats.waitingForDetails, $stats.conflicts, $stats.removed, ($stats.aiReview + $stats.aiDeferred), $PreviewPath)

    # ---------- 9. Apply ----------
    $writeFailures = 0
    if (-not $Apply) {
        foreach ($p in ($work | Select-Object -First 25)) { Write-Log "WOULD $($p.action.ToUpper()) $($p.customer) | $($p.device)$(if ($p.changes.Count) { ' | ' + ($p.changes -join '; ') })" }
        if ($work.Count -gt 25) { Write-Log "...and $($work.Count - 25) more (see $PreviewPath)." }
    } elseif ($blocked) {
        Write-Log "No changes made: $($stats.customerMismatch + $stats.siteMismatch) device(s) don't match an IT Glue customer/site and Sync.BlockAllOnMismatch is on." 'WARN'
    } else {
        $done = 0
        $delay = [int]$Cfg.Sync.DelayMsBetweenWrites
        foreach ($p in $work) {
            if ($done -ge $limit) { $stats.deferred = $work.Count - $done; Write-Log "Change limit reached ($limit). $($stats.deferred) change(s) left for the next run(s)." 'WARN'; break }
            $done++
            try {
                if ($p.action -eq 'create') {
                    # Last check against IT Glue as it is now, in case someone added the device since it was read.
                    $dupNow = Find-ITGlueDuplicateNow -OrgId $p.orgId -Name ([string]$p.attributes['name']) -Hostname ([string]$p.attributes['hostname']) -Serial ([string]$p.attributes['serial-number'])
                    if ($dupNow) { throw "Not created, IT Glue now has a duplicate: $dupNow" }
                    $r = Invoke-ITGlueWrite -Method POST -Path '/configurations' -Attributes $p.attributes
                    $newId = [string]$r.data.id
                    if (-not $newId) { throw 'IT Glue answered without the new configuration id.' }
                    $Sync.links[$p.ncId] = @{ itg = $newId; org = $p.orgId; linkedUtc = Get-UtcText; how = 'created' }
                    $stats.created++
                    Write-Log "CREATED $($p.customer) | $($p.device) (IT Glue $newId)" 'CHANGE'
                } else {
                    $null = Invoke-ITGlueWrite -Method PATCH -Path "/configurations/$($p.itgId)" -Attributes $p.attributes
                    $prev = $Sync.links[$p.ncId]
                    $sends = 1
                    if ($prev -is [hashtable] -and [string]$prev.itg -eq $p.itgId -and $prev.diffHash -eq $p.diffHash) { $sends = [int]$prev.sends + 1 }
                    $linkedUtc = Get-UtcText; if ($prev -is [hashtable] -and $prev.linkedUtc) { $linkedUtc = $prev.linkedUtc }
                    $Sync.links[$p.ncId] = @{ itg = $p.itgId; org = $p.orgId; linkedUtc = $linkedUtc; how = $p.match; diffHash = $p.diffHash; sends = $sends }
                    $stats.updated++
                    $note = ''; if ($p.match -eq 'ai') { $note = ' [matched by the local AI model]' } elseif ($p.match -eq 'approved') { $note = ' [match approved in LocalModel.ApprovedMatches]' }
                    Write-Log "UPDATED $($p.customer) | $($p.device) (IT Glue $($p.itgId))${note}: $($p.changes -join '; ')" 'CHANGE'
                    if ($p.match -eq 'ai') { Write-AiAudit @{ type = 'applied'; ncId = $p.ncId; device = $p.device; itgId = $p.itgId; changes = @($p.changes) } }
                }
            } catch {
                $writeFailures++; $stats.writeFailed++
                $msg = $_.Exception.Message
                Write-Log "IT Glue refused $($p.action) of $($p.customer) | $($p.device): $msg" 'ERROR'
                $link = [string]$p.url
                Add-Failure 'WriteFailed' "$($p.action):$($p.ncId)" $p.customer $p.device "$($p.action) failed: $msg" $link
            }
            if ($delay -gt 0) { Start-Sleep -Milliseconds $delay }
        }
        if (-not $retireBlocked) {
            foreach ($r in $retire) {
                try {
                    $null = Invoke-ITGlueWrite -Method PATCH -Path "/configurations/$($r.conf.id)" -Attributes @{ 'configuration-status-id' = [int64]$retiredStatusId }
                    $Sync.links[$r.ncId].retiredUtc = Get-UtcText
                    $stats.retired++
                    Write-Log "RETIRED $(Get-Attr $r.conf 'organization-name') | $(Get-Attr $r.conf 'name') (IT Glue $($r.conf.id)) set to '$($Cfg.Sync.RetiredStatus)'" 'CHANGE'
                } catch {
                    $writeFailures++; $stats.writeFailed++
                    Add-Failure 'WriteFailed' "retire:$($r.ncId)" (Get-Attr $r.conf 'organization-name') (Get-Attr $r.conf 'name') "Setting status '$($Cfg.Sync.RetiredStatus)' failed: $($_.Exception.Message)" (Get-Attr $r.conf 'resource-url')
                }
                if ($delay -gt 0) { Start-Sleep -Milliseconds $delay }
            }
        }
        Write-Log "Applied: $($stats.created) created, $($stats.updated) updated, $($stats.retired) retired, $writeFailures refused."
    }
    if ($retire.Count -gt 0 -and -not $Apply -and -not $retireBlocked) {
        foreach ($r in $retire) { Write-Log "WOULD SET '$($Cfg.Sync.RetiredStatus)' $(Get-Attr $r.conf 'organization-name') | $(Get-Attr $r.conf 'name') (N-central device $($r.ncId) is gone)" }
    }
    return @{ Stats = $stats; WriteFailures = $writeFailures; RetireBlocked = $retireBlocked }
}

# =====================================================================================
# Main: run, compare problems with last time, alert on change (same rules as the health monitor)
# =====================================================================================
function Invoke-Main {
    $nowUtc = [DateTime]::UtcNow
    $result = $null; $runError = $null
    try { $result = Invoke-DeviceSync } catch { $runError = $_.Exception.Message }

    # Save links even when some writes failed, so created configurations aren't created again.
    if (-not $DryRun -and -not $runError) {
        try { Save-JsonFile -Path $SyncStatePath -Obj $Sync -Depth 5 -Compress }
        catch { Write-Log "Couldn't save $SyncStatePath : $($_.Exception.Message)" 'ERROR' }
    }

    if ($runError) {
        Write-Log "Sync couldn't run: $runError" 'ERROR'
        if ($DryRun -or $Limited) { return $EXIT_ERROR }
        $State.ConsecutiveErrors = [int]$State.ConsecutiveErrors + 1
        $State.LastRunUtc = Get-UtcText; $State.LastRunResult = 'ERROR'
        $lastAlert = ConvertFrom-Utc $State.LastErrorAlertUtc
        $reminder = [double]$Cfg.ReminderHours
        $due = (-not $State.ErrorAlertSent) -or ($reminder -gt 0 -and $lastAlert -and ($nowUtc - $lastAlert).TotalHours -ge $reminder)
        if ($due) {
            $subject = "$($Cfg.Smtp.SubjectPrefix) Device sync can't run ($($State.ConsecutiveErrors) failed runs)"
            $html = "<p>The N-central to IT Glue device sync on <b>$(Get-HtmlText $env:COMPUTERNAME)</b> has failed $($State.ConsecutiveErrors) run(s) in a row, so devices are <b>not being synced</b> to IT Glue.</p><p>Last error: <code>$(Get-HtmlText $runError)</code></p><p>Log: $(Get-HtmlText $LogPath)</p>"
            if (Send-AllNotifications -Subject $subject -Html $html -Payload @{ title = $subject; status = 'error'; text = $runError; html = $html; computer = $env:COMPUTERNAME } -AttachmentPath $null) {
                $State.ErrorAlertSent = $true; $State.LastErrorAlertUtc = Get-UtcText
            }
        } else { Write-Log "Error alert already sent at $($State.LastErrorAlertUtc); next reminder after $reminder hours." }
        Save-JsonFile -Path $StatePath -Obj $State
        return $EXIT_ERROR
    }

    $current = @{}
    foreach ($f in $Failures) { if (-not $current.ContainsKey($f.Key)) { $current[$f.Key] = $f } }
    foreach ($ck in $CheckNames.Keys) {
        $n = @($current.Values | Where-Object { $_.Check -eq $ck }).Count
        if (-not $UseAI -and $ck -like 'Ai*' -and $n -eq 0) { continue }
        Write-Log ("{0}: {1}" -f $CheckNames[$ck], $(if ($n -eq 0) { 'OK' } else { "$n problem(s)" })) $(if ($n -eq 0) { 'INFO' } else { 'PROBLEM' })
    }
    $exitCode = $EXIT_OK
    if ($current.Count -gt 0) { $exitCode = $EXIT_FAILED }
    if ($result.WriteFailures -gt 0 -or $result.RetireBlocked) { $exitCode = $EXIT_WRITE_FAILED }

    # A run limited to a few devices doesn't see the whole picture, so it doesn't alert or save problems.
    if ($Limited) { foreach ($f in $current.Values) { Write-Log "[$($f.Check)] $($f.Customer) | $($f.Item) | $($f.Detail)" 'PROBLEM' }; return $exitCode }

    $prev = $State.ActiveFailures
    $new = @($current.Keys | Where-Object { -not $prev.ContainsKey($_) } | ForEach-Object { $current[$_] })
    $still = @($current.Keys | Where-Object { $prev.ContainsKey($_) } | ForEach-Object { $current[$_] })
    $resolved = @($prev.Keys | Where-Object { -not $current.ContainsKey($_) } | ForEach-Object { $p = $prev[$_]; [pscustomobject]@{ Check = $p.Check; Key = $_; Customer = $p.Customer; Item = $p.Item; Detail = $p.Detail; Link = $p.Link } })
    $total = $current.Count
    foreach ($f in $new) { Write-Log "NEW  [$($f.Check)] $($f.Customer) | $($f.Item) | $($f.Detail)" 'PROBLEM' }
    foreach ($f in $resolved) { Write-Log "RESOLVED [$($f.Check)] $($f.Customer) | $($f.Item)" }
    try { $current.Values | Sort-Object Check, Customer, Item | Select-Object Check, Customer, Item, Detail, Link | Export-Csv -LiteralPath $CurrentCsvPath -NoTypeInformation -Encoding UTF8 }
    catch { Write-Log "Couldn't write $CurrentCsvPath : $($_.Exception.Message)" 'WARN' }

    $recovered = [bool]$State.ErrorAlertSent
    $lastNotified = ConvertFrom-Utc $State.LastNotifiedUtc
    $reminderHours = [double]$Cfg.ReminderHours
    $reasons = @()
    if ($new.Count -gt 0) { $reasons += 'new problems' }
    if ($resolved.Count -gt 0 -and $Cfg.NotifyOnResolved) { $reasons += 'problems resolved' }
    if ($recovered) { $reasons += 'sync running again' }
    if ($total -gt 0 -and $reminderHours -gt 0 -and $lastNotified -and ($nowUtc - $lastNotified).TotalHours -ge $reminderHours) { $reasons += 'reminder' }
    if ($ForceNotify) { $reasons += 'forced' }

    if ($reasons.Count -gt 0) {
        $s = $result.Stats
        $headline = 'All devices matched'; if ($total -gt 0) { $headline = "$total problem(s), devices not synced" }
        $bits = @()
        if ($new.Count) { $bits += "$($new.Count) new" }
        if ($resolved.Count) { $bits += "$($resolved.Count) resolved" }
        if ($reasons -contains 'reminder' -and $new.Count -eq 0 -and $resolved.Count -eq 0) { $bits += 'reminder' }
        $subject = "$($Cfg.Smtp.SubjectPrefix) $headline"; if ($bits.Count) { $subject += " ($($bits -join ', '))" }
        $modeText = 'Report only: IT Glue was not changed.'
        if ($Apply) { $modeText = "$($s.created) created, $($s.updated) updated, $($s.retired) retired in IT Glue this run." }
        $rows = ''
        foreach ($ck in $CheckNames.Keys) {
            $n = @($current.Values | Where-Object { $_.Check -eq $ck }).Count
            if (-not $UseAI -and $ck -like 'Ai*' -and $n -eq 0) { continue }
            $res = 'OK'; $col = '#2e7d32'; if ($n -gt 0) { $res = "$n problem(s)"; $col = '#c62828' }
            $rows += "<tr><td>$(Get-HtmlText $CheckNames[$ck])</td><td style='color:$col'><b>$res</b></td></tr>"
        }
        $html = "<div style='font-family:Segoe UI,Arial,sans-serif;font-size:14px'>"
        $html += "<p>N-central to IT Glue device sync at $(Get-Date -Format 'yyyy-MM-dd HH:mm') from $(Get-HtmlText $env:COMPUTERNAME). $(Get-HtmlText $modeText)</p>"
        $html += "<p>$($s.ncDevices) devices in N-central, $($s.considered) to sync, $($s.inSync) already match, $($s.customerMismatch + $s.siteMismatch) not synced because the customer or site doesn't match IT Glue.</p>"
        if ($UseAI) {
            $aiText = "Local AI model ($($Lm.Model)): $($s.aiAsked) asked, $($s.aiCached) answers reused, $($s.aiLinked) linked$(if (-not $Apply) { ' (not saved: report only)' }), $($s.aiReview) held for you to check, $($s.aiArchive) archive suggestions, $($s.aiDeferred) left for the next run, $($s.aiErrors) errors."
            if ($script:AiDown) { $aiText += " Not available this run, so devices were matched the usual way: $($script:AiDown)" }
            $html += "<p style='color:#444'>$(Get-HtmlText $aiText)</p>"
        }
        if ($recovered) { $html += "<p><b>The sync is running again</b> after $([int]$State.ConsecutiveErrors) failed run(s).</p>" }
        $html += "<table cellpadding='4' style='font-size:14px'>$rows</table>"
        $html += Get-SectionHtml 'New problems' $new '#c62828'
        $html += Get-SectionHtml 'Resolved' $resolved '#2e7d32'
        $html += Get-SectionHtml 'Still failing' $still '#555'
        if ($total -gt 0) { $html += "<p style='color:#666;font-size:12px'>Full list: attached CSV or $(Get-HtmlText $CurrentCsvPath) on $(Get-HtmlText $env:COMPUTERNAME). Reminders every $reminderHours h while problems remain unchanged.</p>" }
        $html += '</div>'
        $text = "$subject`r`n" + (Get-SectionText 'New problems' $new) + (Get-SectionText 'Resolved' $resolved) + (Get-SectionText 'Still failing' $still)
        $payload = @{ title = $subject; status = $(if ($total -gt 0) { 'failing' } else { 'passing' }); computer = $env:COMPUTERNAME; total = $total; new = $new.Count; resolved = $resolved.Count; text = $text; html = $html; stats = $s
            failures = @($current.Values | Sort-Object Check, Customer | Select-Object -First 500 Check, Customer, Item, Detail, Link) }
        Write-Log "Notification due ($($reasons -join ', ')): $subject"
        if ($DryRun) {
            Write-Host ''; Write-Host '----- DRY RUN: this message would be sent -----' -ForegroundColor Cyan
            Write-Host $text
            Write-Host '-----------------------------------------------' -ForegroundColor Cyan
        } else {
            $attach = $null; if ($total -gt 0) { $attach = $CurrentCsvPath }
            if (-not (Send-AllNotifications -Subject $subject -Html $html -Payload $payload -AttachmentPath $attach)) {
                # Don't record these problems as notified, so the next run tries again.
                $State.ConsecutiveErrors = 0; $State.LastRunUtc = Get-UtcText; $State.LastRunResult = 'NOTIFY FAILED'
                Save-JsonFile -Path $StatePath -Obj $State
                return $EXIT_NOTIFY_FAILED
            }
            $State.LastNotifiedUtc = Get-UtcText
            $State.ErrorAlertSent = $false
        }
    } else { Write-Log 'Nothing changed since the last notification, so nothing was sent.' }

    $active = @{}
    foreach ($k in $current.Keys) {
        $f = $current[$k]
        $firstSeen = Get-UtcText
        if ($prev.ContainsKey($k) -and $prev[$k].FirstSeenUtc) { $firstSeen = $prev[$k].FirstSeenUtc }
        $active[$k] = @{ Check = $f.Check; Customer = $f.Customer; Item = $f.Item; Detail = $f.Detail; Link = $f.Link; FirstSeenUtc = $firstSeen }
    }
    $State.ActiveFailures = $active
    $State.ConsecutiveErrors = 0
    $State.LastRunUtc = Get-UtcText
    $State.LastRunResult = $(if ($total -gt 0) { 'PROBLEMS' } else { 'OK' })
    if (-not $DryRun) { Save-JsonFile -Path $StatePath -Obj $State }
    return $exitCode
}

$exitCode = $EXIT_ERROR
try { $exitCode = [int](@(Invoke-Main)[-1]) }
catch { Write-Log "Unexpected error: $($_.Exception.Message) $($_.InvocationInfo.PositionMessage)" 'ERROR'; $exitCode = $EXIT_ERROR }
finally {
    if ($lock) { $lock.Dispose() }
    Write-Log "Finished with exit code $exitCode."
}
exit $exitCode
