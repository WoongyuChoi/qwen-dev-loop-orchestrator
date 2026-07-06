# Codex 작업 요청서

## 프로젝트명

`qwen-dev-loop-orchestrator`

## 목표

Windows 11 환경에서 Qwen Code용 `settings.json`을 최대한 그대로 활용하여, OpenAI-compatible Qwen 서버에 주기적으로 질문을 보내는 로컬 루프 스케줄러를 안정화한다.

## 현재 동작 목표

1. 사용자가 BAT 파일을 더블클릭한다.
2. 스크립트가 `settings.json`을 읽는다.
3. 선택된 provider/model/baseUrl/envKey/generationConfig를 해석한다.
4. 1회 또는 10분 루프로 AI에게 질문을 보낸다.
5. 응답 첫 줄의 `NEXT_QUESTION:`을 다음 질문으로 저장한다.
6. 질문/답변/다음질문/요청 헤더/요청 바디를 로그로 남긴다.
7. Ctrl+C 전까지 계속 반복한다.

## 가장 중요한 개선 포인트

- Windows 11 cmd에서 한글이 깨지지 않는지 실제 검증
- PowerShell 5.1과 PowerShell 7 양쪽 호환성 검토
- `settings.json`의 모든 의미 있는 필드를 request body, header, system prompt 중 어디에 반영할지 명확히 정리
- 서버가 extra field를 거부할 때 fallback 경로 정리
- Client IP 헤더 생성 로직 안정화
- 민감정보 마스킹 정책 정리
- 실행 파일 이름과 README를 사용자가 더블클릭만으로 이해할 수 있게 정리

## 절대 하지 말 것

- `envKey` 값이 비어 보인다고 임의로 `dummy`로 바꾸지 말 것
- settings.json의 provider/generationConfig/permissions를 이유 없이 생략하지 말 것
- 사용자에게 PowerShell 명령어 복붙을 전제로 안내하지 말 것
- 한글 로그 인코딩 문제를 대충 넘기지 말 것
