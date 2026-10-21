@echo off
rem Double-click me on Windows: sets up the RDMS backup with a few dialogs (runs "backup.sh wizard" in Git Bash).
cd /d "%~dp0"
set "B=%ProgramFiles%\Git\usr\bin\bash.exe"
if not exist "%B%" set "B=%LocalAppData%\Programs\Git\usr\bin\bash.exe"
if not exist "%B%" (
  powershell -NoProfile -Command "Add-Type -AssemblyName System.Windows.Forms; [Windows.Forms.MessageBox]::Show(\"This needs Git for Windows (gitforwindows.org).`n`nInstall it, then paste into a terminal:`n`nwinget install Rclone.Rclone jqlang.jq Python.Python.3.12`n`nand double-click Setup.cmd again.\", \"RDMS backup\") | Out-Null"
  exit /b 2
)
"%B%" backup.sh wizard
if errorlevel 1 pause
