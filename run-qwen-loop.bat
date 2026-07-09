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
call :ASK_INTERVAL
if errorlevel 1 goto MENU
echo Interval   : %INTERVAL_DESC%
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%qwen-loop.ps1" ^
  -SettingsPath "%SETTINGS_PATH%" ^
  %INTERVAL_ARGS% ^
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
call :ASK_INTERVAL
if errorlevel 1 goto MENU
echo Interval    : %INTERVAL_DESC%
echo.

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%qwen-loop.ps1" ^
  -SettingsPath "%SETTINGS_PATH%" ^
  -ProjectRoot "%PROJECT_ROOT%" ^
  -FreshProjectQuestion ^
  %INTERVAL_ARGS% ^
  -LastTurnChars 12000 ^
  -WorkDir "%PROJECT_WORKDIR%" ^
  -SeedFile "%SCRIPT_DIR%seed_prompt.txt" ^
  -ContextListFile "%SCRIPT_DIR%context_files.txt"
goto END

:ASK_INTERVAL
echo.
echo Interval mode
echo 1. Random 8-15 minutes after each response
echo 2. Fixed minutes after each response (0 = immediate)
choice /C 12 /N /M "Select interval [1/2]: "
if errorlevel 2 goto ASK_FIXED_INTERVAL
if errorlevel 1 goto SET_RANDOM_INTERVAL
exit /b 1

:SET_RANDOM_INTERVAL
set "INTERVAL_ARGS=-MinIntervalMinutes 8 -MaxIntervalMinutes 15"
set "INTERVAL_DESC=random 8-15 minutes after each response"
exit /b 0

:ASK_FIXED_INTERVAL
set "FIXED_MINUTES="
set /p "FIXED_MINUTES=Minutes (0 = immediate after response): "
set "FIXED_MINUTES=%FIXED_MINUTES:"=%"
set "FIXED_MINUTES=%FIXED_MINUTES: =%"
if "%FIXED_MINUTES%"=="" (
  echo [ERROR] Minutes is empty.
  pause
  exit /b 1
)
for /f "delims=0123456789" %%A in ("%FIXED_MINUTES%") do (
  echo [ERROR] Minutes must be a non-negative integer.
  pause
  exit /b 1
)
:TRIM_FIXED_INTERVAL_ZERO
if not "%FIXED_MINUTES%"=="0" if "%FIXED_MINUTES:~0,1%"=="0" (
  set "FIXED_MINUTES=%FIXED_MINUTES:~1%"
  goto TRIM_FIXED_INTERVAL_ZERO
)
set /a FIXED_SECONDS=FIXED_MINUTES*60
set "INTERVAL_ARGS=-IntervalSeconds %FIXED_SECONDS%"
if "%FIXED_MINUTES%"=="0" (
  set "INTERVAL_DESC=immediate after each response"
) else (
  set "INTERVAL_DESC=fixed %FIXED_MINUTES% minute(s) after each response"
)
exit /b 0

:END
popd >nul
pause
