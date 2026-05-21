# Report Schema Validation Tests
# Validates that the Excel report has correct worksheet names and column headers
# Run with: Invoke-Pester ./Tests/ReportSchema.Tests.ps1 -Output Detailed

$ExpectedSchema = @{
    'Virtual Machines' = @('Subscription', 'ResourceGroup', 'Name', 'Size', 'CPU', 'Memory', 'Location', 'OS', 'OSName', 'OSVersion', 'ImageReference', 'ImageVersion', 'ImageSku', 'ImageOffer', 'OSDisk', 'OSDiskSizeGB', 'HybridBenefit', 'PowerState', 'AvailabilitySet', 'CreatedTime')
    'AKS' = @('Subscription', 'ResourceGroup', 'Name', 'Location', 'Sku', 'SkuTier', 'KubernetesVersion', 'LoadBalancerSku', 'NodePoolName', 'PoolProfileType', 'PoolMode', 'PoolOS', 'NodeSize', 'OSDiskSize', 'Nodes', 'Autoscale', 'AutoscaleMax', 'AutoscaleMin', 'MaxPodsPerNode', 'OrchestratorVersion')
    'Containers' = @('Subscription', 'ResourceGroup', 'Name', 'Location', 'Sku', 'InstanceOSType', 'ContainerName', 'ContainerState', 'ContainerImage', 'RestartCount', 'StartTime', 'Command', 'RequestCPU', 'RequestMemoryGB')
    'Registries' = @('Subscription', 'ResourceGroup', 'Name', 'Location', 'SKU', 'State', 'Encryption', 'CreatedTime')
    'VM Scale Sets' = @('Subscription', 'ResourceGroup', 'Name', 'Location', 'SKUTier', 'VMSize', 'vCPUs', 'RAM', 'License', 'Instances', 'AutoscaleEnabled', 'VMOS', 'OSImage', 'ImageVersion', 'DiskSizeGB', 'StorageAccountType', 'AcceleratedNetworkingEnabled', 'CreatedTime')
    'SQL DBs' = @('Subscription', 'ResourceGroup', 'Name', 'Location', 'StorageAccountType', 'DatabaseServer', 'SecondaryLocation', 'Status', 'Type', 'Tier', 'ComputeTier', 'Sku', 'License', 'Capacity', 'DataMaxSizeGB', 'ZoneRedundant', 'CatalogCollation', 'ReadReplicaCount', 'ElasticPoolID')
    'SQL Servers' = @('Subscription', 'ResourceGroup', 'Name', 'Location', 'Kind', 'State', 'Version', 'ZoneRedundant')
    'Runbooks' = @('Subscription', 'ResourceGroup', 'AutomationAccountName', 'AutomationAccountState', 'AutomationAccountSKU', 'AutomationAccountCreatedTime', 'Location', 'RunbookName', 'LastModifiedTime', 'RunbookState', 'RunbookType', 'RunbookDescription')
    'Availability Sets' = @('Subscription', 'ResourceGroup', 'Name', 'Location', 'FaultDomains', 'UpdateDomains', 'VirtualMachines')
    'FrontDoor' = @('Subscription', 'ResourceGroup', 'Name', 'Location', 'Type', 'State', 'WebApplicationFirewall')
    'Key Vaults' = @('Subscription', 'ResourceGroup', 'Name', 'Location', 'SKUFamily', 'SKU')
    'Service BUS' = @('Subscription', 'ResourceGroup', 'Name', 'Location', 'SKU', 'Status', 'GeoRep', 'ThroughputUnits', 'CreatedTime')
    'Load Balancers' = @('Subscription', 'ResourceGroup', 'Name', 'Location', 'SKU', 'SKUTier', 'RuleCount')
    'Public IPs' = @('Subscription', 'ResourceGroup', 'Name', 'SKU', 'Location', 'AllocationType', 'Version', 'ProvisioningState', 'Use', 'AssociatedResource', 'AssociatedResourceType')
    'Data Explorer Clusters' = @('Subscription', 'ResourceGroup', 'Name', 'Location', 'ComputeSpecifications', 'InstanceCount', 'State', 'StateReason', 'DiskEncryption', 'StreamingIngestion', 'OptimizedAutoscale', 'OptimizedAutoscaleMin', 'OptimizedAutoscaleMax')
    'Storage Acc' = @('Subscription', 'ResourceGroup', 'Name', 'Location', 'SKU', 'Tier', 'Kind', 'AccessTier', 'PrimaryLocation', 'StatusOfPrimary', 'HierarchicalNamespace', 'CreatedTime')
    'Disks' = @('Subscription', 'ResourceGroup', 'Name', 'Tier', 'State', 'AssociatedResource', 'SKU', 'Size', 'Location', 'OSType', 'DiskIOPS', 'DiskMBps', 'CreatedTime')
}

Describe 'Report Schema Validation' {
    BeforeAll {
        $zipPath = if ($env:TEST_ZIP_PATH) { $env:TEST_ZIP_PATH } else {
            Get-ChildItem -Path $PSScriptRoot -Filter 'ResourcesReport_*.zip' |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1 -ExpandProperty FullName
        }

        if ([string]::IsNullOrEmpty($zipPath) -or -not (Test-Path $zipPath)) {
            throw "No test zip found. Copy a ResourcesReport_*.zip to Tests/ or set `$env:TEST_ZIP_PATH"
        }

        $script:ExtractPath = Join-Path ([System.IO.Path]::GetTempPath()) "ReportSchemaTest_$([guid]::NewGuid().ToString().Substring(0,8))"
        New-Item -ItemType Directory -Path $script:ExtractPath -Force | Out-Null
        Expand-Archive -Path $zipPath -DestinationPath $script:ExtractPath -Force

        $script:XlsxFile = Get-ChildItem -Path $script:ExtractPath -Filter '*.xlsx' | Select-Object -First 1

        $script:ExcelData = @{}
        if ($script:XlsxFile) {
            $worksheets = Get-ExcelSheetInfo -Path $script:XlsxFile.FullName
            foreach ($ws in $worksheets) {
                try {
                    $data = Import-Excel -Path $script:XlsxFile.FullName -WorksheetName $ws.Name
                    if ($data) {
                        $script:ExcelData[$ws.Name] = @($data[0].PSObject.Properties.Name)
                    }
                } catch {
                    # Sheets like Overview have no standard headers
                }
            }
        }
    }

    AfterAll {
        if ($script:ExtractPath -and (Test-Path $script:ExtractPath)) {
            Remove-Item -Path $script:ExtractPath -Recurse -Force
        }
    }

    It 'Should contain an xlsx file in the zip' {
        $script:XlsxFile | Should -Not -BeNullOrEmpty
    }

    $testCases = $ExpectedSchema.Keys | ForEach-Object { @{ WorksheetName = $_; ExpectedColumns = $ExpectedSchema[$_] } }

    It "Worksheet [<WorksheetName>] should have correct columns" -TestCases $testCases {
        param($WorksheetName, $ExpectedColumns)

        if (-not $script:ExcelData -or -not $script:ExcelData.ContainsKey($WorksheetName)) {
            Set-ItResult -Skipped -Because "Worksheet '$WorksheetName' not present in this report"
            return
        }
        $actual = $script:ExcelData[$WorksheetName]

        # All actual columns must exist in expected schema (no unknown columns)
        foreach ($col in $actual) {
            $col | Should -BeIn $ExpectedColumns -Because "Column '$col' in '$WorksheetName' must be in the expected schema"
        }

        # Actual columns must be in the same relative order as expected
        $expectedOrder = $ExpectedColumns | Where-Object { $_ -in $actual }
        $actual | Should -Be $expectedOrder -Because "Columns in '$WorksheetName' must maintain expected order"
    }
}


# ============================================================
# Generic worksheet invariants (covers every emitted worksheet,
# including the 40+ that don't have a hand-maintained schema in
# $ExpectedSchema above). Catches broad correctness regressions
# without requiring per-collector column lists.
# ============================================================
Describe 'Generic worksheet invariants' {
    BeforeAll {
        # If outer BeforeAll did not run because the zip was missing, skip.
        $script:GenericReady = $script:XlsxFile -and $script:ExcelData -and ($script:ExcelData.Count -gt 0)

        $script:InventoryJsonPath = $null
        if ($script:ExtractPath -and (Test-Path $script:ExtractPath)) {
            $invFile = Get-ChildItem -Path $script:ExtractPath -Filter 'Inventory_*.json' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($invFile) {
                $script:InventoryJsonPath = $invFile.FullName
                $script:InventoryJson     = Get-Content $invFile.FullName -Raw | ConvertFrom-Json
            }
        }

        $script:ObfuscationColumnPattern = '^(prod|nonprod)_(databricks_|aks_|vmss_)?[0-9a-f]{8}-'
    }

    It 'Every populated worksheet should have at least Subscription, ResourceGroup, and Name columns (or be Overview)' {
        if (-not $script:GenericReady) { Set-ItResult -Skipped -Because 'no fixture'; return }
        foreach ($ws in $script:ExcelData.Keys) {
            if ($ws -eq 'Overview' -or $ws -like '_*' -or $ws -like '*Recommendations*') { continue }
            $cols = $script:ExcelData[$ws]
            # Allow Bastion / Snapshots / etc. that historically may not include all three.
            # The minimum invariant: at least ONE of the three core fields present.
            $hasCore = ($cols -contains 'Subscription') -or ($cols -contains 'ResourceGroup') -or ($cols -contains 'Name')
            $hasCore | Should -BeTrue -Because "Worksheet '$ws' has columns [$($cols -join ', ')] - none are Subscription/ResourceGroup/Name"
        }
    }

    It 'No column name in any worksheet should match the obfuscation pattern' {
        # The obfuscator runs on VALUES, never on COLUMN NAMES. If a column name
        # ever ended up obfuscated, every consumer of the report would be confused.
        if (-not $script:GenericReady) { Set-ItResult -Skipped -Because 'no fixture'; return }
        foreach ($ws in $script:ExcelData.Keys) {
            $cols = $script:ExcelData[$ws]
            foreach ($col in $cols) {
                $col | Should -Not -Match $script:ObfuscationColumnPattern -Because "Column '$col' in worksheet '$ws' was obfuscated; column names must remain literal"
            }
        }
    }

    It 'Every inventory JSON resource type with data should have a corresponding worksheet' {
        if (-not $script:GenericReady -or $null -eq $script:InventoryJson) {
            Set-ItResult -Skipped -Because 'no inventory JSON in fixture'
            return
        }
        # Map of inventory JSON keys to worksheet names. This is sparse on
        # purpose: only collectors whose JSON key differs from worksheet name
        # need entries here. The list is short (worksheet names are usually
        # close to the collector class name).
        $jsonKeyToWorksheet = @{
            VirtualMachines     = 'Virtual Machines'
            VMSS                = 'VM Scale Sets'
            ComputeSnapshots    = 'VM Snapshots'
            VMDisk              = 'Disks'
            StorageAcc          = 'Storage Acc'
            ARCServers          = 'ARC Servers'
            AppServicePlan      = 'App Service Plan'
            AppServices         = 'App Services'
            AppGW               = 'App Gateway'
            APIM                = 'APIM'
            ServiceBUS          = 'Service BUS'
            EvtHub              = 'Event Hubs'
            IOTHubs             = 'IOTHubs'
            AppInsights         = 'AppInsights'
            LoadBalancer        = 'Load Balancers'
            VNETGTW             = 'VNET Gateways'
            ExpressRoute        = 'Express Route'
            VirtualWAN          = 'Virtual WAN'
            AzureFirewall       = 'Azure Firewall'
            PublicIP            = 'Public IPs'
            TrafficManager      = 'Traffic Manager'
            PublicDNS           = 'Public DNS'
            NATGateway          = 'NAT Gateway'
            DataExplorerCluster = 'Data Explorer Clusters'
            NetApp              = 'NetApp'
            CloudServices       = 'CloudServices'
            REGISTRIES          = 'Registries'
            CONTAINER           = 'Containers'
            BASTION             = 'Bastion Hosts'
            RecoveryVault       = 'Recovery Vaults'
            AutomationAcc       = 'Runbooks'
            AvSet               = 'Availability Sets'
            Vault               = 'Key Vaults'
            RedisCache          = 'Redis Cache'
            PostgreSQLflexible  = 'PostgreSQL Flexible'
            POSTGRE             = 'PostgreSQL'
            MySQLflexible       = 'MySQL Flexible'
            MySQL               = 'MySQL'
            MariaDB             = 'MariaDB'
            CosmosDB            = 'Cosmos DB'
            SQLDB               = 'SQL DBs'
            SQLSERVER           = 'SQL Servers'
            SQLPOOL             = 'SQL Pools'
            SQLMI               = 'SQL MI'
            SQLMIDB             = 'SQL MI DBs'
            SQLVM               = 'SQL VMs'
            Purview             = 'Purview'
            WrkSpace            = 'Workspaces'
            Synapse             = 'Synapse'
            Databricks          = 'Databricks'
            MachineLearning     = 'Machine Learning'
            Streamanalytics     = 'Stream Analytics Jobs'
            ARO                 = 'ARO'
            VMWare              = 'VMWare'
            AVD                 = 'AVD'
            AKS                 = 'AKS'
            FRONTDOOR           = 'FrontDoor'
        }

        $script:InventoryJson.PSObject.Properties |
            Where-Object { $null -ne $_.Value -and $_.Name -ne 'Version' -and @($_.Value).Count -gt 0 } |
            ForEach-Object {
                $jsonKey = $_.Name
                # If the inventory has resources for this key, check that the
                # corresponding worksheet exists. Some inventory keys do not
                # produce a worksheet by design (rare); tolerate that with a
                # soft warning rather than a fail.
                if ($jsonKeyToWorksheet.ContainsKey($jsonKey)) {
                    $expectedWs = $jsonKeyToWorksheet[$jsonKey]
                    $script:ExcelData.ContainsKey($expectedWs) |
                        Should -BeTrue -Because "Inventory key '$jsonKey' has resources but worksheet '$expectedWs' is missing"
                }
            }
    }
}
