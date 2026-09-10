<#
    Regression guard for the -ResourceGroup consumption filter's null-resourceUri
    handling.

    MIRRORED FROM: ResourceInventory.ps1 > ExecuteInventoryProcessing() >
                   GetResourceConsumption(), the -ResourceGroup filter block
                   (search for: $ResourceUriValue = $InstanceInfo).

    COVERAGE LIMITATION - stated plainly rather than implied away.
    The behavioural tests below exercise a COPY of the filter expression, not
    production code. GetResourceConsumption() is a nested function inside
    ExecuteInventoryProcessing() in ResourceInventory.ps1, so it cannot be
    dot-sourced or invoked without executing the entire script including
    authentication and the full inventory. There is no seam to call it through,
    and creating one would be a restructure this fix is not permitted to make.

    The consequence is real: this copy can pass while production drifts away
    from it. Tests/ConsumptionObfuscation.Tests.ps1 is the precedent and the
    warning - it is self-described as a "faithful copy" of the obfuscation block
    and has already drifted from it. Do NOT depend on that file or reuse its
    helper here.

    Two mitigations, both required and both present below:
      1. This header, naming the exact mirrored file/function/anchor. If the
         production filter changes, mirror it here.
      2. A source-guard test that reads ResourceInventory.ps1 as text and
         asserts the null guard STILL precedes the .toLower().Contains()
         comparison. That catches silent removal of the guard, which is the
         failure mode a copy-based test is otherwise blind to. It verifies
         presence, not behaviour.

    The end-to-end run against a real subscription, not this file, is what proves
    the production path. This file guards against reintroduction.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:InventoryScript = Join-Path $script:RepoRoot 'ResourceInventory.ps1'

    function Invoke-RgFilterDecision
    {
        param($InstanceInfo, [string]$ResourceGroup, [ref]$NullUriSkipCount)

        if (![string]::IsNullOrEmpty($ResourceGroup))
        {
            $ResourceUriValue = $InstanceInfo.'Microsoft.Resources'.resourceUri
            if ([string]::IsNullOrEmpty($ResourceUriValue))
            {
                $NullUriSkipCount.Value++
                return 'SkippedNullUri'
            }

            if (!$ResourceUriValue.toLower().Contains("/" + $ResourceGroup.toLower() + "/"))
            {
                return 'Skipped'
            }
        }
        else
        {
            return 'NoFilter'
        }

        return 'Included'
    }

    function New-UsageRecord
    {
        param([string]$ResourceUri, [switch]$OmitUri)

        if ($OmitUri)
        {
            return ([pscustomobject]@{ 'Microsoft.Resources' = [pscustomobject]@{ location = 'westeurope' } })
        }
        return ([pscustomobject]@{ 'Microsoft.Resources' = [pscustomobject]@{ location = 'westeurope'; resourceUri = $ResourceUri } })
    }
}

Describe 'Consumption -ResourceGroup filter: null resourceUri' {

    Context 'Bug condition - a meter with no resourceUri' {

        It 'does not throw when resourceUri is absent from the payload' {
            $SkipCount = 0
            { Invoke-RgFilterDecision -InstanceInfo (New-UsageRecord -OmitUri) -ResourceGroup 'rg-app' -NullUriSkipCount ([ref]$SkipCount) } | Should -Not -Throw
        }

        It 'skips the record when resourceUri is absent' {
            $SkipCount = 0
            Invoke-RgFilterDecision -InstanceInfo (New-UsageRecord -OmitUri) -ResourceGroup 'rg-app' -NullUriSkipCount ([ref]$SkipCount) | Should -Be 'SkippedNullUri'
        }

        It 'skips the record when resourceUri is an empty string' {
            $SkipCount = 0
            Invoke-RgFilterDecision -InstanceInfo (New-UsageRecord -ResourceUri '') -ResourceGroup 'rg-app' -NullUriSkipCount ([ref]$SkipCount) | Should -Be 'SkippedNullUri'
        }

        It 'counts the skip so it can be reported once per subscription' {
            $SkipCount = 0
            $null = Invoke-RgFilterDecision -InstanceInfo (New-UsageRecord -OmitUri) -ResourceGroup 'rg-app' -NullUriSkipCount ([ref]$SkipCount)
            $SkipCount | Should -Be 1
        }

        It 'continues past the bad record and still processes the rest of the page' {
            $SkipCount = 0
            $Records = @(
                (New-UsageRecord -ResourceUri '/subscriptions/s1/resourcegroups/rg-app/providers/microsoft.compute/virtualmachines/vm1'),
                (New-UsageRecord -OmitUri),
                (New-UsageRecord -ResourceUri '/subscriptions/s1/resourcegroups/rg-app/providers/microsoft.compute/virtualmachines/vm2')
            )
            $Decisions = foreach ($r in $Records) { Invoke-RgFilterDecision -InstanceInfo $r -ResourceGroup 'rg-app' -NullUriSkipCount ([ref]$SkipCount) }
            @($Decisions | Where-Object { $_ -eq 'Included' }).Count | Should -Be 2
            $SkipCount | Should -Be 1
        }
    }

    Context 'Preservation - every non-bug-condition input is unchanged' {

        It 'includes a record whose resourceUri contains the requested resource group' {
            $SkipCount = 0
            Invoke-RgFilterDecision -InstanceInfo (New-UsageRecord -ResourceUri '/subscriptions/s1/resourcegroups/rg-app/providers/microsoft.compute/virtualmachines/vm1') -ResourceGroup 'rg-app' -NullUriSkipCount ([ref]$SkipCount) | Should -Be 'Included'
            $SkipCount | Should -Be 0
        }

        It 'excludes a record whose resourceUri does not contain the requested resource group' {
            $SkipCount = 0
            Invoke-RgFilterDecision -InstanceInfo (New-UsageRecord -ResourceUri '/subscriptions/s1/resourcegroups/rg-other/providers/microsoft.compute/virtualmachines/vm1') -ResourceGroup 'rg-app' -NullUriSkipCount ([ref]$SkipCount) | Should -Be 'Skipped'
            $SkipCount | Should -Be 0
        }

        It 'matches case-insensitively, because both sides are lowercased' {
            $SkipCount = 0
            Invoke-RgFilterDecision -InstanceInfo (New-UsageRecord -ResourceUri '/subscriptions/s1/resourceGroups/RG-App/providers/microsoft.compute/virtualmachines/vm1') -ResourceGroup 'rg-APP' -NullUriSkipCount ([ref]$SkipCount) | Should -Be 'Included'
        }

        It 'never enters the filter when -ResourceGroup was not supplied' {
            $SkipCount = 0
            Invoke-RgFilterDecision -InstanceInfo (New-UsageRecord -OmitUri) -ResourceGroup '' -NullUriSkipCount ([ref]$SkipCount) | Should -Be 'NoFilter'
            $SkipCount | Should -Be 0
        }

        It 'leaves a null-resourceUri record alone when no resource group is requested' {
            $SkipCount = 0
            $null = Invoke-RgFilterDecision -InstanceInfo (New-UsageRecord -OmitUri) -ResourceGroup $null -NullUriSkipCount ([ref]$SkipCount)
            $SkipCount | Should -Be 0
        }
    }

    Context 'Source guard - the production guard is still in place' {

        It 'ResourceInventory.ps1 exists at the expected path' {
            Test-Path -LiteralPath $script:InventoryScript | Should -BeTrue
        }

        It 'still hoists resourceUri and null-checks it BEFORE the Contains() comparison' {
            $Text = Get-Content -LiteralPath $script:InventoryScript -Raw

            $HoistIdx = $Text.IndexOf('$ResourceUriValue = $InstanceInfo.''Microsoft.Resources''.resourceUri')
            $GuardIdx = $Text.IndexOf('[string]::IsNullOrEmpty($ResourceUriValue)')
            $CmpIdx = $Text.IndexOf('$ResourceUriValue.toLower().Contains(')

            $HoistIdx | Should -BeGreaterThan -1 -Because 'the resourceUri hoist must still exist'
            $GuardIdx | Should -BeGreaterThan -1 -Because 'the null/empty guard must still exist'
            $CmpIdx | Should -BeGreaterThan -1 -Because 'the comparison must read the hoisted value'

            $HoistIdx | Should -BeLessThan $GuardIdx -Because 'the value is hoisted before it is guarded'
            $GuardIdx | Should -BeLessThan $CmpIdx -Because 'the guard MUST precede the .toLower() call, or a null resourceUri throws again and abandons the subscription'
        }

        It 'no longer dereferences resourceUri directly in the resource-group comparison' {
            $Text = Get-Content -LiteralPath $script:InventoryScript -Raw
            $Text | Should -Not -BeLike ('*' + '$InstanceInfo.''Microsoft.Resources''.resourceUri.toLower().Contains(' + '*') -Because 'that unguarded form is the original defect'
        }

        It 'increments a per-subscription counter rather than adding a new global' {
            $Text = Get-Content -LiteralPath $script:InventoryScript -Raw
            $Text | Should -BeLike ('*' + '$ConsumptionNullUriSkipsThisSub++' + '*')
            $Text | Should -Not -BeLike ('*' + '$Global:ConsumptionNullUriSkips' + '*') -Because 'no new global may be introduced'
        }
    }
}
