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

$FunctionsFile = Join-Path $PSScriptRoot 'Functions/ResourceInventory.Functions.ps1'
if (-not (Test-Path -Path $FunctionsFile -PathType Leaf))
{
    Write-Host "ERROR: Required functions file not found: $FunctionsFile" -ForegroundColor Red
    Write-Host "Ensure the 'Functions' folder ships alongside this script." -ForegroundColor Yellow
    exit 1
}
. $FunctionsFile

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
    $Global:TagValueDictionary = $null
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

function Resolve-ObfuscationToken
{
    param(
        [string]$RealValue,
        [string]$LookupKey,
        $SharedDictionary,
        [hashtable]$LocalCache,
        [string]$TokenPrefix
    )

    if ($null -ne $SharedDictionary -and $SharedDictionary.ContainsKey($LookupKey)) { return $SharedDictionary[$LookupKey] }
    if ($LocalCache.ContainsKey($RealValue)) { return $LocalCache[$RealValue] }

    $Token = $TokenPrefix + [guid]::NewGuid().ToString()
    $LocalCache[$RealValue] = $Token
    return $Token
}

function Build-ObfuscatedResourceUri
{
    param(
        [string]$RawUri,
        [string]$Prefix,
        $SubscriptionDictionary,
        $ResourceGroupDictionary,
        $NameDictionary,
        [hashtable]$SubCache,
        [hashtable]$RgCache,
        [hashtable]$NameCache
    )

    if ([string]::IsNullOrEmpty($RawUri))
    {
        return 'obfuscated'
    }

    if ($RawUri -notmatch '^/subscriptions/([^/]+)(/resourcegroups/([^/]+))?(/providers/(.+))?$')
    {
        if (-not $NameCache.ContainsKey($RawUri))
        {
            $NameCache[$RawUri] = $Prefix + [guid]::NewGuid().ToString()
        }
        return $NameCache[$RawUri]
    }

    $RealSub = $Matches[1]
    $RealRg = $Matches[3]
    $RealProv = $Matches[5]

    $ObfSub = Resolve-ObfuscationToken -RealValue $RealSub -LookupKey $RawUri -SharedDictionary $SubscriptionDictionary -LocalCache $SubCache -TokenPrefix ($Prefix + 'sub_')

    $RebuiltUri = '/subscriptions/' + $ObfSub

    if (-not [string]::IsNullOrEmpty($RealRg))
    {
        $RgTag = if ($RealRg -match '^mc_') { 'mc_' } else { '' }
        $ObfRg = Resolve-ObfuscationToken -RealValue $RealRg -LookupKey $RawUri -SharedDictionary $ResourceGroupDictionary -LocalCache $RgCache -TokenPrefix ($Prefix + 'rg_' + $RgTag)
        $RebuiltUri += '/resourcegroups/' + $ObfRg
    }

    if (-not [string]::IsNullOrEmpty($RealProv))
    {
        $ProvParts = $RealProv -split '/'
        $Rebuilt = @()
        for ($Pi = 0; $Pi -lt $ProvParts.Count; $Pi++)
        {
            $Part = $ProvParts[$Pi]
            $IsNameSegment = ($Pi -ge 2 -and ($Pi % 2 -eq 0))
            if ($IsNameSegment -and -not [string]::IsNullOrEmpty($Part) -and $Part -ne '$system')
            {
                $NameSharedDict = if ($Pi -eq $ProvParts.Count - 1) { $NameDictionary } else { $null }
                $Rebuilt += Resolve-ObfuscationToken -RealValue $Part -LookupKey $RawUri -SharedDictionary $NameSharedDict -LocalCache $NameCache -TokenPrefix $Prefix
            }
            else
            {
                $Rebuilt += $Part
            }
        }
        $RebuiltUri += '/providers/' + ($Rebuilt -join '/')
    }

    return $RebuiltUri
}

Function RunInventorySetup()
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

        Write-Log -Message ('Verifying Azure CLI is installed...') -Severity 'Info'

        $AzCliVersion = az --version

        if ($null -eq $AzCliVersion)
        {
            Write-Log -Message ("Azure CLI Not Found. Please install and run the script again.") -Severity 'Error'
            Read-Host "Press <Enter> to exit"
            exit 1
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

        $RequiredAzSubModules = @('Az.Accounts', 'Az.Compute', 'Az.Monitor', 'Az.Billing')

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
                    Exit
                }
            }
        }

        $ProcDiscriminator = ('{0:x4}' -f ($PID -band 0xffff))
        $Global:CurrentDateTime = ((get-date -Format "yyyyMMddHHmmssfff") + $ProcDiscriminator)
        $Global:FolderName = $Global:ReportName + $CurrentDateTime

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
                exit 1
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
        if (-not $Global:RdaSessionInitialized)
        {
            $CloudEnv = az cloud list | ConvertFrom-Json
            Write-Host "Azure Cloud Environment: " -NoNewline

            $CurrentCloudEnvName = $CloudEnv | Where-Object { $_.isActive -eq 'True' }
            Write-Host $CurrentCloudEnvName.name -ForegroundColor Green
        }

        $ExistingAccount = az account show --output json --only-show-errors 2>$null | ConvertFrom-Json
        if ($null -ne $ExistingAccount)
        {
            if (-not $Global:RdaSessionInitialized)
            {
                Write-Log -Message ("Already authenticated as: {0}" -f $ExistingAccount.user.name) -Severity 'Success'
            }

            if (!$TenantID -or $ExistingAccount.tenantId -eq $TenantID)
            {
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
                    exit 1
                }
            }

            $Global:Subscriptions = @(az account list --output json --only-show-errors | ConvertFrom-Json)
            $Global:Subscriptions = @($Subscriptions | Where-Object { $_.tenantID -eq $TenantID })
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

        if ((Test-Path -Path $DefaultPath -PathType Container) -eq $false)
        {
            New-Item -Type Directory -Force -Path $DefaultPath | Out-Null
        }

        $Global:RdaSessionInitialized = $true
    }

    function ResourceInventoryLoop()
    {
        if (![string]::IsNullOrEmpty($ResourceGroup) -and [string]::IsNullOrEmpty($SubscriptionID))
        {
            Write-Log -Message ("Resource Group Name present, but missing Subscription ID.") -Severity 'Error'
            Write-Log -Message ("If using ResourceGroup parameter you must also put SubscriptionId") -Severity 'Error'
            exit 1
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
        $SubLookup = @{}
        $RgLookup = @{}

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
            else
            {
                $ObfuscatedName = $Prefix + [guid]::NewGuid().ToString()
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
                $ObfuscatedName = $ResourceNameDictionary[$resourceItem.ID]
                $ObfuscatedSubscription = $ResourceSubscriptionDictionary[$resourceItem.ID]
                $ObfuscatedResourceGroup = $ResourceResourceGroupDictionary[$resourceItem.ID]
            }
            else
            {
                # Build a structured ARM-shaped obfuscated ID (not a flat GUID token) by
                # substituting the real subscription/resource-group/name segments with the
                # SAME tokens stored in the sibling dictionaries below, so a downstream
                # consumption record that matches this exact resource ID reconstructs an
                # identically-shaped, identically-tokenized path.
                $ObfuscatedID = $resourceItem.ID -replace '(?i)/subscriptions/[^/]+', ('/subscriptions/' + $ObfuscatedSubscription)
                if ($ObfuscatedID -match '(?i)/resourcegroups/[^/]+')
                {
                    $ObfuscatedID = $ObfuscatedID -replace '(?i)/resourcegroups/[^/]+', ('/resourcegroups/' + $ObfuscatedResourceGroup)
                }
                $ObfuscatedID = $ObfuscatedID -replace '/[^/]+$', ('/' + $ObfuscatedName)
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

        $Global:SmaResources | ConvertTo-Json -depth 100 -compress | Out-File $Global:JsonFile

        Write-Log -Message ('Resource Reporting Phase Done.') -Severity 'Info'
    }

    function GetResorceConsumption()
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
                    Write-Log -Message ("Cannot filter consumption by resource group." -f $sub.Name) -Severity 'Info'
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
                                ImageType = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.ImageType) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.ImageType }
                                AHB = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.AHB) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.AHB }
                                vCores = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.vCores) { 0 } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.vCores }
                                VCPUs = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.VCPUs) { 0 } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.VCPUs }
                                ServiceType = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.ServiceType) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.ServiceType }
                                ResourceCategory = ""
                                Edition = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.Edition) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.Edition }
                                LicenseType = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.LicenseType) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.LicenseType }
                                HostLicenseType = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.HostLicenseType) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.HostLicenseType }
                                OS = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.OS) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.OS }
                                IsVM = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.IsVM) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.IsVM }
                                NumberOfCores = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.NumberOfCores) { 0 } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.NumberOfCores }
                                NumberOfLogicalProcessors = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.NumberOfLogicalProcessors) { 0 } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.NumberOfLogicalProcessors }
                                SLO = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.SLO) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.SLO }
                                ServerSku = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.ServerSku) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.ServerSku }
                                ServerEdition = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.ServerEdition) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.ServerEdition }
                                IsHAEnabled = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.IsHAEnabled) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.IsHAEnabled }
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


                            if (![string]::IsNullOrEmpty($RawUri) -and $ResourceIdDictionary.ContainsKey($RawUri))
                            {
                                $ObfuscatedUri = $ResourceIdDictionary[$RawUri]
                            }
                            else
                            {
                                $ObfuscatedUri = Build-ObfuscatedResourceUri -RawUri $RawUri -Prefix $Prefix -SubscriptionDictionary $ResourceSubscriptionDictionary -ResourceGroupDictionary $ResourceResourceGroupDictionary -NameDictionary $ResourceNameDictionary -SubCache $script:ConsumptionSubCache -RgCache $script:ConsumptionRgCache -NameCache $script:ConsumptionNameCache

                                if (![string]::IsNullOrEmpty($RawUri))
                                {
                                    $ResourceIdDictionary[$RawUri] = $ObfuscatedUri
                                }
                            }

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

                    $NewUsageDataExport | Select-Object InstanceData, MeterCategory, MeterId, MeterName, MeterRegion, MeterSubCategory, Quantity, Unit, UsageStartTime, UsageEndTime, ResourceId, ResourceLocation, ConsumptionMeter, ReservationId, ReservationOrderId | Export-Csv $Global:ConsumptionFileCsv -Encoding utf8 -Append -NoTypeInformation

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

if (-not $RunAllSubs.IsPresent)
{

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

    if ($Service -and @($Service).Count -gt 0)
    {
        $PreFlightAvailableServices = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Services') -Filter '*.ps1' -Recurse | ForEach-Object { $_.BaseName } | Sort-Object)
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
        # A top-level throw does not stop the run under the default SilentlyContinue
        # preference, so stop here the way the -Service and -ObfuscationDictionary checks do.
        Write-Host ("ERROR: Pre-flight: cannot write to {0}: {1}. This usually means readonly directory, denied permissions, antivirus or DLP product blocking writes, or a stale handle. Verify the directory is writable and re-run." -f $PreFlightInventoryRoot, $_.Exception.Message) -ForegroundColor Red
        exit 1
    }

    Write-Host "Pre-flight checks passed." -ForegroundColor Green
    Write-Host ""
}

$Global:Runtime = Measure-Command -Expression {
    Variables
    RunInventorySetup

    $Global:PowerShellTranscriptFile = ($Global:DefaultPath + "Transcript_Log_" + $Global:ReportName + "_" + $Global:CurrentDateTime + ".txt")
    Start-Transcript -Path $Global:PowerShellTranscriptFile -UseMinimalHeader
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
        GeneratedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        ResourceIdMap = @{}
        ResourceNameMap = @{}
        SubscriptionMap = @{}
        ResourceGroupMap = @{}
        SubscriptionNameMap = @{}
        TagMap = @{}
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

    $Dictionary | ConvertTo-Json -depth 5 | Out-File $Global:DictionaryFile -Encoding utf8
    Write-Log -Message ("Obfuscation dictionary saved locally: {0}" -f $Global:DictionaryFile) -Severity 'Success'
    Write-Log -Message ("") -Severity 'Info'
    Write-Log -Message ("=== OBFUSCATION NOTICE ===") -Severity 'Warning'
    Write-Log -Message ("The following files remain LOCAL and should NOT be shared:") -Severity 'Warning'
    Write-Log -Message ("  - Dictionary: {0}" -f $Global:DictionaryFile) -Severity 'Warning'
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
    $MetricsPattern = ('Metrics_{0}_{1}*.json' -f $Global:ReportName, $CurrentDateTime)
    $MetricsAny = @(Get-ChildItem -Path $DefaultPath -Filter $MetricsPattern -ErrorAction SilentlyContinue)
    if ($MetricsAny.Count -eq 0)
    {
        @{ Metrics = @() } | ConvertTo-Json -depth 5 -compress | Out-File $Global:MetricsJsonFile -Encoding utf8
    }
}

$ConsumptionCreated = Test-Path -Path $Global:ConsumptionFileCsv

$ConsumptionEmpty = $false
if ($ConsumptionCreated)
{
    try
    {
        $ConsumptionEmpty = ((Get-Item -Path $Global:ConsumptionFileCsv -ErrorAction Stop).Length -eq 0)
    }
    catch
    {
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
    $DiagnosticsFile = Write-RdaShareableDiagnosticsLog -DefaultPath $DefaultPath -ReportName $Global:ReportName -RunDateTime $Global:CurrentDateTime -Version $Global:Version -PhaseTimings $script:PhaseTimings -Obfuscated:$Obfuscate.IsPresent

    $JsonFiles = Get-ChildItem -Path $DefaultPath -Filter "*.json" | Where-Object { $_.Name -notlike "ObfuscationDictionary_*" -and $_.Name -notlike "Full_*" -and $_.Name -notlike "Heartbeat_*" -and $_.Name -notlike "DebugLog_*" -and $_.Name -notlike "ErrorLog_*" } | Select-Object -ExpandProperty FullName
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
    $DiagnosticsFile = Write-RdaShareableDiagnosticsLog -DefaultPath $DefaultPath -ReportName $Global:ReportName -RunDateTime $Global:CurrentDateTime -Version $Global:Version -PhaseTimings $script:PhaseTimings
    $ShareableExtras = @()
    if (-not [string]::IsNullOrEmpty($DiagnosticsFile) -and (Test-Path -LiteralPath $DiagnosticsFile)) { $ShareableExtras += $DiagnosticsFile }

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

# A direct run reaches this point even when it wrote no report (collection stopped,
# or the HTML report or the zip failed), so it must not end as a success. Under
# -RunAllSubs the exit code is left alone: the wrapper treats any non-zero exit as a
# failed subscription and checks each subscription's zip itself.
if (-not $RunAllSubs.IsPresent -and ([string]::IsNullOrEmpty($Global:ZipOutputFile) -or -not (Test-Path -LiteralPath $Global:ZipOutputFile)))
{
    Write-Log -Message ("No report was written: {0} was not created. See the errors above, fix the cause and re-run." -f $Global:ZipOutputFile) -Severity 'Error'
    exit 2
}

Write-Log -Message ("Reporting Data File: {0}" -f $Global:ZipOutputFile) -Severity 'Success'
