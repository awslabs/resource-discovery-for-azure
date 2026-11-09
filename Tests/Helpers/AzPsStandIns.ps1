# Az PowerShell stand-ins for the child-process harnesses that run the real
# ResourceInventory.ps1 / Run-AllSubscriptions.ps1 offline.
#
# The tool signs in, lists subscriptions and queries Resource Graph with Az
# PowerShell only (Get-AzContext, Get-AzAccessToken -TenantId, Get-AzSubscription,
# Invoke-AzRestMethod). A harness dot-sources this file AFTER it has defined its
# own stand-ins:
#
#   - Invoke-StandInGraph (optional): the harness's Resource Graph answers. It is
#     called with arguments in the shape the old CLI stand-ins read
#     (graph query -q <query> --subscriptions <id>... --skip <n> --first <n>) and
#     returns the answer as JSON text ({"data":[...]}); it sets
#     $global:LASTEXITCODE to a non-zero value, and returns the error text, to
#     fail the request.
#   - Get-AzContext, Get-AzAccessToken and Invoke-AzRestMethod (optional): kept;
#     this file wraps them.
#   - $Global:StandInSubs: the subscriptions Get-AzSubscription lists (or, when
#     unset, the JSON Invoke-StandInGraph answers for 'account list').
#
# Generic names and placeholder ids only. No live Azure.

$script:StandInInnerToken = if (Test-Path -LiteralPath 'function:global:Get-AzAccessToken') { ${function:global:Get-AzAccessToken} } else { $null }
$script:StandInInnerRest = if (Test-Path -LiteralPath 'function:global:Invoke-AzRestMethod') { ${function:global:Invoke-AzRestMethod} } else { $null }
$Global:StandInInnerToken = $script:StandInInnerToken
$Global:StandInInnerRest = $script:StandInInnerRest

$Global:StandInInnerContext = if (Test-Path -LiteralPath 'function:global:Get-AzContext') { ${function:global:Get-AzContext} } else { $null }

# A stand-in context with no Account reads as "not signed in" to the sign-in
# checks; give it a placeholder user so the harness's saved sign-in is reused.
if ($null -ne $Global:StandInInnerContext)
{
    function global:Get-AzContext
    {
        [CmdletBinding()]
        param([switch]$ListAvailable)
        $Ctx = & $Global:StandInInnerContext
        if ($null -ne $Ctx -and $null -eq $Ctx.PSObject.Properties['Account']) { $Ctx | Add-Member -NotePropertyName Account -NotePropertyValue ([pscustomobject]@{ Id = 'tester'; Type = 'User' }) -Force }
        return $Ctx
    }
}

# The tenant the stand-in context is on.
function global:Get-StandInTenant
{
    $Ctx = Get-AzContext
    if ($null -ne $Ctx -and $null -ne $Ctx.Tenant) { return [string]$Ctx.Tenant.Id }
    return $null
}

# Accepts -TenantId as the real cmdlet does and always carries TenantId, which
# the sign-in reads to resolve a tenant name to its id.
function global:Get-AzAccessToken
{
    [CmdletBinding()]
    param($ResourceUrl, $TenantId, [switch]$AsSecureString, $ResourceTypeName)
    $Inner = $Global:StandInInnerToken
    $Token = if ($null -ne $Inner)
    {
        if ($ResourceUrl) { & $Inner -ResourceUrl $ResourceUrl } else { & $Inner }
    }
    else
    {
        [pscustomobject]@{ Token = 'stand-in-token' }
    }
    if ($null -eq $Token) { return $null }
    $Tenant = if ($TenantId) { [string]$TenantId } else { Get-StandInTenant }
    if ($null -eq $Token.PSObject.Properties['TenantId']) { $Token | Add-Member -NotePropertyName TenantId -NotePropertyValue $Tenant -Force }
    return $Token
}

if (-not (Test-Path -LiteralPath 'function:global:Get-AzSubscription'))
{
    function global:Get-AzSubscription
    {
        [CmdletBinding()]
        param($TenantId, $SubscriptionId, $SubscriptionName)
        # The harness's own list, or what its CLI-shaped stand-in answers for
        # 'account list' when it keeps none.
        $Subs = $Global:StandInSubs
        if ($null -eq $Subs -and (Test-Path -LiteralPath 'function:global:Invoke-StandInGraph'))
        {
            $Text = Invoke-StandInGraph 'account' 'list' '--output' 'json'
            if ($Text) { $Subs = @($Text | ConvertFrom-Json) }
        }
        foreach ($Sub in @($Subs))
        {
            if ($null -eq $Sub) { continue }
            if ($SubscriptionId -and [string]$Sub.id -ne [string]$SubscriptionId) { continue }
            $Tenant = if ($Sub.tenantId) { [string]$Sub.tenantId } else { Get-StandInTenant }
            [pscustomobject]@{ Id = [string]$Sub.id; Name = [string]$Sub.name; TenantId = $Tenant; HomeTenantId = $Tenant; State = $(if ($Sub.state) { [string]$Sub.state } else { 'Enabled' }) }
        }
    }
}

# Resource Graph discovery requests are answered by Invoke-StandInGraph; the
# skip token is the offset of the next page. Every other request (role checks,
# usage, the per-subscription resource count) goes to the harness's own stand-in.
function global:Invoke-AzRestMethod
{
    [CmdletBinding()]
    param($Method, $Path, $Payload, $Uri)
    $Target = if ($Path) { [string]$Path } else { [string]$Uri }
    $IsGraph = $Target -match 'Microsoft\.ResourceGraph/resources' -and (Test-Path -LiteralPath 'function:global:Invoke-StandInGraph')
    $Request = if ($IsGraph -and $Payload) { $Payload | ConvertFrom-Json } else { $null }
    if ($null -ne $Request -and [string]$Request.query -notmatch 'ResourceCount = count\(\) by subscriptionId')
    {
        $Skip = 0
        if ($Request.options -and $Request.options.'$skipToken') { $Skip = [int]$Request.options.'$skipToken' }
        $Top = if ($Request.options -and $Request.options.'$top') { [int]$Request.options.'$top' } else { 1000 }
        $Parts = @('graph', 'query', '-q', [string]$Request.query, '--subscriptions') + @($Request.subscriptions | ForEach-Object { [string]$_ }) + @('--skip', [string]$Skip, '--first', [string]$Top)
        $global:LASTEXITCODE = 0
        $Text = [string](Invoke-StandInGraph @Parts)
        if ($global:LASTEXITCODE -ne 0)
        {
            $global:LASTEXITCODE = 0
            $Code = if ($Text -match 'ResponsePayloadTooLarge') { 'ResponsePayloadTooLarge' } else { 'StandInFailure' }
            $Status = if ($Code -eq 'ResponsePayloadTooLarge') { 400 } else { 500 }
            return [pscustomobject]@{ StatusCode = $Status; Content = (@{ error = @{ code = $Code; message = $Text } } | ConvertTo-Json -Compress -Depth 4) }
        }
        # A full page may have a next one: hand out the next offset as the token.
        # The text is not parsed with ConvertFrom-Json, which cannot read an
        # empty property name; JsonDocument can.
        $Rows = 0
        try { $Rows = [System.Text.Json.JsonDocument]::Parse($Text).RootElement.GetProperty('data').GetArrayLength() } catch { $Rows = 0 }
        if ($Rows -ge $Top -and $Text.TrimStart().StartsWith('{'))
        {
            $At = $Text.IndexOf('{')
            $Text = $Text.Substring(0, $At + 1) + ('"$skipToken":"{0}",' -f ($Skip + $Top)) + $Text.Substring($At + 1)
        }
        return [pscustomobject]@{ StatusCode = 200; Content = $Text }
    }
    $Inner = $Global:StandInInnerRest
    if ($null -eq $Inner) { throw ('no stand-in for {0} {1}' -f $Method, $Target) }
    $Call = @{ Method = $Method }
    if ($Path) { $Call.Path = $Path }
    if ($Uri) { $Call.Uri = $Uri }
    if ($Payload) { $Call.Payload = $Payload }
    return (& $Inner @Call)
}
