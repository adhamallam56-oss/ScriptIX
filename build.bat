@echo off
setlocal EnableExtensions
cd /d "%~dp0"
set "LOG=%~dp0build_log.txt"
> "%LOG%" echo ScriptIX build started %date% %time%

echo [1/4] Checking for the .NET SDK...
where dotnet >nul 2>&1
if errorlevel 1 goto :nodotnet
set "MAJOR="
for /f "tokens=1 delims=." %%v in ('dotnet --version 2^>nul') do set "MAJOR=%%v"
if not defined MAJOR goto :nodotnet
if %MAJOR% LSS 8 goto :oldsdk
echo       Found .NET SDK %MAJOR%.x

echo [2/4] Restoring packages...
dotnet restore "ScriptIX.sln" >> "%LOG%" 2>&1
if errorlevel 1 goto :fail_restore

echo [3/4] Building (Release)...
dotnet build "ScriptIX.sln" -c Release --no-restore >> "%LOG%" 2>&1
if errorlevel 1 goto :fail_build

echo [4/4] Publishing ScriptIX.exe and scriptix-cli.exe (command line)...
dotnet publish "src\ScriptIX.App\ScriptIX.App.csproj" -c Release -r win-x64 --self-contained false -p:PublishSingleFile=true -o "%~dp0dist" >> "%LOG%" 2>&1
if errorlevel 1 goto :fail_publish
dotnet publish "src\ScriptIX.Cli\ScriptIX.Cli.csproj" -c Release -r win-x64 --self-contained false -p:PublishSingleFile=true -o "%~dp0dist" >> "%LOG%" 2>&1
if errorlevel 1 goto :fail_publish
if exist "dist\*.pdb" del /q "dist\*.pdb"

>> "%LOG%" echo Build finished OK
echo.
echo DONE. Your app is here:
echo   %~dp0dist\ScriptIX.exe
echo Command line version:
echo   %~dp0dist\scriptix-cli.exe
echo (Details are in build_log.txt)
echo.
choice /m "Open the folder now"
if errorlevel 2 goto :end
start "" "%~dp0dist"
goto :end

:nodotnet
echo.
echo ERROR: the .NET 8 SDK was not found.
echo Install it from https://dotnet.microsoft.com/download/dotnet/8.0
echo then double-click build.bat again.
goto :end

:oldsdk
echo.
echo ERROR: .NET SDK %MAJOR% is too old. Version 8 or newer is needed.
echo Install it from https://dotnet.microsoft.com/download/dotnet/8.0
goto :end

:fail_restore
echo.
echo ERROR: restore failed. Check your internet connection and try again.
goto :showlog

:fail_build
echo.
echo ERROR: the build failed. The log below shows the reason.
goto :showlog

:fail_publish
echo.
echo ERROR: publishing failed. The log below shows the reason.
goto :showlog

:showlog
echo.
echo ---------------- build_log.txt ----------------
type "%LOG%"
echo -----------------------------------------------
echo Full log saved at: %LOG%
goto :end

:end
echo.
pause
endlocal
