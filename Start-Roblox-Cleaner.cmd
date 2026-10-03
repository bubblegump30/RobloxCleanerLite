@echo off
setlocal
if not exist "%~dp0RobloxCleanerLite.ps1" (
  echo Extract the complete ZIP before starting Roblox Cleaner Lite.
  pause
  exit /b 1
)
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0RobloxCleanerLite.ps1"
exit /b
