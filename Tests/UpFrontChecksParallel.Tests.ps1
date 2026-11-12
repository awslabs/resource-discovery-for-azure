# =============================================================================
# UpFrontChecksParallel.Tests.ps1
#
# The up-front role check and consumption data check (Functions/Common.Functions.ps1)
# run up to 8 subscriptions at a time with ForEach-Object -Parallel. Pester
# mocks exist only in the test's own runspace, so here Azure is replaced by a
# small stand-in module that every parallel runspace loads from PSModulePath.
# Its answers depend only on the request, never on call order, so a serial
# and a parallel run get the same answers. Offline; no Az modules needed.
# =============================================================================

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1')

    $script:ModuleRoot = Join-Path $TestDrive 'modules'
    $ModuleDir = Join-Path $script:ModuleRoot 'RdaTestAzStandIn'
    $null = New-Item -ItemType Directory -Force -Path $ModuleDir
    @'
# Each call sleeps RDA_TEST_DELAY_MS (RDA_TEST_SLOW_MS for subscription
# RDA_TEST_SLOW_SUB) and writes one JSON line per call to a file in
# RDA_TEST_CALL_DIR. Subscription modes come from RDA_TEST_MODES
# ("sub-x=none;sub-y=nocompute;sub-z=nousage"); any other is Reader.
function Get-TestMode
{
    param([string]$Sub)
    foreach ($Pair in ([string]$env:RDA_TEST_MODES -split ';'))
    {
        $Parts = $Pair -split '='
        if ($Parts.Count -eq 2 -and $Parts[0] -eq $Sub) { return $Parts[1] }
    }
    return 'reader'
}

function Invoke-AzRestMethod
{
    [CmdletBinding()]
    param($Method, $Path, $Payload, $Uri)
    $Target = if ($Path) { [string]$Path } else { [string]$Uri }
    $Sub = if ($Target -match '^/subscriptions/([^/?]+)') { $Matches[1] } else { '' }
    $Mode = Get-TestMode -Sub $Sub
    $Kind = switch -Regex ($Target)
    {
        '/roleAssignments\?' { 'roles'; break }
        '/roleDefinitions/' { 'definition'; break }
        '/Microsoft\.Authorization/permissions\?' { 'permissions'; break }
        '/Microsoft\.Commerce/UsageAggregates\?' { 'usage'; break }
        '^/providers/Microsoft\.ResourceGraph/' { 'counts'; break }
        default { throw "unexpected request $Target" }
    }
    $Start = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $Delay = if ($Sub -and $Sub -eq $env:RDA_TEST_SLOW_SUB) { [int]$env:RDA_TEST_SLOW_MS } else { [int]$env:RDA_TEST_DELAY_MS }
    if ($Delay -gt 0) { Start-Sleep -Milliseconds $Delay }
    $Body = switch ($Kind)
    {
        'roles'
        {
            if ($Mode -eq 'none') { @{ value = @() } }
            else
            {
                $Def = if ($Mode -eq 'nocompute') { 'nocompute' } else { 'reader' }
                @{ value = @(@{ properties = @{ roleDefinitionId = "/subscriptions/$Sub/providers/Microsoft.Authorization/roleDefinitions/$Def"; scope = "/subscriptions/$Sub"; principalId = 'test-oid'; principalType = 'User' } }) }
            }
        }
        'definition'
        {
            if ($Target -match '/nocompute\?') { @{ properties = @{ roleName = 'Reader without Compute'; type = 'CustomRole'; permissions = @(@{ actions = @('*/read'); notActions = @('Microsoft.Compute/*/read') }) } } }
            else { @{ properties = @{ roleName = 'Reader'; type = 'BuiltInRole'; permissions = @(@{ actions = @('*/read'); notActions = @() }) } } }
        }
        'permissions'
        {
            switch ($Mode) { 'none' { @{ value = @() } } 'nocompute' { @{ value = @(@{ actions = @('*/read'); notActions = @('Microsoft.Compute/*/read') }) } } default { @{ value = @(@{ actions = @('*/read'); notActions = @() }) } } }
        }
        'usage'
        {
            # Rows per subscription: 1 + the number in its id, so each answer is told apart.
            $Count = if ($Mode -eq 'nousage') { 0 } else { 1 + [int]($Sub -replace '\D', '') }
            @{ value = @(if ($Count -gt 0) { 1..$Count | ForEach-Object { @{ properties = @{ quantity = 1 } } } }) }
        }
        'counts' { @{ data = @(@(($Payload | ConvertFrom-Json).subscriptions) | ForEach-Object { @{ subscriptionId = $_; ResourceCount = 4 } }) } }
    }
    $End = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    if ($env:RDA_TEST_CALL_DIR)
    {
        @{ Kind = $Kind; Sub = $Sub; Start = $Start; End = $End } | ConvertTo-Json -Compress |
            Set-Content -LiteralPath (Join-Path $env:RDA_TEST_CALL_DIR ([guid]::NewGuid().ToString('N') + '.json'))
    }
    [pscustomobject]@{ StatusCode = 200; Content = ($Body | ConvertTo-Json -Depth 10 -Compress) }
}

function Set-AzContext
{
    [CmdletBinding()]
    param($Subscription, $Context, $Scope)
    if ($env:RDA_TEST_CALL_DIR) { Set-Content -LiteralPath (Join-Path $env:RDA_TEST_CALL_DIR ([guid]::NewGuid().ToString('N') + '.json')) -Value '{"Kind":"set-context"}' }
}

Export-ModuleMember -Function Invoke-AzRestMethod, Set-AzContext
'@ | Set-Content -LiteralPath (Join-Path $ModuleDir 'RdaTestAzStandIn.psm1')

    $script:SavedModulePath = $env:PSModulePath
    $env:PSModulePath = $script:ModuleRoot + [System.IO.Path]::PathSeparator + $env:PSModulePath
    Import-Module (Join-Path $ModuleDir 'RdaTestAzStandIn.psm1') -Force
    function Get-RoleCheckCallerObjectId { 'test-oid' }

    function Reset-Calls
    {
        $Dir = Join-Path $TestDrive ('calls-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $Dir
        $env:RDA_TEST_CALL_DIR = $Dir
    }
    function Get-Calls { @(Get-ChildItem -LiteralPath $env:RDA_TEST_CALL_DIR -Filter '*.json' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json }) }

    # Both checks for $Subs at $Throttle; returns the records, the results and
    # the printed lines with the timings taken out.
    function Invoke-BothChecks
    {
        param([object[]]$Subs, [int]$Throttle)
        $script:Printed = [System.Collections.Generic.List[string]]::new()
        $Roles = @(Test-SubscriptionRoleAccessAll -Subscriptions $Subs -IncludeUsage -ThrottleLimit $Throttle)
        $Check = Invoke-ConsumptionDataCheck -Subscriptions $Subs -Window $script:Window -RoleCheck $Roles -ThrottleLimit $Throttle
        [pscustomobject]@{
            Roles   = @($Roles | ForEach-Object { '{0}|{1}|{2}|{3}|{4}|{5}' -f $_.Id, $_.State, $_.Verdict, $_.Reason, $_.UsageVerdict, $_.UsageText })
            Usage   = @($Check.Results | ForEach-Object { '{0}|{1}|{2}|{3}|{4}|{5}' -f $_.Id, $_.Outcome, $_.Passed, $_.Detail, $_.PagesRead, $_.PageCapReached })
            Printed = @($script:Printed | ForEach-Object { $_ -replace '\(\d+\.\ds\)$', '(t)' })
            Block   = $Check.ShouldBlock
        }
    }

    $script:Window = Get-ConsumptionWindow -Now ([datetime]'2026-10-26T10:00:00')
    $script:Subs = @(1..12 | ForEach-Object { [pscustomobject]@{ Id = ('sub-{0:d2}' -f $_); Name = ('Subscription {0:d2}' -f $_) } })
}

AfterAll {
    $env:PSModulePath = $script:SavedModulePath
    Remove-Module RdaTestAzStandIn -ErrorAction SilentlyContinue
    Remove-Item Env:\RDA_TEST_CALL_DIR, Env:\RDA_TEST_DELAY_MS, Env:\RDA_TEST_SLOW_MS, Env:\RDA_TEST_SLOW_SUB, Env:\RDA_TEST_MODES -ErrorAction SilentlyContinue
}

Describe 'Up-front checks in parallel' {
    BeforeEach {
        Mock Write-Host { $script:Printed.Add([string]$Object) }
        $env:RDA_TEST_DELAY_MS = '0'
        $env:RDA_TEST_SLOW_SUB = ''
        $env:RDA_TEST_MODES = 'sub-03=none;sub-05=nocompute;sub-08=nousage;sub-11=none'
        Reset-Calls
    }

    It 'gives the same records, results and lines one at a time and 8 at a time' {
        $Serial = Invoke-BothChecks -Subs $script:Subs -Throttle 1
        $SerialCalls = Get-Calls
        Reset-Calls
        $Parallel = Invoke-BothChecks -Subs $script:Subs -Throttle 8
        $ParallelCalls = Get-Calls

        $Parallel.Roles | Should -Be $Serial.Roles
        $Parallel.Usage | Should -Be $Serial.Usage
        $Parallel.Printed | Should -Be $Serial.Printed
        $Parallel.Block | Should -Be $Serial.Block
        @($Serial.Roles | Where-Object { $_ -like '*|Readable|*' }).Count | Should -Be 9
        @($ParallelCalls | Group-Object Kind | Sort-Object Name | ForEach-Object { '{0}={1}' -f $_.Name, $_.Count }) | Should -Be @($SerialCalls | Group-Object Kind | Sort-Object Name | ForEach-Object { '{0}={1}' -f $_.Name, $_.Count })
    }

    It 'checks two subscriptions at the same time, each usage request naming its own subscription' {
        $env:RDA_TEST_MODES = ''
        $env:RDA_TEST_DELAY_MS = '400'
        $Two = @($script:Subs[0..1])
        $Roles = @(Test-SubscriptionRoleAccessAll -Subscriptions $Two -IncludeUsage -ThrottleLimit 8)
        Reset-Calls
        $Check = Invoke-ConsumptionDataCheck -Subscriptions $Two -Window $script:Window -RoleCheck $Roles -ThrottleLimit 8
        $Usage = @(Get-Calls | Where-Object { $_.Kind -eq 'usage' } | Sort-Object Sub)
        $Usage.Count | Should -Be 2
        @($Usage | ForEach-Object { $_.Sub }) | Should -Be @('sub-01', 'sub-02')
        ($Usage[0].Start -lt $Usage[1].End -and $Usage[1].Start -lt $Usage[0].End) | Should -BeTrue -Because 'the two usage requests overlap in time'
        # sub-01 answers 2 rows and sub-02 3 rows, so each result came from its own subscription.
        $Check.Results[0].Detail | Should -Be 'usage values found (2 row(s) read over 1 page(s))'
        $Check.Results[1].Detail | Should -Be 'usage values found (3 row(s) read over 1 page(s))'
    }

    It 'prints in the order given when an earlier subscription finishes last' {
        $env:RDA_TEST_MODES = ''
        $env:RDA_TEST_DELAY_MS = '20'
        $env:RDA_TEST_SLOW_SUB = 'sub-01'
        $env:RDA_TEST_SLOW_MS = '600'
        $Result = Invoke-BothChecks -Subs $script:Subs[0..3] -Throttle 8
        $Calls = Get-Calls
        $FirstEnd = (@($Calls | Where-Object { $_.Kind -eq 'usage' -and $_.Sub -eq 'sub-01' }))[0].End
        @($Calls | Where-Object { $_.Kind -eq 'usage' -and $_.Sub -ne 'sub-01' -and $_.End -lt $FirstEnd }).Count | Should -Be 3 -Because 'the other three finished first'
        @($Result.Printed | Where-Object { $_ -like '  `[Pass`] *' -and $_ -like '*usage values*' }) | Should -Be @(1..4 | ForEach-Object { '  [Pass] Subscription {0:d2} - usage values found ({1} row(s) read over 1 page(s)) (t)' -f $_, ($_ + 1) })
    }

    It 'reads the shared role definition once for the whole run' {
        $env:RDA_TEST_MODES = ''
        $env:RDA_TEST_DELAY_MS = '50'
        $null = Test-SubscriptionRoleAccessAll -Subscriptions $script:Subs -ThrottleLimit 8
        @(Get-Calls | Where-Object { $_.Kind -eq 'definition' }).Count | Should -Be 1
        @(Get-Calls | Where-Object { $_.Kind -eq 'roles' }).Count | Should -Be 12
    }

    It 'never switches the Azure context, and no function run in parallel can' {
        $null = Invoke-BothChecks -Subs $script:Subs -Throttle 8
        @(Get-Calls | Where-Object { $_.Kind -eq 'set-context' }).Count | Should -Be 0

        # Every function of Common.Functions.ps1 the parallel part can reach.
        $Tokens = $null
        $Errors = $null
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1'), [ref]$Tokens, [ref]$Errors)
        $Defs = @{}
        foreach ($F in $Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $Defs[$F.Name] = $F }
        $Seen = @{}
        $Queue = [System.Collections.Generic.Queue[string]]::new()
        foreach ($Start in @('Get-SubscriptionRoleAccess', 'Get-SubscriptionConsumptionCheck')) { $Queue.Enqueue($Start) }
        $Commands = [System.Collections.Generic.List[string]]::new()
        while ($Queue.Count -gt 0)
        {
            $Name = $Queue.Dequeue()
            if ($Seen.ContainsKey($Name)) { continue }
            $Seen[$Name] = $true
            foreach ($Cmd in $Defs[$Name].FindAll({ param($N) $N -is [System.Management.Automation.Language.CommandAst] }, $true))
            {
                $Called = $Cmd.GetCommandName()
                if ([string]::IsNullOrEmpty($Called)) { continue }
                $Commands.Add($Called)
                if ($Defs.ContainsKey($Called)) { $Queue.Enqueue($Called) }
            }
        }
        $Seen.Keys | Should -Contain 'Get-UsageAggregatesPage'
        $Seen.Keys | Should -Contain 'Get-RoleAssignmentAccess'
        @($Commands | Where-Object { $_ -match '^(Set|Select|Get|Clear|Import|Remove|Rename)-AzContext$|^Select-AzSubscription$|^Get-UsageAggregates$' }) | Should -BeNullOrEmpty
    }

    It 'reports a subscription whose check throws instead of dropping it, in order (<Throttle> at a time)' -TestCases @(@{ Throttle = 1 }, @{ Throttle = 8 }) {
        param($Throttle)
        $Seen = [System.Collections.Generic.List[object]]::new()
        # Get-SubscriptionConsumptionCheck without its mandatory -Window throws for every item.
        Invoke-SubscriptionCheckInOrder -Items @($script:Subs[0..2]) -Command 'Get-SubscriptionConsumptionCheck' -Arguments @{} -ThrottleLimit $Throttle -OnResult { param($R) $Seen.Add($R) }
        $Seen.Count | Should -Be 3
        @($Seen | ForEach-Object { $_.Failed }) | Should -Be @($true, $true, $true)
        @($Seen | ForEach-Object { $_.Item.Id }) | Should -Be @('sub-01', 'sub-02', 'sub-03')
    }

    It 'turns a per-subscription check that throws into a failing record: Unknown for the role check, Error for the consumption check' {
        # Mocks exist only in this runspace, so this runs one at a time; the
        # parallel catch is covered by the test above.
        Mock Get-SubscriptionRoleAccess { throw 'boom' } -ParameterFilter { $Item.Id -eq 'sub-02' }
        Mock Get-SubscriptionConsumptionCheck { throw 'bang' } -ParameterFilter { $Item.Id -eq 'sub-02' }
        $env:RDA_TEST_MODES = ''
        $Result = Invoke-BothChecks -Subs $script:Subs[0..2] -Throttle 1
        $Result.Roles[1] | Should -Be 'sub-02|Unknown|Unknown|role check inconclusive (boom)|Unknown|unknown - the role check was inconclusive'
        $Result.Usage[1] | Should -Be 'sub-02|Error|False|the check failed: bang|0|False'
        $Result.Block | Should -BeTrue
        $Result.Roles[0] | Should -BeLike 'sub-01|Readable|*'
        $Result.Roles[2] | Should -BeLike 'sub-03|Readable|*'
    }
}
