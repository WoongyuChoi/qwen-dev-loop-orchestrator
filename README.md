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
- **Project directory loop**: scans a local project, opens a new timestamped session, and follows a domain-first business exploration cycle instead of resuming the previous conversation.

Core behavior:

- Reads `%USERPROFILE%\.qwen\settings.json` as the main configuration source.
- Sends OpenAI-compatible `/chat/completions` requests with Qwen Code-like headers and streaming body.
- Preserves `envKey`, provider config, generation config, output language, and permission hints.
- Extracts the final `NEXT_QUESTION:` control line from each answer and uses it as the next prompt.
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

For a no-external-API regression of Fresh isolation, timestamp sessions, retention, business-family evidence selection, the 5-successful-turn cycle, effective streaming overrides, truncated-response continuation, final-line follow-up parsing, and response-depth diagnostics:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tests\run-project-mode-smoke.ps1
```

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
   - Creates an independent session and starts with a fresh business-domain question.
   - Rescans for a different business area after every 5 successful turns.

Select mode [1/2]:
```

Choose:

- `1` to resume or start the general random question loop.
- `2` to enter a project directory path and create a new, independently logged project-analysis session.

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

It indexes both code structure and business evidence, including:

```text
Service/Tasklet/Job, Mapper interface/XML, VO/DTO,
business comments and labels, table/column mappings,
fields, JobParameters, status values, and caller/consumer links
```

Technical entry/config files can remain in the compact project index, but business evidence controls the primary exploration target. Focused excerpts are added within size limits; the full project is not blindly sent.

Project mode never writes into the scanned target project. The launcher passes `qwen-loop-data\project` as the session root. PowerShell derives a stable project identity from the normalized project path and a short SHA-256 hash, then creates a new timestamped session for every option-2 startup:

```text
qwen-loop-data\project\
  <project-name>-<path-hash>\
    exploration_history.jsonl
    sessions\
      <yyyyMMdd-HHmmss-fff>-p<PID>-<suffix>\
```

The path hash prevents two unrelated projects with the same leaf directory name from sharing state. A new timestamped session has its own `next_question.txt`, `last_turn.txt`, transcripts, request logs, and run history, so restarting option 2 cannot silently resume yesterday's class or method chain.

Key outputs:

```text
project_scan_summary.md
project_scan_summary.json
next_question.txt
last_dynamic_project_context.json
exploration_state.json
cycle_evidence.md
cycle_history.jsonl
session_identity.json
.qwen-loop-workdir.json
.active.lock
transcript.md
transcript.jsonl
run_history.md
run_history.jsonl
```

The double-click launcher uses `-NewProjectSession -FreshProjectQuestion`. Each session starts without the previous session's `next_question.txt` or `last_turn.txt`. The scanner groups related files into business families where possible, selects a primary business area, and uses Service/Tasklet/Mapper/XML/VO and their comments, fields, tables, columns, parameters, and status values as evidence for reconstructing the user or batch process. Technical topics such as transactions, framework patterns, performance, and security remain supporting or final risk checks; they are not the default center of the analysis.

One business exploration cycle lasts **5 successful turns** by default (`-ProjectTurnsPerCycle 5`). Failed or incomplete responses do not consume a turn. The five phases progress through business discovery, terms/data contract, normal process, cross-validation, and a business report. A compact `cycle_evidence.md` carries selected business evidence from the earlier turns into that final report without restoring a previous session. At the next cycle boundary, the project is rescanned, the previous turn context and cycle memory are detached, and a new primary business family/file is selected. Recently selected primary areas are recorded in the project-scoped `exploration_history.jsonl` and used only as negative coverage: they help the selector avoid revisiting an already covered area, but old questions and answers are not restored as the new conversation context. If every available area has been covered, the selector relaxes the cooldown in stages while still avoiding the immediately previous family when another choice exists.

Project sessions are retained independently. The launcher keeps the newest 12 sessions, removes sessions older than 30 days, and limits the combined session data for one project identity to 750 MB. The current session and any session holding an active lock are protected from retention. Cleanup is serialized per project identity and limited to recognized, inactive session directories whose marker is revalidated immediately before deletion; a session tree containing a reparse point is preserved. These defaults can be changed with the project-session options shown below.

`run-qwen-loop.bat` asks for the wait interval before starting the selected loop. Choose random to keep the default 8-15 minute wait after each response, or choose fixed minutes to wait a specific number of minutes after each response. A fixed value of `0` means the next request starts immediately after the previous response has been handled.

In project mode, each run prints a `PROMPT SNIPPETS SENT` console section before sending the request. It deduplicates the actual file excerpt blocks included in the prompt and labels whether each snippet came from dynamic question matching, linked expansion, base scan context, or both. Candidate files that were only mentioned by name are shown separately as `REFERENCED ONLY`, so you do not need to inspect `dry_run_request_body.json` just to see which project files were actually sent as snippets.

For every project-mode turn, the script also builds a best-effort dynamic context from the current business question. It extracts meaningful file/class/method/config/SQL-like terms, filters generic framework words, searches the scanned project for matching files, and prepends focused evidence before the compact base scan index. When a business family is known, both the base raw excerpts and dynamic direct/expanded candidates stay inside that family; a common Listener or an unrelated feature cannot quietly become the next topic. Matched files are excerpted around relevant line windows instead of always sending only the file prefix. Large Mapper XML files receive a compact business-evidence index for comments, statement IDs, tables, columns, parameters, and result mappings even when the exact filename is not present inside the XML body. Missing files are skipped rather than treated as errors, and the last lookup summary is saved to `last_dynamic_project_context.json`.

Advanced direct calls to `qwen-loop.ps1 -ProjectRoot ...` **without** `-NewProjectSession` keep the legacy continuation behavior. With an explicit stable `-WorkDir`, the script can continue from `next_question.txt`, then recover from `transcript.jsonl`, `transcript.md`, `last_turn.txt`, or interrupted `pending_question.txt`. `-FreshProjectQuestion` controls the fresh seed within that legacy work folder; `-NewProjectSession` is what requests the hash-identity/timestamp-session layout used by option 2.

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
| from the final control line  |
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

The model is instructed to write the detailed domain analysis first and finish every response with:

```text
NEXT_QUESTION: <one concrete follow-up question>
```

Putting the control line last lets the model derive the next question from the completed analysis instead of committing to a technical tangent before it has reconstructed the business flow.

The script parses that line and stores it in the current WorkDir. For general mode this is:

```text
qwen-loop-data\next_question.txt
```

For option-2 project mode it is stored inside the current timestamped session directory instead.

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
- streaming responses are returned as soon as SSE `data: [DONE]` is received

The script does **not** send `X-Qwen-Loop-*` diagnostic headers by default. Use `-LoopDiagnosticHeaders` only if receiver-side tracing needs client identity information.

## Output Files

Runtime data is written under:

```text
qwen-loop-data\
```

General mode uses files directly below this directory. New project sessions use the hash-identity/timestamp layout described in [Project Directory Mode](#project-directory-mode).

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
Reconstruct what business outcome this batch creates from its Mapper XML tables, VO fields, and normal data flow.

[2026-07-07 10:00:00] POST http://localhost:8000/chat/completions (attempt 1/4, retry-count=0)
[2026-07-07 10:00:28] HTTP 200 OK (28142 ms, 24576 bytes, retry-count=0)
TokenUse     : input=21,204, output=2,842, total=24,046 | developed
AnswerDepth : input=normal, output=developed, target[tokens=False, chars=False], yield=13.4%, finish=stop

ANSWER PREVIEW:
This program turns approved orders into shipment-ready business records...

NEXT QUESTION:
Verify the business meaning of BUSINESS_DATE and SHIPMENT_STATUS from the Mapper columns, VO comments, and downstream consumer.

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
-NewProjectSession              Create a hash-identified, timestamped WorkDir under qwen-loop-data\project
-FreshProjectQuestion           For ProjectRoot, start with a newly sampled project question instead of saved next_question.txt
-ProjectTurnsPerCycle <n>       Successful turns before selecting a fresh business area; launcher default: 5
-ProjectSessionKeepCount <n>    Newest sessions retained per project identity; launcher default: 12
-ProjectSessionKeepDays <n>     Remove inactive sessions older than this; launcher default: 30
-ProjectSessionMaxTotalMB <n>   Combined retained session limit per project identity; launcher default: 750 MB
-ProjectTargetOutputTokens <n>  Soft project-answer depth target; default: about 3,500 output tokens
-ProjectTargetAnswerChars <n>   Soft detailed-answer size target; default: about 8,000 characters
-DynamicProjectContextMaxFiles <n>      Max related files attached per project-mode turn
-DynamicProjectContextMaxFileChars <n>  Max excerpt chars per dynamic related file
-DynamicProjectContextMaxTotalChars <n> Max total chars for dynamic project context
-QuestionTrack <name>           Pick seeds from a specific question_bank track
-MinIntervalMinutes <n>         Random wait minimum
-MaxIntervalMinutes <n>         Random wait maximum
-IntervalSeconds <n>            Fixed wait in seconds; 0 runs again immediately after each response
-MaxRetries <n>                 Retry count for retryable failures
-CompatBody                     Use a stricter standard OpenAI body
-EndpointFallbacks              Try endpoint fallback candidates
-MaskSensitiveLogs              Mask sensitive values in saved header logs
-LoopDiagnosticHeaders          Send X-Qwen-Loop-* diagnostic headers
-NoBanner                       Hide startup ASCII banner
-NoCountdown                    Disable live countdown line
-NoAutoCleanup                  Disable qwen-loop-data cleanup
```

`max_tokens` is an output **ceiling**, not a requested answer length. The normal settings-first path uses `generationConfig.samplingParams.max_tokens` when configured; otherwise it uses the Qwen Code-compatible model limit. A response can still stop far below that ceiling. Project mode therefore also states a soft depth/size target in the prompt and records token usage and completion diagnostics so short answers can be distinguished from a hard length cutoff. Raising `max_tokens` alone does not guarantee a richer answer, and indiscriminately sending more input can dilute attention; project mode favors a compact index plus focused business-evidence excerpts.

The final request body decides the wire mode. If `generationConfig.samplingParams` or `extra_body` overrides `stream`, transport and parsing follow that effective value; non-streaming bodies do not retain `stream_options`. The response `Content-Type` is used as the final SSE/JSON parsing signal and the chosen modes plus request character counts are stored in `last_response_status.json` and run history.

`NEXT_QUESTION:` is a completion control line, not a best-effort heading. If it is missing, or if `finish_reason` is `length`/`content_filter`, the turn is recorded as `partial`, does not advance the five-turn cycle, and saves an explicit continuation request instead of misusing the first answer heading as the next question.

## Safety Notes

- Request/response logs are saved locally for debugging. By default, header/body logs are not masked because this tool is meant for internal API inspection. Use `-MaskSensitiveLogs` if you need safer saved logs.
- Project scan mode excludes common secret files, but you should still review `project_scan_summary.md` before sharing logs.
- Project-session retention deletes only recognized inactive session directories. Keep `session_identity.json` and `.active.lock` intact while a session is running.
- Recursive WorkDir cleanup requires a matching `.qwen-loop-workdir.json`. The normal launcher/session directories are claimed automatically; an existing non-empty custom WorkDir outside `qwen-loop-data` is not claimed and is never recursively cleaned. WorkDir and ProjectRoot may not contain one another, and WorkDir paths with a junction/symlink/reparse-point ancestry are rejected.
- General-mode cleanup excludes the managed `qwen-loop-data\project` subtree entirely; timestamp project sessions are removed only by their marker/lock-aware retention policy.
- DryRun writes its preview files but never runs WorkDir or project-session cleanup.
- `settings.json` should not contain real public credentials.
- This tool automates repeated API calls. Keep the default 8-15 minute randomized interval, or choose a responsible fixed interval for your server. A 0-minute fixed interval is supported for local stress/continuation checks, but it will immediately send the next request after each response completes.

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
