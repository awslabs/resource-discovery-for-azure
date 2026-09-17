# App Insights -> Log Analytics workspace cross-reference tests
# Run with: Invoke-Pester ./Tests/AppInsightsWorkspaceLink.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# A workspace-based Application Insights component stores its telemetry in a Log
# Analytics workspace, and properties.WorkspaceResourceId is the ARM id of that
# workspace. The collector emits it as 'WorkspaceResourceId'.
#
# Two things have to hold and neither is self-evident:
#
#   1. The value is a full ARM id carrying the real subscription GUID and the
#      real resource group name, so an obfuscated run MUST route it through
#      $ResourceIdDictionary. Emitting it raw would leak both, and the generic
#      whole-file GUID scan in Tests/Obfuscation.Tests.ps1 is the only other net.
#
#   2. The workspace is itself a collected resource (Services/Analytics/
#      WrkSpace.ps1), so the token must be the SAME one that collector's row
#      carries - otherwise the link is decoration rather than a usable join. The
#      cross-collector test below invokes BOTH real collectors against one shared
#      dictionary, seeding the component's link in a DIFFERENT CASE from the
#      workspace row's id, so the two sides can only agree if neither collector
#      does its own casing work and the dictionary really is case-insensitive.
#
# A CLASSIC (non-workspace-based) component has no workspace at all and gets
# 'None' - the sentinel SQLVM, SQLDB and PublicIP already use for an absent
# cross-reference. The live sandbox contains no classic component, so that path
# can only be covered here.
#
# Live-confirmed shapes: on a workspace-based component the key is present and
# lowercased ('workspaceresourceid') with a fully lowercased ARM id value,
# because every data-fetch call site passes -Lowercase to
# Invoke-AzGraphQuerySafe, which lowercases KEYS AND VALUES. Property reads in
# PowerShell are case-insensitive, so the collector's PascalCase read works.
#
# No live Azure. No StrictMode - production never sets it, and under StrictMode
# reading an ABSENT property throws instead of yielding $null.

BeforeAll {
    $script:AiCollector = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'Services', 'Integration', 'AppInsights.ps1' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:WsCollector = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'Services', 'Analytics', 'WrkSpace.ps1' | Resolve-Path | Select-Object -ExpandProperty Path

    # Canonical Azure documentation placeholder GUID - not a real identifier.
    $script:DocGuid = '12345678-1234-1234-1234-123456789012'
    $script:WsId = "/subscriptions/$($script:DocGuid)/resourcegroups/rg-obs/providers/microsoft.operationalinsights/workspaces/law-shared01"
    $script:AiId = "/subscriptions/$($script:DocGuid)/resourcegroups/rg-obs/providers/microsoft.insights/components/appi-web01"
    $script:WsToken = "prod_$($script:DocGuid)"

    $script:Subs = @([pscustomobject]@{ id = $script:DocGuid; Name = "prod_sub_$($script:DocGuid)" })

    # The 13 emitted field names after adding WorkspaceResourceId. Frozen so an
    # unreviewed schema change fails here.
    $script:ExpectedFields = @(
        'ID', 'Subscription', 'ResourceGroup', 'Name', 'Location',
        'ApplicationType', 'FlowType', 'Version', 'DataSampling',
        'RetentionInDays', 'IngestionMode', 'WorkspaceResourceId', 'CreatedTime'
    )

    # -WorkspaceResourceId omitted => the property is ABSENT from properties
    # entirely, which is what Azure returns for a classic component.
    function New-ComponentRecord
    {
        param([string]$WorkspaceResourceId)

        $Props = [pscustomobject]@{
            provisioningstate = 'succeeded'
            application_type  = 'web'
            flow_type         = 'bluefield'
            ver               = 'v2'
            retentionindays   = 90
            creationdate      = '2026-01-15T09:30:00.0000000+00:00'
            ingestionmode     = 'applicationinsights'
        }

        if ($PSBoundParameters.ContainsKey('WorkspaceResourceId'))
        {
            $Props | Add-Member -NotePropertyName 'workspaceresourceid' -NotePropertyValue $WorkspaceResourceId -Force
            $Props.ingestionmode = 'loganalytics'
        }

        return [pscustomobject]@{
            TYPE           = 'microsoft.insights/components'
            id             = $script:AiId
            NAME           = 'appi-web01'
            RESOURCEGROUP  = 'rg-obs'
            LOCATION       = 'westeurope'
            subscriptionId = $script:DocGuid
            PROPERTIES     = $Props
        }
    }

    function New-WorkspaceRecord
    {
        return [pscustomobject]@{
            TYPE           = 'microsoft.operationalinsights/workspaces'
            id             = $script:WsId
            NAME           = 'law-shared01'
            RESOURCEGROUP  = 'rg-obs'
            LOCATION       = 'westeurope'
            subscriptionId = $script:DocGuid
            PROPERTIES     = [pscustomobject]@{
                sku             = [pscustomobject]@{ name = 'pergb2018' }
                retentionindays = 30
                createddate     = '2025-11-02T11:00:00.0000000+00:00'
            }
        }
    }

    function Invoke-Collector
    {
        param($Path, $Resources, $Dictionary)
        $Result = & $Path -Sub $script:Subs -Resources $Resources -Task 'Processing' -ResourceIdDictionary $Dictionary
        return @($Result)[0]
    }

    # OrdinalIgnoreCase, matching how ResourceInventory.ps1 builds
    # $Global:ResourceIdDictionary. A plain Dictionary[string,string] would be
    # CASE-SENSITIVE - stricter than production - so a fixture without the
    # comparer silently fails to exercise the case-insensitivity the collector
    # actually relies on.
    function New-Dictionary
    {
        param([hashtable]$Entries = @{})
        $D = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($k in $Entries.Keys) { $D[$k] = $Entries[$k] }
        return $D
    }
}

Describe 'Workspace-based App Insights component' {

    It 'emits the full raw workspace ARM id when obfuscation is off' {
        $Rec = Invoke-Collector -Path $script:AiCollector -Resources @(New-ComponentRecord -WorkspaceResourceId $script:WsId) -Dictionary $null

        $Rec.WorkspaceResourceId | Should -BeExactly $script:WsId -Because 'the field name says ResourceId, so a non-obfuscated run carries the id'
    }

    It 'resolves to the workspace token when the workspace is in the dictionary' {
        $Dict = New-Dictionary -Entries @{ $script:WsId = $script:WsToken }

        $Rec = Invoke-Collector -Path $script:AiCollector -Resources @(New-ComponentRecord -WorkspaceResourceId $script:WsId) -Dictionary $Dict

        $Rec.WorkspaceResourceId | Should -BeExactly $script:WsToken
    }

    It 'resolves the workspace even when the dictionary key differs only in case' {
        # Production keys the dictionary with OrdinalIgnoreCase, so the collector
        # deliberately does no casing work of its own. This proves it may not have to -
        # and would fail if someone replaced the comparer with a case-sensitive one.
        $Dict = New-Dictionary -Entries @{ $script:WsId.ToUpperInvariant() = $script:WsToken }

        $Rec = Invoke-Collector -Path $script:AiCollector -Resources @(New-ComponentRecord -WorkspaceResourceId $script:WsId) -Dictionary $Dict

        $Rec.WorkspaceResourceId | Should -BeExactly $script:WsToken -Because 'the dictionary is case-insensitive by construction'
    }

    It "falls back to 'obfuscated' when the workspace is out of scope for the run" {
        $Dict = New-Dictionary -Entries @{ "/subscriptions/$($script:DocGuid)/resourcegroups/rg-other/providers/microsoft.operationalinsights/workspaces/law-other" = 'prod_unrelated' }

        $Rec = Invoke-Collector -Path $script:AiCollector -Resources @(New-ComponentRecord -WorkspaceResourceId $script:WsId) -Dictionary $Dict

        $Rec.WorkspaceResourceId | Should -BeExactly 'obfuscated' -Because 'an out-of-scope workspace must not leak its real id'
    }

    It 'never leaks the real subscription GUID or resource group under obfuscation' {
        foreach ($Dict in @((New-Dictionary -Entries @{ $script:WsId = $script:WsToken }), (New-Dictionary -Entries @{ 'x' = 'y' })))
        {
            $Rec = Invoke-Collector -Path $script:AiCollector -Resources @(New-ComponentRecord -WorkspaceResourceId $script:WsId) -Dictionary $Dict

            # Assert the field is POPULATED before asserting it does not leak.
            # Without this, an absent or null field satisfies every -Not -Match
            # below and the check passes without checking anything.
            $Rec.WorkspaceResourceId | Should -Not -BeNullOrEmpty -Because 'a no-leak assertion on an empty value proves nothing'
            # Deliberately a LOOSER shape check than $script:ObfuscationPattern in
            # Tests/Obfuscation.Tests.ps1, which remains the single owner of the exact
            # token contract and is the gate applied to a real generated bundle. This is
            # a unit fixture, so it only needs to distinguish "a token" from "a real
            # identifier"; duplicating the full anchored pattern here is what let a
            # second, drifted copy of it exist in the past.
            $Rec.WorkspaceResourceId | Should -Match '^((prod|nonprod)_[0-9a-f]{8}-|obfuscated$)' -Because 'the value must be a token or the obfuscated sentinel, not merely non-leaking'

            $Rec.WorkspaceResourceId | Should -Not -Match '/subscriptions/' -Because 'the value carries a real subscription GUID and RG name'
            $Rec.WorkspaceResourceId | Should -Not -Match 'rg-obs'
            $Rec.WorkspaceResourceId | Should -Not -Match 'law-shared01'
        }
    }
}

Describe 'Classic (non-workspace-based) App Insights component' {

    It "emits 'None' when the component has no workspace at all" {
        $Rec = Invoke-Collector -Path $script:AiCollector -Resources @(New-ComponentRecord) -Dictionary $null

        $Rec.WorkspaceResourceId | Should -BeExactly 'None'
    }

    It "emits 'None' under obfuscation too - absent is not a hidden value" {
        $Dict = New-Dictionary -Entries @{ $script:WsId = $script:WsToken }

        $Rec = Invoke-Collector -Path $script:AiCollector -Resources @(New-ComponentRecord) -Dictionary $Dict

        $Rec.WorkspaceResourceId | Should -BeExactly 'None' -Because "'obfuscated' would falsely imply a workspace exists and is being hidden"
    }
}

Describe 'Cross-collector agreement with WrkSpace.ps1' {

    It 'carries the SAME token the workspace row resolves to, so the join works' {
        # The component's link is seeded UPPER-CASE while the workspace row and the
        # dictionary key use the original casing. That is what makes this a real
        # cross-collector check rather than a restatement of the fixture: if either
        # collector did its own casing work, or the dictionary were case-sensitive,
        # the two sides would resolve differently and the join would break.
        $Dict = New-Dictionary -Entries @{ $script:WsId = $script:WsToken }
        $Resources = @((New-ComponentRecord -WorkspaceResourceId $script:WsId.ToUpperInvariant()), (New-WorkspaceRecord))

        $Ai = Invoke-Collector -Path $script:AiCollector -Resources $Resources -Dictionary $Dict
        $Ws = Invoke-Collector -Path $script:WsCollector -Resources $Resources -Dictionary $Dict

        # WrkSpace.ps1 emits the raw id; the central obfuscation pass in
        # ResourceInventory.ps1 maps that ID through the same dictionary. So the
        # token the workspace row ends up with is $Dict[$Ws.ID], and the App
        # Insights link must equal it.
        $Dict.ContainsKey($Ws.ID) | Should -BeTrue -Because 'both collectors must key on the same lowercased id'
        $Ai.WorkspaceResourceId | Should -BeExactly $Dict[$Ws.ID] -Because 'the cross-reference is only usable if both sides resolve to one token'
    }
}

Describe 'Emitted contract' {

    It 'emits exactly the 13 established field names for both component kinds' {
        $Shapes = @(
            @{ Label = 'workspace-based'; Rec = (New-ComponentRecord -WorkspaceResourceId $script:WsId) }
            @{ Label = 'classic'; Rec = (New-ComponentRecord) }
        )

        foreach ($S in $Shapes)
        {
            $Rec = Invoke-Collector -Path $script:AiCollector -Resources @($S.Rec) -Dictionary $null
            $Names = @($Rec.Keys) | Sort-Object
            $Names | Should -Be (@($script:ExpectedFields) | Sort-Object) -Because "the $($S.Label) component must emit the frozen field set"
        }
    }

    It 'leaves the pre-existing 12 fields untouched' {
        $Rec = Invoke-Collector -Path $script:AiCollector -Resources @(New-ComponentRecord -WorkspaceResourceId $script:WsId) -Dictionary $null

        $Rec.ID | Should -BeExactly $script:AiId
        $Rec.Subscription | Should -BeExactly "prod_sub_$($script:DocGuid)" -Because 'the collector joins the subscription name via $SUB | Where-Object { $_.id -eq $1.subscriptionId }'
        $Rec.Name | Should -BeExactly 'appi-web01'
        $Rec.ResourceGroup | Should -BeExactly 'rg-obs'
        $Rec.Location | Should -BeExactly 'westeurope'
        $Rec.ApplicationType | Should -BeExactly 'web'
        $Rec.FlowType | Should -BeExactly 'bluefield'
        $Rec.Version | Should -BeExactly 'v2'
        $Rec.RetentionInDays | Should -Be 90
        $Rec.IngestionMode | Should -BeExactly 'loganalytics'
        $Rec.DataSampling | Should -BeExactly 'Disabled' -Because 'an absent SamplingPercentage still maps to Disabled'

        # The collector casts the offset-bearing timestamp with [datetime], which
        # converts to LOCAL time. A hardcoded literal here would therefore pass in
        # UTC and fail in every other timezone. Derive the expectation through a
        # DIFFERENT api ([datetimeoffset].LocalDateTime) so this stays a real check
        # on the value and the format without being timezone-dependent.
        $ExpectedCreated = ([datetimeoffset]'2026-01-15T09:30:00.0000000+00:00').LocalDateTime.ToString('yyyy-MM-dd HH:mm')
        $Rec.CreatedTime | Should -BeExactly $ExpectedCreated
    }
}
