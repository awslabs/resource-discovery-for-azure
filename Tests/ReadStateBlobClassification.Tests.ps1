#Requires -Version 7.0
<#
    ReadStateBlobClassification.Tests.ps1

    Read-StateBlob decides whether a shard has resume state to recover. It returns $null
    to mean "start fresh", and a single blanket catch used to return that for two
    OPPOSITE situations:

        blob genuinely ABSENT      -> start fresh is CORRECT (first run for this shard)
        blob present, read FAILED  -> start fresh RE-RUNS THE WHOLE ESTATE

    The second is the expensive one and it was silent. On AKS: a pod is evicted, its
    replacement reads the blob to recover progress, and a momentary throttle makes it look
    like a first run - so it re-collects every subscription the dead pod had finished.

    These tests are OFFLINE. The project's convention is not to mock Azure cmdlets in the
    shipping suites, and the blob helpers are exercised live in BlobStateResume.Tests.ps1.
    That live suite cannot reach these paths though: it has no way to make a real storage
    account fail transiently on demand. So the two Azure calls are stubbed HERE, and only
    here, to drive the classification branches - the retry loop, the absent path, and the
    present-but-unreadable path. Everything under test is the real shipped function,
    dot-sourced from the real file.
#>

BeforeAll {
    $script:FunctionsPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/RunAllSubscriptions.Functions.ps1'
    if (-not (Test-Path -LiteralPath $script:FunctionsPath))
    {
        throw "Cannot find Functions/RunAllSubscriptions.Functions.ps1 at $script:FunctionsPath"
    }

    # Extract ONLY Read-StateBlob via the AST and load that, rather than dot-sourcing the
    # whole file. The file defines a Global Write-Log and other helpers; loading just the
    # function under test keeps the stubs below from being shadowed by real definitions.
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:FunctionsPath, [ref]$null, [ref]$null)
    $Fn = $Ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Read-StateBlob'
        }, $true) | Select-Object -First 1
    if ($null -eq $Fn) { throw 'Could not locate Read-StateBlob; this test cannot verify what it cannot find.' }
    . ([scriptblock]::Create($Fn.Extent.Text))

    # Stub state, driven per test.
    $Global:DlCalls = 0
    $Global:DlFailUntil = 0        # fail the download until this attempt number
    $Global:DlAlwaysFail = $false
    $Global:BlobExists = $false
    $Global:ProbeThrows = $false
    $Global:Payload = '{"TenantID":"t1","CompletedSubscriptionIds":["sub-a","sub-b"]}'

    function Global:Get-AzStorageBlobContent
    {
        [CmdletBinding()]
        param($Container, $Blob, $Destination, $Context, [switch]$Force)
        $Global:DlCalls++
        if ($Global:DlAlwaysFail -or $Global:DlCalls -le $Global:DlFailUntil)
        {
            throw [System.Exception]::new('simulated transient storage failure')
        }
        Set-Content -LiteralPath $Destination -Value $Global:Payload -Encoding utf8
        return [pscustomobject]@{ Name = $Blob }
    }

    function Global:Get-AzStorageBlob
    {
        [CmdletBinding()]
        param($Container, $Blob, $Context)
        if ($Global:ProbeThrows) { throw [System.Exception]::new('simulated probe failure') }
        if ($Global:BlobExists) { return [pscustomobject]@{ Name = $Blob } }
        throw [System.Exception]::new('BlobNotFound')
    }

    function script:Reset-Stubs
    {
        $Global:DlCalls = 0
        $Global:DlFailUntil = 0
        $Global:DlAlwaysFail = $false
        $Global:BlobExists = $false
        $Global:ProbeThrows = $false
    }

    # Split the merged streams into (payload, console text). 6>&1 emits
    # InformationRecord objects for Write-Host - NOT [string] - so filtering on [string]
    # silently matches nothing. Separating them here keeps every assertion below honest
    # about which stream it is inspecting.
    function script:Invoke-Read
    {
        param([int]$MaxAttempts = 3)

        $Lines = [System.Collections.Generic.List[string]]::new()
        $Payload = @(
            Read-StateBlob -Context 'ctx' -Container 'c' -BlobName 'b.json' -MaxAttempts $MaxAttempts 6>&1 |
                ForEach-Object {
                    if ($_ -is [System.Management.Automation.InformationRecord])
                    {
                        $Lines.Add([string]$_)
                    }
                    else
                    {
                        $_
                    }
                }
        )

        return [pscustomobject]@{
            # $null is what "start fresh" looks like; @() from the pipeline collapses it,
            # so report emptiness explicitly rather than trying to preserve $null.
            HasState = (@($Payload | Where-Object { $null -ne $_ }).Count -gt 0)
            State    = @($Payload | Where-Object { $null -ne $_ })
            Text     = ($Lines -join ' ')
        }
    }
}

AfterAll {
    Remove-Item Function:\Get-AzStorageBlobContent -ErrorAction SilentlyContinue
    Remove-Item Function:\Get-AzStorageBlob -ErrorAction SilentlyContinue
}

Describe 'Happy path: a readable blob is parsed and returned' {

    It 'returns the parsed state on the first attempt' {
        script:Reset-Stubs
        $Result = Read-StateBlob -Context 'ctx' -Container 'c' -BlobName 'b.json'
        $Global:DlCalls | Should -Be 1 -Because 'no retry is needed when the first read works'
        @($Result.CompletedSubscriptionIds) -join ',' | Should -Be 'sub-a,sub-b'
    }
}

Describe 'A transient failure is RETRIED instead of reported as start-fresh' {

    # The substance of the fix. Before this, one blip meant re-running the estate.

    It 'recovers when the first attempt fails and the second succeeds' {
        script:Reset-Stubs
        $Global:DlFailUntil = 1
        $Result = Read-StateBlob -Context 'ctx' -Container 'c' -BlobName 'b.json'

        $Global:DlCalls | Should -Be 2
        $Result | Should -Not -BeNullOrEmpty -Because 'a single transient failure must NOT be read as "no resume state"'
        @($Result.CompletedSubscriptionIds) -join ',' | Should -Be 'sub-a,sub-b'
    }

    It 'recovers when only the last attempt succeeds' {
        script:Reset-Stubs
        $Global:DlFailUntil = 2
        $Result = Read-StateBlob -Context 'ctx' -Container 'c' -BlobName 'b.json'
        $Global:DlCalls | Should -Be 3
        $Result | Should -Not -BeNullOrEmpty
    }

    It 'honours MaxAttempts and does not retry forever' {
        script:Reset-Stubs
        $Global:DlAlwaysFail = $true
        $null = script:Invoke-Read -MaxAttempts 2
        $Global:DlCalls | Should -Be 2 -Because 'the budget is bounded so a recovery read cannot stall the run'
    }
}

Describe 'ABSENT blob: unchanged contract, and quiet' {

    # BlobStateResume.Tests.ps1 pins this against a real storage account. Re-asserted
    # here because the classification must not have changed it.

    It 'returns $null when the blob does not exist' {
        script:Reset-Stubs
        $Global:DlAlwaysFail = $true
        $Global:BlobExists = $false
        (script:Invoke-Read).HasState | Should -BeFalse -Because 'an absent blob is the normal start-fresh signal'
    }

    It 'says nothing alarming, because a first run is not a problem' {
        script:Reset-Stubs
        $Global:DlAlwaysFail = $true
        $Global:BlobExists = $false
        (script:Invoke-Read).Text | Should -Not -Match 'WARNING' -Because 'warning on every first run would train operators to ignore the warning'
    }
}

Describe 'PRESENT but UNREADABLE: the silent estate re-run is now loud' {

    It 'still returns $null, so both callers keep working' {
        script:Reset-Stubs
        $Global:DlAlwaysFail = $true
        $Global:BlobExists = $true
        (script:Invoke-Read).HasState | Should -BeFalse -Because 'the per-stream fold runs after collection, so throwing would discard a finished run'
    }

    It 'WARNS, names the blob, and states the consequence' {
        script:Reset-Stubs
        $Global:DlAlwaysFail = $true
        $Global:BlobExists = $true
        $Text = (script:Invoke-Read).Text

        $Text | Should -Match 'WARNING'
        $Text | Should -Match 'b\.json' -Because 'the operator needs to know WHICH state was lost'
        $Text | Should -Match 'EXISTS but could not be read'
        $Text | Should -Match '(?i)RE-PROCESS' -Because 'the cost has to be stated, not implied'
        $Text | Should -Match '(?i)simulated transient storage failure' -Because 'the underlying error is what makes it actionable'
    }

    It 'distinguishes the two cases, which is the whole point' {
        script:Reset-Stubs
        $Global:DlAlwaysFail = $true

        $Global:BlobExists = $false
        $AbsentText = (script:Invoke-Read).Text

        script:Reset-Stubs
        $Global:DlAlwaysFail = $true
        $Global:BlobExists = $true
        $PresentText = (script:Invoke-Read).Text

        $AbsentText | Should -Not -Match 'WARNING'
        $PresentText | Should -Match 'WARNING'
    }
}

Describe 'A failing existence probe does not fabricate a verdict' {

    It 'stays quiet rather than claiming the blob is present' {
        # If the probe itself fails we know nothing new, so asserting either way would be
        # an overclaim. Quiet is the honest choice, and it matches the absent path.
        script:Reset-Stubs
        $Global:DlAlwaysFail = $true
        $Global:ProbeThrows = $true
        $Output = script:Invoke-Read

        $Output.HasState | Should -BeFalse
        $Output.Text | Should -Not -Match 'WARNING'
    }
}

Describe 'Source guards' {

    BeforeAll { $script:Src = Get-Content -LiteralPath $script:FunctionsPath -Raw }

    It 'retries rather than giving up on the first failure' {
        $Src = [regex]::Match($script:Src, '(?s)function Read-StateBlob.*?\n\}').Value
        $Src | Should -Match 'for \(\$Attempt = 1; \$Attempt -le \$MaxAttempts'
    }

    It 'uses a FRESH temp file per attempt, so a partial download is never re-read' {
        $Src = [regex]::Match($script:Src, '(?s)function Read-StateBlob.*?\n\}').Value
        $TmpAssign = @([regex]::Matches($Src, '\$Tmp = Join-Path')).Count
        $TmpAssign | Should -Be 1
        # and it must be INSIDE the loop, after the for
        $Src.IndexOf('$Tmp = Join-Path') | Should -BeGreaterThan $Src.IndexOf('for ($Attempt = 1')
    }

    It 'classifies with an existence probe, not by matching exception text' {
        $Src = [regex]::Match($script:Src, '(?s)function Read-StateBlob.*?\n\}').Value
        $Src | Should -Match 'Get-AzStorageBlob -Container'
        $Src | Should -Not -Match 'BlobNotFound' -Because 'exception shapes differ across Az.Storage versions; probing is version-independent'
    }
}
