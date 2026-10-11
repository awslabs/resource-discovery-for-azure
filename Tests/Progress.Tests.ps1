# Scenario unit tests for the single reusable Write-RdaProgress (all entry points route through it; scenarios differ only by caller args).
# Get-RdaProgressLines captures are wrapped in @() so a lone line stays an array, not a scalar whose $Lines[0] would index a character.

BeforeAll {
    $script:FunctionsPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/Common.Functions.ps1'
    if (-not (Test-Path $script:FunctionsPath))
    {
        throw "Could not find shared functions file at $script:FunctionsPath"
    }
    . $script:FunctionsPath

    # Guard: the function under test must be defined by the shared file. If a
    # future change renames or removes it, fail loudly here rather than with a
    # confusing "command not found" mid-test.
    if (-not (Get-Command 'Write-RdaProgress' -CommandType Function -ErrorAction SilentlyContinue))
    {
        throw "Expected function 'Write-RdaProgress' to be defined by $script:FunctionsPath, but it was not. Has it been renamed or removed?"
    }

    $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
    $script:TestRoot = Join-Path $TmpBase ("ProgressTest_" + [guid]::NewGuid().ToString().Substring(0, 8))
    New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null

    # Helper: capture only the plain-text host line(s) the function writes to the
    # Information stream (stream 6), as an array of strings. Returns @() when the
    # function wrote nothing (e.g. -BarOnly or -Completed). Callers should wrap
    # the invocation in @() (see file header note).
    function Get-RdaProgressLines
    {
        param([scriptblock] $Call)
        $Records = & $Call 6>&1
        @($Records | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } |
                ForEach-Object { $_.MessageData.Message })
    }
}

AfterAll {
    if ($script:TestRoot -and (Test-Path $script:TestRoot))
    {
        Remove-Item -Path $script:TestRoot -Recurse -Force
    }
}

Describe 'Write-RdaProgress' {

    BeforeAll {
        # Mock the bar so the console-host render is suppressed during tests and
        # its arguments are captured for assertion. Effective for every It below.
        Mock Write-Progress { }
    }

    Context 'Scenario 1: Determinate loop (Run-AllSubscriptions per-subscription)' {

        It 'renders a percent bar and an "(index of total)" status' {
            Write-RdaProgress -Activity 'Processing subscriptions' -CurrentItem 'Sub-Prod-01' -Index 1 -Total 4
            Should -Invoke Write-Progress -Times 1 -Exactly -ParameterFilter {
                $Activity -eq 'Processing subscriptions' -and
                $PercentComplete -eq 25 -and
                $Status -eq 'Sub-Prod-01 (1 of 4)'
            }
        }

        It 'advances the percent as the index grows' {
            Write-RdaProgress -Activity 'Processing subscriptions' -CurrentItem 'Sub-Prod-03' -Index 3 -Total 4
            Should -Invoke Write-Progress -Times 1 -Exactly -ParameterFilter {
                $PercentComplete -eq 75 -and $Status -eq 'Sub-Prod-03 (3 of 4)'
            }
        }
    }

    Context 'Scenario 2: Count-only loop (total not known up front)' {

        It 'renders an "(index)" status with NO percent' {
            Write-RdaProgress -Activity 'Discovering' -CurrentItem 'item-x' -Index 3
            Should -Invoke Write-Progress -Times 1 -Exactly -ParameterFilter {
                $Status -eq 'item-x (3)' -and -not $PSBoundParameters.ContainsKey('PercentComplete')
            }
        }
    }

    Context 'Scenario 3: Interactive-loop fallback line (subscription / reveal)' {

        It 'emits a plain "Activity: Status" host line when forced non-interactive' {
            $Lines = @(Get-RdaProgressLines {
                    Write-RdaProgress -Activity 'Processing subscriptions' -CurrentItem 'Sub-Prod-02' -Index 2 -Total 4 -NonInteractiveLine
                })
            $Lines.Count | Should -Be 1
            $Lines[0] | Should -Be 'Processing subscriptions: Sub-Prod-02 (2 of 4)'
        }

        It 'still renders the bar alongside the fallback line' {
            Write-RdaProgress -Activity 'Processing subscriptions' -CurrentItem 'Sub-Prod-02' -Index 2 -Total 4 -NonInteractiveLine 6>$null
            Should -Invoke Write-Progress -Times 1 -Exactly -ParameterFilter { $PercentComplete -eq 50 }
        }
    }

    Context 'Scenario 4: High-frequency bar-only loop (collectors / metrics)' {

        It 'renders the bar but SUPPRESSES the plain host line under -BarOnly' {
            $Lines = @(Get-RdaProgressLines {
                    Write-RdaProgress -Activity 'Service Processing' -CurrentItem 'Compute' -Index 5 -Total 30 -BarOnly
                })
            $Lines.Count | Should -Be 0
        }

        It 'suppresses the line even when -NonInteractiveLine is also passed (BarOnly wins)' {
            # [int](250 / 900 * 100) = [int](27.77..) rounds to 28 (the implementation
            # rounds by design); this is the one non-exact percent in the suite.
            $Lines = @(Get-RdaProgressLines {
                    Write-RdaProgress -Activity 'Metrics collection' -CurrentItem 'batch 1 (250 call(s))' -Index 250 -Total 900 -BarOnly -NonInteractiveLine
                })
            $Lines.Count | Should -Be 0
            Should -Invoke Write-Progress -Times 1 -Exactly -ParameterFilter { $PercentComplete -eq 28 }
        }
    }

    Context 'Scenario 5: Durable heartbeat log (long unattended runs)' {

        It 'appends a timestamped Activity/Status line to the heartbeat file' {
            $HbFile = Join-Path $script:TestRoot ('hb_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.log')
            Write-RdaProgress -Activity 'Processing subscriptions' -CurrentItem 'Sub-Prod-01' -Index 1 -Total 4 -HeartbeatLogFile $HbFile -BarOnly
            Test-Path $HbFile | Should -BeTrue
            $Content = Get-Content $HbFile -Raw
            $Content | Should -Match 'Processing subscriptions: Sub-Prod-01 \(1 of 4\)'
            $Content | Should -Match '^\[\d{2}-\d{2}-\d{4} \d{2}:\d{2}:\d{2}\]'
        }

        It 'accumulates one heartbeat line per call' {
            $HbFile = Join-Path $script:TestRoot ('hb_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.log')
            1..3 | ForEach-Object {
                Write-RdaProgress -Activity 'Revealing reports' -CurrentItem ("folder-$_") -Index $_ -Total 3 -HeartbeatLogFile $HbFile -BarOnly
            }
            (Get-Content $HbFile).Count | Should -Be 3
        }

        It 'never throws when the heartbeat file cannot be written (best-effort)' {
            # The run-safety contract is that a heartbeat write failure is swallowed so
            # a long unattended run is never killed by a transient/broken log path.
            # Point at a path whose parent directory does not exist so Add-Content throws.
            $Unwritable = Join-Path (Join-Path $script:TestRoot ('no-such-dir_' + [guid]::NewGuid().ToString('N').Substring(0, 8))) 'hb.log'
            { Write-RdaProgress -Activity 'Processing subscriptions' -CurrentItem 'Sub-Prod-01' -Index 1 -Total 4 -HeartbeatLogFile $Unwritable -BarOnly } | Should -Not -Throw
        }
    }

    Context 'Scenario 6: Completion (clears the bar after a loop)' {

        It 'invokes Write-Progress -Completed and writes no fallback line' {
            $Lines = @(Get-RdaProgressLines {
                    Write-RdaProgress -Activity 'Processing subscriptions' -Completed -NonInteractiveLine
                })
            $Lines.Count | Should -Be 0
            Should -Invoke Write-Progress -Times 1 -Exactly -ParameterFilter { $Completed -eq $true }
        }

        It 'logs a "complete (N item(s))" line to the heartbeat file' {
            $HbFile = Join-Path $script:TestRoot ('hb_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.log')
            Write-RdaProgress -Activity 'Metrics collection' -Total 900 -Completed -HeartbeatLogFile $HbFile
            (Get-Content $HbFile -Raw) | Should -Match 'Metrics collection: complete \(900 item\(s\)\)'
        }

        It 'uses the final -Index for the completion count in count-only mode (Total omitted)' {
            # In count-only mode $Total is 0, so the completion line must fall back to
            # the final -Index instead of logging 'complete (0 item(s))' regardless of
            # how many items the loop processed.
            $HbFile = Join-Path $script:TestRoot ('hb_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.log')
            Write-RdaProgress -Activity 'Scanning bundles' -Index 42 -Completed -HeartbeatLogFile $HbFile
            (Get-Content $HbFile -Raw) | Should -Match 'Scanning bundles: complete \(42 item\(s\)\)'
        }
    }

    Context 'Scenario 7: Percent bounds are clamped to 0..100' {

        It 'clamps to 100 when the index overshoots the total' {
            Write-RdaProgress -Activity 'X' -CurrentItem 'over' -Index 10 -Total 4
            Should -Invoke Write-Progress -Times 1 -Exactly -ParameterFilter { $PercentComplete -eq 100 }
        }

        It 'reports 0 percent at the start of a loop (index 0)' {
            Write-RdaProgress -Activity 'X' -CurrentItem 'start' -Index 0 -Total 4
            Should -Invoke Write-Progress -Times 1 -Exactly -ParameterFilter { $PercentComplete -eq 0 }
        }

        It 'clamps to 0 when the index is negative (exercises the 0-floor)' {
            # index 0 reaches 0 by exact arithmetic (0/4*100), so it never exercises the
            # 'if ($Percent -lt 0) { $Percent = 0 }' lower-bound guard. A negative index
            # produces a negative raw percent, which the clamp must floor to 0.
            Write-RdaProgress -Activity 'X' -CurrentItem 'under' -Index -1 -Total 4
            Should -Invoke Write-Progress -Times 1 -Exactly -ParameterFilter { $PercentComplete -eq 0 }
        }
    }

    Context 'Scenario 8: Reveal -Resume (enriched item label reused, same function)' {

        It 'carries a caller-enriched "(already revealed)" label into the status' {
            $Lines = @(Get-RdaProgressLines {
                    Write-RdaProgress -Activity 'Revealing reports' -CurrentItem 'Sub-Prod-40 (already revealed)' -Index 40 -Total 100 -NonInteractiveLine
                })
            $Lines[0] | Should -Be 'Revealing reports: Sub-Prod-40 (already revealed) (40 of 100)'
            Should -Invoke Write-Progress -Times 1 -Exactly -ParameterFilter {
                $Status -eq 'Sub-Prod-40 (already revealed) (40 of 100)'
            }
        }
    }
}
