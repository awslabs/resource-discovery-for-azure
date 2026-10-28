# AKS node pool Autoscale tests
# Run with: Invoke-Pester ./Tests/AKSAutoscale.Tests.ps1 -Output Detailed
#
# Services/Containers/AKS.ps1 wrote 'true' whenever enableAutoScaling was
# present, so a node pool with autoscaling turned off (enableAutoScaling false,
# as Resource Graph returns it) read as autoscaled. The column is 'true' for
# the boolean true, 'false' for false, absent or null, and an empty cell for any
# other value. The REAL collector runs on synthetic records; no live Azure.

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
