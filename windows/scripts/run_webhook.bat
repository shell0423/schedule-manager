@echo off
rem ---------------------------------------------------------------------------
rem Flask webhook server, kept alive by a restart loop.
rem Launched hidden by hidden.vbs from the Startup shortcut.
rem ASCII only on purpose: cmd.exe misreads non-ASCII .bat files.
rem ---------------------------------------------------------------------------
setlocal
pushd "%~dp0.."
set "ROOT=%CD%"
set "PYTHONUTF8=1"
set "PYTHONIOENCODING=utf-8"
set "PYTHONUNBUFFERED=1"
set "LOG=%ROOT%\logs\webhook.log"

if not exist "%ROOT%\logs" mkdir "%ROOT%\logs"

:loop
rem keep the log bounded (roll over at ~5MB)
for %%F in ("%LOG%") do if %%~zF GTR 5000000 move /y "%LOG%" "%LOG%.old" >nul 2>&1
echo [%date% %time%] --- starting webhook --->> "%LOG%"
"%ROOT%\.venv\Scripts\python.exe" -m src.main >> "%LOG%" 2>&1
echo [%date% %time%] --- webhook exited (code %ERRORLEVEL%), restarting in 10s --->> "%LOG%"
rem ping instead of timeout: timeout fails when there is no console (hidden launch)
ping -n 11 127.0.0.1 >nul 2>&1
goto loop
