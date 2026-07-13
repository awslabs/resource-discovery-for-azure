# SQL VM -> parent compute VM cross-reference tests
# Run with: Invoke-Pester ./Tests/SqlVmParentLink.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# In an obfuscated report a SQL VM resource
# (microsoft.sqlvirtualmachine/sqlvirtualmachines) must remain linkable to its
# underlying compute VM (microsoft.compute/virtualmachines). The SQLVM collector
# resolves properties.virtualMachineResourceId through $ResourceIdDictionary so
# the emitted 'ParentVirtualMachine' column carries the SAME obfuscated token the
# VirtualMachines collector assigned to that VM.
#
# This is the test that actually EXERCISES that resolution with data. The live
# scenario matrix cannot: the test subscription contains zero SQL VMs, so the
# collector's SQLVM section is empty there and the referential-integrity check
# passes vacuously. This test invokes the REAL Services/Data/SQLVM.ps1 collector
# with a synthetic SQL VM record whose virtualMachineResourceId points at a VM
# that IS in the dictionary, and asserts the parent token resolves correctly. It
# also covers the three fallback paths. No live Azure.

BeforeAll {
    $script:Collector = Join-Path $PSScriptRoot '..' 'Services' 'Data' 'SQLVM.ps1' | Resolve-Path | Select-Object -ExpandProperty Path

    # Real-shaped (lowercased, as the central inventory does via .tolower()) ARM ids.
    # All GUIDs below are the canonical Azure documentation placeholder
    # (12345678-1234-1234-1234-123456789012) so the content-safety hook does not
    # flag them; they are not real subscription/resource identifiers.
    $script:DocGuid = '12345678-1234-1234-1234-123456789012'
    $script:VmRealId = "/subscriptions/$($script:DocGuid)/resourcegroups/rg-sql/providers/microsoft.compute/virtualmachines/sqlhost01"
    $script:SqlVmRealId = "/subscriptions/$($script:DocGuid)/resourcegroups/rg-sql/providers/microsoft.sqlvirtualmachine/sqlvirtualmachines/sqlhost01"
    $script:VmObfToken = "prod_$($script:DocGuid)"

    # Build a $Sub array the collector can resolve $1.subscriptionId against.
    $script:Subs = @([pscustomobject]@{ id = $script:DocGuid; Name = "prod_sub_$($script:DocGuid)" })

    # Construct one SQL VM resource record in the shape the collector consumes.
    function New-SqlVmRecord
    {
        param([string]$VmResourceId)  # value placed at PROPERTIES.virtualMachineResourceId; omit/empty to test the no-parent path

        $Props = [pscustomobject]@{
            virtualMachineResourceId = $VmResourceId
            sqlServerLicenseType     = 'PAYG'
            sqlImageOffer            = 'sql2019-ws2022'
            sqlManagement            = 'Full'
            sqlImageSku              = 'Standard'
        }
        return [pscustomobject]@{
            TYPE           = 'microsoft.sqlvirtualmachine/sqlvirtualmachines'
            id             = $script:SqlVmRealId
            NAME           = 'sqlhost01'
            RESOURCEGROUP  = 'rg-sql'
            LOCATION       = 'eastus'
            ZONES          = $null
            subscriptionId = $script:DocGuid
            PROPERTIES     = $Props
        }
    }

    # Invoke the real collector and return the single emitted record.
    function Invoke-SqlVmCollector
    {
        param($Resources, $Dictionary)
        $Result = & $script:Collector -Sub $script:Subs -Resources $Resources -Task 'Processing' -ResourceIdDictionary $Dictionary
        return @($Result)[0]
    }
}

Describe 'SQL VM parent-VM cross-reference (obfuscated)' {

    It 'resolves ParentVirtualMachine to the SAME token the VM got when the parent is in the dictionary' {
        $Dict = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Dict[$script:VmRealId] = $script:VmObfToken   # the VirtualMachines collector indexes the VM here

        $Rec = Invoke-SqlVmCollector -Resources @(New-SqlVmRecord -VmResourceId $script:VmRealId) -Dictionary $Dict

        $Rec.ParentVirtualMachine | Should -BeExactly $script:VmObfToken -Because 'the SQL VM must carry the same obfuscated token as its compute VM'
        # And it must NOT leak the real id.
        $Rec.ParentVirtualMachine | Should -Not -Match 'microsoft.compute'
    }

    It "falls back to 'obfuscated' when obfuscation is on but the parent VM is not in the dictionary" {
        $Dict = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Dict['/subscriptions/x/some/other/id'] = 'prod_unrelated'   # non-empty dict, but not our VM

        $Rec = Invoke-SqlVmCollector -Resources @(New-SqlVmRecord -VmResourceId $script:VmRealId) -Dictionary $Dict

        $Rec.ParentVirtualMachine | Should -BeExactly 'obfuscated' -Because 'an out-of-scope parent must not leak the real id'
    }

    It "returns 'obfuscated' (never the real id) when obfuscation is on and the SQL VM has no parent id" {
        $Dict = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Dict[$script:VmRealId] = $script:VmObfToken

        $Rec = Invoke-SqlVmCollector -Resources @(New-SqlVmRecord -VmResourceId '') -Dictionary $Dict

        $Rec.ParentVirtualMachine | Should -BeExactly 'obfuscated'
    }
}

Describe 'SQL VM parent-VM cross-reference (non-obfuscated)' {

    It 'passes the raw parent id through when obfuscation is off (null dictionary)' {
        $Rec = Invoke-SqlVmCollector -Resources @(New-SqlVmRecord -VmResourceId $script:VmRealId) -Dictionary $null
        $Rec.ParentVirtualMachine | Should -BeExactly $script:VmRealId
    }

    It "emits 'None' when obfuscation is off and there is no parent id" {
        $Rec = Invoke-SqlVmCollector -Resources @(New-SqlVmRecord -VmResourceId '') -Dictionary $null
        $Rec.ParentVirtualMachine | Should -BeExactly 'None'
    }
}
