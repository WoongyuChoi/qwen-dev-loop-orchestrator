# 대화 요약 및 Codex 인수인계

## 1. Continue VSCode 설정 관련

초기에는 VSCode Continue에서 로컬 Qwen GGUF 모델을 붙이는 설정을 검토했다. `/v1/models` 응답에서 `Server: llama.cpp`가 보였고, 기존 config가 `provider: ollama`로 되어 있어 문제가 발생할 가능성이 컸다.

결론:

- llama.cpp 서버 직접 사용: `provider: llama.cpp`, `apiBase: http://10.32.64.116:8001`
- OpenAI-compatible 서버 사용: `provider: openai`, `apiBase: http://10.32.64.116:8001/v1`
- `roles`는 model block 안에 둔다.
- `title` 대신 `name`을 사용한다.

## 2. Continue에서 폴더/코드베이스 컨텍스트 사용

`@Folder`, `@Codebase`, `@File`, `@Open`, `@Search`, `@Diff`의 역할을 구분했다.

- `@Folder`: 특정 폴더 구조를 파악할 때
- `@Codebase`: 어디 있는지 모르는 기능이나 유사 구현을 찾을 때
- `@File`: 정확한 파일을 알고 있을 때
- `@Open`: 관련 파일 여러 개를 직접 열어두고 묶어서 볼 때
- `@Search`: 키워드/호출처 검색
- `@Diff`: 변경 리뷰

`.continue/rules/*.md`는 매번 `@File`로 붙이지 않아도 계속 적용되는 규칙 문서로 사용하고, 기능별 기획서는 `docs/tasks/*.md`에 둔 뒤 작업 시작 시 `@File`로 붙이는 흐름을 추천했다.

## 3. 기획 기반 개발 워크플로우

기획서를 바로 구현시키지 말고 다음 순서로 진행하는 방식을 정했다.

1. 기획 문서 읽기
2. 유사 구현 찾기
3. 영향 범위 정리
4. 구현 계획 제안
5. 사용자 승인
6. 작은 단위 수정
7. diff 리뷰와 테스트 포인트 정리

권장 문서 구조:

```text
.continue/rules/project.md
.continue/rules/dev-process.md
docs/AI_PROJECT_MAP.md
docs/tasks/<기능명>.md
```

## 4. IntelliJ와 VSCode 병행 사용

Spring Boot 프로젝트는 IntelliJ를 메인 개발/실행/디버깅 IDE로 두고, VSCode는 Continue 기반 분석/문서화/부분 수정 보조로 쓰는 방식을 추천했다.

주의사항:

- Spring Boot 실행은 한 IDE에서만 한다.
- VSCode 자동 포맷/자동 import를 꺼둔다.
- `.vscode`, `.classpath`, `.project`, `.settings` 등 IDE 생성 파일은 필요 시 `.gitignore` 처리한다.
- VSCode는 multi-root workspace로 다른 프로젝트를 추가할 수 있다.

## 5. IntelliJ AI 플러그인 후보

기존 GGUF 모델 서버 또는 OpenAI-compatible endpoint에 붙는 IntelliJ 플러그인 후보를 검토했다.

우선순위:

1. DevoxxGenie
2. Cline for JetBrains
3. Continue JetBrains
4. ProxyAI / CodeGPT
5. JetBrains AI Assistant

Continue JetBrains Plugin에서 한글이 깨지는 문제는 IntelliJ VM option에 `-Dfile.encoding=UTF-8`을 추가하는 방식으로 해결 가능성이 높다고 판단했다.

## 6. Qwen 루프 스케줄러 요구사항

사용자는 `C:\Users\KB099\.qwen\settings.json`에 있는 Qwen Code 설정을 기반으로, 10분마다 AI에게 질문을 보내고 응답의 첫 줄에서 다음 질문을 추출해 다시 이어가는 스케줄러를 원했다.

요구사항 핵심:

- Windows 11 기준 더블클릭 BAT 실행
- cmd 환경에서 로그 확인
- settings.json을 최대한 그대로 활용
- `envKey`를 임의로 dummy로 바꾸지 말 것
- `generationConfig`, `general`, `permissions`, `ui` 등 설정값을 가능한 한 request 또는 system prompt에 반영
- 클라이언트 식별 정보/IP 관련 정보도 header에 포함
- 한글 응답이 깨지지 않도록 UTF-8 처리
- 로그로 질문/답변/다음질문 저장
- 10분마다 반복, Ctrl+C 전까지 지속

## 7. 버전별 진화

- v1: 기본 PowerShell 루프. 한글 응답이 깨지는 문제가 실제로 발생했다.
- v2: UTF-8 강제 디코딩, 이전 답변 포함, DryRun/MaxRuns 추가.
- v2.1: envKey/헤더/IP 검증 로그 강화.
- v4: settings-first 원칙으로 재설계. `settings.json` 값을 최대한 활용하고, 더블클릭 BAT 파일들을 분리.

현재 프로젝트는 v4를 최신 기반으로 포함한다.

## 8. Codex에게 맡길 때 핵심 지시

Codex에는 다음을 강조해야 한다.

- `settings.json`이 source of truth다.
- API Key를 임의로 `dummy`로 정규화하지 말 것.
- 사용자가 PowerShell 명령어를 복붙하지 않아도 되게 BAT 파일을 유지할 것.
- Windows 11 + PowerShell 5.1 + 한국어 cmd 환경에서 한글 깨짐을 테스트할 것.
- `last_request_headers.json`, `last_request_body.json` 같은 검증 로그를 유지할 것.
- 민감정보는 로그에 마스킹하되, 실제 request는 설정값 그대로 보낼 것.
