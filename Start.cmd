@echo off
setlocal
cd /d "%~dp0"
python -X utf8 "%~dp0start_switcher.py" %*
set "switcher_exit=%errorlevel%"
if not "%switcher_exit%"=="0" pause
exit /b %switcher_exit%
