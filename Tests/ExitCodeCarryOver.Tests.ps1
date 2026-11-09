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
# With RemoveRoot, the wrapper's own transcript cannot start (a running one
# would make the folder again on its next line), and the inventory root is
# removed when the wrapper reads the zip a subscription's inner script named,
# right after that script returned with success: as when storage is evicted
# or a mount drops at that point.
if ((Get-RdaStandInScenario).RemoveRoot -and -not $Global:RdaStandInRootBreakpoint)
{
    $Global:RdaStandInRootBreakpoint = $true
    $null = Set-PSBreakpoint -Variable ZipOutputFile -Mode Read -Action {
        $Reader = @(Get-PSCallStack)[1]
        $Root = Join-Path $HOME 'InventoryReports'
        if ($Reader.ScriptName -like '*Run-AllSubscriptions.ps1' -and (Test-Path -LiteralPath $Root))
        {
            Remove-Item -LiteralPath $Root -Recurse -Force
        }
    }
}
# With NarrationFail, the wrapper's "Resources collected" line cannot be
# written (as when the transcript's folder is gone), after its subscription
# worked.
if ((Get-RdaStandInScenario).NarrationFail)
{
    function Write-Host
    {
        if (([string]$args[0]) -like 'Resources collected:*' -and @(Get-PSCallStack)[1].ScriptName -like '*Run-AllSubscriptions.ps1')
        {
            $script:NarrationBroken = $true
            throw 'stand-in: the transcript cannot be written'
        }
        Microsoft.PowerShell.Utility\Write-Host @args
    }
    # With VerboseFail as well (a run with -Verbose), the wrapper's next
    # verbose line after that failed write cannot be written either.
    if ((Get-RdaStandInScenario).VerboseFail)
    {
        function Write-Verbose
        {
            [CmdletBinding()] param([Parameter(Position = 0, ValueFromPipeline = $true)][string]$Message)
            if ($script:NarrationBroken -and @(Get-PSCallStack)[1].ScriptName -like '*Run-AllSubscriptions.ps1')
            {
                $script:NarrationBroken = $false
                throw 'stand-in: the transcript cannot be written (verbose)'
            }
            Microsoft.PowerShell.Utility\Write-Verbose -Message $Message
        }
    }
}
# With ResumeRemoveFail, the wrapper cannot remove the resume state file at
# the end of a clean run, with an error whose text holds braces.
if ((Get-RdaStandInScenario).ResumeRemoveFail)
{
    function Remove-Item
    {
        [CmdletBinding()] param([Parameter(Position = 0)]$Path, $LiteralPath, [switch]$Force, [switch]$Recurse)
        if (([string]$Path) -like '*.resume-state-*' -and ([string]$Path) -notlike '*-stream-*' -and @(Get-PSCallStack)[1].ScriptName -like '*Run-AllSubscriptions.ps1') { throw 'stand-in: the file is in use by {another process}' }
        Microsoft.PowerShell.Management\Remove-Item @PSBoundParameters
    }
}
# With StreamNarrationFail, a stream worker's "done:" line cannot be written
# (as when its output cannot be written), after its subscription worked.
if ((Get-RdaStandInScenario).StreamNarrationFail)
{
    function Write-Host
    {
        if (([string]$args[0]) -match '^\[stream-\d+\] done: ') { throw 'stand-in: the stream console line cannot be written' }
        Microsoft.PowerShell.Utility\Write-Host @args
    }
}
# With FailuresLogFail, the wrapper cannot read the size of stream 0's
# failures log while it reads that stream's summary.
if ((Get-RdaStandInScenario).FailuresLogFail)
{
    function Get-Item
    {
        if (([string]$args[0]) -like '*_stream-0.log' -and @(Get-PSCallStack)[1].ScriptName -like '*Run-AllSubscriptions.ps1') { throw 'stand-in: the stream failures log cannot be read' }
        Microsoft.PowerShell.Management\Get-Item @args
    }
}
# With SummaryFolderAtStart, a folder stands where stream 0's summary file
# goes when the wrapper first looks there to remove an old one (the name holds
# the run's id, so it cannot be made before the run), so the wrapper cannot
# remove it.
if ((Get-RdaStandInScenario).SummaryFolderAtStart -and -not $Global:RdaStandInSummaryBreakpoint)
{
    $Global:RdaStandInSummaryBreakpoint = $true
    $null = Set-PSBreakpoint -Variable OldSummaryPath -Mode Read -Action {
        $Path = [string](Get-Variable -Name OldSummaryPath -ValueOnly -ErrorAction SilentlyContinue)
        if ($Path -like '*.rda-stream-0-*') { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
    }
}
function Start-Transcript
{
    if ((Get-RdaStandInScenario).RemoveRoot -and @(Get-PSCallStack)[1].ScriptName -like '*Run-AllSubscriptions.ps1') { throw 'stand-in: the transcript cannot start' }
    Microsoft.PowerShell.Host\Start-Transcript @args
}
function Get-AzContext { [CmdletBinding()] param([switch]$ListAvailable) Get-RdaStandInContext }
function Set-AzContext { [CmdletBinding()] param($Subscription, $Tenant, $Context, $Scope) if ($Subscription) { $script:ContextSub = [string]$Subscription }; Get-RdaStandInContext }
# Only a stream worker imports the context. The scenario's Plant entries for
# that stream then set what its summary file holds, once the wrapper has
# started the stream: Text (this text, read-only, so the stream cannot
# replace it), Folder (a folder, so the stream can write no summary, as when
# its job dies before the end), Freeze (a file already there is made
# read-only, else a folder) or OtherRun (another wrapper run with the same
# inventory root, at work at the same time, writes its own stream 0 summary
# and a report zip there).
function Import-AzContext
{
    [CmdletBinding()] param($Path)
    $Worker = @(Get-PSCallStack | Where-Object { $_.ScriptName -like '*Run-AllSubscriptions.Stream.ps1' -and $null -ne $_.InvocationInfo.BoundParameters -and $_.InvocationInfo.BoundParameters.ContainsKey('StreamSummaryPath') }) | Select-Object -First 1
    if ($null -ne $Worker)
    {
        $Bound = $Worker.InvocationInfo.BoundParameters
        # ImportFailStream: that stream cannot import the context, so it
        # does not start.
        if ([string](Get-RdaStandInScenario).ImportFailStream -eq [string]$Bound['StreamId']) { throw 'stand-in: the context snapshot cannot be imported' }
        $SummaryPath = [string]$Bound['StreamSummaryPath']
        foreach ($Plant in @((Get-RdaStandInScenario).Plant | Where-Object { $null -ne $_ -and [string]$_.Stream -eq [string]$Bound['StreamId'] }))
        {
            $Kind = [string]$Plant.Kind
            if ($Kind -eq 'Freeze') { $Kind = if (Test-Path -LiteralPath $SummaryPath -PathType Leaf) { 'Keep' } else { 'Folder' } }
            if ($Kind -eq 'Folder') { New-Item -ItemType Directory -Path $SummaryPath -Force | Out-Null }
            if ($Kind -eq 'Text')
            {
                # {Reports} in the text stands for this run's inventory root,
                # {RunId} for this run's id (the worker is given it).
                $ReportsText = (ConvertTo-Json -InputObject ([string]$Bound['InventoryRoot'])).Trim('"')
                Set-Content -LiteralPath $SummaryPath -Value ([string]$Plant.Text).Replace('{Reports}', $ReportsText).Replace('{RunId}', [string]$Bound['RunId']) -Encoding utf8
            }
            if ($Kind -eq 'OtherRun')
            {
                $Root = [string]$Bound['InventoryRoot']
                $OtherDir = New-Item -ItemType Directory -Path (Join-Path $Root 'ResourcesReport_otherrun') -Force
                Set-Content -LiteralPath (Join-Path $OtherDir.FullName 'ResourcesReport_otherrun.zip') -Value 'another run''s report' -Encoding utf8
                Set-Content -LiteralPath (Join-Path $Root '.rda-stream-0-99999999-0000-0000-0000-000000000000-summary.json') -Value '{"RunId":"99999999-0000-0000-0000-000000000000","StreamId":"0","Status":"ok","ResourceCounts":[],"Failed":[]}' -Encoding utf8
            }
            if ($Kind -eq 'Text' -or $Kind -eq 'Keep') { [System.IO.File]::SetUnixFileMode($SummaryPath, [System.IO.UnixFileMode]'UserRead, GroupRead, OtherRead') }
        }
    }
    Get-RdaStandInContext
}
function Save-AzContext { [CmdletBinding()] param($Path, [switch]$Force) Set-Content -LiteralPath $Path -Value '{}' }
function Disable-AzContextAutosave { [CmdletBinding()] param($Scope) }
function Get-AzContextAutosaveSetting { [CmdletBinding()] param($Scope) [pscustomobject]@{ Mode = 'Process'; ContextFile = 'None'; CacheFile = 'None' } }
function Connect-AzAccount { [CmdletBinding()] param($Tenant, [switch]$UseDeviceAuthentication) throw 'stand-in: no sign-in expected' }
function Get-AzAccessToken
{
    [CmdletBinding()] param($TenantId, $ResourceUrl, [switch]$AsSecureString, $ResourceTypeName)
    # With ConsumptionTokenFail, the token check before the consumption phase
    # gets no token, so that phase is skipped for sign-in (the '(auth)' row).
    if ((Get-RdaStandInScenario).ConsumptionTokenFail -and @(Get-PSCallStack | Where-Object { $_.FunctionName -eq 'Test-DataPlaneAuthReady' }).Count -gt 0) { throw 'stand-in: no token for the consumption phase' }
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
        # started for one of the scenario's failing subscriptions.
        $Compute = @'
$FailSub = @((Get-Content -LiteralPath $env:RDA_STANDIN_AZURE -Raw | ConvertFrom-Json).FailSub | Where-Object { $_ })
if ($FailSub.Count -gt 0)
{
    foreach ($Frame in @(Get-PSCallStack))
    {
        $Bound = $Frame.InvocationInfo.BoundParameters
        if ($Frame.ScriptName -like '*ResourceInventory.ps1' -and $null -ne $Bound -and $Bound.ContainsKey('SubscriptionID') -and $FailSub -contains [string]$Bound['SubscriptionID'])
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
        # Az.Billing answers the wrapper's up-front consumption access check
        # (runs without -SkipConsumption only): access is confirmed.
        $Billing = 'function Get-UsageAggregates { [CmdletBinding()] param($ReportedStartTime, $ReportedEndTime, $AggregationGranularity, $ShowDetails, $ContinuationToken) }'
        foreach ($Module in @(@{ Name = 'Az.Accounts'; Body = $Accounts }, @{ Name = 'Az.Compute'; Body = $Compute }, @{ Name = 'Az.Monitor'; Body = '' }, @{ Name = 'Az.Billing'; Body = $Billing }))
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
            param([object[]]$Subs, [string[]]$FailSub = @(), [int]$Streams = 1, [int]$PriorExitCode = -1, [string]$CollectorFailSub = '', [switch]$CorruptStreamSummary, [string]$StreamSummaryJson = '', [switch]$MissingStreamSummary, [string]$Stream1SummaryJson = '', [switch]$Resume, [string[]]$Stream0Completed = @(), [switch]$RemoveRoot, [string]$StaleStreamSummaryJson = '', [switch]$StreamSummaryFolderBeforeRun, [string]$ImportFailStream = '', [switch]$NarrationFail, [switch]$VerboseFail, [switch]$FailuresLogFail, [switch]$OtherRun, [switch]$PinnedCompute, [switch]$StreamNarrationFail, [switch]$ResumeRemoveFail)
            $CaseDir = Join-Path $script:WorkDir ([guid]::NewGuid().ToString('N').Substring(0, 8))
            $CaseHome = Join-Path $CaseDir 'home'
            New-Item -ItemType Directory -Path $CaseHome -Force | Out-Null
            # What the streams' summary files hold once the wrapper has
            # started the streams (see Import-AzContext in the stand-in).
            $Plant = @()
            if ($MissingStreamSummary)
            {
                # A folder where stream 0's summary file goes: the stream
                # cannot write its summary, so the wrapper finds no summary
                # file for it (as when its job dies before the end).
                $Plant += [pscustomobject]@{ Stream = '0'; Kind = 'Folder' }
            }
            if ($StaleStreamSummaryJson)
            {
                # Stream 0's summary file from an earlier run, left on disk
                # before this run starts, under that run's name ({RunId} in
                # the text is that run's id). Stream 0 then cannot write its
                # own summary: a file still there is made read-only, else a
                # folder takes its place.
                $Reports = New-Item -ItemType Directory -Path (Join-Path $CaseHome 'InventoryReports') -Force
                $EarlierRunId = [guid]::NewGuid().ToString()
                Set-Content -LiteralPath (Join-Path $Reports.FullName ('.rda-stream-0-{0}-summary.json' -f $EarlierRunId)) -Value $StaleStreamSummaryJson.Replace('{RunId}', $EarlierRunId) -Encoding utf8
                $Plant += [pscustomobject]@{ Stream = '0'; Kind = 'Freeze' }
            }
            # StreamSummaryFolderBeforeRun: a folder where stream 0's summary
            # file goes, there when the wrapper starts to remove old
            # summaries, so the wrapper cannot remove it (see
            # SummaryFolderAtStart in the stand-in).
            if ($OtherRun)
            {
                $Plant += [pscustomobject]@{ Stream = '0'; Kind = 'OtherRun' }
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
                $Plant += [pscustomobject]@{ Stream = '1'; Kind = 'Text'; Text = $Stream1SummaryJson }
            }
            if ($CorruptStreamSummary)
            {
                # Stream 0's summary file is text that is not JSON and cannot
                # be written, so the stream cannot replace it and the wrapper
                # finds it but cannot read it.
                $Plant += [pscustomobject]@{ Stream = '0'; Kind = 'Text'; Text = 'not json' }
            }
            elseif ($StreamSummaryJson)
            {
                # The same, with a summary the wrapper can read: stream 0 then
                # reports what this text says, not what it did.
                $Plant += [pscustomobject]@{ Stream = '0'; Kind = 'Text'; Text = $StreamSummaryJson }
            }
            $Scenario = Join-Path $CaseDir 'scenario.json'
            [pscustomobject]@{ Tenant = $script:Tenant; Subscriptions = @($Subs); FailSub = @($FailSub); CollectorFailSub = $CollectorFailSub; RemoveRoot = [bool]$RemoveRoot; Plant = @($Plant); ImportFailStream = $ImportFailStream; NarrationFail = [bool]$NarrationFail; VerboseFail = [bool]$VerboseFail; FailuresLogFail = [bool]$FailuresLogFail; StreamNarrationFail = [bool]$StreamNarrationFail; ResumeRemoveFail = [bool]$ResumeRemoveFail; SummaryFolderAtStart = [bool]$StreamSummaryFolderBeforeRun } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Scenario -Encoding utf8

            $WrapperArgs = @('-TenantID', $script:Tenant, '-SkipMetrics', '-SkipConsumption', '-ParallelStreams', [string]$Streams)
            if ($Resume) { $WrapperArgs += '-Resume' }
            # VerboseFail runs the wrapper with -Verbose.
            if ($VerboseFail) { $WrapperArgs += '-Verbose' }
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
            $ModulePath = $script:Modules
            if ($PinnedCompute)
            {
                # The stand-in modules, with an Az.Compute whose manifest asks
                # for exactly Az.Accounts 5.5.3, older than the tool supports.
                $ModulePath = Join-Path $CaseDir 'modules'
                Copy-Item -LiteralPath $script:Modules -Destination $ModulePath -Recurse -Force
                Set-Content -LiteralPath (Join-Path $ModulePath 'Az.Compute/99.0.0/Az.Compute.psd1') -Value "@{ ModuleVersion = '99.0.0'; RootModule = 'Az.Compute.psm1'; FunctionsToExport = '*'; RequiredModules = @(@{ ModuleName = 'Az.Accounts'; RequiredVersion = '5.5.3' }) }" -Encoding utf8
            }
            $Info.Environment['PSModulePath'] = $ModulePath
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
            $InnerZips = @()
            if ($OuterZip.Count -eq 1)
            {
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                $Zip = [System.IO.Compression.ZipFile]::OpenRead($OuterZip[0].FullName)
                try
                {
                    $InnerZips = @($Zip.Entries | Where-Object { $_.FullName -like '*.zip' } | ForEach-Object { $_.FullName })
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
                InnerZips  = $InnerZips
                Root       = Join-Path $CaseHome 'InventoryReports'
            }
        }

        # One pwsh session (`pwsh -Command -`, its lines on stdin, as typed at a
        # prompt) with a fresh home. {Run} in a line becomes the wrapper call
        # with -ParallelStreams $Streams; {RunConsumption} is the same call
        # without -SkipConsumption. With -ConsumptionTokenFail the consumption
        # phase gets no token (see Get-AzAccessToken in the stand-in). Returns
        # the session's exit code and the lines it printed.
        function script:Invoke-SessionRun
        {
            param([object[]]$Subs, [string[]]$Lines, [int]$Streams = 2, [switch]$ConsumptionTokenFail)
            $CaseDir = Join-Path $script:WorkDir ([guid]::NewGuid().ToString('N').Substring(0, 8))
            $CaseHome = Join-Path $CaseDir 'home'
            New-Item -ItemType Directory -Path $CaseHome -Force | Out-Null
            $Scenario = Join-Path $CaseDir 'scenario.json'
            [pscustomobject]@{ Tenant = $script:Tenant; Subscriptions = @($Subs); FailSub = ''; ConsumptionTokenFail = [bool]$ConsumptionTokenFail } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Scenario -Encoding utf8
            $Call = "& '{0}' -TenantID '{1}' -SkipMetrics -SkipConsumption -ParallelStreams {2}" -f ($script:Wrapper -replace "'", "''"), $script:Tenant, $Streams
            $ConsumptionCall = "& '{0}' -TenantID '{1}' -SkipMetrics -ParallelStreams {2}" -f ($script:Wrapper -replace "'", "''"), $script:Tenant, $Streams

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
            foreach ($Line in $Lines) { $Proc.StandardInput.WriteLine($Line.Replace('{RunConsumption}', $ConsumptionCall).Replace('{Run}', $Call)) }
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
        # Stream 0 (Sub A) reports Sub A and two more subscriptions that
        # worked, with a collector failure and a Metrics sign-in skip, and
        # names no zip for any of them, so reports are missing.
        $SubX = [guid]::new(('0' * 31) + 'e').ToString()
        $SubY = [guid]::new(('0' * 31) + 'f').ToString()
        $Forged = [pscustomobject]@{
            RunId             = '{RunId}'
            StreamId          = '0'
            Status            = 'ok'
            ResourceCounts    = @([pscustomobject]@{ Name = $script:SubA.Name; Id = $script:SubA.Id; Count = 1 }, [pscustomobject]@{ Name = 'Sub X'; Id = $SubX; Count = 1 }, [pscustomobject]@{ Name = 'Sub Y'; Id = $SubY; Count = 1 })
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

    It 'two streams with -Resume: a stream that cannot start names as failed only the subscriptions it would have run, not those its resume file lists as done' {
        # Stream-0 holds Sub A then Sub C; its resume file says Sub A is done.
        # Its context import fails, so it runs nothing.
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -Resume -Stream0Completed @($script:SubA.Id) -ImportFailStream '0'
        $Run.Console | Should -Match '\[stream-0\] FATAL: could not import Az context' -Because $Run.Console
        $Run.Console | Should -Match '\[stream-1\] done: Sub B' -Because $Run.Console
        $Run.Console | Should -Match '(?m)^Subscriptions Failed:\s+1 \(Sub C \(stream-0: stream did not start: Az context import failed\)\)\s*$' -Because $Run.Console
        $Run.Console | Should -Match '(?m)^Subscriptions Skipped:\s+1 \(already completed\)' -Because $Run.Console
        $Run.Console | Should -Match '(?m)^Subscriptions Processed: 2\s*$' -Because $Run.Console
        $Run.ZipCount | Should -Be 1 -Because $Run.Console
        $Run.RunSummary | Should -Match ('(?m)^  - {0} \({1}\)\s*$' -f [regex]::Escape($script:SubC.Name), [regex]::Escape($script:SubC.Id)) -Because $Run.RunSummary
        $Run.RunSummary | Should -Not -Match ([regex]::Escape($script:SubA.Id)) -Because 'Sub A was done in an earlier run and was not run or failed this time'
        $Run.MainSummary | Should -Not -Match ([regex]::Escape($script:SubA.Name)) -Because 'Sub A did not fail this run'
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
    }

    It 'two streams without -Resume: a stream that cannot start names every subscription of its slice as failed' {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -ImportFailStream '0'
        $Run.Console | Should -Match '(?m)^Subscriptions Failed:\s+2 \(Sub A \(stream-0: .+\), Sub C \(stream-0: .+\)\)\s*$' -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
    }

    It 'two streams: the zips of a stream whose summary could not be read do not hide the missing zip of a subscription that reported success' {
        # Stream-0 (Sub A, Sub C) writes two zips but its summary cannot be
        # read; stream 1 runs Sub B (one zip) but reports Sub X too, which has
        # no zip (Sub B's row names none either). Three zips for two
        # successes must not pass the check.
        $SubX = [pscustomobject]@{ Name = 'Sub X'; Id = [guid]::new(('0' * 31) + 'e').ToString(); Count = 1 }
        $RowB = [pscustomobject]@{ Name = $script:SubB.Name; Id = $script:SubB.Id; Count = 1 }
        $Forged = [pscustomobject]@{ RunId = '{RunId}'; StreamId = '1'; Status = 'ok'; ResourceCounts = @($RowB, $SubX); Failed = @() } | ConvertTo-Json -Depth 5
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
        # Stream 1 runs Sub B but also reports Sub X with the zip its inner
        # script named, and that zip is not on disk (as when antivirus
        # removes it after it was written). Stream-0's zips (Sub A, Sub C,
        # summary unreadable) and Sub B's zip are fresh, so only the path
        # match can find Sub X's gap.
        $SubX = [pscustomobject]@{ Name = 'Sub X'; Id = [guid]::new(('0' * 31) + 'e').ToString(); Count = 1; Zip = '{Reports}/SubX/ResourcesReport_gone.zip' }
        $RowB = [pscustomobject]@{ Name = $script:SubB.Name; Id = $script:SubB.Id; Count = 1 }
        $Forged = [pscustomobject]@{ RunId = '{RunId}'; StreamId = '1'; Status = 'ok'; ResourceCounts = @($RowB, $SubX); Failed = @() } | ConvertTo-Json -Depth 5
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -CorruptStreamSummary -Stream1SummaryJson $Forged
        $Run.Console | Should -Match '\[stream-1\] done: Sub B' -Because $Run.Console
        $Run.Console | Should -Not -Match 'verification: OK' -Because $Run.Console
        $Run.Console | Should -Match 'Per-subscription output verification failed\.' -Because $Run.Console
        $Run.Console | Should -Match ('(?m)^\s*- Sub X \({0}\) \[1 resources\]' -f [regex]::Escape($SubX.Id)) -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('Exit code 2: a report is missing (verification gap, see Per-subscription output verification failed); no consolidated zip was made.'))
        $Run.ZipCount | Should -Be 0 -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
    }

    It 'sequential: an inventory folder that is gone after a subscription worked is a verification gap, not a clean run' {
        # Sub A's inner script writes its report and returns with success;
        # then the whole inventory root, with that report, is gone. The
        # wrapper runs without its transcript, which would make the folder
        # again.
        $Run = Invoke-CarryOverRun -Subs @($script:SubA) -RemoveRoot
        $Run.Console | Should -Match 'WARNING: Could not start wrapper transcript' -Because $Run.Console
        $Run.Console | Should -Match 'Completed subscription: Sub A' -Because $Run.Console
        $Run.Console | Should -Match 'Per-subscription output verification failed\.' -Because $Run.Console
        $Run.Console | Should -Match 'The inventory folder .+ is gone, so every report under it is lost, with its resume state: the next run collects every subscription again\.' -Because $Run.Console
        $Run.Console | Should -Match ('(?m)^\s*- Sub A \({0}\) \[1 resources\]' -f [regex]::Escape($script:SubA.Id)) -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('Exit code 2: a report is missing (verification gap, see Per-subscription output verification failed); no consolidated zip was made.'))
        $Run.Console | Should -Not -Match 'Exit code 0' -Because $Run.Console
        $Run.ZipCount | Should -Be 0 -Because $Run.Console
        # The resume state was in the folder too, so the next -Resume run
        # starts over and collects Sub A again.
        $Run.StateKept | Should -BeFalse -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
    }

    It '<Case>: a console line that cannot be written after a subscription worked does not make it failed' -ForEach @(
        @{ Case = 'sequential'; Streams = 1 }
        @{ Case = 'one subscription with -ParallelStreams'; Streams = 2 }
    ) {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA) -Streams $Streams -NarrationFail
        $Run.Console | Should -Not -Match 'ERROR processing subscription' -Because $Run.Console
        $Run.Console | Should -Not -Match 'Subscriptions Failed:' -Because $Run.Console
        $Run.Console | Should -Match 'Per-subscription output verification: OK' -Because $Run.Console
        $Run.FailedIds.Count | Should -Be 0 -Because $Run.Console
        $Run.ZipCount | Should -Be 1 -Because $Run.Console
        $Run.ExitCode | Should -Be 0 -Because $Run.Console
    }

    It '<Case> with -Verbose: the note about that failed line cannot make the subscription failed either' -ForEach @(
        @{ Case = 'sequential'; Streams = 1 }
        @{ Case = 'one subscription with -ParallelStreams'; Streams = 2 }
    ) {
        # The verbose note the guard writes about the failed line cannot be
        # written either (the same broken transcript).
        $Run = Invoke-CarryOverRun -Subs @($script:SubA) -Streams $Streams -NarrationFail -VerboseFail
        $Run.Console | Should -Not -Match 'ERROR processing subscription' -Because $Run.Console
        $Run.Console | Should -Not -Match 'Subscriptions Failed:' -Because $Run.Console
        $Run.Console | Should -Match 'Per-subscription output verification: OK' -Because $Run.Console
        $Run.FailedIds.Count | Should -Be 0 -Because $Run.Console
        $Run.ZipCount | Should -Be 1 -Because $Run.Console
        $Run.ExitCode | Should -Be 0 -Because $Run.Console
    }

    It 'two streams: a console line a stream cannot write after its subscription worked does not make it failed' {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -StreamNarrationFail
        $Run.Console | Should -Not -Match 'ERROR processing' -Because $Run.Console
        $Run.Console | Should -Not -Match 'Subscriptions Failed:' -Because $Run.Console
        $Run.Console | Should -Match 'Per-subscription output verification: OK \(each of the 2 successful sub\(s\) has its zip' -Because $Run.Console
        $Run.FailedIds.Count | Should -Be 0 -Because $Run.Console
        $Run.ZipCount | Should -Be 1 -Because $Run.Console
        $Run.ExitCode | Should -Be 0 -Because $Run.Console
    }

    It 'two streams: the verification-gap stop does not count a stream with no summary file as a failed subscription' {
        # Stream 1 (Sub B) reports Sub B and four more subscriptions that
        # worked, with no zip named, so the run stops at the output
        # verification.
        $Phantoms = @('6', '7', '8', '9' | ForEach-Object { [pscustomobject]@{ Name = ('Sub {0}' -f $_); Id = [guid]::new(('0' * 31) + $_).ToString(); Count = 1 } })
        $RowB = [pscustomobject]@{ Name = $script:SubB.Name; Id = $script:SubB.Id; Count = 1 }
        $Forged = [pscustomobject]@{ RunId = '{RunId}'; StreamId = '1'; Status = 'ok'; ResourceCounts = @($RowB) + $Phantoms; Failed = @() } | ConvertTo-Json -Depth 5
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -MissingStreamSummary -Stream1SummaryJson $Forged
        $Run.Console | Should -Match 'Per-subscription output verification failed\.' -Because $Run.Console
        $Run.Console | Should -Not -Match 'Subscriptions Failed:' -Because $Run.Console
        $Run.Console | Should -Not -Match 'ERROR lines above' -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('Exit code 2: the summary of stream 0 is missing; its 2 subscription(s) are not confirmed; no consolidated zip was made.'))
        $Run.ZipCount | Should -Be 0 -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
    }

    It 'two streams: a stream summary left by an earlier run is not read as this run''s' {
        # An earlier run left stream 0's summary on disk ("ok", no rows, as
        # an interrupted -Resume run that skipped everything writes it). This
        # run's stream 0 then writes no summary.
        $Stale = [pscustomobject]@{ RunId = '{RunId}'; StreamId = '0'; Tenant = $script:Tenant; Status = 'ok'; Completed = @(); Failed = @(); ResourceCounts = @() } | ConvertTo-Json -Depth 5
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -StaleStreamSummaryJson $Stale
        $Run.Console | Should -Match '\[stream-0\] WARNING: no summary file' -Because $Run.Console
        # The earlier run's summary is under that run's name, which this run
        # neither reads nor removes.
        @(Get-ChildItem -LiteralPath $Run.Root -Filter '.rda-stream-0-*-summary.json' -File -Force).Count | Should -Be 1 -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('Exit code 2: the summary of stream 0 is missing; its 1 subscription(s) are not confirmed; check the consolidated zip for their reports.')) -Because $Run.Console
        $Run.Console | Should -Not -Match 'Exit code 0' -Because $Run.Console
        # The resume state is kept, and nothing is put on the retry list.
        $Run.StateKept | Should -BeTrue -Because $Run.Console
        $Run.FailedIds.Count | Should -Be 0 -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
    }

    It 'two streams: a summary another run wrote at this run''s stream summary path is not confirmed' {
        # Stream 0 runs Sub A. Its summary file holds a good row for Sub A,
        # but names another run.
        $Json = ('{{"RunId":"99999999-0000-0000-0000-000000000000","StreamId":"0","Status":"ok","ResourceCounts":[{{"Name":"Sub A","Id":"{0}","Count":1,"Zip":""}}],"Failed":[]}}' -f $script:SubA.Id)
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -StreamSummaryJson $Json
        $Run.Console | Should -Match '\[stream-0\] ERROR: summary file .+ is not this run''s summary of stream 0: it is not from this run' -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('Exit code 2: the summary of stream 0 could not be read; its 1 subscription(s) are not confirmed; check the consolidated zip for their reports.')) -Because $Run.Console
        $Run.Console | Should -Match 'Per-subscription output verification: OK \(each of the 1 successful sub\(s\) has its zip' -Because $Run.Console
        $Run.StateKept | Should -BeTrue -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
    }

    It 'two streams: another run sharing the inventory root keeps its summary, and its zip is not in this run''s consolidated zip' {
        # While this run's streams work, another run writes its stream 0
        # summary (under its own run id) and a report zip in the same
        # inventory root.
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -OtherRun
        $Run.Console | Should -Not -Match 'Stream Summary' -Because $Run.Console
        $Run.ZipCount | Should -Be 1 -Because $Run.Console
        @($Run.InnerZips | Where-Object { $_ -like '*otherrun*' }).Count | Should -Be 0 -Because ('the consolidated zip holds: ' + ($Run.InnerZips -join ', '))
        $Run.InnerZips.Count | Should -Be 2 -Because ('the consolidated zip holds: ' + ($Run.InnerZips -join ', '))
        # The other run's summary is not this run's to read or remove.
        Test-Path -LiteralPath (Join-Path $Run.Root '.rda-stream-0-99999999-0000-0000-0000-000000000000-summary.json') -PathType Leaf | Should -BeTrue
        @(Get-ChildItem -LiteralPath $Run.Root -Filter '.rda-stream-*-summary.json' -File -Force).Count | Should -Be 1 -Because 'this run removes its own summaries when it is done'
        $Run.ExitCode | Should -Be 0 -Because $Run.Console
    }

    It 'two streams: a stream summary that is <Case> is not confirmed' -ForEach @(
        @{ Case = 'an empty object'; Json = '{}' }
        @{ Case = 'null'; Json = 'null' }
        @{ Case = 'a list'; Json = '[]' }
        @{ Case = 'without a row for every subscription the stream ran'; Json = '{"RunId":"{RunId}","StreamId":"0","Status":"ok","ResourceCounts":[],"Failed":[]}' }
    ) {
        # Stream 0 runs Sub A then Sub C.
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -StreamSummaryJson $Json
        $Run.Console | Should -Match '\[stream-0\] ERROR: summary file .+ is not this run''s summary of stream 0' -Because $Run.Console
        $Run.Console | Should -Match 'Stream Summary Unreadable:\s+stream-0 \(2 subscription\(s\) not confirmed; check the consolidated zip\)' -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('Exit code 2: the summary of stream 0 could not be read; its 2 subscription(s) are not confirmed; check the consolidated zip for their reports.')) -Because $Run.Console
        $Run.Console | Should -Not -Match 'Subscriptions Failed:' -Because $Run.Console
        $Run.ZipCount | Should -Be 1 -Because $Run.Console
        $Run.StateKept | Should -BeTrue -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
    }

    It 'two streams: a stream summary whose success row has <Case> is not confirmed' -ForEach @(
        @{ Case = 'a Zip that is not a path'; Row = '"Count":1,"Zip":"{Reports}/bad\u0000name.zip"' }
        @{ Case = 'a Count below 0'; Row = '"Count":-1' }
        @{ Case = 'a Count that is not a whole number'; Row = '"Count":1.5' }
        @{ Case = 'a Count that is text'; Row = '"Count":"many"' }
        @{ Case = 'no Count'; Row = '"Zip":""' }
    ) {
        # Stream 0 runs Sub A, and its summary names Sub A with this row.
        $Json = ('{{"RunId":"{{RunId}}","StreamId":"0","Status":"ok","ResourceCounts":[{{"Name":"Sub A","Id":"{0}",{1}}}],"Failed":[]}}' -f $script:SubA.Id, $Row)
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -StreamSummaryJson $Json
        $Run.Console | Should -Match '\[stream-0\] ERROR: summary file .+ is not this run''s summary of stream 0: 1 of its success row\(s\) have a Count that is not a whole number of 0 or more, or a Zip that is not a path' -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('Exit code 2: the summary of stream 0 could not be read; its 1 subscription(s) are not confirmed; check the consolidated zip for their reports.')) -Because $Run.Console
        $Run.Console | Should -Not -Match 'Subscriptions Failed:' -Because $Run.Console
        $Run.ZipCount | Should -Be 1 -Because $Run.Console
        $Run.StateKept | Should -BeTrue -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
    }

    It 'two streams: a stream summary whose <Case> is not confirmed, and the next stream is still read' -ForEach @(
        @{ Case = 'ConsumptionRecords is text'; Extra = '"ConsumptionRecords":"abc"'; Reason = 'its ConsumptionRecords is not a whole number of 0 or more' }
        @{ Case = 'ConsumptionRecords is below 0'; Extra = '"ConsumptionRecords":-1'; Reason = 'its ConsumptionRecords is not a whole number of 0 or more' }
        @{ Case = 'ConsumptionFailedSubs is not a list'; Extra = '"ConsumptionFailedSubs":{"Id":"x"}'; Reason = 'its ConsumptionFailedSubs is not a list' }
        @{ Case = 'MetricsFailedSubs is not a list'; Extra = '"MetricsFailedSubs":"x"'; Reason = 'its MetricsFailedSubs is not a list' }
        @{ Case = 'CollectorFailures row has no Id'; Extra = '"CollectorFailures":[{"Module":"m","Message":"x"}]'; Reason = '1 of its CollectorFailures row(s) have no Id' }
        @{ Case = 'Failed row has no Reason'; Extra = '"Failed":[{"Id":"x","Name":"Sub X"}]'; Reason = '1 of its failed row(s) have no Id or Reason text' }
    ) {
        # Stream 0 runs Sub A, and its summary names Sub A with a good row;
        # one other field holds a value the worker never writes. Stream 1
        # runs Sub B.
        $Json = ('{{"RunId":"{{RunId}}","StreamId":"0","Status":"ok","ResourceCounts":[{{"Name":"Sub A","Id":"{0}","Count":1,"Zip":""}}],{1}}}' -f $script:SubA.Id, $Extra)
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -StreamSummaryJson $Json
        $Run.Console | Should -Match ('\[stream-0\] ERROR: summary file .+ is not this run''s summary of stream 0: ' + [regex]::Escape($Reason)) -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('Exit code 2: the summary of stream 0 could not be read; its 1 subscription(s) are not confirmed; check the consolidated zip for their reports.')) -Because $Run.Console
        # Stream 1 is still read: Sub B is the one success the output
        # verification checks.
        $Run.Console | Should -Match 'Per-subscription output verification: OK \(each of the 1 successful sub\(s\) has its zip' -Because $Run.Console
        $Run.Console | Should -Not -Match 'Subscriptions Failed:' -Because $Run.Console
        $Run.ZipCount | Should -Be 1 -Because $Run.Console
        $Run.StateKept | Should -BeTrue -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
    }

    It 'two streams: a throw while one stream''s summary is read keeps its results and still reads the next stream' {
        # Stream 0 runs Sub A (fails) then Sub C, so it writes a failures
        # log, and the wrapper cannot read that log's size. Stream 1 runs
        # Sub B.
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -FailSub $script:SubA.Id -FailuresLogFail
        $Run.Console | Should -Match '\[stream-0\] ERROR processing Sub A' -Because $Run.Console
        # Sub C (stream 0) and Sub B (stream 1) both count as successes, and
        # Sub A as the one failure.
        $Run.Console | Should -Match 'Per-subscription output verification: OK \(each of the 2 successful sub\(s\) has its zip' -Because $Run.Console
        $Run.Console | Should -Match '\[stream-0\] WARNING: after its results were read: stand-in: the stream failures log cannot be read' -Because $Run.Console
        $Run.Console | Should -Match '(?m)^Subscriptions Failed:\s+1 \(Sub A \(stream-0: ' -Because $Run.Console
        $Run.Console | Should -Not -Match 'Stream Summary' -Because 'both stream summaries were read'
        $Run.FailedIds | Should -Be @($script:SubA.Id)
        $Run.ZipCount | Should -Be 1 -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
    }

    It 'two streams with -Resume: a summary that names another stream is not confirmed, though the stream had nothing left to run' {
        # Stream 0 holds Sub A and Sub C, both done in an earlier run.
        $Wrong = '{"RunId":"{RunId}","StreamId":"1","Status":"ok","ResourceCounts":[],"Failed":[]}'
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -Resume -Stream0Completed @($script:SubA.Id, $script:SubC.Id) -StreamSummaryJson $Wrong
        $Run.Console | Should -Match '\[stream-0\] skipping \(already completed\): Sub C' -Because $Run.Console
        $Run.Console | Should -Match '\[stream-0\] ERROR: summary file .+ is not this run''s summary of stream 0' -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('Exit code 2: the summary of stream 0 could not be read; its 0 subscription(s) are not confirmed; check the consolidated zip for their reports.')) -Because $Run.Console
        $Run.StateKept | Should -BeTrue -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
    }

    It 'two streams: the Stream Summary Missing line says no consolidated zip was made when none was' {
        # Both subscriptions fail, so no report is written; stream 0 also
        # writes no summary.
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -FailSub @($script:SubA.Id, $script:SubB.Id) -MissingStreamSummary
        $Run.ZipCount | Should -Be 0 -Because $Run.Console
        $Run.Console | Should -Match 'No per-subscription zip files found' -Because $Run.Console
        $Run.Console | Should -Match 'Stream Summary Missing:\s+stream-0 \(1 subscription\(s\) not confirmed; no consolidated zip was made\)' -Because $Run.Console
        $Run.Console | Should -Not -Match 'check the consolidated zip' -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('Exit code 2: the summary of stream 0 is missing; its 1 subscription(s) are not confirmed; no consolidated zip was made.')) -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
    }

    It 'two streams: an old stream summary the wrapper cannot remove stops the run with exit 1 before any stream starts' {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -StreamSummaryFolderBeforeRun
        $Run.Console | Should -Match 'ERROR: could not remove the old stream summary .+\.rda-stream-0-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}-summary\.json' -Because $Run.Console
        $Run.Console | Should -Match 'Remove it by hand, then run again\.' -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('Exit code 1: an old stream summary could not be removed; no subscription was collected and no consolidated zip was made.')) -Because $Run.Console
        $Run.Console | Should -Not -Match 'queued:' -Because 'no stream may start while its old summary is still there'
        $Run.ZipCount | Should -Be 0 -Because $Run.Console
        # A setup stop before anything is collected: exit 1, not 2.
        $Run.ExitCode | Should -Be 1 -Because $Run.Console
    }

    It '<Case>: a submodule that pins an older Az.Accounts stops the run once with exit 1, before any subscription' -ForEach @(
        @{ Case = 'sequential'; Streams = 1 }
        @{ Case = 'two streams'; Streams = 2 }
    ) {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams $Streams -PinnedCompute
        $Run.Console | Should -Match ([regex]::Escape('Az.Compute 99.0.0 asks for Az.Accounts 5.5.3')) -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('Install-Module -Name Az.Compute -Repository PSGallery -Scope CurrentUser -Force')) -Because $Run.Console
        $Run.Console | Should -Not -Match 'Processing subscription|queued:' -Because 'no subscription may start'
        $Run.Console | Should -Not -Match 'ERROR processing' -Because $Run.Console
        $Run.ZipCount | Should -Be 0 -Because $Run.Console
        $Run.StateKept | Should -BeFalse -Because 'nothing was collected, so no resume state was written'
        $Run.ExitCode | Should -Be 1 -Because $Run.Console
    }

    It 'sequential: a resume state file that cannot be removed after a clean run gets its warning, though the error holds braces' {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA) -ResumeRemoveFail
        $Run.Console | Should -Match ('WARNING: Could not remove resume state file .+: ' + [regex]::Escape('stand-in: the file is in use by {another process}')) -Because $Run.Console
        $Run.Console | Should -Not -Match 'Error formatting a string' -Because $Run.Console
        $Run.ExitCode | Should -Be 0 -Because $Run.Console
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

    It 'inside a PowerShell session: after a run whose consumption was skipped for sign-in, the next clean run reads 0 and names no consumption failure or count' {
        # The first run's consumption phase gets no token, so it records the
        # '(auth)' row and ends with exit 3. The record count it leaves is set
        # by hand to 7, as a run that collected 7 records leaves it (the
        # stand-in returns no usage rows). The second run skips consumption.
        $Session = Invoke-SessionRun -Subs @($script:SubA) -Streams 1 -ConsumptionTokenFail -Lines @(
            '{RunConsumption}'
            '"after1: $LASTEXITCODE"'
            '$Global:ConsumptionRecordCount = 7'
            '"=== second run ==="'
            '{Run}'
            '"after2: $LASTEXITCODE"'
            '"session still open"'
            'exit 0'
        )
        $First, $Second = $Session.Console -split '=== second run ===', 2
        $First | Should -Match 'Consumption: SKIPPED' -Because $Session.Console
        $First | Should -Match 'Consumption Failures:' -Because $Session.Console
        $Second | Should -Match 'Completed subscription: Sub A' -Because $Session.Console
        $Second | Should -Not -Match 'Consumption Failures:' -Because 'the first run''s consumption failure is not this run''s'
        $Second | Should -Not -Match 'Consumption Records:' -Because 'the first run''s record count is not this run''s'
        $Second | Should -Not -Match 'FAILED \(auth\)' -Because $Second
        $Session.After | Should -Be @('after1: 3', 'after2: 0') -Because $Session.Console
        $Session.Open | Should -BeTrue
    }

    It 'inside a PowerShell session: a run after Remove-Module of a required Az module loads it again' {
        # The first run loads the Az modules; then one is removed from the
        # session. The next run must not take the "already loaded" shortcut.
        $Session = Invoke-SessionRun -Subs @($script:SubA) -Streams 1 -Lines @(
            '{Run}'
            '"after1: $([bool](Get-Module -Name Az.Compute))"'
            'Remove-Module -Name Az.Compute'
            '{Run}'
            '"after2: $([bool](Get-Module -Name Az.Compute))"'
            '"session still open"'
            'exit 0'
        )
        $Session.After | Should -Be @('after1: True', 'after2: True') -Because $Session.Console
        $Session.Open | Should -BeTrue
    }

    It 'pwsh -File: a clean run with 2 streams exits 0' {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2
        $Run.Console | Should -Match '\[stream-1\] done: Sub B'
        $Run.FailedIds.Count | Should -Be 0
        $Run.ExitCode | Should -Be 0
    }
}
