@echo off
rem fms-assistant start wrapper - bypasses the execution policy so start.ps1
rem runs from a double-click or this one command. ASCII-only on purpose.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1"
