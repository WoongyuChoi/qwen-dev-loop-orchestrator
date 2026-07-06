@echo off
chcp 65001 >nul
setlocal EnableExtensions

set "SCRIPT_DIR=%~dp0"
set "USER_SETTINGS=%USERPROFILE%\.qwen\settings.json"
set "PROJECT_SETTINGS=%SCRIPT_DIR%settings.json"
set "CHECK_ROOT=%SCRIPT_DIR%qwen-loop-data\check"
set "FAILED=0"

echo ============================================================
echo Qwen Loop Check
echo ------------------------------------------------------------
echo API 호출 없이 DryRun만 순차 실행합니다.
echo 1. 실제 사용자 settings.json 확인
echo 2. 프로젝트 내부 settings.json 확인
echo ============================================================
echo.

call :RunDryRun "1/2" "실제 사용자 settings" "%USER_SETTINGS%" "%CHECK_ROOT%\user" "optional"
echo.
call :RunDryRun "2/2" "프로젝트 settings" "%PROJECT_SETTINGS%" "%CHECK_ROOT%\project" "required"
echo.

echo ============================================================
echo Check 결과 파일
echo ------------------------------------------------------------
echo 사용자 settings:
echo   %CHECK_ROOT%\user\settings_effective_summary.json
echo   %CHECK_ROOT%\user\dry_run_request_headers.json
echo   %CHECK_ROOT%\user\dry_run_request_body.json
echo 프로젝트 settings:
echo   %CHECK_ROOT%\project\settings_effective_summary.json
echo   %CHECK_ROOT%\project\dry_run_request_headers.json
echo   %CHECK_ROOT%\project\dry_run_request_body.json
echo ============================================================

if "%FAILED%"=="1" (
  echo 하나 이상의 체크가 실패했습니다.
  pause
  exit /b 1
)

echo 실행 가능한 체크가 모두 완료되었습니다.
pause
exit /b 0

:RunDryRun
set "STEP=%~1"
set "LABEL=%~2"
set "SETTINGS_TO_CHECK=%~3"
set "WORK_TO_USE=%~4"
set "REQUIRED=%~5"

if not exist "%SETTINGS_TO_CHECK%" (
  echo [%STEP%] %LABEL% 없음 - 건너뜀
  echo       %SETTINGS_TO_CHECK%
  if /I "%REQUIRED%"=="required" set "FAILED=1"
  exit /b 0
)

echo [%STEP%] %LABEL% DryRun
echo       %SETTINGS_TO_CHECK%
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%qwen-loop.ps1" -SettingsPath "%SETTINGS_TO_CHECK%" -IntervalSeconds 600 -LastTurnChars 12000 -WorkDir "%WORK_TO_USE%" -SeedFile "%SCRIPT_DIR%seed_prompt.txt" -ContextListFile "%SCRIPT_DIR%context_files.txt" -DryRun
if errorlevel 1 (
  echo [FAIL] %LABEL% DryRun 실패
  set "FAILED=1"
) else (
  echo [OK] %LABEL% DryRun 완료
)
exit /b 0
