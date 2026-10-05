@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Verify.ps1"
set "volisle_exit=%ERRORLEVEL%"
echo.
echo Exit code: %volisle_exit%
pause
exit /b %volisle_exit%
