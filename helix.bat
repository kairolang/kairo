@echo off
setlocal enabledelayedexpansion

rem Initialize an empty variable to collect the remaining arguments
set "ARGS="

rem Check if the first argument is '--'
if "%1"=="--" (
    rem Shift to remove the '--'
    shift
) else (
    rem Build the Helix project using xmake
    xmake
)

rem Collect all the remaining arguments after '--'
:loop
if "%1"=="" goto endloop
    set "ARGS=!ARGS! %1"
    shift
    goto loop

:endloop

rem Get the path of the binary using xmake and filter by targetfile
for /f "tokens=3" %%a in ('xmake show -t helix ^| findstr "targetfile"') do (
    set "RAW_PATH=%%a"
)

rem Strip ANSI color codes and non-printable characters using PowerShell
for /f %%b in ('powershell -command "$input = '%RAW_PATH%'; $cleanPath = $input -replace '\x1B\[[0-9;]*[a-zA-Z]', ''; $cleanPath.Trim()"') do (
    set "PATH_TO_BINARY=%%b"
)

rem Convert to an absolute path using for loop to append to current directory
for %%i in ("%cd%\%PATH_TO_BINARY%") do set "ABS_PATH=%%~fi"

rem Run the binary with the remaining arguments
%ABS_PATH% %ARGS%

endlocal