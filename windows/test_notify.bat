@echo off
rem Send todays schedule to LINE right now (test the 08:00 push)
rem This file only starts the PowerShell script that does the real work.
rem ASCII only on purpose: cmd.exe misreads non-ASCII .bat files.
title AI-Hisho
chcp 65001 >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\test_notify.ps1"
echo.
pause
