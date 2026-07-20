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
9. 프로젝트 모드는 기술 호출 그래프 자체보다 업무 도메인·사용자/배치 시나리오·업무 용어·정상 데이터 흐름을 먼저 복원한다. Mapper XML의 테이블/컬럼/주석, VO/DTO 필드와 주석, JobParameter와 상태값을 근거로 삼고 트랜잭션·패턴·성능·보안은 업무 영향 또는 마지막 리스크 점검으로 다룬다.
10. 더블클릭 프로젝트 모드는 매 기동마다 독립 세션을 만든다. 이전 세션의 질문/답변을 새 대화 컨텍스트로 복구하지 않으며, 프로젝트별 `exploration_history.jsonl`은 이미 탐색한 업무 영역을 피하기 위한 negative coverage로만 사용한다.

## 주요 파일

- `qwen-loop.ps1`: 메인 루프 실행 로직
- `check-qwen-loop.bat`: 실제 호출 없이 사용자/프로젝트 settings를 순차 DryRun하는 권장 체크 진입점
- `run-qwen-loop.bat`: 실제 사용자 설정 기준 메인 루프 실행 진입점. 1번은 기존 랜덤 질문 루프, 2번은 canonical 프로젝트 경로 hash identity 아래 timestamp WorkDir를 만드는 프로젝트 디렉터리 새 세션
- `settings.json`: 스크린샷 기반으로 재구성한 Qwen Code 설정 파일
- `.qwen/settings.json`: 실제 사용자 경로 구조를 프로젝트 내부에 미러링한 파일
- `seed_prompt.txt`: question bank가 비었을 때 사용하는 단일 fallback 질문
- `question_bank.txt`: 트랙별 초기 질문 seed 모음
- `01_CHECK_SETTINGS_DOUBLECLICK.bat`: `%USERPROFILE%\.qwen\settings.json` 기준 DryRun
- `02_RUN_ONCE_TEST_DOUBLECLICK.bat`: 실제 사용자 설정 기준 1회 호출
- `03_RUN_LOOP_10MIN_DOUBLECLICK.bat`: 실제 사용자 설정 기준 8-15분 랜덤 간격 루프
- `06_CHECK_PROJECT_SETTINGS_DOUBLECLICK.bat`: 프로젝트 내부 `settings.json` 기준 DryRun
- `07_RUN_ONCE_PROJECT_SETTINGS_DOUBLECLICK.bat`: 프로젝트 내부 `settings.json` 기준 1회 호출
- `08_RUN_LOOP_10MIN_PROJECT_SETTINGS_DOUBLECLICK.bat`: 프로젝트 내부 `settings.json` 기준 8-15분 랜덤 간격 루프

## 테스트 체크리스트

- `check-qwen-loop.bat` 더블클릭 시 사용자/프로젝트 settings DryRun이 순차적으로 정상 실행되는지 확인한다.
- `run-qwen-loop.bat` 더블클릭 시 1번/2번 모드 선택 메뉴가 표시되는지 확인한다. 2번은 `qwen-loop-data/project`를 세션 루트 WorkDir로 넘기고 `-NewProjectSession -FreshProjectQuestion -ProjectTurnsPerCycle 5 -ProjectSessionKeepCount 12 -ProjectSessionKeepDays 30 -ProjectSessionMaxTotalMB 750`를 사용해야 한다.
- 동일 canonical ProjectRoot는 동일한 `<project-name>-<path-hash>` identity를 사용하고, 기동할 때마다 그 아래 `sessions/<yyyyMMdd-HHmmss-fff>-p<PID>-<suffix>` WorkDir를 새로 만드는지 확인한다. leaf 이름이 같은 서로 다른 프로젝트는 hash가 달라야 하며, 새 세션의 첫 요청에는 이전 세션의 `next_question.txt`, `last_turn.txt`, transcript 질문/답변이 들어가지 않아야 한다.
- 프로젝트 디렉터리 모드에서 `project_scan_summary.md`와 `project_scan_summary.json`이 생성되고, `settings_effective_summary.json.projectScan`에 root/scanned/selected/stack 정보가 들어가는지 확인한다.
- 프로젝트 디렉터리 모드는 fresh scan seed에서 업무 family/group을 먼저 샘플링하고 그 안의 대표 파일을 primary question target으로 뽑는지 확인한다. `project_scan_summary.*`에는 primary 업무 group/family와 후보가 남아야 하며, Service/Mapper/`@Transactional` 같은 기술 점수만 높은 core/common 영역이 질문을 독점하지 않아야 한다. Mapper XML·VO/DTO·Tasklet/Job의 업무 주석, 테이블/컬럼, 필드, 파라미터, 상태값이 primary와 보조 근거에 포함되어야 한다.
- 첫 질문과 답변은 1) 누가 언제 왜 수행하는 업무인지, 2) 업무 용어와 데이터 계약, 3) 입력→판단/변환→저장→소비 정상 흐름, 4) 근거 파일과 확인/추론/미확인 구분, 5) 마지막 기술 리스크 순서로 전개해야 한다. 연결 파일은 미해결 업무 질문을 확인하는 증거로 사용하고, 파일/import 자체를 다음 주제로 삼지 않는다.
- 성공 응답 5회 뒤 다음 요청 전에 fresh rescan cycle이 시작되고 새로운 업무 family/primary를 선택하는지 확인한다. HTTP/API 실패와 `finish_reason=length|content_filter`/`NEXT_QUESTION:` 누락 partial 응답은 5회에 포함하지 않는다. 같은 cycle에서는 `cycle_evidence.md` 압축 근거를 다음 turn과 5번째 업무 보고서에 제공하되, 새 cycle 첫 요청은 이전 cycle의 `last_turn`, 질문 히스토리, cycle evidence를 컨텍스트로 재사용하지 않아야 한다.
- 프로젝트 identity 루트의 `exploration_history.jsonl`은 최근 primary 업무 영역을 재선택하지 않기 위한 project-scoped negative coverage만 저장/제공해야 한다. 다른 ProjectRoot의 transcript 또는 과거 질문/답변 전문을 새 prompt에 넣어 구체 클래스명으로 다시 유도하지 않아야 하며, 후보를 모두 소진했을 때만 cooldown을 단계적으로 완화한다.
- 프로젝트 디렉터리 모드는 매 RUN마다 현재 업무 질문에서 파일명/클래스명/메서드명/설정키/SQL placeholder 후보를 뽑아 프로젝트에서 관련 파일을 best-effort로 다시 찾고, 발견한 업무 증거 excerpt를 compact base index 앞에 붙이며 `last_dynamic_project_context.json`에 검색어/찾은 파일/누락 검색어를 남기는지 확인한다. 프로젝트에 없는 파일이나 외부 라이브러리명은 전송하지 않고 누락으로 기록하되 루프를 실패시키지 않는다. active business family 밖의 파일은 active 파일의 import/Mapper `resultType` 등 data-contract가 파일명을 정확히 참조한 경우에만 증거 전용으로 최대 3개 허용하고, same-family 확장보다 먼저 이 슬롯을 예약하되 해당 파일을 다음 업무 주제로 승격하지 않아야 한다.
- 프로젝트 후보 수집은 디렉터리별 random sampling 없이 정렬된 deterministic index를 cycle마다 한 번 만들고 같은 cycle의 동적 lookup에서 재사용해야 한다. 기본 10,000 files/10,000 directories/content scan 2,500 files/파일당 4MB 상한을 적용하고, candidate index 상한에 도달하면 `project_scan_summary.*` 진단에 truncation이 표시되어야 한다.
- BOM/XML declaration/strict UTF-8/CP949 순서의 프로젝트 소스 decoding을 검증하고, CP949로 저장된 Java/XML의 한글 업무 주석·컬럼 설명이 `�`로 깨지지 않은 채 scan evidence와 실제 prompt에 포함되는지 확인한다. 생성 산출물은 계속 UTF-8이어야 한다.
- 세션 retention은 기본 newest 12개, 30일, 프로젝트 identity별 합계 750MB 정책을 적용하되 현재 세션과 active lock을 보유한 다른 세션을 삭제하지 않아야 한다. 새 session lifetime lock/identity/ownership을 확보한 직후에는 이전의 strict-identity 비활성 `initializing`/`failed` sibling만 abandoned-only pass로 정리하여 반복 scan 실패가 누적되지 않게 하고, 현재가 ready가 된 뒤에만 ready count/day/size 정책을 적용한다. `-NoAutoCleanup`/DryRun은 두 정리를 모두 생략한다. 프로젝트별 retention lock 아래에서 삭제 직전 identity marker/physical parent/root/state/active 상태를 다시 확인하고, identity marker가 맞는 인식된 비활성 session directory만 정리한다. legacy/unmarked 경로, 내부에 reparse point가 있는 session tree, scanned ProjectRoot는 건드리지 않으며 `.active.lock`은 모든 다른 descendant 뒤, root의 non-recursive delete 직전에만 해제해야 한다.
- 일반 WorkDir 재귀 cleanup은 해당 경로와 일치하는 `.qwen-loop-workdir.json` 소유권 marker가 있을 때만 수행한다. 기존 non-empty custom WorkDir을 임의로 소유 처리하지 않고, WorkDir/ProjectRoot 양방향 포함 관계를 drive/UNC alias까지 physical path로 확인하며 양쪽의 reparse ancestry를 거부하고, DryRun에서는 cleanup을 전혀 수행하지 않아야 한다.
- 일반/legacy project/DryRun/timestamp session 모두 상태 파일을 쓰기 전에 WorkDir의 `.active.lock` exclusive handle을 획득하고 top-level `finally`까지 유지해야 한다. 같은 stable WorkDir의 두 번째 프로세스는 HTTP 요청이나 transcript/run-history 변경 전에 비정상 종료하고, 첫 프로세스 종료 후에는 남아 있는 unlocked lock 파일 때문에 재실행이 막히지 않아야 한다.
- 일반 모드의 `qwen-loop-data` cleanup은 `qwen-loop-data/project` 하위 전체를 용량 계산·stale file·빈 폴더 정리 대상에서 제외해야 한다. 프로젝트 timestamp session 삭제는 session marker/active lock을 검증하는 전용 retention만 수행한다.
- 직접 `qwen-loop.ps1 -ProjectRoot <path> -WorkDir <stable-path>`를 `-NewProjectSession` 없이 호출하는 고급 경로에서는 기존 `next_question.txt`/transcript/`last_turn.txt` continuation 호환을 유지한다. 이 legacy 경로의 `-FreshProjectQuestion`은 같은 WorkDir 안의 fresh seed만 제어한다.
- `02_RUN_ONCE_TEST_DOUBLECLICK.bat` 또는 `07_RUN_ONCE_PROJECT_SETTINGS_DOUBLECLICK.bat` 더블클릭 시 `NEXT_QUESTION` 한글이 깨지지 않는지 확인한다.
- `qwen-loop-data/last_request_headers.json`과 `last_request_body.json`에 settings 기반 정보가 반영되는지 확인한다. transport에 적용되는 custom header/generationConfig 비밀값을 system prompt에 다시 직렬화하지 않고 key/shape만 안내하며, permissions prompt hint도 secret sanitizer를 통과해야 한다. `settings_effective_summary.json.settingsCoverage`에는 `env`/`modelProviders`/`generationConfig`/`general`/`permissions`/`security`/`ui`/`$version` 각각의 실제 applied·partially-applied·prompt-only·not-applicable·diagnostic-only 범위가 기록되고 `settingsSchemaVersion`에 실제 `$version` 값이 남아야 하며, `-CompatBody`는 samplingParams/extra_body 생략을 `partially-applied`로 보고해야 한다.
- `-MaskSensitiveLogs`는 실제 wire body를 바꾸지 않고 저장용 header/request body/settings generationConfig 사본만 재귀 sanitize해야 한다. nested password/token/Authorization/API-key 값, 알려진 API key의 exact 값과 충분히 긴 embedded literal은 로그에서 제거하되 `max_tokens`·`token_budget` 같은 비민감 설정은 유지하고, 기본 비마스킹 또는 명시적 `-LogSensitive`에서는 내부 API 검증용 raw 값을 유지해야 한다.
- `qwen-loop-data/run_history.md`에서 호출 seq, started/request/response, HTTP, next run 시각이 누적되는지 확인한다.
- `dry_run_request_headers.json`에서 기본 `User-Agent: QwenCode/<version> (win32; x64)`와 `X-Stainless-*`가 보이고 `X-Qwen-Loop-*` 진단 헤더가 기본으로 빠져 있는지 확인한다. Qwen Code version은 `-QwenCodeVersion` → OS `QWEN_CODE_VERSION` → `unknown` 순서로 결정하고, non-null `generationConfig.customHeaders.User-Agent`/`Content-Type`이 있으면 실제 wire header를 덮어써야 한다. `settings_effective_summary.json.qwenCompat`에는 최종 값과 출처를 기록하며 settings schema `$version`을 package version으로 오인하지 않아야 한다.
- retry 기본값은 `MaxRetries=3`이며 retry 시 `X-Stainless-Retry-Count`가 시도 횟수에 맞게 증가하는지 확인한다.
- 서버가 usage를 반환하면 `TokenUse`가 input/output/total과 short/developed/extended 중립 진단으로 표시되고, `AnswerDepth`에 visible output, 목표 달성 여부, context yield, `finish_reason`, reasoning token, 실제 `max_tokens` 상한이 별도로 기록되는지 확인한다.
- 프로젝트 답변 prompt는 기본적으로 약 3,500 output token / 8,000자 수준의 충분한 업무 분석을 soft target으로 요청하되 입력이 부족하면 억지로 채우지 않아야 한다. `max_tokens`는 생성 목표가 아니라 출력 상한이며, 짧은 응답의 원인을 판단할 때 actual output token과 `finish_reason`을 함께 확인한다.
- 프로젝트 응답은 마지막 `NEXT_QUESTION:`/finish reason뿐 아니라 누적 visible output 3,500 tokens 또는 8,000자와 기본 3개의 서로 다른 업무 근거 signal을 quality gate로 확인해야 한다. 미달 응답은 successful turn을 올리지 않고 원 질문 중심 보강을 기본 2회까지만 수행하며, bounded 누적 evidence excerpt를 다음 prompt에 제공하되 continuation 문구를 재귀 중첩하지 않고 현재 답변만으로도 완결된 통합 분석을 요구해야 한다. 한도를 소진하면 해당 run을 `abandoned`로 기록하고 다음 요청 전에 이전 답변 문맥을 재사용하지 않는 fresh family rescan으로 탈출해야 한다. `-NoProjectQualityGate`는 분량/근거 gate만 끄고 protocol 완결성 검증은 끄지 않아야 한다.
- Runtime Summary에 `AutoCleanup`/`Cleanup`이 표시되고, 큰 transcript/error 로그와 오래된 check 산출물은 정리되되 `next_question.txt`와 `last_turn.txt`는 보존되는지 확인한다.
- `dry_run_request_body.json`에서 기본 `stream: true`, `stream_options.include_usage: true`인지 확인한다. `generationConfig.samplingParams`/`extra_body`가 `stream`을 덮어쓰면 최종 body의 effective stream 값이 transport에 적용되고 response Content-Type 기준으로 SSE/JSON parser가 선택되는지 확인한다. `stream:false` body에는 `stream_options`를 남기지 않는다. sampling 설정이 없거나 `temperature` 같은 다른 값만 있으면 Qwen Code 호환 model output limit을 `max_tokens` 상한으로 유지하며 임의의 작은 출력 목표값으로 오해해 낮추지 않는다. settings의 empty/single/multi/nested 배열은 scalar/null로 collapse되지 않고 JSON array shape를 유지해야 한다. `-CompatBody`는 timeout/customHeaders는 적용하되 samplingParams/extra_body를 생략해야 한다.
- `settings_effective_summary.json`에서 기본 interval이 `random`이고 `minSeconds=480`, `maxSeconds=900`인지 확인한다.
- 일반 모드와 `-NewProjectSession` 없는 legacy 직접 호출은 `next_question.txt`가 있으면 이어가고, 없으면 `transcript.jsonl`/`transcript.md`에서 복구한 뒤 마지막 fallback으로 `question_bank.txt` 랜덤 seed를 사용한다. 더블클릭 프로젝트 새 세션에는 이 continuation 규칙을 적용하지 않는다.
- 프로젝트 응답은 상세 업무 분석을 먼저 작성하고 **마지막 줄**에 자기완결적인 `NEXT_QUESTION:`을 하나만 출력해야 한다. parser가 마지막 control line을 추출하고 한글을 깨뜨리지 않은 채 `next_question.txt`에 저장하는지 확인한다. control line이 없거나 응답이 길이 제한으로 잘리면 답변 첫 줄을 질문으로 오인하지 말고 explicit continuation을 저장하며 run status를 `partial`로 남겨야 한다.
- malformed SSE `data:` JSON, OpenAI error payload, invalid/empty non-stream JSON, choices에 textual completion이 없는 응답, `[DONE]` 또는 primary index 0의 terminal `finish_reason` 없이 끝난 SSE는 raw wire text를 답변으로 저장하지 말고 protocol error로 처리해야 한다. 단, 빈 choice라도 `finish_reason=length|content_filter`가 명시되면 정상 수신된 incomplete response로 보아 bounded partial 경로를 사용한다. HTTP response header/body가 시작된 뒤 read timeout/parser/local state 오류가 나면 전달 여부가 불명확하므로 같은 process에서 retry하지 않는다. 진짜 protocol error는 `last_response_status.json.ok=false`, run history `status=error`가 남고 transcript/next question이 오염되지 않으며, 유한 실행은 exit code 1을 반환해야 한다.
- `-Once`/`-MaxRuns` 유한 실행은 모든 요청이 정상 완결되면 0, HTTP/API/parser/state run error가 있으면 1, 종료 시 unresolved partial 또는 아직 다음 fresh rescan으로 탈출하지 못한 bounded abandonment가 남으면 2를 반환해야 한다. 후속 run에서 fresh rescan과 정상 응답까지 완료했다면 과거 abandonment만으로 2를 유지하지 않아야 한다. main launcher와 단일 PowerShell run을 호출하는 numbered BAT는 직후 이 값을 저장해 `pause` 이후 동일한 `exit /b` 값으로 전달하고, `check-qwen-loop.bat`는 두 DryRun 결과를 boolean 실패 코드로 집계해야 한다.
- turn commit은 `pending_turn.json`을 먼저 저장하고 `transcript.jsonl`의 동일 seq/question `stateAfter`를 canonical journal로 삼아야 한다. audit 이후 상태 저장 중 종료되면 재기동에서 partial/exploration/last-turn/next-question을 roll-forward하고, canonical 완료 record가 없는 delivery-unknown request의 동일 질문은 자동 재전송하지 않고 general alternate seed/project escape question으로 벗어나야 한다. seq는 run-history/transcript/pending의 최대값 다음으로 이어가고, torn JSONL 마지막 줄은 이후 record와 newline으로 격리하며 size cleanup 시 원문 prefix를 유효한 진단 JSON record로 보존해야 한다.
- cycle 전환은 pending transition marker를 먼저 원자 저장하고 cycle snapshot/ledger/파생 상태를 기록한 뒤 `exploration_state.json`을 commit pointer로 저장해야 한다. 중간 실패로 pending marker가 남은 재기동에서는 transitionId와 nextCycle을 검증하여 정확히 그 cycle로 roll-forward하고 이미 commit된 marker만 정리하며, cycle을 한 번 더 증가시키거나 history를 중복 기록하지 않아야 한다. scan snapshot은 현재 sanitizer schema/version만 재사용하고 이전 버전은 fresh scan으로 다시 만들어야 한다.
- scanner는 secret-like 파일, directory/file reparse point를 제외하고 PEM, Kubernetes Secret, JSON/YAML/properties의 next-line·continuation 값, multiline XML sensitive element/attribute와 child value가 scan summary/dynamic context/live prompt 어느 표면에도 노출되지 않는지 fixture로 검증해야 한다.
- `qwen-loop-data/transcript.md`와 `next_question.txt`가 UTF-8 한글로 저장되는지 확인한다.
- 서버가 extra body를 거부하면 `04_RUN_LOOP_10MIN_COMPAT_BODY_IF_SERVER_REJECTS.bat` 또는 `-CompatBody` 경로를 검토한다.
