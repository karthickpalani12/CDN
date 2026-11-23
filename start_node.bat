@echo off
cd /d "%~dp0\node_service"
echo ========================================================
echo        STARTING NODE.JS MEDIA BACKEND SERVICE
echo ========================================================
echo.

where node >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] Node.js is not installed or not in PATH!
    echo Please install Node.js from https://nodejs.org
    echo Then run this batch file again.
    pause
    exit /b 1
)

node server.js
pause

