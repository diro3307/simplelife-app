<#
.SYNOPSIS
  Quick-launch the SimpleLife app. Creates the venv and installs deps on first run.

.PARAMETER Reinstall
  Force pip install -e . even if simplelife-app is already importable.

.PARAMETER Host
  Bind address. Default 127.0.0.1.

.PARAMETER Port
  Bind port. Default 8000.

.EXAMPLE
  .\scripts\run.ps1
  .\scripts\run.ps1 -Port 8080
  .\scripts\run.ps1 -Reinstall
#>
param(
    [switch]$Reinstall,
    [string]$BindHost = "127.0.0.1",
    [int]$Port = 8000
)

$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $PSScriptRoot
$venv = Join-Path $root ".venv"
$py   = Join-Path $venv "Scripts\python.exe"

if (-not (Test-Path $py)) {
    Write-Host "==> Creating venv at $venv" -ForegroundColor Cyan
    python -m venv $venv
    if ($LASTEXITCODE -ne 0) { Write-Host "venv creation failed" -ForegroundColor Red; exit 1 }
}

# Probe for the package; install (or reinstall) if missing or -Reinstall passed.
& $py -c "import webapp.main" 2>$null
if ($LASTEXITCODE -ne 0 -or $Reinstall) {
    Write-Host "==> Installing simplelife-app (editable) into venv" -ForegroundColor Cyan
    & $py -m pip install --upgrade pip
    & $py -m pip install -e $root
    if ($LASTEXITCODE -ne 0) { Write-Host "pip install failed" -ForegroundColor Red; exit 1 }
} else {
    Write-Host "==> Deps already installed (use -Reinstall to force)" -ForegroundColor DarkGray
}

$env:WEBAPP_HOST = $BindHost
$env:WEBAPP_PORT = "$Port"

Write-Host "==> Launching on http://${BindHost}:${Port}/" -ForegroundColor Cyan
Write-Host "    Ctrl+C to stop." -ForegroundColor DarkGray
& $py -m webapp.main
