# Report zip contents tests
# Run with: Invoke-Pester ./Tests/ReportZipContents.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# With -OutputDirectory, several runs write into one folder. Each run's zip
# must carry only that run's files: an earlier non-obfuscated run's
# Inventory_*.json inside an obfuscated zip ships every real name it holds,
# and an earlier obfuscated run's dictionary must never leave the machine.
#
# This test is SELF-CONTAINED: it copies the script and its folders to a temp
# dir and runs the REAL ResourceInventory.ps1 three times into one output
# folder (plain, then -Obfuscate, then plain again) in child pwsh processes,
# with -SkipMetrics -SkipConsumption and offline stand-ins for the Azure CLI
# and Az calls the run makes. No live Azure. Generic names and the
# documentation placeholder subscription id only.

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ReportZipContents_" + [guid]::NewGuid().ToString('N'))
    $script:Tree = Join-Path $script:WorkDir 'tree'
    $script:Out = Join-Path $script:WorkDir 'shared-out'
    New-Item -ItemType Directory -Path $script:Tree -Force | Out-Null
    New-Item -ItemType Directory -Path $script:Out -Force | Out-Null

    foreach ($Item in @('ResourceInventory.ps1', 'Version.json', 'Functions', 'Extension', 'Services'))
    {
        Copy-Item -Path (Join-Path $script:RepoRoot $Item) -Destination $script:Tree -Recurse -Force
    }

    # Child-process harness: stand-ins for the az CLI and Az cmdlets, then the
    # real script. Resource Graph returns one public IP address named pip-demo.
    $script:Harness = Join-Path $script:WorkDir 'run.ps1'
    @'
param([string]$Tree, [string]$Out, [switch]$Obfuscate)
$PSStyle.OutputRendering = 'PlainText'
$Global:RdaSessionInitialized = $true
$Global:AzPowerShellLoaded = $true
$Global:PlatformOS = 'PowerShell Unix'
$SubId = '12345678-1234-1234-1234-123456789012'
$Global:StandInSubs = @([pscustomobject]@{ id = $SubId; name = 'Demo Subscription'; tenantId = 'tenant-demo'; state = 'Enabled' })
function global:az
{
    $Joined = $args -join ' '
    $global:LASTEXITCODE = 0
    if ($Joined -like 'account show*') { return '{"user":{"name":"tester"},"tenantId":"tenant-demo"}' }
    if ($Joined -like 'account list*') { return (ConvertTo-Json -InputObject @($Global:StandInSubs) -Compress) }
    if ($Joined -like 'graph*')
    {
        if ($Joined -match 'desktopvirtualizationresources') { return '{"data":[{"count_":0}],"count":1}' }
        if ($Joined -match 'summarize count\(\)') { return '{"data":[{"count_":1}],"count":1}' }
        $Row = @{ id = ('/subscriptions/{0}/resourceGroups/rg-demo/providers/Microsoft.Network/publicIPAddresses/pip-demo' -f $SubId); name = 'pip-demo'; type = 'microsoft.network/publicipaddresses'; location = 'eastus'; subscriptionId = $SubId; resourceGroup = 'rg-demo'; sku = @{ name = 'Standard' }; properties = @{ publicIPAllocationMethod = 'Static'; publicIPAddressVersion = 'IPv4'; provisioningState = 'Succeeded' } }
        return (@{ data = @($Row); count = 1 } | ConvertTo-Json -Depth 8 -Compress)
    }
    return $null
}
function global:Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = 'tenant-demo' }; Subscription = [pscustomobject]@{ Id = '12345678-1234-1234-1234-123456789012'; Name = 'Demo Subscription' }; Account = [pscustomobject]@{ Id = 'tester' } } }
function global:Connect-AzAccount { throw 'no sign-in in this harness' }
# Read-access calls answer as for a Reader assignment on the subscription.
# Any other Resource Manager call fails, so a new one shows up here.
function global:Get-AzAccessToken { param($ResourceUrl) [pscustomobject]@{ Token = ('e30.' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"oid":"test-oid"}')).TrimEnd('=') + '.sig') } }
function global:Invoke-AzRestMethod
{
    param($Method, $Path, $Payload, $Uri)
    $Target = if ($Path) { $Path } else { $Uri }
    $Json = { param($Obj) [pscustomobject]@{ StatusCode = 200; Content = ($Obj | ConvertTo-Json -Depth 10) } }
    if ($Target -match '/roleAssignments\?')
    {
        return (& $Json @{ value = @(@{ properties = @{ roleDefinitionId = "/subscriptions/$SubId/providers/Microsoft.Authorization/roleDefinitions/reader"; scope = "/subscriptions/$SubId"; principalId = 'test-oid'; principalType = 'ServicePrincipal' } }) })
    }
    if ($Target -match '/roleDefinitions/')
    {
        return (& $Json @{ properties = @{ roleName = 'Reader'; type = 'BuiltInRole'; permissions = @(@{ actions = @('*/read'); notActions = @() }) } })
    }
    if ($Target -match '/providers/Microsoft\.Authorization/permissions\?')
    {
        return (& $Json @{ value = @(@{ actions = @('*/read'); notActions = @() }) })
    }
    throw ('no stand-in for {0} {1}' -f $Method, $Target)
}

$Params = @{ SubscriptionID = $SubId; SkipMetrics = $true; SkipConsumption = $true; OutputDirectory = $Out; Service = @('PublicIP') }
if ($Obfuscate) { $Params.Obfuscate = $true }
Set-Location $Tree
$global:LASTEXITCODE = 0
& (Join-Path $Tree 'ResourceInventory.ps1') @Params
exit $LASTEXITCODE
'@ | Set-Content -Path $script:Harness -Encoding utf8

    # Runs one direct run into the shared folder and returns its process exit
    # code, the zip it added, that zip's run stamp and its members (name + text).
    function Invoke-SharedFolderRun
    {
        param([switch]$Obfuscate)

        $Before = @(Get-ChildItem -LiteralPath $script:Out -Filter '*.zip' -File | ForEach-Object Name)
        $ArgList = @('-NoProfile', '-NonInteractive', '-File', $script:Harness, '-Tree', $script:Tree, '-Out', $script:Out)
        if ($Obfuscate) { $ArgList += '-Obfuscate' }
        $Console = @(& pwsh @ArgList 2>&1 | ForEach-Object { [string]$_ })
        $ProcessExit = $LASTEXITCODE

        $Zip = @(Get-ChildItem -LiteralPath $script:Out -Filter '*.zip' -File | Where-Object { $Before -notcontains $_.Name })
        $Members = @()
        $Stamp = $null
        if ($Zip.Count -eq 1)
        {
            # The zip is <ReportName>_<stamp>.zip; every file of the run carries the same stamp.
            $Stamp = [regex]::Match($Zip[0].BaseName, '_([^_]+)$').Groups[1].Value
            $Archive = [System.IO.Compression.ZipFile]::OpenRead($Zip[0].FullName)
            try
            {
                foreach ($Entry in $Archive.Entries)
                {
                    $Reader = [System.IO.StreamReader]::new($Entry.Open())
                    try { $Text = $Reader.ReadToEnd() } finally { $Reader.Dispose() }
                    $Members += [pscustomobject]@{ Name = $Entry.Name; Text = $Text }
                }
            }
            finally
            {
                $Archive.Dispose()
            }
        }

        return [pscustomobject]@{
            ProcessExit = $ProcessExit
            Console     = ($Console -join "`n")
            Zip         = $Zip
            Stamp       = $Stamp
            Members     = $Members
        }
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $script:Plain1 = Invoke-SharedFolderRun
    $script:Obfuscated = Invoke-SharedFolderRun -Obfuscate
    $script:Plain2 = Invoke-SharedFolderRun
    $script:FolderJson = @(Get-ChildItem -LiteralPath $script:Out -Filter '*.json' -File | ForEach-Object Name)
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
    {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Report zip with a reused -OutputDirectory' {
    It 'each run finishes and writes one zip' {
        foreach ($Run in @($script:Plain1, $script:Obfuscated, $script:Plain2))
        {
            $Run.ProcessExit | Should -Be 0 -Because $Run.Console
            $Run.Zip.Count | Should -Be 1 -Because $Run.Console
            $Run.Stamp | Should -Not -BeNullOrEmpty
        }
    }

    It 'the shared folder holds the earlier runs'' inventory and the dictionary' {
        # Without these files on disk the checks below would pass for the wrong reason.
        @($script:FolderJson | Where-Object { $_ -like "Inventory_*_$($script:Plain1.Stamp).json" }).Count | Should -Be 1
        @($script:FolderJson | Where-Object { $_ -like "ObfuscationDictionary_*_$($script:Obfuscated.Stamp).json" }).Count | Should -Be 1
        ($script:Plain1.Members | Where-Object Name -like 'Inventory_*').Text | Should -Match 'pip-demo'
    }

    It 'a run into a fresh folder zips its report, consumption, diagnostics, inventory and metrics files' {
        $Names = @($script:Plain1.Members | ForEach-Object Name | Sort-Object)
        $S = $script:Plain1.Stamp
        $Names | Should -Be @(
            "Consumption_ResourcesReport_$S.csv",
            "Diagnostics_ResourcesReport_$S.log",
            "Inventory_ResourcesReport_$S.json",
            "Metrics_ResourcesReport_$S.json",
            "ResourcesReport_$S.html"
        )
    }

    It 'an obfuscated run ships only its own JSON files and no real name' {
        $S = $script:Obfuscated.Stamp
        $Foreign = @($script:Obfuscated.Members | Where-Object { $_.Name -like '*.json' -and $_.Name -notlike "*_$S*" } | ForEach-Object Name)
        $Foreign | Should -BeNullOrEmpty -Because "every JSON file in the zip must belong to run $S"
        @($script:Obfuscated.Members | Where-Object Name -eq "Inventory_ResourcesReport_$S.json").Count | Should -Be 1
        @($script:Obfuscated.Members | Where-Object Name -eq "Metrics_ResourcesReport_$S.json").Count | Should -Be 1
        $WithRealName = @($script:Obfuscated.Members | Where-Object { $_.Text -match 'pip-demo' } | ForEach-Object Name)
        $WithRealName | Should -BeNullOrEmpty -Because 'an obfuscated zip must not carry a real resource name'
    }

    It 'a later plain run ships neither the dictionary nor an earlier run''s JSON' {
        $S = $script:Plain2.Stamp
        @($script:Plain2.Members | Where-Object Name -like 'ObfuscationDictionary_*') | Should -BeNullOrEmpty
        $Foreign = @($script:Plain2.Members | Where-Object { $_.Name -like '*.json' -and $_.Name -notlike "*_$S*" } | ForEach-Object Name)
        $Foreign | Should -BeNullOrEmpty -Because "every JSON file in the zip must belong to run $S"
        @($script:Plain2.Members | Where-Object Name -eq "Inventory_ResourcesReport_$S.json").Count | Should -Be 1
        @($script:Plain2.Members | Where-Object Name -eq "Metrics_ResourcesReport_$S.json").Count | Should -Be 1
    }
}
