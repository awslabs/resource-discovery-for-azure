# Collector-failure banner tests
# Run with: Invoke-Pester ./Tests/CollectorFailureBanner.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# When a Services/*/*.ps1 collector throws, ResourceInventory.ps1 logs the
# error and carries on. The failed type serialises as an empty array, so its
# section is dropped from the HTML report, which then reads the same as a
# subscription that has none of that type. Summary.ps1 takes this run's
# collector failures (-CollectorFailures) and names the missing types in a
# banner at the top of the report and in a console line at the end of its
# output.
#
# This test is SELF-CONTAINED: it builds a tiny Inventory JSON in a temp dir,
# invokes the REAL Extension/Summary.ps1, and asserts on the written HTML and
# the console output. No live Azure, no output zip. Generic names only.

BeforeAll {
    $script:SummaryScript = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'Extension', 'Summary.ps1' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("CollectorFailureBanner_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null

    # Two populated service types, so the report renders normally around the
    # banner. The VMSS key is an empty array, which is how a failed collector's
    # type reaches the Inventory JSON.
    $script:Inventory = [pscustomobject]@{
        StorageAcc = @(
            [pscustomobject]@{ Name = 'storage-demo-01'; Subscription = 'sub-demo'; Location = 'eastus'; ResourceGroup = 'rg-demo' },
            [pscustomobject]@{ Name = 'storage-demo-02'; Subscription = 'sub-demo'; Location = 'eastus'; ResourceGroup = 'rg-demo' }
        )
        KeyVault   = @(
            [pscustomobject]@{ Name = 'kv-demo-01'; Subscription = 'sub-demo'; Location = 'eastus'; ResourceGroup = 'rg-demo' }
        )
        VMSS       = @()
    }

    function New-Failure
    {
        param($Module, [string]$Message = 'collector error')
        [pscustomobject]@{ Id = '12345678-1234-1234-1234-123456789012'; Module = $Module; Message = $Message }
    }

    # Runs Summary.ps1 and returns the HTML plus the console lines it wrote.
    # -CollectorFailures is passed only when the caller supplies it, so the
    # omitted case is the standalone invocation.
    function Invoke-Summary
    {
        param($CollectorFailures)

        $JsonPath = Join-Path $script:WorkDir ('inv_{0}.json' -f [guid]::NewGuid().ToString('N'))
        $HtmlPath = Join-Path $script:WorkDir ('rpt_{0}.html' -f [guid]::NewGuid().ToString('N'))
        $script:Inventory | ConvertTo-Json -Depth 8 | Out-File -FilePath $JsonPath -Encoding utf8

        $Params = @{ JsonFile = $JsonPath; HtmlFile = $HtmlPath }
        if ($PSBoundParameters.ContainsKey('CollectorFailures')) { $Params['CollectorFailures'] = $CollectorFailures }

        $Console = @(& $script:SummaryScript @Params 6>&1 | ForEach-Object { [string]$_ })
        return [pscustomobject]@{
            Html    = (Get-Content -Path $HtmlPath -Raw)
            Console = $Console
        }
    }
}

AfterAll {
    if ($script:WorkDir -and (Test-Path $script:WorkDir))
    {
        Remove-Item -Path $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Collector-failure banner in the HTML report' {

    It 'names the failed resource type when one collector failed' {
        $R = Invoke-Summary -CollectorFailures @(New-Failure -Module 'VMSS')

        # Assert on the rendered banner text, not the CSS class name
        # ('.coverage-banner' is always present in the <style> block).
        $R.Html | Should -Match '<b>Incomplete collection:</b> 1 resource type\(s\) could not be collected and are MISSING from this report'
        $R.Html | Should -Match 'the collector errored: <code>VMSS</code>\.'
        $R.Html | Should -Match '<b>Service Types:</b> 2 <span class="incomplete-note">\(collection incomplete, see below\)</span>'
    }

    It 'lists each failed type once, sorted, when several failed' {
        $Failures = @(
            (New-Failure -Module 'VMSS'),
            (New-Failure -Module 'AKS'),
            (New-Failure -Module 'VMSS')
        )
        $R = Invoke-Summary -CollectorFailures $Failures

        $R.Html | Should -Match '<b>Incomplete collection:</b> 2 resource type\(s\)'
        $R.Html | Should -Match 'the collector errored: <code>AKS</code>, <code>VMSS</code>\.'
    }

    It 'still shows the banner for a failure record with no collector name' {
        $R = Invoke-Summary -CollectorFailures @(New-Failure -Module '  ')

        $R.Html | Should -Match '<b>Incomplete collection:</b> 1 resource type\(s\)'
        $R.Html | Should -Match '<code>\(unnamed collector\)</code>'
    }

    It 'HTML-escapes the collector name' {
        $R = Invoke-Summary -CollectorFailures @(New-Failure -Module '<b>x</b>')

        $R.Html | Should -Match '<code>&lt;b&gt;x&lt;/b&gt;</code>'
    }

    It 'renders no banner when -CollectorFailures is omitted' {
        $R = Invoke-Summary

        $R.Html | Should -Not -Match 'Incomplete collection'
        $R.Html | Should -Not -Match '<span class="incomplete-note">'
    }

    It 'renders no banner when the failure list is empty or holds only nulls' {
        $Empty = Invoke-Summary -CollectorFailures @()
        $Empty.Html | Should -Not -Match 'Incomplete collection'
        $Empty.Html | Should -Not -Match '<span class="incomplete-note">'

        $NullOnly = Invoke-Summary -CollectorFailures @($null)
        $NullOnly.Html | Should -Not -Match 'Incomplete collection'
        $NullOnly.Html | Should -Not -Match '<span class="incomplete-note">'
    }
}

Describe 'Collector-failure line in the console output' {

    It 'ends the summary output with a line naming the failed types' {
        $R = Invoke-Summary -CollectorFailures @((New-Failure -Module 'VMSS'), (New-Failure -Module 'AKS'))

        $R.Console[-1] | Should -Be '  Collection INCOMPLETE: 2 resource type(s) missing because the collector errored: AKS, VMSS'
        ($R.Console | Where-Object { $_ -match '^  Total resources:' }) | Should -Not -BeNullOrEmpty
    }

    It 'writes no such line when nothing failed' {
        $R = Invoke-Summary -CollectorFailures @()

        ($R.Console | Where-Object { $_ -match 'Collection INCOMPLETE' }) | Should -BeNullOrEmpty
    }
}
