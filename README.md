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
- Holds an exclusive lifetime lock for each WorkDir so two processes cannot update the same state files concurrently.
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

The High-priority regression suite uses only loopback mock SSE/JSON servers. It covers deterministic/CP949 scanning, secret and reparse filtering, session lifecycle/retention, cumulative answer-quality continuation and escape, atomic recovery, fail-closed protocol parsing (including a response-started read timeout), settings precedence, and the single-owner WorkDir lock:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tests\run-high-priority-regression.ps1
```

If Pester is installed, the same scenarios can be run through `Invoke-Pester .\tests\qwen-loop.Tests.ps1`.

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

Candidate discovery is deterministic within each exploration cycle. Directories and files are sorted into one reusable candidate index, and the same index is used by the initial scan and dynamic follow-up lookup so a relevant file cannot disappear because of a second random directory sample. The default safety bounds are 10,000 candidate files, 10,000 visited directories, 2,500 files whose contents may be inspected per scan/search pass, and 4 MB per source file. A truncated candidate index is reported in the scan summary instead of being presented as complete.

Project source decoding is separate from the UTF-8 runtime log format. The scanner recognizes UTF-8/UTF-16 BOMs and XML encoding declarations, validates BOM-less UTF-8 strictly, and falls back to Windows CP949 when UTF-8 decoding fails. This preserves Korean business comments in older Java/MyBatis projects while all generated logs and state files remain UTF-8.

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
partial_state.json
pending_turn.json
pending_cycle_transition.json
session_identity.json
.qwen-loop-workdir.json
.active.lock
transcript.md
transcript.jsonl
run_history.md
run_history.jsonl
```

The double-click launcher uses `-NewProjectSession -FreshProjectQuestion`. Each session starts without the previous session's `next_question.txt` or `last_turn.txt`. The scanner groups related files into business families where possible, selects a primary business area, and uses Service/Tasklet/Mapper/XML/VO and their comments, fields, tables, columns, parameters, and status values as evidence for reconstructing the user or batch process. Technical topics such as transactions, framework patterns, performance, and security remain supporting or final risk checks; they are not the default center of the analysis.

One business exploration cycle lasts **5 successful turns** by default (`-ProjectTurnsPerCycle 5`) in both timestamp sessions and advanced stable-WorkDir project mode. Failed or incomplete responses do not consume a turn. The five phases progress through business discovery, terms/data contract, normal process, cross-validation, and a business report. A compact `cycle_evidence.md` carries selected business evidence from the earlier turns into that final report without restoring a previous session. At the next cycle boundary, the project is rescanned, the previous turn context, cycle-only question history, and cycle memory are detached, and a new primary business family/file is selected. Recently selected primary areas are recorded in the project-scoped `exploration_history.jsonl` and used only as negative coverage: they help the selector avoid revisiting an already covered area, but transcript text from another WorkDir or ProjectRoot is never injected into the prompt. If every available area has been covered, the selector relaxes the cooldown in stages while still avoiding the immediately previous family when another choice exists.

A project answer is successful only when the protocol contract is complete and the business-analysis quality gate is met. By default, cumulative visible output must reach either about 3,500 tokens or 8,000 characters, and it must contain at least 3 distinct business-evidence signals such as purpose, actor/trigger/result, data contract, normal flow, state/downstream, or fact/inference evidence. A shallow answer is recorded as `partial`, keeps the original logical question and bounded cumulative evidence excerpts in `partial_state.json`, and requests a self-contained integrated answer without recursively nesting the continuation instruction. The default maximum is 2 continuation attempts. If the same slice remains incomplete after that bound, the run is recorded as `abandoned` and a fresh business-family rescan is queued before the next request. `-NoProjectQualityGate` disables only the depth/evidence gate; truncation and final `NEXT_QUESTION:` validation still apply.

Project sessions are retained independently. The launcher keeps the newest 12 ready sessions, removes ready sessions older than 30 days, and limits their combined data for one physical project identity to 750 MB. The current session and any session holding an active lock are protected. Immediately after a new session claims its lifetime lock, a narrow abandoned-only pass removes prior strictly validated, inactive `initializing`/`failed` siblings without applying ready-session count/day/size policies. Therefore repeated deterministic scan failures leave at most the current failed session when cleanup is enabled; `-NoAutoCleanup` and `-DryRun` intentionally preserve them. After the current session becomes ready, the normal retention pass applies the ready policies. Both passes are serialized per physical project identity, revalidate marker/physical path/parent/state while holding a retention guard, reject every reparse point, and remove descendants without following recursive links; `.active.lock` is unlinked last. Unmarked or otherwise unrecognized directories remain untouched. These defaults can be changed with the project-session options shown below.

`run-qwen-loop.bat` asks for the wait interval before starting the selected loop. Choose random to keep the default 8-15 minute wait after each response, or choose fixed minutes to wait a specific number of minutes after each response. A fixed value of `0` means the next request starts immediately after the previous response has been handled.

In project mode, each run prints a `PROMPT SNIPPETS SENT` console section before sending the request. It deduplicates the actual file excerpt blocks included in the prompt and labels whether each snippet came from dynamic question matching, linked expansion, base scan context, or both. Candidate files that were only mentioned by name are shown separately as `REFERENCED ONLY`, so you do not need to inspect `dry_run_request_body.json` just to see which project files were actually sent as snippets.

For every project-mode turn, the script also builds a best-effort dynamic context from the current business question. It extracts meaningful file/class/method/config/SQL-like terms, filters generic framework words, searches the scanned project for matching files, and prepends focused evidence before the compact base scan index. When a business family is known, base raw excerpts and ordinary direct/expanded candidates stay inside that family; a common Listener or unrelated feature cannot quietly become the next topic. The only cross-family exception is up to 3 evidence-only files whose names exactly match an import or Mapper data-contract reference such as `resultType`; those bounded slots are reserved before same-family expansion so exact VO/DTO contracts are not crowded out, but the files cannot become a new topic. Matched files are excerpted around relevant line windows instead of always sending only the file prefix. Large Mapper XML files receive a compact business-evidence index for comments, statement IDs, tables, columns, parameters, and result mappings even when the exact filename is not present inside the XML body. Missing files are skipped rather than treated as errors, and the last lookup summary is saved to `last_dynamic_project_context.json`.

Advanced direct calls to `qwen-loop.ps1 -ProjectRoot ...` **without** `-NewProjectSession` keep the legacy continuation behavior. With an explicit stable `-WorkDir`, the script can continue from `next_question.txt`, then recover from `transcript.jsonl`, `transcript.md`, or `last_turn.txt`. `pending_turn.json` is the structured write-ahead marker and `transcript.jsonl` is the canonical completed-turn journal: if a process stops after the response audit but before the next-question/state commit, startup rolls the exact state forward instead of sending the completed question again. If no canonical completed record exists, the request is treated as delivery-unknown and its exact question is not automatically POSTed again: general mode chooses another seed and project mode creates an interrupted-turn escape question. JSONL appends isolate a torn final line so later records remain parseable, and sequence numbers advance from the maximum durable run/transcript/pending value. Old project scan snapshots that predate the current sanitizer schema are discarded and rebuilt rather than replayed. `-FreshProjectQuestion` controls the fresh seed within that legacy work folder; `-NewProjectSession` is what requests the hash-identity/timestamp-session layout used by option 2. General, legacy project, DryRun, and timestamp-session modes all hold the WorkDir's `.active.lock` for the full process lifetime. A second process targeting the same WorkDir stops before transport or state mutation; a leftover unlocked file is harmless because ownership is determined by the live exclusive handle.

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
- an SSE response is accepted as complete only after `data: [DONE]` or a terminal `finish_reason` for primary choice index 0; an unterminated partial stream is rejected

The script does **not** send `X-Qwen-Loop-*` diagnostic headers by default. Use `-LoopDiagnosticHeaders` only if receiver-side tracing needs client identity information.

The default Qwen Code version in `User-Agent` comes from explicit `-QwenCodeVersion`, then the `QWEN_CODE_VERSION` OS environment variable, and otherwise uses the visible fallback `unknown`. A non-null `generationConfig.customHeaders.User-Agent` or `Content-Type` is a settings-first override of that default and is used on the wire. The settings file's `$version` is a settings-schema version and is never reused as the Qwen Code package version. `settings_effective_summary.json.qwenCompat` records the actual effective user agent/content type and their provenance.

`settings_effective_summary.json.settingsCoverage` also records how each top-level settings area is used rather than implying that interactive-only fields were silently emulated:

- `env`: API-key fallback only, after OS environment and `.env` candidates; values are not bulk-forwarded.
- `modelProviders`: provider/model/base URL/`envKey`/`generationConfig` selection.
- `generationConfig`: timeout and custom headers always apply; sampling/body fields and the effective stream shape apply unless `-CompatBody` intentionally omits `samplingParams`/`extra_body`, which is reported as `partially-applied`.
- `general`: `outputLanguage` is applied to the system prompt; interactive-only fields are not applicable.
- `permissions`: `allow` is prompt scope only because this scheduler does not execute Qwen tools.
- `security`: `auth.selectedType` selects the provider type; unrelated interactive authentication UI is not applicable.
- `ui`: preserved but not emulated by the non-interactive scheduler.
- `$version`: diagnostic settings-schema metadata only; its actual value is stored as `settingsSchemaVersion`, never reused as a package version.

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
-MaxRuns <n>                    Run a finite number of scheduled requests and exit
-ProjectRoot <path>             Scan a project directory and start from it
-NewProjectSession              Create a hash-identified, timestamped session under the supplied WorkDir (launcher: qwen-loop-data\project)
-FreshProjectQuestion           For ProjectRoot, start with a newly sampled project question instead of saved next_question.txt
-ProjectTurnsPerCycle <n>       Successful turns before selecting a fresh business area; launcher default: 5
-ProjectSessionKeepCount <n>    Newest sessions retained per project identity; launcher default: 12
-ProjectSessionKeepDays <n>     Remove inactive sessions older than this; launcher default: 30
-ProjectSessionMaxTotalMB <n>   Combined retained session limit per project identity; launcher default: 750 MB
-ProjectTargetOutputTokens <n>  Soft project-answer depth target; default: about 3,500 output tokens
-ProjectTargetAnswerChars <n>   Soft detailed-answer size target; default: about 8,000 characters
-ProjectQualityMinEvidenceSignals <n> Required cumulative business-evidence categories; default: 3, range: 0-6
-ProjectMaxContinuationAttempts <n> Bounded supplementation attempts before abandoning a slice; default: 2
-NoProjectQualityGate           Disable project depth/evidence gating, but keep protocol completeness checks
-ProjectCandidateMaxFiles <n>   Deterministic candidate-index file cap; default: 10,000
-ProjectCandidateMaxDirectories <n> Directory traversal cap for the candidate index; default: 10,000
-ProjectContentScanMaxFiles <n> Content-inspection cap per scan/search pass; default: 2,500
-ProjectMaxSourceFileMB <n>     Largest source file eligible for scanning; default: 4 MB
-DynamicProjectContextMaxFiles <n>      Max related files attached per project-mode turn
-DynamicProjectContextMaxFileChars <n>  Max excerpt chars per dynamic related file
-DynamicProjectContextMaxTotalChars <n> Max total chars for dynamic project context
-QuestionTrack <name>           Pick seeds from a specific question_bank track
-MinIntervalMinutes <n>         Random wait minimum
-MaxIntervalMinutes <n>         Random wait maximum
-IntervalSeconds <n>            Fixed wait in seconds; 0 runs again immediately after each response
-MaxRetries <n>                 Retry count for retryable failures
-QwenCodeVersion <version>      Explicit version used in the QwenCode User-Agent
-CompatBody                     Use a stricter standard OpenAI body
-NonStreaming                   Request a non-streaming body unless settings override stream
-EndpointFallbacks              Try endpoint fallback candidates
-MaskSensitiveLogs              Mask known sensitive values in saved headers, request bodies, and settings diagnostics
-LogSensitive                   Explicitly keep raw sensitive logs, overriding -MaskSensitiveLogs
-LoopDiagnosticHeaders          Send X-Qwen-Loop-* diagnostic headers
-NoClientIdentityHeaders        With diagnostic headers enabled, suppress PC/user/IP collection and headers
-NoBanner                       Hide startup ASCII banner
-NoCountdown                    Disable live countdown line
-NoAutoCleanup                  Disable qwen-loop-data cleanup
```

`max_tokens` is an output **ceiling**, not a requested answer length. The normal settings-first path uses `generationConfig.samplingParams.max_tokens`/`max_completion_tokens` when configured; otherwise it retains the Qwen Code-compatible model limit even when `samplingParams` contains only `temperature` or another unrelated field. A response can still stop far below that ceiling. Project mode therefore also states a soft depth/size target in the prompt and records token usage and completion diagnostics so short answers can be distinguished from a hard length cutoff. Raising `max_tokens` alone does not guarantee a richer answer, and indiscriminately sending more input can dilute attention; project mode favors a compact index plus focused business-evidence excerpts.

The final request body decides the wire mode. If `generationConfig.samplingParams` or `extra_body` overrides `stream`, transport and parsing follow that effective value; non-streaming bodies do not retain `stream_options`. Empty, singleton, multi-value, and nested arrays from settings keep their JSON array shape during these merges. `-CompatBody` deliberately omits those two provider-specific merge layers—including conflicting token keys that are irrelevant once omitted—while still applying timeout/custom headers, and the summary reports that partial coverage. The response `Content-Type` is used as the final SSE/JSON parsing signal and the chosen modes plus request character counts are stored in `last_response_status.json` and run history.

`NEXT_QUESTION:` is a completion control line, not a best-effort heading. If it is missing, or if `finish_reason` is `length`/`content_filter`, the turn is recorded as `partial`, does not advance the five-turn cycle, and saves an explicit continuation request instead of misusing the first answer heading as the next question.

SSE and JSON responses are parsed strictly. A malformed `data:` JSON event, an OpenAI-style error payload, an empty/invalid JSON body, a response with no textual completion content, or an SSE connection ending before `[DONE]` or the primary choice's terminal `finish_reason` is a protocol failure; raw wire JSON is never saved as an assistant answer. The standards-compatible exception is an empty choice explicitly terminated with `finish_reason=length` or `content_filter`; it is a valid but incomplete response and follows the bounded partial-continuation path. Once HTTP response headers/body have started, a later read timeout, parser error, or local acceptance failure is never retried in the same process because delivery is already ambiguous. Protocol failures leave `last_response_status.json.ok=false` and do not commit a new transcript turn or `next_question.txt` value.

Finite `-Once`/`-MaxRuns` processes return exit code `0` when the requested work finishes cleanly, `1` when any HTTP/API/parser/state run error occurs, and `2` when they stop with a partial response or an abandoned slice that has not yet escaped through the next fresh rescan. If a later run successfully performs that rescan and completes, the earlier abandonment no longer forces exit code `2`. An unbounded loop also stops immediately with exit code `1` if a turn/cycle commit has begun and cannot finish; startup recovery owns the roll-forward, so the same process never overwrites its pending journal with another request.

## Safety Notes

- Request/response logs are saved locally for debugging. By default, header/body/settings diagnostic values are not masked because this tool is meant for internal API inspection. `-MaskSensitiveLogs` writes a separate recursively sanitized representation to the normal log paths without changing the real wire object: sensitive property names, exact known API-key values, distinctive embedded known keys, and recognized credential/config patterns are redacted in headers, request bodies, and generationConfig diagnostics. To avoid corrupting ordinary words, a known key shorter than 6 characters is guaranteed to be redacted when it is the complete value but not when it appears only as a substring of a neutral value. This is a safety aid rather than a proof that arbitrary secrets hidden under neutral field names are impossible, so review logs before sharing them. `-LogSensitive` explicitly overrides masking.
- Project scan mode excludes secret-looking files and reparse-point files/directories. Included snippets redact literal credentials, PEM blocks, Kubernetes Secret documents, sensitive JSON/YAML/properties values (including next-line/continued values), and multiline XML sensitive elements/attributes including child `<value>` content. Scan snapshots carry a sanitizer version and older snapshots are rebuilt. You should still review `project_scan_summary.md` before sharing logs.
- Project-session retention deletes only recognized inactive session directories. Keep `session_identity.json` and `.active.lock` intact while a session is running.
- Every WorkDir is single-writer. `.active.lock` is held until top-level cleanup finishes, including for general mode, legacy stable WorkDirs, DryRun, and new timestamp sessions.
- Recursive WorkDir cleanup requires a matching `.qwen-loop-workdir.json`. The normal launcher/session directories are claimed automatically; an existing non-empty custom WorkDir outside `qwen-loop-data` is not claimed and is never recursively cleaned. WorkDir and ProjectRoot may not contain one another. Their existing ancestors are resolved to physical paths so drive-letter/UNC aliases cannot bypass the boundary, and ProjectRoot/WorkDir paths with a junction/symlink/reparse-point ancestry are rejected.
- General-mode cleanup excludes the managed `qwen-loop-data\project` subtree entirely; timestamp project sessions are removed only by their marker/lock-aware retention policy.
- DryRun writes its preview files but never runs WorkDir or project-session cleanup.
- Provider custom-header values and other generationConfig secret values are applied only to transport/body paths; the system prompt contains key names and non-secret shape metadata rather than duplicating those values. Prompt-only permission hints pass through the same secret sanitizer.
- The main launcher and numbered BAT files that invoke one PowerShell run preserve that process exit code across `pause` and return it with `exit /b`, so automation can distinguish success from incomplete or failed runs. `check-qwen-loop.bat` intentionally aggregates two DryRun results into a single success/failure code.
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

The scripts force UTF-8 console/file handling with `chcp 65001` and UTF-8 PowerShell output. Project scanning also supports strict UTF-8 detection, BOM/declaration-based Unicode decoding, and a CP949 fallback for legacy Korean source files. If generated console text is still broken, try Windows Terminal or a UTF-8 compatible console font; if only a source excerpt is broken, verify that the source file's XML declaration or actual byte encoding is correct.

## License

No license file is included yet. Add a `LICENSE` file before publishing if you want others to use, modify, or redistribute this project under a specific license.
