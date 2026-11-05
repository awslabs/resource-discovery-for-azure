# Obfuscated report detection tests (Extension/Summary.ps1 and
# Functions/AllSubHtmlSummary.Functions.ps1)
# Run with: Invoke-Pester ./Tests/ObfuscatedReportDetection.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# Both HTML reports tell an obfuscated inventory from a plain one by sampling
# record Names and Subscriptions and counting the obfuscation tokens among them.
# The check accepted only 'prod_' or 'nonprod_' and a GUID, so a report whose
# sampled names carry a hint word (prod_aks_<guid> for a resource in an
# AKS-managed 'mc_' group, prod_vmss_<guid>, prod_databricks_<guid>) was shown
# as an identifiable report: the wrong privacy banner, the ID column kept, and
# long cells cut through tokens. Get-RdaObfuscationTokenPattern now owns the
# token shape. The token generators are taken from ResourceInventory.ps1 and
# Extension/Metrics.ps1 with the PowerShell AST and their output is checked
# against it, so a shape they start writing that the pattern does not accept
# fails here. Generic names and the documentation placeholder subscription id
# only; the masked tokens are made at runtime.

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $script:Summary = Join-Path $script:Root 'Extension/Summary.ps1'
    $script:Sub = '12345678-1234-1234-1234-123456789012'   # Azure docs placeholder
    $script:Base = "/subscriptions/$script:Sub/resourcegroups"
    . (Join-Path $script:Root 'Functions/AllSubHtmlSummary.Functions.ps1')

    # The text of function $Name in $File, found with the PowerShell AST.
    function Get-FunctionText
    {
        param([string]$File, [string]$Name)
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($File, [ref]$null, [ref]$null)
        $Fn = @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq $Name }.GetNewClosure(), $true))
        if ($Fn.Count -ne 1) { throw "$Name was not found once in $File." }
        return $Fn[0].Extent.Text
    }

    $script:InventoryScript = Join-Path $script:Root 'ResourceInventory.ps1'
    foreach ($Name in @('Get-ObfuscationPrefix', 'New-ObfuscatedNameToken'))
    {
        . ([scriptblock]::Create((Get-FunctionText $script:InventoryScript $Name)))
    }

    # An obfuscated inventory record as -Obfuscate writes one: every name is the
    # token New-ObfuscatedNameToken gives it.
    $script:SubToken = (Get-ObfuscationPrefix 'Demo Subscription') + [guid]::NewGuid().ToString()
    $script:RgToken = 'prod_' + [guid]::NewGuid().ToString()
    function New-ObfuscatedRecord
    {
        param([string]$Id, [string]$Name, [string]$Ref = '')
        $Token = New-ObfuscatedNameToken -ResourceId $Id -Name $Name
        [ordered]@{
            ID                 = "/subscriptions/$script:SubToken/resourcegroups/$script:RgToken/providers/microsoft.compute/disks/$Token"
            Name               = $Token
            Subscription       = $script:SubToken
            ResourceGroup      = $script:RgToken
            AssociatedResource = $Ref
        }
    }

    # Records whose names all carry a hint word, in three collectors of four.
    $AksRg = "$script:Base/mc_rg-demo_aks-demo_eastus/providers"
    $script:LongRef = ('a' * 170) + '/' + (New-ObfuscatedNameToken -ResourceId "$AksRg/microsoft.compute/virtualmachinescalesets/aks-pool-demo" -Name 'aks-pool-demo')
    $script:Hinted = [ordered]@{
        AksDisks   = @(1..4 | ForEach-Object { New-ObfuscatedRecord -Id "$AksRg/microsoft.compute/disks/disk-demo-$_" -Name "disk-demo-$_" -Ref $(if ($_ -eq 1) { $script:LongRef } else { '' }) })
        ScaleSets  = @(1..4 | ForEach-Object { New-ObfuscatedRecord -Id "$script:Base/rg-demo/providers/microsoft.compute/virtualmachinescalesets/vmss-demo-$_" -Name "vmss-demo-$_" })
        Databricks = @(1..4 | ForEach-Object { New-ObfuscatedRecord -Id "$script:Base/rg-demo/providers/microsoft.databricks/workspaces/ws-demo-$_" -Name "ws-demo-$_" })
    }

    # Records of a plain run whose real names start with 'prod_' and have no GUID.
    function New-PlainRecord
    {
        param([string]$Name)
        [ordered]@{
            ID            = "/subscriptions/$script:Sub/resourceGroups/prod_rg_app/providers/Microsoft.Compute/virtualMachines/$Name"
            Name          = $Name
            Subscription  = 'prod_subscription'
            ResourceGroup = 'prod_rg_app'
        }
    }
    $script:PlainProd = [ordered]@{
        VirtualMachines = @('prod_web01', 'prod_sql_primary', 'prod_app_gateway', 'prod_vmss_frontend' | ForEach-Object { New-PlainRecord $_ })
        Disks           = @('prod_web01_osdisk', 'prod_aks_data', 'prod_databricks_ws', 'prod_rg_mc_disk' | ForEach-Object { New-PlainRecord $_ })
    }

    # The inventory json: a Version, then the collectors in order.
    function ConvertTo-InventoryJson
    {
        param($Inventory)
        $Doc = [ordered]@{ Version = '1.0.0' }
        foreach ($Key in $Inventory.Keys) { $Doc[$Key] = $Inventory[$Key] }
        return ($Doc | ConvertTo-Json -Depth 6)
    }

    # Renders one inventory with the real Summary.ps1 and returns the HTML.
    function Get-ReportHtml
    {
        param($Inventory)
        $Dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $Json = Join-Path $Dir 'Inventory_Test.json'
        $Html = Join-Path $Dir 'Report_Test.html'
        ConvertTo-InventoryJson $Inventory | Set-Content -Path $Json -Encoding utf8
        & $script:Summary -JsonFile $Json -HtmlFile $Html *> $null
        return (Get-Content -Raw -Path $Html)
    }

    # Writes $Inventory as one per-subscription report folder of a run and
    # returns the all-subscriptions summary HTML of that run.
    function Get-AllSubHtml
    {
        param($Inventory)
        $Run = Join-Path $TestDrive ('run_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $Dir = Join-Path $Run 'ResourcesReportTest'
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        ConvertTo-InventoryJson $Inventory | Set-Content -Path (Join-Path $Dir 'Inventory_Test.json') -Encoding utf8
        '<!DOCTYPE html><html><body>stub per-sub report</body></html>' | Set-Content -Path (Join-Path $Dir 'ResourcesReport_Test.html') -Encoding utf8
        $Out = Join-Path $Run 'main.html'
        New-RdaAllSubHtmlSummary -RunOutputDirectory $Run -HtmlFile $Out *> $null
        return (Get-Content -Raw -Path $Out)
    }
}

Describe 'Get-RdaObfuscationTokenPattern accepts each token -Obfuscate writes, and nothing else' {
    BeforeAll {
        $script:Whole = '^(?:' + (Get-RdaObfuscationTokenPattern) + ')$'
    }

    It 'accepts the resource name token New-ObfuscatedNameToken writes for <Kind>' -ForEach @(
        @{ Kind = 'a Databricks workspace'; Id = 'rg-demo/providers/microsoft.databricks/workspaces/ws-demo'; Name = 'ws-demo'; Shape = '^prod_databricks_' }
        @{ Kind = 'a resource in an AKS mc_ group'; Id = 'mc_rg-demo_aks-demo_eastus/providers/microsoft.compute/disks/disk-demo'; Name = 'disk-demo'; Shape = '^prod_aks_' }
        @{ Kind = 'a scale set'; Id = 'rg-demo/providers/microsoft.compute/virtualmachinescalesets/vmss-demo'; Name = 'vmss-demo'; Shape = '^prod_vmss_' }
        @{ Kind = 'a non-production VM'; Id = 'rg-demo/providers/microsoft.compute/virtualmachines/vm-test-demo'; Name = 'vm-test-demo'; Shape = '^nonprod_[0-9a-f]{8}-' }
    ) {
        $Token = New-ObfuscatedNameToken -ResourceId "$script:Base/$Id" -Name $Name
        $Token | Should -Match $Shape
        $Token | Should -Match $script:Whole
    }

    It 'accepts the sub_, rg_ and rg_mc_ tokens an older build wrote in a metric id' {
        # Older builds masked a metric id that the inventory did not hold with
        # their own sub_/rg_ tokens; their reports still read as obfuscated.
        $G = '12345678-1234-1234-1234-123456789012'
        foreach ($Segment in @("prod_sub_$G", "prod_rg_$G", "nonprod_sub_$G", "nonprod_rg_mc_$G", "prod_$G"))
        {
            $Segment | Should -Match $script:Whole
        }
    }

    It 'has no private token builder left in <File>: every masked id comes from Get-ObfuscatedResourceId' -ForEach @(
        @{ File = 'ResourceInventory.ps1' }
        @{ File = 'Extension/Metrics.ps1' }
    ) {
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Root $File), [ref]$null, [ref]$null)
        @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -in 'Build-ObfuscatedResourceUri', 'Resolve-ObfuscationToken' }, $true)).Count | Should -Be 0
    }

    It 'accepts <Value>, a token written without a hint word' -ForEach @(
        @{ Value = 'prod_12345678-1234-1234-1234-123456789012' }
        @{ Value = 'nonprod_12345678-1234-1234-1234-123456789012' }
        @{ Value = 'obfuscated_12345678-1234-1234-1234-123456789012' }
    ) {
        $Value | Should -Match $script:Whole
    }

    It 'rejects <Value>' -ForEach @(
        @{ Value = 'prod_web01' }
        @{ Value = 'prod_vmss_frontend' }
        @{ Value = 'prod_12345678' }
        @{ Value = 'prod-12345678-1234-1234-1234-123456789012' }
        @{ Value = 'staging_12345678-1234-1234-1234-123456789012' }
        @{ Value = 'prod_app_12345678-1234-1234-1234-123456789012' }
        @{ Value = 'prod_12345678-1234-1234-1234-123456789012-old' }
    ) {
        $Value | Should -Not -Match $script:Whole
    }
}

Describe 'Summary.ps1 on an obfuscated inventory whose sampled names all carry a hint word' {
    BeforeAll {
        $script:HintedHtml = Get-ReportHtml $script:Hinted
    }

    It 'shows the obfuscated privacy banner' {
        $script:HintedHtml | Should -Match 'privacy-banner obfuscated'
        $script:HintedHtml | Should -Not -Match 'privacy-banner identifiable'
    }

    It 'drops the ID column, as for other obfuscated reports' {
        $script:HintedHtml | Should -Not -Match '<th data-col="ID">'
    }

    It 'keeps a masked token whole when it cuts a long cell' {
        $script:HintedHtml.Contains('<td>' + $script:LongRef + '</td>') | Should -BeTrue -Because "the cell should hold the $($script:LongRef.Length)-character value whole"
    }
}

Describe 'Summary.ps1 on a plain inventory whose real names start with prod_' {
    BeforeAll {
        $script:PlainHtml = Get-ReportHtml $script:PlainProd
    }

    It 'shows the identifiable privacy banner' {
        $script:PlainHtml | Should -Match 'privacy-banner identifiable'
        $script:PlainHtml | Should -Not -Match 'privacy-banner obfuscated'
    }

    It 'keeps the ID column' {
        $script:PlainHtml | Should -Match '<th data-col="ID">'
    }
}

Describe 'New-RdaAllSubHtmlSummary detects obfuscation the same way' {
    It 'shows the obfuscated privacy banner for inventories whose sampled names all carry a hint word' {
        $Html = Get-AllSubHtml $script:Hinted
        $Html | Should -Match 'privacy-banner obfuscated'
        $Html | Should -Not -Match 'privacy-banner identifiable'
    }

    It 'shows the identifiable privacy banner for real names that start with prod_' {
        $Html = Get-AllSubHtml $script:PlainProd
        $Html | Should -Match 'privacy-banner identifiable'
        $Html | Should -Not -Match 'privacy-banner obfuscated'
    }
}
