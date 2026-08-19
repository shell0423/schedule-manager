@echo off
rem STEP 3/3 - start the bot, register autostart and 08:00 notify
rem This file only starts the PowerShell script that does the real work.
rem ASCII only on purpose: cmd.exe misreads non-ASCII .bat files.
title AI-Hisho
chcp 65001 >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start.ps1"
echo.
pause
