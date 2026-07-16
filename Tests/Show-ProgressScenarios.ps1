#Requires -Version 7.0
<#
.SYNOPSIS
    Demonstrates every Write-RdaProgress scenario so the progress reporting can
    be seen (and screenshotted) by eye, and captured as text where a live bar
    cannot render.

.DESCRIPTION
    The live Write-Progress bar renders to the CONSOLE HOST. It cannot be
    redirected to a file or captured as stdout text, so it is not screenshot-able
    from a headless / redirected session - only from a real interactive console
    (Windows PowerShell console, Windows Terminal, the EC2 RDP console, an SSH
    TTY, or the VS Code integrated terminal).

    This harness therefore does two things:

      1. Runs each scenario as a short ANIMATED loop (with small sleeps) so that,
         when you run it in an interactive console, you SEE the live bar move and
         can take a screenshot of each scenario.

      2. Prints a plain-text "TEXT RENDER" of what each scenario emits to the
         Information stream (the -NonInteractiveLine fallback and the heartbeat
         file). That text is identical in any host, so it serves as capturable
         evidence where a bar screenshot is impossible (CI, parallel stream
         workers, transcripts).

    It calls NOTHING in Azure and creates only a temp heartbeat file, which it
    deletes on exit. Pure demonstration of the shared reporter.

.PARAMETER InteractiveDemo
    Run the animated live-bar loops (with sleeps) in addition to the text render.
    Use this on a real console to watch/screenshot the bar. Omit for a fast,
    text-only pass (the default) suitable for headless capture.

.EXAMPLE
    # On the EC2 Windows console / Windows Terminal - watch & screenshot each bar:
    pwsh -NoProfile -File ./Tests/Show-ProgressScenarios.ps1 -InteractiveDemo

.EXAMPLE
    # Headless text-render evidence only (no sleeps, no live bar):
    pwsh -NoProfile -File ./Tests/Show-ProgressScenarios.ps1
#>
[CmdletBinding()]
param(
    [switch] $InteractiveDemo
)

$FunctionsPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/Common.Functions.ps1'
if (-not (Test-Path $FunctionsPath))
{
    throw "Could not find shared functions file at $FunctionsPath"
}
. $FunctionsPath

$HostIsInteractive = ([Environment]::UserInteractive -and -not [Console]::IsOutputRedirected)

Write-Host ''
Write-Host '=======================================================================' -ForegroundColor Cyan
Write-Host ' Write-RdaProgress - scenario demonstration' -ForegroundColor Cyan
Write-Host '=======================================================================' -ForegroundColor Cyan
Write-Host (' Host interactive (live bar will render): {0}' -f $HostIsInteractive)
if (-not $HostIsInteractive)
{
    Write-Host ' -> This host is non-interactive/redirected, so the live Write-Progress' -ForegroundColor Yellow
    Write-Host '    bar renders nothing here. The TEXT RENDER below is the capturable' -ForegroundColor Yellow
    Write-Host '    evidence. Run with -InteractiveDemo on a real console for the bar.' -ForegroundColor Yellow
}
if ($InteractiveDemo -and -not $HostIsInteractive)
{
    Write-Host ' -> -InteractiveDemo was requested but this host is not interactive;' -ForegroundColor Yellow
    Write-Host '    the animated loops will run but you will only see the text lines.' -ForegroundColor Yellow
}

$HeartbeatFile = Join-Path ([System.IO.Path]::GetTempPath()) ('rda_progress_demo_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.log')
$SleepMs = if ($InteractiveDemo) { 250 } else { 0 }

function Write-ScenarioHeader
{
    param([string] $Number, [string] $Title, [string] $Caller)
    Write-Host ''
    Write-Host ('----- Scenario {0}: {1} -----' -f $Number, $Title) -ForegroundColor Green
    Write-Host ('       caller: {0}' -f $Caller) -ForegroundColor DarkGray
    Write-Host '       TEXT RENDER (Information-stream line[s], identical in any host):' -ForegroundColor DarkGray
}

try
{
    # -- Scenario 1: Determinate loop (per-subscription) -------------------
    Write-ScenarioHeader -Number '1' -Title 'Determinate subscription loop' -Caller 'Run-AllSubscriptions.ps1 (sequential per-sub)'
    $Subs = 1..4 | ForEach-Object { 'Sub-Prod-{0:D2}' -f $_ }
    for ($i = 0; $i -lt $Subs.Count; $i++)
    {
        Write-RdaProgress -Activity 'Processing subscriptions' -CurrentItem $Subs[$i] -Index ($i + 1) -Total $Subs.Count -NonInteractiveLine
        if ($SleepMs) { Start-Sleep -Milliseconds $SleepMs }
    }
    Write-RdaProgress -Activity 'Processing subscriptions' -Completed

    # -- Scenario 2: Count-only loop (total unknown up front) --------------
    Write-ScenarioHeader -Number '2' -Title 'Count-only loop (no total, no percent)' -Caller 'any loop whose total is not known in advance'
    foreach ($n in 1..3)
    {
        Write-RdaProgress -Activity 'Discovering resources' -CurrentItem 'streaming page' -Index $n -NonInteractiveLine
        if ($SleepMs) { Start-Sleep -Milliseconds $SleepMs }
    }
    Write-RdaProgress -Activity 'Discovering resources' -Completed

    # -- Scenario 3: Reveal per-folder loop --------------------------------
    Write-ScenarioHeader -Number '3' -Title 'Reveal per-folder loop' -Caller 'Reveal.ps1'
    $Folders = 1..3 | ForEach-Object { 'RevealedStaging/Sub-Prod-{0:D2}' -f $_ }
    for ($i = 0; $i -lt $Folders.Count; $i++)
    {
        Write-RdaProgress -Activity 'Revealing reports' -CurrentItem $Folders[$i] -Index ($i + 1) -Total $Folders.Count -NonInteractiveLine
        if ($SleepMs) { Start-Sleep -Milliseconds $SleepMs }
    }
    Write-RdaProgress -Activity 'Revealing reports' -Completed

    # -- Scenario 4: Reveal -Resume (enriched "already revealed" label) ----
    Write-ScenarioHeader -Number '4' -Title 'Reveal -Resume (skips already-revealed folders)' -Caller 'Reveal.ps1 -Resume'
    $ResumeSet = @(
        @{ Name = 'Sub-Prod-01 (already revealed)' },
        @{ Name = 'Sub-Prod-02 (already revealed)' },
        @{ Name = 'Sub-Prod-03' },
        @{ Name = 'Sub-Prod-04' }
    )
    for ($i = 0; $i -lt $ResumeSet.Count; $i++)
    {
        Write-RdaProgress -Activity 'Revealing reports' -CurrentItem $ResumeSet[$i].Name -Index ($i + 1) -Total $ResumeSet.Count -NonInteractiveLine
        if ($SleepMs) { Start-Sleep -Milliseconds $SleepMs }
    }
    Write-RdaProgress -Activity 'Revealing reports' -Completed

    # -- Scenario 5: High-frequency BAR-ONLY loop (collectors) -------------
    Write-ScenarioHeader -Number '5' -Title 'Bar-only collector loop (line suppressed)' -Caller 'ResourceInventory.ps1 Service Processing (-BarOnly + heartbeat)'
    Write-Host '       (BarOnly: NO per-item text line - only the live bar + heartbeat file.' -ForegroundColor DarkGray
    Write-Host '        Nothing prints below on purpose; see the heartbeat tail at the end.)' -ForegroundColor DarkGray
    $Collectors = 'Compute', 'Storage', 'Networking', 'Data', 'Containers', 'Analytics'
    for ($i = 0; $i -lt $Collectors.Count; $i++)
    {
        Write-RdaProgress -Activity 'Service Processing' -CurrentItem $Collectors[$i] -Index ($i + 1) -Total $Collectors.Count -BarOnly -HeartbeatLogFile $HeartbeatFile
        if ($SleepMs) { Start-Sleep -Milliseconds $SleepMs }
    }
    Write-RdaProgress -Activity 'Service Processing' -Completed -HeartbeatLogFile $HeartbeatFile

    # -- Scenario 6: Metrics batch loop (bar-only, large total) ------------
    Write-ScenarioHeader -Number '6' -Title 'Metrics batch loop (bar-only, large total)' -Caller 'Extension/Metrics.ps1 (-BarOnly)'
    Write-Host '       (BarOnly again: bar advances by batch; no per-batch text line.)' -ForegroundColor DarkGray
    $MetricTotal = 900
    foreach ($processed in 250, 500, 750, 900)
    {
        Write-RdaProgress -Activity 'Metrics collection' -CurrentItem ('batch (up to {0})' -f $processed) -Index $processed -Total $MetricTotal -BarOnly
        if ($SleepMs) { Start-Sleep -Milliseconds $SleepMs }
    }
    Write-RdaProgress -Activity 'Metrics collection' -Completed

    # -- Heartbeat evidence ------------------------------------------------
    Write-Host ''
    Write-Host '----- Durable heartbeat file (Scenario 5, bar-only phase) -----' -ForegroundColor Green
    Write-Host ('       file: {0}' -f $HeartbeatFile) -ForegroundColor DarkGray
    if (Test-Path $HeartbeatFile)
    {
        Get-Content $HeartbeatFile | ForEach-Object { Write-Host ('       {0}' -f $_) }
    }
    else
    {
        Write-Host '       (no heartbeat file was written)' -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host '=======================================================================' -ForegroundColor Cyan
    Write-Host ' Done. On an interactive console, re-run with -InteractiveDemo to watch' -ForegroundColor Cyan
    Write-Host ' and screenshot each live bar; the text above is the headless evidence.' -ForegroundColor Cyan
    Write-Host '=======================================================================' -ForegroundColor Cyan
}
finally
{
    if (Test-Path $HeartbeatFile)
    {
        Remove-Item -Path $HeartbeatFile -Force -ErrorAction SilentlyContinue
    }
}
