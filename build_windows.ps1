$ErrorActionPreference = "Stop"

function Require-Command($Name, $InstallHint) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    Write-Error "$Name is not available. $InstallHint"
  }
}

$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ProjectRoot

Write-Host "== Diff Studio Windows build ==" -ForegroundColor Cyan

Require-Command "flutter" "Install Flutter for Windows first: https://docs.flutter.dev/get-started/install/windows"

flutter config --enable-windows-desktop

if (-not (Test-Path ".\windows")) {
  Write-Host "Generating Windows runner..." -ForegroundColor Cyan
  flutter create --platforms=windows .
}

Write-Host "Fetching dependencies..." -ForegroundColor Cyan
flutter pub get

Write-Host "Checking Flutter Windows toolchain..." -ForegroundColor Cyan
flutter doctor -v

Write-Host "Building release executable..." -ForegroundColor Cyan
flutter build windows --release

$ReleaseDir = Join-Path $ProjectRoot "build\windows\x64\runner\Release"
if (-not (Test-Path $ReleaseDir)) {
  Write-Error "Release output was not found: $ReleaseDir"
}

$DistDir = Join-Path $ProjectRoot "dist"
$PackageDir = Join-Path $DistDir "DiffStudio-Windows"
$ZipPath = Join-Path $DistDir "DiffStudio-Windows.zip"

if (Test-Path $PackageDir) {
  Remove-Item $PackageDir -Recurse -Force
}
if (Test-Path $ZipPath) {
  Remove-Item $ZipPath -Force
}

New-Item -ItemType Directory -Path $PackageDir -Force | Out-Null
Copy-Item -Path (Join-Path $ReleaseDir "*") -Destination $PackageDir -Recurse -Force

Compress-Archive -Path (Join-Path $PackageDir "*") -DestinationPath $ZipPath -Force

Write-Host ""
Write-Host "Build complete." -ForegroundColor Green
Write-Host "Executable folder: $PackageDir"
Write-Host "Zip package:       $ZipPath"
Write-Host "Run:               $PackageDir\diff_studio_flutter.exe"
