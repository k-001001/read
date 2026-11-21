@echo off
setlocal
cd /d "%~dp0"
if not exist "%~dp0github_sync.ps1" (
    echo ERROR: github_sync.ps1 was not found in this folder.
    pause
    exit /b 1
)
where git.exe >nul 2>nul
if errorlevel 1 (
    if exist "%ProgramFiles%\Git\cmd\git.exe" set "PATH=%ProgramFiles%\Git\cmd;%PATH%"
)
where git.exe >nul 2>nul
if errorlevel 1 (
    if exist "%LOCALAPPDATA%\Programs\Git\cmd\git.exe" set "PATH=%LOCALAPPDATA%\Programs\Git\cmd;%PATH%"
)
where git.exe >nul 2>nul
if errorlevel 1 (
    if exist "%USERPROFILE%\.cache\codex-runtimes\codex-primary-runtime\dependencies\native\git\cmd\git.exe" set "PATH=%USERPROFILE%\.cache\codex-runtimes\codex-primary-runtime\dependencies\native\git\cmd;%PATH%"
)
where git.exe >nul 2>nul
if errorlevel 1 (
    echo ERROR: Git was not found. Ask Codex to check the Git installation path.
    pause
    exit /b 1
)
where pwsh.exe >nul 2>nul
if %errorlevel% equ 0 (
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0github_sync.ps1"
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0github_sync.ps1"
)
if errorlevel 1 (
    echo PowerShell returned an error. Please check the message above.
    pause
    exit /b 1
)
endlocal
