# CHANGELOG

## v1.8.0

- 더블클릭 프로젝트 모드를 canonical ProjectRoot의 short hash identity와 기동 timestamp를 조합한 독립 session WorkDir 방식으로 변경. leaf 이름이 같은 서로 다른 프로젝트의 상태 충돌과 재기동 시 이전 대화 복구를 방지.
- `run-qwen-loop.bat` 프로젝트 모드에 `-NewProjectSession`, `-FreshProjectQuestion`, `-ProjectTurnsPerCycle 5`, session newest 12개/30일/프로젝트별 750MB retention 기본값을 적용.
- 프로젝트별 `exploration_history.jsonl`을 이전 대화 복구가 아닌 이미 탐색한 primary 업무 영역의 negative coverage로 사용하고, 다른 프로젝트의 raw 질문 히스토리가 새 대화를 끌고 가지 않도록 범위를 분리.
- 성공 응답 5회마다 이전 cycle 문맥을 끊고 프로젝트를 다시 스캔하여, 최근 업무 family/file을 피한 새 primary 업무 영역에서 다음 cycle을 시작하도록 개선. 실패한 API 호출은 cycle turn으로 계산하지 않음.
- Service/Mapper/트랜잭션 중심의 기술 점수 편향을 줄이고 Mapper XML의 테이블·컬럼·주석, VO/DTO 필드, Tasklet/JobParameter, 상태값과 연결된 업무 family를 우선 탐색하도록 domain-first 분석 방향을 강화.
- 답변을 업무 시나리오·용어/데이터 계약·정상 흐름·근거와 불확실성·마지막 기술 리스크 순서로 작성하고, 분석을 마친 뒤 마지막 줄에 `NEXT_QUESTION:`을 생성하도록 prompt 계약을 변경.
- 프로젝트 답변에 충분한 깊이의 soft output 목표를 추가하고 `max_tokens`는 목표 사용량이 아니라 settings-first/model 호환 출력 상한이라는 점을 명확화. focused business evidence를 우선하여 무조건적인 입력 증액으로 인한 attention dilution을 방지.
- `TokenUse`를 short/developed/extended 중립 표시로 바꾸고 `AnswerDepth`에 `finish_reason`, reasoning/visible output token, 실제 output 상한, 답변 글자 수, 목표 달성률과 context yield를 저장.
- session identity marker와 active lock을 기준으로 현재/실행 중 세션을 retention에서 보호하고, 인식된 비활성 timestamp session만 count/day/aggregate-size 정책으로 정리하도록 안전 경계를 강화.
- 외부 API 없이 Fresh 차단, session/retention, 5턴 cycle, 업무 evidence slice, 마지막 줄 후속 질문 parser와 응답 진단을 검증하는 Mock SSE smoke test를 추가.
- `-NewProjectSession` 없이 `qwen-loop.ps1 -ProjectRoot ... -WorkDir ...`를 직접 호출하는 기존 continuation 경로는 호환 유지.
- 업무 family가 결정되면 seed 보조 파일, 기본 raw excerpt, 동적 direct/expanded context를 같은 family로 제한하고 generic 기술 심볼을 검색어에서 제외. 단, active 파일의 import/Mapper `resultType` 등 data-contract가 파일명을 정확히 참조한 경우에만 외부 family 파일을 증거 전용으로 최대 3개 허용하며 새 주제로 삼지 않음. 대형 Mapper XML은 focus term이 없어도 table/column/comment/statement evidence index를 제공.
- cycle 앞선 turn의 업무 근거를 최대 9,000자 `cycle_evidence.md`로 압축 유지하여 5번째 업무 보고서가 직전 한 답변만 보지 않도록 개선하고, 새 cycle에서는 이 메모리를 초기화.
- 최종 settings-first request body의 실제 `stream` 값과 response Content-Type을 기준으로 transport/SSE·JSON parser를 선택하고 request/parse mode 및 prompt/body 문자 수를 진단 로그에 기록.
- `finish_reason=length|content_filter` 또는 마지막 `NEXT_QUESTION:` 누락 응답을 `partial`로 기록해 성공 turn을 올리지 않고, 답변 첫 제목 대신 명시적인 이어쓰기 질문을 저장하도록 수정.
- retention과 exploration ledger에 프로젝트별 exclusive lock을 적용하고, 삭제 직전 marker/parent/active 상태를 다시 검증하며 session tree 내부 reparse point가 있으면 재귀 삭제하지 않도록 강화. active lock은 top-level `finally`에서 해제.
- WorkDir와 ProjectRoot의 양방향 포함 관계 및 WorkDir reparse ancestry를 거부하고, `.qwen-loop-workdir.json` 소유권을 검증한 폴더에서만 재귀 cleanup을 수행하도록 변경. 기존 non-empty custom WorkDir과 DryRun에서는 cleanup을 비활성화.
- 일반 `qwen-loop-data` cleanup에서 `project` subtree를 완전히 제외하여 timestamp session을 generic size/stale/empty-folder 정책이 건드리지 않고 전용 retention만 관리하도록 분리.
- 프로젝트 후보 탐색의 디렉터리별 random sampling을 제거하고 정렬된 per-cycle candidate index를 scan과 동적 lookup이 함께 재사용하도록 변경. 기본 10,000 files/10,000 directories/content scan 2,500 files/파일당 4MB 상한과 truncation 진단을 추가.
- 프로젝트 소스 읽기에서 BOM/XML encoding declaration을 인식하고 BOM 없는 UTF-8을 strict 검증한 뒤 CP949로 fallback하여 구형 Java/MyBatis 프로젝트의 한글 업무 주석을 보존. 생성되는 상태/로그 파일은 계속 UTF-8로 유지.
- 상태 파일 쓰기를 같은 디렉터리의 임시 파일과 atomic replace/move 방식으로 변경하여 중간 종료 시 기존 파일 대신 반쪽 JSON/text가 노출될 가능성을 줄임.
- timestamp session뿐 아니라 일반·legacy·DryRun을 포함한 모든 WorkDir에서 process lifetime 동안 `.active.lock` exclusive handle을 유지하여 동일 상태 경로를 쓰는 두 프로세스의 seq/transcript/next-question 경합을 차단.
- 프로젝트 응답 성공 판정에 누적 visible token 또는 글자 수 목표와 업무 근거 signal 수를 함께 확인하는 quality gate를 추가. 기본 2회까지만 원 질문 중심 보강을 허용하고 계속 부실하거나 불완전하면 해당 slice를 `abandoned`로 기록한 뒤 새 업무 family rescan을 예약.
- `partial_state.json`에 원 질문, 누적 분량·근거 excerpt, 보강 횟수를 저장하여 continuation 문구가 재귀 중첩되지 않게 하고, 후속 조각이 누적 근거를 반영한 자기완결형 분석인지 확인하도록 보강. `-ProjectQualityMinEvidenceSignals`, `-ProjectMaxContinuationAttempts`, `-NoProjectQualityGate` 옵션을 추가.
- SSE `data:` event와 non-stream JSON을 strict parsing하여 malformed JSON, API error payload, 빈 choices/text를 raw 답변으로 저장하지 않고 protocol error로 처리.
- turn 요청 전 `pending_turn.json`을 저장하고 `transcript.jsonl.stateAfter`를 canonical journal로 사용하여 응답 audit 뒤 상태 commit 중 종료되어도 next/partial/exploration/last-turn을 roll-forward하도록 보강. durable seq는 run-history/transcript/pending 최대값 다음을 사용하고 torn JSONL 뒤의 새 record는 별도 줄로 격리.
- cycle 전환을 `pending_cycle_transition.json`으로 stage하고 per-cycle scan snapshot/ledger/derived files 기록 후 `exploration_state.json`을 commit pointer로 저장. 재기동 시 transitionId/nextCycle이 이미 commit됐는지 판별하고 정확히 같은 cycle을 복구하여 추가 cycle skip과 ledger 중복을 방지하며, stable legacy project에도 성공 5회 경계를 적용.
- 새 cycle 첫 요청은 이전 cycle의 last-turn/question history/evidence를 비우고, 현재 WorkDir·현재 cycle의 질문만 사용할 수 있게 제한. 다른 WorkDir/ProjectRoot transcript 전문을 prompt에 넣던 전역 history 경로를 제거.
- 빈 `finish_reason=length|content_filter` choice는 protocol error가 아닌 정상 incomplete response로 분류하고, SSE의 다중 choice는 non-stream과 동일하게 index 0만 조립하도록 수정.
- 더블클릭 BAT 진입점이 PowerShell 종료 코드를 `pause` 전에 저장하고 이후 `exit /b`로 그대로 반환하도록 변경.
- `settings_effective_summary.json.settingsCoverage`에 `env`, `modelProviders`, `generationConfig`, `general`, `permissions`, `security`, `ui`, `$version`의 applied/prompt-only/not-applicable 범위를 명시하고, Qwen Code `User-Agent` 버전 출처(`-QwenCodeVersion` → `QWEN_CODE_VERSION` → `unknown`)를 별도 진단하도록 보강. settings schema `$version`은 package version으로 사용하지 않음.
- 유한 `-Once`/`-MaxRuns` 실행은 정상 완료 0, HTTP/API/parser/state 오류 1, 종료 시 아직 fresh rescan으로 해소되지 않은 partial/abandoned 상태 2를 반환하도록 구분.
- ProjectRoot/WorkDir/session identity를 기존 ancestor의 physical path로 정규화하여 drive-letter/UNC alias로 containment·retention 경계를 우회하지 못하게 하고, 양쪽 reparse ancestry를 거부하도록 강화.
- session marker를 `initializing`으로 먼저 기록하고 scan/question 준비 완료 뒤에만 `ready`로 전환. 새 session lock 확보 직후 이전 비활성 `initializing`/`failed` sibling만 제거하는 abandoned-only pass를 추가하여 반복 초기 scan 실패가 누적되지 않게 하면서 ready evidence는 보존.
- retention tree 삭제를 reparse point 비추적·non-recursive 방식으로 변경하고 `.active.lock`을 모든 다른 descendant 뒤에 해제하여 새 lifetime owner가 생기는 경합에서도 root 삭제가 안전하게 실패하도록 보강.
- scanner secret sanitizer를 v3로 올려 PEM/Kubernetes Secret, JSON·YAML next-line/container 값, properties continuation, direct/attribute multiline XML element와 child value를 전체 범위에서 제거하고 이전 sanitizer snapshot은 재사용하지 않도록 변경.
- dynamic context가 exact import/Mapper `resultType` 등 cross-family data-contract evidence 슬롯을 same-family 확장보다 먼저 최대 3개 예약하도록 수정.
- SSE 완결 조건을 `[DONE]` 또는 primary choice index 0의 terminal `finish_reason`으로 엄격화하고, response가 시작된 뒤 read timeout/parser/acceptance 오류는 전달 불명확성을 이유로 동일 process에서 재시도하지 않도록 변경.
- HTTP 오류 body 읽기 자체가 timeout되어도 이미 확인된 status code를 보존하여 4xx/5xx retry 판정을 정확히 유지.
- `generationConfig.samplingParams`에 temperature만 있어도 model output token cap을 유지하고, custom `User-Agent`/`Content-Type`을 실제 wire와 summary에 반영하며 `-CompatBody`의 설정 적용 범위를 `partially-applied`로 진단.
- provider 선택·base URL·generation timeout 검증을 session 생성 전에 fail-closed로 수행하고 URL userinfo 및 비정상/무한 timeout을 거부.
- generationConfig custom-header 값과 permissions hint의 비밀값이 system prompt/request body에 중복 노출되지 않도록 prompt metadata를 key/shape 중심으로 제한하고 sanitizer를 적용.
- canonical turn journal이 없는 delivery-unknown 재기동에서 동일 질문을 자동 재전송하지 않고 alternate seed/project escape로 이동하며, torn JSONL은 유효한 diagnostic record로 격리하도록 복구 경계를 강화.
- loopback mock SSE/JSON 회귀 suite와 Pester wrapper를 확장하여 scanner/secret/reparse, session lifecycle/lock/retention, quality continuation, response-started timeout, settings precedence, atomic turn/cycle recovery를 검증.
- `-MaskSensitiveLogs`가 header뿐 아니라 저장용 request body와 settings generationConfig의 중첩 비밀값/알려진 API-key literal도 재귀 sanitize하도록 보강하되 실제 wire object는 변경하지 않음.
- `-CompatBody`에서 어차피 생략되는 samplingParams의 token-key 충돌을 사전 오류로 만들지 않도록 수정하고, `-NoClientIdentityHeaders` 사용 시 PC/user/IP를 수집·출력·기록하지 않으면서 generic 진단 header만 유지하도록 진단 provenance를 정정.
- settings summary에 실제 `$version` schema 값과 effective `Content-Type` 출처를 추가.
- PowerShell pipeline unrolling으로 singleton/empty settings 배열이 scalar/null로 변하던 문제를 수정하여 `stop`과 provider extension의 nested JSON array shape를 wire/log 모두에서 보존.

## v4 project package

- 프로젝트명 `qwen-dev-loop-orchestrator`로 정리.
- v4 settings-first 스크립트 포함.
- 스크린샷 기반 `settings.json` 파일 추가.
- `.qwen/settings.json` 미러 추가.
- Codex용 `AGENTS.md` 추가.
- README에 실행 방법, CMD 출력 예시, 질문 루프 흐름을 통합.
- `run-qwen-loop.bat`에 1번 랜덤 질문 루프 / 2번 프로젝트 디렉터리 루프 선택 메뉴를 추가.
- 프로젝트 디렉터리 루프는 입력한 디렉터리를 로컬 스캔해 `project_scan_summary.md/json`을 만들고, 별도 WorkDir에서 프로젝트 기반 질문으로 시작.
- 과거 대화 요약/인수인계 문서와 이전 배포 reference artifact는 현재 기준 문서로 흡수 후 제거.
- 프로젝트 내부 settings를 직접 쓰는 더블클릭 BAT 3개 추가.
- `context_files.txt` 예시 경로의 백슬래시 오류 보정.

## v4 settings-first 기준

- settings.json을 source of truth로 사용.
- envKey를 dummy로 정규화하지 않음.
- generationConfig/general/permissions/ui/version을 가능한 한 반영.
- 기본 전송은 Qwen Code CLI처럼 `X-Stainless-*`/`QwenCode/<version>` header와 streaming body를 사용.
- client identity header는 기본 전송하지 않고 `-LoopDiagnosticHeaders`에서만 동적으로 전송.
- CMD 시작 화면에 `Qwen Loop Scheduler` ASCII 배너와 작은 터미널 아바타를 표시.
- 통신 실패 시 기본 3회 즉시 retry를 수행하고 `X-Stainless-Retry-Count`를 실제 시도 횟수에 맞게 증가.
- 기본 루프 간격은 매 호출 후 8-15분 사이 랜덤 대기시간을 새로 샘플링.
- 대기 중 CMD 같은 줄 countdown으로 남은 시간과 다음 호출 예정 시각을 표시.
- 실제 응답 수신 후 CMD에 답변 본문 preview와 다음 질문, 저장 경로, 사이클 완료 상태를 표시.
- `run_history.md`/`run_history.jsonl`에 호출 seq, 시작/응답/다음 실행 예정 시각, HTTP 상태를 누적 기록.
- 프로젝트 모드는 기존 답변을 이어받지 않는 fresh session으로 시작하고, project-scoped exploration ledger의 업무 family/path만 중복 회피용 negative coverage로 사용. 다른 WorkDir의 과거 질문/답변 전문은 새 prompt에 포함하지 않음.
- 서버가 usage를 반환하면 입력/출력/전체 token 수와 light/balanced/rich 색상 등급을 표시.
- `qwen-loop-data` 자동정리를 추가해 큰 transcript/error 로그와 오래된 check 산출물을 임계치 기준으로 정리.
- last_request_headers/body 로그 생성.
- 더블클릭 BAT 기반 실행 흐름 제공.
