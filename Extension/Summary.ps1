param($File, $TableStyle, $PlatOS, $Subscriptions, $Resources, $ExtractionRunTime, $ReportingRunTime, $RunLite, $Version)

if(!$RunLite)
{
    $Excel = New-Object -TypeName OfficeOpenXml.ExcelPackage $File
    $Worksheets = $Excel.Workbook.Worksheets

    $Order = $Worksheets | Select-Object -Property Index, name, @{N = "Dimension"; E = { $_.dimension.Rows - 1 } } | Sort-Object -Property Dimension -Descending
    $Order0 = $Order | Where-Object { $_.Name -ne $Order[0].name -and $_.Name -ne ($Order | select-object -Last 1).Name }

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

    $Excel.Save()
    $Excel.Dispose()
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
        $Excel.Save()
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
        $Number = $WorkS.Tables.Name.split('_')

        $tmp = @{
            'Name' = $WorkS.name;
            'Size' = [int]$Number[1]
        }

        $Table += $tmp
    }

    if($RunLite)
    {
        Close-ExcelPackage $excel
    }
    else
    {
        $Excel.Save()
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

    $User = $Subscriptions[0].user.name
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
        $Excel.Save()
        $Excel.Dispose()    
    }



$excel = Open-ExcelPackage -Path $file -KillExcel

Close-ExcelPackage $excel
