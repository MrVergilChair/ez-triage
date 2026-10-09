@echo off
rem Starts EZ Triage. Execution policy is bypassed for this process only; nothing on the machine is changed.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0EZTriage.ps1"
