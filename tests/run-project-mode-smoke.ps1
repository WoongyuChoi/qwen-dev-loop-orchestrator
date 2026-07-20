param([switch]$KeepArtifacts)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repo "qwen-loop.ps1"
$fixture = Join-Path $PSScriptRoot "fixtures\business-project"
$helper = Join-Path $PSScriptRoot "helpers\mock-openai-sse.ps1"
$runId = (Get-Date -Format "yyyyMMdd-HHmmss-fff") + "-" + [Guid]::NewGuid().ToString("N").Substring(0, 8)
$runtime = Join-Path $repo ("qwen-loop-data\_integration-" + $runId)
$sessionRoot = Join-Path $runtime "project"
$settingsPath = Join-Path $runtime "settings.json"
$requestLog = Join-Path $runtime "requests.jsonl"
$readyPath = Join-Path $runtime "ready.txt"
$utf8 = New-Object System.Text.UTF8Encoding($false)
$activeLockStream = $null
$unownedWork = $null
New-Item -ItemType Directory -Force -Path $runtime | Out-Null

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

$portProbe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
$portProbe.Start()
$port = ([System.Net.IPEndPoint]$portProbe.LocalEndpoint).Port
$portProbe.Stop()

$settings = [ordered]@{
    modelProviders = [ordered]@{
        openai = @([ordered]@{
            id = "mock-business-agent"
            name = "mock-business-agent"
            baseUrl = "http://127.0.0.1:$port"
            envKey = "MOCK_QWEN_API_KEY"
            generationConfig = [ordered]@{ modalities = [ordered]@{ image = $false } }
        })
    }
    env = [ordered]@{ MOCK_QWEN_API_KEY = "local-test-key" }
    security = [ordered]@{ auth = [ordered]@{ selectedType = "openai" } }
    general = [ordered]@{ outputLanguage = "Korean" }
    permissions = [ordered]@{ allow = @("Read(**)") }
    ui = [ordered]@{ autoModeAcknowledged = $true }
    '$version' = 4
    model = [ordered]@{ name = "mock-business-agent" }
}
[System.IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Depth 30), $utf8)

$unsafeArgs = @(
    "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $scriptPath,
    "-SettingsPath", $settingsPath, "-ProjectRoot", $fixture, "-WorkDir", $fixture,
    "-NewProjectSession", "-FreshProjectQuestion", "-DryRun", "-NoBanner", "-NoCountdown"
)
$savedErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$unsafeOutput = @(& powershell.exe @unsafeArgs 2>&1)
$unsafeExitCode = $LASTEXITCODE
$ErrorActionPreference = $savedErrorActionPreference
Assert-True ($unsafeExitCode -ne 0) "NewProjectSession accepted WorkDir=ProjectRoot"
Assert-True ((($unsafeOutput -join " ").Contains("WorkDir"))) "unsafe WorkDir rejection did not identify the failing setting"
$unsafeAncestorArgs = @($unsafeArgs)
$workDirArgumentIndex = [Array]::IndexOf($unsafeAncestorArgs, "-WorkDir") + 1
$unsafeAncestorArgs[$workDirArgumentIndex] = Split-Path -Parent $fixture
$ErrorActionPreference = "Continue"
$unsafeAncestorOutput = @(& powershell.exe @unsafeAncestorArgs 2>&1)
$unsafeAncestorExitCode = $LASTEXITCODE
$ErrorActionPreference = $savedErrorActionPreference
Assert-True ($unsafeAncestorExitCode -ne 0) "NewProjectSession accepted a WorkDir containing ProjectRoot"

$staleWork = Join-Path $runtime "fresh-stale-work"
New-Item -ItemType Directory -Force -Path $staleWork | Out-Null
foreach ($name in @("next_question.txt", "last_turn.txt", "pending_question.txt")) {
    [System.IO.File]::WriteAllText((Join-Path $staleWork $name), "STALE_CONTINUATION_SENTINEL", $utf8)
}
[System.IO.File]::WriteAllText((Join-Path $staleWork "transcript.jsonl"), '{"nextQuestion":"STALE_JSONL_SENTINEL"}' + [Environment]::NewLine, $utf8)
[System.IO.File]::WriteAllText((Join-Path $staleWork "transcript.md"), "## Next Question" + [Environment]::NewLine + "STALE_MARKDOWN_SENTINEL", $utf8)
$dryRunCleanupSentinel = Join-Path $staleWork "must-survive-dry-run.tmp"
[System.IO.File]::WriteAllText($dryRunCleanupSentinel, "dry-run-cleanup-sentinel", $utf8)
(Get-Item -LiteralPath $dryRunCleanupSentinel).LastWriteTime = (Get-Date).AddDays(-90)
$freshArgs = @(
    "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $scriptPath,
    "-SettingsPath", $settingsPath,
    "-ProjectRoot", $fixture,
    "-WorkDir", $staleWork,
    "-FreshProjectQuestion", "-DryRun", "-NoBanner", "-NoCountdown"
)
$freshOutput = @(& powershell.exe @freshArgs 2>&1)
Assert-True ($LASTEXITCODE -eq 0) ("Fresh DryRun failed: " + (($freshOutput | Select-Object -Last 20) -join [Environment]::NewLine))
$freshSummary = Get-Content -LiteralPath (Join-Path $staleWork "settings_effective_summary.json") -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ([string]$freshSummary.initialQuestionSource -eq "project-fresh-scan") "Fresh mode was overwritten by stale transcript recovery"
$freshQuestion = Get-Content -LiteralPath (Join-Path $staleWork "next_question.txt") -Raw -Encoding UTF8
Assert-True (-not $freshQuestion.Contains("STALE_")) "Fresh mode reused a stale saved question"
Assert-True (Test-Path -LiteralPath $dryRunCleanupSentinel -PathType Leaf) "DryRun performed destructive stale-file cleanup"

$serverArgLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $helper + '" -Port ' + $port + ' -ResponseCount 6 -RequestLog "' + $requestLog + '" -ReadyPath "' + $readyPath + '"'
$server = Start-Process -FilePath "powershell.exe" -ArgumentList $serverArgLine -PassThru -WindowStyle Hidden
try {
    for ($i = 0; $i -lt 100 -and -not (Test-Path -LiteralPath $readyPath); $i++) { Start-Sleep -Milliseconds 50 }
    Assert-True (Test-Path -LiteralPath $readyPath) "mock server did not become ready"

    $qwenArgs = @(
        "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $scriptPath,
        "-SettingsPath", $settingsPath,
        "-ProjectRoot", $fixture,
        "-WorkDir", $sessionRoot,
        "-NewProjectSession", "-FreshProjectQuestion",
        "-ProjectTurnsPerCycle", "5",
        "-ProjectSessionKeepCount", "12",
        "-ProjectSessionKeepDays", "30",
        "-ProjectSessionMaxTotalMB", "50",
        "-IntervalSeconds", "0",
        "-MaxRuns", "6",
        "-MaxRetries", "0",
        "-TimeoutSec", "20",
        "-NoCountdown", "-NoBanner", "-NoAnswerPreview"
    )
    $console = @(& powershell.exe @qwenArgs 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "qwen-loop.ps1 exited with $LASTEXITCODE. Last output: " + (($console | Select-Object -Last 30) -join [Environment]::NewLine)
    }

    [void]$server.WaitForExit(5000)
    Assert-True $server.HasExited "mock server did not receive six requests"
    Assert-True ($server.ExitCode -eq 0) "mock server exited with $($server.ExitCode)"

    $projectBase = Get-ChildItem -LiteralPath $sessionRoot -Directory | Select-Object -First 1
    Assert-True ($null -ne $projectBase) "project identity directory was not created"
    Assert-True ($projectBase.Name -match '-[0-9a-f]{10}$') "project identity does not include a stable path hash"
    $session = Get-ChildItem -LiteralPath (Join-Path $projectBase.FullName "sessions") -Directory | Select-Object -First 1
    Assert-True ($null -ne $session) "timestamp session directory was not created"
    Assert-True ($session.Name -match '^\d{8}-\d{6}-\d{3}-p\d+-\d{4}$') "session id format is incorrect"

    $manifest = Get-Content -LiteralPath (Join-Path $session.FullName "session_identity.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ([string]$manifest.identity -eq $projectBase.Name) "session identity marker mismatch"
    Assert-True ([string]$manifest.canonicalProjectRoot -eq (Resolve-Path $fixture).Path) "canonical ProjectRoot mismatch"
    Assert-True (Test-Path -LiteralPath (Join-Path $session.FullName ".qwen-loop-workdir.json") -PathType Leaf) "session WorkDir ownership marker was not created"

    $history = @(Get-Content -LiteralPath (Join-Path $session.FullName "run_history.jsonl") -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True ($history.Count -eq 6) "expected six run history records"
    Assert-True (($history.cycleIndex -join ",") -eq "1,1,1,1,1,2") "cycle indexes did not rotate after five successful turns"
    Assert-True (($history.turnInCycle -join ",") -eq "1,2,3,4,5,1") "turn-in-cycle sequence is incorrect"
    Assert-True ([string]$history[0].nextQuestion -eq "FOLLOWUP_1") "NEXT_QUESTION final-line extraction failed on turn one"
    Assert-True ([string]$history[4].nextQuestion -eq "SHOULD_NOT_BE_USED_AFTER_CYCLE") "turn-five NEXT_QUESTION extraction failed"
    Assert-True ([string]$history[5].nextQuestion -eq "FOLLOWUP_6") "NEXT_QUESTION extraction failed after cycle rotation"
    Assert-True ([string]$history[5].questionSource -eq "cycle-rescan") "sixth request was not sourced from a fresh cycle scan"
    Assert-True ([string]$history[0].primaryBusinessFamily -ne [string]$history[5].primaryBusinessFamily) "cycle two reused the previous business family despite an unseen alternative"

    $requests = @(Get-Content -LiteralPath $requestLog -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True ($requests.Count -eq 6) "mock server request log count mismatch"
    $sixthPrompt = [string]$requests[5].messages[1].content
    Assert-True (-not $sixthPrompt.Contains("SHOULD_NOT_BE_USED_AFTER_CYCLE")) "cycle two reused turn five NEXT_QUESTION"
    Assert-True (-not $sixthPrompt.Contains("BUSINESS_EVIDENCE_RESPONSE_5")) "cycle two retained the previous cycle last_turn"

    $cycleOne = Get-Content -LiteralPath (Join-Path $session.FullName "project_scan_cycle_001.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True (-not ([string]$cycleOne.primaryQuestionCandidateFile -match 'CommonJobListener')) "technical common listener became the primary business target"
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$cycleOne.primaryBusinessFamily)) "primary business family was not derived"
    $crossFamilyCandidates = @($cycleOne.questionCandidateDetails | Where-Object { [string]$_.businessFamilyKey -ne [string]$cycleOne.primaryBusinessFamily })
    Assert-True ($crossFamilyCandidates.Count -eq 0) "question seed support crossed the primary business family"
    Assert-True (@($cycleOne.questionCandidateDetails | Where-Object { $_.questionGroupRole -eq "technical-core" }).Count -eq 0) "technical core file entered the business seed slice"
    Assert-True (@($cycleOne.questionCandidateDetails | Where-Object { $_.questionGroupRole -eq "domain-model" }).Count -gt 0) "VO/domain model was not included in the business slice"
    Assert-True (@($cycleOne.questionCandidateDetails | Where-Object { $_.questionGroupRole -eq "db-sql" }).Count -gt 0) "Mapper XML/DB evidence was not included in the business slice"
    $firstPrompt = [string]$requests[0].messages[1].content
    Assert-True (-not ($firstPrompt -match '(?m)^### .*CommonJobListener\.java')) "common technical listener raw excerpt leaked into the business prompt"
    $otherFamilyPrefix = if ([string]$cycleOne.primaryBusinessFamily -eq "ord1001") { "Rfd2001" } else { "Ord1001" }
    Assert-True (-not ($firstPrompt -match ("(?m)^### .*" + $otherFamilyPrefix))) "another business family's raw excerpt leaked into the first prompt"
    $expectedTable = if ([string]$cycleOne.primaryBusinessFamily -eq "ord1001") { "TB_SHIPMENT_BASE" } else { "TB_REFUND_PAYMENT" }
    $expectedVoField = if ([string]$cycleOne.primaryBusinessFamily -eq "ord1001") { "shipmentStatus" } else { "paymentStatus" }
    Assert-True ($firstPrompt.Contains($expectedTable)) "Mapper table/column evidence was absent from the actual request prompt"
    Assert-True ($firstPrompt.Contains($expectedVoField)) "VO field evidence was absent from the actual request prompt"
    Assert-True ($firstPrompt.Length -lt 100000) "project user prompt exceeded the regression safety bound"

    $cycleTwo = Get-Content -LiteralPath (Join-Path $session.FullName "project_scan_cycle_002.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    $lastDynamic = Get-Content -LiteralPath (Join-Path $session.FullName "last_dynamic_project_context.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ([string]$lastDynamic.preferredBusinessFamily -eq [string]$cycleTwo.primaryBusinessFamily) "dynamic context did not retain the active business family restriction"
    Assert-True (@($lastDynamic.files | Where-Object { [string]$_.businessFamilyKey -ne [string]$cycleTwo.primaryBusinessFamily }).Count -eq 0) "dynamic direct/expanded candidates crossed the active business family"

    $status = Get-Content -LiteralPath (Join-Path $session.FullName "last_response_status.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ([string]$status.finishReason -eq "stop") "finish_reason was not recorded"
    Assert-True ([int]$status.reasoningTokens -eq 100) "reasoning token details were not recorded"
    Assert-True ([int]$status.answerDepth.visibleOutputTokens -eq 1700) "visible output tokens were not derived"
    Assert-True (-not [bool]$status.answerDepth.outputTargetMet) "short output incorrectly met token target"
    Assert-True (-not [bool]$status.answerDepth.charTargetMet) "short output incorrectly met char target"
    Assert-True ([bool]$status.requestStreaming) "default settings did not produce a streaming request"
    Assert-True ([string]$status.responseParseMode -eq "sse") "SSE response was parsed with the wrong mode"
    Assert-True ([int]$status.requestBodyChars -gt 0 -and [int]$status.userPromptChars -gt 0) "request-size diagnostics were not recorded"

    $ledger = @(Get-Content -LiteralPath (Join-Path $projectBase.FullName "exploration_history.jsonl") -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True ($ledger.Count -eq 2) "project exploration ledger should contain startup and cycle-two selections"
    Assert-True ([string]$ledger[0].businessFamily -ne [string]$ledger[1].businessFamily) "exploration ledger did not diversify business families"

    $activeSessionId = "20991231-235959-999-p99999-9999"
    $activeSession = Join-Path (Join-Path $projectBase.FullName "sessions") $activeSessionId
    New-Item -ItemType Directory -Force -Path $activeSession | Out-Null
    $activeMarker = [ordered]@{
        schema = "qwen-loop-project-session/v1"
        identity = $projectBase.Name
        canonicalProjectRoot = (Resolve-Path $fixture).Path
        sessionId = $activeSessionId
        createdAt = (Get-Date).ToString("o")
        processId = $PID
    }
    [System.IO.File]::WriteAllText((Join-Path $activeSession "session_identity.json"), ($activeMarker | ConvertTo-Json -Depth 10), $utf8)
    $activeLockStream = [System.IO.File]::Open((Join-Path $activeSession ".active.lock"), [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)

    $portProbe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $portProbe.Start()
    $retentionPort = ([System.Net.IPEndPoint]$portProbe.LocalEndpoint).Port
    $portProbe.Stop()
    $settings["modelProviders"]["openai"][0]["baseUrl"] = "http://127.0.0.1:$retentionPort"
    $settings["modelProviders"]["openai"][0]["generationConfig"]["extra_body"] = [ordered]@{ stream = $false }
    [System.IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Depth 30), $utf8)
    $retentionReady = Join-Path $runtime "retention-ready.txt"
    $retentionRequestLog = Join-Path $runtime "retention-request.jsonl"
    $retentionArgLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $helper + '" -Port ' + $retentionPort + ' -ResponseCount 1 -RequestLog "' + $retentionRequestLog + '" -ReadyPath "' + $retentionReady + '"'
    $server = Start-Process -FilePath "powershell.exe" -ArgumentList $retentionArgLine -PassThru -WindowStyle Hidden
    for ($i = 0; $i -lt 100 -and -not (Test-Path -LiteralPath $retentionReady); $i++) { Start-Sleep -Milliseconds 50 }
    Assert-True (Test-Path -LiteralPath $retentionReady) "retention mock server did not become ready"
    $retentionArgs = @(
        "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $scriptPath,
        "-SettingsPath", $settingsPath,
        "-ProjectRoot", $fixture,
        "-WorkDir", $sessionRoot,
        "-NewProjectSession", "-FreshProjectQuestion",
        "-ProjectTurnsPerCycle", "5",
        "-ProjectSessionKeepCount", "1",
        "-ProjectSessionKeepDays", "30",
        "-ProjectSessionMaxTotalMB", "50",
        "-IntervalSeconds", "0",
        "-MaxRuns", "1",
        "-MaxRetries", "0",
        "-TimeoutSec", "20",
        "-NoCountdown", "-NoBanner", "-NoAnswerPreview"
    )
    $retentionConsole = @(& powershell.exe @retentionArgs 2>&1)
    Assert-True ($LASTEXITCODE -eq 0) ("retention run failed: " + (($retentionConsole | Select-Object -Last 20) -join [Environment]::NewLine))
    [void]$server.WaitForExit(5000)
    Assert-True ($server.HasExited -and $server.ExitCode -eq 0) "retention mock request did not complete"
    $remainingSessions = @(Get-ChildItem -LiteralPath (Join-Path $projectBase.FullName "sessions") -Directory)
    Assert-True ($remainingSessions.Count -eq 2) "retention should preserve the current session plus an externally locked active session"
    Assert-True (Test-Path -LiteralPath $activeSession -PathType Container) "retention deleted an active locked session"
    Assert-True (-not (Test-Path -LiteralPath $session.FullName -PathType Container)) "KeepCount=1 did not remove the inactive old session"
    Assert-True (Test-Path -LiteralPath (Join-Path $projectBase.FullName "exploration_history.jsonl") -PathType Leaf) "retention removed the project exploration ledger"
    $currentSession = @($remainingSessions | Where-Object { $_.Name -ne $activeSessionId })[0]
    $nonStreamStatus = Get-Content -LiteralPath (Join-Path $currentSession.FullName "last_response_status.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ([string]$nonStreamStatus.finishReason -eq "stop") "non-streaming finish_reason was not recorded"
    Assert-True ([int]$nonStreamStatus.reasoningTokens -eq 100) "non-streaming reasoning token details were not recorded"
    Assert-True (-not [bool]$nonStreamStatus.requestStreaming) "settings extra_body.stream=false did not control the actual transport mode"
    Assert-True ([string]$nonStreamStatus.responseParseMode -eq "json") "JSON response was parsed with the wrong mode"
    $retentionRequest = Get-Content -LiteralPath $retentionRequestLog -Encoding UTF8 | Where-Object { $_ } | Select-Object -First 1 | ConvertFrom-Json
    Assert-True (-not [bool]$retentionRequest.stream) "wire body ignored settings stream override"
    Assert-True ($null -eq $retentionRequest.stream_options) "stream_options remained in a non-streaming wire body"

    $sessionsBeforePartial = @((Get-ChildItem -LiteralPath (Join-Path $projectBase.FullName "sessions") -Directory).FullName)
    $portProbe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $portProbe.Start()
    $partialPort = ([System.Net.IPEndPoint]$portProbe.LocalEndpoint).Port
    $portProbe.Stop()
    $settings["modelProviders"]["openai"][0]["baseUrl"] = "http://127.0.0.1:$partialPort"
    [System.IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Depth 30), $utf8)
    $partialReady = Join-Path $runtime "partial-ready.txt"
    $partialRequestLog = Join-Path $runtime "partial-requests.jsonl"
    $partialArgLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $helper + '" -Port ' + $partialPort + ' -ResponseCount 2 -RequestLog "' + $partialRequestLog + '" -ReadyPath "' + $partialReady + '" -FinishReason length -OmitNextQuestion'
    $server = Start-Process -FilePath "powershell.exe" -ArgumentList $partialArgLine -PassThru -WindowStyle Hidden
    for ($i = 0; $i -lt 100 -and -not (Test-Path -LiteralPath $partialReady); $i++) { Start-Sleep -Milliseconds 50 }
    Assert-True (Test-Path -LiteralPath $partialReady) "partial-response mock server did not become ready"
    $partialArgs = @(
        "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $scriptPath,
        "-SettingsPath", $settingsPath, "-ProjectRoot", $fixture, "-WorkDir", $sessionRoot,
        "-NewProjectSession", "-FreshProjectQuestion", "-ProjectTurnsPerCycle", "5",
        "-ProjectSessionKeepCount", "12", "-ProjectSessionKeepDays", "30", "-ProjectSessionMaxTotalMB", "50",
        "-IntervalSeconds", "0", "-MaxRuns", "2", "-MaxRetries", "0", "-TimeoutSec", "20",
        "-NoCountdown", "-NoBanner", "-NoAnswerPreview"
    )
    $partialConsole = @(& powershell.exe @partialArgs 2>&1)
    Assert-True ($LASTEXITCODE -eq 0) ("partial-response run failed: " + (($partialConsole | Select-Object -Last 20) -join [Environment]::NewLine))
    [void]$server.WaitForExit(5000)
    Assert-True ($server.HasExited -and $server.ExitCode -eq 0) "partial-response mock requests did not complete"
    $partialSession = @(Get-ChildItem -LiteralPath (Join-Path $projectBase.FullName "sessions") -Directory | Where-Object { $sessionsBeforePartial -notcontains $_.FullName } | Select-Object -First 1)[0]
    Assert-True ($null -ne $partialSession) "partial-response session was not created"
    $partialHistory = @(Get-Content -LiteralPath (Join-Path $partialSession.FullName "run_history.jsonl") -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True (($partialHistory.status -join ",") -eq "partial,partial") "length-truncated responses were incorrectly marked successful"
    Assert-True (($partialHistory.turnInCycle -join ",") -eq "1,1") "partial responses advanced the successful cycle turn"
    Assert-True (-not [bool]$partialHistory[0].nextQuestionMarkerFound) "missing NEXT_QUESTION marker was not recorded"
    Assert-True ([string]$partialHistory[0].partialReason -eq "finish_reason=length") "partial reason was not recorded"
    $partialNext = Get-Content -LiteralPath (Join-Path $partialSession.FullName "next_question.txt") -Raw -Encoding UTF8
    Assert-True ($partialNext.Contains("finish_reason=length")) "truncated response did not create an explicit continuation question"
    Assert-True (-not $partialNext.Contains("BUSINESS_EVIDENCE_RESPONSE")) "answer heading was misused as the next question"

    $unownedWork = Join-Path $repo ("tests\_unowned-workdir-" + $runId)
    New-Item -ItemType Directory -Force -Path $unownedWork | Out-Null
    $unownedSentinel = Join-Path $unownedWork "user-file-must-survive.tmp"
    [System.IO.File]::WriteAllText($unownedSentinel, "unowned-workdir-sentinel", $utf8)
    (Get-Item -LiteralPath $unownedSentinel).LastWriteTime = (Get-Date).AddDays(-90)
    $portProbe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $portProbe.Start()
    $unownedPort = ([System.Net.IPEndPoint]$portProbe.LocalEndpoint).Port
    $portProbe.Stop()
    $settings["modelProviders"]["openai"][0]["baseUrl"] = "http://127.0.0.1:$unownedPort"
    [System.IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Depth 30), $utf8)
    $unownedReady = Join-Path $runtime "unowned-ready.txt"
    $unownedRequestLog = Join-Path $runtime "unowned-request.jsonl"
    $unownedArgLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $helper + '" -Port ' + $unownedPort + ' -ResponseCount 1 -RequestLog "' + $unownedRequestLog + '" -ReadyPath "' + $unownedReady + '" -AppendTrailingText'
    $server = Start-Process -FilePath "powershell.exe" -ArgumentList $unownedArgLine -PassThru -WindowStyle Hidden
    for ($i = 0; $i -lt 100 -and -not (Test-Path -LiteralPath $unownedReady); $i++) { Start-Sleep -Milliseconds 50 }
    Assert-True (Test-Path -LiteralPath $unownedReady) "unowned-WorkDir mock server did not become ready"
    $unownedArgs = @(
        "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $scriptPath,
        "-SettingsPath", $settingsPath, "-WorkDir", $unownedWork,
        "-SeedFile", (Join-Path $repo "seed_prompt.txt"), "-QuestionBankFile", (Join-Path $repo "question_bank.txt"),
        "-Once", "-MaxRetries", "0", "-TimeoutSec", "20", "-CleanupKeepDays", "1",
        "-NoCountdown", "-NoBanner", "-NoAnswerPreview"
    )
    $unownedConsole = @(& powershell.exe @unownedArgs 2>&1)
    Assert-True ($LASTEXITCODE -eq 0) ("unowned-WorkDir run failed: " + (($unownedConsole | Select-Object -Last 20) -join [Environment]::NewLine))
    [void]$server.WaitForExit(5000)
    Assert-True ($server.HasExited -and $server.ExitCode -eq 0) "unowned-WorkDir mock request did not complete"
    Assert-True (Test-Path -LiteralPath $unownedSentinel -PathType Leaf) "auto-cleanup deleted a file from an unowned custom WorkDir"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $unownedWork ".qwen-loop-workdir.json") -PathType Leaf)) "non-empty custom WorkDir was claimed without ownership"
    $unownedSummary = Get-Content -LiteralPath (Join-Path $unownedWork "settings_effective_summary.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True (-not [bool]$unownedSummary.autoCleanup.enabled -and -not [bool]$unownedSummary.autoCleanup.workDirOwnershipVerified) "unowned custom WorkDir reported cleanup as enabled"
    $unownedHistory = Get-Content -LiteralPath (Join-Path $unownedWork "run_history.jsonl") -Encoding UTF8 | Where-Object { $_ } | Select-Object -Last 1 | ConvertFrom-Json
    Assert-True ([string]$unownedHistory.status -eq "partial" -and -not [bool]$unownedHistory.nextQuestionMarkerFound) "a non-final NEXT_QUESTION control line was accepted as complete"
    Assert-True ([string]$unownedHistory.partialReason -eq "next-question-marker-not-final") "non-final control line did not record its precise partial reason"

    Write-Host "PASS: Fresh isolation, session/cleanup safety, 5-turn rotation, domain slice, stream override, control-line/truncation handling, and answer diagnostics" -ForegroundColor Green
    if ($KeepArtifacts) { Write-Host "Artifacts: $runtime" -ForegroundColor DarkGray }
} finally {
    if ($server -and -not $server.HasExited) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
    if ($activeLockStream) { $activeLockStream.Dispose() }
    if ($unownedWork -and (Test-Path -LiteralPath $unownedWork -PathType Container)) {
        $testsRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
        $unownedFull = [System.IO.Path]::GetFullPath($unownedWork)
        if ($unownedFull.StartsWith($testsRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -and
            ([System.IO.Path]::GetFileName($unownedFull) -match '^_unowned-workdir-')) {
            Remove-Item -LiteralPath $unownedFull -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not $KeepArtifacts) {
        $expectedParent = [System.IO.Path]::GetFullPath((Join-Path $repo "qwen-loop-data"))
        $runtimeFull = [System.IO.Path]::GetFullPath($runtime)
        if ($runtimeFull.StartsWith($expectedParent + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -and
            ([System.IO.Path]::GetFileName($runtimeFull) -match '^_integration-')) {
            Remove-Item -LiteralPath $runtimeFull -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
