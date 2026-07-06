# CHANGELOG

## v4 project package

- 프로젝트명 `qwen-dev-loop-orchestrator`로 정리.
- v4 settings-first 스크립트 포함.
- 스크린샷 기반 `settings.json` 파일 추가.
- `.qwen/settings.json` 미러 추가.
- Codex용 `AGENTS.md` 추가.
- 대화 요약 문서 `docs/CONVERSATION_SUMMARY.md` 추가.
- Codex 작업 요청서 `docs/CODEX_HANDOFF.md` 추가.
- 프로젝트 내부 settings를 직접 쓰는 더블클릭 BAT 3개 추가.
- `context_files.txt` 예시 경로의 백슬래시 오류 보정.

## v4 settings-first 기준

- settings.json을 source of truth로 사용.
- envKey를 dummy로 정규화하지 않음.
- generationConfig/general/permissions/ui/version을 가능한 한 반영.
- 기본 전송은 Qwen Code CLI처럼 `X-Stainless-*`/`QwenCode/<version>` header와 streaming body를 사용.
- client identity header는 기본 전송하지 않고 `-LoopDiagnosticHeaders`에서만 동적으로 전송.
- 기본 루프 간격은 매 호출 후 8-15분 사이 랜덤 대기시간을 새로 샘플링.
- 대기 중 CMD 같은 줄 countdown으로 남은 시간과 다음 호출 예정 시각을 표시.
- 실제 응답 수신 후 CMD에 답변 본문 preview와 다음 질문, 저장 경로, 사이클 완료 상태를 표시.
- last_request_headers/body 로그 생성.
- 더블클릭 BAT 기반 실행 흐름 제공.
