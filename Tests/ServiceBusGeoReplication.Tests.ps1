# Service Bus collector geo replication tests
# Run with: Invoke-Pester ./Tests/ServiceBusGeoReplication.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# Services/Integration/ServiceBUS.ps1 filled the GeoRep column from
# properties.zoneRedundant, so a zone-redundant namespace with no replica in
# another region read as geo-replicated, and a geo-replicated namespace that is
# not zone redundant read as not geo-replicated. A namespace lists every
# region it replicates to, the primary included, in
# properties.geoDataReplication.locations, so GeoRep is true only when that
# list has more than one entry.
#
# This test invokes the REAL Services/Integration/ServiceBUS.ps1 collector with
# synthetic namespace records in the older shape (no geoDataReplication) and
# the current one, with the fields missing, null and of the wrong type, and
# asserts the GeoRep value and that every other column is unchanged. Disaster
# recovery pairing (a separate API per namespace) is not read. No live Azure
# is needed.

BeforeAll {
    $script:Collector = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'Services', 'Integration', 'ServiceBUS.ps1' | Resolve-Path | Select-Object -ExpandProperty Path

    # All GUIDs below are the canonical Azure documentation placeholder; they
    # are not real subscription or resource identifiers.
    $script:DocGuid = '12345678-1234-1234-1234-123456789012'
    $script:Subs = @([pscustomobject]@{ Id = $script:DocGuid; Name = 'sub-placeholder' })
    $script:RgPath = "/subscriptions/$($script:DocGuid)/resourceGroups/rg-sb/providers/Microsoft.ServiceBus/namespaces"

    function New-Location
    {
        param([string]$Name, [string]$Role)
        return [pscustomobject]@{ locationName = $Name; roleType = $Role; replicaState = 'Ready' }
    }

    # Build one namespace record in the shape the collector consumes.
    # -GeoMode: 'Absent' omits geoDataReplication, 'Null' sets it to $null,
    # 'Value' sets it to -GeoData.
    function New-NamespaceRecord
    {
        param(
            [string]$Name,
            [ValidateSet('Absent', 'Null', 'Value')][string]$GeoMode,
            $GeoData,
            [bool]$ZoneRedundant
        )

        $Props = [ordered]@{
            status        = 'Active'
            zoneRedundant = $ZoneRedundant
            # A fixed timestamp with no offset formats the same in every time zone.
            createdAt     = '2024-03-15T09:41:27.1234567'
        }
        if ($GeoMode -eq 'Null') { $Props['geoDataReplication'] = $null }
        if ($GeoMode -eq 'Value') { $Props['geoDataReplication'] = $GeoData }

        return [pscustomobject]@{
            TYPE           = 'microsoft.servicebus/namespaces'
            id             = "$($script:RgPath)/$Name"
            NAME           = $Name
            RESOURCEGROUP  = 'rg-sb'
            LOCATION       = 'eastus'
            subscriptionId = $script:DocGuid
            SKU            = [pscustomobject]@{ name = 'Premium'; tier = 'Premium'; capacity = 1 }
            PROPERTIES     = [pscustomobject]$Props
        }
    }

    # Every column except GeoRep, as the collector should emit it for a record
    # built by New-NamespaceRecord.
    function Get-ExpectedColumns
    {
        param([string]$Name)
        return [ordered]@{
            'ID'              = "$($script:RgPath)/$Name"
            'Subscription'    = 'sub-placeholder'
            'ResourceGroup'   = 'rg-sb'
            'Name'            = $Name
            'Location'        = 'eastus'
            'SKU'             = 'Premium'
            'Status'          = 'Active'
            'ThroughputUnits' = 1
            'CreatedTime'     = '2024-03-15 09:41'
        }
    }

    function Invoke-ServiceBusCollector
    {
        param($Resources)
        return @(& $script:Collector -Sub $script:Subs -Resources @($Resources) -Task 'Processing' -ResourceIdDictionary $null)
    }

    $Primary = New-Location -Name 'eastus' -Role 'Primary'
    $Secondary = New-Location -Name 'westus' -Role 'Secondary'
    $Third = New-Location -Name 'northeurope' -Role 'Secondary'

    # Name -> record and the GeoRep value the collector must write.
    $script:Cases = [ordered]@{
        'sb-older-shape-zone'      = @{ Record = (New-NamespaceRecord -Name 'sb-older-shape-zone' -GeoMode Absent -ZoneRedundant $true); Expected = $false }
        'sb-primary-only-zone'     = @{ Record = (New-NamespaceRecord -Name 'sb-primary-only-zone' -GeoMode Value -GeoData ([pscustomobject]@{ maxReplicationLagDurationInSeconds = 0; locations = @($Primary) }) -ZoneRedundant $true); Expected = $false }
        'sb-two-regions-no-zone'   = @{ Record = (New-NamespaceRecord -Name 'sb-two-regions-no-zone' -GeoMode Value -GeoData ([pscustomobject]@{ maxReplicationLagDurationInSeconds = 300; locations = @($Primary, $Secondary) }) -ZoneRedundant $false); Expected = $true }
        'sb-three-regions-zone'    = @{ Record = (New-NamespaceRecord -Name 'sb-three-regions-zone' -GeoMode Value -GeoData ([pscustomobject]@{ locations = @($Primary, $Secondary, $Third) }) -ZoneRedundant $true); Expected = $true }
        'sb-geo-null'              = @{ Record = (New-NamespaceRecord -Name 'sb-geo-null' -GeoMode Null -ZoneRedundant $true); Expected = $false }
        'sb-locations-absent'      = @{ Record = (New-NamespaceRecord -Name 'sb-locations-absent' -GeoMode Value -GeoData ([pscustomobject]@{ maxReplicationLagDurationInSeconds = 0 }) -ZoneRedundant $true); Expected = $false }
        'sb-locations-null'        = @{ Record = (New-NamespaceRecord -Name 'sb-locations-null' -GeoMode Value -GeoData ([pscustomobject]@{ locations = $null }) -ZoneRedundant $true); Expected = $false }
        'sb-locations-empty'       = @{ Record = (New-NamespaceRecord -Name 'sb-locations-empty' -GeoMode Value -GeoData ([pscustomobject]@{ locations = @() }) -ZoneRedundant $true); Expected = $false }
        'sb-locations-null-entry'  = @{ Record = (New-NamespaceRecord -Name 'sb-locations-null-entry' -GeoMode Value -GeoData ([pscustomobject]@{ locations = @($Primary, $null) }) -ZoneRedundant $true); Expected = $false }
        'sb-geo-wrong-type'        = @{ Record = (New-NamespaceRecord -Name 'sb-geo-wrong-type' -GeoMode Value -GeoData 'eastus,westus' -ZoneRedundant $true); Expected = $false }
        'sb-locations-string'      = @{ Record = (New-NamespaceRecord -Name 'sb-locations-string' -GeoMode Value -GeoData ([pscustomobject]@{ locations = 'eastus,westus' }) -ZoneRedundant $true); Expected = $false }
        'sb-locations-number'      = @{ Record = (New-NamespaceRecord -Name 'sb-locations-number' -GeoMode Value -GeoData ([pscustomobject]@{ locations = 2 }) -ZoneRedundant $true); Expected = $false }
        'sb-locations-one-object'  = @{ Record = (New-NamespaceRecord -Name 'sb-locations-one-object' -GeoMode Value -GeoData ([pscustomobject]@{ locations = $Secondary }) -ZoneRedundant $true); Expected = $false }
    }
}

Describe 'Service Bus collector GeoRep' {

    It 'writes GeoRep <Expected> for <Name>' -ForEach @(
        @{ Name = 'sb-older-shape-zone'; Expected = $false }
        @{ Name = 'sb-primary-only-zone'; Expected = $false }
        @{ Name = 'sb-two-regions-no-zone'; Expected = $true }
        @{ Name = 'sb-three-regions-zone'; Expected = $true }
    ) {
        $Rec = @(Invoke-ServiceBusCollector -Resources $script:Cases[$Name].Record)[0]
        $Rec.GeoRep | Should -BeOfType [bool]
        $Rec.GeoRep | Should -Be $Expected
    }

    It 'writes GeoRep $false when the geo replication fields are missing or null (<Name>)' -ForEach @(
        @{ Name = 'sb-geo-null' }
        @{ Name = 'sb-locations-absent' }
        @{ Name = 'sb-locations-null' }
        @{ Name = 'sb-locations-empty' }
        @{ Name = 'sb-locations-null-entry' }
    ) {
        $Rec = @(Invoke-ServiceBusCollector -Resources $script:Cases[$Name].Record)[0]
        $Rec.GeoRep | Should -BeOfType [bool]
        $Rec.GeoRep | Should -BeFalse
    }

    It 'writes GeoRep $false when the geo replication fields have the wrong type (<Name>)' -ForEach @(
        @{ Name = 'sb-geo-wrong-type' }
        @{ Name = 'sb-locations-string' }
        @{ Name = 'sb-locations-number' }
        @{ Name = 'sb-locations-one-object' }
    ) {
        $Rec = @(Invoke-ServiceBusCollector -Resources $script:Cases[$Name].Record)[0]
        $Rec.Name | Should -BeExactly $Name
        $Rec.GeoRep | Should -BeOfType [bool]
        $Rec.GeoRep | Should -BeFalse
    }

    It 'writes every namespace, in order, when the shapes are mixed' {
        $Recs = @(Invoke-ServiceBusCollector -Resources @($script:Cases.Values | ForEach-Object { $_.Record }))
        $Recs.Count | Should -Be $script:Cases.Count
        ($Recs | ForEach-Object { $_.Name }) | Should -Be @($script:Cases.Keys)
        ($Recs | ForEach-Object { $_.GeoRep }) | Should -Be @($script:Cases.Values | ForEach-Object { $_.Expected })
    }

    It 'leaves every other column unchanged for <Name>' -ForEach @(
        @{ Name = 'sb-older-shape-zone' }
        @{ Name = 'sb-primary-only-zone' }
        @{ Name = 'sb-two-regions-no-zone' }
        @{ Name = 'sb-geo-null' }
        @{ Name = 'sb-locations-string' }
    ) {
        $Rec = @(Invoke-ServiceBusCollector -Resources $script:Cases[$Name].Record)[0]
        $Expected = Get-ExpectedColumns -Name $Name

        @($Rec.Keys | Sort-Object) | Should -Be @(@($Expected.Keys) + 'GeoRep' | Sort-Object)
        foreach ($Key in $Expected.Keys)
        {
            $Rec[$Key] | Should -Be $Expected[$Key] -Because "column '$Key' must not depend on the geo replication fields"
        }
    }
}
