@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0claudex.ps1" %*
exit /b %ERRORLEVEL%
