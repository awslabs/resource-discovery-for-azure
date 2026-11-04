# =============================================================================
# CollectorRowObfuscation.Tests.ps1
#
# Offline tests of the -Obfuscate step that masks each collector's rows in
# ResourceInventory.ps1 (CreateResourceJobs). Under the output contract every
# masked id is an ARM-shaped path whose parts are prod_/nonprod_ tokens, and
# a row's Subscription, ResourceGroup and Name are the tokens of its own id
# path. A row whose id the token loop did not mask, and a row with no id at
# all, must get such a path too: never a flat token, never an empty ID.
#
# The step is taken from ResourceInventory.ps1 with the PowerShell AST and run
# against the run's dictionaries set up here. Generic names and the
# documentation placeholder subscription id only.
#
# Run with: Invoke-Pester ./Tests/CollectorRowObfuscation.Tests.ps1 -Output Detailed
# =============================================================================

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers/ContractIdPattern.ps1')
    $Script = Join-Path (Split-Path $PSScriptRoot -Parent) 'ResourceInventory.ps1'
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$null, [ref]$null)
    foreach ($Name in @('Get-ObfuscationPrefix', 'New-ObfuscatedNameToken', 'Get-ObfuscationSubscriptionIndex', 'Get-ObfuscatedResourceId', 'New-ObfuscatedRowIdWithoutId'))
    {
        $Fn = @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq $Name }, $false))
        # A missing helper fails the tests that need it, not the whole file.
        if ($Fn.Count -eq 1) { . ([scriptblock]::Create($Fn[0].Extent.Text)) }
    }
    $Step = @($Ast.FindAll({
                param($N)
                $N -is [System.Management.Automation.Language.IfStatementAst] -and
                $N.Clauses[0].Item1.Extent.Text -eq '$Obfuscate.IsPresent' -and
                $N.Clauses[0].Item2.Extent.Text -match '^\{\s*foreach \(\$resourceItem in \$Result\)'
            }, $true))
    if ($Step.Count -ne 1) { throw 'The -Obfuscate step over the collector rows was not found in ResourceInventory.ps1.' }
    . ([scriptblock]::Create("function Invoke-RowMasking { param(`$Result, `$ModName) `$Obfuscate = [switch]`$true; $($Step[0].Extent.Text); return `$Result }"))

    $script:Sub = '12345678-1234-1234-1234-123456789012'   # Azure docs placeholder
    $script:SubName = 'Demo Subscription'
    $script:Contract = Get-RdaContractIdPattern
    $script:Token = '^(prod|nonprod)_(databricks_|aks_|vmss_)?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

    function Reset-ObfuscationState
    {
        $Global:Subscriptions = @([pscustomobject]@{ id = $script:Sub; name = $script:SubName })
        $Global:ResourceIdDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:ResourceNameDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:ResourceSubscriptionDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:ResourceResourceGroupDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:ObfuscationSubscriptionTokens = @{}
        $Global:ObfuscationResourceGroupTokens = @{}
        $Global:ObfuscationSubscriptionIndex = $null
    }

    function New-Row
    {
        param([string]$Id, [string]$Name = 'plan-a', [string]$Rg = 'rg-demo')
        @{ ID = $Id; Name = $Name; Subscription = $script:SubName; ResourceGroup = $Rg; Tags = @{ owner = 'team' } }
    }

    # The row's Subscription, ResourceGroup and Name are the tokens of its own id.
    function Assert-FieldsMatchPath
    {
        param($Row)
        $Parts = $Row.ID -split '/'
        $Row.Subscription | Should -BeExactly $Parts[2]
        $Row.ResourceGroup | Should -BeExactly $Parts[4]
        $Row.Name | Should -BeExactly $Parts[-1]
    }
}

AfterAll {
    foreach ($Name in @('Subscriptions', 'ResourceIdDictionary', 'ResourceNameDictionary', 'ResourceSubscriptionDictionary', 'ResourceResourceGroupDictionary', 'ObfuscationSubscriptionTokens', 'ObfuscationResourceGroupTokens', 'ObfuscationSubscriptionIndex'))
    {
        Remove-Variable -Name $Name -Scope Global -ErrorAction SilentlyContinue
    }
}

Describe 'Masking the collector rows under -Obfuscate' {
    BeforeEach { Reset-ObfuscationState }

    It 'keeps the token loop''s masked id and tokens for a discovered resource (control)' {
        $Id = "/subscriptions/$script:Sub/resourcegroups/rg-demo/providers/microsoft.web/serverfarms/plan-a"
        $Masked = Get-ObfuscatedResourceId -ResourceId $Id
        $Global:ResourceIdDictionary[$Id] = $Masked
        $Row = @(Invoke-RowMasking -Result @(New-Row -Id $Id) -ModName 'AppServicePlan')[0]
        $Row.ID | Should -BeExactly $Masked
        Assert-FieldsMatchPath $Row
    }

    It 'gives a row whose id the token loop did not mask a masked ARM path, not a flat token' {
        $Id = "/subscriptions/$script:Sub/resourcegroups/rg-demo/providers/microsoft.web/serverfarms/plan-b"
        $Row = @(Invoke-RowMasking -Result @(New-Row -Id $Id -Name 'plan-b') -ModName 'AppServicePlan')[0]
        $Row.ID | Should -Match $script:Contract
        $Row.ID | Should -Not -Match 'plan-b|rg-demo|12345678-1234'
        Assert-FieldsMatchPath $Row
        $Global:ResourceIdDictionary[$Id] | Should -BeExactly $Row.ID -Because 'consumption rows of the same resource reuse this id'
    }

    It 'uses the run''s subscription and resource group tokens for that row, the ones the other rows of the group get' {
        $Other = Get-ObfuscatedResourceId -ResourceId "/subscriptions/$script:Sub/resourcegroups/rg-demo/providers/microsoft.compute/virtualmachines/vm-a"
        $Id = "/subscriptions/$script:Sub/resourcegroups/rg-demo/providers/microsoft.web/serverfarms/plan-b"
        $Row = @(Invoke-RowMasking -Result @(New-Row -Id $Id -Name 'plan-b') -ModName 'AppServicePlan')[0]
        ($Row.ID -split '/')[2] | Should -BeExactly ($Other -split '/')[2]
        ($Row.ID -split '/')[4] | Should -BeExactly ($Other -split '/')[4]
    }

    It 'gives a dev-named row nonprod_ tokens' {
        $Id = "/subscriptions/$script:Sub/resourcegroups/rg-dev/providers/microsoft.web/serverfarms/plan-dev"
        $Row = @(Invoke-RowMasking -Result @(New-Row -Id $Id -Name 'plan-dev' -Rg 'rg-dev') -ModName 'AppServicePlan')[0]
        $Row.ResourceGroup | Should -Match '^nonprod_'
        $Row.Name | Should -Match '^nonprod_'
    }

    It 'gives a row with no id a non-empty masked ARM path in its own subscription and resource group, and clears its tags' {
        $Other = Get-ObfuscatedResourceId -ResourceId "/subscriptions/$script:Sub/resourcegroups/rg-demo/providers/microsoft.compute/virtualmachines/vm-a"
        foreach ($Empty in @($null, ''))
        {
            $Row = @(Invoke-RowMasking -Result @(New-Row -Id $Empty) -ModName 'AppServicePlan')[0]
            $Row.ID | Should -Not -BeNullOrEmpty
            $Row.ID | Should -Match $script:Contract
            $Row.ID | Should -Match '/providers/rda\.noid/appserviceplan/'
            Assert-FieldsMatchPath $Row
            $Row.Subscription | Should -BeExactly ($Other -split '/')[2]
            $Row.ResourceGroup | Should -BeExactly ($Other -split '/')[4]
            $Row.Tags | Should -BeNullOrEmpty
        }
    }

    It 'gives a row with no id, subscription or group still a full masked path' {
        $Row = @(Invoke-RowMasking -Result @(@{ ID = ''; Name = ''; Subscription = ''; ResourceGroup = '' }) -ModName 'AppServicePlan')[0]
        $Row.ID | Should -Match $script:Contract
        Assert-FieldsMatchPath $Row
    }

    It 'never writes a token without a prod_ or nonprod_ start' {
        $Id = "/subscriptions/$script:Sub/resourcegroups/rg-demo/providers/microsoft.web/serverfarms/plan-c"
        $Global:ResourceIdDictionary[$Id] = ''
        $Global:ResourceNameDictionary[$Id] = ''
        $Rows = @(Invoke-RowMasking -Result @((New-Row -Id $Id -Name 'plan-c'), (New-Row -Id '')) -ModName 'AppServicePlan')
        foreach ($Row in $Rows)
        {
            $Row.ID | Should -Match $script:Contract
            foreach ($F in @('Name', 'Subscription', 'ResourceGroup')) { $Row.$F | Should -Match $script:Token }
        }
    }
}
