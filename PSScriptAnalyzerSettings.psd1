@{
    # PSScriptAnalyzer settings for Resource Discovery for Azure.
    # Keep in sync with .kiro/steering/powershell-style.md.
    #
    # Run locally:
    #   Invoke-ScriptAnalyzer -Path <file-or-folder> -Settings ./PSScriptAnalyzerSettings.psd1 -Recurse

    IncludeDefaultRules = $true

    # Custom rules live alongside this file.
    CustomRulePath   = @('./.scriptanalyzer/CustomRules.psm1')
    IncludeRules     = @('*')

    # Most of the repo predates these rules; excluding here keeps the signal
    # on new code. Remove entries as older files are cleaned up.
    ExcludeRules = @(
        # Pre-existing in ResourceInventory.ps1 for Service Principal auth.
        # TODO: replace with an encrypted credential store and re-enable.
        'PSAvoidUsingConvertToSecureStringWithPlainText',

        # Upstream PSScriptAnalyzer bug: this formatting rule throws a
        # NullReferenceException ("Object reference not set to an instance of an
        # object") while analyzing ResourceInventory.ps1 and Functions/*, which
        # aborts the entire -Recurse run (not just that file). The repo never
        # opted into this rule via the Rules block below — it only ran because
        # IncludeRules = @('*'). Our hashtable/assignment layouts are valid
        # PowerShell; the null-ref is inside the rule's own alignment logic, so
        # excluding the broken rule is the correct fix rather than reshaping
        # valid code to work around it.
        'PSAlignAssignmentStatement',

        # Upstream PSScriptAnalyzer bug: this cosmetic cmdlet-casing rule throws
        # a NullReferenceException inside its own AnalyzeScript ->
        # CommandInfo.get_Parameters() path when it tries to resolve the
        # parameter metadata of a command it cannot fully load (ResourceInventory.ps1
        # is dense with Az cmdlets; CI runs with no Az modules installed, which
        # makes the null-ref more likely). The exception is thrown on a worker
        # thread and aborts the whole analyzer process — it is NOT catchable via
        # -ErrorAction. Captured stack trace:
        #   System.NullReferenceException
        #     at CommandInfo.get_Parameters()
        #     at BuiltinRules.UseCorrectCasing.AnalyzeScript(...)
        # It only enforces cosmetic casing of cmdlet/keyword names, so excluding
        # it costs no correctness/security coverage. (The Rules block below no
        # longer enables it — see the note there.)
        'PSUseCorrectCasing',

        # Intentional architecture, not a defect. The obfuscation dictionaries
        # and per-phase health globals ($Global:ResourceIdDictionary,
        # $Global:ResourceNameDictionary, $Global:ConsumptionFailedSubs,
        # $Global:MetricsFailedSubs, $Global:CollectorFailures, etc.) are the
        # established, documented cross-collector state-sharing mechanism for
        # this tool (see .kiro/steering/project-architecture.md). Collectors
        # read these globals by design; there is no accidental global leakage
        # (Services/* declare none). Flagging every read/write of the sanctioned
        # globals is pure noise here, so the rule is excluded rather than
        # annotating hundreds of intentional uses.
        'PSAvoidGlobalVars',

        # Intentional interactive console UX, not logging. Write-Host is used
        # deliberately for coloured, user-facing terminal output in the
        # interactive wrapper and tooling (PowerShell 7 / Azure CLI / Az module
        # install prompts, Read-Host flows, auth status, progress and run
        # summaries) via -ForegroundColor. File logging goes through Write-Log;
        # structured data is returned as objects. The Services/* collectors
        # contain ZERO Write-Host (verified) — they emit objects — so excluding
        # this rule does not mask collector misuse. Converting these coloured
        # prompts to Write-Output/Write-Information would break the interactive
        # experience, so the rule is excluded rather than "fixed".
        'PSAvoidUsingWriteHost',

        # False positive against the fixed collector contract and indirect
        # parameter use. Every Services/*/*.ps1 collector takes the required
        # 4-param signature ($Sub, $Resources, $Task, $ResourceIdDictionary);
        # collectors without cross-references legitimately never read
        # $ResourceIdDictionary, but it MUST stay because the orchestrator binds
        # it by name (removing it would break the contract). The entry scripts'
        # parameters (TenantID, SubscriptionID, etc.) are consumed indirectly
        # (splatting, $PSBoundParameters, nested scriptblocks) which this rule
        # does not track. Removing either class would be wrong, so the rule is
        # excluded.
        'PSReviewUnusedParameter',

        # False positive on the correct Start-Job pattern. The parallel workers
        # pass state into the job via -ArgumentList bound to a param() block
        # (e.g. Reveal.ps1 Start-Job { param($InputZip,...) } -ArgumentList ...),
        # NOT via $using:. The rule assumes any variable in a job scriptblock
        # needs the Using: modifier and flags the (correct) param-bound ones.
        # Adding $using: would be wrong here.
        'PSUseUsingScopeModifierInNewRunspaces',

        # False positive for a script-based tool with no exported cmdlets. The
        # flagged functions are internal HTML/object builders (New-DonutChart,
        # New-BarChart, New-ServiceTable, test New-* helpers) that return
        # strings/objects, plus internal resume-state helpers. None are public
        # cmdlets, so wiring up ShouldProcess/-WhatIf/-Confirm would be pure
        # ceremony with no user-facing benefit.
        'PSUseShouldProcessForStateChangingFunctions',

        # Intentional: the flagged functions return COLLECTIONS, so the plural
        # noun is semantically accurate (Get-FailedAttempts, Get-CompletedSubscriptionIds,
        # Get-StreamResumeStateFiles, etc.). Renaming to singular would be less
        # accurate and would churn every call site for a cosmetic naming rule.
        'PSUseSingularNouns',

        # Repo convention is UTF-8 WITHOUT BOM and LF line endings (enforced by
        # the formatter pass). This rule wants a BOM on files it considers
        # unicode-encoded; adding BOMs would fight the deliberate no-BOM
        # convention and create churn on Linux/CI. Excluded.
        'PSUseBOMForUnicodeEncodedFile',

        # Intentional best-effort swallow in non-fatal paths. The flagged catch
        # blocks are deliberate (each carries an explanatory comment): CloudShell
        # detection (the failure IS the "not CloudShell" signal), and
        # progress/error/debug-log writes that must NEVER break a run. Genuine
        # error handling elsewhere uses Write-Log + -ErrorAction Stop; these
        # specific paths are meant to fail silently, so the rule is excluded
        # rather than adding no-op statements to satisfy it.
        'PSAvoidUsingEmptyCatchBlock'
    )

    Severity = @('Error', 'Warning', 'Information')

    Rules = @{

        # ---- Brace style --------------------------------------------------
        # Allman (BSD) style: opening brace on its own line so function /
        # block signatures stay visible when the body is folded.
        PSPlaceOpenBrace = @{
            Enable             = $true
            OnSameLine         = $false   # => brace on its own line
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true    # leave `Where-Object { ... }` alone
        }

        PSPlaceCloseBrace = @{
            Enable             = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
            NoEmptyLineBefore  = $false
        }

        # ---- Indentation --------------------------------------------------
        PSUseConsistentIndentation = @{
            Enable              = $true
            Kind                = 'space'
            IndentationSize     = 4
            PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
        }

        PSUseConsistentWhitespace = @{
            Enable                                  = $true
            CheckInnerBrace                         = $true
            CheckOpenBrace                          = $true
            CheckOpenParen                          = $true
            CheckOperator                           = $true
            CheckPipe                               = $true
            CheckPipeForRedundantWhitespace         = $false
            CheckSeparator                          = $true
            CheckParameter                          = $false
            IgnoreAssignmentOperatorInsideHashTable = $true
        }

        # ---- Naming -------------------------------------------------------
        # Variable PascalCase is enforced by the custom rule below.
        #
        # NOTE: PSUseCorrectCasing (cmdlet/keyword casing) is intentionally
        # NOT enabled here — it is listed in ExcludeRules above because it
        # throws a process-aborting NullReferenceException on this repo's
        # Az-cmdlet-heavy files (see the ExcludeRules comment for the captured
        # stack trace). It only enforced cosmetic cmdlet casing, so nothing of
        # substance is lost. Re-enable if/when the upstream PSSA bug is fixed.

        # Custom rule — see .scriptanalyzer/CustomRules.psm1
        # Flags local variable assignments that don't start with an uppercase
        # letter. Keeps a short allow-list for common iterators and automatic
        # variables. Warning severity so it surfaces without blocking CI.
        'Measure-VariablePascalCase' = @{
            Enable = $true
        }
    }
}
