@echo off
rem Windows wrapper for alarm-report.sh: runs it with Git Bash (Git for Windows).
rem Put this folder on PATH to type "alarm-report" (or "alarm-report 14") in CMD.
setlocal
set "BASH=%ProgramFiles%\Git\bin\bash.exe"
if not exist "%BASH%" for %%B in (bash.exe) do set "BASH=%%~$PATH:B"
if not exist "%BASH%" (
  echo alarm-report: Git Bash not found, install Git for Windows 1>&2
  exit /b 1
)
set "SCRIPT=%~dp0alarm-report.sh"
"%BASH%" "%SCRIPT:\=/%" %*
