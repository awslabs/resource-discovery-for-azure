# Collector date tests
# Run with: Invoke-Pester ./Tests/CollectorDates.Tests.ps1 -Output Detailed
#
# Dates: Azure returns creation and modification times in UTC, with a Z or an
# offset. A [datetime] cast or Get-Date turned them into the host's local time,
# and the columns show no zone, so the same resource got a different time
# depending on where the tool ran. Each date column is now written as UTC text
# on every host; a value with no zone is taken as UTC. The host-zone case runs
# the real collectors in child pwsh processes with TZ set, once at UTC+14
# (Pacific/Kiritimati) and once at UTC-11 (Pacific/Pago_Pago), so a time written
# in host local time always differs between the two. A host whose child pwsh
# does not apply TZ skips that case.
#
# Records are built the way Resource Graph answers reach the collectors: JSON
# text, lowercased (Invoke-AzGraphQuerySafe -Lowercase), then ConvertFrom-Json.
# No live Azure is needed. All ids use the Azure documentation placeholder
# subscription id.

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $script:DocGuid = '12345678-1234-1234-1234-123456789012'

    # The same instant in the four forms a value can take: Z, +00:00, another
    # offset, and no zone (taken as UTC).
    $script:Forms = @('2024-03-15T21:41:27.1234567Z', '2024-03-15T21:41:27.1234567+00:00', '2024-03-15T23:41:27.1234567+02:00', '2024-03-15T21:41:27.1234567')

    # Collector, record type, the date properties it reads, and the expected
    # text of each date column for 2024-03-15 21:41:27.1234567 UTC.
    $script:DateCases = @(
        @{ Collector = 'Analytics/Databricks'; Type = 'microsoft.databricks/workspaces'; Props = @('createdDateTime'); Expect = @{ CreatedTime = '2024-03-15 21:41' } }
        @{ Collector = 'Analytics/EvtHub'; Type = 'microsoft.eventhub/namespaces'; Props = @('createdAt'); Expect = @{ CreatedTime = '2024-03-15 21:41' } }
        @{ Collector = 'Analytics/MachineLearning'; Type = 'microsoft.machinelearningservices/workspaces'; Props = @('creationTime'); Expect = @{ CreatedTime = '2024-03-15 21:41' } }
        @{ Collector = 'Analytics/Streamanalytics'; Type = 'microsoft.streamanalytics/streamingjobs'; Props = @('createdDate', 'lastOutputEventTime', 'outputStartTime'); Expect = @{ CreatedDate = '2024-03-15 21:41:27'; LastOutputEventTime = '2024-03-15 21:41:27:1234'; OutputStartTime = '2024-03-15 21:41:27:1234' } }
        @{ Collector = 'Analytics/WrkSpace'; Type = 'microsoft.operationalinsights/workspaces'; Props = @('createdDate'); Expect = @{ CreatedTime = '2024-03-15 21:41' } }
        @{ Collector = 'Containers/REGISTRIES'; Type = 'microsoft.containerregistry/registries'; Props = @('creationDate'); Expect = @{ CreatedTime = '2024-03-15 21:41' } }
        @{ Collector = 'Data/Purview'; Type = 'microsoft.purview/accounts'; Props = @('createdAt'); Expect = @{ CreatedTime = '2024-03-15 21:41' } }
        @{ Collector = 'Infrastructure/AutomationAcc'; Type = 'microsoft.automation/automationaccounts'; Props = @('creationTime'); Expect = @{ AutomationAccountCreatedTime = '2024-03-15 21:41'; LastModifiedTime = '2024-03-15 21:41' } }
        @{ Collector = 'Integration/AppInsights'; Type = 'microsoft.insights/components'; Props = @('CreationDate'); Expect = @{ CreatedTime = '2024-03-15 21:41' } }
        @{ Collector = 'Integration/ServiceBUS'; Type = 'microsoft.servicebus/namespaces'; Props = @('createdAt'); Expect = @{ CreatedTime = '2024-03-15 21:41' } }
        @{ Collector = 'Storage/ComputeSnapshots'; Type = 'microsoft.compute/snapshots'; Props = @('timeCreated'); Expect = @{ CreatedTime = '2024-03-15 21:41' } }
        @{ Collector = 'Storage/StorageAcc'; Type = 'microsoft.storage/storageaccounts'; Props = @('creationTime'); Expect = @{ CreatedTime = '2024-03-15 21:41' } }
        @{ Collector = 'Storage/VMDisk'; Type = 'microsoft.compute/disks'; Props = @('timeCreated'); Expect = @{ CreatedTime = '2024-03-15 21:41' } }
    )

    # Writes a script that builds one record per date form for every case, runs
    # each collector the way ResourceInventory.ps1 does, and prints one line per
    # row: '<collector>|<column>=<value>;...'. The first line is the host's UTC
    # offset on the test date.
    $script:ChildScript = Join-Path $TestDrive 'collector-dates.ps1'
    $Cases = $script:DateCases | ForEach-Object { @{ Collector = $_.Collector; Type = $_.Type; Props = $_.Props; Columns = @($_.Expect.Keys | Sort-Object) } }
    $CasesJson = (ConvertTo-Json -InputObject @($Cases) -Depth 5 -Compress).Replace("'", "''")
    $FormsJson = (ConvertTo-Json -InputObject $script:Forms -Compress).Replace("'", "''")
    Set-Content -LiteralPath $script:ChildScript -Encoding utf8 -Value @"
`$Root = '$($script:Root.Replace("'", "''"))'
`$Guid = '$($script:DocGuid)'
`$Cases = '$CasesJson' | ConvertFrom-Json
`$Forms = '$FormsJson' | ConvertFrom-Json
`$Subs = @([pscustomobject]@{ id = `$Guid; Name = 'sub-placeholder' })
'{0}' -f [System.TimeZoneInfo]::Local.GetUtcOffset([datetime]'2024-03-15').TotalHours
foreach (`$Case in `$Cases)
{
    `$Records = for (`$i = 0; `$i -lt `$Forms.Count; `$i++)
    {
        `$Name = 'res-{0}' -f `$i
        `$Props = [ordered]@{}
        foreach (`$P in `$Case.Props) { `$Props[`$P] = `$Forms[`$i] }
        [ordered]@{ id = "/subscriptions/`$Guid/resourceGroups/RG-Dates/providers/`$(`$Case.Type)/`$Name"; name = `$Name; type = `$Case.Type; resourceGroup = 'RG-Dates'; location = 'eastus'; subscriptionId = `$Guid; properties = `$Props }
        if (`$Case.Collector -eq 'Infrastructure/AutomationAcc')
        {
            [ordered]@{ id = "/subscriptions/`$Guid/resourceGroups/RG-Dates/providers/`$(`$Case.Type)/`$Name/runbooks/rb-`$i"; name = "`$Name/rb-`$i"; type = 'microsoft.automation/automationaccounts/runbooks'; resourceGroup = 'RG-Dates'; location = 'eastus'; subscriptionId = `$Guid; properties = [ordered]@{ lastModifiedTime = `$Forms[`$i]; state = 'Published' } }
        }
    }
    # Resource Graph answers are lowercased before the collectors see them.
    `$Resources = (ConvertTo-Json -InputObject @(`$Records) -Depth 10).ToLower() | ConvertFrom-Json
    `$Rows = @(& (Join-Path `$Root ("Services/{0}.ps1" -f `$Case.Collector)) -Sub `$Subs -Resources `$Resources -Task 'Processing' -ResourceIdDictionary `$null)
    foreach (`$Row in `$Rows) { '{0}|{1}' -f `$Case.Collector, ((`$Case.Columns | ForEach-Object { '{0}={1}' -f `$_, `$Row[`$_] }) -join ';') }
}
"@
    $script:Pwsh = (Get-Process -Id $PID).Path

    function Invoke-DatesInZone
    {
        param([string]$Zone)
        $Saved = $env:TZ
        try
        {
            $env:TZ = $Zone
            return @(& $script:Pwsh -NoProfile -NonInteractive -File $script:ChildScript)
        }
        finally
        {
            if ($null -eq $Saved) { Remove-Item -Path 'Env:TZ' -ErrorAction SilentlyContinue } else { $env:TZ = $Saved }
        }
    }

    function Get-ExpectedLines
    {
        foreach ($Case in $script:DateCases)
        {
            $Line = '{0}|{1}' -f $Case.Collector, ((@($Case.Expect.Keys | Sort-Object) | ForEach-Object { '{0}={1}' -f $_, $Case.Expect[$_] }) -join ';')
            for ($i = 0; $i -lt $script:Forms.Count; $i++) { $Line }
        }
    }
}

Describe 'Collector dates are written in UTC' {
    It 'writes the UTC text for every date form on hosts at UTC+14 and UTC-11' {
        $East = Invoke-DatesInZone 'Pacific/Kiritimati'
        $West = Invoke-DatesInZone 'Pacific/Pago_Pago'
        if ($East[0] -ne '14' -or $West[0] -ne '-11')
        {
            Set-ItResult -Skipped -Because 'this host does not apply the TZ variable to a child pwsh'
            return
        }
        $Expected = @(Get-ExpectedLines)
        $East[1..($East.Count - 1)] | Should -Be $Expected
        $West[1..($West.Count - 1)] | Should -Be $Expected
    }
}
