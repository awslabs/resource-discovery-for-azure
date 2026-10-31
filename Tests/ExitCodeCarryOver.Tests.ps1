# =============================================================================
# ExitCodeCarryOver.Tests.ps1
#
# Offline tests that Run-AllSubscriptions.ps1 reports a subscription as failed
# only when ResourceInventory.ps1 failed for that subscription.
#
# WHY THIS TEST EXISTS
# --------------------
# The wrapper's sequential loop, its one-subscription path and the stream
# worker call ResourceInventory.ps1 with `&` and treat a non-zero
# $LASTEXITCODE afterwards as a failed subscription. The script ends with
# `exit 1` when it stops, and with no `exit` at all when it succeeds, which
# leaves $LASTEXITCODE as it was. With no native command in the run to reset
# it, the `exit 1` of one subscription marked every later subscription of the
# same loop or stream as failed with "Script exited with code 1", even though
# its report was written; a native command that failed in the session before
# the wrapper started did the same to every subscription.
#
# HOW
# ---
# The tool is copied to a temp dir and the REAL Run-AllSubscriptions.ps1 runs
# as its own pwsh process (stdin closed), calling the REAL
# Run-AllSubscriptions.Stream.ps1 and ResourceInventory.ps1. Azure is a set of
# stand-in Az modules found first on PSModulePath; no az command is used. The
# stand-in Az.Compute does not load when the ResourceInventory.ps1 importing it
# was started for the failing subscription, so for that subscription the real
# script takes its "module present on disk but failed to load" path and ends
# with exit 1; the next subscription loads it. The run's home is a scratch
# folder, so the run writes its inventory root under it. On Windows the
# wrapper writes to C:\InventoryReports instead, so these tests do not run
# there. Placeholder ids only. No live Azure.
#
# Run with: Invoke-Pester ./Tests/ExitCodeCarryOver.Tests.ps1 -Output Detailed
# =============================================================================

Describe 'Run-AllSubscriptions.ps1 reports only the subscriptions that failed' -Skip:$IsWindows {
    BeforeAll {
        $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
        $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('ExitCodeCarryOver_' + [guid]::NewGuid().ToString('N'))
        $script:Tenant = '12345678-1234-1234-1234-123456789012'
        $script:SubA = [pscustomobject]@{ Id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'; Name = 'Sub A' }
        $script:SubB = [pscustomobject]@{ Id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'; Name = 'Sub B' }
        $script:SubC = [pscustomobject]@{ Id = 'cccccccc-cccc-cccc-cccc-cccccccccccc'; Name = 'Sub C' }

        $script:Tool = Join-Path $script:WorkDir 'tool'
        New-Item -ItemType Directory -Path $script:Tool -Force | Out-Null
        foreach ($Item in @('Run-AllSubscriptions.ps1', 'Run-AllSubscriptions.Stream.ps1', 'ResourceInventory.ps1', 'Version.json', 'Functions', 'Extension', 'Services'))
        {
            Copy-Item -LiteralPath (Join-Path $script:RepoRoot $Item) -Destination $script:Tool -Recurse -Force
        }
        $script:Wrapper = Join-Path $script:Tool 'Run-AllSubscriptions.ps1'

        # Az.Accounts answers the sign-in, context, token and subscription
        # calls, the role checks, the per-subscription resource count and
        # Resource Graph discovery (one public IP per subscription).
        $Accounts = @'
function Get-RdaStandInScenario { Get-Content -LiteralPath $env:RDA_STANDIN_AZURE -Raw | ConvertFrom-Json }
function Get-RdaStandInContext
{
    [pscustomobject]@{
        Account      = [pscustomobject]@{ Id = 'operator@example.com'; Type = 'User' }
        Tenant       = [pscustomobject]@{ Id = (Get-RdaStandInScenario).Tenant }
        Subscription = [pscustomobject]@{ Id = $script:ContextSub; Name = 'stand-in' }
        Environment  = [pscustomobject]@{ Name = 'AzureCloud'; ResourceManagerUrl = 'https://management.azure.com/' }
    }
}
$script:ContextSub = $null
function Get-AzContext { [CmdletBinding()] param([switch]$ListAvailable) Get-RdaStandInContext }
function Set-AzContext { [CmdletBinding()] param($Subscription, $Tenant, $Context, $Scope) if ($Subscription) { $script:ContextSub = [string]$Subscription }; Get-RdaStandInContext }
function Import-AzContext { [CmdletBinding()] param($Path) Get-RdaStandInContext }
function Save-AzContext { [CmdletBinding()] param($Path, [switch]$Force) Set-Content -LiteralPath $Path -Value '{}' }
function Disable-AzContextAutosave { [CmdletBinding()] param($Scope) }
function Get-AzContextAutosaveSetting { [CmdletBinding()] param($Scope) [pscustomobject]@{ Mode = 'Process'; ContextFile = 'None'; CacheFile = 'None' } }
function Connect-AzAccount { [CmdletBinding()] param($Tenant, [switch]$UseDeviceAuthentication) throw 'stand-in: no sign-in expected' }
function Get-AzAccessToken
{
    [CmdletBinding()] param($TenantId, $ResourceUrl, [switch]$AsSecureString, $ResourceTypeName)
    $Claims = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"oid":"stand-in-caller"}')).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $Tenant = if ($TenantId) { [string]$TenantId } else { (Get-RdaStandInScenario).Tenant }
    [pscustomobject]@{ Token = ('e30.{0}.c2ln' -f $Claims); Type = 'Bearer'; ExpiresOn = (Get-Date).AddHours(1); TenantId = $Tenant }
}
function Get-AzSubscription
{
    [CmdletBinding()] param($TenantId, $SubscriptionId, $SubscriptionName)
    $Scenario = Get-RdaStandInScenario
    @($Scenario.Subscriptions | Where-Object { -not $SubscriptionId -or $_.Id -eq $SubscriptionId } | ForEach-Object { [pscustomobject]@{ Id = $_.Id; SubscriptionId = $_.Id; Name = $_.Name; State = 'Enabled'; TenantId = $Scenario.Tenant; HomeTenantId = $Scenario.Tenant } })
}
function Invoke-AzRestMethod
{
    [CmdletBinding()] param([string]$Method = 'GET', [string]$Path, [string]$Payload, [string]$Uri)
    if (-not $Path) { $Path = $Uri }
    $Answer = { param([int]$Status, $Body) [pscustomobject]@{ StatusCode = $Status; Content = (ConvertTo-Json -InputObject $Body -Depth 10 -Compress); Headers = @{} } }
    if ($Path -match '/subscriptions/([^/?]+)/resourcegroups\?') { return & $Answer 200 @{ value = @() } }
    if ($Path -match '/subscriptions/([^/?]+)/providers/Microsoft\.Authorization/roleAssignments\?')
    {
        $Id = $Matches[1]
        return & $Answer 200 @{ value = @(@{ properties = @{ scope = "/subscriptions/$Id"; principalId = 'stand-in-caller'; roleDefinitionId = "/subscriptions/$Id/providers/Microsoft.Authorization/roleDefinitions/stand-in-reader" } }) }
    }
    if ($Path -match '/providers/Microsoft\.Authorization/roleDefinitions/[^/?]+\?') { return & $Answer 200 @{ properties = @{ roleName = 'Reader'; type = 'BuiltInRole'; permissions = @(@{ actions = @('*/read'); notActions = @() }) } } }
    if ($Path -match '/subscriptions/([^/?]+)/providers/Microsoft\.Authorization/permissions\?') { return & $Answer 200 @{ value = @(@{ actions = @('*/read'); notActions = @() }) } }
    if ($Path -like '*Microsoft.ResourceGraph/resources*')
    {
        $Request = $Payload | ConvertFrom-Json
        $Ids = @($Request.subscriptions | ForEach-Object { [string]$_ })
        $Query = [string]$Request.query
        if ($Query -match 'ResourceCount = count\(\) by subscriptionId') { return & $Answer 200 @{ data = @($Ids | ForEach-Object { @{ subscriptionId = $_; ResourceCount = 1 } }) } }
        if ($Query -match 'desktopvirtualizationresources') { return & $Answer 200 @{ data = @(@{ count_ = 0 }) } }
        if ($Query -match 'summarize count\(\)') { return & $Answer 200 @{ data = @(@{ count_ = $Ids.Count }) } }
        if ($Query -match '^\s*resources\b')
        {
            $Rows = @($Ids | ForEach-Object { @{ id = "/subscriptions/$_/resourceGroups/rg-demo/providers/Microsoft.Network/publicIPAddresses/pip-demo"; name = 'pip-demo'; type = 'microsoft.network/publicipaddresses'; location = 'eastus'; subscriptionId = $_; resourceGroup = 'rg-demo'; sku = @{ name = 'Standard' }; properties = @{ publicIPAllocationMethod = 'Static'; publicIPAddressVersion = 'IPv4'; provisioningState = 'Succeeded' } } })
            return & $Answer 200 @{ data = $Rows; count = $Rows.Count; totalRecords = $Rows.Count }
        }
        return & $Answer 200 @{ data = @(); count = 0; totalRecords = 0 }
    }
    return & $Answer 404 @{ error = @{ code = 'NotFound'; message = 'stand-in: no answer for this path' } }
}
'@
        # Throws while it loads when the ResourceInventory.ps1 importing it was
        # started for the scenario's failing subscription.
        $Compute = @'
$FailSub = (Get-Content -LiteralPath $env:RDA_STANDIN_AZURE -Raw | ConvertFrom-Json).FailSub
if ($FailSub)
{
    foreach ($Frame in @(Get-PSCallStack))
    {
        $Bound = $Frame.InvocationInfo.BoundParameters
        if ($Frame.ScriptName -like '*ResourceInventory.ps1' -and $null -ne $Bound -and $Bound.ContainsKey('SubscriptionID') -and [string]$Bound['SubscriptionID'] -eq $FailSub)
        {
            throw 'stand-in: Az.Compute could not load one of its assemblies'
        }
    }
}
'@
        $script:Modules = Join-Path $script:WorkDir 'modules'
        foreach ($Module in @(@{ Name = 'Az.Accounts'; Body = $Accounts }, @{ Name = 'Az.Compute'; Body = $Compute }, @{ Name = 'Az.Monitor'; Body = '' }, @{ Name = 'Az.Billing'; Body = '' }))
        {
            $Dir = Join-Path $script:Modules (Join-Path $Module.Name '99.0.0')
            New-Item -ItemType Directory -Path $Dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $Dir ($Module.Name + '.psm1')) -Value $Module.Body -Encoding utf8
            Set-Content -LiteralPath (Join-Path $Dir ($Module.Name + '.psd1')) -Value ("@{{ ModuleVersion = '99.0.0'; RootModule = '{0}.psm1'; FunctionsToExport = '*' }}" -f $Module.Name) -Encoding utf8
        }

        # One run of the wrapper as its own process with a fresh home: its exit
        # code, the lines it printed and the resume state it left. -PriorExitCode
        # starts it from a pwsh session whose $LASTEXITCODE already holds that
        # value, as when a native command failed at the prompt before the run.
        function script:Invoke-CarryOverRun
        {
            param([object[]]$Subs, [string]$FailSub = '', [int]$Streams = 1, [int]$PriorExitCode = -1)
            $CaseDir = Join-Path $script:WorkDir ([guid]::NewGuid().ToString('N').Substring(0, 8))
            $CaseHome = Join-Path $CaseDir 'home'
            New-Item -ItemType Directory -Path $CaseHome -Force | Out-Null
            $Scenario = Join-Path $CaseDir 'scenario.json'
            [pscustomobject]@{ Tenant = $script:Tenant; Subscriptions = @($Subs); FailSub = $FailSub } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Scenario -Encoding utf8

            $WrapperArgs = @('-TenantID', $script:Tenant, '-SkipMetrics', '-SkipConsumption', '-ParallelStreams', [string]$Streams)
            if ($PriorExitCode -ge 0)
            {
                $Launcher = Join-Path $CaseDir 'launcher.ps1'
                @(
                    ('$global:LASTEXITCODE = {0}' -f $PriorExitCode)
                    ("& '{0}' {1}" -f $script:Wrapper, (($WrapperArgs | ForEach-Object { if ($_ -like '-*') { $_ } else { "'$_'" } }) -join ' '))
                    'exit $LASTEXITCODE'
                ) | Set-Content -LiteralPath $Launcher -Encoding utf8
                $Entry = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $Launcher)
            }
            else
            {
                $Entry = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script:Wrapper) + $WrapperArgs
            }

            $Info = [System.Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh'))
            foreach ($Arg in $Entry) { $Info.ArgumentList.Add($Arg) }
            $Info.UseShellExecute = $false
            $Info.RedirectStandardInput = $true
            $Info.RedirectStandardOutput = $true
            $Info.RedirectStandardError = $true
            $Info.WorkingDirectory = $script:Tool
            $Info.Environment['HOME'] = $CaseHome
            $Info.Environment['PSModulePath'] = $script:Modules
            $Info.Environment['RDA_STANDIN_AZURE'] = $Scenario
            $Info.Environment['NO_COLOR'] = '1'
            $Proc = [System.Diagnostics.Process]::Start($Info)
            $Proc.StandardInput.Close()
            $Out = $Proc.StandardOutput.ReadToEndAsync()
            $Err = $Proc.StandardError.ReadToEndAsync()
            if (-not $Proc.WaitForExit(300000))
            {
                $Proc.Kill($true)
                throw 'The wrapper run did not end within 300 seconds.'
            }
            $Proc.WaitForExit()
            $StateFile = Join-Path $CaseHome ('InventoryReports/.resume-state-{0}.json' -f $script:Tenant)
            $State = if (Test-Path -LiteralPath $StateFile) { Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json } else { $null }
            return [pscustomobject]@{
                ExitCode  = $Proc.ExitCode
                Console   = ($Out.Result + $Err.Result)
                FailedIds = @(if ($null -ne $State) { @($State.FailedAttempts) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.Id } })
            }
        }
    }

    AfterAll {
        if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
        {
            Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'sequential: the subscription after one that ended with exit 1 completes and is not listed as failed' {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -FailSub $script:SubA.Id
        $Run.Console | Should -Match 'ERROR processing subscription Sub A: Script exited with code 1'
        $Run.Console | Should -Not -Match 'ERROR processing subscription Sub B' -Because $Run.Console
        $Run.Console | Should -Match 'Completed subscription: Sub B'
        $Run.FailedIds | Should -Be @($script:SubA.Id)
    }

    It 'one stream: the subscription after one that ended with exit 1 in the same stream is not listed as failed' {
        # Three subscriptions over two streams: stream-0 holds Sub A then Sub C.
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -FailSub $script:SubA.Id -Streams 2
        $Run.Console | Should -Match '\[stream-0\] queued: 2 subscription\(s\)'
        $Run.Console | Should -Match '\[stream-0\] ERROR processing Sub A: Script exited with code 1'
        $Run.Console | Should -Not -Match 'ERROR processing Sub C' -Because $Run.Console
        $Run.Console | Should -Match '\[stream-0\] done: Sub C'
        $Run.Console | Should -Match '\[stream-1\] done: Sub B'
        $Run.FailedIds | Should -Be @($script:SubA.Id)
    }

    It 'sequential: a non-zero $LASTEXITCODE left in the session before the run fails no subscription' {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -PriorExitCode 1
        $Run.Console | Should -Not -Match 'ERROR processing subscription' -Because $Run.Console
        $Run.Console | Should -Match 'Completed subscription: Sub A'
        $Run.Console | Should -Match 'Completed subscription: Sub B'
        $Run.FailedIds.Count | Should -Be 0
        $Run.ExitCode | Should -Be 0
    }

    It 'one subscription with -ParallelStreams: a non-zero $LASTEXITCODE left in the session before the run does not fail it' {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA) -Streams 2 -PriorExitCode 1
        $Run.Console | Should -Match 'Only one'
        $Run.Console | Should -Not -Match 'ERROR processing subscription' -Because $Run.Console
        $Run.FailedIds.Count | Should -Be 0
        $Run.ExitCode | Should -Be 0
    }

    It 'one subscription with -ParallelStreams: a subscription that ends with exit 1 is still listed as failed' {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA) -Streams 2 -FailSub $script:SubA.Id
        $Run.Console | Should -Match 'ERROR processing subscription Sub A: Script exited with code 1'
        $Run.FailedIds | Should -Be @($script:SubA.Id)
    }
}
