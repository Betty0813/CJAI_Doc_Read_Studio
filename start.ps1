Set-Location $PSScriptRoot

Write-Host "=== AI Doc Read Studio (Cangjie-only) ===" -ForegroundColor Cyan
Write-Host "[INFO] Starting Cangjie backend (serves the frontend too)..." -ForegroundColor Green

PowerShell -NoProfile -ExecutionPolicy Bypass -File ".\cangjie-backend\start.ps1"

