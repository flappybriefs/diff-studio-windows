$ErrorActionPreference = "Stop"

function Require-Winget {
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Error "winget is not available. Please install App Installer from Microsoft Store, then run this script again."
  }
}

function Install-WingetPackage($Id, $Name, $ExtraArgs = @()) {
  Write-Host "Checking $Name..." -ForegroundColor Cyan
  $existing = winget list --id $Id --exact --accept-source-agreements 2>$null
  if ($LASTEXITCODE -eq 0 -and $existing -match [regex]::Escape($Id)) {
    Write-Host "$Name is already installed." -ForegroundColor Green
    return
  }

  Write-Host "Installing $Name..." -ForegroundColor Cyan
  winget install --id $Id --exact --accept-source-agreements --accept-package-agreements @ExtraArgs
}

$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ProjectRoot

Write-Host "== Diff Studio Windows build environment setup ==" -ForegroundColor Cyan

Require-Winget

Install-WingetPackage "Git.Git" "Git"
Install-WingetPackage "Flutter.Flutter" "Flutter"
Install-WingetPackage `
  "Microsoft.VisualStudio.2022.BuildTools" `
  "Visual Studio 2022 Build Tools" `
  @("--override", "--wait --passive --add Microsoft.VisualStudio.Workload.NativeDesktop --includeRecommended")

Write-Host ""
Write-Host "The build tools were installed or were already available." -ForegroundColor Green
Write-Host "Close and reopen PowerShell so PATH changes take effect, then run:"
Write-Host "  powershell -ExecutionPolicy Bypass -File .\build_windows.ps1"
