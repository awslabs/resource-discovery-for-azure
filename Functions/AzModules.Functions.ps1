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
#   SubModulePinned - Az.Accounts is fine, but the copy of a -SubModule
#                  module that loads (or is loaded) pins an Az.Accounts older
#                  than the minimum in its manifest, so loading it would load
#                  that older copy.
# Messages holds the lines to print when Status is not Ok: the found version,
# the needed version and the command that fixes it. Running that command (and,
# for LoadedTooOld, starting a new session) makes the next check pass, so a
# stop on this check never repeats by itself.
#
# -SubModule names the other Az modules the caller loads. A module pins an
# older Az.Accounts only when its manifest asks for an exact one
# (RequiredVersion) or caps it (MaximumVersion) below the minimum; a minimum
# (ModuleVersion) never pins. For a pinning module, a new session alone loads
# the same pair again, so the messages name that module and the command that
# updates it, and how to remove an old copy that is still found first.
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
        # The loaded submodules whose manifest pins an older Az.Accounts:
        # PowerShell loads that copy for them in every new session.
        $Pinning = @(foreach ($Name in @($SubModule | Where-Object { $_ -and $_ -ne 'Az.Accounts' }))
            {
                foreach ($Copy in @(Get-Module -Name $Name -ErrorAction SilentlyContinue | Where-Object { $_ -and $_.Version }))
                {
                    $Pin = Get-RdaAzAccountsPin -Module $Copy -Minimum $Required
                    if ($Pin) { [pscustomobject]@{ Name = [string]$Copy.Name; Version = [version]$Copy.Version; Accounts = $Pin } }
                }
            })
        $Messages += @(Get-RdaAzAccountsPinMessage -Pinning $Pinning)
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
    else
    {
        # Az.Accounts is fine. The copy of each submodule that a plain
        # Import-Module takes (the one loaded, or else the highest version in
        # the first PSModulePath folder that holds it) must not pin an older
        # one, or loading it would stop every subscription's run.
        $Pinning = @(foreach ($Name in @($SubModule | Where-Object { $_ -and $_ -ne 'Az.Accounts' }))
            {
                foreach ($Copy in @(Get-RdaModuleCopyToLoad -Name $Name))
                {
                    $Pin = Get-RdaAzAccountsPin -Module $Copy -Minimum $Required
                    if ($Pin) { [pscustomobject]@{ Name = [string]$Copy.Name; Version = [version]$Copy.Version; Accounts = $Pin } }
                }
            })
        if ($Pinning.Count -gt 0)
        {
            $Status = 'SubModulePinned'
            $Messages += ('Az.Accounts {0} is installed, and this tool needs Az.Accounts {1} or newer.' -f $Installed, $Required)
            $Messages += @(Get-RdaAzAccountsPinMessage -Pinning $Pinning -Effect 'so loading it would load that older copy, or fail when that copy is not installed')
            $Messages += 'Then run again.'
        }
    }

    return [pscustomobject]@{
        Status    = $Status
        Required  = $Required
        Installed = $Installed
        Loaded    = $Loaded
        Messages  = $Messages
    }
}

# The Az.Accounts version a module's manifest pins below -Minimum, as text:
# its RequiredModules entry for Az.Accounts with a RequiredVersion, or a
# MaximumVersion, older than the minimum. $null when it asks only for a
# minimum (ModuleVersion), names Az.Accounts with no version, or its manifest
# cannot be read. It reads the .psd1 in the module's folder: the
# RequiredModules of a loaded module holds the Az.Accounts copy that was
# bound, which can be an older copy loaded first, not what the module asks for.
function Get-RdaAzAccountsPin
{
    [CmdletBinding()]
    [OutputType([string])]
    param($Module, [version]$Minimum)

    if ($null -eq $Module -or [string]::IsNullOrEmpty([string]$Module.ModuleBase)) { return $null }
    $Manifest = Join-Path ([string]$Module.ModuleBase) ('{0}.psd1' -f $Module.Name)
    if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) { return $null }
    try { $Data = Import-PowerShellDataFile -LiteralPath $Manifest -ErrorAction Stop }
    catch { return $null }
    foreach ($Entry in @($Data.RequiredModules))
    {
        if ($Entry -isnot [hashtable] -or [string]$Entry['ModuleName'] -ne 'Az.Accounts') { continue }
        foreach ($Key in @('RequiredVersion', 'MaximumVersion'))
        {
            $Text = [string]$Entry[$Key]
            if (-not $Text) { continue }
            # A MaximumVersion such as 5.3.* allows every 5.3 version.
            $Version = $null
            if ([version]::TryParse(($Text -replace '\*', [string][int]::MaxValue), [ref]$Version) -and $Version -lt $Minimum) { return $Text }
        }
    }
    return $null
}

# The copies of a module a plain Import-Module -Name uses: the loaded ones
# when it is loaded, or else the highest version in the first PSModulePath
# folder that holds it (PowerShell takes that one, even when a later folder
# holds a newer version).
function Get-RdaModuleCopyToLoad
{
    [CmdletBinding()]
    [OutputType([object[]])]
    param([string]$Name)

    $Loaded = @(Get-Module -Name $Name -ErrorAction SilentlyContinue | Where-Object { $_ -and $_.Version })
    if ($Loaded.Count -gt 0) { return $Loaded }
    $Copies = @(Get-Module -Name $Name -ListAvailable -ErrorAction SilentlyContinue | Where-Object { $_ -and $_.Version -and $_.ModuleBase })
    if ($Copies.Count -eq 0) { return @() }
    foreach ($Folder in @($env:PSModulePath -split [System.IO.Path]::PathSeparator | Where-Object { $_ }))
    {
        $Prefix = $Folder.TrimEnd('/', '\') + [System.IO.Path]::DirectorySeparatorChar
        $Here = @($Copies | Where-Object { ([string]$_.ModuleBase).StartsWith($Prefix, [System.StringComparison]::OrdinalIgnoreCase) })
        if ($Here.Count -gt 0) { return @($Here | Sort-Object -Property { [version]$_.Version } -Descending | Select-Object -First 1) }
    }
    return @($Copies | Sort-Object -Property { [version]$_.Version } -Descending | Select-Object -First 1)
}

# The lines that name each module that pins an older Az.Accounts, the command
# that updates it, and how to remove an old copy that is still found first.
# None when nothing pins.
function Get-RdaAzAccountsPinMessage
{
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [object[]]$Pinning = @(),
        # What the pin does, after the module and the version it asks for.
        [string]$Effect = 'so PowerShell loads that older copy for it in every new session'
    )

    $Pinning = @($Pinning | Where-Object { $null -ne $_ })
    if ($Pinning.Count -eq 0) { return @() }
    $Lines = @()
    foreach ($P in $Pinning)
    {
        $Lines += ('{0} {1} asks for Az.Accounts {2}, {3}.' -f $P.Name, $P.Version, $P.Accounts, $Effect)
    }
    $PinnedNames = @($Pinning | ForEach-Object { $_.Name } | Select-Object -Unique)
    $Lines += 'Update it first:'
    $Lines += ('  Install-Module -Name {0} -Repository PSGallery -Scope CurrentUser -Force -AllowClobber -SkipPublisherCheck' -f ($PinnedNames -join ','))
    foreach ($P in $Pinning)
    {
        $Lines += ('If this stops again with the same {0} {1}, that old copy is still found first: see where each copy is with Get-Module -Name {0} -ListAvailable, and remove the old one with Uninstall-Module -Name {0} -RequiredVersion {1} (or delete its folder).' -f $P.Name, $P.Version)
    }
    return $Lines
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
