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
function Test-RdaAzAccountsVersion
{
    [CmdletBinding()]
    param()

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
        $Messages += 'Then open a new PowerShell session and run again.'
        $Messages += 'If your PowerShell profile loads Az.Accounts, start the new session with: pwsh -NoProfile'
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
