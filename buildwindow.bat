@echo off

:: set correct working dir when running as admin
cd /D "%~dp0"

:: Determine if called interactively or from cmd.exe
set interactive=1
echo %cmdcmdline% | find /i "%~0" > nul
if not errorlevel 1 set interactive=0

:: filter --skipboot from params and change runtype if specified
set skipbootstrapper="--skipboot"
set runtype="checkhost"
set forceUpdateSwitch="--forceUpdate"
set forceUpdate=
set params=
set var=0
:nextparam
set /A var=%var% + 1
for /F "tokens=%var% delims= " %%A in ("%*") do (
	IF "%%~A"==%forceUpdateSwitch% (
		set forceUpdate="-forceUpdate"
	) ELSE (
		IF "%%~A"==%skipbootstrapper% (
			set runtype="skip"
		) ELSE (
			set "params=%params%%%A "
		)
	)
    goto nextparam
)

PowerShell -NoProfile -ExecutionPolicy Bypass -Command "& .\build\bootstrapper\bootstrapper.ps1 -runtype '%runtype%' %forceUpdate%;exit $LASTEXITCODE"
call RefreshEnv.cmd

setlocal
cd build
dotnet-script --no-cache build.csx -- %params%

IF %ERRORLEVEL% NEQ 0 (
    echo Buildscript exited with errorcode %errorlevel%
    if _%interactive%_==_0_ pause
    exit /b %errorlevel%
)