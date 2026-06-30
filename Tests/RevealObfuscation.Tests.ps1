# Reveal-Obfuscation.ps1 unit tests
# =============================================================================
# Offline, self-contained tests for the partial-reveal helper. They build a
# synthetic obfuscated report bundle (Inventory JSON + Consumption CSV) and a
# matching ObfuscationDictionary fixture in a temp dir, zip it like an
# -Obfuscate run would, then run Reveal-Obfuscation.ps1 against it and assert:
#   - selected dimensions (Resource Group, Subscription name) are revealed
#   - UNSELECTED dimensions (Resource Id, Resource Name, and tag values unless
#     -Fields Tag is passed) stay masked
#   - the rewritten members are still valid (JSON parses, CSV columns intact
#     even when a revealed value contains a comma)
#   - the source zip is never mutated
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
    $script:TokId   = 'prod_'    + [guid]::NewGuid().ToString()
    $script:TokName = 'prod_'    + [guid]::NewGuid().ToString()
    $script:TokSub  = 'prod_'    + [guid]::NewGuid().ToString()
    $script:TokRg   = 'nonprod_' + [guid]::NewGuid().ToString()
    $script:TokTag  = 'prod_'    + [guid]::NewGuid().ToString()

    # Real values behind the tokens. Subscription name deliberately contains a
    # comma and an ampersand to exercise CSV quoting and HTML encoding.
    $script:RealRgName  = 'rg-app'
    $script:RealSubName = 'Contoso, Inc. (Prod) & Co'
    $script:RealTagVal  = 'payments'

    $idVm = "$base/$($script:RealRgName)/providers/Microsoft.Compute/virtualMachines/vm01"

    # ---- Dictionary fixture ----
    $dict = [ordered]@{
        GeneratedAt         = '2026-06-30 00:00:00'
        ResourceIdMap       = [ordered]@{ $script:TokId   = $idVm }
        ResourceNameMap     = [ordered]@{ $script:TokName = $idVm }
        SubscriptionMap     = [ordered]@{ $script:TokSub  = $idVm }
        ResourceGroupMap    = [ordered]@{ $script:TokRg   = $idVm }
        SubscriptionNameMap = [ordered]@{ $script:TokSub  = $script:RealSubName }
        TagMap              = [ordered]@{ $script:TokTag  = $script:RealTagVal }
    }

    # ---- Synthetic obfuscated report members ----
    $inventory = [ordered]@{
        VirtualMachines = @(
            [ordered]@{
                ID            = $script:TokId
                Name          = $script:TokName
                Subscription  = $script:TokSub
                ResourceGroup = $script:TokRg
                Tags          = @( [ordered]@{ Name = 'environment'; Value = $script:TokTag } )
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

    $script:InputZip = Join-Path $script:TmpDir 'ResourcesReport_Test.zip'
    Compress-Archive -Path (Join-Path $stageDir '*') -DestinationPath $script:InputZip -Force
    $script:InputZipHashBefore = (Get-FileHash -Path $script:InputZip -Algorithm SHA256).Hash

    $script:DictPath = Join-Path $script:TmpDir 'ObfuscationDictionary_Test.json'
    $dict | ConvertTo-Json -Depth 6 | Set-Content -Path $script:DictPath -Encoding utf8

    # Helper: run reveal into a fresh output zip, extract, return parsed members.
    function Invoke-Reveal {
        param([string[]]$Fields)
        $out = Join-Path $script:TmpDir ("out_" + [guid]::NewGuid().ToString('N').Substring(0,8) + ".zip")
        $splat = @{ InputZip = $script:InputZip; DictionaryPath = $script:DictPath; OutputZip = $out }
        if ($Fields) { $splat['Fields'] = $Fields }
        & $script:RevealScript @splat *>&1 | Out-Null
        $ex = Join-Path $script:TmpDir ("ex_" + [guid]::NewGuid().ToString('N').Substring(0,8))
        Expand-Archive -Path $out -DestinationPath $ex -Force
        $invFile = Get-ChildItem $ex -Filter 'Inventory_*.json' | Select-Object -First 1
        $csvFile = Get-ChildItem $ex -Filter 'Consumption_*.csv' | Select-Object -First 1
        return [pscustomobject]@{
            OutputZip = $out
            Inventory = (Get-Content $invFile.FullName -Raw | ConvertFrom-Json)
            Csv       = @(Import-Csv -Path $csvFile.FullName)
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
        @($script:R.Inventory.VirtualMachines).Count | Should -Be 1
    }

    It "reveals the resource group name" {
        $script:R.Inventory.VirtualMachines[0].ResourceGroup | Should -Be $script:RealRgName
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

Describe "Reveal-Obfuscation source safety" {

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
