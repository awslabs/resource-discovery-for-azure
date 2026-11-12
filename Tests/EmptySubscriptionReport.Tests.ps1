# Report header of an empty subscription
# Run with: Invoke-Pester ./Tests/EmptySubscriptionReport.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# A subscription with no resources got a report whose header read
# 'Total Resources:' with nothing after it, where 0 belongs, and
# 'Subscription: (unknown)', where the subscription's name belongs.
# Extension/Summary.ps1 summed the record counts with Measure-Object, which
# gives no sum for no input, and took the subscription name from the first
# record, of which there is none.
#
# The test copies the scripts to a temp folder and runs the REAL
# ResourceInventory.ps1 in a child pwsh, with the default metrics and
# consumption phases, against offline stand-ins for the Azure CLI and the Az
# cmdlets: once for a subscription with no resources and once for one with a
# single disk, each without and with -Obfuscate. It reads the header of the
# report in the output folder and of the copy in the zip. Generic names and the
# documentation placeholder subscription id only; no live Azure.

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("EmptySubscriptionReport_" + [guid]::NewGuid().ToString('N'))
    $script:Tree = Join-Path $script:WorkDir 'tree'
    New-Item -ItemType Directory -Path $script:Tree -Force | Out-Null
    foreach ($Item in @('ResourceInventory.ps1', 'Version.json', 'Functions', 'Extension', 'Services'))
    {
        Copy-Item -Path (Join-Path $script:RepoRoot $Item) -Destination $script:Tree -Recurse -Force
    }

    $script:Harness = Join-Path $script:WorkDir 'run.ps1'
    @'
param([string]$Tree, [string]$Out, [switch]$WithDisk, [switch]$Obfuscate)
$PSStyle.OutputRendering = 'PlainText'
$Global:RdaSessionInitialized = $true
$Global:AzPowerShellLoaded = $true
$Global:PlatformOS = 'PowerShell Unix'
$SubId = '12345678-1234-1234-1234-123456789012'
$Global:StandInSubs = @([pscustomobject]@{ id = $SubId; name = 'Demo Subscription'; tenantId = 'tenant-demo'; state = 'Enabled' })
$Global:StandInRows = @()
if ($WithDisk)
{
    $Global:StandInRows = @(@{ id = "/subscriptions/$SubId/resourceGroups/rg-demo/providers/Microsoft.Compute/disks/disk-demo"; name = 'disk-demo'; type = 'microsoft.compute/disks'; location = 'eastus'; subscriptionId = $SubId; resourceGroup = 'rg-demo'
            sku = @{ name = 'Premium_LRS' }; properties = @{ diskSizeGB = 32; diskState = 'Unattached'; timeCreated = '2024-03-15T09:41:27Z' } })
}
function global:az
{
    $Joined = $args -join ' '
    $global:LASTEXITCODE = 0
    if ($Joined -like 'account show*') { return '{"user":{"name":"tester"},"tenantId":"tenant-demo"}' }
    if ($Joined -like 'account list*') { return (ConvertTo-Json -InputObject @($Global:StandInSubs) -Compress) }
    if ($Joined -like 'graph*')
    {
        if ($Joined -match 'desktopvirtualizationresources') { return '{"data":[{"count_":0}],"count":1}' }
        if ($Joined -match 'summarize count\(\)') { return ('{{"data":[{{"count_":{0}}}],"count":1}}' -f @($Global:StandInRows).Count) }
        return (@{ data = @($Global:StandInRows); count = @($Global:StandInRows).Count } | ConvertTo-Json -Depth 8 -Compress)
    }
    return $null
}
function global:Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = 'tenant-demo' }; Subscription = [pscustomobject]@{ Id = '12345678-1234-1234-1234-123456789012'; Name = 'Demo Subscription' }; Account = [pscustomobject]@{ Id = 'tester' } } }
function global:Set-AzContext { [CmdletBinding()] param($Subscription, $Scope, $Context) $null }
function global:Connect-AzAccount { throw 'no sign-in in this harness' }
function global:Get-AzAccessToken { param($ResourceUrl) [pscustomobject]@{ Token = ('e30.' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"oid":"test-oid"}')).TrimEnd('=') + '.sig') } }
function global:Get-AzMetric { [CmdletBinding()] param($ResourceId, $MetricName, $StartTime, $EndTime, $TimeGrain, $AggregationType, $DefaultProfile) }
function global:Get-UsageAggregates { [CmdletBinding()] param($ReportedStartTime, $ReportedEndTime, $AggregationGranularity, $ShowDetails, $ContinuationToken) [pscustomobject]@{ UsageAggregations = @(); ContinuationToken = $null } }
function global:Invoke-AzRestMethod
{
    param($Method, $Path, $Payload, $Uri)
    $Target = if ($Path) { $Path } else { $Uri }
    $Json = { param($Obj) [pscustomobject]@{ StatusCode = 200; Content = ($Obj | ConvertTo-Json -Depth 10) } }
    if ($Target -match '/roleAssignments\?') { return (& $Json @{ value = @(@{ properties = @{ roleDefinitionId = "/subscriptions/$SubId/providers/Microsoft.Authorization/roleDefinitions/reader"; scope = "/subscriptions/$SubId"; principalId = 'test-oid'; principalType = 'ServicePrincipal' } }) }) }
    if ($Target -match '/roleDefinitions/') { return (& $Json @{ properties = @{ roleName = 'Reader'; type = 'BuiltInRole'; permissions = @(@{ actions = @('*/read'); notActions = @() }) } }) }
    if ($Target -match '/providers/Microsoft\.Authorization/permissions\?') { return (& $Json @{ value = @(@{ actions = @('*/read'); notActions = @() }) }) }
    if ($Target -match '/UsageAggregates\?') { return (& $Json @{ value = @() }) }
    if ($Target -match 'Microsoft\.ResourceGraph/resources') { return (& $Json @{ data = @(@($Global:StandInRows) | ForEach-Object { @{ subscriptionId = $SubId; ResourceCount = 1 } }) }) }
    throw ('no stand-in for {0} {1}' -f $Method, $Target)
}

$Params = @{ SubscriptionID = $SubId; OutputDirectory = $Out; Service = @('VMDisk', 'SQLSERVER') }
if ($Obfuscate) { $Params.Obfuscate = $true }
Set-Location $Tree
& (Join-Path $Tree 'ResourceInventory.ps1') @Params
exit $LASTEXITCODE
'@ | Set-Content -Path $script:Harness -Encoding utf8

    # One direct run; returns its exit code, console text, and the header lines
    # of the report in the output folder and of its copy in the zip.
    function Invoke-DirectRun
    {
        param([switch]$WithDisk, [switch]$Obfuscate)
        $Out = Join-Path $script:WorkDir ('out_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $Out -Force | Out-Null
        $ArgList = @('-NoProfile', '-NonInteractive', '-File', $script:Harness, '-Tree', $script:Tree, '-Out', $Out)
        if ($WithDisk) { $ArgList += '-WithDisk' }
        if ($Obfuscate) { $ArgList += '-Obfuscate' }
        $Console = @(& pwsh @ArgList 2>&1 | ForEach-Object { [string]$_ })
        $Exit = $LASTEXITCODE
        $Html = @(Get-ChildItem -Path $Out -Filter 'ResourcesReport_*.html' -File)[0]
        $Zip = @(Get-ChildItem -Path $Out -Filter 'ResourcesReport_*.zip' -File)[0]
        $ZipHtml = $null
        if ($null -ne $Zip)
        {
            $Ex = Join-Path $Out 'zip'
            Expand-Archive -Path $Zip.FullName -DestinationPath $Ex -Force
            $ZipHtml = @(Get-ChildItem -Path $Ex -Filter '*.html' -File)[0]
        }
        $Read = { param($File) if ($null -eq $File) { $null } else { Get-Content -Raw -Path $File.FullName } }
        return [pscustomobject]@{
            Exit    = $Exit
            Console = ($Console -join "`n")
            Html    = (& $Read $Html)
            ZipHtml = (& $Read $ZipHtml)
        }
    }

    function Get-HeaderValue
    {
        param([string]$Html, [string]$Label)
        if ($Html -match ('<div><b>' + [regex]::Escape($Label) + ':</b> ([^<]*)</div>')) { return $Matches[1] }
        return '<no such line>'
    }

    $script:Empty = Invoke-DirectRun
    $script:EmptyObf = Invoke-DirectRun -Obfuscate
    $script:OneDisk = Invoke-DirectRun -WithDisk
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
    {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Report header of a subscription with no resources' {
    It 'the run finishes and writes the report and the zip' {
        $script:Empty.Exit | Should -Be 0 -Because $script:Empty.Console
        $script:Empty.Html | Should -Not -BeNullOrEmpty -Because $script:Empty.Console
        $script:Empty.ZipHtml | Should -Not -BeNullOrEmpty
    }

    It 'shows Total Resources 0 in the <Copy>' -ForEach @(@{ Copy = 'folder report'; Key = 'Html' }, @{ Copy = 'zip copy'; Key = 'ZipHtml' }) {
        Get-HeaderValue -Html $script:Empty.$Key -Label 'Total Resources' | Should -BeExactly '0'
        Get-HeaderValue -Html $script:Empty.$Key -Label 'Service Types' | Should -BeExactly '0'
    }

    It 'shows the subscription''s name in the <Copy>' -ForEach @(@{ Copy = 'folder report'; Key = 'Html' }, @{ Copy = 'zip copy'; Key = 'ZipHtml' }) {
        Get-HeaderValue -Html $script:Empty.$Key -Label 'Subscription' | Should -BeExactly 'Demo Subscription'
    }

    It 'prints 0 total resources on the console' {
        $script:Empty.Console | Should -Match 'Total resources: 0 across 0 service type\(s\)'
    }
}

Describe 'Report header of an obfuscated run of a subscription with no resources' {
    It 'shows Total Resources 0, and not the real subscription name anywhere in the report' {
        $script:EmptyObf.Exit | Should -Be 0 -Because $script:EmptyObf.Console
        Get-HeaderValue -Html $script:EmptyObf.Html -Label 'Total Resources' | Should -BeExactly '0'
        $script:EmptyObf.Html | Should -Not -Match 'Demo Subscription'
        $script:EmptyObf.ZipHtml | Should -Not -Match 'Demo Subscription'
    }
}

Describe 'Report header of a subscription with one resource' {
    It 'shows Total Resources 1 and the subscription''s name, as before' {
        $script:OneDisk.Exit | Should -Be 0 -Because $script:OneDisk.Console
        Get-HeaderValue -Html $script:OneDisk.Html -Label 'Total Resources' | Should -BeExactly '1'
        Get-HeaderValue -Html $script:OneDisk.Html -Label 'Subscription' | Should -BeExactly 'Demo Subscription'
        Get-HeaderValue -Html $script:OneDisk.ZipHtml -Label 'Total Resources' | Should -BeExactly '1'
    }
}
