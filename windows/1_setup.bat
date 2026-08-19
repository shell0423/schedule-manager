@echo off
rem STEP 1/3 - install python deps, ngrok and write .env
rem This file only starts the PowerShell script that does the real work.
rem ASCII only on purpose: cmd.exe misreads non-ASCII .bat files.
title AI-Hisho
chcp 65001 >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\setup.ps1"
echo.
pause
