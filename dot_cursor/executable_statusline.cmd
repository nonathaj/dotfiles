@echo off
rem -- Launch the Cursor CLI statusline through Git Bash --
rem Resolves Git Bash dynamically (no hardcoded install path):
rem   1) derive <git-root>\bin\bash.exe from `where git` on PATH
rem   2) fall back to common Git for Windows install locations
rem The .sh is found relative to this file (%~dp0); stdin (the statusline
rem JSON) is inherited by bash automatically.
setlocal

set "BASH="
for /f "delims=" %%g in ('where git 2^>nul') do if not defined GITEXE set "GITEXE=%%g"
if defined GITEXE for %%i in ("%GITEXE%") do set "GITCMDDIR=%%~dpi"
if defined GITCMDDIR if exist "%GITCMDDIR%..\bin\bash.exe" set "BASH=%GITCMDDIR%..\bin\bash.exe"

if not defined BASH if exist "%ProgramFiles%\Git\bin\bash.exe" set "BASH=%ProgramFiles%\Git\bin\bash.exe"
if not defined BASH if exist "%ProgramFiles(x86)%\Git\bin\bash.exe" set "BASH=%ProgramFiles(x86)%\Git\bin\bash.exe"
if not defined BASH if exist "%LocalAppData%\Programs\Git\bin\bash.exe" set "BASH=%LocalAppData%\Programs\Git\bin\bash.exe"

rem Git Bash not found: exit 0 with no output so the CLI just shows no statusline
if not defined BASH exit /b 0

set "HERE=%~dp0"
set "HERE=%HERE:\=/%"
"%BASH%" "%HERE%statusline.sh"
exit /b %errorlevel%
