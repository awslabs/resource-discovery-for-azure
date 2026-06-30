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
    $script:RevealScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'Reveal-Obfuscation.ps1'
    if (-not (Test-Path $script:RevealScript)) {
        throw "Reveal-Obfuscation.ps1 not found at $script:RevealScript"
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
