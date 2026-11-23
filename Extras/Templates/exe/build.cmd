@echo off
rem Builds {{name}} with kairo on Windows; no make needed.
rem
rem   build.cmd            the debug program, build\debug\{{name}}.exe
rem   build.cmd release    the optimized program, build\release\{{name}}.exe
rem   build.cmd run        builds the debug program and runs it
rem   build.cmd clean      removes build\
rem
rem KAIRO names the compiler (default: kairo on PATH), CACHE the object cache.

setlocal
set "NAME={{name}}"
if not defined KAIRO set "KAIRO=kairo"
if not defined CACHE set "CACHE=build\cache"
set "FLAGS=-I include --cache-dir %CACHE%"

set "MODE=%~1"
if "%MODE%"=="" set "MODE=debug"
if /i "%MODE%"=="debug" goto debug
if /i "%MODE%"=="release" goto release
if /i "%MODE%"=="run" goto run
if /i "%MODE%"=="clean" goto clean
echo usage: build.cmd [debug^|release^|run^|clean] 1>&2
exit /b 2

:debug
if not exist build\debug mkdir build\debug
if not exist "%CACHE%" mkdir "%CACHE%"
"%KAIRO%" source\main.k %FLAGS% -O0 -g -o build\debug\%NAME%.exe
exit /b %errorlevel%

:release
if not exist build\release mkdir build\release
if not exist "%CACHE%" mkdir "%CACHE%"
"%KAIRO%" source\main.k %FLAGS% -O2 -o build\release\%NAME%.exe
exit /b %errorlevel%

:run
call "%~f0" debug || exit /b 1
build\debug\%NAME%.exe
exit /b %errorlevel%

:clean
if exist build rmdir /s /q build
exit /b 0
