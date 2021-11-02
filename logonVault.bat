@echo off

title "%~dp0"

:: Determine if called interactively or from cmd.exe
set interactive=1
echo %cmdcmdline% | find /i "%~0" >nul
if not errorlevel 1 set interactive=0

:: set correct working dir when running as admin
cd /D "%~dp0"

PowerShell -NoProfile -ExecutionPolicy Bypass -Command "& .\logonVault.ps1"

IF %ERRORLEVEL% NEQ 0 (
    echo script exited with errorcode %errorlevel%
    if _%interactive%_==_0_ pause
    exit /b %errorlevel%
)