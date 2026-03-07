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

# 配置 OpenSSL CA 证书包（让 TLS 可以验证 HTTPS 服务器证书）
$caBundleCandidates = @(
    "D:\miniconda\Library\ssl\cacert.pem",
    "D:\miniconda\lib\site-packages\certifi\cacert.pem",
    "C:\Program Files\Git\mingw64\ssl\certs\ca-bundle.crt",
    "C:\ProgramData\chocolatey\lib\openssl\tools\cacert.pem"
)
foreach ($ca in $caBundleCandidates) {
    if (Test-Path $ca) {
        $env:SSL_CERT_FILE = $ca
        $env:OPENSSL_CA_BUNDLE = $ca
        Write-Host "[INFO] SSL CA bundle: $ca" -ForegroundColor Green
        break
    }
}

# 确保 OpenSSL 3 DLL 在可执行文件旁边（Cangjie TLS 需要）
$binDir = Join-Path $PSScriptRoot "target\release\bin"
$opensslSources = @(
    "C:\Program Files\MySQL\MySQL Server 8.0\bin",
    "C:\Program Files\Microsoft OneDrive"
)
foreach ($src in $opensslSources) {
    $ssl = Get-ChildItem $src -Filter "libssl-3-x64.dll" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    $crypto = Get-ChildItem $src -Filter "libcrypto-3-x64.dll" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($ssl -and $crypto) {
        New-Item -ItemType Directory -Force -Path $binDir | Out-Null
        Copy-Item $ssl.FullName "$binDir\libssl.dll" -Force
        Copy-Item $ssl.FullName "$binDir\libssl-3-x64.dll" -Force
        Copy-Item $crypto.FullName "$binDir\libcrypto.dll" -Force
        Copy-Item $crypto.FullName "$binDir\libcrypto-3-x64.dll" -Force
        Write-Host "[INFO] OpenSSL 3 DLLs copied from $src" -ForegroundColor Green
        break
    }
}

# 编译
Write-Host "[INFO] Compiling Cangjie backend..." -ForegroundColor Green
cjpm build

if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Compilation failed!" -ForegroundColor Red
    exit 1
}

# 运行（SSL_CERT_FILE 已在上方设好，OpenSSL 会读取该 CA bundle）
Write-Host "[INFO] Starting server on http://0.0.0.0:8000 ..." -ForegroundColor Green
cjpm run
