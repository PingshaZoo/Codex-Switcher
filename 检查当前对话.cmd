@echo off
setlocal
cd /d "%~dp0"
python -X utf8 "%~dp0start_switcher.py" check --full %*
set "switcher_exit=%errorlevel%"
pause
exit /b %switcher_exit%
