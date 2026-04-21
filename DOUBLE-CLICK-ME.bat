@echo off
REM Double-click this file in Windows to sync your hoxmedia.net site + DB to GitHub.
REM Place this file inside C:\Users\diama\Desktop\hoxmedia.net (next to sync-from-server.ps1)
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync-from-server.ps1"
pause
