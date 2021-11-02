@echo off

:: set correct working dir when running as admin
cd /D "%~dp0"

if "%1" == "" PowerShell -NoProfile -ExecutionPolicy Bypass -Command "& .\build\bootstrapper\bootstrapper.ps1;exit $LASTEXITCODE"
if NOT "%1" == ""  (
    if NOT "%2" == "" PowerShell -NoProfile -ExecutionPolicy Bypass -Command "& .\build\bootstrapper\bootstrapper.ps1 -runType %1 %2;exit $LASTEXITCODE"
    if "%2" == "" PowerShell -NoProfile -ExecutionPolicy Bypass -Command "& .\build\bootstrapper\bootstrapper.ps1 -runType %1;exit $LASTEXITCODE"
)

IF "%ERRORLEVEL%" EQU "3010" (
    echo One or more packages that was upgraded or installed requested a reboot of the system.
	exit /b %errorlevel%
) 
IF "%ERRORLEVEL%" EQU "1641" (
    echo One or more packages that was upgraded or installed has initiated a reboot of the system.
	exit /b %errorlevel%
) 
IF %ERRORLEVEL% NEQ 0 (
    echo Bootstrapper exited with errorcode %errorlevel%
    if _%interactive%_==_0_ pause
    exit /b %errorlevel%
)