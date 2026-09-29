# Subscription-label tests for the HTML report header.
#
# ResourceInventory.ps1 never passes -SubscriptionName, so Summary.ps1's fallback always decides the
# header. Its documented default usage (no -SubscriptionID) runs an UNSCOPED Resource Graph query and
# consolidates every readable subscription into one report, and the fallback used to name whichever
# subscription owned the first record of whichever service happened to be largest. Reproduced live on
# a multi-subscription tenant: a report was labelled with the subscription contributing a single
# resource, and adding one resource elsewhere could relabel the whole report.

BeforeAll {
    $script:SummaryScript = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'Extension', 'Summary.ps1' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("SummarySubLabel_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null

    # Builds an Inventory JSON holding a StorageAcc service and an optional VirtualMachines service,
    # preserving the record order given. Each call site chooses the shape it needs; the shape that
    # produced the wrong label is described at its own test.
    function script:New-LabelInventory
    {
        param([string[]]$StorageSubs, [string[]]$VmSubs)

        $Inv = [ordered]@{ Version = '9.9.9' }
        if ($StorageSubs.Count -gt 0)
        {
            $Inv['StorageAcc'] = @($StorageSubs | ForEach-Object {
                    [pscustomobject]@{ Subscription = $_; ResourceGroup = 'rg'; Name = 'sa'; Location = 'westeurope' }
                })
        }
        if ($VmSubs.Count -gt 0)
        {
            $Inv['VirtualMachines'] = @($VmSubs | ForEach-Object {
                    [pscustomobject]@{ Subscription = $_; ResourceGroup = 'rg'; Name = 'vm'; Location = 'westeurope' }
                })
        }
        $Path = Join-Path $script:WorkDir ("inv_" + [guid]::NewGuid().ToString('N') + ".json")
        [pscustomobject]$Inv | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $Path -Encoding utf8
        return $Path
    }

    function script:Get-ReportHtml
    {
        param([string]$JsonPath)
        $HtmlPath = Join-Path $script:WorkDir ("rep_" + [guid]::NewGuid().ToString('N') + ".html")
        & $script:SummaryScript -JsonFile $JsonPath -HtmlFile $HtmlPath -Version '9.9.9' | Out-Null
        return (Get-Content -LiteralPath $HtmlPath -Raw)
    }

    # The rendered markup is '<div><b>Subscription:</b> $SubSafe</div>', so every positive anchors on
    # the closing tag: unanchored, 'Only Sub' would also match 'Only Sub and 2 others'.
    function script:Get-HeaderLabel
    {
        param([string]$Html)
        $M = [regex]::Match($Html, '<b>Subscription:</b>([^<]*)</div>')
        if (-not $M.Success) { throw 'the report has no <b>Subscription:</b> header div; the markup this suite binds on has changed' }
        return $M.Groups[1].Value.Trim()
    }
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
    {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'The report header never names one subscription for a consolidated report' {
    It 'reports the COUNT when records span more than one subscription' {
        # StorageAcc is the largest service here and its FIRST record is the subscription contributing
        # exactly 1 of the 6 resources, which is the shape the old fallback mislabelled.
        $Json = script:New-LabelInventory -StorageSubs @('Small Sub', 'Big Sub', 'Big Sub', 'Big Sub') -VmSubs @('Big Sub', 'Big Sub')
        $Html = script:Get-ReportHtml -JsonPath $Json

        script:Get-HeaderLabel -Html $Html | Should -BeExactly '2 subscriptions (consolidated)'
        # Nothing is lost by not naming them in the header: the per-resource column still carries which
        # resource belongs to which subscription, and that is the claim the fix rests on.
        $Html | Should -Match 'Small Sub'
        $Html | Should -Match 'Big Sub'
    }

    It 'scales the count to however many subscriptions are present' {
        $Json = script:New-LabelInventory -StorageSubs @('S1', 'S2', 'S3', 'S4') -VmSubs @()
        script:Get-HeaderLabel -Html (script:Get-ReportHtml -JsonPath $Json) | Should -BeExactly '4 subscriptions (consolidated)'
    }

    It 'still names the subscription when the run covered exactly one (the wrapper case)' {
        # The wrapper scopes every invocation to one subscription, so this is the common path and it
        # must be unchanged: a count here would be a regression, not a fix.
        $Json = script:New-LabelInventory -StorageSubs @('Only Sub', 'Only Sub') -VmSubs @('Only Sub')
        $Html = script:Get-ReportHtml -JsonPath $Json

        script:Get-HeaderLabel -Html $Html | Should -BeExactly 'Only Sub'
        # Unanchored on purpose: $SubSafe also lands in '<title>...</title>', so this catches a count
        # leaking into the title as well as into the header.
        $Html | Should -Not -Match 'subscriptions \(consolidated\)'
    }

    It 'treats subscription names case-insensitively, so casing drift is not a second subscription' {
        $Json = script:New-LabelInventory -StorageSubs @('Only Sub', 'ONLY SUB', 'only sub') -VmSubs @()
        $Html = script:Get-ReportHtml -JsonPath $Json

        # An ordinal comparer would count 3 here and render the consolidated label.
        script:Get-HeaderLabel -Html $Html | Should -BeExactly 'Only Sub'
        $Html | Should -Not -Match 'subscriptions \(consolidated\)'
    }

    It 'ignores a blank subscription beside a populated one rather than counting it' {
        $Path = Join-Path $script:WorkDir 'inv_blank.json'
        [pscustomobject]@{
            Version    = '9.9.9'
            StorageAcc = @(
                [pscustomobject]@{ Subscription = 'Only Sub'; ResourceGroup = 'rg'; Name = 'sa1'; Location = 'westeurope' }
                [pscustomobject]@{ Subscription = '       '; ResourceGroup = 'rg'; Name = 'sa2'; Location = 'westeurope' }
                [pscustomobject]@{ ResourceGroup = 'rg'; Name = 'sa3'; Location = 'westeurope' }
            )
        } | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $Path -Encoding utf8

        script:Get-HeaderLabel -Html (script:Get-ReportHtml -JsonPath $Path) | Should -BeExactly 'Only Sub'
    }

    It 'falls back to (unknown) when no record carries a subscription' {
        $Path = Join-Path $script:WorkDir 'inv_nosub.json'
        [pscustomobject]@{
            Version    = '9.9.9'
            StorageAcc = @([pscustomobject]@{ ResourceGroup = 'rg'; Name = 'sa'; Location = 'westeurope' })
        } | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $Path -Encoding utf8

        script:Get-HeaderLabel -Html (script:Get-ReportHtml -JsonPath $Path) | Should -BeExactly '(unknown)'
    }

    It 'an explicit -SubscriptionName still wins over the fallback' {
        $Json = script:New-LabelInventory -StorageSubs @('S1', 'S2') -VmSubs @()
        $HtmlPath = Join-Path $script:WorkDir 'rep_explicit.html'
        & $script:SummaryScript -JsonFile $Json -HtmlFile $HtmlPath -Version '9.9.9' -SubscriptionName 'Chosen By Caller' | Out-Null

        script:Get-HeaderLabel -Html (Get-Content -LiteralPath $HtmlPath -Raw) | Should -BeExactly 'Chosen By Caller'
    }

    It 'renders the count, and no token, for an OBFUSCATED consolidated inventory' {
        # Under -Obfuscate the Subscription values are prod_/nonprod_ tokens. A count is the right
        # header there, and this pins the claim that the change leaks nothing new: neither the header
        # div nor the <title> may carry a token. These shapes also trip the obfuscation sampler, so
        # the report renders in its obfuscated posture rather than the identifiable one.
        $T1 = 'prod_11111111-1111-1111-1111-111111111111'
        $T2 = 'nonprod_22222222-2222-2222-2222-222222222222'
        $Json = script:New-LabelInventory -StorageSubs @($T1, $T2, $T2) -VmSubs @()
        $Html = script:Get-ReportHtml -JsonPath $Json

        script:Get-HeaderLabel -Html $Html | Should -BeExactly '2 subscriptions (consolidated)'
        $Title = ([regex]::Match($Html, '<title>([^<]*)</title>')).Groups[1].Value
        $Title | Should -Not -Match 'prod_'
        $Title | Should -Match '2 subscriptions \(consolidated\)'
    }

    It 'the label is stable whatever order the records arrive in' {
        # The defect was order-dependence: the label was whichever record happened to be first. Both
        # sides are asserted against the expected value, not only against each other, so an extraction
        # that stopped matching cannot make this pass.
        $A = script:Get-HeaderLabel -Html (script:Get-ReportHtml -JsonPath (script:New-LabelInventory -StorageSubs @('Small Sub', 'Big Sub', 'Big Sub') -VmSubs @()))
        $B = script:Get-HeaderLabel -Html (script:Get-ReportHtml -JsonPath (script:New-LabelInventory -StorageSubs @('Big Sub', 'Big Sub', 'Small Sub') -VmSubs @()))

        $A | Should -BeExactly '2 subscriptions (consolidated)'
        $B | Should -BeExactly '2 subscriptions (consolidated)'
        $A | Should -BeExactly $B
    }
}
