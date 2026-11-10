# =============================================================================
# ReaderAccessCheck.Tests.ps1
#
# The up-front role check (Functions/Common.Functions.ps1). Resource Graph
# returns 0 rows rather than an error for a subscription the identity cannot
# read, so Run-AllSubscriptions.ps1 and direct runs of ResourceInventory.ps1
# decide read access per subscription from two answers - the identity's own
# role assignments (with their role definitions) and Azure's caller-permissions
# answer - and skip every subscription the combination does not show as
# readable, stopping with exit code 1 only when none is readable.
#
# The Az cmdlets are replaced by local stub functions and Pester mocks, so the
# tests run offline and without the Az modules installed.
# =============================================================================

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1')

    # These tests replace Azure with Pester mocks, which exist only in this
    # runspace, so the up-front checks run one subscription at a time here.
    # UpFrontChecksParallel.Tests.ps1 covers the parallel path.
    $script:PSDefaultParameterValues = @{
        'Test-SubscriptionRoleAccessAll:ThrottleLimit' = 1
        'Invoke-ConsumptionDataCheck:ThrottleLimit'    = 1
    }

    # Stubs so the mocks below have a command to replace when Az is absent.
    function Invoke-AzRestMethod { param($Method, $Path, $Payload, $Uri) }
    function Get-AzAccessToken { param($ResourceUrl) }
    function Get-AzContext { param() }
    function Exit-Wrapper { param([int]$Code = 0) }

    $script:BuiltIn = @{
        'Owner'          = @{ Actions = @('*'); NotActions = @() }
        'Contributor'    = @{ Actions = @('*'); NotActions = @('Microsoft.Authorization/*/Delete', 'Microsoft.Authorization/*/Write', 'Microsoft.Authorization/elevateAccess/Action', 'Microsoft.Blueprint/blueprintAssignments/write', 'Microsoft.Blueprint/blueprintAssignments/delete', 'Microsoft.Compute/galleries/share/action', 'Microsoft.Purview/consents/write', 'Microsoft.Purview/consents/delete', 'Microsoft.Resources/deploymentStacks/manageDenySetting/action', 'Microsoft.Subscription/cancel/action', 'Microsoft.Subscription/enable/action') }
        'Reader'         = @{ Actions = @('*/read'); NotActions = @() }
        'Billing Reader' = @{ Actions = @('Microsoft.Authorization/*/read', 'Microsoft.Billing/*/read', 'Microsoft.Commerce/*/read', 'Microsoft.Consumption/*/read', 'Microsoft.Management/managementGroups/read', 'Microsoft.CostManagement/*/read', 'Microsoft.Support/*'); NotActions = @() }
        'SubRead'        = @{ Actions = @('Microsoft.Resources/subscriptions/read'); NotActions = @() }
        'NoCommerce'     = @{ Actions = @('*/read'); NotActions = @('Microsoft.Commerce/*') }
        'NoAuthorization' = @{ Actions = @('*/read'); NotActions = @('Microsoft.Authorization/*') }
        'NoComputeRead'   = @{ Actions = @('*/read'); NotActions = @('Microsoft.Compute/*/read') }
    }
    $script:RoleNames = @{ 'SubRead' = 'Subscription read only'; 'NoCommerce' = 'Reader without Commerce'; 'NoAuthorization' = 'Reader without Authorization'; 'NoComputeRead' = 'Reader without Compute' }

    function New-Grant
    {
        param([string]$Role, [string]$Label = $Role)
        [pscustomobject]@{ Label = $Label; Actions = $script:BuiltIn[$Role].Actions; NotActions = $script:BuiltIn[$Role].NotActions }
    }

    function Test-Allows
    {
        param([object[]]$Grants, [ValidateSet('Resources', 'Usage')][string]$Kind)
        @(Get-RoleGrantsAllowing -Grants $Grants -Action (Get-RoleCheckAction -Kind $Kind)).Count -gt 0
    }

    function New-Response
    {
        param([int]$Status, $Body = @{})
        [pscustomobject]@{ StatusCode = $Status; Content = ($Body | ConvertTo-Json -Depth 10) }
    }

    # Azure, as the tests see it. Assignments: list of @{ Role; Scope; Group }.
    # Permissions: scope path (lower case) -> @{ Status; Roles } or a list of
    # statuses to return in turn. Unlisted scopes answer 200 with no entries.
    function Set-RoleScenario
    {
        param(
            [object[]]$Assignments = @(),
            $ListStatus = 200,
            [hashtable]$Permissions = @{},
            $DefinitionStatus = 200
        )
        $script:Scenario = @{ Assignments = $Assignments; ListStatus = @($ListStatus); Permissions = $Permissions; DefinitionStatus = @($DefinitionStatus); DefinitionCalls = 0; ListCalls = 0; PermCalls = @{} }
        $script:Calls = [System.Collections.Generic.List[string]]::new()
    }

    function Get-ScenarioResponse
    {
        param([string]$Target)
        $S = $script:Scenario
        if ($Target -match '^/subscriptions/([^/]+)/providers/Microsoft\.Authorization/roleAssignments\?')
        {
            $Sub = $Matches[1]
            $script:Calls.Add('roles ' + $Sub)
            $Status = $S.ListStatus[[math]::Min($S.ListCalls, $S.ListStatus.Count - 1)]
            $S.ListCalls++
            if ($Status -ne 200) { return (New-Response -Status $Status -Body @{ error = @{ code = 'x' } }) }
            $Items = @($S.Assignments | Where-Object { $_.Scope -eq '/' -or $_.Scope -like '/providers/*' -or $_.Scope -like "/subscriptions/$Sub*" } | ForEach-Object {
                    @{ properties = @{
                            roleDefinitionId = "/subscriptions/$Sub/providers/Microsoft.Authorization/roleDefinitions/$($_.Role)"
                            scope            = $_.Scope
                            principalId      = $(if ($_.Group) { 'group-1' } else { 'caller-oid' })
                            principalType    = $(if ($_.Group) { 'Group' } else { 'ServicePrincipal' })
                        }
                    }
                })
            return (New-Response -Status 200 -Body @{ value = $Items })
        }
        if ($Target -match '/roleDefinitions/([^?]+)\?')
        {
            $Role = $Matches[1]
            $script:Calls.Add('definition ' + $Role)
            $Status = $S.DefinitionStatus[[math]::Min($S.DefinitionCalls, $S.DefinitionStatus.Count - 1)]
            $S.DefinitionCalls++
            if ($Status -ne 200) { return (New-Response -Status $Status) }
            $Name = if ($script:RoleNames.ContainsKey($Role)) { $script:RoleNames[$Role] } else { $Role }
            $Type = if ($script:RoleNames.ContainsKey($Role)) { 'CustomRole' } else { 'BuiltInRole' }
            return (New-Response -Status 200 -Body @{ properties = @{ roleName = $Name; type = $Type; permissions = @(@{ actions = $script:BuiltIn[$Role].Actions; notActions = $script:BuiltIn[$Role].NotActions }) } })
        }
        if ($Target -match '^(.*)/providers/Microsoft\.Authorization/permissions\?')
        {
            $Scope = $Matches[1].ToLowerInvariant()
            $script:Calls.Add('permissions ' + $Scope)
            $Entry = $S.Permissions[$Scope]
            if ($null -eq $Entry) { return (New-Response -Status 200 -Body @{ value = @() }) }
            $N = if ($S.PermCalls.ContainsKey($Scope)) { $S.PermCalls[$Scope] } else { 0 }
            $S.PermCalls[$Scope] = $N + 1
            $Status = @($Entry.Status)[[math]::Min($N, @($Entry.Status).Count - 1)]
            if ($Status -ne 200) { return (New-Response -Status $Status -Body @{ error = @{ code = 'x' } }) }
            return (New-Response -Status 200 -Body @{ value = @(@($Entry.Roles) | ForEach-Object { @{ actions = $script:BuiltIn[$_].Actions; notActions = $script:BuiltIn[$_].NotActions } }) })
        }
        throw "unexpected request $Target"
    }

    $script:SubA = [pscustomobject]@{ Id = 'sub-a'; Name = 'Alpha' }
}

Describe 'Role action evaluation' {
    It '<Role>: resources <Res>, usage <Use>' -TestCases @(
        @{ Role = 'Owner'; Res = $true; Use = $true }
        @{ Role = 'Contributor'; Res = $true; Use = $true }
        @{ Role = 'Reader'; Res = $true; Use = $true }
        @{ Role = 'Billing Reader'; Res = $false; Use = $true }
        @{ Role = 'SubRead'; Res = $false; Use = $false }
        @{ Role = 'NoCommerce'; Res = $true; Use = $false }
        @{ Role = 'NoAuthorization'; Res = $true; Use = $true }
        @{ Role = 'NoComputeRead'; Res = $false; Use = $true }
    ) {
        param($Role, $Res, $Use)
        Test-Allows -Grants @(New-Grant $Role) -Kind Resources | Should -Be $Res
        Test-Allows -Grants @(New-Grant $Role) -Kind Usage | Should -Be $Use
    }

    It 'notActions only subtract from their own role' {
        $Grants = @((New-Grant 'NoCommerce'), (New-Grant 'Billing Reader'))
        Get-RoleGrantsAllowing -Grants $Grants -Action (Get-RoleCheckAction -Kind Usage) | Should -Be @('Billing Reader')
    }

    It 'matches case-insensitively in actions and notActions' {
        Test-RoleActionAllowed -Actions @('MICROSOFT.COMMERCE/*/READ') -NotActions @() -Action 'Microsoft.Commerce/UsageAggregates/read' | Should -BeTrue
        Test-RoleActionAllowed -Actions @('*') -NotActions @('microsoft.commerce/*') -Action 'Microsoft.Commerce/UsageAggregates/read' | Should -BeFalse
    }

    It 'a wildcard matches any characters; a literal matches only itself' {
        Test-RoleActionPatternMatch -Pattern 'Microsoft.Commerce/*/read' -Action 'Microsoft.Commerce/UsageAggregates/read' | Should -BeTrue
        Test-RoleActionPatternMatch -Pattern 'Microsoft.Commerce/*/read' -Action 'Microsoft.Compute/virtualMachines/read' | Should -BeFalse
        Test-RoleActionPatternMatch -Pattern 'Microsoft.Resources/subscriptions/read' -Action 'Microsoft.Resources/subscriptions/resourceGroups/read' | Should -BeFalse
        Test-RoleActionPatternMatch -Pattern 'Microsoft.Resources/subscriptions.read' -Action 'Microsoft.Resources/subscriptionsXread' | Should -BeFalse
    }
}

Describe 'Read access that leaves out some resource types' {
    It 'a notAction <Pattern> next to <Actions> removes read access' -TestCases @(
        @{ Actions = '*/read'; Pattern = 'Microsoft.Compute/*' }
        @{ Actions = '*/read'; Pattern = 'Microsoft.Compute/*/read' }
        @{ Actions = '*/read'; Pattern = 'Microsoft.Compute/virtualMachines/read' }
        @{ Actions = '*/read'; Pattern = 'MICROSOFT.COMPUTE/VIRTUALMACHINES/READ' }
        @{ Actions = '*'; Pattern = 'Microsoft.Storage/storageAccounts/*' }
        @{ Actions = '*'; Pattern = 'Microsoft.Network/*/Read' }
    ) {
        param($Actions, $Pattern)
        Test-Allows -Grants @([pscustomobject]@{ Label = 'custom'; Actions = @($Actions); NotActions = @($Pattern) }) -Kind Resources | Should -BeFalse
        Get-RoleReadExclusion -NotActions @('Microsoft.Compute/virtualMachines/write', $Pattern) | Should -Be $Pattern
    }

    It 'a wildcard notAction <Pattern> that can match a read action (such as <Example>) removes read access' -TestCases @(
        @{ Pattern = 'Microsoft.Comp*'; Example = 'Microsoft.Compute/virtualMachines/read' }
        @{ Pattern = 'Microsoft.Compute/*/r*'; Example = 'Microsoft.Compute/disks/read' }
        @{ Pattern = 'Microsoft.Compute/virtualMachines/re*d'; Example = 'Microsoft.Compute/virtualMachines/read' }
        @{ Pattern = 'Microsoft.Compute*read'; Example = 'Microsoft.Compute/virtualMachines/read' }
        @{ Pattern = '*ad'; Example = 'Microsoft.Storage/storageAccounts/read' }
        @{ Pattern = 'Microsoft.Auth*'; Example = 'Microsoft.AuthExample/items/read' }
    ) {
        param($Pattern, $Example)
        Test-RoleActionPatternMatch -Pattern $Pattern -Action $Example | Should -BeTrue
        Get-RoleReadExclusion -NotActions @('Microsoft.Compute/virtualMachines/write', $Pattern) | Should -Be $Pattern
        Test-Allows -Grants @([pscustomobject]@{ Label = 'custom'; Actions = @('*/read'); NotActions = @($Pattern) }) -Kind Resources | Should -BeFalse
    }

    It 'a notAction confined to <Pattern> keeps read access' -TestCases @(
        @{ Pattern = 'Microsoft.Authorization/*' }
        @{ Pattern = 'microsoft.authorization/roleAssignments/read' }
        @{ Pattern = 'Microsoft.Commerce/*' }
        @{ Pattern = 'Microsoft.Consumption/*/read' }
        @{ Pattern = 'Microsoft.Billing/*' }
    ) {
        param($Pattern)
        Get-RoleReadExclusion -NotActions @($Pattern) | Should -BeNullOrEmpty
        Test-Allows -Grants @([pscustomobject]@{ Label = 'custom'; Actions = @('*/read'); NotActions = @($Pattern) }) -Kind Resources | Should -BeTrue
    }

    It 'a notAction that is not a read (<Pattern>) keeps read access' -TestCases @(
        @{ Pattern = 'Microsoft.Compute/virtualMachines/write' }
        @{ Pattern = 'Microsoft.Compute/*/delete' }
        @{ Pattern = '*/action' }
        @{ Pattern = '*/write' }
        @{ Pattern = 'Microsoft.Compute/*rea' }
        @{ Pattern = 'Microsoft.Authorization/*/Delete' }
        @{ Pattern = 'Microsoft.Authorization/*/Write' }
        @{ Pattern = 'Microsoft.Authorization/elevateAccess/Action' }
    ) {
        param($Pattern)
        Get-RoleReadExclusion -NotActions @($Pattern) | Should -BeNullOrEmpty
        Test-Allows -Grants @([pscustomobject]@{ Label = 'custom'; Actions = @('*'); NotActions = @($Pattern) }) -Kind Resources | Should -BeTrue
    }

    It 'Contributor''s notActions keep read access' {
        Get-RoleReadExclusion -NotActions $script:BuiltIn['Contributor'].NotActions | Should -BeNullOrEmpty
    }

    It 'Reader beside a role that leaves out some types still reads everything (each role counts on its own)' {
        Test-Allows -Grants @((New-Grant 'NoComputeRead'), (New-Grant 'Reader')) -Kind Resources | Should -BeTrue
        Test-Allows -Grants @(New-Grant 'NoComputeRead') -Kind Usage | Should -BeTrue
    }

    It 'lists the excluding pattern per role that would otherwise read everything' {
        $Found = @(Get-RoleReadExclusions -Grants @((New-Grant 'NoComputeRead' -Label 'one'), (New-Grant 'Billing Reader' -Label 'two'), (New-Grant 'Reader' -Label 'three')))
        $Found.Count | Should -Be 1
        $Found[0].Grant.Label | Should -Be 'one'
        $Found[0].Pattern | Should -Be 'Microsoft.Compute/*/read'
    }
}

Describe 'Get-RoleAssignmentScopeKind' {
    It '<Scope> with resource group "<Rg>" is <Kind>' -TestCases @(
        @{ Scope = '/'; Rg = ''; Kind = 'tenant root' }
        @{ Scope = '/providers/Microsoft.Management/managementGroups/mg-1'; Rg = ''; Kind = 'management group' }
        @{ Scope = '/subscriptions/SUB-A'; Rg = ''; Kind = 'subscription' }
        @{ Scope = '/subscriptions/sub-a/resourceGroups/RG-One'; Rg = 'rg-one'; Kind = 'target resource group' }
        @{ Scope = '/subscriptions/sub-a/resourceGroups/rg-one'; Rg = ''; Kind = 'resource group' }
        @{ Scope = '/subscriptions/sub-a/resourceGroups/rg-two'; Rg = 'rg-one'; Kind = 'resource group' }
        @{ Scope = '/subscriptions/sub-a/resourceGroups/rg-one/providers/Microsoft.Storage/storageAccounts/sa'; Rg = 'rg-one'; Kind = 'resource' }
        @{ Scope = '/subscriptions/sub-b'; Rg = ''; Kind = 'other' }
    ) {
        param($Scope, $Rg, $Kind)
        Get-RoleAssignmentScopeKind -Scope $Scope -SubscriptionId 'sub-a' -ResourceGroup $Rg | Should -Be $Kind
    }
}

Describe 'Get-RoleAssignmentAccess (role assignments)' {
    BeforeEach {
        Mock Start-Sleep { }
        Mock Invoke-AzRestMethod { Get-ScenarioResponse -Target $(if ($Path) { $Path } else { $Uri }) }
    }

    It 'Reader at <Scope> gives resources and usage' -TestCases @(
        @{ Scope = '/' }
        @{ Scope = '/providers/Microsoft.Management/managementGroups/mg-1' }
        @{ Scope = '/subscriptions/sub-a' }
    ) {
        param($Scope)
        Set-RoleScenario -Assignments @(@{ Role = 'Reader'; Scope = $Scope })
        $A = Get-RoleAssignmentAccess -SubscriptionId 'sub-a' -CallerObjectId 'caller-oid'
        $A.Resources | Should -Be 'Yes'
        $A.Usage | Should -Be 'Yes'
    }

    It 'lists assignedTo for the caller, which includes group grants' {
        Set-RoleScenario -Assignments @(@{ Role = 'Reader'; Scope = '/subscriptions/sub-a'; Group = $true })
        $A = Get-RoleAssignmentAccess -SubscriptionId 'sub-a' -CallerObjectId 'caller-oid'
        $A.Resources | Should -Be 'Yes'
        $A.ResourcesGrantedBy | Should -Be @('Reader at subscription through a group')
        Should -Invoke Invoke-AzRestMethod -Times 1 -Exactly -ParameterFilter { $Path -eq "/subscriptions/sub-a/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=assignedTo('caller-oid')" }
    }

    It 'a resource group grant gives resources only to a -ResourceGroup run on that resource group, and never usage' {
        Set-RoleScenario -Assignments @(@{ Role = 'Reader'; Scope = '/subscriptions/sub-a/resourceGroups/rg-one' })
        $OnRg = Get-RoleAssignmentAccess -SubscriptionId 'sub-a' -ResourceGroup 'rg-one' -CallerObjectId 'caller-oid'
        $OnRg.Resources | Should -Be 'Yes'
        $OnRg.Usage | Should -Be 'No'
        $OnRg.ResourcesGrantedBy | Should -Be @("Reader at resource group 'rg-one'")

        $WholeSub = Get-RoleAssignmentAccess -SubscriptionId 'sub-a' -CallerObjectId 'caller-oid'
        $WholeSub.Resources | Should -Be 'No'
        $WholeSub.Usage | Should -Be 'No'
        $WholeSub.VisibleRoles | Should -Be @('Reader at a resource group')

        $OtherRg = Get-RoleAssignmentAccess -SubscriptionId 'sub-a' -ResourceGroup 'rg-two' -CallerObjectId 'caller-oid'
        $OtherRg.Resources | Should -Be 'No'
    }

    It 'labels custom roles' {
        Set-RoleScenario -Assignments @(@{ Role = 'NoCommerce'; Scope = '/subscriptions/sub-a' })
        $A = Get-RoleAssignmentAccess -SubscriptionId 'sub-a' -CallerObjectId 'caller-oid'
        $A.Resources | Should -Be 'Yes'
        $A.Usage | Should -Be 'No'
        $A.ResourcesGrantedBy | Should -Be @('Reader without Commerce (custom role) at subscription')
    }

    It 'is NotVisible when the list comes back empty or refused (HTTP <Status>)' -TestCases @(@{ Status = 200 }, @{ Status = 403 }, @{ Status = 401 }) {
        param($Status)
        Set-RoleScenario -Assignments @() -ListStatus $Status
        $A = Get-RoleAssignmentAccess -SubscriptionId 'sub-a' -CallerObjectId 'caller-oid'
        $A.Resources | Should -Be 'NotVisible'
        $A.Usage | Should -Be 'NotVisible'
    }

    It 'is Unknown when the caller object id is missing, without calling Azure' {
        Set-RoleScenario -Assignments @(@{ Role = 'Reader'; Scope = '/subscriptions/sub-a' })
        $A = Get-RoleAssignmentAccess -SubscriptionId 'sub-a' -CallerObjectId ''
        $A.Resources | Should -Be 'Unknown'
        Should -Invoke Invoke-AzRestMethod -Times 0 -Exactly
    }

    It 'is Unknown when a counted role definition cannot be read' {
        Set-RoleScenario -Assignments @(@{ Role = 'Reader'; Scope = '/subscriptions/sub-a' }) -DefinitionStatus 403
        (Get-RoleAssignmentAccess -SubscriptionId 'sub-a' -CallerObjectId 'caller-oid').Resources | Should -Be 'Unknown'
    }

    It 'retries a throttled list, then uses the answer' {
        Set-RoleScenario -Assignments @(@{ Role = 'Reader'; Scope = '/subscriptions/sub-a' }) -ListStatus @(429, 200)
        (Get-RoleAssignmentAccess -SubscriptionId 'sub-a' -CallerObjectId 'caller-oid').Resources | Should -Be 'Yes'
        $script:Scenario.ListCalls | Should -Be 2
    }

    It 'is Unknown when throttling persists after the retries, and does not retry a 400' {
        Set-RoleScenario -Assignments @() -ListStatus 503
        (Get-RoleAssignmentAccess -SubscriptionId 'sub-a' -CallerObjectId 'caller-oid' -MaxRetries 3).Resources | Should -Be 'Unknown'
        $script:Scenario.ListCalls | Should -Be 4
        Set-RoleScenario -Assignments @() -ListStatus 400
        (Get-RoleAssignmentAccess -SubscriptionId 'sub-a' -CallerObjectId 'caller-oid').Resources | Should -Be 'Unknown'
        $script:Scenario.ListCalls | Should -Be 1
    }

    It 'reads each role definition once across subscriptions' {
        Set-RoleScenario -Assignments @(@{ Role = 'Reader'; Scope = '/subscriptions/sub-a' }, @{ Role = 'Reader'; Scope = '/subscriptions/sub-b' })
        $Cache = @{}
        $null = Get-RoleAssignmentAccess -SubscriptionId 'sub-a' -CallerObjectId 'caller-oid' -DefinitionCache $Cache
        $null = Get-RoleAssignmentAccess -SubscriptionId 'sub-b' -CallerObjectId 'caller-oid' -DefinitionCache $Cache
        @($script:Calls | Where-Object { $_ -like 'definition *' }).Count | Should -Be 1
    }

    It 'does not read a refused role definition again (HTTP <Status>), and the verdict stays Unknown' -TestCases @(@{ Status = 401 }, @{ Status = 403 }, @{ Status = 404 }) {
        param($Status)
        Set-RoleScenario -Assignments @(@{ Role = 'Reader'; Scope = '/subscriptions/sub-a' }, @{ Role = 'Reader'; Scope = '/subscriptions/sub-b' }, @{ Role = 'Reader'; Scope = '/subscriptions/sub-c' }) -DefinitionStatus $Status
        $Cache = @{}
        $Verdicts = foreach ($Sub in @('sub-a', 'sub-b', 'sub-c')) { (Get-RoleAssignmentAccess -SubscriptionId $Sub -CallerObjectId 'caller-oid' -DefinitionCache $Cache).Resources }
        @($Verdicts) | Should -Be @('Unknown', 'Unknown', 'Unknown')
        @($script:Calls | Where-Object { $_ -like 'definition *' }).Count | Should -Be 1
    }

    It 'reads a role definition again after a server error, so a later subscription can pass' {
        Set-RoleScenario -Assignments @(@{ Role = 'Reader'; Scope = '/subscriptions/sub-a' }, @{ Role = 'Reader'; Scope = '/subscriptions/sub-b' }) -DefinitionStatus @(503, 503, 503, 503, 200)
        $Cache = @{}
        (Get-RoleAssignmentAccess -SubscriptionId 'sub-a' -CallerObjectId 'caller-oid' -DefinitionCache $Cache -MaxRetries 3).Resources | Should -Be 'Unknown'
        (Get-RoleAssignmentAccess -SubscriptionId 'sub-b' -CallerObjectId 'caller-oid' -DefinitionCache $Cache -MaxRetries 3).Resources | Should -Be 'Yes'
        @($script:Calls | Where-Object { $_ -like 'definition *' }).Count | Should -Be 5
    }

    It 'names the role and the excluded pattern when a role reads all but some resource types' {
        Set-RoleScenario -Assignments @(@{ Role = 'NoComputeRead'; Scope = '/subscriptions/sub-a'; Group = $true })
        $A = Get-RoleAssignmentAccess -SubscriptionId 'sub-a' -CallerObjectId 'caller-oid'
        $A.Resources | Should -Be 'No'
        $A.Usage | Should -Be 'Yes'
        $A.ResourcesExcluded | Should -Be @("role 'Reader without Compute' at subscription through a group excludes 'Microsoft.Compute/*/read'")
    }
}

Describe 'Get-CallerPermissionsAccess (Azure''s answer)' {
    BeforeEach {
        Mock Start-Sleep { }
        Mock Invoke-AzRestMethod { Get-ScenarioResponse -Target $(if ($Path) { $Path } else { $Uri }) }
    }

    It '<Role> gives resources <Res> and usage <Use>' -TestCases @(
        @{ Role = 'Reader'; Res = 'Yes'; Use = 'Yes' }
        @{ Role = 'Billing Reader'; Res = 'No'; Use = 'Yes' }
        @{ Role = 'SubRead'; Res = 'No'; Use = 'No' }
        @{ Role = 'NoCommerce'; Res = 'Yes'; Use = 'No' }
    ) {
        param($Role, $Res, $Use)
        Set-RoleScenario -Permissions @{ '/subscriptions/sub-a' = @{ Status = 200; Roles = @($Role) } }
        $B = Get-CallerPermissionsAccess -ScopePath '/subscriptions/sub-a'
        $B.Resources | Should -Be $Res
        $B.Usage | Should -Be $Use
    }

    It 'maps 403 to No, 404 to No for a subscription and NotFound for a resource group, and 400 to Unknown without retrying' {
        Set-RoleScenario -Permissions @{ '/subscriptions/sub-a' = @{ Status = 403 } }
        (Get-CallerPermissionsAccess -ScopePath '/subscriptions/sub-a').Resources | Should -Be 'No'
        Set-RoleScenario -Permissions @{ '/subscriptions/sub-a' = @{ Status = 404 }; '/subscriptions/sub-a/resourcegroups/rg-one' = @{ Status = 404 } }
        (Get-CallerPermissionsAccess -ScopePath '/subscriptions/sub-a').Resources | Should -Be 'No'
        (Get-CallerPermissionsAccess -ScopePath '/subscriptions/sub-a/resourceGroups/rg-one' -ResourceGroupTarget).Resources | Should -Be 'NotFound'
        Set-RoleScenario -Permissions @{ '/subscriptions/sub-a' = @{ Status = 400 } }
        (Get-CallerPermissionsAccess -ScopePath '/subscriptions/sub-a').Resources | Should -Be 'Unknown'
        $script:Scenario.PermCalls['/subscriptions/sub-a'] | Should -Be 1
    }

    It 'retries 429 and accepts the 200 that follows; stays Unknown after four 429s' {
        Set-RoleScenario -Permissions @{ '/subscriptions/sub-a' = @{ Status = @(429, 200); Roles = @('Reader') } }
        (Get-CallerPermissionsAccess -ScopePath '/subscriptions/sub-a').Resources | Should -Be 'Yes'
        $script:Scenario.PermCalls['/subscriptions/sub-a'] | Should -Be 2
        Set-RoleScenario -Permissions @{ '/subscriptions/sub-a' = @{ Status = 429 } }
        (Get-CallerPermissionsAccess -ScopePath '/subscriptions/sub-a' -MaxRetries 3).Resources | Should -Be 'Unknown'
        $script:Scenario.PermCalls['/subscriptions/sub-a'] | Should -Be 4
    }
}

Describe 'Resolve-RoleCheckVerdict (every combination)' {
    It 'role assignments <A> + caller permissions <B> -> <Expected>' -TestCases @(
        @{ A = 'Yes'; B = 'Yes'; Expected = 'Yes' }
        @{ A = 'No'; B = 'No'; Expected = 'No' }
        @{ A = 'NotVisible'; B = 'Yes'; Expected = 'YesPermissionsOnly' }
        @{ A = 'NotVisible'; B = 'No'; Expected = 'NoNotVisible' }
        @{ A = 'Yes'; B = 'No'; Expected = 'Disagree' }
        @{ A = 'No'; B = 'Yes'; Expected = 'Disagree' }
        @{ A = 'Unknown'; B = 'Yes'; Expected = 'Unknown' }
        @{ A = 'Yes'; B = 'Unknown'; Expected = 'Unknown' }
        @{ A = 'NotVisible'; B = 'Unknown'; Expected = 'Unknown' }
        @{ A = 'Yes'; B = 'NotFound'; Expected = 'NotFound' }
        @{ A = 'No'; B = 'NotFound'; Expected = 'NotFound' }
        @{ A = ''; B = 'Yes'; Expected = 'Disagree' }
    ) {
        param($A, $B, $Expected)
        Resolve-RoleCheckVerdict -Assignments $A -Permissions $B | Should -Be $Expected
    }
}

Describe 'Test-SubscriptionRoleAccessAll' {
    BeforeEach {
        $script:Lines = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { $script:Lines.Add([string]$Object) }
        Mock Start-Sleep { }
        Mock Get-RoleCheckCallerObjectId { 'caller-oid' }
        Mock Invoke-AzRestMethod { Get-ScenarioResponse -Target $(if ($Path) { $Path } else { $Uri }) }
    }

    It '<Case>: state <State>' -TestCases @(
        @{ Case = 'Reader at the subscription'; Assign = @(@{ Role = 'Reader'; Scope = '/subscriptions/sub-a' }); Perm = 'Reader'; State = 'Readable'; Reason = 'Read access: Reader at subscription' }
        @{ Case = 'Reader through a group'; Assign = @(@{ Role = 'Reader'; Scope = '/subscriptions/sub-a'; Group = $true }); Perm = 'Reader'; State = 'Readable'; Reason = 'Read access: Reader at subscription through a group' }
        @{ Case = 'roles not visible, Azure reports read'; Assign = @(); Perm = 'NoAuthorization'; State = 'Readable'; Reason = 'role assignments are not visible to this identity; Azure reports read access' }
        @{ Case = 'roles not visible, no read'; Assign = @(); Perm = 'SubRead'; State = 'NoAccess'; Reason = 'no read access (role assignments not visible to this identity)' }
        @{ Case = 'Reader on a resource group only'; Assign = @(@{ Role = 'Reader'; Scope = '/subscriptions/sub-a/resourceGroups/rg-one' }); Perm = $null; State = 'NoAccess'; Reason = 'no role grants read access (roles visible: Reader at a resource group)' }
        @{ Case = 'Billing Reader only'; Assign = @(@{ Role = 'Billing Reader'; Scope = '/subscriptions/sub-a' }); Perm = 'Billing Reader'; State = 'NoAccess'; Reason = 'no role grants read access (roles visible: Billing Reader at subscription)' }
    ) {
        param($Case, $Assign, $Perm, $State, $Reason)
        $Permissions = @{}
        if ($Perm) { $Permissions['/subscriptions/sub-a'] = @{ Status = 200; Roles = @($Perm) } }
        Set-RoleScenario -Assignments $Assign -Permissions $Permissions
        $R = @(Test-SubscriptionRoleAccessAll -Subscriptions @($script:SubA))
        $R.Count | Should -Be 1
        $R[0].State | Should -Be $State
        $R[0].Reason | Should -Be $Reason
        $Tag = if ($State -eq 'Readable') { 'Pass' } else { $State }
        $script:Lines[0] | Should -BeLike ([WildcardPattern]::Escape(('  [{0}] Alpha - {1} (' -f $Tag, $Reason)) + '*s)')
    }

    It 'stops on a disagreement (<Case>) and says to wait and re-run' -TestCases @(
        @{ Case = 'roles say yes, Azure says no'; Assign = @(@{ Role = 'Reader'; Scope = '/subscriptions/sub-a' }); Perm = $null }
        @{ Case = 'roles say no, Azure says yes'; Assign = @(@{ Role = 'SubRead'; Scope = '/subscriptions/sub-a' }); Perm = 'Reader' }
    ) {
        param($Case, $Assign, $Perm)
        $Permissions = @{}
        if ($Perm) { $Permissions['/subscriptions/sub-a'] = @{ Status = 200; Roles = @($Perm) } }
        Set-RoleScenario -Assignments $Assign -Permissions $Permissions
        $R = @(Test-SubscriptionRoleAccessAll -Subscriptions @($script:SubA))
        $R[0].State | Should -Be 'Disagree'
        $R[0].Reason | Should -Match 'if roles changed in the last few minutes, wait 5 minutes and re-run$'
        (Resolve-AccessPreflight -Probed $R).ShouldBlock | Should -BeTrue
    }

    It 'stops as inconclusive when an answer stays throttled' {
        Set-RoleScenario -Assignments @(@{ Role = 'Reader'; Scope = '/subscriptions/sub-a' }) -Permissions @{ '/subscriptions/sub-a' = @{ Status = 429 } }
        $R = @(Test-SubscriptionRoleAccessAll -Subscriptions @($script:SubA))
        $R[0].State | Should -Be 'Unknown'
        $R[0].Reason | Should -BeLike 'role check inconclusive after retries (*'
    }

    It 'for a -ResourceGroup run checks that resource group, and the subscription only for usage' {
        Set-RoleScenario -Assignments @(@{ Role = 'Reader'; Scope = '/subscriptions/sub-a/resourceGroups/rg-one' }) -Permissions @{ '/subscriptions/sub-a/resourcegroups/rg-one' = @{ Status = 200; Roles = @('Reader') } }
        $R = @(Test-SubscriptionRoleAccessAll -Subscriptions @($script:SubA) -ResourceGroup 'rg-one' -IncludeUsage)
        $R[0].State | Should -Be 'Readable'
        $R[0].Reason | Should -Be "Read access: Reader at resource group 'rg-one'"
        $R[0].UsageVerdict | Should -Be 'No'
        $script:Calls | Should -Contain 'permissions /subscriptions/sub-a/resourcegroups/rg-one'
        $script:Calls | Should -Contain 'permissions /subscriptions/sub-a'
        $script:Lines[1] | Should -Be '      usage permission (Microsoft.Commerce/UsageAggregates/read): no - the roles on this subscription do not include it'
    }

    It 'for a -ResourceGroup run without consumption asks Azure about the resource group only' {
        Set-RoleScenario -Assignments @(@{ Role = 'Reader'; Scope = '/subscriptions/sub-a' }) -Permissions @{ '/subscriptions/sub-a/resourcegroups/rg-one' = @{ Status = 200; Roles = @('Reader') } }
        $R = @(Test-SubscriptionRoleAccessAll -Subscriptions @($script:SubA) -ResourceGroup 'rg-one')
        $R[0].State | Should -Be 'Readable'
        @($script:Calls | Where-Object { $_ -like 'permissions *' }) | Should -Be @('permissions /subscriptions/sub-a/resourcegroups/rg-one')
        $R[0].UsageVerdict | Should -BeNullOrEmpty
        $script:Lines.Count | Should -Be 1
    }

    It 'stops when the -ResourceGroup target does not exist' {
        Set-RoleScenario -Assignments @(@{ Role = 'Reader'; Scope = '/subscriptions/sub-a' }) -Permissions @{ '/subscriptions/sub-a/resourcegroups/rg-typo' = @{ Status = 404 } }
        $R = @(Test-SubscriptionRoleAccessAll -Subscriptions @($script:SubA) -ResourceGroup 'rg-typo')
        $R[0].State | Should -Be 'NoAccess'
        $R[0].Reason | Should -Be "resource group 'rg-typo' not found or not readable"
    }

    It 'prints the usage verdict with -IncludeUsage, also when reading resources fails' {
        Set-RoleScenario -Assignments @(@{ Role = 'Billing Reader'; Scope = '/subscriptions/sub-a' }) -Permissions @{ '/subscriptions/sub-a' = @{ Status = 200; Roles = @('Billing Reader') } }
        $R = @(Test-SubscriptionRoleAccessAll -Subscriptions @($script:SubA) -IncludeUsage)
        $R[0].State | Should -Be 'NoAccess'
        $R[0].UsageVerdict | Should -Be 'Yes'
        $script:Lines[1] | Should -Be '      usage permission (Microsoft.Commerce/UsageAggregates/read): yes - Billing Reader at subscription'
    }

    It 'stops a role that reads all but some resource types, naming the role and the pattern (<Case>)' -TestCases @(
        @{ Case = 'both answers'; Assign = @(@{ Role = 'NoComputeRead'; Scope = '/subscriptions/sub-a' }); Reason = "role 'Reader without Compute' at subscription excludes 'Microsoft.Compute/*/read'; the inventory would miss those resources" }
        @{ Case = 'role assignments not visible'; Assign = @(); Reason = "Azure reports read access that excludes 'Microsoft.Compute/*/read' (role assignments not visible to this identity); the inventory would miss those resources" }
    ) {
        param($Case, $Assign, $Reason)
        Set-RoleScenario -Assignments $Assign -Permissions @{ '/subscriptions/sub-a' = @{ Status = 200; Roles = @('NoComputeRead') } }
        $R = @(Test-SubscriptionRoleAccessAll -Subscriptions @($script:SubA))
        $R[0].State | Should -Be 'NoAccess'
        $R[0].Reason | Should -Be $Reason
        (Resolve-AccessPreflight -Probed $R).ShouldBlock | Should -BeTrue
    }

    It 'passes Reader beside a role that reads all but some resource types' {
        Set-RoleScenario -Assignments @(@{ Role = 'NoComputeRead'; Scope = '/subscriptions/sub-a' }, @{ Role = 'Reader'; Scope = '/providers/Microsoft.Management/managementGroups/mg-1' }) -Permissions @{ '/subscriptions/sub-a' = @{ Status = 200; Roles = @('NoComputeRead', 'Reader') } }
        $R = @(Test-SubscriptionRoleAccessAll -Subscriptions @($script:SubA))
        $R[0].State | Should -Be 'Readable'
        $R[0].Reason | Should -Be 'Read access: Reader at management group'
    }

    It 'reads a refused role definition once for the whole run, with the same verdicts' {
        Set-RoleScenario -Assignments @(@{ Role = 'Reader'; Scope = '/providers/Microsoft.Management/managementGroups/mg-1' }) -DefinitionStatus 403 -Permissions @{
            '/subscriptions/sub-a' = @{ Status = 200; Roles = @('Reader') }
            '/subscriptions/sub-b' = @{ Status = 200; Roles = @('Reader') }
            '/subscriptions/sub-c' = @{ Status = 200; Roles = @('Reader') }
        }
        $Subs = @('sub-a', 'sub-b', 'sub-c') | ForEach-Object { [pscustomobject]@{ Id = $_; Name = $_ } }
        $R = @(Test-SubscriptionRoleAccessAll -Subscriptions $Subs)
        @($R | ForEach-Object { $_.State }) | Should -Be @('Unknown', 'Unknown', 'Unknown')
        @($R | ForEach-Object { $_.Reason }) | Should -Be @(1..3 | ForEach-Object { 'role check inconclusive after retries (a role definition could not be read)' })
        @($script:Calls | Where-Object { $_ -like 'definition *' }).Count | Should -Be 1
    }

    It 'reads a role definition again after a server error on the first subscription' {
        Set-RoleScenario -Assignments @(@{ Role = 'Reader'; Scope = '/providers/Microsoft.Management/managementGroups/mg-1' }) -DefinitionStatus @(503, 503, 503, 503, 200) -Permissions @{
            '/subscriptions/sub-a' = @{ Status = 200; Roles = @('Reader') }
            '/subscriptions/sub-b' = @{ Status = 200; Roles = @('Reader') }
        }
        $Subs = @('sub-a', 'sub-b') | ForEach-Object { [pscustomobject]@{ Id = $_; Name = $_ } }
        $R = @(Test-SubscriptionRoleAccessAll -Subscriptions $Subs)
        @($R | ForEach-Object { $_.State }) | Should -Be @('Unknown', 'Readable')
    }
}

Describe 'Invoke-RoleCheckGet page cap' {
    BeforeEach {
        Mock Start-Sleep { }
        # A list answer of $script:PageCount pages joined by nextLink. The
        # next page is asked for by path, so the page number is read from it.
        Mock Invoke-AzRestMethod {
            $N = if ($Path -match 'page=(\d+)$') { [int]$Matches[1] } else { 1 }
            $Body = @{ value = @(@{ id = $N }) }
            if ($N -lt $script:PageCount) { $Body.nextLink = 'https://management.example.test/list?page={0}' -f ($N + 1) }
            New-Response -Status 200 -Body $Body
        }
    }

    It 'follows more than 50 pages by default' {
        $script:PageCount = 60
        $Answer = Invoke-RoleCheckGet -Path '/subscriptions/sub-a/list'
        $Answer.Error | Should -BeNullOrEmpty
        @($Answer.Items).Count | Should -Be 60
    }

    It 'still stops after 1000 pages by default, as an error' {
        $script:PageCount = 1001
        $Answer = Invoke-RoleCheckGet -Path '/subscriptions/sub-a/list'
        $Answer.Error | Should -Be 'more than 1000 pages'
        $Answer.Status | Should -BeNullOrEmpty
        Should -Invoke Invoke-AzRestMethod -Times 1000 -Exactly
        Should -Invoke Invoke-AzRestMethod -Times 0 -Exactly -ParameterFilter { -not [string]::IsNullOrEmpty($Uri) }
    }

    It 'stops at -MaxPages, each page asked for by its path' {
        $script:PageCount = 10
        $Answer = Invoke-RoleCheckGet -Path '/subscriptions/sub-a/list' -MaxPages 3
        $Answer.Error | Should -Be 'more than 3 pages'
        Should -Invoke Invoke-AzRestMethod -Times 3 -Exactly
        Should -Invoke Invoke-AzRestMethod -Times 1 -Exactly -ParameterFilter { $Path -eq '/list?page=2' }
        Should -Invoke Invoke-AzRestMethod -Times 1 -Exactly -ParameterFilter { $Path -eq '/list?page=3' }
        Should -Invoke Invoke-AzRestMethod -Times 0 -Exactly -ParameterFilter { -not [string]::IsNullOrEmpty($Uri) }
    }
}

Describe 'Invoke-RoleCheckGet next-page link' {
    BeforeEach {
        Mock Start-Sleep { }
        $script:Requests = [System.Collections.Generic.List[object]]::new()
        # Page 1 answers with $script:NextLink; any later page has none.
        Mock Invoke-AzRestMethod {
            $script:Requests.Add([pscustomobject]@{ Path = $Path; Uri = $Uri })
            if ($script:Requests.Count -eq 1) { return (New-Response -Status 200 -Body @{ value = @(@{ id = 1 }); nextLink = $script:NextLink }) }
            New-Response -Status 200 -Body @{ value = @(@{ id = 2 }) }
        }
    }

    It 'asks for the next page by its path and query on the Resource Manager endpoint, not on the host the link names' {
        $script:NextLink = 'https://other.example.test/subscriptions/sub-a/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&$skipToken=page%2B2'
        $Answer = Invoke-RoleCheckGet -Path '/subscriptions/sub-a/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01'
        $Answer.Error | Should -BeNullOrEmpty
        @($Answer.Items | ForEach-Object { $_.id }) | Should -Be @(1, 2)
        $script:Requests.Count | Should -Be 2
        $script:Requests[1].Path | Should -Be '/subscriptions/sub-a/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&$skipToken=page%2B2'
        Should -Invoke Invoke-AzRestMethod -Times 0 -Exactly -ParameterFilter { -not [string]::IsNullOrEmpty($Uri) }
    }

    It 'counts the answer as missing when the next-page link is <Case>' -TestCases @(
        @{ Case = 'not a URL'; Link = 'not a url' }
        @{ Case = 'a relative path'; Link = '/subscriptions/sub-a/list?page=2' }
        @{ Case = 'a URL without a path'; Link = 'https://other.example.test' }
        @{ Case = 'a URL whose path is only /'; Link = 'https://other.example.test/?page=2' }
        @{ Case = 'a URL whose path starts with //'; Link = 'https://management.example.test//other.example.test/list?page=2' }
        @{ Case = 'not an http(s) URL'; Link = 'file:///subscriptions/sub-a/list' }
    ) {
        param($Case, $Link)
        $script:NextLink = $Link
        $Answer = Invoke-RoleCheckGet -Path '/subscriptions/sub-a/list'
        $Answer.Error | Should -Be 'the answer''s next-page link is not a valid URL'
        $Answer.Status | Should -BeNullOrEmpty
        @($Answer.Items).Count | Should -Be 0
        $script:Requests.Count | Should -Be 1
    }

    It 'skips the subscription whose role assignment list has a malformed next-page link, with its reason, and keeps the other' {
        Set-RoleScenario -Assignments @(@{ Role = 'Reader'; Scope = '/subscriptions/sub-b' }) -Permissions @{ '/subscriptions/sub-b' = @{ Status = 200; Roles = @('Reader') } }
        Mock Get-RoleCheckCallerObjectId { 'caller-oid' }
        Mock Invoke-AzRestMethod {
            $Target = if ($Path) { $Path } else { $Uri }
            if ($Target -like '/subscriptions/sub-a/providers/Microsoft.Authorization/roleAssignments*')
            {
                return (New-Response -Status 200 -Body @{ value = @(@{ properties = @{ roleDefinitionId = '/subscriptions/sub-a/providers/Microsoft.Authorization/roleDefinitions/Reader'; scope = '/subscriptions/sub-a'; principalId = 'caller-oid' } }); nextLink = 'not a url' })
            }
            Get-ScenarioResponse -Target $Target
        }
        $script:Lines = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { $script:Lines.Add([string]$Object) }
        $Subs = @([pscustomobject]@{ Id = 'sub-a'; Name = 'Alpha' }, [pscustomobject]@{ Id = 'sub-b'; Name = 'Bravo' })
        $R = @(Test-SubscriptionRoleAccessAll -Subscriptions $Subs)
        @($R | ForEach-Object { $_.State }) | Should -Be @('Unknown', 'Readable')
        $R[0].Reason | Should -Be 'role check inconclusive after retries (role assignment list: the answer''s next-page link is not a valid URL)'
        $Decision = Resolve-AccessPreflight -Probed $R
        $Decision.ShouldBlock | Should -BeFalse
        $Decision.InaccessibleIds | Should -Be @('sub-a')
        Write-AccessPreflightReport -Decision $Decision -ScopeCount 2
        $script:Lines | Should -Contain '    - Alpha (sub-a) - role check inconclusive after retries (role assignment list: the answer''s next-page link is not a valid URL)'
        $script:Lines | Should -Contain '  Skipping them and continuing with the 1 readable subscription(s). To include them: The role check could not finish (the reason above says why); re-run.'
        Should -Invoke Invoke-AzRestMethod -Times 0 -Exactly -ParameterFilter { -not [string]::IsNullOrEmpty($Uri) }
    }
}

Describe 'Get-RoleCheckCallerObjectId' {
    It 'reads the oid claim from the Resource Manager token of the current context' {
        $Payload = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes('{"oid":"caller-oid","tid":"t"}')).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        Mock Get-AzContext { [pscustomobject]@{ Environment = [pscustomobject]@{ ResourceManagerUrl = 'https://management.example.test/' } } }
        Mock Get-AzAccessToken { [pscustomobject]@{ Token = (ConvertTo-SecureString ('e30.' + $Payload + '.sig') -AsPlainText -Force) } }
        Get-RoleCheckCallerObjectId | Should -Be 'caller-oid'
        Should -Invoke Get-AzAccessToken -Times 1 -Exactly -ParameterFilter { $ResourceUrl -eq 'https://management.example.test/' }
    }

    It 'returns $null when no token can be had' {
        Mock Get-AzContext { $null }
        Mock Get-AzAccessToken { throw 'no context' }
        Get-RoleCheckCallerObjectId | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-AccessPreflight' {
    It 'treats every state other than Readable as not readable, and blocks only when none is readable' {
        $Probed = @(
            [pscustomobject]@{ Id = 's1'; State = 'Readable' }
            [pscustomobject]@{ Id = 's2'; State = 'Disagree' }
            [pscustomobject]@{ Id = 's3'; State = 'SomethingNew' }
        )
        $D = Resolve-AccessPreflight -Probed $Probed
        $D.ShouldBlock | Should -BeFalse
        $D.InaccessibleIds | Should -Be @('s2', 's3')
        $D.ReadableCount | Should -Be 1
        (Resolve-AccessPreflight -Probed @($Probed[1], $Probed[2])).ShouldBlock | Should -BeTrue
    }

    It 'does not block when none is readable but subscriptions recorded as completed are in scope (-Resume)' {
        $NoneReadable = @(
            [pscustomobject]@{ Id = 's2'; State = 'NoAccess' }
            [pscustomobject]@{ Id = 's3'; State = 'Unknown' }
        )
        $D = Resolve-AccessPreflight -Probed $NoneReadable -CompletedCount 1
        $D.ShouldBlock | Should -BeFalse
        $D.InaccessibleIds | Should -Be @('s2', 's3')
        $D.ReadableCount | Should -Be 0
        $D.CompletedCount | Should -Be 1
        (Resolve-AccessPreflight -Probed $NoneReadable -CompletedCount 0).ShouldBlock | Should -BeTrue
        (Resolve-AccessPreflight -Probed $NoneReadable).ShouldBlock | Should -BeTrue -Because 'a run that skips no completed subscription still stops'
    }
}

Describe 'Write-AccessPreflightReport' {
    BeforeEach {
        $script:Lines = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { $script:Lines.Add([string]$Object) }
        $script:Blocked = [pscustomobject]@{
            Inaccessible    = @([pscustomobject]@{ Id = 'sub-b'; Name = 'Bravo'; State = 'NoAccess'; Reason = 'no role grants read access (roles visible: Reader at a resource group)' })
            InaccessibleIds = @('sub-b')
            ShouldBlock     = $true
        }
    }

    It 'stops when no subscription is readable, and offers no switch' {
        Write-AccessPreflightReport -Decision $script:Blocked -ScopeCount 1
        @($script:Lines) | Should -Be @(
            '  1 subscription(s) are NOT readable by the signed-in identity:'
            '    - Bravo (sub-b) - no role grants read access (roles visible: Reader at a resource group)'
            '  No subscription is readable. Stopping before any work. Grant the identity Reader on these subscriptions, then re-run.'
        )
    }

    It 'skips the subscriptions that are not readable and says how to include them' {
        $Decision = [pscustomobject]@{ Inaccessible = $script:Blocked.Inaccessible; InaccessibleIds = @('sub-b'); ReadableCount = 2; ShouldBlock = $false }
        Write-AccessPreflightReport -Decision $Decision -ScopeCount 3
        @($script:Lines) | Should -Be @(
            '  1 subscription(s) are NOT readable by the signed-in identity:'
            '    - Bravo (sub-b) - no role grants read access (roles visible: Reader at a resource group)'
            '  Skipping them and continuing with the 2 readable subscription(s). To include them: Grant the identity Reader on these subscriptions, then re-run.'
        )
    }

    It 'words a resource group run' {
        Write-AccessPreflightReport -Decision $script:Blocked -ScopeCount 1 -ResourceGroup 'rg-one'
        $script:Lines[0] | Should -Be "  Resource group 'rg-one' is NOT readable by the signed-in identity in 1 subscription(s):"
        ($script:Lines -join "`n") | Should -Not -Match 'AllowPartialAccess'
    }

    It 'gives the fix for why the check failed: <Verdict>' -TestCases @(
        @{ State = 'NoAccess'; Verdict = 'No'; Rg = ''; Fix = '  Stopping before any work. Grant the identity Reader on these subscriptions, then re-run.' }
        @{ State = 'NoAccess'; Verdict = 'NoNotVisible'; Rg = ''; Fix = '  Stopping before any work. Grant the identity Reader on these subscriptions, then re-run.' }
        @{ State = 'NoAccess'; Verdict = 'NotFound'; Rg = 'rg-one'; Fix = '  Stopping before any work. Check the resource group name, or grant the identity Reader on the resource group or its subscription, then re-run.' }
        @{ State = 'Unknown'; Verdict = 'Unknown'; Rg = ''; Fix = '  Stopping before any work. The role check could not finish (the reason above says why); re-run.' }
        @{ State = 'Disagree'; Verdict = 'Disagree'; Rg = ''; Fix = '  Stopping before any work. The role assignments and Azure disagree, which usually means roles changed in the last few minutes; wait 5 minutes, then re-run.' }
    ) {
        param($State, $Verdict, $Rg, $Fix)
        $Decision = [pscustomobject]@{
            Inaccessible    = @([pscustomobject]@{ Id = 'sub-b'; Name = 'Bravo'; State = $State; Verdict = $Verdict; Reason = 'reason' })
            InaccessibleIds = @('sub-b')
            ShouldBlock     = $true
        }
        Write-AccessPreflightReport -Decision $Decision -ScopeCount 1 -ResourceGroup $Rg
        $script:Lines[2] | Should -Be ('  No subscription is readable. ' + $Fix.TrimStart())
        $script:Lines.Count | Should -Be 3
    }

    It 'gives one fix per cause, naming the subscriptions, when the causes differ' {
        $Decision = [pscustomobject]@{
            Inaccessible    = @(
                [pscustomobject]@{ Id = 'sub-b'; Name = 'Bravo'; State = 'Unknown'; Verdict = 'Unknown'; Reason = 'role check inconclusive after retries (role assignment list: more than 1000 pages)' }
                [pscustomobject]@{ Id = 'sub-c'; Name = 'Charlie'; State = 'NoAccess'; Verdict = 'No'; Reason = 'no role grants read access (roles visible: none)' }
                [pscustomobject]@{ Id = 'sub-d'; Name = 'Delta'; State = 'Unknown'; Verdict = 'Unknown'; Reason = 'role check inconclusive after retries (caller permissions: HTTP 429)' }
            )
            InaccessibleIds = @('sub-b', 'sub-c', 'sub-d')
            ReadableCount   = 1
            ShouldBlock     = $false
        }
        Write-AccessPreflightReport -Decision $Decision -ScopeCount 4
        @($script:Lines | Select-Object -Skip 4) | Should -Be @(
            '  Skipping them and continuing with the 1 readable subscription(s). To include them:'
            '    Charlie: Grant the identity Reader on these subscriptions, then re-run.'
            '    Bravo, Delta: The role check could not finish (the reason above says why); re-run.'
        )
        $script:Lines.Clear()
        $Decision.ShouldBlock = $true
        $Decision.ReadableCount = 0
        Write-AccessPreflightReport -Decision $Decision -ScopeCount 3
        $script:Lines[4] | Should -Be '  No subscription is readable. Stopping before any work.'
    }

    It 'on -Resume with only completed subscriptions besides these, skips them and finishes the run' {
        $Decision = [pscustomobject]@{ Inaccessible = $script:Blocked.Inaccessible; InaccessibleIds = @('sub-b'); ReadableCount = 0; CompletedCount = 2; ShouldBlock = $false }
        Write-AccessPreflightReport -Decision $Decision -ScopeCount 1 -Resume
        @($script:Lines) | Should -Be @(
            '  1 subscription(s) are NOT readable by the signed-in identity:'
            '    - Bravo (sub-b) - no role grants read access (roles visible: Reader at a resource group)'
            '  Skipping them and finishing the run: the other 2 subscription(s) were completed by an earlier run, so nothing is left to collect. To include them: Grant the identity Reader on these subscriptions, then re-run.'
        )
    }

    It 'on a -Resume stop, ends each fix in running -Resume again and says a run without -Resume stops too' {
        Write-AccessPreflightReport -Decision $script:Blocked -ScopeCount 1 -Resume
        @($script:Lines) | Should -Be @(
            '  1 subscription(s) are NOT readable by the signed-in identity:'
            '    - Bravo (sub-b) - no role grants read access (roles visible: Reader at a resource group)'
            '  No subscription is readable. Stopping before any work. Grant the identity Reader on these subscriptions, then run -Resume again.'
            '  A run without -Resume checks the same subscriptions, so it stops here too.'
        )
        $script:Lines.Clear()
        $Decision = [pscustomobject]@{
            Inaccessible    = @(
                [pscustomobject]@{ Id = 'sub-b'; Name = 'Bravo'; State = 'Unknown'; Reason = 'reason' }
                [pscustomobject]@{ Id = 'sub-c'; Name = 'Charlie'; State = 'NoAccess'; Reason = 'reason' }
                [pscustomobject]@{ Id = 'sub-d'; Name = 'Delta'; State = 'Disagree'; Reason = 'reason' }
            )
            InaccessibleIds = @('sub-b', 'sub-c', 'sub-d')
            ReadableCount   = 0
            ShouldBlock     = $true
        }
        Write-AccessPreflightReport -Decision $Decision -ScopeCount 3 -Resume
        @($script:Lines | Select-Object -Skip 4) | Should -Be @(
            '  No subscription is readable. Stopping before any work.'
            '    Charlie: Grant the identity Reader on these subscriptions, then run -Resume again.'
            '    Bravo: The role check could not finish (the reason above says why); run -Resume again.'
            '    Delta: The role assignments and Azure disagree, which usually means roles changed in the last few minutes; wait 5 minutes, then run -Resume again.'
            '  A run without -Resume checks the same subscriptions.'
        )
    }

    It 'on a -Resume stop, says a run without -Resume stops too only for a missing role (<State>)' -TestCases @(
        @{ State = 'NoAccess'; Last = '  A run without -Resume checks the same subscriptions, so it stops here too.' }
        @{ State = 'SomethingNew'; Last = '  A run without -Resume checks the same subscriptions, so it stops here too.' }
        @{ State = 'Unknown'; Last = '  A run without -Resume checks the same subscriptions.' }
        @{ State = 'Disagree'; Last = '  A run without -Resume checks the same subscriptions.' }
    ) {
        param($State, $Last)
        $Decision = [pscustomobject]@{
            Inaccessible    = @([pscustomobject]@{ Id = 'sub-b'; Name = 'Bravo'; State = $State; Reason = 'reason' })
            InaccessibleIds = @('sub-b')
            ReadableCount   = 0
            ShouldBlock     = $true
        }
        Write-AccessPreflightReport -Decision $Decision -ScopeCount 1 -Resume
        $script:Lines.Count | Should -Be 4
        $script:Lines[-1] | Should -Be $Last
        $script:Lines.Clear()
        Write-AccessPreflightReport -Decision $Decision -ScopeCount 1
        $script:Lines.Count | Should -Be 3 -Because 'a run without -Resume prints no such line'
    }
}

Describe 'Write-UsageRoleReport' {
    BeforeEach {
        $script:Lines = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { $script:Lines.Add([string]$Object) }
        $script:Refused = [pscustomobject]@{ ShouldBlock = $true; Failed = @([pscustomobject]@{ Id = 'sub-a'; Name = 'Alpha' }) }
    }

    It 'gives the fix when the roles do not include the usage permission' {
        Write-UsageRoleReport -ConsumptionResult $script:Refused -RoleCheck @([pscustomobject]@{ Id = 'sub-a'; Name = 'Alpha'; UsageVerdict = 'No'; UsageText = 'no' })
        @($script:Lines) | Should -Be @(
            'Usage permission found by the role check:'
            '  - Alpha: the roles on this subscription do not include Microsoft.Commerce/UsageAggregates/read: add Reader or Billing Reader at the subscription'
        )
    }

    It 'says the roles are not the problem when they include it' {
        Write-UsageRoleReport -ConsumptionResult $script:Refused -RoleCheck @([pscustomobject]@{ Id = 'sub-a'; Name = 'Alpha'; UsageVerdict = 'Yes'; UsageText = 'yes' })
        $script:Lines[1] | Should -BeLike '  - Alpha: the roles include Microsoft.Commerce/UsageAggregates/read, so the missing values are not a role problem*'
    }

    It 'prints nothing when the consumption check passed or there are no role records' {
        Write-UsageRoleReport -ConsumptionResult ([pscustomobject]@{ ShouldBlock = $false; Failed = @() }) -RoleCheck @([pscustomobject]@{ Id = 'sub-a'; UsageVerdict = 'No' })
        Write-UsageRoleReport -ConsumptionResult $script:Refused -RoleCheck @()
        $script:Lines.Count | Should -Be 0
    }
}

Describe 'Role check records feed the consumption data check' {
    BeforeAll {
        function Set-AzContext { param($Subscription, $Context, $Scope) }
        function Get-UsageAggregates { param($ReportedStartTime, $ReportedEndTime, $AggregationGranularity, $ShowDetails, $ContinuationToken) }
        $script:UsageWindow = Get-ConsumptionWindow -Now ([datetime]'2026-10-26T10:00:00')
    }

    BeforeEach {
        Mock Write-Host { }
        Mock Start-Sleep { }
        Mock Get-RoleCheckCallerObjectId { 'caller-oid' }
        Mock Get-AzContext { $null }
        Mock Set-AzContext { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = $Subscription } } }
        # The subscription holds resources and returns no usage rows.
        Mock Invoke-AzRestMethod {
            $Target = if ($Path) { $Path } else { $Uri }
            if ($Target -like '/providers/Microsoft.ResourceGraph/*') { return (New-Response -Status 200 -Body @{ data = @(@{ subscriptionId = 'sub-a'; ResourceCount = 1 }) }) }
            Get-ScenarioResponse -Target $Target
        }
        Mock Get-UsageAggregatesPage { [pscustomobject]@{ UsageAggregations = @(); ContinuationToken = $null } }
    }

    It '<Case>: outcome <Expected>' -TestCases @(
        @{ Case = 'Reader at the subscription in both answers'; Assignments = @(@{ Role = 'Reader'; Scope = '/subscriptions/sub-a' }); Granted = @('Reader'); Expected = 'NoUsage' }
        @{ Case = 'Reader through a group at a management group'; Assignments = @(@{ Role = 'Reader'; Scope = '/providers/Microsoft.Management/managementGroups/mg-1'; Group = $true }); Granted = @('Reader'); Expected = 'NoUsage' }
        @{ Case = 'roles include it, Azure does not'; Assignments = @(@{ Role = 'Reader'; Scope = '/subscriptions/sub-a' }); Granted = @('NoCommerce'); Expected = 'NoRows' }
        @{ Case = 'Azure includes it, the roles do not'; Assignments = @(@{ Role = 'NoCommerce'; Scope = '/subscriptions/sub-a' }); Granted = @('Reader'); Expected = 'NoRows' }
        @{ Case = 'role assignments not visible'; Assignments = @(); Granted = @('Reader'); Expected = 'NoRows' }
        @{ Case = 'usage only granted at a resource group'; Assignments = @(@{ Role = 'NoCommerce'; Scope = '/subscriptions/sub-a' }, @{ Role = 'Billing Reader'; Scope = '/subscriptions/sub-a/resourceGroups/rg-one' }); Granted = @('Reader'); Expected = 'NoRows' }
    ) {
        param($Case, $Assignments, $Granted, $Expected)
        Set-RoleScenario -Assignments $Assignments -Permissions @{ '/subscriptions/sub-a' = @{ Status = 200; Roles = $Granted } }
        $Records = @(Test-SubscriptionRoleAccessAll -Subscriptions @($script:SubA) -IncludeUsage)
        $Result = Invoke-ConsumptionDataCheck -Subscriptions @($script:SubA) -Window $script:UsageWindow -RoleCheck $Records
        $Result.Results[0].Outcome | Should -Be $Expected
        $Result.ShouldBlock | Should -Be ($Expected -ne 'NoUsage')
        if ($Expected -eq 'NoUsage') { $Result.Results[0].Detail | Should -Match 'Reader at (subscription|management group through a group)' }
    }
}

Describe 'Run-AllSubscriptions.ps1 up-front role check' {
    BeforeAll {
        # Runs the wrapper's own statements from '$ScopeForProbe =' to the end
        # of the following if-block with Azure mocked, and records what they
        # print, so the expected lines below pin the wrapper's wording.
        $script:WrapperPath = Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1'
        $Tokens = $null
        $Errors = $null
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:WrapperPath, [ref]$Tokens, [ref]$Errors)
        $script:Top = @($Ast.EndBlock.Statements)
        $Index = -1
        for ($I = 0; $I -lt $script:Top.Count; $I++)
        {
            if ($script:Top[$I].Extent.Text -match '^\$ScopeForProbe\s*=') { $Index = $I; break }
        }
        if ($Index -lt 0) { throw 'The role check was not found in Run-AllSubscriptions.ps1.' }
        $script:GateIndex = $Index
        $script:GateBlock = [scriptblock]::Create(($script:Top[$Index].Extent.Text + "`n" + $script:Top[$Index + 1].Extent.Text))
        # The check keeps some skipped subscriptions on the retry list in the
        # resume state (Add-RoleCheckRetryAttempts, Update-ResumeStateRetryList).
        . (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')
    }

    BeforeEach {
        $script:Lines = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { $script:Lines.Add([string]$Object) }
        Mock Start-Sleep { }
        Mock Exit-Wrapper { throw ('EXIT {0}' -f $Code) }
        Mock Get-RoleCheckCallerObjectId { 'caller-oid' }
        Mock Invoke-AzRestMethod { Get-ScenarioResponse -Target $(if ($Path) { $Path } else { $Uri }) }
        # sub-a readable, sub-b Reader on a resource group only, sub-c throttled.
        Set-RoleScenario -Assignments @(
            @{ Role = 'Reader'; Scope = '/subscriptions/sub-a' }
            @{ Role = 'Reader'; Scope = '/subscriptions/sub-b/resourceGroups/rg-one' }
            @{ Role = 'Reader'; Scope = '/subscriptions/sub-c' }
        ) -Permissions @{
            '/subscriptions/sub-a' = @{ Status = 200; Roles = @('Reader') }
            '/subscriptions/sub-c' = @{ Status = 429 }
        }
        $script:Subscriptions = @(
            [pscustomobject]@{ Id = 'sub-a'; Name = 'Alpha' }
            [pscustomobject]@{ Id = 'sub-b'; Name = 'Bravo' }
            [pscustomobject]@{ Id = 'sub-c'; Name = 'Charlie' }
        )
        $script:CompletedIds = @()
        $script:Resume = $false
        $script:AllowPartialAccess = $false
        $script:SkipConsumption = $true
        $script:FailedAttempts = @()
        $script:TenantID = 'tenant-test'
        $script:ResumeStateFile = Join-Path $TestDrive ('state-{0}.json' -f [guid]::NewGuid().ToString('N').Substring(0, 8))
    }

    AfterAll {
        Remove-Variable -Name Subscriptions, CompletedIds, Resume, AllowPartialAccess, SkipConsumption, FailedAttempts, TenantID, ResumeStateFile -Scope Script -ErrorAction SilentlyContinue
    }

    It 'keeps a subscription whose check could not finish on the retry list as a failed run, but not one without a read role' {
        . $script:GateBlock
        @($FailedAttempts | ForEach-Object { '{0}|{1}|{2}' -f $_.Id, $_.Attempts, $_.Reason }) | Should -Be @(
            'sub-c|1|skipped by the up-front role check: role check inconclusive after retries (caller permissions: HTTP 429)'
        )
        $Saved = Get-Content -LiteralPath $script:ResumeStateFile -Raw | ConvertFrom-Json
        @($Saved.FailedAttempts | ForEach-Object { $_.Id }) | Should -Be @('sub-c')
        @($Saved.CompletedSubscriptionIds) | Should -BeNullOrEmpty
    }

    It 'keeps a subscription whose two answers disagree on the retry list' {
        Set-RoleScenario -Assignments @(
            @{ Role = 'Reader'; Scope = '/subscriptions/sub-a' }
            @{ Role = 'Reader'; Scope = '/subscriptions/sub-c' }
        ) -Permissions @{
            '/subscriptions/sub-a' = @{ Status = 200; Roles = @('Reader') }
            '/subscriptions/sub-c' = @{ Status = 200; Roles = @() }
        }
        $script:Subscriptions = @([pscustomobject]@{ Id = 'sub-a'; Name = 'Alpha' }, [pscustomobject]@{ Id = 'sub-c'; Name = 'Charlie' })
        . $script:GateBlock
        @($AccessDecision.Inaccessible | ForEach-Object { $_.State }) | Should -Be @('Disagree')
        @($FailedAttempts | ForEach-Object { '{0}|{1}' -f $_.Id, $_.Attempts }) | Should -Be @('sub-c|1')
        @($FailedAttempts)[0].Reason | Should -BeLike 'skipped by the up-front role check: role assignments show read access*'
    }

    It 'records the failed run before it stops, so each stopped run counts, and takes the subscription off the completed list' {
        $script:Subscriptions = @([pscustomobject]@{ Id = 'sub-b'; Name = 'Bravo' }, [pscustomobject]@{ Id = 'sub-c'; Name = 'Charlie' })
        $script:FailedAttempts = @([pscustomobject]@{ Id = 'sub-c'; Name = 'Charlie'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'an earlier failure'; Attempts = 2 })
        $script:CompletedIds = @('sub-c', 'sub-z')
        { . $script:GateBlock } | Should -Throw 'EXIT 1'
        $Saved = Get-Content -LiteralPath $script:ResumeStateFile -Raw | ConvertFrom-Json
        @($Saved.FailedAttempts | ForEach-Object { '{0}|{1}' -f $_.Id, $_.Attempts }) | Should -Be @('sub-c|3')
        @($Saved.CompletedSubscriptionIds) | Should -Be @('sub-z')
    }

    It 'adds nothing and writes no state when no subscription was skipped for a cause that can pass later' {
        $script:Subscriptions = @([pscustomobject]@{ Id = 'sub-a'; Name = 'Alpha' }, [pscustomobject]@{ Id = 'sub-b'; Name = 'Bravo' })
        . $script:GateBlock
        @($FailedAttempts) | Should -BeNullOrEmpty
        Test-Path -LiteralPath $script:ResumeStateFile | Should -BeFalse
    }

    It 'runs before the consumption data check and keeps the records for the end-of-run labels' {
        $ConsumptionIndex = -1
        for ($I = 0; $I -lt $script:Top.Count; $I++)
        {
            if ($script:Top[$I].Extent.Text -match '^\$ConsumptionCheckScope\s*=') { $ConsumptionIndex = $I; break }
        }
        $ConsumptionIndex | Should -BeGreaterThan $script:GateIndex
        $script:Top[$ConsumptionIndex + 1].Extent.Text | Should -Match 'Write-UsageRoleReport -ConsumptionResult \$ConsumptionCheck -RoleCheck \$AccessProbed'
        $Text = Get-Content -Path $script:WrapperPath -Raw
        $Text | Should -Not -Match 'Get-SubscriptionAccessState|Test-SubscriptionAccessAll'
        Get-Command Get-SubscriptionAccessState -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'skips the subscriptions that are not readable, with the fix for each cause, and continues' {
        . $script:GateBlock
        Should -Invoke Exit-Wrapper -Times 0 -Exactly
        $Summary = @($script:Lines | Where-Object { $_ -notlike '  `[*' })
        $Summary | Should -Be @(
            'Verifying subscription access up front for 3 subscription(s)...'
            '  2 subscription(s) are NOT readable by the signed-in identity:'
            '    - Bravo (sub-b) - no role grants read access (roles visible: Reader at a resource group)'
            '    - Charlie (sub-c) - role check inconclusive after retries (caller permissions: HTTP 429)'
            '  Skipping them and continuing with the 1 readable subscription(s). To include them:'
            '    Bravo: Grant the identity Reader on these subscriptions, then re-run.'
            '    Charlie: The role check could not finish (the reason above says why); re-run.'
        )
        $script:Lines[1] | Should -BeLike '  `[Pass`] Alpha - Read access: Reader at subscription (*s)'
        @($Subscriptions | ForEach-Object { $_.Id }) | Should -Be @('sub-a')
        @($AccessDecision.InaccessibleIds) | Should -Be @('sub-b', 'sub-c')
    }

    It 'skips a role that reads all but some resource types, with or without -AllowPartialAccess' {
        Set-RoleScenario -Assignments @(
            @{ Role = 'Reader'; Scope = '/subscriptions/sub-a' }
            @{ Role = 'NoComputeRead'; Scope = '/subscriptions/sub-b' }
        ) -Permissions @{
            '/subscriptions/sub-a' = @{ Status = 200; Roles = @('Reader') }
            '/subscriptions/sub-b' = @{ Status = 200; Roles = @('NoComputeRead') }
        }
        $script:Subscriptions = @([pscustomobject]@{ Id = 'sub-a'; Name = 'Alpha' }, [pscustomobject]@{ Id = 'sub-b'; Name = 'Bravo' })
        . $script:GateBlock
        $script:Lines | Should -Contain "    - Bravo (sub-b) - role 'Reader without Compute' at subscription excludes 'Microsoft.Compute/*/read'; the inventory would miss those resources"
        @($Subscriptions | ForEach-Object { $_.Id }) | Should -Be @('sub-a')

        $script:Lines.Clear()
        $script:AllowPartialAccess = $true
        $script:Subscriptions = @([pscustomobject]@{ Id = 'sub-a'; Name = 'Alpha' }, [pscustomobject]@{ Id = 'sub-b'; Name = 'Bravo' })
        . $script:GateBlock
        @($Subscriptions | ForEach-Object { $_.Id }) | Should -Be @('sub-a')
    }

    It 'skips the failing subscriptions the same way under -AllowPartialAccess' {
        $script:AllowPartialAccess = $true
        . $script:GateBlock
        Should -Invoke Exit-Wrapper -Times 0 -Exactly
        $script:Lines[-1] | Should -Be '    Charlie: The role check could not finish (the reason above says why); re-run.'
        @($Subscriptions | ForEach-Object { $_.Id }) | Should -Be @('sub-a')
        @($AccessProbed).Count | Should -Be 3
    }

    It 'stops with exit 1 when no subscription is readable (<Case>)' -TestCases @(@{ Case = 'default'; Allow = $false }, @{ Case = '-AllowPartialAccess'; Allow = $true }) {
        param($Case, $Allow)
        $script:AllowPartialAccess = $Allow
        $script:Subscriptions = @([pscustomobject]@{ Id = 'sub-b'; Name = 'Bravo' }, [pscustomobject]@{ Id = 'sub-c'; Name = 'Charlie' })
        { . $script:GateBlock } | Should -Throw 'EXIT 1'
        $script:Lines | Should -Contain '  No subscription is readable. Stopping before any work.'
    }

    It 'confirms when every subscription is readable, with the usage verdict when consumption is requested' {
        $script:SkipConsumption = $false
        $script:Subscriptions = @([pscustomobject]@{ Id = 'sub-a'; Name = 'Alpha' })
        { . $script:GateBlock } | Should -Not -Throw
        $script:Lines[0] | Should -Be 'Verifying subscription access up front for 1 subscription(s)...'
        $script:Lines[2] | Should -Be '      usage permission (Microsoft.Commerce/UsageAggregates/read): yes - Reader at subscription'
        $script:Lines[3] | Should -Be '  Access verified: all 1 in-scope subscription(s) are readable.'
    }

    It 'on -Resume checks only the subscriptions this run will process' {
        $script:Resume = $true
        $script:CompletedIds = @('sub-b', 'sub-c')
        { . $script:GateBlock } | Should -Not -Throw
        @($script:Calls | Where-Object { $_ -like 'roles *' }) | Should -Be @('roles sub-a')
    }

    It 'on -Resume does not stop when every subscription left to check is unreadable and the others were completed' {
        $script:Resume = $true
        $script:CompletedIds = @('sub-a')
        . $script:GateBlock
        Should -Invoke Exit-Wrapper -Times 0 -Exactly
        @($Subscriptions | ForEach-Object { $_.Id }) | Should -Be @('sub-a')
        @($AccessDecision.InaccessibleIds) | Should -Be @('sub-b', 'sub-c')
        @($script:Lines | Where-Object { $_ -notlike '  `[*' }) | Should -Be @(
            'Verifying subscription access up front for 2 subscription(s)...'
            '  2 subscription(s) are NOT readable by the signed-in identity:'
            '    - Bravo (sub-b) - no role grants read access (roles visible: Reader at a resource group)'
            '    - Charlie (sub-c) - role check inconclusive after retries (caller permissions: HTTP 429)'
            '  Skipping them and finishing the run: the other 1 subscription(s) were completed by an earlier run, so nothing is left to collect. To include them:'
            '    Bravo: Grant the identity Reader on these subscriptions, then re-run.'
            '    Charlie: The role check could not finish (the reason above says why); re-run.'
        )
    }

    It 'stops with exit 1 when none is readable without -Resume, even with completed subscriptions recorded' {
        $script:CompletedIds = @('sub-b')
        $script:Subscriptions = @([pscustomobject]@{ Id = 'sub-b'; Name = 'Bravo' }, [pscustomobject]@{ Id = 'sub-c'; Name = 'Charlie' })
        { . $script:GateBlock } | Should -Throw 'EXIT 1'
        $script:Lines | Should -Contain '    Bravo: Grant the identity Reader on these subscriptions, then re-run.'
        ($script:Lines -join "`n") | Should -Not -Match '-Resume'
    }

    It 'on -Resume stops with exit 1 when none is readable and no subscription in scope is recorded as completed' {
        $script:Resume = $true
        # A completed subscription that is no longer in scope does not count.
        $script:CompletedIds = @('sub-gone')
        $script:Subscriptions = @([pscustomobject]@{ Id = 'sub-b'; Name = 'Bravo' }, [pscustomobject]@{ Id = 'sub-c'; Name = 'Charlie' })
        { . $script:GateBlock } | Should -Throw 'EXIT 1'
        $script:Lines | Should -Contain '    Bravo: Grant the identity Reader on these subscriptions, then run -Resume again.'
        $script:Lines[-1] | Should -Be '  A run without -Resume checks the same subscriptions.' -Because 'Charlie''s check could not finish, so a later run can pass'
    }
}

Describe 'Run-AllSubscriptions.ps1 end-of-run 0-resource labels' {
    BeforeAll {
        $WrapperPath = Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1'
        $Tokens = $null
        $Errors = $null
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($WrapperPath, [ref]$Tokens, [ref]$Errors)
        $Block = @($Ast.EndBlock.Statements | Where-Object { $_.Extent.Text -match '^if \(\$EmptySubs\.Count -gt 0\)' })
        if ($Block.Count -ne 1) { throw 'The 0-resource block was not found in Run-AllSubscriptions.ps1.' }
        $script:EmptyBlock = [scriptblock]::Create($Block[0].Extent.Text)
    }

    BeforeEach {
        $script:Lines = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { $script:Lines.Add([string]$Object) }
        Mock Invoke-AzRestMethod { throw 'no Azure call expected' }
        $script:DiagFile = Join-Path $TestDrive ('diag-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.log')
        $script:InventoryRoot = $TestDrive
        $script:EmptySubs = @([pscustomobject]@{ Id = 'sub-a'; Name = 'Alpha'; Count = 0 }, [pscustomobject]@{ Id = 'sub-z'; Name = 'Zulu'; Count = 0 })
        $script:AccessProbed = @([pscustomobject]@{ Id = 'sub-a'; Name = 'Alpha'; State = 'Readable' })
    }

    It 'labels a subscription that passed the role check genuinely empty, one it did not cover undetermined, without probing Azure' {
        . $script:EmptyBlock
        Should -Invoke Invoke-AzRestMethod -Times 0 -Exactly
        @($GenuinelyEmptySubs | ForEach-Object { $_.Id }) | Should -Be @('sub-a')
        @($UnknownSubs | ForEach-Object { $_.Id }) | Should -Be @('sub-z')
        $script:Lines | Should -Contain '  GENUINELY EMPTY (1) - the up-front role check found read access; the subscription has no resources:'
        $script:Lines | Should -Contain "  UNDETERMINED (1) - not covered by this run's up-front role check:"
        ($script:Lines -join "`n") | Should -Not -Match 'access confirmed|NO ACCESS'
        $Diag = Get-Content -Path $script:DiagFile -Raw
        $Diag | Should -Match 'EMPTY Alpha \(sub-a\) - read access found by the up-front role check, no resources; no action needed'
        $Diag | Should -Match "UNDETERMINED   Zulu \(sub-z\) - not covered by this run's up-front role check"
        $Diag | Should -Not -Match 'access confirmed'
    }
}

Describe 'ResourceInventory.ps1 direct run' {
    BeforeAll {
        # Runs the real script in a child pwsh with Azure replaced by stubs. Every
        # role check request, resource count query and usage query appends a line
        # to a call log, so the order of the up-front checks is observable. The
        # stubbed 'az graph' call is the first inventory step after setup; it
        # writes a marker and exits 3, so reaching inventory is observable and
        # nothing past it runs.
        $script:Harness = Join-Path $TestDrive 'harness.ps1'
        @'
param([string]$Root, [string]$Out, [string]$Roles = 'reader', [string]$PermSub = 'read', [string]$PermRg = 'read', [string]$Usage = 'values', [string]$ResourceGroup, [switch]$SkipConsumption, [switch]$RunAllSubs, [switch]$NoSubscriptionId, [string]$WindowStart, [string]$WindowEnd, [int]$SubCount = 1, [string]$Unreadable = '', [switch]$GraphData)
$Global:RdaSessionInitialized = $true
$Global:AzPowerShellLoaded = $true
$Global:PlatformOS = 'PowerShell Unix'
# The stand-ins below are functions of this runspace, so the up-front checks
# run one subscription at a time here (parallel runspaces would not see them).
$Global:PSDefaultParameterValues = @{ 'Test-SubscriptionRoleAccessAll:ThrottleLimit' = 1; 'Invoke-ConsumptionDataCheck:ThrottleLimit' = 1 }
$TestSub = '12345678-1234-1234-1234-123456789012'
# Subscription N (from 1): ...1234567890<11+N>, so subscription 1 is $TestSub.
$Global:TestSubs = @(1..$SubCount | ForEach-Object { [pscustomobject]@{ id = ('12345678-1234-1234-1234-1234567890{0:d2}' -f (11 + $_)); name = $(if ($SubCount -eq 1) { 'Placeholder subscription' } else { 'Placeholder subscription {0}' -f $_ }); tenantId = $TestSub } })
$Global:UnreadableIds = @(($Unreadable -split ',') | Where-Object { $_ } | ForEach-Object { $Global:TestSubs[[int]$_ - 1].id })
function global:az
{
    $Joined = $args -join ' '
    if ($Joined -like 'account show*') { return ('{{"user":{{"name":"tester"}},"tenantId":"{0}"}}' -f $TestSub) }
    if ($Joined -like 'account list*') { return (ConvertTo-Json -InputObject @($Global:TestSubs) -Compress) }
    if ($Joined -like 'graph*' -and -not $env:RDA_TEST_GRAPH_DATA) { Set-Content -Path $env:RDA_TEST_INVENTORY_MARKER -Value 'inventory started'; exit 3 }
    if ($Joined -like 'graph*')
    {
        # One resource in each visible subscription; no AVD resources.
        Set-Content -Path $env:RDA_TEST_INVENTORY_MARKER -Value 'inventory started'
        $global:LASTEXITCODE = 0
        if ($Joined -match 'desktopvirtualizationresources') { return '{"data":[{"count_":0}],"count":1}' }
        if ($Joined -match 'summarize count\(\)') { return ('{{"data":[{{"count_":{0}}}],"count":1}}' -f $Global:TestSubs.Count) }
        $Rows = @($Global:TestSubs | ForEach-Object { @{ id = ('/subscriptions/{0}/resourcegroups/rg-1/providers/microsoft.network/networksecuritygroups/nsg-1' -f $_.id); name = 'nsg-1'; type = 'microsoft.network/networksecuritygroups'; subscriptionId = $_.id; resourceGroup = 'rg-1' } })
        return (@{ data = $Rows; count = $Rows.Count } | ConvertTo-Json -Depth 5 -Compress)
    }
    return $null
}
# Reached right after the setup phase (inventory collected): records what was
# collected, then stops the run.
function global:Start-Transcript
{
    param($Path, [switch]$UseMinimalHeader)
    @{ ResourceSubscriptions = @($Global:Resources | ForEach-Object { [string]$_.subscriptionId } | Sort-Object -Unique); Subscriptions = @($Global:Subscriptions | ForEach-Object { [string]$_.id }) } |
        ConvertTo-Json -Compress | Set-Content -Path $env:RDA_TEST_COLLECTED
    exit 4
}
function global:Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $TestSub }; Subscription = [pscustomobject]@{ Id = $TestSub } } }
function global:Set-AzContext { param($Subscription, $Context, $Scope) [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = $(if ($Subscription) { $Subscription } else { $TestSub }) } } }
function global:Get-AzAccessToken { param($ResourceUrl) [pscustomobject]@{ Token = ('e30.' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"oid":"test-oid"}')).TrimEnd('=') + '.sig') } }
function global:Invoke-AzRestMethod
{
    param($Method, $Path, $Payload, $Uri)
    $Target = if ($Path) { $Path } else { $Uri }
    $Json = { param($Obj) [pscustomobject]@{ StatusCode = 200; Content = ($Obj | ConvertTo-Json -Depth 10) } }
    $CallSub = if ($Target -match '^/subscriptions/([^/?]+)') { $Matches[1] } else { $TestSub }
    $Unreadable = $Global:UnreadableIds -contains $CallSub
    if ($Target -match '/roleAssignments\?')
    {
        Add-Content -Path $env:RDA_TEST_CALL_LOG -Value 'roles'
        $Scope = switch ($(if ($Unreadable) { 'none' } else { $env:RDA_TEST_ROLES })) { 'reader' { "/subscriptions/$CallSub" } 'nocompute' { "/subscriptions/$CallSub" } 'rg' { "/subscriptions/$CallSub/resourceGroups/rg-one" } default { $null } }
        $Definition = if ($env:RDA_TEST_ROLES -eq 'nocompute') { 'nocompute' } else { 'reader' }
        $Items = if ($Scope) { @(@{ properties = @{ roleDefinitionId = "/subscriptions/$TestSub/providers/Microsoft.Authorization/roleDefinitions/$Definition"; scope = $Scope; principalId = 'test-oid'; principalType = 'ServicePrincipal' } }) } else { @() }
        return (& $Json @{ value = $Items })
    }
    if ($Target -match '/roleDefinitions/nocompute')
    {
        return (& $Json @{ properties = @{ roleName = 'Reader without Compute'; type = 'CustomRole'; permissions = @(@{ actions = @('*/read'); notActions = @('Microsoft.Compute/*/read') }) } })
    }
    if ($Target -match '/roleDefinitions/')
    {
        return (& $Json @{ properties = @{ roleName = 'Reader'; type = 'BuiltInRole'; permissions = @(@{ actions = @('*/read'); notActions = @() }) } })
    }
    if ($Target -match '/providers/Microsoft\.Authorization/permissions\?')
    {
        $OnRg = $Target -match '/resourceGroups/'
        Add-Content -Path $env:RDA_TEST_CALL_LOG -Value ('permissions ' + $(if ($OnRg) { 'rg' } else { 'sub' }))
        $Mode = if ($Unreadable) { 'none' } elseif ($OnRg) { $env:RDA_TEST_PERM_RG } else { $env:RDA_TEST_PERM_SUB }
        if ($Mode -eq '404') { return [pscustomobject]@{ StatusCode = 404; Content = '{}' } }
        $Entries = switch ($Mode) { 'read' { @(@{ actions = @('*/read'); notActions = @() }) } 'nocompute' { @(@{ actions = @('*/read'); notActions = @('Microsoft.Compute/*/read') }) } default { @() } }
        return (& $Json @{ value = $Entries })
    }
    if ($Target -match '/providers/Microsoft\.Commerce/UsageAggregates\?')
    {
        Add-Content -Path $env:RDA_TEST_CALL_LOG -Value 'usage'
        Add-Content -Path ($env:RDA_TEST_CALL_LOG + '.usage-subs') -Value $CallSub
        $Query = [System.Web.HttpUtility]::ParseQueryString(([uri]('https://management.example.test' + $Target)).Query)
        Add-Content -Path $env:RDA_TEST_USAGE_WINDOW -Value ('{0} {1}' -f $Query['reportedStartTime'].Substring(0, 10), $Query['reportedEndTime'].Substring(0, 10))
        # 'in-rg' and 'other-rg' rows carry a resource in resource group RG-ONE or rg-two.
        $Uri = switch ($env:RDA_TEST_USAGE) { 'in-rg' { "/subscriptions/$TestSub/resourceGroups/RG-ONE/providers/Microsoft.Network/networkSecurityGroups/nsg-1" } 'other-rg' { "/subscriptions/$TestSub/resourceGroups/rg-two/providers/Microsoft.Network/networkSecurityGroups/nsg-2" } default { $null } }
        $Rows = if ($env:RDA_TEST_USAGE -eq 'values') { @(@{ properties = @{ quantity = 2 } }) }
        elseif ($Uri) { @(@{ properties = @{ quantity = 2; instanceData = (@{ 'Microsoft.Resources' = @{ resourceUri = $Uri } } | ConvertTo-Json -Compress) } }) }
        else { @() }
        return (& $Json @{ value = $Rows })
    }
    Add-Content -Path $env:RDA_TEST_CALL_LOG -Value 'resource counts'
    & $Json @{ data = @(@(($Payload | ConvertFrom-Json).subscriptions) | ForEach-Object { @{ subscriptionId = $_; ResourceCount = 4 } }) }
}
$env:RDA_TEST_ROLES = $Roles
$env:RDA_TEST_PERM_SUB = $PermSub
$env:RDA_TEST_PERM_RG = $PermRg
$env:RDA_TEST_USAGE = $Usage
$Extra = @{}
if (-not $NoSubscriptionId) { $Extra.SubscriptionID = $TestSub }
if ($ResourceGroup) { $Extra.ResourceGroup = $ResourceGroup }
if ($SkipConsumption) { $Extra.SkipConsumption = $true }
if ($RunAllSubs) { $Extra.RunAllSubs = $true }
if ($WindowStart) { $Extra.ConsumptionWindowStart = $WindowStart }
if ($WindowEnd) { $Extra.ConsumptionWindowEnd = $WindowEnd }
if ($GraphData) { $env:RDA_TEST_GRAPH_DATA = '1' }
& (Join-Path $Root 'ResourceInventory.ps1') -OutputDirectory $Out @Extra
exit $LASTEXITCODE
'@ | Set-Content -Path $script:Harness -Encoding utf8

        function Invoke-DirectRun
        {
            param([string]$Roles = 'reader', [string]$PermSub = 'read', [string]$PermRg = 'read', [string]$Usage = 'values', [string]$ResourceGroup, [switch]$SkipConsumption, [switch]$RunAllSubs, [switch]$NoSubscriptionId, [string]$WindowStart, [string]$WindowEnd, [int]$SubCount = 1, [string]$Unreadable = '', [switch]$GraphData)
            $Out = Join-Path $TestDrive ('out-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Path $Out -Force | Out-Null
            $env:RDA_TEST_INVENTORY_MARKER = Join-Path $Out 'inventory.marker'
            $env:RDA_TEST_CALL_LOG = Join-Path $Out 'calls.log'
            $env:RDA_TEST_USAGE_WINDOW = Join-Path $Out 'usage-window.log'
            $env:RDA_TEST_COLLECTED = Join-Path $Out 'collected.json'
            $PwshArgs = @('-NoProfile', '-NonInteractive', '-File', $script:Harness, '-Root', $script:RepoRoot, '-Out', $Out, '-Roles', $Roles, '-PermSub', $PermSub, '-PermRg', $PermRg, '-Usage', $Usage)
            if ($ResourceGroup) { $PwshArgs += @('-ResourceGroup', $ResourceGroup) }
            if ($SkipConsumption) { $PwshArgs += '-SkipConsumption' }
            if ($RunAllSubs) { $PwshArgs += '-RunAllSubs' }
            if ($NoSubscriptionId) { $PwshArgs += '-NoSubscriptionId' }
            if ($WindowStart) { $PwshArgs += @('-WindowStart', $WindowStart) }
            if ($WindowEnd) { $PwshArgs += @('-WindowEnd', $WindowEnd) }
            $PwshArgs += @('-SubCount', $SubCount, '-Unreadable', $Unreadable)
            if ($GraphData) { $PwshArgs += '-GraphData' }
            Push-Location $script:RepoRoot
            try { $Output = & (Join-Path $PSHOME 'pwsh') @PwshArgs 2>&1 | Out-String }
            finally { Pop-Location }
            $Calls = if (Test-Path -Path $env:RDA_TEST_CALL_LOG) { @(Get-Content -Path $env:RDA_TEST_CALL_LOG) } else { @() }
            [pscustomobject]@{
                ExitCode         = $LASTEXITCODE
                Output           = $Output
                InventoryReached = (Test-Path -Path $env:RDA_TEST_INVENTORY_MARKER)
                Calls            = $Calls
                RoleCalls        = @($Calls | Where-Object { $_ -eq 'roles' -or $_ -like 'permissions *' })
                UsageWindows     = $(if (Test-Path -Path $env:RDA_TEST_USAGE_WINDOW) { @(Get-Content -Path $env:RDA_TEST_USAGE_WINDOW) } else { @() })
                UsageSubs        = $(if (Test-Path -Path ($env:RDA_TEST_CALL_LOG + '.usage-subs')) { @(Get-Content -Path ($env:RDA_TEST_CALL_LOG + '.usage-subs')) } else { @() })
                Collected        = $(if (Test-Path -Path $env:RDA_TEST_COLLECTED) { Get-Content -Path $env:RDA_TEST_COLLECTED -Raw | ConvertFrom-Json } else { $null })
            }
        }
    }

    AfterAll {
        Remove-Item Env:\RDA_TEST_INVENTORY_MARKER, Env:\RDA_TEST_CALL_LOG, Env:\RDA_TEST_USAGE_WINDOW, Env:\RDA_TEST_COLLECTED -ErrorAction SilentlyContinue
    }

    It 'checks the roles before the consumption check, then continues into inventory' {
        $Run = Invoke-DirectRun
        $Run.Calls[0] | Should -Be 'roles'
        $Run.Calls[1] | Should -Be 'permissions sub'
        $Run.Calls | Should -Contain 'usage'
        $Run.InventoryReached | Should -BeTrue
        $Run.ExitCode | Should -Be 3
        $Run.Output | Should -Match '\[Pass\] Placeholder subscription - Read access: Reader at subscription'
        $Run.Output | Should -Match 'usage permission \(Microsoft\.Commerce/UsageAggregates/read\): yes - Reader at subscription'
    }

    It 'exits 1 before the consumption check and before inventory for an identity that can read nothing' {
        $Run = Invoke-DirectRun -Roles 'none' -PermSub 'none'
        $Run.ExitCode | Should -Be 1
        $Run.Calls | Should -Not -Contain 'usage'
        $Run.Calls | Should -Not -Contain 'resource counts'
        $Run.InventoryReached | Should -BeFalse
        $Run.Output | Should -Match 'Placeholder subscription \(12345678-1234-1234-1234-123456789012\) - no read access \(role assignments not visible to this identity\)'
        $Run.Output | Should -Not -Match 'AllowPartialAccess'
    }

    It 'checks the roles under -SkipConsumption too, without a usage verdict' {
        $Run = Invoke-DirectRun -Roles 'none' -PermSub 'none' -SkipConsumption
        $Run.ExitCode | Should -Be 1
        $Run.RoleCalls.Count | Should -Be 2
        $Run.Output | Should -Not -Match 'usage permission'
        $Run.InventoryReached | Should -BeFalse
    }

    It 'does not run the role or usage check under -RunAllSubs (the wrapper already did)' {
        $Run = Invoke-DirectRun -Roles 'none' -PermSub 'none' -RunAllSubs
        $Run.RoleCalls.Count | Should -Be 0
        $Run.Calls | Should -Not -Contain 'usage'
        $Run.Calls | Should -Not -Contain 'resource counts'
        $Run.InventoryReached | Should -BeTrue
    }

    It 'stops a whole-subscription run for Reader on one resource group only' {
        $Run = Invoke-DirectRun -Roles 'rg' -PermSub 'none' -SkipConsumption
        $Run.ExitCode | Should -Be 1
        $Run.Output | Should -Match 'no role grants read access \(roles visible: Reader at a resource group\)'
    }

    It 'passes a -ResourceGroup run for Reader on that resource group' {
        $Run = Invoke-DirectRun -Roles 'rg' -PermSub 'none' -PermRg 'read' -ResourceGroup 'rg-one' -SkipConsumption
        $Run.RoleCalls | Should -Be @('roles', 'permissions rg')
        $Run.InventoryReached | Should -BeTrue
        $Run.Output | Should -Match "Access verified: resource group 'rg-one' is readable"
    }

    It 'stops a -ResourceGroup run when the resource group does not exist' {
        $Run = Invoke-DirectRun -Roles 'reader' -PermRg '404' -ResourceGroup 'rg-one' -SkipConsumption
        $Run.ExitCode | Should -Be 1
        $Run.InventoryReached | Should -BeFalse
        $Run.Output | Should -Match "resource group 'rg-one' not found or not readable"
    }

    It 'with -ResourceGroup but no -SubscriptionID skips the check (ResourceInventoryLoop refuses that combination)' {
        $Run = Invoke-DirectRun -Roles 'none' -PermSub 'none' -ResourceGroup 'rg-one' -SkipConsumption -NoSubscriptionId
        $Run.RoleCalls.Count | Should -Be 0
        $Run.InventoryReached | Should -BeFalse
        $Run.Output | Should -Match 'If using ResourceGroup parameter you must also put SubscriptionId'
    }

    It 'on a consumption refusal prints the usage fix for a resource group grant' {
        $Run = Invoke-DirectRun -Roles 'rg' -PermSub 'none' -PermRg 'read' -ResourceGroup 'rg-one' -Usage 'empty'
        $Run.ExitCode | Should -Be 1
        $Run.InventoryReached | Should -BeFalse
        $Run.Output | Should -Match 'usage permission \(Microsoft\.Commerce/UsageAggregates/read\): no - the roles on this subscription do not include it'
        $Run.Output | Should -Match 'Placeholder subscription: the roles on this subscription do not include Microsoft\.Commerce/UsageAggregates/read: add Reader or Billing Reader at the subscription'
    }

    It 'exits 1 before the consumption check for a role that reads all but some resource types' {
        $Run = Invoke-DirectRun -Roles 'nocompute' -PermSub 'nocompute'
        $Run.ExitCode | Should -Be 1
        $Run.InventoryReached | Should -BeFalse
        $Run.Calls | Should -Not -Contain 'usage'
        $Run.Output | Should -Match ([regex]::Escape("Placeholder subscription (12345678-1234-1234-1234-123456789012) - role 'Reader without Compute' at subscription excludes 'Microsoft.Compute/*/read'; the inventory would miss those resources"))
        $Run.Output | Should -Match 'Grant the identity Reader on these subscriptions, then re-run\.'
    }

    It 'checks a -ResourceGroup run against usage rows of that resource group only (rows elsewhere -> stop)' {
        $Run = Invoke-DirectRun -Roles 'rg' -PermSub 'none' -PermRg 'read' -ResourceGroup 'rg-one' -Usage 'other-rg'
        $Run.ExitCode | Should -Be 1
        $Run.InventoryReached | Should -BeFalse
        $Run.Output | Should -Match "Placeholder subscription \(12345678-1234-1234-1234-123456789012\): NoRows - the query succeeded but returned no usage rows for resource group 'rg-one'"
    }

    It 'passes a -ResourceGroup run on a usage row of that resource group, matched without case' {
        $Run = Invoke-DirectRun -Roles 'rg' -PermSub 'none' -PermRg 'read' -ResourceGroup 'rg-one' -Usage 'in-rg'
        $Run.InventoryReached | Should -BeTrue
        $Run.ExitCode | Should -Be 3
        $Run.Output | Should -Match "\[Pass\] Placeholder subscription - usage values found for resource group 'rg-one'"
        $Run.Output | Should -Match "Consumption data confirmed: 1 subscription\(s\) returned usage values for resource group 'rg-one'"
    }

    It 'passes a -ResourceGroup run with no usage in it, with a warning, when the usage permission is confirmed' {
        $Run = Invoke-DirectRun -Roles 'reader' -PermSub 'read' -PermRg 'read' -ResourceGroup 'rg-one' -Usage 'other-rg'
        $Run.InventoryReached | Should -BeTrue
        $Run.Output | Should -Match "\[NoUsage\] Placeholder subscription - the query succeeded but returned no usage rows for resource group 'rg-one'; the usage permission is confirmed"
        $Run.Output | Should -Match "WARNING: no usage above zero in resource group 'rg-one' for "
        $Run.Output | Should -Match "the consumption sheet for resource group 'rg-one' will be empty"
    }

    It 'checks the consumption window passed in (one window per wrapper run)' {
        $Run = Invoke-DirectRun -WindowStart '2026-01-01' -WindowEnd '2026-01-31'
        $Run.InventoryReached | Should -BeTrue
        $Run.UsageWindows | Should -Be @('2026-01-01 2026-01-31')
        $Run.Output | Should -Match 'usage values for 2026-01-01 to 2026-01-31'
    }

    It 'ignores a consumption window that is not valid (<Start> / <End>), with a warning, and uses its own' -TestCases @(
        @{ Start = '2026-02-30'; End = '2026-03-02' }
        @{ Start = '2026-03-02'; End = '2026-02-01' }
        @{ Start = '2026-01-01'; End = '' }
    ) {
        param($Start, $End)
        $Run = Invoke-DirectRun -WindowStart $Start -WindowEnd $End
        $Run.InventoryReached | Should -BeTrue
        $Own = Format-ConsumptionWindow -Window (Get-ConsumptionWindow)
        $Run.UsageWindows | Should -Be @($Own -replace ' to ', ' ')
        $Run.Output | Should -Match 'Ignoring -ConsumptionWindowStart'
    }

    It 'skips an unreadable subscription in a run over every visible subscription, checks usage for the others, and continues' {
        # The harness's subscription N.
        $SubId = { param($N) '12345678-1234-1234-1234-1234567890{0:d2}' -f (11 + $N) }
        $Run = Invoke-DirectRun -NoSubscriptionId -SubCount 3 -Unreadable '2'
        $Run.InventoryReached | Should -BeTrue
        $Run.ExitCode | Should -Be 3
        $Run.Output | Should -Match ([regex]::Escape('1 subscription(s) are NOT readable by the signed-in identity:'))
        $Run.Output | Should -Match ([regex]::Escape(('- Placeholder subscription 2 ({0}) - no read access (role assignments not visible to this identity)' -f (& $SubId 2))))
        $Run.Output | Should -Match ([regex]::Escape('Skipping them and continuing with the 2 readable subscription(s). To include them: Grant the identity Reader on these subscriptions, then re-run.'))
        $Run.UsageSubs | Should -Be @((& $SubId 1), (& $SubId 3))
        $Run.Output | Should -Match ([regex]::Escape('Verifying consumption data (usage values for'))
        $Run.Output | Should -Match ([regex]::Escape(') for 2 subscription(s)...'))
    }

    It 'leaves a skipped subscription out of the subscriptions and the collected resources' {
        $SubId = { param($N) '12345678-1234-1234-1234-1234567890{0:d2}' -f (11 + $N) }
        $Run = Invoke-DirectRun -NoSubscriptionId -SubCount 3 -Unreadable '2' -GraphData -SkipConsumption
        $Run.ExitCode | Should -Be 4
        @($Run.Collected.Subscriptions) | Should -Be @((& $SubId 1), (& $SubId 3))
        @($Run.Collected.ResourceSubscriptions) | Should -Be @((& $SubId 1), (& $SubId 3))
    }

    It 'collects every subscription when all are readable' {
        $Run = Invoke-DirectRun -NoSubscriptionId -SubCount 3 -GraphData -SkipConsumption
        $Run.ExitCode | Should -Be 4
        @($Run.Collected.ResourceSubscriptions).Count | Should -Be 3
        $Run.Output | Should -Match ([regex]::Escape('Access verified: all 3 in-scope subscription(s) are readable.'))
    }

    It 'stops with exit 1 before inventory when no visible subscription is readable' {
        $Run = Invoke-DirectRun -NoSubscriptionId -SubCount 2 -Unreadable '1,2'
        $Run.ExitCode | Should -Be 1
        $Run.InventoryReached | Should -BeFalse
        $Run.Calls | Should -Not -Contain 'usage'
        $Run.Output | Should -Match ([regex]::Escape('No subscription is readable. Stopping before any work. Grant the identity Reader on these subscriptions, then re-run.'))
    }

    It 'stops with exit 1 for an unreadable -SubscriptionID even when other subscriptions are readable' {
        $Run = Invoke-DirectRun -SubCount 3 -Unreadable '1'
        $Run.ExitCode | Should -Be 1
        $Run.InventoryReached | Should -BeFalse
        $Run.RoleCalls | Should -Be @('roles', 'permissions sub')
        $Run.Output | Should -Match ([regex]::Escape('No subscription is readable. Stopping before any work.'))
    }
}

Describe 'Write-SkippedSubscriptionSummary (end-of-run list)' {
    BeforeEach {
        $script:Lines = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { $script:Lines.Add([string]$Object) }
    }

    It 'lists every skipped subscription with its reason' {
        $Decision = Resolve-AccessPreflight -Probed @(
            [pscustomobject]@{ Id = 'sub-a'; Name = 'Alpha'; State = 'Readable' }
            [pscustomobject]@{ Id = 'sub-b'; Name = 'Bravo'; State = 'NoAccess'; Reason = 'no role grants read access (roles visible: none)' }
            [pscustomobject]@{ Id = 'sub-c'; Name = 'Charlie'; State = 'Unknown'; Reason = 'role check inconclusive after retries (caller permissions: HTTP 429)' }
        )
        Write-SkippedSubscriptionSummary -Decision $Decision
        @($script:Lines) | Should -Be @(
            ''
            'Subscriptions skipped (not readable by the signed-in identity): 2 - they are not in this report:'
            '  - Bravo (sub-b) - no role grants read access (roles visible: none)'
            '  - Charlie (sub-c) - role check inconclusive after retries (caller permissions: HTTP 429)'
            '  To include them, fix the access as the start of the run says, then re-run.'
        )
    }

    It 'prints nothing when none was skipped or there was no check' {
        Write-SkippedSubscriptionSummary -Decision (Resolve-AccessPreflight -Probed @([pscustomobject]@{ Id = 'sub-a'; State = 'Readable' }))
        Write-SkippedSubscriptionSummary -Decision $null
        $script:Lines.Count | Should -Be 0
    }

    It 'is called at the end of both scripts with the role check decision, after the counts in the wrapper' {
        $Wrapper = Get-Content -Path (Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1') -Raw
        $Wrapper | Should -Match ([regex]::Escape('Write-Host ("Subscriptions Processed: {0}" -f ($Subscriptions.Count - $SkippedCount)) -ForegroundColor Green') + '\s*\r?\n(#[^\n]*\n)*Write-SkippedSubscriptionSummary -Decision \$AccessDecision')
        $Direct = (Get-Content -Path (Join-Path $script:RepoRoot 'ResourceInventory.ps1') -Raw).TrimEnd()
        # After the report and zip logging the direct script prints the no-usage and
        # skipped-subscription lists. The only code allowed after them is the direct-run
        # exit 4 check: its comment lines, the failure count and one exit line.
        $ExitFourCheck = '(\r?\n)+(#[^\r\n]*\r?\n)*\$CollectorFailureCount = [^\r\n]*\r?\nif \([^\r\n]*\) \{ exit 4 \}'
        $Direct | Should -Match ([regex]::Escape('Write-Log -Message ("Reporting Data File: {0}" -f $Global:ZipOutputFile) -Severity ''Success''') + '\s*\r?\n(#[^\n]*\n)*' + [regex]::Escape('Write-NoUsageSummary -ConsumptionResult $script:ConsumptionCheckResult') + '\r?\n' + [regex]::Escape('Write-SkippedSubscriptionSummary -Decision $script:AccessSkipped') + '(' + $ExitFourCheck + ')?$')
    }
}

Describe 'Write-PendingRetrySkippedSummary (skipped subscriptions on the retry list)' {
    BeforeEach {
        $script:Lines = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { $script:Lines.Add([string]$Object) }
        $script:Decision = Resolve-AccessPreflight -Probed @(
            [pscustomobject]@{ Id = 'sub-a'; Name = 'Alpha'; State = 'Readable' }
            [pscustomobject]@{ Id = 'sub-b'; Name = 'Bravo'; State = 'NoAccess'; Reason = 'no role grants read access (roles visible: none)' }
            [pscustomobject]@{ Id = 'sub-c'; Name = 'Charlie'; State = 'NoAccess'; Reason = 'no role grants read access (roles visible: none)' }
        )
    }

    It 'names the retry-list subscriptions the role check skipped, with the fix for a missing role' {
        $Retry = @([pscustomobject]@{ Id = 'sub-b'; Name = 'Bravo' }, [pscustomobject]@{ Id = 'sub-d'; Name = 'Delta' })
        Write-PendingRetrySkippedSummary -FailedAttempts $Retry -Decision $script:Decision
        @($script:Lines) | Should -Be @(
            '  1 of them were skipped by this run''s role check:'
            '    - Bravo (sub-b) - no role grants read access (roles visible: none)'
            '  To retry them: Grant the identity Reader on these subscriptions, then run -ResumeFailedOnly.'
        )
    }

    It 'gives the fix for why the check failed: <State>' -TestCases @(
        @{ State = 'NoAccess'; Fix = '  To retry them: Grant the identity Reader on these subscriptions, then run -ResumeFailedOnly.' }
        @{ State = 'Unknown'; Fix = '  To retry them: The role check could not finish (the reason above says why); run -ResumeFailedOnly.' }
        @{ State = 'Disagree'; Fix = '  To retry them: The role assignments and Azure disagree, which usually means roles changed in the last few minutes; wait 5 minutes, then run -ResumeFailedOnly.' }
    ) {
        param($State, $Fix)
        $Decision = Resolve-AccessPreflight -Probed @([pscustomobject]@{ Id = 'sub-b'; Name = 'Bravo'; State = $State; Reason = 'reason' })
        Write-PendingRetrySkippedSummary -FailedAttempts @([pscustomobject]@{ Id = 'sub-b'; Name = 'Bravo' }) -Decision $Decision
        @($script:Lines) | Should -Be @(
            '  1 of them were skipped by this run''s role check:'
            '    - Bravo (sub-b) - reason'
            $Fix
        )
        ($script:Lines -join "`n") | Should -Not -Match 'cannot be read'
    }

    It 'gives one fix per cause, naming the subscriptions, when the causes differ' {
        $Decision = Resolve-AccessPreflight -Probed @(
            [pscustomobject]@{ Id = 'sub-b'; Name = 'Bravo'; State = 'Unknown'; Reason = 'role check inconclusive after retries (caller permissions: HTTP 429)' }
            [pscustomobject]@{ Id = 'sub-c'; Name = 'Charlie'; State = 'NoAccess'; Reason = 'no role grants read access (roles visible: none)' }
            [pscustomobject]@{ Id = 'sub-d'; Name = 'Delta'; State = 'Disagree'; Reason = 'the two answers disagree' }
        )
        $Retry = @('sub-b', 'sub-c', 'sub-d') | ForEach-Object { [pscustomobject]@{ Id = $_ } }
        Write-PendingRetrySkippedSummary -FailedAttempts $Retry -Decision $Decision
        @($script:Lines) | Should -Be @(
            '  3 of them were skipped by this run''s role check:'
            '    - Bravo (sub-b) - role check inconclusive after retries (caller permissions: HTTP 429)'
            '    - Charlie (sub-c) - no role grants read access (roles visible: none)'
            '    - Delta (sub-d) - the two answers disagree'
            '  To retry them:'
            '    Charlie: Grant the identity Reader on these subscriptions, then run -ResumeFailedOnly.'
            '    Bravo: The role check could not finish (the reason above says why); run -ResumeFailedOnly.'
            '    Delta: The role assignments and Azure disagree, which usually means roles changed in the last few minutes; wait 5 minutes, then run -ResumeFailedOnly.'
        )
    }

    It 'prints nothing when no retry-list subscription was skipped, or there was no check' {
        Write-PendingRetrySkippedSummary -FailedAttempts @([pscustomobject]@{ Id = 'sub-a'; Name = 'Alpha' }) -Decision $script:Decision
        Write-PendingRetrySkippedSummary -FailedAttempts @([pscustomobject]@{ Id = 'sub-b'; Name = 'Bravo' }) -Decision $null
        Write-PendingRetrySkippedSummary -FailedAttempts @() -Decision $script:Decision
        $script:Lines.Count | Should -Be 0
    }

    It 'is called in the wrapper between the Pending Retries line and its advice' {
        $Wrapper = Get-Content -Path (Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1') -Raw
        $Wrapper | Should -Match ('"Pending Retries: [^\r\n]*\r?\n(\s*#[^\n]*\n)*\s*' + [regex]::Escape('Write-PendingRetrySkippedSummary -FailedAttempts $FailedAttempts -Decision $AccessDecision') + '\r?\n\s*' + [regex]::Escape('Write-Host "Re-run with -ResumeFailedOnly to retry them."'))
    }
}

Describe 'Resume-state helpers: the retry list and an unreadable per-stream file' {
    BeforeAll {
        . (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')
    }

    BeforeEach {
        $script:Lines = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { $script:Lines.Add([string]$Object) }
        $script:Dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
    }

    It 'Add-RoleCheckRetryAttempts adds the skips that can pass later, counts each run and takes them off the completed list' {
        $Decision = Resolve-AccessPreflight -Probed @(
            [pscustomobject]@{ Id = 'sub-a'; Name = 'Alpha'; State = 'Readable' }
            [pscustomobject]@{ Id = 'sub-b'; Name = 'Bravo'; State = 'NoAccess'; Reason = 'no role grants read access (roles visible: none)' }
            [pscustomobject]@{ Id = 'sub-c'; Name = 'Charlie'; State = 'Unknown'; Reason = 'role check inconclusive after retries (caller permissions: HTTP 429)' }
            [pscustomobject]@{ Id = 'sub-d'; Name = 'Delta'; State = 'Disagree'; Reason = 'the two answers disagree' }
        )
        $Existing = @([pscustomobject]@{ Id = 'sub-d'; Name = 'Delta'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'an earlier failure'; Attempts = 2 })
        $R = Add-RoleCheckRetryAttempts -FailedAttempts $Existing -CompletedIds @('sub-a', 'sub-c') -Decision $Decision
        @($R.Added | ForEach-Object { $_.Id }) | Should -Be @('sub-c', 'sub-d')
        @($R.FailedAttempts | Sort-Object Id | ForEach-Object { '{0}|{1}|{2}' -f $_.Id, $_.Attempts, $_.Reason }) | Should -Be @(
            'sub-c|1|skipped by the up-front role check: role check inconclusive after retries (caller permissions: HTTP 429)'
            'sub-d|3|skipped by the up-front role check: the two answers disagree'
        )
        @($R.CompletedIds) | Should -Be @('sub-a')
        $None = Add-RoleCheckRetryAttempts -FailedAttempts @() -CompletedIds 'sub-a' -Decision $null
        @($None.Added) | Should -BeNullOrEmpty
        @($None.CompletedIds) | Should -Be @('sub-a')
    }

    It 'Update-ResumeStateRetryList changes the retry list and completed ids and keeps every other key' {
        $Path = Join-Path $script:Dir 'state.json'
        [pscustomobject]@{ TenantID = 't'; CompletedSubscriptionIds = @('sub-a', 'sub-c'); CompletedReports = @(@{ Id = 'sub-a'; Zip = 'r/a.zip' }); FailedAttempts = @(); OtherRecord = @('kept') } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path
        $Retry = @([pscustomobject]@{ Id = 'sub-c'; Name = 'Charlie'; Reason = 'r'; Attempts = 1 })
        Update-ResumeStateRetryList -Path $Path -Tenant 't' -Ids @('sub-a') -FailedAttempts $Retry
        $Saved = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        @($Saved.CompletedSubscriptionIds) | Should -Be @('sub-a')
        @($Saved.FailedAttempts | ForEach-Object { $_.Id }) | Should -Be @('sub-c')
        @($Saved.CompletedReports | ForEach-Object { $_.Zip }) | Should -Be @('r/a.zip')
        @($Saved.OtherRecord) | Should -Be @('kept')
        Test-Path -LiteralPath "$Path.tmp" | Should -BeFalse

        $New = Join-Path $script:Dir 'new.json'
        Update-ResumeStateRetryList -Path $New -Tenant 't' -Ids @() -FailedAttempts $Retry
        @((Get-Content -LiteralPath $New -Raw | ConvertFrom-Json).FailedAttempts | ForEach-Object { $_.Id }) | Should -Be @('sub-c')
        Update-ResumeStateRetryList -Path '' -Tenant 't' -Ids @() -FailedAttempts $Retry
    }

    It 'Move-UnreadableStreamStateFile renames the file to a name no recovery or *.json pattern finds, with a warning that names it' {
        $File = Join-Path $script:Dir '.resume-state-t-stream-1.json'
        Set-Content -LiteralPath $File -Value '{ "Completed": [ "sub-b" ]'
        $R = Move-UnreadableStreamStateFile -File (Get-Item -LiteralPath $File -Force) -Now ([datetime]'2026-10-29T14:02:55')
        $R.Name | Should -Be '.resume-state-t-stream-1.json'
        $R.MovedTo | Should -Be '.resume-state-t-stream-1.json.unreadable-20261029-140255'
        Test-Path -LiteralPath $File | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Dir $R.MovedTo) | Should -BeTrue
        @($script:Lines) | Should -Be @(
            'WARNING: The per-stream state file .resume-state-t-stream-1.json from an interrupted parallel run could not be read, so its records are not used: the subscriptions it lists are not counted as completed and this run collects them again. It was moved aside to .resume-state-t-stream-1.json.unreadable-20261029-140255.'
        )
        ($script:Lines -join "`n") | Should -Not -Match 'sub-b'
        @(Get-StreamResumeStateFiles -InventoryRoot $script:Dir -Tenant 't') | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $script:Dir -Force -File -Filter '*.json') | Should -BeNullOrEmpty
    }

    It 'Move-UnreadableStreamStateFile takes the next free name when an earlier one holds the name, and leaves that file as it was' {
        $File = Join-Path $script:Dir '.resume-state-t-stream-0.json'
        Set-Content -LiteralPath $File -Value 'cut'
        $Now = [datetime]'2026-10-29T14:02:55'
        Set-Content -LiteralPath (Join-Path $script:Dir '.resume-state-t-stream-0.json.unreadable-20261029-140255') -Value 'an earlier one'
        $R = Move-UnreadableStreamStateFile -File (Get-Item -LiteralPath $File -Force) -Now $Now
        $R.MovedTo | Should -Be '.resume-state-t-stream-0.json.unreadable-20261029-140255-2'
        $R.NotMoved | Should -BeFalse
        Test-Path -LiteralPath $File | Should -BeFalse
        Get-Content -LiteralPath (Join-Path $script:Dir '.resume-state-t-stream-0.json.unreadable-20261029-140255') -Raw | Should -Match 'an earlier one'
        $script:Lines[0] | Should -BeLike '*It was moved aside to .resume-state-t-stream-0.json.unreadable-20261029-140255-2.'
    }

    It 'Move-UnreadableStreamStateFile marks a file it cannot move as not moved and prints nothing at startup; the run then stops with exit 1 and the command that removes it' {
        $File = Join-Path $script:Dir '.resume-state-t-stream-0.json'
        Set-Content -LiteralPath $File -Value 'cut'
        Mock Rename-Item { throw 'denied' }
        $R = Move-UnreadableStreamStateFile -File (Get-Item -LiteralPath $File -Force)
        $R.NotMoved | Should -BeTrue
        $R.MovedTo | Should -BeNullOrEmpty
        $R.Path | Should -Be (Get-Item -LiteralPath $File -Force).FullName
        Test-Path -LiteralPath $File | Should -BeTrue
        $script:Lines.Count | Should -Be 0
        Mock Exit-Wrapper { throw ('EXIT {0}' -f $Code) }
        { Stop-WrongShapeStateNotMoved -Files @($R) } | Should -Throw 'EXIT 1'
        $script:Lines[0] | Should -Be 'ERROR: The per-stream state file .resume-state-t-stream-0.json could not be read, and it could not be moved aside: denied'
        @($script:Lines | Where-Object { $_ -like "  Remove-Item -LiteralPath '*.resume-state-t-stream-0.json' -Force" }).Count | Should -Be 1
        # The startup fold of the wrapper stops this way, after reading every file and before saving any record.
        $Src = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'Run-AllSubscriptions.ps1') -Raw
        $Src | Should -Match ([regex]::Escape('if ($UnreadableNotMoved.Count -gt 0) { Stop-WrongShapeStateNotMoved -Files $UnreadableNotMoved -ResumeFailedOnly:$ResumeFailedOnly }'))
    }

    It 'Move-UnreadableStreamStateFile -AtRunEnd says a later -Resume collects the subscriptions, and names a file it cannot move' {
        $File = Join-Path $script:Dir '.resume-state-t-stream-3.json'
        Set-Content -LiteralPath $File -Value 'cut'
        $null = Move-UnreadableStreamStateFile -File (Get-Item -LiteralPath $File -Force) -Now ([datetime]'2026-10-29T14:02:55') -AtRunEnd
        $script:Lines[0] | Should -Be 'WARNING: The per-stream state file .resume-state-t-stream-3.json could not be read, so its records are not used: the subscriptions it lists are not counted as completed, and a later -Resume collects them again. It was moved aside to .resume-state-t-stream-3.json.unreadable-20261029-140255.'
        $script:Lines.Clear()
        Set-Content -LiteralPath $File -Value 'cut'
        Mock Rename-Item { throw 'denied' }
        $R = Move-UnreadableStreamStateFile -File (Get-Item -LiteralPath $File -Force) -AtRunEnd
        $R.NotMoved | Should -BeTrue
        $script:Lines[0] | Should -Be 'ERROR: The per-stream state file .resume-state-t-stream-3.json could not be read, and it could not be moved aside: denied'
    }

    It 'Read-StreamResumeStateFile returns nothing for a file that is empty, cut short, not an object, or cannot be read' {
        $File = Join-Path $script:Dir '.resume-state-t-stream-5.json'
        foreach ($Text in '', '{ "Completed": [', '0', '"text"')
        {
            Set-Content -LiteralPath $File -Value $Text -NoNewline
            Read-StreamResumeStateFile -Path $File | Should -BeNullOrEmpty
        }
        Set-Content -LiteralPath $File -Value '{ "Completed": [ "sub-a" ] }'
        @((Read-StreamResumeStateFile -Path $File).Completed) | Should -Be @('sub-a')
        # A read error that does not stop by default (a file the user cannot read) is not read as an empty file.
        Mock Get-Content { Write-Error 'Access to the path is denied.' }
        Read-StreamResumeStateFile -Path $File | Should -BeNullOrEmpty
        Read-StreamResumeStateFile -Path (Join-Path $script:Dir 'missing.json') | Should -BeNullOrEmpty
    }

    It 'Write-UnreadableStreamStateSummary says whether the state was cleared or kept, and where the file went' {
        $Files = @(
            [pscustomobject]@{ Name = '.resume-state-t-stream-1.json'; MovedTo = '.resume-state-t-stream-1.json.unreadable-20261029-140255' }
            [pscustomobject]@{ Name = '.resume-state-t-stream-2.json'; MovedTo = $null }
        )
        Write-UnreadableStreamStateSummary -Unreadable $Files -StateKept $false
        Write-UnreadableStreamStateSummary -Unreadable $Files[0] -StateKept $true
        Write-UnreadableStreamStateSummary -Unreadable @() -StateKept $false
        @($script:Lines) | Should -Be @(
            'Resume state cleared, but not a clean run: the per-stream state file .resume-state-t-stream-1.json could not be read and was moved aside to .resume-state-t-stream-1.json.unreadable-20261029-140255; its records were not used.'
            'Resume state cleared, but not a clean run: the per-stream state file .resume-state-t-stream-2.json could not be read and was left in place (it could not be moved aside); its records were not used.'
            'Resume state kept, but not a clean run: the per-stream state file .resume-state-t-stream-1.json could not be read and was moved aside to .resume-state-t-stream-1.json.unreadable-20261029-140255; its records were not used.'
        )
    }

    It 'Move-UnreadableStreamStateFile under -ResumeFailedOnly says a later -Resume collects the subscriptions' {
        $File = Join-Path $script:Dir '.resume-state-t-stream-1.json'
        Set-Content -LiteralPath $File -Value '{ "Completed": [ "sub-b" ]'
        $null = Move-UnreadableStreamStateFile -File (Get-Item -LiteralPath $File -Force) -Now ([datetime]'2026-10-29T14:02:55') -ResumeFailedOnly
        @($script:Lines) | Should -Be @(
            'WARNING: The per-stream state file .resume-state-t-stream-1.json from an interrupted parallel run could not be read, so its records are not used: the subscriptions it lists are not counted as completed and a later -Resume collects them (-ResumeFailedOnly retries only the retry list). It was moved aside to .resume-state-t-stream-1.json.unreadable-20261029-140255.'
        )
    }

    It 'Remove-ResumeStateFiles removes the per-stream files and the resume state file, and prints nothing' {
        $Stream = @('0', '1') | ForEach-Object { Join-Path $script:Dir ('.resume-state-t-stream-{0}.json' -f $_) }
        $State = Join-Path $script:Dir '.resume-state-t.json'
        foreach ($Path in @($Stream) + $State) { Set-Content -LiteralPath $Path -Value '{}' }
        @(Remove-ResumeStateFiles -StreamFiles $Stream -StateFile $State) | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $script:Dir -Force) | Should -BeNullOrEmpty
        $script:Lines.Count | Should -Be 0
        # Already gone: nothing to report.
        @(Remove-ResumeStateFiles -StreamFiles $Stream -StateFile $State) | Should -BeNullOrEmpty
        $script:Lines.Count | Should -Be 0
    }

    It 'Remove-ResumeStateFiles keeps the resume state file while a per-stream file cannot be removed' {
        $Stream = @('0', '1') | ForEach-Object { Join-Path $script:Dir ('.resume-state-t-stream-{0}.json' -f $_) }
        $State = Join-Path $script:Dir '.resume-state-t.json'
        foreach ($Path in @($Stream) + $State) { Set-Content -LiteralPath $Path -Value '{}' }
        Mock Remove-Item { throw 'denied' } -ParameterFilter { $LiteralPath -like '*-stream-0.json' }
        $Left = @(Remove-ResumeStateFiles -StreamFiles $Stream -StateFile $State)
        $Left | Should -Be @($Stream[0], $State)
        Test-Path -LiteralPath $Stream[1] | Should -BeFalse
        Test-Path -LiteralPath $State | Should -BeTrue
        @($script:Lines) | Should -Be @(
            'WARNING: Could not remove the per-stream state file .resume-state-t-stream-0.json: denied'
            '  The resume state file .resume-state-t.json is kept, so the next -Resume reads the same state and the per-stream state file(s) above again. Once the folder can be written, remove the file(s) named above.'
        )
    }

    It 'Remove-ResumeStateFiles names a resume state file that cannot be removed, or that is still there after the removal' {
        $State = Join-Path $script:Dir '.resume-state-t.json'
        Set-Content -LiteralPath $State -Value '{}'
        Mock Remove-Item { throw 'denied' }
        @(Remove-ResumeStateFiles -StateFile $State) | Should -Be @($State)
        Mock Remove-Item { }
        @(Remove-ResumeStateFiles -StateFile $State) | Should -Be @($State)
        @($script:Lines) | Should -Be @(
            'WARNING: Could not remove the resume state file .resume-state-t.json: denied'
            '  The next run reads it again and retries the removal.'
            'WARNING: Could not remove the resume state file .resume-state-t.json: it is still there after the removal'
            '  The next run reads it again and retries the removal.'
        )
    }
}

# End to end with Run-AllSubscriptions.ps1 itself: each run is the real wrapper,
# started as its own pwsh process (stdin closed) from a copy of the tool whose
# ResourceInventory.ps1 is a stand-in that writes one report folder and zip per
# subscription, as the real one does. Azure is a set of stand-in Az modules and
# an az command, found first on the module path and PATH of that process, which
# answer from a scenario file: the subscriptions, the ones that cannot be read,
# the ones that fail and the one whose collection the session ends in. The
# process's home is a scratch folder, so the run writes its inventory root
# under it. On Windows the wrapper writes to C:\InventoryReports instead, so
# these tests do not run there.
Describe 'Run-AllSubscriptions.ps1 -Resume when every subscription left to check is not readable' -Skip:$IsWindows {
    BeforeAll {
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
        $script:WrapperBase = Join-Path $TmpBase ('ReaderAccessResumeTest_' + [guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $script:WrapperBase -Force | Out-Null
        $script:WrapperTenant = '12345678-1234-1234-1234-123456789012'

        $ToolRoot = Join-Path $script:WrapperBase 'tool'
        New-Item -ItemType Directory -Path $ToolRoot -Force | Out-Null
        foreach ($Item in @('Run-AllSubscriptions.ps1', 'Run-AllSubscriptions.Stream.ps1', 'Version.json', 'Functions', 'Extension'))
        {
            Copy-Item -LiteralPath (Join-Path $script:RepoRoot $Item) -Destination $ToolRoot -Recurse -Force
        }
        $script:WrapperScript = Join-Path $ToolRoot 'Run-AllSubscriptions.ps1'
        @'
param([string]$TenantID, [string]$SubscriptionID, [switch]$RunAllSubs, [switch]$Obfuscate, [switch]$SkipMetrics, [switch]$SkipConsumption, [switch]$DeviceLogin, [int]$ConcurrencyLimit, [string]$ConsumptionWindowStart, [string]$ConsumptionWindowEnd)
$Scenario = Get-Content -LiteralPath $env:RDA_STANDIN_AZURE -Raw | ConvertFrom-Json
# The session ends while this subscription is collected.
if (@($Scenario.EndSessionIds) -contains $SubscriptionID) { [Environment]::Exit(137) }
if (@($Scenario.FailIds) -contains $SubscriptionID) { throw 'stand-in failure for this subscription' }
# The session ends while this subscription is collected in a parallel stream:
# the stand-in marks that it started and waits until the test ends the run.
if (@($Scenario.HangIds) -contains $SubscriptionID) { Set-Content -LiteralPath (Join-Path $HOME ('waiting-' + $SubscriptionID)) -Value $PID; Start-Sleep -Seconds 600 }
$Root = Join-Path $HOME 'InventoryReports'
$Stamp = (Get-Date -Format 'yyyyMMddHHmmssfff') + $SubscriptionID
$Folder = Join-Path $Root ('ResourcesReport' + $Stamp)
$Stage = Join-Path $Root ('stage-' + $Stamp)
New-Item -ItemType Directory -Path $Folder, $Stage -Force | Out-Null
Set-Content -LiteralPath (Join-Path $Stage ('Inventory_ResourcesReport_{0}.json' -f $Stamp)) -Value ('{"VirtualMachines":[{"Name":"vm","Subscription":"' + $SubscriptionID + '"}]}') -Encoding utf8
Set-Content -LiteralPath (Join-Path $Stage ('ResourcesReport_{0}.html' -f $Stamp)) -Value '<html></html>' -Encoding utf8
$Zip = Join-Path $Folder ('ResourcesReport_{0}.zip' -f $Stamp)
Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $Zip -Force
Copy-Item -Path (Join-Path $Stage '*') -Destination $Folder
Remove-Item -LiteralPath $Stage -Recurse -Force
$Global:ZipOutputFile = $Zip
$Global:Resources = @(1)
$Global:ResourceCount = 1
'@ | Set-Content -LiteralPath (Join-Path $ToolRoot 'ResourceInventory.ps1') -Encoding utf8

        # Az.Accounts answers sign-in, context, token and subscription calls, and
        # the Resource Manager paths the up-front checks read, by subscription:
        # role assignments (none visible when not readable) and their
        # definitions, caller permissions (none when not readable), Resource
        # Graph resource counts and usage aggregates (one row above zero).
        $script:WrapperModules = Join-Path $script:WrapperBase 'modules'
        $Accounts = @'
function Get-RdaStandInScenario { Get-Content -LiteralPath $env:RDA_STANDIN_AZURE -Raw | ConvertFrom-Json }
function Get-RdaStandInContext
{
    [pscustomobject]@{
        Account      = [pscustomobject]@{ Id = 'operator@example.com'; Type = 'User' }
        Tenant       = [pscustomobject]@{ Id = (Get-RdaStandInScenario).Tenant }
        Subscription = $null
        Environment  = [pscustomobject]@{ Name = 'AzureCloud'; ResourceManagerUrl = 'https://management.azure.com/' }
    }
}
function Get-AzContext { [CmdletBinding()] param() Get-RdaStandInContext }
function Set-AzContext { [CmdletBinding()] param($Subscription, $Tenant, $Context) Get-RdaStandInContext }
function Import-AzContext { [CmdletBinding()] param($Path) Get-RdaStandInContext }
function Save-AzContext { [CmdletBinding()] param($Path, [switch]$Force) Set-Content -LiteralPath $Path -Value '{}' }
function Disable-AzContextAutosave { [CmdletBinding()] param($Scope) }
function Connect-AzAccount { [CmdletBinding()] param($Tenant, [switch]$UseDeviceAuthentication) throw 'stand-in: no sign-in expected' }
function Get-AzAccessToken
{
    [CmdletBinding()] param($TenantId, $ResourceUrl, [switch]$AsSecureString)
    $Claims = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"oid":"stand-in-caller"}')).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    [pscustomobject]@{ Token = ('e30.{0}.c2ln' -f $Claims); Type = 'Bearer'; ExpiresOn = (Get-Date).AddHours(1) }
}
function Get-AzSubscription
{
    [CmdletBinding()] param($TenantId, $SubscriptionId)
    $Scenario = Get-RdaStandInScenario
    @($Scenario.Subscriptions | ForEach-Object { [pscustomobject]@{ Id = $_.Id; SubscriptionId = $_.Id; Name = $_.Name; State = $_.State; TenantId = $Scenario.Tenant } })
}
function Invoke-AzRestMethod
{
    [CmdletBinding()] param([string]$Method = 'GET', [string]$Path, [string]$Payload)
    $Unreadable = @((Get-RdaStandInScenario).Unreadable)
    $Answer = { param([int]$Status, $Body) [pscustomobject]@{ StatusCode = $Status; Content = (ConvertTo-Json -InputObject $Body -Depth 8 -Compress); Headers = @{} } }
    if ($Path -match '^/subscriptions/([^/?]+)/resourcegroups\?')
    {
        if ($Unreadable -contains $Matches[1]) { return & $Answer 403 @{ error = @{ code = 'AuthorizationFailed'; message = 'stand-in: no role' } } }
        return & $Answer 200 @{ value = @() }
    }
    if ($Path -match '^/subscriptions/([^/?]+)/providers/Microsoft\.Authorization/roleAssignments\?')
    {
        $Id = $Matches[1]
        if ($Unreadable -contains $Id) { return & $Answer 200 @{ value = @() } }
        return & $Answer 200 @{ value = @(@{ properties = @{ scope = "/subscriptions/$Id"; principalId = 'stand-in-caller'; roleDefinitionId = "/subscriptions/$Id/providers/Microsoft.Authorization/roleDefinitions/stand-in-reader" } }) }
    }
    if ($Path -match '/providers/Microsoft\.Authorization/roleDefinitions/[^/?]+\?')
    {
        return & $Answer 200 @{ properties = @{ roleName = 'Reader'; type = 'BuiltInRole'; permissions = @(@{ actions = @('*/read'); notActions = @() }) } }
    }
    if ($Path -match '^/subscriptions/([^/?]+)/providers/Microsoft\.Authorization/permissions\?')
    {
        # Unknown: the answer is not JSON, so the check cannot finish. Disagree:
        # the role assignments show Reader, but Azure reports no permissions.
        $Scenario = Get-RdaStandInScenario
        # LockRoot: the inventory root is made read-only once this
        # subscription's permissions are read, so removing files there fails.
        if (@($Scenario.LockRoot) -contains $Matches[1]) { [System.IO.File]::SetUnixFileMode((Join-Path $HOME 'InventoryReports'), [System.IO.UnixFileMode]'UserRead, UserExecute') }
        if (@($Scenario.Unknown) -contains $Matches[1]) { return [pscustomobject]@{ StatusCode = 200; Content = 'not json'; Headers = @{} } }
        if (@($Scenario.Disagree) -contains $Matches[1]) { return & $Answer 200 @{ value = @() } }
        if ($Unreadable -contains $Matches[1]) { return & $Answer 200 @{ value = @() } }
        return & $Answer 200 @{ value = @(@{ actions = @('*/read'); notActions = @() }) }
    }
    if ($Method -eq 'POST' -and $Path -like '/providers/Microsoft.ResourceGraph/resources*')
    {
        $Ids = @(($Payload | ConvertFrom-Json).subscriptions)
        return & $Answer 200 @{ data = @($Ids | ForEach-Object { @{ subscriptionId = $_; ResourceCount = 1 } }) }
    }
    if ($Path -match '^/subscriptions/([^/?]+)/providers/Microsoft\.Commerce/UsageAggregates\?')
    {
        return & $Answer 200 @{ value = @(@{ properties = @{ quantity = 1.5; meterCategory = 'Stand-in'; instanceData = '' } }) }
    }
    return & $Answer 404 @{ error = @{ code = 'NotFound'; message = 'stand-in: no answer for this path' } }
}
'@
        $Billing = @'
function Get-UsageAggregates
{
    [CmdletBinding()] param($ReportedStartTime, $ReportedEndTime, $AggregationGranularity, [switch]$ShowDetails, $ContinuationToken)
    [pscustomobject]@{ UsageAggregations = @(); ContinuationToken = $null }
}
'@
        foreach ($Module in @(@{ Name = 'Az.Accounts'; Body = $Accounts }, @{ Name = 'Az.Billing'; Body = $Billing }, @{ Name = 'Az.Compute'; Body = '' }, @{ Name = 'Az.Monitor'; Body = '' }))
        {
            $Dir = Join-Path $script:WrapperModules (Join-Path $Module.Name '99.0.0')
            New-Item -ItemType Directory -Path $Dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $Dir ($Module.Name + '.psm1')) -Value $Module.Body -Encoding utf8
            Set-Content -LiteralPath (Join-Path $Dir ($Module.Name + '.psd1')) -Value ("@{{ ModuleVersion = '99.0.0'; RootModule = '{0}.psm1'; FunctionsToExport = '*' }}" -f $Module.Name) -Encoding utf8
        }

        # The az command: signed in to the scenario's tenant, with a token.
        $script:WrapperBin = Join-Path $script:WrapperBase 'bin'
        New-Item -ItemType Directory -Path $script:WrapperBin -Force | Out-Null
        @'
$Scenario = Get-Content -LiteralPath $env:RDA_STANDIN_AZURE -Raw | ConvertFrom-Json
if ($args.Count -ge 2 -and $args[0] -eq 'account' -and $args[1] -eq 'show') { [pscustomobject]@{ tenantId = $Scenario.Tenant } | ConvertTo-Json -Compress; exit 0 }
if ($args.Count -ge 2 -and $args[0] -eq 'account' -and $args[1] -eq 'get-access-token') { exit 0 }
exit 1
'@ | Set-Content -LiteralPath (Join-Path $script:WrapperBin 'az.ps1') -Encoding utf8

        $script:SubA = @{ Id = 'sub-a'; Name = 'Sub A' }
        $script:SubB = @{ Id = 'sub-b'; Name = 'Sub B' }
        $script:SubX = @{ Id = 'sub-x-not-readable'; Name = 'Sub X' }

        # A fresh home (its InventoryReports folder is the run's inventory root),
        # or an earlier one again.
        function script:Use-WrapperCase
        {
            param([string]$CaseHome)
            if (-not $CaseHome)
            {
                $CaseHome = Join-Path $script:WrapperBase ([guid]::NewGuid().ToString().Substring(0, 8))
                New-Item -ItemType Directory -Path $CaseHome -Force | Out-Null
            }
            $script:CaseHome = $CaseHome
            $script:CaseRoot = Join-Path $CaseHome 'InventoryReports'
            $script:CaseScenario = Join-Path $CaseHome 'scenario.json'
            $script:CaseState = Join-Path $script:CaseRoot ('.resume-state-{0}.json' -f $script:WrapperTenant)
        }

        function script:Set-WrapperScenario
        {
            param([object[]]$Subs, [string[]]$Unreadable = @(), [string[]]$Fail = @(), [string[]]$EndSession = @(), [string[]]$Disabled = @(), [string[]]$Hang = @(), [string[]]$Unknown = @(), [string[]]$Disagree = @(), [string[]]$LockRoot = @())
            [pscustomobject]@{
                Tenant        = $script:WrapperTenant
                Subscriptions = @($Subs | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Name = $_.Name; State = $(if ($Disabled -contains $_.Id) { 'Disabled' } else { 'Enabled' }) } })
                Unreadable    = @($Unreadable)
                FailIds       = @($Fail)
                EndSessionIds = @($EndSession)
                HangIds       = @($Hang)
                Unknown       = @($Unknown)
                Disagree      = @($Disagree)
                LockRoot      = @($LockRoot)
            } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:CaseScenario -Encoding utf8
        }

        # One run of the wrapper as its own process, stdin closed: its exit code
        # and the lines it printed. -Streams 0 leaves -ParallelStreams out, so
        # the wrapper picks it from the host; -Environment adds variables to the
        # process; -EndWhen ends the session when its condition holds. A run
        # still going after $TimeoutSeconds is stopped and the test fails.
        function script:Invoke-WrapperRun
        {
            param([string[]]$Arguments = @(), [int]$Streams = 1, [hashtable]$Environment = @{}, [scriptblock]$EndWhen, [int]$TimeoutSeconds = 300)
            $Info = [System.Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh'))
            $StreamArguments = if ($Streams -gt 0) { @('-ParallelStreams', [string]$Streams) } else { @() }
            foreach ($Arg in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script:WrapperScript, '-TenantID', $script:WrapperTenant) + $StreamArguments + @($Arguments)) { $Info.ArgumentList.Add($Arg) }
            $Info.UseShellExecute = $false
            $Info.RedirectStandardInput = $true
            $Info.RedirectStandardOutput = $true
            $Info.RedirectStandardError = $true
            $Info.Environment['HOME'] = $script:CaseHome
            $Info.Environment['PSModulePath'] = $script:WrapperModules
            $Info.Environment['PATH'] = $script:WrapperBin + [IO.Path]::PathSeparator + $env:PATH
            $Info.Environment['RDA_STANDIN_AZURE'] = $script:CaseScenario
            $Info.Environment['NO_COLOR'] = '1'
            foreach ($Name in $Environment.Keys) { $Info.Environment[$Name] = [string]$Environment[$Name] }
            $Proc = [System.Diagnostics.Process]::Start($Info)
            $Proc.StandardInput.Close()
            $Out = $Proc.StandardOutput.ReadToEndAsync()
            $Err = $Proc.StandardError.ReadToEndAsync()
            # -EndWhen: the session ends (the wrapper and its stream processes
            # are stopped) as soon as the condition holds.
            $Ended = $false
            if ($EndWhen)
            {
                $Deadline = (Get-Date).AddSeconds($TimeoutSeconds)
                while (-not $Proc.HasExited -and (Get-Date) -lt $Deadline)
                {
                    if (& $EndWhen) { $Proc.Kill($true); $Ended = $true; break }
                    Start-Sleep -Milliseconds 250
                }
            }
            if (-not $Proc.WaitForExit($TimeoutSeconds * 1000))
            {
                $Proc.Kill($true)
                throw ('The wrapper run did not end within {0} seconds.' -f $TimeoutSeconds)
            }
            $Proc.WaitForExit()
            $Text = @(([string]$Out.Result -replace "`e\[[0-9;]*m", '') -split "`r?`n")
            return [pscustomobject]@{ ExitCode = $Proc.ExitCode; Ended = $Ended; Text = $Text; Error = [string]$Err.Result; Root = $script:CaseRoot }
        }

        # The per-stream state files a parallel run leaves in the inventory root
        # until it merges them, and the subscriptions they record as completed.
        function script:Get-StreamStateFiles
        {
            if (-not (Test-Path -LiteralPath $script:CaseRoot)) { return @() }
            @(Get-ChildItem -LiteralPath $script:CaseRoot -Force -File -Filter ('.resume-state-{0}-stream-*.json' -f $script:WrapperTenant))
        }
        function script:Get-StreamCompletedIds
        {
            @(script:Get-StreamStateFiles | ForEach-Object { @((Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).Completed) } | Where-Object { $_ } | Sort-Object -Unique)
        }

        # The resume state as written, or $null when there is none.
        function script:Read-WrapperState
        {
            if (-not (Test-Path -LiteralPath $script:CaseState)) { return $null }
            $Raw = Get-Content -LiteralPath $script:CaseState -Raw | ConvertFrom-Json
            return [pscustomobject]@{
                Completed = @($Raw.CompletedSubscriptionIds | Where-Object { $_ } | Sort-Object)
                Failed    = @($Raw.FailedAttempts | Where-Object { $_ } | ForEach-Object { $_.Id } | Sort-Object)
                Attempts  = @($Raw.FailedAttempts | Where-Object { $_ })
            }
        }

        # The names of the resume-state files in the inventory root.
        function script:Get-StateFileNames
        {
            if (-not (Test-Path -LiteralPath $script:CaseRoot)) { return @() }
            @(Get-ChildItem -LiteralPath $script:CaseRoot -Force -File -Filter '.resume-state*' | ForEach-Object { $_.Name } | Sort-Object)
        }

        # Cut the last '}' off the per-stream state file that names $Id (as
        # completed or failed), as an interrupted write leaves it. Returns its name.
        function script:Set-StreamStateFileCutShort
        {
            param([string]$Id)
            $File = @(script:Get-StreamStateFiles | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw).Contains('"' + $Id + '"') })[0]
            $Text = Get-Content -LiteralPath $File.FullName -Raw
            [IO.File]::WriteAllText($File.FullName, $Text.Substring(0, $Text.LastIndexOf('}')))
            return $File.Name
        }

        function script:Get-AccessStopLines { param($Run) @($Run.Text | Where-Object { $_ -match 'No subscription is readable|Stopping before any work' }) }

        # The lines that say how the run ended its output: the zip check, the
        # consolidated zip, the bundle and the resume state. Paths and times
        # are replaced so two runs can be compared.
        function script:Get-RunEndLines
        {
            param($Run)
            $Ending = '^(Per-subscription output verification|Compressing |Reporting Data File|No per-subscription zip files found|Inventory root not found|Bundle finalized|Resume state cleared|Resume: carrying)'
            $Lines = @($Run.Text | Where-Object { $_ -match $Ending })
            @($Lines | ForEach-Object { ($_.Replace($Run.Root, '<root>')) -replace '\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}', '<time>' })
        }

        # Every entry of every zip under the inventory root, the zips inside them
        # included: { Zip; Name; Text }.
        function script:Get-WrapperZipEntries
        {
            $Found = [System.Collections.Generic.List[object]]::new()
            $ReadArchive = {
                param([System.IO.Compression.ZipArchive]$Archive, [string]$Label)
                foreach ($Entry in @($Archive.Entries))
                {
                    $Buffer = [System.IO.MemoryStream]::new()
                    $Stream = $Entry.Open()
                    try { $Stream.CopyTo($Buffer) } finally { $Stream.Dispose() }
                    $Found.Add([pscustomobject]@{ Zip = $Label; Name = $Entry.FullName; Text = [System.Text.Encoding]::UTF8.GetString($Buffer.ToArray()) })
                    if ($Entry.FullName -like '*.zip')
                    {
                        $Buffer.Position = 0
                        $Inner = [System.IO.Compression.ZipArchive]::new($Buffer, [System.IO.Compression.ZipArchiveMode]::Read)
                        try { & $ReadArchive $Inner ($Label + '!' + $Entry.FullName) } finally { $Inner.Dispose() }
                    }
                }
            }
            foreach ($Zip in @(Get-ChildItem -LiteralPath $script:CaseRoot -Recurse -Force -File -Filter '*.zip'))
            {
                $Archive = [System.IO.Compression.ZipFile]::OpenRead($Zip.FullName)
                try { & $ReadArchive $Archive $Zip.Name } finally { $Archive.Dispose() }
            }
            return $Found.ToArray()
        }

        $script:SkippedXLine = '    - Sub X (sub-x-not-readable) - no read access (role assignments not visible to this identity)'
        $script:FinishLine = '  Skipping them and finishing the run: the other 1 subscription(s) were completed by an earlier run, so nothing is left to collect. To include them: Grant the identity Reader on these subscriptions, then re-run.'
    }

    AfterAll {
        if ($script:WrapperBase -and (Test-Path -LiteralPath $script:WrapperBase)) { Remove-Item -LiteralPath $script:WrapperBase -Recurse -Force }
    }

    BeforeEach { script:Use-WrapperCase }

    It 'after an interrupted run, skips and lists them, finishes like a -Resume with nothing left to collect, and a second -Resume ends too' {
        # Run 1: Sub A completes, the session ends in Sub X.
        script:Set-WrapperScenario -Subs $script:SubA, $script:SubX -EndSession $script:SubX.Id
        (script:Invoke-WrapperRun).ExitCode | Should -Be 137
        (script:Read-WrapperState).Completed | Should -Be @($script:SubA.Id)

        # Sub X cannot be read any more.
        script:Set-WrapperScenario -Subs $script:SubA, $script:SubX -Unreadable $script:SubX.Id
        $R1 = script:Invoke-WrapperRun -Arguments '-Resume'
        script:Get-AccessStopLines $R1 | Should -BeNullOrEmpty
        $R1.ExitCode | Should -Be 0
        $R1.Text | Should -Contain $script:SkippedXLine
        $R1.Text | Should -Contain $script:FinishLine
        $R1.Text | Should -Contain '  - Sub X (sub-x-not-readable) - no read access (role assignments not visible to this identity)' -Because 'the end of the run lists it again'
        $R1.Text | Should -Not -Contain 'Processing subscription: Sub A (sub-a)' -Because 'Sub A was completed by run 1'
        $R1.Text | Should -Not -Contain 'Processing subscription: Sub X (sub-x-not-readable)'
        Test-Path -LiteralPath $script:CaseState | Should -BeFalse
        $Case = $script:CaseHome

        # The same state with Sub X out of scope: a -Resume with nothing left to
        # collect and no check. The run above ends its output the same way.
        script:Use-WrapperCase
        script:Set-WrapperScenario -Subs $script:SubA, $script:SubX -EndSession $script:SubX.Id
        $null = script:Invoke-WrapperRun
        script:Set-WrapperScenario -Subs $script:SubA, $script:SubX -Disabled $script:SubX.Id
        $Control = script:Invoke-WrapperRun -Arguments '-Resume'
        $Control.ExitCode | Should -Be 0
        script:Get-RunEndLines $R1 | Should -Be @(script:Get-RunEndLines $Control)
        @(script:Get-RunEndLines $R1) | Should -Contain 'Resume state cleared (clean run).'

        # A second -Resume (the first cleared the state) also ends without a stop.
        script:Use-WrapperCase -CaseHome $Case
        $R2 = script:Invoke-WrapperRun -Arguments '-Resume'
        script:Get-AccessStopLines $R2 | Should -BeNullOrEmpty
        $R2.ExitCode | Should -Be 0
        $R2.Text | Should -Contain $script:SkippedXLine
        Test-Path -LiteralPath $script:CaseState | Should -BeFalse
    }

    It 'without -Resume still stops with exit 1 when none is readable, although the state records a completed subscription' {
        script:Set-WrapperScenario -Subs $script:SubA, $script:SubX -EndSession $script:SubX.Id
        $null = script:Invoke-WrapperRun
        script:Set-WrapperScenario -Subs $script:SubA, $script:SubX -Unreadable $script:SubA.Id, $script:SubX.Id
        $R = script:Invoke-WrapperRun
        $R.ExitCode | Should -Be 1
        $R.Text | Should -Contain '  No subscription is readable. Stopping before any work. Grant the identity Reader on these subscriptions, then re-run.'
        @($R.Text | Where-Object { $_ -match 'Resume again|without -Resume' }) | Should -BeNullOrEmpty
        (script:Read-WrapperState).Completed | Should -Be @($script:SubA.Id)
    }

    It 'on -Resume with no completed subscription stops with exit 1 and names the way out that works' {
        # Run 1: Sub B fails, so the state holds a failure and nothing completed.
        script:Set-WrapperScenario -Subs $script:SubB -Fail $script:SubB.Id
        $null = script:Invoke-WrapperRun
        (script:Read-WrapperState).Failed | Should -Be @($script:SubB.Id)

        script:Set-WrapperScenario -Subs $script:SubB -Unreadable $script:SubB.Id
        $R = script:Invoke-WrapperRun -Arguments '-Resume'
        $R.ExitCode | Should -Be 1
        $R.Text | Should -Contain '  No subscription is readable. Stopping before any work. Grant the identity Reader on these subscriptions, then run -Resume again.'
        $R.Text | Should -Contain '  A run without -Resume checks the same subscriptions, so it stops here too.'
        (script:Read-WrapperState).Failed | Should -Be @($script:SubB.Id)

        # As the message says, a run without -Resume stops the same way.
        $Fresh = script:Invoke-WrapperRun
        $Fresh.ExitCode | Should -Be 1
        $Fresh.Text | Should -Contain '  No subscription is readable. Stopping before any work. Grant the identity Reader on these subscriptions, then re-run.'

        # Reader granted: -Resume collects Sub B and clears the state.
        script:Set-WrapperScenario -Subs $script:SubB
        $Granted = script:Invoke-WrapperRun -Arguments '-Resume'
        $Granted.ExitCode | Should -Be 0
        script:Get-AccessStopLines $Granted | Should -BeNullOrEmpty
        $Granted.Text | Should -Contain 'Processing subscription: Sub B (sub-b)'
        Test-Path -LiteralPath $script:CaseState | Should -BeFalse
    }

    It 'under -Obfuscate no zip holds the skipped subscription (<Label>)' -TestCases @(
        @{ Label = 'nothing left to collect'; Subs = @(@{ Id = 'sub-a'; Name = 'Sub A' }, @{ Id = 'sub-x-not-readable'; Name = 'Sub X' }); EndIn = 'sub-x-not-readable'; Bundle = $false }
        @{ Label = 'one readable subscription left'; Subs = @(@{ Id = 'sub-a'; Name = 'Sub A' }, @{ Id = 'sub-b'; Name = 'Sub B' }, @{ Id = 'sub-x-not-readable'; Name = 'Sub X' }); EndIn = 'sub-b'; Bundle = $true }
    ) {
        param($Label, $Subs, $EndIn, $Bundle)
        # Run 1: Sub A completes, the session ends in $EndIn. Then Sub X cannot be read.
        script:Set-WrapperScenario -Subs $Subs -EndSession $EndIn
        (script:Invoke-WrapperRun -Arguments '-Obfuscate').ExitCode | Should -Be 137
        script:Set-WrapperScenario -Subs $Subs -Unreadable $script:SubX.Id
        $R = script:Invoke-WrapperRun -Arguments '-Resume', '-Obfuscate'
        $R.ExitCode | Should -Be 0
        $R.Text | Should -Contain $script:SkippedXLine

        $Entries = @(script:Get-WrapperZipEntries)
        $Entries.Count | Should -BeGreaterThan 0
        if ($Bundle)
        {
            $Outer = @($Entries | Where-Object { $_.Zip -like 'AllSubscriptions_ResourcesReport_*.zip' -and $_.Zip -notlike '*!*' })
            @($Outer | Where-Object { $_.Name -eq 'RunSummary.log' }).Count | Should -Be 1
            @($Outer | Where-Object { $_.Name -eq 'MainSummary.html' }).Count | Should -Be 1
        }
        @($Entries | Where-Object { $_.Text.Contains($script:SubX.Id) -or $_.Name.Contains($script:SubX.Id) -or $_.Text.Contains($script:SubX.Name) } | ForEach-Object { '{0} {1}' -f $_.Zip, $_.Name }) | Should -BeNullOrEmpty
    }

    It 'finishes with one stream and collects no completed subscription again (<Label>)' -TestCases @(
        @{ Label = 'one completed, -ParallelStreams 2'; Completed = 1; Streams = 2 }
        @{ Label = 'one completed, automatic stream count'; Completed = 1; Streams = 0 }
        @{ Label = 'three completed, -ParallelStreams 2'; Completed = 3; Streams = 2 }
        @{ Label = 'three completed, automatic stream count'; Completed = 3; Streams = 0 }
    ) {
        param($Label, $Completed, $Streams)
        $SubC = @{ Id = 'sub-c'; Name = 'Sub C' }
        if ($Completed -eq 1)
        {
            # Run 1: Sub A completes, the session ends in Sub X.
            $Subs = @($script:SubA, $script:SubX)
            script:Set-WrapperScenario -Subs $Subs -EndSession $script:SubX.Id
            (script:Invoke-WrapperRun).ExitCode | Should -Be 137
        }
        else
        {
            # Run 1, two streams: Sub A and Sub B complete, Sub C fails. Run 2,
            # -Resume: Sub C completes and the session ends in Sub X, so three
            # subscriptions are recorded as completed.
            $Subs = @($script:SubA, $script:SubB, $SubC, $script:SubX)
            script:Set-WrapperScenario -Subs $Subs -Fail $SubC.Id -Disabled $script:SubX.Id
            $null = script:Invoke-WrapperRun -Streams 2
            (script:Read-WrapperState).Failed | Should -Be @($SubC.Id)
            script:Set-WrapperScenario -Subs $Subs -EndSession $script:SubX.Id
            (script:Invoke-WrapperRun -Arguments '-Resume').ExitCode | Should -Be 137
        }
        $Done = @($Subs | Where-Object { $_.Id -ne $script:SubX.Id })
        (script:Read-WrapperState).Completed | Should -Be @($Done | ForEach-Object { $_.Id } | Sort-Object)

        # Sub X cannot be read any more. With the automatic value the host is
        # given 4 vCPU, which makes it more than one stream.
        script:Set-WrapperScenario -Subs $Subs -Unreadable $script:SubX.Id
        $R = script:Invoke-WrapperRun -Arguments '-Resume' -Streams $Streams -Environment @{ DOTNET_PROCESSOR_COUNT = '4' }
        script:Get-AccessStopLines $R | Should -BeNullOrEmpty
        $R.ExitCode | Should -Be 0
        $R.Text | Should -Contain $script:SkippedXLine
        foreach ($Sub in $Done)
        {
            $R.Text | Should -Not -Contain ('Processing subscription: {0} ({1})' -f $Sub.Name, $Sub.Id)
            $R.Text | Should -Contain ('Skipping (already completed): {0} ({1})' -f $Sub.Name, $Sub.Id)
        }
        @($R.Text | Where-Object { $_ -match '^\[stream-\d+\] processing' }) | Should -BeNullOrEmpty
        $R.Text | Should -Contain ('Subscriptions Skipped:   {0} (already completed)' -f $Done.Count)
        Test-Path -LiteralPath $script:CaseState | Should -BeFalse
        @(Get-ChildItem -LiteralPath $script:CaseRoot -Force -File -Filter '.resume-state-*' -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty

        $Parallelism = @($R.Text | Where-Object { $_ -like 'Parallelism: *' })
        $Parallelism.Count | Should -Be 1
        if ($Streams -gt 0)
        {
            $Parallelism[0] | Should -BeLike 'Parallelism: -ParallelStreams 1 (nothing is left to collect, so one stream instead of the 2 passed), -ConcurrencyLimit *'
        }
        elseif ($Parallelism[0] -like 'Parallelism: -ParallelStreams 1 (auto)*')
        {
            Set-ItResult -Inconclusive -Because 'the memory of this host makes the automatic value one stream'
        }
        else
        {
            $Parallelism[0] | Should -Match '^Parallelism: -ParallelStreams 1 \(nothing is left to collect, so one stream instead of the [2-9] chosen automatically\), -ConcurrencyLimit '
        }
    }

    It 'after an interrupted parallel run, clears the main and the per-stream state, and the next -Resume collects fresh (<Label>)' -TestCases @(
        @{ Label = '-ParallelStreams 2'; Streams = 2 }
        @{ Label = 'automatic stream count'; Streams = 0 }
        @{ Label = '-ParallelStreams 1'; Streams = 1 }
    ) {
        param($Label, $Streams)
        $Subs = @($script:SubA, $script:SubB, $script:SubX)
        # Run 1, two streams: stream 0 collects Sub A then Sub X, stream 1 Sub B.
        # The session ends while Sub X is collected, once both streams have
        # recorded their completed subscription in their own state file.
        script:Set-WrapperScenario -Subs $Subs -Hang $script:SubX.Id
        $Run1 = script:Invoke-WrapperRun -Streams 2 -EndWhen { (Test-Path -LiteralPath (Join-Path $script:CaseHome ('waiting-' + $script:SubX.Id))) -and (@(script:Get-StreamCompletedIds) -join ',') -eq 'sub-a,sub-b' }
        $Run1.Ended | Should -BeTrue
        @(script:Get-StreamStateFiles).Count | Should -Be 2
        Test-Path -LiteralPath $script:CaseState | Should -BeFalse -Because 'a parallel run merges its stream files only at its end'

        # Sub X cannot be read any more.
        script:Set-WrapperScenario -Subs $Subs -Unreadable $script:SubX.Id
        $Four = @{ DOTNET_PROCESSOR_COUNT = '4' }
        $R1 = script:Invoke-WrapperRun -Arguments '-Resume' -Streams $Streams -Environment $Four
        $R1.ExitCode | Should -Be 0
        @($R1.Text | Where-Object { $_ -like 'Recovered per-stream state from an interrupted parallel run: 2 completed, 0 failed subscription record(s).' }).Count | Should -Be 1 -Because 'a stream file''s [null] retry list is no failure'
        $R1.Text | Should -Contain '  Skipping them and finishing the run: the other 2 subscription(s) were completed by an earlier run, so nothing is left to collect. To include them: Grant the identity Reader on these subscriptions, then re-run.'
        $R1.Text | Should -Contain 'Skipping (already completed): Sub A (sub-a)'
        $R1.Text | Should -Contain 'Skipping (already completed): Sub B (sub-b)'
        @($R1.Text | Where-Object { $_ -match '^(Processing subscription: |\[stream-\d+\] processing )' }) | Should -BeNullOrEmpty
        $R1.Text | Should -Contain 'Resume state cleared (clean run).'
        Test-Path -LiteralPath $script:CaseState | Should -BeFalse
        @(script:Get-StreamStateFiles | ForEach-Object { $_.Name }) | Should -BeNullOrEmpty -Because 'the finish case deletes the stream files it folded in'

        # The next -Resume finds no state: nothing to recover, and Sub A and Sub B
        # are collected again.
        $R2 = script:Invoke-WrapperRun -Arguments '-Resume' -Streams $Streams -Environment $Four
        $R2.ExitCode | Should -Be 0
        @($R2.Text | Where-Object { $_ -like 'Recovered per-stream state*' }) | Should -BeNullOrEmpty
        $R2.Text | Should -Contain 'Resume mode: no previous state found; processing all subscriptions.'
        foreach ($Sub in @($script:SubA, $script:SubB))
        {
            @($R2.Text | Where-Object { $_ -match ('^(Processing subscription: |\[stream-\d+\] processing \(\d+ of \d+\): ){0} \({1}\)$' -f [regex]::Escape($Sub.Name), [regex]::Escape($Sub.Id)) }).Count | Should -Be 1
        }
        $R2.Text | Should -Contain $script:SkippedXLine
        Test-Path -LiteralPath $script:CaseState | Should -BeFalse
        @(script:Get-StreamStateFiles) | Should -BeNullOrEmpty
    }

    It 'names a skipped subscription on the retry list under Pending Retries, and -ResumeFailedOnly is unchanged' {
        $Advice = @(
            'Pending Retries:         1 subscription(s) on the retry list (FailedAttempts)'
            '  1 of them were skipped by this run''s role check:'
            $script:SkippedXLine
            '  To retry them: Grant the identity Reader on these subscriptions, then run -ResumeFailedOnly.'
            'Re-run with -ResumeFailedOnly to retry them.'
        )
        $AdviceIn = {
            param($Run)
            $At = [array]::IndexOf($Run.Text, $Advice[0])
            if ($At -lt 0) { return @() }
            @($Run.Text[$At..($At + $Advice.Count - 1)])
        }
        # Run 0: Sub A completes, Sub X fails. Then Sub X cannot be read.
        script:Set-WrapperScenario -Subs $script:SubA, $script:SubX -Fail $script:SubX.Id
        $null = script:Invoke-WrapperRun -Arguments '-Obfuscate'
        (script:Read-WrapperState).Failed | Should -Be @($script:SubX.Id)
        script:Set-WrapperScenario -Subs $script:SubA, $script:SubX -Unreadable $script:SubX.Id

        $Plain = script:Invoke-WrapperRun -Arguments '-Obfuscate'
        $Plain.ExitCode | Should -Be 0
        & $AdviceIn $Plain | Should -Be $Advice

        $FailedOnly = script:Invoke-WrapperRun -Arguments '-ResumeFailedOnly', '-Obfuscate'
        $FailedOnly.ExitCode | Should -Be 1
        $FailedOnly.Text | Should -Contain '  No subscription is readable. Stopping before any work. Grant the identity Reader on these subscriptions, then re-run.'
        (script:Read-WrapperState).Failed | Should -Be @($script:SubX.Id)

        $Resume = script:Invoke-WrapperRun -Arguments '-Resume', '-Obfuscate'
        $Resume.ExitCode | Should -Be 0
        $Resume.Text | Should -Contain $script:FinishLine
        & $AdviceIn $Resume | Should -Be $Advice
        (script:Read-WrapperState).Failed | Should -Be @($script:SubX.Id) -Because 'the retry list keeps the state'
        @(script:Get-WrapperZipEntries | Where-Object { $_.Text.Contains($script:SubX.Id) -or $_.Name.Contains($script:SubX.Id) -or $_.Text.Contains($script:SubX.Name) } | ForEach-Object { '{0} {1}' -f $_.Zip, $_.Name }) | Should -BeNullOrEmpty

        # Reader granted: -ResumeFailedOnly retries Sub X and the state clears.
        script:Set-WrapperScenario -Subs $script:SubA, $script:SubX
        $Granted = script:Invoke-WrapperRun -Arguments '-ResumeFailedOnly', '-Obfuscate'
        $Granted.ExitCode | Should -Be 0
        $Granted.Text | Should -Contain 'Processing subscription: Sub X (sub-x-not-readable)'
        Test-Path -LiteralPath $script:CaseState | Should -BeFalse
    }

    It 'after a parallel run left a per-stream state file cut short, warns, moves it aside, collects its subscriptions, and the next -Resume ends clean (<Label>)' -TestCases @(
        @{ Label = '-ParallelStreams 1'; Streams = 1 }
        @{ Label = '-ParallelStreams 2'; Streams = 2 }
        @{ Label = 'automatic stream count'; Streams = 0 }
    ) {
        param($Label, $Streams)
        $Subs = @($script:SubA, $script:SubB, $script:SubX)
        # Run 1, two streams: Sub A and Sub B complete, the session ends while
        # Sub X is collected. Then the stream file that records Sub B is cut
        # short, as an interrupted write leaves it. Sub X cannot be read any more.
        script:Set-WrapperScenario -Subs $Subs -Hang $script:SubX.Id
        $Run1 = script:Invoke-WrapperRun -Streams 2 -EndWhen { (Test-Path -LiteralPath (Join-Path $script:CaseHome ('waiting-' + $script:SubX.Id))) -and (@(script:Get-StreamCompletedIds) -join ',') -eq 'sub-a,sub-b' }
        $Run1.Ended | Should -BeTrue
        $Cut = script:Set-StreamStateFileCutShort -Id $script:SubB.Id
        script:Set-WrapperScenario -Subs $Subs -Unreadable $script:SubX.Id
        $Four = @{ DOTNET_PROCESSOR_COUNT = '4' }

        $R1 = script:Invoke-WrapperRun -Arguments '-Resume' -Streams $Streams -Environment $Four
        $R1.ExitCode | Should -Be 0
        $Warning = @($R1.Text | Where-Object { $_ -like 'WARNING: The per-stream state file *' })
        $Warning.Count | Should -Be 1
        $Moved = @(script:Get-StateFileNames | Where-Object { $_ -like '*.unreadable-*' })
        $Moved.Count | Should -Be 1
        $Moved[0] | Should -Match ('^' + [regex]::Escape($Cut) + '\.unreadable-\d{8}-\d{6}$')
        $Warning[0] | Should -Be ('WARNING: The per-stream state file {0} from an interrupted parallel run could not be read, so its records are not used: the subscriptions it lists are not counted as completed and this run collects them again. It was moved aside to {1}.' -f $Cut, $Moved[0])
        ($Warning[0]) | Should -Not -Match 'sub-b'
        @($R1.Text | Where-Object { $_ -like 'Recovered per-stream state from an interrupted parallel run: 1 completed, 0 failed subscription record(s).' }).Count | Should -Be 1 -Because 'the other stream file was read'
        @($R1.Text | Where-Object { $_ -match '^(Skipping \(already completed\): |\[stream-\d+\] skipping \(already completed\): )Sub A \(sub-a\)$' }).Count | Should -Be 1
        @($R1.Text | Where-Object { $_ -match '^(Processing subscription: |\[stream-\d+\] processing \(\d+ of \d+\): )Sub B \(sub-b\)$' }).Count | Should -Be 1 -Because 'Sub B was recorded only in the file that could not be read'
        $R1.Text | Should -Not -Contain 'Resume state cleared (clean run).'
        $R1.Text | Should -Contain ('Resume state cleared, but not a clean run: the per-stream state file {0} could not be read and was moved aside to {1}; its records were not used.' -f $Cut, $Moved[0])
        Test-Path -LiteralPath $script:CaseState | Should -BeFalse
        @(script:Get-StreamStateFiles) | Should -BeNullOrEmpty
        @(script:Get-StateFileNames) | Should -Be @($Moved[0]) -Because 'only the moved file is left, kept for inspection'

        $R2 = script:Invoke-WrapperRun -Arguments '-Resume' -Streams $Streams -Environment $Four
        $R2.ExitCode | Should -Be 0
        @($R2.Text | Where-Object { $_ -like 'WARNING: The per-stream state file *' -or $_ -like 'Recovered per-stream state*' -or $_ -like 'Resume state cleared, but*' -or $_ -like 'Resume state kept*' }) | Should -BeNullOrEmpty
        $R2.Text | Should -Contain 'Resume mode: no previous state found; processing all subscriptions.'
        $R2.Text | Should -Contain 'Resume state cleared (clean run).'
        Test-Path -LiteralPath $script:CaseState | Should -BeFalse
        @(script:Get-StateFileNames) | Should -Be @($Moved[0])
        @(script:Get-WrapperZipEntries | Where-Object { $_.Name -like '*.resume-state*' -or $_.Name -like '*unreadable*' -or $_.Text.Contains('unreadable-') } | ForEach-Object { '{0} {1}' -f $_.Zip, $_.Name }) | Should -BeNullOrEmpty
    }

    It 'with nothing left to collect after a per-stream state file was cut short, keeps that file aside and deletes only the one it read' {
        $Subs = @($script:SubA, $script:SubB, $script:SubX)
        script:Set-WrapperScenario -Subs $Subs -Hang $script:SubX.Id
        $null = script:Invoke-WrapperRun -Streams 2 -EndWhen { (Test-Path -LiteralPath (Join-Path $script:CaseHome ('waiting-' + $script:SubX.Id))) -and (@(script:Get-StreamCompletedIds) -join ',') -eq 'sub-a,sub-b' }
        $Cut = script:Set-StreamStateFileCutShort -Id $script:SubB.Id
        # Sub B and Sub X cannot be read: nothing is left to collect.
        script:Set-WrapperScenario -Subs $Subs -Unreadable $script:SubB.Id, $script:SubX.Id

        $R1 = script:Invoke-WrapperRun -Arguments '-Resume' -Streams 2 -Environment @{ DOTNET_PROCESSOR_COUNT = '4' }
        $R1.ExitCode | Should -Be 0
        @($R1.Text | Where-Object { $_ -like 'WARNING: The per-stream state file *' }).Count | Should -Be 1
        $R1.Text | Should -Contain '  Skipping them and finishing the run: the other 1 subscription(s) were completed by an earlier run, so nothing is left to collect. To include them: Grant the identity Reader on these subscriptions, then re-run.'
        $R1.Text | Should -Contain '    - Sub B (sub-b) - no read access (role assignments not visible to this identity)'
        $R1.Text | Should -Not -Contain 'Resume state cleared (clean run).'
        $Moved = @(script:Get-StateFileNames | Where-Object { $_ -like '*.unreadable-*' })
        $R1.Text | Should -Contain ('Resume state cleared, but not a clean run: the per-stream state file {0} could not be read and was moved aside to {1}; its records were not used.' -f $Cut, $Moved[0])
        @(script:Get-StateFileNames) | Should -Be @($Moved) -Because 'the stream file that was read is deleted; the one that could not be read is kept aside'

        $R2 = script:Invoke-WrapperRun -Arguments '-Resume' -Streams 2 -Environment @{ DOTNET_PROCESSOR_COUNT = '4' }
        @($R2.Text | Where-Object { $_ -like 'WARNING: The per-stream state file *' -or $_ -like 'Recovered per-stream state*' }) | Should -BeNullOrEmpty
        $R2.Text | Should -Contain 'Resume mode: no previous state found; processing all subscriptions.'
        Test-Path -LiteralPath $script:CaseState | Should -BeFalse
    }

    It 'after a parallel run left its per-stream state files, a one-stream -Resume that ends clean deletes them, and the next -Resume starts with no state' {
        $Subs = @($script:SubA, $script:SubB, $script:SubX)
        script:Set-WrapperScenario -Subs $Subs -Hang $script:SubX.Id
        $null = script:Invoke-WrapperRun -Streams 2 -EndWhen { (Test-Path -LiteralPath (Join-Path $script:CaseHome ('waiting-' + $script:SubX.Id))) -and (@(script:Get-StreamCompletedIds) -join ',') -eq 'sub-a,sub-b' }
        @(script:Get-StreamStateFiles).Count | Should -BeGreaterThan 0
        script:Set-WrapperScenario -Subs $Subs

        $R1 = script:Invoke-WrapperRun -Arguments '-Resume' -Streams 1
        $R1.ExitCode | Should -Be 0
        $R1.Text | Should -Contain 'Resume state cleared (clean run).'
        @(script:Get-StateFileNames) | Should -BeNullOrEmpty -Because 'the folded per-stream files are in the state the run cleared'

        $R2 = script:Invoke-WrapperRun -Arguments '-Resume' -Streams 1
        @($R2.Text | Where-Object { $_ -like 'Recovered per-stream state*' }) | Should -BeNullOrEmpty
        $R2.Text | Should -Contain 'Resume mode: no previous state found; processing all subscriptions.'
    }

    It 'keeps a subscription whose check cannot finish, or whose two answers disagree, on the retry list until it is collected (<Cause>, <Route>)' -TestCases @(
        @{ Cause = 'Unknown'; Route = '-Resume'; Fix = 'The role check could not finish (the reason above says why); run -ResumeFailedOnly.' }
        @{ Cause = 'Unknown'; Route = '-ResumeFailedOnly'; Fix = 'The role check could not finish (the reason above says why); run -ResumeFailedOnly.' }
        @{ Cause = 'Disagree'; Route = '-Resume'; Fix = 'The role assignments and Azure disagree, which usually means roles changed in the last few minutes; wait 5 minutes, then run -ResumeFailedOnly.' }
        @{ Cause = 'Disagree'; Route = '-ResumeFailedOnly'; Fix = 'The role assignments and Azure disagree, which usually means roles changed in the last few minutes; wait 5 minutes, then run -ResumeFailedOnly.' }
    ) {
        param($Cause, $Route, $Fix)
        $Subs = @($script:SubA, $script:SubX)
        $Temporary = @{ $Cause = @($script:SubX.Id) }
        $AttemptsOf = { @((script:Read-WrapperState).Attempts | Where-Object { $_.Id -eq $script:SubX.Id } | ForEach-Object { [int]$_.Attempts }) }

        # Run 0, no -Resume: Sub A is collected, Sub X skipped and put on the retry list.
        script:Set-WrapperScenario -Subs $Subs @Temporary
        $R0 = script:Invoke-WrapperRun -Arguments '-Obfuscate'
        $R0.ExitCode | Should -Be 0
        $R0.Text | Should -Not -Contain 'Resume state cleared (clean run).'
        & $AttemptsOf | Should -Be @(1)
        @((script:Read-WrapperState).Attempts)[0].Reason | Should -BeLike 'skipped by the up-front role check: *'
        $At = [array]::IndexOf($R0.Text, 'Pending Retries:         1 subscription(s) on the retry list (FailedAttempts)')
        $At | Should -BeGreaterThan -1
        $R0.Text[$At + 1] | Should -Be '  1 of them were skipped by this run''s role check:'
        $R0.Text[$At + 3] | Should -Be ('  To retry them: {0}' -f $Fix)

        if ($Route -eq '-Resume')
        {
            # -Resume: nothing else left to collect; Sub X is skipped again and counted.
            $R1 = script:Invoke-WrapperRun -Arguments '-Resume', '-Obfuscate'
            $R1.ExitCode | Should -Be 0
            $R1.Text | Should -Contain 'Skipping (already completed): Sub A (sub-a)'
        }
        else
        {
            # -ResumeFailedOnly: nothing on its retry list can be read, so it stops,
            # and the stopped run is counted too.
            $R1 = script:Invoke-WrapperRun -Arguments '-ResumeFailedOnly', '-Obfuscate'
            $R1.ExitCode | Should -Be 1
            @(script:Get-AccessStopLines $R1).Count | Should -BeGreaterThan 0
        }
        & $AttemptsOf | Should -Be @(2)

        # The cause is gone: the same kind of run collects Sub X and clears the state.
        script:Set-WrapperScenario -Subs $Subs
        $R2 = script:Invoke-WrapperRun -Arguments $Route, '-Obfuscate'
        $R2.ExitCode | Should -Be 0
        $R2.Text | Should -Contain 'Processing subscription: Sub X (sub-x-not-readable)'
        $R2.Text | Should -Contain 'Resume state cleared (clean run).'
        Test-Path -LiteralPath $script:CaseState | Should -BeFalse
        @(script:Get-WrapperZipEntries | Where-Object { $_.Text.Contains('skipped by the up-front role check') -or $_.Name -like '*.resume-state*' } | ForEach-Object { '{0} {1}' -f $_.Zip, $_.Name }) | Should -BeNullOrEmpty
    }

    It 'does not put a subscription without a read role on the retry list' {
        script:Set-WrapperScenario -Subs $script:SubA, $script:SubX -Unreadable $script:SubX.Id
        $R = script:Invoke-WrapperRun
        $R.ExitCode | Should -Be 0
        $R.Text | Should -Contain 'Resume state cleared (clean run).'
        Test-Path -LiteralPath $script:CaseState | Should -BeFalse
    }

    It 'under -ResumeFailedOnly, says a later -Resume collects the subscriptions an unreadable per-stream file lists, and the next -Resume does' {
        $Subs = @($script:SubA, $script:SubB, $script:SubX)
        # Run 1, two streams: stream 0 completes Sub A, stream 1 fails Sub B, and
        # the session ends while Sub X is collected. Then the stream file that
        # names Sub B is cut short.
        script:Set-WrapperScenario -Subs $Subs -Fail $script:SubB.Id -Hang $script:SubX.Id
        $Run1 = script:Invoke-WrapperRun -Streams 2 -EndWhen { (Test-Path -LiteralPath (Join-Path $script:CaseHome ('waiting-' + $script:SubX.Id))) -and (@(script:Get-StreamCompletedIds) -join ',') -eq 'sub-a' -and @(script:Get-StreamStateFiles | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw).Contains('"sub-b"') }).Count -eq 1 }
        $Run1.Ended | Should -BeTrue
        $Cut = script:Set-StreamStateFileCutShort -Id $script:SubB.Id
        script:Set-WrapperScenario -Subs $Subs

        $R1 = script:Invoke-WrapperRun -Arguments '-ResumeFailedOnly'
        $R1.ExitCode | Should -Be 0
        $Warning = @($R1.Text | Where-Object { $_ -like 'WARNING: The per-stream state file *' })
        $Warning.Count | Should -Be 1
        $Warning[0] | Should -BeLike ('WARNING: The per-stream state file {0} from an interrupted parallel run could not be read, so its records are not used: the subscriptions it lists are not counted as completed and a later -Resume collects them (-ResumeFailedOnly retries only the retry list). It was moved aside to {0}.unreadable-*.' -f $Cut)
        $R1.Text | Should -Not -Contain 'Processing subscription: Sub B (sub-b)'
        # The retry list is empty (Sub B's failure was in the file put aside), so
        # the run ends early; it still says the run was not clean, and the state kept.
        @($R1.Text | Where-Object { $_ -like ('Resume state kept, but not a clean run: the per-stream state file {0} could not be read and was moved aside to {0}.unreadable-*; its records were not used.' -f $Cut) }).Count | Should -Be 1

        $R2 = script:Invoke-WrapperRun -Arguments '-Resume'
        $R2.ExitCode | Should -Be 0
        $R2.Text | Should -Contain 'Processing subscription: Sub B (sub-b)'
        $R2.Text | Should -Contain 'Processing subscription: Sub X (sub-x-not-readable)'
        @($R2.Text | Where-Object { $_ -like 'WARNING: The per-stream state file *' }) | Should -BeNullOrEmpty
    }

    It 'when a resume state file cannot be removed, names it, does not say the state was cleared, and the next -Resume clears everything' {
        $Subs = @($script:SubA, $script:SubB, $script:SubX)
        script:Set-WrapperScenario -Subs $Subs -Hang $script:SubX.Id
        $null = script:Invoke-WrapperRun -Streams 2 -EndWhen { (Test-Path -LiteralPath (Join-Path $script:CaseHome ('waiting-' + $script:SubX.Id))) -and (@(script:Get-StreamCompletedIds) -join ',') -eq 'sub-a,sub-b' }
        $StreamNames = @(script:Get-StreamStateFiles | ForEach-Object { $_.Name } | Sort-Object)
        $StreamNames.Count | Should -Be 2
        # The removal fails only where a read-only folder refuses writes: not for
        # root, and not on a file system that ignores folder modes. Check first.
        $Probe = Join-Path $script:CaseRoot '.write-probe'
        $Refused = $false
        [System.IO.File]::SetUnixFileMode($script:CaseRoot, [System.IO.UnixFileMode]'UserRead, UserExecute')
        try
        {
            [System.IO.File]::WriteAllText($Probe, 'probe')
            Remove-Item -LiteralPath $Probe -Force
        }
        catch { $Refused = $true }
        finally { [System.IO.File]::SetUnixFileMode($script:CaseRoot, [System.IO.UnixFileMode]'UserRead, UserWrite, UserExecute') }
        if (-not $Refused)
        {
            Remove-Item -LiteralPath $Probe -Force -ErrorAction SilentlyContinue
            Set-ItResult -Skipped -Because 'a read-only folder does not refuse writes here (running as root, or a file system that ignores folder modes)'
            return
        }
        # Sub X cannot be read, so nothing is left to collect. The inventory root
        # becomes read-only during the role check, so the removal at the end fails.
        script:Set-WrapperScenario -Subs $Subs -Unreadable $script:SubX.Id -LockRoot $script:SubX.Id
        try
        {
            $R1 = script:Invoke-WrapperRun -Arguments '-Resume' -Streams 2
        }
        finally
        {
            [System.IO.File]::SetUnixFileMode($script:CaseRoot, [System.IO.UnixFileMode]'UserRead, UserWrite, UserExecute')
        }
        $R1.ExitCode | Should -Be 0
        $R1.Text | Should -Not -Contain 'Resume state cleared (clean run).'
        foreach ($Name in $StreamNames)
        {
            @($R1.Text | Where-Object { $_ -like ('WARNING: Could not remove the per-stream state file {0}: *' -f $Name) }).Count | Should -Be 1
        }
        $R1.Text | Should -Contain ('  The resume state file {0} is kept, so the next -Resume reads the same state and the per-stream state file(s) above again. Once the folder can be written, remove the file(s) named above.' -f (Split-Path -Path $script:CaseState -Leaf))
        Test-Path -LiteralPath $script:CaseState | Should -BeTrue
        @(script:Get-StreamStateFiles | ForEach-Object { $_.Name } | Sort-Object) | Should -Be $StreamNames

        # The folder can be written again: the next -Resume finishes and clears everything.
        script:Set-WrapperScenario -Subs $Subs -Unreadable $script:SubX.Id
        $R2 = script:Invoke-WrapperRun -Arguments '-Resume' -Streams 2
        $R2.ExitCode | Should -Be 0
        @($R2.Text | Where-Object { $_ -like 'WARNING: Could not remove*' }) | Should -BeNullOrEmpty
        $R2.Text | Should -Contain 'Skipping (already completed): Sub A (sub-a)'
        $R2.Text | Should -Contain 'Skipping (already completed): Sub B (sub-b)'
        $R2.Text | Should -Contain 'Resume state cleared (clean run).'
        @(script:Get-StateFileNames) | Should -BeNullOrEmpty
    }
}
