@echo off
chcp 65001 >nul
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Check-Provider.ps1" %*
echo.
pause
