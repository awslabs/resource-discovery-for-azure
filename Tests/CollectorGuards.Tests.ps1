#Requires -Version 7.0
# CollectorGuards.Tests.ps1
# OFFLINE unit tests for two collector guards: (1) an unparseable creation timestamp must fall back to the 'Unknown' sentinel, since a .NET cast throw is NOT suppressed by $ErrorActionPreference='SilentlyContinue'; (2) a Get-AzComputeResourceSku failure must leave the SKU map empty (vCPUs/RAM -> '0') yet still emit. Pester Mock resolves the command first, so the BeforeAll stubs the cmdlet when Az.Compute is absent.

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent

    # Only .Id / .Name are read off the subscription object by the collectors.
    $script:Sub = @([pscustomobject]@{ Id = 'sub1'; Name = 'Test Sub' })

    # Build a minimal ARM-graph-shaped resource. Property access in PowerShell is
    # case-insensitive, so a single 'PROPERTIES' / 'sku' covers the collectors'
    # mixed-case reads. Missing nested members read back as $null (no throw), so
    # only the field under test (plus any per-case Extra) needs populating.
    function New-Res
    {
        param([string]$Type, [hashtable]$Props, [string]$Name = 'res1', [string]$Id)
        if ([string]::IsNullOrEmpty($Id)) { $Id = "/subscriptions/sub1/resourceGroups/rg1/providers/$Type/$Name" }
        [pscustomobject]@{
            TYPE           = $Type
            id             = $Id
            name           = $Name
            RESOURCEGROUP  = 'rg1'
            LOCATION       = 'eastus'
            subscriptionId = 'sub1'
            sku            = $null
            tags           = $null
            zones          = @()
            PROPERTIES     = [pscustomobject]$Props
        }
    }

    # Invoke a collector by repo-relative path under Services/ using the fixed
    # 4-param contract, returning whatever objects it emits.
    function Invoke-Collector
    {
        param([string]$RelPath, $Resources)
        $Full = Join-Path $script:RepoRoot (Join-Path 'Services' $RelPath)
        & $Full -Sub $script:Sub -Resources $Resources -Task 'Processing' -ResourceIdDictionary $null
    }

    # Stub Get-AzComputeResourceSku ONLY when absent, so Pester Mock resolves even without Az.Compute and a real cmdlet is never shadowed where it IS present. [CmdletBinding()] so the collectors' '-ErrorAction Stop' binds.
    # Write-Warning BEFORE the throw is load-bearing: both callers catch the throw, so without the warning an unmocked stub failure would look exactly like the legitimate SKU-failure path (CPU/Memory '0') - a silent false PASS. They suppress DebugPreference, never WarningPreference.
    if (-not (Get-Command Get-AzComputeResourceSku -ErrorAction SilentlyContinue))
    {
        function Get-AzComputeResourceSku
        {
            [CmdletBinding()]
            param([string]$Location)
            Write-Warning 'Get-AzComputeResourceSku stub was INVOKED - the calling test forgot to Mock it, so this result is not trustworthy.'
            throw 'stub - should be mocked'
        }
    }
}

# One row per collector that carries a single 'CreatedTime' guard. Field = the
# PROPERTIES member the collector casts; Key = the emitted column to assert;
# Extra = any additional PROPERTIES a realistic resource of that type carries
# that the collector dereferences before/around the guard.
$script:DateCases = @(
    @{ Name = 'VirtualMachines'; Path = 'Compute/VirtualMachines.ps1'; Type = 'microsoft.compute/virtualmachines'; Field = 'timeCreated'; Key = 'CreatedTime'; Extra = @{ hardwareProfile = @{ vmSize = 'Standard_D2s_v3' } } }
    @{ Name = 'VMSS'; Path = 'Containers/VMSS.ps1'; Type = 'microsoft.compute/virtualmachinescalesets'; Field = 'timeCreated'; Key = 'CreatedTime'; Extra = @{} }
    @{ Name = 'Databricks'; Path = 'Analytics/Databricks.ps1'; Type = 'microsoft.databricks/workspaces'; Field = 'createdDateTime'; Key = 'CreatedTime'; Extra = @{} }
    @{ Name = 'MachineLearning'; Path = 'Analytics/MachineLearning.ps1'; Type = 'microsoft.machinelearningservices/workspaces'; Field = 'creationTime'; Key = 'CreatedTime'; Extra = @{} }
    @{ Name = 'WrkSpace'; Path = 'Analytics/WrkSpace.ps1'; Type = 'microsoft.operationalinsights/workspaces'; Field = 'createdDate'; Key = 'CreatedTime'; Extra = @{} }
    @{ Name = 'EvtHub'; Path = 'Analytics/EvtHub.ps1'; Type = 'microsoft.eventhub/namespaces'; Field = 'createdAt'; Key = 'CreatedTime'; Extra = @{} }
    @{ Name = 'Registries'; Path = 'Containers/REGISTRIES.ps1'; Type = 'microsoft.containerregistry/registries'; Field = 'creationDate'; Key = 'CreatedTime'; Extra = @{} }
    @{ Name = 'ServiceBus'; Path = 'Integration/ServiceBUS.ps1'; Type = 'microsoft.servicebus/namespaces'; Field = 'createdAt'; Key = 'CreatedTime'; Extra = @{} }
    @{ Name = 'AppInsights'; Path = 'Integration/AppInsights.ps1'; Type = 'microsoft.insights/components'; Field = 'CreationDate'; Key = 'CreatedTime'; Extra = @{} }
    @{ Name = 'StorageAcc'; Path = 'Storage/StorageAcc.ps1'; Type = 'microsoft.storage/storageaccounts'; Field = 'creationTime'; Key = 'CreatedTime'; Extra = @{} }
    @{ Name = 'VMDisk'; Path = 'Storage/VMDisk.ps1'; Type = 'microsoft.compute/disks'; Field = 'timeCreated'; Key = 'CreatedTime'; Extra = @{} }
    @{ Name = 'ComputeSnapshots'; Path = 'Storage/ComputeSnapshots.ps1'; Type = 'Microsoft.Compute/snapshots'; Field = 'timeCreated'; Key = 'CreatedTime'; Extra = @{} }
    @{ Name = 'Purview'; Path = 'Data/Purview.ps1'; Type = 'microsoft.purview/accounts'; Field = 'createdAt'; Key = 'CreatedTime'; Extra = @{} }
)

# Blank-timestamp cases: '' and '   ' pass the null check, throw on the [datetime] cast, and are caught ('Unknown'); $null instead hits the else branch (there the null check IS the guard). A NUMBER is deliberately unguarded/untested ([datetime]0 casts via ticks to a real date; ARM sends a string or omits the field).
# Built as a discovery-time cross-product, not a loop inside one It: a Pester Should throws, so a loop would abort on the first failing shape without evaluating the others or naming which broke.
$script:BlankCases = foreach ($Case in $script:DateCases)
{
    foreach ($Blank in @(
            @{ Label = 'null'; Value = $null }
            @{ Label = 'empty-string'; Value = '' }
            @{ Label = 'whitespace-only'; Value = '   ' }))
    {
        $Case + @{ BlankLabel = $Blank.Label; BlankValue = $Blank.Value }
    }
}

Describe 'Collector creation-time [datetime] cast guard' {

    BeforeAll {
        # Neutralise the VM/VMSS SKU lookup so these date-guard cases are offline
        # and fast; the SKU failure path has its own Describe below.
        Mock Get-AzComputeResourceSku { @() }
    }

    It '<Name>: a malformed <Field> yields the Unknown sentinel and does not throw' -ForEach $script:DateCases {
        $Res = New-Res -Type $Type -Props (@{ $Field = 'not-a-real-date' } + $Extra)
        $script:Emitted = $null
        { $script:Emitted = Invoke-Collector -RelPath $Path -Resources @($Res) } | Should -Not -Throw
        $Rec = @($script:Emitted)[0]
        $Rec | Should -Not -BeNullOrEmpty -Because 'the synthetic resource type must match so a record is emitted'
        $Rec[$Key] | Should -Be 'Unknown'
    }

    It '<Name>: a <BlankLabel> <Field> yields the Unknown sentinel and does not throw' -ForEach $script:BlankCases {
        $Res = New-Res -Type $Type -Props (@{ $Field = $BlankValue } + $Extra)
        $script:Emitted = $null
        { $script:Emitted = Invoke-Collector -RelPath $Path -Resources @($Res) } | Should -Not -Throw -Because "a $BlankLabel $Field must not abort the $Name collector"
        $Rec = @($script:Emitted)[0]
        $Rec | Should -Not -BeNullOrEmpty -Because "the $Name record must still be emitted with a $BlankLabel $Field"
        $Rec[$Key] | Should -Be 'Unknown' -Because "a $BlankLabel timestamp must degrade to the sentinel, not a bogus date"
    }

    It '<Name>: a valid <Field> is formatted (not the Unknown sentinel)' -ForEach $script:DateCases {
        $Res = New-Res -Type $Type -Props (@{ $Field = '2026-01-15T10:30:00Z' } + $Extra)
        $Rec = @(Invoke-Collector -RelPath $Path -Resources @($Res))[0]
        $Rec | Should -Not -BeNullOrEmpty
        $Rec[$Key] | Should -Not -Be 'Unknown'
        $Rec[$Key] | Should -Match '\d{4}' -Because 'a parsed timestamp renders with its year'
    }
}

Describe 'AutomationAcc dual creation-time / lastModifiedTime guards' {

    It 'malformed creationTime and lastModifiedTime both yield Unknown and do not throw' {
        $Acct = New-Res -Type 'microsoft.automation/automationaccounts' -Name 'acct1' -Props @{ creationTime = 'garbage'; State = 'Ok'; sku = @{ name = 'Basic' } }
        # Runbook id must have split('/')[8] == the account name for the collector to link it.
        $Rb = New-Res -Type 'microsoft.automation/automationaccounts/runbooks' -Name 'rb1' `
            -Id '/subscriptions/sub1/resourceGroups/rg1/providers/microsoft.automation/automationAccounts/acct1/runbooks/rb1' `
            -Props @{ lastModifiedTime = 'garbage'; state = 'Published'; runbookType = 'PowerShell'; description = 'd' }
        $script:Emitted = $null
        { $script:Emitted = Invoke-Collector -RelPath 'Infrastructure/AutomationAcc.ps1' -Resources @($Acct, $Rb) } | Should -Not -Throw
        $Rec = @($script:Emitted)[0]
        $Rec | Should -Not -BeNullOrEmpty
        $Rec['AutomationAccountCreatedTime'] | Should -Be 'Unknown'
        $Rec['LastModifiedTime'] | Should -Be 'Unknown'
    }

    It 'a <BlankLabel> creationTime and lastModifiedTime both yield Unknown and do not throw' -ForEach @(
        @{ BlankLabel = 'null'; BlankValue = $null }
        @{ BlankLabel = 'empty-string'; BlankValue = '' }
        @{ BlankLabel = 'whitespace-only'; BlankValue = '   ' }
    ) {
        # AutomationAcc is the only collector carrying the creation-time guard TWICE
        # (creationTime on the account, lastModifiedTime on the runbook), and it is
        # excluded from $script:DateCases because its record depends on nested-id
        # linking. Without these cases its blank shapes would be the one gap in the
        # coverage that answers finding #155.
        $Acct = New-Res -Type 'microsoft.automation/automationaccounts' -Name 'acct1' -Props @{ creationTime = $BlankValue; State = 'Ok'; sku = @{ name = 'Basic' } }
        $Rb = New-Res -Type 'microsoft.automation/automationaccounts/runbooks' -Name 'rb1' `
            -Id '/subscriptions/sub1/resourceGroups/rg1/providers/microsoft.automation/automationAccounts/acct1/runbooks/rb1' `
            -Props @{ lastModifiedTime = $BlankValue; state = 'Published'; runbookType = 'PowerShell'; description = 'd' }

        $script:Emitted = $null
        { $script:Emitted = Invoke-Collector -RelPath 'Infrastructure/AutomationAcc.ps1' -Resources @($Acct, $Rb) } | Should -Not -Throw -Because "a $BlankLabel timestamp must not abort the collector"
        $Rec = @($script:Emitted)[0]
        $Rec | Should -Not -BeNullOrEmpty -Because "the record must still be emitted with a $BlankLabel timestamp"
        $Rec['AutomationAccountCreatedTime'] | Should -Be 'Unknown' -Because "a $BlankLabel creationTime must degrade to the sentinel"
        $Rec['LastModifiedTime'] | Should -Be 'Unknown' -Because "a $BlankLabel lastModifiedTime must degrade to the sentinel"
    }

    It 'valid creationTime and lastModifiedTime are formatted (not Unknown)' {
        $Acct = New-Res -Type 'microsoft.automation/automationaccounts' -Name 'acct1' -Props @{ creationTime = '2026-01-15T10:30:00Z'; State = 'Ok'; sku = @{ name = 'Basic' } }
        $Rb = New-Res -Type 'microsoft.automation/automationaccounts/runbooks' -Name 'rb1' `
            -Id '/subscriptions/sub1/resourceGroups/rg1/providers/microsoft.automation/automationAccounts/acct1/runbooks/rb1' `
            -Props @{ lastModifiedTime = '2026-01-15T10:30:00Z'; state = 'Published'; runbookType = 'PowerShell'; description = 'd' }
        $Rec = @(Invoke-Collector -RelPath 'Infrastructure/AutomationAcc.ps1' -Resources @($Acct, $Rb))[0]
        $Rec['AutomationAccountCreatedTime'] | Should -Match '\d{4}'
        $Rec['LastModifiedTime'] | Should -Match '\d{4}'
    }
}

Describe 'Get-AzComputeResourceSku failure guard (VM / VMSS)' {

    BeforeAll {
        # Force the SKU API to fail deterministically. Should -Invoke below proves
        # the mock was actually reached, so a green result really means the
        # collector's try/catch swallowed a genuine throw (not that the call was
        # skipped).
        Mock Get-AzComputeResourceSku { throw 'simulated SKU API failure' }
    }

    It 'VirtualMachines: a SKU-API throw is caught - record still emitted, CPU/Memory fall back to 0' {
        $Res = New-Res -Type 'microsoft.compute/virtualmachines' -Props @{ timeCreated = '2026-01-15T10:30:00Z'; hardwareProfile = @{ vmSize = 'Standard_D2s_v3' } }
        $script:Emitted = $null
        { $script:Emitted = Invoke-Collector -RelPath 'Compute/VirtualMachines.ps1' -Resources @($Res) } | Should -Not -Throw
        Should -Invoke Get-AzComputeResourceSku -Times 1 -Because 'the failing SKU call must actually have been reached'
        $Rec = @($script:Emitted)[0]
        $Rec | Should -Not -BeNullOrEmpty
        $Rec['CPU'] | Should -Be '0'
        $Rec['Memory'] | Should -Be '0'
    }

    It 'VMSS: a SKU-API throw is caught - record still emitted, vCPUs/RAM fall back to 0' {
        $Res = New-Res -Type 'microsoft.compute/virtualmachinescalesets' -Props @{ timeCreated = '2026-01-15T10:30:00Z' }
        $Res.sku = [pscustomobject]@{ name = 'Standard_D2s_v3'; tier = 'Standard'; capacity = 2 }
        $script:Emitted = $null
        { $script:Emitted = Invoke-Collector -RelPath 'Containers/VMSS.ps1' -Resources @($Res) } | Should -Not -Throw
        Should -Invoke Get-AzComputeResourceSku -Times 1 -Because 'the failing SKU call must actually have been reached'
        $Rec = @($script:Emitted)[0]
        $Rec | Should -Not -BeNullOrEmpty
        $Rec['vCPUs'] | Should -Be '0'
        $Rec['RAM'] | Should -Be '0'
    }
}

Describe 'ARO worker-profile derivations' {
    # A cluster with two worker profiles of 3 nodes each: TotalWorkerNodes is the
    # SUM of the profiles' count values (6), never the number of profiles; and the
    # approved WorkerProfileCount column carries that number of profiles (2).
    It 'TotalWorkerNodes sums per-profile counts and WorkerProfileCount counts the profiles' {
        $Profiles = @(
            [pscustomobject]@{ name = 'w1'; count = 3; vmSize = 'Standard_D4s_v3' },
            [pscustomobject]@{ name = 'w2'; count = 3; vmSize = 'Standard_D8s_v3' }
        )
        $Res = New-Res -Type 'microsoft.redhatopenshift/openshiftclusters' -Props @{ workerProfiles = $Profiles }
        $Rec = @(Invoke-Collector -RelPath 'Compute/ARO.ps1' -Resources @($Res))[0]
        $Rec['TotalWorkerNodes'] | Should -Be 6
        $Rec['WorkerProfileCount'] | Should -Be 2
    }

    It 'a single 5-node profile reports 5 nodes, not 1' {
        $Res = New-Res -Type 'microsoft.redhatopenshift/openshiftclusters' -Props @{ workerProfiles = @([pscustomobject]@{ name = 'w1'; count = 5; vmSize = 'Standard_D4s_v3' }) }
        $Rec = @(Invoke-Collector -RelPath 'Compute/ARO.ps1' -Resources @($Res))[0]
        $Rec['TotalWorkerNodes'] | Should -Be 5
        $Rec['WorkerProfileCount'] | Should -Be 1
    }

    It 'no worker profiles yields 0 for both, not null' {
        $Res = New-Res -Type 'microsoft.redhatopenshift/openshiftclusters' -Props @{ workerProfiles = @() }
        $Rec = @(Invoke-Collector -RelPath 'Compute/ARO.ps1' -Resources @($Res))[0]
        $Rec['TotalWorkerNodes'] | Should -Be 0
        $Rec['WorkerProfileCount'] | Should -Be 0
    }
}
