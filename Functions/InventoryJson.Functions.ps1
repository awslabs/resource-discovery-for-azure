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
# failure the temporary file is closed, its removal is tried (a warning says when it cannot be
# removed), and the error is re-thrown.
# Anything but a [pscustomobject] is refused before anything is written. Its PSObject
# properties are not collectors: a dictionary (hashtable, [ordered]) has Keys, Count,
# IsReadOnly and so on, a string has Length, an array has Count, so each would be written
# as the wrong shape.
function Write-InventoryJson
{
    param(
        [Parameter(Mandatory = $true)]
        $InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $FullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $Moved = $false
    # Only a temporary file this call created is removed on failure.
    $Created = $false
    $TempPath = $null
    try
    {
        # The temporary file sits beside the final one under a short ASCII name
        # of its own, 'rda-write-<32 hex>.tmp' (a new GUID for every write): it
        # never ends in .json, it is 46 characters long (so it fits as a file
        # name wherever a longer final name does), and no two writes share it.
        # A file a killed write left stays in that run's folder with the other
        # files the run had written.
        $TempPath = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($FullPath), ('rda-write-{0}.tmp' -f [guid]::NewGuid().ToString('N')))
        # Inside the try: a throw outside any try is skipped when the caller runs with
        # $ErrorActionPreference = 'SilentlyContinue', as ResourceInventory.ps1 does.
        # Here it always stops the function, before the temporary file is created.
        if ($InputObject -is [System.Collections.IDictionary])
        {
            throw ("Write-InventoryJson: -InputObject is a dictionary ({0}). Pass a [pscustomobject] with one property per collector, for example [pscustomobject]`$Table." -f $InputObject.GetType().FullName)
        }
        if ($InputObject.PSObject.BaseObject -isnot [System.Management.Automation.PSCustomObject])
        {
            throw ("Write-InventoryJson: -InputObject is a {0}, not a [pscustomobject]. Pass a [pscustomobject] with one property per collector." -f $InputObject.GetType().FullName)
        }

        # The file is this call's from the moment it exists, so a failure in
        # building the writer still closes and removes it.
        $TempStream = [System.IO.FileStream]::new($TempPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $Created = $true
        try { $Writer = [System.IO.StreamWriter]::new($TempStream, [System.Text.UTF8Encoding]::new($false)) }
        catch { $TempStream.Dispose(); throw }
        try
        {
            $Writer.Write('{')
            $FirstProperty = $true
            foreach ($Prop in $InputObject.PSObject.Properties)
            {
                if (-not $FirstProperty) { $Writer.Write(',') }
                $FirstProperty = $false
                $NameJson = ConvertTo-Json -InputObject $Prop.Name -Compress
                $ValueJson = ConvertTo-Json -InputObject $Prop.Value -Depth 99 -Compress
                # ConvertTo-Json writes 'null' for $null and '[]' for an empty list, so an empty
                # result only comes from a serialiser error the caller's preference let pass.
                # Writing on would leave '"Name":' with no value, which no reader can parse.
                if ([string]::IsNullOrEmpty($NameJson) -or [string]::IsNullOrEmpty($ValueJson))
                {
                    throw ("Write-InventoryJson: ConvertTo-Json returned nothing for the '{0}' property, so the inventory is not written." -f $Prop.Name)
                }
                $Writer.Write($NameJson)
                $Writer.Write(':')
                $Writer.Write($ValueJson)
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
        if (-not $Moved -and $Created -and $null -ne $TempPath -and (Test-Path -LiteralPath $TempPath))
        {
            Remove-Item -LiteralPath $TempPath -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $TempPath) { Write-Warning ("Write-InventoryJson: could not remove the temporary file '{0}'; delete it by hand." -f $TempPath) }
        }
    }
}
