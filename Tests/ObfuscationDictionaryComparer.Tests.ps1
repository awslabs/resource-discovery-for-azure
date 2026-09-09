#Requires -Version 7.0
<#
    ObfuscationDictionaryComparer.Tests.ps1

    Pins WHICH obfuscation dictionaries are case-insensitive and which are not.

    THE FOUR IDENTIFIER DICTIONARIES ARE CASE-INSENSITIVE.
    ARM resource ids, subscription ids and resource-group names are
    case-insensitive identifiers by specification. A lookup keyed on exact case
    misses on a casing difference, and every consequence is SILENT:
      - a cross-reference (VM <-> disk, SQL VM <-> parent VM) falls through to the
        'obfuscated' sentinel instead of the real token
      - a consumption row fails to join back to its inventory resource
      - a dictionary seeded from a previous run (-ObfuscationDictionary) stops
        matching, so the same resource is re-tokenised and the runs no longer
        correlate
    Proven below: a plain Dictionary[string,string] returns FALSE from ContainsKey
    for a case variant, an OrdinalIgnoreCase one returns TRUE.

    TAG AND FREE-TEXT DICTIONARIES ARE CASE-SENSITIVE, DELIBERATELY.
    Azure tag VALUES are genuinely case-sensitive, so 'Env=Prod' and 'Env=prod'
    are two different values. Making those dictionaries case-insensitive would
    collapse them onto one token and lose a real distinction in the estate. There
    is no injectivity/distinctness assertion anywhere in the suite that would
    catch such a collapse - which is exactly why it is pinned here instead.

    Offline: source assertions plus pure .NET behaviour checks. Constructing the
    real globals needs the -Obfuscate branch of Variables(), which needs a run.
#>

BeforeAll {
    $script:InvPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'ResourceInventory.ps1'
    $script:InvSrc = Get-Content -LiteralPath $script:InvPath -Raw

    # Pull the construction lines so the assertions read the real code.
    $script:CtorLines = @($script:InvSrc -split "`r?`n" | Where-Object { $_ -match 'Dictionary\[string,string\]''' })

    function script:Get-CtorLineFor
    {
        param([string]$DictName)
        return @($script:CtorLines | Where-Object { $_ -match ([regex]::Escape('$Global:' + $DictName + ' =')) }) | Select-Object -First 1
    }
}

Describe 'The four IDENTIFIER dictionaries are built case-insensitive' {

    It '<Dict> uses OrdinalIgnoreCase' -ForEach @(
        @{ Dict = 'ResourceIdDictionary' }
        @{ Dict = 'ResourceNameDictionary' }
        @{ Dict = 'ResourceSubscriptionDictionary' }
        @{ Dict = 'ResourceResourceGroupDictionary' }
    ) {
        $Line = script:Get-CtorLineFor -DictName $Dict
        $Line | Should -Not -BeNullOrEmpty -Because "the construction of $Dict must be findable"
        $Line | Should -Match 'OrdinalIgnoreCase' -Because "a case-sensitive $Dict silently misses on an ARM casing difference, and every consequence of the miss is silent"
    }
}

Describe 'The tag / free-text dictionaries stay case-SENSITIVE' {

    It '<Dict> does NOT use a case-insensitive comparer' -ForEach @(
        @{ Dict = 'TagValueDictionary' }
        @{ Dict = 'FreeTextDictionary' }
    ) {
        $Line = script:Get-CtorLineFor -DictName $Dict
        $Line | Should -Not -BeNullOrEmpty -Because "the construction of $Dict must be findable"
        $Line | Should -Not -Match 'IgnoreCase' -Because "Azure tag values are case-sensitive; collapsing 'Prod' and 'prod' onto one token would lose a real distinction, and no injectivity test would catch it"
    }
}

Describe 'Why the comparer matters (behaviour, not opinion)' {

    It 'a case-SENSITIVE dictionary MISSES an ARM id that differs only in case' {
        $Sensitive = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Sensitive['/subscriptions/ABC/resourceGroups/RG1/providers/Microsoft.Compute/virtualMachines/VM1'] = 'prod_token'

        $Sensitive.ContainsKey('/subscriptions/abc/resourcegroups/rg1/providers/microsoft.compute/virtualmachines/vm1') |
            Should -BeFalse -Because 'this is the silent miss: the cross-reference would fall back to the obfuscated sentinel'
    }

    It 'a case-INSENSITIVE dictionary finds it, and returns the SAME token' {
        $Insensitive = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $Insensitive['/subscriptions/ABC/resourceGroups/RG1/providers/Microsoft.Compute/virtualMachines/VM1'] = 'prod_token'

        $Insensitive.ContainsKey('/subscriptions/abc/resourcegroups/rg1/providers/microsoft.compute/virtualmachines/vm1') |
            Should -BeTrue
        $Insensitive['/subscriptions/abc/resourcegroups/rg1/providers/microsoft.compute/virtualmachines/vm1'] |
            Should -Be 'prod_token' -Because 'determinism means one real resource maps to exactly one token, whatever its casing'
    }

    It 'case-insensitivity does NOT break determinism: one resource keeps one token' {
        # Writing through a differently-cased key must UPDATE the existing entry,
        # not add a second one - otherwise the same resource could carry two tokens.
        $D = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $D['/SUBS/A/RG/B'] = 'token1'
        $D['/subs/a/rg/b'] = 'token1'
        $D.Count | Should -Be 1 -Because 'two casings of one ARM id are one resource, so they must be one entry'
    }

    It 'a case-SENSITIVE tag dictionary keeps Prod and prod distinct' {
        # The reason the tag dictionary must NOT be switched over.
        $Tags = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Tags['Prod'] = 'tag_token_1'
        $Tags['prod'] = 'tag_token_2'
        $Tags.Count | Should -Be 2 -Because 'these are two genuinely different Azure tag values'

        $Collapsed = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $Collapsed['Prod'] = 'tag_token_1'
        $Collapsed['prod'] = 'tag_token_2'
        $Collapsed.Count | Should -Be 1 -Because 'this is the collapse being avoided: two real values, one token'
    }
}

Describe 'The case-drift diagnostic no longer claims a premise that is false' {

    It 'does not describe the inventory dictionary as case-sensitive' {
        # The consumption cross-link diagnostic existed partly to catch a
        # lowercasing regression, which was only a failure mode BECAUSE the
        # dictionary was case-sensitive. Leaving that wording in place would send
        # the next reader after a cause that can no longer occur.
        $script:InvSrc | Should -Not -Match 'verify resourceUri lowercasing vs the case-sensitive dictionary' -Because 'the dictionary is no longer case-sensitive, so that guidance would mislead'
    }

    It 'states the miss now means the resource is genuinely absent' {
        $script:InvSrc | Should -Match 'the dictionary is case-insensitive, so this means the resource is genuinely absent' -Because 'the diagnostic should say what a miss actually implies now'
    }
}

Describe 'Protect-RdaMetrics survives a mismatched seeded dictionary set' {

    # Protect-RdaMetrics checks ContainsKey on the ID map ONLY, then reads the three
    # companion maps for the same key. Under -ObfuscationDictionary those four maps
    # come from a FILE and are not guaranteed to be parallel, so the ID map can hold
    # a key the Name map lacks.
    #
    # MEASURED first, not assumed: a missing key on a Dictionary[string,string] does
    # NOT throw under PowerShell - the indexer adapter yields $null. So the defect is
    # a silent null, not a crash, and the fix is to fail closed to the standard
    # 'obfuscated' sentinel that the rest of the function already uses.

    BeforeAll {
        $MetricsFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'Extension/Metrics.ps1'
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($MetricsFile, [ref]$null, [ref]$null)

        # Load the REAL functions out of the file rather than restating them, so this
        # test cannot pass against a version that lost the guard.
        $Wanted = @('Get-RdaMappedValue', 'Protect-RdaMetrics')
        $Fns = $Ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $Wanted
            }, $true)

        # throw, not Should. A failed Should inside BeforeAll surfaces in Pester 5 as an
        # opaque container error rather than a named test failure, which buries the cause.
        if (@($Fns).Count -ne 2)
        {
            throw ('Expected to find both Get-RdaMappedValue and Protect-RdaMetrics in Extension/Metrics.ps1, found {0}: {1}' -f @($Fns).Count, (($Fns | ForEach-Object Name) -join ', '))
        }
        foreach ($f in $Fns) { . ([scriptblock]::Create($f.Extent.Text)) }

        function script:New-IdMap
        {
            New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        }
        $script:RealId = '/subscriptions/aaa/resourcegroups/rg1/providers/microsoft.compute/virtualmachines/vm1'
    }

    It 'confirms the premise: a missing key yields $null instead of throwing' {
        $Map = script:New-IdMap
        { $Map['nope'] } | Should -Not -Throw
        $Map['nope'] | Should -BeNullOrEmpty
    }

    It 'substitutes the sentinel for every companion field the seed is missing' {
        $Id = script:New-IdMap; $Nm = script:New-IdMap; $Sub = script:New-IdMap; $Rg = script:New-IdMap
        $Id[$script:RealId] = 'prod_11111111-1111-1111-1111-111111111111'
        # $Nm / $Sub / $Rg deliberately left empty - the mismatched-seed case.

        $Metrics = @(@{ ID = $script:RealId; Name = 'vm1'; Subscription = 'Real Sub Name'; ResourceGroup = 'rg1' })
        { Protect-RdaMetrics -Metrics $Metrics -ResourceIdDictionary $Id -ResourceNameDictionary $Nm -ResourceSubDictionary $Sub -ResourceGroupDictionary $Rg } |
            Should -Not -Throw

        $M = $Metrics[0]
        $M.ID | Should -Be 'prod_11111111-1111-1111-1111-111111111111'
        $M.Name | Should -Be 'obfuscated'
        $M.Subscription | Should -Be 'obfuscated'
        $M.ResourceGroup | Should -Be 'obfuscated'
    }

    It 'leaves no null or empty field, which the PII suite treats as a defect' {
        $Id = script:New-IdMap; $Nm = script:New-IdMap; $Sub = script:New-IdMap; $Rg = script:New-IdMap
        $Id[$script:RealId] = 'prod_token'

        $Metrics = @(@{ ID = $script:RealId; Name = 'vm1'; Subscription = 'Real Sub Name'; ResourceGroup = 'rg1' })
        Protect-RdaMetrics -Metrics $Metrics -ResourceIdDictionary $Id -ResourceNameDictionary $Nm -ResourceSubDictionary $Sub -ResourceGroupDictionary $Rg

        foreach ($Field in @('ID', 'Name', 'Subscription', 'ResourceGroup'))
        {
            $Metrics[0][$Field] | Should -Not -BeNullOrEmpty -Because "$Field must never ship null"
        }
    }

    It 'never leaks the real value it failed to map' {
        $Id = script:New-IdMap; $Nm = script:New-IdMap; $Sub = script:New-IdMap; $Rg = script:New-IdMap
        $Id[$script:RealId] = 'prod_token'

        $Metrics = @(@{ ID = $script:RealId; Name = 'vm1'; Subscription = 'Real Sub Name'; ResourceGroup = 'rg1' })
        Protect-RdaMetrics -Metrics $Metrics -ResourceIdDictionary $Id -ResourceNameDictionary $Nm -ResourceSubDictionary $Sub -ResourceGroupDictionary $Rg

        $Values = @($Metrics[0].Values)
        foreach ($Real in @('vm1', 'Real Sub Name', 'rg1', $script:RealId))
        {
            $Values | Should -Not -Contain $Real -Because 'failing closed must not fall back to the real value'
        }
    }

    It 'is byte-for-byte unchanged when all four maps agree' {
        $Id = script:New-IdMap; $Nm = script:New-IdMap; $Sub = script:New-IdMap; $Rg = script:New-IdMap
        $Id[$script:RealId] = 'prod_id'
        $Nm[$script:RealId] = 'prod_name'
        $Sub[$script:RealId] = 'prod_sub'
        $Rg[$script:RealId] = 'prod_rg'

        $Metrics = @(@{ ID = $script:RealId; Name = 'vm1'; Subscription = 'Real Sub Name'; ResourceGroup = 'rg1' })
        Protect-RdaMetrics -Metrics $Metrics -ResourceIdDictionary $Id -ResourceNameDictionary $Nm -ResourceSubDictionary $Sub -ResourceGroupDictionary $Rg

        $M = $Metrics[0]
        $M.ID | Should -Be 'prod_id'
        $M.Name | Should -Be 'prod_name'
        $M.Subscription | Should -Be 'prod_sub'
        $M.ResourceGroup | Should -Be 'prod_rg'
    }

    It 'still honours case-insensitive matching through the guarded reads' {
        # The comparer fix and this guard have to compose: an ID differing only in
        # case must resolve through BOTH the ContainsKey check and the companion reads.
        $Id = script:New-IdMap; $Nm = script:New-IdMap; $Sub = script:New-IdMap; $Rg = script:New-IdMap
        $Id[$script:RealId] = 'prod_id'
        $Nm[$script:RealId] = 'prod_name'
        $Sub[$script:RealId] = 'prod_sub'
        $Rg[$script:RealId] = 'prod_rg'

        $Metrics = @(@{ ID = $script:RealId.ToUpperInvariant(); Name = 'vm1'; Subscription = 'S'; ResourceGroup = 'rg1' })
        Protect-RdaMetrics -Metrics $Metrics -ResourceIdDictionary $Id -ResourceNameDictionary $Nm -ResourceSubDictionary $Sub -ResourceGroupDictionary $Rg

        $Metrics[0].Name | Should -Be 'prod_name' -Because 'a casing difference must not fall through to the sentinel'
    }
}
