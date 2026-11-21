@echo off
setlocal DisableDelayedExpansion
where pwsh.exe >nul 2>nul
if errorlevel 1 (
    set "SYNC_SHELL=powershell.exe"
) else (
    set "SYNC_SHELL=pwsh.exe"
)
"%SYNC_SHELL%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0github_sync.ps1" %*
set "SYNC_EXIT=%ERRORLEVEL%"
if not "%SYNC_EXIT%"=="0" pause
exit /b %SYNC_EXIT%
