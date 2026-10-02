# One Step 3 run on Windows, started by Step3-Windows.ps1 in a fresh pwsh process.
# The Windows box runs commands as SYSTEM, which has no Azure sign-in of its own, so this signs in for
# THIS process only, from a short-lived ARM token relayed in a file, with context autosave off, and then
# runs Step3-Streams.ps1 in the same process exactly as the macOS runs did. Nothing is saved to disk by
# Az: the 'processes' design writes its own context snapshot and removes it, as on macOS.
param(
    [Parameter(Mandatory)] [string]$Tree,
    [Parameter(Mandatory)] [ValidateSet('processes', 'runspaces', 'sequential')] [string]$Design,
    [Parameter(Mandatory)] [string]$ResultFile,
    [Parameter(Mandatory)] [string]$TokenFile,
    [int]$Streams = 3,
    [int]$ConcurrencyLimit = 6
)
$ErrorActionPreference = 'Stop'
Import-Module Az.Accounts -WarningAction SilentlyContinue
Disable-AzContextAutosave -Scope Process | Out-Null
$Relay = Get-Content -Raw -LiteralPath $TokenFile | ConvertFrom-Json
try
{
    # Az.Accounts 5 takes the token as a SecureString; earlier versions take a string.
    $Secure = [System.Security.SecureString]::new()
    foreach ($Character in $Relay.Token.ToCharArray()) { $Secure.AppendChar($Character) }
    Connect-AzAccount -AccessToken $Secure -AccountId $Relay.AccountId -Tenant $Relay.TenantId -Scope Process -WarningAction SilentlyContinue | Out-Null
}
catch
{
    Connect-AzAccount -AccessToken $Relay.Token -AccountId $Relay.AccountId -Tenant $Relay.TenantId -Scope Process -WarningAction SilentlyContinue | Out-Null
}
& (Join-Path $Tree 'experiments/one-process-streams/Step3-Streams.ps1') -Tree $Tree -Design $Design -Streams $Streams -ConcurrencyLimit $ConcurrencyLimit -ResultFile $ResultFile
