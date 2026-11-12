# SQL Database collector backup storage tests
# Run with: Invoke-Pester ./Tests/SQLDBBackupStorage.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# Services/Data/SQLDB.ps1 writes the database's backup storage redundancy in
# the StorageAccountType column. Older API shapes carry it as
# properties.storageAccountType; current Resource Graph and ARM shapes have no
# such property and carry currentBackupStorageRedundancy and
# requestedBackupStorageRedundancy instead, so reading only storageAccountType
# left the column empty for every current database.
#
# This test invokes the REAL Services/Data/SQLDB.ps1 collector with synthetic
# database records in the old shape, the current shape, both, neither, with
# null values and with values of the wrong type, and asserts that
# StorageAccountType is storageAccountType when it is a non-empty string, else
# currentBackupStorageRedundancy, else requestedBackupStorageRedundancy, else
# $null, and that every other column is unchanged. No live Azure is needed.

BeforeAll {
    $script:Collector = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'Services', 'Data', 'SQLDB.ps1' | Resolve-Path | Select-Object -ExpandProperty Path

    # All GUIDs below are the canonical Azure documentation placeholder; they
    # are not real subscription or resource identifiers.
    $script:DocGuid = '12345678-1234-1234-1234-123456789012'
    $script:Subs = @([pscustomobject]@{ id = $script:DocGuid; Name = 'sub-placeholder' })
    $script:ServerPath = "/subscriptions/$($script:DocGuid)/resourceGroups/rg-sql/providers/Microsoft.Sql/servers/sql-01"

    # Build one database record in the shape the collector consumes. -Backup
    # maps a backup field name to its value; a field not named is absent, and a
    # field named with $null is present and null.
    function New-SqlDbRecord
    {
        param(
            [string]$Name,
            [hashtable]$Backup = @{}
        )

        $Props = [ordered]@{
            defaultSecondaryLocation      = 'westus'
            status                        = 'Online'
            currentSku                    = [pscustomobject]@{ name = 'GP_Gen5'; tier = 'GeneralPurpose'; capacity = 2 }
            requestedServiceObjectiveName = 'GP_Gen5_2'
            zoneRedundant                 = $false
            licenseType                   = 'LicenseIncluded'
            catalogCollation              = 'SQL_Latin1_General_CP1_CI_AS'
            highAvailabilityReplicaCount  = 1
            maxSizeBytes                  = 34359738368
        }
        foreach ($Key in $Backup.Keys) { $Props[$Key] = $Backup[$Key] }

        return [pscustomobject]@{
            TYPE           = 'microsoft.sql/servers/databases'
            id             = "$($script:ServerPath)/databases/$Name"
            NAME           = $Name
            kind           = 'v12.0,user,vcore'
            RESOURCEGROUP  = 'rg-sql'
            LOCATION       = 'eastus'
            subscriptionId = $script:DocGuid
            PROPERTIES     = [pscustomobject]$Props
        }
    }

    # Every column except StorageAccountType, as the collector should emit it
    # for a record built by New-SqlDbRecord.
    function Get-ExpectedColumns
    {
        param([string]$Name)
        return [ordered]@{
            'ID'                = "$($script:ServerPath)/databases/$Name"
            'Subscription'      = 'sub-placeholder'
            'ResourceGroup'     = 'rg-sql'
            'Name'              = $Name
            'Location'          = 'eastus'
            'DatabaseServer'    = 'sql-01'
            'SecondaryLocation' = 'westus'
            'Status'            = 'Online'
            'Tier'              = 'GeneralPurpose'
            'ComputeTier'       = 'Provisioned'
            'Type'              = 'vcore'
            'Capacity'          = 2
            'Sku'               = 'GP_Gen5_2'
            'ZoneRedundant'     = $false
            'License'           = 'LicenseIncluded'
            'CatalogCollation'  = 'SQL_Latin1_General_CP1_CI_AS'
            'ReadReplicaCount'  = 1
            'DataMaxSizeGB'     = 32
            'ElasticPoolID'     = 'None'
        }
    }

    function Invoke-SqlDbCollector
    {
        param($Resources)
        return @(& $script:Collector -Sub $script:Subs -Resources @($Resources) -Task 'Processing' -ResourceIdDictionary $null)
    }

    # Name -> backup fields and the StorageAccountType the collector must write.
    $script:Cases = [ordered]@{
        'db-old-shape'          = @{ Backup = @{ storageAccountType = 'GRS' }; Expected = 'GRS' }
        'db-old-and-new'        = @{ Backup = @{ storageAccountType = 'LRS'; currentBackupStorageRedundancy = 'Geo'; requestedBackupStorageRedundancy = 'Geo' }; Expected = 'LRS' }
        'db-current-shape'      = @{ Backup = @{ currentBackupStorageRedundancy = 'Geo'; requestedBackupStorageRedundancy = 'Geo' }; Expected = 'Geo' }
        'db-change-pending'     = @{ Backup = @{ currentBackupStorageRedundancy = 'Local'; requestedBackupStorageRedundancy = 'Zone' }; Expected = 'Local' }
        'db-requested-only'     = @{ Backup = @{ requestedBackupStorageRedundancy = 'Zone' }; Expected = 'Zone' }
        'db-all-absent'         = @{ Backup = @{}; Expected = $null }
        'db-all-null'           = @{ Backup = @{ storageAccountType = $null; currentBackupStorageRedundancy = $null; requestedBackupStorageRedundancy = $null }; Expected = $null }
        'db-old-null'           = @{ Backup = @{ storageAccountType = $null; currentBackupStorageRedundancy = 'GeoZone' }; Expected = 'GeoZone' }
        'db-old-empty'          = @{ Backup = @{ storageAccountType = ''; currentBackupStorageRedundancy = 'Geo' }; Expected = 'Geo' }
        'db-old-wrong-type'     = @{ Backup = @{ storageAccountType = 7; currentBackupStorageRedundancy = 'Geo' }; Expected = 'Geo' }
        'db-current-wrong-type' = @{ Backup = @{ currentBackupStorageRedundancy = [pscustomobject]@{ value = 'Geo' }; requestedBackupStorageRedundancy = 'Local' }; Expected = 'Local' }
        'db-all-wrong-type'     = @{ Backup = @{ storageAccountType = $true; currentBackupStorageRedundancy = 3; requestedBackupStorageRedundancy = @('Geo') }; Expected = $null }
    }
    $script:Records = [ordered]@{}
    foreach ($Name in $script:Cases.Keys) { $script:Records[$Name] = New-SqlDbRecord -Name $Name -Backup $script:Cases[$Name].Backup }
}

Describe 'SQL Database collector StorageAccountType' {

    It 'writes the backup storage redundancy for <Name>' -ForEach @(
        @{ Name = 'db-old-shape' }
        @{ Name = 'db-old-and-new' }
        @{ Name = 'db-current-shape' }
        @{ Name = 'db-change-pending' }
        @{ Name = 'db-requested-only' }
        @{ Name = 'db-old-null' }
        @{ Name = 'db-old-empty' }
    ) {
        $Rec = @(Invoke-SqlDbCollector -Resources $script:Records[$Name])[0]
        $Rec.StorageAccountType | Should -BeExactly $script:Cases[$Name].Expected
    }

    It 'writes $null when no backup field is present or non-null (<Name>)' -ForEach @(
        @{ Name = 'db-all-absent' }
        @{ Name = 'db-all-null' }
    ) {
        $Rec = @(Invoke-SqlDbCollector -Resources $script:Records[$Name])[0]
        $Rec.Keys | Should -Contain 'StorageAccountType'
        $Rec.StorageAccountType | Should -BeNullOrEmpty
        $null -eq $Rec.StorageAccountType | Should -BeTrue
    }

    It 'skips a backup field that is present but not a string (<Name>)' -ForEach @(
        @{ Name = 'db-old-wrong-type' }
        @{ Name = 'db-current-wrong-type' }
        @{ Name = 'db-all-wrong-type' }
    ) {
        $Rec = @(Invoke-SqlDbCollector -Resources $script:Records[$Name])[0]
        $Rec.Name | Should -BeExactly $Name
        if ($null -eq $script:Cases[$Name].Expected) { $null -eq $Rec.StorageAccountType | Should -BeTrue }
        else { $Rec.StorageAccountType | Should -BeExactly $script:Cases[$Name].Expected }
    }

    It 'writes every database, in order, when the shapes are mixed' {
        $Recs = @(Invoke-SqlDbCollector -Resources @($script:Records.Values))
        $Recs.Count | Should -Be $script:Cases.Count
        ($Recs | ForEach-Object { $_.Name }) | Should -Be @($script:Cases.Keys)
        foreach ($Rec in $Recs)
        {
            $Expected = $script:Cases[$Rec.Name].Expected
            if ($null -eq $Expected) { $null -eq $Rec.StorageAccountType | Should -BeTrue -Because $Rec.Name }
            else { $Rec.StorageAccountType | Should -BeExactly $Expected -Because $Rec.Name }
        }
    }

    It 'leaves every other column unchanged for <Name>' -ForEach @(
        @{ Name = 'db-old-shape' }
        @{ Name = 'db-current-shape' }
        @{ Name = 'db-all-absent' }
        @{ Name = 'db-all-null' }
        @{ Name = 'db-all-wrong-type' }
    ) {
        $Rec = @(Invoke-SqlDbCollector -Resources $script:Records[$Name])[0]
        $Expected = Get-ExpectedColumns -Name $Name

        @($Rec.Keys | Sort-Object) | Should -Be @(@($Expected.Keys) + 'StorageAccountType' | Sort-Object)
        foreach ($Key in $Expected.Keys)
        {
            $Rec[$Key] | Should -Be $Expected[$Key] -Because "column '$Key' must not depend on the backup storage fields"
        }
    }
}
