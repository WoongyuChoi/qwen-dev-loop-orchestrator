@echo off
setlocal EnableExtensions
set "SCRIPT_DIR=%~dp0"
if not exist "%SCRIPT_DIR%qwen-loop-data" mkdir "%SCRIPT_DIR%qwen-loop-data"
start "" "%SCRIPT_DIR%qwen-loop-data"
