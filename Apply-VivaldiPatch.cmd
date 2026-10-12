@echo off
rem Double-click to apply the patch, or run from a prompt with extra arguments, e.g.
rem     Apply-VivaldiPatch.cmd -Status
rem     Apply-VivaldiPatch.cmd -WhatIf
rem     Apply-VivaldiPatch.cmd -Revert
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Apply-VivaldiPatch.ps1" %*
set RC=%ERRORLEVEL%
if "%~1"=="" pause
exit /b %RC%
