# Public IP -> associated-resource cross-reference tests
# Run with: Invoke-Pester ./Tests/PublicIpAssociation.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# A public IP has TWO association surfaces and the collector used to read only
# one. 'ipConfiguration' is set when the IP is attached to a NIC or a
# load-balancer frontend; 'natGateway' is set when it is attached to a NAT
# gateway. They are separate properties on the ARM PublicIPAddress type, and a
# NAT-gateway-attached IP has NO ipConfiguration at all.
#
# The result was a row that contradicted itself: the Use flag already counted
# natGateway, so the IP was correctly reported 'Utilized' while the association
# fields fell through to the unassociated branch and emitted the literal 'None'
# - in use, associated with nothing - with the real association sitting unread
# in properties.natGateway.id.
#
# The live shapes asserted below were CONFIRMED against a real Azure tenant: on
# a NAT-gateway-only public IP, Resource Graph omits the ipConfiguration key
# ENTIRELY (it is not present-and-null), and returns natGateway = @{ id = ... }.
# The fixtures reproduce that exactly, including the absent key, because
# "absent" and "present but null" are different shapes and only one of them is
# what Azure actually sends.
#
# Casing note: every data-fetch call site passes -Lowercase to
# Invoke-AzGraphQuerySafe, which lowercases KEYS AND VALUES via a JSON
# round-trip. So the provider type extracted from an ARM id is 'natgateways' /
# 'networkinterfaces' in lower case, not the PascalCase spelling from the ARM
# docs. These fixtures are pre-lowercased to match what collectors really see.
#
# No live Azure. No StrictMode - production never sets it, and under StrictMode
# reading an ABSENT property throws instead of yielding $null, which would make
# these fixtures behave in a way production never does.

BeforeAll {
    $script:Collector = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'Services', 'Networking', 'PublicIP.ps1' | Resolve-Path | Select-Object -ExpandProperty Path

    # Canonical Azure documentation placeholder GUID - not a real identifier.
    $script:DocGuid = '12345678-1234-1234-1234-123456789012'
    $script:Base = "/subscriptions/$($script:DocGuid)/resourcegroups/rg-net/providers"

    $script:NatId = "$($script:Base)/microsoft.network/natgateways/nat-egress01"
    $script:NicCfgId = "$($script:Base)/microsoft.network/networkinterfaces/nic01/ipconfigurations/ipconfig1"
    $script:PipId = "$($script:Base)/microsoft.network/publicipaddresses/pip01"

    $script:NatToken = "prod_$($script:DocGuid)"

    $script:Subs = @([pscustomobject]@{ id = $script:DocGuid; Name = "prod_sub_$($script:DocGuid)" })

    # The 12 emitted field names, frozen. This fix changes emitted VALUES only;
    # any drift in the key set here is a schema change and must fail.
    $script:ExpectedFields = @(
        'ID', 'Subscription', 'ResourceGroup', 'Name', 'SKU', 'Location',
        'AllocationType', 'Version', 'ProvisioningState', 'Use',
        'AssociatedResource', 'AssociatedResourceType'
    )

    # Build one public IP record in the post-(-Lowercase) shape collectors consume.
    # -IpConfigurationId / -NatGatewayId omitted => that property is ABSENT from
    # properties entirely, which is what Azure actually returns.
    function New-PublicIpRecord
    {
        param(
            [string]$IpConfigurationId,
            [string]$NatGatewayId
        )

        $Props = [pscustomobject]@{
            provisioningstate        = 'succeeded'
            publicipallocationmethod = 'static'
            publicipaddressversion   = 'ipv4'
            ipaddress                = '203.0.113.10'
            idletimeoutinminutes     = 4
        }

        if ($PSBoundParameters.ContainsKey('IpConfigurationId'))
        {
            $Props | Add-Member -NotePropertyName 'ipconfiguration' -NotePropertyValue ([pscustomobject]@{ id = $IpConfigurationId })
        }
        if ($PSBoundParameters.ContainsKey('NatGatewayId'))
        {
            $Props | Add-Member -NotePropertyName 'natgateway' -NotePropertyValue ([pscustomobject]@{ id = $NatGatewayId })
        }

        return [pscustomobject]@{
            TYPE           = 'microsoft.network/publicipaddresses'
            id             = $script:PipId
            NAME           = 'pip01'
            RESOURCEGROUP  = 'rg-net'
            LOCATION       = 'westeurope'
            subscriptionId = $script:DocGuid
            SKU            = [pscustomobject]@{ name = 'standard' }
            PROPERTIES     = $Props
        }
    }

    function Invoke-PublicIpCollector
    {
        param($Resources, $Dictionary)
        $Result = & $script:Collector -Sub $script:Subs -Resources $Resources -Task 'Processing' -ResourceIdDictionary $Dictionary
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

Describe 'Public IP attached ONLY to a NAT gateway (the reported bug)' {

    It 'reads the association from natGateway.id instead of reporting None' {
        $Rec = Invoke-PublicIpCollector -Resources @(New-PublicIpRecord -NatGatewayId $script:NatId) -Dictionary $null

        $Rec.AssociatedResource | Should -BeExactly 'nat-egress01' -Because 'the association was sitting unread in properties.natGateway.id'
        $Rec.AssociatedResourceType | Should -BeExactly 'natgateways' -Because '-Lowercase lowercases values, so the provider type is not PascalCase'
    }

    It 'still reports Use as Utilized' {
        $Rec = Invoke-PublicIpCollector -Resources @(New-PublicIpRecord -NatGatewayId $script:NatId) -Dictionary $null
        $Rec.Use | Should -BeExactly 'Utilized'
    }

    It 'resolves to the SAME obfuscated token the NATGateway collector emitted' {
        $Dict = New-Dictionary -Entries @{ $script:NatId = $script:NatToken }

        $Rec = Invoke-PublicIpCollector -Resources @(New-PublicIpRecord -NatGatewayId $script:NatId) -Dictionary $Dict

        $Rec.AssociatedResource | Should -BeExactly $script:NatToken -Because 'a NAT gateway is a first-class collected resource, so this is a usable cross-reference, not a sentinel'
    }

    It 'resolves the NAT gateway even when the dictionary key differs only in case' {
        # Production keys the dictionary with OrdinalIgnoreCase, so the collector
        # deliberately does no casing work of its own. This proves it may not have to -
        # and would fail if someone replaced the comparer with a case-sensitive one.
        $Dict = New-Dictionary -Entries @{ $script:NatId.ToUpperInvariant() = $script:NatToken }

        $Rec = Invoke-PublicIpCollector -Resources @(New-PublicIpRecord -NatGatewayId $script:NatId) -Dictionary $Dict

        $Rec.AssociatedResource | Should -BeExactly $script:NatToken -Because 'the dictionary is case-insensitive by construction'
    }

    It "falls back to 'obfuscated' when the NAT gateway is out of scope for the run" {
        $Dict = New-Dictionary -Entries @{ "$($script:Base)/microsoft.network/natgateways/some-other-nat" = 'prod_unrelated' }

        $Rec = Invoke-PublicIpCollector -Resources @(New-PublicIpRecord -NatGatewayId $script:NatId) -Dictionary $Dict

        $Rec.AssociatedResource | Should -BeExactly 'obfuscated'
    }

    It 'never leaks the raw ARM path when obfuscation is on' {
        $Dict = New-Dictionary -Entries @{ $script:NatId = $script:NatToken }

        $Rec = Invoke-PublicIpCollector -Resources @(New-PublicIpRecord -NatGatewayId $script:NatId) -Dictionary $Dict

        # Assert the field is POPULATED before asserting it does not leak. Without
        # this, an absent or null value satisfies every -Not -Match below and the leak
        # gate passes without checking anything.
        $Rec.AssociatedResource | Should -Not -BeNullOrEmpty -Because 'a no-leak assertion on an empty value proves nothing'
        $Rec.AssociatedResource | Should -Match '^(prod|nonprod)_[0-9a-f]{8}-' -Because 'the value must be a token, not merely non-leaking'

        $Rec.AssociatedResource | Should -Not -Match 'microsoft\.network'
        $Rec.AssociatedResource | Should -Not -Match '/subscriptions/'
    }
}

Describe 'Public IP attached via ipConfiguration (must be unchanged by the fix)' {

    It 'extracts the NIC name and provider type' {
        $Rec = Invoke-PublicIpCollector -Resources @(New-PublicIpRecord -IpConfigurationId $script:NicCfgId) -Dictionary $null

        $Rec.AssociatedResource | Should -BeExactly 'nic01'
        $Rec.AssociatedResourceType | Should -BeExactly 'networkinterfaces'
        $Rec.Use | Should -BeExactly 'Utilized'
    }

    It "falls back to 'obfuscated' under obfuscation because an ipConfiguration child path is never a dictionary key" {
        $Dict = New-Dictionary -Entries @{ $script:NatId = $script:NatToken }

        $Rec = Invoke-PublicIpCollector -Resources @(New-PublicIpRecord -IpConfigurationId $script:NicCfgId) -Dictionary $Dict

        $Rec.AssociatedResource | Should -BeExactly 'obfuscated'
    }

    It 'prefers ipConfiguration when BOTH surfaces are populated, so no existing row changes value' {
        $Rec = Invoke-PublicIpCollector -Resources @(New-PublicIpRecord -IpConfigurationId $script:NicCfgId -NatGatewayId $script:NatId) -Dictionary $null

        $Rec.AssociatedResource | Should -BeExactly 'nic01'
        $Rec.AssociatedResourceType | Should -BeExactly 'networkinterfaces'
    }
}

Describe 'Public IP attached to nothing' {

    It "preserves the long-standing 'None' sentinel a consumer may key on" {
        $Rec = Invoke-PublicIpCollector -Resources @(New-PublicIpRecord) -Dictionary $null

        $Rec.AssociatedResource | Should -BeExactly 'None'
        $Rec.AssociatedResourceType | Should -BeExactly 'None'
    }

    It "keeps 'None' under obfuscation too - it is a sentinel, not an identifier" {
        $Dict = New-Dictionary -Entries @{ $script:NatId = $script:NatToken }

        $Rec = Invoke-PublicIpCollector -Resources @(New-PublicIpRecord) -Dictionary $Dict

        $Rec.AssociatedResource | Should -BeExactly 'None'
        $Rec.AssociatedResourceType | Should -BeExactly 'None'
    }

    It 'reports Use as UnderUtilized' {
        $Rec = Invoke-PublicIpCollector -Resources @(New-PublicIpRecord) -Dictionary $null
        $Rec.Use | Should -BeExactly 'UnderUtilized'
    }
}

Describe 'Emitted contract' {

    It 'emits exactly the 12 established field names for every association shape' {
        $Shapes = @(
            @{ Label = 'nat-only'; Rec = (New-PublicIpRecord -NatGatewayId $script:NatId) }
            @{ Label = 'ipconfig-only'; Rec = (New-PublicIpRecord -IpConfigurationId $script:NicCfgId) }
            @{ Label = 'both'; Rec = (New-PublicIpRecord -IpConfigurationId $script:NicCfgId -NatGatewayId $script:NatId) }
            @{ Label = 'neither'; Rec = (New-PublicIpRecord) }
        )

        foreach ($S in $Shapes)
        {
            $Rec = Invoke-PublicIpCollector -Resources @($S.Rec) -Dictionary $null
            $Names = @($Rec.Keys) | Sort-Object
            $Names | Should -Be (@($script:ExpectedFields) | Sort-Object) -Because "the $($S.Label) shape must emit the frozen field set - this fix changes values, not schema"
        }
    }

    It 'never emits a row that is Utilized but associated with nothing (the exact bug signature)' {
        $Labelled = @(
            @{ Label = 'nat-only'; Rec = (New-PublicIpRecord -NatGatewayId $script:NatId); Utilized = $true }
            @{ Label = 'ipconfig-only'; Rec = (New-PublicIpRecord -IpConfigurationId $script:NicCfgId); Utilized = $true }
            @{ Label = 'both'; Rec = (New-PublicIpRecord -IpConfigurationId $script:NicCfgId -NatGatewayId $script:NatId); Utilized = $true }
            @{ Label = 'neither'; Rec = (New-PublicIpRecord); Utilized = $false }
        )

        $UtilizedSeen = 0
        $UnderUtilizedSeen = 0

        foreach ($S in $Labelled)
        {
            foreach ($Dict in @($null, (New-Dictionary -Entries @{ $script:NatId = $script:NatToken })))
            {
                $Rec = Invoke-PublicIpCollector -Resources @($S.Rec) -Dictionary $Dict

                # Pin the Use value per shape, so the conditional below is reached for
                # the reason expected rather than by accident.
                $Expected = if ($S.Utilized) { 'Utilized' } else { 'UnderUtilized' }
                $Rec.Use | Should -BeExactly $Expected -Because "the $($S.Label) shape must be $Expected"

                if ($Rec.Use -eq 'Utilized')
                {
                    $UtilizedSeen++
                    $Rec.AssociatedResource | Should -Not -BeExactly 'None' -Because "the $($S.Label) shape cannot be in use and associated with nothing"
                    $Rec.AssociatedResourceType | Should -Not -BeExactly 'None' -Because "the $($S.Label) shape cannot be in use and associated with nothing"
                }
                else
                {
                    $UnderUtilizedSeen++
                }
            }
        }

        # Without these the whole It could go green having evaluated ZERO leak
        # assertions - if the Use computation regressed to always 'UnderUtilized', or
        # the collector stopped emitting, the guarded branch would simply never run.
        $UtilizedSeen | Should -Be 6 -Because '3 associated shapes x 2 dictionaries must each report Utilized and be checked'
        $UnderUtilizedSeen | Should -Be 2 -Because 'only the unassociated shape may be UnderUtilized'
    }
}
