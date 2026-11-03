#Requires -Version 7.0
# =============================================================================
# InventoryJson.Functions.ps1
#
# Write-InventoryJson, the one writer of Inventory_*.json. Dot-sourced by
# ResourceInventory.ps1 and by Functions/RecoveryMerge.Functions.ps1, so a
# recovery merge loaded on its own writes the same bytes as a normal run.
# Definitions only - no top-level code, so loading it defines this one function
# and changes nothing else in the caller's session.
# =============================================================================

# Write the inventory object (one NoteProperty per collector) to $Path one property at a time,
# so the whole document is never built as one string. The output is byte-for-byte what
# '$InputObject | ConvertTo-Json -Depth 100 -Compress | Out-File $Path' wrote: each value sits
# one level below the root, hence -Depth 99; -InputObject keeps a one-element array as [ ... ];
# UTF-8 with no BOM and a trailing newline; a relative path resolves against the PowerShell
# location, as Out-File does. The file is written under a temporary name in the same folder and
# moved to $Path only once it is complete, so a failed write never leaves a cut-off file: on any
# failure the temporary file is closed and removed, and the error is re-thrown.
# A dictionary (hashtable, [ordered]) is refused before anything is written: its PSObject
# properties are Keys, Count, IsReadOnly and so on, not its entries, so it would be written as
# the wrong shape.
function Write-InventoryJson
{
    param(
        [Parameter(Mandatory = $true)]
        $InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ($InputObject -is [System.Collections.IDictionary])
    {
        throw ("Write-InventoryJson: -InputObject is a dictionary ({0}). Pass a [pscustomobject] with one property per collector, for example [pscustomobject]`$Table." -f $InputObject.GetType().FullName)
    }

    $FullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $TempPath = '{0}.{1}.tmp' -f $FullPath, [guid]::NewGuid().ToString('N')
    $Moved = $false
    try
    {
        $Writer = [System.IO.StreamWriter]::new($TempPath, $false, [System.Text.UTF8Encoding]::new($false))
        try
        {
            $Writer.Write('{')
            $FirstProperty = $true
            foreach ($Prop in $InputObject.PSObject.Properties)
            {
                if (-not $FirstProperty) { $Writer.Write(',') }
                $FirstProperty = $false
                $Writer.Write((ConvertTo-Json -InputObject $Prop.Name -Compress))
                $Writer.Write(':')
                $Writer.Write((ConvertTo-Json -InputObject $Prop.Value -Depth 99 -Compress))
            }
            $Writer.Write('}')
            $Writer.Write([Environment]::NewLine)
        }
        finally
        {
            try { $Writer.Flush() }
            finally { $Writer.Dispose() }
        }
        [System.IO.File]::Move($TempPath, $FullPath, $true)
        $Moved = $true
    }
    finally
    {
        if (-not $Moved -and (Test-Path -LiteralPath $TempPath)) { Remove-Item -LiteralPath $TempPath -Force -ErrorAction SilentlyContinue }
    }
}
