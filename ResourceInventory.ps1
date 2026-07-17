param ($TenantID,
    $Appid,
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$', ErrorMessage = 'Invalid SubscriptionID; must be a GUID')]
    [string]$SubscriptionID,
    [securestring]$Secret,
    [ValidatePattern('^[A-Za-z0-9._()-]{1,90}$', ErrorMessage = 'Invalid resource group name; must match ^[A-Za-z0-9._()-]{1,90}$')]
    [string]$ResourceGroup,
    [string[]]$Service,
    [string]$ObfuscationDictionary,
    [switch]$Debug,
    [switch]$SkipMetrics,
    [switch]$SkipConsumption,
    [switch]$DeviceLogin,
    [switch]$Obfuscate,
    [switch]$RunAllSubs,
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
if (-not (Test-Path -Path $FunctionsFile -PathType Leaf))
{
    Write-Host "ERROR: Required functions file not found: $FunctionsFile" -ForegroundColor Red
    Write-Host "Ensure the 'Functions' folder ships alongside this script." -ForegroundColor Yellow
    exit 1
}
. $FunctionsFile

# Shared cross-cutting helpers (Write-RdaProgress). Same dot-source pattern.
$CommonFunctionsFile = Join-Path $PSScriptRoot 'Functions/Common.Functions.ps1'
if (-not (Test-Path -Path $CommonFunctionsFile -PathType Leaf))
{
    Write-Host "ERROR: Required functions file not found: $CommonFunctionsFile" -ForegroundColor Red
    Write-Host "Ensure the 'Functions' folder ships alongside this script." -ForegroundColor Yellow
    exit 1
}
. $CommonFunctionsFile


if ($Debug.IsPresent) { $DebugPreference = 'Continue' }

if ($Debug.IsPresent) { $ErrorActionPreference = "Continue" }Else { $ErrorActionPreference = "silentlycontinue" }

Write-Debug ('Debugging Mode: On. ErrorActionPreference was set to "Continue", every error will be presented.')



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
    # Maps a REAL free-text / identity value (resource Description, FriendlyName,
    # CreatedBy, RoleName, container image, etc.) to its deterministic obfuscated
    # token. These fields are free-form text - previously they were dropped (nulled
    # or stamped with the literal 'obfuscated') and so were unrecoverable. Tokenizing
    # them (same real value -> same token within a run) keeps them out of the shared
    # report while letting Reveal-Obfuscation.ps1 restore them locally via FreeTextMap.
    $Global:FreeTextDictionary = $null

    if ($Obfuscate.IsPresent)
    {
        $Global:ResourceIdDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:ResourceNameDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:ResourceSubscriptionDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:ResourceResourceGroupDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:TagValueDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:FreeTextDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    }

    $Global:RawRepo = 'https://raw.githubusercontent.com/awslabs/resource-discovery-for-azure/main'
    $Global:TableStyle = "Medium15"
}



Function RunInventorySetup()
{
    function CheckVersion()
    {
        # Idempotent per PowerShell session. Under -RunAllSubs this script is
        # invoked via & once per subscription in the SAME process; the version
        # banner and the GitHub update check (a network round-trip to
        # RawRepo/Version.json) do not vary by subscription, so run them only once.
        # Skipping on later subs also removes one WebClient call per subscription
        # on large tenants. $Global:RdaSessionInitialized is set once at the end of
        # the first subscription's setup (GetSubscriptionsData). Parallel streams
        # are separate processes and each performs the check once.
        if ($Global:RdaSessionInitialized)
        {
            return
        }

        Write-Log -Message ('Checking Version') -Severity 'Info'
        Write-Log -Message ('Version: {0}' -f $Global:Version) -Severity 'Info'

        # The version check is best-effort. On corporate networks that block
        # raw.githubusercontent.com (DNS failure, firewall, or air-gap), this
        # WebClient call would otherwise raise SocketException and abort the
        # entire subscription before any inventory work began. A failed update
        # check is not a reason to skip a subscription's inventory - log a
        # clear note and continue with the local version. See #18.
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
            # A version difference is informational, not fatal. Aborting the whole
            # run on any mismatch (the previous behaviour: Write-Log Error + Exit)
            # blocked users who were only slightly behind or on a managed clone,
            # and mis-fired for local/dev builds whose version is AHEAD of
            # upstream. This mirrors the network-failure branch above, which
            # already chooses "log a clear note and continue" over aborting the
            # inventory. Compare as semver so the note reflects reality (behind vs
            # ahead) rather than a plain string inequality.
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
        # Idempotent per PowerShell session. Under -RunAllSubs the wrapper invokes
        # this script via & once per subscription in the SAME process, so the CLI
        # probe, Resource-Graph extension check, and Az module import only need to
        # run once: the verified CLI and imported modules persist process-wide.
        # $Global:AzPowerShellLoaded is set $true at the end of a successful load
        # (below); when it is already set we skip the whole re-check, which removes
        # the repeated "Verifying Azure CLI... / Loading Az.* ..." output on every
        # subscription. Parallel streams run in separate processes, so each stream
        # still loads once. On a failed load the flag stays $false, so the next
        # subscription retries the full check.
        if ($Global:AzPowerShellLoaded)
        {
            return
        }

        Write-Log -Message ('Verifying Azure CLI is installed...') -Severity 'Info'

        $AzCliVersion = az --version

        if ($null -eq $AzCliVersion)
        {
            Write-Log -Message ("Azure CLI Not Found. Please install and run the script again.") -Severity 'Error'
            Read-Host "Press <Enter> to exit"
            Exit
        }

        Write-Log -Message ('CLI Version: {0}' -f $AzCliVersion[0]) -Severity 'Success'

        Write-Log -Message ('Verifying Azure CLI Extension...') -Severity 'Info'

        $AzCliExtension = az extension list --output json | ConvertFrom-Json
        $AzCliExtension = $AzCliExtension | Where-Object { $_.name -eq 'resource-graph' }

        Write-Log -Message ('Current Resource-Graph Extension Version: {0}' -f $AzCliExtension.Version) -Severity 'Success'

        $AzCliExtensionVersion = $AzCliExtension | Where-Object { $_.name -eq 'resource-graph' }

        if (!$AzCliExtensionVersion)
        {
            Write-Log -Message ('Azure CLI Extension not found') -Severity 'Warning'
            Write-Log -Message ('Installing Azure CLI Extension...') -Severity 'Info'
            az extension add --name resource-graph
        }

        Write-Log -Message ('Checking Azure PowerShell Module...') -Severity 'Info'

        # This tool only calls cmdlets from four Az submodules (see the import
        # loop below), so it validates and loads exactly those - it does NOT
        # require the full ~80-submodule `Az` rollup to be installed. A slim
        # install is sufficient:
        #   Install-Module Az.Accounts, Az.Compute, Az.Monitor, Az.Billing
        # The full `Az` rollup also satisfies this check because installing `Az`
        # lays down each Az.* submodule as its own discoverable module on disk,
        # so Get-Module -Name Az.Accounts (etc.) finds them either way. Checking
        # the submodules (not the `Az` umbrella) is what lets the slim install
        # pass - a slim install has no `Az` meta-module, so the old
        # Get-Module -Name Az check would have thrown a false "not found".
        $RequiredAzSubModules = @('Az.Accounts', 'Az.Compute', 'Az.Monitor', 'Az.Billing')

        $MissingAzSubModules = @($RequiredAzSubModules | Where-Object { $null -eq (Get-Module -Name $_ -ListAvailable -ErrorAction SilentlyContinue | Select-Object -First 1) })

        if ($MissingAzSubModules.Count -eq 0)
        {
            $VarAzPs = Get-Module -Name Az.Accounts -ListAvailable -ErrorAction SilentlyContinue | Select-Object -First 1
            Write-Log -Message ('Azure PowerShell modules present (Az.Accounts {0}); required: {1}' -f $VarAzPs.Version, ($RequiredAzSubModules -join ', ')) -Severity 'Success'
        }
        else
        {
            # Behaviour change (deliberate): do not Install-Module from inside
            # this script. A real field run produced a half-installed Az module
            # - .psd1 manifests present so Get-Module -ListAvailable was happy,
            # but the bundled MSAL/Azure.Core assemblies were missing on disk -
            # and the script then ran for nearly an hour producing zero
            # consumption data because every Get-AzUsageAggregate call failed
            # with "Azure PowerShell context has not been properly initialized".
            # In-process module installs into a script that's already importing
            # the same module are fragile (concurrent install, AppDomain
            # caching, partial download) and the failure mode is a silent broken
            # install rather than a clean error. Failing loudly here is safer.
            Write-Log -Message ('Required Azure PowerShell module(s) not found: {0}' -f ($MissingAzSubModules -join ', ')) -Severity 'Error'
            Write-Log -Message ('This tool needs only these Az submodules. Install them manually before re-running. From an elevated PowerShell 7 prompt:') -Severity 'Error'
            Write-Log -Message ('  Install-Module -Name {0} -Repository PSGallery -Force -AllowClobber -SkipPublisherCheck' -f ($RequiredAzSubModules -join ',')) -Severity 'Error'
            Write-Log -Message ('Or install the full rollup (larger, slower first import): Install-Module -Name Az -Repository PSGallery -Force -AllowClobber -SkipPublisherCheck') -Severity 'Error'
            Write-Log -Message ('Or in Cloud Shell, the Az module is already preinstalled - if it is missing your shell environment is broken.') -Severity 'Error'
            throw ('Required Azure PowerShell submodule(s) not found: {0}. See log above for installation instructions.' -f ($MissingAzSubModules -join ', '))
        }

        # Load ONLY the Az submodules this tool actually uses ($RequiredAzSubModules,
        # validated above), not the full `Az` rollup. Importing `Az` pulls in ~80
        # submodules (hundreds of DLLs plus their format/type data) and stalls for
        # 20-40s on a fresh box with no output - which looks like a hang right
        # after "Checking Azure PowerShell Module...". The tool only calls cmdlets
        # from these four:
        #   Az.Accounts - Connect/Get/Set-AzContext, Get-AzSubscription,
        #                 Get-AzAccessToken, Save-/Import-AzContext
        #   Az.Compute  - Get-AzComputeResourceSku
        #   Az.Monitor  - Get-AzMetric
        #   Az.Billing  - Get-UsageAggregates
        # Because these four are the entire Az cmdlet surface, a slim install of
        # just them is enough and cannot cause "command not found". If the full
        # `Az` rollup happens to be installed instead, any other submodule still
        # auto-loads on first use - but nothing outside these four is ever called.
        #
        # This import doubles as the broken-install probe. Get-Module
        # -ListAvailable above only checks the manifest on disk; importing
        # Az.Accounts actually loads the bundled assemblies (MSAL, Azure.Core),
        # so a half-installed module (manifest present, assemblies missing - a
        # real field-observed scenario) fails loudly HERE instead of silently
        # producing zero data at the consumption phase.
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


        # NOTE: The ImportExcel / EPPlus preflight that used to live here was
        # removed when the report format changed from Excel (.xlsx) to a
        # self-contained HTML report (Extension/Summary.ps1). The HTML report
        # has no external module dependency, so there is nothing to preflight.
        # This is the dependency that previously failed in Cloud Shell when the
        # module was partially installed.
    }

    function CheckPowerShell()
    {
        # Session-scoped detection (once per PowerShell session). Under -RunAllSubs
        # this script runs via & once per subscription in the SAME process, and
        # Variables() does not reset $Global:PlatformOS, so platform / PS-version
        # detection and its console output only need to run for the first sub. The
        # per-subscription timestamp + report-folder computation below still runs
        # every invocation so each subscription gets its own output folder.
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
                    Exit
                }
            }
        }

        # Per-subscription: a fresh report folder every invocation so each sub
        # writes to its own output folder.
        #
        # Millisecond precision is required when multiple inner-script invocations
        # can start in the same second (the parallel-streams orchestration in
        # Run-AllSubscriptions.ps1 fans out N child processes that all run this
        # init block concurrently). Without it, two workers compute the same
        # $Global:CurrentDateTime, point at the same per-sub folder, and the
        # second worker's Compress-Archive fails with "archive file already
        # exists". The format change is invisible to every downstream consumer:
        # all glob filters use `*` wildcards over the timestamp segment.
        # Append a 4-char per-process discriminator to the timestamp. Two
        # worker processes that hit the same millisecond still produce
        # different folder names. Discriminator is hex-only and length-stable
        # so the existing `*<timestamp>*` glob filters keep matching.
        $ProcDiscriminator = ('{0:x4}' -f ($PID -band 0xffff))
        $Global:CurrentDateTime = ((get-date -Format "yyyyMMddHHmmssfff") + $ProcDiscriminator)
        $Global:FolderName = $Global:ReportName + $CurrentDateTime

        # Base output root depends only on the (already cached) platform, so
        # recompute the per-sub default path from $Global:PlatformOS without
        # re-detecting. These strings are byte-for-byte identical to the previous
        # per-branch assignments so downstream glob/zip path handling is unchanged.
        if ($Global:PlatformOS -eq 'Azure CloudShell' -or $Global:PlatformOS -eq 'PowerShell Unix')
        {
            $DefaultOutputDir = "$HOME/InventoryReports/" + $Global:FolderName + "/"
        }
        else
        {
            $DefaultOutputDir = "C:\InventoryReports\" + $Global:FolderName + "\"
        }

        if ($OutputDirectory)
        {
            try
            {
                $OutputDirectory = (Resolve-Path $OutputDirectory -ErrorAction Stop).Path + [IO.Path]::DirectorySeparatorChar
            }
            catch
            {
                Write-Log -Message ("Wrong OutputDirectory Path! OutputDirectory Parameter must contain the full path.") -Severity 'Error'
                Exit
            }
        }

        $Global:DefaultPath = if ($OutputDirectory) { $OutputDirectory } else { $DefaultOutputDir }

        if ($platformOS -eq 'Azure CloudShell')
        {
            $Global:Subscriptions = @(az account list --output json --only-show-errors | ConvertFrom-Json)
        }
        elseif ($platformOS -eq 'PowerShell Unix' -or $platformOS -eq 'PowerShell Desktop')
        {
            LoginSession
        }
    }

    function LoginSession()
    {
        # Display-only banner: the active Azure cloud environment does not change
        # between subscriptions in a session, so print it once. This also skips a
        # redundant `az cloud list` per subscription under -RunAllSubs. The auth
        # logic below (az account show, the Az context check, Connect-AzAccount)
        # is OUTSIDE this guard and still runs on every invocation, unchanged.
        if (-not $Global:RdaSessionInitialized)
        {
            $CloudEnv = az cloud list | ConvertFrom-Json
            Write-Host "Azure Cloud Environment: " -NoNewline

            $CurrentCloudEnvName = $CloudEnv | Where-Object { $_.isActive -eq 'True' }
            Write-Host $CurrentCloudEnvName.name -ForegroundColor Green
        }

        # Check if already authenticated
        $ExistingAccount = az account show --output json --only-show-errors 2>$null | ConvertFrom-Json
        if ($null -ne $ExistingAccount)
        {
            # Display-only: report the authenticated identity once per session. The
            # tenant-context comparison and any reconnect below still run every sub.
            if (-not $Global:RdaSessionInitialized)
            {
                Write-Log -Message ("Already authenticated as: {0}" -f $ExistingAccount.user.name) -Severity 'Success'
            }

            if (!$TenantID -or $ExistingAccount.tenantId -eq $TenantID)
            {
                # Ensure PowerShell Az context is set for the requested tenant.
                # We compare the Az PS context's tenant — not its current subscription
                # — against $existingAccount because the Az PS and az CLI contexts can
                # have different default subscriptions even when authenticated against
                # the same tenant. Comparing subscriptions caused a re-Connect-AzAccount
                # on every iteration of Run-AllSubscriptions.ps1 on PowerShell Desktop,
                # which prompted the user to log in again for each subscription. Per-
                # subscription scoping happens later via Set-AzContext / --subscriptions /
                # resource-id parameters on Get-AzMetric, so the context only needs to
                # match the tenant.
                $AzContext = Get-AzContext -ErrorAction SilentlyContinue
                $NeedsConnect = $null -eq $AzContext -or
                [string]::IsNullOrEmpty($AzContext.Tenant.Id) -or
                $AzContext.Tenant.Id -ne $ExistingAccount.tenantId
                if ($NeedsConnect)
                {
                    Write-Log -Message ('Setting PowerShell Az context...') -Severity 'Info'
                    if ($DeviceLogin.IsPresent)
                    {
                        Connect-AzAccount -UseDeviceAuthentication -Tenant $ExistingAccount.tenantId | Out-Null
                    }
                    else
                    {
                        Connect-AzAccount -Tenant $ExistingAccount.tenantId | Out-Null
                    }
                }

                $Global:Subscriptions = @(az account list --output json --only-show-errors | ConvertFrom-Json)
                if ($TenantID) { $Global:Subscriptions = @($Subscriptions | Where-Object { $_.tenantID -eq $TenantID }) }
                return
            }
            else
            {
                Write-Log -Message ("Current session is for tenant {0}, but requested tenant is {1}. Re-authenticating." -f $ExistingAccount.tenantId, $TenantID) -Severity 'Warning'
            }
        }

        if (!$TenantID)
        {
            Write-Log -Message ('Tenant ID not specified. Use -TenantID parameter if you want to specify directly.') -Severity 'Warning'
            Write-Log -Message ('Authenticating Azure') -Severity 'Info'

            Write-Log -Message ('Clearing account cache') -Severity 'Info'

            if (!$RunAllSubs.IsPresent)
            {
                az account clear | Out-Null
            }

            $DebugPreference = "SilentlyContinue"

            if (!$RunAllSubs.IsPresent)
            {
                Write-Log -Message ('Calling Login, the browser will open and prompt you to login.') -Severity 'Info'
                if ($DeviceLogin.IsPresent)
                {
                    Write-Log -Message ('Using device login') -Severity 'Info'
                    az login --use-device-code
                    Connect-AzAccount -UseDeviceAuthentication | Out-Null
                }
                else
                {
                    Write-Log -Message ('Using browser login') -Severity 'Info'
                    az login --only-show-errors | Out-Null
                    Connect-AzAccount | Out-Null
                }
            }

            $DebugPreference = "Continue"

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
                    write-host "$SequenceID)  $TenantID"
                    $SequenceID ++
                }

                # A read-host here blocks until someone types at a console. Under
                # the wrapper (-RunAllSubs), a parallel worker, an SSM run-command,
                # or any redirected/CI session there IS no console, so the prompt
                # would hang the entire run forever with no way to answer it.
                # Detect a non-interactive session and default to the first tenant
                # instead (the "Default 1" the prompt always intended); a real
                # interactive session still gets the picker. Pass -TenantID to
                # choose a specific tenant and skip this path entirely.
                $IsInteractiveSession = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
                if ($RunAllSubs.IsPresent -or -not $IsInteractiveSession)
                {
                    $TenantID = $Tenants[0]
                    Write-Log -Message ("Non-interactive session with multiple tenants and no -TenantID: defaulting to the first tenant ({0}). Pass -TenantID to choose explicitly." -f $TenantID) -Severity 'Warning'
                }
                else
                {
                    [int]$SelectTenant = read-host "Select Tenant (Default 1)"
                    if ($SelectTenant -lt 1) { $SelectTenant = 1 }
                    $TenantID = $Tenants[$SelectTenant - 1]
                }

                if (!$RunAllSubs.IsPresent)
                {
                    if ($DeviceLogin.IsPresent)
                    {
                        az login --use-device-code -t $TenantID
                        Connect-AzAccount -UseDeviceAuthentication -Tenant $TenantID | Out-Null
                    }
                    else
                    {
                        az login -t $TenantID --only-show-errors | Out-Null
                        Connect-AzAccount -Tenant $TenantID | Out-Null
                    }
                }
            }

            Write-Log -Message ("Extracting from Tenant $TenantID") -Severity 'Info'
            Write-Log -Message ("Extracting Subscriptions") -Severity 'Info'

            $Global:Subscriptions = @(az account list --output json --only-show-errors | ConvertFrom-Json)
            $Global:Subscriptions = @($Subscriptions | Where-Object { $_.tenantID -eq $TenantID })
        }
        else
        {

            if (!$RunAllSubs.IsPresent)
            {
                az account clear | Out-Null

                if (!$Appid)
                {
                    if ($DeviceLogin.IsPresent)
                    {
                        az login --use-device-code -t $TenantID
                        Connect-AzAccount -UseDeviceAuthentication -Tenant $TenantID | Out-Null
                    }
                    else
                    {
                        az login -t $TenantID --only-show-errors | Out-Null
                        Connect-AzAccount -Tenant $TenantID | Out-Null
                    }
                }
                elseif ($Appid -and $Secret -and $tenantid)
                {
                    Write-Log -Message ("Using Service Principal Authentication Method") -Severity 'Success'
                    # Authenticate the az CLI without putting the secret on the command
                    # line (it would otherwise appear in the process list and transcript).
                    # Pipe the plaintext to --password-stdin; the plaintext lives only in
                    # this local variable for the duration of the call.
                    $UnsecuredSecret = [System.Net.NetworkCredential]::new('', $Secret).Password
                    $UnsecuredSecret | az login --service-principal -u $appid --tenant $TenantID --password-stdin --only-show-errors | Out-Null
                    Remove-Variable -Name unsecuredSecret -ErrorAction SilentlyContinue
                    $Credential = New-Object System.Management.Automation.PSCredential($Appid, $Secret)
                    Connect-AzAccount -ServicePrincipal -Credential $Credential -Tenant $TenantID | Out-Null
                }
                else
                {
                    Write-Log -Message ("You are trying to use Service Principal Authentication Method in a wrong way.") -Severity 'Error'
                    Write-Log -Message ("It's Mandatory to specify Application ID, Secret and Tenant ID in Azure Resource Inventory") -Severity 'Error'
                    Write-Log -Message (".\ResourceInventory.ps1 -appid <SP AppID> -secret <SP Secret> -tenant <TenantID>") -Severity 'Error'
                    Exit
                }
            }

            $Global:Subscriptions = @(az account list --output json --only-show-errors | ConvertFrom-Json)
            $Global:Subscriptions = @($Subscriptions | Where-Object { $_.tenantID -eq $TenantID })
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

        if ((Test-Path -Path $DefaultPath -PathType Container) -eq $false)
        {
            New-Item -Type Directory -Force -Path $DefaultPath | Out-Null
        }

        # Session init is complete once the first subscription's setup has run.
        # Subsequent subscriptions in the same PowerShell process now skip the
        # version check, platform/PS detection, and the subscription-count line
        # above (see CheckVersion / CheckPowerShell / the guard just above). This
        # is the single place the flag is set; nothing resets it mid-session
        # (Variables() does not touch it), and parallel streams are separate
        # processes that each set it once.
        $Global:RdaSessionInitialized = $true
    }

    function ResourceInventoryLoop()
    {
        if (![string]::IsNullOrEmpty($ResourceGroup) -and [string]::IsNullOrEmpty($SubscriptionID))
        {
            Write-Log -Message ("Resource Group Name present, but missing Subscription ID.") -Severity 'Error'
            Write-Log -Message ("If using ResourceGroup parameter you must also put SubscriptionId") -Severity 'Error'
            Exit
        }

        if (![string]::IsNullOrEmpty($ResourceGroup))
        {
            $ResourceGroup = $ResourceGroup.ToLower()
        }

        if (![string]::IsNullOrEmpty($ResourceGroup) -and ![string]::IsNullOrEmpty($SubscriptionID))
        {
            Write-Log -Message ('Extracting Resources from Subscription: ' + $SubscriptionID + '. And from Resource Group: ' + $ResourceGroup) -Severity 'Success'

            $Subscri = $SubscriptionID

            $GraphQuery = "resources | where resourceGroup == '$ResourceGroup' and (isnull(properties.definition.actions) or strlen(properties.definition.actions) < 123000) | summarize count()"
            $EnvSize = Invoke-AzGraphQuerySafe -Query $GraphQuery -ExtraArgs @('--subscriptions', $Subscri)
            $EnvSizeNum = $EnvSize.data.'count_'

            if ($EnvSizeNum -ge 1)
            {
                $Loop = $EnvSizeNum / 1000
                $Loop = [math]::ceiling($Loop)
                $Looper = 0
                $Limit = 0

                while ($Looper -lt $Loop)
                {
                    $GraphQuery = "resources | where resourceGroup == '$ResourceGroup' and (isnull(properties.definition.actions) or strlen(properties.definition.actions) < 123000) | project id,name,type,tenantId,kind,location,resourceGroup,subscriptionId,managedBy,sku,plan,properties,identity,zones,extendedLocation,tags | order by id asc"
                    $Resource = Invoke-AzGraphQuerySafe -Query $GraphQuery -ExtraArgs @('--subscriptions', $Subscri, '--skip', $Limit, '--first', 1000) -Lowercase

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
            $EnvSize = Invoke-AzGraphQuerySafe -Query $GraphQuery -ExtraArgs @('--subscriptions', $SubscriptionID)
            $EnvSizeNum = $EnvSize.data.'count_'

            if ($EnvSizeNum -ge 1)
            {
                $Loop = $EnvSizeNum / 1000
                $Loop = [math]::ceiling($Loop)
                $Looper = 0
                $Limit = 0

                while ($Looper -lt $Loop)
                {
                    $GraphQuery = "resources | where (isnull(properties.definition.actions) or strlen(properties.definition.actions) < 123000) | project id,name,type,tenantId,kind,location,resourceGroup,subscriptionId,managedBy,sku,plan,properties,identity,zones,extendedLocation,tags | order by id asc"
                    $Resource = Invoke-AzGraphQuerySafe -Query $GraphQuery -ExtraArgs @('--subscriptions', $SubscriptionID, '--skip', $Limit, '--first', 1000) -Lowercase

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
            $EnvSizeCount = $EnvSize.Data.'count_'

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
                    $Resource = Invoke-AzGraphQuerySafe -Query $GraphQuery -ExtraArgs @('--skip', $Limit, '--first', 1000) -Lowercase

                    $Global:Resources += $Resource.Data
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
        $AVDSizeCount = $AVDSize.data.'count_'

        Write-Host ("AVD Resources Output: {0} AVD Resources Identified" -f $AVDSizeCount) -BackgroundColor Black -ForegroundColor Green

        if ($AVDSizeCount -ge 1)
        {
            $Loop = $AVDSizeCount / 1000
            $Loop = [math]::ceiling($Loop)
            $Looper = 0
            $Limit = 0

            while ($Looper -lt $Loop)
            {
                $GraphQuery = "desktopvirtualizationresources | project id,name,type,tenantId,kind,location,resourceGroup,subscriptionId,managedBy,sku,plan,properties,identity,zones,extendedLocation,tags | order by id asc"
                $AVD = Invoke-AzGraphQuerySafe -Query $GraphQuery -ExtraArgs @('--skip', $Limit, '--first', 1000) -Lowercase

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
    ResourceInventoryLoop
    ResourceInventoryAvd

    if ($Obfuscate.IsPresent)
    {
        # Lookup tables keyed by real subscription name / real RG name so the same
        # real value always maps to the same obfuscated value across resources.
        $SubLookup = @{}
        $RgLookup = @{}

        # -ObfuscationDictionary seeding. When a prior run's saved dictionary file
        # is supplied, preload the obfuscation maps from it so identical real values
        # yield the SAME prod_/nonprod_ tokens as that earlier run. This is what lets
        # a scoped recovery run (e.g. -Service <one collector>) be merged back into
        # the earlier bundle - without it, each run mints fresh random GUID tokens
        # and the recovered rows would not join. New real values not in the seed
        # still get fresh tokens below, so determinism is EXTENDED, never broken.
        # (Pre-flight has already validated the file exists, parses, and -Obfuscate.)
        #
        # The saved file stores each map inverted (token -> real):
        #   - ResourceIdMap / ResourceNameMap: token -> real resource ID. These
        #     tokens are UNIQUE per resource so the maps are complete; invert them
        #     back to the in-memory (real ID -> token) form.
        #   - TagMap / FreeTextMap: token -> real value; the collector loop reuses
        #     these via ContainsKey, so seeding the real-value-keyed dicts suffices.
        #   - Subscription / ResourceGroup tokens are SHARED by every resource in a
        #     sub/RG, so SubscriptionMap/ResourceGroupMap collapse to one
        #     representative real ID per token and CANNOT be reused ID-keyed. Rebuild
        #     the real-value-keyed $subLookup/$rgLookup the mint logic consults:
        #       sub -> SubscriptionNameMap gives token -> real subscription NAME,
        #              which is exactly the key the mint logic uses.
        #       rg  -> extract the RG name from each ResourceGroupMap representative
        #              real ID (/resourcegroups/<name>/); $rgLookup is a
        #              case-insensitive hashtable so ID-vs-property casing is moot.
        if (-not [string]::IsNullOrEmpty($ObfuscationDictionary))
        {
            $SeedDictionary = Get-Content -Path $ObfuscationDictionary -Raw | ConvertFrom-Json

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

            # Seeded reuse (-ObfuscationDictionary): if this real resource ID was
            # preloaded from a prior run's dictionary, reuse its per-resource ID and
            # Name tokens so a scoped recovery run's output lands in the SAME token
            # space as the bundle it will be merged into. Gated purely on
            # ContainsKey: on a normal (non-seeded) run the dictionary starts empty
            # and this loop is what first populates it, so ContainsKey is always
            # false here and behavior is byte-for-byte unchanged. The ID/Name GUIDs
            # minted just above are harmless throwaway on a seed hit.
            #
            # Subscription and ResourceGroup tokens are deliberately NOT reused from
            # the ID-keyed dictionaries here: those tokens are SHARED by every
            # resource in a sub/RG, so the saved SubscriptionMap/ResourceGroupMap
            # collapse to one representative ID per token and the reseeded ID-keyed
            # dicts are sparse. Instead they are reused via the real-value-keyed
            # $subLookup/$rgLookup, which the mint logic above already consulted and
            # which the seed block populated - so $obfuscatedSubscription /
            # $obfuscatedResourceGroup are already the seeded tokens at this point.
            if ($ResourceIdDictionary.ContainsKey($resourceItem.ID))
            {
                $ObfuscatedID = $ResourceIdDictionary[$resourceItem.ID]
                $ObfuscatedName = $ResourceNameDictionary[$resourceItem.ID]
            }

            $ResourceIdDictionary[$resourceItem.ID] = $ObfuscatedID
            $ResourceNameDictionary[$resourceItem.ID] = $ObfuscatedName
            $ResourceSubscriptionDictionary[$resourceItem.ID] = $ObfuscatedSubscription
            $ResourceResourceGroupDictionary[$resourceItem.ID] = $ObfuscatedResourceGroup

            # Raw tags are intentionally NOT scrubbed here any more. They must
            # survive on the in-memory $Global:Resources objects so collectors can
            # surface them; tag VALUES are then obfuscated deterministically (and
            # tag KEYS kept) in the per-collector obfuscation loop further below.
            # $Global:Resources itself is never serialized into the report, so
            # leaving raw tags on it in memory does not leak.
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

        # Local errors-only log (see Write-Log's error sink). Like the transcript
        # and heartbeat it is a LOCAL debug artifact, NEVER added to the shared
        # zip. Under the wrapper (-RunAllSubs) $DefaultPath is a per-subscription
        # subfolder, so writing the error log there buries one per sub. Put it in
        # the PARENT InventoryRoot (next to the transcript / heartbeat / wrapper
        # failures log), tagged with the SubscriptionID, so per-sub error logs are
        # findable at a glance (only subs that actually errored produce one) and
        # never collide. Standalone runs keep it in the report folder.
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

        # Consolidated LOCAL debug log. One file per run (per-sub under the
        # wrapper) that collects the per-collector heartbeat trace AND the
        # metrics-phase diagnostics (previously two separate Heartbeat_* files
        # plus a flood of [Metrics] Write-Host lines on the terminal). Placed
        # with the SAME parent-vs-report-folder + SubscriptionID-tag logic as
        # the error log so it is findable and never collides across a parallel
        # multi-sub run.
        #
        # IMPORTANT: like the transcript and error log this is a LOCAL debug
        # artifact and is NEVER added to the shared zip - the metrics
        # diagnostics interpolate REAL service/resource names (the obfuscation
        # layer does not touch them) and heartbeat FAIL lines can carry raw
        # $_.Exception.Message text. The DebugLog_* name is excluded by the
        # Compress-Archive filter's -notlike guard. Do NOT add it to the zip
        # Path array without scrubbing its contents first.
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
        # Verify a live Azure context + token are available before a data-plane
        # phase (Metrics via Get-AzMetric in parallel runspaces; Consumption via
        # Get-UsageAggregates). Both silently produce ZERO records when the
        # context/token is missing. Because the caller did NOT pass the matching
        # -Skip* switch, the user wants this data - so we detect the gap, attempt
        # ONE reconnect using the same auth method the script was invoked with,
        # then re-check. Returns $true only when a usable token is confirmed.
        #
        # Reuses the script's existing auth approach (Service Principal /
        # device / browser); it does not introduce a new auth path. Under
        # -RunAllSubs the phase may run in a background job where an interactive
        # prompt cannot reach the user, so interactive reconnect is skipped there
        # in favour of a loud failure.
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
            # -SkipMetrics was NOT passed, so the user wants metrics. Get-AzMetric
            # runs in parallel runspaces and returns ZERO data (silently) if the
            # Azure context/token is missing. Detect + attempt recovery first; if
            # it still cannot authenticate, fail loud and skip ONLY this phase so
            # the rest of the inventory still completes (the end-of-script
            # empty-metrics-JSON fallback keeps the output bundle structurally
            # valid). This is intentionally NOT a silent skip.
            if (-not (Test-DataPlaneAuthReady -Phase 'Metrics'))
            {
                Write-Log -Message ('Metrics: SKIPPED - could not establish a usable Azure context/token after one reconnect attempt. Metrics were requested (no -SkipMetrics) but cannot be collected. Re-authenticate (Connect-AzAccount) or pass -appid/-secret/-tenant, then re-run. The rest of the inventory will continue.') -Severity 'Error'

                $Global:AzMetrics = New-Object PSObject
                $Global:AzMetrics | Add-Member -MemberType NoteProperty -Name Metrics -Value NotSet
                $Global:AzMetrics.Metrics = [System.Collections.Concurrent.ConcurrentBag[psobject]]::new()

                # Record per-subscription metrics-phase health so the wrapper's
                # final summary can name exactly which subs are missing metrics
                # (mirrors $Global:ConsumptionFailedSubs). Lives in the wrapper's
                # scope because ResourceInventory.ps1 is invoked via `& <path>`.
                # Resolve which subscription(s) this skip applies to: when invoked
                # per-sub (the wrapper passes -SubscriptionID) it is that one sub;
                # for a standalone all-subs run it is every in-scope subscription.
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
                $MetricPath = Get-ChildItem -Path ($PSScriptRoot + '\Extension\Metrics.ps1') -Recurse
            }
            else
            {
                $MetricPath = Get-ChildItem -Path ($PSScriptRoot + '/Extension/Metrics.ps1') -Recurse
            }

            $MetricsFilePath = ($DefaultPath + "Metrics_" + $Global:ReportName + "_" + $CurrentDateTime + "_")

            $Global:AzMetrics = New-Object PSObject
            $Global:AzMetrics | Add-Member -MemberType NoteProperty -Name Metrics -Value NotSet
            $Global:AzMetrics.Metrics = & $MetricPath -Subscriptions $Subscriptions -Resources $Resources -Task "Processing" -ConcurrencyLimit $ConcurrencyLimit -FilePath $MetricsFilePath -ResourceIdDictionary $(if ($Obfuscate.IsPresent) { $ResourceIdDictionary } else { $null }) -ResourceNameDictionary $(if ($Obfuscate.IsPresent) { $ResourceNameDictionary } else { $null }) -ResourceSubDictionary $(if ($Obfuscate.IsPresent) { $ResourceSubscriptionDictionary } else { $null }) -ResourceGroupDictionary $(if ($Obfuscate.IsPresent) { $ResourceResourceGroupDictionary } else { $null }) -Obfuscate $Obfuscate.IsPresent -MetricsLookbackDays $MetricsLookbackDays
        }
    }

    function ProcessMetricsResult()
    {
        if (!$SkipMetrics.IsPresent)
        {
            $([System.GC]::GetTotalMemory($false))
            $([System.GC]::Collect())
            $([System.GC]::GetTotalMemory($true))
        }
    }

    function GetServiceName($moduleUrl)
    {
        if ($moduleUrl -like '*Services/Analytics*')
        {
            $DirectoryService = 'Analytics'
        }

        if ($moduleUrl -like '*Services/Compute*')
        {
            $DirectoryService = 'Compute'
        }

        if ($moduleUrl -like '*Services/Containers*')
        {
            $DirectoryService = 'Containers'
        }

        if ($moduleUrl -like '*Services/Data*')
        {
            $DirectoryService = 'Data'
        }

        if ($moduleUrl -like '*Services/Infrastructure*')
        {
            $DirectoryService = 'Infrastructure'
        }

        if ($moduleUrl -like '*Services/Integration*')
        {
            $DirectoryService = 'Integration'
        }

        if ($moduleUrl -like '*Services/Networking*')
        {
            $DirectoryService = 'Networking'
        }

        if ($moduleUrl -like '*Services/Storage*')
        {
            $DirectoryService = 'Storage'
        }

        return $DirectoryService
    }

    function CreateResourceJobs()
    {
        $Global:SmaResources = New-Object PSObject

        Write-Log -Message ('Starting Service Processing Jobs.') -Severity 'Info'


        if ($PSScriptRoot -like '*\*')
        {
            $Modules = Get-ChildItem -Path ($PSScriptRoot + '\Services\*.ps1') -Recurse
        }
        else
        {
            $Modules = Get-ChildItem -Path ($PSScriptRoot + '/Services/*.ps1') -Recurse
        }

        # -Service <string[]> targeted collection. When supplied, run ONLY the
        # named collectors (matched on file base name, case-insensitive) instead
        # of every file under Services/. This enables fast re-collection of a
        # single resource type (e.g. recovering one collector that failed for a
        # subscription) WITHOUT re-running the whole tenant, and is what a scoped
        # recovery bundle is built from before it is merged back into a prior run.
        # The metrics/consumption phases are unaffected - they remain governed by
        # their own -SkipMetrics/-SkipConsumption switches. A requested name that
        # matches no collector is almost always a typo; we fail loud (rather than
        # silently producing an empty inventory) so the operator notices before
        # shipping an incomplete report.
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

            $UnmatchedServices = @($Service | Where-Object { $_ -notin $MatchedNames })
            if (@($UnmatchedServices).Count -gt 0)
            {
                Write-Log -Message ("-Service: these requested names matched nothing and were ignored: [{0}]. Available: [{1}]." -f ($UnmatchedServices -join ', '), ($AvailableServices -join ', ')) -Severity 'Warning'
            }
        }

        $Resource = $Resources | Select-Object -First $Resources.count
        #$Resource = ($Resource | ConvertTo-Json -Depth 50)

        # Circuit breaker for collector failures (#22). A single collector
        # throwing (a null property, a malformed API response, a bug in that
        # one file) must not silently drop that resource type NOR abort the
        # whole run - it is recorded loudly and processing continues with the
        # next collector, exactly like the existing Metrics/Consumption
        # fail-loud-and-skip-that-phase pattern. But if MANY collectors fail
        # in a row, the cause is almost never "this one resource type has a
        # bug" - it is systemic (auth dropped mid-run, network gone, Az
        # module broken) and every remaining collector is about to fail for
        # the identical reason. Limping through the rest would just produce
        # ~50 more identical error lines and an empty report that looks like
        # "no resources" instead of "the environment broke partway through".
        # Stop the run once that pattern is detected instead of grinding
        # through it - the operator gets ONE clear diagnosis instead of a
        # wall of repeated errors, and can fix the real problem and re-run.
        $ConsecutiveCollectorFailures = 0
        $CollectorFailureCircuitBreakerThreshold = 5

        # Per-service progress is surfaced two ways, neither of which prints a
        # per-collector line to the shared console (that green Write-Log line
        # per collector - ~40+ lines per subscription - scrolled the real
        # errors/warnings off screen and would repeat once per subscription,
        # e.g. 164x for a 164-subscription run):
        #   1. Write-Progress renders a single updating bar in an interactive
        #      host and is a no-op in non-interactive hosts (parallel runspaces,
        #      transcripts, CI), so it never pollutes the transcript.
        #   2. A per-collector heartbeat is appended to a local .log file.
        #      Because Write-Progress is a no-op in exactly the non-interactive
        #      contexts the wrapper drives collectors in, a transcript otherwise
        #      had NO marker between "Starting Service Processing Jobs" and the
        #      next phase - you could not tell which collector was in flight when
        #      a run hung. This file restores that "how far did it get / where
        #      did it hang" trace without adding any console noise. It is a debug
        #      artifact: named like the transcript (unique per run/process via the
        #      PID-discriminated $CurrentDateTime), it stays local and is never
        #      added to the shared zip (a .log matches no packaging pattern).
        # Collector FAILURES are still logged loudly (Error severity) in the
        # catch below regardless, so nothing diagnostic depends on this file.
        $ModuleTotal = @($Modules).Count
        $ModuleIndex = 0

        $HeartbeatSubLabel = if (![string]::IsNullOrEmpty($SubscriptionID)) { $SubscriptionID } else { '(all in-scope subscriptions)' }
        # The per-collector heartbeat (which collector was in flight when a run
        # hung) is written through the single shared logger: Write-Log with
        # -NoConsole (no per-collector console spam - that green line x40+ per sub
        # scrolled real errors off screen) + -ToDebugLog (append to
        # $Global:DebugLogFile, the consolidated LOCAL debug log the metrics
        # diagnostics also use, established in InitializeInventoryProcessing with
        # the parent-InventoryRoot-vs-report-folder + SubscriptionID-tag placement
        # so per-sub heartbeats are discoverable, never collide, and are never
        # packaged). Write-Log's -ToDebugLog is a silent no-op when no debug-log
        # path exists and never throws, so no separate enable/disable guard is
        # needed here - a write failure can never break collection.
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

                # This collector's resource type is missing from the report,
                # not silently empty-looking-like-none-exist: the Error-severity
                # log line above and the $Global:CollectorFailures entry are
                # the loud signal. $result must still become a defined empty
                # array so $Global:SmaResources.$ModName is a valid (empty)
                # JSON array rather than an absent/undefined member.
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

                    # Collector 'Tags' output is an array of { Name, Value }. Keep the
                    # KEY (Name) verbatim and obfuscate the VALUE deterministically via
                    # $Global:TagValueDictionary: the same real value always maps to the
                    # same prod_/nonprod_ token, so the obfuscated report can still group
                    # and correlate by tag value without exposing it. Prefix is derived
                    # from the value so an environment-type signal survives.
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
            # Wrap with @() so the JSON serializer always emits an array, even
            # when the collector returns exactly one resource. Without this,
            # PowerShell unwraps a single-element pipeline result into a scalar
            # PSCustomObject, ConvertTo-Json emits {...} instead of [{...}],
            # and downstream parsers that iterate the resource type as an
            # array silently see zero rows.
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

        $Global:SmaResources | ConvertTo-Json -depth 100 -compress | Out-File $Global:JsonFile
        #$Global:Resources | ConvertTo-Json -depth 100 -compress | Out-File $Global:AllResourceFile

        Write-Log -Message ('Resource Reporting Phase Done.') -Severity 'Info'
    }

    function GetResorceConsumption()
    {
        $DebugPreference = "SilentlyContinue"

        #Force the culture here...
        [System.Threading.Thread]::CurrentThread.CurrentUICulture = "en-US";
        [System.Threading.Thread]::CurrentThread.CurrentCulture = "en-US";

        $ReportedStartTime = (Get-Date).AddDays(-31).Date.AddHours(0).AddMinutes(0).AddSeconds(0).DateTime
        $ReportedEndTime = (Get-Date).AddDays(-1).Date.AddHours(0).AddMinutes(0).AddSeconds(0).DateTime

        # Consumption was requested (no -SkipConsumption). Get-UsageAggregates
        # silently returns ZERO records when the Azure context/token is missing,
        # which would otherwise leave an empty consumption sheet that looks like
        # "this tenant has no billing data". Detect + attempt one reconnect; if
        # still unauthenticated, record a loud per-run health entry (reusing the
        # existing $Global:ConsumptionFailedSubs surfaced by the wrapper summary)
        # and skip the phase rather than producing silent empty output.
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

            # Switch the Azure context to the TARGET subscription before pulling
            # its billing data. This MUST succeed AND MUST land on $sub.id:
            # Get-UsageAggregates reads whatever subscription the current context
            # points at, so a silently-failed switch (e.g. the identity has no
            # access to this subscription) would leave the context on the PREVIOUS
            # subscription and attribute THAT subscription's consumption to this
            # one - a data-integrity bug and a cross-subscription data leak. The
            # production $ErrorActionPreference = 'SilentlyContinue' would swallow
            # the failure, so force it terminating here and then verify the
            # resulting context actually matches the target. On failure, record
            # per-sub health (mirroring the catch block below) and skip ONLY this
            # subscription's consumption rather than pulling the wrong sub's data.
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

            # Track consumption health per-subscription so the wrapper can report
            # at the end whether consumption data was actually collected. Without
            # this, a broken Az module produces zero consumption records on every
            # subscription and the run still reports as successful - leaving an
            # empty consumption sheet in the output that nobody noticed until the
            # report was reviewed.
            $ConsumptionRecordsThisSub = 0
            $ConsumptionFailedThisSub = $false
            $ConsumptionFailureMessage = $null
            # Page counter so a mid-pull failure can report exactly where it
            # stopped (which paged Get-UsageAggregates call) instead of leaving a
            # silently-truncated CSV that could only be spotted by guessing from
            # the row count. Incremented once per distinct page attempted.
            $ConsumptionPageIndex = 0

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

                    $Params.ContinuationToken = $UsageData.ContinuationToken

                    # Bounded retry with exponential backoff around the billing pull.
                    # On a very large tenant this loop pages through millions of usage
                    # records; a single transient HTTP failure (e.g. "Error while copying
                    # content to a stream", a timeout, or 429/503 throttling) would
                    # otherwise abort the ENTIRE remaining consumption pull for this
                    # subscription via the outer catch. Retrying the SAME page is safe: a
                    # failed assignment leaves $usageData holding the previous page's
                    # ContinuationToken, so the retried call re-requests the same page (no
                    # duplicate rows, no skipped rows). Mirrors the retry the metrics phase
                    # already uses. A permanent error simply exhausts the retries and then
                    # propagates to the outer catch, preserving the existing
                    # warn-and-continue per-subscription health reporting.
                    $ConsumptionMaxRetries = 3
                    $ConsumptionAttempt = 0
                    while ($true)
                    {
                        try
                        {
                            $UsageData = Get-UsageAggregates @Params -ErrorAction Stop
                            break
                        }
                        catch
                        {
                            $ConsumptionAttempt++
                            if ($ConsumptionAttempt -gt $ConsumptionMaxRetries) { throw }
                            $ConsumptionBackoffSeconds = [int][math]::Pow(2, $ConsumptionAttempt)
                            Write-Log -Message ("Consumption page query failed for {0} (attempt {1}/{2}): {3}. Retrying in {4}s..." -f $sub.Name, $ConsumptionAttempt, $ConsumptionMaxRetries, $_.Exception.Message, $ConsumptionBackoffSeconds) -Severity 'Warning'
                            Start-Sleep -Seconds $ConsumptionBackoffSeconds
                        }
                    }
                    $UsageDataExport = $UsageData.UsageAggregations.Properties | Select-Object InstanceData, MeterCategory, MeterId, MeterName, MeterRegion, MeterSubCategory, Quantity, Unit, UsageStartTime, UsageEndTime

                    Write-Log -Message ("Records found: $($UsageDataExport.Count)...") -Severity 'Info'
                    $ConsumptionRecordsThisSub += $UsageDataExport.Count

                    $NewUsageDataExport = [System.Collections.ArrayList]::new()

                    for ($Item = 0; $Item -lt $UsageDataExport.Count; $Item++)
                    {
                        $InstanceInfo = ($UsageDataExport[$Item].InstanceData.tolower() | ConvertFrom-Json)

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
                            ResourceUri = $InstanceInfo.'Microsoft.Resources'.resourceUri
                            Location = $InstanceInfo.'Microsoft.Resources'.location
                            additionalInfo = [PSCustomObject]@{
                                ConsumptionMeter = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.ConsumptionMeter) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.ConsumptionMeter }
                                vCores = 0
                                VCPUs = 0
                                ServiceType = ""
                                ResourceCategory = ""
                            }
                        }

                        $InstanceObject | Add-Member -MemberType NoteProperty -Name "Microsoft.Resources" -Value $AdditionalInfoInstance

                        if ($Obfuscate.IsPresent)
                        {
                            # Pick a prefix (prod_/nonprod_) based on the original
                            # resourceUri before any obfuscation, so we cannot match
                            # against an already-obfuscated value below.
                            $Prefix = if ($UsageDataExport[$Item].ResourceId -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or $UsageDataExport[$Item].ResourceId -match '(^|/|-)([dts])-') { 'nonprod_' } else { 'prod_' }

                            # Obfuscate the consumption ResourceUri while PRESERVING the
                            # ARM path STRUCTURE (resourcegroups/<rg>/providers/<rp>/<type>[/...]/<name>).
                            # The dashboard categorises rows by parsing this path - it
                            # looks at the resource provider + type to detect AKS, VMSS,
                            # Container Instances, Container Registry, Kusto, etc., and
                            # at the `mc_*` resource-group marker to detect AKS-managed
                            # resources specifically. Replacing the whole URI with a flat
                            # opaque token (the previous behaviour) destroyed every one
                            # of those signals and made AKS/VMSS rows invisible on the
                            # dashboard. We now obfuscate ONLY the identifying segments
                            # (subscription id, resource group name, resource name) and
                            # keep the rest of the path intact - including the `mc_`
                            # prefix on AKS-managed RGs - so the server can still
                            # categorise without seeing real customer identifiers.
                            $RawUri = $InstanceObject.'Microsoft.Resources'.resourceUri
                            $ObfuscatedUri = $RawUri

                            # Per-run caches keyed by REAL value, so the same real sub
                            # id / RG / resource name always maps to the same obfuscated
                            # token within a run (deterministic, per the obfuscation
                            # rules in steering). Kept separate from $ResourceIdDictionary
                            # because that dictionary's public contract (the
                            # ObfuscationDictionary file) maps obfuscated full Azure IDs
                            # to their real values - we don't want to pollute it with
                            # per-name-segment entries from consumption ARM-path rebuilds.
                            if (-not $script:ConsumptionSubCache) { $script:ConsumptionSubCache = @{} }
                            if (-not $script:ConsumptionRgCache) { $script:ConsumptionRgCache = @{} }
                            if (-not $script:ConsumptionNameCache) { $script:ConsumptionNameCache = @{} }

                            if ($RawUri -match '^/subscriptions/([^/]+)(/resourcegroups/([^/]+))?(/providers/(.+))?$')
                            {
                                $RealSub = $matches[1]
                                $RealRg = $matches[3]
                                $RealProv = $matches[5]   # e.g. 'microsoft.compute/<type>/<name>[/<subtype>/<name2>]'

                                $ObfSub = if ($script:ConsumptionSubCache.ContainsKey($RealSub)) { $script:ConsumptionSubCache[$RealSub] } else
                                {
                                    $V = $Prefix + 'sub_' + [guid]::NewGuid().ToString()
                                    $script:ConsumptionSubCache[$RealSub] = $V; $V
                                }

                                $RebuiltUri = '/subscriptions/' + $ObfSub

                                if (-not [string]::IsNullOrEmpty($RealRg))
                                {
                                    $ObfRg = if ($script:ConsumptionRgCache.ContainsKey($RealRg)) { $script:ConsumptionRgCache[$RealRg] } else
                                    {
                                        # Preserve the AKS-managed-RG marker so the dashboard can
                                        # still detect AKS-managed resources after obfuscation.
                                        $IsMc = $RealRg -match '^mc_'
                                        $Tag = if ($IsMc) { 'mc_' } else { '' }
                                        $V = $Prefix + 'rg_' + $Tag + [guid]::NewGuid().ToString()
                                        $script:ConsumptionRgCache[$RealRg] = $V; $V
                                    }
                                    $RebuiltUri += '/resourcegroups/' + $ObfRg
                                }

                                if (-not [string]::IsNullOrEmpty($RealProv))
                                {
                                    # $realProv = "<rp>/<type>[/<name>[/<subtype>/<name2>...]]"
                                    # Keep the resource provider (segment 0) and every
                                    # type segment so categorisation works; obfuscate
                                    # only the name segments. After the provider, the
                                    # path alternates type-name-type-name, so within
                                    # the provider-relative index space TYPE segments
                                    # are at indices 1,3,5,... (i.e. odd) and NAME
                                    # segments are at indices 2,4,6,... (i.e. even).
                                    $ProvParts = $RealProv -split '/'
                                    $Rebuilt = @()
                                    for ($Pi = 0; $Pi -lt $ProvParts.Count; $Pi++)
                                    {
                                        $Part = $ProvParts[$Pi]
                                        $IsNameSegment = ($Pi -ge 2 -and ($Pi % 2 -eq 0))
                                        if ($IsNameSegment -and -not [string]::IsNullOrEmpty($Part) -and $Part -ne '$system')
                                        {
                                            $ObfName = if ($script:ConsumptionNameCache.ContainsKey($Part)) { $script:ConsumptionNameCache[$Part] } else
                                            {
                                                $V = $Prefix + [guid]::NewGuid().ToString()
                                                $script:ConsumptionNameCache[$Part] = $V; $V
                                            }
                                            $Rebuilt += $ObfName
                                        }
                                        else
                                        {
                                            $Rebuilt += $Part
                                        }
                                    }
                                    $RebuiltUri += '/providers/' + ($Rebuilt -join '/')
                                }

                                $ObfuscatedUri = $RebuiltUri
                            }
                            else
                            {
                                # Non-ARM-shape uri (e.g. system-namespace placeholder). Hash it
                                # to a stable token rather than emitting the raw value. Use
                                # the local name cache so the obfuscation dictionary file
                                # only ever contains real-Azure-ID -> obfuscated mappings.
                                # A null/empty resourceUri is legitimate for some meters
                                # (marketplace purchases, certain reservations, tenant-level
                                # charges). hashtable.ContainsKey($null) THROWS, which the
                                # per-subscription catch below would swallow - aborting the
                                # rest of that subscription's consumption collection. Guard
                                # the null/empty case explicitly so one such meter row can
                                # never truncate the consumption data (obfuscate-only bug).
                                if ([string]::IsNullOrEmpty($RawUri))
                                {
                                    $ObfuscatedUri = 'obfuscated'
                                }
                                else
                                {
                                    if (-not $script:ConsumptionNameCache.ContainsKey($RawUri))
                                    {
                                        $script:ConsumptionNameCache[$RawUri] = $Prefix + [guid]::NewGuid().ToString()
                                    }
                                    $ObfuscatedUri = $script:ConsumptionNameCache[$RawUri]
                                }
                            }

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

                    $NewUsageDataExport | Select-Object InstanceData, MeterCategory, MeterId, MeterName, MeterRegion, MeterSubCategory, Quantity, Unit, UsageStartTime, UsageEndTime, ResourceId, ResourceLocation, ConsumptionMeter, ReservationId, ReservationOrderId | Export-Csv $Global:ConsumptionFileCsv -Encoding utf8 -Append -NoTypeInformation

                } while ('ContinuationToken' -in $UsageData.psobject.properties.name -and $UsageData.ContinuationToken)
            }
            catch
            {
                # The most common cause is a broken Az module install (manifest
                # present, MSAL/Azure.Core assemblies missing). The script-level
                # Import-Module probe should have caught that, but we also catch
                # here defensively so a transient ARM throttling event or a
                # subscription the identity cannot bill against does not abort
                # the entire run for other subscriptions.
                #
                # Capture WHERE it stopped (page index + records collected so
                # far) so the truncation is precise and self-evident downstream,
                # rather than a silently-short CSV that can only be inferred from
                # a round row count. The rows already written to the CSV up to
                # this page are valid and kept, but this subscription's
                # consumption is INCOMPLETE and is reported as such.
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

        $DebugPreference = "Continue"
    }

    InitializeInventoryProcessing

    # Per-phase timing for the report header. Stored in $script: scope (NOT a new
    # $Global:) so it is readable by ProcessSummary later without polluting the
    # global namespace and without persisting across subscriptions under
    # -RunAllSubs (each & invocation gets a fresh script scope). The individual
    # phase calls are timed WITHOUT reordering them - the stopwatches wrap the
    # existing calls exactly as they were. This replaces the single opaque
    # "Reporting time" (which bundled metrics + collectors + consumption) with a
    # clear breakdown so an operator can see which phase dominates a long run.
    $script:PhaseTimings = [ordered]@{}

    $MetricsPhaseTimer = [System.Diagnostics.Stopwatch]::StartNew()
    CreateMetricsJob
    $MetricsPhaseTimer.Stop()

    $CollectorPhaseTimer = [System.Diagnostics.Stopwatch]::StartNew()
    CreateResourceJobs
    $CollectorPhaseTimer.Stop()

    ProcessMetricsResult
    ProcessResourceResult

    if (!$SkipMetrics.IsPresent)
    {
        $script:PhaseTimings['Metrics collection (Azure Monitor)'] = $MetricsPhaseTimer.Elapsed
    }
    $script:PhaseTimings['Resource detail collection (service collectors)'] = $CollectorPhaseTimer.Elapsed

    if (!$SkipConsumption.IsPresent)
    {
        $ConsumptionPhaseTimer = [System.Diagnostics.Stopwatch]::StartNew()
        GetResorceConsumption
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
            $SummaryPath = Get-ChildItem -Path ($PSScriptRoot + '\Extension\Summary.ps1') -Recurse
        }
        else
        {
            $SummaryPath = Get-ChildItem -Path ($PSScriptRoot + '/Extension/Summary.ps1') -Recurse
        }

        # Tenant ID is shown in the report header for reference, but it is a
        # real Azure identifier and must NOT appear in an obfuscated (shareable)
        # report. Pass it only when NOT obfuscating; the obfuscated HTML then
        # carries no tenant GUID, consistent with the four obfuscation
        # dictionaries that scrub every other identifier.
        $ReportTenantId = if ($Obfuscate.IsPresent) { $null } else { $TenantID }
        $ReportTitle = ('Azure Resource Inventory - {0}' -f $Global:ReportName)

        # Unlike a single collector failing (where the rest of the inventory
        # can still proceed - see CreateResourceJobs), the HTML report IS the
        # deliverable: there is nothing meaningful to "continue" to after this
        # fails. Catch here purely to give a clear, loud, specific diagnosis
        # (which file, which stage) instead of letting a raw exception from
        # deep inside Summary.ps1 surface as an unqualified PowerShell error,
        # then re-throw so this subscription is still correctly marked as
        # failed by the wrapper (same propagation path as every other
        # uncaught throw in this script - see Az-module-load and pre-flight
        # checks above).
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

# === Pre-flight checks ===
#
# Detect the most common environment problems that make a long run pointless,
# before transcript start, authentication, or any per-subscription work.
#
# When this script is invoked by Run-AllSubscriptions.ps1 (-RunAllSubs is
# set), the wrapper has already executed the same checks at its top level,
# so the entire block is skipped here - otherwise the checks would re-run
# once per subscription in a multi-subscription run, adding noise to the
# per-subscription transcript without adding safety. Standalone invocation
# of this script still runs the full block.
#
# NOTE: Keep the body of this block in sync with Invoke-PreFlightChecks in
# Functions/RunAllSubscriptions.Functions.ps1 (which Run-AllSubscriptions.ps1
# dot-sources). This copy is deliberately kept INLINE here - not shared - so
# the environment sanity checks have no dependency on locating another file,
# which matters most in exactly the broken environments these checks exist to
# catch. Intentional differences vs the wrapper copy:
#   - This copy honors -OutputDirectory if the caller passed one (the wrapper
#     does not expose or forward that parameter).
#   - This copy throws on hard-fail; the wrapper's copy calls Exit-Wrapper.
#   - This copy is gated on -not $RunAllSubs to avoid duplicate execution
#     when invoked by the wrapper.
if (-not $RunAllSubs.IsPresent)
{

    # Honor -OutputDirectory when the caller passed one. CheckPowerShell will
    # re-validate -OutputDirectory itself further down and is the authoritative
    # gate; we Resolve-Path here defensively so a relative path is checked at
    # the right location, and fall back to the raw value if it does not yet
    # resolve (the write probe below will surface the underlying error).
    $PreFlightInventoryRoot = if ($OutputDirectory)
    {
        try { (Resolve-Path $OutputDirectory -ErrorAction Stop).Path }
        catch { $OutputDirectory }
    }
    elseif ($PSVersionTable.Platform -eq 'Unix')
    {
        "$HOME/InventoryReports"
    }
    else
    {
        "C:\InventoryReports"
    }
    if (-not (Test-Path -Path $PreFlightInventoryRoot -PathType Container))
    {
        try { New-Item -Path $PreFlightInventoryRoot -ItemType Directory -Force | Out-Null }
        catch { Write-Verbose ("PreFlightInventoryRoot create failed at {0}: {1}" -f $PreFlightInventoryRoot, $_.Exception.Message) }
    }

    Write-Host "Running pre-flight checks..." -ForegroundColor Cyan

    # 0. -Service fast-fail. When -Service is supplied but NONE of the requested
    # names match a collector under Services/, the run would otherwise
    # authenticate and extract every resource only to produce an empty inventory
    # (and, downstream, a failed report) while still exiting 0 - a silent-looking
    # failure for a scripted recovery workflow. Validate up front, before auth or
    # any per-subscription work, and hard-fail (exit 1, matching the
    # functions-file-missing gate near the top of the script) with the full list
    # of valid collector names so a typo is caught immediately. Partial matches
    # (some valid, some not) are allowed through here; CreateResourceJobs
    # surfaces the unmatched names as a Warning.
    if ($Service -and @($Service).Count -gt 0)
    {
        $PreFlightAvailableServices = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Services') -Filter '*.ps1' -Recurse | ForEach-Object { $_.BaseName } | Sort-Object)
        $PreFlightMatchedServices = @($Service | Where-Object { $_ -in $PreFlightAvailableServices })
        if (@($PreFlightMatchedServices).Count -eq 0)
        {
            # Hard-fail here with exit 1 (NOT throw): $ErrorActionPreference is
            # 'SilentlyContinue' for a normal run, under which a bare throw at
            # script scope is swallowed and execution continues - which would
            # authenticate, extract, then produce an empty report while still
            # exiting 0. exit 1 is the script's established hard-fail signal (see
            # the functions-file-missing gate near the top) and is safe here
            # because this whole block is gated on -not $RunAllSubs, so the
            # in-process wrapper never reaches it.
            Write-Host ("ERROR: -Service matched no collectors. Requested: [{0}]." -f ($Service -join ', ')) -ForegroundColor Red
            Write-Host ("Valid collector names: [{0}]" -f ($PreFlightAvailableServices -join ', ')) -ForegroundColor Yellow
            exit 1
        }
        Write-Host ("Pre-flight: -Service will collect {0} of {1} collectors: [{2}]" -f @($PreFlightMatchedServices).Count, @($PreFlightAvailableServices).Count, ($PreFlightMatchedServices -join ', ')) -ForegroundColor Green
    }

    # 0b. -ObfuscationDictionary fast-fail. Seeding only makes sense with
    # -Obfuscate (the dictionaries are created only then), and a missing or
    # unreadable seed file must stop the run BEFORE auth rather than silently
    # minting fresh tokens - which would make a later merge fail to line up.
    # exit 1 (not throw) for the same reason as the -Service gate above:
    # $ErrorActionPreference is SilentlyContinue for a normal run.
    if (-not [string]::IsNullOrEmpty($ObfuscationDictionary))
    {
        if (-not $Obfuscate.IsPresent)
        {
            Write-Host "ERROR: -ObfuscationDictionary requires -Obfuscate (there are no obfuscation dictionaries to seed without it)." -ForegroundColor Red
            exit 1
        }
        if (-not (Test-Path -Path $ObfuscationDictionary -PathType Leaf))
        {
            Write-Host ("ERROR: -ObfuscationDictionary file not found: {0}" -f $ObfuscationDictionary) -ForegroundColor Red
            exit 1
        }
        try
        {
            $null = Get-Content -Path $ObfuscationDictionary -Raw | ConvertFrom-Json
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
        $RootItem = Get-Item -Path $PreFlightInventoryRoot -ErrorAction Stop
        $Drive = $RootItem.PSDrive
        if ($null -ne $Drive -and $null -ne $Drive.Free)
        {
            $FreeMB = [math]::Round($Drive.Free / 1MB, 0)
            if ($FreeMB -lt 100)
            {
                throw ("Pre-flight: free disk space at {0} is {1} MB; the script needs at least 100 MB to start. Free space and re-run." -f $PreFlightInventoryRoot, $FreeMB)
            }
            elseif ($FreeMB -lt 500)
            {
                Write-Host ("WARNING: Free disk space at {0} is {1} MB. A large multi-subscription run can exceed this. Consider freeing space before running." -f $PreFlightInventoryRoot, $FreeMB) -ForegroundColor Yellow
            }
            else
            {
                Write-Host ("Free disk space: {0:N0} MB at {1}" -f $FreeMB, $PreFlightInventoryRoot) -ForegroundColor Green
            }
        }
    }
    catch
    {
        if ($_.Exception.Message -match '^Pre-flight:') { throw }
        Write-Host ("WARNING: Could not determine free disk space at {0}: {1}" -f $PreFlightInventoryRoot, $_.Exception.Message) -ForegroundColor Yellow
    }

    # 3. Write probe.
    $ProbePath = Join-Path $PreFlightInventoryRoot (".write-probe-{0}.tmp" -f ([guid]::NewGuid()))
    try
    {
        Set-Content -Path $ProbePath -Value 'preflight write probe' -Encoding utf8 -ErrorAction Stop
        $ProbeRead = Get-Content -Path $ProbePath -Raw -ErrorAction Stop
        if ($ProbeRead -notmatch 'preflight write probe')
        {
            throw "Write probe content mismatch (read back '$ProbeRead')"
        }
        Remove-Item -Path $ProbePath -Force -ErrorAction Stop
        Write-Host ("Write probe: OK ({0})" -f $PreFlightInventoryRoot) -ForegroundColor Green
    }
    catch
    {
        try { if (Test-Path $ProbePath) { Remove-Item -Path $ProbePath -Force -ErrorAction SilentlyContinue } }
        catch { Write-Verbose ("Probe cleanup failed at {0}: {1}" -f $ProbePath, $_.Exception.Message) }
        throw ("Pre-flight: cannot write to {0}: {1}. This usually means readonly directory, denied permissions, antivirus or DLP product blocking writes, or a stale handle. Verify the directory is writable and re-run." -f $PreFlightInventoryRoot, $_.Exception.Message)
    }

    Write-Host "Pre-flight checks passed." -ForegroundColor Green
    Write-Host ""
}

# Setup and Inventory Gathering.
#
# Variables and RunInventorySetup populate $Global:DefaultPath, $Global:ReportName,
# and $Global:CurrentDateTime which are required to compute the transcript path.
# Start-Transcript must therefore run *after* RunInventorySetup, not before.
# Previously this block placed Start-Transcript above Variables, with the result
# that $DefaultPath/$ReportName/$CurrentDateTime were all $null at that point and
# the transcript file landed in the current working directory with the literal
# name "Transcript_Log__.txt" - two underscores, missing report name and missing
# timestamp.
$Global:Runtime = Measure-Command -Expression {
    Variables
    RunInventorySetup

    $Global:PowerShellTranscriptFile = ($Global:DefaultPath + "Transcript_Log_" + $Global:ReportName + "_" + $Global:CurrentDateTime + ".txt")
    Start-Transcript -Path $Global:PowerShellTranscriptFile -UseMinimalHeader
}

# Execution and processing of inventory.
#
# Wrap in try/finally so this run's transcript frame is ALWAYS stopped - even if
# ExecuteInventoryProcessing throws a terminating error (e.g. the collector
# circuit breaker throwing after repeated failures). PowerShell transcripts are
# a process-wide STACK, and the -RunAllSubs wrapper invokes this script via & in
# the SAME process. A frame left open here is orphaned on that stack; the
# wrapper's own Stop-Transcript at the end then pops THIS orphan instead of the
# wrapper's frame, leaving the wrapper transcript file held open ("in use",
# undeletable) for the life of the calling shell. Stopping it here keeps the
# stack balanced per subscription. The inner try/catch tolerates the rare case
# where no transcript is active (Start-Transcript above having failed).
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
        GeneratedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        ResourceIdMap = @{}
        ResourceNameMap = @{}
        SubscriptionMap = @{}
        ResourceGroupMap = @{}
        # Maps an obfuscated subscription token to the REAL subscription display
        # name, so Unmask-Obfuscation.ps1 can resolve the friendly name fully
        # offline. The other maps store ARM resource Ids, which only contain the
        # subscription GUID - never the name - so without this map the only way
        # back to a name was an online Get-AzSubscription call.
        SubscriptionNameMap = @{}
        # Maps an obfuscated tag-value token back to the REAL tag value, so tag
        # values (which keep their keys but have obfuscated values) can be
        # reversed offline like every other obfuscated field.
        TagMap = @{}
        # Maps an obfuscated free-text/identity token back to the REAL value
        # (Description, FriendlyName, CreatedBy, RoleName, container image, etc.)
        # so Reveal-Obfuscation.ps1 can restore these free-form fields offline.
        FreeTextMap = @{}
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

    $Dictionary | ConvertTo-Json -depth 5 | Out-File $Global:DictionaryFile -Encoding utf8
    Write-Log -Message ("Obfuscation dictionary saved locally: {0}" -f $Global:DictionaryFile) -Severity 'Success'
    Write-Log -Message ("") -Severity 'Info'
    Write-Log -Message ("=== OBFUSCATION NOTICE ===") -Severity 'Warning'
    Write-Log -Message ("The following files remain LOCAL and should NOT be shared:") -Severity 'Warning'
    Write-Log -Message ("  - Dictionary: {0}" -f $Global:DictionaryFile) -Severity 'Warning'
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
    # is local-only (never zipped) and flagged here alongside the transcript.
    if (![string]::IsNullOrEmpty($Global:DebugLogFile) -and (Test-Path -LiteralPath $Global:DebugLogFile))
    {
        Write-Log -Message ("  - Debug log:  {0}" -f $Global:DebugLogFile) -Severity 'Warning'
    }
    Write-Log -Message ("") -Severity 'Info'
    Write-Log -Message ("The ZIP file is safe to share with AWS or partners.") -Severity 'Success'
    Write-Log -Message ("Partners may ask about obfuscated names (e.g. 'prod_a1b2c3d4-...'). Use the dictionary file to look up the real resource name and respond.") -Severity 'Info'
    Write-Log -Message ("Delete the dictionary and transcript when no longer needed for security.") -Severity 'Warning'
}

if ($SkipMetrics.IsPresent)
{
    @{ Metrics = @() } | ConvertTo-Json -depth 5 -compress | Out-File $Global:MetricsJsonFile -Encoding utf8
}
else
{
    # Subscriptions with zero metric-eligible resources never enter the
    # batched-write loop in Extension/Metrics.ps1, so no Metrics_*.json is
    # produced for them. Downstream consumers that expect *every* per-sub
    # bundle to contain a Metrics JSON (dashboard ingestion, the
    # ParallelStreamsAggregation tests) reject the bundle when the file is
    # missing. Detect that case and emit an empty-but-valid Metrics JSON
    # at the canonical $Global:MetricsJsonFile path so the bundle is always
    # structurally complete. Use Get-ChildItem with a wildcard because the
    # batched writer suffixes filenames with "_<rangeIdx>.json".
    $MetricsPattern = ('Metrics_{0}_{1}*.json' -f $Global:ReportName, $CurrentDateTime)
    $MetricsAny = @(Get-ChildItem -Path $DefaultPath -Filter $MetricsPattern -ErrorAction SilentlyContinue)
    if ($MetricsAny.Count -eq 0)
    {
        @{ Metrics = @() } | ConvertTo-Json -depth 5 -compress | Out-File $Global:MetricsJsonFile -Encoding utf8
    }
}

$ConsumptionCreated = Test-Path -Path $Global:ConsumptionFileCsv

# A subscription with zero billing records produces an empty (0-byte) CSV
# rather than a header-only one, because Export-Csv -Append with no input
# objects writes nothing. Treat 0-byte files as "not created" so the safety
# net below emits the header. Without this, downstream consumers that parse
# the CSV by header (dashboard ingestion, the Pester tests) fail on the
# empty file and reject the entire per-sub bundle.
$ConsumptionEmpty = $false
if ($ConsumptionCreated)
{
    try
    {
        $ConsumptionEmpty = ((Get-Item -Path $Global:ConsumptionFileCsv -ErrorAction Stop).Length -eq 0)
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
    "InstanceData,MeterCategory,MeterId,MeterName,MeterRegion,MeterSubCategory,Quantity,Unit,UsageStartTime,UsageEndTime,ResourceId,ResourceLocation,ConsumptionMeter,ReservationId,ReservationOrderId" | Out-File $Global:ConsumptionFileCsv -Encoding utf8
}

$JsonWildCard = $DefaultPath + "*.json"

if ($Obfuscate.IsPresent)
{
    # Shareable diagnostics log for this (obfuscated) run - phase timings +
    # per-subscription collector/metrics/consumption health, every identifier
    # scrubbed via Protect-DiagnosticText. Built by Write-RdaShareableDiagnosticsLog
    # (Functions/ResourceInventory.Functions.ps1) so the SAME builder serves both
    # the obfuscated and default packaging branches. Returns $null on any
    # build/write failure (downgraded to a warning inside), so the guard below
    # cannot inject a missing path into the archive list and break packaging.
    $DiagnosticsFile = Write-RdaShareableDiagnosticsLog -DefaultPath $DefaultPath -ReportName $Global:ReportName -RunDateTime $Global:CurrentDateTime -Version $Global:Version -PhaseTimings $script:PhaseTimings -Obfuscated:$Obfuscate.IsPresent

    # Exclude the obfuscation dictionary and transcript from the obfuscated zip.
    # The dictionary maps obfuscated values back to REAL identifiers, and the
    # transcript captures the raw Write-Log stream (auth UPN, tenant GUID,
    # subscription names) that the obfuscation layer never touches. The
    # transcript is excluded separately below (it is not a .json). Use a
    # specific json file list so only the safe, obfuscated json files ship.
    # The shareable Diagnostics_*.log built above is a .log (so it is NOT swept
    # by this *.json filter and is NOT table-ingested); it is added to the Path
    # array EXPLICITLY below because it is curated + dictionary-scrubbed and is
    # meant to ship. The LOCAL-only .log files (DebugLog_* consolidated
    # heartbeat + metrics diagnostics, legacy Heartbeat_*/ErrorLog_*) are also
    # not .json so this filter never sweeps them AND they are never added to the
    # Path array, so they stay local; the explicit -notlike guards harden the
    # seam so none can ship even if this filter is broadened later - they carry a
    # real subscription GUID and real service/resource names.
    $JsonFiles = Get-ChildItem -Path $DefaultPath -Filter "*.json" | Where-Object { $_.Name -notlike "ObfuscationDictionary_*" -and $_.Name -notlike "Full_*" -and $_.Name -notlike "Heartbeat_*" -and $_.Name -notlike "DebugLog_*" -and $_.Name -notlike "ErrorLog_*" } | Select-Object -ExpandProperty FullName
    # Include the shareable diagnostics .log if it was successfully written.
    # Guarded (not assumed) so a diagnostics build/write failure above - which is
    # caught and downgraded to a warning - cannot inject a $null/missing path
    # into the archive list and break packaging of the actual report.
    $ShareableExtras = @()
    if (-not [string]::IsNullOrEmpty($DiagnosticsFile) -and (Test-Path -LiteralPath $DiagnosticsFile)) { $ShareableExtras += $DiagnosticsFile }
    $CompressionOutput = @{
        Path = @($Global:HtmlFile, $Global:ConsumptionFileCsv) + $ShareableExtras + $JsonFiles
        CompressionLevel = 'Fastest'
        DestinationPath = $Global:ZipOutputFile
    }
    Write-Log -Message ('Obfuscate mode: transcript log excluded from zip (kept locally for debug)') -Severity 'Info'
}
else
{
    # Shareable diagnostics log for this (default/non-obfuscated) run - same
    # builder as the obfuscated branch, WITHOUT -Obfuscated so its header states
    # the bundle is not obfuscated. Identifiers in the log are still class-masked
    # by Protect-DiagnosticText; the surrounding report already carries real
    # names, so shipping the log here adds no new exposure. Guarded like the
    # obfuscate path so a build/write failure cannot break packaging.
    $DiagnosticsFile = Write-RdaShareableDiagnosticsLog -DefaultPath $DefaultPath -ReportName $Global:ReportName -RunDateTime $Global:CurrentDateTime -Version $Global:Version -PhaseTimings $script:PhaseTimings
    $ShareableExtras = @()
    if (-not [string]::IsNullOrEmpty($DiagnosticsFile) -and (Test-Path -LiteralPath $DiagnosticsFile)) { $ShareableExtras += $DiagnosticsFile }

    # Exclude the PowerShell transcript from the default zip too. It captures
    # the authenticated account UPN, tenant/subscription IDs, and local paths
    # from Start-Transcript onward - data customers don't expect in the shared
    # bundle. Keep it on disk locally for debugging (same as the obfuscate path).
    # The Diagnostics_*.log (a .log, not swept by the *.json wildcard) is added
    # explicitly via $ShareableExtras so it ships in the default zip too.
    $CompressionOutput = @{
        Path = @($Global:HtmlFile, $Global:ConsumptionFileCsv, $JsonWildCard) + $ShareableExtras
        CompressionLevel = 'Fastest'
        DestinationPath = $Global:ZipOutputFile
    }
    Write-Log -Message ('Transcript log excluded from zip (kept locally for debug)') -Severity 'Info'
}

try
{
    Compress-Archive @CompressionOutput
}
catch
{
    $_ | Format-List -Force
    Write-Error ("Error Compressing Output File: {0}." -f $Global:ZipOutputFile)
    Write-Error ("Please zip the output files manually.")
}

Write-Log -Message ("Execution Time: {0}" -f $Runtime) -Severity 'Success'
Write-Log -Message ("Reporting Time: {0}" -f $ReportingRunTime) -Severity 'Success'
Write-Log -Message ("Reporting Data File: {0}" -f $Global:ZipOutputFile) -Severity 'Success'
