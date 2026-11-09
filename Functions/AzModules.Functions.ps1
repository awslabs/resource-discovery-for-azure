#Requires -Version 7.0
# =============================================================================
# AzModules.Functions.ps1
#
# The Az.Accounts version check shared by ResourceInventory.ps1 and
# Run-AllSubscriptions.ps1. The lowest supported Az.Accounts version lives
# here and only here (Get-RdaAzAccountsMinimumVersion).
#
# This file must load before any Az module: it only defines functions and
# calls nothing at load time.
# =============================================================================

# The lowest Az.Accounts version this tool supports: the version it was last
# tested with live. Change the number here and nowhere else.
function Get-RdaAzAccountsMinimumVersion
{
    [CmdletBinding()]
    [OutputType([version])]
    param()
    return [version]'5.5.4'
}

# The command that installs a supported Az.Accounts into the user's own scope.
# Install-Module, not Update-Module: Update-Module has no -MinimumVersion and
# fails for a copy that was not installed with Install-Module. -Force installs
# the new version next to an older one.
function Get-RdaAzAccountsInstallCommand
{
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return ('Install-Module -Name Az.Accounts -MinimumVersion {0} -Repository PSGallery -Scope CurrentUser -Force -AllowClobber -SkipPublisherCheck' -f (Get-RdaAzAccountsMinimumVersion))
}

# Checks the installed and the loaded Az.Accounts against the minimum version.
# Returns Status:
#   Ok           - the highest installed version is new enough, and no older
#                  version is loaded in this session.
#   Missing      - Az.Accounts is not installed.
#   TooOld       - the highest installed version is older than the minimum.
#   LoadedTooOld - an older Az.Accounts is already loaded in this session.
#                  It cannot be replaced in a running session (its assemblies
#                  stay loaded), so only a new session gets past it.
# Messages holds the lines to print when Status is not Ok: the found version,
# the needed version and the command that fixes it. Running that command (and,
# for LoadedTooOld, starting a new session) makes the next check pass, so a
# stop on this check never repeats by itself.
#
# -SubModule names the other Az modules the caller loads. When one of them
# that is loaded asks for an Az.Accounts older than the minimum, a new session
# alone loads the same pair again, so the messages name that module and the
# command that updates it, and how to remove an old copy that is still found
# first.
function Test-RdaAzAccountsVersion
{
    [CmdletBinding()]
    param([string[]]$SubModule = @())

    $Required = Get-RdaAzAccountsMinimumVersion
    $InstallCommand = Get-RdaAzAccountsInstallCommand

    # Highest installed version: Get-Module -ListAvailable lists every copy,
    # in no promised order. Sort as [version] so 5.10.0 is above 5.5.4.
    $Installed = @(Get-Module -Name Az.Accounts -ListAvailable -ErrorAction SilentlyContinue |
            Where-Object { $_ -and $_.Version } |
            ForEach-Object { [version]$_.Version } |
            Sort-Object -Descending) | Select-Object -First 1

    # Lowest loaded version: an older loaded copy wins in this session.
    $Loaded = @(Get-Module -Name Az.Accounts -ErrorAction SilentlyContinue |
            Where-Object { $_ -and $_.Version } |
            ForEach-Object { [version]$_.Version } |
            Sort-Object) | Select-Object -First 1

    $Messages = @()
    $Status = 'Ok'

    if ($Loaded -and $Loaded -lt $Required)
    {
        $Status = 'LoadedTooOld'
        $Messages += ('Az.Accounts {0} is already loaded in this PowerShell session. This tool needs Az.Accounts {1} or newer.' -f $Loaded, $Required)
        $Messages += 'An older Az.Accounts that is already loaded cannot be replaced in a running session.'
        if (-not $Installed -or $Installed -lt $Required)
        {
            $Messages += 'Install a supported version first:'
            $Messages += ('  ' + $InstallCommand)
        }
        # The loaded submodules whose manifest asks for an older Az.Accounts:
        # PowerShell loads that copy for them in every new session.
        $Pinning = @(foreach ($Name in @($SubModule | Where-Object { $_ -and $_ -ne 'Az.Accounts' }))
            {
                foreach ($Copy in @(Get-Module -Name $Name -ErrorAction SilentlyContinue | Where-Object { $_ -and $_.Version }))
                {
                    $Old = @($Copy.RequiredModules | Where-Object { $_ -and $_.Name -eq 'Az.Accounts' -and $_.Version -and [version]$_.Version -lt $Required }) | Select-Object -First 1
                    if ($Old) { [pscustomobject]@{ Name = [string]$Copy.Name; Version = [version]$Copy.Version; Accounts = [version]$Old.Version } }
                }
            })
        if ($Pinning.Count -gt 0)
        {
            foreach ($P in $Pinning)
            {
                $Messages += ('{0} {1} asks for Az.Accounts {2}, so PowerShell loads that older copy for it in every new session.' -f $P.Name, $P.Version, $P.Accounts)
            }
            $PinnedNames = @($Pinning | ForEach-Object { $_.Name } | Select-Object -Unique)
            $Messages += 'Update it first:'
            $Messages += ('  Install-Module -Name {0} -Repository PSGallery -Scope CurrentUser -Force -AllowClobber -SkipPublisherCheck' -f ($PinnedNames -join ','))
            foreach ($P in $Pinning)
            {
                $Messages += ('If this stops again with the same {0} {1}, that old copy is still found first: see where each copy is with Get-Module -Name {0} -ListAvailable, and remove the old one with Uninstall-Module -Name {0} -RequiredVersion {1} (or delete its folder).' -f $P.Name, $P.Version)
            }
        }
        $Messages += 'Then open a new PowerShell session and run again.'
        $Messages += 'If your PowerShell profile loads Az.Accounts, start the new session with: pwsh -NoProfile'
        # -NoProfile also drops a sign-in the profile makes (Cloud Shell does).
        $Messages += 'In that new session, sign in first (Connect-AzAccount, or Connect-AzAccount -Identity on an Azure VM), then run again.'
    }
    elseif (-not $Installed)
    {
        $Status = 'Missing'
        $Messages += ('Az.Accounts is not installed. This tool needs Az.Accounts {0} or newer.' -f $Required)
        $Messages += 'Install it, then run again:'
        $Messages += ('  ' + $InstallCommand)
    }
    elseif ($Installed -lt $Required)
    {
        $Status = 'TooOld'
        $Messages += ('Az.Accounts {0} is installed. This tool needs Az.Accounts {1} or newer.' -f $Installed, $Required)
        $Messages += 'Update it, then run again:'
        $Messages += ('  ' + $InstallCommand)
    }

    return [pscustomobject]@{
        Status    = $Status
        Required  = $Required
        Installed = $Installed
        Loaded    = $Loaded
        Messages  = $Messages
    }
}

# Installs the named Az submodules into the user's scope. Az.Accounts is
# installed on its own with -MinimumVersion (Install-Module refuses a version
# with several names); the rest are installed together at their latest.
# Throws on failure; the caller prints the manual command and stops.
function Install-RdaAzSubModule
{
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$Name)

    if ('Az.Accounts' -in $Name)
    {
        Install-Module -Name 'Az.Accounts' -MinimumVersion (Get-RdaAzAccountsMinimumVersion) -Repository PSGallery -Force -AllowClobber -SkipPublisherCheck -Scope CurrentUser -ErrorAction Stop
    }

    $Others = @($Name | Where-Object { $_ -ne 'Az.Accounts' })
    if ($Others.Count -gt 0)
    {
        Install-Module -Name $Others -Repository PSGallery -Force -AllowClobber -SkipPublisherCheck -Scope CurrentUser -ErrorAction Stop
    }
}
