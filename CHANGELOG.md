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
- client identity header 전송.
- last_request_headers/body 로그 생성.
- 더블클릭 BAT 기반 실행 흐름 제공.
