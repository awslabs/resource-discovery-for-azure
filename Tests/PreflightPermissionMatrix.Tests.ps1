#Requires -Version 7.0
# Offline unit tests for the -Preflight permission matrix: Test-MetricsAccess (mocked Az) across all
# outcome branches, and Format-PreflightMatrix's verdict - a Denied probe or an unverifiable Reader blocks;
# Skipped, NoResource and Unavailable results for the Cost Management and Monitoring phases do not.
# The last Describe runs the wrapper's probe loop, lifted from its source, against stub probes.

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

Describe 'The -Preflight probe loop in Run-AllSubscriptions.ps1' {
    # The loop is inline in the wrapper, so it is lifted from the parsed source and run against stub probes.
    BeforeAll {
        $ParseErrors = $null
        $WrapperAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1'), [ref]$null, [ref]$ParseErrors)
        if (@($ParseErrors).Count -gt 0) { throw ('Run-AllSubscriptions.ps1 does not parse: {0}' -f $ParseErrors[0].Message) }
        $Loop = @($WrapperAst.FindAll({ param($Node) $Node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $Node.Left.Extent.Text -eq '$MatrixRows' -and $Node.Right.Extent.Text -like 'foreach ($PfSub in $Subscriptions)*' }, $true))
        if ($Loop.Count -ne 1) { throw ('expected one preflight probe loop, found {0}' -f $Loop.Count) }
        $script:PreflightLoop = [scriptblock]::Create((@(
                    'param($Subscriptions, $CostResult, $Printed)'
                    'function Write-Host { param($Object, $ForegroundColor) $Printed.Add([pscustomobject]@{ Text = [string]$Object; Color = [string]$ForegroundColor }) }'
                    'function Test-ConsumptionAccess { param([string]$SubscriptionId) $CostResult }'
                    'function Test-MetricsAccess { param([string]$SubscriptionId) [pscustomobject]@{ Outcome = ''Ok''; Detail = $null } }'
                    '$SkipConsumption = $false'
                    '$SkipMetrics = $false'
                    '$MatrixRows = @()'
                    $Loop[0].Extent.Text
                    '$MatrixRows'
                ) -join [Environment]::NewLine))
        $script:PfSubs = @([pscustomobject]@{ Name = 'Sub One'; Id = 'sub-1' })
    }

    It 'shows an Unavailable consumption probe''s detail at Warning, the second half of the profile helper''s line' {
        # With no debug log open, the profile helper prints the first lookup's error on the console and the
        # detail says "its error is shown above"; at Verbose only, that line would print with no second half.
        $Printed = [System.Collections.Generic.List[object]]::new()
        $Cost = [pscustomobject]@{ Outcome = 'Unavailable'; Detail = 'could not scope the Az calls to the probe subscription: SubscriptionNotFound (the lookup in the signed-in tenant had also failed; its error is shown above)' }
        $VerbosePreference = 'Continue'
        $Output = @(& $script:PreflightLoop $script:PfSubs $Cost $Printed 4>&1)
        $Rows = @($Output | Where-Object { $_ -isnot [System.Management.Automation.VerboseRecord] })
        $Verbose = @($Output | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] })
        $Rows[0].CostManagement | Should -Be 'Unavailable'
        $Shown = @($Printed | Where-Object { $_.Text -like '  WARNING: `[preflight`] consumption Sub One: could not scope*its error is shown above*' })
        $Shown.Count | Should -Be 1
        $Shown[0].Color | Should -Be 'Yellow'
        @($Verbose | Where-Object { $_.Message -like '*`[preflight`]*' }).Count | Should -Be 0 -Because 'the detail is shown at Warning instead of Verbose, not as well'
    }

    It 'keeps the detail of any other outcome at Verbose' {
        $Printed = [System.Collections.Generic.List[object]]::new()
        $Cost = [pscustomobject]@{ Outcome = 'Denied'; Detail = 'AuthorizationFailed: the client does not have authorization' }
        $VerbosePreference = 'Continue'
        $Verbose = @(& $script:PreflightLoop $script:PfSubs $Cost $Printed 4>&1 | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] })
        @($Printed | Where-Object { $_.Text -like '*`[preflight`]*' }).Count | Should -Be 0 -Because 'a denial already reads Denied in the matrix'
        @($Verbose | Where-Object { $_.Message -like '`[preflight`] consumption Sub One: AuthorizationFailed*' }).Count | Should -Be 1
    }
}
