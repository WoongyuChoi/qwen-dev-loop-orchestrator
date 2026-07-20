@echo off
chcp 65001 >nul
setlocal EnableExtensions
set "SCRIPT_DIR=%~dp0"
set "SETTINGS_PATH=%USERPROFILE%\.qwen\settings.json"
if not exist "%SETTINGS_PATH%" (
  echo [ERROR] settings.json not found: %SETTINGS_PATH%
  pause
  exit /b 1
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%qwen-loop.ps1" ^
  -SettingsPath "%SETTINGS_PATH%" ^
  -MinIntervalMinutes 8 ^
  -MaxIntervalMinutes 15 ^
  -LastTurnChars 12000 ^
  -WorkDir "%SCRIPT_DIR%qwen-loop-data" ^
  -SeedFile "%SCRIPT_DIR%seed_prompt.txt" ^
  -ContextListFile "%SCRIPT_DIR%context_files.txt"

set "QWEN_EXIT_CODE=%ERRORLEVEL%"
if not "%QWEN_EXIT_CODE%"=="0" echo [ERROR] qwen-loop.ps1 exited with code %QWEN_EXIT_CODE%.
pause
exit /b %QWEN_EXIT_CODE%
