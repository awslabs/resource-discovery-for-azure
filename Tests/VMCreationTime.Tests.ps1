# VM collector creation-time tests
# Run with: Invoke-Pester ./Tests/VMCreationTime.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# Services/Compute/VirtualMachines.ps1 casts properties.timeCreated with
# [datetime]. A missing or null value is written as 'Unknown', but a value that
# is present and does not convert to a date (for example an empty string)
# throws "Cannot convert value ... to type System.DateTime". The throw fails the
# whole VM collector and drops every virtual machine from the inventory, not
# only the one with the bad value.
#
# This test invokes the REAL Services/Compute/VirtualMachines.ps1 collector with
# synthetic VM records whose timeCreated is absent, null, a valid timestamp, an
# empty string or 'not-a-date', and asserts that every VM is written, that
# CreatedTime is 'Unknown' when the value is missing or not a date, and that
# every other column is unchanged. Get-AzComputeResourceSku is mocked, so no
# live Azure is needed.
#
# Azure returns timeCreated in UTC (with a Z or an offset). The column is written
# as UTC text on every host; a value with no zone is taken as UTC. A [datetime]
# cast would turn it into the host's local time with no zone shown, so the same
# virtual machine got a different CreatedTime depending on where the tool ran.

BeforeAll {
    $script:Collector = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'Services', 'Compute', 'VirtualMachines.ps1' | Resolve-Path | Select-Object -ExpandProperty Path

    # All GUIDs below are the canonical Azure documentation placeholder; they
    # are not real subscription or resource identifiers.
    $script:DocGuid = '12345678-1234-1234-1234-123456789012'
    $script:Subs = @([pscustomobject]@{ id = $script:DocGuid; Name = 'sub-placeholder' })
    $script:RgPath = "/subscriptions/$($script:DocGuid)/resourcegroups/rg-vm/providers/microsoft.compute"

    # Offline-portability shim: Mock needs a command to intercept even on a box
    # without the Az.Compute module installed.
    function Get-AzComputeResourceSku { }

    # The OS disk every VM record points at.
    $script:OsDisk = [pscustomobject]@{
        TYPE       = 'microsoft.compute/disks'
        id         = "$($script:RgPath)/disks/disk-os"
        sku        = [pscustomobject]@{ name = 'Premium_LRS' }
        Properties = [pscustomobject]@{ diskSizeGB = 128 }
    }

    # Build one VM record in the shape the collector consumes.
    # -TimeCreatedMode: 'Absent' omits the property, 'Null' sets it to $null,
    # 'Value' sets it to -TimeCreated.
    function New-VmRecord
    {
        param(
            [string]$Name,
            [ValidateSet('Absent', 'Null', 'Value')][string]$TimeCreatedMode,
            [string]$TimeCreated
        )

        $Props = [ordered]@{
            licenseType     = 'Windows_Server'
            hardwareProfile = [pscustomobject]@{ vmSize = 'Standard_D2s_v3' }
            storageProfile  = [pscustomobject]@{
                osDisk         = [pscustomobject]@{
                    osType      = 'Windows'
                    managedDisk = [pscustomobject]@{ id = $script:OsDisk.id }
                }
                imageReference = [pscustomobject]@{
                    publisher    = 'MicrosoftWindowsServer'
                    offer        = 'WindowsServer'
                    sku          = '2022-datacenter'
                    exactVersion = '20348.1.1'
                }
            }
            extended        = [pscustomobject]@{
                instanceView = [pscustomobject]@{
                    osname     = 'Windows Server 2022 Datacenter'
                    osversion  = '10.0.20348'
                    powerState = [pscustomobject]@{ displayStatus = 'VM running' }
                }
            }
        }
        if ($TimeCreatedMode -eq 'Null') { $Props['timeCreated'] = $null }
        if ($TimeCreatedMode -eq 'Value') { $Props['timeCreated'] = $TimeCreated }

        return [pscustomobject]@{
            TYPE           = 'microsoft.compute/virtualmachines'
            id             = "$($script:RgPath)/virtualmachines/$Name"
            NAME           = $Name
            RESOURCEGROUP  = 'rg-vm'
            LOCATION       = 'eastus'
            subscriptionId = $script:DocGuid
            PROPERTIES     = [pscustomobject]$Props
        }
    }

    # Every column except CreatedTime, as the collector should emit it for a
    # record built by New-VmRecord with the mocked SKU below.
    function Get-ExpectedColumns
    {
        param([string]$Name)
        return [ordered]@{
            'ID'              = "$($script:RgPath)/virtualmachines/$Name"
            'Subscription'    = 'sub-placeholder'
            'ResourceGroup'   = 'rg-vm'
            'Name'            = $Name
            'Location'        = 'eastus'
            'AvailabilitySet' = 'false'
            'Size'            = 'Standard_D2s_v3'
            'CPU'             = 2
            'Memory'          = 8
            'Set'             = $null
            'ImageReference'  = 'MicrosoftWindowsServer'
            'ImageVersion'    = '20348.1.1'
            'ImageSku'        = '2022-datacenter'
            'ImageOffer'      = 'WindowsServer'
            'HybridBenefit'   = 'AHUB for Windows'
            'OSName'          = 'Windows Server 2022 Datacenter'
            'OSType'          = 'Windows'
            'OSVersion'       = '10.0.20348'
            'OSDisk'          = 'Premium_LRS'
            'OSDiskSizeGB'    = 128
            'PowerState'      = 'VM running'
            'Zones'           = 0
            'Tags'            = $null
        }
    }

    function Invoke-VmCollector
    {
        param($Resources)
        return @(& $script:Collector -Sub $script:Subs -Resources (@($Resources) + $script:OsDisk) -Task 'Processing' -ResourceIdDictionary $null)
    }

    # The host-zone case runs the collector in a child pwsh process with TZ set,
    # once at UTC+14 (Pacific/Kiritimati) and once at UTC-11 (Pacific/Pago_Pago),
    # so a time written in host local time always differs between the two. A host
    # whose child pwsh does not apply TZ skips that case.
    # The first two values are lowercase because Resource Graph answers are
    # lowercased before the collectors see them (Invoke-AzGraphQuerySafe -Lowercase).
    $script:ChildScript = Join-Path $TestDrive 'vm-zone.ps1'
    Set-Content -LiteralPath $script:ChildScript -Encoding utf8 -Value @"
function Get-AzComputeResourceSku { }
`$Guid = '$($script:DocGuid)'
`$Values = @('2024-03-15t09:41:27.1234567z', '2024-03-15t09:41:27.1234567+00:00', '2024-03-15T11:41:27.1234567+02:00', '2024-03-15T09:41:27.1234567')
`$Vms = for (`$i = 0; `$i -lt `$Values.Count; `$i++)
{
    [pscustomobject]@{
        TYPE           = 'microsoft.compute/virtualmachines'
        id             = "/subscriptions/`$Guid/resourcegroups/rg-vm/providers/microsoft.compute/virtualmachines/vm-`$i"
        NAME           = "vm-`$i"
        RESOURCEGROUP  = 'rg-vm'
        LOCATION       = 'eastus'
        subscriptionId = `$Guid
        PROPERTIES     = [pscustomobject]@{ timeCreated = `$Values[`$i]; hardwareProfile = [pscustomobject]@{ vmSize = 'Standard_D2s_v3' } }
    }
}
`$Rows = @(& '$($script:Collector.Replace("'", "''"))' -Sub @([pscustomobject]@{ id = `$Guid; Name = 'sub-placeholder' }) -Resources `$Vms -Task 'Processing' -ResourceIdDictionary `$null)
'{0}|{1}' -f [System.TimeZoneInfo]::Local.BaseUtcOffset.TotalHours, ((`$Rows | ForEach-Object { `$_.CreatedTime }) -join ',')
"@
    $script:Pwsh = (Get-Process -Id $PID).Path

    function Invoke-VmCollectorInZone
    {
        param([string]$Zone)
        $Saved = $env:TZ
        try
        {
            $env:TZ = $Zone
            return [string](& $script:Pwsh -NoProfile -NonInteractive -File $script:ChildScript)
        }
        finally
        {
            if ($null -eq $Saved) { Remove-Item -Path 'Env:TZ' -ErrorAction SilentlyContinue } else { $env:TZ = $Saved }
        }
    }
}

Describe 'VM collector CreatedTime' {

    BeforeAll {
        Mock -CommandName Get-AzComputeResourceSku -MockWith {
            [pscustomobject]@{
                Name         = 'Standard_D2s_v3'
                ResourceType = 'virtualMachines'
                Capabilities = @(
                    [pscustomobject]@{ Name = 'vCPUs'; Value = '2' }
                    [pscustomobject]@{ Name = 'MemoryGB'; Value = '8' }
                )
            }
        }

        # A fixed timestamp with no offset formats the same in every time zone.
        $script:Records = [ordered]@{
            'vm-absent'    = New-VmRecord -Name 'vm-absent' -TimeCreatedMode Absent
            'vm-null'      = New-VmRecord -Name 'vm-null' -TimeCreatedMode Null
            'vm-valid'     = New-VmRecord -Name 'vm-valid' -TimeCreatedMode Value -TimeCreated '2024-03-15T09:41:27.1234567'
            'vm-empty'     = New-VmRecord -Name 'vm-empty' -TimeCreatedMode Value -TimeCreated ''
            'vm-malformed' = New-VmRecord -Name 'vm-malformed' -TimeCreatedMode Value -TimeCreated 'not-a-date'
        }
    }

    It "writes 'Unknown' when properties.timeCreated is absent" {
        $script:Records['vm-absent'].PROPERTIES.PSObject.Properties.Name | Should -Not -Contain 'timeCreated'
        $Rec = @(Invoke-VmCollector -Resources $script:Records['vm-absent'])[0]
        $Rec.CreatedTime | Should -BeExactly 'Unknown'
    }

    It "writes 'Unknown' when properties.timeCreated is null" {
        $script:Records['vm-null'].PROPERTIES.PSObject.Properties.Name | Should -Contain 'timeCreated'
        $Rec = @(Invoke-VmCollector -Resources $script:Records['vm-null'])[0]
        $Rec.CreatedTime | Should -BeExactly 'Unknown'
    }

    It "formats a valid timeCreated as 'yyyy-MM-dd HH:mm'" {
        $Rec = @(Invoke-VmCollector -Resources $script:Records['vm-valid'])[0]
        $Rec.CreatedTime | Should -BeExactly '2024-03-15 09:41'
    }

    It 'formats a UTC timeCreated (as Azure returns it) in UTC' {
        $Iso = '2024-03-15T09:41:27.1234567Z'
        $Rec = @(Invoke-VmCollector -Resources (New-VmRecord -Name 'vm-utc' -TimeCreatedMode Value -TimeCreated $Iso))[0]
        $Expected = [System.DateTimeOffset]::Parse($Iso, [System.Globalization.CultureInfo]::InvariantCulture).UtcDateTime.ToString('yyyy-MM-dd HH:mm')
        $Rec.CreatedTime | Should -BeExactly $Expected
    }

    It 'writes the same UTC text on hosts at UTC+14 and UTC-11' {
        $East = Invoke-VmCollectorInZone 'Pacific/Kiritimati'
        $West = Invoke-VmCollectorInZone 'Pacific/Pago_Pago'
        $EastParts = $East -split '\|'
        $WestParts = $West -split '\|'
        if ($EastParts[0] -ne '14' -or $WestParts[0] -ne '-11')
        {
            Set-ItResult -Skipped -Because 'this host does not apply the TZ variable to a child pwsh'
            return
        }
        $EastParts[1] | Should -BeExactly '2024-03-15 09:41,2024-03-15 09:41,2024-03-15 09:41,2024-03-15 09:41'
        $WestParts[1] | Should -BeExactly $EastParts[1]
    }

    It "writes 'Unknown' when properties.timeCreated is present but not a date (<Name>)" -ForEach @(
        @{ Name = 'vm-empty' }
        @{ Name = 'vm-malformed' }
    ) {
        $Rec = @(Invoke-VmCollector -Resources $script:Records[$Name])[0]
        $Rec.Name | Should -BeExactly $Name
        $Rec.CreatedTime | Should -BeExactly 'Unknown'
    }

    It 'writes every virtual machine when some have a timeCreated that is not a date' {
        $Recs = @(Invoke-VmCollector -Resources @($script:Records.Values))
        $Recs.Count | Should -Be 5
        ($Recs | ForEach-Object { $_.Name }) | Should -Be @('vm-absent', 'vm-null', 'vm-valid', 'vm-empty', 'vm-malformed')
        ($Recs | ForEach-Object { $_.CreatedTime }) | Should -Be @('Unknown', 'Unknown', '2024-03-15 09:41', 'Unknown', 'Unknown')
    }

    It 'leaves CPU and Memory empty for a size the size list does not return' {
        $Record = New-VmRecord -Name 'vm-unlisted' -TimeCreatedMode Value -TimeCreated '2024-03-15T09:41:27.1234567'
        $Record.PROPERTIES.hardwareProfile = [pscustomobject]@{ vmSize = 'Basic_A1' }
        $Recs = @(Invoke-VmCollector -Resources @($script:Records['vm-valid'], $Record))
        $Recs.Count | Should -Be 2
        $Recs[0].CPU | Should -Be 2
        $Recs[0].Memory | Should -Be 8
        $Recs[1].Name | Should -BeExactly 'vm-unlisted'
        $Recs[1].Size | Should -BeExactly 'Basic_A1'
        $Recs[1].CPU | Should -Be $null
        $Recs[1].Memory | Should -Be $null
    }

    It 'leaves every other column unchanged for <Name>' -ForEach @(
        @{ Name = 'vm-absent' }
        @{ Name = 'vm-null' }
        @{ Name = 'vm-valid' }
        @{ Name = 'vm-empty' }
        @{ Name = 'vm-malformed' }
    ) {
        $Rec = @(Invoke-VmCollector -Resources $script:Records[$Name])[0]
        $Expected = Get-ExpectedColumns -Name $Name

        @($Rec.Keys | Sort-Object) | Should -Be @(@($Expected.Keys) + 'CreatedTime' | Sort-Object)
        foreach ($Key in $Expected.Keys)
        {
            $Rec[$Key] | Should -Be $Expected[$Key] -Because "column '$Key' must not depend on timeCreated"
        }
    }
}
