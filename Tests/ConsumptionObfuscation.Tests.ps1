# Consumption Obfuscation null-URI regression tests
# Run with: Invoke-Pester ./Tests/ConsumptionObfuscation.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# The obfuscate-mode consumption path in ResourceInventory.ps1
# (GetResorceConsumption) rebuilds each usage record's resourceUri. Some Azure
# meter types legitimately have a NULL resourceUri (marketplace purchases,
# certain reservations, tenant-level charges). The original code fed that value
# straight into [hashtable].ContainsKey($rawUri); ContainsKey($null) THROWS
# (ArgumentNullException), and the per-subscription try/catch swallowed it -
# aborting the rest of that subscription's consumption collection. Net effect:
# inventory completed but consumption was silently truncated, ONLY under
# -Obfuscate.
#
# This test is SELF-CONTAINED: it replicates the obfuscation guard
# logic exactly as it appears in ResourceInventory.ps1 and proves a null/empty
# resourceUri does not throw and yields the 'obfuscated' fallback token, while a
# normal ARM-shaped uri still obfuscates deterministically. It does NOT need a
# live Azure run or an output zip. If the guard logic in ResourceInventory.ps1
# changes, update the helper below to match.

BeforeAll {
    # Faithful copy of the consumption resourceUri obfuscation block from
    # ResourceInventory.ps1 GetResorceConsumption() (obfuscate branch). The test
    # replicates the logic rather than calling production code, so it stays
    # self-contained (no live Azure, no output zip).
    function Get-ObfuscatedConsumptionUriForTest
    {
        param($RawUri)

        $Prefix = if ($RawUri -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or $RawUri -match '(^|/|-)([dts])-') { 'nonprod_' } else { 'prod_' }

        $ObfuscatedUri = $RawUri

        if (-not $script:ConsumptionSubCache) { $script:ConsumptionSubCache = @{} }
        if (-not $script:ConsumptionRgCache) { $script:ConsumptionRgCache = @{} }
        if (-not $script:ConsumptionNameCache) { $script:ConsumptionNameCache = @{} }

        if ($RawUri -match '^/subscriptions/([^/]+)(/resourcegroups/([^/]+))?(/providers/(.+))?$')
        {
            $RealSub = $matches[1]
            $RealRg = $matches[3]
            $RealProv = $matches[5]

            $ObfSub = if ($script:ConsumptionSubCache.ContainsKey($RealSub)) { $script:ConsumptionSubCache[$RealSub] } else
            {
                $V = $Prefix + 'sub_' + [guid]::NewGuid().ToString()
                $script:ConsumptionSubCache[$RealSub] = $V; $V
            }

            $RebuiltUri = '/subscriptions/' + $ObfSub

            if (-not [string]::IsNullOrEmpty($RealRg))
            {
                $ObfRg = if ($script:ConsumptionRgCache.ContainsKey($RealRg)) { $script:ConsumptionRgCache[$RealRg] } else
                {
                    $IsMc = $RealRg -match '^mc_'
                    $Tag = if ($IsMc) { 'mc_' } else { '' }
                    $V = $Prefix + 'rg_' + $Tag + [guid]::NewGuid().ToString()
                    $script:ConsumptionRgCache[$RealRg] = $V; $V
                }
                $RebuiltUri += '/resourcegroups/' + $ObfRg
            }

            if (-not [string]::IsNullOrEmpty($RealProv))
            {
                $ProvParts = $RealProv -split '/'
                $Rebuilt = @()
                for ($Pi = 0; $Pi -lt $ProvParts.Count; $Pi++)
                {
                    $Part = $ProvParts[$Pi]
                    $IsNameSegment = ($Pi -ge 2 -and ($Pi % 2 -eq 0))
                    if ($IsNameSegment -and -not [string]::IsNullOrEmpty($Part) -and $Part -ne '$system')
                    {
                        $ObfName = if ($script:ConsumptionNameCache.ContainsKey($Part)) { $script:ConsumptionNameCache[$Part] } else
                        {
                            $V = $Prefix + [guid]::NewGuid().ToString()
                            $script:ConsumptionNameCache[$Part] = $V; $V
                        }
                        $Rebuilt += $ObfName
                    }
                    else
                    {
                        $Rebuilt += $Part
                    }
                }
                $RebuiltUri += '/providers/' + ($Rebuilt -join '/')
            }

            $ObfuscatedUri = $RebuiltUri
        }
        else
        {
            # THE GUARD UNDER TEST: a null/empty resourceUri must not reach
            # ContainsKey($null) (which throws). Return the 'obfuscated' fallback.
            if ([string]::IsNullOrEmpty($RawUri))
            {
                $ObfuscatedUri = 'obfuscated'
            }
            else
            {
                if (-not $script:ConsumptionNameCache.ContainsKey($RawUri))
                {
                    $script:ConsumptionNameCache[$RawUri] = $Prefix + [guid]::NewGuid().ToString()
                }
                $ObfuscatedUri = $script:ConsumptionNameCache[$RawUri]
            }
        }

        return $ObfuscatedUri
    }
}

Describe "Consumption obfuscation null/empty resourceUri handling" {

    BeforeEach {
        # Reset the per-run caches so determinism assertions are independent.
        $script:ConsumptionSubCache = @{}
        $script:ConsumptionRgCache = @{}
        $script:ConsumptionNameCache = @{}
    }

    Context "null and empty URIs (the regression)" {

        It "does NOT throw on a null resourceUri" {
            { Get-ObfuscatedConsumptionUriForTest -RawUri $null } | Should -Not -Throw
        }

        It "does NOT throw on an empty-string resourceUri" {
            { Get-ObfuscatedConsumptionUriForTest -RawUri '' } | Should -Not -Throw
        }

        It "returns the 'obfuscated' fallback token for a null resourceUri" {
            Get-ObfuscatedConsumptionUriForTest -RawUri $null | Should -BeExactly 'obfuscated'
        }

        It "returns the 'obfuscated' fallback token for an empty resourceUri" {
            Get-ObfuscatedConsumptionUriForTest -RawUri '' | Should -BeExactly 'obfuscated'
        }

        It "processes a full record set containing a null URI without aborting (mirrors the per-sub loop)" {
            $Uris = @(
                '/subscriptions/aaaa/resourcegroups/rg1/providers/microsoft.compute/virtualmachines/vm1',
                $null,
                '/subscriptions/aaaa/resourcegroups/rg2/providers/microsoft.storage/storageaccounts/sa1'
            )
            $Processed = 0
            $Threw = $false
            try
            {
                foreach ($u in $Uris)
                {
                    $null = Get-ObfuscatedConsumptionUriForTest -RawUri $u
                    $Processed++
                }
            }
            catch { $Threw = $true }

            $Threw    | Should -BeFalse
            $Processed | Should -Be 3
        }
    }

    Context "normal ARM URIs still obfuscate correctly" {

        It "never emits the real subscription / resource-group / resource name" {
            $Real = '/subscriptions/12345678-1234-1234-1234-123456789012/resourcegroups/myrealrg/providers/microsoft.compute/virtualmachines/myrealvm'
            $Obf = Get-ObfuscatedConsumptionUriForTest -RawUri $Real
            $Obf | Should -Not -Match '12345678-1234-1234-1234-123456789012'
            $Obf | Should -Not -Match 'myrealrg'
            $Obf | Should -Not -Match 'myrealvm'
        }

        It "preserves ARM path STRUCTURE and the resource provider/type for categorisation" {
            $Real = '/subscriptions/aaaa/resourcegroups/rg1/providers/microsoft.compute/virtualmachines/vm1'
            $Obf = Get-ObfuscatedConsumptionUriForTest -RawUri $Real
            $Obf | Should -Match '^/subscriptions/'
            $Obf | Should -Match '/resourcegroups/'
            $Obf | Should -Match '/providers/microsoft.compute/virtualmachines/'
        }

        It "is deterministic within a run (same real value -> same obfuscated value)" {
            $Real = '/subscriptions/aaaa/resourcegroups/rg1/providers/microsoft.compute/virtualmachines/vm1'
            $First = Get-ObfuscatedConsumptionUriForTest -RawUri $Real
            $Second = Get-ObfuscatedConsumptionUriForTest -RawUri $Real
            $Second | Should -BeExactly $First
        }

        It "preserves the AKS-managed-RG marker (mc_) so AKS rows stay categorisable" {
            $Real = '/subscriptions/aaaa/resourcegroups/mc_aksrg_cluster_eastus/providers/microsoft.compute/virtualmachinescalesets/aks-nodepool'
            $Obf = Get-ObfuscatedConsumptionUriForTest -RawUri $Real
            $Obf | Should -Match '/resourcegroups/(prod|nonprod)_rg_mc_'
        }
    }
}
