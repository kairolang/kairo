@echo off
setlocal enabledelayedexpansion

set PY=
for %%P in (python python3 py) do (
    where %%P >nul 2>&1
    if not errorlevel 1 (
        set PY=%%P
        goto :found
    )
)

echo Error: Python not found on PATH
exit /b 1

:found
%PY% "%~dp0scripts\build.py" %*
endlocal
