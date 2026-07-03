# VM billing-coverage banner tests
# Run with: Invoke-Pester ./Tests/VmBillingGap.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# The inventory (ARM/Resource Graph) lists every VM that EXISTS; the consumption
# CSV lists VMs that produced a compute-usage record in the billing window. A
# running VM with no compute-usage record is an anomaly that usually means
# consumption data was incomplete for that VM's subscription. Summary.ps1
# cross-checks the count of running VMs against the count of distinct
# 'Virtual Machines'-meter resources in the consumption CSV and, when the
# running count materially exceeds the billed count, renders a coverage banner
# at the top of the report.
#
# This test is SELF-CONTAINED: it builds a tiny Inventory JSON and a tiny
# Consumption CSV in a temp dir, invokes the REAL Extension/Summary.ps1, and
# asserts the banner is present / absent / scoped correctly. No live Azure, no
# output zip. The comparison is count-level by design (the inventory and
# consumption files obfuscate resource ids through different dictionaries, so a
# per-VM join is impossible in an obfuscated report).

BeforeAll {
    $script:SummaryScript = Join-Path $PSScriptRoot '..' 'Extension' 'Summary.ps1' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("VmBillingGap_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null

    # Build an Inventory JSON with a controllable number of running/deallocated
    # VMs. Names use the obfuscated signature so the report's obfuscation
    # detection treats the run as obfuscated (the realistic shareable case).
    function New-TestInventory
    {
        param([int]$RunningVms, [int]$DeallocatedVms)

        $vms = @()
        for ($i = 0; $i -lt $RunningVms; $i++)
        {
            $vms += [pscustomobject]@{
                Name         = ('prod_{0}' -f [guid]::NewGuid())
                Subscription = ('prod_{0}' -f [guid]::NewGuid())
                Location     = 'eastus'
                Size         = 'Standard_D2s_v3'
                PowerState   = 'vm running'
            }
        }
        for ($i = 0; $i -lt $DeallocatedVms; $i++)
        {
            $vms += [pscustomobject]@{
                Name         = ('prod_{0}' -f [guid]::NewGuid())
                Subscription = ('prod_{0}' -f [guid]::NewGuid())
                Location     = 'eastus'
                Size         = 'Standard_D2s_v3'
                PowerState   = 'vm deallocated'
            }
        }
        return [pscustomobject]@{ VirtualMachines = $vms }
    }

    # Build a Consumption CSV with $BilledVms distinct 'Virtual Machines'-meter
    # resource ids (plus some non-VM rows that must be ignored).
    function New-TestConsumptionCsv
    {
        param([string]$Path, [int]$BilledVms)

        $rows = @()
        for ($i = 0; $i -lt $BilledVms; $i++)
        {
            $rid = ('prod_{0}' -f [guid]::NewGuid())
            # two rows per resource to prove DISTINCT counting
            $rows += [pscustomobject]@{ MeterCategory = 'Virtual Machines'; ResourceId = $rid }
            $rows += [pscustomobject]@{ MeterCategory = 'Virtual Machines'; ResourceId = $rid }
        }
        # Non-VM noise rows that must not be counted.
        $rows += [pscustomobject]@{ MeterCategory = 'Storage'; ResourceId = ('prod_{0}' -f [guid]::NewGuid()) }
        $rows += [pscustomobject]@{ MeterCategory = 'Bandwidth'; ResourceId = ('prod_{0}' -f [guid]::NewGuid()) }

        $rows | Select-Object MeterCategory, ResourceId | Export-Csv -Path $Path -Encoding utf8 -NoTypeInformation
    }

    function Invoke-Summary
    {
        param($Inventory, [string]$ConsumptionFile, [int]$Threshold = 0)

        $jsonPath = Join-Path $script:WorkDir ('inv_{0}.json' -f [guid]::NewGuid().ToString('N'))
        $htmlPath = Join-Path $script:WorkDir ('rpt_{0}.html' -f [guid]::NewGuid().ToString('N'))
        $Inventory | ConvertTo-Json -Depth 8 | Out-File -FilePath $jsonPath -Encoding utf8

        $params = @{ JsonFile = $jsonPath; HtmlFile = $htmlPath }
        if ($PSBoundParameters.ContainsKey('ConsumptionFile')) { $params['ConsumptionFile'] = $ConsumptionFile }
        if ($PSBoundParameters.ContainsKey('Threshold')) { $params['VmBillingGapThreshold'] = $Threshold }

        & $script:SummaryScript @params | Out-Null
        return (Get-Content -Path $htmlPath -Raw)
    }
}

AfterAll {
    if ($script:WorkDir -and (Test-Path $script:WorkDir))
    {
        Remove-Item -Path $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'VM billing-coverage banner' {

    It 'renders the banner when running VMs exceed billed VMs' {
        $inv = New-TestInventory -RunningVms 10 -DeallocatedVms 2
        $csv = Join-Path $script:WorkDir 'con_gap.csv'
        New-TestConsumptionCsv -Path $csv -BilledVms 4

        $html = Invoke-Summary -Inventory $inv -ConsumptionFile $csv

        # Assert on the rendered banner DIV's text, not the CSS class name
        # ('.coverage-banner' is always present in the <style> block).
        $html | Should -Match '<div class="coverage-banner">'
        $html | Should -Match 'VM billing-coverage check'
        # 10 running, 4 billed -> gap 6
        $html | Should -Match '10 running VMs'
        $html | Should -Match 'only 4 VMs'
        $html | Should -Match '6 running VMs'
    }

    It 'reports the gap percentage' {
        $inv = New-TestInventory -RunningVms 10 -DeallocatedVms 0
        $csv = Join-Path $script:WorkDir 'con_pct.csv'
        New-TestConsumptionCsv -Path $csv -BilledVms 4
        # gap 6 of 10 running = 60%
        $html = Invoke-Summary -Inventory $inv -ConsumptionFile $csv
        $html | Should -Match '60%'
    }

    It 'does NOT render the banner when billed matches running' {
        $inv = New-TestInventory -RunningVms 5 -DeallocatedVms 3
        $csv = Join-Path $script:WorkDir 'con_match.csv'
        New-TestConsumptionCsv -Path $csv -BilledVms 5

        $html = Invoke-Summary -Inventory $inv -ConsumptionFile $csv
        $html | Should -Not -Match '<div class="coverage-banner">'
        $html | Should -Not -Match 'VM billing-coverage check'
    }

    It 'does NOT render the banner when billed exceeds running (no negative gap)' {
        $inv = New-TestInventory -RunningVms 3 -DeallocatedVms 0
        $csv = Join-Path $script:WorkDir 'con_over.csv'
        New-TestConsumptionCsv -Path $csv -BilledVms 7

        $html = Invoke-Summary -Inventory $inv -ConsumptionFile $csv
        $html | Should -Not -Match '<div class="coverage-banner">'
        $html | Should -Not -Match 'VM billing-coverage check'
    }

    It 'does NOT render the banner when no ConsumptionFile is supplied' {
        $inv = New-TestInventory -RunningVms 10 -DeallocatedVms 0
        $html = Invoke-Summary -Inventory $inv
        $html | Should -Not -Match '<div class="coverage-banner">'
        $html | Should -Not -Match 'VM billing-coverage check'
    }

    It 'does NOT render the banner for a header-only (empty) consumption CSV' {
        $inv = New-TestInventory -RunningVms 10 -DeallocatedVms 0
        $csv = Join-Path $script:WorkDir 'con_empty.csv'
        'MeterCategory,ResourceId' | Out-File -FilePath $csv -Encoding utf8

        $html = Invoke-Summary -Inventory $inv -ConsumptionFile $csv
        $html | Should -Not -Match '<div class="coverage-banner">'
        $html | Should -Not -Match 'VM billing-coverage check'
    }

    It 'respects the VmBillingGapThreshold (suppresses small gaps)' {
        $inv = New-TestInventory -RunningVms 10 -DeallocatedVms 0
        $csv = Join-Path $script:WorkDir 'con_thresh.csv'
        New-TestConsumptionCsv -Path $csv -BilledVms 8   # gap = 2

        $html = Invoke-Summary -Inventory $inv -ConsumptionFile $csv -Threshold 5
        $html | Should -Not -Match '<div class="coverage-banner">'
        $html | Should -Not -Match 'VM billing-coverage check'
    }
}
