@echo off
setlocal EnableExtensions
cd /d "%~dp0"
if exist "dist\ScriptIX.exe" goto :start
echo The app is not built yet. Building it first...
call "%~dp0build.bat"
if exist "dist\ScriptIX.exe" goto :start
echo.
echo The app was not built. See build_log.txt for the reason.
goto :end

:start
start "" "dist\ScriptIX.exe"
echo ScriptIX started.

:end
echo.
pause
endlocal
