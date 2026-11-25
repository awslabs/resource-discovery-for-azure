# End to end: the record the resume state keeps of the subscriptions the
# up-front access check skipped as not readable (NotReadableSubscriptionIds).
#
#   - A subscription on the record that a later check can read is taken off it
#     and collected.
#   - Runs that follow one another end cleanly. After an interrupted run, after
#     a run with a failure and -ResumeFailedOnly, and after an interrupted run
#     that left only not-readable subscriptions to collect, the second of two
#     -Resume runs exits 0 without an access stop, names nothing under
#     "Not Collected", and leaves no resume state.
#   - No zip a run leaves holds the resume state file, the record or the id of
#     the not-readable subscription, with or without -Obfuscate.
#
# Every run is Run-AllSubscriptions.ps1 itself, started as its own pwsh process
# from a copy of the tool whose ResourceInventory.ps1 is a stand-in. Azure is a
# set of stand-in Az modules and an az command, found first on the module path
# and PATH of that process, which answer from a scenario file: the
# subscriptions, the ones that cannot be read, the ones that fail, and the one
# whose collection the session ends in. The process's home is a scratch folder,
# so the run writes its inventory root under it. On Windows the wrapper writes
# to C:\InventoryReports instead, so these tests do not run there.
#
# Run with: Invoke-Pester ./Tests/ResumeStateNotReadable.Tests.ps1 -Output Detailed

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
    $script:TestBase = Join-Path $TmpBase ('ResumeStateNotReadableTest_' + [guid]::NewGuid().ToString().Substring(0, 8))
    New-Item -ItemType Directory -Path $script:TestBase -Force | Out-Null
    $script:Tenant = '12345678-1234-1234-1234-123456789012'
    $script:Pwsh = Join-Path $PSHOME 'pwsh'

    # --- The tool: the wrapper and its helpers as they are, and a stand-in
    # ResourceInventory.ps1 that writes one report folder and zip per call, as
    # the real one does under the inventory root.
    $script:ToolRoot = Join-Path $script:TestBase 'tool'
    New-Item -ItemType Directory -Path $script:ToolRoot -Force | Out-Null
    foreach ($Item in @('Run-AllSubscriptions.ps1', 'Run-AllSubscriptions.Stream.ps1', 'Version.json', 'Functions', 'Extension'))
    {
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot $Item) -Destination $script:ToolRoot -Recurse -Force
    }
    $script:Wrapper = Join-Path $script:ToolRoot 'Run-AllSubscriptions.ps1'
    $StandInInner = @'
param([string]$TenantID, [string]$SubscriptionID, [switch]$RunAllSubs, [switch]$Obfuscate, [switch]$SkipMetrics, [switch]$SkipConsumption, [switch]$DeviceLogin, [int]$ConcurrencyLimit)
$Scenario = Get-Content -LiteralPath $env:RDA_STANDIN_AZURE -Raw | ConvertFrom-Json
# The session ends while this subscription is collected.
if (@($Scenario.EndSessionIds) -contains $SubscriptionID) { [Environment]::Exit(137) }
if (@($Scenario.FailIds) -contains $SubscriptionID) { throw 'stand-in failure for this subscription' }
$Root = Join-Path $HOME 'InventoryReports'
$Stamp = (Get-Date -Format 'yyyyMMddHHmmssfff') + $SubscriptionID
$Folder = Join-Path $Root ('ResourcesReport' + $Stamp)
$Stage = Join-Path $Root ('stage-' + $Stamp)
New-Item -ItemType Directory -Path $Folder, $Stage -Force | Out-Null
Set-Content -LiteralPath (Join-Path $Stage ('Inventory_ResourcesReport_{0}.json' -f $Stamp)) -Value ('{"VirtualMachines":[{"Name":"vm","Subscription":"' + $SubscriptionID + '"}]}') -Encoding utf8
Set-Content -LiteralPath (Join-Path $Stage ('ResourcesReport_{0}.html' -f $Stamp)) -Value '<html></html>' -Encoding utf8
$Zip = Join-Path $Folder ('ResourcesReport_{0}.zip' -f $Stamp)
Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $Zip -Force
Copy-Item -Path (Join-Path $Stage '*') -Destination $Folder
Remove-Item -LiteralPath $Stage -Recurse -Force
$Global:ZipOutputFile = $Zip
$Global:Resources = @(1)
$Global:ResourceCount = 1
'@
    Set-Content -LiteralPath (Join-Path $script:ToolRoot 'ResourceInventory.ps1') -Value $StandInInner -Encoding utf8

    # --- Stand-in Azure ------------------------------------------------------
    # Az.Accounts answers sign-in, context, token and subscription calls, and
    # the Resource Manager paths a run reads, by subscription: the resource
    # group list (403 when not readable), role assignments (none visible when
    # not readable) and their definitions, caller permissions (none when not
    # readable), Resource Graph resource counts and usage aggregates (one row
    # above zero).
    $script:Modules = Join-Path $script:TestBase 'modules'
    $Accounts = @'
function Get-RdaStandInScenario { Get-Content -LiteralPath $env:RDA_STANDIN_AZURE -Raw | ConvertFrom-Json }
function Get-RdaStandInContext
{
    [pscustomobject]@{
        Account      = [pscustomobject]@{ Id = 'operator@example.com'; Type = 'User' }
        Tenant       = [pscustomobject]@{ Id = (Get-RdaStandInScenario).Tenant }
        Subscription = $null
        Environment  = [pscustomobject]@{ Name = 'AzureCloud'; ResourceManagerUrl = 'https://management.azure.com/' }
    }
}
function Get-AzContext { [CmdletBinding()] param() Get-RdaStandInContext }
function Set-AzContext { [CmdletBinding()] param($Subscription, $Tenant, $Context) Get-RdaStandInContext }
function Import-AzContext { [CmdletBinding()] param($Path) Get-RdaStandInContext }
function Save-AzContext { [CmdletBinding()] param($Path, [switch]$Force) Set-Content -LiteralPath $Path -Value '{}' }
function Disable-AzContextAutosave { [CmdletBinding()] param($Scope) }
function Connect-AzAccount { [CmdletBinding()] param($Tenant, [switch]$UseDeviceAuthentication) throw 'stand-in: no sign-in expected' }
function Get-AzAccessToken
{
    [CmdletBinding()] param($TenantId, $ResourceUrl, [switch]$AsSecureString)
    $Claims = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"oid":"stand-in-caller"}')).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    [pscustomobject]@{ Token = ('e30.{0}.c2ln' -f $Claims); Type = 'Bearer'; ExpiresOn = (Get-Date).AddHours(1) }
}
function Get-AzSubscription
{
    [CmdletBinding()] param($TenantId, $SubscriptionId)
    $Scenario = Get-RdaStandInScenario
    @($Scenario.Subscriptions | ForEach-Object { [pscustomobject]@{ Id = $_.Id; SubscriptionId = $_.Id; Name = $_.Name; State = $_.State; TenantId = $Scenario.Tenant } })
}
function Invoke-AzRestMethod
{
    [CmdletBinding()] param([string]$Method = 'GET', [string]$Path, [string]$Payload)
    $Unreadable = @((Get-RdaStandInScenario).Unreadable)
    $Answer = { param([int]$Status, $Body) [pscustomobject]@{ StatusCode = $Status; Content = (ConvertTo-Json -InputObject $Body -Depth 8 -Compress); Headers = @{} } }
    $Read = @{ value = @(@{ actions = @('*/read'); notActions = @() }) }
    if ($Path -match '^/subscriptions/([^/?]+)/resourcegroups\?')
    {
        if ($Unreadable -contains $Matches[1]) { return & $Answer 403 @{ error = @{ code = 'AuthorizationFailed'; message = 'stand-in: no role' } } }
        return & $Answer 200 @{ value = @() }
    }
    if ($Path -match '^/subscriptions/([^/?]+)/providers/Microsoft\.Authorization/roleAssignments\?')
    {
        $Id = $Matches[1]
        if ($Unreadable -contains $Id) { return & $Answer 200 @{ value = @() } }
        return & $Answer 200 @{ value = @(@{ properties = @{ scope = "/subscriptions/$Id"; principalId = 'stand-in-caller'; roleDefinitionId = "/subscriptions/$Id/providers/Microsoft.Authorization/roleDefinitions/stand-in-reader" } }) }
    }
    if ($Path -match '/providers/Microsoft\.Authorization/roleDefinitions/[^/?]+\?')
    {
        return & $Answer 200 @{ properties = @{ roleName = 'Reader'; type = 'BuiltInRole'; permissions = @(@{ actions = @('*/read'); notActions = @() }) } }
    }
    if ($Path -match '^/subscriptions/([^/?]+)/providers/Microsoft\.Authorization/permissions\?')
    {
        if ($Unreadable -contains $Matches[1]) { return & $Answer 200 @{ value = @() } }
        return & $Answer 200 $Read
    }
    if ($Method -eq 'POST' -and $Path -like '/providers/Microsoft.ResourceGraph/resources*')
    {
        $Ids = @(($Payload | ConvertFrom-Json).subscriptions)
        return & $Answer 200 @{ data = @($Ids | ForEach-Object { @{ subscriptionId = $_; ResourceCount = 1 } }) }
    }
    if ($Path -match '^/subscriptions/([^/?]+)/providers/Microsoft\.Commerce/UsageAggregates\?')
    {
        return & $Answer 200 @{ value = @(@{ properties = @{ quantity = 1.5; meterCategory = 'Stand-in'; instanceData = '' } }) }
    }
    return & $Answer 404 @{ error = @{ code = 'NotFound'; message = 'stand-in: no answer for this path' } }
}
'@
    $Billing = @'
function Get-UsageAggregates
{
    [CmdletBinding()] param($ReportedStartTime, $ReportedEndTime, $AggregationGranularity, [switch]$ShowDetails, $ContinuationToken)
    [pscustomobject]@{ UsageAggregations = @(); ContinuationToken = $null }
}
'@
    foreach ($Module in @(@{ Name = 'Az.Accounts'; Body = $Accounts }, @{ Name = 'Az.Billing'; Body = $Billing }, @{ Name = 'Az.Compute'; Body = '' }, @{ Name = 'Az.Monitor'; Body = '' }))
    {
        $Dir = Join-Path $script:Modules (Join-Path $Module.Name '99.0.0')
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Dir ($Module.Name + '.psm1')) -Value $Module.Body -Encoding utf8
        Set-Content -LiteralPath (Join-Path $Dir ($Module.Name + '.psd1')) -Value ("@{{ ModuleVersion = '99.0.0'; RootModule = '{0}.psm1'; FunctionsToExport = '*' }}" -f $Module.Name) -Encoding utf8
    }

    # The az command: signed in to the scenario's tenant, with a token.
    $script:Bin = Join-Path $script:TestBase 'bin'
    New-Item -ItemType Directory -Path $script:Bin -Force | Out-Null
    $Az = @'
$Scenario = Get-Content -LiteralPath $env:RDA_STANDIN_AZURE -Raw | ConvertFrom-Json
if ($args.Count -ge 2 -and $args[0] -eq 'account' -and $args[1] -eq 'show') { [pscustomobject]@{ tenantId = $Scenario.Tenant } | ConvertTo-Json -Compress; exit 0 }
if ($args.Count -ge 2 -and $args[0] -eq 'account' -and $args[1] -eq 'get-access-token') { exit 0 }
exit 1
'@
    Set-Content -LiteralPath (Join-Path $script:Bin 'az.ps1') -Value $Az -Encoding utf8

    $script:A = @{ Id = 'sub-a'; Name = 'Sub A' }
    $script:B = @{ Id = 'sub-b'; Name = 'Sub B' }
    $script:C = @{ Id = 'sub-c'; Name = 'Sub C' }
    $script:X = @{ Id = 'sub-x-not-readable'; Name = 'Sub X' }

    # A fresh home (its InventoryReports folder is the run's inventory root) and
    # scenario for each test.
    function script:New-Case
    {
        $script:CaseHome = Join-Path $script:TestBase ([guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $script:CaseHome -Force | Out-Null
        $script:Root = Join-Path $script:CaseHome 'InventoryReports'
        $script:Scenario = Join-Path $script:CaseHome 'scenario.json'
        $script:State = Join-Path $script:Root ('.resume-state-{0}.json' -f $script:Tenant)
    }

    function script:Set-Scenario
    {
        param([object[]]$Subs, [string[]]$Unreadable = @(), [string[]]$Fail = @(), [string[]]$EndSession = @(), [string[]]$Disabled = @())
        [pscustomobject]@{
            Tenant        = $script:Tenant
            Subscriptions = @($Subs | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Name = $_.Name; State = $(if ($Disabled -contains $_.Id) { 'Disabled' } else { 'Enabled' }) } })
            Unreadable    = @($Unreadable)
            FailIds       = @($Fail)
            EndSessionIds = @($EndSession)
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:Scenario -Encoding utf8
    }

    # One run of the wrapper as its own process, stdin closed. Returns its exit
    # code and the lines it printed. A run that has not ended after
    # $TimeoutSeconds is stopped and the test fails.
    function script:Invoke-Wrapper
    {
        param([string[]]$Arguments = @(), [int]$Streams = 1, [int]$TimeoutSeconds = 300)
        $Info = [System.Diagnostics.ProcessStartInfo]::new($script:Pwsh)
        foreach ($Arg in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script:Wrapper, '-TenantID', $script:Tenant, '-ParallelStreams', [string]$Streams) + @($Arguments)) { $Info.ArgumentList.Add($Arg) }
        $Info.UseShellExecute = $false
        $Info.RedirectStandardInput = $true
        $Info.RedirectStandardOutput = $true
        $Info.RedirectStandardError = $true
        $Info.Environment['HOME'] = $script:CaseHome
        $Info.Environment['PSModulePath'] = $script:Modules
        $Info.Environment['PATH'] = $script:Bin + [IO.Path]::PathSeparator + $env:PATH
        $Info.Environment['RDA_STANDIN_AZURE'] = $script:Scenario
        $Info.Environment['NO_COLOR'] = '1'
        $Proc = [System.Diagnostics.Process]::Start($Info)
        $Proc.StandardInput.Close()
        $Out = $Proc.StandardOutput.ReadToEndAsync()
        $Err = $Proc.StandardError.ReadToEndAsync()
        if (-not $Proc.WaitForExit($TimeoutSeconds * 1000))
        {
            $Proc.Kill($true)
            throw ('The wrapper run did not end within {0} seconds.' -f $TimeoutSeconds)
        }
        $Proc.WaitForExit()
        $Text = @(([string]$Out.Result -replace "`e\[[0-9;]*m", '') -split "`r?`n")
        return [pscustomobject]@{ ExitCode = $Proc.ExitCode; Text = $Text; Error = [string]$Err.Result }
    }

    # The resume state as written, or $null when there is none.
    function script:Read-State
    {
        if (-not (Test-Path -LiteralPath $script:State)) { return $null }
        $Raw = Get-Content -LiteralPath $script:State -Raw | ConvertFrom-Json
        return [pscustomobject]@{
            Completed   = @($Raw.CompletedSubscriptionIds | Where-Object { $_ } | Sort-Object)
            Failed      = @($Raw.FailedAttempts | Where-Object { $_ } | ForEach-Object { $_.Id } | Sort-Object)
            NotReadable = @($Raw.NotReadableSubscriptionIds | Where-Object { $_ } | Sort-Object)
        }
    }

    # The lines that say a run stopped at the access check, or named a
    # subscription as not collected.
    function script:Get-AccessStopLines { param($Run) @($Run.Text | Where-Object { $_ -match 'No subscription is readable|No accessible subscriptions remain|Stopping before any work' }) }
    function script:Get-NotCollectedLines { param($Run) @($Run.Text | Where-Object { $_ -like 'Not Collected:*' }) }

    # Every entry of every zip under the inventory root, the zips inside them
    # included: { Zip; Name; Text }.
    function script:Get-ZipEntries
    {
        $Found = [System.Collections.Generic.List[object]]::new()
        $ReadArchive = {
            param([System.IO.Compression.ZipArchive]$Archive, [string]$Label)
            foreach ($Entry in @($Archive.Entries))
            {
                $Buffer = [System.IO.MemoryStream]::new()
                $Stream = $Entry.Open()
                try { $Stream.CopyTo($Buffer) } finally { $Stream.Dispose() }
                $Found.Add([pscustomobject]@{ Zip = $Label; Name = $Entry.FullName; Text = [System.Text.Encoding]::UTF8.GetString($Buffer.ToArray()) })
                if ($Entry.FullName -like '*.zip')
                {
                    $Buffer.Position = 0
                    $Inner = [System.IO.Compression.ZipArchive]::new($Buffer, [System.IO.Compression.ZipArchiveMode]::Read)
                    try { & $ReadArchive $Inner ($Label + '!' + $Entry.FullName) } finally { $Inner.Dispose() }
                }
            }
        }
        foreach ($Zip in @(Get-ChildItem -LiteralPath $script:Root -Recurse -Force -File -Filter '*.zip'))
        {
            $Archive = [System.IO.Compression.ZipFile]::OpenRead($Zip.FullName)
            try { & $ReadArchive $Archive $Zip.Name } finally { $Archive.Dispose() }
        }
        return $Found.ToArray()
    }
}

AfterAll {
    if ($script:TestBase -and (Test-Path $script:TestBase)) { Remove-Item -Path $script:TestBase -Recurse -Force }
}

Describe 'A subscription on the not-readable record that a later check can read' -Skip:$IsWindows {
    BeforeEach { script:New-Case }

    It 'is taken off the record and collected by the next -Resume, and the state clears once nothing is left' {
        # Run 1: Sub X is not readable and is skipped, Sub B fails.
        script:Set-Scenario -Subs $script:B, $script:X -Unreadable $script:X.Id -Fail $script:B.Id
        $null = script:Invoke-Wrapper -Arguments '-AllowPartialAccess'
        $State1 = script:Read-State
        $State1.NotReadable | Should -Be @($script:X.Id)
        $State1.Failed | Should -Be @($script:B.Id)

        # Run 2: Sub X can be read now; Sub B still fails, so the state is kept.
        script:Set-Scenario -Subs $script:B, $script:X -Fail $script:B.Id
        $R2 = script:Invoke-Wrapper -Arguments '-Resume', '-AllowPartialAccess'
        $State2 = script:Read-State
        @($State2.NotReadable) | Should -BeNullOrEmpty -Because 'the check of this run read Sub X'
        $State2.Completed | Should -Be @($script:X.Id)
        $State2.Failed | Should -Be @($script:B.Id)
        @($R2.Text | Where-Object { $_ -eq ('Processing subscription: {0} ({1})' -f $script:X.Name, $script:X.Id) }).Count | Should -Be 1
        $Inner = @(script:Get-ZipEntries | Where-Object { $_.Zip -like 'AllSubscriptions_*' -and $_.Name -like ('ResourcesReport_*{0}.zip' -f $script:X.Id) })
        $Inner.Count | Should -Be 1 -Because 'the report of Sub X is in the consolidated zip of run 2'

        # Run 3: Sub B works now.
        script:Set-Scenario -Subs $script:B, $script:X
        $R3 = script:Invoke-Wrapper -Arguments '-Resume', '-AllowPartialAccess'
        $R3.ExitCode | Should -Be 0
        @($R3.Text | Where-Object { $_ -eq 'Resume state cleared (clean run).' }).Count | Should -Be 1
        Test-Path -LiteralPath $script:State | Should -BeFalse
    }
}

Describe 'Two -Resume runs in a row after a not-readable subscription was skipped' -Skip:$IsWindows {
    BeforeAll {
        # Two -Resume runs; each must exit 0 without an access stop, name
        # nothing under "Not Collected" and leave no resume state.
        function script:Assert-TwoCleanResumes
        {
            foreach ($Run in 1..2)
            {
                $R = script:Invoke-Wrapper -Arguments '-Resume', '-AllowPartialAccess'
                script:Get-AccessStopLines $R | Should -BeNullOrEmpty -Because ('-Resume run {0} does not stop at the access check' -f $Run)
                $R.ExitCode | Should -Be 0 -Because ('-Resume run {0} ends cleanly' -f $Run)
                script:Get-NotCollectedLines $R | Should -BeNullOrEmpty
                Test-Path -LiteralPath $script:State | Should -BeFalse -Because ('-Resume run {0} clears the state' -f $Run)
            }
        }
    }
    BeforeEach { script:New-Case }

    It 'after an interrupted run, the second -Resume ends cleanly' {
        # Run 1: Sub X is skipped, Sub A completes, the session ends in Sub C.
        script:Set-Scenario -Subs $script:A, $script:C, $script:X -Unreadable $script:X.Id -EndSession $script:C.Id
        $R1 = script:Invoke-Wrapper -Arguments '-AllowPartialAccess'
        $R1.ExitCode | Should -Be 137
        $State1 = script:Read-State
        $State1.Completed | Should -Be @($script:A.Id)
        $State1.NotReadable | Should -Be @($script:X.Id)

        script:Set-Scenario -Subs $script:A, $script:C, $script:X -Unreadable $script:X.Id
        script:Assert-TwoCleanResumes
    }

    It 'after a run with a failure and -ResumeFailedOnly, the second -Resume ends cleanly' {
        # Run 1: Sub X is skipped, Sub B fails.
        script:Set-Scenario -Subs $script:B, $script:X -Unreadable $script:X.Id -Fail $script:B.Id
        $null = script:Invoke-Wrapper -Arguments '-AllowPartialAccess'
        $State1 = script:Read-State
        $State1.Failed | Should -Be @($script:B.Id)
        $State1.NotReadable | Should -Be @($script:X.Id)

        # Run 2: -ResumeFailedOnly; Sub B works now.
        script:Set-Scenario -Subs $script:B, $script:X -Unreadable $script:X.Id
        $R2 = script:Invoke-Wrapper -Arguments '-ResumeFailedOnly', '-AllowPartialAccess'
        $R2.ExitCode | Should -Be 0
        @(script:Get-NotCollectedLines $R2 | Where-Object { $_.Contains($script:X.Name) }) | Should -BeNullOrEmpty
        Test-Path -LiteralPath $script:State | Should -BeFalse

        script:Assert-TwoCleanResumes
    }

    It 'when the interrupted run left only not-readable subscriptions to collect, the second -Resume ends cleanly' {
        # Run 1: Sub X is skipped, Sub A completes, the session ends in Sub C,
        # which is disabled afterwards. Every subscription still to collect is
        # not readable.
        script:Set-Scenario -Subs $script:A, $script:X, $script:C -Unreadable $script:X.Id -EndSession $script:C.Id
        $null = script:Invoke-Wrapper -Arguments '-AllowPartialAccess'
        $State1 = script:Read-State
        $State1.Completed | Should -Be @($script:A.Id)
        $State1.NotReadable | Should -Be @($script:X.Id)

        script:Set-Scenario -Subs $script:A, $script:X, $script:C -Unreadable $script:X.Id -Disabled $script:C.Id
        script:Assert-TwoCleanResumes
    }

    It 'when the subscription left to collect cannot be read after the interruption, the second -Resume ends cleanly' {
        # Run 1: every subscription is readable; Sub A completes, the session ends
        # in Sub X. Sub X cannot be read afterwards.
        script:Set-Scenario -Subs $script:A, $script:X -EndSession $script:X.Id
        $null = script:Invoke-Wrapper -Arguments '-AllowPartialAccess'
        (script:Read-State).Completed | Should -Be @($script:A.Id)

        script:Set-Scenario -Subs $script:A, $script:X -Unreadable $script:X.Id
        script:Assert-TwoCleanResumes
    }
}

Describe 'The not-readable record and the zips a run leaves' -Skip:$IsWindows {
    BeforeEach { script:New-Case }

    It 'no zip holds the resume state, the record or the not-readable id (<Label>)' -TestCases @(
        @{ Label = 'not obfuscated'; Extra = @(); Streams = 1 }
        @{ Label = '-Obfuscate'; Extra = @('-Obfuscate'); Streams = 1 }
        @{ Label = '-Obfuscate, two streams'; Extra = @('-Obfuscate'); Streams = 2 }
    ) {
        param($Label, $Extra, $Streams)
        # Run 1: Sub X is skipped, Sub A completes, Sub B fails, so the state with
        # the record is on disk while the run builds its zips and after it.
        script:Set-Scenario -Subs $script:A, $script:B, $script:X -Unreadable $script:X.Id -Fail $script:B.Id
        $null = script:Invoke-Wrapper -Arguments (@('-AllowPartialAccess') + $Extra) -Streams $Streams
        (script:Read-State).NotReadable | Should -Be @($script:X.Id)
        # Run 2: -Resume; Sub B works now.
        script:Set-Scenario -Subs $script:A, $script:B, $script:X -Unreadable $script:X.Id
        $null = script:Invoke-Wrapper -Arguments (@('-Resume', '-AllowPartialAccess') + $Extra) -Streams $Streams

        $Entries = @(script:Get-ZipEntries)
        $Outer = @($Entries | Where-Object { $_.Zip -like 'AllSubscriptions_ResourcesReport_*.zip' -and $_.Zip -notlike '*!*' })
        @($Outer | Where-Object { $_.Name -eq 'RunSummary.log' }).Count | Should -Be 2 -Because 'each run folds a RunSummary.log into its consolidated zip'
        @($Outer | Where-Object { $_.Name -eq 'MainSummary.html' }).Count | Should -Be 2 -Because 'each run folds a MainSummary.html into its consolidated zip'
        @($Entries | Where-Object { (Split-Path -Path $_.Name -Leaf) -like '.resume-state*' } | ForEach-Object { '{0} {1}' -f $_.Zip, $_.Name }) | Should -BeNullOrEmpty
        @($Entries | Where-Object { $_.Text.Contains('NotReadableSubscriptionIds') } | ForEach-Object { '{0} {1}' -f $_.Zip, $_.Name }) | Should -BeNullOrEmpty
        @($Entries | Where-Object { $_.Text.Contains($script:X.Id) -or $_.Name.Contains($script:X.Id) } | ForEach-Object { '{0} {1}' -f $_.Zip, $_.Name }) | Should -BeNullOrEmpty
    }
}
