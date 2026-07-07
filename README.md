# qwen-dev-loop-orchestrator

![Shell](https://img.shields.io/badge/Shell-Windows%20Batch-2b2b2b)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE)
![Platform](https://img.shields.io/badge/platform-Windows%2011-blue)
![Qwen](https://img.shields.io/badge/Qwen%20Code-settings--first-7c3aed)

> Windows double-click runner that repeatedly calls an OpenAI-compatible Qwen endpoint using a Qwen Code-style `settings.json`, saves the answer, extracts `NEXT_QUESTION`, and continues the loop.

This project is useful when you want to test or observe a Qwen/OpenAI-compatible server as if the request came from a Qwen Code-like client, while keeping a visible local transcript and run history.

It is an independent helper script, not an official Qwen project.

## Overview

`qwen-dev-loop-orchestrator` is a small Windows automation tool made of one main PowerShell script and a few double-click `.bat` entry points.

It can run in two modes:

- **Random question loop**: starts from `question_bank.txt` or resumes `qwen-loop-data\next_question.txt`.
- **Project directory loop**: scans a local Java/Spring, React/TypeScript, SQL/MyBatis, or script-based project and starts a fresh project-specific analysis loop.

Core behavior:

- Reads `%USERPROFILE%\.qwen\settings.json` as the main configuration source.
- Sends OpenAI-compatible `/chat/completions` requests with Qwen Code-like headers and streaming body.
- Preserves `envKey`, provider config, generation config, output language, and permission hints.
- Extracts the first `NEXT_QUESTION:` line from each answer and uses it as the next prompt.
- Saves request logs, response status, answer preview, token usage, transcript, and run history.
- Waits a randomized 8-15 minutes between loop calls by default.
- Keeps `qwen-loop-data` lightweight with automatic cleanup.

## Download

Main files:

- [`run-qwen-loop.bat`](run-qwen-loop.bat) - main double-click launcher
- [`check-qwen-loop.bat`](check-qwen-loop.bat) - dry-run settings checker
- [`qwen-loop.ps1`](qwen-loop.ps1) - main loop implementation
- [`question_bank.txt`](question_bank.txt) - initial question seeds
- [`seed_prompt.txt`](seed_prompt.txt) - fallback seed question
- [`context_files.txt`](context_files.txt) - optional context file list

## Requirements

- Windows 10/11
- Windows PowerShell 5.1 or later
- A Qwen/OpenAI-compatible chat completions endpoint
- A Qwen Code-style `settings.json`

No npm, Python, or external package install is required.

## Configuration

The default launcher reads:

```text
%USERPROFILE%\.qwen\settings.json
```

The script expects an OpenAI-compatible provider entry similar to:

```json
{
  "modelProviders": {
    "openai": [
      {
        "id": "qwen-agent",
        "name": "qwen-agent",
        "baseUrl": "http://localhost:8000",
        "envKey": "QWEN_API_KEY",
        "generationConfig": {
          "samplingParams": {
            "temperature": 0.7
          }
        }
      }
    ]
  },
  "env": {
    "QWEN_API_KEY": ""
  },
  "model": {
    "name": "qwen-agent"
  },
  "general": {
    "outputLanguage": "Korean"
  }
}
```

API key lookup order:

1. OS environment variable named by `envKey`
2. `.env` candidates near the settings/script/user profile
3. `settings.json.env[envKey]`

Do not commit real API keys. For public repositories, keep `settings.json` sanitized or provide a separate example file.

## Usage

### 1. Check settings without calling the API

Double-click:

```bat
check-qwen-loop.bat
```

This creates dry-run files under `qwen-loop-data\check\...`:

```text
settings_effective_summary.json
dry_run_request_headers.json
dry_run_request_body.json
```

Use these files to verify the actual headers/body that would be sent.

### 2. Start the loop

Double-click:

```bat
run-qwen-loop.bat
```

You will see:

```text
Qwen Loop Scheduler
------------------------------------------------------------
1. Random question loop
   - Resumes the existing qwen-loop-data session.

2. Project directory loop
   - Scans a directory and starts a fresh project-based session.

Select mode [1/2]:
```

Choose:

- `1` to resume or start the general random question loop.
- `2` to enter a project directory path and start a fresh project-based loop.

Press `Ctrl+C` in the console to stop the loop.

## Project Directory Mode

Project mode scans the directory locally before the first request.

It excludes large/generated/sensitive locations such as:

```text
.git
node_modules
build
target
dist
qwen-loop-data
.env*
.npmrc
```

It scores useful files by path, filename, extension, and code signals such as:

```text
Service, Controller, Repository, Mapper, pom.xml, package.json,
useEffect, @Transactional, Invoke-RestMethod
```

Selected file excerpts are added to the first prompt within size limits. The full project is not blindly sent.

Project mode writes to a fresh folder:

```text
qwen-loop-data\project\<project-name>-<yyyyMMdd-HHmmss>\
```

Key outputs:

```text
project_scan_summary.md
project_scan_summary.json
next_question.txt
transcript.md
transcript.jsonl
run_history.md
run_history.jsonl
```

Unlike random mode, project mode does not resume the previous project answer. It starts fresh each time, while still using recent global questions only as duplicate-avoidance hints.

## How It Works

```text
+-----------------------------+
| 1. Pick current question     |
| next_question.txt or seed    |
+--------------+--------------+
               |
               v
+-----------------------------+
| 2. Build Qwen-style request  |
| settings-based headers/body  |
+--------------+--------------+
               |
               v
+-----------------------------+
| 3. POST /chat/completions    |
| streaming response expected  |
+--------------+--------------+
               |
               v
+-----------------------------+
| 4. Extract NEXT_QUESTION     |
| from the answer              |
+--------------+--------------+
               |
               v
+-----------------------------+
| 5. Save logs and transcript  |
| next_question, history, json |
+--------------+--------------+
               |
               v
+-----------------------------+
| 6. Wait random interval      |
| default: 8-15 minutes        |
+--------------+--------------+
               |
               v
        Repeat until stopped
```

The model is instructed to start every response with:

```text
NEXT_QUESTION: <one concrete follow-up question>
```

The script parses that line and stores it in:

```text
qwen-loop-data\next_question.txt
```

## Qwen Code-like Request Shape

The default request path is:

```text
<baseUrl>/chat/completions
```

Default wire behavior:

- `stream: true`
- `stream_options.include_usage: true`
- `User-Agent: QwenCode/<version> (win32; x64)`
- `X-Stainless-*` SDK-style headers
- `X-Stainless-Retry-Count` updated per retry attempt
- `generationConfig.customHeaders` merged into HTTP headers
- `generationConfig.samplingParams` merged into request body
- `generationConfig.extra_body` merged last

The script does **not** send `X-Qwen-Loop-*` diagnostic headers by default. Use `-LoopDiagnosticHeaders` only if receiver-side tracing needs client identity information.

## Output Files

Runtime data is written under:

```text
qwen-loop-data\
```

Common files:

```text
settings_effective_summary.json
last_request_headers.json
last_request_body.json
last_response_status.json
next_question.txt
last_turn.txt
transcript.md
transcript.jsonl
run_history.md
run_history.jsonl
error.log
```

`qwen-loop-data` is ignored by git and can be deleted when you do not need the local run state anymore.

## Console Output Example

Shortened example:

```text
=== Runtime Summary: SETTINGS-FIRST ===
ProviderType : openai
ProviderName : qwen-agent
BaseUrl      : http://localhost:8000
Model        : qwen-agent
WireMode     : Qwen Code OpenAI SDK-like headers/body
Stream       : True
Retry        : max 3, backoff 1-10 sec
IntervalMode : random
IntervalRange: 8 min (480 sec) - 15 min (900 sec)

[2026-07-07 10:00:00] RUN #1 QUESTION:
Analyze the transaction boundary of the current Service layer.

[2026-07-07 10:00:00] POST http://localhost:8000/chat/completions (attempt 1/4, retry-count=0)
[2026-07-07 10:00:28] HTTP 200 OK (28142 ms, 24576 bytes, retry-count=0)
TokenUse     : input=1,204, output=2,842, total=4,046 | balanced

ANSWER PREVIEW:
The first thing to verify is whether each Service method owns one complete use case...

NEXT QUESTION:
Analyze whether read-only queries and write use cases share the same @Transactional settings.

RUN #1 complete. Full answer saved to transcript.md.
Wait 11:50 (710s) | next 10:12:18 | random | Ctrl+C
```

## Useful Options

You can call `qwen-loop.ps1` directly for advanced usage:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\qwen-loop.ps1 `
  -SettingsPath "$env:USERPROFILE\.qwen\settings.json" `
  -MinIntervalMinutes 8 `
  -MaxIntervalMinutes 15 `
  -WorkDir ".\qwen-loop-data"
```

Common options:

```text
-DryRun                         Build request logs without calling the API
-Once                           Run one request and exit
-ProjectRoot <path>             Scan a project directory and start from it
-QuestionTrack <name>           Pick seeds from a specific question_bank track
-MinIntervalMinutes <n>         Random wait minimum
-MaxIntervalMinutes <n>         Random wait maximum
-MaxRetries <n>                 Retry count for retryable failures
-CompatBody                     Use a stricter standard OpenAI body
-EndpointFallbacks              Try endpoint fallback candidates
-MaskSensitiveLogs              Mask sensitive values in saved header logs
-LoopDiagnosticHeaders          Send X-Qwen-Loop-* diagnostic headers
-NoBanner                       Hide startup ASCII banner
-NoCountdown                    Disable live countdown line
-NoAutoCleanup                  Disable qwen-loop-data cleanup
```

## Safety Notes

- Request/response logs are saved locally for debugging. By default, header/body logs are not masked because this tool is meant for internal API inspection. Use `-MaskSensitiveLogs` if you need safer saved logs.
- Project scan mode excludes common secret files, but you should still review `project_scan_summary.md` before sharing logs.
- `settings.json` should not contain real public credentials.
- This tool automates repeated API calls. Keep the default 8-15 minute randomized interval, or choose a responsible interval for your server.

## Troubleshooting

### DryRun works, real call fails

Check:

- `last_response_status.json`
- `error.log`
- endpoint path: `<baseUrl>/chat/completions`
- API key source in `settings_effective_summary.json`

### Server rejects extra body fields

Try:

```bat
04_RUN_LOOP_10MIN_COMPAT_BODY_IF_SERVER_REJECTS.bat
```

or pass:

```powershell
-CompatBody
```

### Text is garbled

The scripts force UTF-8 console/file handling with `chcp 65001` and UTF-8 PowerShell output. If your terminal still displays broken text, try Windows Terminal or a UTF-8 compatible console font.

## License

No license file is included yet. Add a `LICENSE` file before publishing if you want others to use, modify, or redistribute this project under a specific license.