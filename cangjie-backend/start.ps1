# AI Doc Read Studio - Cangjie Backend 启动脚本
# 确保已安装 Cangjie SDK 并配置好环境变量
#
# 正确运行方式（任选其一）：
#   1. 在 PowerShell 里：cd 到 cangjie-backend 后执行 .\start.ps1
#   2. 双击 run.cmd（会真正执行脚本，不会用笔记本/编辑器打开）

Set-Location $PSScriptRoot

Write-Host "=== AI Doc Read Studio (Cangjie Backend) ===" -ForegroundColor Cyan

# 检查 .env 文件
if (!(Test-Path "../.env")) {
    Write-Host "[WARN] .env file not found. Copy .env.example to .env and set OPENAI_API_KEY" -ForegroundColor Yellow
}

# 创建必要目录
New-Item -ItemType Directory -Force -Path "../uploads" | Out-Null
New-Item -ItemType Directory -Force -Path "../sessions" | Out-Null
New-Item -ItemType Directory -Force -Path "../logs" | Out-Null

# 编译
Write-Host "[INFO] Compiling Cangjie backend..." -ForegroundColor Green
cjpm build

if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Compilation failed!" -ForegroundColor Red
    exit 1
}

# 运行
Write-Host "[INFO] Starting server on http://0.0.0.0:8000 ..." -ForegroundColor Green
cjpm run
