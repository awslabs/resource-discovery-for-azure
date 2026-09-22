#!/usr/bin/env pwsh
[CmdletBinding()]
param ($TenantID,
    $Appid,
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$', ErrorMessage = 'Invalid SubscriptionID; must be a GUID')]
    [string]$SubscriptionID,
    [switch]$DeviceLogin,
    [securestring]$Secret,
    [ValidatePattern('^[A-Za-z0-9._()-]{1,90}$', ErrorMessage = 'Invalid resource group name; must match ^[A-Za-z0-9._()-]{1,90}$')]
    [string]$ResourceGroup,
    [string[]]$Service,
    [switch]$SkipMetrics,
    [switch]$SkipDiskMetrics,
    [switch]$MetricsDetailed,
    [switch]$IncludeStorageMetrics,
    [switch]$UseMetricsBatch,
    [switch]$SkipConsumption,
    [switch]$SkipMarketplace,
    [switch]$Obfuscate,
    [string]$ObfuscationDictionary,
    [switch]$RunAllSubs,
    [switch]$CapacityPlan,
    [ValidateSet(0, 5, 15, 30, 60)][int]$MetricsIntervalMinutes = 0,
    $ConcurrencyLimit = 6,
    $MetricsLookbackDays = 31,
    $ReportName = 'ResourcesReport',
    $OutputDirectory)

$FunctionsFile = Join-Path $PSScriptRoot 'Functions/ResourceInventory.Functions.ps1'
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

$DebugMode = ($PSBoundParameters.ContainsKey('Debug') -and [bool]$PSBoundParameters['Debug'])

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
    $Global:TagValueDictionary = $null
    $Global:FreeTextDictionary = $null

    if ($Obfuscate.IsPresent)
    {
        $Global:ResourceIdDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $Global:ResourceNameDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $Global:ResourceSubscriptionDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $Global:ResourceResourceGroupDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
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
        if ($Global:RdaSessionInitialized)
        {
            return
        }

        Write-Log -Message ('Checking Version') -Severity 'Info'
        Write-Log -Message ('Version: {0}' -f $Global:Version) -Severity 'Info'

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
        }
    }

    function CheckCliRequirements()
    {
        if ($Global:AzPowerShellLoaded)
        {
            return
        }

        Write-Log -Message ('Checking Azure PowerShell Module...') -Severity 'Info'

        $RequiredAzSubModules = @('Az.Accounts', 'Az.Compute', 'Az.Monitor', 'Az.Billing', 'Az.ResourceGraph')

        $MissingAzSubModules = @($RequiredAzSubModules | Where-Object { $null -eq (Get-Module -Name $_ -ListAvailable -ErrorAction SilentlyContinue | Select-Object -First 1) })

        if ($MissingAzSubModules.Count -eq 0)
        {
            $VarAzPs = Get-Module -Name Az.Accounts -ListAvailable -ErrorAction SilentlyContinue | Select-Object -First 1
            Write-Log -Message ('Azure PowerShell modules present (Az.Accounts {0}); required: {1}' -f $VarAzPs.Version, ($RequiredAzSubModules -join ', ')) -Severity 'Success'
        }
        else
        {
            Write-Log -Message ('Required Azure PowerShell module(s) not found: {0}' -f ($MissingAzSubModules -join ', ')) -Severity 'Error'
            Write-Log -Message ('This tool needs only these Az submodules. Install them manually before re-running. From an elevated PowerShell 7 prompt:') -Severity 'Error'
            Write-Log -Message ('  Install-Module -Name {0} -Repository PSGallery -Force -AllowClobber -SkipPublisherCheck' -f ($RequiredAzSubModules -join ',')) -Severity 'Error'
            Write-Log -Message ('Or install the full rollup (larger, slower first import): Install-Module -Name Az -Repository PSGallery -Force -AllowClobber -SkipPublisherCheck') -Severity 'Error'
            Write-Log -Message ('Or in Cloud Shell, the Az module is already preinstalled - if it is missing your shell environment is broken.') -Severity 'Error'
            throw ('Required Azure PowerShell submodule(s) not found: {0}. See log above for installation instructions.' -f ($MissingAzSubModules -join ', '))
        }

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

    }

    function CheckPowerShell()
    {
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

        $ProcDiscriminator = ('{0:x4}' -f ($PID -band 0xffff))
        $Global:CurrentDateTime = ((Get-Date).ToString('yyyyMMddHHmmssfff', [cultureinfo]::InvariantCulture) + $ProcDiscriminator)
        $Global:FolderName = $Global:ReportName + $CurrentDateTime

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
        $ExistingContext = Get-AzContext -ErrorAction SilentlyContinue

        if (-not $Global:RdaSessionInitialized)
        {
            $CurrentCloudEnvName = if ($ExistingContext) { $ExistingContext.Environment.Name } else { 'AzureCloud' }
            Write-Host "Azure Cloud Environment: " -NoNewline
            Write-Host $CurrentCloudEnvName -ForegroundColor Green
        }

        if ($null -ne $ExistingContext)
        {
            if (-not $Global:RdaSessionInitialized)
            {
                Write-Log -Message ("Already authenticated as: {0}" -f $ExistingContext.Account.Id) -Severity 'Success'
            }

            if (!$TenantID -or $ExistingContext.Tenant.Id -eq $TenantID)
            {
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

        if (-not $Global:RdaSessionInitialized)
        {
            Write-Log -Message ("Number of Subscriptions Found: {0}" -f $SubscriptionCount) -Severity 'Info'
        }

        Write-Log -Message ("Checking report folder: {0}" -f $DefaultPath) -Severity 'Info'

        if ((Test-Path -LiteralPath $DefaultPath -PathType Container) -eq $false)
        {
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
        $SubLookup = @{}
        $RgLookup = @{}

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
                foreach ($SeedProp in $SeedDictionary.SubscriptionNameMap.PSObject.Properties)
                {
                    if (-not [string]::IsNullOrEmpty($SeedProp.Value)) { $SubLookup[$SeedProp.Value] = $SeedProp.Name }
                }
            }
            if ($null -ne $SeedDictionary.ResourceGroupMap)
            {
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

            $RealSub = ($Global:Subscriptions | Where-Object { $_.id -eq $resourceItem.subscriptionId }).Name
            if ([string]::IsNullOrEmpty($RealSub)) { $RealSub = $resourceItem.subscriptionId }
            if (-not $SubLookup.ContainsKey($RealSub))
            {
                $SubPrefix = if ($RealSub -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or $RealSub -match '(^|-)([dts])-') { "nonprod_" } else { "prod_" }
                $SubLookup[$RealSub] = $SubPrefix + [guid]::NewGuid().ToString()
            }
            $ObfuscatedSubscription = $SubLookup[$RealSub]

            $RealRG = $resourceItem.resourceGroup
            if ([string]::IsNullOrEmpty($RealRG)) { $RealRG = '__none__' }
            if (-not $RgLookup.ContainsKey($RealRG))
            {
                $RgPrefix = if ($RealRG -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or $RealRG -match '(^|-)([dts])-') { "nonprod_" } else { "prod_" }
                $RgLookup[$RealRG] = $RgPrefix + [guid]::NewGuid().ToString()
            }
            $ObfuscatedResourceGroup = $RgLookup[$RealRG]

            if ($ResourceIdDictionary.ContainsKey($resourceItem.ID))
            {
                $ObfuscatedID = $ResourceIdDictionary[$resourceItem.ID]
                if ($ResourceNameDictionary.ContainsKey($resourceItem.ID))
                {
                    $ObfuscatedName = $ResourceNameDictionary[$resourceItem.ID]
                }
            }

            $ResourceIdDictionary[$resourceItem.ID] = $ObfuscatedID
            $ResourceNameDictionary[$resourceItem.ID] = $ObfuscatedName
            $ResourceSubscriptionDictionary[$resourceItem.ID] = $ObfuscatedSubscription
            $ResourceResourceGroupDictionary[$resourceItem.ID] = $ObfuscatedResourceGroup

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
        $Global:MarketplaceFileCsv = ($DefaultPath + "Marketplace_" + $Global:ReportName + "_" + $CurrentDateTime + ".csv")

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
            if (-not (Test-DataPlaneAuthReady -Phase 'Metrics'))
            {
                Write-Log -Message ('Metrics: SKIPPED - could not establish a usable Azure context/token after one reconnect attempt. Metrics were requested (no -SkipMetrics) but cannot be collected. Re-authenticate (Connect-AzAccount) or pass -appid/-secret/-tenant, then re-run. The rest of the inventory will continue.') -Severity 'Error'

                $Global:AzMetrics = New-Object PSObject
                $Global:AzMetrics | Add-Member -MemberType NoteProperty -Name Metrics -Value NotSet
                $Global:AzMetrics.Metrics = [System.Collections.Concurrent.ConcurrentBag[psobject]]::new()

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
            [System.GC]::Collect()
            try
            {
                $MemHeapBeforeMB = [math]::Round([System.GC]::GetTotalMemory($false) / 1MB, 1)
                $MemHeapAfterMB = [math]::Round([System.GC]::GetTotalMemory($true) / 1MB, 1)
                $MemWorkingSetMB = [math]::Round([System.Diagnostics.Process]::GetCurrentProcess().WorkingSet64 / 1MB, 1)
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

            $RgTip = ''
            if (-not $SkipMetrics.IsPresent -and [string]::IsNullOrEmpty($ResourceGroup))
            {
                $RgTip = ' For targeted collection of a workload use -ResourceGroup (requires a single -SubscriptionID), which scopes inventory and metrics - but NOT consumption, which stays whole-subscription.'
            }

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

        $ConsecutiveCollectorFailures = 0
        $CollectorFailureCircuitBreakerThreshold = 5

        $ModuleTotal = @($Modules).Count
        $ModuleIndex = 0

        $HeartbeatSubLabel = if (![string]::IsNullOrEmpty($SubscriptionID)) { $SubscriptionID } else { '(all in-scope subscriptions)' }
        Write-Log -Message ("Service processing started for {0}: {1} collectors" -f $HeartbeatSubLabel, $ModuleTotal) -NoConsole -ToDebugLog

        foreach ($Module in $Modules)
        {
            $ModName = $Module.Name.Substring(0, $Module.Name.length - ".ps1".length)
            $ModuleIndex++

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

                $Result = @()
            }

            if ($Obfuscate.IsPresent)
            {
                foreach ($resourceItem in $Result)
                {
                    $OrigID = $resourceItem.ID

                    if ([string]::IsNullOrEmpty($OrigID))
                    {
                        $Fallback = 'obfuscated_' + [guid]::NewGuid().ToString()
                        $resourceItem.ID = $Fallback
                        $resourceItem.Name = $Fallback
                        $resourceItem.Subscription = $Fallback
                        $resourceItem.ResourceGroup = $Fallback
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

        $Global:SmaResources | Add-Member -MemberType NoteProperty -Name 'Version' -Value NotSet
        $Global:SmaResources.Version = $Global:Version

        $Global:SmaResources | ConvertTo-Json -Depth 100 -Compress | Out-File -LiteralPath $Global:JsonFile

        Write-Log -Message ('Resource Reporting Phase Done.') -Severity 'Info'
    }

    function GetResourceConsumption()
    {
        $DebugPreference = "SilentlyContinue"

        [System.Threading.Thread]::CurrentThread.CurrentUICulture = "en-US";
        [System.Threading.Thread]::CurrentThread.CurrentCulture = "en-US";

        $ReportedStartTime = (Get-Date).AddDays(-31).Date.AddHours(0).AddMinutes(0).AddSeconds(0).DateTime
        $ReportedEndTime = (Get-Date).AddDays(-1).Date.AddHours(0).AddMinutes(0).AddSeconds(0).DateTime

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
            if (![string]::IsNullOrEmpty($SubscriptionID))
            {
                if (![string]::IsNullOrEmpty($ResourceGroup))
                {
                    Write-Log -Message "Cannot filter consumption by resource group." -Severity 'Info'
                }

                if ($SubscriptionID -ne $sub.Id)
                {
                    Write-Log -Message ("Skipping: {0}" -f $sub.Name) -Severity 'Info'
                    continue
                }
            }

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

            $ConsumptionRecordsThisSub = 0
            $ConsumptionFailedThisSub = $false
            $ConsumptionFailureMessage = $null
            $ConsumptionPageIndex = 0

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

                    $ConsumptionMaxRetries = 30
                    $ConsumptionAttempt = 0
                    $ConsumptionAuthRefreshedThisPage = $false
                    # The retry loop can run long: up to $ConsumptionMaxRetries attempts, each
                    # sleeping a server-directed Retry-After clamped to 300s (~26 min worst case),
                    # which can outlive the token this page started with. The per-page guard below
                    # ($ConsumptionAuthRefreshedThisPage) stops a PERMANENT 401 reconnecting on every
                    # attempt, but on its own it also blocks a legitimate SECOND lapse: once a
                    # reconnect has succeeded, a token that expires again LATER in the same loop could
                    # not be refreshed, so the loop would burn its remaining budget against a dead
                    # token and fail loud. To close that intra-page gap without reopening the reconnect
                    # storm the guard prevents, a SUCCESSFUL reconnect re-arms the guard (its fresh
                    # token can lapse again and deserves another refresh); a reconnect that yields no
                    # usable token leaves the guard closed (a permanent 401 rides out the budget and
                    # fails loud, unchanged). Total re-arms are capped so an every-attempt expiry that
                    # keeps "succeeding" then immediately lapsing still terminates.
                    $ConsumptionAuthRefreshMax = 3
                    $ConsumptionAuthRefreshCount = 0
                    while ($true)
                    {
                        try
                        {
                            $UsageData = Get-UsageAggregates @Params -ErrorAction Stop
                            break
                        }
                        catch
                        {
                            if (Test-RdaConsumptionDenial -ErrorMessage $_.Exception.Message)
                            {
                                Write-Log -Message ("Consumption page query DENIED for {0} after {1} attempt(s): {2}. This is an authorization failure, not a transient one, so it will not be retried - grant Cost Management Reader (or the billing-scope equivalent) and re-run." -f $sub.Name, ($ConsumptionAttempt + 1), $_.Exception.Message) -Severity 'Error'
                                throw
                            }

                            if ((-not $ConsumptionAuthRefreshedThisPage) -and (Test-RdaAuthExpiry -ErrorMessage $_.Exception.Message))
                            {
                                $ConsumptionAuthRefreshedThisPage = $true
                                $ConsumptionAuthRefreshCount++
                                Write-Log -Message ("Consumption page query for {0} failed with an expired/invalid token: {1}. Attempting Azure re-authentication (refresh {2}/{3} for this page) before retrying this page." -f $sub.Name, $_.Exception.Message, $ConsumptionAuthRefreshCount, $ConsumptionAuthRefreshMax) -Severity 'Warning'
                                if (Test-DataPlaneAuthReady -Phase 'Consumption')
                                {
                                    # Test-DataPlaneAuthReady reconnects with Connect-AzAccount and no
                                    # -Subscription, so a successful reconnect can leave the context on the
                                    # identity's DEFAULT subscription rather than $sub. Get-UsageAggregates
                                    # reads the context's subscription, so retrying now without re-pinning
                                    # would attribute another subscription's usage rows to $sub. Re-pin and
                                    # re-verify exactly as the per-sub loop does before its first page; if the
                                    # scope cannot be restored, abandon this subscription rather than write
                                    # cross-subscription billing data.
                                    $RepinOk = $false
                                    $RepinError = $null
                                    try
                                    {
                                        $null = Set-AzContext -Subscription $sub.id -ErrorAction Stop
                                        $RepinOk = ((Get-AzContext).Subscription.Id -eq $sub.id)
                                    }
                                    catch
                                    {
                                        $RepinError = $_.Exception.Message
                                    }

                                    if ($RepinOk)
                                    {
                                        Write-Log -Message ("Consumption: Azure context re-established and re-pinned to {0}; retrying the current page." -f $sub.Name) -Severity 'Info'
                                        # The reconnect produced a usable, correctly-scoped token. That
                                        # token can itself lapse later in a long retry loop, so re-arm the
                                        # per-page guard to permit another refresh on a genuine SECOND
                                        # expiry - bounded by $ConsumptionAuthRefreshMax so this cannot
                                        # become an unbounded reconnect loop against an every-attempt expiry.
                                        if ($ConsumptionAuthRefreshCount -lt $ConsumptionAuthRefreshMax)
                                        {
                                            $ConsumptionAuthRefreshedThisPage = $false
                                        }
                                    }
                                    else
                                    {
                                        Write-Log -Message ("Consumption: re-authentication for {0} succeeded but the context could not be re-pinned to this subscription{1}. Abandoning this subscription's consumption to avoid attributing another subscription's billing data to it." -f $sub.Name, $(if ($RepinError) { " ($RepinError)" } else { ' (context did not match the target after Set-AzContext)' })) -Severity 'Error'
                                        throw
                                    }
                                }
                                else
                                {
                                    # No usable token after reconnect: a permanent 401 (revoked /
                                    # interaction-required). Leave the guard CLOSED so we do not reconnect
                                    # again this page - the remaining retries ride out the budget and fail
                                    # loud, unchanged from the original behaviour.
                                    Write-Log -Message ("Consumption: re-authentication for {0} did not yield a usable token; the remaining retries will still be attempted but may not recover." -f $sub.Name) -Severity 'Warning'
                                }
                            }

                            $ConsumptionAttempt++
                            if ($ConsumptionAttempt -gt $ConsumptionMaxRetries) { throw }

                            $ConsumptionThrottled = $_.Exception.Message -match 'TooManyRequests|\b429\b|throttl|rate limit'

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
                            $Prefix = if ($UsageDataExport[$Item].ResourceId -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or $UsageDataExport[$Item].ResourceId -match '(^|/|-)([dts])-') { 'nonprod_' } else { 'prod_' }

                            $RawUri = $InstanceObject.'Microsoft.Resources'.resourceUri

                            if (-not $script:ConsumptionSubCache) { $script:ConsumptionSubCache = @{} }
                            if (-not $script:ConsumptionRgCache) { $script:ConsumptionRgCache = @{} }
                            if (-not $script:ConsumptionNameCache) { $script:ConsumptionNameCache = @{} }

                            if ($RawUri -match '^/subscriptions/[^/]+(/resourcegroups/[^/]+)?/providers/(.+)$')
                            {
                                $DiagProvCount = ($Matches[2] -split '/').Count
                                if (($DiagProvCount -eq 3 -or $DiagProvCount -eq 4) -and -not ($null -ne $Global:ResourceIdDictionary -and $Global:ResourceIdDictionary.ContainsKey($RawUri)))
                                {
                                    Write-Log -Message ("Consumption cross-link miss: top-level resourceUri not found in inventory dictionary (leaf uses a name-cache token; the dictionary is case-insensitive, so this means the resource is genuinely absent - deleted between the graph scan and the billing pull, or outside a -Service-narrowed inventory): {0}" -f $RawUri) -Severity 'Info' -NoConsole -ToDebugLog
                                }
                            }

                            $ObfuscatedUri = Build-ObfuscatedResourceUri -RawUri $RawUri -Prefix $Prefix -SubscriptionDictionary $null -ResourceGroupDictionary $null -NameDictionary $Global:ResourceIdDictionary -SubCache $script:ConsumptionSubCache -RgCache $script:ConsumptionRgCache -NameCache $script:ConsumptionNameCache

                            $UsageDataExport[$Item].ResourceId = $ObfuscatedUri
                            $InstanceObject.'Microsoft.Resources'.resourceUri = $ObfuscatedUri

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

                    $ConsumptionRecordsThisSub += $NewUsageDataExport.Count

                } while ('ContinuationToken' -in $UsageData.psobject.properties.name -and $UsageData.ContinuationToken)
            }
            catch
            {
                $ConsumptionFailedThisSub = $true
                $ConsumptionFailureMessage = ("{0} (stopped at consumption page {1}, after {2} record(s); this subscription's consumption is INCOMPLETE)" -f $_.Exception.Message, $ConsumptionPageIndex, $ConsumptionRecordsThisSub)
                Write-Log -Message ("Consumption query failed for {0}: {1}" -f $sub.Name, $ConsumptionFailureMessage) -Severity 'Warning'
            }

            if ($null -eq $Global:ConsumptionRecordCount) { $Global:ConsumptionRecordCount = 0 }
            if ($null -eq $Global:ConsumptionFailedSubs) { $Global:ConsumptionFailedSubs = @() }
            $Global:ConsumptionRecordCount += $ConsumptionRecordsThisSub
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

    }

    function GetMarketplaceConsumption()
    {
        # ADDITIVE Marketplace consumption collector.
        #
        # WHY THIS EXISTS. The first-party consumption collector above uses
        # Get-UsageAggregates (legacy Microsoft.Commerce/UsageAggregates), which
        # returns ONLY first-party Azure metered usage and carries no PublisherType.
        # Azure Marketplace / third-party SaaS charges (e.g. an ISV offer sold via
        # Azure Marketplace, such as an Anthropic/Claude offer surfaced through Azure
        # AI Foundry) live behind a DIFFERENT endpoint that RDA never called, so
        # Marketplace usage was invisible regardless of whether any existed. This
        # closes that endpoint-coverage gap.
        #
        # ENDPOINT (verified against Microsoft docs):
        #   Get-AzConsumptionMarketplace (Az.Billing - already imported by RDA, so NO
        #   new module dependency). Raw REST equivalent:
        #     GET .../providers/Microsoft.Consumption/marketplaces?api-version=2023-05-01
        #     (optionally billing-period-scoped)
        #   Docs: https://learn.microsoft.com/en-us/rest/api/consumption/marketplaces/list
        #   Cmdlet: https://learn.microsoft.com/en-us/powershell/module/az.billing/get-azconsumptionmarketplace
        #   Parameters used (-StartDate/-EndDate/-Top) confirmed via
        #   `Get-Help Get-AzConsumptionMarketplace -Full` on the installed Az.Billing 2.2.0.
        #
        # DISCRIMINATOR. On the modern usageDetails / Cost Management dimension the
        # discriminator is PublisherType ('Azure' = first-party, 'Marketplace' =
        # third-party). The Marketplace endpoint returns ONLY Marketplace rows (its
        # PSMarketplace output type has no PublisherType property at all), so NO
        # client-side filtering is needed - every row it returns is a Marketplace row.
        #
        # ROLE. Reuses the SAME Cost Management Reader / Billing Reader requirement the
        # first-party consumption phase already needs - NO new role. The auth gate,
        # per-subscription context re-pin, denial short-circuit, auth-expiry refresh
        # (with re-pin) and Retry-After/backoff below are the SAME pattern the
        # Get-UsageAggregates loop uses, deliberately reused rather than reinvented.
        #
        # OUTPUT. Writes a SEPARATE Marketplace_<ReportName>_<stamp>.csv - the existing
        # Consumption_* schema and first-party path are untouched. Column set is the
        # documented PSMarketplace schema (property names verified from the installed
        # cmdlet's output type).

        $DebugPreference = "SilentlyContinue"

        [System.Threading.Thread]::CurrentThread.CurrentUICulture = "en-US";
        [System.Threading.Thread]::CurrentThread.CurrentCulture = "en-US";

        # Match the first-party consumption window: previous 31 days through yesterday.
        $MarketplaceStartDate = (Get-Date).AddDays(-31).Date
        $MarketplaceEndDate = (Get-Date).AddDays(-1).Date

        if ($null -eq $Global:MarketplaceRecordCount) { $Global:MarketplaceRecordCount = 0 }
        if ($null -eq $Global:MarketplaceFailedSubs) { $Global:MarketplaceFailedSubs = @() }
        if ($null -eq $script:MarketplaceRecordsThisRun) { $script:MarketplaceRecordsThisRun = 0 }

        if (-not (Test-DataPlaneAuthReady -Phase 'Marketplace'))
        {
            Write-Log -Message ('Marketplace: SKIPPED - could not establish a usable Azure context/token after one reconnect attempt. Marketplace consumption was requested (no -SkipConsumption / -SkipMarketplace) but cannot be collected. Re-authenticate (Connect-AzAccount) or pass -appid/-secret/-tenant, then re-run. The rest of the inventory will continue.') -Severity 'Error'
            $Global:MarketplaceFailedSubs += [pscustomobject]@{
                Name    = '(all subscriptions)'
                Id      = '(auth)'
                Message = 'Marketplace phase skipped: no usable Azure context/token after one reconnect attempt.'
            }
            return
        }

        foreach ($sub in $Global:Subscriptions)
        {
            if (![string]::IsNullOrEmpty($SubscriptionID))
            {
                if ($SubscriptionID -ne $sub.Id)
                {
                    Write-Log -Message ("Skipping (Marketplace): {0}" -f $sub.Name) -Severity 'Info'
                    continue
                }
            }

            $MpContextOk = $false
            $MpContextSwitchError = $null
            try
            {
                $null = Set-AzContext -Subscription $sub.id -ErrorAction Stop
                $MpContextOk = ((Get-AzContext).Subscription.Id -eq $sub.id)
            }
            catch
            {
                $MpContextSwitchError = $_.Exception.Message
            }

            if (-not $MpContextOk)
            {
                $SkipMessage = ("Marketplace SKIPPED: could not switch the Azure context to this subscription{0}. The signed-in identity likely lacks access to it. Skipped to avoid attributing another subscription's Marketplace billing data to this one." -f $(if ($MpContextSwitchError) { " ($MpContextSwitchError)" } else { ' (context did not match the target after Set-AzContext)' }))
                Write-Log -Message ("Marketplace: {0} - {1}" -f $sub.Name, $SkipMessage) -Severity 'Error'
                $Global:MarketplaceFailedSubs += [pscustomobject]@{
                    Name             = $sub.Name
                    Id               = $sub.Id
                    Message          = $SkipMessage
                    Complete         = $false
                    RecordsCollected = 0
                }
                continue
            }

            Write-Log -Message ("Gathering Marketplace consumption for: {0}" -f $sub.Name) -Severity 'Info'

            $MarketplaceRecordsThisSub = 0
            $MarketplaceFailedThisSub = $false
            $MarketplaceFailureMessage = $null
            $MarketplaceData = $null

            try
            {
                $MpMaxRetries = 30
                $MpAttempt = 0
                $MpAuthRefreshedThisCall = $false
                $MpAuthRefreshMax = 3
                $MpAuthRefreshCount = 0
                while ($true)
                {
                    try
                    {
                        # Get-AzConsumptionMarketplace returns the full result set for the
                        # window in one call (the Az.Billing wrapper follows the service
                        # nextLink internally); -Top caps it defensively. It is wrapped in
                        # the same retry/auth-refresh envelope as the first-party loop.
                        $MarketplaceData = @(Get-AzConsumptionMarketplace -StartDate $MarketplaceStartDate -EndDate $MarketplaceEndDate -Top 1000 -ErrorAction Stop)
                        break
                    }
                    catch
                    {
                        if (Test-RdaConsumptionDenial -ErrorMessage $_.Exception.Message)
                        {
                            Write-Log -Message ("Marketplace query DENIED for {0} after {1} attempt(s): {2}. This is an authorization failure, not a transient one, so it will not be retried - grant Cost Management Reader (or the billing-scope equivalent) and re-run." -f $sub.Name, ($MpAttempt + 1), $_.Exception.Message) -Severity 'Error'
                            throw
                        }

                        if ((-not $MpAuthRefreshedThisCall) -and (Test-RdaAuthExpiry -ErrorMessage $_.Exception.Message))
                        {
                            $MpAuthRefreshedThisCall = $true
                            $MpAuthRefreshCount++
                            Write-Log -Message ("Marketplace query for {0} failed with an expired/invalid token: {1}. Attempting Azure re-authentication (refresh {2}/{3}) before retrying." -f $sub.Name, $_.Exception.Message, $MpAuthRefreshCount, $MpAuthRefreshMax) -Severity 'Warning'
                            if (Test-DataPlaneAuthReady -Phase 'Marketplace')
                            {
                                # Test-DataPlaneAuthReady reconnects with no -Subscription, so it can
                                # leave the context on the identity's DEFAULT subscription. Get-AzConsumptionMarketplace
                                # reads the context's subscription, so re-pin and re-verify before retrying,
                                # exactly as the first-party consumption loop does - otherwise another
                                # subscription's Marketplace rows would be attributed to this one.
                                $MpRepinOk = $false
                                $MpRepinError = $null
                                try
                                {
                                    $null = Set-AzContext -Subscription $sub.id -ErrorAction Stop
                                    $MpRepinOk = ((Get-AzContext).Subscription.Id -eq $sub.id)
                                }
                                catch
                                {
                                    $MpRepinError = $_.Exception.Message
                                }

                                if ($MpRepinOk)
                                {
                                    Write-Log -Message ("Marketplace: Azure context re-established and re-pinned to {0}; retrying." -f $sub.Name) -Severity 'Info'
                                    if ($MpAuthRefreshCount -lt $MpAuthRefreshMax)
                                    {
                                        $MpAuthRefreshedThisCall = $false
                                    }
                                }
                                else
                                {
                                    Write-Log -Message ("Marketplace: re-authentication for {0} succeeded but the context could not be re-pinned to this subscription{1}. Abandoning this subscription's Marketplace data to avoid attributing another subscription's billing data to it." -f $sub.Name, $(if ($MpRepinError) { " ($MpRepinError)" } else { ' (context did not match the target after Set-AzContext)' })) -Severity 'Error'
                                    throw
                                }
                            }
                            else
                            {
                                Write-Log -Message ("Marketplace: re-authentication for {0} did not yield a usable token; the remaining retries will still be attempted but may not recover." -f $sub.Name) -Severity 'Warning'
                            }
                        }

                        $MpAttempt++
                        if ($MpAttempt -gt $MpMaxRetries) { throw }

                        $MpThrottled = $_.Exception.Message -match 'TooManyRequests|\b429\b|throttl|rate limit'
                        $MpRetryAfter = Get-RdaRetryAfterSeconds -ErrorRecord $_
                        if ($MpRetryAfter -gt 0)
                        {
                            $MpThrottled = $true
                            $MpBackoffSeconds = [math]::Min($MpRetryAfter, 300)
                        }
                        else
                        {
                            $MpBackoffSeconds = [math]::Min([math]::Pow(2, $MpAttempt), 60)
                            if ($MpThrottled) { $MpBackoffSeconds = [math]::Min($MpBackoffSeconds * 2, 120) }
                        }
                        $MpBackoffSeconds = [math]::Round($MpBackoffSeconds + ((Get-Random -Minimum 0 -Maximum 1000) / 1000.0), 2)

                        $MpRetryMarker = if ($MpRetryAfter -gt 0) { ', throttled, honoring server Retry-After' } elseif ($MpThrottled) { ', throttled' } else { '' }
                        Write-Log -Message ("Marketplace query failed for {0} (attempt {1}/{2}{3}): {4}. Retrying in {5}s..." -f $sub.Name, $MpAttempt, $MpMaxRetries, $MpRetryMarker, $_.Exception.Message, $MpBackoffSeconds) -Severity 'Warning'
                        Start-Sleep -Seconds $MpBackoffSeconds
                    }
                }

                $MarketplaceExport = [System.Collections.ArrayList]::new()
                foreach ($Row in $MarketplaceData)
                {
                    if ($null -eq $Row) { continue }

                    # Field mapping + obfuscation live in ConvertTo-RdaMarketplaceRow
                    # (Functions/ResourceInventory.Functions.ps1) so the exact same code path
                    # is unit-tested. Product identifiers (PublisherName/OfferName/PlanName)
                    # stay readable; InstanceId/ResourceGroup/SubscriptionName/InstanceName
                    # flow through the shared obfuscation caches when -Obfuscate is set.
                    if ($Obfuscate.IsPresent)
                    {
                        if (-not $script:MarketplaceSubCache) { $script:MarketplaceSubCache = @{} }
                        if (-not $script:MarketplaceRgCache) { $script:MarketplaceRgCache = @{} }
                        if (-not $script:MarketplaceNameCache) { $script:MarketplaceNameCache = @{} }
                    }

                    $null = $MarketplaceExport.Add((ConvertTo-RdaMarketplaceRow -Row $Row -Obfuscate:$Obfuscate.IsPresent -NameDictionary $Global:ResourceIdDictionary -SubCache $script:MarketplaceSubCache -RgCache $script:MarketplaceRgCache -NameCache $script:MarketplaceNameCache))
                }

                if ($MarketplaceExport.Count -gt 0)
                {
                    $MarketplaceExport | Select-Object PublisherName, OfferName, PlanName, OrderNumber, ConsumedService, ConsumedQuantity, UnitOfMeasure, PretaxCost, Currency, IsEstimated, MeterId, UsageStart, UsageEnd, SubscriptionGuid, SubscriptionName, ResourceGroup, InstanceId, InstanceName | Export-Csv -LiteralPath $Global:MarketplaceFileCsv -Encoding utf8 -Append -NoTypeInformation
                }

                $MarketplaceRecordsThisSub = $MarketplaceExport.Count
                Write-Log -Message ("Marketplace records found for {0}: {1}" -f $sub.Name, $MarketplaceRecordsThisSub) -Severity 'Info'
            }
            catch
            {
                $MarketplaceFailedThisSub = $true
                $MarketplaceFailureMessage = ("{0} (this subscription's Marketplace data is INCOMPLETE)" -f $_.Exception.Message)
                Write-Log -Message ("Marketplace query failed for {0}: {1}" -f $sub.Name, $MarketplaceFailureMessage) -Severity 'Warning'
            }

            $Global:MarketplaceRecordCount += $MarketplaceRecordsThisSub
            $script:MarketplaceRecordsThisRun += $MarketplaceRecordsThisSub
            if ($MarketplaceFailedThisSub)
            {
                $Global:MarketplaceFailedSubs += [pscustomobject]@{
                    Name             = $sub.Name
                    Id               = $sub.Id
                    Message          = $MarketplaceFailureMessage
                    Complete         = $false
                    RecordsCollected = $MarketplaceRecordsThisSub
                }
            }
        }

        # HONEST NEGATIVES. An empty Marketplace result is a CONFIRMED ZERO (the endpoint
        # was reached and returned no rows), NOT a silently-missing section - mirror the
        # first-party consumption zero-record warning so an empty file reads as "verified
        # none", not "collector never ran". The Marketplace endpoint returns only
        # Marketplace-publisher rows, so zero here means no third-party/Marketplace charges
        # (e.g. no Anthropic-via-Marketplace usage) landed on the in-scope subscriptions in
        # the window.
        if ($Global:MarketplaceRecordCount -eq 0 -and ($Global:MarketplaceFailedSubs | Where-Object { $_.Id -ne '(auth)' } | Measure-Object).Count -eq 0)
        {
            Write-Log -Message ('Marketplace: 0 rows collected across all in-scope subscriptions. This is a CONFIRMED ZERO - the Microsoft.Consumption/marketplaces endpoint was reached successfully and returned no rows, meaning no Azure Marketplace / third-party SaaS charges (e.g. an Anthropic/Claude Marketplace offer) were billed to these subscriptions in the last 31 days. It is NOT a missing/failed section.') -Severity 'Warning'
        }
    }



    $script:PhaseTimings = [ordered]@{}

    $MetricsApiCallsBefore = if ($null -ne $Global:MetricsApiCallCount) { [int]$Global:MetricsApiCallCount } else { 0 }

    $MetricsPhaseTimer = [System.Diagnostics.Stopwatch]::StartNew()
    CreateMetricsJob
    $MetricsPhaseTimer.Stop()

    $MetricsApiCallsAfter = if ($null -ne $Global:MetricsApiCallCount) { [int]$Global:MetricsApiCallCount } else { 0 }
    $script:MetricsApiCallsThisRun = [Math]::Max(0, $MetricsApiCallsAfter - $MetricsApiCallsBefore)

    $CollectorPhaseTimer = [System.Diagnostics.Stopwatch]::StartNew()
    CreateResourceJobs
    $CollectorPhaseTimer.Stop()

    ProcessMetricsResult
    ProcessResourceResult

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
        $ConsumptionPhaseTimer.Stop()
        $script:PhaseTimings['Consumption / cost collection (billing)'] = $ConsumptionPhaseTimer.Elapsed

        # ADDITIVE Marketplace collector. Gated by the SAME -SkipConsumption switch
        # (it needs the same billing/Cost Management Reader access and Azure context)
        # and can be skipped independently with -SkipMarketplace. It emits a SEPARATE
        # Marketplace_* output and never touches the first-party Consumption_* path.
        if (!$SkipMarketplace.IsPresent)
        {
            $MarketplacePhaseTimer = [System.Diagnostics.Stopwatch]::StartNew()
            GetMarketplaceConsumption
            $MarketplacePhaseTimer.Stop()
            $script:PhaseTimings['Marketplace consumption collection (billing)'] = $MarketplacePhaseTimer.Elapsed
        }
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

        $ReportTenantId = if ($Obfuscate.IsPresent) { $null } else { $TenantID }
        $ReportTitle = ('Azure Resource Inventory - {0}' -f $Global:ReportName)

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
if (-not $RunAllSubs.IsPresent)
{

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
    Set-RdaInventoryRootForChildren -Path $PreFlightInventoryRoot

    Write-Host "Running pre-flight checks..." -ForegroundColor Cyan

    if ($Service -and @($Service).Count -gt 0)
    {
        $PreFlightAvailableServices = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Services') -Filter '*.ps1' -Recurse | ForEach-Object { $_.BaseName } | Sort-Object)
        $PreFlightMatchedServices = @($Service | Where-Object { $_ -in $PreFlightAvailableServices })
        if (@($PreFlightMatchedServices).Count -eq 0)
        {
            Write-Host ("ERROR: -Service matched no collectors. Requested: [{0}]." -f ($Service -join ', ')) -ForegroundColor Red
            Write-Host ("Valid collector names: [{0}]" -f ($PreFlightAvailableServices -join ', ')) -ForegroundColor Yellow
            exit 1
        }
        Write-Host ("Pre-flight: -Service will collect {0} of {1} collectors: [{2}]" -f @($PreFlightMatchedServices).Count, @($PreFlightAvailableServices).Count, ($PreFlightMatchedServices -join ', ')) -ForegroundColor Green
    }

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

    try
    {
        $RootItem = Get-Item -LiteralPath $PreFlightInventoryRoot -ErrorAction Stop
        $Drive = $RootItem.PSDrive
        if ($null -ne $Drive -and $null -ne $Drive.Free)
        {
            $FreeMB = [math]::Round($Drive.Free / 1MB, 0)
            if ($FreeMB -lt 100)
            {
                Write-Host ("ERROR: Free disk space at {0} is {1} MB; the script needs at least 100 MB to start. Free space and re-run." -f $PreFlightInventoryRoot, $FreeMB) -ForegroundColor Red
                exit 1
            }
            elseif ($FreeMB -lt 500)
            {
                Write-Host ("WARNING: Free disk space at {0} is {1} MB. A large multi-subscription run can exceed this. Consider freeing space before running." -f $PreFlightInventoryRoot, $FreeMB) -ForegroundColor Yellow
            }
            else
            {
                Write-Host ("Free disk space: {0} MB at {1}" -f $FreeMB.ToString('N0', [cultureinfo]::InvariantCulture), $PreFlightInventoryRoot) -ForegroundColor Green
            }
        }
    }
    catch
    {
        Write-Host ("WARNING: Could not determine free disk space at {0}: {1}" -f $PreFlightInventoryRoot, $_.Exception.Message) -ForegroundColor Yellow
    }

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
        Write-Host ("ERROR: cannot write to {0}: {1}" -f $PreFlightInventoryRoot, $_.Exception.Message) -ForegroundColor Red
        Write-Host "  This usually means a readonly directory, denied permissions, an antivirus or DLP product blocking writes, or a stale handle." -ForegroundColor Yellow
        Write-Host "  Verify the directory is writable and re-run, or pass -OutputDirectory with a writable path." -ForegroundColor Yellow
        exit 1
    }

    Write-Host "Pre-flight checks passed." -ForegroundColor Green
    Write-Host ""
}

$Global:Runtime = Measure-Command -Expression {
    Variables
    RunInventorySetup

    $Global:PowerShellTranscriptFile = ($Global:DefaultPath + "Transcript_Log_" + $Global:ReportName + "_" + $Global:CurrentDateTime + ".txt")
    Start-Transcript -LiteralPath $Global:PowerShellTranscriptFile -UseMinimalHeader
}

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

FinalizeOutputs

Write-Log -Message ("Compressing Resources Output: {0}" -f $Global:ZipOutputFile) -Severity 'Info'

if ($Obfuscate.IsPresent)
{
    $Global:DictionaryFile = ($DefaultPath + "ObfuscationDictionary_" + $Global:ReportName + "_" + $CurrentDateTime + ".json")

    $Dictionary = @{
        GeneratedAt         = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', [cultureinfo]::InvariantCulture)
        ResourceIdMap       = @{}
        ResourceNameMap     = @{}
        SubscriptionMap     = @{}
        ResourceGroupMap    = @{}
        SubscriptionNameMap = @{}
        TagMap              = @{}
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

    if ($null -ne $Global:TagValueDictionary)
    {
        foreach ($realValue in $Global:TagValueDictionary.Keys)
        {
            $Dictionary.TagMap[$Global:TagValueDictionary[$realValue]] = $realValue
        }
    }

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
    if (![string]::IsNullOrEmpty($Global:ErrorLogFile) -and (Test-Path -LiteralPath $Global:ErrorLogFile))
    {
        Write-Log -Message ("  - Error log:  {0}" -f $Global:ErrorLogFile) -Severity 'Warning'
    }
    if (![string]::IsNullOrEmpty($Global:DebugLogFile) -and (Test-Path -LiteralPath $Global:DebugLogFile))
    {
        Write-Log -Message ("  - Debug log:  {0}" -f $Global:DebugLogFile) -Severity 'Warning'
    }
    Write-Log -Message ("") -Severity 'Info'
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
    $MetricsPattern = ('Metrics_{0}_{1}*.json' -f $Global:ReportName, $CurrentDateTime)
    $MetricsAny = @(Get-ChildItem -LiteralPath $DefaultPath -Filter $MetricsPattern -ErrorAction SilentlyContinue)
    if ($MetricsAny.Count -eq 0)
    {
        @{ Metrics = @() } | ConvertTo-Json -Depth 5 -Compress | Out-File -LiteralPath $Global:MetricsJsonFile -Encoding utf8
    }
}

$ConsumptionCreated = Test-Path -LiteralPath $Global:ConsumptionFileCsv

$ConsumptionEmpty = $false
if ($ConsumptionCreated)
{
    try
    {
        $ConsumptionEmpty = ((Get-Item -LiteralPath $Global:ConsumptionFileCsv -ErrorAction Stop).Length -eq 0)
    }
    catch
    {
        $ConsumptionEmpty = $true
    }
}

if ($SkipConsumption.IsPresent -or !$ConsumptionCreated -or $ConsumptionEmpty)
{
    "InstanceData,MeterCategory,MeterId,MeterName,MeterRegion,MeterSubCategory,Quantity,Unit,UsageStartTime,UsageEndTime,ResourceId,ResourceLocation,ConsumptionMeter,ReservationId,ReservationOrderId" | Out-File -LiteralPath $Global:ConsumptionFileCsv -Encoding utf8
}

# Marketplace CSV parallels the Consumption CSV: an empty-but-present file (header only)
# is written when the phase was skipped or produced no rows, so a downstream consumer sees
# a deliberate, schema-shaped "0 Marketplace rows" rather than a missing file. This mirrors
# the confirmed-zero diagnostic the collector logs.
$MarketplaceCreated = Test-Path -LiteralPath $Global:MarketplaceFileCsv
$MarketplaceEmpty = $false
if ($MarketplaceCreated)
{
    try
    {
        $MarketplaceEmpty = ((Get-Item -LiteralPath $Global:MarketplaceFileCsv -ErrorAction Stop).Length -eq 0)
    }
    catch
    {
        $MarketplaceEmpty = $true
    }
}

if ($SkipConsumption.IsPresent -or $SkipMarketplace.IsPresent -or !$MarketplaceCreated -or $MarketplaceEmpty)
{
    "PublisherName,OfferName,PlanName,OrderNumber,ConsumedService,ConsumedQuantity,UnitOfMeasure,PretaxCost,Currency,IsEstimated,MeterId,UsageStart,UsageEnd,SubscriptionGuid,SubscriptionName,ResourceGroup,InstanceId,InstanceName" | Out-File -LiteralPath $Global:MarketplaceFileCsv -Encoding utf8
}

if ($Obfuscate.IsPresent)
{
    $DiagnosticsFile = Write-RdaShareableDiagnosticsLog -DefaultPath $DefaultPath -ReportName $Global:ReportName -RunDateTime $Global:CurrentDateTime -Version $Global:Version -PhaseTimings $script:PhaseTimings -ConsumptionRecordCount $(if ($null -ne $script:ConsumptionRecordsThisRun) { [int]$script:ConsumptionRecordsThisRun } else { 0 }) -ConsumptionRequested:(-not $SkipConsumption.IsPresent) -MarketplaceRecordCount $(if ($null -ne $script:MarketplaceRecordsThisRun) { [int]$script:MarketplaceRecordsThisRun } else { 0 }) -MarketplaceRequested:((-not $SkipConsumption.IsPresent) -and (-not $SkipMarketplace.IsPresent)) -MetricsApiCallCount $(if ($null -ne $script:MetricsApiCallsThisRun) { [int]$script:MetricsApiCallsThisRun } else { 0 }) -MetricsRequested:(-not $SkipMetrics.IsPresent) -Obfuscated:$Obfuscate.IsPresent

    $JsonFiles = Get-ChildItem -LiteralPath $DefaultPath -Filter "*.json" | Where-Object { $_.Name -notlike "ObfuscationDictionary_*" -and $_.Name -notlike "Full_*" -and $_.Name -notlike "Heartbeat_*" -and $_.Name -notlike "DebugLog_*" -and $_.Name -notlike "ErrorLog_*" } | Select-Object -ExpandProperty FullName
    $ShareableExtras = @()
    if (-not [string]::IsNullOrEmpty($DiagnosticsFile) -and (Test-Path -LiteralPath $DiagnosticsFile)) { $ShareableExtras += $DiagnosticsFile }
    $CompressionOutput = @{
        LiteralPath      = @($Global:HtmlFile, $Global:ConsumptionFileCsv, $Global:MarketplaceFileCsv) + $ShareableExtras + $JsonFiles
        CompressionLevel = 'Fastest'
        DestinationPath  = [WildcardPattern]::Escape($Global:ZipOutputFile)
    }
    Write-Log -Message ('Obfuscate mode: transcript log excluded from zip (kept locally for debug)') -Severity 'Info'
}
else
{
    $DiagnosticsFile = Write-RdaShareableDiagnosticsLog -DefaultPath $DefaultPath -ReportName $Global:ReportName -RunDateTime $Global:CurrentDateTime -Version $Global:Version -PhaseTimings $script:PhaseTimings -ConsumptionRecordCount $(if ($null -ne $script:ConsumptionRecordsThisRun) { [int]$script:ConsumptionRecordsThisRun } else { 0 }) -ConsumptionRequested:(-not $SkipConsumption.IsPresent) -MarketplaceRecordCount $(if ($null -ne $script:MarketplaceRecordsThisRun) { [int]$script:MarketplaceRecordsThisRun } else { 0 }) -MarketplaceRequested:((-not $SkipConsumption.IsPresent) -and (-not $SkipMarketplace.IsPresent)) -MetricsApiCallCount $(if ($null -ne $script:MetricsApiCallsThisRun) { [int]$script:MetricsApiCallsThisRun } else { 0 }) -MetricsRequested:(-not $SkipMetrics.IsPresent)
    $ShareableExtras = @()
    if (-not [string]::IsNullOrEmpty($DiagnosticsFile) -and (Test-Path -LiteralPath $DiagnosticsFile)) { $ShareableExtras += $DiagnosticsFile }

    if (-not [string]::IsNullOrEmpty($Global:DebugLogFile) -and (Test-Path -LiteralPath $Global:DebugLogFile))
    {
        $ShareableExtras += $Global:DebugLogFile
        Write-Log -Message ('Debug log INCLUDED in zip (non-obfuscated run): {0}' -f (Split-Path -Path $Global:DebugLogFile -Leaf)) -Severity 'Warning'
        Write-Log -Message ('  It carries real service/resource names and raw exception text. The report in this bundle is already non-obfuscated. Re-run with -Obfuscate to keep the debug log LOCAL.') -Severity 'Warning'
    }

    $JsonFiles = Get-ChildItem -LiteralPath $DefaultPath -Filter "*.json" | Where-Object { $_.Name -notlike "ObfuscationDictionary_*" -and $_.Name -notlike "Full_*" -and $_.Name -notlike "Heartbeat_*" -and $_.Name -notlike "DebugLog_*" -and $_.Name -notlike "ErrorLog_*" } | Select-Object -ExpandProperty FullName

    $CompressionOutput = @{
        LiteralPath      = @($Global:HtmlFile, $Global:ConsumptionFileCsv, $Global:MarketplaceFileCsv) + $ShareableExtras + $JsonFiles
        CompressionLevel = 'Fastest'
        DestinationPath  = [WildcardPattern]::Escape($Global:ZipOutputFile)
    }
    Write-Log -Message ('Transcript log excluded from zip (kept locally for debug)') -Severity 'Info'
}

$ZipWriteError = $null
try
{
    Compress-Archive @CompressionOutput -ErrorAction Stop
}
catch
{
    $ZipWriteError = $_.Exception.Message
}

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

    exit 2
}

Write-Log -Message ("Reporting Data File: {0}" -f $Global:ZipOutputFile) -Severity 'Success'

