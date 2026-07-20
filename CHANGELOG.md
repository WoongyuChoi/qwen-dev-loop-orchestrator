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
- 업무 family가 결정되면 seed 보조 파일, 기본 raw excerpt, 동적 direct/expanded context를 같은 family로 제한하고 generic 기술 심볼을 검색어에서 제외. 대형 Mapper XML은 focus term이 없어도 table/column/comment/statement evidence index를 제공.
- cycle 앞선 turn의 업무 근거를 최대 9,000자 `cycle_evidence.md`로 압축 유지하여 5번째 업무 보고서가 직전 한 답변만 보지 않도록 개선하고, 새 cycle에서는 이 메모리를 초기화.
- 최종 settings-first request body의 실제 `stream` 값과 response Content-Type을 기준으로 transport/SSE·JSON parser를 선택하고 request/parse mode 및 prompt/body 문자 수를 진단 로그에 기록.
- `finish_reason=length|content_filter` 또는 마지막 `NEXT_QUESTION:` 누락 응답을 `partial`로 기록해 성공 turn을 올리지 않고, 답변 첫 제목 대신 명시적인 이어쓰기 질문을 저장하도록 수정.
- retention과 exploration ledger에 프로젝트별 exclusive lock을 적용하고, 삭제 직전 marker/parent/active 상태를 다시 검증하며 session tree 내부 reparse point가 있으면 재귀 삭제하지 않도록 강화. active lock은 top-level `finally`에서 해제.
- WorkDir와 ProjectRoot의 양방향 포함 관계 및 WorkDir reparse ancestry를 거부하고, `.qwen-loop-workdir.json` 소유권을 검증한 폴더에서만 재귀 cleanup을 수행하도록 변경. 기존 non-empty custom WorkDir과 DryRun에서는 cleanup을 비활성화.
- 일반 `qwen-loop-data` cleanup에서 `project` subtree를 완전히 제외하여 timestamp session을 generic size/stale/empty-folder 정책이 건드리지 않고 전용 retention만 관리하도록 분리.

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
- 프로젝트 모드는 기존 답변을 이어받지 않는 fresh session으로 시작하되, 기존 `qwen-loop-data` 최근 질문은 중복 회피용으로만 참고.
- 서버가 usage를 반환하면 입력/출력/전체 token 수와 light/balanced/rich 색상 등급을 표시.
- `qwen-loop-data` 자동정리를 추가해 큰 transcript/error 로그와 오래된 check 산출물을 임계치 기준으로 정리.
- last_request_headers/body 로그 생성.
- 더블클릭 BAT 기반 실행 흐름 제공.
