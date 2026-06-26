@echo off
setlocal
set KBLD_MODE_OVERRIDE=debug
kbld %*
exit /b %errorlevel%