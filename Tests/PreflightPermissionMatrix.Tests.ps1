#Requires -Version 7.0
# =============================================================================
# PreflightPermissionMatrix.Tests.ps1
#
# OFFLINE unit tests for the -Preflight permission matrix added to the wrapper:
#   - Test-MetricsAccess (Functions/RunAllSubscriptions.Functions.ps1): the
#     Monitoring Reader probe. Search-AzGraph and Get-AzMetricDefinition are
#     Pester Mocks (stubbed first when the Az modules are absent, the same idiom
#     as Tests/CollectorGuards.Tests.ps1), so every outcome branch - Ok, Denied,
#     Unavailable, NoResource - is exercised deterministically with no session.
#   - Format-PreflightMatrix: the pure renderer. Layout, the Skipped state, and
#     the Blocking verdict (any Denied on a REQUESTED phase blocks; Unavailable
#     and NoResource never do) are asserted on its returned lines.
# No Azure calls, no zip fixture, no environment coupling.
# =============================================================================

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1')
    . (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')

    # Stubs so Mock can resolve the commands on a host without Az.ResourceGraph /
    # Az.Monitor. Defined only when absent, never shadowing a real cmdlet.
    if (-not (Get-Command Search-AzGraph -ErrorAction SilentlyContinue))
    {
        function Search-AzGraph { [CmdletBinding()] param([string]$Query, [string[]]$Subscription, [int]$First) throw 'stub - should be mocked' }
    }
    if (-not (Get-Command Get-AzMetricDefinition -ErrorAction SilentlyContinue))
    {
        function Get-AzMetricDefinition { [CmdletBinding()] param([string]$ResourceId) throw 'stub - should be mocked' }
    }
    $script:ProbeId = '/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg1/providers/Microsoft.Compute/virtualMachines/vm1'
}

Describe 'Test-MetricsAccess outcome classification' {
    It 'returns Ok when a metric-eligible resource exists and its definitions are readable' {
        Mock Search-AzGraph { [pscustomobject]@{ id = $script:ProbeId } }
        Mock Get-AzMetricDefinition { [pscustomobject]@{ Name = 'Percentage CPU' } }
        $R = Test-MetricsAccess -SubscriptionId '12345678-1234-1234-1234-123456789012'
        $R.Outcome | Should -Be 'Ok'
        $R.Detail | Should -BeNullOrEmpty
        Should -Invoke Get-AzMetricDefinition -Times 1
    }

    It 'returns Denied on an RBAC denial (AuthorizationFailed) and names the probed resource' {
        Mock Search-AzGraph { [pscustomobject]@{ id = $script:ProbeId } }
        Mock Get-AzMetricDefinition { throw "The client 'x' with object id 'y' does not have authorization to perform action 'Microsoft.Insights/metricDefinitions/read' over scope '/subscriptions/...'. AuthorizationFailed" }
        $R = Test-MetricsAccess -SubscriptionId '12345678-1234-1234-1234-123456789012'
        $R.Outcome | Should -Be 'Denied'
        $R.Detail | Should -Match ([regex]::Escape($script:ProbeId))
    }

    It 'returns Unavailable on a non-authorization failure (throttle / token)' {
        Mock Search-AzGraph { [pscustomobject]@{ id = $script:ProbeId } }
        Mock Get-AzMetricDefinition { throw 'Too many requests (429). Retry after 30 seconds.' }
        (Test-MetricsAccess -SubscriptionId '12345678-1234-1234-1234-123456789012').Outcome | Should -Be 'Unavailable'
    }

    It 'returns NoResource when the subscription holds nothing metric-eligible, without calling the Monitor API' {
        Mock Search-AzGraph { @() }
        Mock Get-AzMetricDefinition { throw 'must not be called' }
        $R = Test-MetricsAccess -SubscriptionId '12345678-1234-1234-1234-123456789012'
        $R.Outcome | Should -Be 'NoResource'
        Should -Invoke Get-AzMetricDefinition -Times 0
    }

    It 'returns Unavailable when the Resource Graph lookup itself fails' {
        Mock Search-AzGraph { throw 'token expired' }
        $R = Test-MetricsAccess -SubscriptionId '12345678-1234-1234-1234-123456789012'
        $R.Outcome | Should -Be 'Unavailable'
        $R.Detail | Should -Match 'could not locate'
    }
}

Describe 'Format-PreflightMatrix' {
    BeforeAll {
        $script:Row = { param($Name, $Reader, $Cost, $Mon) [pscustomobject]@{ Name = $Name; Id = "id-$Name"; Reader = $Reader; CostManagement = $Cost; Monitoring = $Mon } }
    }

    It 'renders one line per subscription under a header and is not blocking when nothing is denied' {
        $M = Format-PreflightMatrix -Rows @((& $script:Row 'sub-a' 'Ok' 'Ok' 'Ok'), (& $script:Row 'sub-b' 'Ok' 'Unavailable' 'NoResource'))
        $M.Blocking | Should -BeFalse
        @($M.Lines | Where-Object { $_ -match '^\s+sub-[ab]\s' }).Count | Should -Be 2
        ($M.Lines -join "`n") | Should -Match 'Subscription\s+Reader\s+Cost Mgmt\s+Monitoring'
        ($M.Lines -join "`n") | Should -Not -Match 'To fix before running'
    }

    It 'a Denied on a requested phase is blocking and produces the matching role hint' {
        $M = Format-PreflightMatrix -Rows @((& $script:Row 'sub-a' 'Ok' 'Denied' 'Ok'))
        $M.Blocking | Should -BeTrue
        ($M.Lines -join "`n") | Should -Match 'Cost Management Reader on sub-a'
        ($M.Lines -join "`n") | Should -Not -Match 'Monitoring Reader on sub-a'
    }

    It 'a Denied Monitoring probe hints Monitoring Reader or -SkipMetrics' {
        $M = Format-PreflightMatrix -Rows @((& $script:Row 'sub-a' 'Ok' 'Ok' 'Denied'))
        $M.Blocking | Should -BeTrue
        ($M.Lines -join "`n") | Should -Match 'Monitoring Reader on sub-a.*-SkipMetrics'
    }

    It 'an unverifiable Reader (Unavailable) is blocking, because the real run stops on it' {
        $M = Format-PreflightMatrix -Rows @((& $script:Row 'sub-a' 'Unavailable' 'Skipped' 'Skipped'))
        $M.Blocking | Should -BeTrue
        ($M.Lines -join "`n") | Should -Match 'Reader on sub-a .* could not be verified'
    }

    It 'a Reader-denied subscription with Skipped data columns is blocking and hints Reader' {
        $M = Format-PreflightMatrix -Rows @((& $script:Row 'sub-a' 'Denied' 'Skipped' 'Skipped'))
        $M.Blocking | Should -BeTrue
        ($M.Lines -join "`n") | Should -Match 'Grant Reader on sub-a'
    }

    It 'Skipped phases render as Skipped and never block' {
        $M = Format-PreflightMatrix -Rows @((& $script:Row 'sub-a' 'Ok' 'Skipped' 'Skipped'))
        $M.Blocking | Should -BeFalse
        ($M.Lines | Where-Object { $_ -match '^\s+sub-a\s' }) | Should -Match 'Skipped\s+Skipped'
    }

    It 'truncates a long subscription name so the columns stay aligned' {
        $Long = 'x' * 60
        $M = Format-PreflightMatrix -Rows @((& $script:Row $Long 'Ok' 'Ok' 'Ok'))
        ($M.Lines | Where-Object { $_ -match '^\s+x{37}\.\.\.\s' }).Count | Should -Be 1
    }
}
