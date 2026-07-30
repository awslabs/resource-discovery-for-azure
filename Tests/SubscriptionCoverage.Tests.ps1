# Subscription-coverage helper tests
#
# Unit-tests the two coverage-gate helpers in
# Functions/RunAllSubscriptions.Functions.ps1 in isolation, offline (no live
# Azure, no tenant):
#
#   - Get-RdaMgSubscriptionId: PURE recursive collector. Walks a management-group
#     tree shaped like Get-AzManagementGroup -Expand -Recurse output (nodes with
#     a .Type and .Children; subscription children carry Type '/subscriptions' and
#     their .Name is the subscription GUID; nested management groups carry a
#     'managementGroups' Type and their own .Children). Returns the flat list of
#     subscription ids under the tree. Exercised here against synthetic trees, so
#     it needs no Azure at all - this is the whole point of the pure/side-effecting
#     split.
#   - Get-TenantSubscriptionId: SIDE-EFFECTING fetch. Calls Get-AzManagementGroup
#     and feeds the tree to the pure collector, returning { Ids; Detail } with
#     Ids = distinct id string[] or $null when unverifiable. Exercised via a
#     mocked Get-AzManagementGroup so the success / empty / throw paths are
#     covered without a live tenant.
#
# Run with: Invoke-Pester ./Tests/SubscriptionCoverage.Tests.ps1 -Output Detailed
#
# The functions live in Functions/RunAllSubscriptions.Functions.ps1, a
# definitions-only file with NO top-level side effects, so we dot-source it
# wholesale - the same file both Run-AllSubscriptions.ps1 and its stream worker
# dot-source at runtime, so this test exercises the exact shipping code.

BeforeAll {
    $script:FunctionsPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/RunAllSubscriptions.Functions.ps1'
    if (-not (Test-Path $script:FunctionsPath))
    {
        throw "Could not find shared functions file at $script:FunctionsPath"
    }
    . $script:FunctionsPath

    # Guard: the functions under test must be defined by the shared file. Fail
    # loudly here if a future change renames or removes one, rather than with a
    # confusing "command not found" mid-test.
    foreach ($Fn in @('Get-RdaMgSubscriptionId', 'Get-TenantSubscriptionId'))
    {
        if (-not (Get-Command $Fn -CommandType Function -ErrorAction SilentlyContinue))
        {
            throw "Expected function '$Fn' to be defined by $script:FunctionsPath, but it was not. Has it been renamed or removed?"
        }
    }

    # A subscription child in the Get-AzManagementGroup -Expand -Recurse tree: its
    # Type is '/subscriptions' and its .Name is the subscription GUID.
    function New-MgSub
    {
        param([string]$Id)
        [pscustomobject]@{ Type = '/subscriptions'; Name = $Id; Children = $null }
    }

    # A (nested) management-group node: Type carries 'managementGroups' and it has
    # its own .Children (subscriptions and/or further nested MGs).
    function New-MgNode
    {
        param([string]$Name = 'mg', [object[]]$Children = @())
        [pscustomobject]@{ Type = 'Microsoft.Management/managementGroups'; Name = $Name; Children = $Children }
    }

    # Stub Get-AzManagementGroup so the side-effecting fetch is mockable even on a
    # host without Az.Resources installed (CI). Only define it if it is not already
    # present so we never shadow a real cmdlet when Az IS installed - the tests
    # Mock it either way.
    if (-not (Get-Command Get-AzManagementGroup -ErrorAction SilentlyContinue))
    {
        function Get-AzManagementGroup
        {
            param([string]$GroupName, [switch]$Expand, [switch]$Recurse)
            throw 'stub - should be mocked'
        }
    }
}

Describe 'Get-RdaMgSubscriptionId (pure recursive collector)' {

    It 'returns an empty array for a null node' {
        @(Get-RdaMgSubscriptionId -Node $null).Count | Should -Be 0
    }

    It 'returns an empty array when the node has no children' {
        $Node = [pscustomobject]@{ Type = 'Microsoft.Management/managementGroups'; Name = 'root'; Children = $null }
        @(Get-RdaMgSubscriptionId -Node $Node).Count | Should -Be 0
    }

    It 'collects direct subscription children at the root' {
        $Root = New-MgNode -Name 'root' -Children @(
            (New-MgSub -Id 'sub-root-a'),
            (New-MgSub -Id 'sub-root-b')
        )
        $Ids = @(Get-RdaMgSubscriptionId -Node $Root)
        $Ids.Count | Should -Be 2
        $Ids | Should -Contain 'sub-root-a'
        $Ids | Should -Contain 'sub-root-b'
    }

    It 'recurses into nested management groups and collects subs at every level' {
        $Root = New-MgNode -Name 'root' -Children @(
            (New-MgSub -Id 'sub-root-1'),
            (New-MgNode -Name 'child' -Children @(
                    (New-MgSub -Id 'sub-child-1'),
                    (New-MgNode -Name 'grandchild' -Children @(
                            (New-MgSub -Id 'sub-grandchild-1')
                        ))
                ))
        )
        $Ids = @(Get-RdaMgSubscriptionId -Node $Root)
        $Ids.Count | Should -Be 3
        $Ids | Should -Contain 'sub-root-1'
        $Ids | Should -Contain 'sub-child-1'
        $Ids | Should -Contain 'sub-grandchild-1'
    }

    It 'does NOT count management-group nodes themselves as subscriptions' {
        # A root with only nested MGs (no subscription leaves) yields zero ids -
        # proving the 'managementGroups' Type is never mistaken for a subscription.
        $Root = New-MgNode -Name 'root' -Children @(
            (New-MgNode -Name 'empty-child-1' -Children @()),
            (New-MgNode -Name 'empty-child-2' -Children @())
        )
        @(Get-RdaMgSubscriptionId -Node $Root).Count | Should -Be 0
    }

    It 'skips subscription children whose id is blank or whitespace' {
        $Root = New-MgNode -Name 'root' -Children @(
            (New-MgSub -Id 'good-sub'),
            (New-MgSub -Id '   '),
            (New-MgSub -Id '')
        )
        $Ids = @(Get-RdaMgSubscriptionId -Node $Root)
        $Ids.Count | Should -Be 1
        $Ids[0] | Should -Be 'good-sub'
    }
}

Describe 'Get-TenantSubscriptionId (side-effecting fetch)' {

    It 'returns the distinct id set when the MG tree is readable' {
        Mock Get-AzManagementGroup {
            [pscustomobject]@{ Type = 'Microsoft.Management/managementGroups'; Name = 'root'; Children = @(
                    [pscustomobject]@{ Type = '/subscriptions'; Name = 'sub-1'; Children = $null },
                    [pscustomobject]@{ Type = '/subscriptions'; Name = 'sub-2'; Children = $null }
                ) }
        }
        $Result = Get-TenantSubscriptionId -TenantId '12345678-1234-1234-1234-123456789012'
        $Result.Detail | Should -BeNullOrEmpty
        @($Result.Ids).Count | Should -Be 2
        $Result.Ids | Should -Contain 'sub-1'
        $Result.Ids | Should -Contain 'sub-2'
    }

    It 'de-duplicates repeated subscription ids' {
        Mock Get-AzManagementGroup {
            [pscustomobject]@{ Type = 'Microsoft.Management/managementGroups'; Name = 'root'; Children = @(
                    [pscustomobject]@{ Type = '/subscriptions'; Name = 'dupe'; Children = $null },
                    [pscustomobject]@{ Type = '/subscriptions'; Name = 'dupe'; Children = $null }
                ) }
        }
        $Result = Get-TenantSubscriptionId -TenantId '12345678-1234-1234-1234-123456789012'
        @($Result.Ids).Count | Should -Be 1
    }

    It 'returns Ids=$null with a Detail when the MG tree is empty (unverifiable)' {
        Mock Get-AzManagementGroup {
            [pscustomobject]@{ Type = 'Microsoft.Management/managementGroups'; Name = 'root'; Children = @() }
        }
        $Result = Get-TenantSubscriptionId -TenantId '12345678-1234-1234-1234-123456789012'
        $Result.Ids | Should -BeNullOrEmpty
        $Result.Detail | Should -Not -BeNullOrEmpty
    }

    It 'returns Ids=$null and surfaces the exception message when the read is denied' {
        Mock Get-AzManagementGroup { throw 'AuthorizationFailed: does not have authorization to perform action Microsoft.Management/managementGroups/read' }
        $Result = Get-TenantSubscriptionId -TenantId '12345678-1234-1234-1234-123456789012'
        $Result.Ids | Should -BeNullOrEmpty
        $Result.Detail | Should -Match 'AuthorizationFailed'
    }
}
