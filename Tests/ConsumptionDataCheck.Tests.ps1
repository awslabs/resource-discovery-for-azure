#Requires -Version 7.0
# =============================================================================
# ConsumptionDataCheck.Tests.ps1
#
# The up-front consumption data check (Functions/Common.Functions.ps1): when
# consumption is requested, a run must not start unless every in-scope
# subscription returns at least one usage row with a quantity above zero for
# the billing phase's window. Get-UsageAggregates returns no error and zero rows
# for an identity without Microsoft.Commerce/UsageAggregates/read, so the check
# must prove values came back rather than trust "no error".
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

    foreach ($Fn in @('Get-ConsumptionWindow', 'Get-ConsumptionCheckVerdict', 'Invoke-ConsumptionValueProbe', 'Invoke-ConsumptionDataCheck', 'Write-ConsumptionDataCheckReport'))
    {
        if (-not (Get-Command $Fn -CommandType Function -ErrorAction SilentlyContinue))
        {
            throw "Expected function '$Fn' to be defined by Functions/Common.Functions.ps1."
        }
    }

    # Stubs so the mocks below have a command to replace when Az is absent.
    function Get-UsageAggregates { param($ReportedStartTime, $ReportedEndTime, $AggregationGranularity, $ShowDetails, $ContinuationToken) }
    function Set-AzContext { param($Subscription, $Context, $Scope) }
    function Get-AzContext { param() }
    function Invoke-AzRestMethod { param($Method, $Path, $Payload) }

    function New-UsagePage
    {
        param([object[]]$Quantities = @(), [string]$Token = $null)
        [pscustomobject]@{
            UsageAggregations = @($Quantities | ForEach-Object { [pscustomobject]@{ Properties = [pscustomobject]@{ Quantity = $_ } } })
            ContinuationToken = $Token
        }
    }

    function New-ResourceCountResponse
    {
        param([hashtable]$Counts)
        $Rows = @($Counts.GetEnumerator() | Where-Object { $_.Value -gt 0 } | ForEach-Object { @{ subscriptionId = $_.Key; ResourceCount = $_.Value } })
        [pscustomobject]@{ StatusCode = 200; Content = (@{ data = $Rows } | ConvertTo-Json -Depth 4) }
    }

    function New-StatusException
    {
        param([string]$Message, [System.Net.HttpStatusCode]$Status)
        [System.Net.Http.HttpRequestException]::new($Message, $null, $Status)
    }

    # Shaped like Hyak.Common.CloudException: status under .Response.StatusCode.
    function New-CloudShapedException
    {
        param([string]$Message, [System.Net.HttpStatusCode]$Status)
        $Ex = [System.Exception]::new($Message)
        $Ex | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = $Status })
        $Ex
    }

    $script:Window = Get-ConsumptionWindow -Now ([datetime]'2026-10-26T10:00:00')
}

Describe 'Get-ConsumptionWindow' {
    It 'is the billing phase window: midnight 31 days ago to midnight yesterday of the clock''s date' {
        $W = Get-ConsumptionWindow -Now ([datetime]'2026-10-26T15:30:00')
        $W.Start | Should -Be ([datetime]'2026-09-25T00:00:00')
        $W.End | Should -Be ([datetime]'2026-10-25T00:00:00')
    }

    It 'returns Kind=Unspecified, equal to what the earlier .DateTime strings converted to' {
        $Now = [datetime]::SpecifyKind([datetime]'2026-10-26T15:30:00', [System.DateTimeKind]::Local)
        $W = Get-ConsumptionWindow -Now $Now
        $W.Start.Kind | Should -Be ([System.DateTimeKind]::Unspecified)
        $W.End.Kind | Should -Be ([System.DateTimeKind]::Unspecified)

        $EnUs = [System.Globalization.CultureInfo]::GetCultureInfo('en-US')
        $Old = $Now.AddDays(-31).Date.ToString('F', $EnUs)
        $Converted = [System.Management.Automation.LanguagePrimitives]::ConvertTo($Old, [datetime], $EnUs)
        $W.Start.Ticks | Should -Be $Converted.Ticks
        $W.Start.Kind | Should -Be $Converted.Kind
    }

    It 'is the window of the whole run: ResourceInventory.ps1 computes it once, before the up-front check, and the consumption phase reuses it' {
        $Tokens = $null
        $Errors = $null
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot 'ResourceInventory.ps1'), [ref]$Tokens, [ref]$Errors)
        $Calls = @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.CommandAst] -and $N.GetCommandName() -eq 'Get-ConsumptionWindow' }, $true))
        $Calls.Count | Should -Be 1
        $Setup = @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'RunInventorySetup' }, $true))[0]
        $Setup.Extent.StartOffset | Should -BeLessThan $Calls[0].Extent.StartOffset
        $Setup.Extent.EndOffset | Should -BeGreaterThan $Calls[0].Extent.EndOffset
        $Check = @($Setup.FindAll({ param($N) $N -is [System.Management.Automation.Language.CommandAst] -and $N.GetCommandName() -eq 'Invoke-ConsumptionDataCheck' }, $true))
        $Check.Count | Should -Be 1
        $Check[0].Extent.Text | Should -Match '-Window \$script:ConsumptionWindow'
        $Check[0].Extent.StartOffset | Should -BeGreaterThan $Calls[0].Extent.StartOffset
        $Text = Get-Content -Path (Join-Path $script:RepoRoot 'ResourceInventory.ps1') -Raw
        $Text | Should -Not -Match 'AddDays\(-31\)\.Date'
    }
}

Describe 'Passing the consumption window to child runs' {
    It 'writes the window as invariant yyyy-MM-dd strings, whatever the host culture' {
        $Saved = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try
        {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('th-TH')
            $Arg = ConvertTo-ConsumptionWindowArgument -Window (Get-ConsumptionWindow -Now ([datetime]'2026-10-27T23:59:00'))
        }
        finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $Saved }
        $Arg.ConsumptionWindowStart | Should -Be '2026-09-26'
        $Arg.ConsumptionWindowEnd | Should -Be '2026-10-26'
    }

    It 'reads them back as the same window (midnights, Kind=Unspecified)' {
        $Window = Get-ConsumptionWindow -Now ([datetime]'2026-10-27T23:59:00')
        $Arg = ConvertTo-ConsumptionWindowArgument -Window $Window
        $Back = ConvertFrom-ConsumptionWindowArgument -Start $Arg.ConsumptionWindowStart -End $Arg.ConsumptionWindowEnd
        $Back.Start | Should -Be $Window.Start
        $Back.End | Should -Be $Window.End
        $Back.Start.Kind | Should -Be ([System.DateTimeKind]::Unspecified)
        $Back.End.Kind | Should -Be ([System.DateTimeKind]::Unspecified)
    }

    It 'returns nothing for a missing or invalid value (<Start> / <End>)' -TestCases @(
        @{ Start = ''; End = '' }
        @{ Start = '2026-09-26'; End = '' }
        @{ Start = ''; End = '2026-10-26' }
        @{ Start = '2026-02-30'; End = '2026-03-30' }
        @{ Start = '26-09-2026'; End = '2026-10-26' }
        @{ Start = '2026-09-26T00:00:00'; End = '2026-10-26' }
        @{ Start = '2026-10-27'; End = '2026-10-26' }
    ) {
        param($Start, $End)
        ConvertFrom-ConsumptionWindowArgument -Start $Start -End $End | Should -BeNullOrEmpty
    }
}

Describe 'Run-AllSubscriptions.ps1 passes one consumption window to every subscription' {
    BeforeAll {
        $script:Parsed = @{}
        foreach ($File in @('Run-AllSubscriptions.ps1', 'Run-AllSubscriptions.Stream.ps1'))
        {
            $Tokens = $null
            $Errors = $null
            $script:Parsed[$File] = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot $File), [ref]$Tokens, [ref]$Errors)
        }
        # Runs the top-level statements of $File from the one matching $From to
        # the one matching $To, and returns the $InventoryPassthrough they build.
        function Invoke-PassthroughStatements
        {
            param([string]$File, [string]$From, [string]$To, [hashtable]$Variables)
            $Top = @($script:Parsed[$File].EndBlock.Statements)
            $First = @(0..($Top.Count - 1) | Where-Object { $Top[$_].Extent.Text -match $From })[0]
            $Last = @(0..($Top.Count - 1) | Where-Object { $_ -gt $First -and $Top[$_].Extent.Text -match $To })[0]
            if ($null -eq $First -or $null -eq $Last) { throw ('Statements not found in {0}.' -f $File) }
            $Text = (@($Top[$First..$Last] | ForEach-Object { $_.Extent.Text }) -join "`n") + "`n`$InventoryPassthrough"
            $Block = [scriptblock]::Create('param($Vars) foreach ($K in $Vars.Keys) { Set-Variable -Name $K -Value $Vars[$K] }' + "`n" + $Text)
            return (& $Block $Variables)
        }
    }

    It 'every ResourceInventory.ps1 call site (sequential, parallel with one subscription, stream worker) splats $InventoryPassthrough' {
        $Sites = foreach ($File in $script:Parsed.Keys)
        {
            $script:Parsed[$File].FindAll({ param($N) $N -is [System.Management.Automation.Language.CommandAst] -and $N.Extent.Text -match "^& \(Join-Path [^)]+ .ResourceInventory\.ps1.\)" }, $true) |
                ForEach-Object { [pscustomobject]@{ File = $File; Text = $_.Extent.Text } }
        }
        @($Sites | Where-Object { $_.File -eq 'Run-AllSubscriptions.ps1' }).Count | Should -Be 2
        @($Sites | Where-Object { $_.File -eq 'Run-AllSubscriptions.Stream.ps1' }).Count | Should -Be 1
        foreach ($Site in $Sites) { $Site.Text | Should -Match '@InventoryPassthrough' }
    }

    It 'adds the checked window to the wrapper''s $InventoryPassthrough' {
        $Window = Get-ConsumptionWindow -Now ([datetime]'2026-10-27T23:59:00')
        $Pass = Invoke-PassthroughStatements -File 'Run-AllSubscriptions.ps1' -From '^\$InventoryPassthrough = @\{\}' -To 'ConsumptionWindowEnd' -Variables @{ ConsumptionWindow = $Window; ConcurrencyLimit = 6 }
        $Pass['ConsumptionWindowStart'] | Should -Be '2026-09-26'
        $Pass['ConsumptionWindowEnd'] | Should -Be '2026-10-26'
    }

    It 'gives the window to every parallel worker, which adds it to its own $InventoryPassthrough' {
        $Worker = @($script:Parsed['Run-AllSubscriptions.ps1'].FindAll({ param($N) $N -is [System.Management.Automation.Language.AssignmentStatementAst] -and $N.Left.Extent.Text -eq '$WorkerArgs' }, $true))
        $Worker.Count | Should -Be 1
        $Worker[0].Right.Extent.Text | Should -Match 'ConsumptionWindowStart\s*=\s*\$ConsumptionWindowArgs\.ConsumptionWindowStart'
        $Worker[0].Right.Extent.Text | Should -Match 'ConsumptionWindowEnd\s*=\s*\$ConsumptionWindowArgs\.ConsumptionWindowEnd'
        $Params = @($script:Parsed['Run-AllSubscriptions.Stream.ps1'].ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $Params | Should -Contain 'ConsumptionWindowStart'
        $Params | Should -Contain 'ConsumptionWindowEnd'
        $Pass = Invoke-PassthroughStatements -File 'Run-AllSubscriptions.Stream.ps1' -From '^\$InventoryPassthrough = @\{\}' -To 'ConsumptionWindowEnd' -Variables @{ ConsumptionWindowStart = '2026-09-26'; ConsumptionWindowEnd = '2026-10-26'; ConcurrencyLimit = 6 }
        $Pass['ConsumptionWindowStart'] | Should -Be '2026-09-26'
        $Pass['ConsumptionWindowEnd'] | Should -Be '2026-10-26'
    }
}

Describe 'Consumption phase (GetResorceConsumption in ResourceInventory.ps1)' {
    BeforeAll {
        $Tokens = $null
        $Errors = $null
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot 'ResourceInventory.ps1'), [ref]$Tokens, [ref]$Errors)
        $Fn = @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'GetResorceConsumption' }, $true))
        if ($Fn.Count -ne 1) { throw 'GetResorceConsumption was not found in ResourceInventory.ps1.' }
        $script:CollectionAst = $Fn[0]
        . ([scriptblock]::Create($Fn[0].Extent.Text))
        function Test-DataPlaneAuthReady { param($Phase) $true }

        function New-UsageRow
        {
            param([string]$ResourceUri, $Quantity = 1)
            [pscustomobject]@{ Properties = [pscustomobject]@{
                    InstanceData = (@{ 'Microsoft.Resources' = @{ resourceUri = $ResourceUri; location = 'westeurope' } } | ConvertTo-Json -Compress)
                    MeterCategory = 'Networking'; MeterId = 'meter-1'; MeterName = 'Meter'; MeterRegion = 'EU West'; MeterSubCategory = ''
                    Quantity = $Quantity; Unit = '1 Hour'; UsageStartTime = [datetime]'2026-10-01'; UsageEndTime = [datetime]'2026-10-02'
                }
            }
        }
    }

    BeforeEach {
        $script:SavedCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
        $script:SavedUICulture = [System.Threading.Thread]::CurrentThread.CurrentUICulture
        $script:SavedGlobals = @{}
        foreach ($Name in @('Subscriptions', 'ConsumptionFileCsv', 'ConsumptionRecordCount', 'ConsumptionFailedSubs'))
        {
            $script:SavedGlobals[$Name] = Get-Variable -Name $Name -Scope Global -ValueOnly -ErrorAction SilentlyContinue
        }
        $Global:Subscriptions = @([pscustomobject]@{ Id = 'sub-a'; Name = 'Alpha' })
        $Global:ConsumptionFileCsv = Join-Path $TestDrive ('consumption-{0}.csv' -f [guid]::NewGuid().ToString('N').Substring(0, 8))
        $Global:ConsumptionRecordCount = $null
        $Global:ConsumptionFailedSubs = $null
        $script:SubscriptionID = 'sub-a'
        $script:ResourceGroup = $null
        Mock Write-Log { }
        Mock Set-AzContext { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = $Subscription } } }
        Mock Get-AzContext { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = 'sub-a' } } }
    }

    AfterEach {
        [System.Threading.Thread]::CurrentThread.CurrentCulture = $script:SavedCulture
        [System.Threading.Thread]::CurrentThread.CurrentUICulture = $script:SavedUICulture
        foreach ($Name in $script:SavedGlobals.Keys) { Set-Variable -Name $Name -Scope Global -Value $script:SavedGlobals[$Name] }
        Remove-Variable -Name SubscriptionID, ResourceGroup, ConsumptionWindow -Scope Script -ErrorAction SilentlyContinue
    }


    It 'writes a usage row without additionalInfo when the caller runs under Set-StrictMode -Version Latest' {
        $script:ConsumptionWindow = Get-ConsumptionWindow -Now ([datetime]'2026-10-27T10:00:00')
        Mock Get-UsageAggregates { [pscustomobject]@{ UsageAggregations = @(New-UsageRow -ResourceUri '/subscriptions/sub-a/resourceGroups/rg-one/providers/Microsoft.Network/networkSecurityGroups/nsg-1'); ContinuationToken = $null } }
        Set-StrictMode -Version Latest
        try { GetResorceConsumption }
        finally { Set-StrictMode -Off }
        @($Global:ConsumptionFailedSubs | Where-Object { $null -ne $_ }).Count | Should -Be 0
        $Rows = @(Import-Csv -Path $Global:ConsumptionFileCsv)
        $Rows.Count | Should -Be 1
        ($Rows[0].InstanceData | ConvertFrom-Json).'Microsoft.Resources'.additionalInfo.vCores | Should -Be 0
    }
    It 'collects the window the check queried at 23:59 when it runs after midnight' {
        $script:ConsumptionWindow = Get-ConsumptionWindow -Now ([datetime]'2026-10-27T23:59:00')
        Mock Get-Date { [datetime]'2026-10-28T00:01:00' }
        Mock Get-UsageAggregates { [pscustomobject]@{ UsageAggregations = @(New-UsageRow -ResourceUri '/subscriptions/sub-a/resourceGroups/rg-one/providers/Microsoft.Network/networkSecurityGroups/nsg-1'); ContinuationToken = $null } }
        GetResorceConsumption
        Should -Invoke Get-UsageAggregates -Times 1 -Exactly -ParameterFilter {
            $ReportedStartTime -eq [datetime]'2026-09-26' -and $ReportedEndTime -eq [datetime]'2026-10-26'
        }
        $Global:ConsumptionRecordCount | Should -Be 1
    }

    It 'keeps only the resource group''s rows by the check''s own test (Test-ConsumptionResourceUriInResourceGroup)' {
        $script:ConsumptionWindow = Get-ConsumptionWindow -Now ([datetime]'2026-10-27T10:00:00')
        $script:ResourceGroup = 'rg-one'
        Mock Get-UsageAggregates {
            $Rows = @(
                (New-UsageRow -ResourceUri '/subscriptions/sub-a/resourceGroups/RG-ONE/providers/Microsoft.Network/networkSecurityGroups/nsg-1')
                (New-UsageRow -ResourceUri '/subscriptions/sub-a/resourceGroups/rg-two/providers/Microsoft.Network/networkSecurityGroups/nsg-2')
            )
            [pscustomobject]@{ UsageAggregations = $Rows; ContinuationToken = $null }
        }
        GetResorceConsumption
        $Rows = @(Import-Csv -Path $Global:ConsumptionFileCsv)
        $Rows.Count | Should -Be 1
        $Rows[0].ResourceId | Should -Be '/subscriptions/sub-a/resourcegroups/rg-one/providers/microsoft.network/networksecuritygroups/nsg-1'
        $Uses = @($script:CollectionAst.FindAll({ param($N) $N -is [System.Management.Automation.Language.CommandAst] -and $N.GetCommandName() -eq 'Test-ConsumptionResourceUriInResourceGroup' }, $true))
        $Uses.Count | Should -Be 1
    }

    It 'under -ResourceGroup skips a usage row without a resource URI and keeps collecting the subscription' {
        $script:ConsumptionWindow = Get-ConsumptionWindow -Now ([datetime]'2026-10-27T10:00:00')
        $script:ResourceGroup = 'rg-one'
        Mock Get-UsageAggregates {
            $NoUri = New-UsageRow -ResourceUri 'placeholder'
            $NoUri.Properties.InstanceData = (@{ 'Microsoft.Resources' = @{ location = 'westeurope' } } | ConvertTo-Json -Compress)
            $Rows = @(
                $NoUri
                (New-UsageRow -ResourceUri '/subscriptions/sub-a/resourceGroups/rg-one/providers/Microsoft.Network/networkSecurityGroups/nsg-1')
            )
            [pscustomobject]@{ UsageAggregations = $Rows; ContinuationToken = $null }
        }
        GetResorceConsumption
        @(Import-Csv -Path $Global:ConsumptionFileCsv).Count | Should -Be 1
        @($Global:ConsumptionFailedSubs).Count | Should -Be 0
    }

    # On an ICU host (Linux, macOS) the en-US time pattern has U+202F before
    # AM/PM, so the culture's default date text is not the same on every host.
    It 'writes UsageStartTime and UsageEndTime as M/d/yyyy h:mm:ss tt with a plain space, in ASCII' {
        $script:ConsumptionWindow = Get-ConsumptionWindow -Now ([datetime]'2026-10-27T10:00:00')
        Mock Get-UsageAggregates {
            $A = New-UsageRow -ResourceUri '/subscriptions/sub-a/resourceGroups/rg-one/providers/Microsoft.Network/networkSecurityGroups/nsg-1'
            $B = New-UsageRow -ResourceUri '/subscriptions/sub-a/resourceGroups/rg-one/providers/Microsoft.Network/networkSecurityGroups/nsg-2'
            $B.Properties.UsageStartTime = [datetime]'2026-10-01T13:05:09'
            $B.Properties.UsageEndTime = [datetime]'2026-12-31T23:59:59'
            [pscustomobject]@{ UsageAggregations = @($A, $B); ContinuationToken = $null }
        }
        GetResorceConsumption
        $Rows = @(Import-Csv -Path $Global:ConsumptionFileCsv)
        $Rows[0].UsageStartTime | Should -BeExactly '10/1/2026 12:00:00 AM'
        $Rows[0].UsageEndTime | Should -BeExactly '10/2/2026 12:00:00 AM'
        $Rows[1].UsageStartTime | Should -BeExactly '10/1/2026 1:05:09 PM'
        $Rows[1].UsageEndTime | Should -BeExactly '12/31/2026 11:59:59 PM'
        $Bytes = [System.IO.File]::ReadAllBytes($Global:ConsumptionFileCsv)
        @($Bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0 -Because 'the date text holds no U+202F or other non-ASCII character'
    }

    It 'writes the clock value of the date as it came, whatever its Kind' {
        $script:ConsumptionWindow = Get-ConsumptionWindow -Now ([datetime]'2026-10-27T10:00:00')
        Mock Get-UsageAggregates {
            $Rows = foreach ($Kind in @('Utc', 'Local', 'Unspecified'))
            {
                $Row = New-UsageRow -ResourceUri '/subscriptions/sub-a/resourceGroups/rg-one/providers/Microsoft.Network/networkSecurityGroups/nsg-1'
                $Row.Properties.UsageStartTime = [datetime]::SpecifyKind([datetime]'2026-10-05T00:00:00', $Kind)
                $Row
            }
            [pscustomobject]@{ UsageAggregations = @($Rows); ContinuationToken = $null }
        }
        GetResorceConsumption
        # Compared ordinally: a culture-aware comparison can treat U+202F as a space.
        $Text = (@(Import-Csv -Path $Global:ConsumptionFileCsv) | ForEach-Object { $_.UsageStartTime }) -join '|'
        [string]::Equals($Text, '10/5/2026 12:00:00 AM|10/5/2026 12:00:00 AM|10/5/2026 12:00:00 AM', [System.StringComparison]::Ordinal) | Should -BeTrue -Because "the text was '$Text'"
    }
}

Describe 'Test-ConsumptionRowsHavePositiveQuantity' {
    It 'is false for no rows, zero, negative and non-numeric quantities' {
        Test-ConsumptionRowsHavePositiveQuantity -Rows @() | Should -BeFalse
        Test-ConsumptionRowsHavePositiveQuantity -Rows @([pscustomobject]@{ Quantity = 0 }, [pscustomobject]@{ Quantity = [decimal]0 }) | Should -BeFalse
        Test-ConsumptionRowsHavePositiveQuantity -Rows @([pscustomobject]@{ Quantity = -1 }) | Should -BeFalse
        Test-ConsumptionRowsHavePositiveQuantity -Rows @([pscustomobject]@{ Quantity = 'n/a' }, [pscustomobject]@{ Quantity = $null }, [pscustomobject]@{ Quantity = $true }) | Should -BeFalse
    }

    It 'is true when any row has a quantity above zero' {
        Test-ConsumptionRowsHavePositiveQuantity -Rows @([pscustomobject]@{ Quantity = 0 }, [pscustomobject]@{ Quantity = [decimal]0.0001 }) | Should -BeTrue
        Test-ConsumptionRowsHavePositiveQuantity -Rows @([pscustomobject]@{ Quantity = '4.5' }) | Should -BeTrue
    }
}

Describe 'Invoke-ConsumptionValueProbe and Get-ConsumptionCheckVerdict' {
    BeforeEach {
        Mock Start-Sleep { }
        Mock Set-AzContext { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = $Subscription } } }
    }

    It 'refuses an empty result (no error, zero rows)' {
        Mock Get-UsageAggregatesPage { New-UsagePage }
        $Probe = Invoke-ConsumptionValueProbe -SubscriptionId 'sub-a' -Window $script:Window
        $Verdict = Get-ConsumptionCheckVerdict -Probe $Probe -ResourceCount 5
        $Verdict.Outcome | Should -Be 'NoRows'
        $Verdict.Passed | Should -BeFalse
    }

    It 'refuses when rows come back but every quantity is 0' {
        Mock Get-UsageAggregatesPage { New-UsagePage -Quantities @(0, 0, 0) }
        $Verdict = Get-ConsumptionCheckVerdict -Probe (Invoke-ConsumptionValueProbe -SubscriptionId 'sub-a' -Window $script:Window) -ResourceCount 5
        $Verdict.Outcome | Should -Be 'NoPositiveQuantity'
        $Verdict.Passed | Should -BeFalse
    }

    It 'passes on one positive row and queries the billing phase window with the same options' {
        Mock Get-UsageAggregatesPage { New-UsagePage -Quantities @(0, 2.5) }
        $Probe = Invoke-ConsumptionValueProbe -SubscriptionId 'sub-a' -Window $script:Window
        (Get-ConsumptionCheckVerdict -Probe $Probe -ResourceCount 5).Outcome | Should -Be 'Pass'
        Should -Invoke Get-UsageAggregatesPage -Times 1 -Exactly -ParameterFilter {
            $ReportedStartTime -eq $script:Window.Start -and $ReportedEndTime -eq $script:Window.End -and
            $AggregationGranularity -eq 'Daily' -and $ShowDetails -eq $true
        }
        Should -Invoke Get-UsageAggregatesPage -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq 'sub-a' }
    }

    It 'passes when the only positive row is on page 2, and stops paging there' {
        Mock Get-UsageAggregatesPage { New-UsagePage -Quantities @(0, 0) -Token 'page2' } -ParameterFilter { [string]::IsNullOrEmpty($ContinuationToken) }
        Mock Get-UsageAggregatesPage { New-UsagePage -Quantities @(0, 7) -Token 'page3' } -ParameterFilter { $ContinuationToken -eq 'page2' }
        Mock Get-UsageAggregatesPage { New-UsagePage -Quantities @(9) } -ParameterFilter { $ContinuationToken -eq 'page3' }
        $Probe = Invoke-ConsumptionValueProbe -SubscriptionId 'sub-a' -Window $script:Window
        (Get-ConsumptionCheckVerdict -Probe $Probe -ResourceCount 5).Outcome | Should -Be 'Pass'
        $Probe.PagesRead | Should -Be 2
        Should -Invoke Get-UsageAggregatesPage -Times 0 -Exactly -ParameterFilter { $ContinuationToken -eq 'page3' }
    }

    It 'refuses a permission error without retrying it' {
        Mock Get-UsageAggregatesPage { throw (New-StatusException -Message "The client does not have authorization to perform action 'Microsoft.Commerce/UsageAggregates/read'" -Status Forbidden) }
        $Probe = Invoke-ConsumptionValueProbe -SubscriptionId 'sub-a' -Window $script:Window
        $Verdict = Get-ConsumptionCheckVerdict -Probe $Probe -ResourceCount 5
        $Verdict.Outcome | Should -Be 'Denied'
        $Verdict.Passed | Should -BeFalse
        Should -Invoke Get-UsageAggregatesPage -Times 1 -Exactly
    }

    It 'passes when a transient failure is followed by success' {
        $script:Calls = 0
        Mock Get-UsageAggregatesPage {
            $script:Calls++
            if ($script:Calls -le 2) { throw (New-StatusException -Message 'Too many requests' -Status TooManyRequests) }
            New-UsagePage -Quantities @(1)
        }
        $Probe = Invoke-ConsumptionValueProbe -SubscriptionId 'sub-a' -Window $script:Window
        (Get-ConsumptionCheckVerdict -Probe $Probe -ResourceCount 5).Outcome | Should -Be 'Pass'
        Should -Invoke Get-UsageAggregatesPage -Times 3 -Exactly
        Should -Invoke Start-Sleep -Times 2 -Exactly
    }

    It 'refuses a transient failure that persists after the bounded retries' {
        Mock Get-UsageAggregatesPage { throw (New-StatusException -Message 'Service unavailable' -Status ServiceUnavailable) }
        $Probe = Invoke-ConsumptionValueProbe -SubscriptionId 'sub-a' -Window $script:Window -MaxRetries 3
        $Verdict = Get-ConsumptionCheckVerdict -Probe $Probe -ResourceCount 5
        $Verdict.Outcome | Should -Be 'Error'
        $Verdict.Passed | Should -BeFalse
        Should -Invoke Get-UsageAggregatesPage -Times 4 -Exactly
    }

    It 'refuses a 400 without retrying it' {
        Mock Get-UsageAggregatesPage { throw (New-CloudShapedException -Message 'InvalidInput: The reportedstarttime must have the time set to midnight (0:00:00Z).' -Status BadRequest) }
        $Probe = Invoke-ConsumptionValueProbe -SubscriptionId 'sub-a' -Window $script:Window
        $Verdict = Get-ConsumptionCheckVerdict -Probe $Probe -ResourceCount 5
        $Verdict.Outcome | Should -Be 'Error'
        $Verdict.Detail | Should -Match 'HTTP 400'
        Should -Invoke Get-UsageAggregatesPage -Times 1 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'names the subscription in its usage request and does not switch the Azure context' {
        Mock Set-AzContext { throw 'no context switch expected' }
        Mock Get-UsageAggregatesPage { New-UsagePage -Quantities @(1) }
        $Verdict = Get-ConsumptionCheckVerdict -Probe (Invoke-ConsumptionValueProbe -SubscriptionId 'sub-a' -Window $script:Window) -ResourceCount 5
        $Verdict.Outcome | Should -Be 'Pass'
        Should -Invoke Get-UsageAggregatesPage -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq 'sub-a' }
        Should -Invoke Set-AzContext -Times 0 -Exactly
    }
}

Describe 'Get-UsageAggregatesPage (the usage API Get-UsageAggregates wraps)' {
    BeforeEach {
        Mock Start-Sleep { }
        $script:Paths = [System.Collections.Generic.List[string]]::new()
        $script:Answers = [System.Collections.Generic.Queue[object]]::new()
        Mock Invoke-AzRestMethod { $script:Paths.Add([string]$Path); $script:Answers.Dequeue() }
        function New-RestAnswer
        {
            param([int]$Status = 200, $Body = @{ value = @() }, [string]$Raw)
            $Content = if ($PSBoundParameters.ContainsKey('Raw')) { $Raw } else { $Body | ConvertTo-Json -Depth 10 -Compress }
            [pscustomobject]@{ StatusCode = $Status; Content = $Content }
        }
        $script:NextLink = 'https://management.azure.com/subscriptions/sub-a/providers/Microsoft.Commerce/UsageAggregates?api-version=2015-06-01-preview&reportedStartTime=2026-09-25T00%3a00%3a00Z&continuationToken=abc%2Bdef%3D'
    }

    It 'names the subscription in the path and sends the cmdlet''s window and options' {
        $script:Answers.Enqueue((New-RestAnswer -Body @{ value = @(@{ properties = @{ quantity = 2.5; instanceData = '{"Microsoft.Resources":{"resourceUri":"/subscriptions/sub-a/resourceGroups/rg-one/x"}}' } }) }))
        $Page = Get-UsageAggregatesPage -SubscriptionId 'sub-a' -ReportedStartTime $script:Window.Start -ReportedEndTime $script:Window.End -AggregationGranularity 'Daily' -ShowDetails
        $script:Paths[0] | Should -Be '/subscriptions/sub-a/providers/Microsoft.Commerce/UsageAggregates?api-version=2015-06-01-preview&reportedStartTime=2026-09-25T00%3A00%3A00Z&reportedEndTime=2026-10-25T00%3A00%3A00Z&aggregationGranularity=Daily&showDetails=true'
        @($Page.UsageAggregations).Count | Should -Be 1
        $Page.UsageAggregations[0].Properties.Quantity | Should -Be 2.5
        Get-ConsumptionRowResourceUri -InstanceData $Page.UsageAggregations[0].Properties.InstanceData | Should -Be '/subscriptions/sub-a/resourceGroups/rg-one/x'
        $Page.ContinuationToken | Should -BeNullOrEmpty
    }

    It 'takes the continuation token from nextLink and asks for the next page with it on the same path' {
        $script:Answers.Enqueue((New-RestAnswer -Body @{ value = @(@{ properties = @{ quantity = 0 } }); nextLink = $script:NextLink }))
        $script:Answers.Enqueue((New-RestAnswer -Body @{ value = @(@{ properties = @{ quantity = 3 } }) }))
        $Probe = Invoke-ConsumptionValueProbe -SubscriptionId 'sub-a' -Window $script:Window
        $Probe.PositiveFound | Should -BeTrue
        $Probe.PagesRead | Should -Be 2
        $script:Paths[1] | Should -Be ($script:Paths[0] + '&continuationToken=abc%2Bdef%3D')
    }

    It 'turns an answer outside 2xx into an error with its HTTP status and Azure''s message: <Status> -> <Outcome> after <Calls> call(s)' -TestCases @(
        @{ Status = 403; Outcome = 'Denied'; Calls = 1 }
        @{ Status = 400; Outcome = 'Error'; Calls = 1 }
        @{ Status = 429; Outcome = 'Error'; Calls = 4 }
        @{ Status = 503; Outcome = 'Error'; Calls = 4 }
    ) {
        param($Status, $Outcome, $Calls)
        1..4 | ForEach-Object { $script:Answers.Enqueue((New-RestAnswer -Status $Status -Body @{ error = @{ code = 'SomeCode'; message = 'Azure says no.' } })) }
        $Probe = Invoke-ConsumptionValueProbe -SubscriptionId 'sub-a' -Window $script:Window
        $Verdict = Get-ConsumptionCheckVerdict -Probe $Probe -ResourceCount 5
        $Verdict.Outcome | Should -Be $Outcome
        $Verdict.Passed | Should -BeFalse
        $Verdict.Detail | Should -Be ('query failed (HTTP {0}, {1} attempt(s)): SomeCode: Azure says no.' -f $Status, $Calls)
        $script:Paths.Count | Should -Be $Calls
    }

    It 'says which HTTP status came back when the error answer is not JSON' {
        $script:Answers.Enqueue((New-RestAnswer -Status 403 -Raw '<html>denied</html>'))
        $Verdict = Get-ConsumptionCheckVerdict -Probe (Invoke-ConsumptionValueProbe -SubscriptionId 'sub-a' -Window $script:Window) -ResourceCount 5
        $Verdict.Outcome | Should -Be 'Denied'
        $Verdict.Detail | Should -Be 'query failed (HTTP 403, 1 attempt(s)): the usage API answered HTTP 403'
    }

    It 'stops the subscription (Error), without retrying, on a malformed answer: <Case>' -TestCases @(
        @{ Case = 'a 200 that is not JSON'; Raw = '{"value": [' ; NextLink = $null }
        @{ Case = 'a nextLink that is not a URL'; Raw = $null; NextLink = 'not a url' }
        @{ Case = 'a nextLink without a continuationToken'; Raw = $null; NextLink = 'https://management.azure.com/subscriptions/sub-a/providers/Microsoft.Commerce/UsageAggregates?api-version=2015-06-01-preview' }
    ) {
        param($Case, $Raw, $NextLink)
        $Answer = if ($Raw) { New-RestAnswer -Raw $Raw } else { New-RestAnswer -Body @{ value = @(@{ properties = @{ quantity = 0 } }); nextLink = $NextLink } }
        $script:Answers.Enqueue($Answer)
        $Verdict = Get-ConsumptionCheckVerdict -Probe (Invoke-ConsumptionValueProbe -SubscriptionId 'sub-a' -Window $script:Window) -ResourceCount 5
        $Verdict.Outcome | Should -Be 'Error'
        $Verdict.Passed | Should -BeFalse
        $script:Paths.Count | Should -Be 1
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }
}

Describe 'Usage probe page cap' {
    BeforeEach {
        Mock Start-Sleep { }
        Mock Set-AzContext { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = $Subscription } } }
        # Offers 60 pages of zero quantities, so a reader without a cap reads all
        # 60 and one with the default cap of 50 stops at 50.
        $script:PageCalls = 0
        Mock Get-UsageAggregatesPage {
            $script:PageCalls++
            $Next = if ($script:PageCalls -lt 60) { 'more' } else { $null }
            New-UsagePage -Quantities @(0) -Token $Next
        }
    }

    It 'stops after 50 pages by default and says only those pages were read' {
        $Probe = Invoke-ConsumptionValueProbe -SubscriptionId 'sub-a' -Window $script:Window
        $Probe.PagesRead | Should -Be 50
        $Probe.PageCapReached | Should -BeTrue
        Should -Invoke Get-UsageAggregatesPage -Times 50 -Exactly
        $Verdict = Get-ConsumptionCheckVerdict -Probe $Probe -ResourceCount 5
        $Verdict.Outcome | Should -Be 'NoPositiveQuantity'
        $Verdict.Passed | Should -BeFalse
        $Verdict.Detail | Should -Match 'only the first 50 page\(s\) were read'
    }

    It 'honours -MaxPages' {
        $Probe = Invoke-ConsumptionValueProbe -SubscriptionId 'sub-a' -Window $script:Window -MaxPages 3
        $Probe.PagesRead | Should -Be 3
        $Probe.PageCapReached | Should -BeTrue
        Should -Invoke Get-UsageAggregatesPage -Times 3 -Exactly
    }

    It 'is not reached when the last page is exactly the cap' {
        Mock Get-UsageAggregatesPage { New-UsagePage -Quantities @(0) -Token 'page2' } -ParameterFilter { [string]::IsNullOrEmpty($ContinuationToken) }
        Mock Get-UsageAggregatesPage { New-UsagePage -Quantities @(0) } -ParameterFilter { $ContinuationToken -eq 'page2' }
        $Probe = Invoke-ConsumptionValueProbe -SubscriptionId 'sub-a' -Window $script:Window -MaxPages 2
        $Probe.PagesRead | Should -Be 2
        $Probe.PageCapReached | Should -BeFalse
        (Get-ConsumptionCheckVerdict -Probe $Probe -ResourceCount 5).Detail | Should -Not -Match 'only the first'
    }

    It 'passes with a warning at the cap when both role-check answers confirm the usage permission' {
        $Probe = Invoke-ConsumptionValueProbe -SubscriptionId 'sub-a' -Window $script:Window -MaxPages 3
        $Role = [pscustomobject]@{ Id = 'sub-a'; UsageVerdict = 'Yes'; Assignments = [pscustomobject]@{ UsageGrantedBy = @('Reader at subscription') } }
        $Verdict = Get-ConsumptionCheckVerdict -Probe $Probe -ResourceCount 5 -UsageRole $Role
        $Verdict.Outcome | Should -Be 'NoUsage'
        $Verdict.Passed | Should -BeTrue
        $Verdict.Detail | Should -Match 'only the first 3 page\(s\) were read'
    }

    Context 'what the run says when the cap was reached' {
        BeforeEach {
            $script:Printed = [System.Collections.Generic.List[string]]::new()
            Mock Write-Host { $script:Printed.Add([string]$Object) }
            Mock Get-AzContext { $null }
            Mock Invoke-AzRestMethod { New-ResourceCountResponse -Counts @{ 'sub-a' = 3 } }
            $script:SubAlpha = @([pscustomobject]@{ Id = 'sub-a'; Name = 'Alpha' })
            $script:Confirmed = @([pscustomobject]@{ Id = 'sub-a'; UsageVerdict = 'Yes'; Assignments = [pscustomobject]@{ UsageGrantedBy = @('Reader at subscription') } })
        }

        It 'with the usage permission confirmed, says only the first 50 pages had no usage above zero, never that the sheet is empty' {
            $Result = Invoke-ConsumptionDataCheck -Subscriptions $script:SubAlpha -Window $script:Window -RoleCheck $script:Confirmed
            $Result.ShouldBlock | Should -BeFalse
            $Result.NoUsage[0].PageCapReached | Should -BeTrue
            Write-ConsumptionDataCheckReport -Result $Result
            Write-NoUsageSummary -ConsumptionResult $Result
            $Text = $script:Printed -join "`n"
            $Text | Should -Match 'WARNING: no usage above zero in the first 50 page\(s\) read for 2026-09-25 to 2026-10-25; later pages were not checked\. The run continues and the consumption phase reads every page\.'
            $Text | Should -Match '1 subscription\(s\) showed no usage above zero in the first 50 page\(s\) read for 2026-09-25 to 2026-10-25 and continue'
            $Text | Should -Match 'Subscriptions with no usage above zero in the first 50 page\(s\) the check read: 1'
            $Text | Should -Not -Match 'sheet (will be|is) empty|empty consumption sheet'
            $Text | Should -Not -Match 'Typical causes'
        }

        It 'on a stop, says the subscription had no usage above zero in the pages read' {
            $Result = Invoke-ConsumptionDataCheck -Subscriptions $script:SubAlpha -Window $script:Window
            $Result.ShouldBlock | Should -BeTrue
            $script:Printed.Clear()
            Write-ConsumptionDataCheckReport -Result $Result
            $Text = $script:Printed -join "`n"
            $Text | Should -Match '1 of 1 checked subscription\(s\) returned no usage values for 2026-09-25 to 2026-10-25 \(1 of them: none above zero in the first 50 page\(s\) read; later pages were not checked\)\.'
            $Text | Should -Match 'Alpha \(sub-a\): NoPositiveQuantity - 50 usage row\(s\) came back, none with a quantity above zero; only the first 50 page\(s\) were read'
            $Text | Should -Not -Match 'sheet (will be|is) empty'
        }
    }
}

Describe 'Resource group runs (-ResourceGroup)' {
    BeforeAll {
        function New-RgUsagePage
        {
            param([object[]]$Rows, [string]$Token = $null)
            [pscustomobject]@{
                UsageAggregations = @($Rows | ForEach-Object {
                        $Instance = if ($null -eq $_.Uri) { $_.Raw } else { @{ 'Microsoft.Resources' = @{ resourceUri = $_.Uri } } | ConvertTo-Json -Compress }
                        [pscustomobject]@{ Properties = [pscustomobject]@{ Quantity = $_.Quantity; InstanceData = $Instance } }
                    })
                ContinuationToken = $Token
            }
        }
        $script:InRg = '/subscriptions/sub-a/resourceGroups/RG-One/providers/Microsoft.CognitiveServices/accounts/acct-1'
        $script:OtherRg = '/subscriptions/sub-a/resourceGroups/rg-two/providers/Microsoft.CognitiveServices/accounts/acct-2'
    }

    BeforeEach {
        Mock Start-Sleep { }
        Mock Set-AzContext { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = $Subscription } } }
    }

    It 'matches a resource URI to the resource group without case, by its /<name>/ segment' {
        Test-ConsumptionResourceUriInResourceGroup -ResourceUri $script:InRg -ResourceGroup 'rg-one' | Should -BeTrue
        Test-ConsumptionResourceUriInResourceGroup -ResourceUri $script:InRg.ToUpperInvariant() -ResourceGroup 'Rg-One' | Should -BeTrue
        Test-ConsumptionResourceUriInResourceGroup -ResourceUri $script:OtherRg -ResourceGroup 'rg-one' | Should -BeFalse
        Test-ConsumptionResourceUriInResourceGroup -ResourceUri '/subscriptions/sub-a/resourceGroups/rg-one-b/providers/x/y/z' -ResourceGroup 'rg-one' | Should -BeFalse
        Test-ConsumptionResourceUriInResourceGroup -ResourceUri $null -ResourceGroup 'rg-one' | Should -BeFalse
        Test-ConsumptionResourceUriInResourceGroup -ResourceUri $script:InRg -ResourceGroup '' | Should -BeFalse
    }

    It 'does not match a resource or provider of another resource group whose name equals the resource group (<Case>)' -TestCases @(
        @{ Case = 'web app slot named like the resource group'; Uri = '/subscriptions/sub-a/resourceGroups/prod/providers/Microsoft.Web/sites/web/slots/staging'; Rg = 'web' }
        @{ Case = 'SQL server named like the resource group'; Uri = '/subscriptions/sub-a/resourceGroups/prod/providers/Microsoft.Sql/servers/web/databases/db1'; Rg = 'web' }
        @{ Case = 'provider namespace equal to the resource group'; Uri = '/subscriptions/sub-a/resourceGroups/prod/providers/Microsoft.Web/sites/app1'; Rg = 'microsoft.web' }
        @{ Case = 'not a resource URI'; Uri = 'resourceGroups/web/providers/Microsoft.Web/sites/app1'; Rg = 'web' }
        @{ Case = 'resource group segment missing'; Uri = '/subscriptions/sub-a/providers/Microsoft.Web/sites/web/x'; Rg = 'web' }
    ) {
        param($Case, $Uri, $Rg)
        Test-ConsumptionResourceUriInResourceGroup -ResourceUri $Uri -ResourceGroup $Rg | Should -BeFalse
    }

    It 'matches the resource group''s own resources and the resource group itself' {
        Test-ConsumptionResourceUriInResourceGroup -ResourceUri '/subscriptions/sub-a/resourceGroups/web/providers/Microsoft.Web/sites/app1' -ResourceGroup 'web' | Should -BeTrue
        Test-ConsumptionResourceUriInResourceGroup -ResourceUri '/subscriptions/sub-a/resourcegroups/WEB' -ResourceGroup 'web' | Should -BeTrue
    }

    It 'reads the resource URI from InstanceData, and nothing from missing or malformed InstanceData (<Case>)' -TestCases @(
        @{ Case = 'missing'; Raw = $null }
        @{ Case = 'empty'; Raw = '' }
        @{ Case = 'not JSON'; Raw = '{"Microsoft.Resources": {"resourceUri": ' }
        @{ Case = 'a JSON string'; Raw = '"/subscriptions/sub-a/resourceGroups/rg-one/x"' }
        @{ Case = 'no URI'; Raw = '{"Microsoft.Resources": {"location": "westeurope"}}' }
        @{ Case = 'URI not a string'; Raw = '{"Microsoft.Resources": {"resourceUri": 5}}' }
    ) {
        param($Case, $Raw)
        Get-ConsumptionRowResourceUri -InstanceData $Raw | Should -BeNullOrEmpty
        Get-ConsumptionRowResourceUri -InstanceData (@{ 'Microsoft.Resources' = @{ resourceUri = $script:InRg } } | ConvertTo-Json -Compress) | Should -Be $script:InRg
    }

    It 'does not pass on usage rows of other resource groups' {
        Mock Get-UsageAggregatesPage { New-RgUsagePage -Rows @(@{ Uri = $script:OtherRg; Quantity = 5 }, @{ Uri = $null; Raw = 'not json'; Quantity = 7 }) }
        $Probe = Invoke-ConsumptionValueProbe -SubscriptionId 'sub-a' -Window $script:Window -ResourceGroup 'rg-one'
        $Probe.PositiveFound | Should -BeFalse
        $Probe.RowsSeen | Should -Be 0
        $Verdict = Get-ConsumptionCheckVerdict -Probe $Probe -ResourceCount 2 -ResourceGroup 'rg-one'
        $Verdict.Outcome | Should -Be 'NoRows'
        $Verdict.Passed | Should -BeFalse
        $Verdict.Detail | Should -Be "the query succeeded but returned no usage rows for resource group 'rg-one'"
    }

    It 'passes on a positive usage row of the resource group, matched without case, on a later page' {
        Mock Get-UsageAggregatesPage { New-RgUsagePage -Rows @(@{ Uri = $script:OtherRg; Quantity = 5 }, @{ Uri = $script:InRg; Quantity = 0 }) -Token 'page2' } -ParameterFilter { [string]::IsNullOrEmpty($ContinuationToken) }
        Mock Get-UsageAggregatesPage { New-RgUsagePage -Rows @(@{ Uri = $script:InRg.ToLowerInvariant(); Quantity = 1.5 }) } -ParameterFilter { $ContinuationToken -eq 'page2' }
        $Probe = Invoke-ConsumptionValueProbe -SubscriptionId 'sub-a' -Window $script:Window -ResourceGroup 'RG-ONE'
        $Probe.PositiveFound | Should -BeTrue
        $Probe.PagesRead | Should -Be 2
        $Verdict = Get-ConsumptionCheckVerdict -Probe $Probe -ResourceCount 2 -ResourceGroup 'RG-ONE'
        $Verdict.Outcome | Should -Be 'Pass'
        $Verdict.Detail | Should -Be "usage values found for resource group 'RG-ONE' (2 row(s) read over 2 page(s))"
    }

    It 'counts the resource group''s resources only, and exempts it when Resource Graph has none there' {
        $script:Payloads = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-AzRestMethod { $script:Payloads.Add([string]$Payload); New-ResourceCountResponse -Counts @{} }
        Mock Get-AzContext { $null }
        Mock Write-Host { }
        Mock Get-UsageAggregatesPage { New-RgUsagePage -Rows @() }
        $Result = Invoke-ConsumptionDataCheck -Subscriptions @([pscustomobject]@{ Id = 'sub-a'; Name = 'Alpha' }) -Window $script:Window -ResourceGroup 'RG-One'
        ($script:Payloads[0] | ConvertFrom-Json).query | Should -Be "resources | where resourceGroup == 'rg-one' | summarize ResourceCount = count() by subscriptionId"
        $Result.Results[0].Outcome | Should -Be 'Exempt'
        $Result.Results[0].Detail | Should -Be "no resources in resource group 'RG-One' in Resource Graph; not checked (nothing to price)"
        $Result.ShouldBlock | Should -BeFalse
        Should -Invoke Get-UsageAggregatesPage -Times 0 -Exactly
    }

    It 'does not exempt anything for a resource group name that is not valid, and does not put it in a query' {
        Mock Invoke-AzRestMethod { throw 'no query expected' }
        $Counts = Get-SubscriptionResourceCounts -SubscriptionIds @('sub-a') -ResourceGroup "rg' or 1==1 //"
        $Counts.Count | Should -Be 0
        Should -Invoke Invoke-AzRestMethod -Times 0 -Exactly
    }

    It 'with the usage permission confirmed, passes a resource group with no usage with a warning that names it' {
        $script:Printed = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { $script:Printed.Add([string]$Object) }
        Mock Get-AzContext { $null }
        Mock Invoke-AzRestMethod { New-ResourceCountResponse -Counts @{ 'sub-a' = 1 } }
        Mock Get-UsageAggregatesPage { New-RgUsagePage -Rows @(@{ Uri = $script:OtherRg; Quantity = 5 }) }
        $Role = @([pscustomobject]@{ Id = 'sub-a'; UsageVerdict = 'Yes'; Assignments = [pscustomobject]@{ UsageGrantedBy = @('Reader at subscription') } })
        $Result = Invoke-ConsumptionDataCheck -Subscriptions @([pscustomobject]@{ Id = 'sub-a'; Name = 'Alpha' }) -Window $script:Window -ResourceGroup 'rg-one' -RoleCheck $Role
        $Result.ShouldBlock | Should -BeFalse
        $Result.ResourceGroup | Should -Be 'rg-one'
        Write-ConsumptionDataCheckReport -Result $Result
        Write-NoUsageSummary -ConsumptionResult $Result
        $Text = $script:Printed -join "`n"
        $Text | Should -Match "Verifying consumption data \(usage values for 2026-09-25 to 2026-10-25\) for resource group 'rg-one' in 1 subscription\(s\)\.\.\."
        $Text | Should -Match "WARNING: no usage above zero in resource group 'rg-one' for 2026-09-25 to 2026-10-25\."
        $Text | Should -Match "the consumption sheet for resource group 'rg-one' will be empty"
        $Text | Should -Match "1 subscription\(s\) returned no usage values for resource group 'rg-one' for 2026-09-25 to 2026-10-25 and continue"
        $Text | Should -Match "Subscriptions with no usage values for resource group 'rg-one': 1"
        $Text | Should -Match 'Typical causes: new resources, only free resources, or paused resources\. If usage was expected'
    }

    It 'without a confirmed usage permission, stops a resource group with usage only elsewhere' {
        $script:Printed = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { $script:Printed.Add([string]$Object) }
        Mock Get-AzContext { $null }
        Mock Invoke-AzRestMethod { New-ResourceCountResponse -Counts @{ 'sub-a' = 1 } }
        Mock Get-UsageAggregatesPage { New-RgUsagePage -Rows @(@{ Uri = $script:OtherRg; Quantity = 5 }) }
        $Result = Invoke-ConsumptionDataCheck -Subscriptions @([pscustomobject]@{ Id = 'sub-a'; Name = 'Alpha' }) -Window $script:Window -ResourceGroup 'rg-one'
        $Result.ShouldBlock | Should -BeTrue
        Write-ConsumptionDataCheckReport -Result $Result
        ($script:Printed -join "`n") | Should -Match "1 of 1 checked subscription\(s\) returned no usage values for resource group 'rg-one' for 2026-09-25 to 2026-10-25\."
    }
}

Describe 'Zero usage with the usage permission confirmed by the role check' {
    BeforeAll {
        # A role check record as Test-SubscriptionRoleAccessAll returns it; the
        # usage verdict comes from the real combination of the two answers.
        function New-RoleRecord
        {
            param([string]$Id = 'sub-a', [string]$Assignments, [string]$Permissions, [string[]]$GrantedBy = @())
            [pscustomobject]@{
                Id           = $Id
                State        = 'Readable'
                UsageVerdict = (Resolve-RoleCheckVerdict -Assignments $Assignments -Permissions $Permissions)
                Assignments  = [pscustomobject]@{ Usage = $Assignments; UsageGrantedBy = $GrantedBy }
            }
        }
        $script:NoRowsProbe = [pscustomobject]@{ PositiveFound = $false; RowsSeen = 0; PagesRead = 1; PageCapReached = $false; Attempts = 1; Error = $null }
        $script:ZeroProbe = [pscustomobject]@{ PositiveFound = $false; RowsSeen = 4; PagesRead = 1; PageCapReached = $false; Attempts = 1; Error = $null }
        $script:Confirmed = New-RoleRecord -Assignments 'Yes' -Permissions 'Yes' -GrantedBy @('Reader at subscription')
    }

    It 'passes NoRows as NoUsage, naming the role and scope, when both answers grant the permission' {
        $Verdict = Get-ConsumptionCheckVerdict -Probe $script:NoRowsProbe -ResourceCount 1 -UsageRole $script:Confirmed
        $Verdict.Outcome | Should -Be 'NoUsage'
        $Verdict.Passed | Should -BeTrue
        $Verdict.Detail | Should -Match 'returned no usage rows'
        $Verdict.Detail | Should -Match 'confirmed by the role assignments and by Azure \(Reader at subscription\)'
    }

    It 'passes NoPositiveQuantity as NoUsage when both answers grant the permission' {
        $Verdict = Get-ConsumptionCheckVerdict -Probe $script:ZeroProbe -ResourceCount 1 -UsageRole $script:Confirmed
        $Verdict.Outcome | Should -Be 'NoUsage'
        $Verdict.Passed | Should -BeTrue
        $Verdict.Detail | Should -Match '4 usage row\(s\) came back, none with a quantity above zero'
    }

    It 'still stops (<Expected>) when role assignments say <A> and Azure says <B>' -TestCases @(
        @{ A = 'Yes'; B = 'No'; Expected = 'NoRows' }
        @{ A = 'No'; B = 'Yes'; Expected = 'NoRows' }
        @{ A = 'NotVisible'; B = 'Yes'; Expected = 'NoRows' }
        @{ A = 'NotVisible'; B = 'No'; Expected = 'NoRows' }
        @{ A = 'No'; B = 'No'; Expected = 'NoRows' }
        @{ A = 'Unknown'; B = 'Yes'; Expected = 'NoRows' }
        @{ A = 'Yes'; B = 'Unknown'; Expected = 'NoRows' }
    ) {
        param($A, $B, $Expected)
        $Role = New-RoleRecord -Assignments $A -Permissions $B -GrantedBy @('Reader at subscription')
        $Verdict = Get-ConsumptionCheckVerdict -Probe $script:NoRowsProbe -ResourceCount 1 -UsageRole $Role
        $Verdict.Outcome | Should -Be $Expected
        $Verdict.Passed | Should -BeFalse
        (Get-ConsumptionCheckVerdict -Probe $script:ZeroProbe -ResourceCount 1 -UsageRole $Role).Outcome | Should -Be 'NoPositiveQuantity'
    }

    It 'still stops when there is no role check record for the subscription' {
        (Get-ConsumptionCheckVerdict -Probe $script:NoRowsProbe -ResourceCount 1 -UsageRole $null).Passed | Should -BeFalse
        (Get-ConsumptionCheckVerdict -Probe $script:NoRowsProbe -ResourceCount 1).Outcome | Should -Be 'NoRows'
    }

    It 'still stops on Denied and Error even when both answers grant the permission' {
        $Denied = [pscustomobject]@{ PositiveFound = $false; RowsSeen = 0; PagesRead = 0; Attempts = 1; Error = (New-StatusException -Message 'Forbidden' -Status Forbidden) }
        $Failure = [pscustomobject]@{ PositiveFound = $false; RowsSeen = 0; PagesRead = 0; Attempts = 4; Error = (New-StatusException -Message 'Service unavailable' -Status ServiceUnavailable) }
        $D = Get-ConsumptionCheckVerdict -Probe $Denied -ResourceCount 1 -UsageRole $script:Confirmed
        $E = Get-ConsumptionCheckVerdict -Probe $Failure -ResourceCount 1 -UsageRole $script:Confirmed
        $D.Outcome | Should -Be 'Denied'
        $D.Passed | Should -BeFalse
        $E.Outcome | Should -Be 'Error'
        $E.Passed | Should -BeFalse
    }

    It 'leaves Pass and Exempt unchanged' {
        $Positive = [pscustomobject]@{ PositiveFound = $true; RowsSeen = 2; PagesRead = 1; Attempts = 1; Error = $null }
        (Get-ConsumptionCheckVerdict -Probe $Positive -ResourceCount 1 -UsageRole $script:Confirmed).Outcome | Should -Be 'Pass'
        (Get-ConsumptionCheckVerdict -Probe $null -ResourceCount 0 -UsageRole $script:Confirmed).Outcome | Should -Be 'Exempt'
    }

    Context 'across subscriptions' {
        BeforeEach {
            Mock Start-Sleep { }
            $script:Printed = [System.Collections.Generic.List[object]]::new()
            Mock Write-Host { $script:Printed.Add([pscustomobject]@{ Text = [string]$Object; Colour = [string]$ForegroundColor }) }
            Mock Get-AzContext { $null }
            Mock Set-AzContext { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = $Subscription } } }
            Mock Invoke-AzRestMethod { New-ResourceCountResponse -Counts @{ 'sub-a' = 3; 'sub-b' = 1; 'sub-c' = 2 } }
            $script:Subs = @(
                [pscustomobject]@{ Id = 'sub-a'; Name = 'Alpha' }
                [pscustomobject]@{ Id = 'sub-b'; Name = 'Bravo' }
                [pscustomobject]@{ Id = 'sub-c'; Name = 'Charlie' }
            )
            # Alpha has usage; Bravo and Charlie return none. Bravo's usage
            # permission is confirmed by both answers, Charlie's only by Azure.
            Mock Get-UsageAggregatesPage { if ($SubscriptionId -eq 'sub-a') { New-UsagePage -Quantities @(2) } else { New-UsagePage } }
            $script:Roles = @(
                (New-RoleRecord -Id 'sub-a' -Assignments 'Yes' -Permissions 'Yes' -GrantedBy @('Reader at subscription'))
                (New-RoleRecord -Id 'sub-b' -Assignments 'Yes' -Permissions 'Yes' -GrantedBy @('Billing Reader at management group'))
                (New-RoleRecord -Id 'sub-c' -Assignments 'NotVisible' -Permissions 'Yes')
            )
        }

        It 'passes the confirmed subscription with a yellow warning and stops on the other one' {
            $Result = Invoke-ConsumptionDataCheck -Subscriptions $script:Subs -Window $script:Window -RoleCheck $script:Roles
            $Result.ShouldBlock | Should -BeTrue
            @($Result.Failed | ForEach-Object { $_.Id }) | Should -Be @('sub-c')
            @($Result.NoUsage | ForEach-Object { $_.Id }) | Should -Be @('sub-b')
            $Line = @($script:Printed | Where-Object { $_.Text -like '  `[NoUsage`] Bravo*' })
            $Line.Count | Should -Be 1
            $Line[0].Colour | Should -Be 'Yellow'
            $Line[0].Text | Should -Match 'Billing Reader at management group'
            $Warning = @($script:Printed | Where-Object { $_.Text -match 'WARNING: no usage above zero for 2026-09-25 to 2026-10-25' })
            $Warning.Count | Should -Be 1
            $Warning[0].Colour | Should -Be 'Yellow'
            $Warning[0].Text | Should -Match 'a new subscription, only free resources, or paused resources'
            $Warning[0].Text | Should -Match 'consumption sheet will be empty'

            $script:Printed.Clear()
            Write-ConsumptionDataCheckReport -Result $Result
            $Text = @($script:Printed | ForEach-Object { $_.Text }) -join "`n"
            $Text | Should -Match 'Charlie \(sub-c\): NoRows'
            $Text | Should -Not -Match 'Bravo \(sub-b\): '
            $Text | Should -Match '1 other subscription\(s\) returned no usage values too'
            $Text | Should -Match 'Cost Management Reader does NOT'
        }

        It 'continues when every subscription without usage is confirmed by both answers' {
            $script:Roles[2] = New-RoleRecord -Id 'sub-c' -Assignments 'Yes' -Permissions 'Yes' -GrantedBy @('Owner at subscription through a group')
            $Result = Invoke-ConsumptionDataCheck -Subscriptions $script:Subs -Window $script:Window -RoleCheck $script:Roles
            $Result.ShouldBlock | Should -BeFalse
            @($Result.NoUsage | ForEach-Object { $_.Id }) | Should -Be @('sub-b', 'sub-c')

            $script:Printed.Clear()
            Write-ConsumptionDataCheckReport -Result $Result
            $Lines = @($script:Printed | ForEach-Object { $_.Text })
            $Lines | Should -Contain 'Consumption data confirmed: 1 subscription(s) returned usage values for 2026-09-25 to 2026-10-25.'
            ($Lines -join "`n") | Should -Match '2 subscription\(s\) returned no usage values for 2026-09-25 to 2026-10-25 and continue with an empty consumption sheet'
        }

        It 'stops as before when no role check records are passed' {
            $Result = Invoke-ConsumptionDataCheck -Subscriptions $script:Subs -Window $script:Window
            @($Result.Failed | ForEach-Object { $_.Id }) | Should -Be @('sub-b', 'sub-c')
            @($Result.NoUsage).Count | Should -Be 0
        }
    }
}

Describe 'Write-NoUsageSummary (end-of-run list)' {
    BeforeEach {
        $script:Printed = [System.Collections.Generic.List[object]]::new()
        Mock Write-Host { $script:Printed.Add([pscustomobject]@{ Text = [string]$Object; Colour = [string]$ForegroundColor }) }
    }

    It 'lists every NoUsage subscription by name and id, in yellow' {
        $Result = Resolve-ConsumptionDataCheck -Window $script:Window -Results @(
            [pscustomobject]@{ Id = 'sub-a'; Name = 'Alpha'; Outcome = 'Pass'; Passed = $true }
            [pscustomobject]@{ Id = 'sub-b'; Name = 'Bravo'; Outcome = 'NoUsage'; Passed = $true }
            [pscustomobject]@{ Id = 'sub-c'; Name = 'Charlie'; Outcome = 'Exempt'; Passed = $true }
            [pscustomobject]@{ Id = 'sub-d'; Name = 'Delta'; Outcome = 'NoUsage'; Passed = $true }
        )
        Write-NoUsageSummary -ConsumptionResult $Result
        $Lines = @($script:Printed | Where-Object { $_.Text -ne '' })
        $Lines[0].Text | Should -Be 'Subscriptions with no usage values: 2 - the usage permission was confirmed, but no usage above zero came back for 2026-09-25 to 2026-10-25, so their consumption sheet is empty:'
        @($Lines | ForEach-Object { $_.Text }) | Should -Contain '  - Bravo (sub-b)'
        @($Lines | ForEach-Object { $_.Text }) | Should -Contain '  - Delta (sub-d)'
        @($Lines | ForEach-Object { $_.Text }) | Should -Not -Contain '  - Alpha (sub-a)'
        @($Lines | Where-Object { $_.Colour -ne 'Yellow' }).Count | Should -Be 0
    }

    It 'prints nothing when there are none, or when the check did not run' {
        Write-NoUsageSummary -ConsumptionResult (Resolve-ConsumptionDataCheck -Window $script:Window -Results @([pscustomobject]@{ Id = 'sub-a'; Name = 'Alpha'; Outcome = 'Pass'; Passed = $true }))
        Write-NoUsageSummary -ConsumptionResult $null
        $script:Printed.Count | Should -Be 0
    }

    It 'is called at the end of both scripts with the consumption check result' {
        $Wrapper = Get-Content -Path (Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1') -Raw
        $Summary = $Wrapper.IndexOf('================ Summary ================')
        $Summary | Should -BeGreaterThan 0
        $Wrapper.IndexOf('Write-NoUsageSummary -ConsumptionResult $ConsumptionCheck') | Should -BeGreaterThan $Summary
        $Direct = Get-Content -Path (Join-Path $script:RepoRoot 'ResourceInventory.ps1') -Raw
        $Direct | Should -Match '\$script:ConsumptionCheckResult = \$ConsumptionCheck'
        $Direct.IndexOf('Write-NoUsageSummary -ConsumptionResult $script:ConsumptionCheckResult') | Should -BeGreaterThan $Direct.IndexOf('Reporting Data File')
    }
}

Describe 'Get-ConsumptionErrorKind' {
    It 'treats throttling, timeouts and 5xx as transient' {
        Get-ConsumptionErrorKind -Exception (New-StatusException -Message 'x' -Status TooManyRequests) | Should -Be 'Transient'
        Get-ConsumptionErrorKind -Exception (New-StatusException -Message 'x' -Status BadGateway) | Should -Be 'Transient'
        Get-ConsumptionErrorKind -Exception (New-CloudShapedException -Message 'x' -Status InternalServerError) | Should -Be 'Transient'
        Get-ConsumptionErrorKind -Exception ([System.TimeoutException]::new('The operation has timed out.')) | Should -Be 'Transient'
    }

    It 'treats 400, 401, 403 and unclassified errors as permanent' {
        Get-ConsumptionErrorKind -Exception (New-CloudShapedException -Message 'InvalidInput' -Status BadRequest) | Should -Be 'Permanent'
        Get-ConsumptionErrorKind -Exception (New-StatusException -Message 'x' -Status Unauthorized) | Should -Be 'Permanent'
        Get-ConsumptionErrorKind -Exception (New-StatusException -Message 'x' -Status Forbidden) | Should -Be 'Permanent'
        Get-ConsumptionErrorKind -Exception ([System.Exception]::new('Subscription not found')) | Should -Be 'Permanent'
    }
}

Describe 'Invoke-ConsumptionDataCheck across subscriptions' {
    BeforeEach {
        Mock Start-Sleep { }
        Mock Write-Host { }
        Mock Get-AzContext { [pscustomobject]@{ Name = 'original'; Subscription = [pscustomobject]@{ Id = 'original-sub' } } }
        Mock Set-AzContext { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = $Subscription } } } -ParameterFilter { $null -ne $Subscription }
        Mock Set-AzContext { $Context } -ParameterFilter { $null -ne $Context }
        $script:Subs = @(
            [pscustomobject]@{ Id = 'sub-a'; Name = 'Alpha' }
            [pscustomobject]@{ Id = 'sub-b'; Name = 'Bravo' }
            [pscustomobject]@{ Id = 'sub-c'; Name = 'Charlie' }
        )
    }

    It 'checks every subscription and lists all failures, not just the first' {
        Mock Invoke-AzRestMethod { New-ResourceCountResponse -Counts @{ 'sub-a' = 3; 'sub-b' = 4; 'sub-c' = 5 } }
        Mock Get-UsageAggregatesPage { if ($SubscriptionId -eq 'sub-b') { New-UsagePage -Quantities @(2) } else { New-UsagePage } }

        $Result = Invoke-ConsumptionDataCheck -Subscriptions $script:Subs -Window $script:Window
        $Result.ShouldBlock | Should -BeTrue
        @($Result.Results).Count | Should -Be 3
        @($Result.Failed | ForEach-Object { $_.Name }) | Should -Be @('Alpha', 'Charlie')
        Should -Invoke Get-UsageAggregatesPage -Times 3 -Exactly

        $script:Printed = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { $script:Printed.Add([string]$Object) }
        Write-ConsumptionDataCheckReport -Result $Result
        $Text = $script:Printed -join "`n"
        $Text | Should -Match 'Alpha \(sub-a\): NoRows'
        $Text | Should -Match 'Charlie \(sub-c\): NoRows'
        $Text | Should -Not -Match 'Bravo \(sub-b\)'
        $Text | Should -Match '2026-09-25 to 2026-10-25'
        $Text | Should -Match 'Microsoft\.Commerce/UsageAggregates/read'
        $Text | Should -Match 'Cost Management Reader does NOT'
        $Text | Should -Match 'CSP'
        $Text | Should -Match '-SkipConsumption'
    }

    It 'exempts a subscription with zero resources without querying its usage' {
        Mock Invoke-AzRestMethod { New-ResourceCountResponse -Counts @{ 'sub-a' = 3; 'sub-b' = 0; 'sub-c' = 5 } }
        Mock Get-UsageAggregatesPage { New-UsagePage -Quantities @(1) }
        $Result = Invoke-ConsumptionDataCheck -Subscriptions $script:Subs -Window $script:Window
        $Result.ShouldBlock | Should -BeFalse
        @($Result.Exempt | ForEach-Object { $_.Id }) | Should -Be @('sub-b')
        Should -Invoke Get-UsageAggregatesPage -Times 0 -Exactly -ParameterFilter { $SubscriptionId -eq 'sub-b' }
        Should -Invoke Get-UsageAggregatesPage -Times 2 -Exactly
    }

    It 'checks every subscription when the resource count query fails (no exemption on unknown counts)' {
        Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 403; Content = '{}' } }
        Mock Get-UsageAggregatesPage { New-UsagePage -Quantities @(1) }
        $Result = Invoke-ConsumptionDataCheck -Subscriptions $script:Subs -Window $script:Window
        $Result.Exempt.Count | Should -Be 0
        Should -Invoke Get-UsageAggregatesPage -Times 3 -Exactly
    }

    It 'passes when every subscription returns a positive quantity, and leaves the Azure context alone' {
        Mock Invoke-AzRestMethod { New-ResourceCountResponse -Counts @{ 'sub-a' = 1; 'sub-b' = 1; 'sub-c' = 1 } }
        Mock Get-UsageAggregatesPage { New-UsagePage -Quantities @(0.5) }
        $Result = Invoke-ConsumptionDataCheck -Subscriptions $script:Subs -Window $script:Window
        $Result.ShouldBlock | Should -BeFalse
        Should -Invoke Set-AzContext -Times 0 -Exactly
        Should -Invoke Get-AzContext -Times 0 -Exactly
    }
}

Describe 'Run-AllSubscriptions.ps1 consumption data check block' {
    BeforeAll {
        $WrapperPath = Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1'
        $Tokens = $null
        $Errors = $null
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($WrapperPath, [ref]$Tokens, [ref]$Errors)
        $Top = @($Ast.EndBlock.Statements)
        $script:ScopeIndex = -1
        for ($I = 0; $I -lt $Top.Count; $I++)
        {
            if ($Top[$I].Extent.Text -match '^\$ConsumptionCheckScope\s*=') { $script:ScopeIndex = $I; break }
        }
        if ($script:ScopeIndex -lt 0) { throw 'The consumption data check block was not found in Run-AllSubscriptions.ps1.' }
        $script:CheckBlock = [scriptblock]::Create(($Top[$script:ScopeIndex].Extent.Text + "`n" + $Top[$script:ScopeIndex + 1].Extent.Text))

        $script:FirstInventoryIndex = -1
        for ($I = 0; $I -lt $Top.Count; $I++)
        {
            if ($Top[$I].Extent.Text -match "ResourceInventory\.ps1'|Run-AllSubscriptions\.Stream\.ps1|Get-RecommendedParallelism") { $script:FirstInventoryIndex = $I; break }
        }
        $script:OldGateRemoved = ((Get-Content -Path $WrapperPath -Raw) -notmatch 'Test-ConsumptionAccess|ConsumptionProbeSub')

        # The wrapper defines Exit-Wrapper in RunAllSubscriptions.Functions.ps1;
        # a stub is enough for the mock to replace.
        function Exit-Wrapper { param([int]$Code = 0) }
    }

    BeforeEach {
        Mock Write-Host { }
        Mock Exit-Wrapper { throw ('EXIT {0}' -f $Code) }
        Mock Invoke-AzRestMethod { New-ResourceCountResponse -Counts @{ 'sub-a' = 2; 'sub-b' = 2 } }
        Mock Set-AzContext { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = $Subscription } } }
        Mock Get-AzContext { $null }
        # The wrapper's variables the check block reads, in script scope so the
        # dot-sourced block resolves them.
        $script:Subscriptions = @([pscustomobject]@{ Id = 'sub-a'; Name = 'Alpha' }, [pscustomobject]@{ Id = 'sub-b'; Name = 'Bravo' })
        $script:CompletedIds = @()
        $script:Resume = $false
        $script:SkipConsumption = $false
        $script:AccessProbed = @()
        # Computed once by the wrapper just before this block.
        $script:ConsumptionWindow = $script:Window
    }

    AfterAll {
        Remove-Variable -Name Subscriptions, CompletedIds, Resume, SkipConsumption, AccessProbed, ConsumptionWindow -Scope Script -ErrorAction SilentlyContinue
    }

    It 'checks the window computed once before it (the one passed to every subscription)' {
        $script:ConsumptionWindow = Get-ConsumptionWindow -Now ([datetime]'2026-01-15T23:59:00')
        Mock Get-UsageAggregatesPage { New-UsagePage -Quantities @(3) }
        { . $script:CheckBlock } | Should -Not -Throw
        Should -Invoke Get-UsageAggregatesPage -Times 2 -Exactly -ParameterFilter { $ReportedStartTime -eq [datetime]'2025-12-15' -and $ReportedEndTime -eq [datetime]'2026-01-14' }
        $Text = Get-Content -Path (Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1') -Raw
        $Text.IndexOf('$ConsumptionWindow = Get-ConsumptionWindow') | Should -BeLessThan $Text.IndexOf('$ConsumptionCheckScope =')
        $Text.IndexOf('$ConsumptionWindow = Get-ConsumptionWindow') | Should -BeGreaterThan 0
    }

    It 'runs before parallelism tuning and before any inventory invocation, and replaces the first-subscription gate' {
        $script:FirstInventoryIndex | Should -BeGreaterThan $script:ScopeIndex
        $script:OldGateRemoved | Should -BeTrue
    }

    It 'exits 1 (before inventory starts) when consumption returns no values' {
        Mock Get-UsageAggregatesPage { New-UsagePage }
        { . $script:CheckBlock } | Should -Throw 'EXIT 1'
        Should -Invoke Get-UsageAggregatesPage -Times 2 -Exactly
    }

    It 'continues when every subscription returns values' {
        Mock Get-UsageAggregatesPage { New-UsagePage -Quantities @(3) }
        { . $script:CheckBlock } | Should -Not -Throw
        Should -Invoke Exit-Wrapper -Times 0 -Exactly
    }

    It 'skips the check entirely under -SkipConsumption' {
        $script:SkipConsumption = $true
        Mock Get-UsageAggregatesPage { New-UsagePage }
        { . $script:CheckBlock } | Should -Not -Throw
        Should -Invoke Get-UsageAggregatesPage -Times 0 -Exactly
        Should -Invoke Invoke-AzRestMethod -Times 0 -Exactly
    }

    It 'on -Resume checks only the subscriptions this run will process' {
        $script:Resume = $true
        $script:CompletedIds = @('sub-a')
        Mock Get-UsageAggregatesPage { New-UsagePage -Quantities @(3) }
        { . $script:CheckBlock } | Should -Not -Throw
        Should -Invoke Get-UsageAggregatesPage -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq 'sub-b' }
        Should -Invoke Get-UsageAggregatesPage -Times 0 -Exactly -ParameterFilter { $SubscriptionId -eq 'sub-a' }
    }

    It 'passes the role check records in: no usage with the permission confirmed by both answers continues' {
        $script:AccessProbed = @(
            [pscustomobject]@{ Id = 'sub-a'; UsageVerdict = 'Yes'; Assignments = [pscustomobject]@{ UsageGrantedBy = @('Reader at subscription') } }
            [pscustomobject]@{ Id = 'sub-b'; UsageVerdict = 'Yes'; Assignments = [pscustomobject]@{ UsageGrantedBy = @('Reader at subscription') } }
        )
        Mock Get-UsageAggregatesPage { New-UsagePage }
        . $script:CheckBlock
        Should -Invoke Exit-Wrapper -Times 0 -Exactly
        @($ConsumptionCheck.NoUsage | ForEach-Object { $_.Id }) | Should -Be @('sub-a', 'sub-b')
    }

    It 'still exits 1 on no usage when the usage permission is not confirmed by both answers' {
        $script:AccessProbed = @(
            [pscustomobject]@{ Id = 'sub-a'; UsageVerdict = 'Yes'; Assignments = [pscustomobject]@{ UsageGrantedBy = @('Reader at subscription') } }
            [pscustomobject]@{ Id = 'sub-b'; UsageVerdict = 'YesPermissionsOnly'; Assignments = [pscustomobject]@{ UsageGrantedBy = @() } }
        )
        Mock Get-UsageAggregatesPage { New-UsagePage }
        { . $script:CheckBlock } | Should -Throw 'EXIT 1'
    }
}

Describe 'ResourceInventory.ps1 direct run' {
    BeforeAll {
        # Runs the real script in a child pwsh with Azure replaced by stubs. The
        # stubbed 'az graph' call is the first inventory step after setup; it
        # writes a marker and exits 3, so reaching inventory is observable and
        # nothing past it runs.
        $script:Harness = Join-Path $TestDrive 'harness.ps1'
        @'
param([string]$Root, [string]$Out, [string]$Mode, [switch]$SkipConsumption)
$Global:RdaSessionInitialized = $true
$Global:AzPowerShellLoaded = $true
$Global:PlatformOS = 'PowerShell Unix'
$TestSub = '12345678-1234-1234-1234-123456789012'
function global:az
{
    $Joined = $args -join ' '
    if ($Joined -like 'account show*') { return ('{{"user":{{"name":"tester"}},"tenantId":"{0}"}}' -f $TestSub) }
    if ($Joined -like 'account list*') { return ('[{{"id":"{0}","name":"Placeholder subscription","tenantId":"{0}"}}]' -f $TestSub) }
    if ($Joined -like 'graph*') { Set-Content -Path $env:RDA_TEST_INVENTORY_MARKER -Value 'inventory started'; exit 3 }
    return $null
}
function global:Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $TestSub }; Subscription = [pscustomobject]@{ Id = $TestSub } } }
function global:Set-AzContext { param($Subscription, $Context, $Scope) [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = $(if ($Subscription) { $Subscription } else { $TestSub }) } } }
# The up-front role check sees Reader at the subscription, so these runs reach
# the consumption check. RDA_TEST_ROLES 'permissions-only' hides the role
# assignments, so only Azure's answer grants the usage permission.
function global:Get-AzAccessToken { param($ResourceUrl) [pscustomobject]@{ Token = ('e30.' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"oid":"test-oid"}')).TrimEnd('=') + '.sig') } }
function global:Invoke-AzRestMethod
{
    param($Method, $Path, $Payload, $Uri)
    if ($Path -match '/roleAssignments\?' -and $env:RDA_TEST_ROLES -eq 'permissions-only') { return [pscustomobject]@{ StatusCode = 200; Content = '{"value":[]}' } }
    if ($Path -match '/roleAssignments\?') { return [pscustomobject]@{ StatusCode = 200; Content = (@{ value = @(@{ properties = @{ roleDefinitionId = "/subscriptions/$TestSub/providers/Microsoft.Authorization/roleDefinitions/reader"; scope = "/subscriptions/$TestSub"; principalId = 'test-oid'; principalType = 'ServicePrincipal' } }) } | ConvertTo-Json -Depth 10) } }
    if ($Path -match '/roleDefinitions/') { return [pscustomobject]@{ StatusCode = 200; Content = (@{ properties = @{ roleName = 'Reader'; type = 'BuiltInRole'; permissions = @(@{ actions = @('*/read'); notActions = @() }) } } | ConvertTo-Json -Depth 10) } }
    if ($Path -match '/providers/Microsoft\.Authorization/permissions\?') { return [pscustomobject]@{ StatusCode = 200; Content = (@{ value = @(@{ actions = @('*/read'); notActions = @() }) } | ConvertTo-Json -Depth 10) } }
    if ($Path -match '/providers/Microsoft\.Commerce/UsageAggregates\?')
    {
        Add-Content -Path $env:RDA_TEST_USAGE_MARKER -Value 'usage queried'
        $Rows = if ($env:RDA_TEST_MODE -eq 'values') { @(@{ properties = @{ quantity = 2 } }) } else { @() }
        return [pscustomobject]@{ StatusCode = 200; Content = (@{ value = $Rows } | ConvertTo-Json -Depth 10) }
    }
    [pscustomobject]@{ StatusCode = 200; Content = ('{{"data":[{{"subscriptionId":"{0}","ResourceCount":4}}]}}' -f $TestSub) }
}
$env:RDA_TEST_MODE = $Mode
$Extra = @{}
if ($SkipConsumption) { $Extra.SkipConsumption = $true }
& (Join-Path $Root 'ResourceInventory.ps1') -SubscriptionID $TestSub -OutputDirectory $Out @Extra
exit $LASTEXITCODE
'@ | Set-Content -Path $script:Harness -Encoding utf8

        function Invoke-DirectRun
        {
            param([string]$Mode, [switch]$SkipConsumption, [string]$Roles = 'reader')
            $Out = Join-Path $TestDrive ('out-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Path $Out -Force | Out-Null
            $env:RDA_TEST_INVENTORY_MARKER = Join-Path $Out 'inventory.marker'
            $env:RDA_TEST_USAGE_MARKER = Join-Path $Out 'usage.marker'
            $env:RDA_TEST_ROLES = $Roles
            $PwshArgs = @('-NoProfile', '-NonInteractive', '-File', $script:Harness, '-Root', $script:RepoRoot, '-Out', $Out, '-Mode', $Mode)
            if ($SkipConsumption) { $PwshArgs += '-SkipConsumption' }
            # ResourceInventory.ps1 reads ./Version.json from the current folder.
            Push-Location $script:RepoRoot
            try { $Output = & (Join-Path $PSHOME 'pwsh') @PwshArgs 2>&1 | Out-String }
            finally { Pop-Location }
            [pscustomobject]@{
                ExitCode          = $LASTEXITCODE
                Output            = $Output
                InventoryReached  = (Test-Path -Path $env:RDA_TEST_INVENTORY_MARKER)
                UsageQueried      = (Test-Path -Path $env:RDA_TEST_USAGE_MARKER)
            }
        }
    }

    AfterAll {
        Remove-Item Env:\RDA_TEST_INVENTORY_MARKER, Env:\RDA_TEST_USAGE_MARKER, Env:\RDA_TEST_ROLES -ErrorAction SilentlyContinue
    }

    It 'exits 1 before any inventory or collector work when consumption returns no values and only Azure grants the usage permission' {
        $Run = Invoke-DirectRun -Mode 'empty' -Roles 'permissions-only'
        $Run.ExitCode | Should -Be 1
        $Run.UsageQueried | Should -BeTrue
        $Run.InventoryReached | Should -BeFalse
        $Run.Output | Should -Match 'Placeholder subscription \(12345678-1234-1234-1234-123456789012\): NoRows'
    }

    It 'passes the role check records in: no values with the usage permission confirmed by both answers continues with a warning' {
        $Run = Invoke-DirectRun -Mode 'empty'
        $Run.UsageQueried | Should -BeTrue
        $Run.InventoryReached | Should -BeTrue
        $Run.ExitCode | Should -Be 3
        $Run.Output | Should -Match '\[NoUsage\] Placeholder subscription - the query succeeded but returned no usage rows; the usage permission is confirmed by the role assignments and by Azure \(Reader at subscription\)'
        $Run.Output | Should -Match 'WARNING: no usage above zero for '
    }

    It 'continues into inventory when consumption returns values' {
        $Run = Invoke-DirectRun -Mode 'values'
        $Run.InventoryReached | Should -BeTrue
        $Run.ExitCode | Should -Be 3
        $Run.Output | Should -Match 'Consumption data confirmed'
    }

    It 'does not check consumption under -SkipConsumption' {
        $Run = Invoke-DirectRun -Mode 'empty' -SkipConsumption
        $Run.UsageQueried | Should -BeFalse
        $Run.InventoryReached | Should -BeTrue
    }
}
