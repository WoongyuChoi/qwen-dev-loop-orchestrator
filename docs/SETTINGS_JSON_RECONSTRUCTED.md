# settings.json 재구성 메모

이 프로젝트의 `settings.json`은 사용자가 올린 Qwen Code 설정 스크린샷을 기반으로 재구성한 파일이다.

원래 위치:

```text
C:\Users\KB099\.qwen\settings.json
```

프로젝트에는 두 위치에 같은 내용을 넣었다.

```text
settings.json
.qwen/settings.json
```

`settings.json` 내부의 `env` 값은 스크린샷에 보이는 값을 그대로 반영했다. 실제 운영 시에는 원본 `C:\Users\KB099\.qwen\settings.json`과 차이가 없는지 다시 비교해야 한다.

특히 확인할 항목:

- `modelProviders.openai[].baseUrl`
- `modelProviders.openai[].envKey`
- `env` 내부 API key 값
- `permissions.allow` 경로
- `model.name`
- `general.outputLanguage`
