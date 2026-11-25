# Event Hubs namespace GeoReplication tests
# Run with: Invoke-Pester ./Tests/EventHubGeoReplication.Tests.ps1 -Output Detailed
#
# Services/Analytics/EvtHub.ps1 filled the GeoReplication column from
# properties.zoneRedundant, so a zone-redundant namespace with no replica in
# another region read as geo-replicated. A namespace lists every region it
# replicates to, the primary included, in properties.geoDataReplication.locations,
# so GeoReplication is true only when that list has more than one entry: the
# same rule as Service Bus GeoRep (Tests/ServiceBusGeoReplication.Tests.ps1).
# The REAL collector runs on synthetic records; no live Azure.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    # The Azure documentation placeholder; not a real subscription id.
    $script:Guid = '12345678-1234-1234-1234-123456789012'
    $script:Subs = @([pscustomobject]@{ id = $script:Guid; Name = 'sub-placeholder' })
    $script:NsPath = "/subscriptions/$($script:Guid)/resourceGroups/rg-evh/providers/Microsoft.EventHub/namespaces"

    function Invoke-Collector
    {
        param($Records)
        $Saved = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        try { return , @(& (Join-Path $script:Root 'Services/Analytics/EvtHub.ps1') -Sub $script:Subs -Resources @($Records) -Task 'Processing' -ResourceIdDictionary $null) }
        finally { $ErrorActionPreference = $Saved }
    }

    function New-Location
    {
        param([string]$Name, [string]$Role)
        return [pscustomobject]@{ locationName = $Name; roleType = $Role; replicaState = 'Ready' }
    }

    # -GeoMode: 'Absent' omits geoDataReplication, 'Null' sets it to $null,
    # 'Value' sets it to -GeoData.
    function New-Namespace
    {
        param([string]$Name, [ValidateSet('Absent', 'Null', 'Value')][string]$GeoMode, $GeoData, [bool]$ZoneRedundant, [string]$Sku = 'Standard')
        # A fixed timestamp with no offset formats the same in every time zone.
        $Props = [ordered]@{ status = 'Active'; zoneRedundant = $ZoneRedundant; createdAt = '2024-03-15T09:41:27.1234567' }
        if ($GeoMode -eq 'Null') { $Props['geoDataReplication'] = $null }
        if ($GeoMode -eq 'Value') { $Props['geoDataReplication'] = $GeoData }
        return [pscustomobject]@{
            TYPE           = 'microsoft.eventhub/namespaces'
            id             = "$($script:NsPath)/$Name"
            NAME           = $Name
            RESOURCEGROUP  = 'rg-evh'
            LOCATION       = 'eastus'
            subscriptionId = $script:Guid
            SKU            = [pscustomobject]@{ name = $Sku; capacity = 1 }
            PROPERTIES     = [pscustomobject]$Props
        }
    }

    $Primary = New-Location -Name 'eastus' -Role 'Primary'
    $Secondary = New-Location -Name 'westus' -Role 'Secondary'
    $Third = New-Location -Name 'northeurope' -Role 'Secondary'

    # Name -> record and the GeoReplication value the collector must write.
    $script:Cases = [ordered]@{
        'evh-basic-zone-no-geo'    = @{ Record = (New-Namespace -Name 'evh-basic-zone-no-geo' -GeoMode Absent -ZoneRedundant $true -Sku 'Basic'); Expected = $false }
        'evh-primary-only-zone'    = @{ Record = (New-Namespace -Name 'evh-primary-only-zone' -GeoMode Value -GeoData ([pscustomobject]@{ maxReplicationLagDurationInSeconds = 0; locations = @($Primary) }) -ZoneRedundant $true); Expected = $false }
        'evh-two-regions-no-zone'  = @{ Record = (New-Namespace -Name 'evh-two-regions-no-zone' -GeoMode Value -GeoData ([pscustomobject]@{ maxReplicationLagDurationInSeconds = 300; locations = @($Primary, $Secondary) }) -ZoneRedundant $false); Expected = $true }
        'evh-three-regions-zone'   = @{ Record = (New-Namespace -Name 'evh-three-regions-zone' -GeoMode Value -GeoData ([pscustomobject]@{ locations = @($Primary, $Secondary, $Third) }) -ZoneRedundant $true); Expected = $true }
        'evh-geo-null'             = @{ Record = (New-Namespace -Name 'evh-geo-null' -GeoMode Null -ZoneRedundant $true); Expected = $false }
        'evh-locations-absent'     = @{ Record = (New-Namespace -Name 'evh-locations-absent' -GeoMode Value -GeoData ([pscustomobject]@{ maxReplicationLagDurationInSeconds = 0 }) -ZoneRedundant $true); Expected = $false }
        'evh-locations-null'       = @{ Record = (New-Namespace -Name 'evh-locations-null' -GeoMode Value -GeoData ([pscustomobject]@{ locations = $null }) -ZoneRedundant $true); Expected = $false }
        'evh-locations-empty'      = @{ Record = (New-Namespace -Name 'evh-locations-empty' -GeoMode Value -GeoData ([pscustomobject]@{ locations = @() }) -ZoneRedundant $true); Expected = $false }
        'evh-locations-null-entry' = @{ Record = (New-Namespace -Name 'evh-locations-null-entry' -GeoMode Value -GeoData ([pscustomobject]@{ locations = @($Primary, $null) }) -ZoneRedundant $true); Expected = $false }
        'evh-geo-wrong-type'       = @{ Record = (New-Namespace -Name 'evh-geo-wrong-type' -GeoMode Value -GeoData 'eastus,westus' -ZoneRedundant $true); Expected = $false }
        'evh-locations-string'     = @{ Record = (New-Namespace -Name 'evh-locations-string' -GeoMode Value -GeoData ([pscustomobject]@{ locations = 'eastus,westus' }) -ZoneRedundant $true); Expected = $false }
        'evh-locations-number'     = @{ Record = (New-Namespace -Name 'evh-locations-number' -GeoMode Value -GeoData ([pscustomobject]@{ locations = 2 }) -ZoneRedundant $true); Expected = $false }
        'evh-locations-one-object' = @{ Record = (New-Namespace -Name 'evh-locations-one-object' -GeoMode Value -GeoData ([pscustomobject]@{ locations = $Secondary }) -ZoneRedundant $true); Expected = $false }
    }
}

Describe 'Event Hubs namespace GeoReplication' {

    It 'writes GeoReplication <Expected> for <Name>' -ForEach @(
        @{ Name = 'evh-basic-zone-no-geo'; Expected = $false }
        @{ Name = 'evh-primary-only-zone'; Expected = $false }
        @{ Name = 'evh-two-regions-no-zone'; Expected = $true }
        @{ Name = 'evh-three-regions-zone'; Expected = $true }
    ) {
        $Rec = (Invoke-Collector $script:Cases[$Name].Record)[0]
        $Rec.GeoReplication | Should -BeOfType [bool]
        $Rec.GeoReplication | Should -Be $Expected
    }

    It 'writes GeoReplication $false when the geo replication fields are missing or null (<Name>)' -ForEach @(
        @{ Name = 'evh-geo-null' }
        @{ Name = 'evh-locations-absent' }
        @{ Name = 'evh-locations-null' }
        @{ Name = 'evh-locations-empty' }
        @{ Name = 'evh-locations-null-entry' }
    ) {
        $Rec = (Invoke-Collector $script:Cases[$Name].Record)[0]
        $Rec.GeoReplication | Should -BeOfType [bool]
        $Rec.GeoReplication | Should -BeFalse
    }

    It 'writes GeoReplication $false when the geo replication fields have the wrong type (<Name>)' -ForEach @(
        @{ Name = 'evh-geo-wrong-type' }
        @{ Name = 'evh-locations-string' }
        @{ Name = 'evh-locations-number' }
        @{ Name = 'evh-locations-one-object' }
    ) {
        $Rec = (Invoke-Collector $script:Cases[$Name].Record)[0]
        $Rec.Name | Should -BeExactly $Name
        $Rec.GeoReplication | Should -BeOfType [bool]
        $Rec.GeoReplication | Should -BeFalse
    }

    It 'writes every namespace, in order, when the shapes are mixed' {
        $Recs = (Invoke-Collector @($script:Cases.Values | ForEach-Object { $_.Record }))
        $Recs.Count | Should -Be $script:Cases.Count
        ($Recs | ForEach-Object { $_.Name }) | Should -Be @($script:Cases.Keys)
        ($Recs | ForEach-Object { $_.GeoReplication }) | Should -Be @($script:Cases.Values | ForEach-Object { $_.Expected })
    }

    It 'leaves every other column unchanged' {
        $Rec = (Invoke-Collector $script:Cases['evh-two-regions-no-zone'].Record)[0]
        @($Rec.Keys | Sort-Object) | Should -Be @('AutoInflate', 'CreatedTime', 'GeoReplication', 'ID', 'KafkaEnabled', 'Location', 'MaxThroughputUnits', 'Name', 'ResourceGroup', 'SKU', 'Status', 'Subscription', 'ThroughputUnits')
        $Rec.ID | Should -BeExactly "$($script:NsPath)/evh-two-regions-no-zone"
        $Rec.SKU | Should -BeExactly 'Standard'
        $Rec.ThroughputUnits | Should -Be 1
        $Rec.Status | Should -BeExactly 'Active'
        $Rec.CreatedTime | Should -BeExactly '2024-03-15 09:41'
    }
}
