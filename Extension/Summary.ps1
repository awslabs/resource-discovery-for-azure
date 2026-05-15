param(
    $File, 
    $TableStyle, 
    $PlatOS, 
    $Subscriptions, 
    $Resources, 
    $ExtractionRunTime, 
    $ReportingRunTime, 
    $RunLite, 
    $Version
)

# Ensure the EPPlus types backing ImportExcel are available before any
# `New-Object -TypeName OfficeOpenXml.ExcelPackage` call below.
#
# Background: this script is invoked via `& $SummaryPath ...` from
# ResourceInventory.ps1, which creates a new child scope. PowerShell's
# auto-import of modules only triggers on first use of a *cmdlet* exported
# by the module, but the lines below reference the underlying EPPlus type
# directly via `New-Object`. Type references do not trigger auto-import,
# so on a fresh script invocation - or on the second-and-later iterations
# of a long Run-AllSubscriptions.ps1 loop where module state can be
# evicted on Windows PowerShell - the type lookup fails with:
#
#   Cannot find type [OfficeOpenXml.ExcelPackage]: verify that the
#   assembly containing this type is loaded.
#
# Importing ImportExcel explicitly here is idempotent and inexpensive, and
# guarantees the EPPlus assembly is loaded into the current AppDomain
# before any New-Object call against its types. This matches the pattern
# already used elsewhere in the script for Az modules.
try {
    if (-not ([System.Management.Automation.PSTypeName]'OfficeOpenXml.ExcelPackage').Type) {
        Import-Module ImportExcel -ErrorAction Stop -Force -DisableNameChecking | Out-Null
    }
    if (-not ([System.Management.Automation.PSTypeName]'OfficeOpenXml.ExcelPackage').Type) {
        throw "ImportExcel module imported but the OfficeOpenXml.ExcelPackage type is still not loadable. The ImportExcel module may be present but its bundled EPPlus assembly is missing or unloadable in this runspace."
    }
} catch {
    Write-Error ("Summary.ps1 cannot proceed: {0}" -f $_.Exception.Message)
    throw
}

# Translate the underlying exception chain into a single plain-English
# explanation of what most likely went wrong, so the user does not have to
# read .NET stack traces to triage. Inspects the full InnerException chain
# for known signals and falls through to a generic message if none match.
function Get-SaveFailureDiagnosis
{
    param(
        [Parameter(Mandatory = $true)] $Exception,
        [Parameter(Mandatory = $true)] [int] $WorksheetCount,
        [Parameter(Mandatory = $true)] [bool] $FileExists
    )

    $messages = @()
    $e = $Exception
    while ($null -ne $e)
    {
        $messages += $e.Message
        $e = $e.InnerException
    }
    $combined = ($messages -join ' | ')

    if ($combined -match 'must contain at least one worksheet')
    {
        return 'The workbook is empty (zero worksheets). EPPlus refuses to save a workbook with no sheets. This usually means the inventory phase produced no resources for this subscription, so there were no per-service tabs to write into the file.'
    }
    if ($combined -match 'being used by another process|cannot access the file|sharing violation')
    {
        return 'The output file is held open by another process. Close any Microsoft Excel window that has this file open and re-run.'
    }
    if ($combined -match 'UnauthorizedAccess|access to the path .* is denied|access is denied')
    {
        return 'Access to the output file or its parent folder was denied. Check permissions on the InventoryReports folder, and that no antivirus or DLP product is blocking writes.'
    }
    if ($combined -match 'There is not enough space|disk full|not enough room')
    {
        return 'Insufficient disk space to write the output file.'
    }
    if (-not $FileExists -and $WorksheetCount -gt 0)
    {
        return 'The output file does not exist on disk yet, but the in-memory workbook has worksheets. The Save call should have created the file. This is most likely a path or permission issue from EPPlus rather than a content issue.'
    }
    return 'No specific diagnosis matched. See the exception details below for the underlying error.'
}

# Helper: invoke $package.Save() with diagnostic context. The bare .Save() call
# raises a generic 'Error saving file ...' that doesn't tell the maintainer
# which save site failed, what state the workbook is in, or what the underlying
# .NET exception was. See #16 for context.
#
# Behaviour:
# - On success: returns silently.
# - On failure: writes a structured, human-readable diagnosis followed by the
#   raw exception chain to the host stream; ensures the package is disposed
#   (otherwise the file handle leaks and any subsequent open of the workbook
#   on this run also fails); then re-throws so the caller's existing catch
#   logic still fires.
function Save-ExcelPackageWithDiagnostics
{
    param(
        [Parameter(Mandatory = $true)] $Package,
        [Parameter(Mandatory = $true)] [string] $File,
        [Parameter(Mandatory = $true)] [string] $SaveSite
    )

    try
    {
        $Package.Save()
    }
    catch
    {
        $ex = $_.Exception
        $fileExists = Test-Path $File
        $sizeOnDisk = if ($fileExists) { (Get-Item $File).Length } else { $null }
        $worksheetCount = try { [int]$Package.Workbook.Worksheets.Count } catch { -1 }
        $sizeText = if (-not $fileExists) { '<file does not exist on disk yet>' } else { '{0} bytes' -f $sizeOnDisk }
        $worksheetText = if ($worksheetCount -lt 0) { '<could not read; package state inaccessible>' } else { [string]$worksheetCount }

        $diagnosis = Get-SaveFailureDiagnosis -Exception $ex -WorksheetCount $worksheetCount -FileExists $fileExists

        Write-Host ("[Summary.ps1] Save failed at site '{0}' for {1}" -f $SaveSite, $File) -ForegroundColor Red
        Write-Host ("[Summary.ps1] Likely cause: {0}" -f $diagnosis) -ForegroundColor Yellow
        Write-Host "[Summary.ps1] State at failure:" -ForegroundColor Red
        Write-Host ("[Summary.ps1]   File on disk: {0}" -f $sizeText) -ForegroundColor Red
        Write-Host ("[Summary.ps1]   Worksheets:   {0}" -f $worksheetText) -ForegroundColor Red
        Write-Host "[Summary.ps1] Underlying exception:" -ForegroundColor Red
        Write-Host ("[Summary.ps1]   {0}: {1}" -f $ex.GetType().FullName, $ex.Message) -ForegroundColor Red
        $inner = $ex.InnerException
        $depth = 0
        while ($null -ne $inner -and $depth -lt 5)
        {
            Write-Host ("[Summary.ps1]   Inner[{0}]: {1}: {2}" -f $depth, $inner.GetType().FullName, $inner.Message) -ForegroundColor Red
            $inner = $inner.InnerException
            $depth++
        }

        # Ensure the package is disposed even though Save() failed. Without this
        # the underlying file handle stays held and the next Open-ExcelPackage
        # on the same path fails too, which makes downstream errors confusing.
        try { $Package.Dispose() }
        catch { Write-Verbose ("Package.Dispose() after Save failure threw: {0}" -f $_.Exception.Message) }

        throw
    }
}

if(!$RunLite)
{
    $Excel = New-Object -TypeName OfficeOpenXml.ExcelPackage $File
    $Worksheets = $Excel.Workbook.Worksheets

    # Skip the reorder/save step if the workbook is empty.
    #
    # Background: New-Object OfficeOpenXml.ExcelPackage <path> does not
    # require the file to exist - if the path is missing it returns a fresh
    # in-memory package with zero worksheets. EPPlus then refuses to .Save()
    # a workbook with no sheets ("The workbook must contain at least one
    # worksheet") and the bare error gives no hint about why. Reaching this
    # state means the inventory phase produced no per-service tabs for this
    # subscription - a sub with no resources, a Resource Graph permission
    # gap, or an obfuscation pipeline that filtered everything out. Either
    # way there is nothing to reorder. Let the next block (Export-Excel
    # ... -WorksheetName 'Overview' below) bootstrap the workbook with at
    # least the Overview sheet so subsequent steps have something to work
    # with.
    if ($Worksheets.Count -eq 0)
    {
        Write-Host ("[Summary.ps1] Workbook for '{0}' has zero worksheets at the reorder step. The inventory phase produced no per-service tabs (likely an empty subscription, a permission gap, or all rows filtered by obfuscation). Skipping reorder; the Overview sheet will be created in the next step." -f $File) -ForegroundColor Yellow
        $Excel.Dispose()
    }
    else
    {
        $Order = $Worksheets | Select-Object -Property Index, name, @{N = "Dimension"; E = { $_.dimension.Rows - 1 } } | Sort-Object -Property Dimension -Descending

        # When the workbook has only one or two sheets there is nothing to
        # reorder either: $Order[0] and ($Order | Select -Last 1) collapse to
        # the same item (or are the entire collection), and $Order0 ends up
        # empty. Handle both edge cases explicitly rather than relying on
        # Where-Object filtering an undefined index.
        if ($Worksheets.Count -lt 3)
        {
            $Order0 = @()
        }
        else
        {
            $firstName = $Order[0].name
            $lastName  = ($Order | Select-Object -Last 1).Name
            $Order0 = $Order | Where-Object { $_.Name -ne $firstName -and $_.Name -ne $lastName }
        }

        $Loop = 0

        Foreach ($Ord in $Order0)
        {
            if ($Ord.Index -and $Loop -ne 0)
            {
                $Worksheets.MoveAfter($Ord.Name, $Order0[$Loop - 1].Name)
            }
            if ($Loop -eq 0)
            {
                $Worksheets.MoveAfter($Ord.Name, $Order[0].Name)
            }

            $Loop++
        }

        Save-ExcelPackageWithDiagnostics -Package $Excel -File $File -SaveSite 'reorder-worksheets'
        $Excel.Dispose()
    }
}

"" | Export-Excel -Path $File -WorksheetName 'Overview' -MoveToStart

    if($RunLite)
    {
        $excel = Open-ExcelPackage -Path $file -KillExcel
    }
    else
    {
        $Excel = New-Object -TypeName OfficeOpenXml.ExcelPackage $File
    }

    $Worksheets = $Excel.Workbook.Worksheets
    $WS = $Excel.Workbook.Worksheets | Where-Object { $_.Name -eq 'Overview' }

    $WS.SetValue(75, 70, '')
    $WS.SetValue(76, 70, '')
    $WS.View.ShowGridLines = $false

    if($RunLite)
    {
        Close-ExcelPackage $excel
    }
    else
    {
        Save-ExcelPackageWithDiagnostics -Package $Excel -File $File -SaveSite 'overview-grid-styling'
        $Excel.Dispose()    
    }
        

    $TableStyleEx = if($PlatOS -eq 'PowerShell Desktop'){'Medium1'}else{$TableStyle}
    $TableStyle = if($PlatOS -eq 'PowerShell Desktop'){'Medium15'}else{$TableStyle}
    #$TableStyle = 'Medium22'
    $Font = 'Segoe UI'

    if($RunLite)
    {
        $excel = Open-ExcelPackage -Path $file -KillExcel
    }
    else
    {
        $Excel = New-Object -TypeName OfficeOpenXml.ExcelPackage $File
    }

    $Worksheets = $Excel.Workbook.Worksheets | Where-Object { $_.Name -ne 'Overview' }
    $WS = $Excel.Workbook.Worksheets | Where-Object { $_.Name -eq 'Overview' }

    $TabDraw = $WS.Drawings.AddShape('TP00', 'Rect')
    $TabDraw.SetSize(130 , 78)
    $TabDraw.SetPosition(1, 0, 0, 0)
    $TabDraw.TextAlignment = 'Center'

    $Table = @()
    foreach ($WorkS in $Worksheets)
    {
        # Each per-service worksheet is expected to have exactly one Table
        # whose name follows the pattern "<Name>_<Size>" (the size half is
        # the row count used to populate the Overview tabs grid). Worksheets
        # that lack a Table - or have a Table whose name does not match the
        # pattern - are skipped rather than being allowed to throw on an
        # unsplittable null. Without this guard a single misshapen sheet
        # blocks the entire Overview build.
        $tableName = try { $WorkS.Tables.Name } catch { $null }
        if ([string]::IsNullOrWhiteSpace($tableName)) { continue }

        $parts = $tableName -split '_'
        $size = 0
        if ($parts.Count -ge 2) { [int]::TryParse($parts[1], [ref]$size) | Out-Null }

        $tmp = @{
            'Name' = $WorkS.name;
            'Size' = $size
        }

        $Table += $tmp
    }

    if($RunLite)
    {
        Close-ExcelPackage $excel
    }
    else
    {
        Save-ExcelPackageWithDiagnostics -Package $Excel -File $File -SaveSite 'overview-tabs-table'
        $Excel.Dispose()    
    }

    $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat 0

    $Table | 
    ForEach-Object { [PSCustomObject]$_ } | Sort-Object -Property 'Size' -Descending |
    Select-Object -Unique 'Name',
    'Size' | Export-Excel -Path $File -WorksheetName 'Overview' -AutoSize -MaxAutoSizeRows 100 -TableName 'AzureTabs' -TableStyle $TableStyleEx -Style $Style -StartRow 6 -StartColumn 1

    $Date = (get-date -Format "MM/dd/yyyy")

    $ExtractTime = if($ExtractionRunTime.Totalminutes -lt 1){($ExtractionRunTime.Seconds.ToString()+' Seconds')}else{($ExtractionRunTime.Totalminutes.ToString('#######.##')+' Minutes')}
    $ReportTime = ($ReportingRunTime.Totalminutes.ToString('#######.##')+' Minutes')

    # $User and $TotalRes are kept for backward-compatibility - upstream forks
    # or downstream consumers may reference them via dot-sourcing patterns.
    # The original assignment of $User crashed the entire Summary build if
    # $Subscriptions was empty or its first element lacked a .user, even
    # though nothing in the script body reads $User itself. Guarding the
    # assignment is cheap insurance against a regression that would surface
    # only in unusual environments.
    $User = if ($Subscriptions -and $Subscriptions.Count -gt 0 -and $Subscriptions[0].user) { $Subscriptions[0].user.name } else { '<unknown user>' }
    $TotalRes = $Resources


    if($RunLite)
    {
        $excel = Open-ExcelPackage -Path $file -KillExcel
    }
    else
    {
        $Excel = New-Object -TypeName OfficeOpenXml.ExcelPackage $File
    }

    $Worksheets = $Excel.Workbook.Worksheets 
    $WS = $Excel.Workbook.Worksheets | Where-Object { $_.Name -eq 'Overview' }


    $cell = $WS.Cells | Where-Object {$_.Address -like 'A*' -and $_.Address -notin 'A1','A2','A3','A4','A5','A6'}
    
    foreach ($item in $cell) 
    {
        $Works = $Item.Text
        $Link = New-Object -TypeName OfficeOpenXml.ExcelHyperLink ("'"+$Works+"'"+'!A1'),$Works
        $Item.Hyperlink = $Link
    }

    $Draw = $WS.Drawings.AddShape('Inventory', 'Rect')
    $Draw.SetSize(445, 240)
    $Draw.SetPosition(1, 0, 2, 5)

    $txt = $Draw.RichText.Add('Version ' + $Version + "`n")
    $txt.Size = 14
    $txt.ComplexFont = $Font
    $txt.LatinFont = $Font

    $txt = $Draw.RichText.Add('Report Date: ')
    $txt.Size = 11
    $txt.ComplexFont = $Font
    $txt.LatinFont = $Font

    $txt = $Draw.RichText.Add($Date + "`n")
    $txt.Size = 12
    $txt.ComplexFont = $Font
    $txt.LatinFont = $Font

    $txt = $Draw.RichText.Add('Extraction Time: ')
    $txt.Size = 11
    $txt.ComplexFont = $Font
    $txt.LatinFont = $Font

    $txt = $Draw.RichText.Add($ExtractTime + "`n")
    $txt.Size = 12
    $txt.ComplexFont = $Font
    $txt.LatinFont = $Font

    $txt = $Draw.RichText.Add('Reporting Time: ')
    $txt.Size = 11
    $txt.ComplexFont = $Font
    $txt.LatinFont = $Font

    $txt = $Draw.RichText.Add($ReportTime + "`n")
    $txt.Size = 12
    $txt.ComplexFont = $Font
    $txt.LatinFont = $Font

    $txt = $Draw.RichText.Add('Environment: ')
    $txt.Size = 11
    $txt.ComplexFont = $Font
    $txt.LatinFont = $Font

    $txt = $Draw.RichText.Add($PlatOS)
    $txt.Size = 12
    $txt.ComplexFont = $Font
    $txt.LatinFont = $Font

    $Draw.TextAlignment = 'Center'

    $DrawP00 = $WS.Drawings | Where-Object { $_.Name -eq 'TP00' }
    $P00Name = 'Reported Resources'
    $DrawP00.RichText.Add($P00Name).Size = 16

    if($RunLite)
    {
        Close-ExcelPackage $excel
    }
    else
    {
        Save-ExcelPackageWithDiagnostics -Package $Excel -File $File -SaveSite 'final-shape-and-summary-text'
        $Excel.Dispose()    
    }



$excel = Open-ExcelPackage -Path $file -KillExcel

Close-ExcelPackage $excel
