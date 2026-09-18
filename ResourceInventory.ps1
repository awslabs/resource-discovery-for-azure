#!/usr/bin/env pwsh
# [CmdletBinding()] makes this an ADVANCED script so the binder REJECTS unknown args (a mistyped -Obfuscate must not run the whole inventory UNOBFUSCATED).
# No [switch]$Debug in the param block: -Debug is a CmdletBinding common param and redeclaring it is a fatal MetadataError; the built-in one drives the -Debug branches below.
[CmdletBinding()]
param ($TenantID,
    $Appid,
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$', ErrorMessage = 'Invalid SubscriptionID; must be a GUID')]
    [string]$SubscriptionID,
    [securestring]$Secret,
    [ValidatePattern('^[A-Za-z0-9._()-]{1,90}$', ErrorMessage = 'Invalid resource group name; must match ^[A-Za-z0-9._()-]{1,90}$')]
    [string]$ResourceGroup,
    [string[]]$Service,
    [string]$ObfuscationDictionary,
    [switch]$SkipMetrics,
    [switch]$SkipConsumption,
    [switch]$DeviceLogin,
    [switch]$Obfuscate,
    [switch]$RunAllSubs,
    # EXPERIMENTAL (default OFF), forwarded to Extension/Metrics.ps1: collect VM CPU/memory via the Azure Monitor metrics:getBatch data-plane API instead of per-call Get-AzMetric,
    # falling back to the per-call path on any batch failure (no data lost).
    [switch]$UseMetricsBatch,
    # Metric-volume controls forwarded to Extension/Metrics.ps1: -IncludeStorageMetrics OPTS IN to the costly per-account Storage UsedCapacity metric (OFF by default),
    # -SkipDiskMetrics drops disk I/O metrics, -MetricsIntervalMinutes overrides the VM/SQL/OSS-DB sampling grain (0 = native).
    [switch]$IncludeStorageMetrics,
    [switch]$SkipDiskMetrics,
    # OPT-IN (default OFF): produce the capacity-planning VM placement CSV (Extension/VMPlacement.ps1).
    # Without it no VMPlacement*.csv is written or packaged. A SEPARATE file, so no other output schema changes.
    [switch]$CapacityPlan,
    [ValidateSet(0, 5, 15, 30, 60)][int]$MetricsIntervalMinutes = 0,
    # -MetricsDetailed restores the native (finer) sampling grain; the default is hourly, matching upstream.
    [switch]$MetricsDetailed,
    $ConcurrencyLimit = 6,
    $MetricsLookbackDays = 31,
    $ReportName = 'ResourcesReport',
    $OutputDirectory)

# ---------------------------------------------------------------------------
# Load shared helper functions. Dot-sourced (NOT invoked via &) so they load
# into this script's scope. Fail loud if the file is missing rather than
# breaking later with a confusing "command not found".
# ---------------------------------------------------------------------------
$FunctionsFile = Join-Path $PSScriptRoot 'Functions/ResourceInventory.Functions.ps1'
if (-not (Test-Path -LiteralPath $FunctionsFile -PathType Leaf))
{
    Write-Host "ERROR: Required functions file not found: $FunctionsFile" -ForegroundColor Red
    Write-Host "Ensure the 'Functions' folder ships alongside this script." -ForegroundColor Yellow
    exit 1
}
. $FunctionsFile

# Shared cross-cutting helpers (Write-RdaProgress). Same dot-source pattern.
$CommonFunctionsFile = Join-Path $PSScriptRoot 'Functions/Common.Functions.ps1'
if (-not (Test-Path -LiteralPath $CommonFunctionsFile -PathType Leaf))
{
    Write-Host "ERROR: Required functions file not found: $CommonFunctionsFile" -ForegroundColor Red
    Write-Host "Ensure the 'Functions' folder ships alongside this script." -ForegroundColor Yellow
    exit 1
}
. $CommonFunctionsFile


# -Debug (a common param) has ALREADY set $DebugPreference before this runs, so Write-Debug needs no help here; $DebugMode only feeds the $ErrorActionPreference choice below.
# Read the VALUE, not ContainsKey: '-Debug:$false' is bound-but-false, so a presence test wrongly treats an explicit opt-OUT as opt-IN (matching the two forwarding sites in Run-AllSubscriptions*.ps1).
$DebugMode = ($PSBoundParameters.ContainsKey('Debug') -and [bool]$PSBoundParameters['Debug'])

# Non-Debug runs deliberately default $ErrorActionPreference to SilentlyContinue so the long tail of trivial per-resource errors is swallowed and a partial inventory still completes; high-value phases opt into Stop themselves. Do NOT 'fix' this default.
# Honor an explicitly-passed -ErrorAction (now accepted as an advanced script) instead of clobbering it; with none passed, behavior is byte-for-byte unchanged.
if (-not $PSBoundParameters.ContainsKey('ErrorAction'))
{
    $ErrorActionPreference = if ($DebugMode) { 'Continue' } else { 'SilentlyContinue' }
}

Write-Debug ('Debugging Mode: On. ErrorActionPreference is "{0}", every error will be presented.' -f $ErrorActionPreference)



function Variables
{
    $Global:ResourceContainers = @()
    $Global:Resources = @()
    $Global:Subscriptions = ''
    $Global:ReportName = $ReportName
    $Global:Version = GetLocalVersion

    $Global:ResourceIdDictionary = $null
    $Global:ResourceNameDictionary = $null
    $Global:ResourceSubscriptionDictionary = $null
    $Global:ResourceResourceGroupDictionary = $null
    # Maps a REAL tag value to its deterministic obfuscated token (real -> token).
    # Tag values are obfuscated like the other identifier classes (same real value
    # always yields the same token within a run) so the obfuscated report can still
    # group/correlate by tag value without exposing it. Tag KEYS are kept verbatim.
    $Global:TagValueDictionary = $null
    # Maps a REAL free-text/identity value (Description, FriendlyName, CreatedBy, RoleName, container image, etc.) to a deterministic obfuscated token, so these formerly-dropped fields stay out of the shared report yet remain locally reversible via FreeTextMap.
    $Global:FreeTextDictionary = $null

    if ($Obfuscate.IsPresent)
    {
        # The four IDENTIFIER dictionaries are OrdinalIgnoreCase: ARM ids / sub-ids / RG names are case-insensitive per Azure spec, so a case-sensitive key MISSES silently (broken cross-refs, unjoined consumption rows, a re-tokenised -ObfuscationDictionary seed).
        # TagValueDictionary and FreeTextDictionary stay CASE-SENSITIVE deliberately: Azure tag values are case-sensitive, so collapsing 'Env=Prod' and 'Env=prod' onto one token would lose a real distinction.
        $Global:ResourceIdDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $Global:ResourceNameDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $Global:ResourceSubscriptionDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $Global:ResourceResourceGroupDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        # Case-SENSITIVE on purpose - see the note above.
        $Global:TagValueDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:FreeTextDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    }

    $Global:RawRepo = 'https://raw.githubusercontent.com/awslabs/resource-discovery-for-azure/main'
    $Global:TableStyle = "Medium15"
}



function RunInventorySetup()
{
    function CheckVersion()
    {
        # Version banner + GitHub update check run once per PowerShell session (gated on $Global:RdaSessionInitialized): under -RunAllSubs this script is invoked per-subscription in the SAME process and neither varies by sub. Parallel streams are separate processes and each checks once.
        if ($Global:RdaSessionInitialized)
        {
            return
        }

        Write-Log -Message ('Checking Version') -Severity 'Info'
        Write-Log -Message ('Version: {0}' -f $Global:Version) -Severity 'Info'

        # Best-effort: on a network that blocks raw.githubusercontent.com this WebClient call would otherwise raise SocketException and abort the subscription before any inventory. Log a clear note and continue on the local version (#18).
        try
        {
            $VersionJson = (New-Object System.Net.WebClient).DownloadString($RawRepo + '/Version.json') | ConvertFrom-Json
        }
        catch
        {
            Write-Log -Message ("Could not reach {0}/Version.json to check for an update: {1}" -f $RawRepo, $_.Exception.Message) -Severity 'Warning'
            Write-Log -Message ('Continuing with local version {0}. If you are on a managed network, this is expected.' -f $Global:Version) -Severity 'Info'
            return
        }

        $VersionNumber = ('{0}.{1}.{2}' -f $VersionJson.MajorVersion, $VersionJson.MinorVersion, $VersionJson.BuildVersion)

        if ($VersionNumber -ne $Global:Version)
        {
            # A version difference is informational, not fatal: aborting on any mismatch blocked slightly-behind, managed-clone, and AHEAD dev builds. Compare as semver so the note reflects behind vs ahead, and continue (mirroring the network-failure branch above).
            $LocalParsed = $null
            $UpstreamParsed = $null
            $HaveSemver = [version]::TryParse($Global:Version, [ref]$LocalParsed) -and `
                [version]::TryParse($VersionNumber, [ref]$UpstreamParsed)

            if ($HaveSemver -and $LocalParsed -lt $UpstreamParsed)
            {
                Write-Log -Message ('A newer version ({0}) is available; you are running {1}. Consider updating: https://github.com/awslabs/resource-discovery-for-azure' -f $VersionNumber, $Global:Version) -Severity 'Warning'
            }
            elseif ($HaveSemver -and $LocalParsed -gt $UpstreamParsed)
            {
                Write-Log -Message ('Running a local/pre-release version ({0}); latest published is {1}.' -f $Global:Version, $VersionNumber) -Severity 'Info'
            }
            else
            {
                Write-Log -Message ('Local version ({0}) differs from the latest published version ({1}).' -f $Global:Version, $VersionNumber) -Severity 'Warning'
            }
            # Continue the run regardless - a version check must not gate the
            # inventory (consistent with the network-failure branch above).
        }
    }

    function CheckCliRequirements()
    {
        # Az module check + import run once per PowerShell session (gated on $Global:AzPowerShellLoaded; the imports persist process-wide): under -RunAllSubs this runs per-sub in the same process. The flag stays $false on a failed load so the next sub retries; parallel streams load once each.
        if ($Global:AzPowerShellLoaded)
        {
            return
        }

        # Resource discovery uses the native Az.ResourceGraph cmdlet
        # (Search-AzGraph), so the Azure CLI and its resource-graph extension are
        # no longer prerequisites - only the Az PowerShell modules below are
        # checked/loaded. A module cmdlet is also portable by construction, with no
        # per-OS shell layer between us and the call.
        Write-Log -Message ('Checking Azure PowerShell Module...') -Severity 'Info'

        # Validate/load ONLY the five Az submodules this tool calls (Az.Accounts, Az.Compute, Az.Monitor, Az.Billing, Az.ResourceGraph), NOT the ~80-module Az rollup, so a slim install is sufficient.
        # Checking the submodules (not the Az umbrella) is what lets a slim install pass, since it has no Az meta-module; the full rollup also satisfies it because each submodule is independently discoverable.
        $RequiredAzSubModules = @('Az.Accounts', 'Az.Compute', 'Az.Monitor', 'Az.Billing', 'Az.ResourceGraph')

        $MissingAzSubModules = @($RequiredAzSubModules | Where-Object { $null -eq (Get-Module -Name $_ -ListAvailable -ErrorAction SilentlyContinue | Select-Object -First 1) })

        if ($MissingAzSubModules.Count -eq 0)
        {
            $VarAzPs = Get-Module -Name Az.Accounts -ListAvailable -ErrorAction SilentlyContinue | Select-Object -First 1
            Write-Log -Message ('Azure PowerShell modules present (Az.Accounts {0}); required: {1}' -f $VarAzPs.Version, ($RequiredAzSubModules -join ', ')) -Severity 'Success'
        }
        else
        {
            # Deliberately do NOT Install-Module from inside this script: a field run left a half-installed Az (manifests present, MSAL/Azure.Core assemblies missing) that ran ~an hour producing zero consumption. In-process installs of a module already importing are fragile and fail silently, so fail loud here instead.
            Write-Log -Message ('Required Azure PowerShell module(s) not found: {0}' -f ($MissingAzSubModules -join ', ')) -Severity 'Error'
            Write-Log -Message ('This tool needs only these Az submodules. Install them manually before re-running. From an elevated PowerShell 7 prompt:') -Severity 'Error'
            Write-Log -Message ('  Install-Module -Name {0} -Repository PSGallery -Force -AllowClobber -SkipPublisherCheck' -f ($RequiredAzSubModules -join ',')) -Severity 'Error'
            Write-Log -Message ('Or install the full rollup (larger, slower first import): Install-Module -Name Az -Repository PSGallery -Force -AllowClobber -SkipPublisherCheck') -Severity 'Error'
            Write-Log -Message ('Or in Cloud Shell, the Az module is already preinstalled - if it is missing your shell environment is broken.') -Severity 'Error'
            throw ('Required Azure PowerShell submodule(s) not found: {0}. See log above for installation instructions.' -f ($MissingAzSubModules -join ', '))
        }

        # Import ONLY the five submodules used, NOT the Az rollup (which pulls ~80 modules and stalls 20-40s with no output, looking like a hang).
        # This import also doubles as the broken-install probe: unlike the -ListAvailable manifest check, importing Az.Accounts actually loads MSAL/Azure.Core, so a half-installed module fails loudly HERE instead of silently producing zero data at the consumption phase.
        try
        {
            foreach ($AzSubModule in $RequiredAzSubModules)
            {
                Write-Log -Message ('Loading {0}...' -f $AzSubModule) -Severity 'Info'
                Import-Module $AzSubModule -ErrorAction Stop -DisableNameChecking | Out-Null
            }
            $Global:AzPowerShellLoaded = $true
        }
        catch
        {
            Write-Log -Message ('Azure PowerShell module is present on disk but failed to load: {0}' -f $_.Exception.Message) -Severity 'Error'
            Write-Log -Message ('This usually indicates a broken install - the module manifest is present but its bundled assemblies (MSAL, Azure.Core, etc.) are missing or unloadable.') -Severity 'Error'
            Write-Log -Message ('Reinstall with: Install-Module -Name Az -Repository PSGallery -Force -AllowClobber -SkipPublisherCheck') -Severity 'Error'
            Write-Log -Message ('If the broken install was created by a previous run of this script, also run: Get-Module Az* -ListAvailable | Uninstall-Module -Force') -Severity 'Error'
            $Global:AzPowerShellLoaded = $false
            throw "Azure PowerShell (Az) module is broken on disk and cannot be loaded. See log above for remediation."
        }


        # NOTE: the ImportExcel/EPPlus preflight that lived here was removed when the report moved from Excel (.xlsx) to a self-contained HTML report (Extension/Summary.ps1), which has no external module dependency to preflight.
    }

    function CheckPowerShell()
    {
        # Platform / PS-version detection runs once per PowerShell session (Variables() does not reset $Global:PlatformOS): under -RunAllSubs this runs per-sub in the same process. The per-subscription timestamp + report-folder computation below still runs every invocation.
        if (-not $Global:RdaSessionInitialized)
        {
            Write-Log -Message ('Checking PowerShell...') -Severity 'Info'

            $Global:PlatformOS = 'PowerShell Desktop'
            $CloudShell = try { Get-CloudDrive }catch {}

            if ($CloudShell)
            {
                Write-Log -Message ('Identified Environment as Azure CloudShell') -Severity 'Success'
                $Global:PlatformOS = 'Azure CloudShell'
            }
            elseif ($PSVersionTable.Platform -eq 'Unix')
            {
                Write-Log -Message ('Identified Environment as PowerShell Unix') -Severity 'Success'
                $Global:PlatformOS = 'PowerShell Unix'
            }
            else
            {
                Write-Log -Message ('Identified Environment as PowerShell Desktop') -Severity 'Success'
                $Global:PlatformOS = 'PowerShell Desktop'

                $PsVersion = $PSVersionTable.PSVersion.Major
                Write-Log -Message ("PowerShell Version {0}" -f $PsVersion) -Severity 'Info'

                if ($PSVersionTable.PSVersion.Major -lt 7)
                {
                    Write-Log -Message ("You must use Powershell 7 to run the inventory script.") -Severity 'Error'
                    Write-Log -Message ("https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows?view=powershell-7.3") -Severity 'Error'
                    exit
                }
            }
        }

        # Per-subscription: a fresh report folder every invocation. Millisecond precision plus a 4-char per-process discriminator are REQUIRED because parallel-stream child processes can start in the same second - without them two workers compute the same folder and the second Compress-Archive fails 'already exists'.
        # Invisible to consumers: the discriminator is hex-only/length-stable and every downstream glob wildcards the timestamp segment.
        $ProcDiscriminator = ('{0:x4}' -f ($PID -band 0xffff))
        # InvariantCulture: 'Get-Date -Format' takes the YEAR from CurrentCulture's
        # Calendar, so a th-TH host stamped 2569... and an ar-SA host 1448... into
        # $Global:FolderName and every output filename. Measured byte-identical to the
        # previous expression on any Gregorian culture, and the digit count is unchanged
        # (17), so the existing *<timestamp>* glob filters keep matching either way.
        $Global:CurrentDateTime = ((Get-Date).ToString('yyyyMMddHHmmssfff', [cultureinfo]::InvariantCulture) + $ProcDiscriminator)
        $Global:FolderName = $Global:ReportName + $CurrentDateTime

        # Base output root comes from the SINGLE resolver in Functions/Common.Functions.ps1 (already pinned by this script's pre-flight or by Run-AllSubscriptions.ps1), so it resolves to the SAME validated directory - which is what keeps the wrapper's consolidation and the inner output in agreement.
        # Still ends with a trailing separator: $Global:DefaultPath is string-concatenated with filenames throughout this script, and the log parent-dir logic does Split-Path on it.
        $RootForRun = Get-RdaInventoryRoot
        if (-not $RootForRun.Ok)
        {
            Write-Log -Message $RootForRun.Message -Severity 'Error'
            exit
        }
        if ($RootForRun.IsFallback)
        {
            Write-Log -Message $RootForRun.Message -Severity 'Warning'
        }
        $DefaultOutputDir = (Join-Path $RootForRun.Path $Global:FolderName) + [IO.Path]::DirectorySeparatorChar

        if ($OutputDirectory)
        {
            try
            {
                $OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory -ErrorAction Stop).Path + [IO.Path]::DirectorySeparatorChar
            }
            catch
            {
                Write-Log -Message ("Wrong OutputDirectory Path! OutputDirectory Parameter must contain the full path.") -Severity 'Error'
                exit
            }
        }

        $Global:DefaultPath = if ($OutputDirectory) { $OutputDirectory } else { $DefaultOutputDir }

        if ($platformOS -eq 'Azure CloudShell')
        {
            $Global:Subscriptions = @(Get-AzSubscription -WarningAction SilentlyContinue)
        }
        elseif ($platformOS -eq 'PowerShell Unix' -or $platformOS -eq 'PowerShell Desktop')
        {
            LoginSession
        }
    }

    function LoginSession()
    {
        # Resolve the current Az PowerShell context once and reuse it for both the
        # display banner and the already-authenticated check. Using the native Az
        # context (not `az account show`) means there is a single source of truth
        # for auth state - the tool no longer has to reconcile a separate az CLI
        # login with the Az PS context.
        $ExistingContext = Get-AzContext -ErrorAction SilentlyContinue

        # Display-only banner: the active Azure cloud environment does not change
        # between subscriptions in a session, so print it once. This also skips a
        # redundant lookup per subscription under -RunAllSubs. The auth logic below
        # (the context check and Connect-AzAccount) is OUTSIDE this guard and still
        # runs on every invocation, unchanged.
        if (-not $Global:RdaSessionInitialized)
        {
            $CurrentCloudEnvName = if ($ExistingContext) { $ExistingContext.Environment.Name } else { 'AzureCloud' }
            Write-Host "Azure Cloud Environment: " -NoNewline
            Write-Host $CurrentCloudEnvName -ForegroundColor Green
        }

        # Check if already authenticated (a non-null Az context means we are)
        if ($null -ne $ExistingContext)
        {
            # Display-only: report the authenticated identity once per session. The
            # tenant comparison below still runs every sub.
            if (-not $Global:RdaSessionInitialized)
            {
                Write-Log -Message ("Already authenticated as: {0}" -f $ExistingContext.Account.Id) -Severity 'Success'
            }

            if (!$TenantID -or $ExistingContext.Tenant.Id -eq $TenantID)
            {
                # The existing context already matches the requested tenant (or no
                # tenant was requested), so no reconnect is needed. Per-subscription
                # scoping happens later via Set-AzContext / resource-id parameters on
                # Get-AzMetric, so the context only needs to match the tenant.
                $Global:Subscriptions = @(Get-AzSubscription -WarningAction SilentlyContinue)
                if ($TenantID) { $Global:Subscriptions = @($Subscriptions | Where-Object { $_.HomeTenantId -eq $TenantID }) }
                return
            }
            else
            {
                Write-Log -Message ("Current session is for tenant {0}, but requested tenant is {1}. Re-authenticating." -f $ExistingContext.Tenant.Id, $TenantID) -Severity 'Warning'
            }
        }

        if (!$TenantID)
        {
            Write-Log -Message ('Tenant ID not specified. Use -TenantID parameter if you want to specify directly.') -Severity 'Warning'
            Write-Log -Message ('Authenticating Azure') -Severity 'Info'

            Write-Log -Message ('Clearing account cache') -Severity 'Info'

            if (!$RunAllSubs.IsPresent)
            {
                Disconnect-AzAccount -ErrorAction SilentlyContinue | Out-Null
            }

            # Suppress Az's own debug chatter across interactive sign-in, then RESTORE the incoming value - not a literal 'Continue', which turned debug output on for the rest of this function even under -Debug:$false (the same opt-out-read-as-opt-in defect fixed at the top of the script). Function-scoped, so the effect ends at return; saving the value is also what keeps -Debug working.
            $SavedDebugPref = $DebugPreference
            $DebugPreference = "SilentlyContinue"

            if (!$RunAllSubs.IsPresent)
            {
                Write-Log -Message ('Calling Login, the browser will open and prompt you to login.') -Severity 'Info'
                if ($DeviceLogin.IsPresent)
                {
                    Write-Log -Message ('Using device login') -Severity 'Info'
                    Connect-AzAccount -UseDeviceAuthentication | Out-Null
                }
                else
                {
                    Write-Log -Message ('Using browser login') -Severity 'Info'
                    Connect-AzAccount | Out-Null
                }
            }

            $DebugPreference = $SavedDebugPref

            $Tenants = (Get-AzSubscription -WarningAction SilentlyContinue).HomeTenantId | Sort-Object -Unique

            Write-Log -Message ('Checking number of Tenants') -Severity 'Info'

            if ($Tenants.Count -eq 1)
            {
                Write-Log -Message ('You have privileges only in One Tenant') -Severity 'Success'
                $TenantID = $Tenants
            }
            else
            {
                Write-Log -Message ('Select the the Azure Tenant ID that you want to connect: ') -Severity 'Warning'

                $SequenceID = 1
                foreach ($TenantID in $Tenants)
                {
                    Write-Host "$SequenceID)  $TenantID"
                    $SequenceID ++
                }

                # A Read-Host tenant prompt blocks forever under the wrapper, a parallel worker, SSM, or CI where there is no console. Detect a non-interactive session and default to the first tenant (the prompt's 'Default 1'); pass -TenantID to skip this path entirely.
                $IsInteractiveSession = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
                if ($RunAllSubs.IsPresent -or -not $IsInteractiveSession)
                {
                    $TenantID = $Tenants[0]
                    Write-Log -Message ("Non-interactive session with multiple tenants and no -TenantID: defaulting to the first tenant ({0}). Pass -TenantID to choose explicitly." -f $TenantID) -Severity 'Warning'
                }
                else
                {
                    [int]$SelectTenant = Read-Host "Select Tenant (Default 1)"
                    if ($SelectTenant -lt 1) { $SelectTenant = 1 }
                    $TenantID = $Tenants[$SelectTenant - 1]
                }

                if (!$RunAllSubs.IsPresent)
                {
                    if ($DeviceLogin.IsPresent)
                    {
                        Connect-AzAccount -UseDeviceAuthentication -Tenant $TenantID | Out-Null
                    }
                    else
                    {
                        Connect-AzAccount -Tenant $TenantID | Out-Null
                    }
                }
            }

            Write-Log -Message ("Extracting from Tenant $TenantID") -Severity 'Info'
            Write-Log -Message ("Extracting Subscriptions") -Severity 'Info'

            $Global:Subscriptions = @(Get-AzSubscription -WarningAction SilentlyContinue)
            $Global:Subscriptions = @($Subscriptions | Where-Object { $_.HomeTenantId -eq $TenantID })
        }
        else
        {

            if (!$RunAllSubs.IsPresent)
            {
                Disconnect-AzAccount -ErrorAction SilentlyContinue | Out-Null

                if (!$Appid)
                {
                    if ($DeviceLogin.IsPresent)
                    {
                        Connect-AzAccount -UseDeviceAuthentication -Tenant $TenantID | Out-Null
                    }
                    else
                    {
                        Connect-AzAccount -Tenant $TenantID | Out-Null
                    }
                }
                elseif ($Appid -and $Secret -and $tenantid)
                {
                    Write-Log -Message ("Using Service Principal Authentication Method") -Severity 'Success'
                    # Az PowerShell accepts the SecureString secret directly via a
                    # PSCredential, so the secret never has to be converted to plaintext
                    # (unlike the old az CLI --password-stdin path this replaced).
                    $Credential = New-Object System.Management.Automation.PSCredential($Appid, $Secret)
                    Connect-AzAccount -ServicePrincipal -Credential $Credential -Tenant $TenantID | Out-Null
                }
                else
                {
                    Write-Log -Message ("You are trying to use Service Principal Authentication Method in a wrong way.") -Severity 'Error'
                    Write-Log -Message ("It's Mandatory to specify Application ID, Secret and Tenant ID in Azure Resource Inventory") -Severity 'Error'
                    Write-Log -Message (".\ResourceInventory.ps1 -appid <SP AppID> -secret <SP Secret> -tenant <TenantID>") -Severity 'Error'
                    exit
                }
            }

            $Global:Subscriptions = @(Get-AzSubscription -WarningAction SilentlyContinue)
            $Global:Subscriptions = @($Subscriptions | Where-Object { $_.HomeTenantId -eq $TenantID })
        }
    }

    function GetSubscriptionsData()
    {
        $SubscriptionCount = $Subscriptions.Count

        # The subscription count is tenant-wide and does not change between subs,
        # so under -RunAllSubs (same process) print it only once per session. The
        # report-folder check/creation below stays per-subscription because each
        # subscription writes to its own timestamped folder.
        if (-not $Global:RdaSessionInitialized)
        {
            Write-Log -Message ("Number of Subscriptions Found: {0}" -f $SubscriptionCount) -Severity 'Info'
        }

        Write-Log -Message ("Checking report folder: {0}" -f $DefaultPath) -Severity 'Info'

        if ((Test-Path -LiteralPath $DefaultPath -PathType Container) -eq $false)
        {
            # -ErrorAction Stop + catch: without it this inherited the run's SilentlyContinue, so a failed report-folder creation was invisible and every subsequent write into it failed one-by-one with no statement of the cause. Reaching here is unusual (parent root already write-probed) but it must name the problem.
            try
            {
                New-Item -Type Directory -Force -Path $DefaultPath -ErrorAction Stop | Out-Null
            }
            catch
            {
                Write-Log -Message ("Could not create the report folder {0}: {1}" -f $DefaultPath, $_.Exception.Message) -Severity 'Error'
                Write-Log -Message ("No report can be written for this run. Verify the location is writable, or pass -OutputDirectory with a writable path.") -Severity 'Error'
                exit
            }
        }

        # Mark session init complete: subsequent subscriptions in the same process now skip the version check, platform detection, and the subscription-count line above. Single place the flag is set; nothing resets it mid-session; parallel streams are separate processes that each set it once.
        $Global:RdaSessionInitialized = $true
    }

    function ResourceInventoryLoop()
    {
        if (![string]::IsNullOrEmpty($ResourceGroup) -and [string]::IsNullOrEmpty($SubscriptionID))
        {
            Write-Log -Message ("Resource Group Name present, but missing Subscription ID.") -Severity 'Error'
            Write-Log -Message ("If using ResourceGroup parameter you must also put SubscriptionId") -Severity 'Error'
            exit
        }

        if (![string]::IsNullOrEmpty($ResourceGroup))
        {
            $ResourceGroup = $ResourceGroup.ToLower()
        }

        if (![string]::IsNullOrEmpty($ResourceGroup) -and ![string]::IsNullOrEmpty($SubscriptionID))
        {
            Write-Log -Message ('Extracting Resources from Subscription: ' + $SubscriptionID + '. And from Resource Group: ' + $ResourceGroup) -Severity 'Success'

            $GraphQuery = "resources | where resourceGroup == '$ResourceGroup' and (isnull(properties.definition.actions) or strlen(properties.definition.actions) < 123000) | summarize count()"
            $EnvSize = Invoke-AzGraphQuerySafe -Query $GraphQuery -Subscription $SubscriptionID
            $EnvSizeNum = $EnvSize.data.count_

            if ($EnvSizeNum -ge 1)
            {
                $Loop = $EnvSizeNum / 1000
                $Loop = [math]::ceiling($Loop)
                $Looper = 0
                $Limit = 0

                while ($Looper -lt $Loop)
                {
                    $GraphQuery = "resources | where resourceGroup == '$ResourceGroup' and (isnull(properties.definition.actions) or strlen(properties.definition.actions) < 123000) | project id,name,type,tenantId,kind,location,resourceGroup,subscriptionId,managedBy,sku,plan,properties,identity,zones,extendedLocation,tags | order by id asc"
                    $Resource = Invoke-AzGraphQuerySafe -Query $GraphQuery -Subscription $SubscriptionID -Skip $Limit -First 1000 -Lowercase

                    $Global:Resources += $Resource.data
                    Start-Sleep 2
                    $Looper ++
                    $Limit = $Limit + 1000
                }
            }
        }
        elseif ([string]::IsNullOrEmpty($ResourceGroup) -and ![string]::IsNullOrEmpty($SubscriptionID))
        {
            Write-Log -Message ('Extracting Resources from Subscription: ' + $SubscriptionID) -Severity 'Success'

            $GraphQuery = "resources | where (isnull(properties.definition.actions) or strlen(properties.definition.actions) < 123000) | summarize count()"
            $EnvSize = Invoke-AzGraphQuerySafe -Query $GraphQuery -Subscription $SubscriptionID
            $EnvSizeNum = $EnvSize.data.count_

            if ($EnvSizeNum -ge 1)
            {
                $Loop = $EnvSizeNum / 1000
                $Loop = [math]::ceiling($Loop)
                $Looper = 0
                $Limit = 0

                while ($Looper -lt $Loop)
                {
                    $GraphQuery = "resources | where (isnull(properties.definition.actions) or strlen(properties.definition.actions) < 123000) | project id,name,type,tenantId,kind,location,resourceGroup,subscriptionId,managedBy,sku,plan,properties,identity,zones,extendedLocation,tags | order by id asc"
                    $Resource = Invoke-AzGraphQuerySafe -Query $GraphQuery -Subscription $SubscriptionID -Skip $Limit -First 1000 -Lowercase

                    $Global:Resources += $Resource.data
                    Start-Sleep 2
                    $Looper ++
                    $Limit = $Limit + 1000
                }
            }
        }
        else
        {
            $GraphQuery = "resources | where (isnull(properties.definition.actions) or strlen(properties.definition.actions) < 123000) | summarize count()"
            $EnvSize = Invoke-AzGraphQuerySafe -Query $GraphQuery
            $EnvSizeCount = $EnvSize.data.count_

            Write-Log -Message ("Resources Output: {0} Resources Identified" -f $EnvSizeCount) -Severity 'Success'

            if ($EnvSizeCount -ge 1)
            {
                $Loop = $EnvSizeCount / 1000
                $Loop = [math]::Ceiling($Loop)
                $Looper = 0
                $Limit = 0

                while ($Looper -lt $Loop)
                {
                    $GraphQuery = "resources | where (isnull(properties.definition.actions) or strlen(properties.definition.actions) < 123000) | project id,name,type,tenantId,kind,location,resourceGroup,subscriptionId,managedBy,sku,plan,properties,identity,zones,extendedLocation,tags | order by id asc"
                    $Resource = Invoke-AzGraphQuerySafe -Query $GraphQuery -Skip $Limit -First 1000 -Lowercase

                    $Global:Resources += $Resource.data
                    Start-Sleep 2
                    $Looper++
                    $Limit = $Limit + 1000
                }
            }
        }
    }

    function ResourceInventoryAvd()
    {
        $AVDSize = Invoke-AzGraphQuerySafe -Query "desktopvirtualizationresources | summarize count()"
        $AVDSizeCount = $AVDSize.data.count_

        Write-Log -Message ("AVD Resources Output: {0} AVD Resources Identified" -f $AVDSizeCount) -Severity 'Success'

        if ($AVDSizeCount -ge 1)
        {
            $Loop = $AVDSizeCount / 1000
            $Loop = [math]::ceiling($Loop)
            $Looper = 0
            $Limit = 0

            while ($Looper -lt $Loop)
            {
                $GraphQuery = "desktopvirtualizationresources | project id,name,type,tenantId,kind,location,resourceGroup,subscriptionId,managedBy,sku,plan,properties,identity,zones,extendedLocation,tags | order by id asc"
                $AVD = Invoke-AzGraphQuerySafe -Query $GraphQuery -Skip $Limit -First 1000 -Lowercase

                $Global:Resources += $AVD.data
                Start-Sleep 2
                $Looper++
                $Limit = $Limit + 1000
            }
        }
    }

    CheckVersion
    CheckCliRequirements
    CheckPowerShell
    GetSubscriptionsData

    # Wrap resource discovery in ONE catch: both paging loops append pages ($Global:Resources += $Resource.data) with no local guard, and under the run's SilentlyContinue a terminating error with no catch up-stack does not stop anything - a failed page silently re-appended the PREVIOUS page, producing a plausible-looking total that missed ~1000 real resources.
    # One catch covers every discovery call site; exit 1 (not throw) is this script's hard-fail signal at script scope, so the wrapper marks the sub failed and -Resume can retry it.
    try
    {
        ResourceInventoryLoop
        ResourceInventoryAvd
    }
    catch
    {
        Write-Log -Message ("FAILED to complete resource discovery: {0}" -f $_.Exception.Message) -Severity 'Error'
        Write-Log -Message ('  The inventory for this subscription would be INCOMPLETE, so it is reported as failed rather than written to a report. Re-run with -Resume to retry it.') -Severity 'Error'
        Write-Log -Message ('  If this is a Resource Graph response-size failure on one specific resource type, exclude that type from the discovery query to let the rest of the subscription complete.') -Severity 'Error'
        exit 1
    }

    if ($Obfuscate.IsPresent)
    {
        # Lookup tables keyed by real subscription name / real RG name so the same
        # real value always maps to the same obfuscated value across resources.
        $SubLookup = @{}
        $RgLookup = @{}

        # -ObfuscationDictionary seeding: preload the maps from a prior run's saved (token->real) file so identical real values yield the SAME tokens, letting a scoped recovery run merge back into the earlier bundle; new values still mint fresh tokens (determinism EXTENDED, not broken).
        # Subscription/ResourceGroup tokens are SHARED per sub/RG so they cannot be reused ID-keyed - rebuild the real-value-keyed $subLookup/$rgLookup the mint logic consults (sub name from SubscriptionNameMap; RG name parsed from each ResourceGroupMap representative id).
        if (-not [string]::IsNullOrEmpty($ObfuscationDictionary))
        {
            $SeedDictionary = Get-Content -LiteralPath $ObfuscationDictionary -Raw | ConvertFrom-Json

            if ($null -ne $SeedDictionary.ResourceIdMap)
            {
                foreach ($SeedProp in $SeedDictionary.ResourceIdMap.PSObject.Properties) { $ResourceIdDictionary[$SeedProp.Value] = $SeedProp.Name }
            }
            if ($null -ne $SeedDictionary.ResourceNameMap)
            {
                foreach ($SeedProp in $SeedDictionary.ResourceNameMap.PSObject.Properties) { $ResourceNameDictionary[$SeedProp.Value] = $SeedProp.Name }
            }
            if ($null -ne $SeedDictionary.TagMap)
            {
                foreach ($SeedProp in $SeedDictionary.TagMap.PSObject.Properties) { $Global:TagValueDictionary[$SeedProp.Value] = $SeedProp.Name }
            }
            if ($null -ne $SeedDictionary.FreeTextMap)
            {
                foreach ($SeedProp in $SeedDictionary.FreeTextMap.PSObject.Properties) { $Global:FreeTextDictionary[$SeedProp.Value] = $SeedProp.Name }
            }
            if ($null -ne $SeedDictionary.SubscriptionNameMap)
            {
                # property NAME = subscription token, VALUE = real subscription name
                foreach ($SeedProp in $SeedDictionary.SubscriptionNameMap.PSObject.Properties)
                {
                    if (-not [string]::IsNullOrEmpty($SeedProp.Value)) { $SubLookup[$SeedProp.Value] = $SeedProp.Name }
                }
            }
            if ($null -ne $SeedDictionary.ResourceGroupMap)
            {
                # property NAME = RG token, VALUE = representative real resource ID
                foreach ($SeedProp in $SeedDictionary.ResourceGroupMap.PSObject.Properties)
                {
                    if ($SeedProp.Value -match '(?i)/resourcegroups/([^/]+)') { $RgLookup[$Matches[1]] = $SeedProp.Name }
                }
            }

            Write-Log -Message ("Obfuscation dictionary seeded from '{0}': {1} id, {2} name, {3} subscription, {4} resource-group, {5} tag, {6} free-text mappings preloaded; matching real values will reuse their existing tokens." -f $ObfuscationDictionary, @($ResourceIdDictionary.Keys).Count, @($ResourceNameDictionary.Keys).Count, @($SubLookup.Keys).Count, @($RgLookup.Keys).Count, @($Global:TagValueDictionary.Keys).Count, @($Global:FreeTextDictionary.Keys).Count) -Severity 'Info'
        }

        foreach ($resourceItem in $Global:Resources)
        {
            $IsNonProd = $resourceItem.name -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or $resourceItem.name -match '(^|-)([dts])-'
            $Prefix = if ($IsNonProd) { "nonprod_" } else { "prod_" }

            $ObfuscatedID = $Prefix + [guid]::NewGuid().ToString()
            $ObfuscatedName = $Prefix + [guid]::NewGuid().ToString()

            # Preserve resource type signal in obfuscated name for server-side matching
            # VMs/Disks managed by services have identifiable patterns in their resource ID
            if ($resourceItem.id -match 'databricks')
            {
                $ObfuscatedName = $Prefix + 'databricks_' + [guid]::NewGuid().ToString()
            }
            elseif ($resourceItem.id -match '/resourcegroups/mc_')
            {
                $ObfuscatedName = $Prefix + 'aks_' + [guid]::NewGuid().ToString()
            }
            elseif ($resourceItem.id -match 'virtualmachinescalesets')
            {
                $ObfuscatedName = $Prefix + 'vmss_' + [guid]::NewGuid().ToString()
            }

            # Deterministic subscription obfuscation: derive prefix from sub name, not resource name
            $RealSub = ($Global:Subscriptions | Where-Object { $_.id -eq $resourceItem.subscriptionId }).Name
            if ([string]::IsNullOrEmpty($RealSub)) { $RealSub = $resourceItem.subscriptionId }
            if (-not $SubLookup.ContainsKey($RealSub))
            {
                $SubPrefix = if ($RealSub -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or $RealSub -match '(^|-)([dts])-') { "nonprod_" } else { "prod_" }
                $SubLookup[$RealSub] = $SubPrefix + [guid]::NewGuid().ToString()
            }
            $ObfuscatedSubscription = $SubLookup[$RealSub]

            # Deterministic RG obfuscation: derive prefix from RG name, not resource name
            $RealRG = $resourceItem.resourceGroup
            if ([string]::IsNullOrEmpty($RealRG)) { $RealRG = '__none__' }
            if (-not $RgLookup.ContainsKey($RealRG))
            {
                $RgPrefix = if ($RealRG -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or $RealRG -match '(^|-)([dts])-') { "nonprod_" } else { "prod_" }
                $RgLookup[$RealRG] = $RgPrefix + [guid]::NewGuid().ToString()
            }
            $ObfuscatedResourceGroup = $RgLookup[$RealRG]

            # Seeded reuse (-ObfuscationDictionary): if this real resource id was preloaded, reuse its per-resource ID and Name tokens so a scoped recovery run lands in the SAME token space as the bundle it merges into. Gated on ContainsKey, so a normal (empty-dict) run is byte-for-byte unchanged and the just-minted GUIDs are harmless throwaway.
            # Subscription/ResourceGroup tokens are NOT reused from the ID-keyed dicts (those are shared per sub/RG and reseed sparse) - they come via the real-value-keyed $subLookup/$rgLookup the mint logic already consulted.
            if ($ResourceIdDictionary.ContainsKey($resourceItem.ID))
            {
                $ObfuscatedID = $ResourceIdDictionary[$resourceItem.ID]
                # Guard the name-map read: a seeded/hand-edited -ObfuscationDictionary can hold the id in the ResourceId map but NOT the ResourceName map. The indexer yields $null (not a KeyNotFoundException) on a miss, so an unguarded read would produce a NULL masked name - keep the freshly-minted $ObfuscatedName instead. No-op on a normal run where both maps populate together.
                if ($ResourceNameDictionary.ContainsKey($resourceItem.ID))
                {
                    $ObfuscatedName = $ResourceNameDictionary[$resourceItem.ID]
                }
            }

            $ResourceIdDictionary[$resourceItem.ID] = $ObfuscatedID
            $ResourceNameDictionary[$resourceItem.ID] = $ObfuscatedName
            $ResourceSubscriptionDictionary[$resourceItem.ID] = $ObfuscatedSubscription
            $ResourceResourceGroupDictionary[$resourceItem.ID] = $ObfuscatedResourceGroup

            # Raw tags are intentionally NOT scrubbed here: they must survive on the in-memory $Global:Resources objects so collectors can surface them; tag VALUES are obfuscated deterministically (keys kept) in the per-collector loop below. $Global:Resources is never serialized into the report, so leaving raw tags on it in memory does not leak.
        }
    }
}

function ExecuteInventoryProcessing()
{
    function InitializeInventoryProcessing()
    {
        $Global:ZipOutputFile = ($DefaultPath + $Global:ReportName + "_" + $CurrentDateTime + ".zip")
        $Global:HtmlFile = ($DefaultPath + $Global:ReportName + "_" + $CurrentDateTime + ".html")
        $Global:AllResourceFile = ($DefaultPath + "Full_" + $Global:ReportName + "_" + $CurrentDateTime + ".json")
        $Global:JsonFile = ($DefaultPath + "Inventory_" + $Global:ReportName + "_" + $CurrentDateTime + ".json")
        $Global:MetricsJsonFile = ($DefaultPath + "Metrics_" + $Global:ReportName + "_" + $CurrentDateTime + ".json")
        $Global:ConsumptionFileCsv = ($DefaultPath + "Consumption_" + $Global:ReportName + "_" + $CurrentDateTime + ".csv")

        # Local errors-only log: a LOCAL debug artifact, NEVER zipped. Written to the PARENT InventoryRoot (not the per-sub $DefaultPath, which would bury one per sub) tagged with the SubscriptionID so per-sub error logs are findable and never collide under a parallel multi-sub run; standalone runs keep it in the report folder.
        if ($RunAllSubs.IsPresent)
        {
            $ErrorLogDir = Split-Path -Path ($Global:DefaultPath.TrimEnd([IO.Path]::DirectorySeparatorChar, '/', '\')) -Parent
            $ErrorLogSubTag = if (![string]::IsNullOrEmpty($SubscriptionID)) { $SubscriptionID } else { $Global:CurrentDateTime }
            $Global:ErrorLogFile = (Join-Path $ErrorLogDir ("ErrorLog_" + $Global:ReportName + "_" + $Global:CurrentDateTime + "_" + $ErrorLogSubTag + ".log"))
        }
        else
        {
            $Global:ErrorLogFile = ($DefaultPath + "ErrorLog_" + $Global:ReportName + "_" + $CurrentDateTime + ".log")
        }

        # Consolidated LOCAL debug log (per-collector heartbeat + metrics diagnostics), placed in the parent root tagged with SubscriptionID like the error log. Contents are UNSCRUBBED (real service/resource names, and heartbeat FAIL lines can carry raw exception text incl. a signed URL/token) - treat as sensitive.
        # Zipping is MODE-DEPENDENT: LOCAL-only under -Obfuscate (that bundle must carry no real ids), included by explicit path in a default run; the DebugLog_* -notlike guard on the *.json sweep keeps it out of the obfuscated bundle either way.
        if ($RunAllSubs.IsPresent)
        {
            $DebugLogDir = Split-Path -Path ($Global:DefaultPath.TrimEnd([IO.Path]::DirectorySeparatorChar, '/', '\')) -Parent
            $DebugLogSubTag = if (![string]::IsNullOrEmpty($SubscriptionID)) { $SubscriptionID } else { $Global:CurrentDateTime }
            $Global:DebugLogFile = (Join-Path $DebugLogDir ("DebugLog_" + $Global:ReportName + "_" + $Global:CurrentDateTime + "_" + $DebugLogSubTag + ".log"))
        }
        else
        {
            $Global:DebugLogFile = ($DefaultPath + "DebugLog_" + $Global:ReportName + "_" + $CurrentDateTime + ".log")
        }

        Write-Log -Message ('Report HTML File: {0}' -f $Global:HtmlFile) -Severity 'Info'
    }

    function Test-DataPlaneAuthReady([string]$Phase)
    {
        # Verify a live Azure context + token before a data-plane phase (Metrics via Get-AzMetric, Consumption via Get-UsageAggregates - both silently produce ZERO records when the token is missing). The caller did not pass the matching -Skip*, so detect the gap, reconnect ONCE using the script's own auth method, then re-check; returns $true only when a usable token is confirmed.
        # Interactive reconnect is skipped under -RunAllSubs background jobs (no console) in favour of a loud failure.
        $TokenOk = {
            $Ctx = $null
            try { $Ctx = Get-AzContext -ErrorAction Stop } catch { return $false }
            if ($null -eq $Ctx -or $null -eq $Ctx.Account) { return $false }
            try
            {
                $Tok = Get-AzAccessToken -ErrorAction Stop -WarningAction SilentlyContinue
                return ($null -ne $Tok -and -not [string]::IsNullOrWhiteSpace($Tok.Token))
            }
            catch { return $false }
        }

        if (& $TokenOk) { return $true }

        Write-Log -Message ("{0}: no usable Azure context/token detected; attempting one reconnect before collecting {0} data." -f $Phase) -Severity 'Warning'

        try
        {
            if ($Appid -and $Secret -and $TenantID)
            {
                Write-Log -Message ("{0}: reconnecting via Service Principal." -f $Phase) -Severity 'Info'
                $Credential = New-Object System.Management.Automation.PSCredential($Appid, $Secret)
                Connect-AzAccount -ServicePrincipal -Credential $Credential -Tenant $TenantID -ErrorAction Stop | Out-Null
            }
            elseif ($RunAllSubs.IsPresent)
            {
                Write-Log -Message ("{0}: running under -RunAllSubs without Service Principal credentials - cannot prompt for interactive login in this context. Authenticate before the run (e.g. Connect-AzAccount) or supply -appid/-secret/-tenant." -f $Phase) -Severity 'Error'
                return $false
            }
            elseif (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected)
            {
                # No interactive console available (background job, CI, piped/
                # redirected input, or a detached process). An interactive
                # Connect-AzAccount here would block FOREVER waiting on a browser
                # or device prompt that no one can answer - which manifests as a
                # silent hang. Fail loud instead so the run does not wedge.
                Write-Log -Message ("{0}: no usable Azure context and no interactive console to prompt for login (non-interactive session). Authenticate before the run (Connect-AzAccount) or supply -appid/-secret/-tenant, then re-run." -f $Phase) -Severity 'Error'
                return $false
            }
            elseif ($DeviceLogin.IsPresent)
            {
                Write-Log -Message ("{0}: reconnecting via device login." -f $Phase) -Severity 'Info'
                Connect-AzAccount -UseDeviceAuthentication -ErrorAction Stop | Out-Null
            }
            else
            {
                Write-Log -Message ("{0}: reconnecting via interactive browser login." -f $Phase) -Severity 'Info'
                Connect-AzAccount -ErrorAction Stop | Out-Null
            }
        }
        catch
        {
            Write-Log -Message ("{0}: reconnect attempt failed: {1}" -f $Phase, $_.Exception.Message) -Severity 'Error'
            return $false
        }

        return (& $TokenOk)
    }

    function CreateMetricsJob()
    {
        Write-Log -Message ('Checking if Metrics Job Should be Run.') -Severity 'Info'

        if (!$SkipMetrics.IsPresent)
        {
            # -SkipMetrics was NOT passed, so metrics are wanted, but Get-AzMetric silently returns ZERO in parallel runspaces if the context/token is missing. Detect + attempt recovery; if it still cannot authenticate, fail loud and skip ONLY this phase (the end-of-script empty-metrics-JSON fallback keeps the bundle structurally valid). Intentionally not a silent skip.
            if (-not (Test-DataPlaneAuthReady -Phase 'Metrics'))
            {
                Write-Log -Message ('Metrics: SKIPPED - could not establish a usable Azure context/token after one reconnect attempt. Metrics were requested (no -SkipMetrics) but cannot be collected. Re-authenticate (Connect-AzAccount) or pass -appid/-secret/-tenant, then re-run. The rest of the inventory will continue.') -Severity 'Error'

                $Global:AzMetrics = New-Object PSObject
                $Global:AzMetrics | Add-Member -MemberType NoteProperty -Name Metrics -Value NotSet
                $Global:AzMetrics.Metrics = [System.Collections.Concurrent.ConcurrentBag[psobject]]::new()

                # Record per-subscription metrics-phase health (mirrors $Global:ConsumptionFailedSubs) in the wrapper's scope, since this script is invoked via '&'. Resolve which sub(s) the skip applies to: the -SubscriptionID one when invoked per-sub, else every in-scope sub for a standalone all-subs run.
                if ($null -eq $Global:MetricsFailedSubs) { $Global:MetricsFailedSubs = @() }
                $MetricsSkipMsg = 'Metrics phase skipped: no usable Azure context/token after one reconnect attempt.'
                $AffectedSubs = @(
                    if (![string]::IsNullOrEmpty($SubscriptionID))
                    {
                        $Global:Subscriptions | Where-Object { $_.id -eq $SubscriptionID }
                    }
                    else
                    {
                        $Global:Subscriptions
                    }
                )
                if ($AffectedSubs.Count -eq 0)
                {
                    # Fallback when the subscription list is unavailable: still
                    # record one entry so the failure is never silent.
                    $IdLabel = if (![string]::IsNullOrEmpty($SubscriptionID)) { $SubscriptionID } else { '(unknown)' }
                    $Global:MetricsFailedSubs += [pscustomobject]@{ Name = '(subscription)'; Id = $IdLabel; Message = $MetricsSkipMsg }
                }
                else
                {
                    foreach ($asub in $AffectedSubs)
                    {
                        $Global:MetricsFailedSubs += [pscustomobject]@{ Name = $asub.Name; Id = $asub.Id; Message = $MetricsSkipMsg }
                    }
                }
                return
            }

            Write-Log -Message ('Running Metrics Jobs') -Severity 'Success'

            if ($PSScriptRoot -like '*\*')
            {
                $MetricPath = Get-ChildItem -LiteralPath ($PSScriptRoot + '\Extension\Metrics.ps1') -Recurse
            }
            else
            {
                $MetricPath = Get-ChildItem -LiteralPath ($PSScriptRoot + '/Extension/Metrics.ps1') -Recurse
            }

            $MetricsFilePath = ($DefaultPath + "Metrics_" + $Global:ReportName + "_" + $CurrentDateTime + "_")

            $Global:AzMetrics = New-Object PSObject
            $Global:AzMetrics | Add-Member -MemberType NoteProperty -Name Metrics -Value NotSet
            $Global:AzMetrics.Metrics = & $MetricPath -Subscriptions $Subscriptions -Resources $Resources -Task "Processing" -ConcurrencyLimit $ConcurrencyLimit -FilePath $MetricsFilePath -ResourceIdDictionary $(if ($Obfuscate.IsPresent) { $ResourceIdDictionary } else { $null }) -ResourceNameDictionary $(if ($Obfuscate.IsPresent) { $ResourceNameDictionary } else { $null }) -ResourceSubDictionary $(if ($Obfuscate.IsPresent) { $ResourceSubscriptionDictionary } else { $null }) -ResourceGroupDictionary $(if ($Obfuscate.IsPresent) { $ResourceResourceGroupDictionary } else { $null }) -Obfuscate $Obfuscate.IsPresent -MetricsLookbackDays $MetricsLookbackDays -UseMetricsBatch:$UseMetricsBatch -IncludeStorageMetrics:$IncludeStorageMetrics -SkipDiskMetrics:$SkipDiskMetrics -MetricsDetailed:$MetricsDetailed -MetricsIntervalMinutes $MetricsIntervalMinutes
        }
    }

    function ProcessMetricsResult()
    {
        if (!$SkipMetrics.IsPresent)
        {
            # Managed-heap + working-set snapshot around the post-metrics GC, routed to the consolidated debug log ONLY (-NoConsole / -ToDebugLog): under the wrapper every sub runs in the same long-lived process, so comparing these lines across subs shows whether the footprint is a stable high-water mark or creeping (a real leak).
            # Values are captured into variables (not emitted bare) so nothing leaks onto the pipeline, and it is wrapped defensively so a diagnostic line can never abort a sub whose metrics already succeeded; the GC.Collect($true) stays outside so collection still happens even if measurement hiccups.
            [System.GC]::Collect()
            try
            {
                $MemHeapBeforeMB = [math]::Round([System.GC]::GetTotalMemory($false) / 1MB, 1)
                $MemHeapAfterMB = [math]::Round([System.GC]::GetTotalMemory($true) / 1MB, 1)
                $MemWorkingSetMB = [math]::Round([System.Diagnostics.Process]::GetCurrentProcess().WorkingSet64 / 1MB, 1)
                # InvariantCulture: one-decimal doubles, so a bare -f writes '1234,5 MB' on
                # this en-NL host into DebugLog_*.log, which ships in a default run's zip.
                Write-Log -Message ('[Memory] Post-metrics GC: managed heap {0} MB -> {1} MB after collect; process working set {2} MB.' -f $MemHeapBeforeMB.ToString([cultureinfo]::InvariantCulture), $MemHeapAfterMB.ToString([cultureinfo]::InvariantCulture), $MemWorkingSetMB.ToString([cultureinfo]::InvariantCulture)) -Severity 'Info' -NoConsole -ToDebugLog
            }
            catch
            {
                Write-Log -Message ('[Memory] Post-metrics memory snapshot unavailable: {0}' -f $_.Exception.Message) -Severity 'Info' -NoConsole -ToDebugLog
            }
        }
    }

    function CreateResourceJobs()
    {
        $Global:SmaResources = New-Object PSObject

        Write-Log -Message ('Starting Service Processing Jobs.') -Severity 'Info'


        if ($PSScriptRoot -like '*\*')
        {
            $Modules = Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Services') -Filter '*.ps1' -Recurse
        }
        else
        {
            $Modules = Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Services') -Filter '*.ps1' -Recurse
        }

        # -Service <string[]> targeted collection: run ONLY the named collectors (matched on file base name, case-insensitive) for fast re-collection of one resource type without re-running the whole tenant - the basis of a scoped recovery bundle. Metrics/consumption phases are unaffected. A requested name matching no collector is failed loud (not a silent empty inventory) so the typo is caught before shipping.
        if ($Service -and @($Service).Count -gt 0)
        {
            $AvailableServices = @($Modules | ForEach-Object { $_.BaseName } | Sort-Object)
            $Modules = @($Modules | Where-Object { $_.BaseName -in $Service })

            if (@($Modules).Count -eq 0)
            {
                Write-Log -Message ("-Service matched no collectors. Requested: [{0}]. Available: [{1}]." -f ($Service -join ', '), ($AvailableServices -join ', ')) -Severity 'Error'
                throw ("-Service matched no collectors. Requested: [{0}]." -f ($Service -join ', '))
            }

            $MatchedNames = @($Modules | ForEach-Object { $_.BaseName } | Sort-Object)
            Write-Log -Message ("-Service filter active: collecting {0} of {1} collectors: [{2}]" -f @($Modules).Count, @($AvailableServices).Count, ($MatchedNames -join ', ')) -Severity 'Info'

            # -Service scopes the INVENTORY phase only; metrics and consumption still run subscription-wide. Warn (do NOT enforce) when the operator omitted the skips, naming ONLY the still-wide phases and suggesting ONLY the switch(es) not already supplied - the Merge-RecoveryData recovery recipe intentionally runs -Service WITHOUT the skips, so enforcing them would break that flow.
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

            # The -ResourceGroup tip is STATE-DERIVED: do not offer it to a -SkipMetrics run (scoping metrics is its only benefit here) or to a run that already passed it (the two params are independent and combinable). It narrows the Graph query so it scopes inventory AND metrics but NOT consumption (Get-UsageAggregates is whole-subscription billing), so present it with that caveat since this warning names consumption (see docs/recovery-and-diagnostics.md).
            $RgTip = ''
            if (-not $SkipMetrics.IsPresent -and [string]::IsNullOrEmpty($ResourceGroup))
            {
                $RgTip = ' For targeted collection of a workload use -ResourceGroup (requires a single -SubscriptionID), which scopes inventory and metrics - but NOT consumption, which stays whole-subscription.'
            }

            # Suppressed under -RunAllSubs: the wrapper forwards -Service per-sub, so an ungated warning repeats identically N times and is wrong there (Run-AllSubscriptions.ps1 has no -ResourceGroup param); the wrapper carries its own once-up-front equivalent. Deliberately NOT gated on $Global:RdaSessionInitialized (already $true here), which would suppress it on every run including standalone.
            if (@($UnscopedPhases).Count -gt 0 -and -not $RunAllSubs.IsPresent)
            {
                Write-Log -Message ("-Service scopes the INVENTORY phase only; these phases still run for the WHOLE subscription: {0}. For a clean inventory-only run add {1}.{2} (Ignore this if you are deliberately re-collecting for a later Merge-RecoveryData.)" -f ($UnscopedPhases -join ', '), ($SuggestedSkips -join ' '), $RgTip) -Severity 'Warning'
            }

            $UnmatchedServices = @($Service | Where-Object { $_ -notin $MatchedNames })
            if (@($UnmatchedServices).Count -gt 0)
            {
                Write-Log -Message ("-Service: these requested names matched nothing and were ignored: [{0}]. Available: [{1}]." -f ($UnmatchedServices -join ', '), ($AvailableServices -join ', ')) -Severity 'Warning'
            }
        }

        $Resource = $Resources
        #$Resource = ($Resource | ConvertTo-Json -Depth 50)

        # Circuit breaker for collector failures (#22): one collector throwing is recorded loudly and skipped (like the metrics/consumption fail-and-skip pattern), but MANY failures in a row are almost never per-type bugs - they are systemic (auth dropped, network gone, Az module broken) and every remaining collector will fail identically. Stop once that pattern is detected so the operator gets ONE clear diagnosis instead of ~50 identical errors and an empty-looking report.
        $ConsecutiveCollectorFailures = 0
        $CollectorFailureCircuitBreakerThreshold = 5

        # Per-service progress is surfaced without a per-collector console line (that ~40+/sub green line scrolled real errors off screen and repeated once per sub, e.g. 164x): Write-Progress (a no-op in the non-interactive hosts the wrapper drives collectors in, so transcripts stay clean) plus a per-collector heartbeat appended to a LOCAL .log that restores the 'where did it hang' trace and is never zipped.
        # Collector FAILURES are still logged loudly in the catch below, so nothing diagnostic depends on this file.
        $ModuleTotal = @($Modules).Count
        $ModuleIndex = 0

        $HeartbeatSubLabel = if (![string]::IsNullOrEmpty($SubscriptionID)) { $SubscriptionID } else { '(all in-scope subscriptions)' }
        # Write the per-collector heartbeat through the single shared Write-Log with -NoConsole (no per-collector console spam) + -ToDebugLog (append to the consolidated LOCAL $Global:DebugLogFile, parent-root/SubscriptionID-placed so per-sub heartbeats are discoverable, never collide, and are never packaged). -ToDebugLog is a silent no-op when no debug-log path exists and never throws, so no separate enable/disable guard is needed.
        Write-Log -Message ("Service processing started for {0}: {1} collectors" -f $HeartbeatSubLabel, $ModuleTotal) -NoConsole -ToDebugLog

        foreach ($Module in $Modules)
        {
            $ModName = $Module.Name.Substring(0, $Module.Name.length - ".ps1".length)
            $ModuleIndex++

            # Unified progress bar. -BarOnly keeps the pre-existing behavior for
            # this high-frequency loop that runs inside non-interactive stream
            # workers: the Write-Progress bar renders interactively and is a no-op
            # otherwise, with NO per-collector stdout line (the detailed heartbeat
            # log below is the durable record). See Functions/Common.Functions.ps1.
            Write-RdaProgress -Activity 'Service Processing' -CurrentItem $ModName -Index $ModuleIndex -Total $ModuleTotal -BarOnly

            Write-Log -Message ("START ({0}/{1}) {2}" -f $ModuleIndex, $ModuleTotal, $ModName) -NoConsole -ToDebugLog

            try
            {
                $Result = & $Module -Sub $Subscriptions -Resources $Resource -Task "Processing" -ResourceIdDictionary $(if ($Obfuscate.IsPresent) { $ResourceIdDictionary } else { $null })
                $ConsecutiveCollectorFailures = 0

                Write-Log -Message ("DONE  ({0}/{1}) {2}" -f $ModuleIndex, $ModuleTotal, $ModName) -NoConsole -ToDebugLog
            }
            catch
            {
                $ConsecutiveCollectorFailures++

                Write-Log -Message ("FAIL  ({0}/{1}) {2}: {3}" -f $ModuleIndex, $ModuleTotal, $ModName, $_.Exception.Message) -NoConsole -ToDebugLog

                if ($null -eq $Global:CollectorFailures) { $Global:CollectorFailures = @() }
                $Global:CollectorFailures += [pscustomobject]@{
                    Id      = $SubscriptionID
                    Module  = $ModName
                    Message = $_.Exception.Message
                }

                Write-Log -Message ("Collector FAILED: {0}: {1}" -f $ModName, $_.Exception.Message) -Severity 'Error'
                Write-Log -Message ("The rest of the inventory will continue, but the '{0}' resource type is MISSING from this report - not empty because there are none, but because the collector errored. Re-run to retry, or investigate the error above if it repeats." -f $ModName) -Severity 'Error'

                if ($ConsecutiveCollectorFailures -ge $CollectorFailureCircuitBreakerThreshold)
                {
                    throw ("Stopping: {0} collectors failed in a row (most recently '{1}': {2}). This pattern indicates a systemic problem (authentication dropped mid-run, network lost, or a broken Az module) rather than an issue with any single resource type. Fix the underlying problem (see the error above) and re-run rather than continuing - limping through the remaining collectors would only produce more identical failures and an incomplete report that looks like an empty environment. Total collector failures across the whole run so far (all subscriptions processed to this point): {3}." -f $ConsecutiveCollectorFailures, $ModName, $_.Exception.Message, ($Global:CollectorFailures.Count))
                }

                # This collector's resource type is missing from the report (not silently empty): the Error-severity log line above and the $Global:CollectorFailures entry are the loud signal. $result must still become a defined empty array so $Global:SmaResources.$ModName is a valid (empty) JSON array rather than an absent member.
                $Result = @()
            }

            if ($Obfuscate.IsPresent)
            {
                foreach ($resourceItem in $Result)
                {
                    $OrigID = $resourceItem.ID

                    # A null/empty ID would throw on the dictionary key ASSIGNMENT
                    # in the else branches below (Dictionary[string,string] rejects
                    # a null key with "the array index evaluated to null"). Give the
                    # row a deterministic-within-run fallback and skip the dictionary
                    # lookups so one malformed collector row cannot abort processing.
                    if ([string]::IsNullOrEmpty($OrigID))
                    {
                        $Fallback = 'obfuscated_' + [guid]::NewGuid().ToString()
                        $resourceItem.ID = $Fallback
                        $resourceItem.Name = $Fallback
                        $resourceItem.Subscription = $Fallback
                        $resourceItem.ResourceGroup = $Fallback
                        # Still scrub tags before skipping - a malformed null-ID row
                        # must not carry real tag values into the obfuscated output
                        # just because it bypassed the dictionary path below.
                        if ($resourceItem.ContainsKey('tags')) { $resourceItem.tags = $null }
                        if ($resourceItem.ContainsKey('Tags')) { $resourceItem.Tags = $null }
                        continue
                    }

                    if ($ResourceIdDictionary.ContainsKey($OrigID))
                    {
                        $ObfuscatedID = $ResourceIdDictionary[$OrigID]
                        if ([string]::IsNullOrEmpty($ObfuscatedID)) { $ObfuscatedID = 'obfuscated_' + [guid]::NewGuid().ToString() }
                        $resourceItem.ID = $ObfuscatedID
                    }
                    else
                    {
                        $Prefix = if ($OrigID -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or $OrigID -match '(^|-)([dts])-') { "nonprod_" } else { "prod_" }
                        $Fallback = $Prefix + [guid]::NewGuid().ToString()
                        $ResourceIdDictionary[$OrigID] = $Fallback
                        $resourceItem.ID = $Fallback
                    }

                    $Prefix = $resourceItem.ID.Split('_')[0] + '_'

                    if ($ResourceNameDictionary.ContainsKey($OrigID))
                    {
                        $ObfuscatedName = $ResourceNameDictionary[$OrigID]
                        if ([string]::IsNullOrEmpty($ObfuscatedName)) { $ObfuscatedName = 'obfuscated_' + [guid]::NewGuid().ToString() }
                        $resourceItem.Name = $ObfuscatedName
                    }
                    else
                    {
                        $FbName = $Prefix + [guid]::NewGuid().ToString()
                        $ResourceNameDictionary[$OrigID] = $FbName
                        $resourceItem.Name = $FbName
                    }

                    if ($ResourceSubscriptionDictionary.ContainsKey($OrigID))
                    {
                        $ObfuscatedSub = $ResourceSubscriptionDictionary[$OrigID]
                        if ([string]::IsNullOrEmpty($ObfuscatedSub)) { $ObfuscatedSub = 'obfuscated_' + [guid]::NewGuid().ToString() }
                        $resourceItem.Subscription = $ObfuscatedSub
                    }
                    else
                    {
                        $FbSub = $Prefix + [guid]::NewGuid().ToString()
                        $ResourceSubscriptionDictionary[$OrigID] = $FbSub
                        $resourceItem.Subscription = $FbSub
                    }

                    if ($ResourceResourceGroupDictionary.ContainsKey($OrigID))
                    {
                        $ObfuscatedRG = $ResourceResourceGroupDictionary[$OrigID]
                        if ([string]::IsNullOrEmpty($ObfuscatedRG)) { $ObfuscatedRG = 'obfuscated_' + [guid]::NewGuid().ToString() }
                        $resourceItem.ResourceGroup = $ObfuscatedRG
                    }
                    else
                    {
                        $FbRG = $Prefix + [guid]::NewGuid().ToString()
                        $ResourceResourceGroupDictionary[$OrigID] = $FbRG
                        $resourceItem.ResourceGroup = $FbRG
                    }

                    # Collector 'Tags' output is an array of { Name, Value }: keep the KEY (Name) verbatim and obfuscate the VALUE deterministically via $Global:TagValueDictionary (same value -> same token) so the report can still group/correlate by tag value without exposing it; the prefix is value-derived so an environment-type signal survives.
                    if ($resourceItem.ContainsKey('Tags') -and $null -ne $resourceItem.Tags)
                    {
                        foreach ($Tag in $resourceItem.Tags)
                        {
                            if ($null -ne $Tag -and -not [string]::IsNullOrEmpty([string]$Tag.Value))
                            {
                                $RealTagValue = [string]$Tag.Value
                                if (-not $Global:TagValueDictionary.ContainsKey($RealTagValue))
                                {
                                    $TagPrefix = if ($RealTagValue -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or $RealTagValue -match '(^|-)([dts])-') { 'nonprod_' } else { 'prod_' }
                                    $Global:TagValueDictionary[$RealTagValue] = $TagPrefix + [guid]::NewGuid().ToString()
                                }
                                $Tag.Value = $Global:TagValueDictionary[$RealTagValue]
                            }
                        }
                    }
                }
            }

            $Global:SmaResources | Add-Member -MemberType NoteProperty -Name $ModName -Value NotSet
            # Wrap with @() so the JSON serializer always emits an array, even for a single resource: without it PowerShell unwraps a one-element result into a scalar object, ConvertTo-Json emits {...} instead of [{...}], and array-iterating downstream parsers silently see zero rows.
            $Global:SmaResources.$ModName = @($Result)

            $Result = $null
            [System.GC]::Collect()
        }

        Write-RdaProgress -Activity 'Service Processing' -Completed

        Write-Log -Message ("Service processing complete: {0} collectors" -f $ModuleTotal) -NoConsole -ToDebugLog
    }

    function ProcessResourceResult()
    {
        Write-Log -Message ("Starting Reporting Phase.") -Severity 'Info'

        # The Inventory JSON is the report's single source of truth. It is
        # built entirely from $Global:SmaResources, which the Processing phase
        # (CreateResourceJobs) already populated. The HTML report (Summary.ps1)
        # renders from this JSON. There is no per-collector Excel-writing pass
        # any more - the Excel/EPPlus dependency has been removed.
        $Global:SmaResources | Add-Member -MemberType NoteProperty -Name 'Version' -Value NotSet
        $Global:SmaResources.Version = $Global:Version

        $Global:SmaResources | ConvertTo-Json -Depth 100 -Compress | Out-File -LiteralPath $Global:JsonFile
        #$Global:Resources | ConvertTo-Json -depth 100 -compress | Out-File $Global:AllResourceFile

        Write-Log -Message ('Resource Reporting Phase Done.') -Severity 'Info'
    }

    function GetResourceConsumption()
    {
        $DebugPreference = "SilentlyContinue"

        #Force the culture here...
        [System.Threading.Thread]::CurrentThread.CurrentUICulture = "en-US";
        [System.Threading.Thread]::CurrentThread.CurrentCulture = "en-US";

        $ReportedStartTime = (Get-Date).AddDays(-31).Date.AddHours(0).AddMinutes(0).AddSeconds(0).DateTime
        $ReportedEndTime = (Get-Date).AddDays(-1).Date.AddHours(0).AddMinutes(0).AddSeconds(0).DateTime

        # Consumption was requested (no -SkipConsumption), but Get-UsageAggregates silently returns ZERO records when the context/token is missing (looks like 'no billing data'). Detect + reconnect once; if still unauthenticated, record a loud per-run entry ($Global:ConsumptionFailedSubs, surfaced by the wrapper) and skip the phase rather than produce silent empty output.
        if (-not (Test-DataPlaneAuthReady -Phase 'Consumption'))
        {
            Write-Log -Message ('Consumption: SKIPPED - could not establish a usable Azure context/token after one reconnect attempt. Consumption was requested (no -SkipConsumption) but cannot be collected. Re-authenticate (Connect-AzAccount) or pass -appid/-secret/-tenant, then re-run. The rest of the inventory will continue.') -Severity 'Error'

            if ($null -eq $Global:ConsumptionRecordCount) { $Global:ConsumptionRecordCount = 0 }
            if ($null -eq $Global:ConsumptionFailedSubs) { $Global:ConsumptionFailedSubs = @() }
            $Global:ConsumptionFailedSubs += [pscustomobject]@{
                Name    = '(all subscriptions)'
                Id      = '(auth)'
                Message = 'Consumption phase skipped: no usable Azure context/token after one reconnect attempt.'
            }
            return
        }

        foreach ($sub in $Global:Subscriptions)
        {
            # Check if SubscriptionId is not null, not empty, and matches $sub.id
            if (![string]::IsNullOrEmpty($SubscriptionID))
            {
                if (![string]::IsNullOrEmpty($ResourceGroup))
                {
                    Write-Log -Message ("Cannot filter consumption by resource group." -f $sub.Name) -Severity 'Info'
                }

                if ($SubscriptionID -ne $sub.Id)
                {
                    Write-Log -Message ("Skipping: {0}" -f $sub.Name) -Severity 'Info'
                    continue
                }
            }

            # Switch the Azure context to the TARGET subscription before pulling billing: Get-UsageAggregates reads whatever sub the context points at, so a silently-failed switch (no access) would leave the context on the PREVIOUS sub and attribute its consumption here - a data-integrity bug and cross-subscription leak.
            # Force it terminating (the run's SilentlyContinue would swallow the failure), then VERIFY the resulting context matches $sub.id; on failure record per-sub health and skip ONLY this sub's consumption rather than pull the wrong sub's data.
            $ContextOk = $false
            $ContextSwitchError = $null
            try
            {
                $null = Set-AzContext -Subscription $sub.id -ErrorAction Stop
                $ContextOk = ((Get-AzContext).Subscription.Id -eq $sub.id)
            }
            catch
            {
                $ContextSwitchError = $_.Exception.Message
            }

            if (-not $ContextOk)
            {
                $SkipMessage = ("Consumption SKIPPED: could not switch the Azure context to this subscription{0}. The signed-in identity likely lacks access to it. Skipped to avoid attributing another subscription's billing data to this one." -f $(if ($ContextSwitchError) { " ($ContextSwitchError)" } else { ' (context did not match the target after Set-AzContext)' }))
                Write-Log -Message ("Consumption: {0} - {1}" -f $sub.Name, $SkipMessage) -Severity 'Error'

                if ($null -eq $Global:ConsumptionRecordCount) { $Global:ConsumptionRecordCount = 0 }
                if ($null -eq $Global:ConsumptionFailedSubs) { $Global:ConsumptionFailedSubs = @() }
                $Global:ConsumptionFailedSubs += [pscustomobject]@{
                    Name             = $sub.Name
                    Id               = $sub.Id
                    Message          = $SkipMessage
                    Complete         = $false
                    PageAtFailure    = 0
                    RecordsCollected = 0
                }

                continue
            }

            Write-Log -Message ("Gathering Consumption for: {0}" -f $sub.Name) -Severity 'Info'

            # Track consumption health per-subscription so the wrapper can report at the end whether data was actually collected: without it a broken Az module yields zero consumption records on every sub while the run still reports success, leaving an empty sheet nobody notices until the report is reviewed.
            $ConsumptionRecordsThisSub = 0
            $ConsumptionFailedThisSub = $false
            $ConsumptionFailureMessage = $null
            # Page counter so a mid-pull failure can report exactly where it
            # stopped (which paged Get-UsageAggregates call) instead of leaving a
            # silently-truncated CSV that could only be spotted by guessing from
            # the row count. Incremented once per distinct page attempted.
            $ConsumptionPageIndex = 0

            # Cleared per subscription: $UsageData holds the LAST page fetched and the paging token below is read from it, but it is not loop-scoped - so a sub that failed mid-paging left its live ContinuationToken in place and the NEXT sub's first billing request resumed a different sub's page sequence, attributing its rows here. A fresh start per sub is the only correct first request.
            $UsageData = $null

            try
            {
                do
                {
                    $ConsumptionPageIndex++
                    $Params = @{
                        ReportedStartTime      = $ReportedStartTime
                        ReportedEndTime        = $ReportedEndTime
                        AggregationGranularity = 'Daily'
                        ShowDetails            = $true
                    }

                    $Params.ContinuationToken = if ($null -ne $UsageData) { $UsageData.ContinuationToken } else { $null }

                    # Bounded retry with exponential backoff + jitter around the billing pull: retrying the SAME page is safe (a failed assignment keeps the previous ContinuationToken, so no duplicated/skipped rows) and a permanent error just exhausts retries into the outer catch (preserving warn-and-continue per-sub health).
                    # HONOR the server-directed Retry-After when Azure supplies one (Cost Management 429; read by Get-RdaRetryAfterSeconds, clamped 300s) and back off LONGER on throttling, because that TENANT-SHARED rate limit can persist far beyond a fixed ~14s; jitter de-syncs parallel streams and the budget matches the Resource Graph wrapper so both shared limits ride out the same throttle.
                    $ConsumptionMaxRetries = 30
                    $ConsumptionAttempt = 0
                    # Reset per PAGE: the token can lapse at any page during a multi-hour
                    # subscription, so each page is allowed its own single reconnect
                    # attempt. Without this reset, once one page refreshed no later page
                    # in the same subscription could recover from a fresh expiry.
                    $ConsumptionAuthRefreshedThisPage = $false
                    while ($true)
                    {
                        try
                        {
                            $UsageData = Get-UsageAggregates @Params -ErrorAction Stop
                            break
                        }
                        catch
                        {
                            # ABANDON an authorization denial immediately: retrying a 403 cannot make it a 200, and this otherwise-untyped catch used to burn the whole ~26-min budget per sub first.
                            # Checked BEFORE the throttle test (a loose substring match on '429' that a billing exception's ids/URLs can trip) so a terminal denial is not reclassified as throttling; uses Test-RdaConsumptionDenial - the same verdict as the wrapper's up-front gate - and only an unambiguous denial qualifies (throttle / expired token / 5xx / stream-copy errors still retry).
                            if (Test-RdaConsumptionDenial -ErrorMessage $_.Exception.Message)
                            {
                                Write-Log -Message ("Consumption page query DENIED for {0} after {1} attempt(s): {2}. This is an authorization failure, not a transient one, so it will not be retried - grant Cost Management Reader (or the billing-scope equivalent) and re-run." -f $sub.Name, ($ConsumptionAttempt + 1), $_.Exception.Message) -Severity 'Error'
                                throw
                            }

                            # REFRESH a lapsed token before retrying: an hour-plus paging loop can outlive an interactive sign-in's policy lifetime, and an expired token is NOT a denial, so it used to retry the dead token until the budget was spent. Reconnect ONCE per page via Test-DataPlaneAuthReady (the script's own auth method), then let the existing backoff retry the SAME page (the ContinuationToken guard avoids skip/dup).
                            # Guarded by $ConsumptionAuthRefreshedThisPage so a genuinely permanent 401 triggers at most one reconnect per page then fails loud; a no-op for managed identity / SP / workload identity, which re-issue transparently.
                            if ((-not $ConsumptionAuthRefreshedThisPage) -and (Test-RdaAuthExpiry -ErrorMessage $_.Exception.Message))
                            {
                                $ConsumptionAuthRefreshedThisPage = $true
                                Write-Log -Message ("Consumption page query for {0} failed with an expired/invalid token: {1}. Attempting one Azure re-authentication before retrying this page." -f $sub.Name, $_.Exception.Message) -Severity 'Warning'
                                if (Test-DataPlaneAuthReady -Phase 'Consumption')
                                {
                                    Write-Log -Message ("Consumption: Azure context re-established for {0}; retrying the current page." -f $sub.Name) -Severity 'Info'
                                }
                                else
                                {
                                    Write-Log -Message ("Consumption: re-authentication for {0} did not yield a usable token; the remaining retries will still be attempted but may not recover." -f $sub.Name) -Severity 'Warning'
                                }
                            }

                            $ConsumptionAttempt++
                            if ($ConsumptionAttempt -gt $ConsumptionMaxRetries) { throw }

                            $ConsumptionThrottled = $_.Exception.Message -match 'TooManyRequests|\b429\b|throttl|rate limit'

                            # Prefer the SERVER-DIRECTED wait when Azure supplies one (Cost Management 429 returns the exact delay via the ratelimit/Retry-After header, read by Get-RdaRetryAfterSeconds): more accurate than blind backoff and what keeps us off a bucket another billing pipeline is draining; clamp to 300s. Absent a header, fall back to exponential (2^attempt) capped 60s, doubled (cap 120s) when throttled.
                            $ConsumptionRetryAfter = Get-RdaRetryAfterSeconds -ErrorRecord $_
                            if ($ConsumptionRetryAfter -gt 0)
                            {
                                $ConsumptionThrottled = $true
                                $ConsumptionBackoffSeconds = [math]::Min($ConsumptionRetryAfter, 300)
                            }
                            else
                            {
                                $ConsumptionBackoffSeconds = [math]::Min([math]::Pow(2, $ConsumptionAttempt), 60)
                                if ($ConsumptionThrottled) { $ConsumptionBackoffSeconds = [math]::Min($ConsumptionBackoffSeconds * 2, 120) }
                            }
                            # Sub-second jitter on top so concurrent streams released by the
                            # same server window do not retry on the exact same tick.
                            $ConsumptionBackoffSeconds = [math]::Round($ConsumptionBackoffSeconds + ((Get-Random -Minimum 0 -Maximum 1000) / 1000.0), 2)

                            $ConsumptionRetryMarker = if ($ConsumptionRetryAfter -gt 0) { ', throttled, honoring server Retry-After' } elseif ($ConsumptionThrottled) { ', throttled' } else { '' }
                            Write-Log -Message ("Consumption page query failed for {0} (attempt {1}/{2}{3}): {4}. Retrying in {5}s..." -f $sub.Name, $ConsumptionAttempt, $ConsumptionMaxRetries, $ConsumptionRetryMarker, $_.Exception.Message, $ConsumptionBackoffSeconds) -Severity 'Warning'
                            Start-Sleep -Seconds $ConsumptionBackoffSeconds
                        }
                    }
                    $UsageDataExport = $UsageData.UsageAggregations.Properties | Select-Object InstanceData, MeterCategory, MeterId, MeterName, MeterRegion, MeterSubCategory, Quantity, Unit, UsageStartTime, UsageEndTime

                    Write-Log -Message ("Records found: $($UsageDataExport.Count)...") -Severity 'Info'

                    $NewUsageDataExport = [System.Collections.ArrayList]::new()

                    for ($Item = 0; $Item -lt $UsageDataExport.Count; $Item++)
                    {
                        # Some meters (marketplace purchases, certain reservations, tenant-level charges) return null/empty InstanceData; .tolower() on null throws, and inside this per-sub paging try/catch that throw would abort the WHOLE sub's consumption. Such a record has no resourceUri to attribute anyway, so skip just it (mirroring the RG-filter 'continue' below) and let the rest complete.
                        $RawInstanceData = $UsageDataExport[$Item].InstanceData
                        if ([string]::IsNullOrEmpty($RawInstanceData))
                        {
                            continue
                        }
                        $InstanceInfo = ($RawInstanceData.tolower() | ConvertFrom-Json)

                        if (![string]::IsNullOrEmpty($ResourceGroup))
                        {
                            if (!$InstanceInfo.'Microsoft.Resources'.resourceUri.toLower().Contains("/" + $ResourceGroup.toLower() + "/"))
                            {
                                continue;
                            }
                        }

                        $UsageDataExport[$Item] | Add-Member -MemberType NoteProperty -Name ResourceId -Value NotSet
                        $UsageDataExport[$Item] | Add-Member -MemberType NoteProperty -Name ResourceLocation -Value NotSet

                        $UsageDataExport[$Item] | Add-Member -MemberType NoteProperty -Name ConsumptionMeter -Value NotSet
                        $UsageDataExport[$Item] | Add-Member -MemberType NoteProperty -Name ReservationId -Value NotSet
                        $UsageDataExport[$Item] | Add-Member -MemberType NoteProperty -Name ReservationOrderId -Value NotSet


                        $UsageDataExport[$Item].ResourceId = $InstanceInfo.'Microsoft.Resources'.resourceUri
                        $UsageDataExport[$Item].ResourceLocation = $InstanceInfo.'Microsoft.Resources'.location
                        $UsageDataExport[$Item].ConsumptionMeter = $InstanceInfo.'Microsoft.Resources'.additionalInfo.ConsumptionMeter
                        $UsageDataExport[$Item].ReservationId = $InstanceInfo.'Microsoft.Resources'.additionalInfo.ReservationId
                        $UsageDataExport[$Item].ReservationOrderId = $InstanceInfo.'Microsoft.Resources'.additionalInfo.ReservationOrderId


                        $InstanceObject = [PSCustomObject]@{}

                        $AdditionalInfoInstance = [PSCustomObject]@{
                            ResourceUri    = $InstanceInfo.'Microsoft.Resources'.resourceUri
                            Location       = $InstanceInfo.'Microsoft.Resources'.location
                            additionalInfo = [PSCustomObject]@{
                                ConsumptionMeter          = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.ConsumptionMeter) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.ConsumptionMeter }
                                ImageType                 = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.ImageType) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.ImageType }
                                AHB                       = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.AHB) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.AHB }
                                vCores                    = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.vCores) { 0 } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.vCores }
                                VCPUs                     = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.VCPUs) { 0 } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.VCPUs }
                                ServiceType               = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.ServiceType) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.ServiceType }
                                ResourceCategory          = ""
                                Edition                   = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.Edition) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.Edition }
                                LicenseType               = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.LicenseType) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.LicenseType }
                                HostLicenseType           = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.HostLicenseType) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.HostLicenseType }
                                OS                        = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.OS) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.OS }
                                IsVM                      = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.IsVM) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.IsVM }
                                NumberOfCores             = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.NumberOfCores) { 0 } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.NumberOfCores }
                                NumberOfLogicalProcessors = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.NumberOfLogicalProcessors) { 0 } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.NumberOfLogicalProcessors }
                                SLO                       = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.SLO) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.SLO }
                                ServerSku                 = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.ServerSku) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.ServerSku }
                                ServerEdition             = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.ServerEdition) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.ServerEdition }
                                IsHAEnabled               = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.IsHAEnabled) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.IsHAEnabled }
                            }
                        }

                        $InstanceObject | Add-Member -MemberType NoteProperty -Name "Microsoft.Resources" -Value $AdditionalInfoInstance

                        if ($Obfuscate.IsPresent)
                        {
                            # Pick a prefix (prod_/nonprod_) based on the original
                            # resourceUri before any obfuscation, so we cannot match
                            # against an already-obfuscated value below.
                            $Prefix = if ($UsageDataExport[$Item].ResourceId -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or $UsageDataExport[$Item].ResourceId -match '(^|/|-)([dts])-') { 'nonprod_' } else { 'prod_' }

                            # Obfuscate the consumption ResourceUri while PRESERVING the ARM path structure via the shared Build-ObfuscatedResourceUri helper (Functions/ResourceInventory.Functions.ps1): the dashboard categorises rows by parsing provider+type and the mc_* RG marker (AKS/VMSS/ACI/ACR/Kusto), which a flat opaque token destroys - making those rows invisible. See the helper for the segment-walk contract.
                            $RawUri = $InstanceObject.'Microsoft.Resources'.resourceUri

                            # Per-run caches keyed by REAL value, so the same real sub id / RG / resource name always maps to the same token within a run. Kept SEPARATE from $ResourceIdDictionary because that dictionary's public contract (the ObfuscationDictionary file) maps obfuscated FULL Azure ids to real values - don't pollute it with bare sub/RG/name fragments.
                            if (-not $script:ConsumptionSubCache) { $script:ConsumptionSubCache = @{} }
                            if (-not $script:ConsumptionRgCache) { $script:ConsumptionRgCache = @{} }
                            if (-not $script:ConsumptionNameCache) { $script:ConsumptionNameCache = @{} }

                            # Cross-link diagnostic (case-drift early warning): a TOP-LEVEL resourceUri absent from $Global:ResourceIdDictionary is legitimate for resources deleted between the graph scan and the billing pull, or a -Service-narrowed inventory. Since the dictionary is OrdinalIgnoreCase, this no longer signals a lowercasing regression - it means the uri is genuinely absent. Only the top-level case is surfaced (child rows would flood), routed to the debug log ONLY (-NoConsole / -ToDebugLog) since $RawUri is a real id. Top-level == the leaf name sits at provider-relative index 2 (a 3- or 4-segment provider tail), matching Build-ObfuscatedResourceUri's leaf rule.
                            if ($RawUri -match '^/subscriptions/[^/]+(/resourcegroups/[^/]+)?/providers/(.+)$')
                            {
                                $DiagProvCount = ($Matches[2] -split '/').Count
                                if (($DiagProvCount -eq 3 -or $DiagProvCount -eq 4) -and -not ($null -ne $Global:ResourceIdDictionary -and $Global:ResourceIdDictionary.ContainsKey($RawUri)))
                                {
                                    Write-Log -Message ("Consumption cross-link miss: top-level resourceUri not found in inventory dictionary (leaf uses a name-cache token; the dictionary is case-insensitive, so this means the resource is genuinely absent - deleted between the graph scan and the billing pull, or outside a -Service-narrowed inventory): {0}" -f $RawUri) -Severity 'Info' -NoConsole -ToDebugLog
                                }
                            }

                            # Sub/RG are NOT joined to any shared dictionary here ($null): they use the consumption caches only, exactly as before. Only the LEAF name reuses the inventory token, read-only, via $Global:ResourceIdDictionary keyed by $RawUri.
                            $ObfuscatedUri = Build-ObfuscatedResourceUri -RawUri $RawUri -Prefix $Prefix -SubscriptionDictionary $null -ResourceGroupDictionary $null -NameDictionary $Global:ResourceIdDictionary -SubCache $script:ConsumptionSubCache -RgCache $script:ConsumptionRgCache -NameCache $script:ConsumptionNameCache

                            $UsageDataExport[$Item].ResourceId = $ObfuscatedUri
                            $InstanceObject.'Microsoft.Resources'.resourceUri = $ObfuscatedUri

                            # Obfuscate reservation identifiers (customer purchasing fingerprints)
                            if (![string]::IsNullOrEmpty($UsageDataExport[$Item].ReservationId))
                            {
                                $UsageDataExport[$Item].ReservationId = 'obfuscated'
                            }
                            if (![string]::IsNullOrEmpty($UsageDataExport[$Item].ReservationOrderId))
                            {
                                $UsageDataExport[$Item].ReservationOrderId = 'obfuscated'
                            }
                        }

                        $UsageDataExport[$Item].InstanceData = $InstanceObject | ConvertTo-Json -Compress

                        $NewUsageDataExport.Add($UsageDataExport[$Item]) | Out-Null
                    }

                    $NewUsageDataExport | Select-Object InstanceData, MeterCategory, MeterId, MeterName, MeterRegion, MeterSubCategory, Quantity, Unit, UsageStartTime, UsageEndTime, ResourceId, ResourceLocation, ConsumptionMeter, ReservationId, ReservationOrderId | Export-Csv -LiteralPath $Global:ConsumptionFileCsv -Encoding utf8 -Append -NoTypeInformation

                    # Count rows actually WRITTEN to Consumption_*.csv this page (after the null-InstanceData skip and -ResourceGroup filter), NOT rows FETCHED: $Global:ConsumptionRecordCount is the documented 'rows written' figure, and accumulating the pre-filter count overstated it in a -ResourceGroup-scoped run. The fetched count stays visible in the 'Records found' line above.
                    $ConsumptionRecordsThisSub += $NewUsageDataExport.Count

                } while ('ContinuationToken' -in $UsageData.psobject.properties.name -and $UsageData.ContinuationToken)
            }
            catch
            {
                # Catch defensively (most common cause: a broken Az install the import probe should have caught, plus transient ARM throttling or a non-billable sub) so one sub's failure does not abort the rest of the run. Capture WHERE it stopped (page index + records collected) so the truncation is precise rather than a silently-short CSV; rows already written are valid and kept, but this sub's consumption is reported INCOMPLETE.
                $ConsumptionFailedThisSub = $true
                $ConsumptionFailureMessage = ("{0} (stopped at consumption page {1}, after {2} record(s); this subscription's consumption is INCOMPLETE)" -f $_.Exception.Message, $ConsumptionPageIndex, $ConsumptionRecordsThisSub)
                Write-Log -Message ("Consumption query failed for {0}: {1}" -f $sub.Name, $ConsumptionFailureMessage) -Severity 'Warning'
            }

            # Aggregate per-sub consumption health into globals the wrapper reads
            # at the end of the run. Globals here live in the wrapper's scope
            # because ResourceInventory.ps1 is invoked via `& <path>`.
            if ($null -eq $Global:ConsumptionRecordCount) { $Global:ConsumptionRecordCount = 0 }
            if ($null -eq $Global:ConsumptionFailedSubs) { $Global:ConsumptionFailedSubs = @() }
            $Global:ConsumptionRecordCount += $ConsumptionRecordsThisSub
            # Per-INVOCATION total, separate from the run-wide global: the wrapper invokes this per-sub in the SAME process, so $Global:ConsumptionRecordCount is cumulative across subs. The per-sub Diagnostics log must report only THIS sub's count and be able to fire its zero-record warning even after an earlier sub collected plenty. Script-scoped (not a new global) so it resets naturally per invocation.
            if ($null -eq $script:ConsumptionRecordsThisRun) { $script:ConsumptionRecordsThisRun = 0 }
            $script:ConsumptionRecordsThisRun += $ConsumptionRecordsThisSub
            if ($ConsumptionFailedThisSub)
            {
                $Global:ConsumptionFailedSubs += [pscustomobject]@{
                    Name             = $sub.Name
                    Id               = $sub.Id
                    Message          = $ConsumptionFailureMessage
                    Complete         = $false
                    PageAtFailure    = $ConsumptionPageIndex
                    RecordsCollected = $ConsumptionRecordsThisSub
                }
            }
        }

        # No $DebugPreference restore here on purpose: the suppression above is function-scoped and ends when this function returns. The old trailing assignment was the function's LAST statement (dead code that read like a safeguard) and set the literal 'Continue', which would have forced debug output on for a -Debug:$false caller had it ever been reachable.
    }

    InitializeInventoryProcessing

    # Per-phase timing for the report header, in $script: scope (NOT a new $Global:) so ProcessSummary can read it later without polluting the global namespace or persisting across subs under -RunAllSubs. The stopwatches wrap the existing calls WITHOUT reordering them, replacing the single opaque 'Reporting time' with a per-phase breakdown.
    $script:PhaseTimings = [ordered]@{}

    # Metric-query API calls issued by THIS invocation, for the per-sub Diagnostics log: $Global:MetricsApiCallCount is deliberately RUN-cumulative (the wrapper reports a whole-run total), so handing it over directly would make the third sub's log claim sub1+sub2+sub3. Take the delta across this invocation's metrics phase, mirroring $script:ConsumptionRecordsThisRun.
    $MetricsApiCallsBefore = if ($null -ne $Global:MetricsApiCallCount) { [int]$Global:MetricsApiCallCount } else { 0 }

    $MetricsPhaseTimer = [System.Diagnostics.Stopwatch]::StartNew()
    CreateMetricsJob
    $MetricsPhaseTimer.Stop()

    # Clamped at 0: the only writer is Metrics.ps1's '+=' so the delta cannot normally
    # go negative, but the parallel worker resets the global to 0 for its slice, and a
    # diagnostics figure must never render as a negative count if that ever moves.
    $MetricsApiCallsAfter = if ($null -ne $Global:MetricsApiCallCount) { [int]$Global:MetricsApiCallCount } else { 0 }
    $script:MetricsApiCallsThisRun = [Math]::Max(0, $MetricsApiCallsAfter - $MetricsApiCallsBefore)

    $CollectorPhaseTimer = [System.Diagnostics.Stopwatch]::StartNew()
    CreateResourceJobs
    $CollectorPhaseTimer.Stop()

    ProcessMetricsResult
    ProcessResourceResult

    # VM placement CSV for capacity planning, a SEPARATE file (not new VM-collector fields) so Inventory_*.json and its server ingestion contract are untouched (Extension/VMPlacement.ps1). Runs after ProcessResourceResult (needs $Global:SmaResources populated; no Azure calls of its own).
    # Written to the PARENT InventoryRoot tagged with SubscriptionID (the wrapper concatenates per-sub PARTs into one tenant-wide CSV) so it is NOT swept into the per-sub zip; a standalone run keeps it by its report. A failure here is downgraded to a warning since the report is already written.
    # OPT-IN: only produced when -CapacityPlan is passed. Without the switch no VMPlacement*.csv is written or packaged (the wrapper's aggregation is gated on the same switch), so a default run's output is unchanged bar the removal of this one capacity-planning file.
    if ($CapacityPlan.IsPresent)
    {
        try
        {
            $PlacementScript = Join-Path $PSScriptRoot 'Extension/VMPlacement.ps1'
            if (Test-Path -LiteralPath $PlacementScript -PathType Leaf)
            {
                if ($RunAllSubs.IsPresent)
                {
                    $PlacementDir = Split-Path -Path ($Global:DefaultPath.TrimEnd([IO.Path]::DirectorySeparatorChar, '/', '\')) -Parent
                    $PlacementTag = if (![string]::IsNullOrEmpty($SubscriptionID)) { $SubscriptionID } else { $Global:CurrentDateTime }
                    $PlacementCsv = Join-Path $PlacementDir ("VMPlacementPart_" + $Global:ReportName + "_" + $Global:CurrentDateTime + "_" + $PlacementTag + ".csv")
                }
                else
                {
                    $PlacementCsv = ($DefaultPath + "VMPlacement_" + $Global:ReportName + "_" + $CurrentDateTime + ".csv")
                }

                & $PlacementScript -CsvFile $PlacementCsv
            }
            else
            {
                Write-Log -Message ("VM placement CSV skipped: {0} not found." -f $PlacementScript) -Severity 'Error'
            }
        }
        catch
        {
            Write-Log -Message ("VM placement CSV failed: {0}. The rest of the run is unaffected." -f $_.Exception.Message) -Severity 'Error'
        }
    }

    if (!$SkipMetrics.IsPresent)
    {
        $script:PhaseTimings['Metrics collection (Azure Monitor)'] = $MetricsPhaseTimer.Elapsed
    }
    $script:PhaseTimings['Resource detail collection (service collectors)'] = $CollectorPhaseTimer.Elapsed

    if (!$SkipConsumption.IsPresent)
    {
        $ConsumptionPhaseTimer = [System.Diagnostics.Stopwatch]::StartNew()
        GetResourceConsumption
        #ProcessResourceConsumption
        $ConsumptionPhaseTimer.Stop()
        $script:PhaseTimings['Consumption / cost collection (billing)'] = $ConsumptionPhaseTimer.Elapsed
    }
}

function FinalizeOutputs
{
    function ProcessSummary()
    {
        Write-Log -Message ('Creating Summary Report') -Severity 'Info'
        Write-Log -Message ('Starting Summary Report Processing Job.') -Severity 'Info'

        if ($PSScriptRoot -like '*\*')
        {
            $SummaryPath = Get-ChildItem -LiteralPath ($PSScriptRoot + '\Extension\Summary.ps1') -Recurse
        }
        else
        {
            $SummaryPath = Get-ChildItem -LiteralPath ($PSScriptRoot + '/Extension/Summary.ps1') -Recurse
        }

        # Tenant ID is shown in the report header for reference, but it is a
        # real Azure identifier and must NOT appear in an obfuscated (shareable)
        # report. Pass it only when NOT obfuscating; the obfuscated HTML then
        # carries no tenant GUID, consistent with the four obfuscation
        # dictionaries that scrub every other identifier.
        $ReportTenantId = if ($Obfuscate.IsPresent) { $null } else { $TenantID }
        $ReportTitle = ('Azure Resource Inventory - {0}' -f $Global:ReportName)

        # Unlike a single collector failing (where the rest of the inventory proceeds), the HTML report IS the deliverable, so there is nothing meaningful to continue to. Catch only to give a clear, specific diagnosis (which file, which stage) instead of a raw Summary.ps1 exception, then re-throw so the wrapper still marks this subscription failed (same propagation as every other uncaught throw).
        try
        {
            $null = & $SummaryPath -JsonFile $Global:JsonFile -HtmlFile $Global:HtmlFile -Title $ReportTitle -TenantId $ReportTenantId -Version $Global:Version -ExtractionRunTime $Runtime -ReportingRunTime $ReportingRunTime -PhaseTimings $script:PhaseTimings -PlatOS $PlatformOS -ConsumptionFile $Global:ConsumptionFileCsv
        }
        catch
        {
            Write-Log -Message ("HTML report generation FAILED: {0}" -f $_.Exception.Message) -Severity 'Error'
            Write-Log -Message ("The Inventory/Metrics/Consumption data files were still written to {0}, but no HTML report or zip was produced for this run." -f $Global:DefaultPath) -Severity 'Error'
            throw
        }
    }

    ProcessSummary
}

# === Pre-flight checks === Detect common environment problems before transcript/auth/per-subscription work; skipped under -RunAllSubs (the wrapper already ran them at top level), full block on a standalone run.
# Kept INLINE (not shared with Invoke-PreFlightChecks in RunAllSubscriptions.Functions.ps1) so the checks have no file-location dependency in the broken environments they catch; each gate must exit, not throw (a script-scope throw is swallowed by SilentlyContinue).
if (-not $RunAllSubs.IsPresent)
{

    # Honor -OutputDirectory when the caller passed one (CheckPowerShell re-validates it later and is authoritative; Resolve-Path defensively, falling back to the raw value so the write probe surfaces the real error). Get-RdaInventoryRoot (Common.Functions.ps1) is the SINGLE resolver: it creates, PROVES writable, and for the DEFAULT location degrades to a writable fallback.
    # -NoInherit because this process ESTABLISHES the root for a standalone run, so a stale pin in this shell's environment must not be trusted.
    $RootResult = Get-RdaInventoryRoot -Requested $OutputDirectory -NoInherit
    if (-not $RootResult.Ok)
    {
        Write-Host ("ERROR: {0}" -f $RootResult.Message) -ForegroundColor Red
        exit 1
    }
    $PreFlightInventoryRoot = $RootResult.Path
    if ($RootResult.IsFallback)
    {
        Write-Host ("WARNING: {0}" -f $RootResult.Message) -ForegroundColor Yellow
    }
    # Pin it so the report folder derived in Variables() lands under the SAME root
    # this pre-flight just validated, instead of re-deriving it from $HOME.
    Set-RdaInventoryRootForChildren -Path $PreFlightInventoryRoot

    Write-Host "Running pre-flight checks..." -ForegroundColor Cyan

    # 0. -Service fast-fail: when -Service is supplied but NONE of the names match a collector, the run would otherwise authenticate and extract everything only to produce an empty inventory (and a failed report) while exiting 0 - a silent-looking failure for a scripted recovery. Validate up front, before auth, and hard-fail (exit 1) with the full valid-name list. Partial matches pass through here (CreateResourceJobs warns on the unmatched).
    if ($Service -and @($Service).Count -gt 0)
    {
        $PreFlightAvailableServices = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Services') -Filter '*.ps1' -Recurse | ForEach-Object { $_.BaseName } | Sort-Object)
        $PreFlightMatchedServices = @($Service | Where-Object { $_ -in $PreFlightAvailableServices })
        if (@($PreFlightMatchedServices).Count -eq 0)
        {
            # Hard-fail with exit 1, NOT throw: $ErrorActionPreference is SilentlyContinue for a normal run, under which a bare script-scope throw is swallowed and the run would authenticate, extract, then produce an empty report exiting 0. exit 1 is the established hard-fail signal, and is safe here because this whole block is gated on -not $RunAllSubs.
            Write-Host ("ERROR: -Service matched no collectors. Requested: [{0}]." -f ($Service -join ', ')) -ForegroundColor Red
            Write-Host ("Valid collector names: [{0}]" -f ($PreFlightAvailableServices -join ', ')) -ForegroundColor Yellow
            exit 1
        }
        Write-Host ("Pre-flight: -Service will collect {0} of {1} collectors: [{2}]" -f @($PreFlightMatchedServices).Count, @($PreFlightAvailableServices).Count, ($PreFlightMatchedServices -join ', ')) -ForegroundColor Green
    }

    # 0b. -ObfuscationDictionary fast-fail: seeding only makes sense with -Obfuscate, and a missing/unreadable seed must stop the run BEFORE auth rather than silently mint fresh tokens that make a later merge fail to line up. exit 1 (not throw) for the same SilentlyContinue reason as the -Service gate above.
    if (-not [string]::IsNullOrEmpty($ObfuscationDictionary))
    {
        if (-not $Obfuscate.IsPresent)
        {
            Write-Host "ERROR: -ObfuscationDictionary requires -Obfuscate (there are no obfuscation dictionaries to seed without it)." -ForegroundColor Red
            exit 1
        }
        if (-not (Test-Path -LiteralPath $ObfuscationDictionary -PathType Leaf))
        {
            Write-Host ("ERROR: -ObfuscationDictionary file not found: {0}" -f $ObfuscationDictionary) -ForegroundColor Red
            exit 1
        }
        try
        {
            $null = Get-Content -LiteralPath $ObfuscationDictionary -Raw | ConvertFrom-Json
        }
        catch
        {
            Write-Host ("ERROR: -ObfuscationDictionary is not valid JSON: {0}" -f $ObfuscationDictionary) -ForegroundColor Red
            exit 1
        }
        Write-Host ("Pre-flight: -ObfuscationDictionary will seed obfuscation tokens from {0}" -f $ObfuscationDictionary) -ForegroundColor Green
    }

    # 1. Cloud Shell mount detection. See Run-AllSubscriptions.ps1 for the rationale.
    if (Get-Command Get-CloudDrive -ErrorAction SilentlyContinue)
    {
        $CheckCloudDrive = Get-CloudDrive 3>$null 2>$null
        if ($null -eq $CheckCloudDrive)
        {
            Write-Host ""
            Write-Host "WARNING: Cloud Shell detected, but no storage account is mounted." -ForegroundColor Yellow
            Write-Host "  Outputs in $PreFlightInventoryRoot will be lost when this Cloud Shell session ends." -ForegroundColor Yellow
            Write-Host "  To persist outputs, mount a storage account first:" -ForegroundColor Yellow
            Write-Host "    clouddrive mount" -ForegroundColor Yellow
            Write-Host "  Continuing in ephemeral mode - download the report ZIP from $PreFlightInventoryRoot before closing the shell." -ForegroundColor Yellow
            Write-Host ""
        }
        else
        {
            Write-Host ("Cloud Shell drive mounted: {0}" -f $CheckCloudDrive.Name) -ForegroundColor Green
        }
    }

    # 2. Disk space probe.
    try
    {
        $RootItem = Get-Item -LiteralPath $PreFlightInventoryRoot -ErrorAction Stop
        $Drive = $RootItem.PSDrive
        if ($null -ne $Drive -and $null -ne $Drive.Free)
        {
            $FreeMB = [math]::Round($Drive.Free / 1MB, 0)
            if ($FreeMB -lt 100)
            {
                # exit 1, NOT throw: a bare script-scope throw is swallowed under SilentlyContinue, so the gate would print 'Pre-flight checks passed.' and continue to authentication. Matches the -Service / -ObfuscationDictionary gates above and the wrapper's Exit-Wrapper -Code 1.
                Write-Host ("ERROR: Free disk space at {0} is {1} MB; the script needs at least 100 MB to start. Free space and re-run." -f $PreFlightInventoryRoot, $FreeMB) -ForegroundColor Red
                exit 1
            }
            elseif ($FreeMB -lt 500)
            {
                Write-Host ("WARNING: Free disk space at {0} is {1} MB. A large multi-subscription run can exceed this. Consider freeing space before running." -f $PreFlightInventoryRoot, $FreeMB) -ForegroundColor Yellow
            }
            else
            {
                # InvariantCulture, mirroring the wrapper copy in
                # Functions/RunAllSubscriptions.Functions.ps1: a bare "{0:N0}" formats with
                # CURRENT culture, so an en-NL host renders 22378 as "22.378 MB", which
                # reads as a fraction of a MB rather than ~22 GB.
                Write-Host ("Free disk space: {0} MB at {1}" -f $FreeMB.ToString('N0', [cultureinfo]::InvariantCulture), $PreFlightInventoryRoot) -ForegroundColor Green
            }
        }
    }
    catch
    {
        # The low-space branch above now exits directly, so nothing reaching this
        # catch is a deliberate hard-fail - it is only a failure to MEASURE, which
        # stays a warning (an unreadable PSDrive.Free must not block a run that
        # would otherwise work).
        Write-Host ("WARNING: Could not determine free disk space at {0}: {1}" -f $PreFlightInventoryRoot, $_.Exception.Message) -ForegroundColor Yellow
    }

    # 3. Write probe.
    $ProbePath = Join-Path $PreFlightInventoryRoot (".write-probe-{0}.tmp" -f ([guid]::NewGuid()))
    try
    {
        Set-Content -LiteralPath $ProbePath -Value 'preflight write probe' -Encoding utf8 -ErrorAction Stop
        $ProbeRead = Get-Content -LiteralPath $ProbePath -Raw -ErrorAction Stop
        if ($ProbeRead -notmatch 'preflight write probe')
        {
            throw "Write probe content mismatch (read back '$ProbeRead')"
        }
        Remove-Item -LiteralPath $ProbePath -Force -ErrorAction Stop
        Write-Host ("Write probe: OK ({0})" -f $PreFlightInventoryRoot) -ForegroundColor Green
    }
    catch
    {
        try { if (Test-Path -LiteralPath $ProbePath) { Remove-Item -LiteralPath $ProbePath -Force -ErrorAction SilentlyContinue } }
        catch { Write-Verbose ("Probe cleanup failed at {0}: {1}" -f $ProbePath, $_.Exception.Message) }
        # exit 1, NOT throw (see the disk-space gate above): a swallowed throw let an unwritable output directory print 'passed' and fail later at exit 0. Reaching here is now unusual - Get-RdaInventoryRoot already created + write-probed the root (with a fallback for the default path) - so it fires for an unusable explicit -OutputDirectory or one that became unwritable since.
        Write-Host ("ERROR: cannot write to {0}: {1}" -f $PreFlightInventoryRoot, $_.Exception.Message) -ForegroundColor Red
        Write-Host "  This usually means a readonly directory, denied permissions, an antivirus or DLP product blocking writes, or a stale handle." -ForegroundColor Yellow
        Write-Host "  Verify the directory is writable and re-run, or pass -OutputDirectory with a writable path." -ForegroundColor Yellow
        exit 1
    }

    Write-Host "Pre-flight checks passed." -ForegroundColor Green
    Write-Host ""
}

# Setup and Inventory Gathering. Variables + RunInventorySetup populate $Global:DefaultPath / ReportName / CurrentDateTime, which the transcript path needs, so Start-Transcript MUST run AFTER RunInventorySetup - otherwise those were all $null and the transcript landed in the cwd as 'Transcript_Log__.txt' with the report name and timestamp missing.
$Global:Runtime = Measure-Command -Expression {
    Variables
    RunInventorySetup

    $Global:PowerShellTranscriptFile = ($Global:DefaultPath + "Transcript_Log_" + $Global:ReportName + "_" + $Global:CurrentDateTime + ".txt")
    Start-Transcript -LiteralPath $Global:PowerShellTranscriptFile -UseMinimalHeader
}

# Execution and processing of inventory. Wrap in try/finally so this run's transcript frame is ALWAYS stopped even on a terminating error: transcripts are a process-wide STACK and the -RunAllSubs wrapper invokes this via & in the SAME process, so an orphaned open frame makes the wrapper's Stop-Transcript pop THIS frame instead, leaving the wrapper transcript held open/undeletable. The inner try/catch tolerates the rare case where no transcript is active.
try
{
    $Global:ReportingRunTime = Measure-Command -Expression {
        ExecuteInventoryProcessing
    }
}
finally
{
    try { Stop-Transcript }
    catch { }
}

# Prepare the summary and outputs
FinalizeOutputs

Write-Log -Message ("Compressing Resources Output: {0}" -f $Global:ZipOutputFile) -Severity 'Info'

if ($Obfuscate.IsPresent)
{
    $Global:DictionaryFile = ($DefaultPath + "ObfuscationDictionary_" + $Global:ReportName + "_" + $CurrentDateTime + ".json")

    $Dictionary = @{
        # InvariantCulture: this is a PERSISTED field in ObfuscationDictionary_*.json,
        # so a non-Gregorian host would write a Buddhist/Hijri year into dictionary data.
        GeneratedAt         = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', [cultureinfo]::InvariantCulture)
        ResourceIdMap       = @{}
        ResourceNameMap     = @{}
        SubscriptionMap     = @{}
        ResourceGroupMap    = @{}
        # Maps an obfuscated subscription token to the REAL subscription display
        # name, so Unmask-Obfuscation.ps1 can resolve the friendly name fully
        # offline. The other maps store ARM resource Ids, which only contain the
        # subscription GUID - never the name - so without this map the only way
        # back to a name was an online Get-AzSubscription call.
        SubscriptionNameMap = @{}
        # Maps an obfuscated tag-value token back to the REAL tag value, so tag
        # values (which keep their keys but have obfuscated values) can be
        # reversed offline like every other obfuscated field.
        TagMap              = @{}
        # Maps an obfuscated free-text/identity token back to the REAL value
        # (Description, FriendlyName, CreatedBy, RoleName, container image, etc.)
        # so Reveal-Obfuscation.ps1 can restore these free-form fields offline.
        FreeTextMap         = @{}
    }

    foreach ($key in $ResourceIdDictionary.Keys)
    {
        $Dictionary.ResourceIdMap[$ResourceIdDictionary[$key]] = $key
    }
    foreach ($key in $ResourceNameDictionary.Keys)
    {
        $Dictionary.ResourceNameMap[$ResourceNameDictionary[$key]] = $key
    }
    foreach ($key in $ResourceSubscriptionDictionary.Keys)
    {
        $Dictionary.SubscriptionMap[$ResourceSubscriptionDictionary[$key]] = $key
    }
    foreach ($key in $ResourceResourceGroupDictionary.Keys)
    {
        $Dictionary.ResourceGroupMap[$ResourceResourceGroupDictionary[$key]] = $key
    }

    # Populate token -> real subscription name. The dictionary key ($key) is the
    # real resource Id, which embeds the subscription GUID; resolve that GUID to
    # its display name via the already-loaded $Global:Subscriptions. Uses only
    # in-memory data (no extra Azure calls); skips entries whose name cannot be
    # resolved so the map only ever holds genuine names.
    foreach ($key in $ResourceSubscriptionDictionary.Keys)
    {
        $SubToken = $ResourceSubscriptionDictionary[$key]
        if ($Dictionary.SubscriptionNameMap.ContainsKey($SubToken)) { continue }
        $SubGuid = if ($key -match '(?i)/subscriptions/([^/]+)') { $Matches[1] } else { $null }
        if (-not [string]::IsNullOrEmpty($SubGuid))
        {
            $SubName = ($Global:Subscriptions | Where-Object { $_.id -eq $SubGuid } | Select-Object -First 1).name
            if (-not [string]::IsNullOrEmpty($SubName))
            {
                $Dictionary.SubscriptionNameMap[$SubToken] = $SubName
            }
        }
    }

    # Invert the tag-value dictionary (real value -> token) into TagMap
    # (token -> real value) so the unmask helper can reverse tag values.
    if ($null -ne $Global:TagValueDictionary)
    {
        foreach ($realValue in $Global:TagValueDictionary.Keys)
        {
            $Dictionary.TagMap[$Global:TagValueDictionary[$realValue]] = $realValue
        }
    }

    # Invert the free-text dictionary (real value -> token) into FreeTextMap
    # (token -> real value) so Reveal-Obfuscation.ps1 can restore free-form
    # fields (Description, FriendlyName, CreatedBy, etc.).
    if ($null -ne $Global:FreeTextDictionary)
    {
        foreach ($realValue in $Global:FreeTextDictionary.Keys)
        {
            $Dictionary.FreeTextMap[$Global:FreeTextDictionary[$realValue]] = $realValue
        }
    }

    $Dictionary | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $Global:DictionaryFile -Encoding utf8
    Write-Log -Message ("Obfuscation dictionary saved locally: {0}" -f $Global:DictionaryFile) -Severity 'Success'
    Write-Log -Message ("") -Severity 'Info'
    Write-Log -Message ("=== OBFUSCATION NOTICE ===") -Severity 'Warning'
    Write-Log -Message ("The following files are NEVER placed in the shared report zip and must NOT be shared with a report consumer:") -Severity 'Warning'
    Write-Log -Message ("  - Dictionary: {0}" -f $Global:DictionaryFile) -Severity 'Warning'
    Write-Log -Message ("      (the de-obfuscation key. Kept local by default; under the multi-subscription wrapper, if a blob upload target is set it is mirrored to that operator-PRIVATE container - which must stay private.)") -Severity 'Warning'
    Write-Log -Message ("  - Transcript: {0}" -f $Global:PowerShellTranscriptFile) -Severity 'Warning'
    # The error log is created only when an error was logged; it can contain raw
    # exception text / local paths carrying real identifiers, so it is local-only
    # (never zipped) and listed here so the operator knows to protect it too.
    if (![string]::IsNullOrEmpty($Global:ErrorLogFile) -and (Test-Path -LiteralPath $Global:ErrorLogFile))
    {
        Write-Log -Message ("  - Error log:  {0}" -f $Global:ErrorLogFile) -Severity 'Warning'
    }
    # The consolidated debug log (per-collector heartbeat + metrics diagnostics)
    # holds real service/resource names and can carry raw exception text, so it
    # is local-only in THIS (-Obfuscate) branch and flagged here alongside the
    # transcript. On a default run it DOES ship in the zip - see the packaging
    # section - which is why this notice is emitted only for obfuscated runs.
    if (![string]::IsNullOrEmpty($Global:DebugLogFile) -and (Test-Path -LiteralPath $Global:DebugLogFile))
    {
        Write-Log -Message ("  - Debug log:  {0}" -f $Global:DebugLogFile) -Severity 'Warning'
    }
    Write-Log -Message ("") -Severity 'Info'
    # Scope the sharing claim to the artifact it is about: under the wrapper this runs once PER SUBSCRIPTION, so an unqualified 'the ZIP is safe to share' told the operator N times a per-sub zip was sendable while never naming the consolidated bundle they should actually send - so operators sent the whole folder, dictionary included.
    if ($RunAllSubs.IsPresent)
    {
        Write-Log -Message ("This subscription's ZIP is obfuscated and is one COMPONENT of the run's bundle - it is not the file to send on its own.") -Severity 'Success'
        Write-Log -Message ("Send the single AllSubscriptions_*.zip named at the end of the run ('SEND THIS ONE FILE'); it already contains this zip.") -Severity 'Success'
    }
    else
    {
        Write-Log -Message ("The ZIP file is safe to share with AWS or partners. Send that ZIP only - not the folder it sits in.") -Severity 'Success'
    }
    Write-Log -Message ("Partners may ask about obfuscated names (e.g. 'prod_a1b2c3d4-...'). Use the dictionary file to look up the real resource name and respond.") -Severity 'Info'
    Write-Log -Message ("Delete the dictionary and transcript when no longer needed for security.") -Severity 'Warning'
}

if ($SkipMetrics.IsPresent)
{
    @{ Metrics = @() } | ConvertTo-Json -Depth 5 -Compress | Out-File -LiteralPath $Global:MetricsJsonFile -Encoding utf8
}
else
{
    # Subscriptions with zero metric-eligible resources produce no Metrics_*.json, but downstream consumers that expect every per-sub bundle to contain one (dashboard ingestion, the ParallelStreamsAggregation tests) reject the bundle when it is missing. Emit an empty-but-valid Metrics JSON at $Global:MetricsJsonFile so the bundle is always structurally complete; wildcard Get-ChildItem because the batched writer suffixes '_<rangeIdx>.json'.
    $MetricsPattern = ('Metrics_{0}_{1}*.json' -f $Global:ReportName, $CurrentDateTime)
    $MetricsAny = @(Get-ChildItem -LiteralPath $DefaultPath -Filter $MetricsPattern -ErrorAction SilentlyContinue)
    if ($MetricsAny.Count -eq 0)
    {
        @{ Metrics = @() } | ConvertTo-Json -Depth 5 -Compress | Out-File -LiteralPath $Global:MetricsJsonFile -Encoding utf8
    }
}

$ConsumptionCreated = Test-Path -LiteralPath $Global:ConsumptionFileCsv

# A subscription with zero billing records produces an empty (0-byte) CSV rather than a header-only one (Export-Csv -Append with no input writes nothing), so treat 0-byte files as 'not created' and emit the header below - otherwise header-parsing consumers (dashboard ingestion, the Pester tests) fail on the empty file and reject the entire per-sub bundle.
$ConsumptionEmpty = $false
if ($ConsumptionCreated)
{
    try
    {
        $ConsumptionEmpty = ((Get-Item -LiteralPath $Global:ConsumptionFileCsv -ErrorAction Stop).Length -eq 0)
    }
    catch
    {
        # Treat unreadable as not-created so the header gets written; safer than
        # leaving an unparseable file in the bundle.
        $ConsumptionEmpty = $true
    }
}

if ($SkipConsumption.IsPresent -or !$ConsumptionCreated -or $ConsumptionEmpty)
{
    "InstanceData,MeterCategory,MeterId,MeterName,MeterRegion,MeterSubCategory,Quantity,Unit,UsageStartTime,UsageEndTime,ResourceId,ResourceLocation,ConsumptionMeter,ReservationId,ReservationOrderId" | Out-File -LiteralPath $Global:ConsumptionFileCsv -Encoding utf8
}

if ($Obfuscate.IsPresent)
{
    # Shareable diagnostics log for this (obfuscated) run - phase timings + per-sub collector/metrics/consumption health, every identifier scrubbed via Protect-DiagnosticText, built by Write-RdaShareableDiagnosticsLog so the SAME builder serves both packaging branches. Returns $null on any build/write failure (downgraded to a warning) so the guard below cannot inject a missing path into the archive list and break packaging.
    $DiagnosticsFile = Write-RdaShareableDiagnosticsLog -DefaultPath $DefaultPath -ReportName $Global:ReportName -RunDateTime $Global:CurrentDateTime -Version $Global:Version -PhaseTimings $script:PhaseTimings -ConsumptionRecordCount $(if ($null -ne $script:ConsumptionRecordsThisRun) { [int]$script:ConsumptionRecordsThisRun } else { 0 }) -ConsumptionRequested:(-not $SkipConsumption.IsPresent) -MetricsApiCallCount $(if ($null -ne $script:MetricsApiCallsThisRun) { [int]$script:MetricsApiCallsThisRun } else { 0 }) -MetricsRequested:(-not $SkipMetrics.IsPresent) -Obfuscated:$Obfuscate.IsPresent

    # Exclude the obfuscation dictionary (maps obfuscated values back to REAL ids) and the transcript (raw Write-Log auth UPN / tenant GUID / sub names) from the obfuscated zip; ship only a specific safe obfuscated .json file list. The curated dictionary-scrubbed Diagnostics_*.log is added explicitly below.
    # The LOCAL-only .log files (DebugLog_* heartbeat+metrics, legacy Heartbeat_*/ErrorLog_*) carry a real sub GUID and real names, are not .json so this filter never sweeps them, and are never added - with explicit -notlike guards hardening the seam if the filter is later broadened.
    $JsonFiles = Get-ChildItem -LiteralPath $DefaultPath -Filter "*.json" | Where-Object { $_.Name -notlike "ObfuscationDictionary_*" -and $_.Name -notlike "Full_*" -and $_.Name -notlike "Heartbeat_*" -and $_.Name -notlike "DebugLog_*" -and $_.Name -notlike "ErrorLog_*" } | Select-Object -ExpandProperty FullName
    # Include the shareable diagnostics .log if it was successfully written.
    # Guarded (not assumed) so a diagnostics build/write failure above - which is
    # caught and downgraded to a warning - cannot inject a $null/missing path
    # into the archive list and break packaging of the actual report.
    $ShareableExtras = @()
    if (-not [string]::IsNullOrEmpty($DiagnosticsFile) -and (Test-Path -LiteralPath $DiagnosticsFile)) { $ShareableExtras += $DiagnosticsFile }
    $CompressionOutput = @{
        LiteralPath      = @($Global:HtmlFile, $Global:ConsumptionFileCsv) + $ShareableExtras + $JsonFiles
        CompressionLevel = 'Fastest'
        DestinationPath  = [WildcardPattern]::Escape($Global:ZipOutputFile)
    }
    Write-Log -Message ('Obfuscate mode: transcript log excluded from zip (kept locally for debug)') -Severity 'Info'
}
else
{
    # Shareable diagnostics log for the default (non-obfuscated) run - same builder WITHOUT -Obfuscated so the header states it; identifiers are still class-masked by Protect-DiagnosticText. The surrounding report already carries real names, so shipping the log adds no new exposure; guarded like the obfuscate path so a build/write failure cannot break packaging.
    $DiagnosticsFile = Write-RdaShareableDiagnosticsLog -DefaultPath $DefaultPath -ReportName $Global:ReportName -RunDateTime $Global:CurrentDateTime -Version $Global:Version -PhaseTimings $script:PhaseTimings -ConsumptionRecordCount $(if ($null -ne $script:ConsumptionRecordsThisRun) { [int]$script:ConsumptionRecordsThisRun } else { 0 }) -ConsumptionRequested:(-not $SkipConsumption.IsPresent) -MetricsApiCallCount $(if ($null -ne $script:MetricsApiCallsThisRun) { [int]$script:MetricsApiCallsThisRun } else { 0 }) -MetricsRequested:(-not $SkipMetrics.IsPresent)
    $ShareableExtras = @()
    if (-not [string]::IsNullOrEmpty($DiagnosticsFile) -and (Test-Path -LiteralPath $DiagnosticsFile)) { $ShareableExtras += $DiagnosticsFile }

    # Include the consolidated DEBUG log in the DEFAULT (non-obfuscated) zip ONLY: this bundle already carries real sub/RG/resource names throughout, so the log's real names add no new class of identifier while its per-collector heartbeat + metrics diagnostics explain a thin report without a second support-logs run.
    # Deliberately NOT done in the -Obfuscate branch (that bundle must carry no real ids and the log is unscrubbed); added by explicit path, and the DebugLog_* -notlike JSON-sweep guard stays in both branches so an obfuscated run still cannot pick it up.
    if (-not [string]::IsNullOrEmpty($Global:DebugLogFile) -and (Test-Path -LiteralPath $Global:DebugLogFile))
    {
        $ShareableExtras += $Global:DebugLogFile
        Write-Log -Message ('Debug log INCLUDED in zip (non-obfuscated run): {0}' -f (Split-Path -Path $Global:DebugLogFile -Leaf)) -Severity 'Warning'
        Write-Log -Message ('  It carries real service/resource names and raw exception text. The report in this bundle is already non-obfuscated. Re-run with -Obfuscate to keep the debug log LOCAL.') -Severity 'Warning'
    }

    # Use the SAME hardened json file list as the obfuscated branch, not a broad DefaultPath+'*.json' wildcard: in a default run none of the excluded names exist as .json so it ships the same files today, but keeping the branches symmetric stops a future local *.json artifact being swept into the default zip while filtered out of the obfuscated one.
    $JsonFiles = Get-ChildItem -LiteralPath $DefaultPath -Filter "*.json" | Where-Object { $_.Name -notlike "ObfuscationDictionary_*" -and $_.Name -notlike "Full_*" -and $_.Name -notlike "Heartbeat_*" -and $_.Name -notlike "DebugLog_*" -and $_.Name -notlike "ErrorLog_*" } | Select-Object -ExpandProperty FullName

    # Exclude the PowerShell transcript from the default zip too (it captures the authenticated account UPN, tenant/subscription ids, and local paths); keep it on disk locally for debugging. The Diagnostics_*.log (a .log, not swept by the *.json wildcard) is added explicitly via $ShareableExtras so it still ships.
    $CompressionOutput = @{
        LiteralPath      = @($Global:HtmlFile, $Global:ConsumptionFileCsv) + $ShareableExtras + $JsonFiles
        CompressionLevel = 'Fastest'
        DestinationPath  = [WildcardPattern]::Escape($Global:ZipOutputFile)
    }
    Write-Log -Message ('Transcript log excluded from zip (kept locally for debug)') -Severity 'Info'
}

# Packaging is the LAST place a subscription's whole report can be lost unnoticed, so it fails loudly and is verified on disk before claiming success. The run-wide SilentlyContinue discarded Compress-Archive's non-terminating error and the old Write-Error handler printed nothing / set no exit code, so the wrapper consolidated a bundle one report short.
# -ErrorAction Stop forces the compress terminating so the catch always fires, then the archive is confirmed present + non-empty; exit 1 (not throw) is the hard-fail signal since a script-scope throw is swallowed.
$ZipWriteError = $null
try
{
    Compress-Archive @CompressionOutput -ErrorAction Stop
}
catch
{
    $ZipWriteError = $_.Exception.Message
}

# Test-ReportArchiveUsable (Common.Functions.ps1) is the SINGLE definition of 'the archive is really there' (present, a file, non-empty); the wrapper's per-subscription output verification calls the same predicate, so the two sides of this seam cannot drift. The absent-vs-empty distinction below is only for the operator message.
$ZipVerified = $false
if ($null -eq $ZipWriteError)
{
    $ZipVerified = Test-ReportArchiveUsable -Path $Global:ZipOutputFile
    if (-not $ZipVerified)
    {
        $ZipWriteError = if (Test-Path -LiteralPath $Global:ZipOutputFile -PathType Leaf)
        {
            'the archive was created but is 0 bytes'
        }
        else
        {
            'the archive is absent from disk even though Compress-Archive reported no error'
        }
    }
}

Write-Log -Message ("Execution Time: {0}" -f $Runtime) -Severity 'Success'
Write-Log -Message ("Reporting Time: {0}" -f $ReportingRunTime) -Severity 'Success'

if (-not $ZipVerified)
{
    Write-Log -Message ("FAILED to write the report archive: {0}" -f $Global:ZipOutputFile) -Severity 'Error'
    Write-Log -Message ("  Reason: {0}" -f $ZipWriteError) -Severity 'Error'
    Write-Log -Message ("  The uncompressed report files are still in {0} - check free disk space first, then an antivirus/DLP quarantine, then write permissions on that folder." -f $DefaultPath) -Severity 'Error'
    Write-Log -Message ('  Reporting this subscription as FAILED so the wrapper does not consolidate a bundle that is missing it. Re-run with -Resume to retry.') -Severity 'Error'

    # Delete whatever IS at the archive path before leaving: the wrapper consolidates by globbing *.zip under the inventory root by write time (it does not consult this script's verdict), so a truncated/half-written archive left here would be swept in as a corrupt member and inflate the wrapper's archive count, hiding the very gap this exit reports. Best-effort, and must not mask the original failure.
    if (Test-Path -LiteralPath $Global:ZipOutputFile -PathType Leaf)
    {
        try
        {
            Remove-Item -LiteralPath $Global:ZipOutputFile -Force -ErrorAction Stop
            Write-Log -Message ('  Removed the unusable archive so it cannot be folded into the consolidated bundle.') -Severity 'Error'
        }
        catch
        {
            Write-Log -Message ('  WARNING: could not remove the unusable archive at {0} ({1}). Delete it by hand before consolidating, or it will ship as a corrupt member.' -f $Global:ZipOutputFile, $_.Exception.Message) -Severity 'Error'
        }
    }

    # Exit code 2 specifically means 'the report archive is missing', distinct from the generic hard-fail (exit 1) used by the pre-flight gates: Run-AllSubscriptions.ps1 treats any non-zero as 'this subscription failed' but reads the 2 to also set its OWN exit code 2 ('per-subscription output gap'), so a lost report is visible to automation, not just the console summary.
    exit 2
}

Write-Log -Message ("Reporting Data File: {0}" -f $Global:ZipOutputFile) -Severity 'Success'
