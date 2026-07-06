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

## Qwen Code 호환 전송 기준

이 프로젝트는 `settings.json`을 주 설정 원천으로 사용하지만, OpenAI-compatible HTTP 요청 바디에 설정 객체 전체를 그대로 넣지는 않습니다. Qwen Code CLI의 기본 OpenAI-compatible provider 동작에 맞춰 다음 필드만 전송 형태에 직접 매핑합니다.

- `generationConfig.customHeaders`: HTTP header로 병합
- `generationConfig.samplingParams`: request body의 sampling parameter로 병합
- `generationConfig.extra_body`: request body에 마지막으로 병합
- `envKey`: OS 환경변수, `.env`, `settings.json.env` 순서로 API key를 찾아 `Authorization` header에 사용

`generationConfig.modalities`, `generationConfig.contextWindowSize`, `generationConfig.timeout`, `general`, `permissions`, `security`, `ui`, `$version` 등은 버리지 않고 provider 선택, system prompt, 요약 로그, 검증 파일에 반영합니다. 다만 Qwen Code CLI가 raw body field로 보내지 않는 값은 기본 요청 바디에 임의로 추가하지 않습니다.

기본 전송은 Qwen Code가 사용하는 OpenAI Node SDK 경로를 더 가깝게 흉내냅니다. `X-Stainless-*` SDK fingerprint header를 포함하고, `User-Agent: QwenCode/<version> (win32; x64)`가 SDK 기본 User-Agent를 덮어쓰는 순서를 따릅니다. `<version>`은 수신측 서버 버전이 아니라 요청을 보내는 Qwen Code CLI 클라이언트 버전입니다. 실제 CLI 버전을 모르면 공식 fallback과 같은 `unknown`을 사용하고, 정확한 버전을 알고 있으면 `QWEN_CODE_VERSION` 환경변수나 `-QwenCodeVersion` 인자로 지정합니다. Qwen Code가 실제로 사용하는 Node 런타임 버전을 모르면 `X-Stainless-Runtime-Version`도 `unknown`으로 두며, 정확히 알 때만 `QWEN_CODE_NODE_VERSION` 환경변수나 `-NodeRuntimeVersion` 인자로 지정합니다.

기본 요청은 `stream: true`, `stream_options.include_usage: true`이며, endpoint도 OpenAI SDK처럼 `baseUrl + /chat/completions` 한 곳만 사용합니다. 예전처럼 `/v1/chat/completions`를 먼저 시도하는 fallback은 `-EndpointFallbacks`를 켰을 때만 사용합니다.

`temperature: 0.35`나 `max_tokens: 8192` 같은 스케줄러 임의값은 기본으로 보내지 않습니다. `samplingParams`가 없으면 Qwen Code의 token limit 로직에 맞춰 모델명 기반 `max_tokens`만 계산합니다. 임의 sampling 기본값을 일부러 보내야 할 때만 `-UseSchedulerSamplingDefaults`를 사용합니다.

`X-Qwen-Loop-*` 진단 header는 기본으로 보내지 않습니다. 수신자 추적이 필요할 때만 `qwen-loop.ps1` 실행 시 `-LoopDiagnosticHeaders`를 추가합니다. PC명, 사용자명, local IP 같은 식별 header만 빼려면 `-LoopDiagnosticHeaders -NoClientIdentityHeaders`를 함께 사용합니다.

`dry_run_request_headers.json`과 `last_request_headers.json`은 내부 API 테스트용으로 기본 비마스킹 저장합니다. 민감값 마스킹이 필요한 경우에만 `-MaskSensitiveLogs`를 추가합니다.

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
dry_run_request_headers.json
dry_run_request_body.json
next_question.txt
last_turn.txt
transcript.md
transcript.jsonl
error.log
```

## 주의

이 루프는 모델 가중치를 실제로 학습시키는 파인튜닝이 아닙니다. 대신 개발 분석 질문/답변 로그를 계속 축적하여 나중에 문서화, RAG, Continue/Qwen 컨텍스트로 재활용하기 위한 도구입니다.
