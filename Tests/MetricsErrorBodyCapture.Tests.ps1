#Requires -Version 7.0
<#
    MetricsErrorBodyCapture.Tests.ps1

    Covers Get-RdaMetricErrorBody in Extension/Metrics.ps1 - the best-effort
    extraction of Azure Monitor's RESPONSE BODY for a failed metric call.

    WHY IT EXISTS. $_.Exception.Message for a rejected metric call is a generic
    line ("Operation returned an invalid status code 'BadRequest'") that says the
    request was refused but not why. The body underneath separates the causes the
    status cannot:
      - metric not defined for this resource type   (resource-side, benign)
      - unsupported time grain                      (TOOL-side, reachable via
                                                     -MetricsIntervalMinutes)
      - resource deleted after discovery            (resource-side, benign)
    Without it a tool-side 400 is indistinguishable from a benign one, which is
    how a few hundred Linux function apps burned hours of a run before the cause was visible.

    DIAGNOSTICS ONLY. The body is never read to make a retry or skip decision and
    never reaches Metrics_*.json. Two tests below assert that separation directly,
    because the moment it feeds control flow, a malformed body becomes a behaviour
    change rather than a cosmetic one.

    The function is defined INSIDE the ForEach-Object -Parallel scriptblock (a
    file-scope function is not visible in those runspaces), so these tests lift it
    out with the AST and evaluate it standalone. Fully offline - no Azure.

    VERIFIED AGAINST REAL AZURE (2026-09-09). The shapes below are synthetic, so
    the extractor was additionally run against genuine Get-AzMetric failures to
    confirm the traversal finds the body in the real nesting - which is
    PSInvalidOperationException wrapping Microsoft.Azure.Management.Monitor.Models.ErrorResponseException,
    a shape none of the synthetic cases model. All three real cases carried the
    SAME useless .Message ("Operation returned an invalid status code 'BadRequest'"
    / "'NotFound'"), and the extractor separated them:

      bogus metric name    -> BadRequest: Failed to find metric configuration for
                              provider: Microsoft.Compute, resource Type:
                              virtualMachines, metric: ... Valid metrics: ...
      unsupported grain    -> BadRequest: Invalid time grain duration: PT7S,
                              supported ones are: PT1M,PT5M,PT15M,...
      deleted resource     -> ResourceNotFound: The Resource '...' was not found

    The middle one is the TOOL-side case -MetricsIntervalMinutes can produce, and
    before this capture it was indistinguishable from the first. The classifier
    returned permanent BadRequest / BadRequest / NotFound in all three, confirming
    the body does not feed the retry decision.

    If this extractor is ever changed, re-run that live check: a synthetic shape
    passing here does not prove the real SDK nesting is still handled.
#>

BeforeAll {
    $script:MetricsPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Extension/Metrics.ps1'
    $script:MetricsSrc = Get-Content -LiteralPath $script:MetricsPath -Raw

    # AST rather than regex: the function contains nested braces and try/catch, so
    # a lazy regex truncates it into something that will not parse.
    $Errors = $null
    $Tokens = $null
    $Ast = [System.Management.Automation.Language.Parser]::ParseInput($script:MetricsSrc, [ref]$Tokens, [ref]$Errors)
    $FnAst = $Ast.FindAll({
            param($Node)
            $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $Node.Name -eq 'Get-RdaMetricErrorBody'
        }, $true) | Select-Object -First 1

    if (-not $FnAst)
    {
        throw 'Get-RdaMetricErrorBody was not found in Extension/Metrics.ps1; these tests cannot verify what is not there.'
    }
    . ([scriptblock]::Create($FnAst.Extent.Text))

    # Helpers that build error-record SHAPES. Note the parameter is deliberately
    # NOT called -Input: $Input is an automatic variable and binding to it silently
    # yields nothing.
    function script:New-RecWithBody { param($Body) [pscustomobject]@{ Exception = [pscustomobject]@{ Body = $Body; InnerException = $null } } }
    function script:New-RecWithResponse { param($Content) [pscustomobject]@{ Exception = [pscustomobject]@{ Response = [pscustomobject]@{ Content = $Content }; InnerException = $null } } }
    function script:New-RecWithDetails { param($Message) [pscustomobject]@{ ErrorDetails = [pscustomobject]@{ Message = $Message }; Exception = $null } }
}

Describe 'Contract: never throws, and a miss is $null' {

    It 'returns $null for <Label> without throwing' -ForEach @(
        @{ Label = 'a null record'; Rec = $null }
        @{ Label = 'an empty string'; Rec = '' }
        @{ Label = 'a bare integer'; Rec = 42 }
        @{ Label = 'an empty object'; Rec = ([pscustomobject]@{}) }
        @{ Label = 'a null Exception'; Rec = ([pscustomobject]@{ Exception = $null }) }
    ) {
        { Get-RdaMetricErrorBody -ErrorRecord $Rec } | Should -Not -Throw
        Get-RdaMetricErrorBody -ErrorRecord $Rec | Should -BeNullOrEmpty
    }

    It 'survives property getters that throw' {
        # Each probe must be individually guarded; one hostile getter must not
        # abort the whole extraction.
        $Hostile = New-Object psobject
        $Hostile | Add-Member -MemberType ScriptProperty -Name Response -Value { throw 'boom' } -Force
        $Hostile | Add-Member -MemberType ScriptProperty -Name Body -Value { throw 'boom' } -Force
        $Hostile | Add-Member -MemberType NoteProperty -Name InnerException -Value $null -Force
        $Rec = [pscustomobject]@{ Exception = $Hostile }

        { Get-RdaMetricErrorBody -ErrorRecord $Rec } | Should -Not -Throw
        Get-RdaMetricErrorBody -ErrorRecord $Rec | Should -BeNullOrEmpty
    }

    It 'treats a whitespace-only body as no body' {
        Get-RdaMetricErrorBody -ErrorRecord (script:New-RecWithBody "  `n  ") | Should -BeNullOrEmpty
    }
}

Describe 'Extraction finds the body wherever the SDK put it' {

    It 'reads ErrorDetails.Message' {
        Get-RdaMetricErrorBody -ErrorRecord (script:New-RecWithDetails '{"error":{"code":"MetricNotFound","message":"Metric not defined"}}') |
            Should -Match 'MetricNotFound'
    }

    It 'reads Response.Content' {
        Get-RdaMetricErrorBody -ErrorRecord (script:New-RecWithResponse '{"error":{"code":"BadRequest","message":"Unsupported time grain PT5M"}}') |
            Should -Match 'Unsupported time grain'
    }

    It 'reads .Body' {
        Get-RdaMetricErrorBody -ErrorRecord (script:New-RecWithBody '{"code":"InvalidTimeGrain","message":"unsupported time grain"}') |
            Should -Match 'InvalidTimeGrain'
    }

    It 'walks the InnerException chain to find a nested body' {
        # Built outward from the innermost node so the nesting stays readable
        # rather than collapsing into one deeply-indented literal.
        $Depth3 = [pscustomobject]@{
            Response       = [pscustomobject]@{ Content = '{"error":{"code":"DeepCode","message":"found at depth 3"}}' }
            InnerException = $null
        }
        $Depth2 = [pscustomobject]@{ InnerException = $Depth3 }
        $Depth1 = [pscustomobject]@{ InnerException = $Depth2 }
        $Rec = [pscustomobject]@{ Exception = $Depth1 }

        Get-RdaMetricErrorBody -ErrorRecord $Rec | Should -Match 'DeepCode'
    }

    It 'renders JSON as code: message, which is the part a human reads' {
        Get-RdaMetricErrorBody -ErrorRecord (script:New-RecWithBody '{"error":{"code":"BadRequest","message":"no such metric"}}') |
            Should -Be 'BadRequest: no such metric'
    }

    It 'falls back to raw text when the body is not JSON' {
        Get-RdaMetricErrorBody -ErrorRecord (script:New-RecWithBody 'this is not json at all') |
            Should -Match 'not json at all'
    }

    It 'falls back to raw text when the JSON is malformed, rather than losing it' {
        Get-RdaMetricErrorBody -ErrorRecord (script:New-RecWithBody '{"error":{"code":') |
            Should -Not -BeNullOrEmpty
    }
}

Describe 'Traversal is bounded, so a cyclic chain cannot hang the metrics phase' {

    It 'terminates on a self-referencing InnerException' {
        # A depth bound ALONE is not sufficient here - the visited set is what stops
        # the same node being re-inspected at every level.
        $Cyclic = [pscustomobject]@{ Response = [pscustomobject]@{ Content = $null } }
        $Cyclic | Add-Member -MemberType NoteProperty -Name InnerException -Value $Cyclic -Force

        { Get-RdaMetricErrorBody -ErrorRecord ([pscustomobject]@{ Exception = $Cyclic }) } | Should -Not -Throw
    }

    It 'terminates on a two-node cycle A -> B -> A' {
        $A = [pscustomobject]@{ Response = [pscustomobject]@{ Content = $null } }
        $B = [pscustomobject]@{ Response = [pscustomobject]@{ Content = $null } }
        $A | Add-Member -MemberType NoteProperty -Name InnerException -Value $B -Force
        $B | Add-Member -MemberType NoteProperty -Name InnerException -Value $A -Force

        { Get-RdaMetricErrorBody -ErrorRecord ([pscustomobject]@{ Exception = $A }) } | Should -Not -Throw
    }

    It 'stops at the depth bound rather than walking an arbitrarily long chain' {
        $Deep = [pscustomobject]@{ Response = [pscustomobject]@{ Content = '{"code":"TooDeep"}' }; InnerException = $null }
        for ($i = 0; $i -lt 15; $i++)
        {
            $Deep = [pscustomobject]@{ Response = [pscustomobject]@{ Content = $null }; InnerException = $Deep }
        }
        Get-RdaMetricErrorBody -ErrorRecord ([pscustomobject]@{ Exception = $Deep }) |
            Should -BeNullOrEmpty -Because 'a body past the bound is given up on, which is the point of bounding it'
    }
}

Describe 'Retained text is capped and single-line' {

    It 'caps retained text at 2000 characters, keeping the head AND the tail' {
        # The cap keeps both ends on purpose. Azure Monitor's rejection puts the
        # actionable part LAST - "... Valid metrics: a,b,c" is the list of metrics the
        # resource actually publishes, i.e. the answer to what we should have asked
        # for - so a head-only cap threw away the only useful sentence. HEAD_MARKER
        # and TAIL_MARKER below stand in for that structure.
        $Long = '{"error":{"code":"Big","message":"HEAD_MARKER ' + ('x' * 4000) + ' TAIL_MARKER"}}'
        $Result = Get-RdaMetricErrorBody -ErrorRecord (script:New-RecWithBody $Long)

        $Result | Should -Match 'HEAD_MARKER' -Because 'the start says which error it was'
        $Result | Should -Match 'TAIL_MARKER' -Because 'the end carries the valid-metric list, which is the actionable part'
        $Result | Should -Match 'chars omitted' -Because 'truncation must be visible, not silent'

        # 2000 retained characters plus the inserted marker, and nothing near the
        # original 4000+.
        $Result.Length | Should -BeGreaterThan 2000
        $Result.Length | Should -BeLessThan 2100

        # Assert the PROPERTY, not just the marker: a surviving marker proves little, so require a tail big enough
        # to hold a realistic 'Valid metrics:' list (Azure's Microsoft.Web rejection enumerates hundreds of chars).
        $TailIdx = $Result.IndexOf('chars omitted')
        $TailIdx | Should -BeGreaterThan 0
        $RetainedTail = $Result.Substring($TailIdx)
        $RetainedTail.Length | Should -BeGreaterThan 600 -Because 'the retained tail must be able to hold a real valid-metric list, not just the marker'
    }

    It 'does not make a barely-oversized body LONGER than it started' {
        # head + tail + marker can exceed the original when the input is only just past
        # the cap, which would be a truncation that costs bytes instead of saving them.
        $Body = 'x' * 2010
        $Result = Get-RdaMetricErrorBody -ErrorRecord (script:New-RecWithBody $Body)
        $Result.Length | Should -BeLessOrEqual $Body.Length -Because 'truncating must never inflate the text'
    }

    It 'does not truncate a body that already fits, and adds no marker' {
        $Short = '{"error":{"code":"Small","message":"metric not defined for this resource type"}}'
        $Result = Get-RdaMetricErrorBody -ErrorRecord (script:New-RecWithBody $Short)

        $Result | Should -Be 'Small: metric not defined for this resource type'
        $Result | Should -Not -Match 'omitted'
    }

    It 'collapses newlines so one record stays one log line' {
        $Result = Get-RdaMetricErrorBody -ErrorRecord (script:New-RecWithBody "line one`nline two`r`nline three")
        $Result | Should -Not -Match "`n"
        $Result | Should -Not -Match "`r"
        $Result | Should -Be 'line one line two line three'
    }
}

Describe 'It is DIAGNOSTICS ONLY - the body must not reach control flow or output' {

    It 'resets the captured body on every attempt, so a recovered call reports no body' {
        # Without a per-attempt reset this was write-once-and-linger: a body captured
        # on a failed attempt 1 survived into a SUCCESSFUL attempt 2, producing a
        # record with Outcome='Success' AND a non-null ErrorBody - a log entry
        # describing a failure that had already recovered.
        $Src = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'Extension/Metrics.ps1') -Raw

        # The reset must sit with the other per-attempt resets at the top of the retry
        # loop, not somewhere that only runs once.
        $Src | Should -Match '(?s)\$Throttled = \$false.*?\$CallErrorBody = \$null' -Because 'the reset belongs beside $TimedOut/$Throttled, inside the while loop'

        # And it must come BEFORE the capture site, otherwise it would erase the very
        # body it was meant to scope.
        $ResetIdx = $Src.IndexOf('$CallErrorBody = $null')
        $CaptureIdx = $Src.IndexOf('$CallErrorBody = Get-RdaMetricErrorBody')
        $ResetIdx | Should -BeGreaterThan -1
        $CaptureIdx | Should -BeGreaterThan $ResetIdx
    }

    It 'shows the body for the calls that burned the whole retry budget too' {
        # The costly failures (Timeout/Throttled/Error) were the least explained,
        # because the body was only appended on the cheap permanent path.
        $Src = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'Extension/Metrics.ps1') -Raw
        $Block = [regex]::Match($Src, "(?s)Non-success calls \(where it got stuck\).*?\r?\n\s*\}").Value
        $Block | Should -Not -BeNullOrEmpty
        $Block | Should -Match 'ErrorBody' -Because 'the most expensive failures need the cause most'
    }

    It 'is captured into $CallErrorBody and carried on the diagnostics record' {
        $script:MetricsSrc | Should -Match '\$CallErrorBody = Get-RdaMetricErrorBody -ErrorRecord \$_' -Because 'the capture must happen in the catch where the exception chain is still available'
        $script:MetricsSrc | Should -Match 'ErrorBody\s*=\s*\$CallErrorBody' -Because 'the extracted body must reach the diagnostics bag or it was captured for nothing'
    }

    It 'does not participate in the permanent-vs-throttle classification' {
        # The classification must remain a function of $LastError alone. If the body
        # ever fed a branch here, a malformed body would change retry behaviour.
        # Classification lives in Get-RdaMetricFailureClass and is called with the message alone.
        $ClassBlock = [regex]::Match($script:MetricsSrc, '(?s)function Get-RdaMetricFailureClass\s*\{.*?\n                \}').Value
        $ClassBlock | Should -Not -BeNullOrEmpty -Because 'the classification function must be findable'
        $ClassBlock | Should -Not -Match 'CallErrorBody|ErrorBody' -Because 'the response body must never influence a retry or skip decision'
        $script:MetricsSrc | Should -Match '(?m)Get-RdaMetricFailureClass -Message \$LastError\s*$' -Because 'the loop must classify from $LastError only'
    }

    It 'never reaches the metrics OUTPUT object, only the diagnostics bag' {
        # $Obj is what becomes Metrics_*.json. ErrorBody must not appear in it.
        $ObjBlock = [regex]::Match($script:MetricsSrc, '(?s)\$Obj = @\{.*?\r?\n\s*\}').Value
        $ObjBlock | Should -Not -BeNullOrEmpty -Because 'the output object must be findable'
        $ObjBlock | Should -Not -Match 'ErrorBody' -Because 'this is a diagnostics field; adding it to output would be a JSON schema change'
    }

    It 'surfaces the body in the permanent-failure listing, where the cause is ambiguous' {
        $script:MetricsSrc | Should -Match '\$BodyNote = if \(\[string\]::IsNullOrWhiteSpace\(\$rec\.ErrorBody\)\)' -Because 'an absent body must render as nothing rather than an empty label'
        $script:MetricsSrc | Should -Match 'azure: ' -Because 'the body must be labelled so it is not confused with our own message'
    }
}
