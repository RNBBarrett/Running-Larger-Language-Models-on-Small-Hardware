@echo off
REM Wrapper that runs start.ps1 without requiring a global PowerShell execution
REM policy change. Pass any flags through: e.g. `start.cmd -Pick`, `start.cmd -Benchmark`.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1" %*
