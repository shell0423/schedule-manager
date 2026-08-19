@echo off
rem ---------------------------------------------------------------------------
rem ngrok tunnel (fixed domain), kept alive by a restart loop.
rem Reads NGROK_DOMAIN / WEBHOOK_PORT out of .env.
rem ASCII only on purpose: cmd.exe misreads non-ASCII .bat files.
rem ---------------------------------------------------------------------------
setlocal
pushd "%~dp0.."
set "ROOT=%CD%"
set "LOG=%ROOT%\logs\ngrok.log"
set "NGROK_DOMAIN="
set "WEBHOOK_PORT=5555"

if not exist "%ROOT%\logs" mkdir "%ROOT%\logs"

for /f "tokens=1,* delims==" %%A in ('findstr /b /i "NGROK_DOMAIN=" "%ROOT%\.env" 2^>nul') do set "NGROK_DOMAIN=%%B"
for /f "tokens=1,* delims==" %%A in ('findstr /b /i "WEBHOOK_PORT=" "%ROOT%\.env" 2^>nul') do set "WEBHOOK_PORT=%%B"

set "NGROK=%ROOT%\bin\ngrok.exe"
if not exist "%NGROK%" set "NGROK=ngrok"

if "%NGROK_DOMAIN%"=="" (
  echo [%date% %time%] NGROK_DOMAIN is empty in .env - run 1_setup.bat again >> "%LOG%"
  exit /b 1
)

:loop
for %%F in ("%LOG%") do if %%~zF GTR 5000000 move /y "%LOG%" "%LOG%.old" >nul 2>&1
echo [%date% %time%] --- starting ngrok on %NGROK_DOMAIN% -^> %WEBHOOK_PORT% --->> "%LOG%"
"%NGROK%" http %WEBHOOK_PORT% --url=%NGROK_DOMAIN% --log=stdout >> "%LOG%" 2>&1
echo [%date% %time%] --- ngrok exited (code %ERRORLEVEL%), restarting in 10s --->> "%LOG%"
ping -n 11 127.0.0.1 >nul 2>&1
goto loop
