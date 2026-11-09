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
    [switch]$UseManagedIdentity,
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

$AzModulesFunctionsFile = Join-Path $PSScriptRoot 'Functions/AzModules.Functions.ps1'
if (-not (Test-Path -Path $AzModulesFunctionsFile -PathType Leaf))
{
    Write-Host "ERROR: Required functions file not found: $AzModulesFunctionsFile" -ForegroundColor Red
    Write-Host "Ensure the 'Functions' folder ships alongside this script." -ForegroundColor Yellow
    exit 1
}
. $AzModulesFunctionsFile

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
        $RequiredAzSubModules = @('Az.Accounts', 'Az.Compute', 'Az.Monitor', 'Az.Billing')

        # An earlier run in this session loaded the modules. Skip the checks
        # only when all four are still loaded (one can have been removed
        # since, with Remove-Module) and the lowest loaded Az.Accounts is
        # still the supported version: an older build of the tool may have
        # loaded an older one. Get-Module without -ListAvailable reads the
        # session only, so this stays cheap. Otherwise the full check below
        # runs: it loads what is missing, or stops the run.
        if ($Global:AzPowerShellLoaded)
        {
            $NotLoaded = @($RequiredAzSubModules | Where-Object { $null -eq (Get-Module -Name $_ -ErrorAction SilentlyContinue | Select-Object -First 1) })
            $LoadedAzAccounts = @(Get-Module -Name Az.Accounts -ErrorAction SilentlyContinue |
                    Where-Object { $_ -and $_.Version } |
                    ForEach-Object { [version]$_.Version } |
                    Sort-Object) | Select-Object -First 1
            if ($NotLoaded.Count -eq 0 -and $LoadedAzAccounts -and $LoadedAzAccounts -ge (Get-RdaAzAccountsMinimumVersion))
            {
                return
            }
        }

        Write-Log -Message ('Checking Azure PowerShell Module...') -Severity 'Info'

        $MissingAzSubModules = @($RequiredAzSubModules | Where-Object { $null -eq (Get-Module -Name $_ -ListAvailable -ErrorAction SilentlyContinue | Select-Object -First 1) })

        if ($MissingAzSubModules.Count -gt 0)
        {
            Write-Log -Message ('Required Azure PowerShell module(s) not found: {0}' -f ($MissingAzSubModules -join ', ')) -Severity 'Error'
            Write-Log -Message ('This tool needs only these Az submodules. Install them manually before re-running. From an elevated PowerShell 7 prompt:') -Severity 'Error'
            Write-Log -Message ('  Install-Module -Name {0} -Repository PSGallery -Force -AllowClobber -SkipPublisherCheck' -f ($RequiredAzSubModules -join ',')) -Severity 'Error'
            Write-Log -Message ('Or install the full rollup (larger, slower first import): Install-Module -Name Az -Repository PSGallery -Force -AllowClobber -SkipPublisherCheck') -Severity 'Error'
            Write-Log -Message ('Or in Cloud Shell, the Az module is already preinstalled - if it is missing your shell environment is broken.') -Severity 'Error'
            # exit, not throw: the production 'SilentlyContinue' preference
            # suppresses a bare throw and the run would go on to sign in and
            # collect without the modules its collectors need.
            exit 1
        }

        # Az.Accounts must be the supported version or newer, on disk and in
        # this session (Functions/AzModules.Functions.ps1 holds the number).
        # The printed command is the way out: once it has run, the next run
        # passes this check.
        # -SubModule: Az modules an earlier run in this session loaded can
        # hold an older Az.Accounts there, and the copy of a submodule that
        # would load can pin one in its manifest; the check names the one to
        # update, before anything is loaded.
        $AzAccountsCheck = Test-RdaAzAccountsVersion -SubModule $RequiredAzSubModules
        if ($AzAccountsCheck.Status -ne 'Ok')
        {
            foreach ($Line in $AzAccountsCheck.Messages)
            {
                Write-Log -Message $Line -Severity 'Error'
            }
            # exit, not throw, for the same reason as above.
            exit 1
        }
        Write-Log -Message ('Azure PowerShell modules present (Az.Accounts {0}, {1} or newer needed); required: {2}' -f $AzAccountsCheck.Installed, $AzAccountsCheck.Required, ($RequiredAzSubModules -join ', ')) -Severity 'Success'

        try
        {
            # Az.Accounts first, with -MinimumVersion: the check above saw the
            # highest copy on disk, but a plain import takes the first copy in
            # PSModulePath order, which can be an older one.
            Write-Log -Message 'Loading Az.Accounts...' -Severity 'Info'
            Import-Module Az.Accounts -MinimumVersion (Get-RdaAzAccountsMinimumVersion) -ErrorAction Stop -DisableNameChecking | Out-Null
            foreach ($AzSubModule in @($RequiredAzSubModules | Where-Object { $_ -ne 'Az.Accounts' }))
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
            # exit, not throw, for the same reason as above.
            exit 1
        }

        # Check the copy that actually loaded. The import above takes 5.5.4 or
        # newer, but Az.Compute, Az.Monitor and Az.Billing load after it: one
        # whose manifest asks for an exact older Az.Accounts (RequiredVersion)
        # makes PowerShell load that older copy next to the new one, and the
        # check reads the lowest loaded copy. A new session alone loads the
        # same pair again, so -SubModule makes the advice name the submodule
        # and the command that updates it. The printed advice is the way out;
        # nothing retries.
        $AzAccountsCheck = Test-RdaAzAccountsVersion -SubModule $RequiredAzSubModules
        if ($AzAccountsCheck.Status -ne 'Ok')
        {
            foreach ($Line in $AzAccountsCheck.Messages)
            {
                Write-Log -Message $Line -Severity 'Error'
            }
            $Global:AzPowerShellLoaded = $false
            # exit, not throw, for the same reason as above.
            exit 1
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
                Exit
            }
        }

        $Global:DefaultPath = if ($OutputDirectory) { $OutputDirectory } else { $DefaultOutputDir }

        # Every environment signs in through LoginSession. In Cloud Shell the
        # sign-in Cloud Shell made is a cached sign-in like any other (rule 2),
        # so -Appid, -UseManagedIdentity, -DeviceLogin and -TenantID are
        # honoured and its token and tenant are checked there too.
        if ($platformOS -in 'Azure CloudShell', 'PowerShell Unix', 'PowerShell Desktop')
        {
            LoginSession
        }
    }

    function LoginSession()
    {
        if (-not $Global:RdaSessionInitialized)
        {
            # The cloud of the Az PowerShell sign-in (Connect-AzAccount signs
            # in to AzureCloud unless it is told another environment).
            $CloudEnvName = try { (Get-AzContext -ErrorAction Stop).Environment.Name } catch { $null }
            Write-Host "Azure Cloud Environment: " -NoNewline
            if ($CloudEnvName) { Write-Host $CloudEnvName -ForegroundColor Green }
            else { Write-Host 'AzureCloud (not signed in yet)' -ForegroundColor Green }
        }

        # Direct run (not -RunAllSubs), Azure Cloud Shell included. The tool
        # signs in with Az PowerShell only, by three rules:
        #  1. -Appid/-Secret/-TenantID: always the service principal, even
        #     when a user is already signed in. If that sign-in fails, or the
        #     context is then not that service principal, the run stops with
        #     exit 1; it never goes on as whoever was signed in before. The
        #     same holds for -UseManagedIdentity and the machine's identity.
        #  2. Otherwise a cached sign-in that can acquire a token for the
        #     target tenant silently is reused, with no prompt: as it is when
        #     it is on that tenant, switched to it for this process when it is
        #     on another one. Cloud Shell's own sign-in is such a sign-in.
        #  3. Otherwise sign in once (device code with -DeviceLogin; a
        #     session with no console stops with exit 1 instead of opening a
        #     browser), then check the token; if the sign-in fails or the
        #     token still fails the run stops with exit 1 instead of prompting
        #     again or collecting an empty inventory. The next run starts from
        #     the same checks, so it cannot loop either.
        # Whatever the rule, the run goes on only when the context is on the
        # target tenant (Invoke-AzRestMethod and Get-AzSubscription use the
        # context's tenant) and the tenant lists at least one subscription.
        # With nothing usable and no -TenantID, the sign-in is made without a
        # tenant and the tenant is chosen afterwards. A usable sign-in is never
        # disconnected; a tenant switch applies to this process only, and so
        # do service principal and managed identity sign-ins.
        if (!$RunAllSubs.IsPresent)
        {
            function Stop-SignIn([string]$Message, [string]$Advice)
            {
                Write-Log -Message $Message -Severity 'Error'
                Write-Log -Message $Advice -Severity 'Error'
                exit 1
            }

            function Stop-UnusableSignIn([string]$Tenant, [string]$Advice)
            {
                Stop-SignIn -Message ("Az PowerShell: sign-in to tenant {0} did not give a usable token; stopping instead of prompting again." -f $Tenant) -Advice $Advice
            }

            function Get-UserSignInAdvice([string]$Tenant)
            {
                $Command = if ($Tenant) { "Connect-AzAccount -Tenant $Tenant" } else { 'Connect-AzAccount' }
                return ("Run '{0}' yourself, complete any MFA or Conditional Access prompt, then re-run (or pass -DeviceLogin, or -UseManagedIdentity on an Azure VM)." -f $Command)
            }

            # The one sign-in of a run. A failed sign-in stops the run: it is
            # not tried again, and the run does not go on with whatever was
            # signed in before it.
            function Invoke-AzPsSignIn([hashtable]$SignInArgs, [string]$What, [string]$Advice)
            {
                try { Connect-AzAccount @SignInArgs -ErrorAction Stop | Out-Null }
                catch { Stop-SignIn -Message ("Az PowerShell: {0} failed: {1}" -f $What, $_.Exception.Message) -Advice $Advice }
            }

            function Invoke-AzPsUserSignIn([string]$Tenant)
            {
                $Advice = Get-UserSignInAdvice -Tenant $Tenant
                if (-not $DeviceLogin.IsPresent -and -not (Test-RdaInteractiveSession))
                {
                    Stop-SignIn -Message 'Az PowerShell: no usable sign-in, and this session has no console to sign in from (non-interactive); stopping instead of opening a browser.' -Advice ('Sign in before the run, or pass -Appid/-Secret/-TenantID, -UseManagedIdentity on an Azure VM, or -DeviceLogin. ' + $Advice)
                }
                $SignInArgs = @{}
                if ($Tenant) { $SignInArgs.Tenant = $Tenant }
                if ($DeviceLogin.IsPresent) { $SignInArgs.UseDeviceAuthentication = $true }
                # The reconnect before metrics and consumption reads this: a
                # run prompts a person at most once.
                $script:RdaUserSignInMade = $true
                Invoke-AzPsSignIn -SignInArgs $SignInArgs -What 'sign-in' -Advice $Advice
            }

            # The tenant id (a GUID) of tenant $Tenant, given as an id or a
            # domain: a domain is resolved through the token Az PowerShell
            # acquires for it.
            function Get-AzPsTenantId([string]$Tenant)
            {
                $Id = [guid]::Empty
                if ([guid]::TryParse($Tenant, [ref]$Id)) { return $Tenant }
                try { return [string](Get-AzAccessToken -TenantId $Tenant -ErrorAction Stop -WarningAction SilentlyContinue).TenantId }
                catch { return $null }
            }

            function Test-AzPsContextOnTenant([string]$Tenant)
            {
                $Current = Get-AzPsSignedInTenant
                $Expected = Get-AzPsTenantId -Tenant $Tenant
                return ([bool]$Current -and [bool]$Expected -and $Current -eq $Expected)
            }

            # A token for the tenant does not prove the context is on it, and
            # the collectors use the context. Returns the tenant id.
            function Confirm-AzPsContextTenant([string]$Tenant, [string]$Advice)
            {
                if (-not (Test-AzPsContextOnTenant -Tenant $Tenant))
                {
                    $Current = Get-AzPsSignedInTenant
                    Stop-SignIn -Message ("Az PowerShell: the context is on tenant {0}, not on tenant {1}; stopping instead of collecting another tenant." -f $(if ($Current) { $Current } else { '(none)' }), $Tenant) -Advice $Advice
                }
                return (Get-AzPsSignedInTenant)
            }

            # After a service principal or managed identity sign-in the
            # context must be that identity, never a cached user.
            function Confirm-AzPsAccount([string]$Type, [string]$Id, [string]$What, [string]$Advice)
            {
                $Account = try { (Get-AzContext -ErrorAction Stop).Account } catch { $null }
                if ($null -eq $Account -or [string]$Account.Type -ne $Type -or ($Id -and [string]$Account.Id -ne $Id))
                {
                    Stop-SignIn -Message ("Az PowerShell: after the {0} the context is not that identity; stopping instead of running as another account." -f $What) -Advice $Advice
                }
            }

            # The run's subscriptions. A direct run with none stops instead of
            # writing an empty report.
            function Set-RdaRunSubscriptions([string]$Tenant)
            {
                $script:RdaRunTenant = $Tenant
                $Global:Subscriptions = @(Get-RdaTenantSubscriptions -Tenant $Tenant)
                if ($Global:Subscriptions.Count -eq 0)
                {
                    Stop-SignIn -Message ("Az PowerShell: tenant {0} lists no subscriptions for this sign-in; stopping instead of writing an empty report." -f $Tenant) -Advice 'Check that the signed-in identity has at least Reader on a subscription of the tenant, and that -TenantID names the right tenant, then re-run.'
                }
            }

            if ($Appid)
            {
                if ($UseManagedIdentity.IsPresent)
                {
                    Write-Log -Message ('-UseManagedIdentity is ignored because -Appid is given; signing in as the Service Principal.') -Severity 'Warning'
                }
                if (!$Secret -or !$TenantID)
                {
                    Write-Log -Message ("You are trying to use Service Principal Authentication Method in a wrong way.") -Severity 'Error'
                    Write-Log -Message ("It's Mandatory to specify Application ID, Secret and Tenant ID in Azure Resource Inventory") -Severity 'Error'
                    Write-Log -Message (".\ResourceInventory.ps1 -appid <SP AppID> -secret <SP Secret> -tenant <TenantID>") -Severity 'Error'
                    exit 1
                }

                Write-Log -Message ("Using Service Principal Authentication Method") -Severity 'Success'
                $SpAdvice = 'Check the -Appid, -Secret and -TenantID values and that the Service Principal can sign in to the tenant, then re-run.'
                # The secret stays a SecureString inside the credential.
                $Credential = New-Object System.Management.Automation.PSCredential($Appid, $Secret)
                # -Scope Process: not saved as the default context, so a later
                # run without -Appid does not reuse the service principal.
                Invoke-AzPsSignIn -SignInArgs @{ ServicePrincipal = $true; Credential = $Credential; Tenant = $TenantID; Scope = 'Process' } -What 'service principal sign-in' -Advice $SpAdvice
                Confirm-AzPsAccount -Type 'ServicePrincipal' -Id $Appid -What 'service principal sign-in' -Advice $SpAdvice
                if (!(Test-AzPsTokenSilent -Tenant $TenantID)) { Stop-UnusableSignIn -Tenant $TenantID -Advice $SpAdvice }

                Set-RdaRunSubscriptions -Tenant (Confirm-AzPsContextTenant -Tenant $TenantID -Advice $SpAdvice)
                return
            }

            if ($UseManagedIdentity.IsPresent)
            {
                Write-Log -Message ('Using Managed Identity Authentication Method') -Severity 'Info'
                $MiAdvice = 'Check that this machine has a managed identity with access to the tenant (and pass -TenantID for a specific tenant), then re-run.'
                # -Scope Process, as for the service principal.
                $MiArgs = @{ Identity = $true; Scope = 'Process' }
                if ($TenantID) { $MiArgs.Tenant = $TenantID }
                Invoke-AzPsSignIn -SignInArgs $MiArgs -What 'managed identity sign-in' -Advice $MiAdvice
                Confirm-AzPsAccount -Type 'ManagedService' -What 'managed identity sign-in' -Advice $MiAdvice

                $TargetTenant = if ($TenantID) { $TenantID } else { Get-AzPsSignedInTenant }
                if (!$TargetTenant) { Stop-UnusableSignIn -Tenant '(managed identity)' -Advice $MiAdvice }
                if (!(Test-AzPsTokenSilent -Tenant $TargetTenant)) { Stop-UnusableSignIn -Tenant $TargetTenant -Advice $MiAdvice }

                Set-RdaRunSubscriptions -Tenant (Confirm-AzPsContextTenant -Tenant $TargetTenant -Advice $MiAdvice)
                return
            }

            $PsTenant = Get-AzPsSignedInTenant
            $PsTokenOk = if ($PsTenant) { Test-AzPsTokenSilent -Tenant $PsTenant } else { $false }

            # Without -TenantID the target is the tenant of the cached sign-in,
            # usable or not: one that cannot acquire a token is signed in to
            # that same tenant again below.
            $TargetTenant = $null
            if ($TenantID) { $TargetTenant = $TenantID }
            elseif ($PsTenant) { $TargetTenant = $PsTenant }

            if (!$TargetTenant)
            {
                # Nothing usable and no -TenantID: sign in once without a
                # tenant, choose the tenant, then check the token on it.
                Write-Log -Message ('Tenant ID not specified. Use -TenantID parameter if you want to specify directly.') -Severity 'Warning'
                Write-Log -Message ('Authenticating Azure') -Severity 'Info'

                # No Az debug lines during the sign-in; afterwards the caller's
                # setting again (Continue only under -Debug).
                $SavedDebugPreference = $DebugPreference
                $DebugPreference = "SilentlyContinue"
                if ($DeviceLogin.IsPresent) { Write-Log -Message ('Calling Login, using device login.') -Severity 'Info' }
                else { Write-Log -Message ('Calling Login, the browser will open and prompt you to login.') -Severity 'Info' }

                try { Invoke-AzPsUserSignIn }
                finally { $DebugPreference = $SavedDebugPreference }

                # The tenants the sign-in reaches, by the tenant each
                # subscription is accessed through (TenantId, not
                # HomeTenantId: a subscription delegated with Azure Lighthouse
                # has the customer's tenant as its home), plus the tenant the
                # sign-in is on.
                $Tenants = @(@(@(Get-AzSubscription -WarningAction SilentlyContinue).TenantId) + @(Get-AzPsSignedInTenant) | Where-Object { $_ } | Sort-Object -Unique)

                Write-Log -Message ('Checking number of Tenants') -Severity 'Info'

                if ($Tenants.Count -eq 0)
                {
                    Stop-UnusableSignIn -Tenant '(none given)' -Advice (Get-UserSignInAdvice)
                }
                elseif ($Tenants.Count -eq 1)
                {
                    Write-Log -Message ('You have privileges only in One Tenant') -Severity 'Success'
                    $TargetTenant = $Tenants[0]
                }
                else
                {
                    Write-Log -Message ('Select the the Azure Tenant ID that you want to connect: ') -Severity 'Warning'

                    $SequenceID = 1
                    foreach ($ListedTenant in $Tenants)
                    {
                        write-host "$SequenceID)  $ListedTenant"
                        $SequenceID ++
                    }

                    if (-not (Test-RdaInteractiveSession))
                    {
                        $TargetTenant = $Tenants[0]
                        Write-Log -Message ("Non-interactive session with multiple tenants and no -TenantID: defaulting to the first tenant ({0}). Pass -TenantID to choose explicitly." -f $TargetTenant) -Severity 'Warning'
                    }
                    else
                    {
                        # Asked at most twice; an answer that is not a number
                        # of the list stops the run.
                        for ($Ask = 1; $Ask -le 2 -and !$TargetTenant; $Ask++)
                        {
                            $Answer = [string](Read-Host "Select Tenant (Default 1)")
                            $Number = 0
                            if ([string]::IsNullOrWhiteSpace($Answer)) { $Number = 1 }
                            elseif (-not [int]::TryParse($Answer.Trim(), [ref]$Number)) { $Number = 0 }
                            if ($Number -ge 1 -and $Number -le $Tenants.Count) { $TargetTenant = $Tenants[$Number - 1] }
                            else { Write-Log -Message ("'{0}' is not a number from 1 to {1}." -f $Answer, $Tenants.Count) -Severity 'Warning' }
                        }
                        if (!$TargetTenant)
                        {
                            Stop-SignIn -Message 'No tenant was chosen; stopping.' -Advice 'Re-run with -TenantID <tenant> to choose the tenant directly.'
                        }
                    }
                }

                # Point Az PowerShell at the chosen tenant (no new sign-in); this
                # process only, so the user's saved context is left alone.
                if ((Get-AzPsSignedInTenant) -ne $TargetTenant)
                {
                    Set-AzContext -Tenant $TargetTenant -Scope Process | Out-Null
                }

                $Advice = Get-UserSignInAdvice -Tenant $TargetTenant
                if (!(Test-AzPsTokenSilent -Tenant $TargetTenant)) { Stop-UnusableSignIn -Tenant $TargetTenant -Advice $Advice }
                $TargetTenant = Confirm-AzPsContextTenant -Tenant $TargetTenant -Advice $Advice

                Write-Log -Message ("Extracting from Tenant $TargetTenant") -Severity 'Info'
                Write-Log -Message ("Extracting Subscriptions") -Severity 'Info'

                Set-RdaRunSubscriptions -Tenant $TargetTenant
                return
            }

            $Reused = $false
            if ($PsTokenOk -and $PsTenant -eq $TargetTenant)
            {
                Write-Log -Message ("Az PowerShell: reusing existing sign-in for tenant {0}" -f $TargetTenant) -Severity 'Success'
                $Reused = $true
            }
            elseif ($PsTenant -and $PsTenant -ne $TargetTenant -and (Test-AzPsTokenSilent -Tenant $TargetTenant))
            {
                # The cached account reaches the target tenant without a
                # prompt: switch this process to it instead of signing in.
                Write-Log -Message ("Az PowerShell: signed in to tenant {0}; switching this process to {1} with the same sign-in." -f $PsTenant, $TargetTenant) -Severity 'Info'
                Set-AzContext -Tenant $TargetTenant -Scope Process | Out-Null
                $Reused = Test-AzPsContextOnTenant -Tenant $TargetTenant
            }

            if (-not $Reused)
            {
                if ($null -eq $PsTenant) { Write-Log -Message ('Az PowerShell: not signed in; signing in.') -Severity 'Info' }
                elseif ($PsTenant -ne $TargetTenant) { Write-Log -Message ("Az PowerShell: signed in to tenant {0}; signing in to {1}." -f $PsTenant, $TargetTenant) -Severity 'Warning' }
                else { Write-Log -Message ("Az PowerShell: session for tenant {0} cannot acquire a token silently; signing in again." -f $TargetTenant) -Severity 'Warning' }

                Invoke-AzPsUserSignIn -Tenant $TargetTenant

                if (!(Test-AzPsTokenSilent -Tenant $TargetTenant))
                {
                    Stop-UnusableSignIn -Tenant $TargetTenant -Advice (Get-UserSignInAdvice -Tenant $TargetTenant)
                }
            }

            Set-RdaRunSubscriptions -Tenant (Confirm-AzPsContextTenant -Tenant $TargetTenant -Advice (Get-UserSignInAdvice -Tenant $TargetTenant))
            return
        }

        # -RunAllSubs: Run-AllSubscriptions.ps1 has already signed Az
        # PowerShell in to -TenantID before it starts this script, so that
        # sign-in is used as it is: no sign-in here.
        $Context = try { Get-AzContext -ErrorAction Stop } catch { $null }
        $ContextTenant = if ($null -ne $Context -and $null -ne $Context.Account) { [string]$Context.Tenant.Id } else { $null }
        if ($ContextTenant -and -not $Global:RdaSessionInitialized)
        {
            Write-Log -Message ("Already authenticated as: {0}" -f $Context.Account.Id) -Severity 'Success'
        }

        $TargetTenant = if ($TenantID) { $TenantID } else { $ContextTenant }
        if ($TargetTenant -and $ContextTenant -and $ContextTenant -ne $TargetTenant)
        {
            Write-Log -Message ("Current session is for tenant {0}, but requested tenant is {1}. Switching this process to it." -f $ContextTenant, $TargetTenant) -Severity 'Warning'
            Set-AzContext -Tenant $TargetTenant -Scope Process | Out-Null
        }

        if (!$TargetTenant)
        {
            Write-Log -Message ('Tenant ID not specified. Use -TenantID parameter if you want to specify directly.') -Severity 'Warning'
            $Tenants = @((Get-AzSubscription -WarningAction SilentlyContinue).HomeTenantId | Where-Object { $_ } | Sort-Object -Unique)
            if ($Tenants.Count -gt 0)
            {
                $TargetTenant = $Tenants[0]
                if ($Tenants.Count -gt 1) { Write-Log -Message ("Non-interactive session with multiple tenants and no -TenantID: defaulting to the first tenant ({0}). Pass -TenantID to choose explicitly." -f $TargetTenant) -Severity 'Warning' }
                Write-Log -Message ("Extracting from Tenant $TargetTenant") -Severity 'Info'
            }
        }

        if (!$TargetTenant)
        {
            $Global:Subscriptions = @()
            return
        }

        # The wrapper starts this script once per subscription in the same
        # process; the tenant's subscription list is read once.
        $Cache = $Global:RdaTenantSubscriptionCache
        if ($null -ne $Cache -and $Cache.Tenant -eq $TargetTenant)
        {
            $Global:Subscriptions = @($Cache.Subscriptions)
            return
        }
        $Global:Subscriptions = @(Get-RdaTenantSubscriptions -Tenant $TargetTenant)
        if ($Global:Subscriptions.Count -gt 0)
        {
            $Global:RdaTenantSubscriptionCache = @{ Tenant = $TargetTenant; Subscriptions = @($Global:Subscriptions) }
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

    # The resources are sorted by their id in lower case. Resource Graph sorts
    # text by its exact characters, upper case first, and the case of the
    # resource group in an id can change between two reads of the same resource
    # (a virtual machine that is starting or stopping switches several times).
    # Sorted by the id as returned, such a resource moves between pages while
    # they are read: it is listed twice or not at all, and the resource at a
    # page edge is lost or listed twice with it.
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
            $EnvSize = Invoke-AzGraphQuerySafe -Query $GraphQuery -SubscriptionId @($Subscri) -HideRawOutput:$Obfuscate.IsPresent
            $EnvSizeNum = Get-AzGraphCount -Result $EnvSize

            if ($EnvSizeNum -ge 1)
            {
                # Every page, read with the skip token.
                $GraphQuery = "resources | where resourceGroup == '$ResourceGroup' and (isnull(properties.definition.actions) or strlen(properties.definition.actions) < 123000) | project id,name,type,tenantId,kind,location,resourceGroup,subscriptionId,managedBy,sku,plan,properties,identity,zones,extendedLocation,tags | order by tolower(id) asc"
                $Resource = Invoke-AzGraphQuerySafe -Query $GraphQuery -SubscriptionId @($Subscri) -Lowercase -HideRawOutput:$Obfuscate.IsPresent

                $Global:Resources += $Resource.data
            }
        }
        elseif ([string]::IsNullOrEmpty($ResourceGroup) -and ![string]::IsNullOrEmpty($SubscriptionID))
        {
            Write-Log -Message ('Extracting Resources from Subscription: ' + $SubscriptionID) -Severity 'Success'

            $GraphQuery = "resources | where (isnull(properties.definition.actions) or strlen(properties.definition.actions) < 123000) | summarize count()"
            $EnvSize = Invoke-AzGraphQuerySafe -Query $GraphQuery -SubscriptionId @($SubscriptionID) -HideRawOutput:$Obfuscate.IsPresent
            $EnvSizeNum = Get-AzGraphCount -Result $EnvSize

            if ($EnvSizeNum -ge 1)
            {
                # Every page, read with the skip token.
                $GraphQuery = "resources | where (isnull(properties.definition.actions) or strlen(properties.definition.actions) < 123000) | project id,name,type,tenantId,kind,location,resourceGroup,subscriptionId,managedBy,sku,plan,properties,identity,zones,extendedLocation,tags | order by tolower(id) asc"
                $Resource = Invoke-AzGraphQuerySafe -Query $GraphQuery -SubscriptionId @($SubscriptionID) -Lowercase -HideRawOutput:$Obfuscate.IsPresent

                $Global:Resources += $Resource.data
            }
        }
        else
        {
            # Every subscription of the run, named explicitly (in batches of
            # 1000), rather than whatever scope Resource Graph defaults to.
            $RunSubscriptionIds = @($Global:Subscriptions | ForEach-Object { [string]$_.id })
            $GraphQuery = "resources | where (isnull(properties.definition.actions) or strlen(properties.definition.actions) < 123000) | summarize count()"
            $EnvSize = Invoke-AzGraphQuerySafe -Query $GraphQuery -SubscriptionId $RunSubscriptionIds -HideRawOutput:$Obfuscate.IsPresent
            $EnvSizeCount = Get-AzGraphCount -Result $EnvSize

            Write-Log -Message ("Resources Output: {0} Resources Identified" -f $EnvSizeCount) -Severity 'Success'

            if ($EnvSizeCount -ge 1)
            {
                # Every page, read with the skip token.
                $GraphQuery = "resources | where (isnull(properties.definition.actions) or strlen(properties.definition.actions) < 123000) | project id,name,type,tenantId,kind,location,resourceGroup,subscriptionId,managedBy,sku,plan,properties,identity,zones,extendedLocation,tags | order by tolower(id) asc"
                $Resource = Invoke-AzGraphQuerySafe -Query $GraphQuery -SubscriptionId $RunSubscriptionIds -Lowercase -HideRawOutput:$Obfuscate.IsPresent

                $Global:Resources += $Resource.Data
            }
        }
    }

    function ResourceInventoryAvd()
    {
        # The subscriptions ResourceInventoryLoop reads: -SubscriptionID alone
        # when it is given, else every subscription of the run, named explicitly
        # (in batches of 1000). Session hosts of other subscriptions never match
        # this run's host pools, and the wrapper runs one -SubscriptionID run per
        # subscription, so reading them put their real ids in every run's
        # dictionary, each run with its own tokens, and counted them as the
        # run's own resources.
        $RunSubscriptionIds = if (![string]::IsNullOrEmpty($SubscriptionID)) { @([string]$SubscriptionID) } else { @($Global:Subscriptions | ForEach-Object { [string]$_.id }) }
        # A -ResourceGroup run reads that group only, for the same reason. =~
        # matches without regard to case: only the resources table is known to
        # keep resourceGroup in lower case, other tables may keep the portal's.
        # Lower-cased without the host's culture: on a Turkish host ToLower()
        # turns I into a dotless i, which matches no group.
        $AVDGroupFilter = if (![string]::IsNullOrEmpty($ResourceGroup)) { " | where resourceGroup =~ '{0}'" -f $ResourceGroup.ToLowerInvariant() } else { '' }
        $AVDSize = Invoke-AzGraphQuerySafe -Query ("desktopvirtualizationresources{0} | summarize count()" -f $AVDGroupFilter) -SubscriptionId $RunSubscriptionIds -HideRawOutput:$Obfuscate.IsPresent
        $AVDSizeCount = Get-AzGraphCount -Result $AVDSize

        Write-Host ("AVD Resources Output: {0} AVD Resources Identified" -f $AVDSizeCount) -BackgroundColor Black -ForegroundColor Green

        if ($AVDSizeCount -ge 1)
        {
            # Every page, read with the skip token, sorted by the id in lower
            # case for the reason given above ResourceInventoryLoop.
            $GraphQuery = "desktopvirtualizationresources$AVDGroupFilter | project id,name,type,tenantId,kind,location,resourceGroup,subscriptionId,managedBy,sku,plan,properties,identity,zones,extendedLocation,tags | order by tolower(id) asc"
            $AVD = Invoke-AzGraphQuerySafe -Query $GraphQuery -SubscriptionId $RunSubscriptionIds -Lowercase -HideRawOutput:$Obfuscate.IsPresent

            $Global:Resources += $AVD.data
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

        # At most one reconnect per run, whatever the identity: after it,
        # later phases are skipped without trying again. A user is never
        # prompted a second time in a run, and only for the run's tenant.
        if ($script:RdaReconnectTried)
        {
            Write-Log -Message ("{0}: the one reconnect of this run was already made; not trying again. Re-authenticate (Connect-AzAccount), then re-run." -f $Phase) -Severity 'Error'
            return $false
        }
        $RunTenant = if ($TenantID) { $TenantID } else { $script:RdaRunTenant }

        try
        {
            if ($Appid -and $Secret -and $TenantID)
            {
                $script:RdaReconnectTried = $true
                Write-Log -Message ("{0}: reconnecting via Service Principal." -f $Phase) -Severity 'Info'
                $Credential = New-Object System.Management.Automation.PSCredential($Appid, $Secret)
                Connect-AzAccount -ServicePrincipal -Credential $Credential -Tenant $TenantID -Scope Process -ErrorAction Stop | Out-Null
            }
            elseif ($UseManagedIdentity.IsPresent)
            {
                # Never a user sign-in for a managed identity run.
                $script:RdaReconnectTried = $true
                Write-Log -Message ("{0}: reconnecting with the managed identity." -f $Phase) -Severity 'Info'
                if ($TenantID) { Connect-AzAccount -Identity -Tenant $TenantID -Scope Process -ErrorAction Stop | Out-Null }
                else { Connect-AzAccount -Identity -Scope Process -ErrorAction Stop | Out-Null }
                if (& $TokenOk) { return $true }
                Write-Log -Message ("{0}: the managed identity reconnect did not give a usable token. Check that this machine has a managed identity with access to the tenant, then re-run." -f $Phase) -Severity 'Error'
                return $false
            }
            elseif ($RunAllSubs.IsPresent)
            {
                Write-Log -Message ("{0}: running under -RunAllSubs without Service Principal credentials - cannot prompt for interactive login in this context. Authenticate before the run (e.g. Connect-AzAccount) or supply -appid/-secret/-tenant." -f $Phase) -Severity 'Error'
                return $false
            }
            elseif ($RunTenant -and (Test-AzPsTokenSilent -Tenant $RunTenant))
            {
                # The sign-in still reaches the run's tenant without a prompt:
                # point this process back at it.
                $script:RdaReconnectTried = $true
                Write-Log -Message ("{0}: switching this process back to tenant {1} with the same sign-in." -f $Phase, $RunTenant) -Severity 'Info'
                Set-AzContext -Tenant $RunTenant -Scope Process -ErrorAction Stop | Out-Null
            }
            elseif ($script:RdaUserSignInMade)
            {
                Write-Log -Message ("{0}: reconnecting would prompt a second time in this run; not prompting again. Re-authenticate (Connect-AzAccount{1}), then re-run." -f $Phase, $(if ($RunTenant) { " -Tenant $RunTenant" })) -Severity 'Error'
                return $false
            }
            elseif (-not (Test-RdaInteractiveSession))
            {
                Write-Log -Message ("{0}: no usable Azure context and no interactive console to prompt for login (non-interactive session). Authenticate before the run (Connect-AzAccount) or supply -appid/-secret/-tenant, then re-run." -f $Phase) -Severity 'Error'
                return $false
            }
            else
            {
                $script:RdaReconnectTried = $true
                $script:RdaUserSignInMade = $true
                $SignInArgs = @{}
                if ($RunTenant) { $SignInArgs.Tenant = $RunTenant }
                if ($DeviceLogin.IsPresent)
                {
                    Write-Log -Message ("{0}: reconnecting via device login." -f $Phase) -Severity 'Info'
                    $SignInArgs.UseDeviceAuthentication = $true
                }
                else { Write-Log -Message ("{0}: reconnecting via interactive browser login." -f $Phase) -Severity 'Info' }
                Connect-AzAccount @SignInArgs -ErrorAction Stop | Out-Null
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
            # SubscriptionId: the one subscription a wrapper run is for (empty
            # in a direct run of all), so the wrapper counts each skip once.
            # Only counted, never printed.
            $Global:ConsumptionFailedSubs += [pscustomobject]@{
                Name           = '(all subscriptions)'
                Id             = '(auth)'
                Message        = 'Consumption phase skipped: no usable Azure context/token after one reconnect attempt.'
                SubscriptionId = [string]$SubscriptionID
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
                $null = Set-AzContext -Subscription $sub.id -Scope Process -ErrorAction Stop
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
                # exit, not throw: the production 'SilentlyContinue' preference
                # suppresses a bare throw, and the run would go on.
                Write-Host ("ERROR: Pre-flight: free disk space at {0} is {1} MB; the script needs at least 100 MB to start. Free space and re-run." -f $PreFlightInventoryRoot, $FreeMB) -ForegroundColor Red
                exit 1
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
        $ProbeError = $_.Exception.Message
        try { if (Test-Path $ProbePath) { Remove-Item -Path $ProbePath -Force -ErrorAction SilentlyContinue } }
        catch { Write-Verbose ("Probe cleanup failed at {0}: {1}" -f $ProbePath, $_.Exception.Message) }
        Write-Host ("ERROR: Pre-flight: cannot write to {0}: {1}. This usually means readonly directory, denied permissions, antivirus or DLP product blocking writes, or a stale handle. Verify the directory is writable and re-run." -f $PreFlightInventoryRoot, $ProbeError) -ForegroundColor Red
        exit 1
    }

    Write-Host "Pre-flight checks passed." -ForegroundColor Green
    Write-Host ""
}

# A direct run owns the health lists, so it starts them empty: a second run in
# the same session must not report the first run's failures. Under -RunAllSubs
# the wrapper (or its stream worker) empties them once at its own start and
# gathers every subscription's entries in them, so they are left alone here.
if (-not $RunAllSubs.IsPresent)
{
    $Global:CollectorFailures = @()
    $Global:MetricsFailedSubs = @()
    $Global:ConsumptionFailedSubs = @()
    $Global:ConsumptionRecordCount = 0
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
Write-Log -Message ("Reporting Data File: {0}" -f $Global:ZipOutputFile) -Severity 'Success'
