# =============================================================================
# SubscriptionTokenById.Tests.ps1
#
# Under -Obfuscate the subscription token is keyed by subscription id, so two
# subscriptions that share a display name (two "Pay-As-You-Go", say) get two
# tokens, and anything that reads the subscription from the id path still
# sees two subscriptions. One subscription keeps one token in
# every file: the inventory ID, a consumption ResourceId, a metric ID and the
# ResourceIdMap keys. The prod_/nonprod_ prefix still comes from the name.
#
# The run's steps are taken from ResourceInventory.ps1 and Extension/Metrics.ps1
# with the PowerShell AST. Generic names and placeholder ids only.
#
# Run with: Invoke-Pester ./Tests/SubscriptionTokenById.Tests.ps1 -Output Detailed
# =============================================================================

BeforeAll {
    $Root = Split-Path $PSScriptRoot -Parent
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'ResourceInventory.ps1'), [ref]$null, [ref]$null)
    foreach ($Name in @('Get-ObfuscationPrefix', 'New-ObfuscatedNameToken', 'Get-ObfuscationSubscriptionIndex', 'Test-RdaTenantScopeIdMaskable', 'Get-ObfuscatedResourceId', 'Test-ObfuscatedIdShape'))
    {
        $Fn = @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq $Name }, $false))
        if ($Fn.Count -eq 1) { . ([scriptblock]::Create($Fn[0].Extent.Text)) }
    }
    $Vars = $Ast.Find({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'Variables' }, $false)
    . ([scriptblock]::Create("function Invoke-RunVariables { `$Obfuscate = [switch]`$true; $($Vars.Body.Extent.Text.Substring(1, $Vars.Body.Extent.Text.Length - 2)) }"))
    $Setup = $Ast.Find({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'RunInventorySetup' }, $true)
    $Build = @($Setup.Body.FindAll({ param($N) $N -is [System.Management.Automation.Language.IfStatementAst] -and $N.Clauses[0].Item1.Extent.Text -eq '$Obfuscate.IsPresent' -and $N.Extent.Text -match 'foreach \(\$resourceItem in \$(Global:Resources|TokenLoopRows)\)' }, $true))
    . ([scriptblock]::Create("function Invoke-DictionaryBuild { param(`$Seed) `$Obfuscate = [switch]`$true; `$ObfuscationDictionary = `$Seed; function Write-Log { param(`$Message, `$Severity) if (`$Severity -eq 'Warning') { `$script:BuildWarnings.Add([string]`$Message) } }; $($Build[0].Extent.Text) }"))
    $script:BuildWarnings = [System.Collections.Generic.List[string]]::new()
    $MetAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'Extension/Metrics.ps1'), [ref]$null, [ref]$null)
    $Step = @($MetAst.FindAll({ param($N) $N -is [System.Management.Automation.Language.IfStatementAst] -and $N.Clauses[0].Item1.Extent.Text -eq '$Obfuscate' -and $N.Clauses[0].Item2.Extent.Text -match '^\{\s*foreach \(\$metric in \$Tmp\.Metrics\)' }, $true))
    . ([scriptblock]::Create("function Invoke-MetricMasking { param(`$Tmp) `$Obfuscate = `$true; `$ResourceIdDictionary = `$Global:ResourceIdDictionary; `$ResourceNameDictionary = `$Global:ResourceNameDictionary; `$ResourceSubDictionary = `$Global:ResourceSubscriptionDictionary; `$ResourceGroupDictionary = `$Global:ResourceResourceGroupDictionary; $($Step[0].Extent.Text); return `$Tmp }"))
    function GetLocalVersion { '0.0.0-test' }

    $script:SubA = '11111111-1111-1111-1111-111111111111'
    $script:SubB = '22222222-2222-2222-2222-222222222222'
    function script:Get-Id { param([string]$Sub, [string]$Type, [string]$Name) "/subscriptions/$Sub/resourcegroups/rg-shared/providers/$Type/$Name" }
}

AfterAll {
    Remove-Variable -Scope Global -Name Subscriptions, Resources, ResourceIdDictionary, ResourceNameDictionary, ResourceSubscriptionDictionary, ResourceResourceGroupDictionary, TagValueDictionary, FreeTextDictionary, ObfuscationSubscriptionTokens, ObfuscationResourceGroupTokens, ObfuscationSubscriptionIndex, ResourceCount, ResourceContainers, ReportName, Version, RawRepo, TableStyle -ErrorAction SilentlyContinue
}

Describe 'Two subscriptions with one display name' {
    BeforeAll {
        Invoke-RunVariables
        $Global:Subscriptions = @([pscustomobject]@{ id = $script:SubA; name = 'Pay-As-You-Go' }, [pscustomobject]@{ id = $script:SubB; name = 'Pay-As-You-Go' })
        $Global:ObfuscationSubscriptionIndex = $null
        $script:VmA = Get-Id $script:SubA 'microsoft.compute/virtualmachines' 'vm-a'
        $script:VmB = Get-Id $script:SubB 'microsoft.compute/virtualmachines' 'vm-b'
        $Global:Resources = @(
            [pscustomobject]@{ id = $script:VmA; name = 'vm-a'; subscriptionId = $script:SubA; resourceGroup = 'rg-shared' }
            [pscustomobject]@{ id = $script:VmB; name = 'vm-b'; subscriptionId = $script:SubB; resourceGroup = 'rg-shared' }
        )
        Invoke-DictionaryBuild
        $script:TokA = ($Global:ResourceIdDictionary[$script:VmA] -split '/')[2]
        $script:TokB = ($Global:ResourceIdDictionary[$script:VmB] -split '/')[2]
    }

    It 'get two subscription tokens in the inventory ids' {
        $script:TokA | Should -Not -BeNullOrEmpty
        $script:TokA | Should -Not -BeExactly $script:TokB
    }

    It 'give each inventory row the subscription token of its own id' {
        $Global:ResourceSubscriptionDictionary[$script:VmA] | Should -BeExactly $script:TokA
        $Global:ResourceSubscriptionDictionary[$script:VmB] | Should -BeExactly $script:TokB
    }

    It 'keep one token per subscription in a consumption ResourceId of a resource outside the inventory' {
        ((Get-ObfuscatedResourceId -ResourceId (Get-Id $script:SubA 'microsoft.compute/disks' 'disk-a')) -split '/')[2] | Should -BeExactly $script:TokA
        ((Get-ObfuscatedResourceId -ResourceId (Get-Id $script:SubB 'microsoft.compute/disks' 'disk-b')) -split '/')[2] | Should -BeExactly $script:TokB
    }

    It 'keep one token per subscription in a metric id outside the inventory, and in its Subscription field' {
        $List = [System.Collections.Generic.List[object]]::new()
        $List.Add([pscustomobject]@{ ID = (Get-Id $script:SubB 'microsoft.web/sites' 'app-b'); Name = 'app-b'; Subscription = 'Pay-As-You-Go'; ResourceGroup = 'rg-shared'; MetricValue = 1 })
        $Row = @((Invoke-MetricMasking -Tmp ([pscustomobject]@{ Metrics = $List })).Metrics)[0]
        ($Row.ID -split '/')[2] | Should -BeExactly $script:TokB
        $Row.Subscription | Should -BeExactly $script:TokB
    }

    It 'keep one token per subscription across every ResourceIdMap key' {
        $Keys = @($Global:ResourceIdDictionary.Keys | ForEach-Object { [pscustomobject]@{ Sub = ($_ -split '/')[2]; Tok = ($Global:ResourceIdDictionary[$_] -split '/')[2] } })
        foreach ($Group in @($Keys | Group-Object Sub)) { @($Group.Group.Tok | Select-Object -Unique).Count | Should -Be 1 -Because "subscription $($Group.Name)" }
        @($Keys.Tok | Select-Object -Unique).Count | Should -Be 2
    }

    It 'keep the prefix rule from the name' {
        $script:TokA | Should -BeLike 'prod_*'
        Invoke-RunVariables
        $Global:Subscriptions = @([pscustomobject]@{ id = $script:SubA; name = 'dev Subscription' })
        $Global:ObfuscationSubscriptionIndex = $null
        ((Get-ObfuscatedResourceId -ResourceId $script:VmA) -split '/')[2] | Should -BeLike 'nonprod_*'
    }
}

Describe 'Two subscriptions with one display name, in a seeded run' {
    It 'keep each subscription''s seeded token for its new rows, though the name map cannot tell them apart' {
        $TokA = 'prod_' + [guid]::NewGuid().ToString(); $TokB = 'prod_' + [guid]::NewGuid().ToString(); $Rg = 'prod_' + [guid]::NewGuid().ToString()
        $VmA = Get-Id $script:SubA 'microsoft.compute/virtualmachines' 'vm-a'
        $VmB = Get-Id $script:SubB 'microsoft.compute/virtualmachines' 'vm-b'
        $Seed = Join-Path ([System.IO.Path]::GetTempPath()) ('rda-subseed-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
        @{
            ResourceIdMap       = @{ "/subscriptions/$TokA/resourcegroups/$Rg/providers/microsoft.compute/virtualmachines/prod_$([guid]::NewGuid())" = $VmA; "/subscriptions/$TokB/resourcegroups/$Rg/providers/microsoft.compute/virtualmachines/prod_$([guid]::NewGuid())" = $VmB }
            SubscriptionNameMap = @{ $TokA = 'Pay-As-You-Go'; $TokB = 'Pay-As-You-Go' }
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Seed -Encoding utf8
        try
        {
            Invoke-RunVariables
            $Global:Subscriptions = @([pscustomobject]@{ id = $script:SubA; name = 'Pay-As-You-Go' }, [pscustomobject]@{ id = $script:SubB; name = 'Pay-As-You-Go' })
            $Global:ObfuscationSubscriptionIndex = $null
            $DiskA = Get-Id $script:SubA 'microsoft.compute/disks' 'disk-a'
            $DiskB = Get-Id $script:SubB 'microsoft.compute/disks' 'disk-b'
            $Global:Resources = @(
                [pscustomobject]@{ id = $VmA; name = 'vm-a'; subscriptionId = $script:SubA; resourceGroup = 'rg-shared' }
                [pscustomobject]@{ id = $VmB; name = 'vm-b'; subscriptionId = $script:SubB; resourceGroup = 'rg-shared' }
                [pscustomobject]@{ id = $DiskA; name = 'disk-a'; subscriptionId = $script:SubA; resourceGroup = 'rg-shared' }
                [pscustomobject]@{ id = $DiskB; name = 'disk-b'; subscriptionId = $script:SubB; resourceGroup = 'rg-shared' }
            )
            Invoke-DictionaryBuild -Seed $Seed
            ($Global:ResourceIdDictionary[$DiskA] -split '/')[2] | Should -BeExactly $TokA
            ($Global:ResourceIdDictionary[$DiskB] -split '/')[2] | Should -BeExactly $TokB
        }
        finally { Remove-Item -LiteralPath $Seed -ErrorAction SilentlyContinue }
    }
}

Describe 'An older seed that gave two subscriptions with one display name one token' {
    It 'gives them two tokens again, and the next two seeded runs keep them' {
        $Shared = 'prod_' + [guid]::NewGuid().ToString(); $Rg = 'prod_' + [guid]::NewGuid().ToString()
        $VmA = Get-Id $script:SubA 'microsoft.compute/virtualmachines' 'vm-a'
        $VmB = Get-Id $script:SubB 'microsoft.compute/virtualmachines' 'vm-b'
        $Ids = @{ "/subscriptions/$Shared/resourcegroups/$Rg/providers/microsoft.compute/virtualmachines/prod_$([guid]::NewGuid())" = $VmA; "/subscriptions/$Shared/resourcegroups/$Rg/providers/microsoft.compute/virtualmachines/prod_$([guid]::NewGuid())" = $VmB }
        $SeedMaps = @{ ResourceIdMap = $Ids; SubscriptionNameMap = @{ $Shared = 'Pay-As-You-Go' } }
        $First = $null
        foreach ($Run in 1, 2, 3)
        {
            $script:BuildWarnings.Clear()
            $Seed = Join-Path ([System.IO.Path]::GetTempPath()) ('rda-subseed-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
            $SeedMaps | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Seed -Encoding utf8
            try
            {
                Invoke-RunVariables
                $Global:Subscriptions = @([pscustomobject]@{ id = $script:SubA; name = 'Pay-As-You-Go' }, [pscustomobject]@{ id = $script:SubB; name = 'Pay-As-You-Go' })
                $Global:ObfuscationSubscriptionIndex = $null
                $Global:Resources = @(
                    [pscustomobject]@{ id = $VmA; name = 'vm-a'; subscriptionId = $script:SubA; resourceGroup = 'rg-shared' }
                    [pscustomobject]@{ id = $VmB; name = 'vm-b'; subscriptionId = $script:SubB; resourceGroup = 'rg-shared' }
                )
                Invoke-DictionaryBuild -Seed $Seed
            }
            finally { Remove-Item -LiteralPath $Seed -ErrorAction SilentlyContinue }
            $A = ($Global:ResourceIdDictionary[$VmA] -split '/')[2]; $B = ($Global:ResourceIdDictionary[$VmB] -split '/')[2]
            $Drop = @($script:BuildWarnings | Where-Object { $_ -match 'seeded id\(s\)' })
            if ($Run -eq 1) { $Drop | Should -Match '^Obfuscation dictionary: 2 seeded id\(s\)' -Because 'both ids holding the shared token are dropped' }
            else { $Drop | Should -BeNullOrEmpty -Because "run $Run keeps every id: the loop has ended" }
            $A | Should -Not -BeExactly $B -Because "run $Run"
            $A | Should -Not -BeExactly $Shared
            if ($Run -eq 1) { $First = @($A, $B) } else { @($A, $B) | Should -Be $First -Because "run $Run keeps run 1's tokens" }
            # The next seed, as the run's dictionary file holds it.
            $NextIds = @{}; foreach ($K in @($Global:ResourceIdDictionary.Keys)) { $NextIds[$Global:ResourceIdDictionary[$K]] = $K }
            $SeedMaps = @{ ResourceIdMap = $NextIds; SubscriptionNameMap = @{ $A = 'Pay-As-You-Go'; $B = 'Pay-As-You-Go' } }
        }
    }
}

Describe 'A row whose subscriptionId is missing' {
    It 'takes its subscription token from its own id' {
        Invoke-RunVariables
        $Global:Subscriptions = @([pscustomobject]@{ id = $script:SubA; name = 'Sub A' })
        $Global:ObfuscationSubscriptionIndex = $null
        $Vm = Get-Id $script:SubA 'microsoft.compute/virtualmachines' 'vm-a'
        $Global:Resources = @([pscustomobject]@{ id = $Vm; name = 'vm-a'; subscriptionId = $null; resourceGroup = 'rg-shared' })
        Invoke-DictionaryBuild
        $Global:ResourceSubscriptionDictionary[$Vm] | Should -BeExactly ($Global:ResourceIdDictionary[$Vm] -split '/')[2]
    }
}

Describe 'A seed whose name map gives a renamed subscription''s old name' {
    It 'does not give that token to the subscription that has the old name now' {
        $SubC = '33333333-3333-3333-3333-333333333333'
        $TokA = 'prod_' + [guid]::NewGuid().ToString(); $Rg = 'prod_' + [guid]::NewGuid().ToString()
        $VmA = Get-Id $script:SubA 'microsoft.compute/virtualmachines' 'vm-a'
        $VmC = Get-Id $SubC 'microsoft.compute/virtualmachines' 'vm-c'
        $Seed = Join-Path ([System.IO.Path]::GetTempPath()) ('rda-subseed-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
        @{ ResourceIdMap = @{ "/subscriptions/$TokA/resourcegroups/$Rg/providers/microsoft.compute/virtualmachines/prod_$([guid]::NewGuid())" = $VmA }; SubscriptionNameMap = @{ $TokA = 'Foo' } } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Seed -Encoding utf8
        try
        {
            Invoke-RunVariables
            $Global:Subscriptions = @([pscustomobject]@{ id = $script:SubA; name = 'Bar' }, [pscustomobject]@{ id = $SubC; name = 'Foo' })
            $Global:ObfuscationSubscriptionIndex = $null
            $Global:Resources = @(
                [pscustomobject]@{ id = $VmA; name = 'vm-a'; subscriptionId = $script:SubA; resourceGroup = 'rg-shared' }
                [pscustomobject]@{ id = $VmC; name = 'vm-c'; subscriptionId = $SubC; resourceGroup = 'rg-shared' }
            )
            Invoke-DictionaryBuild -Seed $Seed
        }
        finally { Remove-Item -LiteralPath $Seed -ErrorAction SilentlyContinue }
        ($Global:ResourceIdDictionary[$VmA] -split '/')[2] | Should -BeExactly $TokA
        ($Global:ResourceIdDictionary[$VmC] -split '/')[2] | Should -Not -BeExactly $TokA
    }
}

Describe 'A seed whose renamed subscription''s ids are all of an older shape' {
    It 'still does not give its token by name to the subscription that has the old name now' {
        $SubC = '33333333-3333-3333-3333-333333333333'
        $TokA = 'prod_' + [guid]::NewGuid().ToString()
        $VmA = Get-Id $script:SubA 'microsoft.sql/servers' 'srv-a'
        $VmC = Get-Id $SubC 'microsoft.compute/virtualmachines' 'vm-c'
        # Older shape: the server's real name left in the id (dropped by the shape check).
        $Old = "/subscriptions/$TokA/resourcegroups/prod_$([guid]::NewGuid())/providers/microsoft.sql/servers/srv-a/databases/prod_$([guid]::NewGuid())"
        $Seed = Join-Path ([System.IO.Path]::GetTempPath()) ('rda-subseed-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
        @{ ResourceIdMap = @{ $Old = "$VmA/databases/db-a" }; SubscriptionNameMap = @{ $TokA = 'Foo' } } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Seed -Encoding utf8
        try
        {
            Invoke-RunVariables
            $Global:Subscriptions = @([pscustomobject]@{ id = $script:SubA; name = 'Bar' }, [pscustomobject]@{ id = $SubC; name = 'Foo' })
            $Global:ObfuscationSubscriptionIndex = $null
            $DbA = Get-Id $script:SubA 'microsoft.compute/virtualmachines' 'vm-a2'
            $Global:Resources = @(
                [pscustomobject]@{ id = $VmC; name = 'vm-c'; subscriptionId = $SubC; resourceGroup = 'rg-shared' }
                [pscustomobject]@{ id = $DbA; name = 'vm-a2'; subscriptionId = $script:SubA; resourceGroup = 'rg-shared' }
            )
            $script:BuildWarnings.Clear()
            Invoke-DictionaryBuild -Seed $Seed
        }
        finally { Remove-Item -LiteralPath $Seed -ErrorAction SilentlyContinue }
        @($script:BuildWarnings | Where-Object { $_ -match '^Obfuscation dictionary: 1 seeded id\(s\)' }).Count | Should -Be 1 -Because 'the older-shape id is dropped'
        ($Global:ResourceIdDictionary[$VmC] -split '/')[2] | Should -Not -BeExactly $TokA
        ($Global:ResourceIdDictionary[$DbA] -split '/')[2] | Should -Not -BeExactly ($Global:ResourceIdDictionary[$VmC] -split '/')[2] -Because 'A and C keep two tokens'
    }
}

Describe 'An older seed whose shared-name subscriptions have one good and one older-shape id' {
    It 'gives the two subscriptions two tokens in the first seeded run, and the next two keep them (good id in the <Good> subscription)' -ForEach @(@{ Good = 'kept-name' }, @{ Good = 'renamed' }) {
        $Shared = 'prod_' + [guid]::NewGuid().ToString(); $Rg = 'prod_' + [guid]::NewGuid().ToString()
        $VmA = Get-Id $script:SubA 'microsoft.compute/virtualmachines' 'vm-a'
        $DbB = (Get-Id $script:SubB 'microsoft.sql/servers' 'srv-b') + '/databases/db-b'
        $VmB = Get-Id $script:SubB 'microsoft.compute/virtualmachines' 'vm-b'
        $DbA = (Get-Id $script:SubA 'microsoft.sql/servers' 'srv-a') + '/databases/db-a'
        $Ids = @{}
        if ($Good -eq 'kept-name')
        {
            $Ids["/subscriptions/$Shared/resourcegroups/$Rg/providers/microsoft.compute/virtualmachines/prod_$([guid]::NewGuid())"] = $VmA
            $Ids["/subscriptions/$Shared/resourcegroups/$Rg/providers/microsoft.sql/servers/srv-b/databases/prod_$([guid]::NewGuid())"] = $DbB
        }
        else
        {
            $Ids["/subscriptions/$Shared/resourcegroups/$Rg/providers/microsoft.sql/servers/srv-a/databases/prod_$([guid]::NewGuid())"] = $DbA
            $Ids["/subscriptions/$Shared/resourcegroups/$Rg/providers/microsoft.compute/virtualmachines/prod_$([guid]::NewGuid())"] = $VmB
        }
        $SeedMaps = @{ ResourceIdMap = $Ids; SubscriptionNameMap = @{ $Shared = 'Pay-As-You-Go' } }
        $First = $null
        foreach ($Run in 1, 2, 3)
        {
            $Seed = Join-Path ([System.IO.Path]::GetTempPath()) ('rda-subseed-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
            $SeedMaps | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Seed -Encoding utf8
            try
            {
                Invoke-RunVariables
                $Global:Subscriptions = @([pscustomobject]@{ id = $script:SubA; name = 'Pay-As-You-Go' }, [pscustomobject]@{ id = $script:SubB; name = 'Renamed' })
                $Global:ObfuscationSubscriptionIndex = $null
                $Global:Resources = @(
                    [pscustomobject]@{ id = $VmA; name = 'vm-a'; subscriptionId = $script:SubA; resourceGroup = 'rg-shared' }
                    [pscustomobject]@{ id = $VmB; name = 'vm-b'; subscriptionId = $script:SubB; resourceGroup = 'rg-shared' }
                )
                Invoke-DictionaryBuild -Seed $Seed
            }
            finally { Remove-Item -LiteralPath $Seed -ErrorAction SilentlyContinue }
            $A = ($Global:ResourceIdDictionary[$VmA] -split '/')[2]; $B = ($Global:ResourceIdDictionary[$VmB] -split '/')[2]
            $A | Should -Not -BeExactly $B -Because "run $Run"
            if ($Run -eq 1) { $First = @($A, $B) } else { @($A, $B) | Should -Be $First }
            $NextIds = @{}; foreach ($K in @($Global:ResourceIdDictionary.Keys)) { $NextIds[$Global:ResourceIdDictionary[$K]] = $K }
            $SeedMaps = @{ ResourceIdMap = $NextIds; SubscriptionNameMap = @{ $A = 'Pay-As-You-Go'; $B = 'Renamed' } }
        }
    }
}

