# Az context scope tests
# =============================================================================
# Offline tests for the per-subscription cost step (GetResorceConsumption in
# ResourceInventory.ps1), which switches the Az PowerShell context to each
# subscription it collects consumption for.
#
# WHY THIS TEST EXISTS
# --------------------
# With context autosave on (the Az default, scope CurrentUser), Set-AzContext
# without -Scope Process also writes the switch to the user's saved Az
# context, so a run left the user's next PowerShell session pointing at
# whichever subscription the cost step switched to last. The switch must
# apply to this process only, and still target the right subscription.
#
# HOW
# ---
# Set-AzContext, Get-AzContext and Get-UsageAggregates are mocked. The shim
# functions below give Mock something to intercept without the Az modules
# installed or loaded; the Set-AzContext shim accepts the same -Scope values
# as the real cmdlet. GetResorceConsumption is nested inside
# ResourceInventory.ps1, which runs login and collection when invoked, so it
# is lifted out with the PowerShell parser. No live Azure.
#
# The only literal GUID is the Azure docs placeholder; the second subscription
# id is generated at runtime.
#
# Run with: Invoke-Pester ./Tests/AzContextScope.Tests.ps1 -Output Detailed
# =============================================================================

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:CommonFunctions = Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1'
    $script:InventoryScript = Join-Path $script:RepoRoot 'ResourceInventory.ps1'
    foreach ($Required in @($script:CommonFunctions, $script:InventoryScript))
    {
        if (-not (Test-Path -LiteralPath $Required -PathType Leaf)) { throw "Required file not found: $Required" }
    }

    . $script:CommonFunctions

    $Tokens = $null
    $ParseErrors = $null
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:InventoryScript, [ref]$Tokens, [ref]$ParseErrors)
    if (@($ParseErrors).Count -gt 0) { throw ("ResourceInventory.ps1 does not parse: {0}" -f $ParseErrors[0].Message) }
    $ConsumptionFn = $Ast.FindAll({
            param($Node)
            $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'GetResorceConsumption'
        }, $true) | Select-Object -First 1
    if ($null -eq $ConsumptionFn) { throw 'GetResorceConsumption was not found in ResourceInventory.ps1. Has it been renamed or removed?' }
    $script:ConsumptionFunctionText = $ConsumptionFn.Extent.Text

    # Shims for Mock to intercept (see file header).
    function Set-AzContext
    {
        [CmdletBinding(SupportsShouldProcess = $true)]
        param([string]$Subscription, [ValidateSet('Process', 'CurrentUser')][string]$Scope)
        $null = $Subscription, $Scope
    }
    function Get-AzContext { [CmdletBinding()] param() }
    function Get-UsageAggregates
    {
        [CmdletBinding()]
        param($ReportedStartTime, $ReportedEndTime, $AggregationGranularity, [switch]$ShowDetails, $ContinuationToken)
        $null = $ReportedStartTime, $ReportedEndTime, $AggregationGranularity, $ShowDetails, $ContinuationToken
    }

    $script:DocsGuid = '12345678-1234-1234-1234-123456789012'
    $script:OtherSubId = [guid]::NewGuid().ToString()

    $script:TmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('AzContextScopeTest_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $script:TmpRoot -Force | Out-Null

    # A global that did not exist before this file is removed again afterwards,
    # not left behind as $null; the others get their old values back.
    $script:SavedGlobals = @{}
    $script:MissingGlobals = [System.Collections.Generic.List[string]]::new()
    foreach ($Name in 'Subscriptions', 'ConsumptionFileCsv', 'ConsumptionRecordCount', 'ConsumptionFailedSubs', 'ErrorLogFile')
    {
        $Existing = Get-Variable -Scope Global -Name $Name -ErrorAction SilentlyContinue
        if ($null -eq $Existing) { $script:MissingGlobals.Add($Name) }
        else { $script:SavedGlobals[$Name] = $Existing.Value }
    }
    $script:SavedCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
    $script:SavedUICulture = [System.Threading.Thread]::CurrentThread.CurrentUICulture
}

AfterAll {
    foreach ($Name in $script:SavedGlobals.Keys)
    {
        Set-Variable -Scope Global -Name $Name -Value $script:SavedGlobals[$Name]
    }
    foreach ($Name in $script:MissingGlobals)
    {
        Remove-Variable -Scope Global -Name $Name -ErrorAction SilentlyContinue
    }
    [System.Threading.Thread]::CurrentThread.CurrentCulture = $script:SavedCulture
    [System.Threading.Thread]::CurrentThread.CurrentUICulture = $script:SavedUICulture
    if ($script:TmpRoot -and (Test-Path -LiteralPath $script:TmpRoot))
    {
        Get-ChildItem -LiteralPath $script:TmpRoot -Recurse -Force | Sort-Object { $_.FullName.Length } -Descending | Remove-Item -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:TmpRoot -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Consumption step context switch' {

    BeforeAll {
        . ([scriptblock]::Create($script:ConsumptionFunctionText))
        function Test-DataPlaneAuthReady { param([string]$Phase) $null = $Phase; return $true }

        # Get-AzContext reports whatever subscription was switched to last, so the
        # step goes on to query usage instead of skipping the subscription.
        Mock -CommandName Set-AzContext -MockWith { $script:CurrentSubscription = $Subscription }
        Mock -CommandName Get-AzContext -MockWith { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = $script:CurrentSubscription } } }
        Mock -CommandName Get-UsageAggregates -MockWith { [pscustomobject]@{ UsageAggregations = @() } }
    }

    BeforeEach {
        $script:CurrentSubscription = $null
        $Global:Subscriptions = @(
            [pscustomobject]@{ Id = $script:OtherSubId; Name = 'sub-a' }
            [pscustomobject]@{ Id = $script:DocsGuid; Name = 'sub-b' }
        )
        $Global:ConsumptionFileCsv = Join-Path $script:TmpRoot ('Consumption_{0}.csv' -f [guid]::NewGuid().ToString('N').Substring(0, 8))
        $Global:ConsumptionRecordCount = 0
        $Global:ConsumptionFailedSubs = @()
        $Global:ErrorLogFile = $null
        $ResourceGroup = $null
        $Obfuscate = [switch]$false
        $null = $ResourceGroup, $Obfuscate
    }

    It 'switches to the requested subscription for this process only' {
        $SubscriptionID = $script:DocsGuid
        $null = $SubscriptionID

        GetResorceConsumption 6>$null

        @($Global:ConsumptionFailedSubs).Count | Should -Be 0 -Because 'the switch succeeded, so the subscription is not skipped'
        Should -Invoke -CommandName Set-AzContext -Times 1 -Exactly
        Should -Invoke -CommandName Set-AzContext -Times 1 -Exactly -ParameterFilter { $Subscription -eq $script:DocsGuid -and $Scope -eq 'Process' } -Because 'a switch without -Scope Process is also saved as the user''s default subscription'
        Should -Invoke -CommandName Get-UsageAggregates -Times 1 -Exactly
    }

    It 'switches to each subscription in turn for this process only' {
        $SubscriptionID = $null
        $null = $SubscriptionID

        GetResorceConsumption 6>$null

        @($Global:ConsumptionFailedSubs).Count | Should -Be 0
        Should -Invoke -CommandName Set-AzContext -Times 2 -Exactly
        Should -Invoke -CommandName Set-AzContext -Times 1 -Exactly -ParameterFilter { $Subscription -eq $script:OtherSubId -and $Scope -eq 'Process' }
        Should -Invoke -CommandName Set-AzContext -Times 1 -Exactly -ParameterFilter { $Subscription -eq $script:DocsGuid -and $Scope -eq 'Process' }
        Should -Invoke -CommandName Get-UsageAggregates -Times 2 -Exactly
    }
}
