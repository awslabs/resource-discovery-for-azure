# tools/install-hooks.ps1
#
# Installs the repo's git hooks (in .git-hooks/) into .git/hooks/. Run once
# after cloning. Idempotent: re-running replaces existing hooks.

[CmdletBinding()]
param(
    [switch]$Force
)

$repoRoot = git rev-parse --show-toplevel 2>$null
if (-not $repoRoot) {
    Write-Host 'ERROR: not in a git repository' -ForegroundColor Red
    exit 1
}

$srcDir = Join-Path $repoRoot '.git-hooks'
$dstDir = Join-Path $repoRoot '.git/hooks'

if (-not (Test-Path $srcDir)) {
    Write-Host "ERROR: source hook dir not found at $srcDir" -ForegroundColor Red
    exit 1
}

$hooks = @('pre-commit', 'commit-msg', 'pre-push')
foreach ($name in $hooks) {
    $src = Join-Path $srcDir $name
    $dst = Join-Path $dstDir $name

    if (-not (Test-Path $src)) {
        Write-Host "  SKIP: $name not present in source" -ForegroundColor Yellow
        continue
    }

    if ((Test-Path $dst) -and -not $Force) {
        # Compare contents - skip if identical, warn if different
        $existing = Get-Content -Path $dst -Raw -ErrorAction SilentlyContinue
        $incoming = Get-Content -Path $src -Raw -ErrorAction SilentlyContinue
        if ($existing -eq $incoming) {
            Write-Host "  ok: $name already installed and identical" -ForegroundColor DarkGray
            continue
        } else {
            Write-Host "  WARN: $name exists but differs. Re-run with -Force to replace." -ForegroundColor Yellow
            continue
        }
    }

    Copy-Item -Path $src -Destination $dst -Force
    if ($IsLinux -or $IsMacOS) {
        chmod +x $dst
    }
    Write-Host "  installed: $name" -ForegroundColor Green
}

Write-Host ''
Write-Host 'Hooks installed. Verify with:' -ForegroundColor Cyan
Write-Host '  git commit --allow-empty -m "test"   # should run pre-commit + commit-msg'
Write-Host '  git push --dry-run                   # should run pre-push'
