@echo off
rem ---------------------------------------------------------------------------
rem Morning notification batch. Runs once and exits.
rem Fired daily at 08:00 by the "AI-Hisho-DailyNotify" scheduled task.
rem ASCII only on purpose: cmd.exe misreads non-ASCII .bat files.
rem ---------------------------------------------------------------------------
setlocal
pushd "%~dp0.."
set "ROOT=%CD%"
set "PYTHONUTF8=1"
set "PYTHONIOENCODING=utf-8"
set "PYTHONUNBUFFERED=1"
set "LOG=%ROOT%\logs\notifier.log"

if not exist "%ROOT%\logs" mkdir "%ROOT%\logs"
for %%F in ("%LOG%") do if %%~zF GTR 5000000 move /y "%LOG%" "%LOG%.old" >nul 2>&1

echo [%date% %time%] --- notifier start --->> "%LOG%"
"%ROOT%\.venv\Scripts\python.exe" -m src.notifier >> "%LOG%" 2>&1
echo [%date% %time%] --- notifier end (code %ERRORLEVEL%) --->> "%LOG%"
