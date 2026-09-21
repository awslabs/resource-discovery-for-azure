#Requires -Version 7.0
<#
    ParamForwardingParity.Tests.ps1

    Guards the parameter-forwarding chain:

        Run-AllSubscriptions.ps1  --($InventoryPassthrough)-->  ResourceInventory.ps1   (sequential)
        Run-AllSubscriptions.ps1  --($WorkerArgs)-->  Run-AllSubscriptions.Stream.ps1
        Run-AllSubscriptions.Stream.ps1  --($InventoryPassthrough)-->  ResourceInventory.ps1

    WHY THIS EXISTS. Those are THREE hand-maintained key lists, and they drifted:
    -Debug was forwarded on the sequential path but absent from both parallel hops,
    so `-Debug -ParallelStreams N` accepted the flag and silently produced no inner
    debug output at all. Reproduced against the sandbox: 2 streams, 3 subscriptions,
    zero 'DEBUG:' lines and zero 'Debugging Mode: On'.

    By contrast the pwsh-7 relaunch in Run-AllSubscriptions.ps1 enumerates
    $PSBoundParameters generically, so it forwards new switches for free and cannot
    drift. The hand-maintained lists are the risk, hence a static guard.

    These are OFFLINE source-text assertions - no Azure calls, no execution of the
    wrapper. Same approach as Tests/WeightedInventoryPlan.Tests.ps1, which already
    asserts against wrapper source text.
#>

BeforeAll {
    $script:Repo = Split-Path $PSScriptRoot -Parent
    $script:WrapperPath = Join-Path $script:Repo 'Run-AllSubscriptions.ps1'
    $script:StreamPath = Join-Path $script:Repo 'Run-AllSubscriptions.Stream.ps1'
    $script:InnerPath = Join-Path $script:Repo 'ResourceInventory.ps1'

    $script:WrapperSrc = Get-Content -LiteralPath $script:WrapperPath -Raw
    $script:StreamSrc = Get-Content -LiteralPath $script:StreamPath -Raw

    function script:Get-ScriptParamNames
    {
        param([string]$Path)
        $Errors = $null
        $Tokens = $null
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$Tokens, [ref]$Errors)
        if (-not $Ast.ParamBlock) { return @() }
        return @($Ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    }

    # Keys the wrapper splats at the parallel worker, from BOTH sources: the $WorkerArgs accessor forms AND the @{...} literal keys.
    # The accessor regex alone omits every literal key, so an unbindable literal key would slip past the binding assertion below.
    $script:WorkerArgAccessorKeys = @([regex]::Matches($script:WrapperSrc, '\$WorkerArgs(?:\.|\['')([A-Za-z]+)') |
            ForEach-Object { $_.Groups[1].Value })
    $script:WorkerArgLiteralBody = [regex]::Match($script:WrapperSrc, '\$WorkerArgs\s*=\s*@\{([\s\S]*?)\}').Groups[1].Value
    $script:WorkerArgLiteralKeys = @([regex]::Matches($script:WorkerArgLiteralBody, '(?m)^\s*([A-Za-z]+)\s*=') |
            ForEach-Object { $_.Groups[1].Value })
    $script:WorkerArgKeys = @($script:WorkerArgAccessorKeys + $script:WorkerArgLiteralKeys) | Sort-Object -Unique

    # Keys each script puts into the hashtable it splats at ResourceInventory.ps1.
    $script:WrapperPassKeys = @([regex]::Matches($script:WrapperSrc, '\$InventoryPassthrough\[''([A-Za-z]+)''\]') |
            ForEach-Object { $_.Groups[1].Value }) | Sort-Object -Unique
    $script:StreamPassKeys = @([regex]::Matches($script:StreamSrc, '\$InventoryPassthrough\[''([A-Za-z]+)''\]') |
            ForEach-Object { $_.Groups[1].Value }) | Sort-Object -Unique

    $script:StreamParams = script:Get-ScriptParamNames $script:StreamPath
    $script:InnerParams = script:Get-ScriptParamNames $script:InnerPath
}

Describe 'Sequential and parallel paths reach ResourceInventory.ps1 with the same options' {

    It 'forwards an identical key set on both paths' {
        # THE regression that produced this file. If these ever diverge again, the
        # difference is named in the failure message rather than silently shipping.
        $OnlySequential = @($script:WrapperPassKeys | Where-Object { $_ -notin $script:StreamPassKeys })
        $OnlyParallel = @($script:StreamPassKeys | Where-Object { $_ -notin $script:WrapperPassKeys })

        $OnlySequential -join ', ' | Should -BeNullOrEmpty -Because 'an option honoured only in sequential mode is silently ignored under -ParallelStreams'
        $OnlyParallel -join ', ' | Should -BeNullOrEmpty -Because 'an option honoured only in parallel mode is silently ignored in sequential mode'
    }

    It 'forwards -Debug on both paths' {
        # Named explicitly because this is the flag that actually drifted.
        'Debug' | Should -BeIn $script:WrapperPassKeys -Because 'the sequential path must forward -Debug'
        'Debug' | Should -BeIn $script:StreamPassKeys -Because 'the parallel worker must forward -Debug to the inner script'
        'Debug' | Should -BeIn $script:WorkerArgKeys -Because 'the wrapper must forward -Debug to the worker, since jobs do not inherit $DebugPreference'
    }

    It 'honours an explicit -Debug:$false rather than inverting it' {
        # ContainsKey('Debug') is also true for -Debug:$false, so a literal $true
        # would invert the operator's intent at every forwarding site.
        $BadForwards = @(
            @($script:WrapperSrc -split "`n") + @($script:StreamSrc -split "`n") |
                Where-Object { $_ -match "ContainsKey\('Debug'\)" -and $_ -match '=\s*\$true' }
        )
        $BadForwards.Count | Should -Be 0 -Because 'use [bool]$PSBoundParameters[''Debug''] so -Debug:$false is honoured'
    }

    It 'the RECEIVING script also reads the value, not just the key' {
        # Forwarding parity is worthless if the destination disagrees: a bare ContainsKey on $DebugMode once re-inverted
        # -Debug:$false on arrival (flipping $ErrorActionPreference for the whole run), so assert the receiving script reads the value too.
        $InvPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'ResourceInventory.ps1'
        $InvSrc = Get-Content -LiteralPath $InvPath -Raw

        $DebugModeLine = @($InvSrc -split "`r?`n" | Where-Object { $_ -match '^\s*\$DebugMode\s*=' }) | Select-Object -First 1
        $DebugModeLine | Should -Not -BeNullOrEmpty -Because 'the $DebugMode assignment must be locatable'

        $DebugModeLine | Should -Match "ContainsKey\('Debug'\)" -Because 'a common parameter can only be detected via $PSBoundParameters'
        $DebugModeLine | Should -Match '\[bool\]\$PSBoundParameters\[''Debug''\]' -Because 'ContainsKey alone is TRUE for -Debug:$false, so the VALUE must be read as well'
    }

    It 'the -Debug:$false semantics hold when the expression is evaluated' {
        # Behavioural, not just textual: extract the real predicate and run it against
        # the three cases the binder can produce.
        $InvPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'ResourceInventory.ps1'
        $Line = @((Get-Content -LiteralPath $InvPath) | Where-Object { $_ -match '^\s*\$DebugMode\s*=' }) | Select-Object -First 1
        # $PSBoundParameters cannot be used as the scriptblock's own parameter name - it
        # is an automatic variable that PowerShell repopulates for each invocation, which
        # would silently shadow the value under test. Rename it in the extracted text.
        $Expr = ($Line -replace '^\s*\$DebugMode\s*=\s*', '') -replace '\$PSBoundParameters', '$Bound'
        $Block = [scriptblock]::Create('param($Bound) ' + $Expr)

        (& $Block @{}) | Should -BeFalse -Because '-Debug omitted entirely'
        (& $Block @{ Debug = $true }) | Should -BeTrue  -Because '-Debug or -Debug:$true'
        (& $Block @{ Debug = $false }) | Should -BeFalse -Because '-Debug:$false is an explicit opt-OUT and must not enable debug mode'
        (& $Block @{ Debug = [switch]$false }) | Should -BeFalse -Because 'the binder supplies a SwitchParameter, not a raw bool'
        (& $Block @{ Debug = [switch]$true }) | Should -BeTrue
    }
}

Describe 'Every key forwarded actually binds on the receiving script' {

    It 'sends the worker nothing Run-AllSubscriptions.Stream.ps1 cannot bind' {
        # Debug is a COMMON parameter, so it binds on Run-AllSubscriptions.Stream.ps1 (advanced via its [Parameter(Mandatory)] attributes)
        # without being declared - hence it is exempt from the unbindable-key check. Verified across a real Start-Job boundary.
        $Common = @('Debug')
        $Unbindable = @($script:WorkerArgKeys | Where-Object { $_ -notin $script:StreamParams -and $_ -notin $Common })
        $Unbindable -join ', ' | Should -BeNullOrEmpty -Because 'a key with no matching parameter is a binding error at runtime, not a no-op'
    }

    It 'keeps Run-AllSubscriptions.Stream.ps1 an ADVANCED script, so common parameters keep binding' {
        # The Debug forward depends on this. If the [Parameter()] attributes were
        # ever removed, the script would silently become simple, -Debug would land
        # in $args, and the forward would break with no error.
        $Errors = $null
        $Tokens = $null
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:StreamPath, [ref]$Tokens, [ref]$Errors)
        $HasCmdletBinding = @($Ast.ParamBlock.Attributes.TypeName.Name) -contains 'CmdletBinding'
        $HasParameterAttr = @($Ast.ParamBlock.Parameters.Attributes.TypeName.Name) -contains 'Parameter'
        ($HasCmdletBinding -or $HasParameterAttr) | Should -BeTrue -Because 'only an advanced script accepts -Debug as a common parameter'
    }

    It 'sends ResourceInventory.ps1 nothing it cannot bind, from either path' {
        # -Debug is a CmdletBinding COMMON parameter on the inner script (it
        # deliberately declares no [switch]$Debug), so it binds without appearing
        # in the param block. Every other key must be a declared parameter.
        $Common = @('Debug')
        $AllPassKeys = @($script:WrapperPassKeys + $script:StreamPassKeys) | Sort-Object -Unique
        $Unbindable = @($AllPassKeys | Where-Object { $_ -notin $script:InnerParams -and $_ -notin $Common })
        $Unbindable -join ', ' | Should -BeNullOrEmpty -Because 'a forwarded key with no matching parameter on the inner script would throw'
    }
}

Describe 'Wrapper-only options are deliberately not forwarded' {

    It 'does not forward options the inner script has no parameter for' {
        # These options are genuinely wrapper-scoped - none is a parameter on ResourceInventory.ps1, so forwarding any would be a binding error.
        # Asserted so that if one is ever ADDED to the inner script this test flags the decision instead of leaving it quietly unforwarded.
        $WrapperOnly = @(
            'IncludeDisabled'
            'AllowPartialAccess'
            'MainSummary'
            'Detailed'
            'UploadToBlobContainerUri'
            'PlanPerQuerySeconds'
        )
        foreach ($Name in $WrapperOnly)
        {
            $Name | Should -Not -BeIn $script:InnerParams -Because "$Name is wrapper-scoped; if the inner script gained this parameter, revisit whether it should now be forwarded"
        }
    }

    It 'reduces ConcurrencyLimit for -HeadRoom BEFORE building either passthrough' {
        # -HeadRoom is correctly absent from both forwards because it MUTATES
        # $ConcurrencyLimit, which IS forwarded. That only holds while the
        # reduction happens before both hashtables are built; if it were ever moved
        # after them, -HeadRoom would silently stop applying.
        $HeadRoomIdx = $script:WrapperSrc.IndexOf('Get-HeadroomAdjustedConcurrency')
        $SeqIdx = $script:WrapperSrc.IndexOf("InventoryPassthrough['ConcurrencyLimit']")
        # The worker args set ConcurrencyLimit as a key in the @{ } literal, not via
        # a '.' accessor, so an IndexOf('WorkerArgs.ConcurrencyLimit') never matches
        # and a fixed-whitespace literal match breaks the moment the hashtable is
        # realigned. Match the assignment with a whitespace-insensitive regex and
        # use its index, so this asserts ORDER, not formatting.
        $ParMatch = [regex]::Match($script:WrapperSrc, 'ConcurrencyLimit\s*=\s*\$ConcurrencyLimit')
        $ParIdx = if ($ParMatch.Success) { $ParMatch.Index } else { -1 }

        $HeadRoomIdx | Should -BeGreaterThan -1 -Because 'the headroom reduction must exist to be ordered'
        $ParIdx | Should -BeGreaterThan -1 -Because 'the worker-args ConcurrencyLimit assignment must be found regardless of whitespace'
        $SeqIdx | Should -BeGreaterThan $HeadRoomIdx -Because 'the sequential passthrough must be built AFTER the headroom reduction'
        $ParIdx | Should -BeGreaterThan $HeadRoomIdx -Because 'the worker args must be built AFTER the headroom reduction'
    }
}
