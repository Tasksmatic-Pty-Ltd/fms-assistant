@echo off
rem fms-assistant stop wrapper - bypasses the execution policy. ASCII-only.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0stop.ps1"
