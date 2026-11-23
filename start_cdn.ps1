$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$dartPath = "C:\flutter\bin\cache\dart-sdk\bin\dart.exe"
if (-not (Test-Path $dartPath)) {
    $dartPath = "dart"
}

Write-Host "Starting CDN Lab Server..." -ForegroundColor Cyan
& $dartPath run cdn_lab.dart

