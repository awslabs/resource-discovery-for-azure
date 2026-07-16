# Merge-RecoveryData unit tests
# =============================================================================
# Offline, self-contained tests for the recovery-merge splice + re-package
# helper in Functions/RecoveryMerge.Functions.ps1. Each test builds a synthetic
# "gap" bundle (the incomplete run) and a "recovery" bundle (the scoped re-run)
# in a temp dir - Inventory_*.json plus optional Consumption_*.csv,
# Metrics_*.json and ObfuscationDictionary_*.json - then calls Merge-RecoveryData
# and asserts the splice, the packaging, and the fail-loud guards.
#
# No live Azure and no external fixture zip: the function only reads/writes files
# and re-invokes Extension/Summary.ps1 to regenerate the HTML, so a temp bundle
# is enough to drive it end to end. The only literal GUID used in synthetic ARM
# paths is the Azure docs placeholder (12345678-...-123456789012); obfuscation
# tokens are minted at runtime. No customer data.
# =============================================================================

BeforeAll {
    $script:FnFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/RecoveryMerge.Functions.ps1'
    if (-not (Test-Path -Path $script:FnFile))
    {
        throw "RecoveryMerge.Functions.ps1 not found at $script:FnFile"
    }
    . $script:FnFile
    if (-not (Get-Command -Name 'Merge-RecoveryData' -ErrorAction SilentlyContinue))
    {
        throw 'Merge-RecoveryData was not defined after dot-sourcing RecoveryMerge.Functions.ps1'
    }

    $script:TmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('RecoveryMergeTest_' + [guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $script:TmpRoot -Force | Out-Null

    # Canonical empty-consumption header the function writes when no CSV exists.
    $script:CsvHeader = 'InstanceData,MeterCategory,MeterId,MeterName,MeterRegion,MeterSubCategory,Quantity,Unit,UsageStartTime,UsageEndTime,ResourceId,ResourceLocation,ConsumptionMeter,ReservationId,ReservationOrderId'
    $script:DocsGuid = '12345678-1234-1234-1234-123456789012'

    # Fresh, isolated gap/recovery/output folders per test case.
    function New-Case
    {
        $Id = [guid]::NewGuid().ToString('N').Substring(0, 8)
        [pscustomobject]@{
            Gap      = Join-Path $script:TmpRoot ("gap_$Id")
            Recovery = Join-Path $script:TmpRoot ("rec_$Id")
            Output   = Join-Path $script:TmpRoot ("out_$Id")
        }
    }

    # One synthetic resource record with the common fields Summary.ps1 samples.
    function New-Record([string]$Name, [string]$Rg = 'rg-app')
    {
        [ordered]@{
            Name          = $Name
            Subscription  = 'prod_sub'
            Location      = 'eastus'
            ResourceGroup = $Rg
            ID            = ('/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Compute/virtualMachines/{2}' -f $script:DocsGuid, $Rg, $Name)
        }
    }

    # Write a bundle folder. Inventory is a hashtable of service-name -> record[].
    function New-Bundle
    {
        param(
            [Parameter(Mandatory)][string]$Dir,
            [Parameter(Mandatory)][string]$Base,
            $Inventory,
            [string]$ConsumptionCsv,
            [hashtable]$MetricsFiles,
            $Dictionary
        )
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        if ($null -ne $Inventory)
        {
            ($Inventory | ConvertTo-Json -Depth 100) | Out-File -FilePath (Join-Path $Dir ('Inventory_{0}.json' -f $Base)) -Encoding utf8
        }
        if ($PSBoundParameters.ContainsKey('ConsumptionCsv') -and $null -ne $ConsumptionCsv)
        {
            $ConsumptionCsv | Out-File -FilePath (Join-Path $Dir ('Consumption_{0}.csv' -f $Base)) -Encoding utf8
        }
        if ($null -ne $MetricsFiles)
        {
            foreach ($Suffix in $MetricsFiles.Keys)
            {
                $MetricsFiles[$Suffix] | Out-File -FilePath (Join-Path $Dir ('Metrics_{0}{1}.json' -f $Base, $Suffix)) -Encoding utf8
            }
        }
        if ($null -ne $Dictionary)
        {
            ($Dictionary | ConvertTo-Json -Depth 10) | Out-File -FilePath (Join-Path $Dir ('ObfuscationDictionary_{0}.json' -f $Base)) -Encoding utf8
        }
    }

    # Expand a produced zip and return the entry file names.
    function Get-ZipEntryNames([string]$ZipPath)
    {
        $Dest = Join-Path $script:TmpRoot ('unzip_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        Expand-Archive -Path $ZipPath -DestinationPath $Dest -Force
        @(Get-ChildItem -Path $Dest -File | Select-Object -ExpandProperty Name)
    }

    $script:GapBase = 'GapReport_20260101_000000'
    $script:RecBase = 'RecReport_20260102_000000'
}

AfterAll {
    if ($script:TmpRoot -and (Test-Path -Path $script:TmpRoot))
    {
        Remove-Item -Path $script:TmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Merge-RecoveryData inventory splice' {

    It 'adds a missing service key from the recovery bundle (default = all keys)' {
        $C = New-Case
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{
                Version         = '3.2.3'
                VirtualMachines = @((New-Record 'vm01'))
            })
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{
                Version     = '3.2.3'
                AppServices = @((New-Record 'app01'))
            })

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output

        $Merged = Get-Content -Path $Result.OutputInventory -Raw | ConvertFrom-Json
        $Merged.PSObject.Properties.Name | Should -Contain 'VirtualMachines' -Because 'the gap inventory key must be preserved'
        $Merged.PSObject.Properties.Name | Should -Contain 'AppServices' -Because 'the recovered key must be spliced in'
        @($Merged.AppServices).Count | Should -Be 1
    }

    It 'replaces an existing service key when the recovery bundle provides the same key' {
        $C = New-Case
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{
                Version         = '3.2.3'
                VirtualMachines = @((New-Record 'vm-old'))
            })
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{
                Version         = '3.2.3'
                VirtualMachines = @((New-Record 'vm-new-a'), (New-Record 'vm-new-b'))
            })

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output

        $Merged = Get-Content -Path $Result.OutputInventory -Raw | ConvertFrom-Json
        @($Merged.VirtualMachines).Count | Should -Be 2 -Because 'the recovery key replaces the gap key, not appends to it'
        @($Merged.VirtualMachines.Name) | Should -Not -Contain 'vm-old'
    }

    It 'returns MergedServiceKeys listing exactly what was spliced' {
        $C = New-Case
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) })
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')); StorageAcc = @((New-Record 'sa01')) })

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output

        @($Result.MergedServiceKeys) | Should -Contain 'AppServices'
        @($Result.MergedServiceKeys) | Should -Contain 'StorageAcc'
        @($Result.MergedServiceKeys) | Should -Not -Contain 'Version' -Because 'the Version marker is not a service key'
    }

    It 'names inventory, html and zip outputs from the gap bundle base' {
        $C = New-Case
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) })
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) })

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output

        $Result.BundleBase | Should -Be $script:GapBase
        (Split-Path $Result.OutputInventory -Leaf) | Should -Be ('Inventory_{0}.json' -f $script:GapBase)
        (Split-Path $Result.OutputHtml -Leaf) | Should -Be ('{0}.html' -f $script:GapBase)
        Test-Path -Path $Result.OutputZip | Should -BeTrue
        Test-Path -Path $Result.OutputHtml | Should -BeTrue
    }
}

Describe 'Merge-RecoveryData -Service selection and fail-loud guards' {

    It 'splices only the named service when -Service is an explicit subset' {
        $C = New-Case
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) })
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')); StorageAcc = @((New-Record 'sa01')) })

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -Service 'AppServices'

        @($Result.MergedServiceKeys) | Should -Be @('AppServices')
        $Merged = Get-Content -Path $Result.OutputInventory -Raw | ConvertFrom-Json
        $Merged.PSObject.Properties.Name | Should -Contain 'AppServices'
        $Merged.PSObject.Properties.Name | Should -Not -Contain 'StorageAcc' -Because 'a service not named in -Service must not be spliced'
    }

    It 'throws when a named -Service is absent from the recovery inventory (partial miss)' {
        $C = New-Case
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) })
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) })

        { Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -Service 'AppServices', 'Missing' } |
            Should -Throw -ExpectedMessage '*not found in the recovery inventory*'
    }

    It 'throws when the recovery inventory has no service keys and no recover switch is set' {
        $C = New-Case
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) })
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3' })

        { Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output } |
            Should -Throw -ExpectedMessage '*nothing to merge*'
    }
}

Describe 'Merge-RecoveryData consumption handling' {

    It 'carries the gap consumption CSV forward by default (ConsumptionSource = gap)' {
        $C = New-Case
        $GapCsv = "$script:CsvHeader`n{},Compute,m1,GAP-METER,eastus,vm,1,Hours,2026-01-01,2026-01-02,/id,eastus,,,"
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -ConsumptionCsv $GapCsv
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) })

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output

        $Result.ConsumptionSource | Should -Be 'gap'
        $OutCsv = Join-Path $C.Output ('Consumption_{0}.csv' -f $script:GapBase)
        (Get-Content -Path $OutCsv -Raw) | Should -Match 'GAP-METER'
    }

    It 'replaces consumption with the recovery CSV under -RecoverConsumption (ConsumptionSource = recovery)' {
        $C = New-Case
        $GapCsv = "$script:CsvHeader`n{},Compute,m1,GAP-METER,eastus,vm,1,Hours,2026-01-01,2026-01-02,/id,eastus,,,"
        $RecCsv = "$script:CsvHeader`n{},Compute,m1,REC-METER,eastus,vm,9,Hours,2026-01-01,2026-01-02,/id,eastus,,,"
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -ConsumptionCsv $GapCsv
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -ConsumptionCsv $RecCsv

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -RecoverConsumption

        $Result.ConsumptionSource | Should -Be 'recovery'
        $OutCsv = Join-Path $C.Output ('Consumption_{0}.csv' -f $script:GapBase)
        (Get-Content -Path $OutCsv -Raw) | Should -Match 'REC-METER'
        (Get-Content -Path $OutCsv -Raw) | Should -Not -Match 'GAP-METER'
    }

    It 'throws when -RecoverConsumption is set but the recovery bundle has no CSV' {
        $C = New-Case
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) })
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) })

        { Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -RecoverConsumption } |
            Should -Throw -ExpectedMessage '*has no Consumption_*'
    }

    It 'writes a canonical header-only CSV when neither bundle has consumption' {
        $C = New-Case
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) })
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) })

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output

        $OutCsv = Join-Path $C.Output ('Consumption_{0}.csv' -f $script:GapBase)
        Test-Path -Path $OutCsv | Should -BeTrue
        (Get-Content -Path $OutCsv -Raw).Trim() | Should -Be $script:CsvHeader -Because 'a bundle with no consumption still gets a structurally complete header-only CSV'
    }
}

Describe 'Merge-RecoveryData metrics handling' {

    It 'carries gap metrics forward verbatim by default (MetricsSource = gap)' {
        $C = New-Case
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -MetricsFiles @{ '__0' = '{"Metrics":["gap-metric"]}' }
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) })

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output

        $Result.MetricsSource | Should -Be 'gap'
        $OutMetrics = Join-Path $C.Output ('Metrics_{0}__0.json' -f $script:GapBase)
        Test-Path -Path $OutMetrics | Should -BeTrue
        (Get-Content -Path $OutMetrics -Raw) | Should -Match 'gap-metric'
    }

    It 'replaces and rebases metrics to the gap base under -RecoverMetrics (MetricsSource = recovery)' {
        $C = New-Case
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -MetricsFiles @{ '__0' = '{"Metrics":["gap-metric"]}' }
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -MetricsFiles @{ '__0' = '{"Metrics":["rec-metric"]}' }

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -RecoverMetrics

        $Result.MetricsSource | Should -Be 'recovery'
        $Rebased = Join-Path $C.Output ('Metrics_{0}__0.json' -f $script:GapBase)
        Test-Path -Path $Rebased | Should -BeTrue -Because 'recovery metrics are rebased to the output bundle base'
        (Get-Content -Path $Rebased -Raw) | Should -Match 'rec-metric'
        Test-Path -Path (Join-Path $C.Output ('Metrics_{0}__0.json' -f $script:RecBase)) | Should -BeFalse -Because 'the recovery base name must not survive into the output'
    }

    It 'throws when -RecoverMetrics is set but the recovery bundle has no metrics' {
        $C = New-Case
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -MetricsFiles @{ '__0' = '{"Metrics":[]}' }
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) })

        { Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -RecoverMetrics } |
            Should -Throw -ExpectedMessage '*has no Metrics_*'
    }
}

Describe 'Merge-RecoveryData guards (advisory warnings)' {

    It 'warns when the recovery dictionary shares no ResourceIdMap tokens with the gap (likely unseeded recovery)' {
        $C = New-Case
        $GapDict = [ordered]@{ GeneratedAt = '2026-01-01 00:00:00'; ResourceIdMap = [ordered]@{ 'prod_gapTok' = '/id/gap' } }
        $RecDict = [ordered]@{ GeneratedAt = '2026-01-02 00:00:00'; ResourceIdMap = [ordered]@{ 'prod_recTok' = '/id/rec' } }
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -Dictionary $GapDict
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) }) -Dictionary $RecDict

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -WarningAction SilentlyContinue

        ($Result.Warnings -join "`n") | Should -Match 'share NO ResourceIdMap tokens'
    }

    It 'does NOT warn about token overlap when the dictionaries share ResourceIdMap tokens (seeded recovery)' {
        $C = New-Case
        $GapDict = [ordered]@{ GeneratedAt = '2026-01-01 00:00:00'; ResourceIdMap = [ordered]@{ 'prod_shared' = '/id/shared' } }
        $RecDict = [ordered]@{ GeneratedAt = '2026-01-02 00:00:00'; ResourceIdMap = [ordered]@{ 'prod_shared' = '/id/shared'; 'prod_recNew' = '/id/new' } }
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -Dictionary $GapDict
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) }) -Dictionary $RecDict

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -WarningAction SilentlyContinue

        ($Result.Warnings -join "`n") | Should -Not -Match 'share NO ResourceIdMap tokens'
    }

    It 'warns about mixed obfuscation state when only one bundle has a dictionary' {
        $C = New-Case
        $GapDict = [ordered]@{ GeneratedAt = '2026-01-01 00:00:00'; ResourceIdMap = [ordered]@{ 'prod_gapTok' = '/id/gap' } }
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -Dictionary $GapDict
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) })

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -WarningAction SilentlyContinue

        ($Result.Warnings -join "`n") | Should -Match 'only one of the gap/recovery bundles has an ObfuscationDictionary'
    }

    It 'warns when a replaced inventory key has fewer records than the gap held' {
        $C = New-Case
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01'), (New-Record 'vm02')) })
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm-only-one')) })

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -WarningAction SilentlyContinue

        ($Result.Warnings -join "`n") | Should -Match 'REPLACED with FEWER records'
    }

    It 'warns when -RecoverConsumption replaces with fewer rows than the gap CSV' {
        $C = New-Case
        $GapCsv = "$script:CsvHeader`n{},Compute,m1,GAP1,eastus,vm,1,Hours,2026-01-01,2026-01-02,/id,eastus,,,`n{},Compute,m2,GAP2,eastus,vm,1,Hours,2026-01-01,2026-01-02,/id,eastus,,,"
        $RecCsv = "$script:CsvHeader`n{},Compute,m1,REC1,eastus,vm,1,Hours,2026-01-01,2026-01-02,/id,eastus,,,"
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -ConsumptionCsv $GapCsv
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -ConsumptionCsv $RecCsv

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -RecoverConsumption -WarningAction SilentlyContinue

        ($Result.Warnings -join "`n") | Should -Match 'FEWER rows than the gap CSV'
    }

    It 'warns when -RecoverConsumption billing window differs from the gap CSV' {
        $C = New-Case
        $GapCsv = "$script:CsvHeader`n{},Compute,m1,GAP1,eastus,vm,1,Hours,2026-01-01,2026-01-02,/id,eastus,,,"
        $RecCsv = "$script:CsvHeader`n{},Compute,m1,REC1,eastus,vm,1,Hours,2026-02-01,2026-02-02,/id,eastus,,,"
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -ConsumptionCsv $GapCsv
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -ConsumptionCsv $RecCsv

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -RecoverConsumption -WarningAction SilentlyContinue

        ($Result.Warnings -join "`n") | Should -Match 'billing window differs'
    }

    It 'emits the HTML-does-not-render-metrics advisory under -RecoverMetrics' {
        $C = New-Case
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -MetricsFiles @{ '__0' = '{"Metrics":["gap-metric"]}' }
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -MetricsFiles @{ '__0' = '{"Metrics":["rec-metric"]}' }

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -RecoverMetrics -WarningAction SilentlyContinue

        ($Result.Warnings -join "`n") | Should -Match 'does not render metrics'
    }

    It 'HARD FAILS when the gap dictionary does not match its inventory (wrong dictionary)' {
        $C = New-Case
        $GapInv = [ordered]@{
            Version         = '3.2.3'
            VirtualMachines = @(
                [ordered]@{ Name = 'vm01'; ID = 'prod_11111111-1111-1111-1111-111111111111' },
                [ordered]@{ Name = 'vm02'; ID = 'prod_22222222-2222-2222-2222-222222222222' },
                [ordered]@{ Name = 'vm03'; ID = 'prod_33333333-3333-3333-3333-333333333333' }
            )
        }
        # Dictionary from a DIFFERENT run: none of the gap inventory's tokens appear.
        $WrongDict = [ordered]@{ GeneratedAt = '2026-01-01 00:00:00'; ResourceIdMap = [ordered]@{ 'prod_99999999-9999-9999-9999-999999999999' = '/id/x' } }
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory $GapInv -Dictionary $WrongDict
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) })

        { Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -WarningAction SilentlyContinue } |
            Should -Throw -ExpectedMessage '*does NOT match its inventory*'
    }

    It 'HARD FAILS when the recovery dictionary does not match its inventory' {
        $C = New-Case
        $RecInv = [ordered]@{
            Version         = '3.2.3'
            VirtualMachines = @(
                [ordered]@{ Name = 'vm01'; ID = 'prod_aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' },
                [ordered]@{ Name = 'vm02'; ID = 'prod_bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' },
                [ordered]@{ Name = 'vm03'; ID = 'prod_cccccccc-cccc-cccc-cccc-cccccccccccc' }
            )
        }
        $WrongDict = [ordered]@{ GeneratedAt = '2026-01-02 00:00:00'; ResourceIdMap = [ordered]@{ 'prod_dddddddd-dddd-dddd-dddd-dddddddddddd' = '/id/y' } }
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) })
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory $RecInv -Dictionary $WrongDict

        { Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -WarningAction SilentlyContinue } |
            Should -Throw -ExpectedMessage '*recovery bundle*does NOT match its inventory*'
    }

    It 'passes when the dictionary contains all of its inventory tokens (correct dictionary)' {
        $C = New-Case
        $GapInv = [ordered]@{
            Version         = '3.2.3'
            VirtualMachines = @(
                [ordered]@{ Name = 'vm01'; ID = 'prod_11111111-1111-1111-1111-111111111111' },
                [ordered]@{ Name = 'vm02'; ID = 'prod_22222222-2222-2222-2222-222222222222' },
                [ordered]@{ Name = 'vm03'; ID = 'prod_33333333-3333-3333-3333-333333333333' }
            )
        }
        $GoodDict = [ordered]@{
            GeneratedAt   = '2026-01-01 00:00:00'
            ResourceIdMap = [ordered]@{
                'prod_11111111-1111-1111-1111-111111111111' = '/id/1'
                'prod_22222222-2222-2222-2222-222222222222' = '/id/2'
                'prod_33333333-3333-3333-3333-333333333333' = '/id/3'
            }
        }
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory $GapInv -Dictionary $GoodDict
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) }) -Dictionary $GoodDict

        { Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -WarningAction SilentlyContinue } |
            Should -Not -Throw
    }

    It 'warns (does not fail) on partial dictionary coverage below 50 percent' {
        $C = New-Case
        $GapInv = [ordered]@{
            Version         = '3.2.3'
            VirtualMachines = @(
                [ordered]@{ Name = 'vm01'; ID = 'prod_11111111-1111-1111-1111-111111111111' },
                [ordered]@{ Name = 'vm02'; ID = 'prod_22222222-2222-2222-2222-222222222222' },
                [ordered]@{ Name = 'vm03'; ID = 'prod_33333333-3333-3333-3333-333333333333' },
                [ordered]@{ Name = 'vm04'; ID = 'prod_44444444-4444-4444-4444-444444444444' }
            )
        }
        # Only 1 of 4 tokens present -> 25% coverage -> warn, not throw.
        $PartialDict = [ordered]@{ GeneratedAt = '2026-01-01 00:00:00'; ResourceIdMap = [ordered]@{ 'prod_11111111-1111-1111-1111-111111111111' = '/id/1' } }
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory $GapInv -Dictionary $PartialDict
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) }) -Dictionary $PartialDict

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -WarningAction SilentlyContinue

        ($Result.Warnings -join "`n") | Should -Match 'covers only'
    }

    It 'reports no warnings for a clean, dictionary-compatible, same-window merge' {
        $C = New-Case
        $GapDict = [ordered]@{ GeneratedAt = '2026-01-01 00:00:00'; ResourceIdMap = [ordered]@{ 'prod_shared' = '/id/shared' } }
        $RecDict = [ordered]@{ GeneratedAt = '2026-01-02 00:00:00'; ResourceIdMap = [ordered]@{ 'prod_shared' = '/id/shared' } }
        $Csv = "$script:CsvHeader`n{},Compute,m1,MET,eastus,vm,1,Hours,2026-01-01,2026-01-02,/id,eastus,,,"
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -ConsumptionCsv $Csv -Dictionary $GapDict
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -ConsumptionCsv $Csv -Dictionary $RecDict

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -RecoverConsumption -WarningAction SilentlyContinue

        @($Result.Warnings).Count | Should -Be 0
    }
}

Describe 'Merge-RecoveryData dictionary merge and packaging' {

    It 'merges the obfuscation dictionaries as a union and returns its path' {
        $C = New-Case
        $GapDict = [ordered]@{
            GeneratedAt         = '2026-01-01 00:00:00'
            ResourceIdMap       = [ordered]@{ 'prod_tokA' = '/id/a' }
            SubscriptionNameMap = [ordered]@{ 'prod_subtok' = 'Gap Sub' }
        }
        $RecDict = [ordered]@{
            GeneratedAt   = '2026-01-02 00:00:00'
            ResourceIdMap = [ordered]@{ 'prod_tokB' = '/id/b' }
            TagMap        = [ordered]@{ 'prod_tagtok' = 'payments' }
        }
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -Dictionary $GapDict
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) }) -Dictionary $RecDict

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output

        $Result.OutputDictionary | Should -Not -BeNullOrEmpty
        Test-Path -Path $Result.OutputDictionary | Should -BeTrue
        $Dict = Get-Content -Path $Result.OutputDictionary -Raw | ConvertFrom-Json
        $Dict.ResourceIdMap.PSObject.Properties.Name | Should -Contain 'prod_tokA' -Because 'gap entries are retained'
        $Dict.ResourceIdMap.PSObject.Properties.Name | Should -Contain 'prod_tokB' -Because 'recovery-only entries are added (union)'
        $Dict.PSObject.Properties.Name | Should -Contain 'TagMap' -Because 'a map present only in the recovery dictionary is added'
    }

    It 'never includes the obfuscation dictionary in the output zip' {
        $C = New-Case
        $GapDict = [ordered]@{ GeneratedAt = '2026-01-01 00:00:00'; ResourceIdMap = [ordered]@{ 'prod_tokA' = '/id/a' } }
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -Dictionary $GapDict
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) })

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output

        $Entries = Get-ZipEntryNames -ZipPath $Result.OutputZip
        ($Entries | Where-Object { $_ -like 'ObfuscationDictionary_*' }) | Should -BeNullOrEmpty -Because 'the dictionary maps back to real values and must never ship'
        ($Entries | Where-Object { $_ -like 'Inventory_*.json' }) | Should -Not -BeNullOrEmpty
        ($Entries | Where-Object { $_ -like '*.html' }) | Should -Not -BeNullOrEmpty
    }

    It 'does not mutate the source gap or recovery bundles' {
        $C = New-Case
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) })
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) })
        $GapInvPath = Join-Path $C.Gap ('Inventory_{0}.json' -f $script:GapBase)
        $RecInvPath = Join-Path $C.Recovery ('Inventory_{0}.json' -f $script:RecBase)
        $GapBefore = Get-Content -Path $GapInvPath -Raw
        $RecBefore = Get-Content -Path $RecInvPath -Raw

        $null = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output

        (Get-Content -Path $GapInvPath -Raw) | Should -Be $GapBefore -Because 'the merge writes to OutputPath only, never back into the gap bundle'
        (Get-Content -Path $RecInvPath -Raw) | Should -Be $RecBefore -Because 'the recovery bundle is read-only input'
    }
}
