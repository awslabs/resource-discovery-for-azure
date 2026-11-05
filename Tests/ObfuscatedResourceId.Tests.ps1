# Get-ObfuscatedResourceId tests
# Run with: Invoke-Pester ./Tests/ObfuscatedResourceId.Tests.ps1 -Output Detailed
#
# Get-ObfuscatedResourceId (ResourceInventory.ps1) builds the masked id that
# -Obfuscate writes for a resource. Every name segment must be masked,
# including a parent's name inside a child's id (SQL databases and elastic
# pools, managed instance databases, automation runbooks, NetApp capacity pools
# and volumes), and a parent segment must carry the parent's own token so ids
# still join. The functions are taken from ResourceInventory.ps1 with the
# PowerShell AST and run against the run's dictionaries set up here. Generic
# names and the documentation placeholder subscription id only.

BeforeAll {
    $Script = Join-Path (Split-Path $PSScriptRoot -Parent) 'ResourceInventory.ps1'
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$null, [ref]$null)
    foreach ($Name in @('Get-ObfuscationPrefix', 'New-ObfuscatedNameToken', 'Get-ObfuscationSubscriptionIndex', 'Test-RdaTenantScopeIdMaskable', 'Get-ObfuscatedResourceId'))
    {
        $Fn = @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq $Name }, $false))
        if ($Fn.Count -ne 1) { throw "$Name was not found in ResourceInventory.ps1." }
        . ([scriptblock]::Create($Fn[0].Extent.Text))
    }
    # The seeded dictionary build calls it; a missing one fails those tests only.
    $ShapeFn = @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'Test-ObfuscatedIdShape' }, $false))
    if ($ShapeFn.Count -eq 1) { . ([scriptblock]::Create($ShapeFn[0].Extent.Text)) }

    $script:Sub = '12345678-1234-1234-1234-123456789012'   # Azure docs placeholder
    $script:Base = "/subscriptions/$script:Sub/resourcegroups/rg-demo/providers"
    $script:Token = '(?:prod|nonprod)_(?:[a-z0-9]+_)*[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'

    function Reset-ObfuscationState
    {
        $Global:Subscriptions = @([pscustomobject]@{ id = $script:Sub; name = 'Demo Subscription' })
        $Global:ResourceIdDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:ResourceNameDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:ResourceSubscriptionDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:ResourceResourceGroupDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:ObfuscationSubscriptionTokens = @{}
        $Global:ObfuscationResourceGroupTokens = @{}
    }
}

AfterAll {
    foreach ($Name in @('Subscriptions', 'ResourceIdDictionary', 'ResourceNameDictionary', 'ResourceSubscriptionDictionary', 'ResourceResourceGroupDictionary', 'ObfuscationSubscriptionTokens', 'ObfuscationResourceGroupTokens', 'ObfuscationSubscriptionIndex', 'Resources'))
    {
        Remove-Variable -Name $Name -Scope Global -ErrorAction SilentlyContinue
    }
}

Describe 'Get-ObfuscatedResourceId' {
    BeforeEach { Reset-ObfuscationState }

    It 'masks every name segment of a <Label> id and keeps its shape' -ForEach @(
        @{ Label = 'SQL database'; Id = '/microsoft.sql/servers/srv-a/databases/db-a'; Names = @('srv-a', 'db-a') }
        @{ Label = 'SQL elastic pool'; Id = '/microsoft.sql/servers/srv-a/elasticpools/pool-a'; Names = @('srv-a', 'pool-a') }
        @{ Label = 'managed instance database'; Id = '/microsoft.sql/managedinstances/mi-a/databases/midb-a'; Names = @('mi-a', 'midb-a') }
        @{ Label = 'automation runbook'; Id = '/microsoft.automation/automationaccounts/aa-a/runbooks/rb-a'; Names = @('aa-a', 'rb-a') }
        @{ Label = 'NetApp volume'; Id = '/microsoft.netapp/netappaccounts/na-a/capacitypools/cp-a/volumes/vol-a'; Names = @('na-a', 'cp-a', 'vol-a') }
        @{ Label = 'extension resource'; Id = '/microsoft.compute/virtualmachines/vm-a/providers/microsoft.insights/diagnosticsettings/ds-a'; Names = @('vm-a', 'ds-a') }
    ) {
        $Real = $script:Base + $Id
        $Masked = Get-ObfuscatedResourceId -ResourceId $Real
        foreach ($N in @($Names + @('rg-demo', $script:Sub))) { $Masked | Should -Not -Match ([regex]::Escape($N)) }
        $RealParts = $Real -split '/'
        $MaskedParts = $Masked -split '/'
        $MaskedParts.Count | Should -Be $RealParts.Count
        for ($i = 0; $i -lt $RealParts.Count; $i++)
        {
            if ($RealParts[$i] -in @($Names + @('rg-demo', $script:Sub))) { $MaskedParts[$i] | Should -Match ('^' + $script:Token + '$') }
            else { $MaskedParts[$i] | Should -BeExactly $RealParts[$i] }
        }
    }

    It 'uses the parent resource''s own name token for the parent segment' {
        $Server = "$script:Base/microsoft.sql/servers/srv-a"
        $Global:ResourceNameDictionary[$Server] = 'prod_' + [guid]::NewGuid().ToString()
        $Masked = Get-ObfuscatedResourceId -ResourceId "$Server/databases/db-a"
        ($Masked -split '/')[8] | Should -BeExactly $Global:ResourceNameDictionary[$Server]
        (Get-ObfuscatedResourceId -ResourceId $Server) | Should -BeExactly ($Masked -replace '/databases/[^/]+$', '')
    }

    It 'gives two children of one parent that is not in the inventory the same parent token, and records it for the dictionary' {
        $A = Get-ObfuscatedResourceId -ResourceId "$script:Base/microsoft.sql/servers/srv-gone/databases/db-1"
        $B = Get-ObfuscatedResourceId -ResourceId "$script:Base/microsoft.sql/servers/srv-gone/databases/db-2"
        ($A -split '/')[8] | Should -BeExactly ($B -split '/')[8]
        $Global:ResourceNameDictionary["$script:Base/microsoft.sql/servers/srv-gone"] | Should -BeExactly ($A -split '/')[8]
        $Global:ResourceNameDictionary["$script:Base/microsoft.sql/servers/srv-gone/databases/db-1"] | Should -BeExactly ($A -split '/')[10]
    }

    It 'uses the inventory''s subscription and resource group tokens, and records them for an id outside the inventory' {
        $Global:ObfuscationSubscriptionTokens[$script:Sub] = 'prod_' + [guid]::NewGuid().ToString()
        $Global:ObfuscationResourceGroupTokens['rg-demo'] = 'prod_' + [guid]::NewGuid().ToString()
        $Id = "$script:Base/microsoft.compute/disks/disk-gone"
        $Masked = Get-ObfuscatedResourceId -ResourceId $Id
        ($Masked -split '/')[2] | Should -BeExactly $Global:ObfuscationSubscriptionTokens[$script:Sub]
        ($Masked -split '/')[4] | Should -BeExactly $Global:ObfuscationResourceGroupTokens['rg-demo']
        $Global:ResourceSubscriptionDictionary[$Id] | Should -BeExactly $Global:ObfuscationSubscriptionTokens[$script:Sub]
        $Global:ResourceResourceGroupDictionary[$Id] | Should -BeExactly $Global:ObfuscationResourceGroupTokens['rg-demo']
    }

    It 'masks a subscription-level id, keeps the name ''$system'', and gives an AKS-managed resource the aks_ hint' {
        $SubLevel = Get-ObfuscatedResourceId -ResourceId "/subscriptions/$script:Sub/providers/microsoft.insights/components/ai-a"
        $SubLevel | Should -Match ('^/subscriptions/' + $script:Token + '/providers/microsoft.insights/components/' + $script:Token + '$')
        $System = Get-ObfuscatedResourceId -ResourceId "$script:Base/microsoft.servicebus/namespaces/sb-a/topics/`$system"
        ($System -split '/')[-1] | Should -BeExactly '$system'
        $Aks = Get-ObfuscatedResourceId -ResourceId "/subscriptions/$script:Sub/resourcegroups/mc_rg_aks_eastus/providers/microsoft.compute/disks/osdisk-a"
        ($Aks -split '/')[-1] | Should -Match '^(prod|nonprod)_aks_'
    }

    It 'keeps the path of a tenant-scope id (no subscription), masks each name, and gives a parent one token' {
        $Order = '/providers/Microsoft.Capacity/reservationOrders/ro-a'
        $Masked = Get-ObfuscatedResourceId -ResourceId "$Order/reservations/res-a"
        $Masked | Should -Match ('^/providers/Microsoft\.Capacity/reservationOrders/' + $script:Token + '/reservations/' + $script:Token + '$')
        $Masked | Should -Not -Match 'ro-a|res-a'
        $Second = Get-ObfuscatedResourceId -ResourceId "$Order/reservations/res-b"
        ($Second -split '/')[4] | Should -BeExactly ($Masked -split '/')[4] -Because 'one reservation order keeps one token'
        (Get-ObfuscatedResourceId -ResourceId '/providers/Microsoft.Management/managementGroups/mg-a') | Should -Match ('^/providers/Microsoft\.Management/managementGroups/' + $script:Token + '$')
        $Global:ResourceNameDictionary.ContainsKey("$Order/reservations/res-a") | Should -BeTrue -Because 'the dictionary can reverse every segment'
    }

    It 'gives a /providers/ id that cannot be fully masked one flat token, never a path with a real part: <Label>' -ForEach @(
        @{ Label = 'a type with no name'; Id = '/providers/Microsoft.Capacity/reservationOrders' }
        @{ Label = 'an empty segment'; Id = '/providers/Microsoft.Capacity/reservationOrders//reservations/res-a' }
        @{ Label = 'a $system name'; Id = '/providers/Microsoft.Capacity/reservationOrders/$system' }
        @{ Label = 'a trailing slash'; Id = '/providers/Microsoft.Capacity/reservationOrders/ro-a/' }
    ) {
        $Masked = Get-ObfuscatedResourceId -ResourceId $Id
        $Masked | Should -Match ('^' + $script:Token + '$')
    }

    It 'returns ''obfuscated'' for an empty id and one token for an id that is not subscription-scoped' {
        Get-ObfuscatedResourceId -ResourceId '' | Should -BeExactly 'obfuscated'
        Get-ObfuscatedResourceId -ResourceId 'not-an-arm-id' | Should -Match ('^' + $script:Token + '$')
    }
}

Describe 'The dictionary build writes the name token New-ObfuscatedNameToken writes' {
    BeforeAll {
        # The -Obfuscate dictionary build of RunInventorySetup, run as a function. Its
        # per-resource loop builds the name token inline.
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'ResourceInventory.ps1'), [ref]$null, [ref]$null)
        $Setup = $Ast.Find({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'RunInventorySetup' }, $true)
        $Build = @($Setup.Body.FindAll({ param($N) $N -is [System.Management.Automation.Language.IfStatementAst] -and $N.Clauses[0].Item1.Extent.Text -eq '$Obfuscate.IsPresent' -and $N.Extent.Text -match 'foreach \(\$resourceItem in \$Global:Resources\)' }, $true))
        if ($Build.Count -ne 1) { throw 'The -Obfuscate dictionary build was not found in RunInventorySetup.' }
        . ([scriptblock]::Create("function Invoke-DictionaryBuild { `$Obfuscate = [switch]`$true; `$ObfuscationDictionary = `$null; $($Build[0].Extent.Text) }"))

        $script:Cases = @(
            @{ Id = "$script:Base/microsoft.compute/virtualmachines/vm-a"; Name = 'vm-a' }
            @{ Id = "$script:Base/microsoft.compute/virtualmachines/vm-dev-a"; Name = 'vm-dev-a' }
            @{ Id = "$script:Base/microsoft.compute/virtualmachines/VM-TEST-B"; Name = 'VM-TEST-B' }
            @{ Id = "$script:Base/microsoft.web/sites/t-web"; Name = 't-web' }
            @{ Id = "$script:Base/microsoft.compute/disks/disk-noname"; Name = $null }
            @{ Id = "$script:Base/microsoft.databricks/workspaces/dbw-a"; Name = 'dbw-a' }
            @{ Id = "$script:Base/microsoft.databricks/workspaces/dbw-dev"; Name = 'dbw-dev' }
            @{ Id = "/subscriptions/$script:Sub/resourcegroups/mc_rg_aks/providers/microsoft.compute/disks/osdisk-b"; Name = 'osdisk-b' }
            @{ Id = "$script:Base/microsoft.compute/virtualmachinescalesets/vmss-a"; Name = 'vmss-a' }
        )
        Reset-ObfuscationState
        $Global:Resources = @(foreach ($C in $script:Cases) { [pscustomobject]@{ id = $C.Id; name = $C.Name; subscriptionId = $script:Sub; resourceGroup = ($C.Id -split '/')[4] } })
        Invoke-DictionaryBuild
    }

    It 'gives <Id> the prefix and hint New-ObfuscatedNameToken gives it' -ForEach @(
        @{ Id = 'vm-a' }, @{ Id = 'vm-dev-a' }, @{ Id = 'VM-TEST-B' }, @{ Id = 't-web' }, @{ Id = 'disk-noname' }, @{ Id = 'dbw-a' }, @{ Id = 'dbw-dev' }, @{ Id = 'osdisk-b' }, @{ Id = 'vmss-a' }
    ) {
        $Case = @($script:Cases | Where-Object { $_.Id.EndsWith('/' + $Id) })[0]
        $Expected = (New-ObfuscatedNameToken -ResourceId $Case.Id -Name $Case.Name) -replace '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', '<guid>'
        $Written = $Global:ResourceNameDictionary[$Case.Id]
        $Written | Should -Match ('^' + $script:Token + '$')
        ($Written -replace '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', '<guid>') | Should -BeExactly $Expected
    }
}

Describe 'The run''s resource dictionaries ignore the case of an id' {
    BeforeAll {
        # Variables (ResourceInventory.ps1) builds the run's dictionaries; the
        # -Obfuscate dictionary build of RunInventorySetup fills them.
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'ResourceInventory.ps1'), [ref]$null, [ref]$null)
        $Vars = $Ast.Find({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'Variables' }, $false)
        . ([scriptblock]::Create("function Invoke-RunVariables { `$Obfuscate = [switch]`$true; $($Vars.Body.Extent.Text.Substring(1, $Vars.Body.Extent.Text.Length - 2)) }"))
        $Setup = $Ast.Find({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'RunInventorySetup' }, $true)
        $Build = @($Setup.Body.FindAll({ param($N) $N -is [System.Management.Automation.Language.IfStatementAst] -and $N.Clauses[0].Item1.Extent.Text -eq '$Obfuscate.IsPresent' -and $N.Extent.Text -match 'foreach \(\$resourceItem in \$(Global:Resources|TokenLoopRows)\)' }, $true))
        . ([scriptblock]::Create("function Invoke-DictionaryBuild2 { `$Obfuscate = [switch]`$true; `$ObfuscationDictionary = `$null; $($Build[0].Extent.Text) }"))
        function GetLocalVersion { '0.0.0-test' }
    }

    AfterAll {
        Remove-Variable -Scope Global -Name TagValueDictionary, FreeTextDictionary, ResourceCount, ResourceContainers, ReportName, Version, RawRepo, TableStyle -ErrorAction SilentlyContinue
    }

    BeforeEach {
        Invoke-RunVariables
        $Global:Subscriptions = @([pscustomobject]@{ id = $script:Sub; name = 'Demo Subscription' })
        $Global:ObfuscationSubscriptionIndex = $null
    }

    It 'finds the id Resource Graph gave in lower case when consumption gives it in other casing' {
        $Lower = "$script:Base/microsoft.compute/virtualmachines/vm-a"
        $Global:Resources = @([pscustomobject]@{ id = $Lower; name = 'vm-a'; subscriptionId = $script:Sub; resourceGroup = 'rg-demo' })
        Invoke-DictionaryBuild2
        $Mixed = "/subscriptions/$script:Sub/resourceGroups/RG-Demo/providers/Microsoft.Compute/virtualMachines/VM-A"
        foreach ($D in @($Global:ResourceIdDictionary, $Global:ResourceNameDictionary, $Global:ResourceSubscriptionDictionary, $Global:ResourceResourceGroupDictionary))
        {
            $D.ContainsKey($Mixed) | Should -BeTrue
        }
        $Global:ResourceIdDictionary[$Mixed] | Should -BeExactly $Global:ResourceIdDictionary[$Lower]
    }

    It 'gives the subscription one token when it is listed twice, the one its ids hold' {
        $Global:Subscriptions = @([pscustomobject]@{ id = $script:Sub; name = 'Demo Subscription' }, [pscustomobject]@{ id = $script:Sub; name = 'Demo Subscription' })
        $Global:ObfuscationSubscriptionIndex = $null
        $Global:Resources = @(
            [pscustomobject]@{ id = "$script:Base/microsoft.compute/virtualmachines/vm-a"; name = 'vm-a'; subscriptionId = $script:Sub; resourceGroup = 'rg-demo' }
            [pscustomobject]@{ id = "$script:Base/microsoft.compute/virtualmachines/vm-b"; name = 'vm-b'; subscriptionId = $script:Sub; resourceGroup = 'rg-demo' }
        )
        Invoke-DictionaryBuild2
        foreach ($Id in @($Global:ResourceIdDictionary.Keys))
        {
            $Global:ResourceSubscriptionDictionary[$Id] | Should -BeExactly ($Global:ResourceIdDictionary[$Id] -split '/')[2]
        }
    }

    It 'masks a resource listed twice in different casing once, with one id' {
        $Global:Resources = @(
            [pscustomobject]@{ id = "$script:Base/microsoft.compute/virtualmachines/vm-a"; name = 'vm-a'; subscriptionId = $script:Sub; resourceGroup = 'rg-demo' }
            [pscustomobject]@{ id = "$script:Base/Microsoft.Compute/virtualMachines/VM-A"; name = 'VM-A'; subscriptionId = $script:Sub; resourceGroup = 'rg-demo' }
        )
        Invoke-DictionaryBuild2
        @($Global:ResourceIdDictionary.Keys).Count | Should -Be 1
    }
}

Describe 'A run seeded with an obfuscation dictionary' {
    BeforeAll {
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'ResourceInventory.ps1'), [ref]$null, [ref]$null)
        $Vars = $Ast.Find({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'Variables' }, $false)
        . ([scriptblock]::Create("function Invoke-RunVariables3 { `$Obfuscate = [switch]`$true; $($Vars.Body.Extent.Text.Substring(1, $Vars.Body.Extent.Text.Length - 2)) }"))
        $Setup = $Ast.Find({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'RunInventorySetup' }, $true)
        $Build = @($Setup.Body.FindAll({ param($N) $N -is [System.Management.Automation.Language.IfStatementAst] -and $N.Clauses[0].Item1.Extent.Text -eq '$Obfuscate.IsPresent' -and $N.Extent.Text -match 'foreach \(\$resourceItem in \$(Global:Resources|TokenLoopRows)\)' }, $true))
        . ([scriptblock]::Create("function Invoke-SeededBuild { param(`$Seed) `$Obfuscate = [switch]`$true; `$ObfuscationDictionary = `$Seed; function Write-Log { }; $($Build[0].Extent.Text) }"))
        function GetLocalVersion { '0.0.0-test' }
        $script:SeedDir = Join-Path ([System.IO.Path]::GetTempPath()) ('rda-seed-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:SeedDir -Force | Out-Null
    }

    AfterAll {
        Remove-Item -LiteralPath $script:SeedDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Variable -Scope Global -Name TagValueDictionary, FreeTextDictionary, ResourceCount, ResourceContainers, ReportName, Version, RawRepo, TableStyle -ErrorAction SilentlyContinue
    }

    It 'gives each seeded resource the subscription, resource group and name tokens of its own seeded id' {
        # A first run's tokens, written as its dictionary file is.
        $Vm = "$script:Base/microsoft.compute/virtualmachines/vm-a"
        $SubTok = 'prod_' + [guid]::NewGuid().ToString()
        $RgTok = 'prod_' + [guid]::NewGuid().ToString()
        $NameTok = 'prod_' + [guid]::NewGuid().ToString()
        $Masked = "/subscriptions/$SubTok/resourcegroups/$RgTok/providers/microsoft.compute/virtualmachines/$NameTok"
        $Seed = Join-Path $script:SeedDir 'seed.json'
        @{
            ResourceIdMap       = @{ $Masked = $Vm }
            ResourceNameMap     = @{ $NameTok = $Vm }
            SubscriptionNameMap = @{ $SubTok = 'Demo Subscription' }
            ResourceGroupMap    = @{ $RgTok = $Vm }
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Seed -Encoding utf8

        Invoke-RunVariables3
        $Global:Subscriptions = @([pscustomobject]@{ id = $script:Sub; name = 'Demo Subscription' })
        $Global:ObfuscationSubscriptionIndex = $null
        $Global:Resources = @(
            [pscustomobject]@{ id = $Vm; name = 'vm-a'; subscriptionId = $script:Sub; resourceGroup = 'rg-demo' }
            [pscustomobject]@{ id = "$script:Base/microsoft.compute/disks/disk-a"; name = 'disk-a'; subscriptionId = $script:Sub; resourceGroup = 'rg-demo' }
        )
        Invoke-SeededBuild -Seed $Seed

        $Global:ResourceIdDictionary[$Vm] | Should -BeExactly $Masked
        $Global:ResourceSubscriptionDictionary[$Vm] | Should -BeExactly $SubTok
        $Global:ResourceResourceGroupDictionary[$Vm] | Should -BeExactly $RgTok
        $Global:ResourceNameDictionary[$Vm] | Should -BeExactly $NameTok
        # The unseeded disk of the same group gets the same seeded tokens.
        $Disk = "$script:Base/microsoft.compute/disks/disk-a"
        ($Global:ResourceIdDictionary[$Disk] -split '/')[2] | Should -BeExactly $SubTok
        ($Global:ResourceIdDictionary[$Disk] -split '/')[4] | Should -BeExactly $RgTok
        foreach ($D in @($Global:ResourceSubscriptionDictionary, $Global:ResourceResourceGroupDictionary, $Global:ResourceNameDictionary))
        {
            @($D.Values | Where-Object { [string]::IsNullOrEmpty($_) }) | Should -BeNullOrEmpty
        }
    }

    It 'masks again a seeded id of another shape: <Label>' -ForEach @(
        @{ Label = 'an older dictionary''s child id that kept its parent''s real name'; Flat = $false }
        @{ Label = 'a flat seeded token'; Flat = $true }
    ) {
        $Db = "$script:Base/microsoft.sql/servers/srv-a/databases/db-a"
        $SubTok = 'prod_' + [guid]::NewGuid().ToString()
        $RgTok = 'prod_' + [guid]::NewGuid().ToString()
        $NameTok = 'prod_' + [guid]::NewGuid().ToString()
        $Seeded = if ($Flat) { 'prod_' + [guid]::NewGuid().ToString() } else { "/subscriptions/$SubTok/resourcegroups/$RgTok/providers/microsoft.sql/servers/srv-a/databases/$NameTok" }
        $Seed = Join-Path $script:SeedDir ('seed-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json')
        @{
            ResourceIdMap       = @{ $Seeded = $Db }
            SubscriptionNameMap = @{ $SubTok = 'Demo Subscription' }
            ResourceGroupMap    = @{ $RgTok = $Db }
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Seed -Encoding utf8
        Invoke-RunVariables3
        $Global:Subscriptions = @([pscustomobject]@{ id = $script:Sub; name = 'Demo Subscription' })
        $Global:ObfuscationSubscriptionIndex = $null
        $Global:Resources = @([pscustomobject]@{ id = $Db; name = 'db-a'; subscriptionId = $script:Sub; resourceGroup = 'rg-demo' })
        Invoke-SeededBuild -Seed $Seed

        $Masked = $Global:ResourceIdDictionary[$Db]
        $Masked | Should -Not -BeExactly $Seeded
        $Masked | Should -Not -Match 'srv-a'
        Test-ObfuscatedIdShape -RealId $Db -MaskedId $Masked | Should -BeTrue
        # The subscription token comes from good seeded ids only (none here),
        # never from the name map; the group token still comes from the map.
        ($Masked -split '/')[2] | Should -Not -BeExactly $SubTok -Because 'the name map is not read for subscription tokens'
        ($Masked -split '/')[4] | Should -BeExactly $RgTok
        $Global:ResourceSubscriptionDictionary[$Db] | Should -BeExactly ($Masked -split '/')[2]
        $Global:ResourceResourceGroupDictionary[$Db] | Should -BeExactly ($Masked -split '/')[4]
    }

    It 'gives a new resource the subscription and group tokens of the seeded ids when the seed has no map entry for them' {
        $Vm = "$script:Base/microsoft.compute/virtualmachines/vm-a"
        $SubTok = 'prod_' + [guid]::NewGuid().ToString()
        $RgTok = 'prod_' + [guid]::NewGuid().ToString()
        $NameTok = 'prod_' + [guid]::NewGuid().ToString()
        $Seed = Join-Path $script:SeedDir 'seed-nomaps.json'
        @{ ResourceIdMap = @{ "/subscriptions/$SubTok/resourcegroups/$RgTok/providers/microsoft.compute/virtualmachines/$NameTok" = $Vm } } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Seed -Encoding utf8
        Invoke-RunVariables3
        $Global:Subscriptions = @([pscustomobject]@{ id = $script:Sub; name = 'Demo Subscription' })
        $Global:ObfuscationSubscriptionIndex = $null
        $Disk = "$script:Base/microsoft.compute/disks/disk-a"
        $Global:Resources = @(
            [pscustomobject]@{ id = $Vm; name = 'vm-a'; subscriptionId = $script:Sub; resourceGroup = 'rg-demo' }
            [pscustomobject]@{ id = $Disk; name = 'disk-a'; subscriptionId = $script:Sub; resourceGroup = 'rg-demo' }
        )
        Invoke-SeededBuild -Seed $Seed
        $Global:ResourceSubscriptionDictionary[$Disk] | Should -BeExactly $SubTok
        $Global:ResourceResourceGroupDictionary[$Disk] | Should -BeExactly $RgTok
        ($Global:ResourceIdDictionary[$Disk] -split '/')[2] | Should -BeExactly $SubTok
    }
}

Describe 'The seed is checked when it is read' {
    BeforeAll {
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'ResourceInventory.ps1'), [ref]$null, [ref]$null)
        $Vars = $Ast.Find({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'Variables' }, $false)
        . ([scriptblock]::Create("function Invoke-RunVariables4 { `$Obfuscate = [switch]`$true; $($Vars.Body.Extent.Text.Substring(1, $Vars.Body.Extent.Text.Length - 2)) }"))
        $Setup = $Ast.Find({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'RunInventorySetup' }, $true)
        $Build = @($Setup.Body.FindAll({ param($N) $N -is [System.Management.Automation.Language.IfStatementAst] -and $N.Clauses[0].Item1.Extent.Text -eq '$Obfuscate.IsPresent' -and $N.Extent.Text -match 'foreach \(\$resourceItem in \$(Global:Resources|TokenLoopRows)\)' }, $true))
        . ([scriptblock]::Create("function Invoke-SeededBuild4 { param(`$Seed) `$Obfuscate = [switch]`$true; `$ObfuscationDictionary = `$Seed; function Write-Log { param(`$Message, `$Severity) if (`$Severity -eq 'Warning') { `$script:SeedWarnings.Add([string]`$Message) } }; $($Build[0].Extent.Text) }"))
        $script:SeedWarnings = [System.Collections.Generic.List[string]]::new()
        function GetLocalVersion { '0.0.0-test' }
        $script:SeedDir4 = Join-Path ([System.IO.Path]::GetTempPath()) ('rda-seed4-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:SeedDir4 -Force | Out-Null
        $script:SeedDirW = $script:SeedDir4
        function New-Tok { param([string]$Hint = '') 'prod_' + $Hint + [guid]::NewGuid().ToString() }
        # One run: seed file in, the run's dictionaries out.
        function Invoke-SeededRun
        {
            param([hashtable]$SeedMaps, [object[]]$Rows)
            $Path = Join-Path $script:SeedDir4 ('seed-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json')
            $SeedMaps | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -Encoding utf8
            Invoke-RunVariables4
            $Global:Subscriptions = @([pscustomobject]@{ id = $script:Sub; name = 'Demo Subscription' })
            $Global:ObfuscationSubscriptionIndex = $null
            $Global:Resources = @($Rows)
            Invoke-SeededBuild4 -Seed $Path
        }
        # The run's dictionary file, written by ResourceInventory.ps1's own
        # writer, read back as the next run's seed.
        $Writer = @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.IfStatementAst] -and $N.Clauses[0].Item1.Extent.Text -eq '$Obfuscate.IsPresent' -and $N.Clauses[0].Item2.Extent.Text -match '\$Global:DictionaryFile = ' }, $false))
        if ($Writer.Count -ne 1) { throw 'The dictionary writer was not found in ResourceInventory.ps1.' }
        . ([scriptblock]::Create("function Invoke-DictionaryWriter { param(`$DefaultPath) `$Obfuscate = [switch]`$true; `$CurrentDateTime = 'test'; function Write-Log { }; $($Writer[0].Extent.Text) }"))
        function Get-RunDictionaryMaps
        {
            $Dir = Join-Path $script:SeedDirW ([guid]::NewGuid().ToString('N').Substring(0, 6))
            New-Item -ItemType Directory -Path $Dir -Force | Out-Null
            $Global:ReportName = 'ResourcesReport'
            Invoke-DictionaryWriter -DefaultPath ($Dir + [System.IO.Path]::DirectorySeparatorChar)
            Get-Content -LiteralPath (Get-ChildItem -LiteralPath $Dir -Filter 'ObfuscationDictionary_*.json').FullName -Raw | ConvertFrom-Json -AsHashtable
        }
        function New-Res { param([string]$Id) [pscustomobject]@{ id = $Id; name = ($Id -split '/')[-1]; subscriptionId = $script:Sub; resourceGroup = ($Id -split '/')[4] } }
    }

    AfterAll {
        Remove-Item -LiteralPath $script:SeedDir4 -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Variable -Scope Global -Name TagValueDictionary, FreeTextDictionary, ResourceCount, ResourceContainers, ReportName, Version, RawRepo, TableStyle -ErrorAction SilentlyContinue
    }

    It 'does not keep a seeded id of another shape for a resource this run does not see: <Label>' -ForEach @(
        @{ Label = 'a flat token'; Masked = 'prod_{0}' }
        @{ Label = 'a real parent name'; Masked = '/subscriptions/prod_{0}/resourcegroups/prod_{0}/providers/microsoft.sql/servers/srv-gone/databases/prod_{0}' }
        @{ Label = 'the metric step''s old sub_/rg_ tokens'; Masked = '/subscriptions/prod_sub_{0}/resourcegroups/prod_rg_{0}/providers/microsoft.sql/servers/prod_{0}/databases/prod_{0}' }
    ) {
        $Gone = "$script:Base/microsoft.sql/servers/srv-gone/databases/db-gone"
        Invoke-SeededRun -SeedMaps @{ ResourceIdMap = @{ ($Masked -f [guid]::NewGuid().ToString()) = $Gone } } -Rows @()
        $Global:ResourceIdDictionary.ContainsKey($Gone) | Should -BeFalse -Because 'consumption or metrics that meet it mask it again'
    }

    It 'warns when the seed gives one resource two masked ids by case, and keeps the one of the right shape' {
        $script:SeedWarnings.Clear()
        $Vm = "$script:Base/microsoft.compute/virtualmachines/vm-a"
        $M = { "/subscriptions/$(New-Tok)/resourcegroups/$(New-Tok)/providers/microsoft.compute/virtualmachines/$(New-Tok)" }
        Invoke-SeededRun -SeedMaps @{ ResourceIdMap = @{ (& $M) = $Vm; (& $M) = $Vm.ToUpperInvariant() } } -Rows @()
        ($script:SeedWarnings -join "`n") | Should -Match 'gives 1 resource\(s\) two masked ids by case.*only one can be kept.*collect the gap bundle on this build'
        # One good and one flat variant, in both orders: the good one is kept.
        foreach ($Order in 1, 2)
        {
            $Good = & $M; $Flat = New-Tok
            $Map = [ordered]@{}
            if ($Order -eq 1) { $Map[$Good] = $Vm; $Map[$Flat] = $Vm.ToUpperInvariant() } else { $Map[$Flat] = $Vm.ToUpperInvariant(); $Map[$Good] = $Vm }
            Invoke-SeededRun -SeedMaps @{ ResourceIdMap = $Map } -Rows @()
            $Global:ResourceIdDictionary[$Vm] | Should -BeExactly $Good -Because "order $Order"
        }
    }

    It 'keeps a good seeded id for a resource this run does not see' {
        $Gone = "$script:Base/microsoft.compute/virtualmachines/vm-gone"
        $Masked = "/subscriptions/$(New-Tok)/resourcegroups/$(New-Tok)/providers/microsoft.compute/virtualmachines/$(New-Tok)"
        Invoke-SeededRun -SeedMaps @{ ResourceIdMap = @{ $Masked = $Gone } } -Rows @()
        $Global:ResourceIdDictionary[$Gone] | Should -BeExactly $Masked
    }

    It 'records the subscription and group tokens of a kept seeded id that the token loop does not see, for the rows and metrics that reuse it' {
        $Gone = "$script:Base/microsoft.compute/virtualmachines/vm-gone"
        $Masked = "/subscriptions/$(New-Tok)/resourcegroups/$(New-Tok)/providers/microsoft.compute/virtualmachines/$(New-Tok)"
        Invoke-SeededRun -SeedMaps @{ ResourceIdMap = @{ $Masked = $Gone } } -Rows @()
        $Global:ResourceSubscriptionDictionary[$Gone] | Should -BeExactly ($Masked -split '/')[2]
        $Global:ResourceResourceGroupDictionary[$Gone] | Should -BeExactly ($Masked -split '/')[4]
        $Global:ResourceNameDictionary[$Gone] | Should -BeExactly ($Masked -split '/')[-1]
    }

    It 'keeps the seeded flat token of a real id that is not an ARM path, so it stays the same across seeded runs' {
        $Flat = New-Tok
        Invoke-SeededRun -SeedMaps @{ ResourceIdMap = @{ $Flat = 'not-an-arm-id' } } -Rows @()
        $Global:ResourceIdDictionary['not-an-arm-id'] | Should -BeExactly $Flat
    }

    It 'keeps the seeded flat token of a real id that is not an ARM path for a resource this run sees too' {
        $Flat = New-Tok
        $Odd = [pscustomobject]@{ id = 'not-an-arm-id'; name = 'odd-a'; subscriptionId = $script:Sub; resourceGroup = 'rg-demo' }
        Invoke-SeededRun -SeedMaps @{ ResourceIdMap = @{ $Flat = 'not-an-arm-id' } } -Rows @($Odd)
        $Global:ResourceIdDictionary['not-an-arm-id'] | Should -BeExactly $Flat
    }

    It 'keeps the seeded flat token of a /providers/ id this run writes flat too' {
        $Flat = New-Tok
        Invoke-SeededRun -SeedMaps @{ ResourceIdMap = @{ $Flat = '/providers/Microsoft.Capacity/reservationOrders' } } -Rows @()
        $Global:ResourceIdDictionary['/providers/Microsoft.Capacity/reservationOrders'] | Should -BeExactly $Flat
    }

    It 'does not keep a seeded flat value that is not a flat token (plain text)' {
        # (An empty key is not valid seed JSON: the pre-flight refuses the file.)
        Invoke-SeededRun -SeedMaps @{ ResourceIdMap = @{ 'not-a-token' = 'not-an-arm-id' } } -Rows @()
        $Global:ResourceIdDictionary.ContainsKey('not-an-arm-id') | Should -BeFalse
    }

    It 'masks a resource from an old metric-fallback dictionary to the contract shape, and the next two seeded runs keep it' {
        $Vm = "$script:Base/microsoft.compute/virtualmachines/vm-a"
        $G = { [guid]::NewGuid().ToString() }
        $OldSub = 'prod_sub_' + (& $G); $OldRg = 'prod_rg_' + (& $G); $OldName = 'prod_' + (& $G)
        $Seed = @{
            ResourceIdMap       = @{ "/subscriptions/$OldSub/resourcegroups/$OldRg/providers/microsoft.compute/virtualmachines/$OldName" = $Vm }
            ResourceNameMap     = @{ $OldName = $Vm }
            SubscriptionNameMap = @{ $OldSub = 'Demo Subscription' }
            ResourceGroupMap    = @{ $OldRg = $Vm }
        }
        $First = $null
        foreach ($Run in 1, 2, 3)
        {
            Invoke-SeededRun -SeedMaps $Seed -Rows @(New-Res $Vm)
            $Id = $Global:ResourceIdDictionary[$Vm]
            Test-ObfuscatedIdShape -RealId $Vm -MaskedId $Id | Should -BeTrue -Because "run $Run writes the contract shape"
            $Id | Should -Not -Match '_sub_|_rg_'
            if ($Run -eq 1) { $First = $Id } else { $Id | Should -BeExactly $First -Because "run $Run keeps run 1's id" }
            $Seed = Get-RunDictionaryMaps
        }
    }

    It 'records no ''$system'' name token for a seeded Service Bus id that keeps it' {
        $Sys = "$script:Base/microsoft.servicebus/namespaces/`$system"
        Invoke-SeededRun -SeedMaps @{ ResourceIdMap = @{ "/subscriptions/$(New-Tok)/resourcegroups/$(New-Tok)/providers/microsoft.servicebus/namespaces/`$system" = $Sys } } -Rows @()
        $Global:ResourceIdDictionary.ContainsKey($Sys) | Should -BeTrue
        @($Global:ResourceNameDictionary.Values | Where-Object { $_ -eq '$system' }) | Should -BeNullOrEmpty
    }

    It 'takes the subscription and group tokens of the seeded ids over a map entry that disagrees' {
        $Vm = "$script:Base/microsoft.compute/virtualmachines/vm-a"
        $Sub = New-Tok; $Rg = New-Tok
        Invoke-SeededRun -SeedMaps @{
            ResourceIdMap       = @{ "/subscriptions/$Sub/resourcegroups/$Rg/providers/microsoft.compute/virtualmachines/$(New-Tok)" = $Vm }
            SubscriptionNameMap = @{ (New-Tok) = 'Demo Subscription' }
            ResourceGroupMap    = @{ (New-Tok) = $Vm }
        } -Rows @((New-Res $Vm), (New-Res "$script:Base/microsoft.compute/disks/disk-a"))
        ($Global:ResourceIdDictionary["$script:Base/microsoft.compute/disks/disk-a"] -split '/')[2] | Should -BeExactly $Sub
        ($Global:ResourceIdDictionary["$script:Base/microsoft.compute/disks/disk-a"] -split '/')[4] | Should -BeExactly $Rg
    }

    It 'gives a subscription whose seeded ids hold two tokens one token again, and the next seeded run keeps every id' {
        $A = "$script:Base/microsoft.compute/virtualmachines/vm-a"
        $B = "$script:Base/microsoft.compute/virtualmachines/vm-b"
        $Rg = New-Tok
        $SeedIds = @{}
        $SeedIds["/subscriptions/$(New-Tok)/resourcegroups/$Rg/providers/microsoft.compute/virtualmachines/$(New-Tok)"] = $A
        $SeedIds["/subscriptions/$(New-Tok)/resourcegroups/$Rg/providers/microsoft.compute/virtualmachines/$(New-Tok)"] = $B
        $Seed1 = @{ ResourceIdMap = $SeedIds }
        Invoke-SeededRun -SeedMaps $Seed1 -Rows @((New-Res $A), (New-Res $B))
        $Run1 = @{ A = $Global:ResourceIdDictionary[$A]; B = $Global:ResourceIdDictionary[$B] }
        ($Run1.A -split '/')[2] | Should -BeExactly ($Run1.B -split '/')[2] -Because 'one subscription, one token'
        $Seed2 = Get-RunDictionaryMaps
        # Run 2 and run 3, each seeded from the run before: every id kept.
        foreach ($Run in 2, 3)
        {
            Invoke-SeededRun -SeedMaps $Seed2 -Rows @((New-Res $A), (New-Res $B))
            $Global:ResourceIdDictionary[$A] | Should -BeExactly $Run1.A -Because "run $Run keeps run 1's id"
            $Global:ResourceIdDictionary[$B] | Should -BeExactly $Run1.B
            $Seed2 = Get-RunDictionaryMaps
        }
    }
}

Describe 'The seed''s parent tokens' {
    BeforeAll {
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'ResourceInventory.ps1'), [ref]$null, [ref]$null)
        $Vars = $Ast.Find({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'Variables' }, $false)
        . ([scriptblock]::Create("function Invoke-RunVariables5 { `$Obfuscate = [switch]`$true; $($Vars.Body.Extent.Text.Substring(1, $Vars.Body.Extent.Text.Length - 2)) }"))
        $Setup = $Ast.Find({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'RunInventorySetup' }, $true)
        $Build = @($Setup.Body.FindAll({ param($N) $N -is [System.Management.Automation.Language.IfStatementAst] -and $N.Clauses[0].Item1.Extent.Text -eq '$Obfuscate.IsPresent' -and $N.Extent.Text -match 'foreach \(\$resourceItem in \$(Global:Resources|TokenLoopRows)\)' }, $true))
        . ([scriptblock]::Create("function Invoke-SeededBuild5 { param(`$Seed) `$Obfuscate = [switch]`$true; `$ObfuscationDictionary = `$Seed; function Write-Log { }; $($Build[0].Extent.Text) }"))
        function GetLocalVersion { '0.0.0-test' }
        $script:SeedDir5 = Join-Path ([System.IO.Path]::GetTempPath()) ('rda-seed5-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:SeedDir5 -Force | Out-Null
        function New-Tok5 { 'prod_' + [guid]::NewGuid().ToString() }
        function Invoke-SeededRun5
        {
            param([hashtable]$SeedMaps, [object[]]$Rows)
            $Path = Join-Path $script:SeedDir5 ('seed-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json')
            $SeedMaps | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -Encoding utf8
            Invoke-RunVariables5
            $Global:Subscriptions = @([pscustomobject]@{ id = $script:Sub; name = 'Demo Subscription' })
            $Global:ObfuscationSubscriptionIndex = $null
            $Global:Resources = @($Rows)
            Invoke-SeededBuild5 -Seed $Path
        }
        $Writer = @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.IfStatementAst] -and $N.Clauses[0].Item1.Extent.Text -eq '$Obfuscate.IsPresent' -and $N.Clauses[0].Item2.Extent.Text -match '\$Global:DictionaryFile = ' }, $false))
        . ([scriptblock]::Create("function Invoke-DictionaryWriter5 { param(`$DefaultPath) `$Obfuscate = [switch]`$true; `$CurrentDateTime = 'test'; function Write-Log { }; $($Writer[0].Extent.Text) }"))
        function Get-RunMaps5
        {
            $Dir = Join-Path $script:SeedDir5 ([guid]::NewGuid().ToString('N').Substring(0, 6))
            New-Item -ItemType Directory -Path $Dir -Force | Out-Null
            $Global:ReportName = 'ResourcesReport'
            Invoke-DictionaryWriter5 -DefaultPath ($Dir + [System.IO.Path]::DirectorySeparatorChar)
            Get-Content -LiteralPath (Get-ChildItem -LiteralPath $Dir -Filter 'ObfuscationDictionary_*.json').FullName -Raw | ConvertFrom-Json -AsHashtable
        }
        function New-Res5 { param([string]$Id) [pscustomobject]@{ id = $Id; name = ($Id -split '/')[-1]; subscriptionId = $script:Sub; resourceGroup = ($Id -split '/')[4] } }
    }

    AfterAll {
        Remove-Item -LiteralPath $script:SeedDir5 -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Variable -Scope Global -Name TagValueDictionary, FreeTextDictionary, ResourceCount, ResourceContainers, ReportName, Version, RawRepo, TableStyle -ErrorAction SilentlyContinue
    }

    It 'gives a parent that the seeded ids give two tokens one token, and keeps it for the next two seeded runs' {
        $Srv = "$script:Base/microsoft.sql/servers/srv-a"
        $Db1 = "$Srv/databases/db-1"; $Db2 = "$Srv/databases/db-2"; $Db3 = "$Srv/databases/db-3"
        $Sub = New-Tok5; $Rg = New-Tok5; $SrvTok = New-Tok5
        $P = "/subscriptions/$Sub/resourcegroups/$Rg/providers/microsoft.sql/servers"
        $Seed = @{
            ResourceIdMap   = @{ "$P/$SrvTok" = $Srv; "$P/$SrvTok/databases/$(New-Tok5)" = $Db1; "$P/$(New-Tok5)/databases/$(New-Tok5)" = $Db2 }
            ResourceNameMap = @{ (New-Tok5) = $Srv }
        }
        $Rows = @((New-Res5 $Srv), (New-Res5 $Db1), (New-Res5 $Db2), (New-Res5 $Db3))
        $Parent = $null
        foreach ($Run in 1, 2, 3)
        {
            Invoke-SeededRun5 -SeedMaps $Seed -Rows $Rows
            $Tokens = @($Srv, $Db1, $Db2, $Db3 | ForEach-Object { ($Global:ResourceIdDictionary[$_] -split '/')[8] } | Select-Object -Unique)
            $Tokens.Count | Should -Be 1 -Because "run $Run gives the server one token in every id"
            ($Global:ResourceIdDictionary[$Srv] -split '/')[-1] | Should -BeExactly $Tokens[0]
            if ($Run -eq 1) { $Parent = $Tokens[0] } else { $Tokens[0] | Should -BeExactly $Parent -Because "run $Run keeps run 1's server token" }
            $Seed = Get-RunMaps5
        }
    }

    It 'gives a new child the parent token of the seeded ids, over a name map entry that disagrees' {
        $Srv = "$script:Base/microsoft.sql/servers/srv-b"
        $Sub = New-Tok5; $Rg = New-Tok5; $SrvTok = New-Tok5
        Invoke-SeededRun5 -SeedMaps @{
            ResourceIdMap   = @{ "/subscriptions/$Sub/resourcegroups/$Rg/providers/microsoft.sql/servers/$SrvTok" = $Srv }
            ResourceNameMap = @{ (New-Tok5) = $Srv }
        } -Rows @((New-Res5 $Srv), (New-Res5 "$Srv/databases/db-new"))
        ($Global:ResourceIdDictionary["$Srv/databases/db-new"] -split '/')[8] | Should -BeExactly $SrvTok
    }

    It 'gives a parent with no seeded id of its own the token its kept child holds, in its own id and every id under it' {
        $Srv = "$script:Base/microsoft.sql/servers/srv-c"
        $Db = "$Srv/databases/db-a"; $Pool = "$Srv/elasticpools/pool-a"
        $Sub = New-Tok5; $Rg = New-Tok5; $SrvTok = New-Tok5
        Invoke-SeededRun5 -SeedMaps @{
            ResourceIdMap = @{ "/subscriptions/$Sub/resourcegroups/$Rg/providers/microsoft.sql/servers/$SrvTok/databases/$(New-Tok5)" = $Db }
        } -Rows @((New-Res5 $Srv), (New-Res5 $Db), (New-Res5 $Pool))
        ($Global:ResourceIdDictionary[$Db] -split '/')[8] | Should -BeExactly $SrvTok -Because 'the seeded child id is kept'
        ($Global:ResourceIdDictionary[$Srv] -split '/')[-1] | Should -BeExactly $SrvTok -Because 'the server takes the token its child already holds'
        $Global:ResourceNameDictionary[$Srv] | Should -BeExactly $SrvTok
        ($Global:ResourceIdDictionary[$Pool] -split '/')[8] | Should -BeExactly $SrvTok -Because 'one server path has one masked form'
    }

    It 'gives two parents that the seed gives one token two tokens, and keeps them apart for the next two seeded runs' {
        $SrvA = "$script:Base/microsoft.sql/servers/srv-x"; $SrvB = "$script:Base/microsoft.sql/servers/srv-y"
        $DbA = "$SrvA/databases/db-1"; $DbB = "$SrvB/databases/db-1"
        $Sub = New-Tok5; $Rg = New-Tok5; $Shared = New-Tok5
        $P = "/subscriptions/$Sub/resourcegroups/$Rg/providers/microsoft.sql/servers/$Shared/databases"
        $Seed = @{ ResourceIdMap = @{ "$P/$(New-Tok5)" = $DbA; "$P/$(New-Tok5)" = $DbB } }
        $Rows = @((New-Res5 $SrvA), (New-Res5 $SrvB), (New-Res5 $DbA), (New-Res5 $DbB))
        foreach ($Run in 1, 2, 3)
        {
            Invoke-SeededRun5 -SeedMaps $Seed -Rows $Rows
            $Global:ResourceIdDictionary[$SrvA] | Should -Not -BeExactly $Global:ResourceIdDictionary[$SrvB] -Because "run $Run keeps the two servers apart"
            ($Global:ResourceIdDictionary[$DbA] -split '/')[8] | Should -BeExactly ($Global:ResourceIdDictionary[$SrvA] -split '/')[-1]
            ($Global:ResourceIdDictionary[$DbB] -split '/')[8] | Should -BeExactly ($Global:ResourceIdDictionary[$SrvB] -split '/')[-1]
            @($Global:ResourceIdDictionary.Values | Select-Object -Unique).Count | Should -Be @($Global:ResourceIdDictionary.Keys).Count -Because "run $Run gives no two resources one masked id"
            $Seed = Get-RunMaps5
        }
    }

    It 'does not give a name map token to a resource when a seeded id holds that token for another parent' {
        $SrvA = "$script:Base/microsoft.sql/servers/srv-p"; $SrvB = "$script:Base/microsoft.sql/servers/srv-q"
        $Sub = New-Tok5; $Rg = New-Tok5; $Shared = New-Tok5
        Invoke-SeededRun5 -SeedMaps @{
            ResourceIdMap   = @{ "/subscriptions/$Sub/resourcegroups/$Rg/providers/microsoft.sql/servers/$Shared/databases/$(New-Tok5)" = "$SrvA/databases/db-1" }
            ResourceNameMap = @{ $Shared = $SrvB }
        } -Rows @((New-Res5 $SrvA), (New-Res5 $SrvB), (New-Res5 "$SrvA/databases/db-1"))
        $Global:ResourceIdDictionary[$SrvA] | Should -Not -BeExactly $Global:ResourceIdDictionary[$SrvB]
        $Global:ResourceNameDictionary[$SrvA] | Should -Not -BeExactly $Global:ResourceNameDictionary[$SrvB]
    }

    It 'does not keep a token the seed gives both a subscription and a resource group, for the next two seeded runs' {
        $Vm = "$script:Base/microsoft.compute/virtualmachines/vm-t"
        $T = New-Tok5
        $Seed = @{ ResourceIdMap = @{ "/subscriptions/$T/resourcegroups/$T/providers/microsoft.compute/virtualmachines/$(New-Tok5)" = $Vm } }
        foreach ($Run in 1, 2, 3)
        {
            Invoke-SeededRun5 -SeedMaps $Seed -Rows @((New-Res5 $Vm))
            $Parts = $Global:ResourceIdDictionary[$Vm] -split '/'
            $Parts[2] | Should -Not -BeExactly $Parts[4] -Because "run $Run gives the subscription and the group their own tokens"
            $Seed = Get-RunMaps5
        }
    }

    It 'keeps the one name token a SQL VM and its VM share (their ids differ only in the provider)' {
        $Vm = "$script:Base/microsoft.compute/virtualmachines/vm-sql"
        $SqlVm = "$script:Base/microsoft.sqlvirtualmachine/sqlvirtualmachines/vm-sql"
        $Sub = New-Tok5; $Rg = New-Tok5; $Name = New-Tok5
        $P = "/subscriptions/$Sub/resourcegroups/$Rg/providers"
        Invoke-SeededRun5 -SeedMaps @{ ResourceIdMap = @{ "$P/microsoft.compute/virtualmachines/$Name" = $Vm; "$P/microsoft.sqlvirtualmachine/sqlvirtualmachines/$Name" = $SqlVm } } -Rows @((New-Res5 $Vm), (New-Res5 $SqlVm))
        $Global:ResourceIdDictionary[$Vm] | Should -BeExactly "$P/microsoft.compute/virtualmachines/$Name"
        $Global:ResourceIdDictionary[$SqlVm] | Should -BeExactly "$P/microsoft.sqlvirtualmachine/sqlvirtualmachines/$Name"
    }

    It 'keeps a seeded name map token for a resource whose seeded id is not kept' {
        $Vm = "$script:Base/microsoft.compute/virtualmachines/vm-n"
        $NameTok = New-Tok5
        Invoke-SeededRun5 -SeedMaps @{ ResourceIdMap = @{ (New-Tok5) = $Vm }; ResourceNameMap = @{ $NameTok = $Vm } } -Rows @((New-Res5 $Vm))
        $Global:ResourceNameDictionary[$Vm] | Should -BeExactly $NameTok
        ($Global:ResourceIdDictionary[$Vm] -split '/')[-1] | Should -BeExactly $NameTok
    }
}

Describe 'The seed check frees what it built' {
    It 'sets <_> to null in the seeded branch, after it is last read and before the token loop' -ForEach @('SeedSlotsOf', 'SeedSlotTokens', 'SeedDictionary') {
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'ResourceInventory.ps1'), [ref]$null, [ref]$null)
        $Setup = $Ast.Find({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'RunInventorySetup' }, $true)
        $Loop = $Setup.Find({ param($N) $N -is [System.Management.Automation.Language.ForEachStatementAst] -and $N.Condition.Extent.Text -match '^\$(TokenLoopRows|Global:Resources)$' -and $N.Body.Extent.Text -match 'IdsToMask\.Contains\(\$resourceItem\.ID\)' }, $true)
        $Name = $_
        $Nulls = @($Setup.FindAll({ param($N) $N -is [System.Management.Automation.Language.AssignmentStatementAst] -and $N.Left.Extent.Text -eq ('$' + $Name) -and $N.Right.Extent.Text -eq '$null' }, $true))
        $Nulls.Count | Should -Be 1
        $Null0 = $Nulls[0]
        # Inside an 'if' on the seed, as a statement that runs (not a comment).
        $If = $Null0.Parent
        while ($null -ne $If -and -not ($If -is [System.Management.Automation.Language.IfStatementAst] -and $If.Clauses[0].Item1.Extent.Text -match 'ObfuscationDictionary')) { $If = $If.Parent }
        $If | Should -Not -BeNullOrEmpty
        $Null0.Extent.StartOffset | Should -BeLessThan $Loop.Extent.StartOffset
        $Reads = @($Setup.FindAll({ param($N) $N -is [System.Management.Automation.Language.VariableExpressionAst] -and $N.VariablePath.UserPath -eq $Name -and $N.Extent.StartOffset -gt $Null0.Extent.EndOffset }, $true))
        $Reads | Should -BeNullOrEmpty -Because "$Name is not read after it is freed"
    }
}

Describe 'Test-ObfuscatedIdShape' {
    BeforeAll {
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'ResourceInventory.ps1'), [ref]$null, [ref]$null)
        $Fn = $Ast.Find({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'Test-ObfuscatedIdShape' }, $false)
        if ($null -ne $Fn) { . ([scriptblock]::Create($Fn.Extent.Text)) }
        $script:T = 'prod_0f0e0d0c-0b0a-4908-8706-050403020100'
    }

    It 'takes what Get-ObfuscatedResourceId writes, a $system name and a tenant-scope id' {
        Reset-ObfuscationState
        $Real = "$script:Base/microsoft.sql/servers/srv-a/databases/db-a"
        Test-ObfuscatedIdShape -RealId $Real -MaskedId (Get-ObfuscatedResourceId -ResourceId $Real) | Should -BeTrue
        Test-ObfuscatedIdShape -RealId "$script:Base/microsoft.servicebus/namespaces/`$system" -MaskedId "/subscriptions/$script:T/resourcegroups/$script:T/providers/microsoft.servicebus/namespaces/`$system" | Should -BeTrue
        Test-ObfuscatedIdShape -RealId '/providers/Microsoft.Capacity/reservationOrders/ro-a' -MaskedId "/providers/Microsoft.Capacity/reservationOrders/$script:T" | Should -BeTrue
    }

    It 'refuses <Label>' -ForEach @(
        @{ Label = 'a real parent name left'; Masked = '/subscriptions/{0}/resourcegroups/{0}/providers/microsoft.sql/servers/srv-a/databases/{0}' }
        @{ Label = 'a flat token'; Masked = '{0}' }
        @{ Label = 'another type'; Masked = '/subscriptions/{0}/resourcegroups/{0}/providers/microsoft.sql/servers/{0}/elasticpools/{0}' }
        @{ Label = 'a real resource group'; Masked = '/subscriptions/{0}/resourcegroups/rg-demo/providers/microsoft.sql/servers/{0}/databases/{0}' }
        @{ Label = 'the metric step''s old sub_ and rg_ tokens'; Masked = '/subscriptions/prod_sub_0f0e0d0c-0b0a-4908-8706-050403020100/resourcegroups/prod_rg_0f0e0d0c-0b0a-4908-8706-050403020100/providers/microsoft.sql/servers/{0}/databases/{0}' }
        @{ Label = 'a word in a name token'; Masked = '/subscriptions/{0}/resourcegroups/{0}/providers/microsoft.sql/servers/prod_secret_0f0e0d0c-0b0a-4908-8706-050403020100/databases/{0}' }
    ) {
        Test-ObfuscatedIdShape -RealId "$script:Base/microsoft.sql/servers/srv-a/databases/db-a" -MaskedId ($Masked -f $script:T) | Should -BeFalse
    }
}

