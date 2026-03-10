Set-Location $PSScriptRoot

Write-Host "=== AI Doc Read Studio (Cangjie Backend) ===" -ForegroundColor Cyan

$binDir = Join-Path $PSScriptRoot "target\release\bin"
$backendExe = Join-Path $binDir "main.exe"

function Stop-RunningBackendByPath {
    param(
        [Parameter(Mandatory = $true)][string]$ExePath
    )

    $resolved = Resolve-Path -LiteralPath $ExePath -ErrorAction SilentlyContinue
    $exe = if ($resolved) { $resolved.Path } else { $ExePath }

    # NOTE: Avoid WMI/Get-CimInstance here (can hang on some systems).
    $maxAttempts = 12
    for ($i = 1; $i -le $maxAttempts; $i++) {
        $pids = @()
        try {
            $procs = Get-Process -Name "main" -ErrorAction SilentlyContinue
            foreach ($p in $procs) {
                # Path may require admin; treat missing path as match by name only.
                if (-not $p.Path -or ($p.Path -ieq $exe)) {
                    $pids += $p.Id
                }
            }
        } catch { }

        if (-not $pids -or $pids.Count -eq 0) {
            return
        }

        if ($i -eq 1) {
            Write-Host "[INFO] Stopping running backend (releases main.exe / OpenSSL DLL locks)..." -ForegroundColor Yellow
        }

        foreach ($procId in $pids) {
            try { Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue } catch { }
        }
        Start-Sleep -Milliseconds (250 + 250 * $i)
    }

    try {
        $still = Get-Process -Name "main" -ErrorAction SilentlyContinue | Where-Object { -not $_.Path -or ($_.Path -ieq $exe) }
        if ($still) {
            Write-Host "[ERROR] Backend is still running and locking build outputs: $exe" -ForegroundColor Red
            Write-Host "        Close the running server terminal (or kill the process) then retry." -ForegroundColor Red
            exit 1
        }
    } catch { }
}

function Copy-WithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Dest,
        [int]$Attempts = 6
    )

    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            Copy-Item -LiteralPath $Source -Destination $Dest -Force -ErrorAction Stop
            return $true
        } catch {
            if ($i -eq $Attempts) {
                Write-Host "[WARN] Copy failed (likely locked): $Dest. Keeping existing file." -ForegroundColor Yellow
                return $false
            }
            Start-Sleep -Milliseconds (200 * $i)
        }
    }
    return $false
}

# Stop previous instance (prevents Permission denied on link step and DLL copy failures)
Stop-RunningBackendByPath -ExePath $backendExe

# Check .env exists at repo root
if (!(Test-Path "..\.env")) {
    Write-Host "[WARN] .env not found at repo root. Copy .env.example to .env and set OPENAI_API_KEY." -ForegroundColor Yellow
}

# Runtime directories (relative to cangjie-backend/)
New-Item -ItemType Directory -Force -Path ".\uploads" | Out-Null
New-Item -ItemType Directory -Force -Path ".\sessions" | Out-Null
New-Item -ItemType Directory -Force -Path ".\logs" | Out-Null

# CA bundle for TLS
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

# Ensure OpenSSL 3 DLLs next to the built exe (Cangjie TLS needs them)
$opensslSources = @(
    "C:\Program Files\MySQL\MySQL Server 8.0\bin",
    "C:\Program Files\OpenSSL-Win64\bin"
)
foreach ($src in $opensslSources) {
    if (!(Test-Path $src)) { continue }
    # Avoid -Recurse (can be slow). These DLLs should exist directly in the bin folder.
    $sslPath = Join-Path $src "libssl-3-x64.dll"
    $cryptoPath = Join-Path $src "libcrypto-3-x64.dll"
    $ssl = if (Test-Path $sslPath) { Get-Item $sslPath -ErrorAction SilentlyContinue } else { $null }
    $crypto = if (Test-Path $cryptoPath) { Get-Item $cryptoPath -ErrorAction SilentlyContinue } else { $null }
    if ($ssl -and $crypto) {
        New-Item -ItemType Directory -Force -Path $binDir | Out-Null
        Copy-WithRetry -Source $ssl.FullName -Dest (Join-Path $binDir "libssl.dll") | Out-Null
        Copy-WithRetry -Source $ssl.FullName -Dest (Join-Path $binDir "libssl-3-x64.dll") | Out-Null
        Copy-WithRetry -Source $crypto.FullName -Dest (Join-Path $binDir "libcrypto.dll") | Out-Null
        Copy-WithRetry -Source $crypto.FullName -Dest (Join-Path $binDir "libcrypto-3-x64.dll") | Out-Null
        Write-Host "[INFO] OpenSSL 3 DLLs copied from $src" -ForegroundColor Green
        break
    }
}

# Find Cangjie SDK root and add all required paths to PATH
$cangjieRoots = @("D:\Cangjie", "C:\Cangjie")
$cjpmExe = $null
foreach ($root in $cangjieRoots) {
    $candidate = Join-Path $root "tools\bin\cjpm.exe"
    if (Test-Path $candidate) {
        $cjpmExe = $candidate
        $dirsToAdd = @(
            (Join-Path $root "tools\bin"),
            (Join-Path $root "bin"),
            (Join-Path $root "runtime\lib\windows_x86_64_llvm"),
            (Join-Path $root "third_party\llvm\bin"),
            (Join-Path $root "third_party\mingw\bin")
        )
        foreach ($d in $dirsToAdd) {
            if ((Test-Path $d) -and ($env:PATH -notlike "*$d*")) {
                $env:PATH = "$d;" + $env:PATH
            }
        }
        Write-Host "[INFO] Cangjie SDK found at: $root" -ForegroundColor Green
        break
    }
}
if (-not $cjpmExe) {
    Write-Host "[ERROR] Cannot find cjpm.exe. Please install Cangjie SDK to D:\Cangjie or C:\Cangjie." -ForegroundColor Red
    exit 1
}

Write-Host "[INFO] Compiling Cangjie backend..." -ForegroundColor Green
Stop-RunningBackendByPath -ExePath $backendExe

if (Test-Path $backendExe) {
    for ($i = 1; $i -le 6; $i++) {
        try {
            Remove-Item -LiteralPath $backendExe -Force -ErrorAction Stop
            break
        } catch {
            Start-Sleep -Milliseconds (200 * $i)
        }
    }
}

& $cjpmExe build
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Compilation failed!" -ForegroundColor Red
    exit 1
}

Write-Host "[INFO] Starting server on http://0.0.0.0:8000 ..." -ForegroundColor Green
& $cjpmExe run
