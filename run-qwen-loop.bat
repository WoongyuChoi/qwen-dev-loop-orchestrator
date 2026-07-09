@echo off
chcp 65001 >nul
setlocal EnableExtensions DisableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
set "SETTINGS_PATH=%USERPROFILE%\.qwen\settings.json"

pushd "%SCRIPT_DIR%" >nul
if errorlevel 1 (
  echo [ERROR] Cannot enter script directory: "%SCRIPT_DIR%"
  pause
  exit /b 1
)

if not exist "%SETTINGS_PATH%" (
  echo [ERROR] settings.json not found: "%SETTINGS_PATH%"
  popd >nul
  pause
  exit /b 1
)

:MENU
cls
echo ============================================================
echo Qwen Loop Scheduler
echo ------------------------------------------------------------
echo 1. Random question loop
echo    - 기존 qwen-loop-data 상태를 이어서 사용합니다.
echo.
echo 2. Project directory loop
echo    - 입력한 프로젝트 디렉터리를 스캔합니다.
echo    - 매 실행마다 중요 후보 파일을 다시 샘플링해 새 첫 질문으로 시작합니다.
echo ============================================================
echo.
choice /C 12 /N /M "Select mode [1/2]: "
if errorlevel 2 goto PROJECT_MODE
if errorlevel 1 goto RANDOM_MODE
goto MENU

:RANDOM_MODE
echo.
echo [MODE] Random question loop
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%qwen-loop.ps1" ^
  -SettingsPath "%SETTINGS_PATH%" ^
  -MinIntervalMinutes 8 ^
  -MaxIntervalMinutes 15 ^
  -LastTurnChars 12000 ^
  -WorkDir "%SCRIPT_DIR%qwen-loop-data" ^
  -SeedFile "%SCRIPT_DIR%seed_prompt.txt" ^
  -ContextListFile "%SCRIPT_DIR%context_files.txt"
goto END

:PROJECT_MODE
echo.
echo [MODE] Project directory loop
echo ProjectRoot 예시: D:\workspace\my-project
echo.
set "PROJECT_ROOT="
set /p "PROJECT_ROOT=ProjectRoot: "
set "PROJECT_ROOT=%PROJECT_ROOT:"=%"

if "%PROJECT_ROOT%"=="" (
  echo [ERROR] ProjectRoot is empty.
  pause
  goto MENU
)

if not exist "%PROJECT_ROOT%\" (
  echo [ERROR] directory not found: "%PROJECT_ROOT%"
  pause
  goto MENU
)

for %%I in ("%PROJECT_ROOT%") do set "PROJECT_NAME=%%~nI"
if "%PROJECT_NAME%"=="" set "PROJECT_NAME=project"
set "PROJECT_WORKDIR=%SCRIPT_DIR%qwen-loop-data\project\%PROJECT_NAME%"

echo.
echo ProjectRoot : "%PROJECT_ROOT%"
echo WorkDir     : "%PROJECT_WORKDIR%"
echo.

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%qwen-loop.ps1" ^
  -SettingsPath "%SETTINGS_PATH%" ^
  -ProjectRoot "%PROJECT_ROOT%" ^
  -FreshProjectQuestion ^
  -MinIntervalMinutes 8 ^
  -MaxIntervalMinutes 15 ^
  -LastTurnChars 12000 ^
  -WorkDir "%PROJECT_WORKDIR%" ^
  -SeedFile "%SCRIPT_DIR%seed_prompt.txt" ^
  -ContextListFile "%SCRIPT_DIR%context_files.txt"
goto END

:END
popd >nul
pause
