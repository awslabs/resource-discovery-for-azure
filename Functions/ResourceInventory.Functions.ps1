#Requires -Version 7.0

function GetLocalVersion()
{
    if ([string]::IsNullOrWhiteSpace($PSScriptRoot))
    {
        Write-Host 'Cannot resolve the script location ($PSScriptRoot is empty). Run the tool from its files on disk, not an inline script block. Exiting.' -ForegroundColor Red
        exit 1
    }

    $VersionJsonPath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Version.json'

    if (-not (Test-Path -LiteralPath $VersionJsonPath -PathType Leaf))
    {
        Write-Host ("Version.json not found at '{0}' (expected at the repo root, alongside ResourceInventory.ps1). Ensure the full repo is present. Exiting." -f $VersionJsonPath) -ForegroundColor Red
        exit 1
    }

    try
    {
        $LocalVersionJson = Get-Content -LiteralPath $VersionJsonPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch
    {
        Write-Host ("Version.json at '{0}' could not be read or parsed as JSON: {1}. Exiting." -f $VersionJsonPath, $_.Exception.Message) -ForegroundColor Red
        exit 1
    }

    return ('{0}.{1}.{2}' -f $LocalVersionJson.MajorVersion, $LocalVersionJson.MinorVersion, $LocalVersionJson.BuildVersion)
}

function Global:Protect-FreeTextValue([string]$Value)
{
    if ([string]::IsNullOrEmpty($Value)) { return $null }
    if ($null -eq $Global:FreeTextDictionary) { return $Value }
    if (-not $Global:FreeTextDictionary.ContainsKey($Value))
    {
        $TfPrefix = if ($Value -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or $Value -match '(^|-)([dts])-') { 'nonprod_' } else { 'prod_' }
        $Global:FreeTextDictionary[$Value] = $TfPrefix + [guid]::NewGuid().ToString()
    }
    return $Global:FreeTextDictionary[$Value]
}

function Global:ConvertTo-RdaMarketplaceRow
{
    # Maps ONE PSMarketplace-shaped row (as returned by Get-AzConsumptionMarketplace,
    # Az.Billing) to the flat object emitted into Marketplace_<ReportName>_<stamp>.csv.
    #
    # Field names are the documented PSMarketplace property names, verified from the
    # installed cmdlet's output type
    # ([Microsoft.Azure.Commands.Consumption.Models.PSMarketplace]) and the docs:
    #   https://learn.microsoft.com/en-us/powershell/module/az.billing/get-azconsumptionmarketplace
    #   https://learn.microsoft.com/en-us/rest/api/consumption/marketplaces/list  (api-version 2023-05-01)
    #
    # OBFUSCATION. When -Obfuscate is active the caller passes $Obfuscate = $true. PublisherName /
    # OfferName / PlanName are THIRD-PARTY PRODUCT identifiers (the "which ISV / which offer"
    # signal), not customer secrets, so they are left READABLE by design.
    # Every identifying field is masked:
    #   - OrderNumber is masked, unlike the three product fields above, because it identifies a
    #     specific customer PURCHASE rather than a product. It is tokenised through the shared
    #     free-text dictionary so the owner can reverse it; see the inline block below.
    #   - InstanceId is an ARM resource id, routed through Build-ObfuscatedResourceUri (which
    #     masks the embedded subscription and resource-group segments); its leaf resource-NAME
    #     cross-references the shared run-wide ID dictionary passed as -NameDictionary (URI-keyed),
    #     exactly as the first-party consumption path does.
    #   - SubscriptionGuid and SubscriptionName both identify ONE subscription, so both resolve to
    #     the SAME token via the shared run-wide subscription dictionary ($Global:ResourceSubscriptionDictionary,
    #     passed as -SubGuidTokenMap: a guid->token view the caller derives from it once). This is
    #     the P0 fix: without it SubscriptionGuid shipped RAW in the obfuscated, externally-shareable
    #     Marketplace_*.csv (no-customer-data-in-public.md). Routing it through the SHARED dictionary
    #     (not a fresh local token) is what makes the Marketplace row cross-reference every other
    #     sheet in the bundle for the same sub.
    #   - ResourceGroup cross-references the shared run-wide resource-group dictionary
    #     ($Global:ResourceResourceGroupDictionary, passed as -RgTokenMap: an rgName->token view),
    #     so a resource group that also appears in Inventory_*/Metrics_*/Consumption_* gets the SAME
    #     token here. When a sub/RG is absent from the shared maps (e.g. a Marketplace-only sub with
    #     no first-party resource inventoried), a deterministic local token is minted so the row is
    #     still internally consistent.
    #   - InstanceName is a leaf resource name with no shared-dictionary equivalent, tokenised
    #     deterministically within the run via the local NameCache.
    # NOTE: this deliberately DIVERGES from the first-party consumption path for the sub/RG dimensions
    # (consumption passes $null shared sub/RG dictionaries and emits no bare subscription-GUID column
    # at all). The divergence is intentional: the Marketplace CSV carries explicit SubscriptionGuid /
    # SubscriptionName / ResourceGroup columns that MUST cross-reference the rest of the bundle.
    param(
        [Parameter(Mandatory = $true)]$Row,
        [bool]$Obfuscate = $false,
        # URI-keyed shared resource-ID dictionary ($Global:ResourceIdDictionary). Passed as the
        # -NameDictionary to Build-ObfuscatedResourceUri, which keys the InstanceId leaf on the FULL
        # resource URI (NOT the resource name) - so this must be the ID dictionary, not
        # $Global:ResourceNameDictionary, which is keyed differently and would break the cross-reference.
        $UriKeyedNameDictionary = $null,
        # guid -> shared-subscription-token view, derived by the caller from $Global:ResourceSubscriptionDictionary.
        $SubGuidTokenMap = $null,
        # rgName -> shared-resource-group-token view, derived by the caller from $Global:ResourceResourceGroupDictionary.
        $RgTokenMap = $null,
        [hashtable]$SubCache = $null,
        [hashtable]$RgCache = $null,
        [hashtable]$NameCache = $null
    )

    $OutInstanceId = $Row.InstanceId
    $OutResourceGroup = $Row.ResourceGroup
    $OutSubscriptionName = $Row.SubscriptionName
    $OutInstanceName = $Row.InstanceName
    $OutSubscriptionGuid = $Row.SubscriptionGuid
    $OutOrderNumber = $Row.OrderNumber

    if ($Obfuscate)
    {
        if ($null -eq $SubCache) { $SubCache = @{} }
        if ($null -eq $RgCache) { $RgCache = @{} }
        if ($null -eq $NameCache) { $NameCache = @{} }

        $Prefix = if ("$($Row.InstanceId) $($Row.InstanceName) $($Row.ResourceGroup)" -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or "$($Row.InstanceId)" -match '(^|/|-)([dts])-') { 'nonprod_' } else { 'prod_' }

        if (-not [string]::IsNullOrEmpty($Row.InstanceId))
        {
            $OutInstanceId = Build-ObfuscatedResourceUri -RawUri $Row.InstanceId -Prefix $Prefix -SubscriptionDictionary $null -ResourceGroupDictionary $null -NameDictionary $UriKeyedNameDictionary -SubCache $SubCache -RgCache $RgCache -NameCache $NameCache
        }

        # SubscriptionGuid + SubscriptionName both identify ONE subscription. Resolve the shared
        # subscription token from the GUID (the unambiguous key) and reuse it for BOTH, so the whole
        # Marketplace row's subscription identity matches the token used elsewhere in the bundle.
        # The shared token is keyed on the raw GUID (via $SubGuidTokenMap) so it survives across rows
        # and subscriptions; $SubCache is the deterministic local fallback when the GUID is not in the
        # shared map (a Marketplace-only sub with nothing in the first-party inventory).
        $SharedSubToken = $null
        if (-not [string]::IsNullOrEmpty($Row.SubscriptionGuid))
        {
            $SharedSubToken = Resolve-ObfuscationToken -RealValue $Row.SubscriptionGuid -LookupKey $Row.SubscriptionGuid -SharedDictionary $SubGuidTokenMap -LocalCache $SubCache -TokenPrefix ($Prefix + 'sub_')
            $OutSubscriptionGuid = $SharedSubToken
        }

        if (-not [string]::IsNullOrEmpty($Row.SubscriptionName))
        {
            if ($null -ne $SharedSubToken)
            {
                $OutSubscriptionName = $SharedSubToken
            }
            else
            {
                # No GUID on the row to anchor the shared token; fall back to a deterministic local
                # token keyed by the subscription name.
                $OutSubscriptionName = Resolve-ObfuscationToken -RealValue $Row.SubscriptionName -LookupKey $Row.SubscriptionName -SharedDictionary $null -LocalCache $SubCache -TokenPrefix ($Prefix + 'sub_')
            }
        }

        if (-not [string]::IsNullOrEmpty($Row.ResourceGroup))
        {
            $RgTag = if ($Row.ResourceGroup -match '^mc_') { 'mc_' } else { '' }
            $OutResourceGroup = Resolve-ObfuscationToken -RealValue $Row.ResourceGroup -LookupKey $Row.ResourceGroup -SharedDictionary $RgTokenMap -LocalCache $RgCache -TokenPrefix ($Prefix + 'rg_' + $RgTag)
        }

        if (-not [string]::IsNullOrEmpty($Row.InstanceName))
        {
            $OutInstanceName = Resolve-ObfuscationToken -RealValue $Row.InstanceName -LookupKey $Row.InstanceName -SharedDictionary $null -LocalCache $NameCache -TokenPrefix $Prefix
        }

        # OrderNumber identifies a specific customer PURCHASE, which is why it is masked while
        # PublisherName / OfferName / PlanName stay readable - those say WHICH PRODUCT was bought
        # (the signal the report exists to carry), this says WHO bought it and under which order.
        # Routed through the shared free-text helper rather than a cache local to this function, so
        # the token lands in $Global:FreeTextDictionary and is exported to the dictionary's
        # FreeTextMap. That is what makes it reversible by the report owner, stable across runs and
        # streams that seed from an existing dictionary, and scrubbed from the diagnostics log.
        # A cache private to this call site gets none of that: the token never leaves the process,
        # so nobody - including the owner - can map it back.
        if (-not [string]::IsNullOrEmpty($Row.OrderNumber))
        {
            $OutOrderNumber = Protect-FreeTextValue $Row.OrderNumber
        }
    }

    return [PSCustomObject]@{
        PublisherName    = $Row.PublisherName
        OfferName        = $Row.OfferName
        PlanName         = $Row.PlanName
        OrderNumber      = $OutOrderNumber
        ConsumedService  = $Row.ConsumedService
        ConsumedQuantity = $Row.ConsumedQuantity
        UnitOfMeasure    = $Row.UnitOfMeasure
        PretaxCost       = $Row.PretaxCost
        Currency         = $Row.Currency
        IsEstimated      = $Row.IsEstimated
        MeterId          = $Row.MeterId
        UsageStart       = $Row.UsageStart
        UsageEnd         = $Row.UsageEnd
        SubscriptionGuid = $OutSubscriptionGuid
        SubscriptionName = $OutSubscriptionName
        ResourceGroup    = $OutResourceGroup
        InstanceId       = $OutInstanceId
        InstanceName     = $OutInstanceName
    }
}
function Global:Test-RdaClaudeMarketplaceRow
{
    # Returns $true when a Marketplace row (PSMarketplace shape) is an Anthropic/Claude
    # offer that should be folded into the first-party Consumption CSV as a "Foundry Models"
    # row (see ConvertTo-RdaFoldedFoundryRow and the GetFoundryFoldConsumption collector).
    #
    # WHY A TOKEN MATCH, NOT AN EXACT PUBLISHER STRING. The exact PublisherName/OfferName/
    # PlanName spellings Azure Marketplace uses for a Claude-on-Foundry offer are not yet
    # verified against a live billed row (no such subscription is available to this project),
    # so this matches on the stable, human-meaningful tokens "anthropic" and "claude" anywhere
    # in the three product-identity fields rather than hardcoding one brittle full string. That
    # is the same "product identity lives in PublisherName/OfferName/PlanName" contract the
    # Marketplace collector already documents. The match is case-insensitive.
    param([Parameter(Mandatory = $true)][AllowNull()]$Row)

    if ($null -eq $Row) { return $false }
    $Haystack = ("{0} {1} {2}" -f $Row.PublisherName, $Row.OfferName, $Row.PlanName)
    return ($Haystack -imatch '\b(anthropic|claude)\b')
}

function Global:Get-RdaClaudeModelIdentity
{
    # Derives a server-recognizable Claude MODEL identity string from a Marketplace row's
    # product-identity fields (OfferName/PlanName, then PublisherName as a last resort).
    #
    # SERVER CONTRACT. The ingestion server resolves the model by alias-matching a recognizable
    # Claude token (e.g. "Claude Sonnet 4.5", "Claude Opus 4.5", "Claude Haiku 4.5") out of
    # MeterName/ProductName. This returns the best such string we can read from the row so the
    # folded row's MeterName carries it. When the row names a specific family (sonnet/opus/haiku)
    # and/or a version, that specific identity is returned; otherwise a bare "Claude" is returned
    # so the row is still attributable to Claude even when the model cannot be pinned down.
    #
    # CAVEAT (unverified against a live tenant). The precise OfferName/PlanName spellings Azure
    # uses for Claude-on-Foundry are not yet confirmed against a real billed row. This parser is
    # deliberately tolerant (family + optional version tokens) rather than an exact-string table,
    # and MUST be validated once a live Claude-on-Foundry deployment is available.
    param([Parameter(Mandatory = $true)]$Row)

    $Text = ("{0} {1} {2}" -f $Row.OfferName, $Row.PlanName, $Row.PublisherName)

    # Family (sonnet/opus/haiku) - the strongest model signal.
    $Family = $null
    if ($Text -imatch '\b(sonnet|opus|haiku)\b') { $Family = (Get-Culture).TextInfo.ToTitleCase($Matches[1].ToLower()) }

    # Version like "4.5", "3.7", "4", "3" ONLY when it sits ADJACENT to the family token (either
    # side), e.g. "Claude 3 Sonnet" or "Sonnet 4.5". A Claude model version is a single-digit major
    # with an optional minor (never a large plan quantity like "100000 tokens"), so the number is
    # bounded to \d(?:\.\d+)? - a bare "100000" adjacent to the family is NOT treated as a version.
    $Version = $null
    if ($Family)
    {
        $Fam = [regex]::Escape($Family)
        if ($Text -imatch ('\b(\d(?:\.\d+)?)\s+' + $Fam + '\b')) { $Version = $Matches[1] }
        elseif ($Text -imatch ('\b' + $Fam + '\s+(\d(?:\.\d+)?)\b')) { $Version = $Matches[1] }
    }

    if ($Family)
    {
        if ($Version) { return ("Claude {0} {1}" -f $Family, $Version) }
        return ("Claude {0}" -f $Family)
    }

    # No family token: still return a Claude identity so the row is attributable. Without a family
    # to anchor a version, do NOT attach a spurious number.
    return 'Claude'
}

function Global:ConvertTo-RdaFoldedFoundryRow
{
    # TIER 1 FOLD (CCU / cost, always available). Maps ONE Claude/Anthropic Marketplace row
    # (PSMarketplace shape, as returned by Get-AzConsumptionMarketplace) to a row shaped like
    # the FIRST-PARTY Consumption CSV, so the deployed ingestion server - which reads ONLY
    # Consumption_*.csv and has NO reader for Marketplace_*.csv - actually sees Claude usage.
    #
    # WHY. The server's Foundry->Bedrock path admits a consumption row ONLY when its
    # MeterCategory == "Foundry Models" (exact string). Claude has no first-party Azure retail
    # meter, so Claude usage arrives only on the Marketplace endpoint and is silently dropped
    # server-side. Folding it into the Consumption CSV with MeterCategory="Foundry Models" and
    # the Claude model identity in MeterName is what makes the server attribute the Azure cost.
    #
    # NON-TOKEN (CCU / cost) MARKING. This Tier 1 row carries the Marketplace PretaxCost as an
    # Azure cost, NOT a token count. The server must attribute that Azure cost but must NOT try
    # to compute an AWS Bedrock token price from it (that is Tier 2's job, when per-model token
    # telemetry exists). So the row is marked non-token: Unit is a cost/quantity unit (never a
    # token unit) and additionalInfo.IsTokenMeter=$false. The per-(model,role) TOKEN rows are
    # produced separately by Tier 2 with the role encoded in MeterName and a token Unit.
    #
    # OUTPUT SHAPE. Returns an object carrying EXACTLY the first-party Consumption CSV columns
    # (AdditionalInfo, MeterCategory, MeterId, MeterName, MeterRegion, MeterSubCategory, Quantity,
    # Unit, UsageStartTime, UsageEndTime, ResourceId, ResourceLocation, ConsumptionMeter,
    # ReservationId, ReservationOrderId) so the collector can Select-Object + Export-Csv -Append
    # it straight onto the existing Consumption_*.csv with no schema change.
    #   - MeterCategory = "Foundry Models" (exact, server contract).
    #   - MeterName     = the Claude model identity (server resolves the model from it).
    #   - Quantity      = the Marketplace ConsumedQuantity (usage quantity, mirrors first-party).
    #   - Unit          = the Marketplace UnitOfMeasure, or a neutral cost unit; NEVER a token unit.
    #   - AdditionalInfo = a JSON blob shaped like the first-party path's
    #                      {"Microsoft.Resources":{resourceUri,location,additionalInfo:{...}}},
    #                      carrying PretaxCost/Currency (the Azure cost the server attributes),
    #                      the readable product identity, and the fold markers. Cost lives here
    #                      because the Consumption CSV has no dedicated cost column - the
    #                      first-party path likewise carries per-resource detail inside this blob.
    #
    # SYNTHESIZED, STABLE, OBFUSCATION-CONSISTENT ResourceId + MeterId. The server requires a
    # NON-EMPTY ResourceId and MeterId. A Marketplace row's InstanceId/MeterId may be empty, so
    # when absent we SYNTHESIZE them deterministically from the row's stable identity fields (a
    # SHA256 over publisher/offer/plan/instance) so the same offer maps to the same ids across
    # runs. Under -Obfuscate the ResourceId is routed through the SAME Build-ObfuscatedResourceUri
    # path the first-party consumption + Marketplace rows use, so a folded row cross-references the
    # rest of the bundle exactly like every other row and never leaks a real identifier.
    #
    # OBFUSCATION PARITY. Same param surface as ConvertTo-RdaMarketplaceRow: the caller passes the
    # shared URI-keyed name dictionary and the per-run caches. Product identity (the "which model"
    # signal) stays readable in MeterName by design, exactly as Marketplace keeps PublisherName/
    # OfferName/PlanName readable.
    param(
        [Parameter(Mandatory = $true)]$Row,
        [bool]$Obfuscate = $false,
        # URI-keyed shared resource-ID dictionary ($Global:ResourceIdDictionary), passed through to
        # Build-ObfuscatedResourceUri exactly as the Marketplace/consumption paths do.
        $UriKeyedNameDictionary = $null,
        [hashtable]$SubCache = $null,
        [hashtable]$RgCache = $null,
        [hashtable]$NameCache = $null
    )

    # --- Model identity (readable, drives server model resolution via MeterName) ---
    $ModelIdentity = Get-RdaClaudeModelIdentity -Row $Row

    # --- Stable synthetic ids from the row's identity, used when the row lacks its own ---
    $IdentitySeed = ("{0}|{1}|{2}|{3}" -f $Row.PublisherName, $Row.OfferName, $Row.PlanName, $Row.InstanceId)
    $Sha = [System.Security.Cryptography.SHA256]::Create()
    try
    {
        $HashBytes = $Sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($IdentitySeed))
    }
    finally
    {
        $Sha.Dispose()
    }
    $HashHex = -join ($HashBytes | ForEach-Object { $_.ToString('x2') })
    # A GUID-shaped slice so the synthetic ids look like the ARM/meter ids they stand in for and
    # are stable for a given offer identity across runs.
    $SynthGuid = ("{0}-{1}-{2}-{3}-{4}" -f $HashHex.Substring(0, 8), $HashHex.Substring(8, 4), $HashHex.Substring(12, 4), $HashHex.Substring(16, 4), $HashHex.Substring(20, 12))

    # MeterId: prefer the row's own, else the synthetic (server requires non-empty).
    $MeterId = if (-not [string]::IsNullOrEmpty($Row.MeterId)) { $Row.MeterId } else { ("foundryfold-{0}" -f $SynthGuid) }

    # ResourceId: prefer the row's InstanceId, else a synthetic SaaS-shaped ARM URI so the server
    # sees a well-formed non-empty resource id. Kept as an ARM path so obfuscation preserves its
    # structure exactly like a real one.
    $RawResourceId = if (-not [string]::IsNullOrEmpty($Row.InstanceId))
    {
        $Row.InstanceId
    }
    elseif (-not [string]::IsNullOrEmpty($Row.SubscriptionGuid))
    {
        ("/subscriptions/{0}/providers/Microsoft.Foundry/foundryModels/{1}" -f $Row.SubscriptionGuid, $SynthGuid)
    }
    else
    {
        ("/providers/Microsoft.Foundry/foundryModels/{0}" -f $SynthGuid)
    }

    $ResourceLocation = if (-not [string]::IsNullOrEmpty($Row.MeterRegion)) { $Row.MeterRegion } elseif (-not [string]::IsNullOrEmpty($Row.ResourceLocation)) { $Row.ResourceLocation } else { 'global' }

    # --- Obfuscation of the ResourceId (parity with the Marketplace/consumption paths) ---
    $OutResourceId = $RawResourceId
    if ($Obfuscate)
    {
        if ($null -eq $SubCache) { $SubCache = @{} }
        if ($null -eq $RgCache) { $RgCache = @{} }
        if ($null -eq $NameCache) { $NameCache = @{} }

        $Prefix = if ("$($Row.InstanceId) $($Row.InstanceName) $($Row.ResourceGroup)" -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or "$RawResourceId" -match '(^|/|-)([dts])-') { 'nonprod_' } else { 'prod_' }
        $OutResourceId = Build-ObfuscatedResourceUri -RawUri $RawResourceId -Prefix $Prefix -SubscriptionDictionary $null -ResourceGroupDictionary $null -NameDictionary $UriKeyedNameDictionary -SubCache $SubCache -RgCache $RgCache -NameCache $NameCache
    }

    # --- AdditionalInfo JSON blob (mirror the first-party {"Microsoft.Resources":{...}} shape) ---
    # Cost lives here because the Consumption CSV carries no dedicated cost column; the first-party
    # path likewise stows per-resource licensing detail inside this same blob. The fold markers let
    # the server (and a human reading the CSV) tell a folded Claude cost row from a native one.
    $AdditionalInfoObject = [PSCustomObject]@{
        'Microsoft.Resources' = [PSCustomObject]@{
            resourceUri    = $OutResourceId
            location       = $ResourceLocation
            additionalInfo = [PSCustomObject]@{
                # Fold provenance + non-token marking.
                IsFoundryFold  = $true
                FoldTier       = 1
                IsTokenMeter   = $false
                ModelIdentity  = $ModelIdentity
                # The Azure cost the server attributes for this Claude usage.
                PretaxCost     = $Row.PretaxCost
                Currency       = $Row.Currency
                # The Marketplace usage quantity + its original unit, preserved for fidelity (the
                # emitted Unit column is forced to a neutral non-token 'CCU' - see the Unit note).
                ConsumedQuantity        = $Row.ConsumedQuantity
                MarketplaceUnitOfMeasure = $Row.UnitOfMeasure
                # Readable product identity (never masked - the "which offer" signal).
                PublisherName  = $Row.PublisherName
                OfferName      = $Row.OfferName
                PlanName       = $Row.PlanName
            }
        }
    }

    return [PSCustomObject]@{
        AdditionalInfo     = ($AdditionalInfoObject | ConvertTo-Json -Compress -Depth 6)
        MeterCategory      = 'Foundry Models'
        MeterId            = $MeterId
        MeterName          = $ModelIdentity
        MeterRegion        = $ResourceLocation
        # Carry the readable model identity as the sub-category too, a second place the server can
        # read the model from, mirroring how the product identity is preserved on Marketplace rows.
        MeterSubCategory   = $ModelIdentity
        # Usage quantity, mirroring the first-party path (NOT a token count - this is the CCU/cost row).
        Quantity           = $Row.ConsumedQuantity
        # A FIXED non-token unit. The server decides token-vs-cost partly from the Unit
        # (Quantity x TokensPerAzureUnit(Unit)); a token-shaped Marketplace unit like "1M Tokens"
        # on this cost row could make the server misprice the CCU/usage Quantity as tokens. So this
        # Tier 1 row ALWAYS carries a neutral unit and marks itself non-token; the real Marketplace
        # unit is preserved in additionalInfo.MarketplaceUnitOfMeasure for fidelity. Per-role TOKEN
        # rows (with a token unit) are Tier 2's job.
        Unit               = 'CCU'
        UsageStartTime     = $Row.UsageStart
        UsageEndTime       = $Row.UsageEnd
        ResourceId         = $OutResourceId
        ResourceLocation   = $ResourceLocation
        ConsumptionMeter   = $ModelIdentity
        ReservationId      = ''
        ReservationOrderId = ''
    }
}

function Global:Get-RdaFoundryDeploymentModelMap
{
    # TIER 2 (per-model TOKEN counts) - pure helper. Given the list of model deployments returned by
    # Get-AzCognitiveServicesAccountDeployment for ONE Cognitive Services account, returns a hashtable
    # mapping each deployment NAME (the ModelDeploymentName metric-dimension value) to the underlying
    # MODEL name used in MeterName. The metric dimension keys on the DEPLOYMENT name; the model name is
    # what the ingestion server resolves, so prefer the model name and fall back to the deployment name.
    #
    # WHY A PURE HELPER (this is a regression guard). Get-AzCognitiveServicesAccountDeployment returns
    # Microsoft.Azure.Management.CognitiveServices.Models.Deployment instances whose public CLR
    # properties are NOT surfaced as adapted PSObject members: $Dep.PSObject.Properties['Name'] is
    # ABSENT (indexing it can even throw) while $Dep.Name returns the value. The earlier inline
    # implementation gated every read behind $Dep.PSObject.Properties['...'] membership, so on REAL
    # Azure data every deployment was skipped ("none resolved a usable name") and zero token rows were
    # collected despite tokens existing. This helper reads via DIRECT null-safe member access, which
    # works on the real .NET type, on a Newtonsoft JObject (the faithful test fake for that adapter
    # divergence), and on a [pscustomobject], returning $null only when a member is genuinely absent.
    # Living here as a pure function lets the offline tests reproduce the divergence and prove the fix.
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Deployments
    )

    $Map = @{}
    if ($null -eq $Deployments) { return $Map }

    foreach ($Dep in @($Deployments))
    {
        if ($null -eq $Dep) { continue }

        $DepNameRaw = $Dep.Name
        $DepName = if ($null -ne $DepNameRaw) { [string]$DepNameRaw } else { $null }
        if ([string]::IsNullOrWhiteSpace($DepName)) { continue }

        $ModelName = $null
        # Deployment model identity: properties.model.name (ARM shape). Null-safe through each hop;
        # tolerate the alternative top-level .Model shape as well.
        $ModelObj = $Dep.Properties.Model
        if ($null -ne $ModelObj)
        {
            if ($ModelObj -is [string]) { $ModelName = $ModelObj }
            elseif ($null -ne $ModelObj.Name) { $ModelName = [string]$ModelObj.Name }
        }
        if ([string]::IsNullOrWhiteSpace($ModelName))
        {
            $ModelObj = $Dep.Model
            if ($null -ne $ModelObj)
            {
                if ($ModelObj -is [string]) { $ModelName = $ModelObj }
                elseif ($null -ne $ModelObj.Name) { $ModelName = [string]$ModelObj.Name }
            }
        }
        if ([string]::IsNullOrWhiteSpace($ModelName)) { $ModelName = $DepName }

        $Map[$DepName] = $ModelName
    }

    return $Map
}

function Global:Test-RdaFoundryMetricPermanentFailure
{
    # TIER 2 (per-model TOKEN counts) - pure classifier. Given a Get-AzMetric error message, returns
    # $true when the failure is PERMANENT for THIS metric on THIS account (so it must NOT be retried,
    # just skipped once and logged), $false when it is a transient error worth retrying.
    #
    # WHY THIS EXISTS (a live-data resilience fix). Not every account supports every token metric.
    # A real run saw Get-AzMetric for 'TotalCalls' return HTTP 400 / BadRequest ("metric not valid
    # for this resource") and the token-query retry loop RETRIED it five times - a pointless retry
    # storm, because a 400 will never succeed on the next attempt. The metrics phase already draws
    # this exact line (Extension/Metrics.ps1 Get-RdaMetricFailureClass): 400/BadRequest/NotFound are
    # permanent, 429/throttle/timeout are transient. This mirrors that split for the Foundry token
    # path so an unsupported metric is skipped immediately and only genuinely transient errors burn
    # the retry budget. Authorization (403) and auth-expiry (401) are handled separately by the
    # caller (Test-RdaConsumptionDenial / Test-RdaAuthExpiry) and are intentionally NOT re-classified
    # here, so this owner is only the "bad request / not supported for this resource" line.
    #
    # It is a pure function so the offline tests can prove the retry storm is gone without a live call.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string]$ErrorMessage)

    if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { return $false }

    # A throttle/timeout can co-occur with a 4xx-shaped word in a long chained message; classify it
    # as TRANSIENT first so a genuinely retryable throttle is never mistaken for a permanent skip.
    if ($ErrorMessage -match '(?i)(TooManyRequests|\b429\b|throttl|rate limit|\btimed? ?out\b|\b408\b|temporarily unavailable|\b503\b)') { return $false }

    # Permanent: the request itself is invalid for this metric/resource and will never succeed.
    # Mirrors Extension/Metrics.ps1's "invalid status code 'BadRequest|NotFound'" and a bare 400.
    $PermanentPattern = '(?i)(' + (@(
            "invalid status code '?(?:BadRequest|NotFound)'?"
            '(?<![\w-])BadRequest(?![\w-])'
            '\(400\)'
            '\bstatus\s?code\D{0,40}400\b'
            '(?<![\w-])NotFound(?![\w-])'
            '\(404\)'
            'metric[^.]{0,60}(?:not (?:valid|supported|found)|is not)'
        ) -join '|') + ')'

    return [bool]($ErrorMessage -match $PermanentPattern)
}

function Global:Get-RdaFoundryTokenRole
{
    # TIER 2 (per-model TOKEN counts). Maps ONE Azure AI Foundry / Cognitive Services token
    # METRIC NAME to the server-recognizable token ROLE and the MeterName word that encodes it,
    # or $null when the metric is NOT a per-role billable token count and must not be emitted as
    # its own priced row.
    #
    # WHY. The ingestion server's Foundry->Bedrock path resolves a token role by scanning MeterName
    # for a role substring (verified in the server's role parser):
    #     input        <- "inp" / "input"
    #     output       <- "outp" / "out" / "output"
    #     cached-input <- "cd inp" / "cached inp" / "cache read"
    #     cache-write  <- "cd wr" / "cache write"
    # So each emitted token row must carry BOTH the model identity AND one of those role substrings
    # in MeterName. This helper is the single owner of the metric-name -> role mapping so the
    # collector wiring and the tests agree on it, and it is a pure function so it is unit-tested.
    #
    # LIVE-VERIFIED METRIC NAMES (confirmed 2026-09-26 against a real Phi-4 + Phi-4-mini deployment;
    # Unit=Count on all of them):
    #     InputTokens, OutputTokens, TotalTokens,
    #     cacheReadInputTokens, ephemeral5mInputTokens, ephemeral1hInputTokens,
    #     ModelRequests, TotalCalls
    #
    # WHAT MAPS TO A PRICED ROLE (returns a role) vs WHAT DOES NOT (returns $null):
    #   - InputTokens              -> input        ("Inp")
    #   - OutputTokens             -> output       ("Outp")
    #   - cacheReadInputTokens     -> cached-input ("Cd Inp") - a cache-READ hit (discounted input)
    #   - ephemeral5mInputTokens   -> cache-write  ("Cd Wr")  - a cache-WRITE (ephemeral cache entry)
    #   - ephemeral1hInputTokens   -> cache-write  ("Cd Wr")
    #   - TotalTokens              -> $null: it is Input+Output SUMMED. Emitting it as its own token
    #                                 row alongside the input/output rows would DOUBLE-COUNT tokens
    #                                 (test (d)). It is preserved for fidelity in AdditionalInfo, not
    #                                 emitted as a priced row.
    #   - ModelRequests, TotalCalls-> $null: request/call COUNTS, not token counts. A token Unit on
    #                                 these would misprice a call count as tokens. Preserved for
    #                                 fidelity, not emitted as a priced token row.
    #
    # Returns a PSCustomObject { Role; MeterWord; IsCacheWrite } or $null. Match is case-insensitive
    # on the exact live-verified metric names above.
    param([Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string]$MetricName)

    if ([string]::IsNullOrWhiteSpace($MetricName)) { return $null }

    switch -Regex ($MetricName.Trim())
    {
        # cache-READ hit (discounted input token) - matched BEFORE the plain InputTokens branch so
        # 'cacheReadInputTokens' does not fall through to the input role.
        '^(?i)cacheReadInputTokens$' { return [pscustomobject]@{ Role = 'cached-input'; MeterWord = 'Cd Inp'; IsCacheWrite = $false } }
        # cache-WRITE (ephemeral cache entry, 5-minute or 1-hour TTL) - also matched before the plain
        # InputTokens branch. Both ephemeral variants are cache writes.
        '^(?i)ephemeral(5m|1h)InputTokens$' { return [pscustomobject]@{ Role = 'cache-write'; MeterWord = 'Cd Wr'; IsCacheWrite = $true } }
        '^(?i)InputTokens$' { return [pscustomobject]@{ Role = 'input'; MeterWord = 'Inp'; IsCacheWrite = $false } }
        '^(?i)OutputTokens$' { return [pscustomobject]@{ Role = 'output'; MeterWord = 'Outp'; IsCacheWrite = $false } }
        # TotalTokens / ModelRequests / TotalCalls are intentionally not priced rows (see header).
        default { return $null }
    }
}

function Global:ConvertTo-RdaFoldedFoundryTokenRow
{
    # TIER 2 FOLD (per-model TOKEN counts). Maps ONE (Cognitive Services account, deployed model,
    # token role, token count) tuple to a row shaped like the FIRST-PARTY Consumption CSV, so the
    # deployed ingestion server - which reads ONLY Consumption_*.csv - can price the Azure-hosted
    # model's token usage against AWS Bedrock. Sibling of the Tier 1 ConvertTo-RdaFoldedFoundryRow
    # (which folds Claude/CCU cost rows); this one folds the per-role TOKEN rows.
    #
    # WHY. Azure AI Foundry models that DO expose token telemetry (Phi / OpenAI / DeepSeek / etc.)
    # publish per-model token metrics on the Cognitive Services account, split by the
    # ModelDeploymentName dimension. Those token counts never reach the first-party consumption
    # endpoint, so without this fold the server sees the account but no token quantities to price.
    # This emits one "Foundry Models" consumption row per (account, model, role) carrying the token
    # count as Quantity and a token Unit, exactly the shape the server's token-pricing path expects.
    #
    # OUTPUT SHAPE. Returns an object carrying EXACTLY the first-party Consumption CSV columns
    # (AdditionalInfo, MeterCategory, MeterId, MeterName, MeterRegion, MeterSubCategory, Quantity,
    # Unit, UsageStartTime, UsageEndTime, ResourceId, ResourceLocation, ConsumptionMeter,
    # ReservationId, ReservationOrderId) so the collector can Select-Object + Export-Csv -Append it
    # straight onto the existing Consumption_*.csv with no schema change.
    #   - MeterCategory = "Foundry Models" (exact, server contract - the Foundry->Bedrock gate).
    #   - MeterName     = "<ModelName> <RoleWord> Tkns" (e.g. "Phi-4 Inp Tkns", "Phi-4 Outp Tkns",
    #                     "Phi-4 Cd Inp Tkns", "Phi-4 Cd Wr Tkns"). Carries BOTH the model identity
    #                     (so BedrockModelFamilies aliases resolve it) AND the role substring the
    #                     server parser keys on. The role word comes from Get-RdaFoundryTokenRole.
    #   - Quantity      = the raw token count for that (model, role) over the window.
    #   - Unit          = "Tokens" - a UNIT-1 token unit so the server's token multiplier is 1 and
    #                     Quantity x multiplier = the raw token count. A "1M Tokens"-style unit would
    #                     make the server divide by 1e6 and misprice; this row emits RAW token counts,
    #                     so the unit MUST be the unit-1 "Tokens" (never "1M Tokens").
    #   - ResourceId    = the Cognitive Services account resourceId (non-empty; obfuscated via the
    #                     shared dictionary like every other row).
    #   - MeterId       = a STABLE synthesized id per (account, model, role) - SHA256 over the
    #                     account id + model + role - so the same tuple maps to the same id across runs.
    #   - MeterSubCategory = the model name (a second place the server can read the model from).
    #   - ResourceLocation = the account location.
    #   - AdditionalInfo   = JSON {"Microsoft.Resources":{resourceUri,location,additionalInfo:{...}}}
    #                        carrying the fold markers (IsFoundryFold, FoldTier=2, IsTokenMeter=$true),
    #                        the model identity, the role, the source metric name, and - for fidelity -
    #                        the raw non-priced counts (TotalTokens / ModelRequests / TotalCalls) when
    #                        the caller passes them.
    #
    # OBFUSCATION PARITY. Same surface as ConvertTo-RdaFoldedFoundryRow: the caller passes the shared
    # URI-keyed name dictionary and the per-run caches. The model identity (the "which model" signal)
    # stays READABLE in MeterName / MeterSubCategory by design, exactly as Marketplace/Tier 1 keep the
    # product identity readable; only the ResourceId is masked.
    param(
        [Parameter(Mandatory = $true)][string]$AccountResourceId,
        [Parameter(Mandatory = $true)][string]$ModelName,
        # The per-role MeterName word from Get-RdaFoundryTokenRole (e.g. 'Inp', 'Outp', 'Cd Inp', 'Cd Wr').
        [Parameter(Mandatory = $true)][string]$RoleMeterWord,
        # The token ROLE key ('input'/'output'/'cached-input'/'cache-write'), preserved in AdditionalInfo.
        [Parameter(Mandatory = $true)][string]$Role,
        # The raw token count for this (model, role) over the window.
        [Parameter(Mandatory = $true)][double]$TokenQuantity,
        # The source metric name (e.g. 'InputTokens'), preserved in AdditionalInfo for auditability.
        [string]$SourceMetricName = '',
        [string]$AccountLocation = 'global',
        $UsageStartTime = $null,
        $UsageEndTime = $null,
        # Optional raw non-priced counts for fidelity (NOT emitted as priced rows - see Get-RdaFoundryTokenRole).
        $TotalTokens = $null,
        $ModelRequests = $null,
        $TotalCalls = $null,
        [bool]$Obfuscate = $false,
        $UriKeyedNameDictionary = $null,
        [hashtable]$SubCache = $null,
        [hashtable]$RgCache = $null,
        [hashtable]$NameCache = $null
    )

    # --- MeterName: model identity + role word + "Tkns" (server reads model AND role from it) ---
    $MeterName = ("{0} {1} Tkns" -f $ModelName, $RoleMeterWord)

    # --- Stable synthetic MeterId per (account, model, role) ---
    $IdentitySeed = ("{0}|{1}|{2}" -f $AccountResourceId, $ModelName, $Role)
    $Sha = [System.Security.Cryptography.SHA256]::Create()
    try
    {
        $HashBytes = $Sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($IdentitySeed))
    }
    finally
    {
        $Sha.Dispose()
    }
    $HashHex = -join ($HashBytes | ForEach-Object { $_.ToString('x2') })
    $SynthGuid = ("{0}-{1}-{2}-{3}-{4}" -f $HashHex.Substring(0, 8), $HashHex.Substring(8, 4), $HashHex.Substring(12, 4), $HashHex.Substring(16, 4), $HashHex.Substring(20, 12))
    $MeterId = ("foundrytoken-{0}" -f $SynthGuid)

    $ResourceLocation = if (-not [string]::IsNullOrEmpty($AccountLocation)) { $AccountLocation } else { 'global' }

    # --- Obfuscation of the account ResourceId (parity with the Marketplace/consumption/Tier1 paths) ---
    $OutResourceId = $AccountResourceId
    if ($Obfuscate)
    {
        if ($null -eq $SubCache) { $SubCache = @{} }
        if ($null -eq $RgCache) { $RgCache = @{} }
        if ($null -eq $NameCache) { $NameCache = @{} }

        $Prefix = if ("$AccountResourceId $ModelName" -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or "$AccountResourceId" -match '(^|/|-)([dts])-') { 'nonprod_' } else { 'prod_' }
        if (-not [string]::IsNullOrEmpty($AccountResourceId))
        {
            $OutResourceId = Build-ObfuscatedResourceUri -RawUri $AccountResourceId -Prefix $Prefix -SubscriptionDictionary $null -ResourceGroupDictionary $null -NameDictionary $UriKeyedNameDictionary -SubCache $SubCache -RgCache $RgCache -NameCache $NameCache
        }
    }

    # --- AdditionalInfo JSON (mirror the first-party {"Microsoft.Resources":{...}} shape) ---
    $ExtraInfo = [ordered]@{
        IsFoundryFold   = $true
        FoldTier        = 2
        IsTokenMeter    = $true
        ModelIdentity   = $ModelName
        TokenRole       = $Role
        SourceMetric    = $SourceMetricName
    }
    # Raw non-priced counts for fidelity, only when supplied (never emitted as their own priced rows).
    if ($null -ne $TotalTokens) { $ExtraInfo['TotalTokens'] = $TotalTokens }
    if ($null -ne $ModelRequests) { $ExtraInfo['ModelRequests'] = $ModelRequests }
    if ($null -ne $TotalCalls) { $ExtraInfo['TotalCalls'] = $TotalCalls }

    $AdditionalInfoObject = [PSCustomObject]@{
        'Microsoft.Resources' = [PSCustomObject]@{
            resourceUri    = $OutResourceId
            location       = $ResourceLocation
            additionalInfo = [PSCustomObject]$ExtraInfo
        }
    }

    return [PSCustomObject]@{
        AdditionalInfo     = ($AdditionalInfoObject | ConvertTo-Json -Compress -Depth 6)
        MeterCategory      = 'Foundry Models'
        MeterId            = $MeterId
        MeterName          = $MeterName
        MeterRegion        = $ResourceLocation
        MeterSubCategory   = $ModelName
        # RAW token count. Unit is the unit-1 'Tokens' so Quantity x server-multiplier = raw tokens.
        Quantity           = $TokenQuantity
        Unit               = 'Tokens'
        UsageStartTime     = $UsageStartTime
        UsageEndTime       = $UsageEndTime
        ResourceId         = $OutResourceId
        ResourceLocation   = $ResourceLocation
        ConsumptionMeter   = $ModelName
        ReservationId      = ''
        ReservationOrderId = ''
    }
}

function Global:Get-RdaFoundryTokenSeriesTotals
{
    # TIER 2 (per-model TOKEN counts) - pure parser. Given ONE Get-AzMetric result object for a
    # single token metric collected WITH the ModelDeploymentName dimension split
    # (-MetricFilter "ModelDeploymentName eq '*'"), returns the summed Total per model deployment
    # as an array of { ModelDeploymentName; Total }.
    #
    # WHY A PURE HELPER. The dimension-parsing is the fiddly part of Tier 2 and must be unit-tested
    # offline against a faithful fake of the Az.Monitor result shape, so it lives here rather than
    # inline in the collector. The collector calls this once per (account, metric).
    #
    # AZ.MONITOR RESULT SHAPE (PSMetric, Az.Monitor). A metric collected with a dimension filter
    # returns its per-dimension breakdown under .Timeseries: a list of PSTimeSeriesElement, each with
    #   .Metadatavalues -> list of { Name.Value = '<dimension name>'; Value = '<dimension value>' }
    #   .Data           -> list of PSMetricValue, each with .Total (AggregationType Total was requested)
    # So for the ModelDeploymentName dimension, each timeseries element is ONE model, and its per-point
    # .Total values are summed to the model's token total for the window. A metric with NO dimension
    # split (some accounts / older shapes) exposes only .Data; that whole-account fallback is handled
    # by the collector, not here (this helper reports only what the dimension split gives).
    #
    # ROBUSTNESS. Null/absent .Timeseries -> empty array (the collector then treats it as "no per-model
    # split"); a null .Total data point contributes 0; a model with no non-null points still returns a
    # row with Total 0 so the caller can log a confirmed-zero for it. The dimension name match is
    # case-insensitive and tolerant of the Name being either a plain string or a { Value = ... } object.
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$MetricResult,
        [string]$DimensionName = 'ModelDeploymentName'
    )

    $Out = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $MetricResult) { return @($Out) }

    # READ VIA DIRECT NULL-SAFE MEMBER ACCESS, not $X.PSObject.Properties['...'] indexing. The real
    # Az.Monitor result (PSMetric) and its .Timeseries elements (PSTimeSeriesElement), plus the
    # LocalizableString dimension name, are .NET CLR types whose public properties are not reliably
    # surfaced as adapted PSObject members (the same defect that made the deployment collector skip
    # every real deployment). Direct access returns $null when a member is genuinely absent and works
    # on both the real types and the [pscustomobject] fakes the offline tests use. Casing differs
    # across Az versions (Timeseries vs TimeSeries, Metadatavalues vs MetadataValues); PowerShell
    # member access is case-insensitive, so one read covers both.
    $SeriesList = $MetricResult.Timeseries
    if ($null -eq $SeriesList) { return @($Out) }

    foreach ($Series in @($SeriesList))
    {
        if ($null -eq $Series) { continue }

        # Resolve this series' model deployment name from its Metadatavalues (the dimension pairs).
        $ModelValue = $null
        $MetaList = $Series.Metadatavalues
        if ($null -ne $MetaList)
        {
            foreach ($Meta in @($MetaList))
            {
                if ($null -eq $Meta) { continue }
                # .Name is a LocalizableString ({ Value = 'ModelDeploymentName' }) on the real type,
                # but tolerate a plain string too so the fake in tests can be simple.
                $RawName = $null
                $NameVal = $Meta.Name
                if ($null -ne $NameVal)
                {
                    if ($NameVal -is [string]) { $RawName = $NameVal }
                    else
                    {
                        $InnerVal = $NameVal.Value
                        $RawName = if ($null -ne $InnerVal) { [string]$InnerVal } else { [string]$NameVal }
                    }
                }
                if ($RawName -and $RawName.Equals($DimensionName, [System.StringComparison]::OrdinalIgnoreCase))
                {
                    $ModelValue = [string]$Meta.Value
                    break
                }
            }
        }

        # Sum the per-point Total for this series.
        $Total = 0.0
        $DataList = $Series.Data
        if ($null -ne $DataList)
        {
            foreach ($Point in @($DataList))
            {
                if ($null -eq $Point) { continue }
                $PointTotal = $Point.Total
                if ($null -ne $PointTotal)
                {
                    $Total += [double]$PointTotal
                }
            }
        }

        $Out.Add([pscustomobject]@{
                ModelDeploymentName = $ModelValue
                Total               = $Total
            })
    }

    return @($Out)
}

function Global:Get-RdaFoundryModelMatchTokens
{
    # Normalizes a free-form model/meter string into a lower-cased set of alphanumeric
    # tokens, used by Test-RdaRetailPriceMatch to compare a deployed model's identity
    # against a Retail Prices catalog entry WITHOUT a hardcoded model->meter table.
    #
    # WHY. There is no clean join key between a deployment's properties.model.name
    # (e.g. 'gpt-4o', 'claude-opus-5') and a Retail Prices meterName/skuName/productName
    # (e.g. 'Azure OpenAI GPT5', '5.4 opt Dz 1M Tokens') - the catalog names are
    # marketing-shaped and abbreviated (the design spec section 4.3). So we compare on normalized
    # token OVERLAP rather than an exact key. Purely mechanical, so it lives in a pure
    # helper and is unit-tested.
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }

    # Lower-case, split on any non-alphanumeric run, drop empties and 1-char noise.
    $Lower = $Value.ToLowerInvariant()
    $Parts = [regex]::Split($Lower, '[^a-z0-9]+') | Where-Object { $_.Length -ge 2 }
    return @($Parts | Select-Object -Unique)
}

function Global:Test-RdaRetailPriceMatch
{
    # Decides whether a single deployed model has a CONFIDENT match among the supplied
    # Azure Retail Prices catalog items (serviceName eq 'Foundry Models'), returning the
    # matched productName/meterName so the server team can audit the match (the design spec section 4.3).
    #
    # CONSERVATIVE + PER-MODEL (the design spec section 4.2/4.3): the match is decided at the individual
    # catalog-item granularity, never at vendor granularity - a vendor like Cohere/Llama/
    # Mistral can be PARTIALLY present (some SKUs metered, others not), so "the vendor has
    # meters" is NOT proof this SKU is metered. A match requires BOTH:
    #   1. the model's vendor discriminator (ModelFormat, e.g. 'OpenAI') to appear in the
    #      catalog item's tokens, AND
    #   2. the distinctive tokens of the model's name/version (e.g. 'gpt','4o') to be
    #      covered by the catalog item's tokens.
    # A miss is NOT proof of absence (it may be a naming mismatch) - the caller combines
    # this with the Marketplace probe before ever emitting UNPRICED (the design spec section 4.3/10).
    param(
        [Parameter(Mandatory = $true)]$Model,
        $CatalogItems
    )

    $Result = [pscustomobject]@{
        Matched      = $false
        RetailMatch  = '(no confident Retail Prices match)'
    }

    if ($null -eq $CatalogItems -or @($CatalogItems).Count -eq 0) { return $Result }

    $ModelName = "$($Model.ModelName)"
    $ModelFormat = "$($Model.ModelFormat)"

    $NameTokens = @(Get-RdaFoundryModelMatchTokens -Value $ModelName)
    $FormatTokens = @(Get-RdaFoundryModelMatchTokens -Value $ModelFormat)

    # A model with no usable name tokens cannot be confidently matched - be conservative.
    if ($NameTokens.Count -eq 0) { return $Result }

    foreach ($Item in @($CatalogItems))
    {
        if ($null -eq $Item) { continue }

        $ItemText = @(
            "$($Item.productName)"
            "$($Item.meterName)"
            "$($Item.skuName)"
            "$($Item.armSkuName)"
        ) -join ' '
        $ItemTokens = @(Get-RdaFoundryModelMatchTokens -Value $ItemText)
        if ($ItemTokens.Count -eq 0) { continue }

        # Condition 1: vendor discriminator present (when we have one to check).
        $VendorOk = $true
        if ($FormatTokens.Count -gt 0)
        {
            $VendorOk = @($FormatTokens | Where-Object { $ItemTokens -contains $_ }).Count -gt 0
        }
        if (-not $VendorOk) { continue }

        # Condition 2: the model's distinctive name tokens are covered by the item's
        # tokens. Require ALL name tokens (drift-safe: a partial coincidental token
        # overlap must not count as a confident match).
        $NameCovered = @($NameTokens | Where-Object { $ItemTokens -notcontains $_ }).Count -eq 0
        if (-not $NameCovered) { continue }

        $Result.Matched = $true
        $Result.RetailMatch = ("{0} / {1}" -f "$($Item.productName)", "$($Item.meterName)").Trim(' /')
        return $Result
    }

    return $Result
}

function Global:Test-RdaMarketplaceModelMatch
{
    # Decides whether a deployed model is covered by the Marketplace plane, by looking for
    # a Marketplace/CCU row (PSMarketplace-shaped) whose PublisherName/OfferName corresponds
    # to the model's vendor (the design spec section 5.2). Because CCU is billed as a SINGLE AGGREGATED
    # line per subscription/offer (the design spec section 2.1/5.2), we do NOT expect one row per model:
    # any attributable Marketplace row for the model's vendor is Marketplace-plane evidence.
    #
    # Returns the matched row (for CCU quantity/cost) and whether the CCU could be tied to a
    # SPECIFIC deployment (PerModel) or only to the offer aggregate (AggregatedOffer).
    param(
        [Parameter(Mandatory = $true)]$Model,
        $MarketplaceRows
    )

    $Result = [pscustomobject]@{
        Matched        = $false
        Row            = $null
        CcuAttribution = $null
    }

    if ($null -eq $MarketplaceRows -or @($MarketplaceRows).Count -eq 0) { return $Result }

    $VendorTokens = @(Get-RdaFoundryModelMatchTokens -Value "$($Model.ModelFormat) $($Model.ModelName)")
    $AccountRg = "$($Model.ResourceGroup)"
    $AccountId = "$($Model.AccountId)"

    $KnownVendorTokens = @('anthropic', 'claude', 'cohere', 'mistral', 'ministral', 'codestral', 'llama', 'openai', 'deepseek', 'grok', 'kimi', 'qwen', 'phi', 'tsuzumi', 'foundry')
    $ModelVendorDiscriminators = @($VendorTokens | Where-Object { $_ -in $KnownVendorTokens })
    if ($ModelVendorDiscriminators.Count -eq 0) { return $Result }

    $BestOfferRow = $null

    foreach ($Row in @($MarketplaceRows))
    {
        if ($null -eq $Row) { continue }

        $OfferText = @("$($Row.PublisherName)", "$($Row.OfferName)", "$($Row.PlanName)") -join ' '
        $OfferTokens = @(Get-RdaFoundryModelMatchTokens -Value $OfferText)
        if ($OfferTokens.Count -eq 0) { continue }

        # Vendor alignment: overlap on a KNOWN Foundry-vendor discriminator (e.g.
        # 'anthropic'/'claude'), not any incidental shared name token. A bare common
        # word like 'meta' in an unrelated publisher must not align the model to that
        # offer. Vendor-level here is CORRECT: Marketplace attribution is inherently
        # offer-level (aggregated), unlike the per-model Retail Prices match.
        $VendorAligned = @($ModelVendorDiscriminators | Where-Object { $OfferTokens -contains $_ }).Count -gt 0
        if (-not $VendorAligned) { continue }

        # Can we tie the CCU line to THIS specific deployment/account? Only if the row's
        # InstanceId/ResourceGroup references the model's account/RG. The common case is
        # NO (aggregation collapses per-model detail) -> AggregatedOffer.
        $InstanceId = "$($Row.InstanceId)"
        $RowRg = "$($Row.ResourceGroup)"
        $TiedToDeployment = $false
        if (-not [string]::IsNullOrEmpty($AccountId) -and -not [string]::IsNullOrEmpty($InstanceId) -and $InstanceId -like ("*" + $AccountId + "*"))
        {
            $TiedToDeployment = $true
        }
        elseif (-not [string]::IsNullOrEmpty($AccountRg) -and -not [string]::IsNullOrEmpty($RowRg) -and $RowRg -eq $AccountRg)
        {
            $TiedToDeployment = $true
        }

        if ($TiedToDeployment)
        {
            $Result.Matched = $true
            $Result.Row = $Row
            $Result.CcuAttribution = 'PerModel'
            return $Result
        }

        if ($null -eq $BestOfferRow) { $BestOfferRow = $Row }
    }

    if ($null -ne $BestOfferRow)
    {
        $Result.Matched = $true
        $Result.Row = $BestOfferRow
        $Result.CcuAttribution = 'AggregatedOffer'
    }

    return $Result
}

function Global:Get-RdaFoundryCoverageStatus
{
    # The core branch/flag decision (the design spec section 3-5, 9, 10). Given the outcome of BOTH
    # plane probes for one deployed model, returns the CoverageStatus + a human-readable
    # CoverageFlag. This is the whole point of the collector - it is what fixes "dropped
    # with no warning".
    #
    # KEY INVARIANT (no-overclaiming, the design spec section 10): UNPRICED is emitted ONLY when BOTH
    # planes were SUCCESSFULLY probed and BOTH came back negative. If either probe
    # failed/was denied/was unreachable, the status is Unknown-<reason>, NEVER UNPRICED -
    # a probe failure must never masquerade as a confirmed coverage gap.
    param(
        [bool]$AzureMetered,          # confident Retail Prices match found
        [bool]$MarketplaceCovered,    # Marketplace/CCU evidence found
        [bool]$RetailProbed = $true,  # was the Retail Prices catalog readable this run?
        [bool]$MarketplaceProbed = $true, # was the Marketplace plane successfully probed for this sub?
        [string]$MarketplaceDeniedReason = $null # set when Marketplace was denied/failed
    )

    if ($AzureMetered)
    {
        $Status = if ($MarketplaceCovered) { 'AzureMetered+Marketplace' } else { 'AzureMetered' }
        $Flag = if ($MarketplaceCovered)
        {
            'Billed on BOTH planes: an Azure meter exists (Retail Prices) AND Marketplace/CCU usage was found.'
        }
        else
        {
            'Azure-metered: a matching meter exists in the Retail Prices API. Priced by the server team via Retail Prices.'
        }
        return [pscustomobject]@{ CoverageStatus = $Status; CoverageFlag = $Flag }
    }

    if ($MarketplaceCovered)
    {
        return [pscustomobject]@{
            CoverageStatus = 'MarketplaceOnly'
            CoverageFlag   = 'Marketplace-billed, absent from Retail Prices - priced via CCU path.'
        }
    }

    # Neither plane came back positive. Decide UNPRICED vs Unknown-<reason> based on
    # whether BOTH planes were actually probed successfully.
    if (-not $MarketplaceProbed)
    {
        $Reason = if (-not [string]::IsNullOrEmpty($MarketplaceDeniedReason)) { $MarketplaceDeniedReason } else { 'MarketplaceNotProbed' }
        return [pscustomobject]@{
            CoverageStatus = ('Unknown-' + $Reason)
            CoverageFlag   = ('Coverage INDETERMINATE on the Marketplace axis ({0}); NOT declared UNPRICED because the Marketplace plane was not successfully probed. Grant Cost Management Reader (or Billing Reader on the billing scope) and re-run.' -f $Reason)
        }
    }

    if (-not $RetailProbed)
    {
        return [pscustomobject]@{
            CoverageStatus = 'Unknown-RetailCatalogUnavailable'
            CoverageFlag   = 'Coverage INDETERMINATE on the Azure-metered axis (Retail Prices catalog could not be read this run); NOT declared UNPRICED. Retry when the price catalog is reachable.'
        }
    }

    # BOTH planes probed, BOTH negative -> a genuine, confirmed coverage gap.
    return [pscustomobject]@{
        CoverageStatus = 'UNPRICED'
        CoverageFlag   = 'UNPRICED MODEL / COVERAGE GAP - deployed model found in NEITHER billing plane (no Retail Prices meter, no Marketplace/CCU usage). Do NOT silently drop; the server team must investigate.'
    }
}

function Global:ConvertTo-RdaFoundryCoverageRow
{
    # Maps ONE classified deployed-model record to the flat object emitted into
    # FoundryModelCoverage_<ReportName>_<stamp>.csv, and applies obfuscation with the SAME
    # discipline as ConvertTo-RdaMarketplaceRow (the design spec section 9.1):
    #   - READABLE (product/plane identity, not customer secrets): AccountKind, ModelName,
    #     ModelFormat, ModelVersion, DeploymentSku, DeploymentCapacity, Region,
    #     DetectedPlanes, CoverageStatus, CoverageFlag, RetailPriceMatch,
    #     MarketplacePublisher, MarketplaceOffer, CcuAttribution, all numeric usage/cost,
    #     the probe presence flags, TokenProbeStatus, and the run window/timestamp.
    #   - MASKED (identifying), via the SHARED run-wide dictionaries so tokens
    #     cross-reference the rest of the bundle: SubscriptionGuid, SubscriptionName,
    #     ResourceGroup, AccountName, DeploymentName. Reuses the exact
    #     Resolve-ObfuscationToken + shared SubGuidTokenMap/RgTokenMap machinery the
    #     Marketplace collector uses; a sub/RG absent from the shared maps mints a
    #     deterministic local token so the row is still internally consistent.
    param(
        [Parameter(Mandatory = $true)]$Record,
        [bool]$Obfuscate = $false,
        $SubGuidTokenMap = $null,
        $RgTokenMap = $null,
        [hashtable]$SubCache = $null,
        [hashtable]$RgCache = $null,
        [hashtable]$NameCache = $null
    )

    $OutSubscriptionGuid = $Record.SubscriptionGuid
    $OutSubscriptionName = $Record.SubscriptionName
    $OutResourceGroup = $Record.ResourceGroup
    $OutAccountName = $Record.AccountName
    $OutDeploymentName = $Record.DeploymentName

    if ($Obfuscate)
    {
        if ($null -eq $SubCache) { $SubCache = @{} }
        if ($null -eq $RgCache) { $RgCache = @{} }
        if ($null -eq $NameCache) { $NameCache = @{} }

        $Prefix = if ("$($Record.AccountName) $($Record.DeploymentName) $($Record.ResourceGroup)" -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or "$($Record.AccountName) $($Record.DeploymentName)" -match '(^|/|-)([dts])-') { 'nonprod_' } else { 'prod_' }

        $SharedSubToken = $null
        if (-not [string]::IsNullOrEmpty($Record.SubscriptionGuid))
        {
            $SharedSubToken = Resolve-ObfuscationToken -RealValue $Record.SubscriptionGuid -LookupKey $Record.SubscriptionGuid -SharedDictionary $SubGuidTokenMap -LocalCache $SubCache -TokenPrefix ($Prefix + 'sub_')
            $OutSubscriptionGuid = $SharedSubToken
        }

        if (-not [string]::IsNullOrEmpty($Record.SubscriptionName))
        {
            if ($null -ne $SharedSubToken)
            {
                $OutSubscriptionName = $SharedSubToken
            }
            else
            {
                $OutSubscriptionName = Resolve-ObfuscationToken -RealValue $Record.SubscriptionName -LookupKey $Record.SubscriptionName -SharedDictionary $null -LocalCache $SubCache -TokenPrefix ($Prefix + 'sub_')
            }
        }

        if (-not [string]::IsNullOrEmpty($Record.ResourceGroup))
        {
            $RgTag = if ($Record.ResourceGroup -match '^mc_') { 'mc_' } else { '' }
            $OutResourceGroup = Resolve-ObfuscationToken -RealValue $Record.ResourceGroup -LookupKey $Record.ResourceGroup -SharedDictionary $RgTokenMap -LocalCache $RgCache -TokenPrefix ($Prefix + 'rg_' + $RgTag)
        }

        if (-not [string]::IsNullOrEmpty($Record.AccountName))
        {
            $OutAccountName = Resolve-ObfuscationToken -RealValue $Record.AccountName -LookupKey $Record.AccountName -SharedDictionary $null -LocalCache $NameCache -TokenPrefix $Prefix
        }

        if (-not [string]::IsNullOrEmpty($Record.DeploymentName))
        {
            $OutDeploymentName = Resolve-ObfuscationToken -RealValue $Record.DeploymentName -LookupKey $Record.DeploymentName -SharedDictionary $null -LocalCache $NameCache -TokenPrefix $Prefix
        }
    }

    return [PSCustomObject]@{
        SubscriptionGuid      = $OutSubscriptionGuid
        SubscriptionName      = $OutSubscriptionName
        ResourceGroup         = $OutResourceGroup
        AccountName           = $OutAccountName
        AccountKind           = $Record.AccountKind
        DeploymentName        = $OutDeploymentName
        ModelName             = $Record.ModelName
        ModelFormat           = $Record.ModelFormat
        ModelVersion          = $Record.ModelVersion
        DeploymentSku         = $Record.DeploymentSku
        DeploymentCapacity    = $Record.DeploymentCapacity
        Region                = $Record.Region
        DetectedPlanes        = $Record.DetectedPlanes
        CoverageStatus        = $Record.CoverageStatus
        CoverageFlag          = $Record.CoverageFlag
        RetailPriceMatch      = $Record.RetailPriceMatch
        MarketplacePublisher  = $Record.MarketplacePublisher
        MarketplaceOffer      = $Record.MarketplaceOffer
        CcuQuantity           = $Record.CcuQuantity
        CcuUnitOfMeasure      = $Record.CcuUnitOfMeasure
        MarketplacePretaxCost = $Record.MarketplacePretaxCost
        MarketplaceCurrency   = $Record.MarketplaceCurrency
        CcuAttribution        = $Record.CcuAttribution
        TokenMetricsPresent   = $Record.TokenMetricsPresent
        InputTokens           = $Record.InputTokens
        OutputTokens          = $Record.OutputTokens
        TotalTokens           = $Record.TotalTokens
        ProbeWindowStart      = $Record.ProbeWindowStart
        ProbeWindowEnd        = $Record.ProbeWindowEnd
        RunTimestampUtc       = $Record.RunTimestampUtc
        TokenProbeStatus      = $Record.TokenProbeStatus
    }
}

function Global:Get-RdaFoundryRetailCatalog
{
    # Pulls the Azure Retail Prices catalog for serviceName 'Foundry Models' (the design spec section 4.1).
    # The API is GLOBAL and UNAUTHENTICATED - no Azure permission, no per-tenant scoping - so
    # this is a plain paged HTTP GET, called ONCE per run and cached by the caller. It answers
    # only "does a first-party Azure meter exist for this model?" (plane membership), not usage.
    #   https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices
    param(
        [string]$ServiceName = 'Foundry Models',
        [int]$MaxPages = 200
    )

    $Base = 'https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview'
    $Filter = [uri]::EscapeDataString("serviceName eq '$ServiceName'")
    $Uri = $Base + '&$filter=' + $Filter
    $Items = [System.Collections.ArrayList]::new()
    $Page = 0

    while (-not [string]::IsNullOrEmpty($Uri) -and $Page -lt $MaxPages)
    {
        $Resp = Invoke-RestMethod -Uri $Uri -Method GET -ErrorAction Stop
        if ($null -ne $Resp.Items) { foreach ($It in $Resp.Items) { $null = $Items.Add($It) } }
        $Uri = $Resp.NextPageLink
        $Page++
    }

    return @($Items)
}

function Global:Get-RdaFoundryCoverageTokenFields
{
    # The coverage CSV's token columns for ONE deployment, read from what the Tier 2 token
    # collector (GetFoundryTokenConsumption in ResourceInventory.ps1) already collected for its
    # account. Coverage never queries Azure Monitor itself: one owner of the token metric calls,
    # their retry/denial handling and the Az.Monitor result parsing.
    #
    # TokenProbeStatus says what the token columns mean, so a failed probe is never read as a zero:
    #   Collected      every token metric the account supports was read. A blank column is a metric
    #                  the account does not support; 0 is a real zero for the window.
    #   Partial        some metrics were read and others failed (denied, throttled out, error).
    #                  Only the failed columns are blank.
    #   NoTokenMetrics the account supports none of the three token metrics. A real absence.
    #   Failed         no token metric could be read, or the token phase failed for this
    #                  subscription or run. The blanks are NOT a zero.
    #   NotRun         the token phase did not run (-SkipMetrics / -SkipFoundryTokens), or it did not
    #                  reach this account. The blanks are NOT a zero.
    # (Rows that are not a deployment use NotApplicable; the caller sets that.)
    #
    # $AccountResult is the collector's record for the account: Metrics (metric name -> outcome),
    # Totals (deployment name -> metric name -> total) and NoDeployments. A deployment missing from
    # Totals for a Collected metric had no data points in the window, which is a real zero.
    param(
        [ValidateSet('NotRun', 'Failed', 'Ran')][string]$TokenPhaseState = 'NotRun',
        $AccountResult = $null,
        [bool]$SubscriptionFailed = $false,
        [string]$DeploymentName = ''
    )

    $Result = [pscustomobject]@{ TokenProbeStatus = 'NotRun'; TokenMetricsPresent = $false; InputTokens = ''; OutputTokens = ''; TotalTokens = '' }

    if ($TokenPhaseState -eq 'Failed')
    {
        $Result.TokenProbeStatus = 'Failed'
        return $Result
    }
    if ($TokenPhaseState -ne 'Ran') { return $Result }
    if ($null -eq $AccountResult)
    {
        if ($SubscriptionFailed) { $Result.TokenProbeStatus = 'Failed' }
        return $Result
    }
    if ($AccountResult.NoDeployments) { return $Result }

    $CollectedCount = 0
    $FailedCount = 0
    foreach ($Column in 'InputTokens', 'OutputTokens', 'TotalTokens')
    {
        $Outcome = $null
        if ($null -ne $AccountResult.Metrics -and $AccountResult.Metrics.ContainsKey($Column)) { $Outcome = $AccountResult.Metrics[$Column] }

        if ($Outcome -eq 'Collected')
        {
            $CollectedCount++
            $Total = 0.0
            if ($null -ne $AccountResult.Totals -and $AccountResult.Totals.ContainsKey($DeploymentName) -and $AccountResult.Totals[$DeploymentName].ContainsKey($Column))
            {
                $Total = [double]$AccountResult.Totals[$DeploymentName][$Column]
            }
            $Result.$Column = $Total
        }
        elseif ($Outcome -ne 'NotSupported')
        {
            # Denied, Failed, or never reached because the account failed first.
            $FailedCount++
        }
    }

    $Result.TokenMetricsPresent = ($CollectedCount -gt 0)
    if ($CollectedCount -gt 0 -and $FailedCount -eq 0)
    {
        $Result.TokenProbeStatus = 'Collected'
    }
    elseif ($CollectedCount -gt 0)
    {
        $Result.TokenProbeStatus = 'Partial'
    }
    elseif ($FailedCount -gt 0)
    {
        $Result.TokenProbeStatus = 'Failed'
    }
    else
    {
        $Result.TokenProbeStatus = 'NoTokenMetrics'
    }

    return $Result
}

function Global:Resolve-ObfuscationToken
{
    param(
        [string]$RealValue,
        [string]$LookupKey,
        $SharedDictionary,
        [hashtable]$LocalCache,
        [string]$TokenPrefix
    )

    if ($null -ne $SharedDictionary -and $SharedDictionary.ContainsKey($LookupKey)) { return $SharedDictionary[$LookupKey] }
    if ($LocalCache.ContainsKey($RealValue)) { return $LocalCache[$RealValue] }

    $Token = $TokenPrefix + [guid]::NewGuid().ToString()
    $LocalCache[$RealValue] = $Token
    return $Token
}

function Global:Build-ObfuscatedResourceUri
{
    param(
        [string]$RawUri,
        [string]$Prefix,
        $SubscriptionDictionary,
        $ResourceGroupDictionary,
        $NameDictionary,
        [hashtable]$SubCache,
        [hashtable]$RgCache,
        [hashtable]$NameCache
    )

    if ([string]::IsNullOrEmpty($RawUri))
    {
        return 'obfuscated'
    }

    if ($RawUri -notmatch '^/subscriptions/([^/]+)(/resourcegroups/([^/]+))?(/providers/(.+))?$')
    {
        if (-not $NameCache.ContainsKey($RawUri))
        {
            $NameCache[$RawUri] = $Prefix + [guid]::NewGuid().ToString()
        }
        return $NameCache[$RawUri]
    }

    $RealSub = $Matches[1]
    $RealRg = $Matches[3]
    $RealProv = $Matches[5]

    $ObfSub = Resolve-ObfuscationToken -RealValue $RealSub -LookupKey $RawUri -SharedDictionary $SubscriptionDictionary -LocalCache $SubCache -TokenPrefix ($Prefix + 'sub_')
    $RebuiltUri = '/subscriptions/' + $ObfSub

    if (-not [string]::IsNullOrEmpty($RealRg))
    {
        $RgTag = if ($RealRg -match '^mc_') { 'mc_' } else { '' }
        $ObfRg = Resolve-ObfuscationToken -RealValue $RealRg -LookupKey $RawUri -SharedDictionary $ResourceGroupDictionary -LocalCache $RgCache -TokenPrefix ($Prefix + 'rg_' + $RgTag)
        $RebuiltUri += '/resourcegroups/' + $ObfRg
    }

    if (-not [string]::IsNullOrEmpty($RealProv))
    {
        $ProvParts = $RealProv -split '/'
        $LeafNameIndex = -1
        for ($Li = $ProvParts.Count - 1; $Li -ge 2; $Li--)
        {
            if ($Li % 2 -eq 0) { $LeafNameIndex = $Li; break }
        }

        $Rebuilt = @()
        for ($Pi = 0; $Pi -lt $ProvParts.Count; $Pi++)
        {
            $Part = $ProvParts[$Pi]
            $IsNameSegment = ($Pi -ge 2 -and ($Pi % 2 -eq 0))
            if ($IsNameSegment -and -not [string]::IsNullOrEmpty($Part) -and $Part -ne '$system')
            {
                $LeafShared = if ($Pi -eq $LeafNameIndex) { $NameDictionary } else { $null }
                $Rebuilt += Resolve-ObfuscationToken -RealValue $Part -LookupKey $RawUri -SharedDictionary $LeafShared -LocalCache $NameCache -TokenPrefix $Prefix
            }
            else
            {
                $Rebuilt += $Part
            }
        }
        $RebuiltUri += '/providers/' + ($Rebuilt -join '/')
    }

    return $RebuiltUri
}

function Global:Protect-DiagnosticText([string]$Text, [System.Collections.IDictionary]$ValueMap)
{
    if ([string]::IsNullOrEmpty($Text)) { return $Text }

    $Result = $Text
    if ($null -ne $ValueMap -and $ValueMap.Count -gt 0)
    {
        foreach ($real in ($ValueMap.Keys | Sort-Object -Property Length -Descending))
        {
            if (-not [string]::IsNullOrEmpty($real) -and $Result.Contains($real))
            {
                $Result = $Result.Replace($real, $ValueMap[$real])
            }
        }
    }

    $Result = [regex]::Replace($Result, '(?i)\b(sig|signature|sas|accesstoken|access_token|bearertoken|accountkey|sharedaccesskey|sharedaccesssignature|password|pwd|client_secret|clientsecret|[a-z0-9_\-]*(?:key|secret|token))=[^&;\s"''<>]+', '$1=<redacted>')
    $Result = [regex]::Replace($Result, '(?i)\bBearer\s+[A-Za-z0-9._\-]+', 'Bearer <redacted>')

    $Result = [regex]::Replace($Result, '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}', '<email>')
    $Result = [regex]::Replace($Result, '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b', '<ip>')
    $Result = [regex]::Replace($Result, '(?i)\b[a-z0-9][a-z0-9-]*\.(?:blob|file|queue|table|dfs|vault|database|servicebus|azurewebsites|documents|search|azurecr|azuredatabricks|cognitiveservices|azconfig|azurefd|azure-api)\.[a-z0-9.]+\b', '<host>')
    $Result = [regex]::Replace($Result, '(?i)\b[a-z0-9][a-z0-9-]*\.(?:cloudapp\.azure\.com|trafficmanager\.net|cache\.windows\.net)\b', '<host>')
    $Result = [regex]::Replace($Result, '(?i)/home/[a-z0-9._-]+', '/home/<user>')
    $Result = [regex]::Replace($Result, '(?i)C:\\Users\\[a-z0-9._-]+', 'C:\Users\<user>')
    $Result = [regex]::Replace($Result, '(?<!_)\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b', '<guid>')

    return $Result
}

function Get-RetryWaitSeconds
{
    param(
        [Parameter(Mandatory = $true)]$Exception,
        [Parameter(Mandatory = $true)][double]$FallbackSeconds,
        [double]$MaxSeconds = 120
    )

    $ReadHeader = {
        param($Container, $Name)
        if ($null -eq $Container) { return $null }
        $Enum = $null
        try { $Enum = $Container.GetEnumerator() } catch { return $null }
        if ($null -eq $Enum) { return $null }
        while ($Enum.MoveNext())
        {
            $Pair = $Enum.Current
            if ($Pair.Key -and (([string]$Pair.Key).Trim().ToLowerInvariant() -eq $Name))
            {
                $Val = @($Pair.Value)[0]
                if ($null -ne $Val) { return [string]$Val }
            }
        }
        return $null
    }

    $Containers = @()
    foreach ($Ex in @($Exception, $Exception.InnerException))
    {
        if ($null -ne $Ex -and $null -ne $Ex.Response -and $null -ne $Ex.Response.Headers)
        {
            $Containers += $Ex.Response.Headers
        }
    }
    if ($Containers.Count -eq 0) { return $FallbackSeconds }

    $FirstHeader = {
        param($Name)
        foreach ($Container in $Containers)
        {
            $Found = & $ReadHeader $Container $Name
            if ($Found) { return $Found }
        }
        return $null
    }

    $Raw = & $FirstHeader 'retry-after'
    if ($Raw)
    {
        $Sec = 0
        if ([int]::TryParse($Raw.Trim(), [ref]$Sec) -and $Sec -gt 0)
        {
            return [math]::Min([math]::Max($Sec, 1), $MaxSeconds)
        }
    }

    $Raw = & $FirstHeader 'x-ms-ratelimit-microsoft.consumption-retry-after'
    if ($Raw)
    {
        $Sec = 0
        if ([int]::TryParse($Raw.Trim(), [ref]$Sec) -and $Sec -gt 0)
        {
            return [math]::Min([math]::Max($Sec, 1), $MaxSeconds)
        }
    }

    $Raw = & $FirstHeader 'x-ms-user-quota-resets-after'
    if ($Raw)
    {
        $Span = [TimeSpan]::Zero
        if ([TimeSpan]::TryParse($Raw.Trim(), [System.Globalization.CultureInfo]::InvariantCulture, [ref]$Span) -and $Span.TotalSeconds -ge 1)
        {
            return [math]::Min($Span.TotalSeconds, $MaxSeconds)
        }
    }

    return $FallbackSeconds
}

function Get-AzGraphErrorInfo
{
    param($Exception)

    $Info = [pscustomobject]@{
        Codes               = @()
        HttpStatus          = 0
        Message             = ''
        HasStructuredBody   = $false
        IsPayloadTooLarge   = $false
        IsThrottled         = $false
        IsPermanent         = $false
        IsEmptyPropertyName = $false
    }
    if ($null -eq $Exception) { return $Info }

    try { $Info.Message = [string]$Exception.Message } catch { $Info.Message = '' }

    $Codes = New-Object System.Collections.Generic.List[string]
    $Node = $Exception
    $Depth = 0
    while ($null -ne $Node -and $Depth -lt 5)
    {
        try
        {
            $Err = $Node.Body.Error
            if ($null -ne $Err)
            {
                $Info.HasStructuredBody = $true
                if ($Err.Code) { $Codes.Add([string]$Err.Code) }
                foreach ($Detail in @($Err.Details))
                {
                    if ($Detail -and $Detail.Code) { $Codes.Add([string]$Detail.Code) }
                }
            }
        }
        catch { }
        if ($Info.HttpStatus -eq 0)
        {
            try
            {
                if ($null -ne $Node.Response -and $null -ne $Node.Response.StatusCode)
                {
                    $Info.HttpStatus = [int]$Node.Response.StatusCode
                }
            }
            catch { }
        }
        try { $Node = $Node.InnerException } catch { $Node = $null }
        $Depth++
    }
    $Info.Codes = @($Codes | Select-Object -Unique)

    $HasCode = {
        param([string]$Name)
        foreach ($C in $Info.Codes) { if ($C -and $C.Equals($Name, [System.StringComparison]::OrdinalIgnoreCase)) { return $true } }
        return $false
    }

    $Info.IsPayloadTooLarge = (& $HasCode 'ResponsePayloadTooLarge')

    $Info.IsThrottled = ($Info.HttpStatus -eq 429) -or (& $HasCode 'TooManyRequests') -or (& $HasCode 'ThrottledRequest')

    if (-not $Info.IsPayloadTooLarge -and -not $Info.IsThrottled)
    {
        $Permanent4xx = ($Info.HttpStatus -ge 400 -and $Info.HttpStatus -lt 500 -and $Info.HttpStatus -ne 408 -and $Info.HttpStatus -ne 429)
        $PermanentCode = (& $HasCode 'AuthorizationFailed') -or (& $HasCode 'Forbidden') -or (& $HasCode 'InvalidQuery') -or
        (& $HasCode 'SemanticError') -or (& $HasCode 'SyntaxError') -or (& $HasCode 'ParserFailure') -or
        (& $HasCode 'BadRequest') -or (& $HasCode 'InvalidAuthenticationToken')
        $Info.IsPermanent = ($Permanent4xx -or $PermanentCode)
    }

    if (-not $Info.HasStructuredBody -and $Info.HttpStatus -eq 0)
    {
        $Text = $Info.Message
        if ($Text -match 'ResponsePayloadTooLarge|Response payload size is \d+, exceeded the limit') { $Info.IsPayloadTooLarge = $true }
        elseif ($Text -match 'TooManyRequests|\b429\b|throttl') { $Info.IsThrottled = $true }
        elseif ($Text -match 'the value of argument "name" is not valid|property whose name is an empty string')
        {
            $Info.IsEmptyPropertyName = $true
        }
        elseif ($Text -match 'AuthorizationFailed|does not have authorization|\bForbidden\b|\bBadRequest\b|SemanticError|SyntaxError|InvalidQuery|Please provide a valid') { $Info.IsPermanent = $true }
    }

    return $Info
}

$Script:RdaEmptyPropertyNameSentinel = '_rda_emptykey'

function Get-AzGraphRowsViaRest
{
    param(
        [Parameter(Mandatory = $true)][string]$Query,
        [string[]]$Subscription,
        [int]$First = 1000,
        [int]$Skip = 0
    )

    $Body = @{
        query   = $Query
        options = @{
            '$top'  = $First
            '$skip' = $Skip
        }
    }
    if ($Subscription) { $Body['subscriptions'] = @($Subscription) }

    $Payload = $Body | ConvertTo-Json -Depth 10
    $Response = Invoke-AzRestMethod -Method POST `
        -Path '/providers/Microsoft.ResourceGraph/resources?api-version=2021-03-01' `
        -Payload $Payload -ErrorAction Stop

    $Status = [int]$Response.StatusCode
    if ($Status -lt 200 -or $Status -ge 300)
    {
        $Detail = [string]$Response.Content
        if ($Detail.Length -gt 500) { $Detail = $Detail.Substring(0, 500) + '...(truncated)' }
        throw ("Resource Graph REST fallback returned HTTP {0}: {1}" -f $Status, $Detail)
    }

    $Sanitized = [regex]::Replace(
        $Response.Content,
        '(?<=[{,]\s*)""(?=\s*:)',
        ('"' + $Script:RdaEmptyPropertyNameSentinel + '"'))

    $Parsed = $Sanitized | ConvertFrom-Json
    if ($null -ne $Parsed -and $Parsed.PSObject.Properties.Name -contains 'data')
    {
        return @($Parsed.data)
    }
    return @()
}

function Invoke-AzGraphRequest
{
    param(
        [Parameter(Mandatory = $true)][string]$Query,
        [string[]]$Subscription,
        [int]$First = 1000,
        [int]$Skip = 0
    )

    $GraphParams = @{ Query = $Query; First = $First; ErrorAction = 'Stop' }
    if ($Subscription) { $GraphParams['Subscription'] = $Subscription }
    if ($Skip -gt 0) { $GraphParams['Skip'] = $Skip }

    $GraphMaxRetries = 30
    $Rows = $null
    $FailureMessage = $null
    $Failure = $null
    $AttemptsMade = 0

    for ($Attempt = 0; ; $Attempt++)
    {
        $AttemptsMade = $Attempt + 1
        try
        {
            $Response = Search-AzGraph @GraphParams
            $Rows = if ($null -eq $Response) { @() } else { @($Response) }
            $FailureMessage = $null
            $Failure = $null
            break
        }
        catch
        {
            $ErrorInfo = Get-AzGraphErrorInfo -Exception $_.Exception
            $Message = $ErrorInfo.Message
            $CodeText = if ($ErrorInfo.Codes.Count -gt 0) { ' [' + ($ErrorInfo.Codes -join ', ') + ']' } else { '' }

            if ($ErrorInfo.IsPayloadTooLarge)
            {
                $Failure = $ErrorInfo
                break
            }

            if ($ErrorInfo.IsEmptyPropertyName)
            {
                try
                {
                    $Rows = @(Get-AzGraphRowsViaRest -Query $Query -Subscription $Subscription -First $First -Skip $Skip)
                    $FailureMessage = $null
                    $Failure = $null
                    Write-Log -Message ("Recovered {0} row(s) at offset {1} via the raw Resource Graph REST path after an empty-property-name materialization error; empty JSON keys were renamed to '{2}'. The resource(s) were captured, not dropped." -f $Rows.Count, $Skip, $Script:RdaEmptyPropertyNameSentinel) -Severity 'Warning'
                    break
                }
                catch
                {
                    $RestInfo = Get-AzGraphErrorInfo -Exception $_.Exception
                    $Failure = $RestInfo
                    $FailureMessage = ("Resource Graph empty-property-name recovery via REST failed at offset {0}: {1}`nQuery: {2}" -f $Skip, $RestInfo.Message, $Query)
                    break
                }
            }

            if ($ErrorInfo.IsPermanent -or $Attempt -ge $GraphMaxRetries)
            {
                $Failure = $ErrorInfo
                $FailureMessage = ("Resource Graph query failed after {0} attempt(s): {1}{2}`nQuery: {3}" -f $AttemptsMade, $Message, $CodeText, $Query)
                break
            }

            $Throttled = $ErrorInfo.IsThrottled
            $Backoff = [math]::Min([math]::Pow(2, $Attempt), 30)
            if ($Throttled) { $Backoff = [math]::Min($Backoff * 2, 60) }
            $Backoff = Get-RetryWaitSeconds -Exception $_.Exception -FallbackSeconds $Backoff -MaxSeconds 120
            $Jitter = (Get-Random -Minimum 0 -Maximum 1000) / 1000.0
            Start-Sleep -Seconds ([math]::Round($Backoff + $Jitter, 2))
        }
    }

    return [pscustomobject]@{
        Rows           = $Rows
        Failure        = $Failure
        FailureMessage = $FailureMessage
        Attempts       = $AttemptsMade
    }
}

function Get-AzGraphRowWindow
{
    param(
        [Parameter(Mandatory = $true)][string]$Query,
        [string[]]$Subscription,
        [int]$First = 1000,
        [int]$Skip = 0
    )

    $Pending = New-Object System.Collections.Stack
    $Pending.Push([pscustomobject]@{ Skip = $Skip; First = $First })
    $Rows = @()
    $SplitCount = 0

    $FatalMessage = $null

    while ($Pending.Count -gt 0)
    {
        $Window = $Pending.Pop()
        $Result = Invoke-AzGraphRequest -Query $Query -Subscription $Subscription -First $Window.First -Skip $Window.Skip

        if ($null -eq $Result.Failure)
        {
            $Rows += @($Result.Rows)
            continue
        }

        $Message = $Result.Failure.Message

        if (-not $Result.Failure.IsPayloadTooLarge)
        {
            $FatalMessage = $Result.FailureMessage
            break
        }

        if ($Query -notmatch 'order\s+by')
        {
            $FatalMessage = ("Resource Graph refused the response as too large and the query is not ordered, so it cannot be split safely. Add an 'order by' clause to page it.`n{0}`nQuery: {1}" -f $Message, $Query)
            break
        }

        if ($Window.First -le 1)
        {
            $FatalMessage = ("Resource Graph refused a SINGLE resource as too large (offset {0}); it exceeds the 16 MB response cap and cannot be retrieved. Exclude this resource type from the discovery query to complete the run.`n{1}" -f $Window.Skip, $Message)
            break
        }

        $LeftCount = [math]::Floor($Window.First / 2)
        $RightCount = $Window.First - $LeftCount
        $Pending.Push([pscustomobject]@{ Skip = ($Window.Skip + $LeftCount); First = $RightCount })
        $Pending.Push([pscustomobject]@{ Skip = $Window.Skip; First = $LeftCount })
        $SplitCount++
        Write-Log -Message ("Resource Graph response too large at offset {0} for {1} rows; retrying as {2} + {3}." -f $Window.Skip, $Window.First, $LeftCount, $RightCount) -Severity 'Warning'
    }

    if ($null -ne $FatalMessage) { throw $FatalMessage }

    if ($SplitCount -gt 0)
    {
        Write-Log -Message ("Fetched offset {0}..{1} in smaller sub-pages after {2} split(s); {3} row(s) collected. This subscription holds at least one unusually large resource type." -f $Skip, ($Skip + $First - 1), $SplitCount, $Rows.Count) -Severity 'Warning'
    }

    return $Rows
}

function Invoke-AzGraphQuerySafe
{
    param(
        [Parameter(Mandatory = $true)][string]$Query,
        [string[]]$Subscription,
        [int]$First = 1000,
        [int]$Skip = 0,
        [switch]$Lowercase
    )

    $Rows = @(Get-AzGraphRowWindow -Query $Query -Subscription $Subscription -First $First -Skip $Skip)

    if ($Lowercase -and $Rows.Count -gt 0)
    {
        $Json = ($Rows | ConvertTo-Json -Depth 100).ToLowerInvariant()
        $Json = [regex]::Replace($Json, '(?<=[{,]\s*)""(?=\s*:)', ('"' + $Script:RdaEmptyPropertyNameSentinel + '"'))
        $Rows = @($Json | ConvertFrom-Json)
    }

    return [pscustomobject]@{ data = $Rows }
}

function Write-RdaShareableDiagnosticsLog
{
    param(
        [string]$DefaultPath,
        [string]$ReportName,
        [string]$RunDateTime,
        [string]$Version,
        $PhaseTimings,
        $MemoryReadings = @(),
        [int]$ConsumptionRecordCount = 0,
        # Rows FETCHED from the billing API. -1 = not supplied.
        [int]$ConsumptionRowsFetchedCount = -1,
        [bool]$ConsumptionRequested = $true,
        [int]$MarketplaceRecordCount = 0,
        [bool]$MarketplaceRequested = $true,
        [int]$MetricsApiCallCount = 0,
        [bool]$MetricsRequested = $true,
        # Billing was not pulled because the collector circuit breaker aborted collection, not because
        # of an operator -Skip switch; the n/a line would otherwise name a switch nobody passed. Closed
        # switches rather than free text: the Diagnostics log ships, and its wording is owned here. Each
        # is read only on the n/a line, that is, when the matching -*Requested is false and no record
        # was kept.
        [switch]$ConsumptionSkippedForAbort,
        [switch]$MarketplaceSkippedForAbort,
        # Was this run scoped with -ResourceGroup? Selects which exclusions the
        # excluded-by-scope note is allowed to name - see
        # Get-RdaConsumptionExcludedByScopeText. A [bool] defaulting to $false (not
        # a [switch]) so an omitting caller gets the honest narrow form.
        [bool]$ConsumptionResourceGroupScoped = $false,
        [switch]$Obfuscated
    )

    # -1 means "not supplied". A caller reporting only the collected count is
    # describing a run where nothing was excluded, so fetched collapses to written and
    # every existing gate verdict is preserved. A default of 0 would instead read as
    # "N written out of 0 fetched", which is impossible, and would fire the zero-record
    # warning on every existing caller.
    $RowsFetched = if ($ConsumptionRowsFetchedCount -lt 0) { $ConsumptionRecordCount } else { $ConsumptionRowsFetchedCount }

    try
    {
        $DiagScrubMap = @{}
        if ($null -ne $Global:ResourceIdDictionary)
        {
            foreach ($realId in $Global:ResourceIdDictionary.Keys)
            {
                if ([string]::IsNullOrEmpty($realId)) { continue }
                if (-not $DiagScrubMap.ContainsKey($realId)) { $DiagScrubMap[$realId] = $Global:ResourceIdDictionary[$realId] }

                $ShortName = ($realId -split '/')[-1]
                if (-not [string]::IsNullOrEmpty($ShortName) -and $null -ne $Global:ResourceNameDictionary -and $Global:ResourceNameDictionary.ContainsKey($realId) -and -not $DiagScrubMap.ContainsKey($ShortName))
                {
                    $DiagScrubMap[$ShortName] = $Global:ResourceNameDictionary[$realId]
                }
                if ($realId -match '(?i)/resourceGroups/([^/]+)')
                {
                    $RgName = $Matches[1]
                    if (-not [string]::IsNullOrEmpty($RgName) -and $null -ne $Global:ResourceResourceGroupDictionary -and $Global:ResourceResourceGroupDictionary.ContainsKey($realId) -and -not $DiagScrubMap.ContainsKey($RgName))
                    {
                        $DiagScrubMap[$RgName] = $Global:ResourceResourceGroupDictionary[$realId]
                    }
                }
                if ($realId -match '(?i)/subscriptions/([^/]+)')
                {
                    $SubGuid = $Matches[1]
                    if (-not [string]::IsNullOrEmpty($SubGuid) -and $null -ne $Global:ResourceSubscriptionDictionary -and $Global:ResourceSubscriptionDictionary.ContainsKey($realId) -and -not $DiagScrubMap.ContainsKey($SubGuid))
                    {
                        $DiagScrubMap[$SubGuid] = $Global:ResourceSubscriptionDictionary[$realId]
                    }
                }
            }
        }
        if ($null -ne $Global:TagValueDictionary)
        {
            foreach ($tagReal in $Global:TagValueDictionary.Keys) { if (-not [string]::IsNullOrEmpty($tagReal) -and -not $DiagScrubMap.ContainsKey($tagReal)) { $DiagScrubMap[$tagReal] = $Global:TagValueDictionary[$tagReal] } }
        }
        if ($null -ne $Global:FreeTextDictionary)
        {
            foreach ($ftReal in $Global:FreeTextDictionary.Keys) { if (-not [string]::IsNullOrEmpty($ftReal) -and -not $DiagScrubMap.ContainsKey($ftReal)) { $DiagScrubMap[$ftReal] = $Global:FreeTextDictionary[$ftReal] } }
        }

        $PhaseTimingsText = [ordered]@{}
        if ($null -ne $PhaseTimings)
        {
            foreach ($PhaseName in $PhaseTimings.Keys)
            {
                $PhaseTotalSec = [int][math]::Round(([TimeSpan]$PhaseTimings[$PhaseName]).TotalSeconds)
                $PhaseTimingsText[$PhaseName] = ('{0}min {1:D2} sec' -f [int][math]::Floor($PhaseTotalSec / 60), ($PhaseTotalSec % 60))
            }
        }

        $CollectorFails = @(@($Global:CollectorFailures) | Where-Object { $null -ne $_ })
        $MetricsSkips = @(@($Global:MetricsFailedSubs) | Where-Object { $null -ne $_ })
        $ConsumpSkips = @(@($Global:ConsumptionFailedSubs) | Where-Object { $null -ne $_ })
        $MarketplaceSkips = @(@($Global:MarketplaceFailedSubs) | Where-Object { $null -ne $_ })

        $DiagLines = [System.Collections.Generic.List[string]]::new()
        if ($Obfuscated)
        {
            $DiagLines.Add('Resource Discovery for Azure - shareable diagnostics (obfuscated run)')
            $DiagLines.Add('Safe to share: identifiers are obfuscated/masked. Human-readable')
            $DiagLines.Add('troubleshooting log - NOT report data, do not ingest into tables.')
        }
        else
        {
            $DiagLines.Add('Resource Discovery for Azure - diagnostics (default/non-obfuscated run)')
            $DiagLines.Add('NOTE: this bundle is NOT obfuscated - the report itself contains real')
            $DiagLines.Add('identifiers. This log masks GUIDs/emails but treat the whole bundle as')
            $DiagLines.Add('sensitive. Human-readable troubleshooting log - NOT report data, do not')
            $DiagLines.Add('ingest into tables.')
        }
        $DiagLines.Add(('Generated (UTC) : {0}' -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [cultureinfo]::InvariantCulture)))
        $DiagLines.Add(('Tool version    : {0}' -f [string]$Version))
        $DiagLines.Add('')
        $DiagLines.Add('Phase timings:')
        if ($PhaseTimingsText.Count -gt 0)
        {
            foreach ($PhaseName in $PhaseTimingsText.Keys) { $DiagLines.Add(('  {0}: {1}' -f $PhaseName, $PhaseTimingsText[$PhaseName])) }
        }
        else
        {
            $DiagLines.Add('  (none recorded)')
        }
        $DiagLines.Add('')
        $DiagLines.Add(('Collector failures: {0}' -f $CollectorFails.Count))
        foreach ($cfItem in $CollectorFails)
        {
            $DiagLines.Add(('  [sub {0}] {1}: {2}' -f (Protect-DiagnosticText ([string]$cfItem.Id) $DiagScrubMap), [string]$cfItem.Module, (Protect-DiagnosticText ([string]$cfItem.Message) $DiagScrubMap)))
        }
        $DiagLines.Add('')
        $DiagLines.Add(('Metrics auth-skipped subscriptions: {0}' -f $MetricsSkips.Count))
        foreach ($msItem in $MetricsSkips)
        {
            $DiagLines.Add(('  [sub {0}] {1}' -f (Protect-DiagnosticText ([string]$msItem.Id) $DiagScrubMap), (Protect-DiagnosticText ([string]$msItem.Message) $DiagScrubMap)))
        }
        $DiagLines.Add('')
        $DiagLines.Add(('Consumption failed/incomplete subscriptions: {0}' -f $ConsumpSkips.Count))
        foreach ($csItem in $ConsumpSkips)
        {
            $DiagLines.Add(('  [sub {0}] {1}' -f (Protect-DiagnosticText ([string]$csItem.Id) $DiagScrubMap), (Protect-DiagnosticText ([string]$csItem.Message) $DiagScrubMap)))
        }

        $DiagLines.Add('')
        $AbortNaReason = 'not pulled because collection was aborted by the circuit breaker'
        if ($ConsumptionRequested -or $ConsumptionRecordCount -ne 0)
        {
            $DiagLines.Add(('Consumption records collected: {0}' -f $ConsumptionRecordCount.ToString('N0', [cultureinfo]::InvariantCulture)))
            $DiagLines.Add(('Consumption rows fetched from the billing API: {0}' -f $RowsFetched.ToString('N0', [cultureinfo]::InvariantCulture)))
        }
        else
        {
            $ConsumptionNaReason = if ($ConsumptionSkippedForAbort) { $AbortNaReason } else { '-SkipConsumption was passed' }
            $DiagLines.Add(('Consumption records collected: n/a ({0})' -f $ConsumptionNaReason))
        }

        if ($ConsumptionRequested -and $RowsFetched -eq 0 -and $ConsumpSkips.Count -eq 0)
        {
            # LIMITATION (accepted): $ConsumpSkips reads $Global:ConsumptionFailedSubs,
            # which accumulates across the subscriptions of one run: ResourceInventory.ps1
            # nil-initializes it and '+='s per subscription in the same process.
            # Run-AllSubscriptions.ps1 resets it once per run on the sequential path; with
            # -ParallelStreams each stream is a separate process that
            # Run-AllSubscriptions.Stream.ps1 resets once. So one earlier subscription's
            # billing failure suppresses this zero-records warning for every LATER
            # subscription in the same run or stream, including one whose billing API
            # genuinely returned no rows. This is bounded: the failure list above is still
            # printed, so the log never reads as a clean run. Scoping the guard to this
            # invocation would take a per-invocation failure count passed in the way
            # -ConsumptionRecordCount is, which this diagnostics writer does not take.
            $DiagLines.Add('  WARNING - consumption was requested but ZERO usage records were collected,')
            $DiagLines.Add('  and no subscription reported a billing error. The billing API answered')
            $DiagLines.Add('  successfully with no rows, so the Consumption CSV holds only its header.')
            $DiagLines.Add('  Expected ONLY if there is genuinely no usage in the queried window (the 30')
            $DiagLines.Add('  days ending at midnight yesterday, host local time). Otherwise the usual causes are:')
            $DiagLines.Add('    - CSP / Partner-managed subscription with the partner cost visibility')
            $DiagLines.Add('      policy OFF (the default). Billing scope on CSP subscriptions is not')
            $DiagLines.Add('      governed by Azure RBAC, so granting Cost Management Reader does not')
            $DiagLines.Add('      help - the partner must enable it in Partner Center.')
            $DiagLines.Add('    - Subscription not transitioned to the Azure plan.')
            $DiagLines.Add('    - A subscription offer the legacy usage API does not serve.')
        }
        # The other half of that signature, and the half nothing reported at all
        # before: the billing API DID return rows, and the tool excluded every one
        # of them. The causes named above are all false here - the API answered with
        # data - so this branch is mutually exclusive with the one above and carries
        # the scope/filter explanation instead.
        #
        # Inert by design when -ConsumptionRowsFetchedCount is omitted: the -1
        # sentinel collapses $RowsFetched to $ConsumptionRecordCount, so the two
        # tests below cannot both hold. That is right - with no fetched figure
        # nothing is KNOWN to have been excluded, so staying silent beats guessing.
        # This is load-bearing: do not "simplify" the sentinel without re-checking it.
        #
        # The $ConsumpSkips.Count -eq 0 guard is deliberately SHARED with the sibling
        # above: a reported billing failure is already surfaced by its own block, and
        # it - not scope - is then the reason nothing was written. Neither branch may
        # also claim a cause in that case, so this guard must stay in step with its
        # sibling. Both branches of Get-RunSummaryLogContent carry the equivalent
        # ($Consumption.Count -eq 0); the parity is on THAT guard only - those two
        # also carry ($Processed -gt 0), which has no per-subscription analogue here.
        #
        # Known limitation, accepted: $ConsumpSkips is run-CUMULATIVE, not
        # per-subscription (ResourceInventory.ps1 nil-initializes
        # $Global:ConsumptionFailedSubs once and appends per subscription in the same
        # process), so under the wrapper one subscription's billing failure also
        # withholds this note from later subscriptions. Bounded - the fetched/written
        # counts and the failure list are still printed - and the sibling above
        # already behaves this way. Narrowing it would need a current-subscription id
        # parameter this function does not take.
        elseif ($ConsumptionRequested -and $RowsFetched -gt 0 -and $ConsumptionRecordCount -eq 0 -and $ConsumpSkips.Count -eq 0)
        {
            foreach ($Line in (Get-RdaConsumptionExcludedByScopeText -RowsFetched $RowsFetched -Indent '  ' -ResourceGroupScoped:$ConsumptionResourceGroupScoped)) { $DiagLines.Add($Line) }
        }

        $DiagLines.Add('')
        $DiagLines.Add(('Marketplace failed/incomplete subscriptions: {0}' -f $MarketplaceSkips.Count))
        foreach ($mkItem in $MarketplaceSkips)
        {
            $DiagLines.Add(('  [sub {0}] {1}' -f (Protect-DiagnosticText ([string]$mkItem.Id) $DiagScrubMap), (Protect-DiagnosticText ([string]$mkItem.Message) $DiagScrubMap)))
        }
        $DiagLines.Add('')
        if ($MarketplaceRequested -or ($MarketplaceRecordCount -ne 0))
        {
            $DiagLines.Add(('Marketplace consumption records collected: {0}' -f $MarketplaceRecordCount.ToString('N0', [cultureinfo]::InvariantCulture)))
        }
        else
        {
            $MarketplaceNaReason = if ($MarketplaceSkippedForAbort) { $AbortNaReason } else { '-SkipMarketplace or -SkipConsumption was passed' }
            $DiagLines.Add(('Marketplace consumption records collected: n/a ({0})' -f $MarketplaceNaReason))
        }

        if ($MarketplaceRequested -and $MarketplaceRecordCount -eq 0 -and $MarketplaceSkips.Count -eq 0)
        {
            # HONEST NEGATIVE (mirrors the consumption zero-records note above). The
            # Microsoft.Consumption/marketplaces endpoint returns ONLY Marketplace-publisher
            # rows, so a successful call with zero rows is a CONFIRMED absence of Azure
            # Marketplace / third-party SaaS charges (e.g. an ISV SaaS offer) in the
            # window - not a missing or failed section. The Marketplace CSV
            # holds only its header in that case.
            $DiagLines.Add('  Note: ZERO Marketplace rows is a CONFIRMED zero (endpoint reached, no third-party/Marketplace charges billed), not a skipped section.')
        }

        $DiagLines.Add('')
        if ($MetricsRequested -or ($MetricsApiCallCount -ne 0))
        {
            $DiagLines.Add(('Metric-query API calls issued: {0}' -f $MetricsApiCallCount.ToString('N0', [cultureinfo]::InvariantCulture)))
        }
        else
        {
            $DiagLines.Add('Metric-query API calls issued: n/a (-SkipMetrics was passed)')
        }

        # Counts and megabytes, labelled by subscription. The label passes through the same scrub as
        # every other '[sub ...]' line here, so the default log masks the id as its header says.
        # Filtered to this run's stamp: the readings global is not reset by a standalone run, so a
        # prompt that has run the script before still holds the earlier run's rows. Rendered in its
        # own try/catch so a rendering fault costs this block, not the whole log.
        $MemoryLines = @()
        try
        {
            $MemoryLines = @(Get-RdaMemoryReadingLines -Readings $MemoryReadings -Stamp $RunDateTime -Obfuscated:$Obfuscated)
        }
        catch
        {
            $MemoryLines = @(('Memory readings unavailable: {0}' -f (Protect-DiagnosticText $_.Exception.Message $DiagScrubMap)))
        }
        if ($MemoryLines.Count -gt 0)
        {
            $DiagLines.Add('')
            foreach ($MemoryLine in $MemoryLines) { $DiagLines.Add((Protect-DiagnosticText $MemoryLine $DiagScrubMap)) }
        }

        $DiagnosticsFile = ($DefaultPath + "Diagnostics_" + $ReportName + "_" + $RunDateTime + ".log")
        ($DiagLines -join [Environment]::NewLine) | Out-File -LiteralPath $DiagnosticsFile -Encoding utf8
        Write-Log -Message ('Shareable diagnostics log written: {0}' -f (Split-Path -Path $DiagnosticsFile -Leaf)) -Severity 'Info'
        return $DiagnosticsFile
    }
    catch
    {
        Write-Log -Message ('Could not build/write shareable diagnostics log: {0}' -f $_.Exception.Message) -Severity 'Warning'
        return $null
    }
}

function Get-RdaRetryAfterSeconds
{
    param(
        [Parameter(Mandatory = $true)]$ErrorRecord
    )

    $HeaderNames = @('x-ms-ratelimit-microsoft.consumption-retry-after', 'Retry-After')

    try
    {
        $Ex = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ErrorRecord.Exception } else { $ErrorRecord }
        $Depth = 0
        while ($null -ne $Ex -and $Depth -lt 5)
        {
            $Headers = $null
            $ResponseProp = $Ex.PSObject.Properties['Response']
            if ($ResponseProp -and $null -ne $ResponseProp.Value)
            {
                $HeadersProp = $ResponseProp.Value.PSObject.Properties['Headers']
                if ($HeadersProp) { $Headers = $HeadersProp.Value }
            }

            if ($null -ne $Headers -and $Headers.Keys)
            {
                foreach ($Name in $HeaderNames)
                {
                    $Raw = $null
                    foreach ($Key in $Headers.Keys)
                    {
                        if ($Key -and $Key.Equals($Name, [System.StringComparison]::OrdinalIgnoreCase))
                        {
                            $Raw = @($Headers[$Key])[0]
                            break
                        }
                    }
                    if ([string]::IsNullOrWhiteSpace($Raw)) { continue }

                    $Raw = ([string]$Raw).Trim()

                    $Seconds = 0
                    if ([int]::TryParse($Raw, [ref]$Seconds))
                    {
                        if ($Seconds -lt 0) { $Seconds = 0 }
                        return $Seconds
                    }

                    $When = [datetimeoffset]::MinValue
                    if ([datetimeoffset]::TryParse($Raw, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$When))
                    {
                        $Delta = [int][math]::Ceiling(($When - [datetimeoffset]::UtcNow).TotalSeconds)
                        if ($Delta -lt 0) { $Delta = 0 }
                        return $Delta
                    }
                }
            }

            $Ex = $Ex.InnerException
            $Depth++
        }
    }
    catch
    {
    }

    return 0
}

