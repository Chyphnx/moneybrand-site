param(
    [string]$Message = "MoneyBrand auto-deploy $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
)

$ErrorActionPreference = 'Stop'

Write-Host "=== MoneyBrand Deploy Start ===" -ForegroundColor Cyan

# Always work from the script directory
Set-Location -Path $PSScriptRoot

# Stage everything (new/changed/deleted)
git add -A

# Only commit if there is something staged
$hasChanges = $false
try {
    git diff --cached --quiet
} catch {
    # git diff --quiet exits with non-zero when there ARE changes
    $hasChanges = $true
}

if ($hasChanges) {
    Write-Host "Committing changes..." -ForegroundColor Yellow
    git commit -m $Message
} else {
    Write-Host "No changes to commit." -ForegroundColor DarkYellow
}

Write-Host "Pushing to origin/main..." -ForegroundColor Yellow
git push origin main

Write-Host "=== MoneyBrand Deploy Complete ===" -ForegroundColor Green
