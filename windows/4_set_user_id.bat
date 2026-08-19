@echo off
rem Pick up LINE_USER_ID from the log so morning push works
rem This file only starts the PowerShell script that does the real work.
rem ASCII only on purpose: cmd.exe misreads non-ASCII .bat files.
title AI-Hisho
chcp 65001 >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\set_user_id.ps1"
echo.
pause
