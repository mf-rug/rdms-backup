@echo off
rem Double-click me on Windows: sets up the RDMS backup with a few dialogs (runs "backup.sh wizard" in Git Bash).
rem No ( ) blocks and no \" here: cmd has no quote escape, so a ")" inside a quoted string would end the block early.
cd /d "%~dp0"
set "B=%ProgramFiles%\Git\usr\bin\bash.exe"
if not exist "%B%" set "B=%LocalAppData%\Programs\Git\usr\bin\bash.exe"
if exist "%B%" goto run
powershell -NoProfile -Command "Add-Type -AssemblyName System.Windows.Forms; $n = [char]10; [void][Windows.Forms.MessageBox]::Show('This needs Git for Windows (gitforwindows.org).' + $n + $n + 'Install it, then paste into a terminal:' + $n + $n + 'winget install Rclone.Rclone jqlang.jq Python.Python.3.12' + $n + $n + 'and double-click Setup.cmd again.', 'RDMS backup')"
exit /b 2
:run
"%B%" backup.sh wizard
if errorlevel 1 pause
