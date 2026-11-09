# Report header of a direct run over several subscriptions
# Run with: Invoke-Pester ./Tests/MultiSubscriptionHeader.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# A direct run without -SubscriptionID inventories every subscription the
# sign-in lists into one report. Its header still read 'Subscription: <name>'
# with one subscription's name: Summary.ps1 took the name from the first
# record it found. The header now says how many subscriptions the report
# covers. A count says nothing that -Obfuscate would mask.
#
# The test copies the scripts to a temp folder and runs the REAL
# ResourceInventory.ps1 in a child pwsh through the shared offline harness
# Tests/Helpers/InnerRunHarness.ps1 (stand-ins for the Azure CLI and the Az
# cmdlets): two subscriptions without -SubscriptionID (with and without
# -Obfuscate), two subscriptions with -SubscriptionID, and one subscription
# without -SubscriptionID, under en-US and tr-TR. Each subscription holds one
# disk. Placeholder ids and generic names only; no live Azure.
#
# Not run on Windows: the stand-ins are written for the Unix paths.

BeforeDiscovery {
    $Two = '12345678-1234-1234-1234-123456789012,12345678-1234-1234-1234-123456789013'
    $One = '12345678-1234-1234-1234-123456789012'
    $script:Cases = @(
        foreach ($Culture in @('en-US', 'tr-TR'))
        {
            @{ Culture = $Culture; SubIds = $Two; AllSubs = $true; Obfuscate = $false; Header = '2 subscriptions (consolidated)'; Disks = 2; Name = 'two subscriptions, no -SubscriptionID' }
            @{ Culture = $Culture; SubIds = $Two; AllSubs = $true; Obfuscate = $true; Header = '2 subscriptions (consolidated)'; Disks = 2; Name = 'two subscriptions, no -SubscriptionID, -Obfuscate' }
            @{ Culture = $Culture; SubIds = $Two; AllSubs = $false; Obfuscate = $false; Header = 'Demo Subscription 1'; Disks = 1; Name = 'two subscriptions, -SubscriptionID' }
            # This header comes from the first record's Subscription field. On this
            # branch's base a tr-TR run lower-cases the Resource Graph text with
            # tr-TR rules, so 'subscriptionId' loses its dotted i and the record's
            # Subscription is empty; that is older than this change and is fixed
            # where Resource Graph is read with Az PowerShell. So that one case
            # runs under en-US only.
            if ($Culture -eq 'en-US')
            {
                @{ Culture = $Culture; SubIds = $One; AllSubs = $true; Obfuscate = $false; Header = 'Demo Subscription 1'; Disks = 1; Name = 'one subscription, no -SubscriptionID' }
            }
        }
    )
}

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('MultiSubscriptionHeader_' + [guid]::NewGuid().ToString('N'))
    $script:Tree = Join-Path $script:WorkDir 'tree'
    $null = New-Item -ItemType Directory -Path $script:Tree -Force
    foreach ($Item in @('ResourceInventory.ps1', 'Version.json', 'Functions', 'Extension', 'Services'))
    {
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot $Item) -Destination $script:Tree -Recurse -Force
    }

    # The child run: the shared stand-ins, then the real script.
    $script:Harness = Join-Path $PSScriptRoot 'Helpers/InnerRunHarness.ps1'

    # The pwsh that runs these tests runs the child too.
    $script:Pwsh = (Get-Process -Id $PID).Path

    # Reads what a run wrote: its exit code, console, header line and disks.
    function Read-HeaderRun
    {
        param([string]$Out, [object[]]$Console, [int]$Exit)
        $Html = @(Get-ChildItem -LiteralPath $Out -Filter 'ResourcesReport_*.html' -File)[0]
        $Text = if ($null -ne $Html) { Get-Content -LiteralPath $Html.FullName -Raw } else { '' }
        $Json = @(Get-ChildItem -LiteralPath $Out -Filter 'Inventory_*.json' -File)[0]
        $Disks = if ($null -ne $Json) { @((Get-Content -LiteralPath $Json.FullName -Raw | ConvertFrom-Json).VMDisk) } else { @() }
        $Header = if ($Text -match '<div><b>Subscription:</b> ([^<]*)</div>') { $Matches[1] } else { '<no such line>' }
        return [pscustomobject]@{ Exit = $Exit; Console = ($Console -join "`n"); Header = $Header; Disks = $Disks; Html = $Text }
    }

    function New-RunOut
    {
        $Out = Join-Path $script:WorkDir ('out_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $Out -Force
        return $Out
    }

    function Invoke-HeaderRun
    {
        param([string]$Culture, [string]$SubIds, [bool]$AllSubs, [bool]$Obfuscate)
        $Out = New-RunOut
        $ArgList = @('-NoProfile', '-NonInteractive', '-File', $script:Harness, '-Tree', $script:Tree, '-Out', $Out, '-Culture', $Culture, '-SubIds', $SubIds)
        if ($AllSubs) { $ArgList += '-AllSubs' }
        if ($Obfuscate) { $ArgList += '-Obfuscate' }
        $Console = @(& $script:Pwsh @ArgList 2>&1 | ForEach-Object { [string]$_ })
        return (Read-HeaderRun -Out $Out -Console $Console -Exit $LASTEXITCODE)
    }

    # The shared harness lists only Enabled subscriptions of its own tenant.
    # This small local stand-in adds more entries to the 'az account list'
    # answer only (a global alias wins over the harness's az function), and
    # can pass -TenantID through a one-line forwarder in a second tree copy.
    # Resource Graph and the rest stay the harness's own.
    $script:TenantTree = Join-Path $script:WorkDir 'tenant-tree'
    Copy-Item -LiteralPath $script:Tree -Destination $script:TenantTree -Recurse -Force
    Move-Item -LiteralPath (Join-Path $script:TenantTree 'ResourceInventory.ps1') -Destination (Join-Path $script:TenantTree 'ResourceInventory.Real.ps1')
    '& (Join-Path $PSScriptRoot ''ResourceInventory.Real.ps1'') @args -TenantID $env:RDA_TEST_TENANT; exit $LASTEXITCODE' |
        Set-Content -LiteralPath (Join-Path $script:TenantTree 'ResourceInventory.ps1') -Encoding utf8
    $script:ExtraRunner = Join-Path $script:WorkDir 'extra-subs.ps1'
    @'
param([string]$Harness, [string]$SubIds, [string]$ExtraSubs)
$Global:StandInExtraSubs = @($ExtraSubs | ConvertFrom-Json)
function global:Invoke-StandInAzWithExtras
{
    if (($args -join ' ') -like 'account list*')
    {
        $global:LASTEXITCODE = 0
        return (ConvertTo-Json -InputObject @(@($Global:StandInSubs) + @($Global:StandInExtraSubs)) -Compress)
    }
    & $function:global:az @args
}
Set-Alias -Name az -Value Invoke-StandInAzWithExtras -Scope Global
& $Harness -SubIds $SubIds -AllSubs
exit $LASTEXITCODE
'@ | Set-Content -LiteralPath $script:ExtraRunner -Encoding utf8

    function Invoke-ExtraSubsRun
    {
        param([string]$SubIds, [object[]]$ExtraSubs, [string]$TenantId)
        $Out = New-RunOut
        $env:RDA_INNER_HARNESS_TREE = if ($TenantId) { $script:TenantTree } else { $script:Tree }
        $env:RDA_INNER_HARNESS_OUT = $Out
        $env:RDA_TEST_TENANT = $TenantId
        try
        {
            $ArgList = @('-NoProfile', '-NonInteractive', '-File', $script:ExtraRunner, '-Harness', $script:Harness, '-SubIds', $SubIds, '-ExtraSubs', (ConvertTo-Json -InputObject @($ExtraSubs) -Compress))
            $Console = @(& $script:Pwsh @ArgList 2>&1 | ForEach-Object { [string]$_ })
            return (Read-HeaderRun -Out $Out -Console $Console -Exit $LASTEXITCODE)
        }
        finally
        {
            Remove-Item Env:RDA_INNER_HARNESS_TREE, Env:RDA_INNER_HARNESS_OUT, Env:RDA_TEST_TENANT -ErrorAction SilentlyContinue
        }
    }
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
    {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Direct run under <Culture>: <Name>' -ForEach $script:Cases -Skip:$IsWindows {
    BeforeAll {
        $script:Run = Invoke-HeaderRun -Culture $Culture -SubIds $SubIds -AllSubs $AllSubs -Obfuscate $Obfuscate
    }

    It 'finishes with exit 0' {
        $script:Run.Exit | Should -Be 0 -Because $script:Run.Console
    }

    It 'lists the disk of every subscription it covers' {
        @($script:Run.Disks).Count | Should -Be $Disks
    }

    It 'names the subscription, or the number of subscriptions, in the header' {
        $script:Run.Header | Should -BeExactly $Header
    }

    It 'shows no subscription name under -Obfuscate' {
        if (-not $Obfuscate) { Set-ItResult -Skipped -Because 'this run is not obfuscated' }
        $script:Run.Html | Should -Not -Match 'Demo Subscription'
    }
}

# The count is of the subscriptions the run inventories: az's list (by default
# only 'Enabled' ones), narrowed to -TenantID when one is given. A Disabled or
# Warned entry, or another tenant's subscription under -TenantID, is not one.
Describe 'Direct run without -SubscriptionID: <Name>' -Skip:$IsWindows -ForEach @(
    @{ Name = 'two Enabled subscriptions plus a Disabled and a Warned one'; SubIds = '12345678-1234-1234-1234-123456789012,12345678-1234-1234-1234-123456789013'; TenantId = ''; Header = '2 subscriptions (consolidated)'; Disks = 2
        ExtraSubs = @(
            @{ id = '12345678-1234-1234-1234-123456789014'; name = 'Demo Subscription 3'; tenantId = '12345678-1234-1234-1234-123456789012'; state = 'Disabled' }
            @{ id = '12345678-1234-1234-1234-123456789015'; name = 'Demo Subscription 4'; tenantId = '12345678-1234-1234-1234-123456789012'; state = 'Warned' }
        ) }
    @{ Name = 'one Enabled subscription plus a Disabled one'; SubIds = '12345678-1234-1234-1234-123456789012'; TenantId = ''; Header = 'Demo Subscription 1'; Disks = 1
        ExtraSubs = @(
            @{ id = '12345678-1234-1234-1234-123456789014'; name = 'Demo Subscription 3'; tenantId = '12345678-1234-1234-1234-123456789012'; state = 'Disabled' }
        ) }
    @{ Name = '-TenantID, two subscriptions of that tenant plus one of another tenant'; SubIds = '12345678-1234-1234-1234-123456789012,12345678-1234-1234-1234-123456789013'; TenantId = '12345678-1234-1234-1234-123456789012'; Header = '2 subscriptions (consolidated)'; Disks = 2
        ExtraSubs = @(
            @{ id = '12345678-1234-1234-1234-123456789016'; name = 'Demo Subscription 5'; tenantId = '87654321-4321-4321-4321-210987654321'; state = 'Enabled' }
        ) }
) {
    BeforeAll {
        $script:Run = Invoke-ExtraSubsRun -SubIds $SubIds -ExtraSubs $ExtraSubs -TenantId $TenantId
    }

    It 'finishes with exit 0' {
        $script:Run.Exit | Should -Be 0 -Because $script:Run.Console
    }

    It 'lists the disk of every subscription it covers' {
        @($script:Run.Disks).Count | Should -Be $Disks
    }

    It 'counts only the subscriptions the run inventories' {
        $script:Run.Header | Should -BeExactly $Header
    }
}
