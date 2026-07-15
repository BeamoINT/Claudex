@echo off
node "%~dp0bin\claudex-package.mjs" %*
exit /b %ERRORLEVEL%
