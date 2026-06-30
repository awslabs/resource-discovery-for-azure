# Unmask-Obfuscation.ps1 unit tests
# =============================================================================
# Offline, self-contained tests for the reverse-lookup (unmask) helper.
#
# These build a SYNTHETIC ObfuscationDictionary fixture in a temp file (no real
# Azure data, no network) that mirrors the real dictionary shape produced by
# ResourceInventory.ps1 -Obfuscate:
#   - four maps (ResourceIdMap / ResourceNameMap / SubscriptionMap /
#     ResourceGroupMap), each keyed by an obfuscated prod_/nonprod_ token and
#     valued with the REAL resource Id (an ARM path) the token came from.
#   - a GeneratedAt stamp.
#
# The fixture deliberately exercises the edge cases observed in real output:
#   - a mix of prod_ and nonprod_ tokens
#   - a nested SQL child resource (.../servers/<s>/databases/<db>) so the
#     ResourceName "last segment" rule is tested on a deep path
#   - a name token that embeds a resource-type hint (nonprod_vmss_...)
#   - an AKS managed resource group (MC_...) whose name is parsed from the Id
#   - resource-group name casing preserved verbatim from the Id
#   - multiple resources sharing one resource group token (determinism)
#   - the lossy sentinels ('obfuscated', 'obfuscated_<guid>')
#
# All identifiers below are fabricated. The subscription GUID is the Azure
# documentation placeholder. No customer data.
# =============================================================================

BeforeAll {
    $script:UnmaskScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'Unmask-Obfuscation.ps1'
    if (-not (Test-Path $script:UnmaskScript)) {
        throw "Unmask-Obfuscation.ps1 not found at $script:UnmaskScript"
    }

    $sub = '12345678-1234-1234-1234-123456789012'   # Azure docs placeholder GUID
    $base = "/subscriptions/$sub/resourceGroups"

    # Real Ids the tokens resolve back to.
    $script:IdVm     = "$base/rg-app/providers/Microsoft.Compute/virtualMachines/vm01"
    $script:IdSqlDb  = "$base/rg-data/providers/Microsoft.Sql/servers/sqlsrv01/databases/appdb"
    $script:IdVmss   = "$base/rg-dev/providers/Microsoft.Compute/virtualMachineScaleSets/vmss01"
    $script:IdAks    = "$base/MC_rg-aks_aks01_eastus/providers/Microsoft.Compute/virtualMachines/aksnode0"
    $script:IdCase   = "/subscriptions/$sub/resourceGroups/RG-APP/providers/Microsoft.Storage/storageAccounts/sa01"

    # Obfuscated tokens. Real tokens are prod_/nonprod_ followed by a GUID, but
    # the script treats them purely as opaque dictionary keys, so these tests
    # use readable, obviously-synthetic keys. (Real GUID-shaped strings here
    # would trip secret/identifier scanners despite being fabricated.)
    $script:TokIdVm    = 'prod_tok-id-vm'
    $script:TokIdSql   = 'prod_tok-id-sql'
    $script:TokNameVm  = 'prod_tok-name-vm'
    $script:TokNameSql = 'prod_tok-name-sql'
    $script:TokNameVmss= 'nonprod_vmss_tok-name-vmss'   # embedded type hint
    $script:TokRgApp   = 'prod_tok-rg-app'
    $script:TokRgData  = 'prod_tok-rg-data'
    $script:TokRgAks   = 'prod_tok-rg-aks'
    $script:TokRgCase  = 'prod_tok-rg-case'
    $script:TokSub     = 'prod_tok-sub'

    $dict = [ordered]@{
        GeneratedAt = '2026-06-30 00:00:00'
        ResourceIdMap = [ordered]@{
            $script:TokIdVm  = $script:IdVm
            $script:TokIdSql = $script:IdSqlDb
        }
        ResourceNameMap = [ordered]@{
            $script:TokNameVm   = $script:IdVm
            $script:TokNameSql  = $script:IdSqlDb
            $script:TokNameVmss = $script:IdVmss
        }
        SubscriptionMap = [ordered]@{
            $script:TokSub = $script:IdVm
        }
        ResourceGroupMap = [ordered]@{
            $script:TokRgApp  = $script:IdVm     # rg-app (also covers vm02 determinism conceptually)
            $script:TokRgData = $script:IdSqlDb  # rg-data
            $script:TokRgAks  = $script:IdAks    # MC_... managed RG
            $script:TokRgCase = $script:IdCase   # RG-APP (uppercase) -> casing preserved
        }
    }

    $script:TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("UnmaskTest_" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:TmpDir -Force | Out-Null
    $script:DictPath = Join-Path $script:TmpDir 'ObfuscationDictionary_Test.json'
    $dict | ConvertTo-Json -Depth 5 | Set-Content -Path $script:DictPath -Encoding utf8

    # Helper: invoke the real script for a single value.
    function Invoke-Unmask {
        param([string]$Value, [string[]]$Field)
        $splat = @{ DictionaryPath = $script:DictPath; Value = $Value }
        if ($Field) { $splat['Field'] = $Field }
        & $script:UnmaskScript @splat
    }
}

AfterAll {
    if ($script:TmpDir -and (Test-Path $script:TmpDir)) {
        Remove-Item -Path $script:TmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe "Unmask-Obfuscation field resolution" {

    It "resolves a ResourceGroup token to the RG name parsed from the Id" {
        $r = Invoke-Unmask -Value $script:TokRgApp
        $r.Type      | Should -Be 'ResourceGroup'
        $r.RealValue | Should -Be 'rg-app'
    }

    It "resolves an AKS managed (MC_) resource group name" {
        $r = Invoke-Unmask -Value $script:TokRgAks
        $r.Type      | Should -Be 'ResourceGroup'
        $r.RealValue | Should -Be 'MC_rg-aks_aks01_eastus'
    }

    It "preserves the resource-group name casing exactly as it appears in the Id" {
        $r = Invoke-Unmask -Value $script:TokRgCase
        $r.RealValue | Should -Be 'RG-APP'
    }

    It "resolves a Subscription token to the subscription GUID" {
        $r = Invoke-Unmask -Value $script:TokSub
        $r.Type      | Should -Be 'Subscription'
        $r.RealValue | Should -Be '12345678-1234-1234-1234-123456789012'
    }

    It "notes that -ResolveSubscriptionName is needed for the friendly name" {
        $r = Invoke-Unmask -Value $script:TokSub
        $r.Note | Should -Match 'ResolveSubscriptionName'
    }

    It "resolves a ResourceId token to the full ARM Id" {
        $r = Invoke-Unmask -Value $script:TokIdVm
        $r.Type      | Should -Be 'ResourceId'
        $r.RealValue | Should -Be $script:IdVm
    }

    It "resolves a ResourceName token to the last Id segment" {
        $r = Invoke-Unmask -Value $script:TokNameVm
        $r.Type      | Should -Be 'ResourceName'
        $r.RealValue | Should -Be 'vm01'
    }

    It "resolves a nested SQL child ResourceName to the database name" {
        $r = Invoke-Unmask -Value $script:TokNameSql
        $r.Type      | Should -Be 'ResourceName'
        $r.RealValue | Should -Be 'appdb'
    }

    It "resolves a ResourceName token that embeds a type hint (vmss)" {
        $r = Invoke-Unmask -Value $script:TokNameVmss
        $r.Type      | Should -Be 'ResourceName'
        $r.RealValue | Should -Be 'vmss01'
    }
}

Describe "Unmask-Obfuscation lossy and not-found handling" {

    It "reports the literal 'obfuscated' sentinel as Lossy" {
        $r = Invoke-Unmask -Value 'obfuscated'
        $r.Type | Should -Be 'Lossy'
        $r.RealValue | Should -BeNullOrEmpty
    }

    It "reports the 'obfuscated_<guid>' fallback as Lossy" {
        $r = Invoke-Unmask -Value 'obfuscated_fallback-token-sample'
        $r.Type | Should -Be 'Lossy'
    }

    It "reports an unknown token as NotFound" {
        $r = Invoke-Unmask -Value 'prod_does-not-exist-0000'
        $r.Type | Should -Be 'NotFound'
    }
}

Describe "Unmask-Obfuscation -Field scoping" {

    It "resolves when the token's field type is selected" {
        $r = Invoke-Unmask -Value $script:TokRgApp -Field 'ResourceGroup'
        $r.Type | Should -Be 'ResourceGroup'
    }

    It "returns NotFound when the token's field type is excluded" {
        # TokIdVm lives in ResourceIdMap; restricting to ResourceGroup must miss it.
        $r = Invoke-Unmask -Value $script:TokIdVm -Field 'ResourceGroup'
        $r.Type | Should -Be 'NotFound'
    }
}

Describe "Unmask-Obfuscation pipeline and -All" {

    It "returns one result per piped value" {
        $results = @($script:TokRgApp, $script:TokSub) | & $script:UnmaskScript -DictionaryPath $script:DictPath
        @($results).Count | Should -Be 2
    }

    It "dumps every Subscription mapping with -All -Field Subscription" {
        $results = & $script:UnmaskScript -DictionaryPath $script:DictPath -All -Field 'Subscription'
        @($results).Count | Should -Be 1
        @($results)[0].Type | Should -Be 'Subscription'
    }

    It "defaults -All to Subscription + ResourceGroup maps" {
        $results = & $script:UnmaskScript -DictionaryPath $script:DictPath -All
        # 4 ResourceGroup tokens + 1 Subscription token = 5
        @($results).Count | Should -Be 5
    }
}

Describe "Unmask-Obfuscation dictionary handling" {

    It "auto-discovers the newest dictionary in -SearchDirectory" {
        $r = & $script:UnmaskScript -SearchDirectory $script:TmpDir -Value $script:TokRgApp
        $r.RealValue | Should -Be 'rg-app'
    }

    It "throws on a dictionary missing a required map" {
        $badDir = Join-Path $script:TmpDir 'bad'
        New-Item -ItemType Directory -Path $badDir -Force | Out-Null
        $badPath = Join-Path $badDir 'ObfuscationDictionary_Bad.json'
        @{ GeneratedAt = 'x'; ResourceIdMap = @{}; ResourceNameMap = @{}; SubscriptionMap = @{} } |
            ConvertTo-Json | Set-Content -Path $badPath -Encoding utf8
        { & $script:UnmaskScript -DictionaryPath $badPath -Value 'prod_x' } | Should -Throw
    }
}
