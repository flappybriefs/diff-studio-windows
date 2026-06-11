$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ProjectRoot

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
  Write-Error "Flutter is not installed or not in PATH. Install Flutter for Windows first: https://docs.flutter.dev/get-started/install/windows"
}

flutter config --enable-windows-desktop

if (-not (Test-Path ".\windows")) {
  flutter create --platforms=windows .
}

flutter pub get

Write-Host ""
Write-Host "Diff Studio Flutter is ready."
Write-Host "Run:   .\run_windows.ps1"
Write-Host "Build: .\build_windows.ps1"
