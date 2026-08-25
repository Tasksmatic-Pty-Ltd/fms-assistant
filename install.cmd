@echo off
rem fms-assistant installer (Windows) - wrapper that bypasses the execution
rem policy so install.ps1 can run from a double-click or this one command.
rem ASCII-only on purpose (see install.ps1 header).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
