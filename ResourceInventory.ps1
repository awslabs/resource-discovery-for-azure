param ($TenantID,
        $Appid,
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$', ErrorMessage = 'Invalid SubscriptionID; must be a GUID')]
        [string]$SubscriptionID,
        [securestring]$Secret, 
        [ValidatePattern('^[A-Za-z0-9._()-]{1,90}$', ErrorMessage = 'Invalid resource group name; must match ^[A-Za-z0-9._()-]{1,90}$')]
        [string]$ResourceGroup, 
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


if ($Debug.IsPresent) {$DebugPreference = 'Continue'}

if ($Debug.IsPresent) {$ErrorActionPreference = "Continue" }Else {$ErrorActionPreference = "silentlycontinue" }

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

    if ($Obfuscate.IsPresent) {
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
            $versionJson = (New-Object System.Net.WebClient).DownloadString($RawRepo + '/Version.json') | ConvertFrom-Json
        }
        catch
        {
            Write-Log -Message ("Could not reach {0}/Version.json to check for an update: {1}" -f $RawRepo, $_.Exception.Message) -Severity 'Warning'
            Write-Log -Message ('Continuing with local version {0}. If you are on a managed network, this is expected.' -f $Global:Version) -Severity 'Info'
            return
        }

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

        # Load ONLY the Az submodules this tool actually uses, not the full `Az`
        # rollup. Importing `Az` pulls in ~80 submodules (hundreds of DLLs plus
        # their format/type data) and stalls for 20-40s on a fresh box with no
        # output - which looks like a hang right after "Checking Azure PowerShell
        # Module...". The tool only calls cmdlets from these four:
        #   Az.Accounts - Connect/Get/Set-AzContext, Get-AzSubscription,
        #                 Get-AzAccessToken, Save-/Import-AzContext
        #   Az.Compute  - Get-AzComputeResourceSku
        #   Az.Monitor  - Get-AzMetric
        #   Az.Billing  - Get-UsageAggregates
        # Anything not listed still auto-loads its submodule on first use (the
        # full rollup is installed, so every submodule is on PSModulePath), so
        # this is purely a startup speed-up and cannot cause "command not found".
        #
        # This import doubles as the broken-install probe. Get-Module
        # -ListAvailable above only checks the manifest on disk; importing
        # Az.Accounts actually loads the bundled assemblies (MSAL, Azure.Core),
        # so a half-installed module (manifest present, assemblies missing - a
        # real field-observed scenario) fails loudly HERE instead of silently
        # producing zero data at the consumption phase.
        try {
            foreach ($AzSubModule in @('Az.Accounts', 'Az.Compute', 'Az.Monitor', 'Az.Billing'))
            {
                Write-Log -Message ('Loading {0}...' -f $AzSubModule) -Severity 'Info'
                Import-Module $AzSubModule -ErrorAction Stop -DisableNameChecking | Out-Null
            }
            $Global:AzPowerShellLoaded = $true
        } catch {
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
        Write-Log -Message ('Checking PowerShell...') -Severity 'Info'
    
        $Global:PlatformOS = 'PowerShell Desktop'
        $cloudShell = try{Get-CloudDrive}catch{}

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
        $procDiscriminator = ('{0:x4}' -f ($PID -band 0xffff))
        $Global:CurrentDateTime = ((get-date -Format "yyyyMMddHHmmssfff") + $procDiscriminator)
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
                # Authenticate the az CLI without putting the secret on the command
                # line (it would otherwise appear in the process list and transcript).
                # Pipe the plaintext to --password-stdin; the plaintext lives only in
                # this local variable for the duration of the call.
                $unsecuredSecret = [System.Net.NetworkCredential]::new('', $Secret).Password
                $unsecuredSecret | az login --service-principal -u $appid --tenant $TenantID --password-stdin --only-show-errors | Out-Null
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
            $EnvSize = Invoke-AzGraphQuerySafe -Query $GraphQuery -ExtraArgs @('--subscriptions', $Subscri)
            $EnvSizeNum = $EnvSize.data.'count_'

            if ($EnvSizeNum -ge 1) {
                $Loop = $EnvSizeNum / 1000
                $Loop = [math]::ceiling($Loop)
                $Looper = 0
                $Limit = 0

                while ($Looper -lt $Loop) {
                    $GraphQuery = "resources | where resourceGroup == '$ResourceGroup' and (isnull(properties.definition.actions) or strlen(properties.definition.actions) < 123000) | project id,name,type,tenantId,kind,location,resourceGroup,subscriptionId,managedBy,sku,plan,properties,identity,zones,extendedLocation,tags | order by id asc"
                    $Resource = Invoke-AzGraphQuerySafe -Query $GraphQuery -ExtraArgs @('--subscriptions', $Subscri, '--skip', $Limit, '--first', 1000) -Lowercase

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
            $EnvSize = Invoke-AzGraphQuerySafe -Query $GraphQuery -ExtraArgs @('--subscriptions', $SubscriptionID)
            $EnvSizeNum = $EnvSize.data.'count_'

            if ($EnvSizeNum -ge 1) {
                $Loop = $EnvSizeNum / 1000
                $Loop = [math]::ceiling($Loop)
                $Looper = 0
                $Limit = 0

                while ($Looper -lt $Loop) {
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
        $Global:JsonFile = ($DefaultPath + "Inventory_"+ $Global:ReportName + "_" + $CurrentDateTime + ".json")
        $Global:MetricsJsonFile = ($DefaultPath + "Metrics_"+ $Global:ReportName + "_" + $CurrentDateTime + ".json")
        $Global:ConsumptionFileCsv = ($DefaultPath + "Consumption_"+ $Global:ReportName + "_" + $CurrentDateTime + ".csv")

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
        $tokenOk = {
            $ctx = $null
            try { $ctx = Get-AzContext -ErrorAction Stop } catch { return $false }
            if ($null -eq $ctx -or $null -eq $ctx.Account) { return $false }
            try
            {
                $tok = Get-AzAccessToken -ErrorAction Stop -WarningAction SilentlyContinue
                return ($null -ne $tok -and -not [string]::IsNullOrWhiteSpace($tok.Token))
            }
            catch { return $false }
        }

        if (& $tokenOk) { return $true }

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

        return (& $tokenOk)
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
                $metricsSkipMsg = 'Metrics phase skipped: no usable Azure context/token after one reconnect attempt.'
                $affectedSubs = @(
                    if (![string]::IsNullOrEmpty($SubscriptionID)) {
                        $Global:Subscriptions | Where-Object { $_.id -eq $SubscriptionID }
                    } else {
                        $Global:Subscriptions
                    }
                )
                if ($affectedSubs.Count -eq 0) {
                    # Fallback when the subscription list is unavailable: still
                    # record one entry so the failure is never silent.
                    $idLabel = if (![string]::IsNullOrEmpty($SubscriptionID)) { $SubscriptionID } else { '(unknown)' }
                    $Global:MetricsFailedSubs += [pscustomobject]@{ Name = '(subscription)'; Id = $idLabel; Message = $metricsSkipMsg }
                } else {
                    foreach ($asub in $affectedSubs) {
                        $Global:MetricsFailedSubs += [pscustomobject]@{ Name = $asub.Name; Id = $asub.Id; Message = $metricsSkipMsg }
                    }
                }
                return
            }

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
            $Global:AzMetrics.Metrics = & $MetricPath -Subscriptions $Subscriptions -Resources $Resources -Task "Processing" -ConcurrencyLimit $ConcurrencyLimit -FilePath $metricsFilePath -ResourceIdDictionary $(if ($Obfuscate.IsPresent) { $ResourceIdDictionary } else { $null }) -ResourceNameDictionary $(if ($Obfuscate.IsPresent) { $ResourceNameDictionary } else { $null }) -ResourceSubDictionary $(if ($Obfuscate.IsPresent) { $ResourceSubscriptionDictionary } else { $null }) -ResourceGroupDictionary $(if ($Obfuscate.IsPresent) { $ResourceResourceGroupDictionary } else { $null }) -Obfuscate $Obfuscate.IsPresent -MetricsLookbackDays $MetricsLookbackDays
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

        foreach ($Module in $Modules) 
        {
            $ModName = $Module.Name.Substring(0, $Module.Name.length - ".ps1".length)
            
            Write-Log -Message ("Service Processing: {0}" -f $ModName) -Severity 'Success'

            try
            {
                $result = & $Module -Sub $Subscriptions -Resources $Resource -Task "Processing" -ResourceIdDictionary $(if ($Obfuscate.IsPresent) { $ResourceIdDictionary } else { $null })
                $ConsecutiveCollectorFailures = 0
            }
            catch
            {
                $ConsecutiveCollectorFailures++

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
                $result = @()
            }

            if($Obfuscate.IsPresent)
            {
                foreach ($resourceItem in $result) 
                {
                    $origID = $resourceItem.ID

                    # A null/empty ID would throw on the dictionary key ASSIGNMENT
                    # in the else branches below (Dictionary[string,string] rejects
                    # a null key with "the array index evaluated to null"). Give the
                    # row a deterministic-within-run fallback and skip the dictionary
                    # lookups so one malformed collector row cannot abort processing.
                    if ([string]::IsNullOrEmpty($origID))
                    {
                        $fallback = 'obfuscated_' + [guid]::NewGuid().ToString()
                        $resourceItem.ID = $fallback
                        $resourceItem.Name = $fallback
                        $resourceItem.Subscription = $fallback
                        $resourceItem.ResourceGroup = $fallback
                        # Still scrub tags before skipping - a malformed null-ID row
                        # must not carry real tag values into the obfuscated output
                        # just because it bypassed the dictionary path below.
                        if($resourceItem.ContainsKey('tags')) { $resourceItem.tags = $null }
                        if($resourceItem.ContainsKey('Tags')) { $resourceItem.Tags = $null }
                        continue
                    }

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

                    # Collector 'Tags' output is an array of { Name, Value }. Keep the
                    # KEY (Name) verbatim and obfuscate the VALUE deterministically via
                    # $Global:TagValueDictionary: the same real value always maps to the
                    # same prod_/nonprod_ token, so the obfuscated report can still group
                    # and correlate by tag value without exposing it. Prefix is derived
                    # from the value so an environment-type signal survives.
                    if($resourceItem.ContainsKey('Tags') -and $null -ne $resourceItem.Tags)
                    {
                        foreach ($tag in $resourceItem.Tags)
                        {
                            if ($null -ne $tag -and -not [string]::IsNullOrEmpty([string]$tag.Value))
                            {
                                $realTagValue = [string]$tag.Value
                                if (-not $Global:TagValueDictionary.ContainsKey($realTagValue))
                                {
                                    $tagPrefix = if ($realTagValue -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or $realTagValue -match '(^|-)([dts])-') { 'nonprod_' } else { 'prod_' }
                                    $Global:TagValueDictionary[$realTagValue] = $tagPrefix + [guid]::NewGuid().ToString()
                                }
                                $tag.Value = $Global:TagValueDictionary[$realTagValue]
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
            $Global:SmaResources.$ModName = @($result)

            $result = $null
            [System.GC]::Collect()
        }
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

        $reportedStartTime = (Get-Date).AddDays(-31).Date.AddHours(0).AddMinutes(0).AddSeconds(0).DateTime
        $reportedEndTime = (Get-Date).AddDays(-1).Date.AddHours(0).AddMinutes(0).AddSeconds(0).DateTime

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
            if ($null -eq $Global:ConsumptionFailedSubs)  { $Global:ConsumptionFailedSubs  = @() }
            $Global:ConsumptionFailedSubs += [pscustomobject]@{
                Name    = '(all subscriptions)'
                Id      = '(auth)'
                Message = 'Consumption phase skipped: no usable Azure context/token after one reconnect attempt.'
            }
            return
        }

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
                        # Pick a prefix (prod_/nonprod_) based on the original
                        # resourceUri before any obfuscation, so we cannot match
                        # against an already-obfuscated value below.
                        $prefix = if ($usageDataExport[$item].ResourceId -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or $usageDataExport[$item].ResourceId -match '(^|/|-)([dts])-') { 'nonprod_' } else { 'prod_' }

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
                        $rawUri = $instanceObject.'Microsoft.Resources'.resourceUri
                        $obfuscatedUri = $rawUri

                        # Per-run caches keyed by REAL value, so the same real sub
                        # id / RG / resource name always maps to the same obfuscated
                        # token within a run (deterministic, per the obfuscation
                        # rules in steering). Kept separate from $ResourceIdDictionary
                        # because that dictionary's public contract (the
                        # ObfuscationDictionary file) maps obfuscated full Azure IDs
                        # to their real values - we don't want to pollute it with
                        # per-name-segment entries from consumption ARM-path rebuilds.
                        if (-not $script:ConsumptionSubCache)  { $script:ConsumptionSubCache  = @{} }
                        if (-not $script:ConsumptionRgCache)   { $script:ConsumptionRgCache   = @{} }
                        if (-not $script:ConsumptionNameCache) { $script:ConsumptionNameCache = @{} }

                        if ($rawUri -match '^/subscriptions/([^/]+)(/resourcegroups/([^/]+))?(/providers/(.+))?$')
                        {
                            $realSub  = $matches[1]
                            $realRg   = $matches[3]
                            $realProv = $matches[5]   # e.g. 'microsoft.compute/<type>/<name>[/<subtype>/<name2>]'

                            $obfSub = if ($script:ConsumptionSubCache.ContainsKey($realSub)) { $script:ConsumptionSubCache[$realSub] } else {
                                $v = $prefix + 'sub_' + [guid]::NewGuid().ToString()
                                $script:ConsumptionSubCache[$realSub] = $v; $v
                            }

                            $rebuiltUri = '/subscriptions/' + $obfSub

                            if (-not [string]::IsNullOrEmpty($realRg))
                            {
                                $obfRg = if ($script:ConsumptionRgCache.ContainsKey($realRg)) { $script:ConsumptionRgCache[$realRg] } else {
                                    # Preserve the AKS-managed-RG marker so the dashboard can
                                    # still detect AKS-managed resources after obfuscation.
                                    $isMc = $realRg -match '^mc_'
                                    $tag  = if ($isMc) { 'mc_' } else { '' }
                                    $v = $prefix + 'rg_' + $tag + [guid]::NewGuid().ToString()
                                    $script:ConsumptionRgCache[$realRg] = $v; $v
                                }
                                $rebuiltUri += '/resourcegroups/' + $obfRg
                            }

                            if (-not [string]::IsNullOrEmpty($realProv))
                            {
                                # $realProv = "<rp>/<type>[/<name>[/<subtype>/<name2>...]]"
                                # Keep the resource provider (segment 0) and every
                                # type segment so categorisation works; obfuscate
                                # only the name segments. After the provider, the
                                # path alternates type-name-type-name, so within
                                # the provider-relative index space TYPE segments
                                # are at indices 1,3,5,... (i.e. odd) and NAME
                                # segments are at indices 2,4,6,... (i.e. even).
                                $provParts = $realProv -split '/'
                                $rebuilt   = @()
                                for ($pi = 0; $pi -lt $provParts.Count; $pi++)
                                {
                                    $part = $provParts[$pi]
                                    $isNameSegment = ($pi -ge 2 -and ($pi % 2 -eq 0))
                                    if ($isNameSegment -and -not [string]::IsNullOrEmpty($part) -and $part -ne '$system')
                                    {
                                        $obfName = if ($script:ConsumptionNameCache.ContainsKey($part)) { $script:ConsumptionNameCache[$part] } else {
                                            $v = $prefix + [guid]::NewGuid().ToString()
                                            $script:ConsumptionNameCache[$part] = $v; $v
                                        }
                                        $rebuilt += $obfName
                                    }
                                    else
                                    {
                                        $rebuilt += $part
                                    }
                                }
                                $rebuiltUri += '/providers/' + ($rebuilt -join '/')
                            }

                            $obfuscatedUri = $rebuiltUri
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
                            if ([string]::IsNullOrEmpty($rawUri))
                            {
                                $obfuscatedUri = 'obfuscated'
                            }
                            else
                            {
                                if (-not $script:ConsumptionNameCache.ContainsKey($rawUri))
                                {
                                    $script:ConsumptionNameCache[$rawUri] = $prefix + [guid]::NewGuid().ToString()
                                }
                                $obfuscatedUri = $script:ConsumptionNameCache[$rawUri]
                            }
                        }

                        $usageDataExport[$item].ResourceId = $obfuscatedUri
                        $instanceObject.'Microsoft.Resources'.resourceUri = $obfuscatedUri

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

        # Tenant ID is shown in the report header for reference, but it is a
        # real Azure identifier and must NOT appear in an obfuscated (shareable)
        # report. Pass it only when NOT obfuscating; the obfuscated HTML then
        # carries no tenant GUID, consistent with the four obfuscation
        # dictionaries that scrub every other identifier.
        $reportTenantId = if ($Obfuscate.IsPresent) { $null } else { $TenantID }
        $reportTitle = ('Azure Resource Inventory - {0}' -f $Global:ReportName)

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
            $ChartsRun = & $SummaryPath -JsonFile $Global:JsonFile -HtmlFile $Global:HtmlFile -Title $reportTitle -TenantId $reportTenantId -Version $Global:Version -ExtractionRunTime $Runtime -ReportingRunTime $ReportingRunTime -PlatOS $PlatformOS -ConsumptionFile $Global:ConsumptionFileCsv
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
if (-not $RunAllSubs.IsPresent) {

    # Honor -OutputDirectory when the caller passed one. CheckPowerShell will
    # re-validate -OutputDirectory itself further down and is the authoritative
    # gate; we Resolve-Path here defensively so a relative path is checked at
    # the right location, and fall back to the raw value if it does not yet
    # resolve (the write probe below will surface the underlying error).
    $PreFlightInventoryRoot = if ($OutputDirectory) {
        try { (Resolve-Path $OutputDirectory -ErrorAction Stop).Path }
        catch { $OutputDirectory }
    } elseif ($PSVersionTable.Platform -eq 'Unix') {
        "$HOME/InventoryReports"
    } else {
        "C:\InventoryReports"
    }
    if (-not (Test-Path -Path $PreFlightInventoryRoot -PathType Container)) {
        try { New-Item -Path $PreFlightInventoryRoot -ItemType Directory -Force | Out-Null }
        catch { Write-Verbose ("PreFlightInventoryRoot create failed at {0}: {1}" -f $PreFlightInventoryRoot, $_.Exception.Message) }
    }

    Write-Host "Running pre-flight checks..." -ForegroundColor Cyan

    # 1. Cloud Shell mount detection. See Run-AllSubscriptions.ps1 for the rationale.
    if (Get-Command Get-CloudDrive -ErrorAction SilentlyContinue) {
        $CheckCloudDrive = Get-CloudDrive 3>$null 2>$null
        if ($null -eq $CheckCloudDrive) {
            Write-Host ""
            Write-Host "WARNING: Cloud Shell detected, but no storage account is mounted." -ForegroundColor Yellow
            Write-Host "  Outputs in $PreFlightInventoryRoot will be lost when this Cloud Shell session ends." -ForegroundColor Yellow
            Write-Host "  To persist outputs, mount a storage account first:" -ForegroundColor Yellow
            Write-Host "    clouddrive mount" -ForegroundColor Yellow
            Write-Host "  Continuing in ephemeral mode - download the report ZIP from $PreFlightInventoryRoot before closing the shell." -ForegroundColor Yellow
            Write-Host ""
        } else {
            Write-Host ("Cloud Shell drive mounted: {0}" -f $CheckCloudDrive.Name) -ForegroundColor Green
        }
    }

    # 2. Disk space probe.
    try {
        $rootItem = Get-Item -Path $PreFlightInventoryRoot -ErrorAction Stop
        $drive = $rootItem.PSDrive
        if ($null -ne $drive -and $null -ne $drive.Free) {
            $freeMB = [math]::Round($drive.Free / 1MB, 0)
            if ($freeMB -lt 100) {
                throw ("Pre-flight: free disk space at {0} is {1} MB; the script needs at least 100 MB to start. Free space and re-run." -f $PreFlightInventoryRoot, $freeMB)
            } elseif ($freeMB -lt 500) {
                Write-Host ("WARNING: Free disk space at {0} is {1} MB. A large multi-subscription run can exceed this. Consider freeing space before running." -f $PreFlightInventoryRoot, $freeMB) -ForegroundColor Yellow
            } else {
                Write-Host ("Free disk space: {0:N0} MB at {1}" -f $freeMB, $PreFlightInventoryRoot) -ForegroundColor Green
            }
        }
    } catch {
        if ($_.Exception.Message -match '^Pre-flight:') { throw }
        Write-Host ("WARNING: Could not determine free disk space at {0}: {1}" -f $PreFlightInventoryRoot, $_.Exception.Message) -ForegroundColor Yellow
    }

    # 3. Write probe.
    $probePath = Join-Path $PreFlightInventoryRoot (".write-probe-{0}.tmp" -f ([guid]::NewGuid()))
    try {
        Set-Content -Path $probePath -Value 'preflight write probe' -Encoding utf8 -ErrorAction Stop
        $probeRead = Get-Content -Path $probePath -Raw -ErrorAction Stop
        if ($probeRead -notmatch 'preflight write probe') {
            throw "Write probe content mismatch (read back '$probeRead')"
        }
        Remove-Item -Path $probePath -Force -ErrorAction Stop
        Write-Host ("Write probe: OK ({0})" -f $PreFlightInventoryRoot) -ForegroundColor Green
    } catch {
        try { if (Test-Path $probePath) { Remove-Item -Path $probePath -Force -ErrorAction SilentlyContinue } }
        catch { Write-Verbose ("Probe cleanup failed at {0}: {1}" -f $probePath, $_.Exception.Message) }
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

    # Populate token -> real subscription name. The dictionary key ($key) is the
    # real resource Id, which embeds the subscription GUID; resolve that GUID to
    # its display name via the already-loaded $Global:Subscriptions. Uses only
    # in-memory data (no extra Azure calls); skips entries whose name cannot be
    # resolved so the map only ever holds genuine names.
    foreach ($key in $ResourceSubscriptionDictionary.Keys) {
        $subToken = $ResourceSubscriptionDictionary[$key]
        if ($dictionary.SubscriptionNameMap.ContainsKey($subToken)) { continue }
        $subGuid = if ($key -match '(?i)/subscriptions/([^/]+)') { $Matches[1] } else { $null }
        if (-not [string]::IsNullOrEmpty($subGuid)) {
            $subName = ($Global:Subscriptions | Where-Object { $_.id -eq $subGuid } | Select-Object -First 1).name
            if (-not [string]::IsNullOrEmpty($subName)) {
                $dictionary.SubscriptionNameMap[$subToken] = $subName
            }
        }
    }

    # Invert the tag-value dictionary (real value -> token) into TagMap
    # (token -> real value) so the unmask helper can reverse tag values.
    if ($null -ne $Global:TagValueDictionary) {
        foreach ($realValue in $Global:TagValueDictionary.Keys) {
            $dictionary.TagMap[$Global:TagValueDictionary[$realValue]] = $realValue
        }
    }

    # Invert the free-text dictionary (real value -> token) into FreeTextMap
    # (token -> real value) so Reveal-Obfuscation.ps1 can restore free-form
    # fields (Description, FriendlyName, CreatedBy, etc.).
    if ($null -ne $Global:FreeTextDictionary) {
        foreach ($realValue in $Global:FreeTextDictionary.Keys) {
            $dictionary.FreeTextMap[$Global:FreeTextDictionary[$realValue]] = $realValue
        }
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

if($SkipMetrics.IsPresent)
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
    $metricsPattern = ('Metrics_{0}_{1}*.json' -f $Global:ReportName, $CurrentDateTime)
    $metricsAny = @(Get-ChildItem -Path $DefaultPath -Filter $metricsPattern -ErrorAction SilentlyContinue)
    if ($metricsAny.Count -eq 0)
    {
        @{ Metrics = @() } | ConvertTo-Json -depth 5 -compress | Out-File $Global:MetricsJsonFile -Encoding utf8
    }
}

$consumptionCreated = Test-Path -Path $Global:ConsumptionFileCsv

# A subscription with zero billing records produces an empty (0-byte) CSV
# rather than a header-only one, because Export-Csv -Append with no input
# objects writes nothing. Treat 0-byte files as "not created" so the safety
# net below emits the header. Without this, downstream consumers that parse
# the CSV by header (dashboard ingestion, the Pester tests) fail on the
# empty file and reject the entire per-sub bundle.
$consumptionEmpty = $false
if ($consumptionCreated)
{
    try
    {
        $consumptionEmpty = ((Get-Item -Path $Global:ConsumptionFileCsv -ErrorAction Stop).Length -eq 0)
    }
    catch
    {
        # Treat unreadable as not-created so the header gets written; safer than
        # leaving an unparseable file in the bundle.
        $consumptionEmpty = $true
    }
}

if($SkipConsumption.IsPresent -or !$consumptionCreated -or $consumptionEmpty)
{
    "InstanceData,MeterCategory,MeterId,MeterName,MeterRegion,MeterSubCategory,Quantity,Unit,UsageStartTime,UsageEndTime,ResourceId,ResourceLocation,ConsumptionMeter,ReservationId,ReservationOrderId" | Out-File $Global:ConsumptionFileCsv -Encoding utf8
}

$jsonWildCard = $DefaultPath + "*.json"

if($Obfuscate.IsPresent)
{
    # Exclude the obfuscation dictionary and transcript from the obfuscated zip.
    # The dictionary maps obfuscated values back to REAL identifiers, and the
    # transcript captures the raw Write-Log stream (auth UPN, tenant GUID,
    # subscription names) that the obfuscation layer never touches. The
    # transcript is excluded separately below (it is not a .json). Use a
    # specific json file list so only the safe, obfuscated json files ship.
    $jsonFiles = Get-ChildItem -Path $DefaultPath -Filter "*.json" | Where-Object { $_.Name -notlike "ObfuscationDictionary_*" -and $_.Name -notlike "Full_*" } | Select-Object -ExpandProperty FullName
    $compressionOutput = @{
        Path = @($Global:HtmlFile, $Global:ConsumptionFileCsv) + $jsonFiles
        CompressionLevel = 'Fastest'
        DestinationPath = $Global:ZipOutputFile
    }
    Write-Log -Message ('Obfuscate mode: transcript log excluded from zip (kept locally for debug)') -Severity 'Info'
}
else
{
    # Exclude the PowerShell transcript from the default zip too. It captures
    # the authenticated account UPN, tenant/subscription IDs, and local paths
    # from Start-Transcript onward - data customers don't expect in the shared
    # bundle. Keep it on disk locally for debugging (same as the obfuscate path).
    $compressionOutput = @{
        Path = $Global:HtmlFile, $Global:ConsumptionFileCsv, $jsonWildCard
        CompressionLevel = 'Fastest'
        DestinationPath = $Global:ZipOutputFile
    }
    Write-Log -Message ('Transcript log excluded from zip (kept locally for debug)') -Severity 'Info'
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
