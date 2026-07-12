# Reveal-Obfuscation.ps1 unit tests
# =============================================================================
# Offline, self-contained tests for the partial-reveal helper. They build a
# synthetic obfuscated report bundle (Inventory JSON + Consumption CSV) and a
# matching ObfuscationDictionary fixture in a temp dir, zip it like an
# -Obfuscate run would, then run Reveal-Obfuscation.ps1 against it and assert:
#   - selected dimensions (Resource Group, Subscription name) are revealed,
#     including the Resource-Group-name parsing edge cases (AKS MC_ managed
#     groups, casing preserved) that the reveal tool shares
#   - UNSELECTED dimensions (Resource Id, Resource Name, and tag values unless
#     -Fields Tag is passed) stay masked
#   - the rewritten members are still valid (JSON parses, CSV columns intact
#     even when a revealed value contains a comma), and the literal 'obfuscated'
#     sentinel is left untouched
#   - older dictionaries (no SubscriptionNameMap) fall back to the sub GUID, and
#     -Fields Tag is a no-op when the dictionary has no TagMap
#   - the dictionary auto-discovers via -SearchDirectory, and the source zip is
#     never mutated
#
# The obfuscated tokens are generated at runtime as 'prod_'/'nonprod_' + a fresh
# GUID, so the tool's token regex matches them while no real GUID literal lives
# in this source file. The only literal GUID is the Azure docs placeholder used
# inside the synthetic ARM paths. No customer data.
# =============================================================================

BeforeAll {
    # The single-report reveal engine now lives in Reveal.ps1 (single mode), which
    # delegates to Invoke-RdaReveal. Reveal.ps1's single param set accepts the same
    # arguments the former standalone Reveal-Obfuscation.ps1 did (-InputZip,
    # -DictionaryPath, -SearchDirectory, -Fields, -All, -OutputZip), so every
    # invocation below drives it unchanged.
    $script:RevealScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'Reveal.ps1'
    if (-not (Test-Path $script:RevealScript)) {
        throw "Reveal.ps1 not found at $script:RevealScript"
    }

    $subGuid = '12345678-1234-1234-1234-123456789012'   # Azure docs placeholder
    $base = "/subscriptions/$subGuid/resourceGroups"

    # Runtime-generated obfuscated tokens (GUID-shaped so the tool matches them).
    $script:TokId     = 'prod_'    + [guid]::NewGuid().ToString()
    $script:TokName   = 'prod_'    + [guid]::NewGuid().ToString()
    $script:TokSub    = 'prod_'    + [guid]::NewGuid().ToString()
    $script:TokRg     = 'nonprod_' + [guid]::NewGuid().ToString()
    $script:TokRgAks  = 'prod_'    + [guid]::NewGuid().ToString()
    $script:TokRgCase = 'prod_'    + [guid]::NewGuid().ToString()
    $script:TokTag    = 'prod_'    + [guid]::NewGuid().ToString()
    $script:TokFree   = 'prod_'    + [guid]::NewGuid().ToString()

    # Real values behind the tokens. Subscription name deliberately contains a
    # comma and an ampersand to exercise CSV quoting and HTML encoding.
    $script:RealRgName   = 'rg-app'
    $script:RealRgAks    = 'MC_rg-aks_aks01_eastus'   # AKS managed RG
    $script:RealRgCase   = 'RG-APP'                   # casing must be preserved
    $script:RealSubName  = 'Contoso, Inc. (Prod) & Co'
    $script:RealTagVal   = 'payments'
    $script:RealFreeText = 'data-platform workspace for the analytics team'

    $idVm   = "$base/$($script:RealRgName)/providers/Microsoft.Compute/virtualMachines/vm01"
    $idAks  = "$base/$($script:RealRgAks)/providers/Microsoft.Compute/virtualMachines/aksnode0"
    $idCase = "$base/$($script:RealRgCase)/providers/Microsoft.Storage/storageAccounts/sa01"

    # ---- Dictionary fixture (current shape: has SubscriptionNameMap + TagMap) ----
    $dict = [ordered]@{
        GeneratedAt         = '2026-06-30 00:00:00'
        ResourceIdMap       = [ordered]@{ $script:TokId   = $idVm }
        ResourceNameMap     = [ordered]@{ $script:TokName = $idVm }
        SubscriptionMap     = [ordered]@{ $script:TokSub  = $idVm }
        ResourceGroupMap    = [ordered]@{
            $script:TokRg     = $idVm
            $script:TokRgAks  = $idAks
            $script:TokRgCase = $idCase
        }
        SubscriptionNameMap = [ordered]@{ $script:TokSub  = $script:RealSubName }
        TagMap              = [ordered]@{ $script:TokTag  = $script:RealTagVal }
        FreeTextMap         = [ordered]@{ $script:TokFree = $script:RealFreeText }
    }

    # ---- Synthetic obfuscated report members ----
    # vm01 carries the full set of dimensions; vmAks/vmCase exercise the two RG
    # name-parsing edge cases. A literal 'obfuscated' sentinel (out-of-scope
    # cross-ref) sits on vm01 and must survive untouched.
    $inventory = [ordered]@{
        VirtualMachines = @(
            [ordered]@{
                ID            = $script:TokId
                Name          = $script:TokName
                Subscription  = $script:TokSub
                ResourceGroup = $script:TokRg
                Set           = 'obfuscated'
                Description   = $script:TokFree
                Tags          = @( [ordered]@{ Name = 'environment'; Value = $script:TokTag } )
            }
            [ordered]@{
                ID            = $script:TokId
                Name          = $script:TokName
                Subscription  = $script:TokSub
                ResourceGroup = $script:TokRgAks
            }
            [ordered]@{
                ID            = $script:TokId
                Name          = $script:TokName
                Subscription  = $script:TokSub
                ResourceGroup = $script:TokRgCase
            }
        )
    }

    # Consumption CSV with the sub + rg tokens embedded inside an ARM-path field,
    # so revealing the comma-bearing subscription name must not break columns.
    $consumptionRows = @(
        [pscustomobject]@{
            InstanceId = "/subscriptions/$($script:TokSub)/resourceGroups/$($script:TokRg)/providers/Microsoft.Compute/virtualMachines/vm01"
            Cost       = '12.34'
        }
    )

    $script:TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("RevealTest_" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:TmpDir -Force | Out-Null

    $stageDir = Join-Path $script:TmpDir 'stage'
    New-Item -ItemType Directory -Path $stageDir -Force | Out-Null
    $inventory | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $stageDir 'Inventory_Test.json') -Encoding utf8
    $consumptionRows | Export-Csv -Path (Join-Path $stageDir 'Consumption_Test.csv') -NoTypeInformation -Encoding utf8
    # A tiny HTML member so the tool's HTML-encode escape branch is exercised:
    # the revealed subscription name carries an '&', which must come out as the
    # entity '&amp;' (matching the report's own encoding), not a raw '&'.
    "<html><body><table><tr><td>$($script:TokSub)</td></tr></table></body></html>" |
        Set-Content -Path (Join-Path $stageDir 'ResourcesReport_Test.html') -Encoding utf8

    $script:InputZip = Join-Path $script:TmpDir 'ResourcesReport_Test.zip'
    Compress-Archive -Path (Join-Path $stageDir '*') -DestinationPath $script:InputZip -Force
    $script:InputZipHashBefore = (Get-FileHash -Path $script:InputZip -Algorithm SHA256).Hash

    $script:DictPath = Join-Path $script:TmpDir 'ObfuscationDictionary_Test.json'
    $dict | ConvertTo-Json -Depth 6 | Set-Content -Path $script:DictPath -Encoding utf8

    # Helper: run reveal into a fresh output zip, extract, return parsed members.
    # -DictPath / -SearchDir let individual tests point at alternate fixtures.
    function Invoke-Reveal {
        param([string[]]$Fields, [string]$DictPath = $script:DictPath, [string]$SearchDir, [switch]$All)
        $out = Join-Path $script:TmpDir ("out_" + [guid]::NewGuid().ToString('N').Substring(0,8) + ".zip")
        $splat = @{ InputZip = $script:InputZip; OutputZip = $out }
        if ($SearchDir) { $splat['SearchDirectory'] = $SearchDir } else { $splat['DictionaryPath'] = $DictPath }
        if ($Fields) { $splat['Fields'] = $Fields }
        if ($All) { $splat['All'] = $true }
        & $script:RevealScript @splat *>&1 | Out-Null
        $ex = Join-Path $script:TmpDir ("ex_" + [guid]::NewGuid().ToString('N').Substring(0,8))
        Expand-Archive -Path $out -DestinationPath $ex -Force
        $invFile = Get-ChildItem $ex -Filter 'Inventory_*.json' | Select-Object -First 1
        $csvFile = Get-ChildItem $ex -Filter 'Consumption_*.csv' | Select-Object -First 1
        $htmlFile = Get-ChildItem $ex -Filter '*.html' | Select-Object -First 1
        return [pscustomobject]@{
            OutputZip = $out
            Inventory = (Get-Content $invFile.FullName -Raw | ConvertFrom-Json)
            Csv       = @(Import-Csv -Path $csvFile.FullName)
            Html      = (Get-Content $htmlFile.FullName -Raw)
        }
    }
}

AfterAll {
    if ($script:TmpDir -and (Test-Path $script:TmpDir)) {
        Remove-Item -Path $script:TmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe "Reveal-Obfuscation default fields (ResourceGroup + Subscription)" {

    BeforeAll { $script:R = Invoke-Reveal }

    It "produces valid JSON that re-parses" {
        $script:R.Inventory | Should -Not -BeNullOrEmpty
        @($script:R.Inventory.VirtualMachines).Count | Should -Be 3
    }

    It "reveals the resource group name" {
        $script:R.Inventory.VirtualMachines[0].ResourceGroup | Should -Be $script:RealRgName
    }

    It "reveals an AKS managed (MC_) resource group name" {
        $script:R.Inventory.VirtualMachines[1].ResourceGroup | Should -Be $script:RealRgAks
    }

    It "preserves resource-group name casing exactly as it appears in the Id" {
        $script:R.Inventory.VirtualMachines[2].ResourceGroup | Should -Be $script:RealRgCase
    }

    It "reveals the subscription friendly name (offline from SubscriptionNameMap)" {
        $script:R.Inventory.VirtualMachines[0].Subscription | Should -Be $script:RealSubName
    }

    It "leaves the Resource Id masked" {
        $script:R.Inventory.VirtualMachines[0].ID | Should -Be $script:TokId
    }

    It "leaves the Resource Name masked" {
        $script:R.Inventory.VirtualMachines[0].Name | Should -Be $script:TokName
    }

    It "leaves tag values masked when Tag is not selected" {
        $script:R.Inventory.VirtualMachines[0].Tags[0].Value | Should -Be $script:TokTag
    }

    It "keeps the tag key verbatim" {
        $script:R.Inventory.VirtualMachines[0].Tags[0].Name | Should -Be 'environment'
    }

    It "leaves the literal 'obfuscated' sentinel untouched" {
        $script:R.Inventory.VirtualMachines[0].Set | Should -Be 'obfuscated'
    }

    It "leaves free-text fields masked when FreeText is not selected" {
        $script:R.Inventory.VirtualMachines[0].Description | Should -Be $script:TokFree
    }

    It "HTML-encodes a revealed value containing special characters in the HTML report" {
        # RealSubName has an '&'; the HTML branch must emit the '&amp;' entity.
        $script:R.Html | Should -Match 'Contoso, Inc\. \(Prod\) &amp; Co'
        $script:R.Html | Should -Not -Match ([regex]::Escape($script:TokSub))
    }

    It "keeps the Consumption CSV columns intact despite a comma in the revealed subscription name" {
        @($script:R.Csv).Count | Should -Be 1
        $script:R.Csv[0].Cost | Should -Be '12.34'
        $script:R.Csv[0].InstanceId | Should -Match ([regex]::Escape($script:RealSubName))
        $script:R.Csv[0].InstanceId | Should -Match ([regex]::Escape($script:RealRgName))
    }
}

Describe "Reveal-Obfuscation with -Fields Tag" {

    BeforeAll { $script:RT = Invoke-Reveal -Fields @('ResourceGroup','Subscription','Tag') }

    It "reveals the tag value when Tag is selected" {
        $script:RT.Inventory.VirtualMachines[0].Tags[0].Value | Should -Be $script:RealTagVal
    }

    It "still leaves the Resource Id masked" {
        $script:RT.Inventory.VirtualMachines[0].ID | Should -Be $script:TokId
    }
}

Describe "Reveal-Obfuscation opt-in ResourceName / ResourceId" {

    It "reveals the resource short name when ResourceName is selected" {
        $r = Invoke-Reveal -Fields @('ResourceName')
        $r.Inventory.VirtualMachines[0].Name | Should -Be 'vm01'
    }

    It "leaves the Resource Id masked when only ResourceName is selected" {
        $r = Invoke-Reveal -Fields @('ResourceName')
        $r.Inventory.VirtualMachines[0].ID | Should -Be $script:TokId
    }

    It "reveals the full ARM resource Id when ResourceId is selected" {
        $r = Invoke-Reveal -Fields @('ResourceId')
        $r.Inventory.VirtualMachines[0].ID | Should -Be "/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/$($script:RealRgName)/providers/Microsoft.Compute/virtualMachines/vm01"
    }

    It "leaves the resource Name masked when only ResourceId is selected" {
        $r = Invoke-Reveal -Fields @('ResourceId')
        $r.Inventory.VirtualMachines[0].Name | Should -Be $script:TokName
    }
}

Describe "Reveal-Obfuscation -All full reveal" {

    BeforeAll { $script:RA = Invoke-Reveal -All }

    It "reveals the resource group name" {
        $script:RA.Inventory.VirtualMachines[0].ResourceGroup | Should -Be $script:RealRgName
    }

    It "reveals the subscription friendly name" {
        $script:RA.Inventory.VirtualMachines[0].Subscription | Should -Be $script:RealSubName
    }

    It "reveals the resource short name" {
        $script:RA.Inventory.VirtualMachines[0].Name | Should -Be 'vm01'
    }

    It "reveals the full ARM resource Id" {
        $script:RA.Inventory.VirtualMachines[0].ID | Should -Be "/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/$($script:RealRgName)/providers/Microsoft.Compute/virtualMachines/vm01"
    }

    It "reveals the tag value" {
        $script:RA.Inventory.VirtualMachines[0].Tags[0].Value | Should -Be $script:RealTagVal
    }

    It "reveals free-text fields" {
        $script:RA.Inventory.VirtualMachines[0].Description | Should -Be $script:RealFreeText
    }

    It "leaves the lossy 'obfuscated' sentinel untouched (not recoverable)" {
        $script:RA.Inventory.VirtualMachines[0].Set | Should -Be 'obfuscated'
    }
}

Describe "Reveal-Obfuscation -Fields FreeText" {

    It "reveals free-text fields when FreeText is selected" {
        $r = Invoke-Reveal -Fields @('FreeText')
        $r.Inventory.VirtualMachines[0].Description | Should -Be $script:RealFreeText
    }

    It "leaves the resource group masked when only FreeText is selected" {
        $r = Invoke-Reveal -Fields @('FreeText')
        $r.Inventory.VirtualMachines[0].ResourceGroup | Should -Be $script:TokRg
    }

    It "is a no-op for free-text when the dictionary has no FreeTextMap" {
        $noFreeDir = Join-Path $script:TmpDir ("nofree_" + [guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $noFreeDir -Force | Out-Null
        $noFreeDict = Join-Path $noFreeDir 'ObfuscationDictionary_NoFree.json'
        [ordered]@{
            GeneratedAt      = '2026-06-30 00:00:00'
            ResourceIdMap    = [ordered]@{ $script:TokId  = "/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm01" }
            ResourceNameMap  = [ordered]@{ $script:TokName = "/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm01" }
            SubscriptionMap  = [ordered]@{ $script:TokSub  = "/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm01" }
            ResourceGroupMap = [ordered]@{ $script:TokRg   = "/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm01" }
        } | ConvertTo-Json -Depth 6 | Set-Content -Path $noFreeDict -Encoding utf8

        # Pair FreeText with a resolvable dimension so the run has something to do;
        # FreeText must be a no-op (Description stays a token) when no FreeTextMap.
        $r = Invoke-Reveal -Fields @('ResourceGroup','FreeText') -DictPath $noFreeDict
        $r.Inventory.VirtualMachines[0].Description | Should -Be $script:TokFree
        $r.Inventory.VirtualMachines[0].ResourceGroup | Should -Be $script:RealRgName
    }
}

Describe "Reveal-Obfuscation older / partial dictionaries" {

    It "falls back to the subscription GUID when the dictionary has no SubscriptionNameMap" {
        # A dictionary written before SubscriptionNameMap existed: the friendly
        # name is unrecoverable, so the subscription reveals to its GUID instead.
        $legacyDir = Join-Path $script:TmpDir ("legacy_" + [guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $legacyDir -Force | Out-Null
        $legacyDict = Join-Path $legacyDir 'ObfuscationDictionary_Legacy.json'
        [ordered]@{
            GeneratedAt      = '2026-06-30 00:00:00'
            ResourceIdMap    = [ordered]@{ $script:TokId  = "/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm01" }
            ResourceNameMap  = [ordered]@{ $script:TokName = "/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm01" }
            SubscriptionMap  = [ordered]@{ $script:TokSub = "/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm01" }
            ResourceGroupMap = [ordered]@{ $script:TokRg  = "/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm01" }
        } | ConvertTo-Json -Depth 6 | Set-Content -Path $legacyDict -Encoding utf8

        $r = Invoke-Reveal -DictPath $legacyDict
        $r.Inventory.VirtualMachines[0].Subscription | Should -Be '12345678-1234-1234-1234-123456789012'
    }

    It "leaves tag values masked when -Fields Tag is requested but the dictionary has no TagMap" {
        $noTagDir = Join-Path $script:TmpDir ("notag_" + [guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $noTagDir -Force | Out-Null
        $noTagDict = Join-Path $noTagDir 'ObfuscationDictionary_NoTag.json'
        [ordered]@{
            GeneratedAt         = '2026-06-30 00:00:00'
            ResourceIdMap       = [ordered]@{ $script:TokId   = "/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm01" }
            ResourceNameMap     = [ordered]@{ $script:TokName = "/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm01" }
            SubscriptionMap     = [ordered]@{ $script:TokSub  = "/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm01" }
            ResourceGroupMap    = [ordered]@{ $script:TokRg   = "/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm01" }
            SubscriptionNameMap = [ordered]@{ $script:TokSub  = $script:RealSubName }
        } | ConvertTo-Json -Depth 6 | Set-Content -Path $noTagDict -Encoding utf8

        $r = Invoke-Reveal -Fields @('ResourceGroup','Subscription','Tag') -DictPath $noTagDict
        $r.Inventory.VirtualMachines[0].Tags[0].Value | Should -Be $script:TokTag
    }
}

Describe "Reveal-Obfuscation dictionary handling and source safety" {

    It "auto-discovers the newest dictionary in -SearchDirectory" {
        $r = Invoke-Reveal -SearchDir $script:TmpDir
        $r.Inventory.VirtualMachines[0].ResourceGroup | Should -Be $script:RealRgName
    }

    It "does not mutate the input zip" {
        $null = Invoke-Reveal
        (Get-FileHash -Path $script:InputZip -Algorithm SHA256).Hash | Should -Be $script:InputZipHashBefore
    }

    It "throws when neither -DictionaryPath nor a discoverable dictionary exists" {
        $emptyDir = Join-Path $script:TmpDir ("empty_" + [guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null
        { & $script:RevealScript -InputZip $script:InputZip -SearchDirectory $emptyDir -OutputZip (Join-Path $emptyDir 'o.zip') } |
            Should -Throw -ExpectedMessage '*ObfuscationDictionary*'
    }
}

# =============================================================================
# FreeText round-trip via FreeTextMap (P3) — fixture-independent
# -----------------------------------------------------------------------------
# Task 5.2 | Requirements 5.2, 5.3 | Property: P3
#
# Closes a coverage gap. The live-dictionary determinism block in
# Obfuscation.Tests.ps1 ("FreeText: each real free-text value maps to exactly
# one token", P1 / Req 5.3) SKIPS whenever the run's FreeTextMap is empty —
# which it is for the current obfuscated fixture — and the reveal FreeText
# tests above exercise only a single token occurrence. These assertions depend
# on neither: they build a self-contained obfuscated bundle whose FreeText
# tokens model a deterministic Protect-FreeTextValue output (a real value seen
# twice yields ONE shared token, a distinct value gets a distinct token) plus a
# matching FreeTextMap, then run the real Reveal-Obfuscation substitution path
# and prove the round-trip:
#   - the tokens are present in the obfuscated ZIP and resolve to real values
#     via FreeTextMap (Req 5.2), each stored value being a real value — not a
#     token, null, or the 'obfuscated' sentinel (lossless intent);
#   - a real value that appears more than once carries a single shared token
#     (Req 5.3) and every occurrence round-trips back to that same real value,
#     i.e. reveal(obfuscate(x)) == x (P3).
# The real->token determinism itself is asserted against a live dictionary by
# the P1 FreeTextMap block in Obfuscation.Tests.ps1; this block is its
# fixture-independent round-trip counterpart and does not duplicate it. No
# customer data: tokens are runtime GUIDs, the only literal GUID is the Azure
# docs placeholder, and the free-text values are synthetic.
# =============================================================================
Describe "Reveal-Obfuscation FreeText round-trip via FreeTextMap (P3)" {

    BeforeAll {
        $subGuid = '12345678-1234-1234-1234-123456789012'   # Azure docs placeholder
        $base = "/subscriptions/$subGuid/resourceGroups/rg-p3/providers/Microsoft.Compute/virtualMachines"

        # Tokens modelling a deterministic obfuscator run: vmA and vmB shared the
        # SAME real free-text value, so Protect-FreeTextValue would have emitted a
        # single shared token for both; vmC had a distinct value -> distinct token.
        $script:P3TokShared = 'prod_'    + [guid]::NewGuid().ToString()
        $script:P3TokOther  = 'nonprod_' + [guid]::NewGuid().ToString()

        $script:P3RealShared = 'created-by: platform-team (owner of record)'
        $script:P3RealOther  = 'runbook: nightly-maintenance, stage=qa'

        # vmA and vmB carry the shared token in a free-text field; vmC the other.
        $script:P3Inventory = [ordered]@{
            VirtualMachines = @(
                [ordered]@{ Name = 'a'; ResourceGroup = 'rg-p3'; CreatedBy = $script:P3TokShared }
                [ordered]@{ Name = 'b'; ResourceGroup = 'rg-p3'; CreatedBy = $script:P3TokShared }
                [ordered]@{ Name = 'c'; ResourceGroup = 'rg-p3'; RoleName  = $script:P3TokOther }
            )
        }

        $vmId = "$base/vm-p3"
        $script:P3Dict = [ordered]@{
            GeneratedAt      = '2026-06-30 00:00:00'
            ResourceIdMap    = [ordered]@{ ('prod_' + [guid]::NewGuid().ToString()) = $vmId }
            ResourceNameMap  = [ordered]@{ ('prod_' + [guid]::NewGuid().ToString()) = $vmId }
            SubscriptionMap  = [ordered]@{ ('prod_' + [guid]::NewGuid().ToString()) = $vmId }
            ResourceGroupMap = [ordered]@{ ('prod_' + [guid]::NewGuid().ToString()) = $vmId }
            FreeTextMap      = [ordered]@{
                $script:P3TokShared = $script:P3RealShared
                $script:P3TokOther  = $script:P3RealOther
            }
        }

        $script:P3Dir = Join-Path ([System.IO.Path]::GetTempPath()) ("RevealP3_" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:P3Dir -Force | Out-Null

        $stageDir = Join-Path $script:P3Dir 'stage'
        New-Item -ItemType Directory -Path $stageDir -Force | Out-Null
        $invPath = Join-Path $stageDir 'Inventory_P3.json'
        $script:P3Inventory | ConvertTo-Json -Depth 8 | Set-Content -Path $invPath -Encoding utf8

        $script:P3InputZip = Join-Path $script:P3Dir 'ResourcesReport_P3.zip'
        Compress-Archive -Path (Join-Path $stageDir '*') -DestinationPath $script:P3InputZip -Force

        $script:P3DictPath = Join-Path $script:P3Dir 'ObfuscationDictionary_P3.json'
        $script:P3Dict | ConvertTo-Json -Depth 6 | Set-Content -Path $script:P3DictPath -Encoding utf8

        # Raw pre-reveal obfuscated inventory (proves the tokens are IN the ZIP).
        $script:P3RawObfuscated = Get-Content -Path $invPath -Raw

        # Run the real reveal substitution path for FreeText only.
        $out = Join-Path $script:P3Dir 'ResourcesReport_P3_revealed.zip'
        & $script:RevealScript -InputZip $script:P3InputZip -DictionaryPath $script:P3DictPath -Fields FreeText -OutputZip $out *>&1 | Out-Null
        $ex = Join-Path $script:P3Dir 'ex'
        Expand-Archive -Path $out -DestinationPath $ex -Force
        $invFile = Get-ChildItem $ex -Filter 'Inventory_*.json' | Select-Object -First 1
        $script:P3Revealed = Get-Content $invFile.FullName -Raw | ConvertFrom-Json

        $script:P3TokenRegex = '^(?:prod|nonprod)_(?:[a-z0-9]+_)?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    }

    AfterAll {
        if ($script:P3Dir -and (Test-Path $script:P3Dir)) {
            Remove-Item -Path $script:P3Dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "the free-text tokens are present in the obfuscated ZIP (pre-reveal)" {
        $script:P3RawObfuscated | Should -Match ([regex]::Escape($script:P3TokShared))
        $script:P3RawObfuscated | Should -Match ([regex]::Escape($script:P3TokOther))
    }

    It "FreeTextMap resolves each token to a real value (not a token, null, or the 'obfuscated' sentinel)" {
        foreach ($tok in @($script:P3TokShared, $script:P3TokOther)) {
            $real = $script:P3Dict.FreeTextMap[$tok]
            $real | Should -Not -BeNullOrEmpty
            $real | Should -Not -Match $script:P3TokenRegex
            $real | Should -Not -Be 'obfuscated'
        }
    }

    It "a real value seen more than once carries a single shared token in the obfuscated ZIP (Req 5.3)" {
        # vmA and vmB shared one real free-text value -> one shared token.
        $script:P3Inventory.VirtualMachines[0].CreatedBy | Should -Be $script:P3Inventory.VirtualMachines[1].CreatedBy
        $script:P3Inventory.VirtualMachines[0].CreatedBy | Should -Be $script:P3TokShared
    }

    It "every occurrence of the shared token round-trips to the same real value (P3)" {
        $script:P3Revealed.VirtualMachines[0].CreatedBy | Should -Be $script:P3RealShared
        $script:P3Revealed.VirtualMachines[1].CreatedBy | Should -Be $script:P3RealShared
        # both came back to the SAME real value from a single shared token
        $script:P3Revealed.VirtualMachines[0].CreatedBy | Should -Be $script:P3Revealed.VirtualMachines[1].CreatedBy
    }

    It "a distinct free-text value round-trips to its own real value (P3)" {
        $script:P3Revealed.VirtualMachines[2].RoleName | Should -Be $script:P3RealOther
    }

    It "no free-text token survives the round-trip reveal" {
        $script:P3Revealed.VirtualMachines[0].CreatedBy | Should -Not -Match $script:P3TokenRegex
        $script:P3Revealed.VirtualMachines[1].CreatedBy | Should -Not -Match $script:P3TokenRegex
        $script:P3Revealed.VirtualMachines[2].RoleName  | Should -Not -Match $script:P3TokenRegex
    }
}

# =============================================================================
# Explicit -Fields subset reveal isolation (P4) — Task 7.2 | Requirements 7.2, 7.3
# -----------------------------------------------------------------------------
# Task 7.1 (the "default fields" Describe near the top) covers the no--Fields
# default (ResourceGroup + Subscription). These blocks close the EXPLICIT-subset
# gap for Property P4 (selective isolation / no bleed): for each single dimension
# named explicitly on its own via -Fields, and for a multi-dimension subset,
# assert the named dimension(s) round-trip to the real value AND every OTHER
# dimension's token is left unchanged (still masked).
#
# The synthetic vm01 (VirtualMachines[0]) built in the top-level BeforeAll carries
# all six revealable dimensions at once (ID, Name, Subscription, ResourceGroup,
# Tags[0].Value, Description), so a single reveal per field set proves both the
# reveal and the no-bleed for the remaining dimensions. Reuses that fixture, its
# $script:Tok*/Real* vars and the Invoke-Reveal helper; no new fixture, no
# customer data (tokens are runtime GUIDs; the only literal GUID is the Azure docs
# placeholder inside the synthetic ARM paths).
#
# Non-duplication: the single-dimension ResourceName, ResourceId and FreeText
# reveals (plus one no-bleed check each) are already asserted by the "opt-in
# ResourceName / ResourceId" and "-Fields FreeText" Describes above, so the
# corresponding contexts here add ONLY the remaining previously-unchecked
# no-bleed dimensions for those three. The ResourceGroup-only, Subscription-only,
# Tag-only single-dimension cases and the two-dimension subset are entirely new.
# =============================================================================
Describe "Reveal-Obfuscation explicit -Fields subset isolation (P4)" {

    Context "single dimension: -Fields ResourceGroup" {

        BeforeAll { $script:P4Rg = Invoke-Reveal -Fields @('ResourceGroup') }

        It "reveals the resource group name" {
            $script:P4Rg.Inventory.VirtualMachines[0].ResourceGroup | Should -Be $script:RealRgName
        }
        It "leaves Subscription masked (no bleed)" {
            $script:P4Rg.Inventory.VirtualMachines[0].Subscription | Should -Be $script:TokSub
        }
        It "leaves Resource Name masked (no bleed)" {
            $script:P4Rg.Inventory.VirtualMachines[0].Name | Should -Be $script:TokName
        }
        It "leaves Resource Id masked (no bleed)" {
            $script:P4Rg.Inventory.VirtualMachines[0].ID | Should -Be $script:TokId
        }
        It "leaves the tag value masked (no bleed)" {
            $script:P4Rg.Inventory.VirtualMachines[0].Tags[0].Value | Should -Be $script:TokTag
        }
        It "leaves free-text masked (no bleed)" {
            $script:P4Rg.Inventory.VirtualMachines[0].Description | Should -Be $script:TokFree
        }
    }

    Context "single dimension: -Fields Subscription" {

        BeforeAll { $script:P4Sub = Invoke-Reveal -Fields @('Subscription') }

        It "reveals the subscription friendly name" {
            $script:P4Sub.Inventory.VirtualMachines[0].Subscription | Should -Be $script:RealSubName
        }
        It "leaves Resource Group masked (no bleed)" {
            $script:P4Sub.Inventory.VirtualMachines[0].ResourceGroup | Should -Be $script:TokRg
        }
        It "leaves Resource Name masked (no bleed)" {
            $script:P4Sub.Inventory.VirtualMachines[0].Name | Should -Be $script:TokName
        }
        It "leaves Resource Id masked (no bleed)" {
            $script:P4Sub.Inventory.VirtualMachines[0].ID | Should -Be $script:TokId
        }
        It "leaves the tag value masked (no bleed)" {
            $script:P4Sub.Inventory.VirtualMachines[0].Tags[0].Value | Should -Be $script:TokTag
        }
        It "leaves free-text masked (no bleed)" {
            $script:P4Sub.Inventory.VirtualMachines[0].Description | Should -Be $script:TokFree
        }
    }

    Context "single dimension: -Fields Tag" {

        BeforeAll { $script:P4Tag = Invoke-Reveal -Fields @('Tag') }

        It "reveals the tag value" {
            $script:P4Tag.Inventory.VirtualMachines[0].Tags[0].Value | Should -Be $script:RealTagVal
        }
        It "keeps the tag key verbatim" {
            $script:P4Tag.Inventory.VirtualMachines[0].Tags[0].Name | Should -Be 'environment'
        }
        It "leaves Resource Group masked (no bleed)" {
            $script:P4Tag.Inventory.VirtualMachines[0].ResourceGroup | Should -Be $script:TokRg
        }
        It "leaves Subscription masked (no bleed)" {
            $script:P4Tag.Inventory.VirtualMachines[0].Subscription | Should -Be $script:TokSub
        }
        It "leaves Resource Name masked (no bleed)" {
            $script:P4Tag.Inventory.VirtualMachines[0].Name | Should -Be $script:TokName
        }
        It "leaves Resource Id masked (no bleed)" {
            $script:P4Tag.Inventory.VirtualMachines[0].ID | Should -Be $script:TokId
        }
        It "leaves free-text masked (no bleed)" {
            $script:P4Tag.Inventory.VirtualMachines[0].Description | Should -Be $script:TokFree
        }
    }

    Context "single dimension: -Fields ResourceName (no-bleed completion)" {
        # The reveal (Name -> 'vm01') and the ID-masked no-bleed check are already
        # asserted by the "opt-in ResourceName / ResourceId" Describe; assert ONLY
        # the remaining previously-unchecked no-bleed dimensions here.
        BeforeAll { $script:P4Name = Invoke-Reveal -Fields @('ResourceName') }

        It "leaves Subscription masked (no bleed)" {
            $script:P4Name.Inventory.VirtualMachines[0].Subscription | Should -Be $script:TokSub
        }
        It "leaves Resource Group masked (no bleed)" {
            $script:P4Name.Inventory.VirtualMachines[0].ResourceGroup | Should -Be $script:TokRg
        }
        It "leaves the tag value masked (no bleed)" {
            $script:P4Name.Inventory.VirtualMachines[0].Tags[0].Value | Should -Be $script:TokTag
        }
        It "leaves free-text masked (no bleed)" {
            $script:P4Name.Inventory.VirtualMachines[0].Description | Should -Be $script:TokFree
        }
    }

    Context "single dimension: -Fields ResourceId (no-bleed completion)" {
        # The reveal (ID -> full ARM path) and the Name-masked no-bleed check are
        # already asserted by the "opt-in ResourceName / ResourceId" Describe;
        # assert ONLY the remaining previously-unchecked no-bleed dimensions here.
        BeforeAll { $script:P4Id = Invoke-Reveal -Fields @('ResourceId') }

        It "leaves Subscription masked (no bleed)" {
            $script:P4Id.Inventory.VirtualMachines[0].Subscription | Should -Be $script:TokSub
        }
        It "leaves the Resource Group token masked (no bleed)" {
            # VM[0].ResourceGroup holds the RG *token*, which is distinct from the
            # RG name embedded inside the revealed ResourceId ARM path.
            $script:P4Id.Inventory.VirtualMachines[0].ResourceGroup | Should -Be $script:TokRg
        }
        It "leaves the tag value masked (no bleed)" {
            $script:P4Id.Inventory.VirtualMachines[0].Tags[0].Value | Should -Be $script:TokTag
        }
        It "leaves free-text masked (no bleed)" {
            $script:P4Id.Inventory.VirtualMachines[0].Description | Should -Be $script:TokFree
        }
    }

    Context "single dimension: -Fields FreeText (no-bleed completion)" {
        # The reveal (Description -> real value) and the RG-masked no-bleed check
        # are already asserted by the "-Fields FreeText" Describe; assert ONLY the
        # remaining previously-unchecked no-bleed dimensions here.
        BeforeAll { $script:P4Free = Invoke-Reveal -Fields @('FreeText') }

        It "leaves Subscription masked (no bleed)" {
            $script:P4Free.Inventory.VirtualMachines[0].Subscription | Should -Be $script:TokSub
        }
        It "leaves Resource Name masked (no bleed)" {
            $script:P4Free.Inventory.VirtualMachines[0].Name | Should -Be $script:TokName
        }
        It "leaves Resource Id masked (no bleed)" {
            $script:P4Free.Inventory.VirtualMachines[0].ID | Should -Be $script:TokId
        }
        It "leaves the tag value masked (no bleed)" {
            $script:P4Free.Inventory.VirtualMachines[0].Tags[0].Value | Should -Be $script:TokTag
        }
    }

    Context "multi-dimension subset: -Fields ResourceGroup,Tag" {

        BeforeAll { $script:P4Multi = Invoke-Reveal -Fields @('ResourceGroup', 'Tag') }

        It "reveals the resource group name (named dimension)" {
            $script:P4Multi.Inventory.VirtualMachines[0].ResourceGroup | Should -Be $script:RealRgName
        }
        It "reveals the tag value (named dimension)" {
            $script:P4Multi.Inventory.VirtualMachines[0].Tags[0].Value | Should -Be $script:RealTagVal
        }
        It "leaves Subscription masked (no bleed)" {
            $script:P4Multi.Inventory.VirtualMachines[0].Subscription | Should -Be $script:TokSub
        }
        It "leaves Resource Name masked (no bleed)" {
            $script:P4Multi.Inventory.VirtualMachines[0].Name | Should -Be $script:TokName
        }
        It "leaves Resource Id masked (no bleed)" {
            $script:P4Multi.Inventory.VirtualMachines[0].ID | Should -Be $script:TokId
        }
        It "leaves free-text masked (no bleed)" {
            $script:P4Multi.Inventory.VirtualMachines[0].Description | Should -Be $script:TokFree
        }
    }
}

# =============================================================================
# Full reveal -All: overrides -Fields + lossy-fields warning
#   Task 8 | Requirements 8.1, 8.3 | Property: P3
# -----------------------------------------------------------------------------
# The "Reveal-Obfuscation -All full reveal" Describe above already asserts that
# -All restores all six dictionary-backed dimensions in one pass (Req 8.1/8.2,
# P3) and leaves the lossy 'obfuscated' sentinel unrecovered (Req 8.3). These
# blocks close the two remaining Req 8 gaps, reusing the top-level synthetic
# fixture (vm01 carries all six revealable dimensions plus an 'obfuscated'
# sentinel) and the Invoke-Reveal helper:
#   - Req 8.1 (override): passing '-All -Fields Subscription' must STILL reveal
#     every dimension, not just Subscription. If -Fields had won, RG / Name / Id
#     / Tag / FreeText would remain tokenized; asserting they are all revealed
#     proves -All clobbered the explicit -Fields value. Invoke-Reveal forwards
#     both switches, so this exercises the real precedence path.
#   - Req 8.3 (warning): on completion under -All the reveal script surfaces a
#     lossy-fields notice (a yellow host line naming values nulled at
#     obfuscation time / stamped 'obfuscated' as unrecoverable). This captures
#     the script's merged output stream (*>&1 - the same capture the rest of
#     this file uses to invoke the script, and the stream Write-Host lands on
#     under PowerShell 7) and asserts the notice is present, then confirms the
#     'obfuscated' sentinel indeed survives unrecovered in that same -All output.
# No production/reveal-logic change - assertions only. No customer data: reuses
# runtime-GUID tokens and the Azure docs placeholder GUID from the fixture.
# =============================================================================
Describe "Reveal-Obfuscation -All overrides -Fields and warns of lossy fields (Req 8.1, 8.3, P3)" {

    Context "-All overrides an explicit -Fields value" {

        BeforeAll { $script:AllOverride = Invoke-Reveal -All -Fields @('Subscription') }

        It "still reveals the resource group name (RG not named in -Fields)" {
            $script:AllOverride.Inventory.VirtualMachines[0].ResourceGroup | Should -Be $script:RealRgName
        }
        It "reveals the subscription friendly name (the one dimension -Fields named)" {
            $script:AllOverride.Inventory.VirtualMachines[0].Subscription | Should -Be $script:RealSubName
        }
        It "still reveals the resource short name (not named in -Fields)" {
            $script:AllOverride.Inventory.VirtualMachines[0].Name | Should -Be 'vm01'
        }
        It "still reveals the full ARM resource Id (not named in -Fields)" {
            $script:AllOverride.Inventory.VirtualMachines[0].ID | Should -Be "/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/$($script:RealRgName)/providers/Microsoft.Compute/virtualMachines/vm01"
        }
        It "still reveals the tag value (not named in -Fields)" {
            $script:AllOverride.Inventory.VirtualMachines[0].Tags[0].Value | Should -Be $script:RealTagVal
        }
        It "still reveals free-text fields (not named in -Fields)" {
            $script:AllOverride.Inventory.VirtualMachines[0].Description | Should -Be $script:RealFreeText
        }
    }

    Context "-All emits the lossy-fields warning" {

        BeforeAll {
            $script:AllWarnOut = Join-Path $script:TmpDir ("allwarn_" + [guid]::NewGuid().ToString('N').Substring(0, 8) + ".zip")
            # Capture the script's merged output stream (*>&1), matching how this
            # file already invokes the reveal script; the lossy-fields notice is
            # surfaced on completion when -All is supplied.
            $script:AllWarnStream = & $script:RevealScript -InputZip $script:InputZip -DictionaryPath $script:DictPath -All -OutputZip $script:AllWarnOut *>&1
            $script:AllWarnText = ($script:AllWarnStream | Out-String)
        }

        It "warns that fields are lossy and remain unrecoverable" {
            $script:AllWarnText | Should -Match 'lossy'
            $script:AllWarnText | Should -Match '(?i)remain'
        }

        It "names the 'obfuscated' sentinel as unrecovered in the warning" {
            $script:AllWarnText | Should -Match 'obfuscated'
        }

        It "leaves the 'obfuscated' sentinel unrecovered in the -All output" {
            $ex = Join-Path $script:TmpDir ("allwarn_ex_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
            Expand-Archive -Path $script:AllWarnOut -DestinationPath $ex -Force
            $invFile = Get-ChildItem $ex -Filter 'Inventory_*.json' | Select-Object -First 1
            $inv = Get-Content $invFile.FullName -Raw | ConvertFrom-Json
            $inv.VirtualMachines[0].Set | Should -Be 'obfuscated'
        }
    }
}

# =============================================================================
# Structural preservation (P5) — Task 9.1 | Requirements 7.4 | Property: P5
# -----------------------------------------------------------------------------
# Reveal-Obfuscation.ps1 preserves structure by extracting the input ZIP
# (Expand-Archive, line 304), rewriting each member IN PLACE under its original
# filename through the format-correct writer (CSV via Export-Csv line 365,
# JSON/HTML via Set-Content line 385 after the escapeMode switch at line 374),
# and re-zipping the same temp tree (Compress-Archive line 397) — so member
# names never change and every member stays valid in its own format.
#
# These assertions close the P5 gap left by the rest of this file: the default
# "produces valid JSON that re-parses" check is incidental (it only inspects the
# Inventory object the helper already parsed), and the CSV/HTML checks above are
# value/escaping (P9) assertions, not structure-parity ones. NONE of them (a)
# compare the revealed ZIP's member SET/filenames to the input ZIP's, (b) assert
# every JSON member re-parses with no error, (c) compare revealed CSV column
# headers to the INPUT's headers, or (d) check the HTML member is well-formed.
# This block adds exactly those four, reusing the top-level synthetic fixture
# (Inventory JSON + Consumption CSV + HTML report members), the Invoke-Reveal
# helper, and the top-level AfterAll (the two extraction dirs live under
# $script:TmpDir, so they are cleaned with it). No production/reveal-logic
# change — assertions only. No customer data: reuses runtime-GUID tokens and the
# Azure docs placeholder GUID from the fixture; revealed values are synthetic.
# =============================================================================
Describe "Reveal-Obfuscation structural preservation (P5, Req 7.4)" {

    BeforeAll {
        # Reveal with the default fields (ResourceGroup + Subscription) into a
        # fresh output zip; then extract BOTH the input and revealed zips
        # independently so member sets and per-member content can be compared
        # without depending on the reveal helper's internal extraction.
        $script:P5Result      = Invoke-Reveal
        $script:P5RevealedZip = $script:P5Result.OutputZip

        $script:P5InExtract  = Join-Path $script:TmpDir ("p5_in_"  + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:P5OutExtract = Join-Path $script:TmpDir ("p5_out_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        Expand-Archive -Path $script:InputZip      -DestinationPath $script:P5InExtract  -Force
        Expand-Archive -Path $script:P5RevealedZip -DestinationPath $script:P5OutExtract -Force

        $script:P5InNames  = @(Get-ChildItem -Path $script:P5InExtract  -Recurse -File | ForEach-Object { $_.Name } | Sort-Object)
        $script:P5OutNames = @(Get-ChildItem -Path $script:P5OutExtract -Recurse -File | ForEach-Object { $_.Name } | Sort-Object)
    }

    It "the revealed ZIP has the same member set/filenames as the input ZIP" {
        # Join to a stable string so the comparison is order-independent (both
        # sides are sorted) and unambiguous for array equality.
        ($script:P5OutNames -join '|') | Should -Be ($script:P5InNames -join '|')
    }

    It "the revealed ZIP has the same member count as the input ZIP" {
        $script:P5OutNames.Count | Should -Be $script:P5InNames.Count
    }

    It "every revealed JSON member re-parses via ConvertFrom-Json without error" {
        $JsonFiles = @(Get-ChildItem -Path $script:P5OutExtract -Recurse -File -Filter '*.json')
        $JsonFiles.Count | Should -BeGreaterThan 0
        foreach ($JsonFile in $JsonFiles)
        {
            { Get-Content -Path $JsonFile.FullName -Raw | ConvertFrom-Json } | Should -Not -Throw
        }
    }

    It "every revealed CSV member re-imports with the same column headers and row count as the input" {
        $OutCsvFiles = @(Get-ChildItem -Path $script:P5OutExtract -Recurse -File -Filter '*.csv')
        $OutCsvFiles.Count | Should -BeGreaterThan 0
        foreach ($OutCsvFile in $OutCsvFiles)
        {
            $InCsvPath = Join-Path $script:P5InExtract $OutCsvFile.Name
            Test-Path -Path $InCsvPath | Should -BeTrue

            $InRows  = @(Import-Csv -Path $InCsvPath)
            $OutRows = @(Import-Csv -Path $OutCsvFile.FullName)

            $InHeaders  = @($InRows[0].PSObject.Properties.Name)
            $OutHeaders = @($OutRows[0].PSObject.Properties.Name)

            ($OutHeaders -join '|') | Should -Be ($InHeaders -join '|')
            $OutRows.Count | Should -Be $InRows.Count
        }
    }

    It "every revealed HTML member is well-formed (loads without error)" {
        $HtmlFiles = @(Get-ChildItem -Path $script:P5OutExtract -Recurse -File | Where-Object { $_.Extension -in '.html', '.htm' })
        $HtmlFiles.Count | Should -BeGreaterThan 0
        foreach ($HtmlFile in $HtmlFiles)
        {
            # Lightweight well-formedness check: the synthetic report member has a
            # single root element with balanced tags and entity-encoded values
            # (the reveal HTML branch emits '&amp;' etc.), so it loads as XML.
            # This proves the revealed member stayed structurally intact rather
            # than being corrupted by a raw substitution.
            $Raw = Get-Content -Path $HtmlFile.FullName -Raw
            { [xml]$Raw } | Should -Not -Throw
        }
    }
}

# =============================================================================
# No-op byte equality (P6) — Task 9.2 | Requirements 9.4 | Property: P6
# -----------------------------------------------------------------------------
# Reveal-Obfuscation.ps1 leaves a member with NO selected tokens byte-for-byte
# unchanged: it re-writes a member only when that member's per-file hit counter
# is greater than zero. CSV members are re-exported only under
# `if ($script:fileHits -gt 0)` (Export-Csv, line 363-366); JSON/HTML/other
# members are re-written only under the same guard (Set-Content, line 383-386).
# A zero-hit member is therefore never opened for write on disk, so it survives
# the extract -> (no change) -> re-zip -> extract round-trip with identical
# bytes.
#
# This closes the P6 gap the rest of this file leaves open. The nearest existing
# checks assert something different:
#   - "does not mutate the input zip" hashes the INPUT zip (input immutability,
#     not an output member being unchanged);
#   - the P5 structural block compares member SET/filenames, JSON re-parse, CSV
#     header/row parity, and HTML well-formedness — none of which is a byte
#     comparison (a re-quoted or re-encoded member can pass all four yet differ
#     byte-for-byte);
#   - the FreeText/Tag "no-op" checks assert a token value is unchanged in the
#     PARSED object, not that the raw member bytes are identical.
#
# Approach: reveal ONLY the Tag dimension against the top-level synthetic
# fixture. The Tag token ($script:TokTag) lives EXCLUSIVELY in the Inventory
# JSON member, so:
#   - Inventory_Test.json       -> has Tag hits  -> rewritten (proves reveal ran)
#   - Consumption_Test.csv      -> zero Tag hits -> must be byte-identical
#   - ResourcesReport_Test.html -> zero Tag hits -> must be byte-identical
# (The CSV/HTML carry only Subscription/ResourceGroup tokens, which are NOT in
# the replacement map when -Fields is Tag, so their hit counters stay zero.)
# Byte equality is proved with a SHA256 hash of each member extracted from the
# input ZIP vs the revealed ZIP. Reuses the top-level fixture, its
# $script:Tok*/Real* vars, and the Invoke-Reveal helper; the two extraction dirs
# live under $script:TmpDir, so the top-level AfterAll cleans them. No
# production/reveal-logic change — assertions only. No customer data: reuses
# runtime-GUID tokens and the Azure docs placeholder GUID from the fixture.
# =============================================================================
Describe "Reveal-Obfuscation no-op byte equality (P6, Req 9.4)" {

    BeforeAll {
        # Reveal ONLY Tag: the tag token is present only in the Inventory JSON,
        # leaving the CSV and HTML members with zero selected-token hits.
        $script:P6Result = Invoke-Reveal -Fields @('Tag')

        $script:P6InExtract  = Join-Path $script:TmpDir ("p6_in_"  + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:P6OutExtract = Join-Path $script:TmpDir ("p6_out_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        Expand-Archive -Path $script:InputZip           -DestinationPath $script:P6InExtract  -Force
        Expand-Archive -Path $script:P6Result.OutputZip -DestinationPath $script:P6OutExtract -Force
    }

    It "reveals the Tag token in the member that DOES contain it (guards against a vacuous no-op)" {
        # If the reveal had done nothing at all, a byte-identical CSV/HTML would
        # prove nothing. Confirm the Tag value was actually revealed in Inventory.
        $script:P6Result.Inventory.VirtualMachines[0].Tags[0].Value | Should -Be $script:RealTagVal
    }

    It "leaves a CSV member with no selected tokens byte-for-byte identical (SHA256)" {
        $InCsv  = Join-Path $script:P6InExtract  'Consumption_Test.csv'
        $OutCsv = Join-Path $script:P6OutExtract 'Consumption_Test.csv'
        Test-Path -Path $InCsv  | Should -BeTrue
        Test-Path -Path $OutCsv | Should -BeTrue
        (Get-FileHash -Path $OutCsv -Algorithm SHA256).Hash | Should -Be (Get-FileHash -Path $InCsv -Algorithm SHA256).Hash
    }

    It "leaves an HTML member with no selected tokens byte-for-byte identical (SHA256)" {
        $InHtml  = Join-Path $script:P6InExtract  'ResourcesReport_Test.html'
        $OutHtml = Join-Path $script:P6OutExtract 'ResourcesReport_Test.html'
        Test-Path -Path $InHtml  | Should -BeTrue
        Test-Path -Path $OutHtml | Should -BeTrue
        (Get-FileHash -Path $OutHtml -Algorithm SHA256).Hash | Should -Be (Get-FileHash -Path $InHtml -Algorithm SHA256).Hash
    }
}

# =============================================================================
# Per-format escaping safety (P9) — Task 10 | Requirements 9.1, 9.2, 9.3
# -----------------------------------------------------------------------------
# Reveal-Obfuscation.ps1 escapes each revealed value to match its destination
# member's format so a real value carrying format-significant characters cannot
# corrupt the file:
#   - .json  -> Get-JsonEscaped (ConvertTo-Json -Compress then strip the
#               wrapping quotes) so the value is a valid JSON string literal
#               (Reveal-Obfuscation.ps1 lines 290-298; invoked at line 327).
#   - .csv   -> per-field raw reveal (Convert-RevealString -EscapeMode 'None',
#               line 359) then re-emit through Export-Csv (line 366), which
#               re-quotes any field containing a comma/quote/newline so columns
#               stay intact.
#   - .html  -> [System.Net.WebUtility]::HtmlEncode (line 328) so '&', '<', '>'
#               and '"' become entities, matching the report's own encoding.
#
# This closes the P9 gap the rest of this file leaves open. The existing
# escaping checks in the "default fields" Describe exercise only a SUBSET of the
# format-significant characters and only two of the three formats:
#   - the HTML check uses $RealSubName ('Contoso, Inc. (Prod) & Co'), so only
#     '&' is exercised for HTML — never '<' or '"';
#   - the CSV check exercises only the embedded comma from the same value —
#     never an embedded quote or newline;
#   - no assertion anywhere feeds a JSON member a value bearing the
#     JSON-significant characters ('"', backslash, newline) and proves the
#     member re-parses to the exact real value.
#
# This block builds a DEDICATED synthetic obfuscated bundle whose single
# revealable (FreeText) value carries ALL of { '"', ',', '&', '<', newline }
# (plus '>'), embeds the SAME token in a JSON member, a CSV member and an HTML
# member, runs the real Reveal-Obfuscation.ps1 FreeText substitution path, and
# asserts per format:
#   - JSON  (Req 9.1): the member re-parses via ConvertFrom-Json AND the revealed
#     field equals the exact real value (proving proper string-literal escaping
#     of the quote/backslash/newline/'<'/'&').
#   - CSV   (Req 9.2): Import-Csv yields the SAME column set, the row count is
#     unchanged, the neighbouring column is untouched (columns did not split on
#     the embedded comma/quote/newline) and the revealed field round-trips to the
#     exact real value.
#   - HTML  (Req 9.3): the member is well-formed ([xml] load) AND the raw member
#     contains the value entity-encoded exactly as [System.Net.WebUtility]::HtmlEncode
#     produces (matching the report's own encoding), with the token consumed.
#
# No production/reveal-logic change — assertions only. No customer data: the
# token is a runtime GUID, the only literal GUID is the Azure docs placeholder
# inside the synthetic ARM paths, and the free-text value is synthetic. The
# dedicated fixture lives under its own temp dir and is removed in AfterAll.
# =============================================================================
Describe "Reveal-Obfuscation per-format escaping safety (P9, Req 9.1/9.2/9.3)" {

    BeforeAll {
        $subGuid = '12345678-1234-1234-1234-123456789012'   # Azure docs placeholder
        $vmId = "/subscriptions/$subGuid/resourceGroups/rg-p9/providers/Microsoft.Compute/virtualMachines/vm-p9"

        # One FreeText token whose real value carries every format-significant
        # character: a double quote, a comma, an ampersand, a less-than (and a
        # greater-than), and an embedded newline. Synthetic, no customer data.
        $script:P9Tok  = 'prod_' + [guid]::NewGuid().ToString()
        $script:P9Real = "owner `"ops`", team A & B <primary>`nsecond line"

        # Independently computed expected encodings (NOT reusing the production
        # code path) so the format assertions verify behaviour, not tautology.
        $script:P9HtmlExpected = [System.Net.WebUtility]::HtmlEncode($script:P9Real)

        # ---- Synthetic obfuscated members: SAME token in JSON, CSV and HTML ----
        $script:P9Inventory = [ordered]@{
            VirtualMachines = @(
                [ordered]@{ Name = 'vm-p9'; ResourceGroup = 'rg-p9'; Description = $script:P9Tok }
            )
        }

        # Two columns: the token-bearing FreeText field plus a neighbour marker.
        # If the embedded comma/quote/newline broke quoting, the marker column
        # would shift/split — so asserting Marker survives proves columns intact.
        $script:P9CsvRows = @(
            [pscustomobject]@{ FreeText = $script:P9Tok; Marker = 'KEEP' }
        )

        $script:P9Dict = [ordered]@{
            GeneratedAt      = '2026-06-30 00:00:00'
            ResourceIdMap    = [ordered]@{ ('prod_' + [guid]::NewGuid().ToString()) = $vmId }
            ResourceNameMap  = [ordered]@{ ('prod_' + [guid]::NewGuid().ToString()) = $vmId }
            SubscriptionMap  = [ordered]@{ ('prod_' + [guid]::NewGuid().ToString()) = $vmId }
            ResourceGroupMap = [ordered]@{ ('prod_' + [guid]::NewGuid().ToString()) = $vmId }
            FreeTextMap      = [ordered]@{ $script:P9Tok = $script:P9Real }
        }

        $script:P9Dir = Join-Path ([System.IO.Path]::GetTempPath()) ("RevealP9_" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:P9Dir -Force | Out-Null

        $stageDir = Join-Path $script:P9Dir 'stage'
        New-Item -ItemType Directory -Path $stageDir -Force | Out-Null
        $script:P9Inventory | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $stageDir 'Inventory_P9.json') -Encoding utf8
        $script:P9CsvRows | Export-Csv -Path (Join-Path $stageDir 'Consumption_P9.csv') -NoTypeInformation -Encoding utf8
        "<html><body><table><tr><td>$($script:P9Tok)</td></tr></table></body></html>" |
            Set-Content -Path (Join-Path $stageDir 'ResourcesReport_P9.html') -Encoding utf8

        $script:P9InputZip = Join-Path $script:P9Dir 'ResourcesReport_P9.zip'
        Compress-Archive -Path (Join-Path $stageDir '*') -DestinationPath $script:P9InputZip -Force

        $script:P9DictPath = Join-Path $script:P9Dir 'ObfuscationDictionary_P9.json'
        $script:P9Dict | ConvertTo-Json -Depth 6 | Set-Content -Path $script:P9DictPath -Encoding utf8

        # Run the real reveal substitution path for FreeText only, then extract.
        $out = Join-Path $script:P9Dir 'ResourcesReport_P9_revealed.zip'
        & $script:RevealScript -InputZip $script:P9InputZip -DictionaryPath $script:P9DictPath -Fields FreeText -OutputZip $out *>&1 | Out-Null

        $script:P9Extract = Join-Path $script:P9Dir 'ex'
        Expand-Archive -Path $out -DestinationPath $script:P9Extract -Force

        $script:P9JsonFile = (Get-ChildItem $script:P9Extract -Filter 'Inventory_*.json'   | Select-Object -First 1).FullName
        $script:P9CsvFile  = (Get-ChildItem $script:P9Extract -Filter 'Consumption_*.csv'   | Select-Object -First 1).FullName
        $script:P9HtmlFile = (Get-ChildItem $script:P9Extract -Filter '*.html'              | Select-Object -First 1).FullName

        $script:P9TokenRegex = '(?:prod|nonprod)_(?:[a-z0-9]+_)?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    }

    AfterAll {
        if ($script:P9Dir -and (Test-Path $script:P9Dir)) {
            Remove-Item -Path $script:P9Dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context "JSON member (Req 9.1: string-literal escaped, stays valid)" {

        It "re-parses via ConvertFrom-Json without error" {
            { Get-Content -Path $script:P9JsonFile -Raw | ConvertFrom-Json } | Should -Not -Throw
        }

        It "round-trips the revealed field to the exact real value (quote/backslash/newline/'<'/'&' escaped)" {
            $Parsed = Get-Content -Path $script:P9JsonFile -Raw | ConvertFrom-Json
            $Parsed.VirtualMachines[0].Description | Should -Be $script:P9Real
        }

        It "leaves no FreeText token behind in the JSON member" {
            $Parsed = Get-Content -Path $script:P9JsonFile -Raw | ConvertFrom-Json
            $Parsed.VirtualMachines[0].Description | Should -Not -Match $script:P9TokenRegex
        }
    }

    Context "CSV member (Req 9.2: re-quoted, columns stay intact)" {

        BeforeAll { $script:P9Csv = @(Import-Csv -Path $script:P9CsvFile) }

        It "preserves the column set exactly" {
            $Headers = @($script:P9Csv[0].PSObject.Properties.Name)
            ($Headers -join '|') | Should -Be 'FreeText|Marker'
        }

        It "preserves the row count (embedded comma/quote/newline did not split rows)" {
            $script:P9Csv.Count | Should -Be 1
        }

        It "leaves the neighbouring column untouched (columns did not bleed)" {
            $script:P9Csv[0].Marker | Should -Be 'KEEP'
        }

        It "round-trips the revealed field to the exact real value" {
            $script:P9Csv[0].FreeText | Should -Be $script:P9Real
        }
    }

    Context "HTML member (Req 9.3: entity-encoded, stays well-formed)" {

        BeforeAll { $script:P9Html = Get-Content -Path $script:P9HtmlFile -Raw }

        It "is well-formed (loads as XML without error)" {
            { [xml]$script:P9Html } | Should -Not -Throw
        }

        It "entity-encodes the revealed value exactly as the report's own encoder does" {
            $script:P9Html | Should -Match ([regex]::Escape($script:P9HtmlExpected))
        }

        It "emits less-than, ampersand and double-quote as entities, not raw markup-significant characters" {
            $script:P9Html | Should -Match '&lt;primary&gt;'
            $script:P9Html | Should -Match 'A &amp; B'
            $script:P9Html | Should -Match '&quot;ops&quot;'
        }

        It "leaves no FreeText token behind in the HTML member" {
            $script:P9Html | Should -Not -Match $script:P9TokenRegex
        }
    }
}

# =============================================================================
# Input / dictionary resolution and failure paths — Task 11
# Requirements 10.1, 10.2, 10.3, 7.6, 12.4
# -----------------------------------------------------------------------------
# Purely-additive coverage for the reveal tool's resolution and failure
# contract. These close gaps left by the existing "dictionary handling and
# source safety" Describe (which asserts single-dictionary auto-discovery,
# input-zip immutability, and the unresolvable-dictionary throw / Req 10.3),
# without duplicating any of them:
#
#   - Req 10.1  auto-discovery picks the NEWEST ObfuscationDictionary_*.json
#               among SEVERAL of differing timestamps under -SearchDirectory
#               (the existing test proves discovery works with a lone file; it
#               does NOT prove "newest wins"). Reveal-Obfuscation.ps1:122-123
#               sorts by LastWriteTime -Descending and takes -First 1.
#   - Req 10.2  a missing input ZIP throws an error that NAMES the file
#               (Reveal-Obfuscation.ps1:115-119).
#   - Req 7.6   a field selection yielding zero token mappings throws
#               "Nothing to reveal" (Reveal-Obfuscation.ps1:277-280) AND emits
#               NO output ZIP (the throw precedes temp-dir creation:299,
#               extraction:304 and Compress-Archive:397).
#   - Req 12.4  the temp extraction dir (Reveal_<guid> under the system temp
#               path, Reveal-Obfuscation.ps1:299) is removed by the finally
#               block (410) on BOTH a successful reveal and a failed one.
#
# All fixtures live under $script:TmpDir so the top-level AfterAll removes them.
# Synthetic values only; the sole literal GUID is the Azure docs placeholder
# inside the synthetic ARM paths, and reveal tokens are runtime GUIDs (reusing
# $script:TokRg from the top-level fixture). No customer data.
# =============================================================================
Describe "Reveal-Obfuscation input/dictionary resolution and failure paths (Task 11)" {

    Context "auto-discovery picks the newest dictionary (Req 10.1)" {

        BeforeAll {
            $Base = '/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups'   # Azure docs placeholder

            $script:NewestDir = Join-Path $script:TmpDir ("newest_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Path $script:NewestDir -Force | Out-Null

            # Two discoverable dictionaries mapping the SAME token to DIFFERENT
            # resource-group names. The newer one carries the distinctive winning
            # value; if the tool wrongly picked the older it would reveal the
            # loser instead.
            $StaleDict = Join-Path $script:NewestDir 'ObfuscationDictionary_Stale.json'
            [ordered]@{
                GeneratedAt      = '2026-06-01 00:00:00'
                ResourceGroupMap = [ordered]@{ $script:TokRg = "$Base/rg-stale-loser/providers/Microsoft.Compute/virtualMachines/vm01" }
            } | ConvertTo-Json -Depth 6 | Set-Content -Path $StaleDict -Encoding utf8

            $FreshDict = Join-Path $script:NewestDir 'ObfuscationDictionary_Fresh.json'
            [ordered]@{
                GeneratedAt      = '2026-06-30 00:00:00'
                ResourceGroupMap = [ordered]@{ $script:TokRg = "$Base/rg-fresh-winner/providers/Microsoft.Compute/virtualMachines/vm01" }
            } | ConvertTo-Json -Depth 6 | Set-Content -Path $FreshDict -Encoding utf8

            # Make the timestamp ordering explicit and deterministic.
            (Get-Item $StaleDict).LastWriteTime = (Get-Date).AddMinutes(-30)
            (Get-Item $FreshDict).LastWriteTime = (Get-Date)

            $script:Newest = Invoke-Reveal -Fields @('ResourceGroup') -SearchDir $script:NewestDir
        }

        It "reveals the resource group from the NEWEST dictionary" {
            $script:Newest.Inventory.VirtualMachines[0].ResourceGroup | Should -Be 'rg-fresh-winner'
        }

        It "does not use the older dictionary's mapping" {
            $script:Newest.Inventory.VirtualMachines[0].ResourceGroup | Should -Not -Be 'rg-stale-loser'
        }
    }

    Context "missing input ZIP (Req 10.2)" {

        It "throws an error that names the missing input file" {
            $MissingZip = Join-Path $script:TmpDir 'no-such-report_doesnotexist.zip'
            $Err = { & $script:RevealScript -InputZip $MissingZip -DictionaryPath $script:DictPath -OutputZip (Join-Path $script:TmpDir 'unused.zip') } |
                Should -Throw -PassThru
            $Err.Exception.Message | Should -BeLike '*Input zip not found*'
            $Err.Exception.Message | Should -BeLike '*no-such-report_doesnotexist.zip*'
        }
    }

    Context "zero-mapping field selection (Req 7.6)" {

        BeforeAll {
            # Core-maps-only dictionary (no TagMap), so selecting ONLY Tag yields
            # zero token mappings and the tool must fail rather than emit a ZIP.
            $script:ZeroDir = Join-Path $script:TmpDir ("zeromap_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Path $script:ZeroDir -Force | Out-Null
            $script:ZeroDict = Join-Path $script:ZeroDir 'ObfuscationDictionary_NoTag.json'
            [ordered]@{
                GeneratedAt      = '2026-06-30 00:00:00'
                ResourceGroupMap = [ordered]@{ $script:TokRg = "/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm01" }
            } | ConvertTo-Json -Depth 6 | Set-Content -Path $script:ZeroDict -Encoding utf8
        }

        It "throws 'Nothing to reveal' and emits no output ZIP" {
            $Out = Join-Path $script:ZeroDir 'should-never-be-written.zip'
            { & $script:RevealScript -InputZip $script:InputZip -DictionaryPath $script:ZeroDict -Fields Tag -OutputZip $Out } |
                Should -Throw -ExpectedMessage '*Nothing to reveal*'
            Test-Path -Path $Out | Should -BeFalse
        }
    }

    Context "temp extraction dir cleanup (Req 12.4)" {

        BeforeAll { $script:SysTemp = [System.IO.Path]::GetTempPath() }

        It "leaves no Reveal_* temp dir behind after a successful reveal" {
            $Before = @(Get-ChildItem -Path $script:SysTemp -Directory -Filter 'Reveal_*' -ErrorAction SilentlyContinue | ForEach-Object Name)
            $null = Invoke-Reveal
            $After = @(Get-ChildItem -Path $script:SysTemp -Directory -Filter 'Reveal_*' -ErrorAction SilentlyContinue | ForEach-Object Name)
            @($After | Where-Object { $_ -notin $Before }) | Should -BeNullOrEmpty
        }

        It "leaves no Reveal_* temp dir behind after a failed reveal (post-extraction failure)" {
            # A file that exists (so the input-zip guard passes) but is not a real
            # archive, so Expand-Archive fails INSIDE the try block, exercising the
            # finally cleanup on the failure path.
            $CorruptZip = Join-Path $script:TmpDir ("corrupt_" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.zip')
            Set-Content -Path $CorruptZip -Value 'this is not a zip archive' -Encoding utf8

            $Before = @(Get-ChildItem -Path $script:SysTemp -Directory -Filter 'Reveal_*' -ErrorAction SilentlyContinue | ForEach-Object Name)
            { & $script:RevealScript -InputZip $CorruptZip -DictionaryPath $script:DictPath -OutputZip (Join-Path $script:TmpDir 'corrupt_out.zip') } |
                Should -Throw
            $After = @(Get-ChildItem -Path $script:SysTemp -Directory -Filter 'Reveal_*' -ErrorAction SilentlyContinue | ForEach-Object Name)
            @($After | Where-Object { $_ -notin $Before }) | Should -BeNullOrEmpty
        }
    }
}

# =============================================================================
# Backward compatibility with older / partial dictionaries — Task 12
# Requirements 11.1, 11.2, 11.3
# -----------------------------------------------------------------------------
# Purely-additive coverage for graceful degradation against older-shaped
# dictionaries. Reveal-Obfuscation.ps1 confirms the contract:
#   - Req 11.1  Subscription reveal prefers SubscriptionNameMap; when a token
#               has no friendly name it falls back to the /subscriptions/<guid>
#               GUID (Reveal-Obfuscation.ps1:219-221) and, once the pass
#               completes, emits a Write-Warning naming the missing
#               SubscriptionNameMap (272-274).
#   - Req 11.2  -Fields Tag against a dictionary with no TagMap emits a
#               Write-Warning and skips Tag (empty TagMap loop adds nothing,
#               229-235) WITHOUT throwing - the run still succeeds for the other
#               selected dimensions. (Tag alone would hit the "Nothing to
#               reveal" throw at 277-280, so it is asserted alongside a
#               resolvable dimension, matching the tool's real behavior.)
#   - Req 11.3  with the four core maps present but the optional maps
#               (SubscriptionNameMap / TagMap / FreeTextMap) absent, the tool
#               proceeds and reverses the dimensions it can - ResourceGroup
#               (196-203) and ResourceId (234-241) still resolve off the core
#               maps.
#
# Non-duplication: the existing "older / partial dictionaries" Describe already
# asserts (a) Subscription falls back to the GUID (Req 11.1 value) and (b) tag
# values stay masked with no TagMap (Req 11.2 skip). This block adds ONLY the
# previously-unasserted pieces: the Req 11.1 WARNING, the Req 11.2 WARNING plus
# an explicit does-NOT-throw, and the Req 11.3 proceed-with-reversible-dimensions
# assertions (ResourceGroup + ResourceId revealed from a core-maps-only dict).
#
# Warnings are captured off the script's warning stream (3>&1, filtered to
# WarningRecord); Write-Host status lines land on the information stream and are
# not captured. Value assertions reuse the top-level Invoke-Reveal helper. All
# synthetic older-shaped dictionaries are built here (not read from the real
# fixture) and live under $script:TmpDir, so the top-level AfterAll removes them.
# Synthetic values only: reveal tokens are runtime GUIDs reused from the
# top-level fixture ($script:TokSub / $script:TokRg / $script:TokId /
# $script:TokName / $script:TokTag), and the only literal GUID is the Azure docs
# placeholder inside the synthetic ARM paths. No customer data.
# =============================================================================
Describe "Reveal-Obfuscation backward compatibility with older dictionaries (Req 11.1, 11.2, 11.3)" {

    BeforeAll {
        $BcBase = '/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups'   # Azure docs placeholder
        $script:BcVmId = "$BcBase/$($script:RealRgName)/providers/Microsoft.Compute/virtualMachines/vm01"

        # Capture ONLY the warning stream (3>&1); Write-Host status lines are on
        # the information stream and are intentionally excluded.
        function Get-RevealWarning
        {
            param([string]$DictPath, [string[]]$Fields)
            $Out = Join-Path $script:TmpDir ("bcwarn_" + [guid]::NewGuid().ToString('N').Substring(0, 8) + ".zip")
            $Streamed = & $script:RevealScript -InputZip $script:InputZip -DictionaryPath $DictPath -Fields $Fields -OutputZip $Out 3>&1
            return @($Streamed | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
        }

        # ---- Older-shaped dictionary: NO SubscriptionNameMap (predates it) ----
        $script:BcLegacyDir = Join-Path $script:TmpDir ("bc_legacy_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:BcLegacyDir -Force | Out-Null
        $script:BcLegacyDict = Join-Path $script:BcLegacyDir 'ObfuscationDictionary_LegacyNoSubName.json'
        [ordered]@{
            GeneratedAt      = '2026-06-30 00:00:00'
            ResourceIdMap    = [ordered]@{ $script:TokId   = $script:BcVmId }
            ResourceNameMap  = [ordered]@{ $script:TokName = $script:BcVmId }
            SubscriptionMap  = [ordered]@{ $script:TokSub  = $script:BcVmId }
            ResourceGroupMap = [ordered]@{ $script:TokRg   = $script:BcVmId }
        } | ConvertTo-Json -Depth 6 | Set-Content -Path $script:BcLegacyDict -Encoding utf8

        # ---- Older-shaped dictionary: NO TagMap (tags not obfuscated) ----
        # Keeps SubscriptionNameMap so the Tag-skip warning is asserted in
        # isolation (no subscription-fallback warning noise).
        $script:BcNoTagDir = Join-Path $script:TmpDir ("bc_notag_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:BcNoTagDir -Force | Out-Null
        $script:BcNoTagDict = Join-Path $script:BcNoTagDir 'ObfuscationDictionary_NoTag.json'
        [ordered]@{
            GeneratedAt         = '2026-06-30 00:00:00'
            ResourceIdMap       = [ordered]@{ $script:TokId   = $script:BcVmId }
            ResourceNameMap     = [ordered]@{ $script:TokName = $script:BcVmId }
            SubscriptionMap     = [ordered]@{ $script:TokSub  = $script:BcVmId }
            ResourceGroupMap    = [ordered]@{ $script:TokRg   = $script:BcVmId }
            SubscriptionNameMap = [ordered]@{ $script:TokSub  = $script:RealSubName }
        } | ConvertTo-Json -Depth 6 | Set-Content -Path $script:BcNoTagDict -Encoding utf8

        # ---- Older-shaped dictionary: core maps ONLY, all optional maps absent ----
        $script:BcCoreOnlyDir = Join-Path $script:TmpDir ("bc_coreonly_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:BcCoreOnlyDir -Force | Out-Null
        $script:BcCoreOnlyDict = Join-Path $script:BcCoreOnlyDir 'ObfuscationDictionary_CoreOnly.json'
        [ordered]@{
            GeneratedAt      = '2026-06-30 00:00:00'
            ResourceIdMap    = [ordered]@{ $script:TokId   = $script:BcVmId }
            ResourceNameMap  = [ordered]@{ $script:TokName = $script:BcVmId }
            SubscriptionMap  = [ordered]@{ $script:TokSub  = $script:BcVmId }
            ResourceGroupMap = [ordered]@{ $script:TokRg   = $script:BcVmId }
        } | ConvertTo-Json -Depth 6 | Set-Content -Path $script:BcCoreOnlyDict -Encoding utf8
    }

    Context "SubscriptionNameMap absent -> GUID fallback + warning (Req 11.1)" {

        It "reveals the subscription GUID (not a friendly name) from an older dictionary" {
            $R = Invoke-Reveal -Fields @('Subscription') -DictPath $script:BcLegacyDict
            $R.Inventory.VirtualMachines[0].Subscription | Should -Be '12345678-1234-1234-1234-123456789012'
        }

        It "emits a warning about falling back to the subscription GUID / missing SubscriptionNameMap" {
            $Warnings = Get-RevealWarning -DictPath $script:BcLegacyDict -Fields @('Subscription')
            ($Warnings -join "`n") | Should -Match '(?i)SubscriptionNameMap'
            ($Warnings -join "`n") | Should -Match '(?i)GUID'
        }
    }

    Context "TagMap absent + -Fields Tag -> skip with warning, no failure (Req 11.2)" {

        It "does not throw when Tag is requested alongside a resolvable dimension but TagMap is absent" {
            $Out = Join-Path $script:TmpDir ("bc_notag_nothrow_" + [guid]::NewGuid().ToString('N').Substring(0, 8) + ".zip")
            { & $script:RevealScript -InputZip $script:InputZip -DictionaryPath $script:BcNoTagDict -Fields ResourceGroup, Subscription, Tag -OutputZip $Out *>&1 | Out-Null } |
                Should -Not -Throw
        }

        It "emits a warning that Tag is skipped because the dictionary has no TagMap" {
            $Warnings = Get-RevealWarning -DictPath $script:BcNoTagDict -Fields @('ResourceGroup', 'Subscription', 'Tag')
            ($Warnings -join "`n") | Should -Match '(?i)TagMap'
            ($Warnings -join "`n") | Should -Match '(?i)Skipping Tag'
        }

        It "leaves the tag value masked while still revealing the resolvable dimensions" {
            $R = Invoke-Reveal -Fields @('ResourceGroup', 'Subscription', 'Tag') -DictPath $script:BcNoTagDict
            $R.Inventory.VirtualMachines[0].Tags[0].Value | Should -Be $script:TokTag
            $R.Inventory.VirtualMachines[0].ResourceGroup | Should -Be $script:RealRgName
            $R.Inventory.VirtualMachines[0].Subscription  | Should -Be $script:RealSubName
        }
    }

    Context "core maps present, optional maps absent -> proceed with reversible dimensions (Req 11.3)" {

        It "still reveals ResourceGroup from a core-maps-only dictionary" {
            $R = Invoke-Reveal -Fields @('ResourceGroup') -DictPath $script:BcCoreOnlyDict
            $R.Inventory.VirtualMachines[0].ResourceGroup | Should -Be $script:RealRgName
        }

        It "still reveals ResourceId from a core-maps-only dictionary" {
            $R = Invoke-Reveal -Fields @('ResourceId') -DictPath $script:BcCoreOnlyDict
            $R.Inventory.VirtualMachines[0].ID | Should -Be $script:BcVmId
        }

        It "reveals ResourceGroup + ResourceId together without requiring the optional maps" {
            $R = Invoke-Reveal -Fields @('ResourceGroup', 'ResourceId') -DictPath $script:BcCoreOnlyDict
            $R.Inventory.VirtualMachines[0].ResourceGroup | Should -Be $script:RealRgName
            $R.Inventory.VirtualMachines[0].ID | Should -Be $script:BcVmId
        }
    }
}
