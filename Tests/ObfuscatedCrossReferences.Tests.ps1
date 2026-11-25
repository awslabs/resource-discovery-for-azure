# Obfuscated cross-reference tests: Front Door WAF policy and AVD session host name
# Run with: Invoke-Pester ./Tests/ObfuscatedCrossReferences.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# Under -Obfuscate a cross-reference column must hold the token of the resource
# it points at, so it still joins to that resource's row and Reveal.ps1 can
# restore it:
#   - Frontdoor WebApplicationFirewall: a classic Front Door lists its WAF policy
#     link per frontend endpoint, so the property walk returns one id per linked
#     endpoint. Two or more linked endpoints (a default endpoint and a custom
#     domain, say) gave an array, which missed the dictionary lookup and wrote
#     'obfuscated'. The column names every distinct policy (sorted by id, joined
#     with ', '), each its own token under -Obfuscate, and says how many
#     endpoints have no policy, in plain runs too.
#   - AVD Hostname: in a plain run it is the backing VM's name, so under
#     -Obfuscate it must be the name token that VM's own row gets. It was a hash
#     of the VM id, which matched no row and no dictionary entry.
#
# The test invokes the REAL collectors with records shaped the way the
# inventory builds them (JSON text lowercased, then ConvertFrom-Json) and the
# id and name dictionaries keyed by real resource id, as RunInventorySetup in
# ResourceInventory.ps1 fills them before any collector runs. Tokens are made
# at run time; the subscription id is the documentation placeholder. No live
# Azure.

BeforeAll {
    $script:ServicesRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'Services' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:SubId = '12345678-1234-1234-1234-123456789012'
    $script:Subs = @([pscustomobject]@{ id = $script:SubId; Name = 'sub-demo' })

    function ConvertTo-InventoryRecord
    {
        param($Records)
        (ConvertTo-Json -InputObject @($Records) -Depth 20).ToLower() | ConvertFrom-Json
    }

    function New-Token { 'prod_' + [guid]::NewGuid().ToString() }

    # The masked id RunInventorySetup stores for a resource: the ARM shape with the
    # subscription, resource group and name segments replaced by tokens.
    function New-MaskedId
    {
        param([string]$RealId, [string]$NameToken)
        $Parts = $RealId.Split('/')
        $Parts[2] = New-Token
        $Parts[4] = New-Token
        $Parts[-1] = $NameToken
        $Parts -join '/'
    }

    function Invoke-Collector
    {
        param([string]$Path, $Records, $IdDictionary)
        @(& (Join-Path $script:ServicesRoot $Path) -Sub $script:Subs -Resources (ConvertTo-InventoryRecord $Records) -Task 'Processing' -ResourceIdDictionary $IdDictionary)
    }

    $Edge = "/subscriptions/$($script:SubId)/resourcegroups/rg-edge/providers"
    $script:WafA = "$Edge/microsoft.network/frontdoorwebapplicationfirewallpolicies/wafpolicya"
    $script:WafB = "$Edge/microsoft.network/frontdoorwebapplicationfirewallpolicies/wafpolicyb"
    $script:WafC = "$Edge/microsoft.network/frontdoorwebapplicationfirewallpolicies/wafpolicyc"

    function New-FrontDoor
    {
        # $Links: one entry per frontend endpoint; $null = no WAF link object,
        # 'null' = the link set to null, '' = a link object with an empty id,
        # else the linked policy id.
        param([string]$Name, [object[]]$Links)
        $i = 0
        $Endpoints = foreach ($Link in $Links)
        {
            $i++
            $Props = [ordered]@{ hostName = "$Name-$i.azurefd.net"; sessionAffinityEnabledState = 'Disabled' }
            if ($Link -eq 'null') { $Props.webApplicationFirewallPolicyLink = $null }
            elseif ($null -ne $Link) { $Props.webApplicationFirewallPolicyLink = @{ id = $Link } }
            [ordered]@{ name = "endpoint$i"; properties = $Props }
        }
        [ordered]@{
            id = "$Edge/microsoft.network/frontdoors/$Name"; name = $Name; type = 'microsoft.network/frontdoors'; location = 'global'
            subscriptionId = $script:SubId; resourceGroup = 'rg-edge'; properties = [ordered]@{ enabledState = 'Enabled'; frontendEndpoints = @($Endpoints) }
        }
    }

    function Get-WafColumn
    {
        param($FrontDoor, $IdDictionary)
        @(Invoke-Collector -Path 'Infrastructure/Frontdoor.ps1' -Records @($FrontDoor) -IdDictionary $IdDictionary)[0].WebApplicationFirewall
    }

    $script:WafDict = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    $script:WafATok = New-MaskedId $script:WafA (New-Token)
    $script:WafBTok = New-MaskedId $script:WafB (New-Token)
    $script:WafDict[$script:WafA] = $script:WafATok
    $script:WafDict[$script:WafB] = $script:WafBTok
}

Describe 'Front Door WAF policy column' {
    It 'holds the policy token when two endpoints link the same policy (obfuscated)' {
        Get-WafColumn (New-FrontDoor 'fd-two' @($script:WafA, $script:WafA)) $script:WafDict | Should -BeExactly $script:WafATok
    }

    It 'holds the policy token when one endpoint links it (obfuscated)' {
        Get-WafColumn (New-FrontDoor 'fd-one' @($script:WafA)) $script:WafDict | Should -BeExactly $script:WafATok
    }

    It 'names every policy, sorted by id, when endpoints link different policies (obfuscated and plain)' {
        Get-WafColumn (New-FrontDoor 'fd-split' @($script:WafA, $script:WafB)) $script:WafDict | Should -BeExactly "$($script:WafATok), $($script:WafBTok)"
        Get-WafColumn (New-FrontDoor 'fd-split' @($script:WafA, $script:WafB)) $null | Should -BeExactly 'wafpolicya, wafpolicyb'
        Get-WafColumn (New-FrontDoor 'fd-split' @($script:WafB, $script:WafA, $script:WafB)) $script:WafDict | Should -BeExactly "$($script:WafATok), $($script:WafBTok)"
        Get-WafColumn (New-FrontDoor 'fd-split' @($script:WafB, $script:WafA, $script:WafB)) $null | Should -BeExactly 'wafpolicya, wafpolicyb'
    }

    It 'counts an endpoint with no link or an empty link id as without WAF' {
        Get-WafColumn (New-FrontDoor 'fd-mixed' @($null, '', $script:WafB)) $script:WafDict | Should -BeExactly "$($script:WafBTok) (2 of 3 endpoints without WAF)"
        Get-WafColumn (New-FrontDoor 'fd-mixed' @($null, '', $script:WafB)) $null | Should -BeExactly 'wafpolicyb (2 of 3 endpoints without WAF)'
    }

    It 'says how many endpoints have no policy when two of three are unlinked (obfuscated and plain)' {
        $Fd = New-FrontDoor 'fd-partial' @('null', $null, $script:WafB)
        Get-WafColumn $Fd $script:WafDict | Should -BeExactly "$($script:WafBTok) (2 of 3 endpoints without WAF)"
        Get-WafColumn $Fd $null | Should -BeExactly 'wafpolicyb (2 of 3 endpoints without WAF)'
    }

    It 'writes the policy, not its resource type, when an empty link comes first (obfuscated and plain)' {
        $Fd = New-FrontDoor 'fd-emptyfirst' @('', $script:WafB)
        Get-WafColumn $Fd $script:WafDict | Should -BeExactly "$($script:WafBTok) (1 of 2 endpoints without WAF)"
        Get-WafColumn $Fd $null | Should -BeExactly 'wafpolicyb (1 of 2 endpoints without WAF)'
    }

    It 'names both policies and the endpoint without one together (obfuscated and plain)' {
        $Fd = New-FrontDoor 'fd-both' @($script:WafB, 'null', $script:WafA)
        Get-WafColumn $Fd $script:WafDict | Should -BeExactly "$($script:WafATok), $($script:WafBTok) (1 of 3 endpoints without WAF)"
        Get-WafColumn $Fd $null | Should -BeExactly 'wafpolicya, wafpolicyb (1 of 3 endpoints without WAF)'
    }

    It "writes 'False' when no endpoint has a link id" {
        Get-WafColumn (New-FrontDoor 'fd-none' @($null, '')) $script:WafDict | Should -BeExactly 'False'
        Get-WafColumn (New-FrontDoor 'fd-none' @($null)) $null | Should -BeExactly 'False'
        Get-WafColumn (New-FrontDoor 'fd-none' @('null', 'null')) $null | Should -BeExactly 'False'
        Get-WafColumn (New-FrontDoor 'fd-none' @()) $null | Should -BeExactly 'False'
    }

    It 'names the policy when two endpoints link it (plain)' {
        Get-WafColumn (New-FrontDoor 'fd-two' @($script:WafA, $script:WafA)) $null | Should -BeExactly 'wafpolicya'
    }

    It 'names the policy when one endpoint links it (plain)' {
        Get-WafColumn (New-FrontDoor 'fd-one' @($script:WafA)) $null | Should -BeExactly 'wafpolicya'
    }

    It "writes 'obfuscated' for a policy that is not in the dictionary (obfuscated)" {
        $Other = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Other['/subscriptions/x/other'] = New-Token
        Get-WafColumn (New-FrontDoor 'fd-two' @($script:WafA, $script:WafA)) $Other | Should -BeExactly 'obfuscated'
    }

    It "writes 'obfuscated' only for the policy that is not in the dictionary (obfuscated)" {
        Get-WafColumn (New-FrontDoor 'fd-other' @($script:WafC, $script:WafA)) $script:WafDict | Should -BeExactly "$($script:WafATok), obfuscated"
    }

    It "keeps a link id that is not a resource id whole (plain), and writes 'obfuscated' for it (obfuscated)" {
        Get-WafColumn (New-FrontDoor 'fd-bad' @('not-a-resource-id')) $null | Should -BeExactly 'not-a-resource-id'
        Get-WafColumn (New-FrontDoor 'fd-bad' @('not-a-resource-id')) $script:WafDict | Should -BeExactly 'obfuscated'
    }

    It "keeps 'Unknown' for a Standard or Premium profile" {
        $AfdProfile = [ordered]@{
            id = "$Edge/microsoft.cdn/profiles/afd-std"; name = 'afd-std'; type = 'microsoft.cdn/profiles'; location = 'global'
            subscriptionId = $script:SubId; resourceGroup = 'rg-edge'; sku = @{ name = 'Standard_AzureFrontDoor' }; properties = @{ provisioningState = 'Succeeded' }
        }
        Get-WafColumn $AfdProfile $script:WafDict | Should -BeExactly 'Unknown'
        Get-WafColumn $AfdProfile $null | Should -BeExactly 'Unknown'
    }
}

Describe 'Front Door WAF policy column after Reveal.ps1 -All' {
    BeforeAll {
        # An obfuscated report and dictionary in the shapes ResourceInventory.ps1 writes:
        # masked ids share the subscription and resource group tokens, and the
        # dictionary maps each token back to the real resource id.
        $script:RevealDir = Join-Path ([System.IO.Path]::GetTempPath()) ('WafReveal_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $Stage = Join-Path $script:RevealDir 'stage'
        New-Item -ItemType Directory -Path $Stage -Force | Out-Null
        $SubTok = New-Token
        $RgTok = New-Token
        $IdDict = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Dict = [ordered]@{
            GeneratedAt = '2026-10-28 00:00:00'; ResourceIdMap = [ordered]@{}; ResourceNameMap = [ordered]@{}
            SubscriptionMap = [ordered]@{ $SubTok = $script:WafA }; ResourceGroupMap = [ordered]@{ $RgTok = $script:WafA }
            SubscriptionNameMap = [ordered]@{ $SubTok = 'sub-demo' }; TagMap = [ordered]@{}; FreeTextMap = [ordered]@{}
        }
        foreach ($Id in @($script:WafA, $script:WafB))
        {
            $NameTok = New-Token
            $Masked = ($Id -replace '/subscriptions/[^/]+', "/subscriptions/$SubTok" -replace '/resourcegroups/[^/]+', "/resourcegroups/$RgTok") -replace '/[^/]+$', "/$NameTok"
            $IdDict[$Id] = $Masked
            $Dict.ResourceIdMap[$Masked] = $Id
            $Dict.ResourceNameMap[$NameTok] = $Id
        }
        $script:RevealIdDict = $IdDict
        $Row = @(Invoke-Collector -Path 'Infrastructure/Frontdoor.ps1' -Records @(New-FrontDoor 'fd-reveal' @($script:WafB, $null, $script:WafA)) -IdDictionary $IdDict)[0]
        $script:ObfuscatedWaf = $Row.WebApplicationFirewall
        [ordered]@{ Frontdoor = @($Row) } | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $Stage 'Inventory_Test.json') -Encoding utf8
        $Zip = Join-Path $script:RevealDir 'ResourcesReport_Test.zip'
        Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $Zip -Force
        $DictPath = Join-Path $script:RevealDir 'ObfuscationDictionary_Test.json'
        $Dict | ConvertTo-Json -Depth 6 | Set-Content -Path $DictPath -Encoding utf8
        $Out = Join-Path $script:RevealDir 'revealed.zip'
        & (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'Reveal.ps1') -InputZip $Zip -DictionaryPath $DictPath -All -OutputZip $Out *>&1 | Out-Null
        $Ex = Join-Path $script:RevealDir 'revealed'
        Expand-Archive -Path $Out -DestinationPath $Ex -Force
        $script:RevealedWaf = (Get-Content -Raw -Path (Join-Path $Ex 'Inventory_Test.json') | ConvertFrom-Json).Frontdoor[0].WebApplicationFirewall
    }

    AfterAll {
        if ($script:RevealDir -and (Test-Path $script:RevealDir)) { Remove-Item -Path $script:RevealDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'holds each policy as its own masked id (obfuscated)' {
        $script:ObfuscatedWaf | Should -BeExactly ("{0}, {1} (1 of 3 endpoints without WAF)" -f $script:RevealIdDict[$script:WafA], $script:RevealIdDict[$script:WafB])
    }

    It 'restores every policy and keeps the endpoint count' {
        $script:RevealedWaf | Should -Not -Match '(?:prod|nonprod)_(?:[a-z0-9]+_)?[0-9a-f]{8}-'
        $Policy = '/subscriptions/[^/,]+/resourcegroups/rg-edge/providers/microsoft\.network/frontdoorwebapplicationfirewallpolicies/'
        $script:RevealedWaf | Should -Match ('^{0}wafpolicya, {0}wafpolicyb \(1 of 3 endpoints without WAF\)$' -f $Policy)
    }
}

Describe 'AVD session host Hostname' {
    BeforeAll {
        $Avd = "/subscriptions/$($script:SubId)/resourcegroups/rg-avd/providers"
        $script:VmId = "$Avd/microsoft.compute/virtualmachines/avdhost-0"
        $script:AvdRecords = @(
            [ordered]@{
                id = "$Avd/microsoft.desktopvirtualization/hostpools/hp-demo"; name = 'hp-demo'; type = 'microsoft.desktopvirtualization/hostpools'; location = 'eastus'
                subscriptionId = $script:SubId; resourceGroup = 'rg-avd'; properties = [ordered]@{ hostPoolType = 'Pooled'; loadBalancerType = 'BreadthFirst'; maxSessionLimit = 10 }
            }
            [ordered]@{
                id = "$Avd/microsoft.desktopvirtualization/hostpools/hp-demo/sessionhosts/avdhost-0.contoso.example"; name = 'hp-demo/avdhost-0.contoso.example'
                type = 'microsoft.desktopvirtualization/hostpools/sessionhosts'; location = 'eastus'; subscriptionId = $script:SubId; resourceGroup = 'rg-avd'
                properties = [ordered]@{ resourceId = $script:VmId; agentVersion = '1.0.9'; status = 'Available' }
            }
            [ordered]@{
                id = $script:VmId; name = 'avdhost-0'; type = 'microsoft.compute/virtualmachines'; location = 'eastus'; subscriptionId = $script:SubId; resourceGroup = 'rg-avd'
                properties = [ordered]@{ hardwareProfile = @{ vmSize = 'Standard_D4s_v5' }; storageProfile = @{ osDisk = @{ osType = 'Windows'; managedDisk = @{ storageAccountType = 'Premium_LRS' } } } }
            }
        )
        $script:SavedNameDictionary = $Global:ResourceNameDictionary
    }

    AfterAll {
        $Global:ResourceNameDictionary = $script:SavedNameDictionary
    }

    BeforeEach {
        $script:VmName = New-Token
        $script:IdDict = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $script:IdDict[$script:VmId] = New-MaskedId $script:VmId $script:VmName
        $Global:ResourceNameDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:ResourceNameDictionary[$script:VmId] = $script:VmName
    }

    It "is the backing VM's name token, the Name that VM's row gets (obfuscated)" {
        $Row = @(Invoke-Collector -Path 'Compute/AVD.ps1' -Records $script:AvdRecords -IdDictionary $script:IdDict)[0]
        $Row.Hostname | Should -BeExactly $script:VmName
        $Row.HostId | Should -BeExactly $script:IdDict[$script:VmId]
    }

    It "is 'obfuscated' when the VM has no name token (obfuscated)" {
        $Global:ResourceNameDictionary.Clear()
        $Row = @(Invoke-Collector -Path 'Compute/AVD.ps1' -Records $script:AvdRecords -IdDictionary $script:IdDict)[0]
        $Row.Hostname | Should -BeExactly 'obfuscated'
        $Row.HostId | Should -BeExactly $script:IdDict[$script:VmId]
    }

    It "is 'obfuscated' when there is no name dictionary (obfuscated)" {
        $Global:ResourceNameDictionary = $null
        $Row = @(Invoke-Collector -Path 'Compute/AVD.ps1' -Records $script:AvdRecords -IdDictionary $script:IdDict)[0]
        $Row.Hostname | Should -BeExactly 'obfuscated'
    }

    It "is the VM's name, and HostId its id (plain)" {
        $Global:ResourceNameDictionary = $null
        $Row = @(Invoke-Collector -Path 'Compute/AVD.ps1' -Records $script:AvdRecords -IdDictionary $null)[0]
        $Row.Hostname | Should -BeExactly 'avdhost-0'
        $Row.HostId | Should -BeExactly $script:VmId
    }
}
