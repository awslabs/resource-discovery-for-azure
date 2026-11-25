# Report cell cut tests (Extension/Summary.ps1)
# Run with: Invoke-Pester ./Tests/ReportCellCut.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# The HTML report shows at most 200 characters of a cell, then '...'. In an
# obfuscated report a masked id can be longer than that (a disk's
# AssociatedResource is the full masked id of its VM), and a cut through the
# last masked token left a piece of it that Reveal.ps1 cannot match, so it
# stayed masked in the revealed HTML. In an obfuscated report a cut that would
# split a masked token now ends after the token, and a value whose cut reaches
# its end is shown whole. Other reports are cut at 200 characters as before.
#
# The test renders synthetic inventories with the REAL Extension/Summary.ps1
# and reads the cells. The masked tokens are made at runtime; no real data.

BeforeAll {
    $script:Summary = Join-Path (Split-Path $PSScriptRoot -Parent) 'Extension/Summary.ps1'
    $script:Sub = '12345678-1234-1234-1234-123456789012'   # Azure docs placeholder

    function New-Token { param([string]$Prefix = 'prod_') $Prefix + [guid]::NewGuid().ToString() }

    # Renders one inventory (collector name -> records) and returns the HTML.
    function Get-ReportHtml
    {
        param([hashtable]$Inventory)
        $Dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $Json = Join-Path $Dir 'Inventory_Test.json'
        $Html = Join-Path $Dir 'Report_Test.html'
        ($Inventory + @{ Version = '1.0.0' }) | ConvertTo-Json -Depth 6 | Set-Content -Path $Json -Encoding utf8
        & $script:Summary -JsonFile $Json -HtmlFile $Html *> $null
        return (Get-Content -Raw -Path $Html)
    }

    # A long value whose masked token starts before character 200 and ends after it.
    $script:Head = 'a' * 170 + '/'
    $script:Crossing = New-Token 'nonprod_'
    $script:CrossingRg = New-Token 'prod_rg_mc_'
    $script:EndsAt200 = 'b' * 159 + (New-Token)
    $script:NoToken = 'c' * 260

    function New-Records
    {
        param([scriptblock]$Name, [scriptblock]$Subscription)
        @(
            [ordered]@{ Name = (& $Name 1); Subscription = (& $Subscription); Ref = ($script:Head + $script:Crossing) }
            [ordered]@{ Name = (& $Name 2); Subscription = (& $Subscription); Ref = ($script:Head + $script:Crossing + '/tail') }
            [ordered]@{ Name = (& $Name 3); Subscription = (& $Subscription); Ref = ($script:EndsAt200 + '/zz') }
            [ordered]@{ Name = (& $Name 4); Subscription = (& $Subscription); Ref = $script:NoToken }
            [ordered]@{ Name = (& $Name 5); Subscription = (& $Subscription); Ref = @(('d' * 180), ('/' + $script:CrossingRg + '/x')) }
        )
    }

    $SubToken = New-Token
    $script:Obfuscated = Get-ReportHtml @{ Demo = @(New-Records -Name { New-Token } -Subscription { $SubToken }) }
    $script:Plain = Get-ReportHtml @{ Demo = @(New-Records -Name { param($n) "res-$n" } -Subscription { 'Demo Subscription' }) }
}

Describe 'Summary.ps1 cuts a long cell of an obfuscated report' {
    It 'is rendered as an obfuscated report' {
        $script:Obfuscated | Should -Match 'privacy-banner obfuscated'
    }

    It 'shows a value whole when the token its cut would split runs to its end' {
        $script:Obfuscated.Contains('<td>' + $script:Head + $script:Crossing + '</td>') | Should -BeTrue
    }

    It 'ends the cut after the token it would split, then ''...''' {
        $script:Obfuscated.Contains('<td>' + $script:Head + $script:Crossing + '...</td>') | Should -BeTrue
    }

    It 'keeps the 200-character cut when a token ends exactly there' {
        $script:Obfuscated.Contains('<td>' + $script:EndsAt200 + '...</td>') | Should -BeTrue
    }

    It 'keeps the 200-character cut of a value with no token' {
        $script:Obfuscated.Contains('<td>' + ('c' * 200) + '...</td>') | Should -BeTrue
    }

    It 'ends the cut of a list cell after a token with two hint words (an AKS ''mc_'' group)' {
        $script:Obfuscated.Contains('<td>' + ('d' * 180) + ', /' + $script:CrossingRg + '...</td>') | Should -BeTrue
    }
}

Describe 'Summary.ps1 cuts a long cell of a report that is not obfuscated' {
    It 'is rendered as an identifiable report' {
        $script:Plain | Should -Match 'privacy-banner identifiable'
    }

    It 'cuts every long value at 200 characters, as before, even through a token-shaped text' {
        $Values = @(($script:Head + $script:Crossing), ($script:Head + $script:Crossing + '/tail'), ($script:EndsAt200 + '/zz'), $script:NoToken, (('d' * 180) + ', /' + $script:CrossingRg + '/x'))
        foreach ($Value in $Values)
        {
            $script:Plain.Contains('<td>' + $Value.Substring(0, 200) + '...</td>') | Should -BeTrue -Because "'$($Value.Substring(0, 30))...' should be cut at 200"
        }
    }
}
