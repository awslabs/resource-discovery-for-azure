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
