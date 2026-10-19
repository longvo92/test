@echo off
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Run-Baseline.ps1" %*
set "EVCC_EXIT=%ERRORLEVEL%"
if not "%EVCC_EXIT%"=="0" if "%~1"=="" pause
exit /b %EVCC_EXIT%
