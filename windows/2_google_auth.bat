@echo off
rem STEP 2/3 - grant Google Calendar access (creates token.json)
rem This file only starts the PowerShell script that does the real work.
rem ASCII only on purpose: cmd.exe misreads non-ASCII .bat files.
title AI-Hisho
chcp 65001 >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\google_auth.ps1"
echo.
pause
