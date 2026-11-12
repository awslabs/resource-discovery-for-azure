# Location and ResourceGroup columns of the SQL MI database and Traffic Manager collectors
# Run with: Invoke-Pester ./Tests/CollectorLocationColumns.Tests.ps1 -Output Detailed
#
# Services/Data/SQLMIDB.ps1 and Services/Networking/TrafficManager.ps1 were the only
# collectors that wrote no Location column, and a SQL MI database record had no
# ResourceGroup either. The REAL collectors run on synthetic records shaped as
# Resource Graph returns them; no live Azure.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    # The Azure documentation placeholder; not a real subscription id.
    $script:Guid = '12345678-1234-1234-1234-123456789012'
    $script:Subs = @([pscustomobject]@{ id = $script:Guid; Name = 'sub-placeholder' })
    $script:Rg = "/subscriptions/$($script:Guid)/resourceGroups/rg-a/providers"

    function Invoke-Collector
    {
        param($Path, $Records)
        return , @(& (Join-Path $script:Root $Path) -Sub $script:Subs -Resources @($Records) -Task 'Processing' -ResourceIdDictionary $null)
    }
}

Describe 'SQL MI database records' {
    It 'write the database resource group and location, and keep the other columns' {
        $Db = [pscustomobject]@{
            TYPE           = 'microsoft.sql/managedinstances/databases'
            id             = "$($script:Rg)/microsoft.sql/managedinstances/mi-a/databases/db-a"
            NAME           = 'db-a'
            RESOURCEGROUP  = 'rg-a'
            LOCATION       = 'eastus'
            subscriptionId = $script:Guid
            PROPERTIES     = [pscustomobject]@{ collation = 'SQL_Latin1_General_CP1_CI_AS'; defaultSecondaryLocation = 'westus'; status = 'Online' }
        }

        $Rows = Invoke-Collector 'Services/Data/SQLMIDB.ps1' @($Db)

        $Rows.Count | Should -Be 1
        $Rows[0].Keys | Should -Contain 'ResourceGroup'
        $Rows[0].Keys | Should -Contain 'Location'
        $Rows[0].ResourceGroup | Should -BeExactly 'rg-a'
        $Rows[0].Location | Should -BeExactly 'eastus'
        $Rows[0].ManagedInstance | Should -BeExactly 'mi-a'
        $Rows[0].Name | Should -BeExactly 'db-a'
        $Rows[0].Status | Should -BeExactly 'Online'
    }
}

Describe 'Traffic Manager records' {
    It 'write the profile location, and keep the other columns' {
        $Tm = [pscustomobject]@{
            TYPE           = 'microsoft.network/trafficmanagerprofiles'
            id             = "$($script:Rg)/microsoft.network/trafficmanagerprofiles/tm-a"
            NAME           = 'tm-a'
            RESOURCEGROUP  = 'rg-a'
            LOCATION       = 'global'
            subscriptionId = $script:Guid
            PROPERTIES     = [pscustomobject]@{
                profilestatus        = 'Enabled'
                trafficroutingmethod = 'Priority'
                monitorconfig        = [pscustomobject]@{ profilemonitorstatus = 'Online' }
            }
        }

        $Rows = Invoke-Collector 'Services/Networking/TrafficManager.ps1' @($Tm)

        $Rows.Count | Should -Be 1
        $Rows[0].Keys | Should -Contain 'Location'
        $Rows[0].Location | Should -BeExactly 'global'
        $Rows[0].ResourceGroup | Should -BeExactly 'rg-a'
        $Rows[0].Status | Should -BeExactly 'Enabled'
        $Rows[0].RoutingMethod | Should -BeExactly 'Priority'
    }
}
