# AGENTS.md

이 프로젝트는 Windows 11에서 Qwen Code용 `settings.json`을 최대한 존중하여, 주기적으로 OpenAI-compatible Qwen 서버에 질문을 보내고 다음 질문을 이어가는 루프 스케줄러입니다.

## 반드시 지킬 원칙

1. `settings.json`을 단순 참고가 아니라 주 설정 원천으로 사용한다.
2. `envKey`, `modelProviders`, `generationConfig`, `general`, `permissions`, `security`, `ui`, `$version` 값을 임의로 무시하지 않는다.
3. API Key를 임의로 `dummy`로 바꾸지 않는다. OS 환경변수 또는 `settings.json.env`에서 찾은 값을 그대로 사용한다.
4. 한글 입출력은 Windows PowerShell 5.1과 Windows 11 cmd 환경을 기준으로 UTF-8 깨짐이 없어야 한다.
5. 사용자가 더블클릭으로 실행할 수 있는 `.bat` 파일을 우선 제공한다. 사용자가 PowerShell 명령어를 직접 복붙해야 하는 흐름은 피한다.
6. 내부 API 테스트 정확도를 위해 header/body 로그는 기본 비마스킹으로 저장한다. 마스킹은 `-MaskSensitiveLogs` 옵션으로만 사용한다.
7. request body를 줄여야 하는 경우에도 `settings-first` 원칙을 README와 코드에 명확히 남긴다.
8. 기본 전송은 Qwen Code의 OpenAI Node SDK 경로처럼 보이도록 `X-Stainless-*`, `User-Agent: QwenCode/<version>`, streaming body, `baseUrl + /chat/completions`를 사용하고 `X-Qwen-Loop-*` 진단 헤더는 보내지 않는다. 수신자 식별이 필요할 때만 `-LoopDiagnosticHeaders`로 TCP local IP, PC명, 사용자명 등 클라이언트 식별값을 동적으로 조회하고 헤더/로그에 남길 수 있게 유지한다.

## 주요 파일

- `qwen-loop.ps1`: 메인 루프 실행 로직
- `check-qwen-loop.bat`: 실제 호출 없이 사용자/프로젝트 settings를 순차 DryRun하는 권장 체크 진입점
- `run-qwen-loop.bat`: 실제 사용자 설정 기준 메인 루프 실행 진입점
- `settings.json`: 스크린샷 기반으로 재구성한 Qwen Code 설정 파일
- `.qwen/settings.json`: 실제 사용자 경로 구조를 프로젝트 내부에 미러링한 파일
- `seed_prompt.txt`: question bank가 비었을 때 사용하는 단일 fallback 질문
- `question_bank.txt`: 트랙별 초기 질문 seed 모음
- `01_CHECK_SETTINGS_DOUBLECLICK.bat`: `%USERPROFILE%\.qwen\settings.json` 기준 DryRun
- `02_RUN_ONCE_TEST_DOUBLECLICK.bat`: 실제 사용자 설정 기준 1회 호출
- `03_RUN_LOOP_10MIN_DOUBLECLICK.bat`: 실제 사용자 설정 기준 10분 루프
- `06_CHECK_PROJECT_SETTINGS_DOUBLECLICK.bat`: 프로젝트 내부 `settings.json` 기준 DryRun
- `07_RUN_ONCE_PROJECT_SETTINGS_DOUBLECLICK.bat`: 프로젝트 내부 `settings.json` 기준 1회 호출
- `08_RUN_LOOP_10MIN_PROJECT_SETTINGS_DOUBLECLICK.bat`: 프로젝트 내부 `settings.json` 기준 10분 루프

## 테스트 체크리스트

- `check-qwen-loop.bat` 더블클릭 시 사용자/프로젝트 settings DryRun이 순차적으로 정상 실행되는지 확인한다.
- `02_RUN_ONCE_TEST_DOUBLECLICK.bat` 또는 `07_RUN_ONCE_PROJECT_SETTINGS_DOUBLECLICK.bat` 더블클릭 시 `NEXT_QUESTION` 한글이 깨지지 않는지 확인한다.
- `qwen-loop-data/last_request_headers.json`과 `last_request_body.json`에 settings 기반 정보가 반영되는지 확인한다.
- `dry_run_request_headers.json`에서 `User-Agent: QwenCode/<version> (win32; x64)`와 `X-Stainless-*`가 보이고 `X-Qwen-Loop-*` 진단 헤더가 기본으로 빠져 있는지 확인한다.
- `dry_run_request_body.json`에서 기본 `stream: true`, `stream_options.include_usage: true`인지 확인하고, 임의 `temperature: 0.35`/`max_tokens: 8192`가 들어가지 않는지 확인한다.
- `next_question.txt`가 있으면 재시작 시 같은 질문 루프를 이어가고, 없으면 `transcript.jsonl`/`transcript.md`에서 복구한 뒤 마지막 fallback으로 `question_bank.txt` 랜덤 seed를 사용한다.
- `qwen-loop-data/transcript.md`와 `next_question.txt`가 UTF-8 한글로 저장되는지 확인한다.
- 서버가 extra body를 거부하면 `04_RUN_LOOP_10MIN_COMPAT_BODY_IF_SERVER_REJECTS.bat` 또는 `-CompatBody` 경로를 검토한다.
