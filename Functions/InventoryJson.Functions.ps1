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
# Fail-safe rule for the clean-up after a failed write: it is best effort and never replaces the
# write's own error. Every clean-up step (closing the writer, the existence check, the removal,
# the warning) sits in a try whose catch drops a second error, so the caller always gets the
# first one.
# Before writing, it warns once for each temporary inventory file already in the destination
# folder ('rda-write-<32 hex>.tmp', or '<name>.json.<32 hex>.tmp' from builds before it): one a
# stopped write left, or one another run is writing into the same folder now, named so the
# operator can delete it. It is never removed here, as it may be another run's.
# -TempName (optional) names the temporary file, a name only (it always goes in the destination
# folder): 'rda-write-<32 hex>.tmp', in that exact case, never the final file's name. A caller that
# must name the file to delete whatever its stream settings chooses the name, passes it here and
# logs the path it gives (ResourceInventory.ps1 does, before the write): this function's warnings
# can be silenced, so a caller never relies on them for that.
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
        [string]$Path,

        [string]$TempName
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
        # A file a killed write left stays in the destination folder; the next
        # write into that folder names it (below).
        $Folder = [System.IO.Path]::GetDirectoryName($FullPath)
        $TempPath = [System.IO.Path]::Combine($Folder, ('rda-write-{0}.tmp' -f [guid]::NewGuid().ToString('N')))
        if (-not [string]::IsNullOrEmpty($TempName))
        {
            # A name only, so the file is always beside the final one (the move stays in one
            # folder); this writer's own form in its exact case, so a later write's listing names
            # it as a leftover; and never the final file's name (case aside, for any file system).
            if ($TempName -cnotmatch '^rda-write-[0-9a-f]{32}\.tmp\z' -or [string]::Equals($TempName, [System.IO.Path]::GetFileName($FullPath), [System.StringComparison]::OrdinalIgnoreCase))
            {
                throw ("Write-InventoryJson: -TempName '{0}' must be a name of the form 'rda-write-<32 hex>.tmp' (lower case), not the final file's name." -f $TempName)
            }
            $TempPath = [System.IO.Path]::Combine($Folder, $TempName)
        }
        # Naming the leftovers is best effort: a folder that cannot be listed never stops the write.
        try
        {
            if ([System.IO.Directory]::Exists($Folder))
            {
                foreach ($Leftover in @([System.IO.Directory]::EnumerateFiles($Folder, '*.tmp') | Where-Object { [System.IO.Path]::GetFileName($_) -cmatch '(?s)^(rda-write-[0-9a-f]{32}|.+\.json\.[0-9a-f]{32})\.tmp\z' } | Sort-Object))
                {
                    Write-Warning ("Write-InventoryJson: '{0}' is a temporary file of an inventory write that was stopped, or of one another run is writing now; delete it once no other run is writing to this folder." -f $Leftover)
                }
            }
        }
        catch { $null = $_ }
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
        catch
        {
            # The fail-safe rule: closing the stream never replaces the writer's error.
            $WriterError = $_
            try { $TempStream.Dispose() } catch { $null = $_ }
            throw $WriterError
        }
        $Written = $false
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
            $Writer.Flush()
            $Written = $true
        }
        finally
        {
            # After a failure the file is discarded, so a second error from closing it
            # (the flush inside Dispose on a full disk) is dropped: the first error stands.
            if ($Written) { $Writer.Dispose() }
            else
            {
                try { $Writer.Dispose() } catch { $null = $_ }
            }
        }
        [System.IO.File]::Move($TempPath, $FullPath, $true)
        $Moved = $true
    }
    finally
    {
        # $Created: a name CreateNew refused (a GUID that is already taken) is not this
        # call's file, so it is never removed.
        if (-not $Moved -and $Created)
        {
            # The fail-safe rule above: nothing here may replace the write's own error.
            try
            {
                # A failed removal warns by itself: File.Exists reads false when the folder
                # cannot be read, so it is only the second signal.
                $RemoveError = $null
                # A file that is already gone is removed, so ItemNotFound is no failure.
                try { Remove-Item -LiteralPath $TempPath -Force -ErrorAction Stop } catch { if ($_.Exception -isnot [System.Management.Automation.ItemNotFoundException]) { $RemoveError = $_ } }
                if ($null -ne $RemoveError -or [System.IO.File]::Exists($TempPath)) { Write-Warning ("Write-InventoryJson: could not remove the temporary file '{0}'; delete it by hand." -f $TempPath) }
            }
            catch { $null = $_ }
        }
    }
}
