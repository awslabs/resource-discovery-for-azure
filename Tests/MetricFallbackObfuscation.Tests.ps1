# =============================================================================
# MetricFallbackObfuscation.Tests.ps1
#
# Offline tests of the -Obfuscate step in Extension/Metrics.ps1 that masks a
# metric row whose resource id is not in the run's id dictionary (the
# fallback). Under the output contract the row's ID is the masked ARM path
# the inventory and consumption rows use, with the run's own subscription and
# resource group tokens, and its Subscription, ResourceGroup and Name are the
# tokens of that path. The prod_/nonprod_ prefix follows the inventory's rule.
#
# The step is taken from Extension/Metrics.ps1 with the PowerShell AST and run
# with the token functions of ResourceInventory.ps1, as in a real run.
# Generic names and the documentation placeholder subscription id only.
#
# Run with: Invoke-Pester ./Tests/MetricFallbackObfuscation.Tests.ps1 -Output Detailed
# =============================================================================

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers/ContractIdPattern.ps1')
    $Root = Split-Path $PSScriptRoot -Parent
    $InvAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'ResourceInventory.ps1'), [ref]$null, [ref]$null)
    foreach ($Name in @('Get-ObfuscationPrefix', 'New-ObfuscatedNameToken', 'Get-ObfuscationSubscriptionIndex', 'Get-ObfuscatedResourceId'))
    {
        $Fn = @($InvAst.FindAll({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq $Name }, $false))
        if ($Fn.Count -ne 1) { throw "$Name was not found in ResourceInventory.ps1." }
        . ([scriptblock]::Create($Fn[0].Extent.Text))
    }
    $MetAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'Extension/Metrics.ps1'), [ref]$null, [ref]$null)
    $Step = @($MetAst.FindAll({
                param($N)
                $N -is [System.Management.Automation.Language.IfStatementAst] -and
                $N.Clauses[0].Item1.Extent.Text -eq '$Obfuscate' -and
                $N.Clauses[0].Item2.Extent.Text -match '^\{\s*foreach \(\$metric in \$Tmp\.Metrics\)'
            }, $true))
    if ($Step.Count -ne 1) { throw 'The -Obfuscate step over the metric rows was not found in Extension/Metrics.ps1.' }
    $script:Step = $Step
    . ([scriptblock]::Create("function Invoke-MetricMasking { param(`$Tmp) `$Obfuscate = `$true; `$ResourceIdDictionary = `$Global:ResourceIdDictionary; `$ResourceNameDictionary = `$Global:ResourceNameDictionary; `$ResourceSubDictionary = `$Global:ResourceSubscriptionDictionary; `$ResourceGroupDictionary = `$Global:ResourceResourceGroupDictionary; $($Step[0].Extent.Text); return `$Tmp }"))

    $script:Sub = '12345678-1234-1234-1234-123456789012'   # Azure docs placeholder
    $script:SubName = 'Demo Subscription'
    $script:Contract = Get-RdaContractIdPattern

    # The run's dictionaries as Variables (ResourceInventory.ps1) builds them:
    # keyed by real id, ignoring case.
    function Reset-ObfuscationState
    {
        $Global:Subscriptions = @([pscustomobject]@{ id = $script:Sub; name = $script:SubName })
        $Global:ResourceIdDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $Global:ResourceNameDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $Global:ResourceSubscriptionDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $Global:ResourceResourceGroupDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $Global:ObfuscationSubscriptionTokens = @{}
        $Global:ObfuscationResourceGroupTokens = @{}
        $Global:ObfuscationSubscriptionIndex = $null
        $script:MetricsFallbackSubCache = $null
        $script:MetricsFallbackRgCache = $null
        $script:MetricsFallbackNameCache = $null
    }

    function New-MetricSet
    {
        param([string[]]$Id)
        $List = [System.Collections.Generic.List[object]]::new()
        foreach ($I in $Id) { $List.Add([pscustomobject]@{ ID = $I; Name = ($I -split '/')[-1]; Subscription = $script:SubName; ResourceGroup = ($I -split '/')[4]; MetricValue = 1.5 }) }
        [pscustomobject]@{ Metrics = $List }
    }
}

AfterAll {
    foreach ($Name in @('Subscriptions', 'ResourceIdDictionary', 'ResourceNameDictionary', 'ResourceSubscriptionDictionary', 'ResourceResourceGroupDictionary', 'ObfuscationSubscriptionTokens', 'ObfuscationResourceGroupTokens', 'ObfuscationSubscriptionIndex'))
    {
        Remove-Variable -Name $Name -Scope Global -ErrorAction SilentlyContinue
    }
}

Describe 'Masking a metric row whose resource the inventory does not hold' {
    BeforeEach { Reset-ObfuscationState }

    It 'gives it the masked ARM path with the fields equal to the path''s own tokens' {
        $Id = "/subscriptions/$script:Sub/resourcegroups/rg-demo/providers/microsoft.web/sites/app-a"
        $Row = @((Invoke-MetricMasking -Tmp (New-MetricSet -Id $Id)).Metrics)[0]
        $Row.ID | Should -Match $script:Contract
        $Parts = $Row.ID -split '/'
        $Row.Subscription | Should -BeExactly $Parts[2]
        $Row.ResourceGroup | Should -BeExactly $Parts[4]
        $Row.Name | Should -BeExactly $Parts[-1]
        $Row.MetricValue | Should -Be 1.5
    }

    It 'uses the subscription and resource group tokens the inventory rows of that group get' {
        $Inventory = Get-ObfuscatedResourceId -ResourceId "/subscriptions/$script:Sub/resourcegroups/rg-demo/providers/microsoft.compute/virtualmachines/vm-a"
        $Row = @((Invoke-MetricMasking -Tmp (New-MetricSet -Id "/subscriptions/$script:Sub/resourcegroups/rg-demo/providers/microsoft.web/sites/app-a")).Metrics)[0]
        ($Row.ID -split '/')[2] | Should -BeExactly ($Inventory -split '/')[2]
        ($Row.ID -split '/')[4] | Should -BeExactly ($Inventory -split '/')[4]
        $Row.Subscription | Should -BeExactly $Global:ObfuscationSubscriptionTokens[$script:SubName]
    }

    It 'gives a group named with the short d- rule the nonprod_ prefix, as the inventory does' {
        $Row = @((Invoke-MetricMasking -Tmp (New-MetricSet -Id "/subscriptions/$script:Sub/resourcegroups/d-web/providers/microsoft.web/sites/app-b")).Metrics)[0]
        $Row.ResourceGroup | Should -Match '^nonprod_'
        $Row.ResourceGroup | Should -BeExactly $Global:ObfuscationResourceGroupTokens['d-web']
    }

    It 'gives one resource one id for all of its metric rows, the one consumption then reuses' {
        $Id = "/subscriptions/$script:Sub/resourcegroups/rg-demo/providers/microsoft.web/sites/app-a"
        $Rows = @((Invoke-MetricMasking -Tmp (New-MetricSet -Id @($Id, $Id))).Metrics)
        $Rows[0].ID | Should -BeExactly $Rows[1].ID
        $Global:ResourceIdDictionary[$Id] | Should -BeExactly $Rows[0].ID
    }

    It 'keeps the inventory''s masked id for a metric that gives the id in other casing' {
        $Id = "/subscriptions/$script:Sub/resourcegroups/rg-demo/providers/microsoft.compute/virtualmachines/vm-a"
        $Global:ResourceIdDictionary[$Id] = Get-ObfuscatedResourceId -ResourceId $Id
        $Row = @((Invoke-MetricMasking -Tmp (New-MetricSet -Id "/subscriptions/$script:Sub/resourceGroups/RG-Demo/providers/Microsoft.Compute/virtualMachines/VM-A")).Metrics)[0]
        $Row.ID | Should -BeExactly $Global:ResourceIdDictionary[$Id]
        @($Global:ResourceIdDictionary.Keys).Count | Should -Be 1
    }

    It 'has one way to mask a fallback row: the run''s Get-ObfuscatedResourceId, never private token caches' {
        $script:Step[0].Extent.Text | Should -Match 'Get-ObfuscatedResourceId -ResourceId \$OriginalId'
        $script:Step[0].Extent.Text | Should -Not -Match 'MetricsFallback(Sub|Rg|Name)Cache|Build-ObfuscatedResourceUri'
    }

    It 'stops before any Azure call when run on its own with -Obfuscate' {
        $Pwsh = (Get-Process -Id $PID).Path
        $Script = Join-Path (Split-Path $PSScriptRoot -Parent) 'Extension/Metrics.ps1'
        $Cmd = "function Get-AzContext { 'azure-called' }; function Invoke-AzRestMethod { 'azure-called' }; try { & '$Script' -Subscriptions @() -Resources @() -Task 'Processing' -ConcurrencyLimit 1 -FilePath 'x' -Obfuscate `$true; 'no-stop' } catch { 'STOP ' + `$_.Exception.Message }"
        $Out = @(& $Pwsh -NoProfile -NonInteractive -Command $Cmd 2>&1 | ForEach-Object { [string]$_ })
        ($Out -join "`n") | Should -Match 'STOP Metrics\.ps1 -Obfuscate needs Get-ObfuscatedResourceId'
        ($Out -join "`n") | Should -Not -Match 'azure-called|no-stop'
    }

    It 'keeps the inventory''s masked id for a resource the inventory holds (control)' {
        $Id = "/subscriptions/$script:Sub/resourcegroups/rg-demo/providers/microsoft.compute/virtualmachines/vm-a"
        $Global:ResourceIdDictionary[$Id] = Get-ObfuscatedResourceId -ResourceId $Id
        $Row = @((Invoke-MetricMasking -Tmp (New-MetricSet -Id $Id)).Metrics)[0]
        $Row.ID | Should -BeExactly $Global:ResourceIdDictionary[$Id]
    }
}
