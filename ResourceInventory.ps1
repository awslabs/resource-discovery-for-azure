param ($TenantID,
        $Appid,
        $SubscriptionID,
        $Secret, 
        $ResourceGroup, 
        [switch]$Debug, 
        [switch]$SkipMetrics, 
        [switch]$SkipConsumption, 
        [switch]$DeviceLogin,
        [switch]$EnableLogs,
        [switch]$Obfuscate,
        [switch]$RunAllSubs,
        $ConcurrencyLimit = 6,
        $ReportName = 'ResourcesReport', 
        $OutputDirectory)


if ($Debug.IsPresent) {$DebugPreference = 'Continue'}

if ($Debug.IsPresent) {$ErrorActionPreference = "Continue" }Else {$ErrorActionPreference = "silentlycontinue" }

Write-Debug ('Debugging Mode: On. ErrorActionPreference was set to "Continue", every error will be presented.')

Function Write-Log([string]$Message, [string]$Severity)
{
   $DateTime = "[{0:dd-MM-yyyy} {0:HH:mm:ss}]" -f (Get-Date)

   if($EnableLogs.IsPresent)
   {
        $Global:Logging.Logs.Add([PSCustomObject]@{ Date = $DateTime; Message = $Message; Severity = $Severity })
   }

   switch ($Severity) 
   {
        "Info"    { Write-Host $Message -ForegroundColor Cyan }
        "Warning" { Write-Host $Message -ForegroundColor Yellow }
        "Error"   { Write-Host $Message -ForegroundColor Red }
        "Success"   { Write-Host $Message -ForegroundColor Green }
        default   { Write-Host $Message }
    }
}

function GetLocalVersion() 
{
    $versionJsonPath = "./Version.json"
    if (Test-Path $versionJsonPath) 
    {
        $localVersionJson = Get-Content $versionJsonPath | ConvertFrom-Json
        return ('{0}.{1}.{2}' -f $localVersionJson.MajorVersion, $localVersionJson.MinorVersion, $localVersionJson.BuildVersion)
    } 
    else 
    {
        Write-Host "Local Version.json not found. Clone the repo and execute the script from the root. Exiting." -ForegroundColor Red
        Exit
    }
}

function Variables 
{
    $Global:ResourceContainers = @()
    $Global:Resources = @()
    $Global:Subscriptions = ''
    $Global:ReportName = $ReportName   
    $Global:Version = GetLocalVersion

    $Global:Logging = New-Object PSObject
    $Global:Logging | Add-Member -MemberType NoteProperty -Name Logs -Value NotSet
    $Global:Logging.Logs = [System.Collections.Generic.List[object]]::new()

    $Global:ResourceIdDictionary = $null
    $Global:ResourceNameDictionary = $null
    $Global:ResourceSubscriptionDictionary = $null
    $Global:ResourceResourceGroupDictionary = $null

    if ($Obfuscate.IsPresent) {
        $Global:ResourceIdDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:ResourceNameDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:ResourceSubscriptionDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:ResourceResourceGroupDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    }

    $Global:RawRepo = 'https://raw.githubusercontent.com/awslabs/resource-discovery-for-azure/main'
    $Global:TableStyle = "Medium15"
}

Function RunInventorySetup()
{
    function CheckVersion()
    {
        Write-Log -Message ('Checking Version') -Severity 'Info'
        Write-Log -Message ('Version: {0}' -f $Global:Version) -Severity 'Info'
        
        $versionJson = (New-Object System.Net.WebClient).DownloadString($RawRepo + '/Version.json') | ConvertFrom-Json
        $versionNumber = ('{0}.{1}.{2}' -f $versionJson.MajorVersion, $versionJson.MinorVersion, $versionJson.BuildVersion)

        if($versionNumber -ne $Global:Version)
        {
            Write-Log -Message ('New Version Available: {0}.{1}.{2}' -f $versionJson.MajorVersion, $versionJson.MinorVersion, $versionJson.BuildVersion) -Severity 'Warning'
            Write-Log -Message ('Download or Clone the latest version and run again: https://github.com/awslabs/resource-discovery-for-azure') -Severity 'Error'
            Exit
        }
    }

    function CheckCliRequirements() 
    {        
        Write-Log -Message ('Verifying Azure CLI is installed...') -Severity 'Info'

        $azCliVersion = az --version

        if ($null -eq $azCliVersion) 
        {
            Write-Log -Message ("Azure CLI Not Found. Please install and run the script again.") -Severity 'Error'
            Read-Host "Press <Enter> to exit"
            Exit
        }

        Write-Log -Message ('CLI Version: {0}' -f $azCliVersion[0]) -Severity 'Success'

        Write-Log -Message ('Verifying Azure CLI Extension...') -Severity 'Info'

        $azCliExtension = az extension list --output json | ConvertFrom-Json
        $azCliExtension = $azCliExtension | Where-Object {$_.name -eq 'resource-graph'}

        Write-Log -Message ('Current Resource-Graph Extension Version: {0}' -f $azCliExtension.Version) -Severity 'Success'
        
        $azCliExtensionVersion = $azCliExtension | Where-Object {$_.name -eq 'resource-graph'}
    
        if (!$azCliExtensionVersion) 
        {
            Write-Log -Message ('Azure CLI Extension not found') -Severity 'Warning'
            Write-Log -Message ('Installing Azure CLI Extension...') -Severity 'Info'
            az extension add --name resource-graph
        }

        Write-Log -Message ('Checking Azure PowerShell Module...') -Severity 'Info'

        $VarAzPs = Get-Module -Name Az -ListAvailable -ErrorAction SilentlyContinue | Select-Object -First 1

        if ($null -ne $VarAzPs)
        {
            Write-Log -Message ('Azure PowerShell Module Version: {0}' -f $VarAzPs.Version) -Severity 'Success'
        }
        else
        {
            # Behaviour change (deliberate): do not Install-Module Az from inside
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
            Write-Log -Message ('Azure PowerShell Module not found.') -Severity 'Error'
            Write-Log -Message ('Install it manually before re-running this script. From an elevated PowerShell 7 prompt:') -Severity 'Error'
            Write-Log -Message ('  Install-Module -Name Az -Repository PSGallery -Force -AllowClobber -SkipPublisherCheck') -Severity 'Error'
            Write-Log -Message ('Or in Cloud Shell, the Az module is already preinstalled - if it is missing your shell environment is broken.') -Severity 'Error'
            throw 'Azure PowerShell (Az) module is required and was not found. See log above for installation instructions.'
        }

        # Probe that the Az module actually loads. Get-Module -ListAvailable above
        # only checks for the manifest on disk; it does not validate that the
        # bundled assemblies (MSAL, Azure.Core, etc.) are present and loadable.
        # Without this probe a broken install (manifest present, assemblies
        # missing - a real field-observed scenario) would let the script
        # continue all the way to the consumption phase before failing.
        try {
            Import-Module Az -ErrorAction Stop -DisableNameChecking | Out-Null
            $Global:AzPowerShellLoaded = $true
        } catch {
            Write-Log -Message ('Azure PowerShell module is present on disk but failed to load: {0}' -f $_.Exception.Message) -Severity 'Error'
            Write-Log -Message ('This usually indicates a broken install - the module manifest is present but its bundled assemblies (MSAL, Azure.Core, etc.) are missing or unloadable.') -Severity 'Error'
            Write-Log -Message ('Reinstall with: Install-Module -Name Az -Repository PSGallery -Force -AllowClobber -SkipPublisherCheck') -Severity 'Error'
            Write-Log -Message ('If the broken install was created by a previous run of this script, also run: Get-Module Az* -ListAvailable | Uninstall-Module -Force') -Severity 'Error'
            $Global:AzPowerShellLoaded = $false
            throw "Azure PowerShell (Az) module is broken on disk and cannot be loaded. See log above for remediation."
        }


        Write-Log -Message ('Checking ImportExcel Module...') -Severity 'Info'

        $VarExcel = Get-Module -Name ImportExcel -ListAvailable -ErrorAction SilentlyContinue | Select-Object -First 1
    
        if ($null -ne $VarExcel)
        {
            Write-Log -Message ('ImportExcel Module Version: {0}' -f $VarExcel.Version) -Severity 'Success'
        }
        else
        {
            # Behaviour change (deliberate): do not Install-Module ImportExcel
            # from inside this script. Same rationale as the Az module check
            # above - in-process module installs into a script that's already
            # importing the same module produce silent broken installs that
            # only surface much later. Fail loud here with a clear command.
            Write-Log -Message ('ImportExcel Module not found.') -Severity 'Error'
            Write-Log -Message ('Install it manually before re-running this script. From an elevated PowerShell 7 prompt:') -Severity 'Error'
            Write-Log -Message ('  Install-Module -Name ImportExcel -Force -AllowClobber -SkipPublisherCheck') -Severity 'Error'
            throw 'ImportExcel module is required and was not found. See log above for installation instructions.'
        }

        # Eagerly import ImportExcel so its bundled EPPlus assembly is loaded into the
        # current AppDomain before any code path constructs OfficeOpenXml types via
        # New-Object. -ListAvailable (above) only confirms the module exists; it does
        # not load it. Without this explicit import, scripts further down the call
        # chain (notably Extension/Summary.ps1, which is invoked in a child scope via
        # `& $SummaryPath ...`) fail with:
        #
        #   Cannot find type [OfficeOpenXml.ExcelPackage]: verify that the
        #   assembly containing this type is loaded.
        #
        # The failure surfaces especially on Windows PowerShell Desktop in
        # multi-subscription runs where the auto-import behavior across iterations
        # can lose the loaded assembly's reference. Importing once here is idempotent
        # and inexpensive.
        try {
            Import-Module ImportExcel -ErrorAction Stop -Force -DisableNameChecking | Out-Null
            if (-not ([System.Management.Automation.PSTypeName]'OfficeOpenXml.ExcelPackage').Type) {
                Write-Log -Message ('ImportExcel imported but OfficeOpenXml.ExcelPackage type is not loadable. The Excel report step will fail.') -Severity 'Error'
            }
        } catch {
            Write-Log -Message ('Import-Module ImportExcel failed: {0}' -f $_.Exception.Message) -Severity 'Error'
            throw
        }
    }
    
    function CheckPowerShell() 
    {
        Write-Log -Message ('Checking PowerShell...') -Severity 'Info'
    
        $Global:PlatformOS = 'PowerShell Desktop'
        $cloudShell = try{Get-CloudDrive}catch{}

        $Global:CurrentDateTime = (get-date -Format "yyyyMMddHHmmss")
        $Global:FolderName = $Global:ReportName + $CurrentDateTime
        
        if ($cloudShell) 
        {
            Write-Log -Message ('Identified Environment as Azure CloudShell') -Severity 'Success'
            $Global:PlatformOS = 'Azure CloudShell'
            $defaultOutputDir = "$HOME/InventoryReports/" + $Global:FolderName + "/"
        }
        elseif ($PSVersionTable.Platform -eq 'Unix') 
        {
            Write-Log -Message ('Identified Environment as PowerShell Unix') -Severity 'Success'
            $Global:PlatformOS = 'PowerShell Unix'
            $defaultOutputDir = "$HOME/InventoryReports/" + $Global:FolderName + "/"
        }
        else 
        {
            Write-Log -Message ('Identified Environment as PowerShell Desktop') -Severity 'Success'
            $Global:PlatformOS= 'PowerShell Desktop'
            $defaultOutputDir = "C:\InventoryReports\" + $Global:FolderName + "\"

            $psVersion = $PSVersionTable.PSVersion.Major
            Write-Log -Message ("PowerShell Version {0}" -f $psVersion) -Severity 'Info'
        
            if ($PSVersionTable.PSVersion.Major -lt 7) 
            {
                Write-Log -Message ("You must use Powershell 7 to run the inventory script.") -Severity 'Error'
                Write-Log -Message ("https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows?view=powershell-7.3") -Severity 'Error'
                Exit
            }
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
    
        $Global:DefaultPath = if($OutputDirectory) {$OutputDirectory} else {$defaultOutputDir}
    
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
        $CloudEnv = az cloud list | ConvertFrom-Json
        Write-Host "Azure Cloud Environment: " -NoNewline
    
        $CurrentCloudEnvName = $CloudEnv | Where-Object {$_.isActive -eq 'True'}
        Write-Host $CurrentCloudEnvName.name -ForegroundColor Green

        # Check if already authenticated
        $existingAccount = az account show --output json --only-show-errors 2>$null | ConvertFrom-Json
        if ($null -ne $existingAccount)
        {
            Write-Log -Message ("Already authenticated as: {0}" -f $existingAccount.user.name) -Severity 'Success'

            if (!$TenantID -or $existingAccount.tenantId -eq $TenantID)
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
                $azContext = Get-AzContext -ErrorAction SilentlyContinue
                $needsConnect = $null -eq $azContext -or
                                [string]::IsNullOrEmpty($azContext.Tenant.Id) -or
                                $azContext.Tenant.Id -ne $existingAccount.tenantId
                if ($needsConnect)
                {
                    Write-Log -Message ('Setting PowerShell Az context...') -Severity 'Info'
                    if($DeviceLogin.IsPresent)
                    {
                        Connect-AzAccount -UseDeviceAuthentication -Tenant $existingAccount.tenantId | Out-Null
                    }
                    else
                    {
                        Connect-AzAccount -Tenant $existingAccount.tenantId | Out-Null
                    }
                }

                $Global:Subscriptions = @(az account list --output json --only-show-errors | ConvertFrom-Json)
                if ($TenantID) { $Global:Subscriptions = @($Subscriptions | Where-Object { $_.tenantID -eq $TenantID }) }
                return
            }
            else
            {
                Write-Log -Message ("Current session is for tenant {0}, but requested tenant is {1}. Re-authenticating." -f $existingAccount.tenantId, $TenantID) -Severity 'Warning'
            }
        }
    
        if (!$TenantID) 
        {
            Write-Log -Message ('Tenant ID not specified. Use -TenantID parameter if you want to specify directly.') -Severity 'Warning'
            Write-Log -Message ('Authenticating Azure') -Severity 'Info'
    
            Write-Log -Message ('Clearing account cache') -Severity 'Info'

            if(!$RunAllSubs.IsPresent)
            {
                az account clear | Out-Null
            }
            
            $DebugPreference = "SilentlyContinue"

            if(!$RunAllSubs.IsPresent)
            {
                    Write-Log -Message ('Calling Login, the browser will open and prompt you to login.') -Severity 'Info'
                    if($DeviceLogin.IsPresent)
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
    
            $Tenants = az account list --query [].homeTenantId -o tsv --only-show-errors | Sort-Object -Unique

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
    
                [int]$SelectTenant = read-host "Select Tenant (Default 1)"
                $defaultTenant = --$SelectTenant
                $TenantID = $Tenants[$defaultTenant]

                if(!$RunAllSubs.IsPresent)
                {
                        if($DeviceLogin.IsPresent)
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

            if(!$RunAllSubs.IsPresent)
            {
                az account clear | Out-Null
            
              if (!$Appid) 
              {
                if($DeviceLogin.IsPresent)
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
                az login --service-principal -u $appid -p $secret -t $TenantID | Out-Null
                $SecureSecret = ConvertTo-SecureString $Secret -AsPlainText -Force
                $Credential = New-Object System.Management.Automation.PSCredential($Appid, $SecureSecret)
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
        
        Write-Log -Message ("Number of Subscriptions Found: {0}" -f $SubscriptionCount) -Severity 'Info'
        Write-Log -Message ("Checking report folder: {0}" -f $DefaultPath) -Severity 'Info'
        
        if ((Test-Path -Path $DefaultPath -PathType Container) -eq $false) 
        {
            New-Item -Type Directory -Force -Path $DefaultPath | Out-Null
        }
    }
    
    function ResourceInventoryLoop()
    {
        if(![string]::IsNullOrEmpty($ResourceGroup) -and [string]::IsNullOrEmpty($SubscriptionID))
        {
            Write-Log -Message ("Resource Group Name present, but missing Subscription ID.") -Severity 'Error'
            Write-Log -Message ("If using ResourceGroup parameter you must also put SubscriptionId") -Severity 'Error'
            Exit
        }

        if(![string]::IsNullOrEmpty($ResourceGroup))
        {
           $ResourceGroup = $ResourceGroup.ToLower()
        }

        if(![string]::IsNullOrEmpty($ResourceGroup) -and ![string]::IsNullOrEmpty($SubscriptionID))
        {
            Write-Log -Message ('Extracting Resources from Subscription: ' + $SubscriptionID + '. And from Resource Group: ' + $ResourceGroup) -Severity 'Success'

            $Subscri = $SubscriptionID

            $GraphQuery = "resources | where resourceGroup == '$ResourceGroup' and (isnull(properties.definition.actions) or strlen(properties.definition.actions) < 123000) | summarize count()"
            $EnvSize = az graph query -q $GraphQuery --subscriptions $Subscri --output json --only-show-errors | ConvertFrom-Json
            $EnvSizeNum = $EnvSize.data.'count_'

            if ($EnvSizeNum -ge 1) {
                $Loop = $EnvSizeNum / 1000
                $Loop = [math]::ceiling($Loop)
                $Looper = 0
                $Limit = 0

                while ($Looper -lt $Loop) {
                    $GraphQuery = "resources | where resourceGroup == '$ResourceGroup' and (isnull(properties.definition.actions) or strlen(properties.definition.actions) < 123000) | project id,name,type,tenantId,kind,location,resourceGroup,subscriptionId,managedBy,sku,plan,properties,identity,zones,extendedLocation,tags | order by id asc"
                    $Resource = (az graph query -q $GraphQuery --subscriptions $Subscri --skip $Limit --first 1000 --output json --only-show-errors).tolower() | ConvertFrom-Json

                    $Global:Resources += $Resource.data
                    Start-Sleep 2
                    $Looper ++
                    $Limit = $Limit + 1000
                }
            }
        }
        elseif([string]::IsNullOrEmpty($ResourceGroup) -and ![string]::IsNullOrEmpty($SubscriptionID))
        {
            Write-Log -Message ('Extracting Resources from Subscription: ' + $SubscriptionID) -Severity 'Success'

            $GraphQuery = "resources | where (isnull(properties.definition.actions) or strlen(properties.definition.actions) < 123000) | summarize count()"
            $EnvSize = az graph query -q $GraphQuery  --output json --subscriptions $SubscriptionID --only-show-errors | ConvertFrom-Json
            $EnvSizeNum = $EnvSize.data.'count_'

            if ($EnvSizeNum -ge 1) {
                $Loop = $EnvSizeNum / 1000
                $Loop = [math]::ceiling($Loop)
                $Looper = 0
                $Limit = 0

                while ($Looper -lt $Loop) {
                    $GraphQuery = "resources | where (isnull(properties.definition.actions) or strlen(properties.definition.actions) < 123000) | project id,name,type,tenantId,kind,location,resourceGroup,subscriptionId,managedBy,sku,plan,properties,identity,zones,extendedLocation,tags | order by id asc"
                    $Resource = (az graph query -q $GraphQuery --subscriptions $SubscriptionID --skip $Limit --first 1000 --output json --only-show-errors).tolower() | ConvertFrom-Json

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
            $EnvSize = az graph query -q  $GraphQuery --output json --only-show-errors | ConvertFrom-Json
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
                    $Resource = (az graph query -q $GraphQuery --skip $Limit --first 1000 --output json --only-show-errors).tolower() | ConvertFrom-Json
                    
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
        $AVDSize = az graph query -q "desktopvirtualizationresources | summarize count()" --output json --only-show-errors | ConvertFrom-Json
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
                $AVD = (az graph query -q $GraphQuery --skip $Limit --first 1000 --output json --only-show-errors).tolower() | ConvertFrom-Json
    
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

    if($Obfuscate.IsPresent)
    {
        # Lookup tables keyed by real subscription name / real RG name so the same
        # real value always maps to the same obfuscated value across resources.
        $subLookup = @{}
        $rgLookup  = @{}

        foreach ($resourceItem in $Global:Resources) 
        {
            $isNonProd = $resourceItem.name -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or $resourceItem.name -match '(^|-)([dts])-'
            $prefix = if ($isNonProd) { "nonprod_" } else { "prod_" }

            $obfuscatedID   = $prefix + [guid]::NewGuid().ToString()
            $obfuscatedName = $prefix + [guid]::NewGuid().ToString()

            # Preserve resource type signal in obfuscated name for server-side matching
            # VMs/Disks managed by services have identifiable patterns in their resource ID
            if ($resourceItem.id -match 'databricks') {
                $obfuscatedName = $prefix + 'databricks_' + [guid]::NewGuid().ToString()
            } elseif ($resourceItem.id -match '/resourcegroups/mc_') {
                $obfuscatedName = $prefix + 'aks_' + [guid]::NewGuid().ToString()
            } elseif ($resourceItem.id -match 'virtualmachinescalesets') {
                $obfuscatedName = $prefix + 'vmss_' + [guid]::NewGuid().ToString()
            }

            # Deterministic subscription obfuscation: derive prefix from sub name, not resource name
            $realSub = ($Global:Subscriptions | Where-Object { $_.id -eq $resourceItem.subscriptionId }).Name
            if ([string]::IsNullOrEmpty($realSub)) { $realSub = $resourceItem.subscriptionId }
            if (-not $subLookup.ContainsKey($realSub)) {
                $subPrefix = if ($realSub -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or $realSub -match '(^|-)([dts])-') { "nonprod_" } else { "prod_" }
                $subLookup[$realSub] = $subPrefix + [guid]::NewGuid().ToString()
            }
            $obfuscatedSubscription = $subLookup[$realSub]

            # Deterministic RG obfuscation: derive prefix from RG name, not resource name
            $realRG = $resourceItem.resourceGroup
            if ([string]::IsNullOrEmpty($realRG)) { $realRG = '__none__' }
            if (-not $rgLookup.ContainsKey($realRG)) {
                $rgPrefix = if ($realRG -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or $realRG -match '(^|-)([dts])-') { "nonprod_" } else { "prod_" }
                $rgLookup[$realRG] = $rgPrefix + [guid]::NewGuid().ToString()
            }
            $obfuscatedResourceGroup = $rgLookup[$realRG]

            $ResourceIdDictionary[$resourceItem.ID] = $obfuscatedID
            $ResourceNameDictionary[$resourceItem.ID] = $obfuscatedName
            $ResourceSubscriptionDictionary[$resourceItem.ID] = $obfuscatedSubscription
            $ResourceResourceGroupDictionary[$resourceItem.ID] = $obfuscatedResourceGroup

            if ($resourceItem.PSObject.Properties['tags']) { $resourceItem.tags = $null }
            if ($resourceItem.PSObject.Properties['Tags']) { $resourceItem.Tags = $null }
        }
    }
}

function ExecuteInventoryProcessing()
{
    function InitializeInventoryProcessing()
    {   
        $Global:ZipOutputFile = ($DefaultPath + $Global:ReportName + "_" + $CurrentDateTime + ".zip")
        $Global:File = ($DefaultPath + $Global:ReportName + "_" + $CurrentDateTime + ".xlsx")
        $Global:AllResourceFile = ($DefaultPath + "Full_" + $Global:ReportName + "_" + $CurrentDateTime + ".json")
        $Global:JsonFile = ($DefaultPath + "Inventory_"+ $Global:ReportName + "_" + $CurrentDateTime + ".json")
        $Global:MetricsJsonFile = ($DefaultPath + "Metrics_"+ $Global:ReportName + "_" + $CurrentDateTime + ".json")
        $Global:ConsumptionFile = ($DefaultPath + "Consumption_"+ $Global:ReportName + "_" + $CurrentDateTime + ".json")
        $Global:ConsumptionFileCsv = ($DefaultPath + "Consumption_"+ $Global:ReportName + "_" + $CurrentDateTime + ".csv")

        $Global:LogFile = ($DefaultPath + "Logs_"+ $Global:ReportName + "_" + $CurrentDateTime + ".json")
    

        Write-Log -Message ('Report Excel File: {0}' -f $File) -Severity 'Info'
    }

    function CreateMetricsJob()
    {
        Write-Log -Message ('Checking if Metrics Job Should be Run.') -Severity 'Info'

        if (!$SkipMetrics.IsPresent) 
        {
            Write-Log -Message ('Running Metrics Jobs') -Severity 'Success'

            if($PSScriptRoot -like '*\*')
            {
                $MetricPath = Get-ChildItem -Path ($PSScriptRoot + '\Extension\Metrics.ps1') -Recurse
            }
            else
            {
                $MetricPath = Get-ChildItem -Path ($PSScriptRoot + '/Extension/Metrics.ps1') -Recurse
            }

            $metricsFilePath = ($DefaultPath + "Metrics_"+ $Global:ReportName + "_" + $CurrentDateTime + "_")
            
            $Global:AzMetrics = New-Object PSObject
            $Global:AzMetrics | Add-Member -MemberType NoteProperty -Name Metrics -Value NotSet
            $Global:AzMetrics.Metrics = & $MetricPath -Subscriptions $Subscriptions -Resources $Resources -Task "Processing" -File $file -Metrics $null -TableStyle $null -ConcurrencyLimit $ConcurrencyLimit -FilePath $metricsFilePath -ResourceIdDictionary $(if ($Obfuscate.IsPresent) { $ResourceIdDictionary } else { $null }) -ResourceNameDictionary $(if ($Obfuscate.IsPresent) { $ResourceNameDictionary } else { $null }) -ResourceSubDictionary $(if ($Obfuscate.IsPresent) { $ResourceSubscriptionDictionary } else { $null }) -ResourceGroupDictionary $(if ($Obfuscate.IsPresent) { $ResourceResourceGroupDictionary } else { $null }) -Obfuscate $Obfuscate.IsPresent
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
            $directoryService = 'Analytics'
        }

        if ($moduleUrl -like '*Services/Compute*')
        {
            $directoryService = 'Compute'
        }

        if ($moduleUrl -like '*Services/Containers*')
        {
            $directoryService = 'Containers'
        }

        if ($moduleUrl -like '*Services/Data*')
        {
            $directoryService = 'Data'
        }

        if ($moduleUrl -like '*Services/Infrastructure*')
        {
            $directoryService = 'Infrastructure'
        }

        if ($moduleUrl -like '*Services/Integration*')
        {
            $directoryService = 'Integration'
        }

        if ($moduleUrl -like '*Services/Networking*')
        {
            $directoryService = 'Networking'
        }

        if ($moduleUrl -like '*Services/Storage*')
        {
            $directoryService = 'Storage'
        }

        return $directoryService
    }

    function CreateResourceJobs()
    {
        $Global:SmaResources = New-Object PSObject

        Write-Log -Message ('Starting Service Processing Jobs.') -Severity 'Info'
        

        if($PSScriptRoot -like '*\*')
        {
            $Modules = Get-ChildItem -Path ($PSScriptRoot +  '\Services\*.ps1') -Recurse
        }
        else
        {
            $Modules = Get-ChildItem -Path ($PSScriptRoot +  '/Services/*.ps1') -Recurse
        }

        $Resource = $Resources | Select-Object -First $Resources.count
        #$Resource = ($Resource | ConvertTo-Json -Depth 50)

        foreach ($Module in $Modules) 
        {
            $ModName = $Module.Name.Substring(0, $Module.Name.length - ".ps1".length)
            
            Write-Log -Message ("Service Processing: {0}" -f $ModName) -Severity 'Success'

            $result = & $Module -SCPath $SCPath -Sub $Subscriptions -Resources $Resource -Task "Processing" -File $file -SmaResources $null -TableStyle $null -Metrics $Global:AzMetrics -ResourceIdDictionary $(if ($Obfuscate.IsPresent) { $ResourceIdDictionary } else { $null })

            if($Obfuscate.IsPresent)
            {
                foreach ($resourceItem in $result) 
                {
                    $origID = $resourceItem.ID

                    if ($ResourceIdDictionary.ContainsKey($origID)) {
                        $obfuscatedID = $ResourceIdDictionary[$origID]
                        if ([string]::IsNullOrEmpty($obfuscatedID)) { $obfuscatedID = 'obfuscated_' + [guid]::NewGuid().ToString() }
                        $resourceItem.ID = $obfuscatedID
                    } else {
                        $prefix = if ($origID -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or $origID -match '(^|-)([dts])-') { "nonprod_" } else { "prod_" }
                        $fallback = $prefix + [guid]::NewGuid().ToString()
                        $ResourceIdDictionary[$origID] = $fallback
                        $resourceItem.ID = $fallback
                    }

                    $prefix = $resourceItem.ID.Split('_')[0] + '_'

                    if ($ResourceNameDictionary.ContainsKey($origID)) {
                        $obfuscatedName = $ResourceNameDictionary[$origID]
                        if ([string]::IsNullOrEmpty($obfuscatedName)) { $obfuscatedName = 'obfuscated_' + [guid]::NewGuid().ToString() }
                        $resourceItem.Name = $obfuscatedName
                    } else {
                        $fbName = $prefix + [guid]::NewGuid().ToString()
                        $ResourceNameDictionary[$origID] = $fbName
                        $resourceItem.Name = $fbName
                    }

                    if ($ResourceSubscriptionDictionary.ContainsKey($origID)) {
                        $obfuscatedSub = $ResourceSubscriptionDictionary[$origID]
                        if ([string]::IsNullOrEmpty($obfuscatedSub)) { $obfuscatedSub = 'obfuscated_' + [guid]::NewGuid().ToString() }
                        $resourceItem.Subscription = $obfuscatedSub
                    } else {
                        $fbSub = $prefix + [guid]::NewGuid().ToString()
                        $ResourceSubscriptionDictionary[$origID] = $fbSub
                        $resourceItem.Subscription = $fbSub
                    }

                    if ($ResourceResourceGroupDictionary.ContainsKey($origID)) {
                        $obfuscatedRG = $ResourceResourceGroupDictionary[$origID]
                        if ([string]::IsNullOrEmpty($obfuscatedRG)) { $obfuscatedRG = 'obfuscated_' + [guid]::NewGuid().ToString() }
                        $resourceItem.ResourceGroup = $obfuscatedRG
                    } else {
                        $fbRG = $prefix + [guid]::NewGuid().ToString()
                        $ResourceResourceGroupDictionary[$origID] = $fbRG
                        $resourceItem.ResourceGroup = $fbRG
                    }

                    if($resourceItem.ContainsKey('tags')) { $resourceItem.tags = $null }
                    if($resourceItem.ContainsKey('Tags') -and $null -ne $resourceItem.Tags)
                    {
                        $resourceItem.Tags = $null
                    }
                }
            }

            $Global:SmaResources | Add-Member -MemberType NoteProperty -Name $ModName -Value NotSet
            $Global:SmaResources.$ModName = $result

            $result = $null
            [System.GC]::Collect()
        }
    }

    function ProcessResourceResult()
    {
        Write-Log -Message ("Starting Reporting Phase.") -Severity 'Info'

        $Services = @()

        if($PSScriptRoot -like '*\*')
        {
            $Services = Get-ChildItem -Path ($PSScriptRoot + '\Services\*.ps1') -Recurse
        }
        else
        {
            $Services = Get-ChildItem -Path ($PSScriptRoot + '/Services/*.ps1') -Recurse
        }

        Write-Log -Message ('Services Found: ' + $Services.Count) -Severity 'Info'
        $Lops = $Services.count
        $ReportCounter = 0

        foreach ($Service in $Services) 
        {
            $c = (($ReportCounter / $Lops) * 100)
            $c = [math]::Round($c)
            
            Write-Log -Message ("Running Services: $Service") -Severity 'Info'
            $ProcessResults = & $Service.FullName -SCPath $PSScriptRoot -Sub $null -Resources $null -Task "Reporting" -File $file -SmaResources $Global:SmaResources -TableStyle $Global:TableStyle -Metrics $null -ResourceIdDictionary $(if ($Obfuscate.IsPresent) { $ResourceIdDictionary } else { $null })

            $ReportCounter++
        }

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

        $reportedStartTime = (Get-Date).AddDays(-31).Date.AddHours(0).AddMinutes(0).AddSeconds(0).DateTime
        $reportedEndTime = (Get-Date).AddDays(-1).Date.AddHours(0).AddMinutes(0).AddSeconds(0).DateTime

        foreach($sub in $Global:Subscriptions)
        {
            # Check if SubscriptionId is not null, not empty, and matches $sub.id
            if (![string]::IsNullOrEmpty($SubscriptionID))
            {
                if (![string]::IsNullOrEmpty($ResourceGroup))
                {
                    Write-Log -Message ("Cannot filter consumption by resource group." -f $sub.Name) -Severity 'Info'
                }

                if($SubscriptionID -ne $sub.Id)
                {
                    Write-Log -Message ("Skipping: {0}" -f $sub.Name) -Severity 'Info'
                    continue
                }
            }

            Set-AzContext -Subscription $sub.id | Out-Null
            Write-Log -Message ("Gathering Consumption for: {0}" -f $sub.Name) -Severity 'Info'

            # Track consumption health per-subscription so the wrapper can report
            # at the end whether consumption data was actually collected. Without
            # this, a broken Az module produces zero consumption records on every
            # subscription and the run still reports as successful - leaving an
            # empty consumption sheet in the output that nobody noticed until the
            # report was reviewed.
            $consumptionRecordsThisSub = 0
            $consumptionFailedThisSub = $false
            $consumptionFailureMessage = $null

            try {
                do
                {
                    $params = @{
                        ReportedStartTime      = $reportedStartTime
                        ReportedEndTime        = $reportedEndTime
                        AggregationGranularity = 'Daily'
                        ShowDetails            = $true
                    }

                    $params.ContinuationToken = $usageData.ContinuationToken

                    $usageData = Get-UsageAggregates @params -ErrorAction Stop
                    $usageDataExport = $usageData.UsageAggregations.Properties | Select-Object InstanceData, MeterCategory, MeterId, MeterName, MeterRegion, MeterSubCategory, Quantity, Unit, UsageStartTime, UsageEndTime

                    Write-Log -Message ("Records found: $($usageDataExport.Count)...") -Severity 'Info'
                    $consumptionRecordsThisSub += $usageDataExport.Count

                $newUsageDataExport = [System.Collections.ArrayList]::new()

                for($item = 0; $item -lt $usageDataExport.Count; $item++) 
                {
                    $instanceInfo = ($usageDataExport[$item].InstanceData.tolower() | ConvertFrom-Json)

                    if (![string]::IsNullOrEmpty($ResourceGroup))
                    {
                        if(!$instanceInfo.'Microsoft.Resources'.resourceUri.toLower().Contains("/" + $ResourceGroup.toLower() + "/"))
                        {
                            continue;
                        }
                    }
                    
                    $usageDataExport[$item] | Add-Member -MemberType NoteProperty -Name ResourceId -Value NotSet
                    $usageDataExport[$item] | Add-Member -MemberType NoteProperty -Name ResourceLocation -Value NotSet

                    $usageDataExport[$item] | Add-Member -MemberType NoteProperty -Name ConsumptionMeter -Value NotSet
                    $usageDataExport[$item] | Add-Member -MemberType NoteProperty -Name ReservationId -Value NotSet
                    $usageDataExport[$item] | Add-Member -MemberType NoteProperty -Name ReservationOrderId -Value NotSet

        
                    $usageDataExport[$item].ResourceId = $instanceInfo.'Microsoft.Resources'.resourceUri
                    $usageDataExport[$item].ResourceLocation = $instanceInfo.'Microsoft.Resources'.location
                    $usageDataExport[$item].ConsumptionMeter = $instanceInfo.'Microsoft.Resources'.additionalInfo.ConsumptionMeter
                    $usageDataExport[$item].ReservationId = $instanceInfo.'Microsoft.Resources'.additionalInfo.ReservationId
                    $usageDataExport[$item].ReservationOrderId = $instanceInfo.'Microsoft.Resources'.additionalInfo.ReservationOrderId
                    

                    $instanceObject = [PSCustomObject]@{}

                    $additionalInfoInstance = [PSCustomObject]@{
                        ResourceUri = $instanceInfo.'Microsoft.Resources'.resourceUri
                        Location = $instanceInfo.'Microsoft.Resources'.location
                        additionalInfo = [PSCustomObject]@{
                            ConsumptionMeter = if ($null -eq $instanceInfo.'Microsoft.Resources'.additionalInfo.ConsumptionMeter) { "" } else { $instanceInfo.'Microsoft.Resources'.additionalInfo.ConsumptionMeter }
                            vCores = 0
                            VCPUs = 0
                            ServiceType = ""
                            ResourceCategory = ""
                        }
                    }
                    
                    $instanceObject | Add-Member -MemberType NoteProperty -Name "Microsoft.Resources" -Value $additionalInfoInstance

                    if($Obfuscate.IsPresent)
                    {
                        if (-not $ResourceIdDictionary.ContainsKey($usageDataExport[$item].ResourceId)) 
                        {
                            $prefix = if ($usageDataExport[$item].ResourceId -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or $usageDataExport[$item].ResourceId -match '(^|/|-)([dts])-') { "nonprod_" } else { "prod_" }
                            $resId = $usageDataExport[$item].ResourceId
                            $obfuscatedID = if ($resId -match 'databricks') { $prefix + 'databricks_' + [guid]::NewGuid().ToString() }
                                elseif ($resId -match '/resourcegroups/mc_') { $prefix + 'aks_' + [guid]::NewGuid().ToString() }
                                elseif ($resId -match 'virtualmachinescalesets') { $prefix + 'vmss_' + [guid]::NewGuid().ToString() }
                                else { $prefix + [guid]::NewGuid().ToString() }
                            $ResourceIdDictionary[$usageDataExport[$item].ResourceId] = $obfuscatedID
                            $usageDataExport[$item].ResourceId = $obfuscatedID
                            $instanceObject.'Microsoft.Resources'.resourceUri = $obfuscatedID
                        } 
                        else 
                        {
                            $obfuscatedID = $ResourceIdDictionary[$usageDataExport[$item].ResourceId]
                            $usageDataExport[$item].ResourceId = $obfuscatedID
                            $instanceObject.'Microsoft.Resources'.resourceUri = $obfuscatedID
                        }

                        # Obfuscate reservation identifiers (customer purchasing fingerprints)
                        if (![string]::IsNullOrEmpty($usageDataExport[$item].ReservationId)) {
                            $usageDataExport[$item].ReservationId = 'obfuscated'
                        }
                        if (![string]::IsNullOrEmpty($usageDataExport[$item].ReservationOrderId)) {
                            $usageDataExport[$item].ReservationOrderId = 'obfuscated'
                        }
                    }

                    $usageDataExport[$item].InstanceData = $instanceObject | ConvertTo-Json -Compress

                    $newUsageDataExport.Add($usageDataExport[$item]) | Out-Null
                }

                #$newUsageDataExport | Export-Csv $Global:ConsumptionFileCsv -Encoding utf-8 -Append

                $newUsageDataExport | Select-Object InstanceData, MeterCategory, MeterId, MeterName, MeterRegion, MeterSubCategory, Quantity, Unit, UsageStartTime, UsageEndTime, ResourceId, ResourceLocation, ConsumptionMeter, ReservationId, ReservationOrderId | Export-Csv $Global:ConsumptionFileCsv -Encoding utf8 -Append -NoTypeInformation
                
                } while ('ContinuationToken' -in $usageData.psobject.properties.name -and $usageData.ContinuationToken)
            } catch {
                # The most common cause is a broken Az module install (manifest
                # present, MSAL/Azure.Core assemblies missing). The script-level
                # Import-Module probe should have caught that, but we also catch
                # here defensively so a transient ARM throttling event or a
                # subscription the identity cannot bill against does not abort
                # the entire run for other subscriptions.
                $consumptionFailedThisSub = $true
                $consumptionFailureMessage = $_.Exception.Message
                Write-Log -Message ("Consumption query failed for {0}: {1}" -f $sub.Name, $_.Exception.Message) -Severity 'Warning'
            }

            # Aggregate per-sub consumption health into globals the wrapper reads
            # at the end of the run. Globals here live in the wrapper's scope
            # because ResourceInventory.ps1 is invoked via `& <path>`.
            if ($null -eq $Global:ConsumptionRecordCount) { $Global:ConsumptionRecordCount = 0 }
            if ($null -eq $Global:ConsumptionFailedSubs)  { $Global:ConsumptionFailedSubs  = @() }
            $Global:ConsumptionRecordCount += $consumptionRecordsThisSub
            if ($consumptionFailedThisSub) {
                $Global:ConsumptionFailedSubs += [pscustomobject]@{
                    Name    = $sub.Name
                    Id      = $sub.Id
                    Message = $consumptionFailureMessage
                }
            }
        }

        $DebugPreference = "Continue"
    }

    InitializeInventoryProcessing
    CreateMetricsJob
    CreateResourceJobs   
    ProcessMetricsResult
    ProcessResourceResult

    if(!$SkipConsumption.IsPresent)
    {
       GetResorceConsumption
       #ProcessResourceConsumption
    }
}

function FinalizeOutputs
{
    function ProcessSummary()
    {
        Write-Log -Message ('Creating Summary Report') -Severity 'Info'
        Write-Log -Message ('Starting Summary Report Processing Job.') -Severity 'Info'

        if($PSScriptRoot -like '*\*')
        {
            $SummaryPath = Get-ChildItem -Path ($PSScriptRoot + '\Extension\Summary.ps1') -Recurse
        }
        else
        {
            $SummaryPath = Get-ChildItem -Path ($PSScriptRoot + '/Extension/Summary.ps1') -Recurse
        }

        $ChartsRun = & $SummaryPath -File $file -TableStyle $TableStyle -PlatOS $PlatformOS -Subscriptions $Subscriptions -Resources $Resources -ExtractionRunTime $Runtime -ReportingRunTime $ReportingRunTime -RunLite $false -Version $Global:Version
    }

    ProcessSummary
}

$Global:PowerShellTranscriptFile = ($DefaultPath + "Transcript_Log_"+ $Global:ReportName + "_" + $CurrentDateTime + ".txt")
Start-Transcript -Path $Global:PowerShellTranscriptFile -UseMinimalHeader

# Setup and Inventory Gathering
$Global:Runtime = Measure-Command -Expression {
    Variables
    RunInventorySetup
}

# Execution and processing of inventory
$Global:ReportingRunTime = Measure-Command -Expression {
    ExecuteInventoryProcessing
}

Stop-Transcript

# Prepare the summary and outputs
FinalizeOutputs

Write-Log -Message ("Compressing Resources Output: {0}" -f $Global:ZipOutputFile) -Severity 'Info'

if($Obfuscate.IsPresent)
{
    $Global:DictionaryFile = ($DefaultPath + "ObfuscationDictionary_"+ $Global:ReportName + "_" + $CurrentDateTime + ".json")
    
    $dictionary = @{
        GeneratedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        ResourceIdMap = @{}
        ResourceNameMap = @{}
        SubscriptionMap = @{}
        ResourceGroupMap = @{}
    }

    foreach ($key in $ResourceIdDictionary.Keys) {
        $dictionary.ResourceIdMap[$ResourceIdDictionary[$key]] = $key
    }
    foreach ($key in $ResourceNameDictionary.Keys) {
        $dictionary.ResourceNameMap[$ResourceNameDictionary[$key]] = $key
    }
    foreach ($key in $ResourceSubscriptionDictionary.Keys) {
        $dictionary.SubscriptionMap[$ResourceSubscriptionDictionary[$key]] = $key
    }
    foreach ($key in $ResourceResourceGroupDictionary.Keys) {
        $dictionary.ResourceGroupMap[$ResourceResourceGroupDictionary[$key]] = $key
    }

    $dictionary | ConvertTo-Json -depth 5 | Out-File $Global:DictionaryFile -Encoding utf8
    Write-Log -Message ("Obfuscation dictionary saved locally: {0}" -f $Global:DictionaryFile) -Severity 'Success'
    Write-Log -Message ("") -Severity 'Info'
    Write-Log -Message ("=== OBFUSCATION NOTICE ===") -Severity 'Warning'
    Write-Log -Message ("The following files remain LOCAL and should NOT be shared:") -Severity 'Warning'
    Write-Log -Message ("  - Dictionary: {0}" -f $Global:DictionaryFile) -Severity 'Warning'
    Write-Log -Message ("  - Transcript: {0}" -f $Global:PowerShellTranscriptFile) -Severity 'Warning'
    Write-Log -Message ("") -Severity 'Info'
    Write-Log -Message ("The ZIP file is safe to share with AWS or partners.") -Severity 'Success'
    Write-Log -Message ("Partners may ask about obfuscated names (e.g. 'prod_a1b2c3d4-...'). Use the dictionary file to look up the real resource name and respond.") -Severity 'Info'
    Write-Log -Message ("Delete the dictionary and transcript when no longer needed for security.") -Severity 'Warning'
}

if($EnableLogs.IsPresent)
{
    $Global:Logging | ConvertTo-Json -depth 5 -compress | Out-File $Global:LogFile
} 

if($SkipMetrics.IsPresent)
{
    @{ Metrics = @() } | ConvertTo-Json -depth 5 -compress | Out-File $Global:MetricsJsonFile -Encoding utf8
}

$consumptionCreated = Test-Path -Path $Global:ConsumptionFileCsv

if($SkipConsumption.IsPresent -or !$consumptionCreated)
{
    "InstanceData,MeterCategory,MeterId,MeterName,MeterRegion,MeterSubCategory,Quantity,Unit,UsageStartTime,UsageEndTime,ResourceId,ResourceLocation,ConsumptionMeter,ReservationId,ReservationOrderId" | Out-File $Global:ConsumptionFileCsv -Encoding utf8
}

$jsonWildCard = $DefaultPath + "*.json"

if($Obfuscate.IsPresent)
{
    # Exclude dictionary and transcript from zip - use specific json files only
    $jsonFiles = Get-ChildItem -Path $DefaultPath -Filter "*.json" | Where-Object { $_.Name -notlike "ObfuscationDictionary_*" } | Select-Object -ExpandProperty FullName
    $compressionOutput = @{
        Path = @($Global:File, $Global:ConsumptionFileCsv) + $jsonFiles
        CompressionLevel = 'Fastest'
        DestinationPath = $Global:ZipOutputFile
    }
    Write-Log -Message ('Obfuscate mode: transcript log excluded from zip (kept locally for debug)') -Severity 'Info'
}
else
{
    $compressionOutput = @{
        Path = $Global:File, $Global:ConsumptionFileCsv, $Global:PowerShellTranscriptFile, $jsonWildCard
        CompressionLevel = 'Fastest'
        DestinationPath = $Global:ZipOutputFile
    }
}

try 
{
    Compress-Archive @compressionOutput
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
