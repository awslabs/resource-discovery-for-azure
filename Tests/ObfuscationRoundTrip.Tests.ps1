# Obfuscation round-trip tests
# Run with: Invoke-Pester ./Tests/ObfuscationRoundTrip.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# -Obfuscate must mask every identifying segment of every resource id in the
# shareable files, including a parent resource's name inside a child's id
# (a SQL database id holds its server's name), and Reveal.ps1 -All must give
# back what a run without -Obfuscate writes: ids with the subscription id,
# short names where the plain run writes short names, and consumption rows for
# resources that are not in the inventory.
#
# The test copies the scripts to a temp dir and runs the REAL
# ResourceInventory.ps1 twice in a child pwsh, once plain and once with
# -Obfuscate, with metrics and consumption on, over the same synthetic records:
# a SQL server with a database and an elastic pool (SQLDB and SQLPOOL child
# ids), a VM with a disk, and
# usage rows that include resources not in the inventory (a database of the
# same server, a Service Bus '$system' topic in another resource group, a disk
# in an AKS-managed 'mc_' group, a subscription-level resource). The Azure CLI,
# the Az cmdlets and Get-AzMetric are offline stand-ins. It then runs
# Reveal.ps1 -All on the obfuscated zip and compares every inventory, metrics
# and consumption value with the plain run. Cross-reference columns that hold
# another resource's short name in a plain run (DatabaseServer, ElasticPoolID,
# AssociatedResource) are compared by that name. The VM's name looks like a
# test one, so its masked id (the disk's AssociatedResource) is longer than the
# report's 200-character cell limit; the revealed HTML must hold no masked token,
# whole or cut. Generic names and the documentation placeholder subscription id
# only; no live Azure.

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ObfuscationRoundTrip_" + [guid]::NewGuid().ToString('N'))
    $script:Tree = Join-Path $script:WorkDir 'tree'
    New-Item -ItemType Directory -Path $script:Tree -Force | Out-Null
    foreach ($Item in @('ResourceInventory.ps1', 'Reveal.ps1', 'Version.json', 'Functions', 'Extension', 'Services'))
    {
        Copy-Item -Path (Join-Path $script:RepoRoot $Item) -Destination $script:Tree -Recurse -Force
    }

    # Stand-in Az.Monitor: Get-AzMetric runs in ForEach-Object -Parallel and
    # thread-job runspaces, which only a module on PSModulePath reaches.
    $MonitorDir = Join-Path $script:WorkDir 'modules/Az.Monitor'
    New-Item -ItemType Directory -Path $MonitorDir -Force | Out-Null
    @'
function Get-AzMetric
{
    [CmdletBinding()]
    param([string]$ResourceId, [string[]]$MetricName, [datetime]$StartTime, [datetime]$EndTime, [timespan]$TimeGrain, [string]$AggregationType, $DefaultProfile, [switch]$DetailedOutput)
    foreach ($Name in @($MetricName))
    {
        $Data = [System.Collections.Generic.List[object]]::new()
        $Data.Add([pscustomobject]@{ TimeStamp = $StartTime; Average = 2; Minimum = 1; Maximum = 3; Total = 6; Count = 3 })
        [pscustomobject]@{ Id = $ResourceId + '/providers/Microsoft.Insights/metrics/' + $Name; Name = [pscustomobject]@{ Value = $Name; LocalizedValue = $Name }; Data = $Data }
    }
}
Export-ModuleMember -Function Get-AzMetric
'@ | Set-Content -Path (Join-Path $MonitorDir 'Az.Monitor.psm1') -Encoding utf8

    $script:Harness = Join-Path $script:WorkDir 'run.ps1'
    @'
param([string]$Tree, [string]$Out, [string]$Modules, [switch]$Obfuscate)
$PSStyle.OutputRendering = 'PlainText'
$env:PSModulePath = $Modules + [System.IO.Path]::PathSeparator + $env:PSModulePath
$Global:RdaSessionInitialized = $true
$Global:AzPowerShellLoaded = $true
$Global:PlatformOS = 'PowerShell Unix'
$SubId = '12345678-1234-1234-1234-123456789012'
$Base = "/subscriptions/$SubId/resourceGroups/rg-demo/providers"
$Global:StandInSubs = @([pscustomobject]@{ id = $SubId; name = 'Demo Subscription'; tenantId = 'tenant-demo'; state = 'Enabled' })
$Global:StandInRows = @(
    @{ id = "$Base/Microsoft.Sql/servers/sqlsrv-demo"; name = 'sqlsrv-demo'; type = 'microsoft.sql/servers'; kind = 'v12.0'; location = 'eastus'; subscriptionId = $SubId; resourceGroup = 'rg-demo'; properties = @{ state = 'Ready'; version = '12.0' } }
    @{ id = "$Base/Microsoft.Sql/servers/sqlsrv-demo/databases/sqldb-demo"; name = 'sqldb-demo'; type = 'microsoft.sql/servers/databases'; kind = 'v12.0,user,vcore'; location = 'eastus'; subscriptionId = $SubId; resourceGroup = 'rg-demo'
        properties = @{ status = 'Online'; maxSizeBytes = 34359738368; currentSku = @{ tier = 'GeneralPurpose'; capacity = 2 }; currentBackupStorageRedundancy = 'Geo'; elasticPoolId = "$Base/Microsoft.Sql/servers/sqlsrv-demo/elasticPools/pool-demo" } }
    @{ id = "$Base/Microsoft.Sql/servers/sqlsrv-demo/elasticPools/pool-demo"; name = 'pool-demo'; type = 'microsoft.sql/servers/elasticpools'; location = 'eastus'; subscriptionId = $SubId; resourceGroup = 'rg-demo'; properties = @{ state = 'Ready' } }
    @{ id = "$Base/Microsoft.Compute/virtualMachines/vm-test-demo"; name = 'vm-test-demo'; type = 'microsoft.compute/virtualmachines'; location = 'eastus'; subscriptionId = $SubId; resourceGroup = 'rg-demo'; properties = @{ hardwareProfile = @{ vmSize = 'Standard_D2s_v3' }; storageProfile = @{ osDisk = @{ osType = 'Linux' } } } }
    @{ id = "$Base/Microsoft.Compute/disks/disk-demo"; name = 'disk-demo'; type = 'microsoft.compute/disks'; location = 'eastus'; subscriptionId = $SubId; resourceGroup = 'rg-demo'; managedBy = "$Base/Microsoft.Compute/virtualMachines/vm-test-demo"
        sku = @{ name = 'Premium_LRS' }; properties = @{ diskSizeGB = 32; diskState = 'Attached'; timeCreated = '2024-03-15T09:41:27Z' } }
)
# Usage rows: the database in the inventory, and resources that are not in it.
$Global:StandInUsage = @(
    "/subscriptions/$SubId/resourceGroups/rg-demo/providers/Microsoft.Sql/servers/sqlsrv-demo/databases/sqldb-demo"
    "/subscriptions/$SubId/resourceGroups/rg-demo/providers/Microsoft.Sql/servers/sqlsrv-demo/databases/sqldb-gone"
    "/subscriptions/$SubId/resourceGroups/rg-gone/providers/Microsoft.ServiceBus/namespaces/sb-gone/topics/`$system"
    "/subscriptions/$SubId/resourceGroups/MC_rg-aks_aks-gone_eastus/providers/Microsoft.Compute/disks/osdisk-gone"
    "/subscriptions/$SubId/providers/Microsoft.Insights/components/insights-gone"
) | ForEach-Object {
    [pscustomobject]@{
        InstanceData     = (@{ 'Microsoft.Resources' = @{ resourceUri = $_; location = 'eastus'; additionalInfo = @{ ServiceType = 'Standard'; ConsumptionMeter = 'meter-demo' } } } | ConvertTo-Json -Depth 5 -Compress)
        MeterCategory    = 'SQL Database'; MeterId = 'meter-demo'; MeterName = 'vCore'; MeterRegion = 'US East'; MeterSubCategory = 'General Purpose'
        Quantity         = [decimal]24; Unit = '1 Hour'
        UsageStartTime   = [datetime]::SpecifyKind([datetime]'2026-10-01T00:00:00', 'Utc'); UsageEndTime = [datetime]::SpecifyKind([datetime]'2026-10-02T00:00:00', 'Utc')
    }
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
function global:Get-UsageAggregates
{
    [CmdletBinding()]
    param($ReportedStartTime, $ReportedEndTime, $AggregationGranularity, $ShowDetails, $ContinuationToken)
    [pscustomobject]@{ UsageAggregations = @($Global:StandInUsage | ForEach-Object { [pscustomobject]@{ Properties = $_.PSObject.Copy() } }); ContinuationToken = $null }
}
function global:Invoke-AzRestMethod
{
    param($Method, $Path, $Payload, $Uri)
    $Target = if ($Path) { $Path } else { $Uri }
    $Json = { param($Obj) [pscustomobject]@{ StatusCode = 200; Content = ($Obj | ConvertTo-Json -Depth 10) } }
    if ($Target -match '/roleAssignments\?') { return (& $Json @{ value = @(@{ properties = @{ roleDefinitionId = "/subscriptions/$SubId/providers/Microsoft.Authorization/roleDefinitions/reader"; scope = "/subscriptions/$SubId"; principalId = 'test-oid'; principalType = 'ServicePrincipal' } }) }) }
    if ($Target -match '/roleDefinitions/') { return (& $Json @{ properties = @{ roleName = 'Reader'; type = 'BuiltInRole'; permissions = @(@{ actions = @('*/read'); notActions = @() }) } }) }
    if ($Target -match '/providers/Microsoft\.Authorization/permissions\?') { return (& $Json @{ value = @(@{ actions = @('*/read'); notActions = @() }) }) }
    if ($Target -match '/UsageAggregates\?') { return (& $Json @{ value = @(@{ properties = @{ quantity = 24; instanceData = $Global:StandInUsage[0].InstanceData } }) }) }
    if ($Target -match 'Microsoft\.ResourceGraph/resources') { return (& $Json @{ data = @(@{ subscriptionId = $SubId; ResourceCount = @($Global:StandInRows).Count }) }) }
    throw ('no stand-in for {0} {1}' -f $Method, $Target)
}

$Params = @{ SubscriptionID = $SubId; OutputDirectory = $Out; Service = @('SQLSERVER', 'SQLDB', 'SQLPOOL', 'VMDisk') }
if ($Obfuscate) { $Params.Obfuscate = $true }
Set-Location $Tree
& (Join-Path $Tree 'ResourceInventory.ps1') @Params
exit $LASTEXITCODE
'@ | Set-Content -Path $script:Harness -Encoding utf8

    function Invoke-InventoryRun
    {
        param([string]$Label, [switch]$Obfuscate)
        $Out = Join-Path $script:WorkDir ('out_' + $Label)
        New-Item -ItemType Directory -Path $Out -Force | Out-Null
        $ArgList = @('-NoProfile', '-NonInteractive', '-File', $script:Harness, '-Tree', $script:Tree, '-Out', $Out, '-Modules', (Join-Path $script:WorkDir 'modules'))
        if ($Obfuscate) { $ArgList += '-Obfuscate' }
        $Console = @(& pwsh @ArgList 2>&1 | ForEach-Object { [string]$_ })
        return [pscustomobject]@{
            Exit       = $LASTEXITCODE
            Console    = ($Console -join "`n")
            Zip        = @(Get-ChildItem -Path $Out -Filter 'ResourcesReport_*.zip' -File)[0]
            Dictionary = @(Get-ChildItem -Path $Out -Filter 'ObfuscationDictionary_*.json' -File)[0]
        }
    }

    # One record as JSON with its properties in name order, at every depth: the
    # collectors build records as hashtables, whose key order differs between
    # processes.
    function ConvertTo-CanonicalJson
    {
        param($Value)
        $Sort = {
            param($V)
            if ($V -is [System.Management.Automation.PSCustomObject])
            {
                $O = [ordered]@{}
                foreach ($Pr in @($V.PSObject.Properties | Sort-Object Name)) { $O[$Pr.Name] = & $Sort $Pr.Value }
                return $O
            }
            if ($V -is [System.Collections.IList] -and $V -isnot [string]) { return , @(foreach ($E in $V) { & $Sort $E }) }
            return $V
        }
        return (ConvertTo-Json -InputObject (& $Sort $Value) -Depth 12 -Compress)
    }

    # The report zip's members: inventory records (cross-reference columns cut to
    # the referenced resource's name), metrics
    # records, consumption rows, the HTML, and every member's text.
    function Read-Report
    {
        param([string]$Zip)
        $Dir = Join-Path $script:WorkDir ('x_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        Expand-Archive -Path $Zip -DestinationPath $Dir -Force
        $Inventory = Get-Content -Raw -Path (Get-ChildItem $Dir -Filter 'Inventory_*.json')[0].FullName | ConvertFrom-Json
        $Records = [System.Collections.Generic.List[string]]::new()
        foreach ($Collector in $Inventory.PSObject.Properties | Where-Object { $_.Name -ne 'Version' })
        {
            foreach ($Rec in @($Collector.Value))
            {
                $Copy = $Rec.PSObject.Copy()
                foreach ($Column in @('DatabaseServer', 'ElasticPoolID', 'AssociatedResource'))
                {
                    if ($Copy.PSObject.Properties.Name -contains $Column -and $Copy.$Column -is [string]) { $Copy.$Column = ($Copy.$Column -split '/')[-1] }
                }
                $Records.Add($Collector.Name + ' ' + (ConvertTo-CanonicalJson $Copy))
            }
        }
        $Metrics = @(Get-ChildItem $Dir -Filter 'Metrics_*.json' | ForEach-Object { (Get-Content -Raw -Path $_.FullName | ConvertFrom-Json).Metrics } | Where-Object { $null -ne $_ } |
                ForEach-Object { ConvertTo-CanonicalJson $_ })
        $CsvFile = (Get-ChildItem $Dir -Filter 'Consumption_*.csv')[0].FullName
        return [pscustomobject]@{
            Inventory = @($Records | Sort-Object)
            Metrics   = @($Metrics | Sort-Object)
            Csv       = @(Import-Csv -Path $CsvFile | ForEach-Object { ConvertTo-Json -InputObject $_ -Compress } | Sort-Object)
            CsvRows   = @(Import-Csv -Path $CsvFile)
            Html      = Get-Content -Raw -Path (Get-ChildItem $Dir -Filter '*.html')[0].FullName
            Text      = @(Get-ChildItem $Dir -File | ForEach-Object { [pscustomobject]@{ File = $_.Name; Text = (Get-Content -Raw -Path $_.FullName) } })
            Raw       = $Inventory
        }
    }

    $script:Plain = Invoke-InventoryRun -Label 'plain'
    $script:Obf = Invoke-InventoryRun -Label 'obf' -Obfuscate
    $script:RevealedZip = Join-Path $script:WorkDir 'revealed.zip'
    if ($null -ne $script:Obf.Zip -and $null -ne $script:Obf.Dictionary)
    {
        $null = & pwsh -NoProfile -NonInteractive -File (Join-Path $script:Tree 'Reveal.ps1') -InputZip $script:Obf.Zip.FullName -DictionaryPath $script:Obf.Dictionary.FullName -All -OutputZip $script:RevealedZip 2>&1
    }
    # A run that wrote no zip leaves its report $null, so each test reports it.
    $script:P = if ($null -ne $script:Plain.Zip) { Read-Report $script:Plain.Zip.FullName } else { $null }
    $script:O = if ($null -ne $script:Obf.Zip) { Read-Report $script:Obf.Zip.FullName } else { $null }
    $script:R = if (Test-Path -LiteralPath $script:RevealedZip) { Read-Report $script:RevealedZip } else { $null }

    # Every real identifying value of the synthetic estate.
    $script:RealValues = @('12345678-1234-1234-1234-123456789012', 'Demo Subscription', 'rg-demo', 'sqlsrv-demo', 'sqldb-demo', 'pool-demo', 'vm-test-demo', 'disk-demo',
        'sqldb-gone', 'rg-gone', 'sb-gone', 'mc_rg-aks_aks-gone_eastus', 'osdisk-gone', 'insights-gone')
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
    {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'The two runs' {
    It 'both finish and write a report zip, and the obfuscated run writes a dictionary' {
        $script:Plain.Exit | Should -Be 0 -Because $script:Plain.Console
        $script:Obf.Exit | Should -Be 0 -Because $script:Obf.Console
        $script:Plain.Zip | Should -Not -BeNullOrEmpty -Because $script:Plain.Console
        $script:Obf.Zip | Should -Not -BeNullOrEmpty -Because $script:Obf.Console
        $script:Obf.Dictionary | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $script:RevealedZip | Should -BeTrue
    }

    It 'collect the same records: 4 inventory, metrics for the database and the VM, 5 usage rows' {
        $script:P.Inventory.Count | Should -Be 4
        $script:O.Inventory.Count | Should -Be 4
        $script:P.Metrics.Count | Should -BeGreaterThan 0
        $script:O.Metrics.Count | Should -Be $script:P.Metrics.Count
        $script:P.CsvRows.Count | Should -Be 5
        $script:O.CsvRows.Count | Should -Be 5
    }
}

Describe '-Obfuscate masks every identifying segment' {
    It 'leaves no real name, group, subscription id or subscription name in <File>' -ForEach @(
        @{ File = 'inventory' }, @{ File = 'metrics' }, @{ File = 'consumption' }, @{ File = 'report HTML' }, @{ File = 'diagnostics log' }
    ) {
        $Pattern = @{ 'inventory' = '^Inventory_'; 'metrics' = '^Metrics_'; 'consumption' = '^Consumption_'; 'report HTML' = '\.html$'; 'diagnostics log' = '^Diagnostics_' }[$File]
        $Members = @($script:O.Text | Where-Object { $_.File -match $Pattern })
        $Members.Count | Should -BeGreaterThan 0
        foreach ($Member in $Members)
        {
            foreach ($Real in $script:RealValues)
            {
                $Member.Text.IndexOf($Real, [System.StringComparison]::OrdinalIgnoreCase) | Should -Be -1 -Because "'$Real' must not appear in $($Member.File)"
            }
        }
    }

    It 'gives a child the same parent token as the parent''s own masked id, so ids still join' {
        $Server = @($script:O.Raw.SQLSERVER)[0]
        $Database = @($script:O.Raw.SQLDB)[0]
        $Database.ID.StartsWith($Server.ID + '/databases/') | Should -BeTrue -Because "$($Database.ID) should start with $($Server.ID)"
        ($Database.ID -split '/').Count | Should -Be (($script:P.Raw.SQLDB)[0].ID -split '/').Count
        ($Database.ID -split '/')[-1] | Should -Be $Database.Name
    }

    It 'writes the database''s masked id, with the parent masked, on every one of its metric records' {
        $Database = @($script:O.Raw.SQLDB)[0]
        $DbMetrics = @($script:O.Metrics | ConvertFrom-Json | Where-Object { $_.Service -eq 'SQL Database' })
        $DbMetrics.Count | Should -BeGreaterThan 0
        foreach ($Metric in $DbMetrics) { $Metric.ID | Should -BeExactly $Database.ID }
    }

    It 'uses the inventory''s tokens in the consumption row of a database of the same server that is not in the inventory' {
        $Server = @($script:O.Raw.SQLSERVER)[0]
        @($script:O.CsvRows | Where-Object { $_.ResourceId.StartsWith($Server.ID + '/databases/') }).Count | Should -Be 2
    }
}

Describe 'Reveal.ps1 -All gives back the plain run' {
    It 'restores every inventory record exactly' {
        $script:R.Inventory | Should -Be $script:P.Inventory
    }

    It 'restores every metrics record exactly' {
        $script:R.Metrics | Should -Be $script:P.Metrics
    }

    It 'restores every consumption row exactly, including resources not in the inventory' {
        $script:R.Csv | Should -Be $script:P.Csv
    }

    It 'restores the subscription id, not its display name, inside resource ids' {
        foreach ($Row in $script:R.CsvRows) { $Row.ResourceId | Should -Match '^/subscriptions/12345678-1234-1234-1234-123456789012(/|$)' }
        @($script:R.Raw.SQLDB)[0].Subscription | Should -Be 'Demo Subscription'
    }

    It 'replaces the obfuscated-report banner in the revealed HTML' {
        $script:O.Html | Should -Match 'privacy-banner obfuscated'
        $script:R.Html | Should -Not -Match 'privacy-banner obfuscated'
        $script:R.Html | Should -Not -Match 'Real identifiers are not present'
        $script:R.Html | Should -Match 'privacy-banner identifiable'
    }
}

Describe 'Reveal.ps1 -All on a report and dictionary in the format earlier versions wrote' {
    # Earlier versions kept a child's parent name in its masked id, used the
    # subscription display-name token for the subscription segment, and gave a
    # consumption row for a resource not in the inventory tokens that only the
    # whole masked id in ResourceIdMap could reverse (an AKS 'mc_' group got a
    # 'prod_rg_mc_' token there). Tokens are generated at runtime.
    BeforeAll {
        $G = '12345678-1234-1234-1234-123456789012'
        $New = { param([string]$Hint) 'prod_' + $Hint + [guid]::NewGuid().ToString() }
        $Sub = & $New ''; $Rg = & $New ''; $Srv = & $New ''; $Db = & $New ''
        $GoneSub = & $New 'sub_'; $GoneRg = & $New 'rg_mc_'; $GoneName = & $New ''; $AksRg = & $New 'rg_mc_'
        $RealSrv = "/subscriptions/$G/resourcegroups/rg-old/providers/microsoft.sql/servers/sqlsrv-old"
        $RealDb = "$RealSrv/databases/sqldb-old"
        $RealGone = "/subscriptions/$G/resourcegroups/mc_rg-aks_aks-old_eastus/providers/microsoft.compute/disks/osdisk-old"
        $MaskSrv = "/subscriptions/$Sub/resourcegroups/$Rg/providers/microsoft.sql/servers/$Srv"
        $MaskDb = "/subscriptions/$Sub/resourcegroups/$Rg/providers/microsoft.sql/servers/sqlsrv-old/databases/$Db"
        $MaskGone = "/subscriptions/$GoneSub/resourcegroups/$GoneRg/providers/microsoft.compute/disks/$GoneName"
        $script:OldExpected = @{ Srv = $RealSrv; Db = $RealDb; Gone = $RealGone }

        $Dir = Join-Path $script:WorkDir 'old-format'
        $Stage = Join-Path $Dir 'stage'
        New-Item -ItemType Directory -Path $Stage -Force | Out-Null
        [ordered]@{
            SQLSERVER = @([ordered]@{ ID = $MaskSrv; Subscription = $Sub; ResourceGroup = $Rg; Name = $Srv })
            SQLDB     = @([ordered]@{ ID = $MaskDb; Subscription = $Sub; ResourceGroup = $Rg; Name = $Db; DatabaseServer = $MaskSrv })
            AKS       = @([ordered]@{ ID = $MaskSrv; Subscription = $Sub; ResourceGroup = $AksRg; Name = $Srv })
        } | ConvertTo-Json -Depth 6 -Compress | Set-Content -Path (Join-Path $Stage 'Inventory_Old.json') -Encoding utf8
        @(
            [pscustomobject]@{ InstanceData = (@{ 'Microsoft.Resources' = @{ ResourceUri = $MaskDb } } | ConvertTo-Json -Compress); ResourceId = $MaskDb; Quantity = '24' }
            [pscustomobject]@{ InstanceData = (@{ 'Microsoft.Resources' = @{ ResourceUri = $MaskGone } } | ConvertTo-Json -Compress); ResourceId = $MaskGone; Quantity = '1' }
        ) | Export-Csv -Path (Join-Path $Stage 'Consumption_Old.csv') -NoTypeInformation -Encoding utf8
        $script:OldZip = Join-Path $Dir 'ResourcesReport_Old.zip'
        Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $script:OldZip -Force
        $OldDict = Join-Path $Dir 'ObfuscationDictionary_Old.json'
        [ordered]@{
            GeneratedAt         = '2026-10-01 00:00:00'
            ResourceIdMap       = [ordered]@{ $MaskSrv = $RealSrv; $MaskDb = $RealDb; $MaskGone = $RealGone }
            ResourceNameMap     = [ordered]@{ $Srv = $RealSrv; $Db = $RealDb }
            SubscriptionMap     = [ordered]@{ $Sub = $RealDb }
            ResourceGroupMap    = [ordered]@{ $Rg = $RealDb; $AksRg = $RealGone }
            SubscriptionNameMap = [ordered]@{ $Sub = 'Demo Subscription' }
            TagMap              = [ordered]@{}
            FreeTextMap         = [ordered]@{}
        } | ConvertTo-Json -Depth 4 | Set-Content -Path $OldDict -Encoding utf8

        $Out = Join-Path $Dir 'revealed.zip'
        $null = & pwsh -NoProfile -NonInteractive -File (Join-Path $script:Tree 'Reveal.ps1') -InputZip $script:OldZip -DictionaryPath $OldDict -All -OutputZip $Out 2>&1
        $Ex = Join-Path $Dir 'ex'
        Expand-Archive -Path $Out -DestinationPath $Ex -Force
        $script:OldInv = Get-Content -Raw -Path (Join-Path $Ex 'Inventory_Old.json') | ConvertFrom-Json
        $script:OldCsv = @(Import-Csv -Path (Join-Path $Ex 'Consumption_Old.csv'))
        $script:OldText = (Get-Content -Raw -Path (Join-Path $Ex 'Inventory_Old.json')) + (Get-Content -Raw -Path (Join-Path $Ex 'Consumption_Old.csv'))
    }

    It 'restores the ids with the subscription id, and the subscription display name' {
        $script:OldInv.SQLSERVER[0].ID | Should -BeExactly $script:OldExpected.Srv
        $script:OldInv.SQLDB[0].ID | Should -BeExactly $script:OldExpected.Db
        $script:OldInv.SQLDB[0].DatabaseServer | Should -BeExactly $script:OldExpected.Srv
        $script:OldInv.SQLDB[0].Subscription | Should -BeExactly 'Demo Subscription'
    }

    It 'restores a consumption row of a resource not in the inventory from its whole masked id' {
        $script:OldCsv[0].ResourceId | Should -BeExactly $script:OldExpected.Db
        $script:OldCsv[1].ResourceId | Should -BeExactly $script:OldExpected.Gone
        ($script:OldCsv[1].InstanceData | ConvertFrom-Json).'Microsoft.Resources'.ResourceUri | Should -BeExactly $script:OldExpected.Gone
    }

    It 'reveals a resource group token with two hint words (AKS ''mc_'' group)' {
        $script:OldInv.AKS[0].ResourceGroup | Should -BeExactly 'mc_rg-aks_aks-old_eastus'
    }

    It 'leaves no token in the revealed inventory or consumption file' {
        $script:OldText | Should -Not -Match '(?:prod|nonprod)_(?:[a-z0-9]+_)*[0-9a-f]{8}-'
    }
}

Describe 'The report HTML of the obfuscated run and its Reveal.ps1 -All copy' {
    It 'keeps a cell longer than 200 characters whole when its cut would split a masked token' {
        $Masked = @($script:O.Raw.VMDisk)[0].AssociatedResource
        $Masked.Length | Should -BeGreaterThan 200
        $Masked | Should -Match '/nonprod_[0-9a-f-]{36}$'
        $script:O.Html.Contains('<td>' + $Masked + '</td>') | Should -BeTrue -Because "the cell should hold '$Masked' whole"
    }

    It 'leaves no masked token, whole or cut, in the revealed HTML' {
        $Left = @([regex]::Matches($script:R.Html, '(?:non)?prod_[0-9a-z_-]*') | ForEach-Object { $_.Value })
        $Left.Count | Should -Be 0 -Because ('these remain: ' + ($Left -join ', '))
    }

    It 'shows the revealed disk''s AssociatedResource cell as the revealed inventory holds it' {
        $Revealed = @($script:R.Raw.VMDisk)[0].AssociatedResource
        $Revealed | Should -Match '/virtualmachines/vm-test-demo$'
        $script:R.Html.Contains('<td>' + $Revealed + '</td>') | Should -BeTrue -Because "the cell should read '$Revealed'"
    }
}
