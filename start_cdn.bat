@echo off
cd /d "%~dp0"
echo ========================================================
echo        STARTING LOCAL CDN - LATENCY TEST LAB
echo ========================================================
echo.

set "DART_CMD=C:\flutter\bin\cache\dart-sdk\bin\dart.exe"

if not exist "%DART_CMD%" (
    set "DART_CMD=dart"
)

"%DART_CMD%" run cdn_lab.dart
pause
