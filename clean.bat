@echo off
setlocal EnableExtensions
cd /d "%~dp0"
echo This deletes the bin, obj and dist folders and build_log.txt.
choice /m "Continue"
if errorlevel 2 goto :end
for %%P in (ScriptIX.Core ScriptIX.App ScriptIX.Cli) do call :wipe "src\%%P"
if exist "dist" rmdir /s /q "dist"
if exist "build_log.txt" del /q "build_log.txt"
echo Clean.
goto :end

:wipe
if exist "%~1\bin" rmdir /s /q "%~1\bin"
if exist "%~1\obj" rmdir /s /q "%~1\obj"
goto :eof

:end
echo.
pause
endlocal
