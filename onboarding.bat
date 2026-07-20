@echo off
setlocal enabledelayedexpansion
rem Thin wrapper so onboarding works from a plain cmd.exe window.
rem onboarding.sh remains the only real implementation — this just locates
rem Git Bash and re-invokes the same script through it.

set "SCRIPT_DIR=%~dp0"
set "BASH_EXE="

rem Prefer known Git for Windows install locations over PATH: some machines
rem have a WSL launcher stub named bash.exe earlier on PATH (see fallback
rem below) which pops a "install WSL?" prompt instead of running anything.
if not defined BASH_EXE if exist "%ProgramFiles%\Git\bin\bash.exe" set "BASH_EXE=%ProgramFiles%\Git\bin\bash.exe"
if not defined BASH_EXE if exist "%ProgramFiles%\Git\usr\bin\bash.exe" set "BASH_EXE=%ProgramFiles%\Git\usr\bin\bash.exe"
if not defined BASH_EXE if exist "%LocalAppData%\Programs\Git\bin\bash.exe" set "BASH_EXE=%LocalAppData%\Programs\Git\bin\bash.exe"
if not defined BASH_EXE if exist "%LocalAppData%\Programs\Git\usr\bin\bash.exe" set "BASH_EXE=%LocalAppData%\Programs\Git\usr\bin\bash.exe"

rem Fall back to PATH, skipping any WindowsApps WSL launcher stub.
if not defined BASH_EXE (
  for /f "delims=" %%B in ('where bash 2^>nul') do (
    echo %%B | findstr /I "WindowsApps" >nul
    if errorlevel 1 if not defined BASH_EXE set "BASH_EXE=%%B"
  )
)

if not defined BASH_EXE (
  echo.
  echo   IronBank onboarding needs Git Bash, which wasn't found on this machine.
  echo   Install Git for Windows ^(bundles Git Bash^): https://gitforwindows.org
  echo   Then re-run this file — no restart needed.
  echo.
  exit /b 1
)

"%BASH_EXE%" "%SCRIPT_DIR%onboarding.sh" %*
exit /b %ERRORLEVEL%
