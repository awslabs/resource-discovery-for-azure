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
# A clean run also has to set the code itself: inside a PowerShell session a
# run with two or more streams calls no inventory in the session, so without
# its own `exit 0` the session read the code it held before the run.
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
        # ResourceInventory.ps1 takes only a GUID as -SubscriptionID. The stand-in
        # ids are built here from 32 hex digits, so the file holds no id but the
        # documentation placeholder.
        $script:SubA = [pscustomobject]@{ Id = [guid]::new(('0' * 31) + 'a').ToString(); Name = 'Sub A' }
        $script:SubB = [pscustomobject]@{ Id = [guid]::new(('0' * 31) + 'b').ToString(); Name = 'Sub B' }
        $script:SubC = [pscustomobject]@{ Id = [guid]::new(('0' * 31) + 'c').ToString(); Name = 'Sub C' }

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
# Every process that runs the tool loads this stand-in first (the wrapper and
# each stream), so it skips ResourceInventory.ps1's online version check there,
# as Tests/SetupStop.Tests.ps1 does in its harness. The platform is set because
# the same flag also skips the environment check that sets it.
$Global:RdaSessionInitialized = $true
$Global:PlatformOS = 'PowerShell Unix'
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
        # A collector, in the copy only, that fails for the scenario's
        # CollectorFailSub, so that subscription's run records a collector
        # failure and still writes its report.
        @'
param($Sub, $Resources, $Task, $ResourceIdDictionary)
$CollectorFailSub = (Get-Content -LiteralPath $env:RDA_STANDIN_AZURE -Raw | ConvertFrom-Json).CollectorFailSub
if ($Task -eq 'Processing' -and $CollectorFailSub -and @($Resources | Where-Object { $_.subscriptionId -eq $CollectorFailSub }).Count -gt 0)
{
    throw 'stand-in: this collector failed'
}
'@ | Set-Content -LiteralPath (Join-Path $script:Tool 'Services/Networking/StandInCollector.ps1') -Encoding utf8

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
            param([object[]]$Subs, [string]$FailSub = '', [int]$Streams = 1, [int]$PriorExitCode = -1, [string]$CollectorFailSub = '', [switch]$CorruptStreamSummary, [string]$StreamSummaryJson = '', [switch]$MissingStreamSummary, [string]$Stream1SummaryJson = '', [switch]$Resume, [string[]]$Stream0Completed = @())
            $CaseDir = Join-Path $script:WorkDir ([guid]::NewGuid().ToString('N').Substring(0, 8))
            $CaseHome = Join-Path $CaseDir 'home'
            New-Item -ItemType Directory -Path $CaseHome -Force | Out-Null
            if ($MissingStreamSummary)
            {
                # A folder where stream 0's summary file goes: the stream
                # cannot write its summary, so the wrapper finds no summary
                # file for it (as when its job dies before the end).
                New-Item -ItemType Directory -Path (Join-Path $CaseHome 'InventoryReports/.rda-stream-0-summary.json') -Force | Out-Null
            }
            if ($Stream0Completed.Count -gt 0)
            {
                # Stream 0's resume file from an earlier run that stopped
                # before its end: under -Resume it skips these subscriptions.
                $Reports = New-Item -ItemType Directory -Path (Join-Path $CaseHome 'InventoryReports') -Force
                [pscustomobject]@{ Tenant = $script:Tenant; StreamId = '0'; Completed = @($Stream0Completed); FailedAttempts = @() } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $Reports.FullName ('.resume-state-{0}-stream-0.json' -f $script:Tenant)) -Encoding utf8
            }
            if ($Stream1SummaryJson)
            {
                # Stream 1 then reports what this text says, not what it did.
                # {Reports} in the text stands for this run's inventory root.
                $Reports = New-Item -ItemType Directory -Path (Join-Path $CaseHome 'InventoryReports') -Force
                $Summary = Join-Path $Reports.FullName '.rda-stream-1-summary.json'
                $ReportsText = (ConvertTo-Json -InputObject $Reports.FullName).Trim('"')
                Set-Content -LiteralPath $Summary -Value $Stream1SummaryJson.Replace('{Reports}', $ReportsText) -Encoding utf8
                [System.IO.File]::SetUnixFileMode($Summary, [System.IO.UnixFileMode]'UserRead, GroupRead, OtherRead')
            }
            if ($CorruptStreamSummary)
            {
                # Stream 0's summary file is left as text that is not JSON and
                # cannot be written, so the stream cannot replace it and the
                # wrapper finds it but cannot read it.
                $Reports = New-Item -ItemType Directory -Path (Join-Path $CaseHome 'InventoryReports') -Force
                $Summary = Join-Path $Reports.FullName '.rda-stream-0-summary.json'
                Set-Content -LiteralPath $Summary -Value 'not json' -Encoding utf8
                [System.IO.File]::SetUnixFileMode($Summary, [System.IO.UnixFileMode]'UserRead, GroupRead, OtherRead')
            }
            elseif ($StreamSummaryJson)
            {
                # The same, with a summary the wrapper can read: stream 0 then
                # reports what this text says, not what it did.
                $Reports = New-Item -ItemType Directory -Path (Join-Path $CaseHome 'InventoryReports') -Force
                $Summary = Join-Path $Reports.FullName '.rda-stream-0-summary.json'
                Set-Content -LiteralPath $Summary -Value $StreamSummaryJson -Encoding utf8
                [System.IO.File]::SetUnixFileMode($Summary, [System.IO.UnixFileMode]'UserRead, GroupRead, OtherRead')
            }
            $Scenario = Join-Path $CaseDir 'scenario.json'
            [pscustomobject]@{ Tenant = $script:Tenant; Subscriptions = @($Subs); FailSub = $FailSub; CollectorFailSub = $CollectorFailSub } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Scenario -Encoding utf8

            $WrapperArgs = @('-TenantID', $script:Tenant, '-SkipMetrics', '-SkipConsumption', '-ParallelStreams', [string]$Streams)
            if ($Resume) { $WrapperArgs += '-Resume' }
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
            $Info.Environment['POWERSHELL_TELEMETRY_OPTOUT'] = '1'
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
            # RunSummary.log from the consolidated zip, when one was made.
            $OuterZip = @(Get-ChildItem -Path (Join-Path $CaseHome 'InventoryReports') -Filter 'AllSubscriptions_ResourcesReport_*.zip' -File -ErrorAction SilentlyContinue)
            $RunSummary = $null
            $MainSummary = $null
            if ($OuterZip.Count -eq 1)
            {
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                $Zip = [System.IO.Compression.ZipFile]::OpenRead($OuterZip[0].FullName)
                try
                {
                    $Entry = $Zip.GetEntry('RunSummary.log')
                    if ($null -ne $Entry)
                    {
                        $Reader = [System.IO.StreamReader]::new($Entry.Open())
                        try { $RunSummary = $Reader.ReadToEnd() } finally { $Reader.Dispose() }
                    }
                    $Entry = $Zip.GetEntry('MainSummary.html')
                    if ($null -ne $Entry)
                    {
                        $Reader = [System.IO.StreamReader]::new($Entry.Open())
                        try { $MainSummary = $Reader.ReadToEnd() } finally { $Reader.Dispose() }
                    }
                }
                finally { $Zip.Dispose() }
            }
            return [pscustomobject]@{
                ExitCode   = $Proc.ExitCode
                Console    = ($Out.Result + $Err.Result)
                FailedIds  = @(if ($null -ne $State) { @($State.FailedAttempts) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.Id } })
                StateKept  = $null -ne $State
                ZipCount   = $OuterZip.Count
                RunSummary = $RunSummary
                MainSummary = $MainSummary
            }
        }

        # One pwsh session (`pwsh -Command -`, its lines on stdin, as typed at a
        # prompt) with a fresh home. {Run} in a line becomes the wrapper call
        # with -ParallelStreams $Streams. Returns the session's exit code and
        # the lines it printed.
        function script:Invoke-SessionRun
        {
            param([object[]]$Subs, [string[]]$Lines, [int]$Streams = 2)
            $CaseDir = Join-Path $script:WorkDir ([guid]::NewGuid().ToString('N').Substring(0, 8))
            $CaseHome = Join-Path $CaseDir 'home'
            New-Item -ItemType Directory -Path $CaseHome -Force | Out-Null
            $Scenario = Join-Path $CaseDir 'scenario.json'
            [pscustomobject]@{ Tenant = $script:Tenant; Subscriptions = @($Subs); FailSub = '' } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Scenario -Encoding utf8
            $Call = "& '{0}' -TenantID '{1}' -SkipMetrics -SkipConsumption -ParallelStreams {2}" -f ($script:Wrapper -replace "'", "''"), $script:Tenant, $Streams

            $Info = [System.Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh'))
            foreach ($Arg in @('-NoLogo', '-NoProfile', '-Command', '-')) { $Info.ArgumentList.Add($Arg) }
            $Info.UseShellExecute = $false
            $Info.RedirectStandardInput = $true
            $Info.RedirectStandardOutput = $true
            $Info.RedirectStandardError = $true
            $Info.WorkingDirectory = $script:Tool
            $Info.Environment['HOME'] = $CaseHome
            $Info.Environment['PSModulePath'] = $script:Modules
            $Info.Environment['RDA_STANDIN_AZURE'] = $Scenario
            $Info.Environment['NO_COLOR'] = '1'
            $Info.Environment['POWERSHELL_TELEMETRY_OPTOUT'] = '1'
            $Proc = [System.Diagnostics.Process]::Start($Info)
            foreach ($Line in $Lines) { $Proc.StandardInput.WriteLine($Line.Replace('{Run}', $Call)) }
            $Proc.StandardInput.Close()
            $Out = $Proc.StandardOutput.ReadToEndAsync()
            $Err = $Proc.StandardError.ReadToEndAsync()
            if (-not $Proc.WaitForExit(300000))
            {
                $Proc.Kill($true)
                throw 'The session did not end within 300 seconds.'
            }
            $Proc.WaitForExit()
            $Text = @(($Out.Result + $Err.Result) -split "`r?`n" | ForEach-Object { $_.Trim() })
            return [pscustomobject]@{
                ExitCode = $Proc.ExitCode
                Console  = ($Text -join "`n")
                After    = @($Text | Where-Object { $_ -match '^after\d?: ' })
                Open     = @($Text | Where-Object { $_ -eq 'session still open' }).Count -eq 1
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
        # Sub A's report is missing, so the run is not reported as clean.
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
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
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
    }

    It 'sequential: exit 2 for a failed subscription still names the collector failure it hides, on the console and in RunSummary.log' {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -FailSub $script:SubA.Id -CollectorFailSub $script:SubB.Id
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
        $Run.Console | Should -Match 'FAILED \(collectors\)'
        $Run.ZipCount | Should -Be 1 -Because 'Sub B''s report is still consolidated'
        $Made = 'Exit code 2: one or more subscriptions failed (see Subscriptions Failed); the consolidated zip holds the reports of the subscriptions that worked.'
        $Hidden = 'Exit code 2 takes priority over exit code 4, which this run also has: one or more collectors failed.'
        $Run.Console | Should -Match ([regex]::Escape($Made))
        $Run.Console | Should -Match ([regex]::Escape($Hidden))
        $Run.RunSummary | Should -Match ([regex]::Escape($Made))
        $Run.RunSummary | Should -Match ([regex]::Escape($Hidden))
    }

    It 'sequential: exit 2 when every subscription failed says no consolidated zip was made' {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA) -FailSub $script:SubA.Id
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
        $Run.ZipCount | Should -Be 0
        $Run.Console | Should -Match ([regex]::Escape('Exit code 2: one or more subscriptions failed (see Subscriptions Failed); no consolidated zip was made.'))
    }

    It 'two streams: a stream summary the wrapper cannot read is not counted as a failed subscription, and exit 2 names it' {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -CorruptStreamSummary
        $Run.Console | Should -Match '\[stream-0\] ERROR: could not parse summary file' -Because $Run.Console
        $Run.Console | Should -Not -Match 'ERROR processing' -Because 'no inventory run failed; only the stream summary is lost'
        # Both reports are in the consolidated zip, so no subscription is
        # counted or named as failed.
        $Run.ZipCount | Should -Be 1 -Because $Run.Console
        $Run.Console | Should -Not -Match 'Subscriptions Failed:' -Because $Run.Console
        $Run.Console | Should -Not -Match 'subscriptions failed' -Because $Run.Console
        $Run.Console | Should -Match '2 subscription\(s\), 2 total resource\(s\), 0 empty, 0 failed' -Because $Run.Console
        $Run.Console | Should -Match 'Stream Summary Unreadable:\s+stream-0 \(1 subscription\(s\) not confirmed; check the consolidated zip\)' -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('Exit code 2: the summary of stream 0 could not be read; its 1 subscription(s) are not confirmed; check the consolidated zip for their reports.'))
        # The run cannot show that stream's results, so it is not called clean
        # and its resume state is kept.
        $Run.StateKept | Should -BeTrue -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
    }

    It 'two streams: the verification-gap stop prints the Exit code lines, naming the sign-in skip and collector failures it hides' {
        # Stream 0 reports two subscriptions that worked, with a collector
        # failure and a Metrics sign-in skip; only two reports are on disk
        # (Sub A and Sub B), so one report is missing.
        $SubX = [guid]::new(('0' * 31) + 'e').ToString()
        $SubY = [guid]::new(('0' * 31) + 'f').ToString()
        $Forged = [pscustomobject]@{
            Status            = 'ok'
            ResourceCounts    = @([pscustomobject]@{ Name = 'Sub X'; Id = $SubX; Count = 1 }, [pscustomobject]@{ Name = 'Sub Y'; Id = $SubY; Count = 1 })
            Failed            = @()
            CollectorFailures = @([pscustomobject]@{ Id = $SubX; Name = 'Sub X'; Module = 'StandIn'; Message = 'stand-in: this collector failed' })
            MetricsFailedSubs = @([pscustomobject]@{ Id = $SubX; Name = 'Sub X'; Message = 'stand-in: no token' })
        } | ConvertTo-Json -Depth 5
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -StreamSummaryJson $Forged
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
        $Run.ZipCount | Should -Be 0 -Because $Run.Console
        $Gap = 'Exit code 2: a report is missing (verification gap, see Per-subscription output verification failed); no consolidated zip was made.'
        $Hidden = 'Exit code 2 takes priority over exit code 5, which this run also has: Metrics and/or Consumption were skipped for a sign-in problem and one or more collectors failed.'
        $Run.Console | Should -Match ('(?s)Per-subscription output verification failed\..*' + [regex]::Escape($Gap) + '\s+' + [regex]::Escape($Hidden)) -Because $Run.Console
        $Run.Console | Should -Not -Match 'subscriptions failed' -Because $Run.Console
    }

    It 'sequential: RunSummary.log lists the failed subscription by its name and id' {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -FailSub $script:SubA.Id
        $Run.ZipCount | Should -Be 1 -Because $Run.Console
        $Run.RunSummary | Should -Match ('(?m)^  - {0} \({1}\)\s*$' -f [regex]::Escape($script:SubA.Name), [regex]::Escape($script:SubA.Id)) -Because $Run.RunSummary
        $Run.RunSummary | Should -Not -Match '(?m)^  -  \(\)' -Because $Run.RunSummary
    }

    It 'one stream: RunSummary.log lists the subscription that failed in a stream by its name and id' {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -FailSub $script:SubA.Id -Streams 2
        $Run.ZipCount | Should -Be 1 -Because $Run.Console
        $Run.RunSummary | Should -Match ('(?m)^  - {0} \({1}\)\s*$' -f [regex]::Escape($script:SubA.Name), [regex]::Escape($script:SubA.Id)) -Because $Run.RunSummary
        $Run.RunSummary | Should -Not -Match '(?m)^  -  \(\)' -Because $Run.RunSummary
    }

    It 'two streams: RunSummary.log names a stream whose summary could not be read under Exit code, not as a failed subscription' {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -CorruptStreamSummary
        $Run.ZipCount | Should -Be 1 -Because $Run.Console
        $Run.RunSummary | Should -Match '(?m)^  Failed subscriptions\s+: 0\s*$' -Because $Run.RunSummary
        $Run.RunSummary | Should -Not -Match 'corrupt summary' -Because $Run.RunSummary
        $Run.RunSummary | Should -Not -Match 'subscriptions failed' -Because $Run.RunSummary
        $Run.RunSummary | Should -Match ([regex]::Escape('  Exit code 2: the summary of stream 0 could not be read; its 1 subscription(s) are not confirmed; check the consolidated zip for their reports.')) -Because $Run.RunSummary
        $Run.RunSummary | Should -Not -Match '(?m)^  -  \(\)' -Because $Run.RunSummary
    }

    It 'two streams: MainSummary.html names a stream whose summary could not be read, not as a failed subscription' {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -CorruptStreamSummary
        $Run.ZipCount | Should -Be 1 -Because $Run.Console
        $Run.MainSummary | Should -Not -BeNullOrEmpty -Because $Run.Console
        $Run.MainSummary | Should -Match ([regex]::Escape('The summary of stream 0 could not be read.</b> Its 1 subscription(s) are not confirmed; check the consolidated zip for their reports.')) -Because 'MainSummary.html must show the same signal as the console and RunSummary.log'
        $Run.MainSummary | Should -Not -Match 'failed to process' -Because 'no subscription failed'
    }

    It 'two streams with -Resume: a stream with no summary file names its 2 subscriptions as not confirmed, not as one failed subscription' {
        # Three subscriptions over two streams: stream-0 holds Sub A then Sub C.
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -MissingStreamSummary -Resume
        $Run.Console | Should -Match '\[stream-0\] WARNING: no summary file' -Because $Run.Console
        $Run.Console | Should -Not -Match 'Subscriptions Failed:' -Because $Run.Console
        $Run.Console | Should -Match 'Stream Summary Missing:\s+stream-0 \(2 subscription\(s\) not confirmed; check the consolidated zip\)' -Because $Run.Console
        $Run.Console | Should -Not -Match 'could not be read' -Because 'the summary file is missing, not unreadable'
        $Run.Console | Should -Match ([regex]::Escape('Exit code 2: the summary of stream 0 is missing; its 2 subscription(s) are not confirmed; check the consolidated zip for their reports.'))
        # No subscription was skipped: all three ran this time.
        $Run.Console | Should -Match '(?m)^Subscriptions Skipped:\s+0 \(already completed\)' -Because $Run.Console
        $Run.Console | Should -Match '(?m)^Subscriptions Processed: 3\s*$' -Because $Run.Console
        $Run.ZipCount | Should -Be 1 -Because $Run.Console
        $Run.RunSummary | Should -Match '(?m)^  Failed subscriptions\s+: 0\s*$' -Because $Run.RunSummary
        $Run.MainSummary | Should -Match ([regex]::Escape('The summary of stream 0 is missing.</b> Its 2 subscription(s) are not confirmed')) -Because $Run.Console
        $Run.MainSummary | Should -Not -Match 'failed to process' -Because 'no subscription failed'
        # The resume state is kept, and nothing is put on the retry list.
        $Run.StateKept | Should -BeTrue -Because $Run.Console
        $Run.FailedIds.Count | Should -Be 0 -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
    }

    It 'two streams with -Resume: an unreadable stream summary names only the subscriptions the stream ran this time as not confirmed' {
        # Stream-0 holds Sub A then Sub C; its resume file says Sub A is done,
        # so this run it runs only Sub C.
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -CorruptStreamSummary -Resume -Stream0Completed @($script:SubA.Id)
        $Run.Console | Should -Match '\[stream-0\] skipping \(already completed\): Sub A' -Because $Run.Console
        $Run.Console | Should -Match 'Stream Summary Unreadable:\s+stream-0 \(1 subscription\(s\) not confirmed; check the consolidated zip\)' -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('Exit code 2: the summary of stream 0 could not be read; its 1 subscription(s) are not confirmed; check the consolidated zip for their reports.'))
        $Run.Console | Should -Match '(?m)^Subscriptions Skipped:\s+1 \(already completed\)' -Because $Run.Console
        $Run.Console | Should -Match '(?m)^Subscriptions Processed: 2\s*$' -Because $Run.Console
        $Run.RunSummary | Should -Match ([regex]::Escape('  Exit code 2: the summary of stream 0 could not be read; its 1 subscription(s) are not confirmed; check the consolidated zip for their reports.')) -Because $Run.RunSummary
        $Run.MainSummary | Should -Match ([regex]::Escape('The summary of stream 0 could not be read.</b> Its 1 subscription(s) are not confirmed')) -Because $Run.Console
        $Run.StateKept | Should -BeTrue -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
    }

    It 'two streams: the zips of a stream whose summary could not be read do not hide the missing zip of a subscription that reported success' {
        # Stream-0 (Sub A, Sub C) writes two zips but its summary cannot be
        # read; stream 1 runs Sub B (one zip) but reports Sub X, which has no
        # zip. Three zips for one success must not pass the check.
        $SubX = [pscustomobject]@{ Name = 'Sub X'; Id = [guid]::new(('0' * 31) + 'e').ToString(); Count = 1 }
        $Forged = [pscustomobject]@{ Status = 'ok'; ResourceCounts = @($SubX); Failed = @() } | ConvertTo-Json -Depth 5
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -CorruptStreamSummary -Stream1SummaryJson $Forged
        $Run.Console | Should -Match '\[stream-1\] done: Sub B' -Because $Run.Console
        $Run.Console | Should -Not -Match 'verification: OK' -Because $Run.Console
        $Run.Console | Should -Match 'Per-subscription output verification failed\.' -Because $Run.Console
        $Run.Console | Should -Match ('(?m)^\s*- Sub X \({0}\) \[1 resources\]' -f [regex]::Escape($SubX.Id)) -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('Exit code 2: a report is missing (verification gap, see Per-subscription output verification failed); no consolidated zip was made.'))
        $Run.ZipCount | Should -Be 0 -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
    }

    It 'two streams: a subscription whose named zip is gone fails the check, though other fresh zips are present' {
        # Stream 1 runs Sub B but reports Sub X with the zip its inner script
        # named, and that zip is not on disk (as when antivirus removes it
        # after it was written). Stream-0's zips (Sub A, Sub C, summary
        # unreadable) and Sub B's zip are fresh, so only the path match can
        # find the gap.
        $SubX = [pscustomobject]@{ Name = 'Sub X'; Id = [guid]::new(('0' * 31) + 'e').ToString(); Count = 1; Zip = '{Reports}/SubX/ResourcesReport_gone.zip' }
        $Forged = [pscustomobject]@{ Status = 'ok'; ResourceCounts = @($SubX); Failed = @() } | ConvertTo-Json -Depth 5
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -CorruptStreamSummary -Stream1SummaryJson $Forged
        $Run.Console | Should -Match '\[stream-1\] done: Sub B' -Because $Run.Console
        $Run.Console | Should -Not -Match 'verification: OK' -Because $Run.Console
        $Run.Console | Should -Match 'Per-subscription output verification failed\.' -Because $Run.Console
        $Run.Console | Should -Match ('(?m)^\s*- Sub X \({0}\) \[1 resources\]' -f [regex]::Escape($SubX.Id)) -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('Exit code 2: a report is missing (verification gap, see Per-subscription output verification failed); no consolidated zip was made.'))
        $Run.ZipCount | Should -Be 0 -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
    }

    It 'two streams: the verification-gap stop does not count a stream with no summary file as a failed subscription' {
        # Stream 1 reports four subscriptions that worked; only three reports
        # are on disk, so the run stops at the output verification.
        $Phantoms = @('6', '7', '8', '9' | ForEach-Object { [pscustomobject]@{ Name = ('Sub {0}' -f $_); Id = [guid]::new(('0' * 31) + $_).ToString(); Count = 1 } })
        $Forged = [pscustomobject]@{ Status = 'ok'; ResourceCounts = $Phantoms; Failed = @() } | ConvertTo-Json -Depth 5
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -MissingStreamSummary -Stream1SummaryJson $Forged
        $Run.Console | Should -Match 'Per-subscription output verification failed\.' -Because $Run.Console
        $Run.Console | Should -Not -Match 'Subscriptions Failed:' -Because $Run.Console
        $Run.Console | Should -Not -Match 'ERROR lines above' -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('Exit code 2: the summary of stream 0 is missing; its 2 subscription(s) are not confirmed; no consolidated zip was made.'))
        $Run.ZipCount | Should -Be 0 -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
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
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
    }

    # With two streams the session runs no inventory itself, so only the
    # wrapper's own exit sets $LASTEXITCODE there.
    It 'inside a PowerShell session: a clean run with 2 streams sets $LASTEXITCODE to 0 where the session held 1, and the session stays open' {
        $Session = Invoke-SessionRun -Subs @($script:SubA, $script:SubB) -Lines @('$global:LASTEXITCODE = 1', '{Run}', '"after: $LASTEXITCODE"', '"session still open"', 'exit 0')
        $Session.Console | Should -Match '2 subscription\(s\), 2 total resource\(s\), 0 empty, 0 failed'
        $Session.After | Should -Be @('after: 0') -Because $Session.Console
        $Session.Open | Should -BeTrue
        $Session.ExitCode | Should -Be 0
    }

    It 'inside a PowerShell session: after a run that stopped with exit 1, the next clean run with 2 streams reads 0' {
        # The first run finds no Az modules on the session's module path and
        # stops with exit 1 at the wrapper's module check.
        $Session = Invoke-SessionRun -Subs @($script:SubA, $script:SubB) -Lines @(
            '$Saved = $env:PSModulePath'
            '$env:PSModulePath = (New-Item -ItemType Directory -Force -Path (Join-Path $HOME "no-modules")).FullName'
            '{Run}'
            '"after1: $LASTEXITCODE"'
            '$env:PSModulePath = $Saved'
            '{Run}'
            '"after2: $LASTEXITCODE"'
            '"session still open"'
            'exit 0'
        )
        $Session.Console | Should -Match 'Required Az submodule\(s\) not found'
        $Session.After | Should -Be @('after1: 1', 'after2: 0') -Because $Session.Console
        $Session.Open | Should -BeTrue
    }

    It 'pwsh -File: a clean run with 2 streams exits 0' {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2
        $Run.Console | Should -Match '\[stream-1\] done: Sub B'
        $Run.FailedIds.Count | Should -Be 0
        $Run.ExitCode | Should -Be 0
    }
}
