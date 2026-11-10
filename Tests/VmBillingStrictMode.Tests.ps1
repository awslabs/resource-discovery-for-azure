# Extension/Summary.ps1: the VM billing check under Set-StrictMode -Version
# Latest, which a caller's session can pass on. A billing file with rows but
# none for 'Virtual Machines' is a real zero and shows the banner, and an
# inventory with no VirtualMachines section renders (a missing section reads
# as an empty list). Offline; placeholder ids only.
#
# Run with: Invoke-Pester ./Tests/VmBillingStrictMode.Tests.ps1 -Output Detailed

BeforeAll {
    $script:SummaryScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'Extension/Summary.ps1'
    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('VmBillingStrict_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null
    function script:Invoke-StrictSummary
    {
        param($Inventory, $Rows)
        $Json = Join-Path $script:WorkDir ('inv_{0}.json' -f [guid]::NewGuid().ToString('N'))
        $Html = Join-Path $script:WorkDir ('rpt_{0}.html' -f [guid]::NewGuid().ToString('N'))
        $Csv = Join-Path $script:WorkDir ('con_{0}.csv' -f [guid]::NewGuid().ToString('N'))
        $Inventory | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Json -Encoding utf8
        @($Rows) | Export-Csv -LiteralPath $Csv -Encoding utf8 -NoTypeInformation
        & {
            Set-StrictMode -Version Latest
            & $script:SummaryScript -JsonFile $Json -HtmlFile $Html -ConsumptionFile $Csv | Out-Null
        }
        Get-Content -LiteralPath $Html -Raw
    }
}

AfterAll { Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'The VM billing check under Set-StrictMode -Version Latest' {
    It 'shows the banner for a running VM when the billing file has rows but none for Virtual Machines' {
        $Inv = [pscustomobject]@{ Version = 'test'; VirtualMachines = @([pscustomobject]@{ Name = 'prod_0f8fad5b-d9cb-469f-a165-70867728950e'; Subscription = 'prod_1f8fad5b-d9cb-469f-a165-70867728950e'; PowerState = 'vm running' }) }
        $Html = script:Invoke-StrictSummary -Inventory $Inv -Rows @([pscustomobject]@{ MeterCategory = 'Storage'; ResourceId = 'prod_2f8fad5b-d9cb-469f-a165-70867728950e' })
        $Html | Should -Match '<div class="coverage-banner">'
    }

    It 'renders an inventory with no VirtualMachines section' {
        $Inv = [pscustomobject]@{ Version = 'test'; StorageAcc = @([pscustomobject]@{ Name = 'prod_3f8fad5b-d9cb-469f-a165-70867728950e'; Subscription = 'prod_1f8fad5b-d9cb-469f-a165-70867728950e' }) }
        $Html = script:Invoke-StrictSummary -Inventory $Inv -Rows @([pscustomobject]@{ MeterCategory = 'Storage'; ResourceId = 'prod_2f8fad5b-d9cb-469f-a165-70867728950e' })
        $Html | Should -Match '<html'
        $Html | Should -Not -Match '<div class="coverage-banner">'
    }
}
