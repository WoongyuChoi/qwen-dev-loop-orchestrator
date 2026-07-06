# qwen-dev-loop-orchestrator

Windows 11에서 Qwen Code용 `settings.json`을 기반으로 Qwen/OpenAI-compatible 서버에 주기적으로 질문을 보내는 개발 분석 루프 스케줄러 프로젝트입니다.

이 프로젝트는 기존 `qwen_loop_scheduler_v4_settings_first` 최신 파일을 기반으로 따로 분리한 Codex 작업용 프로젝트입니다.

더블클릭 실행 시 CMD 상단에 `Qwen Loop Scheduler` ASCII 배너와 작은 터미널 아바타가 표시됩니다. 조용한 로그가 필요하면 `qwen-loop.ps1` 실행 옵션에 `-NoBanner`를 추가합니다.

## 핵심 목표

- `%USERPROFILE%\.qwen\settings.json` 설정을 최대한 존중한다.
- `envKey`, `generationConfig`, `permissions`, `general`, `ui`, `$version` 등을 임의로 버리지 않는다.
- Windows 11에서 더블클릭 BAT 파일로 실행한다.
- 한글 질문/응답/로그가 깨지지 않도록 UTF-8을 강제한다.
- 매 호출 후 8-15분 사이의 랜덤 대기시간을 새로 뽑아 질문 → 답변 → 다음 질문 추출 → 다음 루프를 반복한다.
- 실제 전송 헤더와 바디를 로그로 확인할 수 있게 한다.
- 오래 켜둬도 `qwen-loop-data`가 무한정 커지지 않도록 상태 파일은 보존하고 오래된 산출물/큰 로그는 자동 정리한다.

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

실제 호출 성공 시 CMD에는 `HTTP 200 OK (... ms, ... bytes)` 형식의 응답 상태가 출력되고, 추출된 응답 글자 수도 함께 표시됩니다. 404/500 같은 HTTP 오류나 연결 실패는 `Endpoint failed`와 함께 상태 코드/응답 body 일부가 콘솔과 `error.log`에 남습니다.

응답을 받은 뒤에는 `ANSWER PREVIEW`로 실제 답변 본문 앞부분을 기본 4줄/1000자까지 CMD에 보여줍니다. 전체 답변은 `transcript.md`와 `transcript.jsonl`에 저장됩니다. preview가 너무 길거나 불필요하면 `-AnswerPreviewLines`, `-AnswerPreviewChars`, `-NoAnswerPreview`로 조정합니다.

각 호출 생명주기는 `run_history.md`와 `run_history.jsonl`에 별도로 누적됩니다. `transcript`가 답변 본문 중심이라면, `run_history`는 `Seq`, `Session`, `Status`, `Started`, `Request`, `Response`, `HTTP`, `Next Wait`, `Next Run`을 테이블처럼 남겨 “정말 다음 순번까지 쐈는지” 확인하는 용도입니다.

서버가 OpenAI-compatible `usage` 값을 반환하면 CMD에 `TokenUse`도 표시합니다. 기본 기준은 출력 토큰이 `1000` 미만이면 초록색 `light`, `1000-3999`면 노란색 `balanced`, `4000` 이상이면 마젠타색 `rich`입니다. 이 루프는 깊은 답변을 의도하므로 `rich`는 경고가 아니라 분석량이 충분하다는 신호에 가깝고, 대신 응답 시간과 비용은 늘 수 있습니다. 기준은 `-TokenLowThreshold`, `-TokenRichThreshold`로 조정합니다.

통신 실패 시 기본 `-MaxRetries 3`으로 즉시 재시도합니다. 네트워크/타임아웃 오류와 HTTP `408`, `409`, `429`, `5xx`는 retry 대상이고, `400`, `401`, `403`, `404`처럼 요청/인증/경로가 틀린 오류는 같은 endpoint에서 반복해도 회복 가능성이 낮아 재시도하지 않습니다. 각 retry 요청의 `X-Stainless-Retry-Count` header는 `0`, `1`, `2`, `3`처럼 실제 시도 횟수에 맞춰 증가합니다.

`qwen-loop-data` 자동정리는 기본으로 켜져 있습니다. 기본값은 전체 WorkDir `100 MB`, `transcript.md`/`transcript.jsonl` 각각 `25 MB`, `error.log` `5 MB`, 오래된 check/DryRun 산출물 `14일`, 최근 대화 `30 turn` 보존입니다. `next_question.txt`, `last_turn.txt`, 최신 request/response 로그처럼 루프 재시작에 필요한 상태 파일은 삭제하지 않습니다. 필요하면 `-MaxWorkDirMB`, `-MaxTranscriptMB`, `-MaxErrorLogMB`, `-CleanupKeepDays`, `-CleanupKeepTurns`로 조정하고, 완전히 끄려면 `-NoAutoCleanup`을 사용합니다.

## 호출 간격

기본 루프는 고정 10분 타이머가 아니라 `-MinIntervalMinutes 8 -MaxIntervalMinutes 15` 범위에서 매 호출 후 새 랜덤 대기시간을 뽑습니다. 예를 들어 한 번 호출한 뒤 11분 20초를 기다렸다면, 다음 호출 뒤에는 다시 8-15분 범위에서 새 값을 뽑습니다.

기존처럼 고정 간격 테스트가 필요하면 `qwen-loop.ps1`에 `-IntervalSeconds 600`만 단독으로 넘깁니다. `-MinIntervalMinutes`/`-MaxIntervalMinutes`를 함께 넘기면 랜덤 범위가 우선입니다.

대기 중에는 CMD의 같은 줄에서 `Wait 07:30 (450s) | next 15:23:29 | random | Ctrl+C`처럼 짧은 countdown이 기본 1초마다 갱신됩니다. 너무 번잡하면 `-CountdownRefreshSeconds 60`으로 1분마다 갱신하거나, `-NoCountdown`으로 예전처럼 한 번만 출력하고 조용히 대기할 수 있습니다.

## 먼저 볼 파일

```text
README.md                         실행 방법, 콘솔 출력 예시, 동작 흐름
AGENTS.md                         Codex 작업 규칙
CHANGELOG.md                      현재 기능 기준 변경 요약
settings.json                     스크린샷 기반 재구성 settings.json
.qwen/settings.json               사용자 .qwen 폴더 구조 미러
qwen-loop.ps1                     메인 실행 로직
seed_prompt.txt                   question_bank.txt가 없거나 비었을 때 쓰는 단일 fallback 질문
question_bank.txt                 트랙별 초기 질문 seed 모음
```

## 더블클릭 실행 파일

권장 진입점:

```text
check-qwen-loop.bat               실제 호출 없이 사용자/프로젝트 settings를 순차 DryRun
run-qwen-loop.bat                 실제 사용자 settings 기준 메인 루프 실행
05_OPEN_LOG_FOLDER.bat            로그 폴더 열기
```

세부 검증용 파일:

`10MIN`이 들어간 파일명은 기존 호환 이름이며, 현재 루프 BAT의 실제 기본 대기시간은 8-15분 랜덤입니다.

실제 사용자 경로 `%USERPROFILE%\.qwen\settings.json`을 읽는 파일:

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

## 추천 실행 순서

1. `check-qwen-loop.bat` 더블클릭
2. 사용자/프로젝트 settings DryRun 결과 확인
3. `qwen-loop-data\check\...\dry_run_request_headers.json`과 `dry_run_request_body.json` 확인
4. 정상이라면 `run-qwen-loop.bat` 실행

프로젝트 내부 settings로 테스트하려면 01/02/03 대신 06/07/08을 사용합니다.

## CMD 출력 예시

아래는 실제 실행값이 아니라 CMD에서 보이는 형태 예시입니다. 경로, endpoint, 응답 시간, token 수, 다음 질문, 랜덤 대기시간은 실행 환경과 서버 응답에 따라 달라집니다.

DryRun 체크를 실행하면 실제 API는 호출하지 않고 settings 해석 결과와 전송 예정 header/body 파일만 만듭니다.

```text
   ____                         __
  / __ \__      _____  ____    / /   ____  ____  ____
 / / / / | /| / / _ \/ __ \  / /   / __ \/ __ \/ __ \
/ /_/ /| |/ |/ /  __/ / / / / /___/ /_/ / /_/ / /_/ /
\___\_\|__/|__/\___/_/ /_/ /_____/\____/\____/ .___/
                                             /_/
                 S C H E D U L E R   v4
       +------------------------------------------------+
       | settings-first OpenAI-compatible API runner    |
       | random loop / visible status / transcript log  |
       +--------------------------.---------------------+
                                  |
                              [ QWEN ]
                               (o_o)
                            ---/|_|\---

=== Runtime Summary: SETTINGS-FIRST ===
SettingsPath : C:\Users\<user>\.qwen\settings.json
ProviderType : openai
ProviderName : qwen3.6-agent
ProviderId   : qwen3.6-agent
BaseUrl      : http://10.32.64.116:8002
Model        : qwen3.6-agent
EnvKey       : QWEN_CUSTOM_API_KEY_OPENAI_HTTP_10_32_64_116_8002_...
ApiKeySource : settings.json/env
Authorization: sent exactly from settings.json/env
ClientIdent  : disabled; use -LoopDiagnosticHeaders only when receiver-side tracing needs it
CompatBody   : False
WireMode     : Qwen Code OpenAI SDK-like headers/body
Stream       : True
Retry        : max 3, backoff 1-10 sec
TokenUse     : light < 1000, rich >= 4000 output tokens
HeaderLog    : unmasked
QuestionSrc  : question_bank.txt
AnswerPreview: 4 lines / 1000 chars
AutoCleanup  : folder <= 100 MB, transcript <= 25 MB, error <= 5 MB, keep 30 turns, stale check > 14 days
Cleanup     : ok, current 182.3 KB
IntervalMode : random
IntervalRange: 8 min (480 sec) - 15 min (900 sec)
Countdown    : live every 1 sec
TimeoutSec   : 120
WorkDir      : ...\qwen-loop-data\check\user
Stop         : Ctrl+C
==============================================
DryRun mode: API 호출 없이 settings.json 활용 내역만 확인했습니다.
Created:
- ...\qwen-loop-data\check\user\settings_effective_summary.json
- ...\qwen-loop-data\check\user\dry_run_request_headers.json
- ...\qwen-loop-data\check\user\dry_run_request_body.json
Endpoint:
- http://10.32.64.116:8002/chat/completions
```

실제 루프에서는 질문 전송, HTTP 상태, 답변 preview, token 사용량, 다음 질문, 저장 경로가 한 사이클 안에서 이어서 보입니다.

```text
[2026-07-06 13:50:15] RUN #1 QUESTION:
현재 Spring Boot 백엔드의 핵심 도메인 서비스 레이어에서 트랜잭션 경계가 Repository 호출 시점에 명확히 구분되어 있는지 분석해 줘.

[2026-07-06 13:50:15] POST http://10.32.64.116:8002/chat/completions (attempt 1/4, retry-count=0)
[2026-07-06 13:50:42] HTTP 200 OK (27091 ms, 18432 bytes, retry-count=0)
ResponseText : 6280 chars extracted
TokenUse     : input=2,418, output=1,946, total=4,364 | balanced (reasonable depth and cost)

ANSWER PREVIEW:
트랜잭션 경계를 검토할 때는 먼저 Service public method 단위에서 업무 유스케이스가 닫히는지 확인해야 합니다.
그 다음 Repository 호출이 같은 트랜잭션 안에서 필요한 지연 로딩, 변경 감지, 예외 롤백 규칙을 공유하는지 봅니다.
...

NEXT QUESTION:
현재 Service 계층에서 읽기 전용 조회와 쓰기 유스케이스가 같은 @Transactional 설정을 공유하면서 불필요한 flush나 lock 경합을 만들 가능성이 있는지 분석해 줘.

Saved:
- ...\qwen-loop-data\next_question.txt
- ...\qwen-loop-data\last_turn.txt
- ...\qwen-loop-data\transcript.md
- ...\qwen-loop-data\transcript.jsonl
- ...\qwen-loop-data\last_request_headers.json
- ...\qwen-loop-data\last_request_body.json
- ...\qwen-loop-data\last_response_status.json

RUN #1 complete. Full answer saved to transcript.md.
RunHistory  : ...\qwen-loop-data\run_history.md
Wait 11:50 (710s) | next 14:02:32 | random | Ctrl+C
```

통신이 불안정하면 retry 대상 오류만 다시 시도합니다. `404`나 인증 오류처럼 같은 요청을 반복해도 해결되지 않는 오류는 retry 없이 실패 로그를 남깁니다.

```text
[2026-07-06 14:10:04] POST http://10.32.64.116:8002/chat/completions (attempt 1/4, retry-count=0)
Endpoint failed: http://10.32.64.116:8002/chat/completions (attempt 1/4, retryable=True)
HTTP 호출 실패 after 120013 ms: The operation has timed out.
Retry 1/3 in 1.4 sec...

[2026-07-06 14:10:06] POST http://10.32.64.116:8002/chat/completions (attempt 2/4, retry-count=1)
[2026-07-06 14:10:29] HTTP 200 OK (22841 ms, 15320 bytes, retry-count=1)
```

## 로그 파일

실행 후 `qwen-loop-data` 폴더에 생성됩니다. 이 폴더는 `.gitignore` 대상인 런타임 상태/검증 출력이며 설정 원천이 아닙니다. 다른 PC에서 실행하면 그 PC의 `%USERPROFILE%`, settings 경로, 질문 상태에 맞춰 새로 생성됩니다.

기본 실행에서는 Qwen Code CLI 전송 모양을 해치지 않도록 PC명, 사용자명, 도메인, TCP local IP, target host 같은 `X-Qwen-Loop-*` 진단값을 조회하거나 보내지 않습니다. 수신자 추적이 필요할 때만 `-LoopDiagnosticHeaders`를 켜며, 이때 생성되는 `clientNetworkIdentity` 값은 해당 실행 환경에서 동적으로 계산된 진단 로그입니다.

자동정리는 시작 시 한 번, 각 루프 저장 후 한 번 실행됩니다. 크기 임계치를 넘으면 `transcript.md`는 최근 turn 중심으로 compact하고, `transcript.jsonl`은 최근 record와 짧은 답변 preview만 남깁니다. `error.log`는 최근 tail만 남기며, 오래된 check/DryRun 파일은 날짜 기준으로 제거합니다.

```text
settings_effective_summary.json
last_request_headers.json
last_request_body.json
last_response_status.json
dry_run_request_headers.json
dry_run_request_body.json
next_question.txt
last_turn.txt
transcript.md
transcript.jsonl
run_history.md
run_history.jsonl
error.log
```

## run_history 예시

`run_history.md`는 콘솔을 계속 보고 있지 않아도 호출 흐름을 확인할 수 있는 실행 일지입니다. `Seq`는 `run_history.jsonl`을 기준으로 계속 증가하는 누적 번호이고, `Session`은 현재 프로그램 실행 창 안의 `RUN #1`, `RUN #2` 번호입니다.

```text
# Qwen Loop Run History

| Seq | Session | Status | Started | Request | Response | Elapsed | HTTP | Next Wait | Next Run | Question | Next Question | Note |
|---:|---:|---|---|---|---|---:|---|---|---|---|---|---|
| 1 | 1 | ok | 2026-07-06 15:36:32 | 2026-07-06 15:36:32 | 2026-07-06 15:36:32 | 334 ms | 200 OK | 0 min 1 sec (1 sec) | 2026-07-06 15:36:33 | 업무용 React 화면에서 키보드 접근성... | history-follow-up-1 | answer=53 chars, outputTokens=201 |
| 2 | 2 | ok | 2026-07-06 15:36:34 | 2026-07-06 15:36:34 | 2026-07-06 15:36:34 | 130 ms | 200 OK | 11 min 50 sec (710 sec) | 2026-07-06 15:48:24 | history-follow-up-1 | history-follow-up-2 | answer=53 chars, outputTokens=202 |
| 3 | 3 | error | 2026-07-06 15:48:24 | 2026-07-06 15:48:24 | 2026-07-06 15:50:24 | 2 min (120 sec) |  | 8 min 4 sec (484 sec) | 2026-07-06 15:58:28 | history-follow-up-2 |  | 모든 endpoint 호출 실패... |
```

이 예시에서 볼 수 있는 것:

- `Seq 1`, `Seq 2`가 모두 `ok`이고 HTTP가 `200 OK`이면 실제 요청/응답이 정상 완료된 것입니다.
- `Seq 2`의 `Question`이 `Seq 1`의 `Next Question`과 같으면 다음 질문 이어달리기가 정상입니다.
- 마지막 실행이 `-Once`나 `-MaxRuns`로 끝나는 경우에는 `Next Wait`/`Next Run`이 비어 있을 수 있습니다.
- `Status`가 `error`이면 `HTTP`가 비어 있거나 실패 코드가 들어가고, `Note`에 오류 요약이 남습니다.

`run_history.jsonl`은 같은 내용을 한 줄 JSON으로 저장합니다. 사람이 볼 때는 `run_history.md`, 나중에 필터링하거나 집계할 때는 `run_history.jsonl`을 보면 됩니다.

## 문서/산출물 정리 기준

현재 유지하는 기준 문서는 `README.md`, `AGENTS.md`, `CHANGELOG.md`입니다. 과거 대화 요약, 일회성 인수인계 문서, 이전 배포 zip/diff 같은 reference artifact는 현재 실행 기준과 충돌하거나 중복되면 보관하지 않습니다.

`qwen-loop-data`는 예외입니다. 이 폴더는 실행할 때마다 생기는 상태/검증 출력이므로 git에 올리지 않지만, 루프 재시작과 API 검증에는 실제로 사용됩니다. 특히 `run_history.md`는 호출 성공/실패와 다음 실행 예정 시각을 빠르게 보는 운영 일지 역할을 합니다.

## 질문 루프

전체 흐름은 아래처럼 반복됩니다.

```text
+-----------------------------+
| 1. 다음 질문 선택           |
| next_question.txt 우선 사용 |
+--------------+--------------+
               |
               v
+-----------------------------+
| 2. API 요청 생성/전송       |
| settings.json 기반 header   |
| body + 현재 질문            |
+--------------+--------------+
               |
               v
+-----------------------------+
| 3. 응답 수신/상태 표시      |
| HTTP status, retry, preview |
+--------------+--------------+
               |
               v
+-----------------------------+
| 4. NEXT_QUESTION 추출       |
| 답변 첫 줄에서 다음 질문    |
| 파싱                        |
+--------------+--------------+
               |
               v
+-----------------------------+
| 5. 상태/로그 저장           |
| next_question.txt           |
| transcript.md / jsonl       |
| last_turn.txt               |
+--------------+--------------+
               |
               v
+-----------------------------+
| 6. 랜덤 대기                |
| 8-15분 countdown 표시       |
+--------------+--------------+
               |
               v
        다음 루프로 반복
```

핵심은 프로그램이 직접 다음 질문 문장을 조립하지 않는다는 점입니다. 모델에게 답변 첫 줄을 `NEXT_QUESTION:`으로 쓰라고 지시하고, 프로그램은 그 줄을 파싱해서 `next_question.txt`에 저장합니다. 다음 루프에서는 저장된 이 질문을 다시 현재 질문으로 사용합니다.

질문은 아래 순서로 결정됩니다.

1. `qwen-loop-data\next_question.txt`가 있으면 그대로 이어서 사용
2. 없거나 비어 있으면 `transcript.jsonl`의 마지막 `nextQuestion` 복구
3. 그래도 없으면 `transcript.md`의 마지막 `## Next Question` 복구
4. 그래도 없으면 `last_turn.txt`를 바탕으로 복구 질문 생성
5. 완전히 처음이면 `question_bank.txt`에서 랜덤 seed 선택
6. `question_bank.txt`가 없거나 비어 있으면 `seed_prompt.txt` 사용

`question_bank.txt`는 `[java-spring]`, `[react-typescript]`처럼 트랙을 붙인 질문 목록입니다. 특정 트랙만 시작하고 싶으면 `qwen-loop.ps1`에 `-QuestionTrack java-spring`처럼 넘깁니다. 기본 프롬프트는 Java/Spring 질문과 React 질문을 억지로 묶지 않고, 현재 질문의 주 트랙 안에서 더 좁고 검증 가능한 후속 질문을 만들도록 지시합니다.

## 주의

이 루프는 모델 가중치를 실제로 학습시키는 파인튜닝이 아닙니다. 대신 개발 분석 질문/답변 로그를 계속 축적하여 나중에 문서화, RAG, Continue/Qwen 컨텍스트로 재활용하기 위한 도구입니다.
