@echo off
rem Launcher for the pin window prototype (PowerShell + WPF).
rem Tries pwsh (PowerShell 7) first, falls back to Windows PowerShell 5.1.
set "SCRIPT=%~dp0pin_window_prototype.ps1"
where pwsh >nul 2>nul
if %errorlevel%==0 (
  start "PinWindow" pwsh -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SCRIPT%"
) else (
  start "PinWindow" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SCRIPT%"
)
