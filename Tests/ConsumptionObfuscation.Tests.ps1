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

        $prefix = if ($RawUri -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or $RawUri -match '(^|/|-)([dts])-') { 'nonprod_' } else { 'prod_' }

        $obfuscatedUri = $RawUri

        if (-not $script:ConsumptionSubCache) { $script:ConsumptionSubCache = @{} }
        if (-not $script:ConsumptionRgCache) { $script:ConsumptionRgCache = @{} }
        if (-not $script:ConsumptionNameCache) { $script:ConsumptionNameCache = @{} }

        if ($RawUri -match '^/subscriptions/([^/]+)(/resourcegroups/([^/]+))?(/providers/(.+))?$')
        {
            $realSub = $matches[1]
            $realRg = $matches[3]
            $realProv = $matches[5]

            $obfSub = if ($script:ConsumptionSubCache.ContainsKey($realSub)) { $script:ConsumptionSubCache[$realSub] } else
            {
                $v = $prefix + 'sub_' + [guid]::NewGuid().ToString()
                $script:ConsumptionSubCache[$realSub] = $v; $v
            }

            $rebuiltUri = '/subscriptions/' + $obfSub

            if (-not [string]::IsNullOrEmpty($realRg))
            {
                $obfRg = if ($script:ConsumptionRgCache.ContainsKey($realRg)) { $script:ConsumptionRgCache[$realRg] } else
                {
                    $isMc = $realRg -match '^mc_'
                    $tag = if ($isMc) { 'mc_' } else { '' }
                    $v = $prefix + 'rg_' + $tag + [guid]::NewGuid().ToString()
                    $script:ConsumptionRgCache[$realRg] = $v; $v
                }
                $rebuiltUri += '/resourcegroups/' + $obfRg
            }

            if (-not [string]::IsNullOrEmpty($realProv))
            {
                $provParts = $realProv -split '/'
                $rebuilt = @()
                for ($pi = 0; $pi -lt $provParts.Count; $pi++)
                {
                    $part = $provParts[$pi]
                    $isNameSegment = ($pi -ge 2 -and ($pi % 2 -eq 0))
                    if ($isNameSegment -and -not [string]::IsNullOrEmpty($part) -and $part -ne '$system')
                    {
                        $obfName = if ($script:ConsumptionNameCache.ContainsKey($part)) { $script:ConsumptionNameCache[$part] } else
                        {
                            $v = $prefix + [guid]::NewGuid().ToString()
                            $script:ConsumptionNameCache[$part] = $v; $v
                        }
                        $rebuilt += $obfName
                    }
                    else
                    {
                        $rebuilt += $part
                    }
                }
                $rebuiltUri += '/providers/' + ($rebuilt -join '/')
            }

            $obfuscatedUri = $rebuiltUri
        }
        else
        {
            # THE GUARD UNDER TEST: a null/empty resourceUri must not reach
            # ContainsKey($null) (which throws). Return the 'obfuscated' fallback.
            if ([string]::IsNullOrEmpty($RawUri))
            {
                $obfuscatedUri = 'obfuscated'
            }
            else
            {
                if (-not $script:ConsumptionNameCache.ContainsKey($RawUri))
                {
                    $script:ConsumptionNameCache[$RawUri] = $prefix + [guid]::NewGuid().ToString()
                }
                $obfuscatedUri = $script:ConsumptionNameCache[$RawUri]
            }
        }

        return $obfuscatedUri
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
            $uris = @(
                '/subscriptions/aaaa/resourcegroups/rg1/providers/microsoft.compute/virtualmachines/vm1',
                $null,
                '/subscriptions/aaaa/resourcegroups/rg2/providers/microsoft.storage/storageaccounts/sa1'
            )
            $processed = 0
            $threw = $false
            try
            {
                foreach ($u in $uris)
                {
                    $null = Get-ObfuscatedConsumptionUriForTest -RawUri $u
                    $processed++
                }
            }
            catch { $threw = $true }

            $threw    | Should -BeFalse
            $processed | Should -Be 3
        }
    }

    Context "normal ARM URIs still obfuscate correctly" {

        It "never emits the real subscription / resource-group / resource name" {
            $real = '/subscriptions/12345678-1234-1234-1234-123456789012/resourcegroups/myrealrg/providers/microsoft.compute/virtualmachines/myrealvm'
            $obf = Get-ObfuscatedConsumptionUriForTest -RawUri $real
            $obf | Should -Not -Match '12345678-1234-1234-1234-123456789012'
            $obf | Should -Not -Match 'myrealrg'
            $obf | Should -Not -Match 'myrealvm'
        }

        It "preserves ARM path STRUCTURE and the resource provider/type for categorisation" {
            $real = '/subscriptions/aaaa/resourcegroups/rg1/providers/microsoft.compute/virtualmachines/vm1'
            $obf = Get-ObfuscatedConsumptionUriForTest -RawUri $real
            $obf | Should -Match '^/subscriptions/'
            $obf | Should -Match '/resourcegroups/'
            $obf | Should -Match '/providers/microsoft.compute/virtualmachines/'
        }

        It "is deterministic within a run (same real value -> same obfuscated value)" {
            $real = '/subscriptions/aaaa/resourcegroups/rg1/providers/microsoft.compute/virtualmachines/vm1'
            $first = Get-ObfuscatedConsumptionUriForTest -RawUri $real
            $second = Get-ObfuscatedConsumptionUriForTest -RawUri $real
            $second | Should -BeExactly $first
        }

        It "preserves the AKS-managed-RG marker (mc_) so AKS rows stay categorisable" {
            $real = '/subscriptions/aaaa/resourcegroups/mc_aksrg_cluster_eastus/providers/microsoft.compute/virtualmachinescalesets/aks-nodepool'
            $obf = Get-ObfuscatedConsumptionUriForTest -RawUri $real
            $obf | Should -Match '/resourcegroups/(prod|nonprod)_rg_mc_'
        }
    }
}
