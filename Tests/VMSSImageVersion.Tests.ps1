# VMSS collector ImageVersion tests
# Run with: Invoke-Pester ./Tests/VMSSImageVersion.Tests.ps1 -Output Detailed
#
# The ImageVersion column of a scale set must hold the image version, as the
# VirtualMachines.ps1 collector's ImageVersion column does (exactVersion), not
# the image SKU. A scale set model's
# properties.virtualMachineProfile.storageProfile.imageReference carries
# publisher, offer, sku and version (often 'latest'); exactVersion is read
# when present. This test invokes the REAL Services/Containers/VMSS.ps1
# collector with synthetic records; Get-AzComputeResourceSku is mocked, so no
# live Azure is needed.

BeforeAll {
    $script:Collector = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'Services', 'Containers', 'VMSS.ps1' | Resolve-Path | Select-Object -ExpandProperty Path

    # The canonical Azure documentation placeholder, not a real identifier.
    $script:DocGuid = '12345678-1234-1234-1234-123456789012'
    $script:Subs = @([pscustomobject]@{ id = $script:DocGuid; Name = 'sub-placeholder' })

    function Get-AzComputeResourceSku { }

    # One Uniform scale set whose imageReference is built from -ImageReference
    # (a hashtable; $null leaves imageReference out, as for a custom image
    # referenced only by a gallery id that the hashtable can also carry).
    function New-VmssRecord
    {
        param([string]$Name, $ImageReference)
        $Storage = [ordered]@{ osDisk = [pscustomobject]@{ osType = 'Linux'; diskSizeGB = 30; managedDisk = [pscustomobject]@{ storageAccountType = 'Premium_LRS' } } }
        if ($null -ne $ImageReference) { $Storage['imageReference'] = [pscustomobject]$ImageReference }
        return [pscustomobject]@{
            TYPE           = 'microsoft.compute/virtualmachinescalesets'
            id             = "/subscriptions/$($script:DocGuid)/resourcegroups/rg-vmss/providers/microsoft.compute/virtualmachinescalesets/$Name"
            NAME           = $Name
            RESOURCEGROUP  = 'rg-vmss'
            LOCATION       = 'eastus'
            subscriptionId = $script:DocGuid
            sku            = [pscustomobject]@{ name = 'Standard_D2s_v3'; tier = 'Standard'; capacity = 2 }
            PROPERTIES     = [pscustomobject]@{
                orchestrationMode     = 'Uniform'
                timeCreated           = '2024-03-15T09:41:27.1234567'
                virtualMachineProfile = [pscustomobject]@{ storageProfile = [pscustomobject]$Storage }
            }
        }
    }

    function Invoke-VmssCollector
    {
        param($Resources)
        return @(& $script:Collector -Sub $script:Subs -Resources $Resources -Task 'Processing' -ResourceIdDictionary $null)
    }

    $script:Ubuntu = @{ publisher = 'Canonical'; offer = '0001-com-ubuntu-server-jammy'; sku = '22_04-lts-gen2' }
}

Describe 'VMSS collector ImageVersion' {
    BeforeAll {
        Mock -CommandName Get-AzComputeResourceSku -MockWith {
            [pscustomobject]@{
                Name         = 'Standard_D2s_v3'
                ResourceType = 'virtualMachines'
                Capabilities = @([pscustomobject]@{ Name = 'vCPUs'; Value = '2' }, [pscustomobject]@{ Name = 'MemoryGB'; Value = '8' })
            }
        }
    }

    It "writes imageReference.version ('latest'), not the image sku" {
        $Rec = @(Invoke-VmssCollector -Resources @(New-VmssRecord -Name 'ss-latest' -ImageReference ($script:Ubuntu + @{ version = 'latest' })))[0]
        $Rec.ImageVersion | Should -BeExactly 'latest'
        $Rec.ImageVersion | Should -Not -Be '22_04-lts-gen2'
        $Rec.OSImage | Should -BeExactly '0001-com-ubuntu-server-jammy'
    }

    It 'writes a pinned imageReference.version as it is' {
        $Rec = @(Invoke-VmssCollector -Resources @(New-VmssRecord -Name 'ss-pinned' -ImageReference ($script:Ubuntu + @{ version = '22.04.202410020' })))[0]
        $Rec.ImageVersion | Should -BeExactly '22.04.202410020'
    }

    It 'prefers imageReference.exactVersion when it is present, as VirtualMachines.ps1 reads it' {
        $Rec = @(Invoke-VmssCollector -Resources @(New-VmssRecord -Name 'ss-exact' -ImageReference ($script:Ubuntu + @{ version = 'latest'; exactVersion = '22.04.202410020' })))[0]
        $Rec.ImageVersion | Should -BeExactly '22.04.202410020'
    }

    It "falls back to version when exactVersion is present but <Label>" -ForEach @(
        @{ Label = 'null'; Exact = $null }
        @{ Label = 'empty'; Exact = '' }
    ) {
        $Rec = @(Invoke-VmssCollector -Resources @(New-VmssRecord -Name 'ss-fallback' -ImageReference ($script:Ubuntu + @{ version = 'latest'; exactVersion = $Exact })))[0]
        $Rec.ImageVersion | Should -BeExactly 'latest'
    }

    It 'writes an empty ImageVersion, not the sku, when the image has no version (<Label>)' -ForEach @(
        @{ Label = 'sku only'; Ref = @{ publisher = 'Canonical'; offer = '0001-com-ubuntu-server-jammy'; sku = '22_04-lts-gen2' } }
        @{ Label = 'version empty'; Ref = @{ publisher = 'Canonical'; offer = '0001-com-ubuntu-server-jammy'; sku = '22_04-lts-gen2'; version = '' } }
        @{ Label = 'gallery image id only'; Ref = @{ id = "/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-img/providers/Microsoft.Compute/galleries/g1/images/img1" } }
        @{ Label = 'no imageReference'; Ref = $null }
    ) {
        $Rec = @(Invoke-VmssCollector -Resources @(New-VmssRecord -Name 'ss-none' -ImageReference $Ref))[0]
        $Rec.Name | Should -BeExactly 'ss-none'
        $Rec.ImageVersion | Should -BeNullOrEmpty
    }

    It 'gives each scale set its own ImageVersion' {
        $Recs = @(Invoke-VmssCollector -Resources @(
                (New-VmssRecord -Name 'ss-a' -ImageReference ($script:Ubuntu + @{ version = 'latest' }))
                (New-VmssRecord -Name 'ss-b' -ImageReference $script:Ubuntu)
                (New-VmssRecord -Name 'ss-c' -ImageReference ($script:Ubuntu + @{ version = '22.04.202410020' }))
            ))
        ($Recs | ForEach-Object { $_.Name }) | Should -Be @('ss-a', 'ss-b', 'ss-c')
        ($Recs | ForEach-Object { [string]$_.ImageVersion }) | Should -Be @('latest', '', '22.04.202410020')
    }
}
