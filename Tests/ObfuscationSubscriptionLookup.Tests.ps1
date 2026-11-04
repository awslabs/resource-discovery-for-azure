# Subscription lookup tests for -Obfuscate (ResourceInventory.ps1)
# Run with: Invoke-Pester ./Tests/ObfuscationSubscriptionLookup.Tests.ps1 -Output Detailed
#
# The masked id's subscription token is chosen by the subscription's display name,
# looked up by id in $Global:Subscriptions. Get-ObfuscationSubscriptionIndex builds
# that lookup once per list instead of scanning the list for every resource id. The
# tests check that every lookup gives what the list scans gave (Get-ScanName and
# Get-ScanRealSub below are those scans), so the masked ids are the same: for a
# known subscription, an unknown one, an id in different letter case, a list entry
# with no name, a duplicated id, a list entry with no id, and missing or empty ids.
# The functions and the dictionary build are taken from ResourceInventory.ps1 with
# the PowerShell AST. Generic names only; no live Azure.

BeforeAll {
    $Script = Join-Path (Split-Path $PSScriptRoot -Parent) 'ResourceInventory.ps1'
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$null, [ref]$null)
    foreach ($Name in @('Get-ObfuscationPrefix', 'New-ObfuscatedNameToken', 'Get-ObfuscationSubscriptionIndex', 'Test-RdaTenantScopeIdMaskable', 'Get-ObfuscatedResourceId'))
    {
        $Fn = @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq $Name }, $false))
        if ($Fn.Count -ne 1) { throw "$Name was not found in ResourceInventory.ps1." }
        . ([scriptblock]::Create($Fn[0].Extent.Text))
    }

    # The -Obfuscate dictionary build of RunInventorySetup, run as a function.
    $Setup = $Ast.Find({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'RunInventorySetup' }, $true)
    $Build = @($Setup.Body.FindAll({ param($N) $N -is [System.Management.Automation.Language.IfStatementAst] -and $N.Clauses[0].Item1.Extent.Text -eq '$Obfuscate.IsPresent' -and $N.Extent.Text -match 'foreach \(\$resourceItem in \$Global:Resources\)' }, $true))
    if ($Build.Count -ne 1) { throw 'The -Obfuscate dictionary build was not found in RunInventorySetup.' }
    . ([scriptblock]::Create("function Invoke-DictionaryBuild { `$Obfuscate = [switch]`$true; `$ObfuscationDictionary = `$null; $($Build[0].Extent.Text) }"))

    # The list scans the lookup replaced: Get-ObfuscatedResourceId's and the dictionary build's.
    function Get-ScanName([string]$Id) { [string](@($Global:Subscriptions) | Where-Object { $null -ne $_ -and [string]$_.id -eq $Id } | Select-Object -First 1).name }
    function Get-ScanRealSub($SubscriptionId) { ($Global:Subscriptions | Where-Object { $_.id -eq $SubscriptionId }).Name }

    $script:List = @(
        [pscustomobject]@{ id = 'demo-sub-a'; name = 'Demo Subscription A' }
        [pscustomobject]@{ id = 'Demo-Sub-B'; name = 'Demo Subscription B' }
        [pscustomobject]@{ id = 'demo-sub-noname' }
        $null
        [pscustomobject]@{ name = 'Entry With No Id' }
    )
    $script:Child = 'resourcegroups/rg-demo/providers/microsoft.sql/servers/sqlsrv-demo/databases/sqldb-demo'

    function Reset-ObfuscationState([object[]]$Subscriptions)
    {
        $Global:Subscriptions = $Subscriptions
        $Global:ResourceIdDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:ResourceNameDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:ResourceSubscriptionDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:ResourceResourceGroupDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:ObfuscationSubscriptionTokens = @{}
        $Global:ObfuscationResourceGroupTokens = @{}
    }
}

AfterAll {
    foreach ($Name in @('Subscriptions', 'Resources', 'ResourceIdDictionary', 'ResourceNameDictionary', 'ResourceSubscriptionDictionary', 'ResourceResourceGroupDictionary', 'ObfuscationSubscriptionTokens', 'ObfuscationResourceGroupTokens', 'ObfuscationSubscriptionIndex'))
    {
        Remove-Variable -Name $Name -Scope Global -ErrorAction SilentlyContinue
    }
}

Describe 'Get-ObfuscatedResourceId picks the subscription the list scan picked' {
    It 'uses the token of <Expect> for <Label>' -ForEach @(
        @{ Label = 'a known subscription'; Sub = 'demo-sub-a'; Expect = 'Demo Subscription A' }
        @{ Label = 'the id in upper case'; Sub = 'DEMO-SUB-A'; Expect = 'Demo Subscription A' }
        @{ Label = 'an id the list holds in other letter case'; Sub = 'demo-sub-b'; Expect = 'Demo Subscription B' }
        @{ Label = 'a subscription not in the list'; Sub = 'demo-sub-unknown'; Expect = 'demo-sub-unknown' }
        @{ Label = 'a list entry with no name'; Sub = 'demo-sub-noname'; Expect = 'demo-sub-noname' }
    ) {
        Reset-ObfuscationState $script:List
        $Id = "/subscriptions/$Sub/$script:Child"
        $ScanName = Get-ScanName $Sub
        if ([string]::IsNullOrEmpty($ScanName)) { $ScanName = $Sub }
        $ScanName | Should -BeExactly $Expect

        $Masked = Get-ObfuscatedResourceId -ResourceId $Id
        # One token, keyed by the subscription id; the prefix from the name the scan found.
        @($Global:ObfuscationSubscriptionTokens.Keys) | Should -Be @($Sub)
        $Masked.Split('/')[2] | Should -BeExactly $Global:ObfuscationSubscriptionTokens[$Sub]
        $Masked.Split('/')[2] | Should -BeLike ((Get-ObfuscationPrefix $Expect) + '*')
        $Global:ResourceSubscriptionDictionary[$Id] | Should -BeExactly $Global:ObfuscationSubscriptionTokens[$Sub]
    }

    It 'takes the first entry when the list holds an id twice' {
        Reset-ObfuscationState (@($script:List) + [pscustomobject]@{ id = 'DEMO-SUB-A'; name = 'Demo Subscription A Again' })
        Get-ScanName 'demo-sub-a' | Should -BeExactly 'Demo Subscription A'
        $null = Get-ObfuscatedResourceId -ResourceId "/subscriptions/demo-sub-a/$script:Child"
        @($Global:ObfuscationSubscriptionTokens.Keys) | Should -Be @('demo-sub-a')
    }

    It 'returns ''obfuscated'' for a missing or empty id and one token for an id with no subscription, as before' {
        Reset-ObfuscationState $script:List
        Get-ObfuscatedResourceId -ResourceId $null | Should -BeExactly 'obfuscated'
        Get-ObfuscatedResourceId -ResourceId '' | Should -BeExactly 'obfuscated'
        Get-ObfuscatedResourceId -ResourceId '/subscriptions/' | Should -Match '^(prod|nonprod)_[0-9a-f-]{36}$'
        Get-ObfuscatedResourceId -ResourceId 'not-an-arm-id' | Should -Match '^(prod|nonprod)_[0-9a-f-]{36}$'
        $Global:ObfuscationSubscriptionTokens.Count | Should -Be 0
    }

    It 'reads the new list after $Global:Subscriptions is replaced' {
        Reset-ObfuscationState $script:List
        $null = Get-ObfuscatedResourceId -ResourceId "/subscriptions/demo-sub-a/$script:Child"
        Reset-ObfuscationState @([pscustomobject]@{ id = 'demo-sub-a'; name = 'Renamed dev Subscription' })
        $Masked = Get-ObfuscatedResourceId -ResourceId "/subscriptions/demo-sub-a/$script:Child"
        $Masked.Split('/')[2] | Should -BeLike 'nonprod_*' -Because 'the prefix follows the name in the new list'
    }
}

Describe 'The dictionary build picks the subscription the list scan picked' {
    BeforeAll {
        $script:Cases = @(
            @{ Name = 'db-known'; Sub = 'demo-sub-a' }
            @{ Name = 'db-upper'; Sub = 'DEMO-SUB-A' }
            @{ Name = 'db-case'; Sub = 'demo-sub-b' }
            @{ Name = 'db-unknown'; Sub = 'demo-sub-unknown' }
            @{ Name = 'db-noname'; Sub = 'demo-sub-noname' }
            @{ Name = 'db-empty'; Sub = '' }
            @{ Name = 'db-missing'; Sub = $null }
        )
        Reset-ObfuscationState $script:List
        $Global:Resources = @(foreach ($C in $script:Cases)
            {
                [pscustomobject]@{ id = "/subscriptions/demo-sub-a/resourcegroups/rg-demo/providers/microsoft.sql/servers/sqlsrv-demo/databases/$($C.Name)"; name = $C.Name; subscriptionId = $C.Sub; resourceGroup = 'rg-demo' }
            })
        Invoke-DictionaryBuild
    }

    It 'gives <Name> the token of the subscription the scan found, or of its id' -ForEach @(
        @{ Name = 'db-known' }, @{ Name = 'db-upper' }, @{ Name = 'db-case' }, @{ Name = 'db-unknown' }, @{ Name = 'db-noname' }, @{ Name = 'db-empty' }, @{ Name = 'db-missing' }
    ) {
        $Res = @($Global:Resources | Where-Object { $_.name -eq $Name })[0]
        # Keyed by the subscription id; a resource with none by the name the scan found.
        $Expect = if (-not [string]::IsNullOrEmpty($Res.subscriptionId)) { $Res.subscriptionId } else { Get-ScanRealSub $Res.subscriptionId }
        if ($null -eq $Expect) { $Expect = [string]$Res.subscriptionId }
        $Global:ObfuscationSubscriptionTokens.ContainsKey($Expect) | Should -BeTrue
        $Global:ResourceSubscriptionDictionary[$Res.id] | Should -BeExactly $Global:ObfuscationSubscriptionTokens[$Expect]
    }

    It 'matches the list entry with no id only for a resource with no subscription id, as the scan did' {
        Get-ScanRealSub $null | Should -BeExactly 'Entry With No Id'
        $Res = @($Global:Resources | Where-Object { $_.name -eq 'db-missing' })[0]
        $Global:ResourceSubscriptionDictionary[$Res.id] | Should -BeExactly $Global:ObfuscationSubscriptionTokens['Entry With No Id']
    }
}
