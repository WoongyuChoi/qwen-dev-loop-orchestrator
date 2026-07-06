# qwen-dev-loop-orchestrator

Windows 11에서 Qwen Code용 `settings.json`을 기반으로 Qwen/OpenAI-compatible 서버에 주기적으로 질문을 보내는 개발 분석 루프 스케줄러 프로젝트입니다.

이 프로젝트는 기존 `qwen_loop_scheduler_v4_settings_first` 최신 파일을 기반으로 따로 분리한 Codex 작업용 프로젝트입니다.

## 핵심 목표

- `C:\Users\KB099\.qwen\settings.json` 설정을 최대한 존중한다.
- `envKey`, `generationConfig`, `permissions`, `general`, `ui`, `$version` 등을 임의로 버리지 않는다.
- Windows 11에서 더블클릭 BAT 파일로 실행한다.
- 한글 질문/응답/로그가 깨지지 않도록 UTF-8을 강제한다.
- 10분마다 질문 → 답변 → 다음 질문 추출 → 다음 루프를 반복한다.
- 실제 전송 헤더와 바디를 로그로 확인할 수 있게 한다.

## 먼저 볼 파일

```text
AGENTS.md                         Codex 작업 규칙
settings.json                     스크린샷 기반 재구성 settings.json
.qwen/settings.json               사용자 .qwen 폴더 구조 미러
docs/CONVERSATION_SUMMARY.md      지금까지 대화 요약
docs/CODEX_HANDOFF.md             Codex에게 맡길 작업 지시서
qwen-loop.ps1                     메인 실행 로직
```

## 더블클릭 실행 파일

실제 사용자 경로 `C:\Users\KB099\.qwen\settings.json`을 읽는 파일:

```text
01_CHECK_SETTINGS_DOUBLECLICK.bat
02_RUN_ONCE_TEST_DOUBLECLICK.bat
03_RUN_LOOP_10MIN_DOUBLECLICK.bat
04_RUN_LOOP_10MIN_COMPAT_BODY_IF_SERVER_REJECTS.bat
```

프로젝트 내부 `settings.json`을 읽는 파일:

```text
06_CHECK_PROJECT_SETTINGS_DOUBLECLICK.bat
07_RUN_ONCE_PROJECT_SETTINGS_DOUBLECLICK.bat
08_RUN_LOOP_10MIN_PROJECT_SETTINGS_DOUBLECLICK.bat
```

로그 폴더 열기:

```text
05_OPEN_LOG_FOLDER.bat
```

## 추천 실행 순서

1. `01_CHECK_SETTINGS_DOUBLECLICK.bat` 더블클릭
2. settings 해석이 맞는지 확인
3. `02_RUN_ONCE_TEST_DOUBLECLICK.bat` 더블클릭
4. `qwen-loop-data`의 로그와 한글 깨짐 여부 확인
5. 정상이라면 `03_RUN_LOOP_10MIN_DOUBLECLICK.bat` 실행

프로젝트 내부 settings로 테스트하려면 01/02/03 대신 06/07/08을 사용합니다.

## 로그 파일

실행 후 `qwen-loop-data` 폴더에 생성됩니다.

```text
settings_effective_summary.json
last_request_headers.json
last_request_body.json
next_question.txt
last_turn.txt
transcript.md
transcript.jsonl
error.log
```

## 주의

이 루프는 모델 가중치를 실제로 학습시키는 파인튜닝이 아닙니다. 대신 개발 분석 질문/답변 로그를 계속 축적하여 나중에 문서화, RAG, Continue/Qwen 컨텍스트로 재활용하기 위한 도구입니다.
