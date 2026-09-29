#Requires -Version 7.0
<#
    ObfuscationUri.Tests.ps1

    Direct unit tests for the extracted ARM-URI obfuscation helpers in
    Functions/ResourceInventory.Functions.ps1:

      Resolve-ObfuscationToken   - stable token resolution (shared read-only -> local cache -> mint)
      Build-ObfuscatedResourceUri - segment-by-segment ARM-URI rebuild

    These lock the contract the consumption path (ResourceInventory.ps1) and the
    metrics fallback (Extension/Metrics.ps1) both depend on: structure / provider /
    TYPE and the mc_ AKS-managed-RG marker are preserved so the dashboard can still
    categorise a masked row, only identifying segments are tokenised, the leaf
    reuse of the inventory token is READ-ONLY against the shared dictionary, and
    the same input always yields the same token (determinism).

    Offline: dot-sources the definitions only; no Azure calls, no run.
#>

BeforeAll {
    $FunctionsFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/ResourceInventory.Functions.ps1'
    if (-not (Test-Path -LiteralPath $FunctionsFile)) { throw "ResourceInventory.Functions.ps1 not found at $FunctionsFile" }
    . $FunctionsFile

    # A canonical ARM id uses lowercase 'resourcegroups' as the consumption/metrics paths feed it.
    $script:Sub = '12345678-1234-1234-1234-123456789012'
    $script:Canonical = "/subscriptions/$script:Sub/resourcegroups/rg1/providers/microsoft.compute/virtualmachines/vm1"

    function New-Caches { return @{ Sub = @{}; Rg = @{}; Name = @{} } }

    function Invoke-Build
    {
        param([string]$Uri, [string]$Prefix = 'prod_', $NameDict = $null, $Caches)
        if (-not $Caches) { $Caches = New-Caches }
        Build-ObfuscatedResourceUri -RawUri $Uri -Prefix $Prefix `
            -SubscriptionDictionary $null -ResourceGroupDictionary $null -NameDictionary $NameDict `
            -SubCache $Caches.Sub -RgCache $Caches.Rg -NameCache $Caches.Name
    }
}

Describe 'Resolve-ObfuscationToken' {

    It 'mints a prefix+GUID into the local cache on a first miss' {
        $Cache = @{}
        $Token = Resolve-ObfuscationToken -RealValue 'realA' -LookupKey 'k' -SharedDictionary $null -LocalCache $Cache -TokenPrefix 'prod_sub_'
        $Token | Should -Match '^prod_sub_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        $Cache['realA'] | Should -Be $Token -Because 'the minted token must be cached under the real value'
    }

    It 'is deterministic: the same real value returns the same token from the local cache' {
        $Cache = @{}
        $T1 = Resolve-ObfuscationToken -RealValue 'realA' -LookupKey 'k1' -SharedDictionary $null -LocalCache $Cache -TokenPrefix 'prod_'
        $T2 = Resolve-ObfuscationToken -RealValue 'realA' -LookupKey 'k2' -SharedDictionary $null -LocalCache $Cache -TokenPrefix 'prod_'
        $T2 | Should -Be $T1 -Because 'the local cache is keyed by the real value, so a second lookup must reuse the first token'
    }

    It 'prefers the shared dictionary (keyed by LookupKey) over minting' {
        $Shared = @{ 'the-key' = 'inventory_token' }
        $Cache = @{}
        $Token = Resolve-ObfuscationToken -RealValue 'realA' -LookupKey 'the-key' -SharedDictionary $Shared -LocalCache $Cache -TokenPrefix 'prod_'
        $Token | Should -Be 'inventory_token'
        $Cache.Count | Should -Be 0 -Because 'a shared-dictionary hit must not write to the local cache'
    }

    It 'is READ-ONLY against the shared dictionary on a miss (count unchanged)' {
        $Shared = @{ 'other-key' = 'x' }
        $Before = $Shared.Count
        $null = Resolve-ObfuscationToken -RealValue 'realA' -LookupKey 'absent-key' -SharedDictionary $Shared -LocalCache @{} -TokenPrefix 'prod_'
        $Shared.Count | Should -Be $Before -Because 'a miss must never write back into the shared dictionary'
    }
}

Describe 'Build-ObfuscatedResourceUri - structure preservation' {

    It 'canonical URI: masks sub / RG / name, keeps provider + type verbatim' {
        $Out = Invoke-Build -Uri $script:Canonical
        $Out | Should -Match '^/subscriptions/prod_sub_[0-9a-f-]+/resourcegroups/prod_rg_[0-9a-f-]+/providers/microsoft\.compute/virtualmachines/prod_[0-9a-f-]+$'
        $Out | Should -Match '/providers/microsoft\.compute/virtualmachines/' -Because 'the provider and TYPE segments carry the categorisation signal and must survive'
    }

    It 'RG-less URI: subscription-only path is preserved (no /resourcegroups/ synthesised)' {
        $Out = Invoke-Build -Uri "/subscriptions/$script:Sub/providers/microsoft.resources/deployments/dep1"
        $Out | Should -Match '^/subscriptions/prod_sub_[0-9a-f-]+/providers/microsoft\.resources/deployments/prod_[0-9a-f-]+$'
        $Out | Should -Not -Match '/resourcegroups/' -Because 'the source URI had no resource group; one must not be invented'
    }

    It 'provider-less URI: subscription + RG only, no providers tail' {
        $Out = Invoke-Build -Uri "/subscriptions/$script:Sub/resourcegroups/rg1"
        $Out | Should -Match '^/subscriptions/prod_sub_[0-9a-f-]+/resourcegroups/prod_rg_[0-9a-f-]+$'
        $Out | Should -Not -Match '/providers/'
    }

    It 'nested child resource: alternating type/name masks every NAME, keeps every TYPE' {
        $Uri = "/subscriptions/$script:Sub/resourcegroups/rg1/providers/microsoft.sql/servers/srv1/databases/db1"
        $Out = Invoke-Build -Uri $Uri
        $Out | Should -Match '/providers/microsoft\.sql/servers/prod_[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}/databases/prod_[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' `
            -Because 'servers and databases are TYPE segments (kept); srv1 and db1 are NAME segments (masked)'
        $Out | Should -Not -Match 'srv1'
        # db1 is all hex, so it can occur by chance inside a minted GUID; look past the tokens' GUIDs.
        ($Out -replace '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', '<guid>') | Should -Not -Match 'db1'
    }

    It 'mc_ resource-group prefix is preserved in the RG token' {
        $Out = Invoke-Build -Uri "/subscriptions/$script:Sub/resourcegroups/mc_myaks_cluster_eastus/providers/microsoft.compute/virtualmachinescalesets/vmss1"
        $Out | Should -Match '/resourcegroups/prod_rg_mc_[0-9a-f-]+/' -Because 'the mc_ marker lets the dashboard detect AKS-managed resources after masking'
    }

    It '$system name segment is left intact (not tokenised)' {
        $Out = Invoke-Build -Uri "/subscriptions/$script:Sub/resourcegroups/rg1/providers/microsoft.storage/storageaccounts/`$system"
        $Out | Should -Match ([regex]::Escape('/storageaccounts/$system') + '$') -Because '$system is a well-known placeholder, not an identifying name'
    }
}

Describe 'Build-ObfuscatedResourceUri - non-ARM and empty shapes' {

    It 'empty URI -> the literal sentinel ''obfuscated''' {
        Invoke-Build -Uri '' | Should -Be 'obfuscated'
    }

    It 'non-ARM shape -> a single cached token (no segment structure)' {
        $Out = Invoke-Build -Uri 'some/marketplace/meter/thing'
        $Out | Should -Match '^prod_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        $Out | Should -Not -Match '/' -Because 'a non-ARM shape collapses to one opaque token, it is not rebuilt segment-by-segment'
    }

    It 'non-ARM shape is deterministic within a run (same input -> same token via NameCache)' {
        $Caches = New-Caches
        $A = Invoke-Build -Uri 'weird-non-arm-id' -Caches $Caches
        $B = Invoke-Build -Uri 'weird-non-arm-id' -Caches $Caches
        $B | Should -Be $A
    }
}

Describe 'Build-ObfuscatedResourceUri - determinism and the read-only leaf link' {

    It 'determinism: the same canonical URI twice (same caches) yields the same token' {
        $Caches = New-Caches
        $A = Invoke-Build -Uri $script:Canonical -Caches $Caches
        $B = Invoke-Build -Uri $script:Canonical -Caches $Caches
        $B | Should -Be $A -Because 'sub/rg/name all resolve from the per-run caches on the second pass'
    }

    It 'a case-insensitive inventory dictionary hit returns the SAME inventory leaf token' {
        # The four identifier dictionaries are OrdinalIgnoreCase in the real run; the
        # leaf must join back to inventory even when the billing URI differs in case.
        $InvDict = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $InvDict[$script:Canonical.ToUpper()] = 'inventory_leaf_token'
        $Out = Invoke-Build -Uri $script:Canonical -NameDict $InvDict
        $Out | Should -Match '/virtualmachines/inventory_leaf_token$' -Because 'the leaf name segment must reuse the exact token inventory assigned, despite casing drift'
    }

    It 'read-only guarantee: an inventory-dictionary MISS does not change its count' {
        $InvDict = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $InvDict['/subscriptions/aaa/resourcegroups/rg/providers/microsoft.compute/virtualmachines/other'] = 'x'
        $Before = $InvDict.Count
        $null = Invoke-Build -Uri $script:Canonical -NameDict $InvDict   # not present -> miss
        $InvDict.Count | Should -Be $Before -Because 'the consumption/metrics leaf link is READ-ONLY; a miss must never inject a consumption-derived key into the exported ResourceIdMap'
    }

    It 'only the LEAF reuses inventory: an intermediate name is NOT drawn from the inventory dict' {
        # A nested child; the inventory dict carries a value under $RawUri, but only the
        # leaf (largest even index) may consult it - intermediate names use the name cache.
        $Uri = "/subscriptions/$script:Sub/resourcegroups/rg1/providers/microsoft.sql/servers/srv1/databases/db1"
        $InvDict = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $InvDict[$Uri] = 'leaf_only_token'
        $Out = Invoke-Build -Uri $Uri -NameDict $InvDict
        $Out | Should -Match '/databases/leaf_only_token$' -Because 'db1 is the leaf and reuses the inventory token'
        ($Out -split '/servers/')[1].StartsWith('leaf_only_token') | Should -BeFalse -Because 'srv1 is an intermediate name and must get its own cache token, not the leaf inventory token'
    }
}

Describe 'Get-RdaEnvironmentPrefix - one value, classified the way inventory classifies it' {

    It "labels '<Value>' as <Expected>" -ForEach @(
        @{ Value = 'rg-test'; Expected = 'nonprod_' }
        @{ Value = 'app-dev-01'; Expected = 'nonprod_' }
        @{ Value = 'UAT-Web'; Expected = 'nonprod_' }
        @{ Value = 'd-app01'; Expected = 'nonprod_' }
        @{ Value = 'app-t-01'; Expected = 'nonprod_' }
        @{ Value = 'vm1'; Expected = 'prod_' }
        @{ Value = 'rg-app'; Expected = 'prod_' }
        @{ Value = 'production'; Expected = 'prod_' }
        @{ Value = '12345678-1234-1234-1234-123456789012'; Expected = 'prod_' }
    ) {
        Get-RdaEnvironmentPrefix $Value | Should -BeExactly $Expected
    }

    It 'does not treat a slash as a segment boundary, because it judges one segment and not a path' {
        Get-RdaEnvironmentPrefix 'shared/d-app' | Should -BeExactly 'prod_' -Because 'a neighbouring segment must not change this segment''s answer'
    }

    It 'uses exactly the two patterns the inventory loop applies to a resource name, a subscription name and a resource-group name' {
        $Root = Split-Path $PSScriptRoot -Parent
        $InventorySrc = Get-Content -LiteralPath (Join-Path $Root 'ResourceInventory.ps1') -Raw
        $FunctionsAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'Functions/ResourceInventory.Functions.ps1'), [ref]$null, [ref]$null)
        $HelperAst = $FunctionsAst.Find({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -like '*Get-RdaEnvironmentPrefix' }, $true)
        $HelperAst | Should -Not -BeNullOrEmpty -Because 'the helper must exist before its patterns can be compared'
        $PairOf = {
            param([string]$Source, [string]$Subject)
            $Pattern = [regex]::Escape($Subject) + " -match '([^']+)' -or " + [regex]::Escape($Subject) + " -match '([^']+)'"
            $Found = [regex]::Match($Source, $Pattern)
            $Found.Success | Should -BeTrue -Because ("the classifier on {0} must still be written as two -match tests" -f $Subject)
            '{0} || {1}' -f $Found.Groups[1].Value, $Found.Groups[2].Value
        }
        $Helper = & $PairOf $HelperAst.Extent.Text '$Value'
        (& $PairOf $InventorySrc '$resourceItem.name') | Should -BeExactly $Helper
        (& $PairOf $InventorySrc '$RealSub') | Should -BeExactly $Helper
        (& $PairOf $InventorySrc '$RealRG') | Should -BeExactly $Helper
    }
}

Describe 'Build-ObfuscatedResourceUri -PerSegmentPrefix - each token labelled by its own value' {

    BeforeAll {
        function Invoke-SegmentBuild
        {
            param([string]$Uri, [string]$Prefix = 'prod_', [string]$SubPrefix = '', $NameDict = $null, $Caches)
            if (-not $Caches) { $Caches = New-Caches }
            Build-ObfuscatedResourceUri -RawUri $Uri -Prefix $Prefix -SubPrefix $SubPrefix -PerSegmentPrefix `
                -SubscriptionDictionary $null -ResourceGroupDictionary $null -NameDictionary $NameDict `
                -SubCache $Caches.Sub -RgCache $Caches.Rg -NameCache $Caches.Name
        }
    }

    It 'a test resource group in a production subscription no longer relabels the subscription or the resource' {
        $Uri = "/subscriptions/$script:Sub/resourcegroups/rg-test/providers/microsoft.compute/virtualmachines/vm-app"
        $Out = Invoke-SegmentBuild -Uri $Uri -Prefix 'nonprod_' -SubPrefix 'prod_'
        $Out | Should -Match '^/subscriptions/prod_sub_[0-9a-f-]+/resourcegroups/nonprod_rg_[0-9a-f-]+/providers/microsoft\.compute/virtualmachines/prod_[0-9a-f-]+$'
    }

    It 'a dev resource in a production resource group is labelled on its own name' {
        $Uri = "/subscriptions/$script:Sub/resourcegroups/rg-app/providers/microsoft.compute/virtualmachines/vm-dev"
        $Out = Invoke-SegmentBuild -Uri $Uri -SubPrefix 'prod_'
        $Out | Should -Match '/resourcegroups/prod_rg_[0-9a-f-]+/providers/microsoft\.compute/virtualmachines/nonprod_[0-9a-f-]+$'
    }

    It 'takes the subscription marker from -SubPrefix, not from -Prefix' {
        $Out = Invoke-SegmentBuild -Uri $script:Canonical -Prefix 'prod_' -SubPrefix 'nonprod_'
        $Out | Should -Match '^/subscriptions/nonprod_sub_'
    }

    It 'keeps the mc_ marker on an AKS-managed resource group' {
        $Uri = "/subscriptions/$script:Sub/resourcegroups/mc_rg_aks-dev/providers/microsoft.network/loadbalancers/kubernetes"
        $Out = Invoke-SegmentBuild -Uri $Uri -SubPrefix 'prod_'
        $Out | Should -Match '/resourcegroups/nonprod_rg_mc_[0-9a-f-]+/'
    }

    It 'labels each name segment of a child resource on its own value' {
        $Uri = "/subscriptions/$script:Sub/resourcegroups/rg-app/providers/microsoft.sql/servers/sql-app/databases/db-test"
        $Out = Invoke-SegmentBuild -Uri $Uri -SubPrefix 'prod_'
        $Out | Should -Match '/servers/prod_[0-9a-f-]+/databases/nonprod_[0-9a-f-]+$'
    }

    It 'still reuses the inventory token for the leaf' {
        $Uri = "/subscriptions/$script:Sub/resourcegroups/rg-test/providers/microsoft.compute/virtualmachines/vm-app"
        $InvDict = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $InvDict[$Uri] = 'inventory_leaf_token'
        $Out = Invoke-SegmentBuild -Uri $Uri -SubPrefix 'prod_' -NameDict $InvDict
        $Out | Should -Match '/virtualmachines/inventory_leaf_token$'
    }

    It 'gives one resource group the same token across different resources in a run' {
        $Caches = New-Caches
        $A = Invoke-SegmentBuild -Uri "/subscriptions/$script:Sub/resourcegroups/rg-test/providers/microsoft.compute/virtualmachines/vm-a" -SubPrefix 'prod_' -Caches $Caches
        $B = Invoke-SegmentBuild -Uri "/subscriptions/$script:Sub/resourcegroups/rg-test/providers/microsoft.storage/storageaccounts/sta" -SubPrefix 'prod_' -Caches $Caches
        ($A -split '/')[4] | Should -BeExactly ($B -split '/')[4]
        ($A -split '/')[2] | Should -BeExactly ($B -split '/')[2]
    }

    It 'labels a value that is not ARM-shaped with -Prefix, which has no segments to judge' {
        $Out = Invoke-SegmentBuild -Uri '/providers/microsoft.capacity/reservationorders/order1' -Prefix 'nonprod_' -SubPrefix 'prod_'
        $Out | Should -Match '^nonprod_[0-9a-f-]+$'
    }

    It 'without the switch, every segment keeps the single -Prefix (existing callers unchanged)' {
        $Uri = "/subscriptions/$script:Sub/resourcegroups/rg-test/providers/microsoft.compute/virtualmachines/vm-app"
        $Out = Invoke-Build -Uri $Uri -Prefix 'prod_'
        $Out | Should -Match '^/subscriptions/prod_sub_[0-9a-f-]+/resourcegroups/prod_rg_[0-9a-f-]+/providers/microsoft\.compute/virtualmachines/prod_[0-9a-f-]+$'
    }
}

Describe 'Consumption call site - the only caller that labels per segment' {

    BeforeAll {
        $Root = Split-Path $PSScriptRoot -Parent
        $script:InventorySrc = Get-Content -LiteralPath (Join-Path $Root 'ResourceInventory.ps1') -Raw
        $script:CallerFiles = @('ResourceInventory.ps1', 'Extension/Metrics.ps1', 'Functions/ResourceInventory.Functions.ps1')
    }

    It 'passes the subscription-name marker and -PerSegmentPrefix to the builder' {
        $Call = [regex]::Match($script:InventorySrc, 'Build-ObfuscatedResourceUri -RawUri \$RawUri [^\r\n]+')
        $Call.Success | Should -BeTrue
        $Call.Value | Should -Match '-SubPrefix \$SubPrefix -PerSegmentPrefix'
        $script:InventorySrc | Should -Match '\$SubPrefix = Get-RdaEnvironmentPrefix \$\(if \(-not \[string\]::IsNullOrEmpty\(\$sub\.Name\)\) \{ \$sub\.Name \} else \{ \$sub\.Id \}\)'
    }

    It 'no other caller opts in, so Marketplace, Foundry and metrics tokens are unchanged' {
        $Root = Split-Path $PSScriptRoot -Parent
        $OptIns = foreach ($File in $script:CallerFiles)
        {
            Get-Content -LiteralPath (Join-Path $Root $File) | Where-Object { $_ -match 'Build-ObfuscatedResourceUri\b.*-PerSegmentPrefix' } | ForEach-Object { '{0}: {1}' -f $File, $_.Trim() }
        }
        @($OptIns).Count | Should -Be 1 -Because (@($OptIns) -join '; ')
    }
}
