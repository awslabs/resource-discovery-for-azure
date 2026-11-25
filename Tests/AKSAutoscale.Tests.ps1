# AKS node pool Autoscale tests
# Run with: Invoke-Pester ./Tests/AKSAutoscale.Tests.ps1 -Output Detailed
#
# Services/Containers/AKS.ps1 wrote 'true' whenever enableAutoScaling was
# present, so a node pool with autoscaling turned off (enableAutoScaling false,
# as Resource Graph returns it) read as autoscaled. The column is 'true' for
# the boolean true, 'false' for false, absent or null, and an empty cell for any
# other value.
#
# Azure sets minCount and maxCount only on a pool with autoscaling on, and the
# collector wrote '0' in AutoscaleMax and AutoscaleMin when they were absent,
# which reads as a pool that may scale to no nodes. Both cells now carry Azure's
# value: empty when absent, the number when set, including a real 0.
#
# The REAL collector runs on synthetic records; no live Azure.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    # The Azure documentation placeholder; not a real subscription id.
    $script:Guid = '12345678-1234-1234-1234-123456789012'
    $script:Subs = @([pscustomobject]@{ id = $script:Guid; Name = 'sub-placeholder' })
    $script:Rg = "/subscriptions/$($script:Guid)/resourceGroups/rg-a/providers"

    function Invoke-Collector
    {
        param($Records)
        $Saved = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        try { return , @(& (Join-Path $script:Root 'Services/Containers/AKS.ps1') -Sub $script:Subs -Resources @($Records) -Task 'Processing' -ResourceIdDictionary $null) }
        finally { $ErrorActionPreference = $Saved }
    }

    function New-Cluster
    {
        param([string]$Mode, $Value)
        $Pool = [ordered]@{ name = 'pool1'; count = 3; vmSize = 'Standard_D2s_v3'; maxCount = 5; minCount = 1 }
        if ($Mode -eq 'value') { $Pool['enableAutoScaling'] = $Value }
        [pscustomobject]@{
            TYPE           = 'microsoft.containerservice/managedclusters'
            id             = "$($script:Rg)/microsoft.containerservice/managedclusters/aks-a"
            NAME           = 'aks-a'
            RESOURCEGROUP  = 'rg-a'
            LOCATION       = 'eastus'
            subscriptionId = $script:Guid
            sku            = [pscustomobject]@{ name = 'Base'; tier = 'Free' }
            PROPERTIES     = [pscustomobject]@{ kubernetesVersion = '1.29'; agentPoolProfiles = @([pscustomobject]$Pool) }
        }
    }
}

Describe 'AKS node pool Autoscale' {
    It 'writes <Expected> for enableAutoScaling <Label>' -ForEach @(
        @{ Label = 'true'; Mode = 'value'; Value = $true; Expected = 'true' }
        @{ Label = 'false'; Mode = 'value'; Value = $false; Expected = 'false' }
        @{ Label = 'absent'; Mode = 'absent'; Value = $null; Expected = 'false' }
        @{ Label = 'null'; Mode = 'value'; Value = $null; Expected = 'false' }
    ) {
        $Rows = Invoke-Collector @(New-Cluster -Mode $Mode -Value $Value)
        $Rows.Count | Should -Be 1
        $Rows[0].Autoscale | Should -BeExactly $Expected
    }

    It 'writes an empty cell for a value that is not a boolean (<Label>), and keeps the row' -ForEach @(
        @{ Label = "'yes'"; Value = 'yes' }
        @{ Label = "'true' as text"; Value = 'true' }
        @{ Label = 'the number 1'; Value = 1 }
        @{ Label = 'an object'; Value = [pscustomobject]@{ value = 'not-a-value' } }
    ) {
        $Rows = Invoke-Collector @(New-Cluster -Mode 'value' -Value $Value)
        $Rows.Count | Should -Be 1
        $Rows[0].Autoscale | Should -BeNullOrEmpty
        $Rows[0].NodePoolName | Should -BeExactly 'pool1'
    }
}

Describe 'AKS node pool autoscale bounds' {
    BeforeAll {
        # A pool with autoscaling off, as Azure returns it: enableAutoScaling false
        # and no minCount or maxCount. Then a pool with autoscaling on, and one
        # that may scale down to 0 nodes. Built as Resource Graph answers reach the
        # collectors: JSON text, lowercased, then ConvertFrom-Json.
        $Pools = @(
            [ordered]@{ name = 'fixedpool'; count = 1; vmSize = 'Standard_D2as_v4'; osDiskSizeGB = 128; type = 'VirtualMachineScaleSets'; mode = 'System'; osType = 'Linux'; maxPods = 110; enableAutoScaling = $false; orchestratorVersion = '1.30.4' }
            [ordered]@{ name = 'scalepool'; count = 2; vmSize = 'Standard_D4s_v5'; osDiskSizeGB = 128; type = 'VirtualMachineScaleSets'; mode = 'User'; osType = 'Linux'; maxPods = 110; enableAutoScaling = $true; minCount = 1; maxCount = 5; orchestratorVersion = '1.30.4' }
            [ordered]@{ name = 'zeropool'; count = 0; vmSize = 'Standard_D4s_v5'; osDiskSizeGB = 128; type = 'VirtualMachineScaleSets'; mode = 'User'; osType = 'Linux'; maxPods = 110; enableAutoScaling = $true; minCount = 0; maxCount = 3; orchestratorVersion = '1.30.4' }
        )
        $Cluster = [ordered]@{ id = "$($script:Rg)/Microsoft.ContainerService/managedClusters/aks-1"; name = 'aks-1'; type = 'microsoft.containerservice/managedclusters'; resourceGroup = 'rg-a'; location = 'eastus'; subscriptionId = $script:Guid; sku = [ordered]@{ name = 'Base'; tier = 'Free' }; properties = [ordered]@{ kubernetesVersion = '1.30.4'; agentPoolProfiles = $Pools } }
        $Records = (ConvertTo-Json -InputObject @($Cluster) -Depth 10).ToLower() | ConvertFrom-Json
        $script:AksRows = Invoke-Collector @($Records)
    }

    It 'writes one row per node pool' {
        ($script:AksRows | ForEach-Object { $_.NodePoolName }) | Should -Be @('fixedpool', 'scalepool', 'zeropool')
    }

    It 'leaves AutoscaleMax and AutoscaleMin empty for a pool with autoscaling off, not 0' {
        $script:AksRows[0].Autoscale | Should -BeExactly 'false'
        $script:AksRows[0].AutoscaleMax | Should -BeNullOrEmpty
        $script:AksRows[0].AutoscaleMin | Should -BeNullOrEmpty
        $script:AksRows[0].Nodes | Should -Be 1
    }

    It 'keeps the bounds of a pool with autoscaling on, including a real 0' {
        $script:AksRows[1].AutoscaleMax | Should -Be 5
        $script:AksRows[1].AutoscaleMin | Should -Be 1
        $script:AksRows[2].AutoscaleMax | Should -Be 3
        $script:AksRows[2].AutoscaleMin | Should -Be 0
        $script:AksRows[2].AutoscaleMin | Should -Not -BeNullOrEmpty
    }
}
