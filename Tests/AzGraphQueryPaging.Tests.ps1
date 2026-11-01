# Requires -Modules Pester
# =============================================================================
# AzGraphQueryPaging.Tests.ps1
#
# Unit tests for what Invoke-AzGraphQuerySafe (Functions/ResourceInventory.
# Functions.ps1) returns from Resource Graph through Invoke-AzRestMethod: the
# result shape the inventory reads (.data rows, their count and order), skip
# token paging, explicit subscription batches of at most 1000, the -Lowercase
# behaviour (culture-invariant, a row that cannot be lowercased kept as
# returned) and resources with an empty-string property key.
#
# WHY THIS TEST EXISTS
# --------------------
# The inventory used to read these results from `az graph query`. The REST
# call must hand the callers and collectors the same data: one PSCustomObject
# per row in .data, no phantom row for an empty answer, every page of a large
# answer, and every subscription of a tenant that has more than 1000.
# PowerShell 7's ConvertFrom-Json cannot make an object with an empty-string
# property name ("": ...), which user-authored definitions (Logic Apps,
# policies, templates) can hold; such a resource must still be returned, with
# the key renamed to '_rda_emptykey', rather than failing the subscription.
#
# No live Azure: Invoke-AzRestMethod is mocked with canned responses.
# Run with: Invoke-Pester ./Tests/AzGraphQueryPaging.Tests.ps1 -Output Detailed
# =============================================================================

BeforeAll {
    $FunctionsFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/ResourceInventory.Functions.ps1'
    if (-not (Test-Path $FunctionsFile)) { throw "ResourceInventory.Functions.ps1 not found at $FunctionsFile" }
    . $FunctionsFile

    function Invoke-AzRestMethod { param($Method, $Path, $Payload, $Uri) }

    $script:Sub = '12345678-1234-1234-1234-123456789012'

    function New-GraphResponse
    {
        param([object[]]$Rows = @(), [string]$SkipToken, [string]$Content)
        if (-not $PSBoundParameters.ContainsKey('Content'))
        {
            $Body = [ordered]@{ totalRecords = $Rows.Count; count = $Rows.Count; data = @($Rows); facets = @(); resultTruncated = 'false' }
            if ($SkipToken) { $Body['$skipToken'] = $SkipToken }
            $Content = $Body | ConvertTo-Json -Depth 10 -Compress
        }
        [pscustomobject]@{ StatusCode = 200; Content = $Content; Headers = @{} }
    }

    function New-Row([int]$N, [string]$Sub = $script:Sub)
    {
        [ordered]@{ id = ('/subscriptions/{0}/resourceGroups/RG/providers/Microsoft.Network/networkSecurityGroups/NSG-{1:d5}' -f $Sub, $N); name = ('NSG-{0:d5}' -f $N); type = 'Microsoft.Network/networkSecurityGroups'; subscriptionId = $Sub }
    }

    Mock -CommandName Start-Sleep -MockWith { }
}

Describe 'Invoke-AzGraphQuerySafe result shape' {

    It 'returns no rows and a zero count for an empty answer (no phantom row)' {
        Mock -CommandName Invoke-AzRestMethod -MockWith { New-GraphResponse -Rows @() }

        $Result = Invoke-AzGraphQuerySafe -Query 'resources' -SubscriptionId $script:Sub
        @($Result.data).Count | Should -Be 0
        $Result.count | Should -Be 0
        $Result.total_records | Should -Be 0
    }

    It 'returns one PSCustomObject for a one-row answer' {
        Mock -CommandName Invoke-AzRestMethod -MockWith { New-GraphResponse -Rows @((New-Row 1)) }

        $Result = Invoke-AzGraphQuerySafe -Query 'resources' -SubscriptionId $script:Sub
        @($Result.data).Count | Should -Be 1
        $Result.count | Should -Be 1
        $Result.data[0] | Should -BeOfType [pscustomobject]
        $Result.data[0].name | Should -Be 'NSG-00001'
    }

    It 'returns the count probe row the inventory reads (.data.count_)' {
        Mock -CommandName Invoke-AzRestMethod -MockWith { New-GraphResponse -Rows @(@{ count_ = 1234 }) }

        $Result = Invoke-AzGraphQuerySafe -Query 'resources | summarize count()' -SubscriptionId $script:Sub
        $Result.data.count_ | Should -Be 1234
        Get-AzGraphCount -Result $Result | Should -Be 1234
    }

    It 'counts 0 when the count probe has no rows' {
        Get-AzGraphCount -Result ([pscustomobject]@{ data = @() }) | Should -Be 0
    }

    It 'stops on a count that is not a whole number of 0 or more (<Value>), instead of reading it as 0' -ForEach @(@{ Value = 'not-a-number' }, @{ Value = '1.5' }, @{ Value = -5 }) {
        $Result = [pscustomobject]@{ data = @([pscustomobject]@{ count_ = 7 }, [pscustomobject]@{ count_ = $Value }) }
        { Get-AzGraphCount -Result $Result } | Should -Throw -ExpectedMessage 'Resource Graph returned a count (count_, a *) that is not a whole number of 0 or more.'
    }

    It 'stops under the inventory''s SilentlyContinue too, for a count that is not a number' {
        $Result = [pscustomobject]@{ data = @([pscustomobject]@{ count_ = 'not-a-number' }) }
        { $ErrorActionPreference = 'SilentlyContinue'; Get-AzGraphCount -Result $Result } | Should -Throw -ExpectedMessage 'Resource Graph returned a count (count_, a String) that is not a whole number of 0 or more.'
    }

    It 'adds a whole number given as text' {
        Get-AzGraphCount -Result ([pscustomobject]@{ data = @([pscustomobject]@{ count_ = '12' }, [pscustomobject]@{ count_ = 3 }) }) | Should -Be 15
    }

    It 'sends the subscriptions, the query and an object-array page of 1000 rows' {
        $script:Bodies = [System.Collections.Generic.List[object]]::new()
        Mock -CommandName Invoke-AzRestMethod -MockWith { $script:Bodies.Add(($Payload | ConvertFrom-Json)); New-GraphResponse -Rows @() }

        Invoke-AzGraphQuerySafe -Query 'resources | project id' -SubscriptionId $script:Sub | Out-Null
        $script:Bodies.Count | Should -Be 1
        @($script:Bodies[0].subscriptions) | Should -Be @($script:Sub)
        $script:Bodies[0].query | Should -Be 'resources | project id'
        $script:Bodies[0].options.resultFormat | Should -Be 'objectArray'
        $script:Bodies[0].options.'$top' | Should -Be 1000
        $script:Bodies[0].options.PSObject.Properties.Name | Should -Not -Contain '$skipToken'
    }

    It 'makes no request and returns no rows when there is no subscription to query' {
        Mock -CommandName Invoke-AzRestMethod -MockWith { throw 'no request expected' }

        $Result = Invoke-AzGraphQuerySafe -Query 'resources' -SubscriptionId @()
        @($Result.data).Count | Should -Be 0
        Should -Invoke -CommandName Invoke-AzRestMethod -Exactly -Times 0
    }
}

Describe 'Invoke-AzGraphQuerySafe paging' {

    It 'follows the skip token over 3 pages and returns all 2500 rows in order' {
        $script:Tokens = [System.Collections.Generic.List[string]]::new()
        Mock -CommandName Invoke-AzRestMethod -MockWith {
            $Token = [string](($Payload | ConvertFrom-Json).options.'$skipToken')
            $script:Tokens.Add($Token)
            switch ($Token)
            {
                '' { New-GraphResponse -Rows @(1..1000 | ForEach-Object { New-Row $_ }) -SkipToken 'PAGE2-Token+/=' }
                'PAGE2-Token+/=' { New-GraphResponse -Rows @(1001..2000 | ForEach-Object { New-Row $_ }) -SkipToken 'PAGE3' }
                'PAGE3' { New-GraphResponse -Rows @(2001..2500 | ForEach-Object { New-Row $_ }) }
                default { throw "unexpected skip token $Token" }
            }
        }

        $Result = Invoke-AzGraphQuerySafe -Query 'resources | order by id asc' -SubscriptionId $script:Sub -Lowercase
        @($Result.data).Count | Should -Be 2500
        $Result.count | Should -Be 2500
        $Result.data[0].name | Should -Be 'nsg-00001'
        $Result.data[999].name | Should -Be 'nsg-01000'
        $Result.data[1000].name | Should -Be 'nsg-01001'
        $Result.data[2499].name | Should -Be 'nsg-02500'
        @($script:Tokens) | Should -Be @('', 'PAGE2-Token+/=', 'PAGE3') -Because 'the skip token is sent back exactly, never lowercased'
    }

    It 'fails instead of looping when Azure hands back the same skip token again' {
        $script:Calls = 0
        Mock -CommandName Invoke-AzRestMethod -MockWith { $script:Calls++; New-GraphResponse -Rows @((New-Row $script:Calls)) -SkipToken 'same' }

        { Invoke-AzGraphQuerySafe -Query 'resources' -SubscriptionId $script:Sub } | Should -Throw -ExpectedMessage '*skip token*'
        $script:Calls | Should -BeLessOrEqual 3
    }
}

Describe 'Invoke-AzGraphQuerySafe subscription batches' {

    It 'queries 2500 subscriptions in batches of at most 1000 and returns every batch''s rows' {
        $Ids = @(1..2500 | ForEach-Object { '00000000-0000-0000-0000-{0:d12}' -f $_ })
        $script:Batches = [System.Collections.Generic.List[object]]::new()
        Mock -CommandName Invoke-AzRestMethod -MockWith {
            $Subs = @(($Payload | ConvertFrom-Json).subscriptions)
            $script:Batches.Add($Subs)
            New-GraphResponse -Rows @((New-Row 1 -Sub $Subs[0]), (New-Row 2 -Sub $Subs[-1]))
        }

        $Result = Invoke-AzGraphQuerySafe -Query 'resources' -SubscriptionId $Ids
        $script:Batches.Count | Should -Be 3
        @($script:Batches | ForEach-Object { $_.Count }) | Should -Be @(1000, 1000, 500)
        @($script:Batches | ForEach-Object { $_ }) | Should -Be $Ids -Because 'every subscription is queried exactly once, in order'
        @($Result.data).Count | Should -Be 6
        $Result.data[0].subscriptionId | Should -Be $Ids[0]
        $Result.data[5].subscriptionId | Should -Be $Ids[2499]
    }

    It 'sums the count probe over every batch' {
        $Ids = @(1..1500 | ForEach-Object { '00000000-0000-0000-0000-{0:d12}' -f $_ })
        Mock -CommandName Invoke-AzRestMethod -MockWith { New-GraphResponse -Rows @(@{ count_ = @(($Payload | ConvertFrom-Json).subscriptions).Count }) }

        $Result = Invoke-AzGraphQuerySafe -Query 'resources | summarize count()' -SubscriptionId $Ids
        Get-AzGraphCount -Result $Result | Should -Be 1500
    }

    It 'queries a subscription listed twice only once' {
        $script:Batches = [System.Collections.Generic.List[object]]::new()
        Mock -CommandName Invoke-AzRestMethod -MockWith { $script:Batches.Add(@(($Payload | ConvertFrom-Json).subscriptions)); New-GraphResponse -Rows @() }

        Invoke-AzGraphQuerySafe -Query 'resources' -SubscriptionId @($script:Sub, $script:Sub.ToUpperInvariant(), '') | Out-Null
        @($script:Batches[0]) | Should -Be @($script:Sub)
    }
}

Describe 'Invoke-AzGraphQuerySafe -Lowercase' {

    It 'lowercases keys and values culture-invariantly, also on a Turkish-culture host' {
        Mock -CommandName Invoke-AzRestMethod -MockWith { New-GraphResponse -Content '{"count":1,"data":[{"ID":"/SUBSCRIPTIONS/X/PROVIDERS/MICROSOFT.INSIGHTS/COMPONENTS/IT","Title":"INFO"}],"resultTruncated":"false"}' }
        $Saved = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try
        {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('tr-TR')
            $Result = Invoke-AzGraphQuerySafe -Query 'resources' -SubscriptionId $script:Sub -Lowercase
        }
        finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $Saved }

        $Row = $Result.data[0]
        $Row.PSObject.Properties.Name | Should -Be @('id', 'title')
        $Row.id | Should -BeExactly '/subscriptions/x/providers/microsoft.insights/components/it'
        $Row.title | Should -BeExactly 'info'
    }

    It 'keeps a row as returned when its lowercased text cannot be parsed, and lowercases the others' {
        $Content = '{"count":2,"data":[{"id":"A","properties":{"Kind":"POISON"}},{"id":"B","Type":"T"}],"resultTruncated":"false"}'
        Mock -CommandName Invoke-AzRestMethod -MockWith { New-GraphResponse -Content $Content }
        # Stand-in for a row whose lowercased text no longer parses: only the
        # lowercased form of row A is refused; everything else parses normally.
        Mock -CommandName ConvertFrom-Json -ParameterFilter { [string]$InputObject -cmatch '"poison"' } -MockWith { throw 'stand-in parse failure' }

        $Result = Invoke-AzGraphQuerySafe -Query 'resources' -SubscriptionId $script:Sub -Lowercase
        @($Result.data).Count | Should -Be 2
        $Result.data[0].id | Should -BeExactly 'A'
        $Result.data[0].properties.Kind | Should -BeExactly 'POISON'
        $Result.data[1].id | Should -BeExactly 'b'
        $Result.data[1].type | Should -BeExactly 't'
    }

    It 'merges keys that differ only in case, as lowercasing the az CLI text did' {
        Mock -CommandName Invoke-AzRestMethod -MockWith { New-GraphResponse -Content '{"count":1,"data":[{"id":"A","properties":{"Name":"Upper","name":"lower"}}],"resultTruncated":"false"}' }

        $Result = Invoke-AzGraphQuerySafe -Query 'resources' -SubscriptionId $script:Sub -Lowercase
        @($Result.data).Count | Should -Be 1
        $Result.data[0].properties.PSObject.Properties.Name | Should -Be @('name')
    }

    It 'keeps date strings as the lowercased text, as the az CLI path did' {
        Mock -CommandName Invoke-AzRestMethod -MockWith { New-GraphResponse -Content '{"count":1,"data":[{"properties":{"timeCreated":"2024-03-15T09:41:27.1234567Z"}}],"resultTruncated":"false"}' }

        $Result = Invoke-AzGraphQuerySafe -Query 'resources' -SubscriptionId $script:Sub -Lowercase
        $Result.data[0].properties.timecreated | Should -BeOfType [string]
        $Result.data[0].properties.timecreated | Should -BeExactly '2024-03-15t09:41:27.1234567z'
    }

    It 'does not touch keys or values without -Lowercase' {
        Mock -CommandName Invoke-AzRestMethod -MockWith { New-GraphResponse -Content '{"count":1,"data":[{"Name":"MyResource"}],"resultTruncated":"false"}' }

        $Result = Invoke-AzGraphQuerySafe -Query 'resources' -SubscriptionId $script:Sub
        $Result.data[0].PSObject.Properties.Name | Should -BeExactly @('Name')
        $Result.data[0].Name | Should -BeExactly 'MyResource'
    }
}

Describe 'Invoke-AzGraphQuerySafe and an empty-string property key' {

    BeforeAll {
        # A Logic App definition with a parameter named "" next to an ordinary resource.
        $script:EmptyKeyContent = '{"count":2,"data":[{"id":"/subscriptions/s/resourcegroups/rg/providers/microsoft.logic/workflows/wf","properties":{"definition":{"parameters":{"": {"type":"String"},"Normal":{"type":"Int"}}}},"note":"say \"\": here"},{"id":"/subscriptions/s/resourcegroups/rg/providers/microsoft.network/networksecuritygroups/nsg","properties":{}}],"resultTruncated":"false"}'
    }

    It 'returns the resource with the empty key renamed to _rda_emptykey' {
        Mock -CommandName Invoke-AzRestMethod -MockWith { New-GraphResponse -Content $script:EmptyKeyContent }

        $Result = Invoke-AzGraphQuerySafe -Query 'resources' -SubscriptionId $script:Sub
        @($Result.data).Count | Should -Be 2
        $Params = $Result.data[0].properties.definition.parameters
        $Params.PSObject.Properties.Name | Should -Be @('_rda_emptykey', 'Normal')
        $Params._rda_emptykey.type | Should -Be 'String'
        $Result.data[0].note | Should -BeExactly 'say "": here' -Because 'a "": inside a string value is not a key'
    }

    It 'does the same with -Lowercase' {
        Mock -CommandName Invoke-AzRestMethod -MockWith { New-GraphResponse -Content $script:EmptyKeyContent }

        $Result = Invoke-AzGraphQuerySafe -Query 'resources' -SubscriptionId $script:Sub -Lowercase
        @($Result.data).Count | Should -Be 2
        $Result.data[0].properties.definition.parameters._rda_emptykey.type | Should -Be 'string'
        $Result.data[1].id | Should -Match 'networksecuritygroups/nsg$'
    }

    # A row can already hold a key named like the sentinel. Renaming "" to
    # that name would give the object two keys of the same name, and one
    # value would be lost (or the row would fail to parse).
    It 'keeps both values when a row already has a key named _rda_emptykey' {
        Mock -CommandName Invoke-AzRestMethod -MockWith { New-GraphResponse -Content '{"count":1,"data":[{"_rda_emptykey":"theirs","":"empty","_rda_emptykey1":"also theirs"}],"resultTruncated":"false"}' }

        $Result = Invoke-AzGraphQuerySafe -Query 'resources' -SubscriptionId $script:Sub
        $Row = $Result.data[0]
        @($Row.PSObject.Properties).Count | Should -Be 3 -Because 'no value is dropped'
        $Row._rda_emptykey | Should -BeExactly 'theirs'
        $Row._rda_emptykey1 | Should -BeExactly 'also theirs'
        @($Row.PSObject.Properties | Where-Object { $_.Value -eq 'empty' }).Count | Should -Be 1
        @($Row.PSObject.Properties | Where-Object { $_.Value -eq 'empty' })[0].Name | Should -Match '^_rda_emptykey\d+$'
    }

    It 'keeps both values when a key differing only in case would collide after -Lowercase' {
        Mock -CommandName Invoke-AzRestMethod -MockWith { New-GraphResponse -Content '{"count":1,"data":[{"_RDA_EMPTYKEY":"Theirs","":"Empty"}],"resultTruncated":"false"}' }

        $Result = Invoke-AzGraphQuerySafe -Query 'resources' -SubscriptionId $script:Sub -Lowercase
        $Row = $Result.data[0]
        @($Row.PSObject.Properties).Count | Should -Be 2 -Because 'no value is dropped'
        $Row._rda_emptykey | Should -BeExactly 'theirs'
        @($Row.PSObject.Properties | Where-Object { $_.Value -eq 'empty' }).Count | Should -Be 1
    }

    It 'does not rename a key that ends in an escaped quote' {
        Mock -CommandName Invoke-AzRestMethod -MockWith { New-GraphResponse -Content '{"count":1,"data":[{"a\"":"x","b":""}],"resultTruncated":"false"}' }

        $Result = Invoke-AzGraphQuerySafe -Query 'resources' -SubscriptionId $script:Sub
        $Result.data[0].PSObject.Properties.Name | Should -Be @('a"', 'b')
        $Result.data[0].b | Should -BeExactly ''
    }
}
