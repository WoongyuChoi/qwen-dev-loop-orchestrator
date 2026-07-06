# AGENTS.md

이 프로젝트는 Windows 11에서 Qwen Code용 `settings.json`을 최대한 존중하여, 주기적으로 OpenAI-compatible Qwen 서버에 질문을 보내고 다음 질문을 이어가는 루프 스케줄러입니다.

## 반드시 지킬 원칙

1. `settings.json`을 단순 참고가 아니라 주 설정 원천으로 사용한다.
2. `envKey`, `modelProviders`, `generationConfig`, `general`, `permissions`, `security`, `ui`, `$version` 값을 임의로 무시하지 않는다.
3. API Key를 임의로 `dummy`로 바꾸지 않는다. OS 환경변수 또는 `settings.json.env`에서 찾은 값을 그대로 사용한다.
4. 한글 입출력은 Windows PowerShell 5.1과 Windows 11 cmd 환경을 기준으로 UTF-8 깨짐이 없어야 한다.
5. 사용자가 더블클릭으로 실행할 수 있는 `.bat` 파일을 우선 제공한다. 사용자가 PowerShell 명령어를 직접 복붙해야 하는 흐름은 피한다.
6. 로그에는 민감값을 기본적으로 마스킹한다. 단, 실제 요청에는 원 설정값을 전송한다.
7. request body를 줄여야 하는 경우에도 `settings-first` 원칙을 README와 코드에 명확히 남긴다.
8. 수신자 식별을 위해 TCP local IP, PC명, 사용자명 등 클라이언트 식별 헤더를 보낼 수 있게 유지한다.

## 주요 파일

- `qwen-loop.ps1`: 메인 루프 실행 로직
- `settings.json`: 스크린샷 기반으로 재구성한 Qwen Code 설정 파일
- `.qwen/settings.json`: 실제 사용자 경로 구조를 프로젝트 내부에 미러링한 파일
- `01_CHECK_SETTINGS_DOUBLECLICK.bat`: `%USERPROFILE%\.qwen\settings.json` 기준 DryRun
- `02_RUN_ONCE_TEST_DOUBLECLICK.bat`: 실제 사용자 설정 기준 1회 호출
- `03_RUN_LOOP_10MIN_DOUBLECLICK.bat`: 실제 사용자 설정 기준 10분 루프
- `06_CHECK_PROJECT_SETTINGS_DOUBLECLICK.bat`: 프로젝트 내부 `settings.json` 기준 DryRun
- `07_RUN_ONCE_PROJECT_SETTINGS_DOUBLECLICK.bat`: 프로젝트 내부 `settings.json` 기준 1회 호출
- `08_RUN_LOOP_10MIN_PROJECT_SETTINGS_DOUBLECLICK.bat`: 프로젝트 내부 `settings.json` 기준 10분 루프

## 테스트 체크리스트

- `01_CHECK_SETTINGS_DOUBLECLICK.bat` 또는 `06_CHECK_PROJECT_SETTINGS_DOUBLECLICK.bat` 더블클릭 시 settings 해석이 정상인지 확인한다.
- `02_RUN_ONCE_TEST_DOUBLECLICK.bat` 또는 `07_RUN_ONCE_PROJECT_SETTINGS_DOUBLECLICK.bat` 더블클릭 시 `NEXT_QUESTION` 한글이 깨지지 않는지 확인한다.
- `qwen-loop-data/last_request_headers.json`과 `last_request_body.json`에 settings 기반 정보가 반영되는지 확인한다.
- `qwen-loop-data/transcript.md`와 `next_question.txt`가 UTF-8 한글로 저장되는지 확인한다.
- 서버가 extra body를 거부하면 `04_RUN_LOOP_10MIN_COMPAT_BODY_IF_SERVER_REJECTS.bat` 또는 `-CompatBody` 경로를 검토한다.
