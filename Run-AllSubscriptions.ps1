#!/usr/bin/env pwsh
param (
    [Parameter()]
    [string]$TenantID,
    [switch]$DeviceLogin,
    [switch]$Obfuscate,
    [switch]$SkipMetrics,
    [switch]$SkipConsumption,
    [switch]$SkipMarketplace,

    [switch]$UseMetricsBatch,

    [switch]$IncludeStorageMetrics,
    [switch]$SkipDiskMetrics,
    [switch]$MetricsDetailed,
    [switch]$CapacityPlan,
    [ValidateSet(0, 5, 15, 30, 60)][int]$MetricsIntervalMinutes = 0,
    [ValidateRange(1, 93)][int]$MetricsLookbackDays,

    [string[]]$Service,

    [switch]$Resume,
    [switch]$ResumeFailedOnly,
    [switch]$IncludeDisabled,

    [switch]$AllowPartialAccess,

    [switch]$Preflight,

    [switch]$MainSummary,

    [switch]$Detailed,

    [int]$ConcurrencyLimit = 6,

    [int]$ParallelStreams = 1,

    [ValidateRange(0, 90)]
    [int]$HeadRoom = 0,

    [int]$ShardIndex = 0,
    [int]$ShardCount = 1,

    [string]$UploadToBlobContainerUri,

    [string]$StateBlobContainerUri,

    [switch]$Plan,

    [double]$PlanPerQuerySeconds = 0
)

if ([string]::IsNullOrWhiteSpace($TenantID))
{
    Write-Host "ERROR: -TenantID is required." -ForegroundColor Red
    Write-Host "Supply the tenant to inventory, either its GUID or its domain name:" -ForegroundColor Yellow
    Write-Host "    ./Run-AllSubscriptions.ps1 -TenantID contoso.onmicrosoft.com" -ForegroundColor Yellow
    Write-Host "To read it from an existing signed-in session: (Get-AzContext).Tenant.Id" -ForegroundColor Yellow
    exit 1
}

if ($PSVersionTable.PSVersion.Major -lt 7)
{
    Write-Host ("Detected Windows PowerShell {0}. This tool requires PowerShell 7." -f $PSVersionTable.PSVersion) -ForegroundColor Yellow

    $PwshPath = $null
    $PwshCommand = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($PwshCommand -and $PwshCommand.Version -and $PwshCommand.Version.Major -ge 7)
    {
        $PwshPath = $PwshCommand.Source
    }
    else
    {
        $PwshCandidates = @()
        if ($env:ProgramFiles)
        {
            $PwshCandidates += (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe')
        }
        $ProgramFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
        if ($ProgramFilesX86)
        {
            $PwshCandidates += (Join-Path $ProgramFilesX86 'PowerShell\7\pwsh.exe')
        }
        foreach ($PwshCandidate in $PwshCandidates)
        {
            if (Test-Path -LiteralPath $PwshCandidate)
            {
                $PwshPath = $PwshCandidate
                break
            }
        }
    }

    if (-not $PwshPath)
    {
        $ManualInstallHint = '  Invoke-Expression "& { $(Invoke-RestMethod https://aka.ms/install-powershell.ps1) } -UseMSI"'
        $IsInteractive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected

        if (-not $IsInteractive)
        {
            Write-Host "PowerShell 7 (pwsh) was not found, and this is a non-interactive session, so I will not prompt to install it." -ForegroundColor Red
            Write-Host "Install PowerShell 7 and re-run. For example:" -ForegroundColor Yellow
            Write-Host $ManualInstallHint -ForegroundColor Yellow
            exit 1
        }

        Write-Host ""
        $InstallAnswer = Read-Host "PowerShell 7 is not installed. Install it now? [y/N]"
        if ($InstallAnswer -notmatch '^(y|yes)$')
        {
            Write-Host "Not installing. Install PowerShell 7 manually and re-run:" -ForegroundColor Yellow
            Write-Host $ManualInstallHint -ForegroundColor Yellow
            exit 1
        }

        Write-Host "Installing PowerShell 7 via the official Microsoft installer (this may prompt for elevation)..." -ForegroundColor Cyan
        try
        {
            $InstallScript = Invoke-RestMethod -Uri 'https://aka.ms/install-powershell.ps1'
            $InstallBlock = [ScriptBlock]::Create($InstallScript)
            & $InstallBlock -UseMSI -Quiet
        }
        catch
        {
            Write-Host ("Automatic install failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
            Write-Host "Install PowerShell 7 manually from https://aka.ms/powershell-release then re-run." -ForegroundColor Yellow
            exit 1
        }

        $PwshCommand = Get-Command pwsh -ErrorAction SilentlyContinue
        if ($PwshCommand -and $PwshCommand.Version -and $PwshCommand.Version.Major -ge 7)
        {
            $PwshPath = $PwshCommand.Source
        }
        elseif ($env:ProgramFiles -and (Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe')))
        {
            $PwshPath = (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe')
        }

        if (-not $PwshPath)
        {
            Write-Host "PowerShell 7 was installed but is not visible in this session yet." -ForegroundColor Yellow
            Write-Host "Close this window, open a new PowerShell 7 (pwsh) prompt, then re-run the same command." -ForegroundColor Yellow
            exit 1
        }
    }

    $ForwardArgs = @()
    foreach ($BoundParam in $PSBoundParameters.GetEnumerator())
    {
        $BoundValue = $BoundParam.Value
        if ($BoundValue -is [System.Management.Automation.SwitchParameter])
        {
            if ($BoundValue.IsPresent)
            {
                $ForwardArgs += ('-' + $BoundParam.Key)
            }
        }
        else
        {
            $ForwardArgs += ('-' + $BoundParam.Key)
            if ($BoundValue -is [System.Array])
            {
                $ForwardArgs += (($BoundValue | ForEach-Object { [string]$_ }) -join ',')
            }
            else
            {
                $ForwardArgs += [string]$BoundValue
            }
        }
    }

    Write-Host ("Re-launching under PowerShell 7: {0}" -f $PwshPath) -ForegroundColor Cyan
    & $PwshPath -NoLogo -NoProfile -File $PSCommandPath @ForwardArgs
    exit $LASTEXITCODE
}

$RequiredAzSubModules = @('Az.Accounts', 'Az.Compute', 'Az.Monitor', 'Az.Billing', 'Az.ResourceGraph')
$MissingAzSubModules = @($RequiredAzSubModules | Where-Object { $null -eq (Get-Module -Name $_ -ListAvailable -ErrorAction SilentlyContinue | Select-Object -First 1) })
if ($MissingAzSubModules.Count -gt 0)
{
    $AzModuleManualHint = ('  Install-Module -Name {0} -Repository PSGallery -Force -AllowClobber -SkipPublisherCheck -Scope CurrentUser' -f ($RequiredAzSubModules -join ','))
    $AzModuleInteractive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected

    if (-not $AzModuleInteractive)
    {
        Write-Host ("Required Az submodule(s) not found ({0}), and this is a non-interactive session, so I will not prompt to install them." -f ($MissingAzSubModules -join ', ')) -ForegroundColor Red
        Write-Host "Install them and re-run:" -ForegroundColor Yellow
        Write-Host $AzModuleManualHint -ForegroundColor Yellow
        exit 1
    }

    Write-Host ""
    $AzModuleAnswer = Read-Host ("These Az submodules are required but not installed: {0}. Install them now (into your user scope)? [y/N]" -f ($MissingAzSubModules -join ', '))
    if ($AzModuleAnswer -notmatch '^(y|yes)$')
    {
        Write-Host "Not installing. Install them and re-run:" -ForegroundColor Yellow
        Write-Host $AzModuleManualHint -ForegroundColor Yellow
        exit 1
    }

    Write-Host ("Installing the required Az submodules into your user scope: {0} ..." -f ($MissingAzSubModules -join ', ')) -ForegroundColor Cyan
    try
    {
        $null = Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser -ErrorAction SilentlyContinue
        Install-Module -Name $MissingAzSubModules -Repository PSGallery -Force -AllowClobber -SkipPublisherCheck -Scope CurrentUser -ErrorAction Stop
    }
    catch
    {
        Write-Host ("Az submodule install failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
        Write-Host "Install them manually then re-run:" -ForegroundColor Yellow
        Write-Host $AzModuleManualHint -ForegroundColor Yellow
        exit 1
    }
}

try
{
    Import-Module Az.Accounts -ErrorAction Stop
}
catch
{
    Write-Host ("The Az PowerShell module is present but failed to load: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host "This usually indicates a broken/partial install (manifest present but bundled assemblies missing or unloadable)." -ForegroundColor Yellow
    Write-Host "Repair it, then re-run:" -ForegroundColor Yellow
    Write-Host "  Get-Module Az* -ListAvailable | Uninstall-Module -Force" -ForegroundColor Yellow
    Write-Host "  Install-Module -Name Az.Accounts,Az.Compute,Az.Monitor,Az.Billing,Az.ResourceGraph -Repository PSGallery -Force -AllowClobber -SkipPublisherCheck -Scope CurrentUser" -ForegroundColor Yellow
    exit 1
}

$FunctionsFile = Join-Path $PSScriptRoot 'Functions/RunAllSubscriptions.Functions.ps1'
if (-not (Test-Path -LiteralPath $FunctionsFile -PathType Leaf))
{
    Write-Host "ERROR: Required functions file not found: $FunctionsFile" -ForegroundColor Red
    Write-Host "Ensure the 'Functions' folder ships alongside this script." -ForegroundColor Yellow
    exit 1
}
. $FunctionsFile

$CommonFunctionsFile = Join-Path $PSScriptRoot 'Functions/Common.Functions.ps1'
if (-not (Test-Path -LiteralPath $CommonFunctionsFile -PathType Leaf))
{
    Write-Host "ERROR: Required functions file not found: $CommonFunctionsFile" -ForegroundColor Red
    Write-Host "Ensure the 'Functions' folder ships alongside this script." -ForegroundColor Yellow
    exit 1
}
. $CommonFunctionsFile

Disable-ConsoleQuickEdit

$RunStartTime = Get-Date

if ($PSBoundParameters.ContainsKey('MainSummary'))
{
    Write-Host "Note: -MainSummary is a retained no-op. The aggregate MainSummary.html is produced on EVERY run and folded into the consolidated bundle, so you already get it without this flag." -ForegroundColor DarkGray
}

$FailedSubscriptions = @()

$ArchiveWriteFailures = @()

$Global:MetricsFailedSubs = @()

$Global:MarketplaceFailedSubs = @()

$Global:MarketplaceRecordCount = 0

$Global:CollectorFailures = @()

$RootResult = Get-RdaInventoryRoot -NoInherit
if (-not $RootResult.Ok)
{
    Write-Host ("ERROR: {0}" -f $RootResult.Message) -ForegroundColor Red
    Exit-Wrapper -Code 1
}
$InventoryRoot = $RootResult.Path
if ($RootResult.IsFallback)
{
    Write-Host ("WARNING: {0}" -f $RootResult.Message) -ForegroundColor Yellow
}
Set-RdaInventoryRootForChildren -Path $InventoryRoot

$WrapperTranscriptStarted = $false
$WrapperTranscriptFile = Join-Path $InventoryRoot ("RunAllSubscriptions_transcript_{0}.txt" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
try
{
    Start-Transcript -LiteralPath $WrapperTranscriptFile -UseMinimalHeader -Force | Out-Null
    $WrapperTranscriptStarted = $true
    Write-Host ("Wrapper transcript: {0}" -f $WrapperTranscriptFile) -ForegroundColor DarkGray
}
catch
{
    Write-Host ("WARNING: Could not start wrapper transcript at {0}: {1}" -f $WrapperTranscriptFile, $_.Exception.Message) -ForegroundColor Yellow
}

Invoke-PreFlightChecks -InventoryRoot $InventoryRoot

try
{
    $TenantID = Resolve-TenantId -Value $TenantID
}
catch
{
    Write-Host ("ERROR: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Exit-Wrapper -Code 1
}

if ($ShardCount -lt 1)
{
    Write-Host ("ERROR: -ShardCount must be >= 1 (got {0})." -f $ShardCount) -ForegroundColor Red
    Exit-Wrapper -Code 1
}
if ($ShardIndex -lt 0 -or $ShardIndex -ge $ShardCount)
{
    Write-Host ("ERROR: -ShardIndex must be in [0, {0}] for -ShardCount {1} (got {2})." -f ($ShardCount - 1), $ShardCount, $ShardIndex) -ForegroundColor Red
    Exit-Wrapper -Code 1
}

if ($UploadToBlobContainerUri)
{
    $UploadUriValid = $false
    try
    {
        $PreflightUri = [System.Uri]$UploadToBlobContainerUri
        $UploadUriValid = $PreflightUri.Scheme -eq 'https' -and
        $PreflightUri.Host -match '\.blob\.' -and -not [string]::IsNullOrWhiteSpace($PreflightUri.AbsolutePath.Trim('/'))
    }
    catch
    {
        $UploadUriValid = $false
    }
    if (-not $UploadUriValid)
    {
        Write-Host ("ERROR: -UploadToBlobContainerUri '{0}' is not a valid blob container URL. Expected https://<account>.blob.core.windows.net/<container>[/<prefix>]." -f $UploadToBlobContainerUri) -ForegroundColor Red
        Exit-Wrapper -Code 1
    }
    if ($null -eq (Get-Module -Name Az.Storage -ListAvailable -ErrorAction SilentlyContinue | Select-Object -First 1))
    {
        Write-Host "ERROR: -UploadToBlobContainerUri was requested but the Az.Storage module is not installed. Install it (Install-Module Az.Storage -Scope CurrentUser) or bake it into the container image, then re-run." -ForegroundColor Red
        Exit-Wrapper -Code 1
    }
}

$ResumeStateFile = if ($ShardCount -gt 1)
{
    Join-Path $InventoryRoot (".resume-state-{0}-shard-{1}of{2}.json" -f $TenantID, $ShardIndex, $ShardCount)
}
else
{
    Join-Path $InventoryRoot (".resume-state-{0}.json" -f $TenantID)
}

$StateBlobParts = $null
if ($StateBlobContainerUri)
{
    $StateUriValid = $false
    try
    {
        $StatePreflightUri = [System.Uri]$StateBlobContainerUri
        $StateUriValid = $StatePreflightUri.Scheme -eq 'https' -and
        $StatePreflightUri.Host -match '\.blob\.' -and -not [string]::IsNullOrWhiteSpace($StatePreflightUri.AbsolutePath.Trim('/'))
    }
    catch
    {
        $StateUriValid = $false
    }
    if (-not $StateUriValid)
    {
        Write-Host ("ERROR: -StateBlobContainerUri '{0}' is not a valid blob container URL. Expected https://<account>.blob.core.windows.net/<container>[/<prefix>]." -f $StateBlobContainerUri) -ForegroundColor Red
        Exit-Wrapper -Code 1
    }
    if ($null -eq (Get-Module -Name Az.Storage -ListAvailable -ErrorAction SilentlyContinue | Select-Object -First 1))
    {
        Write-Host "ERROR: -StateBlobContainerUri was requested but the Az.Storage module is not installed. Install it (Install-Module Az.Storage -Scope CurrentUser) or bake it into the container image, then re-run." -ForegroundColor Red
        Exit-Wrapper -Code 1
    }
    $StateBlobParts = Split-BlobContainerUri -Uri $StateBlobContainerUri
    Write-Host ("Resume state will be mirrored to blob: {0}/{1}_state/ (shard-namespaced)" -f $StateBlobParts.Container, $StateBlobParts.Prefix) -ForegroundColor Cyan
}

try
{
    $PsTenant = Get-AzPsSignedInTenant

    $PsTenantOk = ($PsTenant -eq $TenantID)

    $PsTokenOk = $false
    if ($PsTenantOk) { $PsTokenOk = Test-AzPsTokenSilent -Tenant $TenantID }

    $PsOk = $PsTenantOk -and $PsTokenOk

    if ($PsOk)
    {
        Write-Host ("Existing session detected for tenant {0} (token probe ok); skipping interactive login." -f $TenantID) -ForegroundColor Green
    }
    else
    {
        if ($null -eq $PsTenant)
        {
            Write-Host "Az PowerShell is not signed in; authenticating..." -ForegroundColor Cyan
        }
        elseif (-not $PsTenantOk)
        {
            Write-Host ("Az PowerShell is signed in to tenant {0}; switching to {1}..." -f $PsTenant, $TenantID) -ForegroundColor Cyan
        }
        else
        {
            Write-Host ("Az PowerShell session for tenant {0} cannot acquire a token silently (likely expired or CA/MFA-gated); re-authenticating..." -f $TenantID) -ForegroundColor Cyan
        }

        $SessionInteractive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
        if (-not $SessionInteractive -and -not $DeviceLogin)
        {
            Write-Host ("ERROR: No usable Az PowerShell session for tenant {0}, and this is a non-interactive session - refusing to launch an interactive sign-in (it would hang here)." -f $TenantID) -ForegroundColor Red
            Write-Host "Establish a session before running (choose one):" -ForegroundColor Yellow
            Write-Host "  - Use an AzurePowerShell@5 pipeline task (NOT AzureCLI@2) so the Az PowerShell context is set from the service connection." -ForegroundColor Yellow
            Write-Host ("  - Or run 'Connect-AzAccount -Tenant {0}' interactively first, then re-run." -f $TenantID) -ForegroundColor Yellow
            Write-Host "  - Or pass -DeviceLogin to use the device-code flow (still requires a human to complete it)." -ForegroundColor Yellow
            Exit-Wrapper -Code 1
        }

        if ($DeviceLogin)
        {
            Connect-AzAccount -Tenant $TenantID -UseDeviceAuthentication | Out-Null
        }
        else
        {
            Connect-AzAccount -Tenant $TenantID | Out-Null
        }
    }
}
catch
{
    Write-Host "ERROR: Authentication failed. $_" -ForegroundColor Red
    Exit-Wrapper -Code 1
}

Write-Host ""
Write-Host "Running identity:" -ForegroundColor Cyan
$BannerCtx = Get-AzContext -ErrorAction SilentlyContinue
if ($BannerCtx -and $BannerCtx.Account)
{
    Write-Host ("  Az PowerShell : {0} (type: {1})" -f $BannerCtx.Account.Id, $BannerCtx.Account.Type) -ForegroundColor Green
    Write-Host ("  Tenant        : {0}" -f $BannerCtx.Tenant.Id) -ForegroundColor Green
    if ($BannerCtx.Subscription -and $BannerCtx.Subscription.Id)
    {
        Write-Host ("  Active sub    : {0}" -f $BannerCtx.Subscription.Id) -ForegroundColor Green
    }
    if ($BannerCtx.Account.Type -and $BannerCtx.Account.Type -ne 'User')
    {
        Write-Host "  Note          : running as a service principal / workload identity. If the id above shows as '***', that" -ForegroundColor DarkYellow
        Write-Host "                  is Azure DevOps masking the service connection's client id in the log - not the tool." -ForegroundColor DarkYellow
        Write-Host "                  Identify this principal in Project Settings > Service connections, or resolve its object id" -ForegroundColor DarkYellow
        Write-Host "                  with  Get-AzADServicePrincipal -ApplicationId <app-id>  from a workstation, then grant THAT" -ForegroundColor DarkYellow
        Write-Host "                  object id Reader at the tenant-root management group (it differs from an interactive login)." -ForegroundColor DarkYellow
    }
}
else
{
    Write-Host "  Az PowerShell : NOT signed in (Get-AzContext returned nothing)" -ForegroundColor Red
}
Write-Host ""

$AllSubscriptions = Get-AzSubscription -TenantId $TenantID -WarningVariable SubWarnings -WarningAction SilentlyContinue
if ($null -eq $AllSubscriptions) { $AllSubscriptions = @() }
$AllSubscriptions = @($AllSubscriptions)

if ($AllSubscriptions.Count -eq 0)
{
    Write-Host ("ERROR: Get-AzSubscription returned no subscriptions for tenant {0}." -f $TenantID) -ForegroundColor Red
    if ($SubWarnings.Count -gt 0)
    {
        Write-Host "Underlying warnings:" -ForegroundColor Red
        foreach ($w in $SubWarnings) { Write-Host ("  - {0}" -f $w) -ForegroundColor Red }
        Write-Host "This typically indicates the cached session cannot acquire a token (Conditional Access / MFA), or the signed-in identity has no access to any subscription in this tenant." -ForegroundColor Yellow
        Write-Host "Try re-running with -DeviceLogin, or sign out and sign back in to the requested tenant." -ForegroundColor Yellow
    }
    else
    {
        Write-Host "The signed-in identity may have no subscriptions in this tenant. Verify with 'Get-AzSubscription -TenantId <id>' interactively." -ForegroundColor Yellow
    }
    Exit-Wrapper -Code 1
}

if ($IncludeDisabled)
{
    $Subscriptions = $AllSubscriptions
    $Excluded = @()
}
else
{
    $Subscriptions = @($AllSubscriptions | Where-Object { $_.State -eq 'Enabled' })
    $Excluded = @($AllSubscriptions | Where-Object { $_.State -ne 'Enabled' })
}

Write-Host ("Subscriptions visible: {0}" -f $AllSubscriptions.Count) -ForegroundColor Cyan
if ($Excluded.Count -gt 0)
{
    $ByState = $Excluded | Group-Object -Property State | ForEach-Object { ('{0}: {1}' -f $_.Name, $_.Count) }
    Write-Host ("Excluded {0} non-Enabled subscription(s) [{1}]. Use -IncludeDisabled to inventory them anyway." -f $Excluded.Count, ($ByState -join ', ')) -ForegroundColor Yellow
}

if ($Plan)
{
    $PlanRec = Get-RecommendedParallelism
    $PlanStreamsExplicit = $PSBoundParameters.ContainsKey('ParallelStreams')
    $PlanConcurrencyExplicit = $PSBoundParameters.ContainsKey('ConcurrencyLimit')
    $PlanStreams = if ($PlanStreamsExplicit) { $ParallelStreams } else { $PlanRec.Streams }
    $PlanConcurrency = if ($PlanConcurrencyExplicit) { $ConcurrencyLimit } else { $PlanRec.Concurrency }
    if ($Subscriptions.Count -gt 0 -and $PlanStreams -gt $Subscriptions.Count) { $PlanStreams = $Subscriptions.Count }

    $FmtDur = {
        param([long]$Seconds)
        $TotalMinutes = [long][math]::Round($Seconds / 60.0)
        $Hours = [math]::Floor($TotalMinutes / 60)
        $Minutes = $TotalMinutes % 60
        if ($Hours -gt 0) { '{0}h {1}m' -f $Hours, $Minutes } else { '{0}m' -f $Minutes }
    }

    $QuoteArg = { param($Value) "'" + ([string]$Value -replace "'", "''") + "'" }

    $ExtraFlags = @()
    if ($Obfuscate) { $ExtraFlags += '-Obfuscate' }
    if ($DeviceLogin) { $ExtraFlags += '-DeviceLogin' }
    if ($IncludeDisabled) { $ExtraFlags += '-IncludeDisabled' }
    if ($AllowPartialAccess) { $ExtraFlags += '-AllowPartialAccess' }
    if ($Detailed) { $ExtraFlags += '-Detailed' }
    if ($Service) { $ExtraFlags += ('-Service {0}' -f (& $QuoteArg ($Service -join ','))) }
    if ($SkipMetrics) { $ExtraFlags += '-SkipMetrics' }
    if ($SkipConsumption) { $ExtraFlags += '-SkipConsumption' }
    if ($SkipMarketplace) { $ExtraFlags += '-SkipMarketplace' }
    if ($UseMetricsBatch) { $ExtraFlags += '-UseMetricsBatch' }
    if ($IncludeStorageMetrics) { $ExtraFlags += '-IncludeStorageMetrics' }
    if ($SkipDiskMetrics) { $ExtraFlags += '-SkipDiskMetrics' }
    if ($MetricsDetailed) { $ExtraFlags += '-MetricsDetailed' }
    if ($CapacityPlan) { $ExtraFlags += '-CapacityPlan' }
    if ($MetricsIntervalMinutes -gt 0) { $ExtraFlags += ('-MetricsIntervalMinutes {0}' -f $MetricsIntervalMinutes) }
    if ($PSBoundParameters.ContainsKey('MetricsLookbackDays')) { $ExtraFlags += ('-MetricsLookbackDays {0}' -f $MetricsLookbackDays) }
    if ($HeadRoom -gt 0) { $ExtraFlags += ('-HeadRoom {0}' -f $HeadRoom) }
    if ($UploadToBlobContainerUri) { $ExtraFlags += ('-UploadToBlobContainerUri {0}' -f (& $QuoteArg $UploadToBlobContainerUri)) }
    if ($StateBlobContainerUri) { $ExtraFlags += ('-StateBlobContainerUri {0}' -f (& $QuoteArg $StateBlobContainerUri)) }
    $ExtraStr = if ($ExtraFlags.Count -gt 0) { ' ' + ($ExtraFlags -join ' ') } else { '' }
    $RamLabelPlan = if ($PlanRec.RamGB -gt 0) { '{0} GB RAM' -f $PlanRec.RamGB.ToString([cultureinfo]::InvariantCulture) } else { 'RAM undetected' }

    $WeightedPlan = $null
    $PlanArgUnavailable = $false
    $PlanZeroWeightSubs = 0
    $PlanCallPerQuery = 0.0
    $PlanBatchPerQuery = 0.0
    if (-not $SkipMetrics -and $Subscriptions.Count -gt 0)
    {
        $PlanSkipStorage = -not $IncludeStorageMetrics
        $PlanSubWeights = Get-PlanSubscriptionWeights -SubscriptionIds @($Subscriptions | ForEach-Object { [string]$_.Id }) -SkipDiskMetrics:$SkipDiskMetrics -SkipStorageMetrics:$PlanSkipStorage
        if ($null -ne $PlanSubWeights)
        {
            $PlanCallPerQuery = if ($PlanPerQuerySeconds -gt 0) { $PlanPerQuerySeconds } else { 9.5 }
            $PlanBatchPerQuery = if ($PlanPerQuerySeconds -gt 0) { $PlanPerQuerySeconds } else { 0.5 }
            $PlanBaseSeconds = 90.0
            $PlanSafetyFactor = 1.3
            $PlanSubSeconds = @{}
            foreach ($PlanSub in $Subscriptions)
            {
                $SubKey = [string]$PlanSub.Id
                if ($PlanSubWeights.ContainsKey($SubKey))
                {
                    $SubW = $PlanSubWeights[$SubKey]
                    $BatchW = [double]$SubW.Batch
                    $CallW = [double]$SubW.Total - $BatchW
                    if ($CallW -lt 0) { $CallW = 0 }
                    $MetricSeconds = if ($UseMetricsBatch)
                    {
                        ($PlanBatchPerQuery * $BatchW) + ($PlanCallPerQuery * $CallW)
                    }
                    else
                    {
                        $PlanCallPerQuery * [double]$SubW.Total
                    }
                    $PlanSubSeconds[$SubKey] = $PlanBaseSeconds + ($MetricSeconds * $PlanSafetyFactor)
                }
                else
                {
                    $PlanZeroWeightSubs++
                    $PlanSubSeconds[$SubKey] = $PlanBaseSeconds
                }
            }
            $WeightedPlan = Get-WeightedInventoryPlan -SubSeconds $PlanSubSeconds -Streams $PlanStreams -MaxSingleMachineHours 2
        }
        else
        {
            $PlanArgUnavailable = $true
        }
    }

    if ($null -ne $WeightedPlan)
    {
        $CostSource = if ($PlanPerQuerySeconds -gt 0) { 'operator-supplied -PlanPerQuerySeconds' } elseif ($UseMetricsBatch) { 'auto: batched, rough' } else { 'auto: per-call, rough' }
        $StreamsSrcPlan = if ($PlanStreamsExplicit) { 'explicit' } else { 'auto' }
        $ConcSrcPlan = if ($PlanConcurrencyExplicit) { 'explicit' } else { 'auto' }
        Write-Host ""
        Write-Host "================ Inventory Plan (assessment only - nothing was inventoried) ================" -ForegroundColor Green
        Write-Host ("Eligible subscriptions   : {0}" -f $WeightedPlan.SubscriptionCount) -ForegroundColor Cyan
        Write-Host ("This machine             : {0} vCPU / {1}  ->  -ParallelStreams {2} ({3}) -ConcurrencyLimit {4} ({5})" -f $PlanRec.VCpu, $RamLabelPlan, $PlanStreams, $StreamsSrcPlan, $PlanConcurrency, $ConcSrcPlan) -ForegroundColor Cyan
        Write-Host "Sizing basis             : live metric-query volume (Resource Graph)" -ForegroundColor Cyan
        if ($UseMetricsBatch)
        {
            Write-Host ("Per-metric-query cost    : ~{0}s per-call, ~{1}s batched types [{2}]" -f $PlanCallPerQuery, $PlanBatchPerQuery, $CostSource) -ForegroundColor Cyan
        }
        else
        {
            Write-Host ("Per-metric-query cost    : ~{0}s [{1}]" -f $PlanCallPerQuery, $CostSource) -ForegroundColor Cyan
        }
        Write-Host ("Single-machine ceiling   : {0} h" -f $WeightedPlan.MaxSingleMachineHours) -ForegroundColor Cyan
        Write-Host ("Slowest single sub (est) : ~{0}" -f (& $FmtDur $WeightedPlan.LargestSingleSubSeconds)) -ForegroundColor Cyan
        Write-Host ""

        if ($WeightedPlan.CeilingUnreachable)
        {
            if ($WeightedPlan.CeilingUnreachableReason -eq 'single-subscription-exceeds-ceiling')
            {
                Write-Host ("WARNING: the single slowest subscription alone is ~{0}, over the {1} h ceiling. Sharding splits work ACROSS subscriptions and cannot speed up ONE subscription, so NO shard count fixes this - reduce that subscription's metrics load instead (-SkipDiskMetrics removes the disk queries that dominate volume, -UseMetricsBatch cuts the per-query cost, -MetricsIntervalMinutes 60 shrinks each response, -MetricsLookbackDays 14 shortens the window each response covers). See docs/Plan.md." -f (& $FmtDur $WeightedPlan.LargestSingleSubSeconds), $WeightedPlan.MaxSingleMachineHours) -ForegroundColor Yellow
            }
            else
            {
                Write-Host ("WARNING: even at {0} shard(s) - one per subscription, the maximum useful - the busiest shard is ~{1}, over the {2} h ceiling, because the hash partition clumps several heavy subscriptions together. Reduce metrics load (-SkipDiskMetrics / -UseMetricsBatch / -MetricsIntervalMinutes 60 / -MetricsLookbackDays 14) to bring the busiest shard down. See docs/Plan.md." -f $WeightedPlan.ShardCount, (& $FmtDur $WeightedPlan.BusiestShardSeconds), $WeightedPlan.MaxSingleMachineHours) -ForegroundColor Yellow
            }
            Write-Host ""
            Write-Host ("Best achievable with the current settings: SHARD across {0} machine(s) (busiest shard still ~{1} - does NOT get under the ceiling)." -f $WeightedPlan.ShardCount, (& $FmtDur $WeightedPlan.BusiestShardSeconds)) -ForegroundColor Yellow
            $MaxToList = 10
            $ListCount = [math]::Min($WeightedPlan.ShardCount, $MaxToList)
            for ($i = 0; $i -lt $ListCount; $i++)
            {
                Write-Host ("    ./Run-AllSubscriptions.ps1 -TenantID {0} -ShardCount {1} -ShardIndex {2} -ParallelStreams {3} -ConcurrencyLimit {4}{5}" -f (& $QuoteArg $TenantID), $WeightedPlan.ShardCount, $i, $PlanStreams, $PlanConcurrency, $ExtraStr) -ForegroundColor White
            }
            if ($WeightedPlan.ShardCount -gt $MaxToList)
            {
                Write-Host ("    ... through -ShardIndex {0} (use -ShardIndex 0..{0}, one per machine)." -f ($WeightedPlan.ShardCount - 1)) -ForegroundColor DarkGray
            }
        }
        elseif ($WeightedPlan.Mode -eq 'Single')
        {
            Write-Host ("Recommendation: SINGLE MACHINE is sufficient (busiest-path est. ~{0}, under the {1} h ceiling)." -f (& $FmtDur $WeightedPlan.BusiestShardSeconds), $WeightedPlan.MaxSingleMachineHours) -ForegroundColor Green
            Write-Host "Run:" -ForegroundColor Green
            Write-Host ("  ./Run-AllSubscriptions.ps1 -TenantID {0} -ParallelStreams {1} -ConcurrencyLimit {2}{3}" -f (& $QuoteArg $TenantID), $PlanStreams, $PlanConcurrency, $ExtraStr) -ForegroundColor White
        }
        else
        {
            Write-Host ("Recommendation: SHARD across {0} machines (busiest shard est. ~{1}, within the {2} h ceiling)." -f $WeightedPlan.ShardCount, (& $FmtDur $WeightedPlan.BusiestShardSeconds), $WeightedPlan.MaxSingleMachineHours) -ForegroundColor Green
            Write-Host ("  ~{0} subscription(s) per machine (shards balanced by the real hash partition, so heavy subscriptions are spread out)." -f $WeightedPlan.PerMachineSubscriptions) -ForegroundColor Green
            Write-Host "  Run ONE of these per machine (same command, distinct -ShardIndex):" -ForegroundColor Green
            $MaxToList = 10
            $ListCount = [math]::Min($WeightedPlan.ShardCount, $MaxToList)
            for ($i = 0; $i -lt $ListCount; $i++)
            {
                Write-Host ("    ./Run-AllSubscriptions.ps1 -TenantID {0} -ShardCount {1} -ShardIndex {2} -ParallelStreams {3} -ConcurrencyLimit {4}{5}" -f (& $QuoteArg $TenantID), $WeightedPlan.ShardCount, $i, $PlanStreams, $PlanConcurrency, $ExtraStr) -ForegroundColor White
            }
            if ($WeightedPlan.ShardCount -gt $MaxToList)
            {
                Write-Host ("    ... through -ShardIndex {0} (use -ShardIndex 0..{0}, one per machine, across all {1} machines)." -f ($WeightedPlan.ShardCount - 1), $WeightedPlan.ShardCount) -ForegroundColor DarkGray
            }
            Write-Host "  Then upload each machine's AllSubscriptions_ResourcesReport_*.zip (see docs/horizontal-sharding.md)." -ForegroundColor DarkGray
        }

        if ($PlanZeroWeightSubs -gt 0)
        {
            Write-Host ("Note: {0} of {1} subscription(s) matched no metric-eligible resources and were sized at base overhead only. If you expect metrics there, the signed-in identity may lack Resource Graph visibility into them." -f $PlanZeroWeightSubs, $WeightedPlan.SubscriptionCount) -ForegroundColor DarkGray
        }
        foreach ($DirLine in (Get-PlanShardDirective -ShardCount $WeightedPlan.ShardCount))
        {
            if ($DirLine -like 'IMPORTANT:*') { Write-Host $DirLine -ForegroundColor Yellow }
            else { Write-Host $DirLine -ForegroundColor DarkGray }
        }
        Write-Host ""
        Write-Host "(Estimate only - the per-metric-query cost is throttling-dependent and the sizing is a conservative lower bound with a built-in safety margin; pass -PlanPerQuerySeconds measured from a prior run's Diagnostics timings for a tenant-accurate estimate. See docs/Plan.md.)" -ForegroundColor DarkGray
        Exit-Wrapper -Code 0
    }

    if ($PlanArgUnavailable)
    {
        Write-Host ""
        Write-Host "NOTE: could not size by live metric-query volume (Resource Graph unavailable or the query failed), so this is a COARSE flat per-subscription estimate - it ignores per-subscription metric composition and can under- or over-size a tenant with uneven metric load. For a composition-aware plan ensure the Az.ResourceGraph module is available; for a tenant-accurate figure pass -PlanPerQuerySeconds measured from a prior run's Diagnostics timings." -ForegroundColor Yellow
    }
    $PlanPerSub = 60.0
    $PlanMode = 'inventory + metrics + consumption'
    if ($SkipMetrics -and $SkipConsumption) { $PlanPerSub = 20.0; $PlanMode = 'inventory only' }
    elseif ($SkipMetrics -or $SkipConsumption) { $PlanPerSub = 40.0; $PlanMode = 'inventory + one of metrics/consumption' }
    $PlanResult = Get-InventoryPlan -SubscriptionCount $Subscriptions.Count -Streams $PlanStreams -PerSubSeconds $PlanPerSub -MaxSingleMachineHours 2

    Write-Host ""
    Write-Host "================ Inventory Plan (assessment only - nothing was inventoried) ================" -ForegroundColor Green
    Write-Host ("Eligible subscriptions : {0}" -f $PlanResult.SubscriptionCount) -ForegroundColor Cyan
    Write-Host ("This machine           : {0} vCPU / {1}  ->  -ParallelStreams {2} -ConcurrencyLimit {3}" -f $PlanRec.VCpu, $RamLabelPlan, $PlanStreams, $PlanConcurrency) -ForegroundColor Cyan
    Write-Host ("Per-subscription est.  : ~{0}s ({1})" -f [int]$PlanResult.PerSubSeconds, $PlanMode) -ForegroundColor Cyan
    Write-Host ("Single-machine ceiling : {0} h" -f $PlanResult.MaxSingleMachineHours) -ForegroundColor Cyan
    Write-Host ""

    if ($PlanResult.SubscriptionCount -le 0)
    {
        Write-Host "No eligible subscriptions to plan for." -ForegroundColor Yellow
    }
    elseif ($PlanResult.Mode -eq 'Single')
    {
        Write-Host ("Recommendation: SINGLE MACHINE is sufficient (est. ~{0}, under the {1} h ceiling)." -f (& $FmtDur $PlanResult.EstimatedSeconds), $PlanResult.MaxSingleMachineHours) -ForegroundColor Green
        Write-Host "Run:" -ForegroundColor Green
        Write-Host ("  ./Run-AllSubscriptions.ps1 -TenantID {0} -ParallelStreams {1} -ConcurrencyLimit {2}{3}" -f (& $QuoteArg $TenantID), $PlanStreams, $PlanConcurrency, $ExtraStr) -ForegroundColor White
    }
    else
    {
        Write-Host ("Recommendation: SHARD across {0} machines (a single machine would take ~{1}, over the {2} h ceiling)." -f $PlanResult.ShardCount, (& $FmtDur $PlanResult.EstimatedSeconds), $PlanResult.MaxSingleMachineHours) -ForegroundColor Green
        Write-Host ("  Each machine handles ~{0} subscription(s) in ~{1}." -f $PlanResult.PerMachineSubscriptions, (& $FmtDur $PlanResult.EstimatedPerMachineSeconds)) -ForegroundColor Green
        Write-Host "  Run ONE of these per machine (same command, distinct -ShardIndex):" -ForegroundColor Green
        $MaxToList = 10
        $ListCount = [math]::Min($PlanResult.ShardCount, $MaxToList)
        for ($i = 0; $i -lt $ListCount; $i++)
        {
            Write-Host ("    ./Run-AllSubscriptions.ps1 -TenantID {0} -ShardCount {1} -ShardIndex {2} -ParallelStreams {3} -ConcurrencyLimit {4}{5}" -f (& $QuoteArg $TenantID), $PlanResult.ShardCount, $i, $PlanStreams, $PlanConcurrency, $ExtraStr) -ForegroundColor White
        }
        if ($PlanResult.ShardCount -gt $MaxToList)
        {
            Write-Host ("    ... through -ShardIndex {0} (use -ShardIndex 0..{0}, one per machine, across all {1} machines)." -f ($PlanResult.ShardCount - 1), $PlanResult.ShardCount) -ForegroundColor DarkGray
        }
        Write-Host "  Then upload each machine's AllSubscriptions_ResourcesReport_*.zip (see docs/horizontal-sharding.md)." -ForegroundColor DarkGray
    }
    foreach ($DirLine in (Get-PlanShardDirective -ShardCount $PlanResult.ShardCount))
    {
        if ($DirLine -like 'IMPORTANT:*') { Write-Host $DirLine -ForegroundColor Yellow }
        else { Write-Host $DirLine -ForegroundColor DarkGray }
    }
    Write-Host ""
    Write-Host "Throttling: Resource Graph queries auto-retry with exponential backoff + jitter (up to 30 retries, backoff capped per attempt) and honor the service's own Retry-After / quota-reset header when it sends one, so a shard rides out sustained tenant-wide throttling at scale instead of failing a subscription." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "(Estimate only - actual time varies with resource density and metrics/consumption volume.)" -ForegroundColor DarkGray
    Exit-Wrapper -Code 0
}

if ($ShardCount -gt 1)
{
    $BeforeShard = $Subscriptions.Count
    $Subscriptions = @(Select-ShardSubscriptions -Subscriptions $Subscriptions -ShardIndex $ShardIndex -ShardCount $ShardCount)
    Write-Host ("Shard {0} of {1}: processing {2} of {3} eligible subscription(s) on this machine." -f $ShardIndex, $ShardCount, $Subscriptions.Count, $BeforeShard) -ForegroundColor Cyan
    Write-Host "  Run the other shards (same -ShardCount, different -ShardIndex) on separate machines to cover the full tenant." -ForegroundColor DarkGray
    if ($Subscriptions.Count -eq 0)
    {
        Write-Host ("Shard {0} of {1} has no subscriptions assigned to it; nothing to process on this machine." -f $ShardIndex, $ShardCount) -ForegroundColor Yellow
        Exit-Wrapper -Code 0
    }
}

Write-Host ("Subscriptions to process: {0}" -f $Subscriptions.Count) -ForegroundColor Cyan

$StateBlobArgs = @{}
if ($null -ne $StateBlobParts)
{
    $StateBlobCtx = New-StateBlobContext -Account $StateBlobParts.Account
    $StateBlobArgs = @{
        BlobContext   = $StateBlobCtx
        BlobContainer = $StateBlobParts.Container
        BlobName      = Get-StateBlobName -Prefix $StateBlobParts.Prefix -Tenant $TenantID -ShardIndex $ShardIndex -ShardCount $ShardCount -StreamId -1
    }
}

$SeedState = Get-ResumeStateObject -Path $ResumeStateFile -Tenant $TenantID @StateBlobArgs
$CompletedIds = @(Get-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID @StateBlobArgs -State $SeedState)
$FailedAttempts = @(Get-FailedAttempts -Path $ResumeStateFile -Tenant $TenantID @StateBlobArgs -State $SeedState)

$StartSnapshot = Get-StartSnapshot -Path $ResumeStateFile -Tenant $TenantID @StateBlobArgs -State $SeedState
if ($null -eq $StartSnapshot)
{
    $StartSnapshot = [pscustomobject]@{ CapturedUtc = (Get-Date).ToString('o'); SubscriptionIds = @($AllSubscriptions.Id) }
}
$StateSaveArgs = @{ StartSnapshot = $StartSnapshot } + $StateBlobArgs

if ($Resume -or $ResumeFailedOnly)
{
    $StrandedStreamFiles = @(Get-StreamResumeStateFiles -InventoryRoot $InventoryRoot -Tenant $TenantID)
    if ($StrandedStreamFiles.Count -gt 0)
    {
        $StrandedCompleted = @()
        $StrandedFailed = @()
        foreach ($StreamFile in $StrandedStreamFiles)
        {
            try
            {
                $Obj = Get-Content -LiteralPath $StreamFile.FullName -Raw | ConvertFrom-Json
                if ($null -ne $Obj.Completed) { $StrandedCompleted += @($Obj.Completed) }
                if ($null -ne $Obj.FailedAttempts) { $StrandedFailed += @($Obj.FailedAttempts) }
            }
            catch
            {
                Write-Verbose ("Could not read stranded stream resume file {0}: {1}" -f $StreamFile.FullName, $_.Exception.Message)
            }
        }
        if ($StrandedCompleted.Count -gt 0)
        {
            $CompletedIds = @($CompletedIds + $StrandedCompleted | Sort-Object -Unique)
        }
        $FailedAttempts = Merge-FailedAttempts -ExistingFailedAttempts $FailedAttempts -StreamFailedAttempts $StrandedFailed -CompletedIds $CompletedIds
        if ($StrandedCompleted.Count -gt 0 -or @($StrandedFailed).Count -gt 0)
        {
            Write-Host ("Recovered per-stream state from an interrupted parallel run: {0} completed, {1} failed subscription record(s)." -f $StrandedCompleted.Count, @($StrandedFailed).Count) -ForegroundColor Cyan
            Save-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID -Ids $CompletedIds -FailedAttempts $FailedAttempts @StateSaveArgs
        }
    }
}

if ($Resume)
{
    if ($CompletedIds.Count -gt 0)
    {
        Write-Host ("Resume mode: {0} previously completed subscription(s) will be skipped." -f $CompletedIds.Count) -ForegroundColor Cyan
    }
    else
    {
        Write-Host "Resume mode: no previous state found; processing all subscriptions." -ForegroundColor Cyan
    }
}
else
{
    if ($CompletedIds.Count -gt 0)
    {
        Write-Host ("Note: resume state file exists at {0} ({1} previously completed). Pass -Resume to skip them." -f $ResumeStateFile, $CompletedIds.Count) -ForegroundColor Yellow
    }
}

if ($ResumeFailedOnly)
{
    if ($FailedAttempts.Count -eq 0)
    {
        Write-Host "ResumeFailedOnly: no failed subscriptions in resume state. Nothing to retry." -ForegroundColor Green
        Write-Host ("If you expected failures here, verify {0} has a non-empty FailedAttempts array." -f $ResumeStateFile) -ForegroundColor DarkGray
        Exit-Wrapper -Code 0
    }
    $FailedIds = @($FailedAttempts | ForEach-Object { $_.Id })
    $BeforeCount = $Subscriptions.Count
    $Subscriptions = @($Subscriptions | Where-Object { $FailedIds -contains $_.Id })
    Write-Host ("ResumeFailedOnly: filtered to {0} previously-failed subscription(s) (was {1})." -f $Subscriptions.Count, $BeforeCount) -ForegroundColor Cyan
    if ($Subscriptions.Count -eq 0)
    {
        Write-Host "WARNING: FailedAttempts list contained IDs but none are visible in the current subscription set. Verify access and -IncludeDisabled flag matches the prior run." -ForegroundColor Yellow
        Exit-Wrapper -Code 0
    }
}

Write-Host "Verifying full subscription coverage (tenant-root management group)..." -ForegroundColor Cyan
$PreflightCoverageMsg = $null
$Coverage = Get-TenantSubscriptionId -TenantId $TenantID
if ($null -eq $Coverage.Ids)
{
    $PreflightCoverageMsg = $CoverageMsg = ("Could not verify full subscription coverage: the tenant-root management group (GroupName = tenant id) could not be read by this identity, so there is no way to confirm the {0} enumerated subscription(s) are ALL of them." -f $AllSubscriptions.Count)
    if ($AllowPartialAccess -or $Preflight)
    {
        Write-Host ("WARNING: {0}" -f $CoverageMsg) -ForegroundColor Yellow
        if (-not [string]::IsNullOrWhiteSpace($Coverage.Detail)) { Write-Host ("  Reason: {0}" -f $Coverage.Detail) -ForegroundColor DarkYellow }
        Write-Host "  -AllowPartialAccess set: continuing with the enumerated subscription(s), which may not be the full tenant." -ForegroundColor Yellow
    }
    else
    {
        Write-Host ("ERROR: {0}" -f $CoverageMsg) -ForegroundColor Red
        if (-not [string]::IsNullOrWhiteSpace($Coverage.Detail)) { Write-Host ("  Reason: {0}" -f $Coverage.Detail) -ForegroundColor Red }
        Write-Host "  Grant the identity Reader at the tenant-root management group (it inherits to every subscription and makes coverage verifiable), then re-run." -ForegroundColor Red
        Write-Host "  (Or pass -AllowPartialAccess to proceed with only the subscriptions this identity can currently see.)" -ForegroundColor Red
        Exit-Wrapper -Code 1
    }
}
else
{
    $AccessibleIdSet = @{}
    foreach ($S in $AllSubscriptions) { $AccessibleIdSet[([string]$S.Id).ToLowerInvariant()] = $true }
    $MissedIds = @($Coverage.Ids | Where-Object { -not $AccessibleIdSet.ContainsKey(([string]$_).ToLowerInvariant()) })
    if ($MissedIds.Count -gt 0)
    {
        $ShownMissed = @($MissedIds | Select-Object -First 10)
        $MoreNote = if ($MissedIds.Count -gt $ShownMissed.Count) { (' (+{0} more)' -f ($MissedIds.Count - $ShownMissed.Count)) } else { '' }
        $PreflightCoverageMsg = $CoverageMsg = ("Subscription coverage shortfall: the tenant-root management group contains {0} subscription(s) but this identity can enumerate only {1} - {2} would be SILENTLY MISSED from the inventory." -f $Coverage.Ids.Count, $AllSubscriptions.Count, $MissedIds.Count)
        if ($AllowPartialAccess -or $Preflight)
        {
            Write-Host ("WARNING: {0}" -f $CoverageMsg) -ForegroundColor Yellow
            Write-Host ("  Missed: {0}{1}" -f ($ShownMissed -join ', '), $MoreNote) -ForegroundColor DarkYellow
            Write-Host ("  -AllowPartialAccess set: continuing with the {0} visible subscription(s)." -f $AllSubscriptions.Count) -ForegroundColor Yellow
        }
        else
        {
            Write-Host ("ERROR: {0}" -f $CoverageMsg) -ForegroundColor Red
            Write-Host ("  Missed: {0}{1}" -f ($ShownMissed -join ', '), $MoreNote) -ForegroundColor Red
            Write-Host "  Grant the identity Reader at the tenant-root management group (it inherits to all subscriptions) instead of per-subscription, then re-run." -ForegroundColor Red
            Write-Host "  (Or pass -AllowPartialAccess to proceed with only the subscriptions this identity can currently see.)" -ForegroundColor Red
            Exit-Wrapper -Code 1
        }
    }
    else
    {
        Write-Host ("  Coverage verified: all {0} subscription(s) under the tenant-root management group are visible to this identity." -f $Coverage.Ids.Count) -ForegroundColor Green
    }
}

$ScopeForProbe = if ($Resume) { @($Subscriptions | Where-Object { -not ($CompletedIds -contains $_.Id) }) } else { @($Subscriptions) }
if ($ScopeForProbe.Count -gt 0)
{
    Write-Host ("Verifying subscription access up front for {0} subscription(s)..." -f $ScopeForProbe.Count) -ForegroundColor Cyan
    $AccessProbed = Test-SubscriptionAccessAll -Subscriptions $ScopeForProbe
    $AccessDecision = Resolve-AccessPreflight -Probed $AccessProbed -AllowPartialAccess:$AllowPartialAccess
    if ($AccessDecision.Inaccessible.Count -gt 0)
    {
        Write-Host ("  {0} subscription(s) are NOT readable by the signed-in identity:" -f $AccessDecision.Inaccessible.Count) -ForegroundColor Red
        foreach ($NA in $AccessDecision.Inaccessible)
        {
            $Label = if ($NA.State -eq 'Unknown') { 'access probe inconclusive after retries' } else { 'no role on the subscription' }
            Write-Host ("    - {0} ({1}) - {2}" -f $NA.Name, $NA.Id, $Label) -ForegroundColor Red
        }
        if ($AccessDecision.ShouldBlock -and -not $Preflight)
        {
            Write-Host "  Stopping before any work. Grant the identity Reader on these subscriptions, then re-run." -ForegroundColor Red
            Write-Host "  (Or pass -AllowPartialAccess to skip them and inventory only the accessible subscriptions.)" -ForegroundColor Red
            Exit-Wrapper -Code 1
        }
        if ($Preflight) { Write-Host "  -Preflight: continuing so the permission matrix can report these subscriptions." -ForegroundColor Yellow }
        else { Write-Host "  -AllowPartialAccess set: skipping the above and continuing with the accessible subscription(s)." -ForegroundColor Yellow }
        $PreflightInaccessible = @($AccessDecision.Inaccessible)
        $Subscriptions = @($Subscriptions | Where-Object { $AccessDecision.InaccessibleIds -notcontains $_.Id })
        if ($Subscriptions.Count -eq 0 -and -not $Preflight)
        {
            Write-Host "No accessible subscriptions remain in scope; nothing to process." -ForegroundColor Yellow
            Exit-Wrapper -Code 1
        }
    }
    else
    {
        Write-Host ("  Access verified: all {0} in-scope subscription(s) are readable." -f $ScopeForProbe.Count) -ForegroundColor Green
    }
}

if ($Preflight)
{
    Write-Host ""
    Write-Host ("Preflight: probing data-phase permissions on {0} subscription(s)..." -f $Subscriptions.Count) -ForegroundColor Cyan
    $PreflightOriginalContext = Get-AzContext -ErrorAction SilentlyContinue
    $MatrixRows = @()
    if ($PreflightInaccessible)
    {
        $MatrixRows += foreach ($NA in $PreflightInaccessible)
        {
            $ReaderState = if ($NA.State -eq 'Unknown') { 'Unavailable' } else { 'Denied' }
            [pscustomobject]@{ Name = $NA.Name; Id = $NA.Id; Reader = $ReaderState; CostManagement = 'Skipped'; Monitoring = 'Skipped' }
        }
    }
    $MatrixRows += foreach ($PfSub in $Subscriptions)
    {
        $ReaderState = 'Ok'
        $CostState = 'Skipped'
        if (-not $SkipConsumption)
        {
            $CostProbe = Test-ConsumptionAccess -SubscriptionId $PfSub.Id
            $CostState = $CostProbe.Outcome
            if ($CostProbe.Detail) { Write-Verbose ("[preflight] consumption {0}: {1}" -f $PfSub.Name, $CostProbe.Detail) }
        }
        $MonState = 'Skipped'
        if (-not $SkipMetrics)
        {
            $MonProbe = Test-MetricsAccess -SubscriptionId $PfSub.Id
            $MonState = $MonProbe.Outcome
            if ($MonProbe.Detail) { Write-Verbose ("[preflight] metrics {0}: {1}" -f $PfSub.Name, $MonProbe.Detail) }
        }
        [pscustomobject]@{ Name = $PfSub.Name; Id = $PfSub.Id; Reader = $ReaderState; CostManagement = $CostState; Monitoring = $MonState }
    }
    if ($PreflightOriginalContext) { try { $null = Set-AzContext -Context $PreflightOriginalContext -ErrorAction Stop } catch { Write-Verbose "[preflight] could not restore the original Az context" } }
    $Matrix = Format-PreflightMatrix -Rows @($MatrixRows)
    $CoverageBlocking = $false
    if ($PreflightCoverageMsg)
    {
        $CoverageBlocking = $true
        Write-Host ""
        Write-Host ("Coverage: {0}" -f $PreflightCoverageMsg) -ForegroundColor Red
        Write-Host "  A real run stops here unless -AllowPartialAccess is passed. Grant Reader at the tenant-root management group to make coverage verifiable." -ForegroundColor Red
    }
    if ($Subscriptions.Count -eq 0) { Write-Host "  (no subscription passed the Reader gate, so the data-phase columns could not be probed)" -ForegroundColor Yellow }
    Write-Host ""
    foreach ($Line in $Matrix.Lines) { Write-Host $Line -ForegroundColor $(if ($Line -match 'Denied') { 'Red' } else { 'Gray' }) }
    Write-Host ""
    if ($Matrix.Blocking -or $CoverageBlocking)
    {
        Write-Host "Preflight result: at least one requested permission is DENIED or coverage could not be verified. Fix the roles above (or pass the matching -Skip* switch), then run without -Preflight." -ForegroundColor Red
        Exit-Wrapper -Code 1
    }
    Write-Host "Preflight result: no denials. Nothing was collected; run again without -Preflight to start the inventory." -ForegroundColor Green
    Exit-Wrapper -Code 0
}

if (-not $SkipConsumption -and $Subscriptions.Count -gt 0)
{
    $ConsumptionProbeSub = $Subscriptions[0]
    Write-Host ("Verifying consumption (billing) access using subscription '{0}'..." -f $ConsumptionProbeSub.Name) -ForegroundColor Cyan
    $ConsumptionAccess = Test-ConsumptionAccess -SubscriptionId $ConsumptionProbeSub.Id
    if ($ConsumptionAccess.Outcome -eq 'Denied')
    {
        Write-Host ""
        Write-Host "ERROR: Consumption data was requested (no -SkipConsumption), but the signed-in identity is not authorized to read consumption/billing data." -ForegroundColor Red
        Write-Host ("Probed subscription: {0}" -f $ConsumptionProbeSub.Name) -ForegroundColor Red
        if (-not [string]::IsNullOrWhiteSpace($ConsumptionAccess.Detail))
        {
            Write-Host ("Reason: {0}" -f $ConsumptionAccess.Detail) -ForegroundColor Red
        }
        Write-Host "Grant this identity 'Cost Management Reader' (or 'Billing Reader' on the billing scope), or re-run with -SkipConsumption to inventory without billing data." -ForegroundColor Yellow
        Exit-Wrapper -Code 1
    }
    elseif ($ConsumptionAccess.Outcome -eq 'Unavailable')
    {
        Write-Host "WARNING: Could not verify consumption access up front (a transient/token issue, not an authorization denial). Continuing; per-subscription consumption health is reported at the end of the run." -ForegroundColor Yellow
        if (-not [string]::IsNullOrWhiteSpace($ConsumptionAccess.Detail))
        {
            Write-Host ("  Probe error (why it could not be verified): {0}" -f $ConsumptionAccess.Detail) -ForegroundColor DarkYellow
        }
    }
    else
    {
        Write-Host "Consumption access confirmed." -ForegroundColor Green
    }
}

if ($UploadToBlobContainerUri)
{
    Write-Host "Verifying blob-upload write access..." -ForegroundColor Cyan
    $BlobProbeFile = $null
    $BlobProbeContext = $null
    $BlobProbeName = $null
    $BlobProbeContainer = $null
    $BlobProbeWritten = $false
    try
    {
        $BlobProbeParts = Split-BlobContainerUri -Uri $UploadToBlobContainerUri
        $BlobProbeAccount = $BlobProbeParts.Account
        $BlobProbeContainer = $BlobProbeParts.Container
        $BlobProbePrefix = $BlobProbeParts.Prefix

        $BlobProbeName = '{0}_rda-upload-probe/{1}.txt' -f $BlobProbePrefix, ([guid]::NewGuid().ToString('N'))
        $BlobProbeFile = Join-Path ([System.IO.Path]::GetTempPath()) ('rda-upload-probe-{0}.txt' -f ([guid]::NewGuid().ToString('N')))
        Set-Content -LiteralPath $BlobProbeFile -Value 'rda upload access probe' -Encoding UTF8

        $BlobProbeContext = New-AzStorageContext -StorageAccountName $BlobProbeAccount -UseConnectedAccount -ErrorAction Stop
        $null = Set-AzStorageBlobContent -File $BlobProbeFile -Container $BlobProbeContainer -Blob $BlobProbeName -Context $BlobProbeContext -Force -ErrorAction Stop
        $BlobProbeWritten = $true
        Write-Host ("Blob-upload access confirmed (wrote a probe blob in {0}/{1})." -f $BlobProbeAccount, $BlobProbeContainer) -ForegroundColor Green
    }
    catch
    {
        $BlobProbeErr = $_.Exception.Message
        if ($BlobProbeErr -match 'AuthorizationPermissionMismatch|AuthorizationFailure|AuthorizationFailed|\b403\b|Forbidden|not authorized|does not have|ContainerNotFound|\b404\b|does not exist')
        {
            Write-Host ""
            Write-Host "ERROR: Blob upload was requested (-UploadToBlobContainerUri), but the target container could not be written to (missing 'Storage Blob Data Contributor' role, or the container does not exist)." -ForegroundColor Red
            Write-Host ("Reason: {0}" -f $BlobProbeErr) -ForegroundColor Red
            Write-Host "Grant this identity 'Storage Blob Data Contributor' and verify the storage account/container name is correct, or re-run without -UploadToBlobContainerUri to keep each zip node-local." -ForegroundColor Yellow
            Exit-Wrapper -Code 1
        }
        else
        {
            Write-Host "WARNING: Could not verify blob-upload access up front (a transient/token issue, not an authorization denial). Continuing; the upload at the end of the run is best-effort and will warn if it fails." -ForegroundColor Yellow
            Write-Host ("  Probe error (why it could not be verified): {0}" -f $BlobProbeErr) -ForegroundColor DarkYellow
        }
    }
    finally
    {
        if ($BlobProbeWritten -and $BlobProbeContext -and $BlobProbeName -and $BlobProbeContainer)
        {
            Remove-AzStorageBlob -Container $BlobProbeContainer -Blob $BlobProbeName -Context $BlobProbeContext -Force -ErrorAction SilentlyContinue
        }
        if ($BlobProbeFile -and (Test-Path -LiteralPath $BlobProbeFile)) { Remove-Item -LiteralPath $BlobProbeFile -Force -ErrorAction SilentlyContinue }
    }
}

$AutoTune = Get-RecommendedParallelism
$StreamsAuto = -not $PSBoundParameters.ContainsKey('ParallelStreams')
$ConcurrencyAuto = -not $PSBoundParameters.ContainsKey('ConcurrencyLimit')
if ($StreamsAuto) { $ParallelStreams = $AutoTune.Streams }
if ($ConcurrencyAuto) { $ConcurrencyLimit = $AutoTune.Concurrency }

if ($HeadRoom -gt 0)
{
    $ConcurrencyBeforeHeadroom = $ConcurrencyLimit
    $ConcurrencyLimit = Get-HeadroomAdjustedConcurrency -Concurrency $ConcurrencyLimit -HeadRoomPercent $HeadRoom
    Write-Host ("API headroom: -HeadRoom {0} -> ConcurrencyLimit {1} -> {2} (leaving ~{0}% of concurrency in reserve for other workloads)." -f $HeadRoom, $ConcurrencyBeforeHeadroom, $ConcurrencyLimit) -ForegroundColor DarkGray
}

$RamLabel = if ($AutoTune.RamGB -gt 0) { '{0} GB RAM' -f $AutoTune.RamGB.ToString([cultureinfo]::InvariantCulture) } else { 'RAM undetected' }
$StreamsSrc = if ($StreamsAuto) { 'auto' } else { 'explicit' }
$ConcurrencySrc = if ($ConcurrencyAuto) { 'auto' } else { 'explicit' }
if ($HeadRoom -gt 0) { $ConcurrencySrc = '{0}, -HeadRoom {1}' -f $ConcurrencySrc, $HeadRoom }
Write-Host ("Host: {0} vCPU / {1}." -f $AutoTune.VCpu, $RamLabel) -ForegroundColor DarkGray
Write-Host ("Parallelism: -ParallelStreams {0} ({1}), -ConcurrencyLimit {2} ({3}). Pass either flag to override." -f $ParallelStreams, $StreamsSrc, $ConcurrencyLimit, $ConcurrencySrc) -ForegroundColor DarkGray

if ($ParallelStreams -gt 1 -and -not (Test-BackgroundJobSupport))
{
    Write-Host ""
    Write-Host "WARNING: PowerShell background jobs (Start-Job) are unavailable in this session." -ForegroundColor Yellow
    Write-Host "         This host enforces a system-wide language-mode / application-control policy" -ForegroundColor Yellow
    Write-Host "         (WDAC / AppLocker) that is incompatible with Start-Job, so parallel streams" -ForegroundColor Yellow
    Write-Host "         cannot launch here. Falling back to the SEQUENTIAL path (one subscription at a" -ForegroundColor Yellow
    Write-Host "         time). The report content is identical - only slower. Pass -ParallelStreams 1" -ForegroundColor Yellow
    Write-Host "         explicitly to select the sequential path up front and silence this notice." -ForegroundColor Yellow
    Write-Host ""
    $ParallelStreams = 1
}

$Service = Expand-ServiceFilter -Service $Service
if ($Service.Count -gt 0)
{
    $AvailableServices = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Services') -Filter '*.ps1' -Recurse | ForEach-Object { $_.BaseName } | Sort-Object -Unique)
    $UnknownServices = @($Service | Where-Object { $_ -notin $AvailableServices })
    if ($UnknownServices.Count -gt 0)
    {
        Write-Host ("ERROR: -Service contains unknown collector name(s): [{0}]." -f ($UnknownServices -join ', ')) -ForegroundColor Red
        Write-Host ("Valid collector names: [{0}]" -f ($AvailableServices -join ', ')) -ForegroundColor Yellow
        Exit-Wrapper -Code 1
    }
    Write-Host ("Service filter active: collecting ONLY [{0}] across all in-scope subscriptions." -f ($Service -join ', ')) -ForegroundColor Cyan

    $UnscopedPhases = @()
    $SuggestedSkips = @()

    if (-not $SkipMetrics.IsPresent)
    {
        $UnscopedPhases += 'metrics'
        $SuggestedSkips += '-SkipMetrics'
    }

    if (-not $SkipConsumption.IsPresent)
    {
        $UnscopedPhases += 'consumption'
        $SuggestedSkips += '-SkipConsumption'
    }

    if (@($UnscopedPhases).Count -gt 0)
    {
        Write-Warning ("-Service scopes the INVENTORY phase only; these phases still run for the WHOLE subscription, for every subscription in scope: {0}. For a clean inventory-only run add {1}. (Ignore this if you are deliberately re-collecting for a later Merge-RecoveryData.)" -f ($UnscopedPhases -join ', '), ($SuggestedSkips -join ' '))
    }
}

$InventoryPassthrough = @{}
if ($DeviceLogin) { $InventoryPassthrough['DeviceLogin'] = $true }
if ($Obfuscate) { $InventoryPassthrough['Obfuscate'] = $true }
if ($SkipMetrics) { $InventoryPassthrough['SkipMetrics'] = $true }
if ($SkipConsumption) { $InventoryPassthrough['SkipConsumption'] = $true }
if ($SkipMarketplace) { $InventoryPassthrough['SkipMarketplace'] = $true }
if ($UseMetricsBatch) { $InventoryPassthrough['UseMetricsBatch'] = $true }
if ($IncludeStorageMetrics) { $InventoryPassthrough['IncludeStorageMetrics'] = $true }
if ($SkipDiskMetrics) { $InventoryPassthrough['SkipDiskMetrics'] = $true }
if ($MetricsDetailed) { $InventoryPassthrough['MetricsDetailed'] = $true }
if ($CapacityPlan) { $InventoryPassthrough['CapacityPlan'] = $true }
if ($MetricsIntervalMinutes -gt 0) { $InventoryPassthrough['MetricsIntervalMinutes'] = $MetricsIntervalMinutes }
if ($PSBoundParameters.ContainsKey('MetricsLookbackDays')) { $InventoryPassthrough['MetricsLookbackDays'] = $MetricsLookbackDays }
if ($Service.Count -gt 0) { $InventoryPassthrough['Service'] = $Service }
$InventoryPassthrough['ConcurrencyLimit'] = $ConcurrencyLimit
if ($PSBoundParameters.ContainsKey('Debug')) { $InventoryPassthrough['Debug'] = [bool]$PSBoundParameters['Debug'] }

$SkippedCount = 0
$DiagFile = $null
$SubResourceCounts = @()

$EligibleCount = @($Subscriptions).Count

if ($ParallelStreams -le 1)
{
    # === SEQUENTIAL PATH (default) ============================================
    $SubTotal = @($Subscriptions).Count
    $SubIndex = 0
    foreach ($Sub in $Subscriptions)
    {
        $SubIndex++
        Write-RdaProgress -Activity 'Processing subscriptions' -CurrentItem $Sub.Name -Index $SubIndex -Total $SubTotal
        if ($Resume -and ($CompletedIds -contains $Sub.Id))
        {
            Write-Host ("Skipping (already completed): {0} ({1})" -f $Sub.Name, $Sub.Id) -ForegroundColor DarkGray
            $SkippedCount++
            continue
        }

        Write-Host "Processing subscription: $($Sub.Name) ($($Sub.Id))" -ForegroundColor Cyan

        try
        {
            $global:LASTEXITCODE = 0
            $Global:ZipOutputFile = $null
            & (Join-Path $PSScriptRoot "ResourceInventory.ps1") -TenantID $TenantID -SubscriptionID $Sub.Id @InventoryPassthrough -RunAllSubs
            if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0)
            {
                if ($LASTEXITCODE -eq 2) { $ArchiveWriteFailures += ("{0} ({1})" -f $Sub.Name, $Sub.Id) }
                throw "Script exited with code $LASTEXITCODE"
            }

            $ResCount = if ($null -ne $Global:Resources) { @($Global:Resources).Count } else { 0 }
            $SubResourceCounts += [pscustomobject]@{
                Name  = $Sub.Name
                Id    = $Sub.Id
                Count = $ResCount
                Zip   = $Global:ZipOutputFile
            }

            if ($ResCount -eq 0)
            {
                Write-Host ("WARNING: Subscription '{0}' returned 0 resources. Likely permission gap (no Reader on the subscription) or a genuinely empty subscription. Verify with: Search-AzGraph -Query 'resources | summarize count()' -Subscription {1}" -f $Sub.Name, $Sub.Id) -ForegroundColor Yellow
            }
            else
            {
                Write-Host ("Resources collected: {0:N0}" -f $ResCount) -ForegroundColor DarkGreen
            }

            Write-Host "Completed subscription: $($Sub.Name)" -ForegroundColor Green

            $StateChanged = $false
            if (-not ($CompletedIds -contains $Sub.Id))
            {
                $CompletedIds += $Sub.Id
                $StateChanged = $true
            }
            $BeforeFailedCount = @($FailedAttempts).Count
            $FailedAttempts = Remove-FailedAttempt -Existing $FailedAttempts -Id $Sub.Id
            if (@($FailedAttempts).Count -ne $BeforeFailedCount) { $StateChanged = $true }
            if ($StateChanged)
            {
                Save-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID -Ids $CompletedIds -FailedAttempts $FailedAttempts @StateSaveArgs
            }
        }
        catch
        {
            $ErrRecord = $_
            Write-Host "ERROR processing subscription $($Sub.Name): $ErrRecord" -ForegroundColor Red

            $DiagLines = @()
            $DiagLines += "==== Failure for subscription: $($Sub.Name) ($($Sub.Id)) ===="
            $DiagLines += "Timestamp: $(Get-Date -Format 'o')"
            $DiagLines += "Message:   $($ErrRecord.Exception.Message)"
            $DiagLines += "Type:      $($ErrRecord.Exception.GetType().FullName)"

            $Inner = $ErrRecord.Exception.InnerException
            $Depth = 0
            while ($null -ne $Inner -and $Depth -lt 5)
            {
                $DiagLines += "Inner[$Depth] Type:    $($Inner.GetType().FullName)"
                $DiagLines += "Inner[$Depth] Message: $($Inner.Message)"
                $Inner = $Inner.InnerException
                $Depth++
            }

            if ($null -ne $ErrRecord.InvocationInfo)
            {
                $DiagLines += "ScriptName:    $($ErrRecord.InvocationInfo.ScriptName)"
                $DiagLines += "Line:          $($ErrRecord.InvocationInfo.ScriptLineNumber)"
                $DiagLines += "PositionMsg:   $($ErrRecord.InvocationInfo.PositionMessage)"
            }

            $DiagLines += "StackTrace:"
            $DiagLines += $ErrRecord.ScriptStackTrace
            if ($null -ne $ErrRecord.Exception.StackTrace)
            {
                $DiagLines += "ExceptionStackTrace:"
                $DiagLines += $ErrRecord.Exception.StackTrace
            }

            try
            {
                $Proc = Get-Process -Id $PID
                $DiagLines += "Process WorkingSet (MB):  $([math]::Round($Proc.WorkingSet64 / 1MB, 1))"
                $DiagLines += "Process PrivateMemory (MB): $([math]::Round($Proc.PrivateMemorySize64 / 1MB, 1))"
            }
            catch { Write-Verbose ("Process snapshot failed: {0}" -f $_.Exception.Message) }

            try
            {
                $DiagRoot = if (-not [string]::IsNullOrWhiteSpace($env:RDA_INVENTORY_ROOT)) { $env:RDA_INVENTORY_ROOT } else { $InventoryRoot }
                if (-not [string]::IsNullOrWhiteSpace($DiagRoot) -and (Test-Path -LiteralPath $DiagRoot))
                {
                    $RootDrive = (Get-Item -LiteralPath $DiagRoot).PSDrive
                    if ($RootDrive)
                    {
                        $DiagLines += "Free disk on $($RootDrive.Name): (MB): $([math]::Round($RootDrive.Free / 1MB, 1))"
                    }
                }
            }
            catch { Write-Verbose ("Disk snapshot failed: {0}" -f $_.Exception.Message) }

            $DiagLines += ""

            if ($null -eq $DiagFile)
            {
                $FailRoot = if (-not [string]::IsNullOrWhiteSpace($env:RDA_INVENTORY_ROOT)) { $env:RDA_INVENTORY_ROOT } else { $InventoryRoot }
                if ([string]::IsNullOrWhiteSpace($FailRoot))
                {
                    $Resolved = Get-RdaInventoryRoot
                    if ($Resolved.Ok) { $FailRoot = $Resolved.Path }
                }
                if (-not [string]::IsNullOrWhiteSpace($FailRoot) -and -not (Test-Path -LiteralPath $FailRoot))
                {
                    try { New-Item -ItemType Directory -Path $FailRoot -Force -ErrorAction Stop | Out-Null }
                    catch { Write-Host ("WARNING: could not create {0} for the failures log: {1}" -f $FailRoot, $_.Exception.Message) -ForegroundColor Yellow }
                }
                $DiagFile = Join-Path $FailRoot ("RunAllSubscriptions_failures_{0}_{1}.log" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss-fff'), [guid]::NewGuid().ToString().Substring(0, 4))
            }
            try { $DiagLines | Out-File -LiteralPath $DiagFile -Append -Encoding utf8 }
            catch { Write-Verbose ("DiagFile write failed at {0}: {1}" -f $DiagFile, $_.Exception.Message) }

            $FailedSubscriptions += $Sub.Name
            $FailedAttempts = Add-FailedAttempt -Existing $FailedAttempts `
                -Id $Sub.Id -Name $Sub.Name `
                -Reason $ErrRecord.Exception.Message
            Save-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID -Ids $CompletedIds -FailedAttempts $FailedAttempts @StateSaveArgs
        }

        Write-Host "-----------------------------------" -ForegroundColor Gray
    }

    Write-RdaProgress -Activity 'Processing subscriptions' -Completed

}
else
{
    # === PARALLEL-STREAMS PATH: each "stream" is a separate `pwsh` background job (Start-Job runs the ScriptBlock in a fresh process). Process-level isolation is what makes this safe - the inner script's Set-AzContext -Subscription (consumption phase) mutates PROCESS-GLOBAL Az state, so two streams in one process would race contexts and silently cross-contaminate consumption data.

    $StreamCount = [Math]::Min($ParallelStreams, $Subscriptions.Count)
    Write-Host ""
    Write-Host ("Parallel-streams mode: {0} streams across {1} eligible subscription(s)" -f $StreamCount, $Subscriptions.Count) -ForegroundColor Cyan
    if ($ParallelStreams -gt $Subscriptions.Count)
    {
        Write-Host ("Note: -ParallelStreams {0} clamped to {1} (one stream per subscription is the practical limit)." -f $ParallelStreams, $StreamCount) -ForegroundColor DarkGray
    }
    Write-Host "Each stream is a separate pwsh background job with its own Az context and resume-state file." -ForegroundColor DarkGray
    Write-Host ""

    if ($StreamCount -le 1)
    {
        Write-Host "Only one eligible subscription; running sequentially." -ForegroundColor Yellow
        if ($Subscriptions.Count -gt 0)
        {
            $Sub = $Subscriptions[0]
            Write-Host "Processing subscription: $($Sub.Name) ($($Sub.Id))" -ForegroundColor Cyan
            try
            {
                $global:LASTEXITCODE = 0
                $Global:ZipOutputFile = $null
                & (Join-Path $PSScriptRoot "ResourceInventory.ps1") -TenantID $TenantID -SubscriptionID $Sub.Id @InventoryPassthrough -RunAllSubs
                if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0)
                {
                    if ($LASTEXITCODE -eq 2) { $ArchiveWriteFailures += ("{0} ({1})" -f $Sub.Name, $Sub.Id) }
                    throw "Script exited with code $LASTEXITCODE"
                }
                $ResCount = if ($null -ne $Global:Resources) { @($Global:Resources).Count } else { 0 }
                $SubResourceCounts += [pscustomobject]@{ Name = $Sub.Name; Id = $Sub.Id; Count = $ResCount; Zip = $Global:ZipOutputFile }
                if ($ResCount -eq 0)
                {
                    Write-Host ("WARNING: '{0}' returned 0 resources." -f $Sub.Name) -ForegroundColor Yellow
                }
                else
                {
                    Write-Host ("Resources collected: {0:N0}" -f $ResCount) -ForegroundColor DarkGreen
                }
                if (-not ($CompletedIds -contains $Sub.Id))
                {
                    $CompletedIds += $Sub.Id
                    $FailedAttempts = Remove-FailedAttempt -Existing $FailedAttempts -Id $Sub.Id
                    Save-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID -Ids $CompletedIds -FailedAttempts $FailedAttempts @StateSaveArgs
                }
            }
            catch
            {
                $ErrRecord = $_
                Write-Host ("ERROR processing subscription {0}: {1}" -f $Sub.Name, $ErrRecord) -ForegroundColor Red
                $DiagLines = @()
                $DiagLines += "==== Failure for subscription: $($Sub.Name) ($($Sub.Id)) ===="
                $DiagLines += "Timestamp: $(Get-Date -Format 'o')"
                $DiagLines += "Message:   $($ErrRecord.Exception.Message)"
                $DiagLines += "Type:      $($ErrRecord.Exception.GetType().FullName)"
                $DiagLines += "StackTrace:"
                $DiagLines += $ErrRecord.ScriptStackTrace
                $DiagLines += ""
                if ($null -eq $DiagFile)
                {
                    $DiagFile = Join-Path $InventoryRoot ("RunAllSubscriptions_failures_{0}_{1}.log" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss-fff'), [guid]::NewGuid().ToString().Substring(0, 4))
                }
                try { $DiagLines | Out-File -LiteralPath $DiagFile -Append -Encoding utf8 }
                catch { Write-Verbose ("DiagFile write failed at {0}: {1}" -f $DiagFile, $_.Exception.Message) }
                $FailedSubscriptions += $Sub.Name
                $FailedAttempts = Add-FailedAttempt -Existing $FailedAttempts `
                    -Id $Sub.Id -Name $Sub.Name `
                    -Reason $ErrRecord.Exception.Message
                Save-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID -Ids $CompletedIds -FailedAttempts $FailedAttempts @StateSaveArgs
            }
        }
        $StreamCount = 0
    }
    if ($StreamCount -ge 2)
    {

        $AzContextSnapshot = Join-Path $InventoryRoot (".rda-stream-azcontext-{0}.json" -f ([guid]::NewGuid().ToString()))
        try
        {
            Save-AzContext -Path $AzContextSnapshot -Force -ErrorAction Stop | Out-Null
        }
        catch
        {
            Write-Host ("ERROR: could not snapshot Az context for stream workers: {0}" -f $_.Exception.Message) -ForegroundColor Red
            Write-Host "Re-run without -ParallelStreams to use the sequential code path." -ForegroundColor Yellow
            if (Test-Path -LiteralPath $AzContextSnapshot)
            {
                try { Remove-Item -LiteralPath $AzContextSnapshot -Force }
                catch { Write-Verbose ("Could not remove partial Az context snapshot: {0}" -f $_.Exception.Message) }
            }
            Exit-Wrapper -Code 1
        }

        $Jobs = @()
        $StreamSummaries = @()
        try
        {
            $WorkerScript = Join-Path $PSScriptRoot 'Run-AllSubscriptions.Stream.ps1'
            if (-not (Test-Path -LiteralPath $WorkerScript -PathType Leaf))
            {
                Write-Host ("ERROR: parallel worker script not found at {0}." -f $WorkerScript) -ForegroundColor Red
                Write-Host "Make sure Run-AllSubscriptions.Stream.ps1 is present alongside Run-AllSubscriptions.ps1, or re-run without -ParallelStreams." -ForegroundColor Yellow
                Exit-Wrapper -Code 1
            }

            $Slices = @()
            for ($i = 0; $i -lt $StreamCount; $i++)
            {
                $Slices += , (New-Object 'System.Collections.Generic.List[object]')
            }
            for ($i = 0; $i -lt $Subscriptions.Count; $i++)
            {
                $Slices[$i % $StreamCount].Add($Subscriptions[$i])
            }

            for ($S = 0; $S -lt $StreamCount; $S++)
            {
                $SliceList = $Slices[$S]
                $SliceIds = @($SliceList | ForEach-Object { $_.Id })
                $SliceNames = @($SliceList | ForEach-Object { $_.Name })

                $SummaryPath = Join-Path $InventoryRoot (".rda-stream-{0}-summary.json" -f $S)
                $FailuresPath = Join-Path $InventoryRoot ("RunAllSubscriptions_failures_{0}_stream-{1}.log" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'), $S)

                $StreamSummaries += [pscustomobject]@{
                    StreamId     = $S
                    SummaryPath  = $SummaryPath
                    FailuresPath = $FailuresPath
                    SubCount     = $SliceList.Count
                }

                Write-Host ("[stream-{0}] queued: {1} subscription(s)" -f $S, $SliceList.Count) -ForegroundColor DarkCyan

                $WorkerArgs = @{
                    TenantID           = $TenantID
                    StreamId           = [string]$S
                    InventoryRoot      = $InventoryRoot
                    ScriptRoot         = $PSScriptRoot
                    AzContextPath      = $AzContextSnapshot
                    StreamSummaryPath  = $SummaryPath
                    StreamFailuresPath = $FailuresPath
                    SubscriptionIds    = $SliceIds
                    SubscriptionNames  = $SliceNames
                    ConcurrencyLimit   = $ConcurrencyLimit
                }
                if ($Resume) { $WorkerArgs.Resume = $true }
                if ($ResumeFailedOnly) { $WorkerArgs.ResumeFailedOnly = $true }
                if ($DeviceLogin) { $WorkerArgs.DeviceLogin = $true }
                if ($Obfuscate) { $WorkerArgs.Obfuscate = $true }
                if ($SkipMetrics) { $WorkerArgs.SkipMetrics = $true }
                if ($SkipConsumption) { $WorkerArgs.SkipConsumption = $true }
                if ($SkipMarketplace) { $WorkerArgs.SkipMarketplace = $true }
                if ($UseMetricsBatch) { $WorkerArgs.UseMetricsBatch = $true }
                if ($IncludeStorageMetrics) { $WorkerArgs.IncludeStorageMetrics = $true }
                if ($SkipDiskMetrics) { $WorkerArgs.SkipDiskMetrics = $true }
                if ($MetricsDetailed) { $WorkerArgs.MetricsDetailed = $true }
                if ($CapacityPlan) { $WorkerArgs.CapacityPlan = $true }
                if ($MetricsIntervalMinutes -gt 0) { $WorkerArgs.MetricsIntervalMinutes = $MetricsIntervalMinutes }
                if ($PSBoundParameters.ContainsKey('MetricsLookbackDays')) { $WorkerArgs.MetricsLookbackDays = $MetricsLookbackDays }
                if ($Service.Count -gt 0) { $WorkerArgs.Service = $Service }
                if ($PSBoundParameters.ContainsKey('Debug')) { $WorkerArgs.Debug = [bool]$PSBoundParameters['Debug'] }
                if ($StateBlobContainerUri)
                {
                    $WorkerArgs.StateBlobContainerUri = $StateBlobContainerUri
                    $WorkerArgs.ShardIndex = $ShardIndex
                    $WorkerArgs.ShardCount = $ShardCount
                }

                $Jobs += Start-Job -ScriptBlock {
                    param($WorkerScript, $WorkerArgs)
                    & $WorkerScript @WorkerArgs
                } -ArgumentList @($WorkerScript, $WorkerArgs)
            }

            Write-Host ""
            Write-Host "All streams launched. Streaming output (lines prefixed [stream-N]):" -ForegroundColor Green
            Write-Host ""
            Write-Host ("Note: per-stream tags only prefix the wrapper's narration. The inner script's") -ForegroundColor DarkGray
            Write-Host ("Write-Host/Write-Log output is unprefixed and will interleave across streams.") -ForegroundColor DarkGray
            Write-Host ""
            $Jobs | Receive-Job
            while (@($Jobs | Where-Object { $_.State -eq 'Running' }).Count -gt 0)
            {
                $Jobs | Receive-Job
                Start-Sleep -Milliseconds 1500
            }
            $Jobs | Receive-Job

            foreach ($j in $Jobs)
            {
                if ($j.State -ne 'Completed')
                {
                    Write-Host ("[stream-{0}] job ended in state {1}" -f $j.Id, $j.State) -ForegroundColor Yellow
                }
            }

            foreach ($S in $StreamSummaries)
            {
                if (-not (Test-Path -LiteralPath $S.SummaryPath -PathType Leaf))
                {
                    Write-Host ("[stream-{0}] WARNING: no summary file at {1} - the stream did not finish cleanly" -f $S.StreamId, $S.SummaryPath) -ForegroundColor Yellow
                    $FailedSubscriptions += ("stream-{0} (no summary)" -f $S.StreamId)
                    continue
                }
                try
                {
                    $StreamSummary = Get-Content -LiteralPath $S.SummaryPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                }
                catch
                {
                    Write-Host ("[stream-{0}] ERROR: could not parse summary file {1}: {2}" -f $S.StreamId, $S.SummaryPath, $_.Exception.Message) -ForegroundColor Red
                    $FailedSubscriptions += ("stream-{0} (corrupt summary)" -f $S.StreamId)
                    continue
                }

                if ($StreamSummary.Status -and $StreamSummary.Status -ne 'ok' -and $StreamSummary.Status -ne 'partial-failure')
                {
                    $ReasonText = if ($StreamSummary.Reason) { $StreamSummary.Reason } else { '(no reason given)' }
                    Write-Host ("[stream-{0}] stream status: {1} - {2}" -f $S.StreamId, $StreamSummary.Status, $ReasonText) -ForegroundColor Red
                }

                if ($StreamSummary.ResourceCounts)
                {
                    foreach ($rc in $StreamSummary.ResourceCounts)
                    {
                        if ($null -eq $rc) { continue }
                        $SubResourceCounts += [pscustomobject]@{
                            Name  = $rc.Name
                            Id    = $rc.Id
                            Count = [int]$rc.Count
                            Zip   = $rc.Zip
                        }
                    }
                }

                if ($StreamSummary.Failed)
                {
                    foreach ($f in $StreamSummary.Failed)
                    {
                        $FailedSubscriptions += ("{0} (stream-{1}: {2})" -f $f.Name, $S.StreamId, $f.Reason)
                    }
                }

                if ($null -ne $StreamSummary.ConsumptionRecords)
                {
                    if ($null -eq $Global:ConsumptionRecordCount) { $Global:ConsumptionRecordCount = 0 }
                    $Global:ConsumptionRecordCount = [int]$Global:ConsumptionRecordCount + [int]$StreamSummary.ConsumptionRecords
                }

                if ($null -ne $StreamSummary.MetricsApiCalls)
                {
                    if ($null -eq $Global:MetricsApiCallCount) { $Global:MetricsApiCallCount = 0 }
                    $Global:MetricsApiCallCount = [int]$Global:MetricsApiCallCount + [int]$StreamSummary.MetricsApiCalls
                }

                if ($null -ne $StreamSummary.MarketplaceRecords)
                {
                    if ($null -eq $Global:MarketplaceRecordCount) { $Global:MarketplaceRecordCount = 0 }
                    $Global:MarketplaceRecordCount = [int]$Global:MarketplaceRecordCount + [int]$StreamSummary.MarketplaceRecords
                }
                if ($StreamSummary.ConsumptionFailedSubs -and $StreamSummary.ConsumptionFailedSubs.Count -gt 0)
                {
                    if ($null -eq $Global:ConsumptionFailedSubs) { $Global:ConsumptionFailedSubs = @() }
                    $Global:ConsumptionFailedSubs += @($StreamSummary.ConsumptionFailedSubs)
                }

                if ($StreamSummary.MetricsFailedSubs -and $StreamSummary.MetricsFailedSubs.Count -gt 0)
                {
                    if ($null -eq $Global:MetricsFailedSubs) { $Global:MetricsFailedSubs = @() }
                    $Global:MetricsFailedSubs += @($StreamSummary.MetricsFailedSubs)
                }

                if ($StreamSummary.MarketplaceFailedSubs -and $StreamSummary.MarketplaceFailedSubs.Count -gt 0)
                {
                    if ($null -eq $Global:MarketplaceFailedSubs) { $Global:MarketplaceFailedSubs = @() }
                    $Global:MarketplaceFailedSubs += @($StreamSummary.MarketplaceFailedSubs)
                }

                if ($StreamSummary.CollectorFailures -and $StreamSummary.CollectorFailures.Count -gt 0)
                {
                    if ($null -eq $Global:CollectorFailures) { $Global:CollectorFailures = @() }
                    $Global:CollectorFailures += @($StreamSummary.CollectorFailures)
                }
                if ($StreamSummary.ArchiveWriteFailures -and $StreamSummary.ArchiveWriteFailures.Count -gt 0)
                {
                    $ArchiveWriteFailures += @($StreamSummary.ArchiveWriteFailures)
                }

                if ((Test-Path -LiteralPath $S.FailuresPath -PathType Leaf) -and ((Get-Item -LiteralPath $S.FailuresPath).Length -gt 0))
                {
                    if ($null -eq $DiagFile)
                    {
                        $DiagFile = Join-Path $InventoryRoot ("RunAllSubscriptions_failures_{0}_{1}.log" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss-fff'), [guid]::NewGuid().ToString().Substring(0, 4))
                    }
                    try
                    {
                        Get-Content -LiteralPath $S.FailuresPath -Raw | Out-File -LiteralPath $DiagFile -Append -Encoding utf8
                    }
                    catch
                    {
                        Write-Verbose ("Failed to merge stream failures log {0}: {1}" -f $S.FailuresPath, $_.Exception.Message)
                    }
                }
            }

            foreach ($S in $StreamSummaries)
            {
                if (Test-Path -LiteralPath $S.SummaryPath)
                {
                    try { Remove-Item -LiteralPath $S.SummaryPath -Force } catch { Write-Verbose ("Could not remove stream summary {0}: {1}" -f $S.SummaryPath, $_.Exception.Message) }
                }
            }

            $AllStreamFiles = @(Get-StreamResumeStateFiles -InventoryRoot $InventoryRoot -Tenant $TenantID)
            $AllCompletedFromStreams = @()
            $AllFailedFromStreams = @()
            foreach ($StreamFile in $AllStreamFiles)
            {
                $PerStreamFile = $StreamFile.FullName
                try
                {
                    $Obj = Get-Content -LiteralPath $PerStreamFile -Raw | ConvertFrom-Json
                    if ($null -ne $Obj.Completed)
                    {
                        $AllCompletedFromStreams += @($Obj.Completed)
                    }
                    if ($null -ne $Obj.FailedAttempts)
                    {
                        $AllFailedFromStreams += @($Obj.FailedAttempts)
                    }
                }
                catch
                {
                    Write-Verbose ("Could not read stream resume file {0}: {1}" -f $PerStreamFile, $_.Exception.Message)
                }
            }
            if ($null -ne $StateBlobParts)
            {
                $StreamBlobNames = @(Get-StateBlobNames -Context $StateBlobCtx -Container $StateBlobParts.Container -Prefix $StateBlobParts.Prefix -Tenant $TenantID -ShardIndex $ShardIndex -ShardCount $ShardCount)
                foreach ($StreamBlobName in $StreamBlobNames)
                {
                    $BlobObj = Read-StateBlob -Context $StateBlobCtx -Container $StateBlobParts.Container -BlobName $StreamBlobName
                    if ($null -ne $BlobObj)
                    {
                        if ($null -ne $BlobObj.Completed) { $AllCompletedFromStreams += @($BlobObj.Completed) }
                        if ($null -ne $BlobObj.FailedAttempts) { $AllFailedFromStreams += @($BlobObj.FailedAttempts) }
                    }
                }
            }
            if ($AllCompletedFromStreams.Count -gt 0)
            {
                $CompletedIds = @($CompletedIds + $AllCompletedFromStreams | Sort-Object -Unique)
            }
            $FailedAttempts = Merge-FailedAttempts -ExistingFailedAttempts $FailedAttempts -StreamFailedAttempts $AllFailedFromStreams -CompletedIds $CompletedIds
            if ($AllCompletedFromStreams.Count -gt 0 -or $AllFailedFromStreams.Count -gt 0)
            {
                Save-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID -Ids $CompletedIds -FailedAttempts $FailedAttempts @StateSaveArgs
            }
            foreach ($StreamFile in $AllStreamFiles)
            {
                $PerStreamFile = $StreamFile.FullName
                try { Remove-Item -LiteralPath $PerStreamFile -Force } catch { Write-Verbose ("Could not remove stream resume file {0}: {1}" -f $PerStreamFile, $_.Exception.Message) }
            }
            if ($null -ne $StateBlobParts)
            {
                foreach ($MergedStreamBlob in $StreamBlobNames)
                {
                    try { Remove-AzStorageBlob -Container $StateBlobParts.Container -Blob $MergedStreamBlob -Context $StateBlobCtx -Force -ErrorAction Stop }
                    catch { Write-Verbose ("Could not remove per-stream state blob {0}: {1}" -f $MergedStreamBlob, $_.Exception.Message) }
                }
            }
        }
        finally
        {

            if ($null -ne $Jobs -and @($Jobs).Count -gt 0)
            {
                try
                {
                    @($Jobs | Where-Object { $_.State -eq 'Running' }) | ForEach-Object {
                        try { Stop-Job -Job $_ -ErrorAction SilentlyContinue } catch {}
                    }
                    $Jobs | Remove-Job -Force -ErrorAction SilentlyContinue
                }
                catch
                {
                    Write-Host ("WARNING: could not fully clean up background jobs: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
                }
            }

            if (Test-Path -LiteralPath $AzContextSnapshot)
            {
                try
                {
                    Remove-Item -LiteralPath $AzContextSnapshot -Force -ErrorAction Stop
                }
                catch
                {
                    Write-Host ("WARNING: could not remove Az context snapshot at {0}: {1}" -f $AzContextSnapshot, $_.Exception.Message) -ForegroundColor Yellow
                    Write-Host "  This file contains an Azure token cache and should be deleted manually." -ForegroundColor Yellow
                }
            }
        }
    }
}

# === Moving-target subscription reconciliation: another team can create/delete subs DURING a long run, so the start-of-run Get-AzSubscription is stale by now. Re-enumerate and classify the delta against the ORIGINAL start snapshot ($StartSnapshot, preserved across resume) - subs deleted mid-run (Vanished) must NOT be reported as failures, and subs created mid-run (New) would otherwise be SILENTLY MISSING from the report.
$StartIds = if ($StartSnapshot -and $StartSnapshot.SubscriptionIds) { @($StartSnapshot.SubscriptionIds) } else { @() }
if ($StartIds.Count -gt 0)
{
    try
    {
        $EndSubs = @(Get-AzSubscription -TenantId $TenantID -WarningAction SilentlyContinue)
        $EndIds = @($EndSubs | ForEach-Object { $_.Id })
        $Delta = Get-SubscriptionDelta -StartIds $StartIds -EndIds $EndIds -CompletedIds $CompletedIds
        $ResponsibleSet = @{}
        foreach ($ResponsibleSub in $Subscriptions) { $ResponsibleSet[([string]$ResponsibleSub.Id).ToLowerInvariant()] = $true }
        $VanishedMine = @($Delta.Vanished | Where-Object { $ResponsibleSet.ContainsKey(([string]$_).ToLowerInvariant()) })
        $IncompleteMine = @($Delta.Incomplete | Where-Object { $ResponsibleSet.ContainsKey(([string]$_).ToLowerInvariant()) })
        if ($VanishedMine.Count -gt 0 -or $Delta.New.Count -gt 0 -or $IncompleteMine.Count -gt 0)
        {
            Write-Host ""
            Write-Host "Subscription reconciliation (start-of-run vs now):" -ForegroundColor Cyan
        }
        if ($VanishedMine.Count -gt 0)
        {
            Write-Host ("  Deleted mid-run ({0}): {1}" -f $VanishedMine.Count, (($VanishedMine | Select-Object -First 10) -join ', ')) -ForegroundColor DarkYellow
            Write-Host "    These no longer exist; failures against them are expected and are dropped from the retry list (not run faults)." -ForegroundColor DarkGray
            $VanishedSet = @{}
            foreach ($VanishedId in $VanishedMine) { $VanishedSet[([string]$VanishedId).ToLowerInvariant()] = $true }
            $FailedAttempts = @($FailedAttempts | Where-Object { $_ -and -not $VanishedSet.ContainsKey(([string]$_.Id).ToLowerInvariant()) })
            Save-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID -Ids $CompletedIds -FailedAttempts $FailedAttempts @StateSaveArgs
        }
        if ($Delta.New.Count -gt 0)
        {
            Write-Host ("  Created mid-run ({0}): {1}" -f $Delta.New.Count, (($Delta.New | Select-Object -First 10) -join ', ')) -ForegroundColor Yellow
            Write-Host "    NOT in this report - they did not exist when the run started. Re-run with -Resume to pick them up." -ForegroundColor Yellow
        }
        if ($IncompleteMine.Count -gt 0)
        {
            Write-Host ("  Owed by this run but not completed ({0}): {1}" -f $IncompleteMine.Count, (($IncompleteMine | Select-Object -First 10) -join ', ')) -ForegroundColor Yellow
            Write-Host "    Re-run with -Resume to finish these." -ForegroundColor Yellow
        }
    }
    catch
    {
        Write-Host ("WARNING: subscription reconciliation skipped (re-enumeration failed): {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
}

Write-Host "All subscriptions processed!" -ForegroundColor Green

# === Per-subscription output verification (hard-stop): fail with exit code 2 (distinct from auth/runtime exit code 1) if any sub that ran to completion this invocation left no report archive on disk. Checks IDENTITY first (every successful sub records the exact $Global:ZipOutputFile it wrote, so a missing report is reported BY SUBSCRIPTION) and count second (catches an absent recorded path or a replaced archive).
$ExpectedZipCount = @($SubResourceCounts).Count
if ($ExpectedZipCount -gt 0 -and (Test-Path -LiteralPath $InventoryRoot -PathType Container))
{
    $ActualSubZips = @(Get-ChildItem -LiteralPath $InventoryRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Filter "*.zip" -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $RunStartTime } })
    $ActualZipCount = $ActualSubZips.Count

    $MissingSubs = @($SubResourceCounts | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Zip) -and -not (Test-ReportArchiveUsable -Path $_.Zip) })
    $UnverifiableSubs = @($SubResourceCounts | Where-Object { [string]::IsNullOrWhiteSpace($_.Zip) })

    if ($MissingSubs.Count -gt 0 -or $ActualZipCount -lt $ExpectedZipCount)
    {
        $MissingCount = $ExpectedZipCount - $ActualZipCount
        Write-Host ""
        Write-Host "ERROR: Per-subscription output verification failed." -ForegroundColor Red
        Write-Host ("  Expected zips: {0} (one per subscription that ran to completion this run)" -f $ExpectedZipCount) -ForegroundColor Red
        Write-Host ("  Found zips:    {0} (filter: under {1}, LastWriteTime >= {2:o})" -f $ActualZipCount, $InventoryRoot, $RunStartTime) -ForegroundColor Red
        if ($MissingCount -gt 0)
        {
            Write-Host ("  Gap:           {0} missing per-subscription zip(s)." -f $MissingCount) -ForegroundColor Red
        }
        Write-Host ""
        if ($MissingSubs.Count -gt 0)
        {
            Write-Host ("Subscription(s) whose report archive is MISSING ({0}):" -f $MissingSubs.Count) -ForegroundColor Red
            foreach ($M in $MissingSubs)
            {
                Write-Host ("  - {0} ({1}) [{2:N0} resources]" -f $M.Name, $M.Id, $M.Count) -ForegroundColor Red
                if (Test-Path -LiteralPath $M.Zip -PathType Leaf)
                {
                    Write-Host ("      archive is present but EMPTY (0 bytes): {0}" -f $M.Zip) -ForegroundColor Red
                    Write-Host "      -> a truncating quarantine or a write cut off mid-flush; it is not a usable report." -ForegroundColor Red
                }
                else
                {
                    Write-Host ("      expected archive: {0}" -f $M.Zip) -ForegroundColor Red
                }
                $MissingDir = try { [System.IO.Path]::GetDirectoryName($M.Zip) } catch { $null }
                if (-not [string]::IsNullOrWhiteSpace($MissingDir))
                {
                    if (Test-Path -LiteralPath $MissingDir -PathType Container)
                    {
                        Write-Host ("      report folder IS present: {0}" -f $MissingDir) -ForegroundColor Yellow
                        Write-Host "      -> the uncompressed report files in it can be zipped by hand instead of re-collecting." -ForegroundColor Yellow
                    }
                    else
                    {
                        Write-Host ("      report folder is ALSO gone: {0}" -f $MissingDir) -ForegroundColor Red
                        Write-Host "      -> the whole folder was removed after the run wrote it; re-collect this subscription." -ForegroundColor Red
                    }
                }
            }
            Write-Host ""
        }
        if ($UnverifiableSubs.Count -gt 0)
        {
            Write-Host ("Subscription(s) with no recorded archive path - cannot be checked individually ({0}):" -f $UnverifiableSubs.Count) -ForegroundColor Yellow
            foreach ($U in $UnverifiableSubs)
            {
                Write-Host ("  - {0} ({1})" -f $U.Name, $U.Id) -ForegroundColor Yellow
            }
            Write-Host ""
        }
        Write-Host "Subscriptions whose inner script reported success this run:" -ForegroundColor Yellow
        foreach ($S in $SubResourceCounts)
        {
            Write-Host ("  - {0} ({1}) [{2:N0} resources]" -f $S.Name, $S.Id, $S.Count) -ForegroundColor Yellow
        }
        Write-Host ""
        Write-Host "Likely causes:" -ForegroundColor Yellow
        Write-Host "  - Antivirus or DLP product quarantined the per-sub zip after the inner script wrote it." -ForegroundColor Yellow
        Write-Host "  - Cloud Shell ephemeral storage was evicted between worker exit and wrapper consolidation." -ForegroundColor Yellow
        Write-Host "  - A parallel worker crashed after the inner script logged completion but before flushing the zip to disk." -ForegroundColor Yellow
        Write-Host "  - Out-of-disk-space write that the inner script swallowed silently." -ForegroundColor Yellow
        Write-Host ""
        Write-Host ("Resume State:            {0}" -f $ResumeStateFile) -ForegroundColor Yellow
        Write-Host "Recover by either:" -ForegroundColor Yellow
        Write-Host "  - Inspecting the report folder named above and zipping its files by hand if they are still present, OR" -ForegroundColor Yellow
        Write-Host "  - Re-running with -Resume to re-collect any unprocessed/missing subscription." -ForegroundColor Yellow
        Write-Host "    NOTE: a subscription listed above is already recorded as complete in the resume state, so plain" -ForegroundColor Yellow
        Write-Host "    -Resume will SKIP it. To force a re-collect, either remove its id from the resume-state file" -ForegroundColor Yellow
        Write-Host "    above, or collect just that one directly with:" -ForegroundColor Yellow
        Write-Host "      ./ResourceInventory.ps1 -TenantID <tenant> -SubscriptionID <the id listed above>" -ForegroundColor Yellow
        if ($WrapperTranscriptStarted)
        {
            Write-Host ("Wrapper Transcript:      {0}" -f $WrapperTranscriptFile) -ForegroundColor Yellow
        }
        Exit-Wrapper -Code 2
    }
    $VerifiedByPathCount = $ExpectedZipCount - $UnverifiableSubs.Count
    Write-Host ("Per-subscription output verification: OK ({0} archive(s) on disk for {1} successful sub(s); {2} verified by exact path)" -f $ActualZipCount, $ExpectedZipCount, $VerifiedByPathCount) -ForegroundColor Green
    if ($UnverifiableSubs.Count -gt 0)
    {
        Write-Host ("  Note: {0} sub(s) recorded no archive path and were covered by the count check only." -f $UnverifiableSubs.Count) -ForegroundColor Yellow
    }
}

$OuterZipFile = $null

if (Test-Path -LiteralPath $InventoryRoot -PathType Container)
{
    $SubZips = @(Get-ChildItem -LiteralPath $InventoryRoot -Directory | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Filter "*.zip" -File | Where-Object { $_.LastWriteTime -ge $RunStartTime } })
    if ($SubZips.Count -gt 0)
    {
        $Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
        $OuterZipFile = Join-Path $InventoryRoot "AllSubscriptions_ResourcesReport_$Timestamp.zip"
        Write-Host ("Compressing {0} per-subscription report(s) into: {1}" -f $SubZips.Count, $OuterZipFile) -ForegroundColor Cyan
        Compress-Archive -LiteralPath $SubZips.FullName -DestinationPath ([WildcardPattern]::Escape($OuterZipFile)) -Force
        Write-Host ("Consolidated bundle created: {0}" -f $OuterZipFile) -ForegroundColor Green
    }
    else
    {
        Write-Host ("No per-subscription zip files found under {0} to consolidate." -f $InventoryRoot) -ForegroundColor Yellow
    }
}
else
{
    Write-Host ("Inventory root not found at {0}. Nothing to consolidate." -f $InventoryRoot) -ForegroundColor Yellow
}

$MainSummaryFile = $null
if ($null -ne $OuterZipFile)
{
    try
    {
        $AllSubSummaryFunctions = Join-Path $PSScriptRoot 'Functions/AllSubHtmlSummary.Functions.ps1'
        if (-not (Test-Path -LiteralPath $AllSubSummaryFunctions -PathType Leaf))
        {
            throw "Main summary functions not found at '$AllSubSummaryFunctions'."
        }
        . $AllSubSummaryFunctions
        $MainSummaryFile = Join-Path $InventoryRoot ("MainSummary_{0}.html" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
        $MainVer = $Global:Version
        try
        {
            $VerObj = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Version.json') -Raw | ConvertFrom-Json
            $MainVer = ('{0}.{1}.{2}' -f $VerObj.MajorVersion, $VerObj.MinorVersion, $VerObj.BuildVersion)
        }
        catch { Write-Verbose ("MainSummary: could not read Version.json: {0}" -f $_.Exception.Message) }
        New-RdaAllSubHtmlSummary -RunOutputDirectory $InventoryRoot -HtmlFile $MainSummaryFile -SinceTime $RunStartTime `
            -FailedSubscriptions $FailedSubscriptions `
            -ConsumptionFailedSubs $Global:ConsumptionFailedSubs `
            -MetricsFailedSubs $Global:MetricsFailedSubs `
            -MarketplaceFailedSubs $Global:MarketplaceFailedSubs `
            -CollectorFailures $Global:CollectorFailures `
            -TenantId $TenantID -Version $MainVer -PlatOS $PSVersionTable.OS `
            -Detailed:$Detailed -Obfuscated:$Obfuscate
    }
    catch
    {
        Write-Host ("WARNING: Could not build the main summary: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
}

$VmPlacementFile = $null
if ($CapacityPlan)
{
    try
    {
        $PlacementParts = @(Get-ChildItem -LiteralPath $InventoryRoot -Filter 'VMPlacementPart_*.csv' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $RunStartTime } | Sort-Object Name)

        $PlacementRows = @()
        foreach ($Part in $PlacementParts)
        {
            $PlacementRows += @(Import-Csv -LiteralPath $Part.FullName)
        }

        if ($PlacementRows.Count -gt 0)
        {
            $VmPlacementFile = Join-Path $InventoryRoot ("VMPlacement_{0}.csv" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
            $PlacementRows | Export-Csv -LiteralPath $VmPlacementFile -Encoding utf8 -NoTypeInformation

            $ZonalRows = @($PlacementRows | Where-Object { $_.Zone -ne 'Regional' -and $_.Zone -ne 'Unknown' }).Count
            Write-Host ("VM placement CSV: {0} VM(s) across {1} subscription(s) written to {2} ({3} zonal)." -f `
                    $PlacementRows.Count, $PlacementParts.Count, (Split-Path -Path $VmPlacementFile -Leaf), $ZonalRows) -ForegroundColor Green
        }
        else
        {
            Write-Host ("VM placement CSV: not written - no VM rows were produced by this run (parts found: {0}). A tenant with no virtual machines, or a -Resume run whose remaining subscriptions have none, both land here." -f $PlacementParts.Count) -ForegroundColor Yellow
        }

        foreach ($Part in $PlacementParts)
        {
            Remove-Item -LiteralPath $Part.FullName -Force -ErrorAction SilentlyContinue
        }

    }
    catch
    {
        Write-Host ("WARNING: Could not build the tenant-wide VM placement CSV: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
}

if ($FailedSubscriptions.Count -eq 0 -and $FailedAttempts.Count -eq 0 -and (Test-Path -LiteralPath $ResumeStateFile -PathType Leaf))
{
    try
    {
        Remove-Item -LiteralPath $ResumeStateFile -Force
        Write-Host "Resume state cleared (clean run)." -ForegroundColor Green
    }
    catch
    {
        Write-Host ("WARNING: Could not remove resume state file {0}: $_" -f $ResumeStateFile) -ForegroundColor Yellow
    }
}

$Elapsed = (Get-Date) - $RunStartTime
Write-Host ""
Write-Host "================ Summary ================" -ForegroundColor Green
Write-Host ("Subscriptions Visible:   {0}" -f $AllSubscriptions.Count) -ForegroundColor Green
if ($Excluded.Count -gt 0)
{
    Write-Host ("Subscriptions Excluded:  {0} (non-Enabled; use -IncludeDisabled to inventory them)" -f $Excluded.Count) -ForegroundColor Green
}
Write-Host ("Subscriptions Eligible:  {0}" -f $EligibleCount) -ForegroundColor Green
if ($ParallelStreams -gt 1 -and $Resume -and $SkippedCount -eq 0)
{
    $ActuallyProcessed = ($SubResourceCounts | Measure-Object).Count + $FailedSubscriptions.Count
    $DerivedSkip = $EligibleCount - $ActuallyProcessed
    if ($DerivedSkip -gt 0) { $SkippedCount = $DerivedSkip }
}
if ($Resume)
{
    Write-Host ("Subscriptions Skipped:   {0} (already completed)" -f $SkippedCount) -ForegroundColor Green
}
Write-Host ("Subscriptions Processed: {0}" -f ($EligibleCount - $SkippedCount)) -ForegroundColor Green

$EmptySubs = @($SubResourceCounts | Where-Object { $_.Count -eq 0 })
$NonEmptySubs = @($SubResourceCounts | Where-Object { $_.Count -gt 0 })
$NoAccessSubs = @()
$GenuinelyEmptySubs = @()
$UnknownSubs = @()
if ($SubResourceCounts.Count -gt 0)
{
    $TotalRes = ($SubResourceCounts | Measure-Object -Property Count -Sum).Sum
    Write-Host ("Total Resources:         {0:N0} across {1} subscription(s)" -f $TotalRes, $NonEmptySubs.Count) -ForegroundColor Green
}
if ($EmptySubs.Count -gt 0)
{
    $NoAccessSubs = @()
    $GenuinelyEmptySubs = @()
    $UnknownSubs = @()
    foreach ($e in $EmptySubs)
    {
        switch (Get-SubscriptionAccessState -SubscriptionId $e.Id)
        {
            'NoAccess' { $NoAccessSubs += $e }
            'Empty' { $GenuinelyEmptySubs += $e }
            default { $UnknownSubs += $e }
        }
    }

    Write-Host ""
    Write-Host ("Subscriptions with 0 resources: {0}" -f $EmptySubs.Count) -ForegroundColor Yellow

    if ($NoAccessSubs.Count -gt 0)
    {
        Write-Host ("  NO ACCESS ({0}) - the signed-in identity has no role on these subscriptions:" -f $NoAccessSubs.Count) -ForegroundColor Red
        foreach ($e in $NoAccessSubs) { Write-Host ("    - {0} ({1})" -f $e.Name, $e.Id) -ForegroundColor Red }
        Write-Host "    Fix: grant the identity Reader on these subscriptions, then re-run." -ForegroundColor Red
    }
    if ($GenuinelyEmptySubs.Count -gt 0)
    {
        Write-Host ("  GENUINELY EMPTY ({0}) - access confirmed, the subscription has no resources:" -f $GenuinelyEmptySubs.Count) -ForegroundColor Yellow
        foreach ($e in $GenuinelyEmptySubs) { Write-Host ("    - {0} ({1})" -f $e.Name, $e.Id) -ForegroundColor Yellow }
        Write-Host "    No action needed - these are expected to be empty in the report." -ForegroundColor DarkGray
    }
    if ($UnknownSubs.Count -gt 0)
    {
        Write-Host ("  UNDETERMINED ({0}) - access probe was inconclusive (transient error / throttling):" -f $UnknownSubs.Count) -ForegroundColor Yellow
        foreach ($e in $UnknownSubs) { Write-Host ("    - {0} ({1})" -f $e.Name, $e.Id) -ForegroundColor Yellow }
        Write-Host "    Verify manually (PowerShell): (Invoke-AzRestMethod -Method GET -Path '/subscriptions/<id>/resourcegroups?api-version=2021-04-01').StatusCode" -ForegroundColor Yellow
    }

    if ($null -eq $DiagFile)
    {
        $DiagFile = Join-Path $InventoryRoot ("RunAllSubscriptions_diagnostics_{0}_{1}.log" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss-fff'), [guid]::NewGuid().ToString().Substring(0, 4))
    }
    $EmptyDiag = @()
    $EmptyDiag += "==== Subscriptions with 0 resources - access verdict ===="
    $EmptyDiag += "Timestamp: $(Get-Date -Format 'o')"
    foreach ($e in $NoAccessSubs)
    {
        $EmptyDiag += ("NO_ACCESS {0} ({1}) - identity has no role on the subscription; grant Reader and re-run with -Resume" -f $e.Name, $e.Id)
    }
    foreach ($e in $GenuinelyEmptySubs)
    {
        $EmptyDiag += ("EMPTY {0} ({1}) - access confirmed, no resources; no action needed" -f $e.Name, $e.Id)
    }
    foreach ($e in $UnknownSubs)
    {
        $EmptyDiag += ("UNDETERMINED   {0} ({1}) - access probe inconclusive; verify (PowerShell): (Invoke-AzRestMethod -Method GET -Path '/subscriptions/{1}/resourcegroups?api-version=2021-04-01').StatusCode" -f $e.Name, $e.Id)
    }
    $EmptyDiag += ""
    try
    {
        $EmptyDiag | Out-File -LiteralPath $DiagFile -Append -Encoding utf8
        Write-Host ("  Access verdict written to diagnostic log: {0}" -f $DiagFile) -ForegroundColor DarkGray
    }
    catch
    {
        Write-Verbose ("Diagnostic log write failed at {0}: {1}" -f $DiagFile, $_.Exception.Message)
    }
    Write-Host ""
}

$ConsumptionRecords = if ($null -ne $Global:ConsumptionRecordCount) { [int]$Global:ConsumptionRecordCount } else { 0 }
$ConsumptionFailures = if ($null -ne $Global:ConsumptionFailedSubs) { @($Global:ConsumptionFailedSubs) } else { @() }
if (-not $SkipConsumption)
{
    $ConsumptionRecordColor = if ($ConsumptionRecords -gt 0) { 'Green' } else { 'Yellow' }
    Write-Host ("Consumption Records:     {0:N0} record(s) collected" -f $ConsumptionRecords) -ForegroundColor $ConsumptionRecordColor
}
elseif ($ConsumptionRecords -gt 0 -or $ConsumptionFailures.Count -gt 0)
{
    Write-Host ("Consumption Records:     {0:N0} record(s) collected" -f $ConsumptionRecords) -ForegroundColor Green
}

$MarketplaceRecords = if ($null -ne $Global:MarketplaceRecordCount) { [int]$Global:MarketplaceRecordCount } else { 0 }
$MarketplaceFailures = if ($null -ne $Global:MarketplaceFailedSubs) { @($Global:MarketplaceFailedSubs) } else { @() }
$MarketplaceRequested = (-not $SkipConsumption) -and (-not $SkipMarketplace)
if ($MarketplaceRequested)
{
    $MarketplaceRecordColor = if ($MarketplaceRecords -gt 0) { 'Green' } else { 'Yellow' }
    Write-Host ("Marketplace Records:     {0:N0} record(s) collected" -f $MarketplaceRecords) -ForegroundColor $MarketplaceRecordColor
}
elseif ($MarketplaceRecords -gt 0 -or $MarketplaceFailures.Count -gt 0)
{
    Write-Host ("Marketplace Records:     {0:N0} record(s) collected" -f $MarketplaceRecords) -ForegroundColor Green
}

if (-not $SkipConsumption -and $ConsumptionRecords -eq 0 -and $ConsumptionFailures.Count -eq 0 -and @($SubResourceCounts).Count -gt 0 -and ($EligibleCount - $SkippedCount) -gt 0)
{
    Write-Host ""
    Write-Host "WARNING: Consumption data was requested (no -SkipConsumption) but ZERO usage records were collected," -ForegroundColor Yellow
    Write-Host "         and no subscription reported a billing error. The billing API answered successfully with no rows." -ForegroundColor Yellow
    Write-Host "         The consumption CSV in the report will contain only its header row." -ForegroundColor Yellow
    Write-Host "         This is expected ONLY if the subscriptions genuinely have no usage in the queried window" -ForegroundColor Yellow
    Write-Host "         (the 30 days ending at midnight yesterday, host local time)." -ForegroundColor Yellow
    Write-Host "         Otherwise the most common causes are:" -ForegroundColor Yellow
    Write-Host "           - CSP / Partner-managed subscription: the partner's cost visibility policy is OFF by default." -ForegroundColor Yellow
    Write-Host "             Billing scope on CSP subscriptions is not governed by Azure RBAC, so granting Cost Management" -ForegroundColor Yellow
    Write-Host "             Reader does NOT help. The partner must enable cost visibility for the customer in Partner Center." -ForegroundColor Yellow
    Write-Host "           - The subscription has not been transitioned to the Azure plan (required for CSP billing APIs)." -ForegroundColor Yellow
    Write-Host "           - A subscription offer the legacy usage API does not serve (e.g. sponsored/sandbox offers)." -ForegroundColor Yellow
    Write-Host "         Confirm in the Azure portal under Cost Management + Billing before sharing this report." -ForegroundColor Yellow
    Write-Host ""
}
if ($ConsumptionFailures.Count -gt 0)
{
    Write-Host ""
    Write-Host ("Consumption Failures:    {0} subscription(s)" -f $ConsumptionFailures.Count) -ForegroundColor Yellow
    foreach ($cf in (@($ConsumptionFailures | Where-Object { $_.Id -ne '(auth)' }) | Sort-Object Name -Unique))
    {
        Write-Host ("  - {0} ({1})" -f $cf.Name, $cf.Id) -ForegroundColor Yellow
    }
    $UniqueMessages = @($ConsumptionFailures | Select-Object -ExpandProperty Message -Unique)
    foreach ($m in $UniqueMessages)
    {
        Write-Host ("  - {0}" -f $m) -ForegroundColor Yellow
    }
    if ($UniqueMessages | Where-Object { $_ -match 'context has not been properly initialized|Could not load file or assembly|MSAL|Azure\.Core' })
    {
        Write-Host "  This message strongly suggests the Az PowerShell module is broken on disk." -ForegroundColor Yellow
        Write-Host "  Reinstall with:" -ForegroundColor Yellow
        Write-Host "    Get-Module Az* -ListAvailable | Uninstall-Module -Force" -ForegroundColor Yellow
        Write-Host "    Install-Module -Name Az.Accounts,Az.Compute,Az.Monitor,Az.Billing,Az.ResourceGraph -Repository PSGallery -Force -AllowClobber -SkipPublisherCheck -Scope CurrentUser" -ForegroundColor Yellow
    }
    Write-Host "  Note: the consumption sheet in the output report may be empty or incomplete for these subscriptions." -ForegroundColor Yellow
    Write-Host ""
}

if ($MarketplaceFailures.Count -gt 0)
{
    Write-Host ""
    Write-Host ("Marketplace Failures:    {0} subscription(s)" -f $MarketplaceFailures.Count) -ForegroundColor Yellow
    foreach ($mf in (@($MarketplaceFailures | Where-Object { $_.Id -ne '(auth)' }) | Sort-Object Name -Unique))
    {
        Write-Host ("  - {0} ({1})" -f $mf.Name, $mf.Id) -ForegroundColor Yellow
    }
    $UniqueMarketplaceMessages = @($MarketplaceFailures | Select-Object -ExpandProperty Message -Unique)
    foreach ($m in $UniqueMarketplaceMessages)
    {
        Write-Host ("  - {0}" -f $m) -ForegroundColor Yellow
    }
    Write-Host "  Note: the Marketplace CSV in the output report may be empty or incomplete for these subscriptions." -ForegroundColor Yellow
    Write-Host ""
}
elseif ($MarketplaceRequested -and $MarketplaceRecords -eq 0 -and @($SubResourceCounts).Count -gt 0 -and ($EligibleCount - $SkippedCount) -gt 0)
{
    Write-Host ""
    Write-Host "Marketplace Records:     0 collected. This is a CONFIRMED ZERO - the Microsoft.Consumption/marketplaces" -ForegroundColor Yellow
    Write-Host "         endpoint was reached successfully and returned no rows, meaning no Azure Marketplace /" -ForegroundColor Yellow
    Write-Host "         third-party SaaS charges were billed to the in-scope subscriptions in the queried window." -ForegroundColor Yellow
    Write-Host "         It is NOT a missing/failed section. The Marketplace CSV will contain only its header row." -ForegroundColor Yellow
    Write-Host ""
}

$MetricsFailures = if ($null -ne $Global:MetricsFailedSubs) { @($Global:MetricsFailedSubs) } else { @() }
if ($MetricsFailures.Count -gt 0)
{
    Write-Host ""
    Write-Host ("Metrics Auth Failures:   {0} subscription(s) - metrics SKIPPED" -f $MetricsFailures.Count) -ForegroundColor Yellow
    foreach ($m in ($MetricsFailures | Sort-Object Name -Unique))
    {
        Write-Host ("  - {0} ({1})" -f $m.Name, $m.Id) -ForegroundColor Yellow
    }
    $FirstMsg = @($MetricsFailures | Where-Object { -not [string]::IsNullOrEmpty($_.Message) } | Select-Object -First 1).Message
    if (-not [string]::IsNullOrEmpty($FirstMsg))
    {
        Write-Host ("  Reason: {0}" -f $FirstMsg) -ForegroundColor Yellow
    }
    Write-Host "  Re-authenticate (Connect-AzAccount) or pass -appid/-secret/-tenant, then re-run." -ForegroundColor Yellow
    Write-Host "  Note: the metrics sheet in the output report will be empty for these subscriptions." -ForegroundColor Yellow
    Write-Host ""
}

$CollectorFailuresList = if ($null -ne $Global:CollectorFailures) { @($Global:CollectorFailures) } else { @() }
if ($CollectorFailuresList.Count -gt 0)
{
    Write-Host ""
    Write-Host ("Collector Failures:      {0} failure(s) across {1} subscription(s)" -f $CollectorFailuresList.Count, (@($CollectorFailuresList | Select-Object -ExpandProperty Id -Unique)).Count) -ForegroundColor Yellow
    foreach ($SubGroup in ($CollectorFailuresList | Group-Object -Property Id))
    {
        Write-Host ("  - Subscription {0}:" -f $SubGroup.Name) -ForegroundColor Yellow
        foreach ($f in $SubGroup.Group)
        {
            Write-Host ("      {0}: {1}" -f $f.Module, $f.Message) -ForegroundColor Yellow
        }
    }
    Write-Host "  These resource types are missing (not empty) from the affected subscription's report." -ForegroundColor Yellow
    Write-Host "  Re-run to retry, or investigate the error(s) above if they repeat." -ForegroundColor Yellow
    Write-Host ""
}

if ($FailedSubscriptions.Count -gt 0)
{
    Write-Host ("Subscriptions Failed:    {0} ({1})" -f $FailedSubscriptions.Count, ($FailedSubscriptions -join ', ')) -ForegroundColor Red
    Write-Host ("Resume State:            {0}" -f $ResumeStateFile) -ForegroundColor Yellow
    Write-Host "Re-run with -Resume to retry failed and any unprocessed subscriptions." -ForegroundColor Yellow
    Write-Host "Or re-run with -ResumeFailedOnly to retry ONLY the failed subscriptions." -ForegroundColor Yellow
    if ($DiagFile -and (Test-Path -LiteralPath $DiagFile))
    {
        Write-Host ("Failure Diagnostics:     {0}" -f $DiagFile) -ForegroundColor Red
    }
    if ($WrapperTranscriptStarted)
    {
        Write-Host ("Wrapper Transcript:      {0}" -f $WrapperTranscriptFile) -ForegroundColor Red
    }
}
elseif ($FailedAttempts.Count -gt 0)
{
    Write-Host ("Pending Retries:         {0} subscription(s) from a prior run still in FailedAttempts" -f $FailedAttempts.Count) -ForegroundColor Yellow
    Write-Host "Re-run with -ResumeFailedOnly to retry them." -ForegroundColor Yellow
}
Write-Host ("Execution Time:          {0}" -f $Elapsed.ToString('hh\:mm\:ss')) -ForegroundColor Green
if ($OuterZipFile)
{
    Write-Host ("Consolidated Report:     {0}" -f $OuterZipFile) -ForegroundColor Green
}
if ($WrapperTranscriptStarted)
{
    Write-Host ("Wrapper Transcript:      {0}" -f $WrapperTranscriptFile) -ForegroundColor Green
}
Write-Host "=========================================" -ForegroundColor Green

$BundleVer = $Global:Version
try
{
    $BundleVerObj = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Version.json') -Raw | ConvertFrom-Json
    $BundleVer = ('{0}.{1}.{2}' -f $BundleVerObj.MajorVersion, $BundleVerObj.MinorVersion, $BundleVerObj.BuildVersion)
}
catch { Write-Verbose ("Bundle finalize: could not read Version.json: {0}" -f $_.Exception.Message) }

$RunSummaryLocalFile = $null
try
{
    $ConsumptionRecordTotal = if ($null -ne $Global:ConsumptionRecordCount) { [int]$Global:ConsumptionRecordCount } else { 0 }
    $MarketplaceRecordTotal = if ($null -ne $Global:MarketplaceRecordCount) { [int]$Global:MarketplaceRecordCount } else { 0 }
    $MetricsApiCallTotal = if ($null -ne $Global:MetricsApiCallCount) { [int]$Global:MetricsApiCallCount } else { 0 }
    $RunSummaryLines = Get-RunSummaryLogContent `
        -InvocationParameters $PSBoundParameters `
        -Version $BundleVer `
        -StartTime $RunStartTime -EndTime (Get-Date) `
        -Visible $AllSubscriptions.Count -Excluded $Excluded.Count `
        -Eligible $EligibleCount -Processed ($EligibleCount - $SkippedCount) -Skipped $SkippedCount `
        -EmptyNoAccess $NoAccessSubs -EmptyGenuinelyEmpty $GenuinelyEmptySubs -EmptyUndetermined $UnknownSubs `
        -FailedSubscriptions $FailedSubscriptions `
        -CollectorFailures $Global:CollectorFailures `
        -MetricsFailedSubs $Global:MetricsFailedSubs `
        -ConsumptionFailedSubs $Global:ConsumptionFailedSubs `
        -MarketplaceFailedSubs $Global:MarketplaceFailedSubs `
        -ConsumptionRecordCount $ConsumptionRecordTotal `
        -MarketplaceRecordCount $MarketplaceRecordTotal `
        -MetricsApiCallCount $MetricsApiCallTotal `
        -ConsumptionRequested:(-not $SkipConsumption.IsPresent) `
        -MarketplaceRequested:((-not $SkipConsumption.IsPresent) -and (-not $SkipMarketplace.IsPresent)) `
        -MetricsRequested:(-not $SkipMetrics.IsPresent) `
        -HostVCpu $AutoTune.VCpu -HostRamGB $AutoTune.RamGB `
        -Streams $ParallelStreams -StreamsSource $StreamsSrc `
        -Concurrency $ConcurrencyLimit -ConcurrencySource $ConcurrencySrc `
        -Obfuscated:$Obfuscate
    $RunSummaryLocalFile = Join-Path $InventoryRoot ('RunSummary_{0}.log' -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
    $RunSummaryLines | Out-File -LiteralPath $RunSummaryLocalFile -Encoding utf8
    Write-Host ("Run summary written: {0}" -f $RunSummaryLocalFile) -ForegroundColor Green
}
catch
{
    $RunSummaryLocalFile = $null
    Write-Host ("WARNING: Could not generate the run summary: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
}

if ($null -ne $RunSummaryLocalFile -and (Test-Path -LiteralPath $RunSummaryLocalFile) -and `
        $null -ne $OuterZipFile -and (Test-Path -LiteralPath $OuterZipFile))
{
    $RunSummaryStage = $null
    try
    {
        $RunSummaryStage = Join-Path $InventoryRoot ('.rda-runsummary-{0}' -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
        New-Item -ItemType Directory -Path $RunSummaryStage -Force | Out-Null
        Copy-Item -LiteralPath $RunSummaryLocalFile -Destination (Join-Path $RunSummaryStage 'RunSummary.log') -Force
        Compress-Archive -LiteralPath (Join-Path $RunSummaryStage 'RunSummary.log') -DestinationPath ([WildcardPattern]::Escape($OuterZipFile)) -Update

        if (Test-ZipArchiveEntry -ZipPath $OuterZipFile -EntryName 'RunSummary.log')
        {
            Write-Host ("Run summary folded into {0}" -f (Split-Path -Path $OuterZipFile -Leaf)) -ForegroundColor Green
        }
        else
        {
            Write-Host ("WARNING: RunSummary.log did not persist into {0}; the on-disk copy remains at {1}" -f (Split-Path -Path $OuterZipFile -Leaf), $RunSummaryLocalFile) -ForegroundColor Yellow
        }
    }
    catch
    {
        Write-Host ("WARNING: Could not fold RunSummary.log into the consolidated zip (on-disk copy at {0}): {1}" -f $RunSummaryLocalFile, $_.Exception.Message) -ForegroundColor Yellow
    }
    finally
    {
        if ($null -ne $RunSummaryStage) { Remove-Item -LiteralPath $RunSummaryStage -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

$StagedLeafNames = @()
if ($null -ne $OuterZipFile -and (Test-Path -LiteralPath $OuterZipFile))
{
    $BundleStage = $null
    try
    {
        $BundleStage = Join-Path $InventoryRoot ('.rda-bundle-{0}' -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
        New-Item -ItemType Directory -Path $BundleStage -Force | Out-Null

        $StagedMainSummary = Join-Path $BundleStage 'MainSummary.html'
        if ($null -ne $MainSummaryFile -and (Test-Path -LiteralPath $MainSummaryFile))
        {
            Copy-Item -LiteralPath $MainSummaryFile -Destination $StagedMainSummary -Force
            (Get-Content -LiteralPath $StagedMainSummary -Raw) -replace 'href="ResourcesReport', 'href="HTML' | Set-Content -LiteralPath $StagedMainSummary -Encoding utf8
        }

        foreach ($SubDir in @(Get-ChildItem -LiteralPath $InventoryRoot -Directory -Filter 'ResourcesReport*' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $RunStartTime }))
        {
            $SubHtml = Get-ChildItem -LiteralPath $SubDir.FullName -Filter '*.html' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*_revealed*' } | Select-Object -First 1
            if ($null -eq $SubHtml) { continue }
            $HtmlFolderName = ($SubDir.Name -replace '^ResourcesReport', 'HTML')
            $DestDir = Join-Path $BundleStage $HtmlFolderName
            New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
            Copy-Item -LiteralPath $SubHtml.FullName -Destination (Join-Path $DestDir $SubHtml.Name) -Force
        }

        if (-not [string]::IsNullOrEmpty($VmPlacementFile) -and (Test-Path -LiteralPath $VmPlacementFile))
        {
            Copy-Item -LiteralPath $VmPlacementFile -Destination (Join-Path $BundleStage 'VMPlacement.csv') -Force
        }

        $StageItems = @(Get-ChildItem -LiteralPath $BundleStage -Force -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
        if ($StageItems.Count -gt 0)
        {
            Compress-Archive -LiteralPath $StageItems -DestinationPath ([WildcardPattern]::Escape($OuterZipFile)) -Update

            $StagedLeafNames = @($StageItems | ForEach-Object { Split-Path -Path $_ -Leaf })
        }
    }
    catch
    {
        Write-Host ("WARNING: Could not fold main-summary / VM placement CSV / per-subscription HTML into the consolidated zip: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
    finally
    {
        if ($null -ne $BundleStage) { Remove-Item -LiteralPath $BundleStage -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

if ($null -ne $OuterZipFile -and (Test-Path -LiteralPath $OuterZipFile))
{
    $BundleMembers = @()
    try
    {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $FinalArchive = [System.IO.Compression.ZipFile]::OpenRead($OuterZipFile)
        try { $BundleMembers = @($FinalArchive.Entries | ForEach-Object { $_.FullName }) }
        finally { $FinalArchive.Dispose() }
    }
    catch
    {
        Write-Host ("WARNING: could not read {0} to confirm its contents: {1}" -f (Split-Path -Path $OuterZipFile -Leaf), $_.Exception.Message) -ForegroundColor Yellow
    }

    $SubZipCount = @($BundleMembers | Where-Object { $_ -notmatch '[\\/]' -and $_ -like 'ResourcesReport_*.zip' }).Count
    $HtmlFolderCount = @($BundleMembers | Where-Object { $_ -like 'HTML*/*' } | ForEach-Object { ($_ -split '[\\/]')[0] } | Select-Object -Unique).Count
    $HasMainSummary = @($BundleMembers | Where-Object { $_ -ieq 'MainSummary.html' }).Count -gt 0
    $HasPlacementCsv = @($BundleMembers | Where-Object { $_ -ieq 'VMPlacement.csv' }).Count -gt 0
    $HasRunSummary = @($BundleMembers | Where-Object { $_ -ieq 'RunSummary.log' }).Count -gt 0

    Write-Host ""
    Write-Host "================ What to send ================" -ForegroundColor Green
    Write-Host ("SEND THIS ONE FILE:  {0}" -f $OuterZipFile) -ForegroundColor Green
    if ($ShardCount -gt 1)
    {
        Write-Host ("  This is shard {0} of {1} - it covers only this node's subscriptions. Send one such file from EVERY shard; together they cover the tenant once." -f $ShardIndex, $ShardCount) -ForegroundColor Yellow
    }
    Write-Host "  Confirmed contents:" -ForegroundColor Green
    Write-Host ("    - {0} per-subscription data archive(s) (the subscriptions this run processed)" -f $SubZipCount) -ForegroundColor Green
    if ($HasMainSummary) { Write-Host "    - MainSummary.html (tenant-wide summary)" -ForegroundColor Green }
    if ($HtmlFolderCount -gt 0) { Write-Host ("    - {0} per-subscription HTML report folder(s)" -f $HtmlFolderCount) -ForegroundColor Green }
    if ($HasPlacementCsv) { Write-Host "    - VMPlacement.csv (tenant-wide VM placement)" -ForegroundColor Green }
    if ($HasRunSummary) { Write-Host "    - RunSummary.log (run health, needed to triage the bundle)" -ForegroundColor Green }

    $MissingMembers = @($StagedLeafNames | Where-Object { $Leaf = $_; @($BundleMembers | Where-Object { $_ -ieq $Leaf -or $_ -like ($Leaf + '/*') }).Count -eq 0 })
    if ($MissingMembers.Count -gt 0)
    {
        Write-Host ("  WARNING: staged but NOT found inside the bundle: {0}. Their on-disk copies remain under {1}." -f (($MissingMembers | Select-Object -Unique) -join ', '), $InventoryRoot) -ForegroundColor Yellow
    }

    if ($Obfuscate.IsPresent)
    {
        Write-Host ("  Do NOT zip or send the {0} folder itself. It also holds files that must stay local: the obfuscation dictionary (which reverses the masking), the transcripts, and the debug logs." -f (Split-Path -Path $InventoryRoot -Leaf)) -ForegroundColor Yellow
    }
    else
    {
        Write-Host ("  Do NOT zip or send the {0} folder itself. It also holds the PowerShell transcripts, which carry your signed-in account and tenant id." -f (Split-Path -Path $InventoryRoot -Leaf)) -ForegroundColor Yellow
    }
    Write-Host "=============================================" -ForegroundColor Green
}

if ($UploadToBlobContainerUri -and $null -ne $OuterZipFile -and (Test-Path -LiteralPath $OuterZipFile))
{
    try
    {
        $BlobParts = Split-BlobContainerUri -Uri $UploadToBlobContainerUri
        $StorageAccountName = $BlobParts.Account
        $ContainerName = $BlobParts.Container
        $BlobPrefix = $BlobParts.Prefix
        if ([string]::IsNullOrWhiteSpace($StorageAccountName) -or [string]::IsNullOrWhiteSpace($ContainerName))
        {
            throw "Could not parse '<account>' and '<container>' from -UploadToBlobContainerUri '$UploadToBlobContainerUri' (expected https://<account>.blob.core.windows.net/<container>)."
        }

        $ShardTag = if ($ShardCount -gt 1) { 'shard-{0}of{1}-' -f $ShardIndex, $ShardCount } else { '' }
        $BlobName = '{0}{1}{2}' -f $BlobPrefix, $ShardTag, (Split-Path -Path $OuterZipFile -Leaf)

        Write-Host ("Uploading consolidated report to blob: {0} / {1} / {2}" -f $StorageAccountName, $ContainerName, $BlobName) -ForegroundColor Cyan
        $StorageContext = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount -ErrorAction Stop
        $null = Set-AzStorageBlobContent -File $OuterZipFile -Container $ContainerName -Blob $BlobName -Context $StorageContext -Force -ErrorAction Stop
        Write-Host ("Blob upload complete: {0}" -f $BlobName) -ForegroundColor Green

        try
        {
            $DictionaryFiles = @(Get-ChildItem -LiteralPath $InventoryRoot -Recurse -Filter 'ObfuscationDictionary_*.json' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $RunStartTime })
            if ($DictionaryFiles.Count -gt 0)
            {
                Write-Host ("Uploading {0} obfuscation dictionary file(s) to blob (PRIVATE - de-obfuscation key; never share this container as-is)..." -f $DictionaryFiles.Count) -ForegroundColor Cyan
                foreach ($DictFile in $DictionaryFiles)
                {
                    $DictBlobName = '{0}_dictionaries/{1}{2}' -f $BlobPrefix, $ShardTag, $DictFile.Name
                    $null = Set-AzStorageBlobContent -File $DictFile.FullName -Container $ContainerName -Blob $DictBlobName -Context $StorageContext -Force -ErrorAction Stop
                }
                Write-Host ("Obfuscation dictionaries uploaded to {0}/{1}_dictionaries/ (keep PRIVATE)." -f $ContainerName, $BlobPrefix) -ForegroundColor Green
            }
        }
        catch
        {
            Write-Host ("WARNING: Obfuscation dictionary upload failed ({0}). The dictionaries remain on local disk under {1} - capture them before the node is reclaimed if you need token-consistent recovery later." -f $_.Exception.Message, $InventoryRoot) -ForegroundColor Yellow
        }
    }
    catch
    {
        Write-Host ("WARNING: Blob upload failed ({0}). The consolidated zip remains on local disk at: {1}" -f $_.Exception.Message, $OuterZipFile) -ForegroundColor Yellow
    }
}
elseif ($UploadToBlobContainerUri)
{
    $NoZipDetail = if ($OuterZipFile) { "expected zip not found at: $OuterZipFile" } else { 'no consolidated zip was produced' }
    Write-Host ("WARNING: Blob upload was requested (-UploadToBlobContainerUri) but nothing was uploaded - {0}. Check that the run produced an AllSubscriptions_*.zip (look for the earlier 'Consolidated bundle created:' line)." -f $NoZipDetail) -ForegroundColor Yellow
}

$AuthSkippedPhases = @()
if (@($Global:MetricsFailedSubs).Count -gt 0) { $AuthSkippedPhases += 'Metrics' }
$ConsumptionAuthSkipped = @(
    if ($null -ne $Global:ConsumptionFailedSubs) { $Global:ConsumptionFailedSubs } else { @() }
) | Where-Object { $_.Id -eq '(auth)' }
if ($ConsumptionAuthSkipped.Count -gt 0) { $AuthSkippedPhases += 'Consumption' }

if ($AuthSkippedPhases.Count -gt 0)
{
    Write-Host ""
    Write-Host "===================== FAILED (auth) =====================" -ForegroundColor Red
    Write-Host ("Could not collect: {0}" -f ($AuthSkippedPhases -join ' and ')) -ForegroundColor Red
    Write-Host "Reason: no usable Azure context/token (even after one reconnect attempt)." -ForegroundColor Red
    Write-Host "These were requested (no matching -Skip switch) but returned no data." -ForegroundColor Red
    Write-Host "Fix: run Connect-AzAccount (or pass -appid/-secret/-tenant), then re-run." -ForegroundColor Red
    Write-Host "The rest of the inventory completed and the report was still produced." -ForegroundColor Yellow
    Write-Host "=========================================================" -ForegroundColor Red
}

if (@($Global:CollectorFailures).Count -gt 0)
{
    Write-Host ""
    Write-Host "=================== FAILED (collectors) ===================" -ForegroundColor Red
    Write-Host ("{0} collector failure(s) across {1} subscription(s) - see 'Collector Failures' above for detail." -f @($Global:CollectorFailures).Count, (@($Global:CollectorFailures | Select-Object -ExpandProperty Id -Unique)).Count) -ForegroundColor Red
    Write-Host "One or more resource types are MISSING (not empty) from the affected subscription(s)' reports." -ForegroundColor Red
    Write-Host "Re-run to retry, or investigate the error(s) above if they repeat." -ForegroundColor Red
    Write-Host "The rest of the inventory completed and the report was still produced." -ForegroundColor Yellow
    Write-Host "=========================================================" -ForegroundColor Red
}

if (@($ArchiveWriteFailures).Count -gt 0)
{
    Write-Host ""
    Write-Host "=================== FAILED (report archive) ===================" -ForegroundColor Red
    Write-Host ("{0} subscription(s) completed collection but could NOT write a report archive:" -f @($ArchiveWriteFailures).Count) -ForegroundColor Red
    foreach ($A in @($ArchiveWriteFailures))
    {
        Write-Host ("  - {0}" -f $A) -ForegroundColor Red
    }
    Write-Host "Their reports are NOT in the consolidated bundle. The per-subscription log above gives the reason" -ForegroundColor Red
    Write-Host "(free disk space is the usual one). The uncompressed report files are still in each subscription's" -ForegroundColor Red
    Write-Host "report folder under the inventory root and can be zipped by hand instead of re-collecting." -ForegroundColor Red
    Write-Host "==============================================================" -ForegroundColor Red
}

if ($WrapperTranscriptStarted)
{
    try { Stop-Transcript | Out-Null }
    catch { Write-Verbose ("Stop-Transcript on normal completion failed: {0}" -f $_.Exception.Message) }
}

# Marketplace is a deliberately SOFT best-effort phase: a Marketplace-only failure or
# auth-skip does NOT flip the wrapper exit code and does NOT trigger the automatic
# Collect-SupportLogs bundle. This matches its optional, additive nature (it is the
# third-party/Marketplace SaaS slice of consumption, opt-out via -SkipMarketplace and
# implied-skipped by -SkipConsumption) and mirrors how the metric-query call count is
# telemetry-only. Marketplace health is still surfaced (the console 'Marketplace
# Failures:' block, the RunSummary.log Health block, and the MainSummary banner), so a
# truncated Marketplace CSV is never silent - it just does not, by itself, mark the
# whole run failed. First-party Consumption remains a hard-participating phase below.
# See the exit-code table in README.md.
$RunHadFailures = ($FailedSubscriptions.Count -gt 0) -or (@($Global:CollectorFailures).Count -gt 0) -or (@($Global:MetricsFailedSubs).Count -gt 0) -or (@($Global:ConsumptionFailedSubs).Count -gt 0)
if ($RunHadFailures -or -not [string]::IsNullOrWhiteSpace($UploadToBlobContainerUri))
{
    Invoke-RdaSupportLogCollection -InventoryRoot $InventoryRoot -SinceTime $RunStartTime -ContainerUri $UploadToBlobContainerUri -ShardIndex $ShardIndex -ShardCount $ShardCount
}

$AuthSkipped = $AuthSkippedPhases.Count -gt 0
$CollectorsFailed = @($Global:CollectorFailures).Count -gt 0
$WrapperExitCode = Get-WrapperExitCode -AuthSkipped $AuthSkipped -CollectorsFailed $CollectorsFailed

if (@($ArchiveWriteFailures).Count -gt 0)
{
    $WrapperExitCode = 2
}
exit $WrapperExitCode

