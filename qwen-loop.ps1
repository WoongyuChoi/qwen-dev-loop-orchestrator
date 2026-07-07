param(
    [string]$SettingsPath = "$env:USERPROFILE\.qwen\settings.json",
    [string]$ProviderName = "",
    [string]$ModelName = "",
    [string]$SeedFile = "$PSScriptRoot\seed_prompt.txt",
    [string]$QuestionBankFile = "$PSScriptRoot\question_bank.txt",
    [string]$QuestionTrack = "",
    [string]$ContextListFile = "$PSScriptRoot\context_files.txt",
    [string]$ProjectRoot = "",
    [string]$WorkDir = "$PSScriptRoot\qwen-loop-data",
    [int]$IntervalSeconds = 600,
    [int]$MinIntervalMinutes = 8,
    [int]$MaxIntervalMinutes = 15,
    [int]$MaxTokens = 8192,
    [double]$Temperature = 0.35,
    [int]$TimeoutSec = 120,
    [int]$MaxContextChars = 30000,
    [int]$ProjectScanMaxFiles = 60,
    [int]$ProjectScanMaxFileChars = 2500,
    [int]$ProjectScanMaxTotalChars = 30000,
    [int]$LastTurnChars = 12000,
    [int]$CountdownRefreshSeconds = 1,
    [int]$AnswerPreviewLines = 4,
    [int]$AnswerPreviewChars = 1000,
    [int]$TokenLowThreshold = 1000,
    [int]$TokenRichThreshold = 4000,
    [int]$MaxWorkDirMB = 100,
    [int]$MaxTranscriptMB = 25,
    [int]$MaxErrorLogMB = 5,
    [int]$CleanupKeepDays = 14,
    [int]$CleanupKeepTurns = 30,
    [int]$MaxRuns = 0,
    [int]$MaxRetries = 3,
    [int]$RetryInitialDelaySeconds = 1,
    [int]$RetryMaxDelaySeconds = 10,
    [string]$QwenCodeVersion = "",
    [string]$OpenAISdkVersion = "5.11.0",
    [string]$NodeRuntimeVersion = "",
    [switch]$Once,
    [switch]$DryRun,
    [switch]$CompatBody,
    [switch]$NonStreaming,
    [switch]$EndpointFallbacks,
    [switch]$UseSchedulerSamplingDefaults,
    [switch]$LoopDiagnosticHeaders,
    [switch]$NoClientIdentityHeaders,
    [switch]$NoBanner,
    [switch]$NoCountdown,
    [switch]$NoAnswerPreview,
    [switch]$NoAutoCleanup,
    [switch]$MaskSensitiveLogs,
    [switch]$LogSensitive
)

$ErrorActionPreference = "Stop"
$ScriptBoundParameterNames = @{}
foreach ($key in $PSBoundParameters.Keys) { $ScriptBoundParameterNames[$key] = $true }

# Windows PowerShell 5.1 + Korean Windows: make console and files consistently UTF-8.
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $Utf8NoBom
[Console]::InputEncoding = $Utf8NoBom
$OutputEncoding = $Utf8NoBom
try { [System.Net.ServicePointManager]::Expect100Continue = $false } catch { }

function Write-Utf8File($Path, $Text) {
    $dir = Split-Path -Parent $Path
    if ($dir -and !(Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($Path, [string]$Text, $Utf8NoBom)
}

function Append-Utf8File($Path, $Text) {
    $dir = Split-Path -Parent $Path
    if ($dir -and !(Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::AppendAllText($Path, [string]$Text, $Utf8NoBom)
}

function Read-Utf8File($Path) {
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
}

function Format-ByteSize([long]$Bytes) {
    if ($Bytes -ge 1GB) { return ("{0:N1} GB" -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ("{0:N1} MB" -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ("{0:N1} KB" -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Get-DirectorySizeBytes([string]$Path) {
    if (!(Test-Path -LiteralPath $Path -PathType Container)) { return 0 }

    $total = [int64]0
    Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $total += [int64]$_.Length
    }
    return $total
}

function Get-RelativeWorkPath([string]$Root, [string]$Path) {
    try {
        $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\', '/'))
        $pathFull = [System.IO.Path]::GetFullPath($Path)
        if ($pathFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $pathFull.Substring($rootFull.Length).TrimStart([char[]]@('\', '/'))
        }
    } catch { }
    return $Path
}

function Add-CleanupAction($Actions, [string]$Kind, [string]$Path, [long]$BeforeBytes, [long]$AfterBytes, [string]$Note) {
    $null = $Actions.Add([PSCustomObject]@{
        kind = $Kind
        path = $Path
        beforeBytes = $BeforeBytes
        afterBytes = $AfterBytes
        note = $Note
    })
}

function Assert-CleanupConfig() {
    if ($MaxWorkDirMB -lt 0) { throw "MaxWorkDirMB는 0 이상이어야 합니다. 0은 전체 폴더 크기 제한을 끕니다." }
    if ($MaxTranscriptMB -lt 0) { throw "MaxTranscriptMB는 0 이상이어야 합니다. 0은 transcript compact를 끕니다." }
    if ($MaxErrorLogMB -lt 0) { throw "MaxErrorLogMB는 0 이상이어야 합니다. 0은 error.log compact를 끕니다." }
    if ($CleanupKeepDays -lt 0) { throw "CleanupKeepDays는 0 이상이어야 합니다. 0은 날짜 기준 삭제를 끕니다." }
    if ($CleanupKeepTurns -lt 1) { throw "CleanupKeepTurns는 1 이상이어야 합니다." }
}

function Test-ProtectedWorkFile([string]$Root, [string]$FileFullName) {
    $relative = Get-RelativeWorkPath $Root $FileFullName
    if ($relative -match '[\\/]') { return $false }

    $name = [System.IO.Path]::GetFileName($relative)
    $protected = @(
        "next_question.txt",
        "last_turn.txt",
        "transcript.md",
        "transcript.jsonl",
        "run_history.md",
        "run_history.jsonl",
        "project_scan_summary.md",
        "project_scan_summary.json",
        "pending_question.txt",
        "error.log",
        "settings_effective_summary.json",
        "last_request_headers.json",
        "last_request_headers_sensitive.json",
        "last_request_body.json",
        "last_response_status.json"
    )
    return ($protected -contains $name)
}

function Test-StaleCleanupCandidate([string]$Root, $File) {
    if (Test-ProtectedWorkFile $Root $File.FullName) { return $false }

    $relative = Get-RelativeWorkPath $Root $File.FullName
    if ($relative -match '(^|[\\/])check([\\/]|$)') { return $true }
    if ($File.Name -match '^(dry_run_request_|settings_effective_summary).*\.json$') { return $true }
    if ($File.Name -match '\.(old|bak|tmp)$') { return $true }
    return $false
}

function Compact-TranscriptMarkdown([string]$Path, [int]$MaxMB, [int]$KeepTurns, $Actions, [string]$Root) {
    if ($MaxMB -le 0) { return }
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { return }

    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $item) { return }

    $maxBytes = [int64]$MaxMB * 1MB
    $beforeBytes = [int64]$item.Length
    if ($beforeBytes -le $maxBytes) { return }

    $raw = Read-Utf8File $Path
    $matches = [regex]::Matches($raw, '(?m)^---\s*$')
    $note = "kept recent transcript content"

    if ($matches.Count -gt $KeepTurns) {
        $start = $matches[$matches.Count - $KeepTurns].Index
        $kept = $raw.Substring($start).TrimStart()
        $note = "kept last $KeepTurns turns"
    } else {
        $targetChars = [Math]::Max(1000, [int]($maxBytes / 4))
        if ($raw.Length -le $targetChars) { return }
        $kept = $raw.Substring($raw.Length - $targetChars)
        $note = "kept size-limited tail"
    }

    $header = "<!-- qwen-loop auto-cleanup: compacted at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); $note. -->`n`n"
    Write-Utf8File $Path ($header + $kept)

    $afterBytes = [int64](Get-Item -LiteralPath $Path).Length
    if ($afterBytes -gt $maxBytes) {
        $raw = Read-Utf8File $Path
        $targetChars = [Math]::Max(1000, [int]($maxBytes / 4))
        if ($raw.Length -gt $targetChars) {
            $tail = $raw.Substring($raw.Length - $targetChars)
            $header = "<!-- qwen-loop auto-cleanup: compacted at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); kept size-limited tail. -->`n`n"
            Write-Utf8File $Path ($header + $tail)
            $afterBytes = [int64](Get-Item -LiteralPath $Path).Length
            $note = "kept size-limited tail"
        }
    }

    Add-CleanupAction $Actions "compacted" (Get-RelativeWorkPath $Root $Path) $beforeBytes $afterBytes $note
}

function Convert-JsonlLineForCleanup([string]$Line, [int]$AnswerChars) {
    try {
        $record = $Line | ConvertFrom-Json
        $plain = ConvertTo-PlainObject $record
        if ($plain -is [System.Collections.IDictionary] -and $plain.Contains("answer")) {
            $plain["answer"] = Get-TextPrefix ([string]$plain["answer"]) $AnswerChars
        }
        return ($plain | ConvertTo-Json -Compress -Depth 50)
    } catch {
        return (Get-TextPrefix $Line $AnswerChars)
    }
}

function Compact-TranscriptJsonl([string]$Path, [int]$MaxMB, [int]$KeepTurns, $Actions, [string]$Root) {
    if ($MaxMB -le 0) { return }
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { return }

    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $item) { return }

    $maxBytes = [int64]$MaxMB * 1MB
    $beforeBytes = [int64]$item.Length
    if ($beforeBytes -le $maxBytes) { return }

    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -gt $KeepTurns) {
        $lines = @($lines | Select-Object -Last $KeepTurns)
    }

    $processed = @($lines | ForEach-Object { Convert-JsonlLineForCleanup $_ 2000 })
    Write-Utf8File $Path (($processed -join "`n") + "`n")

    $afterBytes = [int64](Get-Item -LiteralPath $Path).Length
    $note = "kept last $($lines.Count) records with compact answers"

    if ($afterBytes -gt $maxBytes) {
        $fallbackCount = [Math]::Min(10, $processed.Count)
        $processed = @($lines | Select-Object -Last $fallbackCount | ForEach-Object { Convert-JsonlLineForCleanup $_ 500 })
        Write-Utf8File $Path (($processed -join "`n") + "`n")
        $afterBytes = [int64](Get-Item -LiteralPath $Path).Length
        $note = "kept last $fallbackCount records with short answers"
    }

    Add-CleanupAction $Actions "compacted" (Get-RelativeWorkPath $Root $Path) $beforeBytes $afterBytes $note
}

function Compact-TextTailFile([string]$Path, [int]$MaxMB, [string]$Label, $Actions, [string]$Root) {
    if ($MaxMB -le 0) { return }
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { return }

    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $item) { return }

    $maxBytes = [int64]$MaxMB * 1MB
    $beforeBytes = [int64]$item.Length
    if ($beforeBytes -le $maxBytes) { return }

    $raw = Read-Utf8File $Path
    $targetChars = [Math]::Max(1000, [int]($maxBytes / 4))
    if ($raw.Length -gt $targetChars) {
        $raw = $raw.Substring($raw.Length - $targetChars)
    }

    $header = "# qwen-loop auto-cleanup: compacted $Label at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); kept recent tail only.`n"
    Write-Utf8File $Path ($header + $raw)
    $afterBytes = [int64](Get-Item -LiteralPath $Path).Length
    Add-CleanupAction $Actions "compacted" (Get-RelativeWorkPath $Root $Path) $beforeBytes $afterBytes "kept recent tail"
}

function Remove-StaleCleanupFiles([string]$Root, [int]$KeepDays, $Actions) {
    if ($KeepDays -le 0) { return }
    if (!(Test-Path -LiteralPath $Root -PathType Container)) { return }

    $cutoff = (Get-Date).AddDays(-$KeepDays)
    $files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue)
    foreach ($file in $files) {
        if ($file.LastWriteTime -ge $cutoff) { continue }
        if (-not (Test-StaleCleanupCandidate $Root $file)) { continue }

        $beforeBytes = [int64]$file.Length
        $relative = Get-RelativeWorkPath $Root $file.FullName
        try {
            Remove-Item -LiteralPath $file.FullName -Force
            Add-CleanupAction $Actions "deleted" $relative $beforeBytes 0 "older than $KeepDays days"
        } catch {
            Add-CleanupAction $Actions "failed" $relative $beforeBytes $beforeBytes $_.Exception.Message
        }
    }
}

function Remove-EmptyWorkDirectories([string]$Root) {
    if (!(Test-Path -LiteralPath $Root -PathType Container)) { return }

    $dirs = @(Get-ChildItem -LiteralPath $Root -Recurse -Directory -Force -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length } -Descending)
    foreach ($dir in $dirs) {
        try {
            $children = @(Get-ChildItem -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue)
            if ($children.Count -eq 0) { Remove-Item -LiteralPath $dir.FullName -Force }
        } catch { }
    }
}

function Enforce-WorkDirSize([string]$Root, [int]$MaxMB, $Actions) {
    if ($MaxMB -le 0) { return "" }
    if (!(Test-Path -LiteralPath $Root -PathType Container)) { return "" }

    $maxBytes = [int64]$MaxMB * 1MB
    $total = Get-DirectorySizeBytes $Root
    if ($total -le $maxBytes) { return "" }

    $candidates = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { -not (Test-ProtectedWorkFile $Root $_.FullName) } |
        Sort-Object LastWriteTimeUtc, Length)

    foreach ($file in $candidates) {
        if ($total -le $maxBytes) { break }
        $beforeBytes = [int64]$file.Length
        $relative = Get-RelativeWorkPath $Root $file.FullName
        try {
            Remove-Item -LiteralPath $file.FullName -Force
            $total -= $beforeBytes
            Add-CleanupAction $Actions "deleted" $relative $beforeBytes 0 "folder size cap"
        } catch {
            Add-CleanupAction $Actions "failed" $relative $beforeBytes $beforeBytes $_.Exception.Message
        }
    }

    if ($total -gt $maxBytes) {
        return "WorkDir is still above limit: $(Format-ByteSize $total) / $(Format-ByteSize $maxBytes). Protected state files were kept."
    }
    return ""
}

function Invoke-WorkDirCleanup([string]$Root, [string]$TranscriptPath, [string]$JsonlPath, [string]$ErrorLogPath) {
    $actions = New-Object System.Collections.Generic.List[object]
    $beforeBytes = Get-DirectorySizeBytes $Root
    $warning = ""

    if ($NoAutoCleanup) {
        return [PSCustomObject]@{
            enabled = $false
            beforeBytes = $beforeBytes
            afterBytes = $beforeBytes
            actions = [object[]]@()
            warning = ""
        }
    }

    Compact-TranscriptMarkdown $TranscriptPath $MaxTranscriptMB $CleanupKeepTurns $actions $Root
    Compact-TranscriptJsonl $JsonlPath $MaxTranscriptMB $CleanupKeepTurns $actions $Root
    Compact-TextTailFile $ErrorLogPath $MaxErrorLogMB "error.log" $actions $Root
    Remove-StaleCleanupFiles $Root $CleanupKeepDays $actions
    $warning = Enforce-WorkDirSize $Root $MaxWorkDirMB $actions
    Remove-EmptyWorkDirectories $Root

    $afterBytes = Get-DirectorySizeBytes $Root
    return [PSCustomObject]@{
        enabled = $true
        beforeBytes = $beforeBytes
        afterBytes = $afterBytes
        actions = [object[]]$actions.ToArray()
        warning = $warning
    }
}

function Get-CleanupPolicyText() {
    if ($NoAutoCleanup) { return "disabled" }

    $folder = if ($MaxWorkDirMB -gt 0) { "folder <= $MaxWorkDirMB MB" } else { "folder cap off" }
    $transcript = if ($MaxTranscriptMB -gt 0) { "transcript <= $MaxTranscriptMB MB" } else { "transcript compact off" }
    $error = if ($MaxErrorLogMB -gt 0) { "error <= $MaxErrorLogMB MB" } else { "error compact off" }
    $days = if ($CleanupKeepDays -gt 0) { "stale check > $CleanupKeepDays days" } else { "stale check cleanup off" }
    return "$folder, $transcript, $error, keep $CleanupKeepTurns turns, $days"
}

function Write-WorkDirCleanupStatus($Summary, [bool]$Always) {
    if ($null -eq $Summary) { return }

    if (-not $Summary.enabled) {
        if ($Always) { Write-Host "Cleanup     : disabled" -ForegroundColor DarkGray }
        return
    }

    $actions = @($Summary.actions)
    if ($actions.Count -eq 0) {
        if ($Always) {
            Write-Host "Cleanup     : ok, current $(Format-ByteSize $Summary.afterBytes)" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "Cleanup     : $($actions.Count) action(s), $(Format-ByteSize $Summary.beforeBytes) -> $(Format-ByteSize $Summary.afterBytes)" -ForegroundColor DarkYellow
        foreach ($action in @($actions | Select-Object -First 6)) {
            $sizeText = if ($action.beforeBytes -gt 0 -or $action.afterBytes -gt 0) { " ($(Format-ByteSize $action.beforeBytes) -> $(Format-ByteSize $action.afterBytes))" } else { "" }
            Write-Host "  - $($action.kind) $($action.path)$sizeText; $($action.note)" -ForegroundColor DarkGray
        }
        if ($actions.Count -gt 6) {
            Write-Host "  - ... $($actions.Count - 6) more cleanup action(s)" -ForegroundColor DarkGray
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Summary.warning)) {
        Write-Host "CleanupWarn : $($Summary.warning)" -ForegroundColor Yellow
    }
}

function Remove-BomAndTrim([string]$Text) {
    if ($null -eq $Text) { return "" }
    return ([string]$Text).TrimStart([char]0xFEFF).Trim()
}

function Get-TextPrefix([string]$Text, [int]$MaxChars) {
    if ([string]::IsNullOrEmpty($Text)) { return "" }
    if ($Text.Length -le $MaxChars) { return $Text }
    return $Text.Substring(0, $MaxChars) + "`n...[truncated]..."
}

function Get-JsonProperty($obj, [string]$name) {
    if ($null -eq $obj) { return $null }
    $prop = $obj.PSObject.Properties | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if ($prop) { return $prop.Value }
    return $null
}

function ConvertTo-PlainObject($obj) {
    if ($null -eq $obj) { return $null }
    if ($obj -is [string] -or $obj.GetType().IsPrimitive -or $obj -is [decimal]) { return $obj }
    if ($obj -is [System.Collections.IDictionary]) {
        $h = [ordered]@{}
        foreach ($key in $obj.Keys) { $h[[string]$key] = ConvertTo-PlainObject $obj[$key] }
        return $h
    }
    if ($obj -is [System.Collections.IEnumerable] -and -not ($obj -is [string]) -and -not ($obj -is [System.Management.Automation.PSCustomObject])) {
        $arr = @()
        foreach ($i in $obj) { $arr += ,(ConvertTo-PlainObject $i) }
        return $arr
    }
    if ($obj -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = ConvertTo-PlainObject $p.Value }
        return $h
    }
    return $obj
}

function Mask-Secret([string]$value) {
    if ($null -eq $value) { return $null }
    if ($value.Length -le 4) { return "****" }
    return ($value.Substring(0,2) + "****" + $value.Substring($value.Length-2))
}

function Test-QuotedEmptySecret([string]$value) {
    if ($null -eq $value) { return $false }
    $trimmed = $value.Trim()
    return ($trimmed -eq '""' -or $trimmed -eq "''")
}

function Is-SensitiveHeaderName([string]$name) {
    if ([string]::IsNullOrWhiteSpace($name)) { return $false }
    if ($name -match '(?i)(source|envkey)$') { return $false }
    return ($name -match '(?i)(authorization|api[-_]?key|token|secret|credential|cookie)')
}

function Mask-HeaderValue([string]$name, [string]$value) {
    if ($name -ieq "Authorization" -and $value -match '^(Bearer\s+)(.+)$') {
        return ($Matches[1] + (Mask-Secret $Matches[2]))
    }
    return Mask-Secret $value
}

function Remove-HeaderKey($headers, [string]$name) {
    foreach ($key in @($headers.Keys)) {
        if ($key -ieq $name) { $headers.Remove($key) }
    }
}

function Set-HeaderLikeSdk($headers, [string]$name, $value) {
    Remove-HeaderKey $headers $name
    if ($null -ne $value) { $headers[$name] = [string]$value }
}

function Write-StartupBanner() {
    if ($NoBanner) { return }

    Write-Host ""
    Write-Host "   ____                         __                         " -ForegroundColor DarkYellow
    Write-Host "  / __ \__      _____  ____    / /   ____  ____  ____     " -ForegroundColor Yellow
    Write-Host " / / / / | /| / / _ \/ __ \  / /   / __ \/ __ \/ __ \    " -ForegroundColor Yellow
    Write-Host "/ /_/ /| |/ |/ /  __/ / / / / /___/ /_/ / /_/ / /_/ /    " -ForegroundColor Yellow
    Write-Host "\___\_\|__/|__/\___/_/ /_/ /_____/\____/\____/ .___/     " -ForegroundColor DarkYellow
    Write-Host "                                             /_/          " -ForegroundColor DarkYellow
    Write-Host "                 S C H E D U L E R   v4                  " -ForegroundColor DarkYellow
    Write-Host "       +------------------------------------------------+" -ForegroundColor DarkGray
    Write-Host "       | settings-first OpenAI-compatible API runner    |" -ForegroundColor Yellow
    Write-Host "       | random loop / visible status / transcript log  |" -ForegroundColor Yellow
    Write-Host "       +--------------------------.---------------------+" -ForegroundColor DarkGray
    Write-Host "                                  |" -ForegroundColor DarkGray
    Write-Host "                              [ QWEN ]" -ForegroundColor DarkYellow
    Write-Host "                               (o_o)" -ForegroundColor Yellow
    Write-Host "                            ---/|_|\---" -ForegroundColor DarkYellow
    Write-Host ""
}

function Get-PlatformUserAgent() {
    $arch = if ([Environment]::Is64BitProcess) { "x64" } else { "x86" }
    $version = $QwenCodeVersion
    if ([string]::IsNullOrWhiteSpace($version)) {
        $version = [Environment]::GetEnvironmentVariable("QWEN_CODE_VERSION")
    }
    if ([string]::IsNullOrWhiteSpace($version)) { $version = "unknown" }
    return "QwenCode/$version (win32; $arch)"
}

function Get-NodeLikeRuntimeVersion() {
    if (-not [string]::IsNullOrWhiteSpace($NodeRuntimeVersion)) { return $NodeRuntimeVersion }

    $fromEnv = [Environment]::GetEnvironmentVariable("QWEN_CODE_NODE_VERSION")
    if (-not [string]::IsNullOrWhiteSpace($fromEnv)) { return $fromEnv }

    return "unknown"
}

function Get-StainlessOsName() {
    return "Windows"
}

function Get-StainlessArchName() {
    if ([Environment]::Is64BitProcess) { return "x64" }
    return "x32"
}

function Get-ObjectProperties($obj) {
    if ($null -eq $obj -or $null -eq $obj.PSObject) { return @() }
    return @($obj.PSObject.Properties)
}

function Get-GenerationConfig($providerInfo) {
    if ($null -eq $providerInfo -or $null -eq $providerInfo.ProviderRaw) { return $null }
    return Get-JsonProperty $providerInfo.ProviderRaw "generationConfig"
}

function Get-ProviderModels($modelProviders, [string]$selectedType) {
    $selectedProviders = Get-JsonProperty $modelProviders $selectedType
    if ($null -eq $selectedProviders) { return @() }

    # Qwen Code source currently treats modelProviders.<authType> as ModelConfig[].
    # Some docs/examples show { protocol, models }, so accept that shape too.
    if ($selectedProviders -is [System.Management.Automation.PSCustomObject]) {
        $models = Get-JsonProperty $selectedProviders "models"
        if ($models) { return @($models) }
    }
    return @($selectedProviders)
}

function Read-DotEnvFile([string]$Path) {
    $result = [ordered]@{}
    if ([string]::IsNullOrWhiteSpace($Path) -or !(Test-Path -LiteralPath $Path -PathType Leaf)) { return $result }

    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        $trimmed = Remove-BomAndTrim $line
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) { continue }
        if ($trimmed -notmatch '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$') { continue }

        $key = $Matches[1]
        $value = $Matches[2].Trim()
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            if ($value.Length -ge 2) { $value = $value.Substring(1, $value.Length - 2) }
        }
        $result[$key] = $value
    }
    return $result
}

function Get-DotEnvCandidates([string]$settingsPath) {
    $candidates = New-Object System.Collections.Generic.List[string]
    $scriptQwenEnv = Join-Path $PSScriptRoot ".qwen\.env"
    $scriptEnv = Join-Path $PSScriptRoot ".env"
    $candidates.Add($scriptQwenEnv)
    $candidates.Add($scriptEnv)

    $settingsDir = Split-Path -Parent (Expand-PathInput $settingsPath)
    if ($settingsDir) { $candidates.Add((Join-Path $settingsDir ".env")) }

    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $candidates.Add((Join-Path $env:USERPROFILE ".qwen\.env"))
        $candidates.Add((Join-Path $env:USERPROFILE ".env"))
    }

    return $candidates | Select-Object -Unique
}

function Get-ApiKeyFromEnvironment([string]$envKeyName, $settings, [string]$settingsPath) {
    if ([string]::IsNullOrWhiteSpace($envKeyName)) {
        return [PSCustomObject]@{ Value = $null; Source = "none" }
    }

    $apiKey = [Environment]::GetEnvironmentVariable($envKeyName)
    if (-not [string]::IsNullOrEmpty($apiKey)) {
        return [PSCustomObject]@{ Value = $apiKey; Source = "os-environment" }
    }

    foreach ($candidate in (Get-DotEnvCandidates $settingsPath)) {
        $dotenv = Read-DotEnvFile $candidate
        if ($dotenv.Contains($envKeyName) -and -not [string]::IsNullOrEmpty([string]$dotenv[$envKeyName])) {
            return [PSCustomObject]@{ Value = [string]$dotenv[$envKeyName]; Source = ".env:$candidate" }
        }
    }

    $envObj = Get-JsonProperty $settings "env"
    $settingsEnvValue = Get-JsonProperty $envObj $envKeyName
    if ($null -ne $settingsEnvValue -and -not [string]::IsNullOrEmpty([string]$settingsEnvValue)) {
        return [PSCustomObject]@{ Value = [string]$settingsEnvValue; Source = "settings.json/env" }
    }

    return [PSCustomObject]@{ Value = $null; Source = "none" }
}

function Get-SettingsProvider($settings, [string]$providerName, [string]$modelNameOverride) {
    $modelProviders = Get-JsonProperty $settings "modelProviders"
    if ($null -eq $modelProviders) { throw "settings.json에서 modelProviders 항목을 찾지 못했습니다." }

    $selectedType = "openai"
    $security = Get-JsonProperty $settings "security"
    $auth = Get-JsonProperty $security "auth"
    $selectedFromSettings = Get-JsonProperty $auth "selectedType"
    if (-not [string]::IsNullOrWhiteSpace([string]$selectedFromSettings)) { $selectedType = [string]$selectedFromSettings }

    $providers = @(Get-ProviderModels $modelProviders $selectedType)
    if ($providers.Count -eq 0 -or $null -eq $providers[0]) {
        throw "settings.json에서 modelProviders.$selectedType 항목을 찾지 못했습니다."
    }

    $target = $providerName
    $model = Get-JsonProperty $settings "model"
    $modelNameFromSettings = Get-JsonProperty $model "name"
    if ([string]::IsNullOrWhiteSpace($target) -and $modelNameFromSettings) { $target = [string]$modelNameFromSettings }

    $provider = $null
    if (-not [string]::IsNullOrWhiteSpace($target)) {
        $provider = $providers | Where-Object { $_.name -eq $target -or $_.id -eq $target } | Select-Object -First 1
    }
    if ($null -eq $provider) { $provider = $providers | Select-Object -First 1 }

    $baseUrl = ([string](Get-JsonProperty $provider "baseUrl")).Trim().TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($baseUrl)) { throw "선택된 provider에 baseUrl이 없습니다. provider=$($provider.name)" }

    $providerId = [string](Get-JsonProperty $provider "id")
    $providerDisplayName = [string](Get-JsonProperty $provider "name")
    $modelId = if ([string]::IsNullOrWhiteSpace($modelNameOverride)) { $providerId } else { $modelNameOverride }
    if ([string]::IsNullOrWhiteSpace($modelId)) { $modelId = $providerDisplayName }
    if ([string]::IsNullOrWhiteSpace($modelId)) { throw "선택된 provider에 model id/name이 없습니다." }

    # IMPORTANT: exact envKey behavior. No dummy normalization.
    # Priority mirrors Qwen Code closely: OS environment, .env candidates, then settings.json env object.
    $envKeyName = [string](Get-JsonProperty $provider "envKey")
    $apiKeyResult = Get-ApiKeyFromEnvironment $envKeyName $settings $SettingsPath

    return [PSCustomObject]@{
        Type = $selectedType
        ProviderName = $providerDisplayName
        ProviderId = $providerId
        ModelId = $modelId
        BaseUrl = $baseUrl
        EnvKey = $envKeyName
        ApiKey = $apiKeyResult.Value
        ApiKeySource = $apiKeyResult.Source
        ProviderRaw = $provider
    }
}

function Get-EndpointCandidates([string]$baseUrl) {
    $b = $baseUrl.TrimEnd('/')
    if (-not $EndpointFallbacks) {
        return @("$b/chat/completions")
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($b -match '/v1$') {
        $candidates.Add("$b/chat/completions")
    } else {
        $candidates.Add("$b/v1/chat/completions")
        $candidates.Add("$b/chat/completions")
    }
    return $candidates | Select-Object -Unique
}

function Normalize-ModelForQwenTokenLimit([string]$model) {
    $s = ([string]$model).ToLower().Trim()
    $s = $s -replace '^.*/', ''
    $parts = $s -split '[|:]'
    $s = $parts[$parts.Length - 1]
    $s = $s -replace '\s+', '-'
    if ($s -notmatch '^qwen-(?:plus|flash|vl-max)-latest$' -and $s -notmatch '^kimi-k2-\d{4}$') {
        $s = $s -replace '-(?:\d{4,}|\d+x\d+b|v\d+(?:\.\d+)*|latest|exp)$', ''
    }
    $s = $s -replace '-(?:\d?bit|int[48]|bf16|fp16|q[45]|quantized)$', ''
    return $s
}

function Get-QwenCodeOutputTokenLimit([string]$model) {
    $envMaxTokens = [Environment]::GetEnvironmentVariable("QWEN_CODE_MAX_OUTPUT_TOKENS")
    if (-not [string]::IsNullOrWhiteSpace($envMaxTokens) -and $envMaxTokens -match '^\d+$') {
        $parsed = [int64]$envMaxTokens
        if ($parsed -gt 0 -and $parsed -le [int]::MaxValue) { return [int]$parsed }
    }

    $norm = Normalize-ModelForQwenTokenLimit $model
    if ($norm -match '^gemini-3') { return 65536 }
    if ($norm -match '^gemini-') { return 8192 }
    if ($norm -match '^gpt-5') { return 131072 }
    if ($norm -match '^gpt-') { return 16384 }
    if ($norm -match '^o\d') { return 131072 }
    if ($norm -match '^claude-opus-4-6') { return 131072 }
    if ($norm -match '^claude-sonnet-4-6') { return 65536 }
    if ($norm -match '^claude-') { return 65536 }
    if ($norm -match '^qwen3\.\d') { return 65536 }
    if ($norm -match '^coder-model$') { return 65536 }
    if ($norm -match '^qwen') { return 32000 }
    if ($norm -match '^deepseek-v4') { return 384000 }
    if ($norm -match '^deepseek-reasoner' -or $norm -match '^deepseek-r1') { return 65536 }
    if ($norm -match '^deepseek-chat') { return 8192 }
    if ($norm -match '^glm-5(?:\.\d+)?(?:-|$)') { return 131072 }
    if ($norm -match '^glm-4\.7') { return 16384 }
    if ($norm -match '^minimax-m2\.5') { return 65536 }
    if ($norm -match '^kimi-k2\.5') { return 32000 }
    return 32000
}

function Get-EffectiveTimeoutSeconds($providerInfo) {
    $generationConfig = Get-GenerationConfig $providerInfo
    $timeoutMs = Get-JsonProperty $generationConfig "timeout"
    if ($null -ne $timeoutMs) {
        try {
            $numericTimeoutMs = [double]$timeoutMs
            if ($numericTimeoutMs -gt 0) {
                return [int][Math]::Ceiling($numericTimeoutMs / 1000)
            }
        } catch { }
    }
    return $TimeoutSec
}

function Get-IntervalPlan() {
    $fixedIntervalWasExplicit = $ScriptBoundParameterNames.ContainsKey("IntervalSeconds")
    $randomIntervalWasExplicit = $ScriptBoundParameterNames.ContainsKey("MinIntervalMinutes") -or $ScriptBoundParameterNames.ContainsKey("MaxIntervalMinutes")

    if ($fixedIntervalWasExplicit -and -not $randomIntervalWasExplicit) {
        if ($IntervalSeconds -le 0) { throw "IntervalSeconds는 1 이상이어야 합니다." }
        return [PSCustomObject]@{
            Mode = "fixed"
            FixedSeconds = [int]$IntervalSeconds
            MinSeconds = [int]$IntervalSeconds
            MaxSeconds = [int]$IntervalSeconds
            Note = "Legacy fixed interval mode because -IntervalSeconds was explicitly provided without random min/max."
        }
    }

    if ($MinIntervalMinutes -le 0) { throw "MinIntervalMinutes는 1 이상이어야 합니다." }
    if ($MaxIntervalMinutes -le 0) { throw "MaxIntervalMinutes는 1 이상이어야 합니다." }
    if ($MaxIntervalMinutes -lt $MinIntervalMinutes) {
        throw "MaxIntervalMinutes는 MinIntervalMinutes보다 크거나 같아야 합니다. min=$MinIntervalMinutes max=$MaxIntervalMinutes"
    }

    $minSeconds = [int]($MinIntervalMinutes * 60)
    $maxSeconds = [int]($MaxIntervalMinutes * 60)
    return [PSCustomObject]@{
        Mode = "random"
        FixedSeconds = $null
        MinSeconds = $minSeconds
        MaxSeconds = $maxSeconds
        Note = "After each request, a new random wait interval is sampled from MinIntervalMinutes..MaxIntervalMinutes."
    }
}

function Get-NextIntervalSeconds($intervalPlan) {
    if ($intervalPlan.Mode -eq "fixed") { return [int]$intervalPlan.FixedSeconds }
    return [int](Get-Random -Minimum ([int]$intervalPlan.MinSeconds) -Maximum ([int]$intervalPlan.MaxSeconds + 1))
}

function Format-IntervalDuration([int]$seconds) {
    $minutes = [int][Math]::Floor($seconds / 60)
    $remainingSeconds = $seconds % 60
    if ($remainingSeconds -eq 0) { return "$minutes min ($seconds sec)" }
    return "$minutes min $remainingSeconds sec ($seconds sec)"
}

function Format-CountdownDuration([int]$seconds) {
    if ($seconds -lt 0) { $seconds = 0 }

    $span = [TimeSpan]::FromSeconds($seconds)
    if ($span.TotalHours -ge 1) {
        return "{0:00}:{1:00}:{2:00}" -f [int][Math]::Floor($span.TotalHours), $span.Minutes, $span.Seconds
    }
    return "{0:00}:{1:00}" -f $span.Minutes, $span.Seconds
}

function Get-ConsoleLineLimit() {
    $widths = New-Object System.Collections.Generic.List[int]
    try {
        if ([Console]::BufferWidth -gt 0) { $widths.Add([int][Console]::BufferWidth) }
    } catch { }
    try {
        if ([Console]::WindowWidth -gt 0) { $widths.Add([int][Console]::WindowWidth) }
    } catch { }

    $width = 80
    if ($widths.Count -gt 0) {
        $width = [int](($widths | Measure-Object -Minimum).Minimum)
    }

    return [Math]::Max(20, [Math]::Min(60, $width - 2))
}

function Get-SafeConsoleLine([string]$Line) {
    $maxLength = Get-ConsoleLineLimit

    if ($Line.Length -le $maxLength) { return $Line }
    if ($maxLength -le 3) { return $Line.Substring(0, $maxLength) }
    return ($Line.Substring(0, $maxLength - 3) + "...")
}

function Wait-WithCountdown([int]$seconds, $intervalPlan) {
    if ($seconds -le 0) { return }
    if ($CountdownRefreshSeconds -le 0) { throw "CountdownRefreshSeconds는 1 이상이어야 합니다." }

    $nextAt = (Get-Date).AddSeconds($seconds)
    $modeSuffix = if ($intervalPlan.Mode -eq "random") { "random" } else { "fixed" }

    if ($NoCountdown) {
        Write-Host "`nWait $(Format-CountdownDuration $seconds) ($(Format-IntervalDuration $seconds)); next $($nextAt.ToString('HH:mm:ss')); $modeSuffix; Ctrl+C to stop." -ForegroundColor DarkGray
        Start-Sleep -Seconds $seconds
        return
    }

    Write-Host ""
    $lastLength = 0
    while ($true) {
        $remaining = [int][Math]::Ceiling(($nextAt - (Get-Date)).TotalSeconds)
        if ($remaining -lt 0) { $remaining = 0 }

        $lineLimit = Get-ConsoleLineLimit
        $line = Get-SafeConsoleLine ("Wait $(Format-CountdownDuration $remaining) (${remaining}s) | next $($nextAt.ToString('HH:mm:ss')) | $modeSuffix | Ctrl+C")
        $paddingLength = [Math]::Max(0, ([Math]::Min($lastLength, $lineLimit) - $line.Length))
        $padding = if ($paddingLength -gt 0) { " " * $paddingLength } else { "" }
        [Console]::Write("`r$line$padding")
        $lastLength = $line.Length

        if ($remaining -le 0) { break }
        Start-Sleep -Seconds ([Math]::Min($CountdownRefreshSeconds, $remaining))
    }
    [Console]::WriteLine("")
}

function Format-HistoryDate($DateValue) {
    if ($null -eq $DateValue) { return "" }
    try { return ([datetime]$DateValue).ToString("yyyy-MM-dd HH:mm:ss") } catch { return "" }
}

function Format-HistoryDuration([Nullable[double]]$Seconds) {
    if ($null -eq $Seconds) { return "" }
    if ($Seconds -lt 1) { return ("{0:N0} ms" -f ($Seconds * 1000)) }
    if ($Seconds -lt 60) { return ("{0:N1} sec" -f $Seconds) }
    return (Format-IntervalDuration ([int][Math]::Round($Seconds)))
}

function Get-HistoryPreview([string]$Text, [int]$MaxChars) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    $singleLine = (($Text -replace '\r?\n', ' ') -replace '\s+', ' ').Trim()
    if ($singleLine.Length -le $MaxChars) { return $singleLine }
    return ($singleLine.Substring(0, [Math]::Max(0, $MaxChars - 3)) + "...")
}

function Escape-MarkdownTableCell([string]$Text) {
    if ($null -eq $Text) { return "" }
    return (([string]$Text) -replace '\|', '\|' -replace '\r?\n', '<br>')
}

function Ensure-RunHistoryMarkdown([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
        if ($item -and $item.Length -gt 0) { return }
    }

    $header = @"
# Qwen Loop Run History

이 파일은 실행 생명주기 확인용 기록입니다. `transcript.md`가 답변 내용 중심이라면, 이 파일은 언제 쐈고 언제 응답이 왔고 다음 실행 예정이 언제였는지 보는 테이블입니다.

| Seq | Session | Status | Started | Request | Response | Elapsed | HTTP | Next Wait | Next Run | Question | Next Question | Note |
|---:|---:|---|---|---|---|---:|---|---|---|---|---|---|
"@
    Write-Utf8File $Path ($header + "`n")
}

function Get-NextRunHistorySequence([string]$JsonlPath) {
    if (!(Test-Path -LiteralPath $JsonlPath -PathType Leaf)) { return 1 }

    $lines = @(Get-Content -LiteralPath $JsonlPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        try {
            $record = $lines[$i] | ConvertFrom-Json
            $seq = Get-JsonProperty $record "seq"
            if ($null -ne $seq) { return ([int]$seq + 1) }
        } catch { }
    }
    return ($lines.Count + 1)
}

function Append-RunHistory($Record, [string]$MarkdownPath, [string]$JsonlPath) {
    Ensure-RunHistoryMarkdown $MarkdownPath

    $elapsed = ""
    if ($Record.startedAt -and $Record.completedAt) {
        try { $elapsed = Format-HistoryDuration (([datetime]$Record.completedAt - [datetime]$Record.startedAt).TotalSeconds) } catch { }
    }

    $http = ""
    if ($Record.httpStatusCode) {
        $http = "$($Record.httpStatusCode) $($Record.httpStatusDescription)".Trim()
    }

    $nextWait = ""
    if ($Record.nextWaitSeconds -ne $null) { $nextWait = Format-IntervalDuration ([int]$Record.nextWaitSeconds) }

    $note = ""
    if ($Record.error) {
        $note = Get-HistoryPreview ([string]$Record.error) 80
    } elseif ($Record.answerChars -ne $null) {
        $note = "answer=$($Record.answerChars) chars"
        if ($Record.outputTokens -ne $null) { $note += ", outputTokens=$($Record.outputTokens)" }
    }

    $cells = @(
        $Record.seq,
        $Record.sessionRun,
        $Record.status,
        (Format-HistoryDate $Record.startedAt),
        (Format-HistoryDate $Record.requestAt),
        (Format-HistoryDate $Record.completedAt),
        $elapsed,
        $http,
        $nextWait,
        (Format-HistoryDate $Record.nextRunAt),
        (Get-HistoryPreview ([string]$Record.question) 70),
        (Get-HistoryPreview ([string]$Record.nextQuestion) 70),
        $note
    ) | ForEach-Object { Escape-MarkdownTableCell ([string]$_) }

    Append-Utf8File $MarkdownPath (("| " + ($cells -join " | ") + " |") + "`n")
    Append-Utf8File $JsonlPath (($Record | ConvertTo-Json -Compress -Depth 30) + "`n")
}

function Expand-PathInput([string]$PathText) {
    $p = Remove-BomAndTrim $PathText
    if ([string]::IsNullOrWhiteSpace($p)) { return "" }
    $p = [Environment]::ExpandEnvironmentVariables($p)
    if ($p -eq "~") { return $env:USERPROFILE }
    if ($p.StartsWith("~\") -or $p.StartsWith("~/")) {
        return (Join-Path $env:USERPROFILE $p.Substring(2))
    }
    return $p
}

function Resolve-ReadablePath([string]$PathText) {
    $p = Expand-PathInput $PathText
    if ([string]::IsNullOrWhiteSpace($p)) { return $null }

    $candidates = New-Object System.Collections.Generic.List[string]
    $candidates.Add($p)
    if (-not [System.IO.Path]::IsPathRooted($p)) {
        $candidates.Add((Join-Path $PSScriptRoot $p))
        $candidates.Add((Join-Path (Get-Location).Path $p))
    }

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate | Select-Object -First 1).Path
        }
    }
    throw "파일을 찾지 못했습니다: $p"
}

function Read-ContextBundle([string]$listFile, [int]$maxChars) {
    if (!(Test-Path -LiteralPath $listFile)) { return "" }

    $paths = Get-Content -LiteralPath $listFile -Encoding UTF8 |
        ForEach-Object { Remove-BomAndTrim $_ } |
        Where-Object { $_ -and -not $_.StartsWith('#') }

    if ($paths.Count -eq 0) { return "" }

    $bundleParts = New-Object System.Collections.Generic.List[string]
    $used = 0
    foreach ($p in $paths) {
        try {
            $resolvedPath = Resolve-ReadablePath $p
            $raw = Read-Utf8File $resolvedPath
            $remaining = $maxChars - $used
            if ($remaining -le 0) { break }
            if ($raw.Length -gt $remaining) { $raw = $raw.Substring(0, $remaining) + "`n...[context truncated]..." }
            $bundleParts.Add("`n--- CONTEXT FILE: $resolvedPath ---`n$raw`n--- END CONTEXT FILE ---`n")
            $used += $raw.Length
        } catch {
            $bundleParts.Add("`n--- CONTEXT FILE LOAD FAILED: $p / $($_.Exception.Message) ---`n")
        }
    }
    return ($bundleParts -join "`n")
}

function Assert-ProjectScanConfig() {
    if ($ProjectScanMaxFiles -lt 1) { throw "ProjectScanMaxFiles는 1 이상이어야 합니다." }
    if ($ProjectScanMaxFileChars -lt 200) { throw "ProjectScanMaxFileChars는 200 이상이어야 합니다." }
    if ($ProjectScanMaxTotalChars -lt 1000) { throw "ProjectScanMaxTotalChars는 1000 이상이어야 합니다." }
}

function Resolve-ProjectRoot([string]$PathText) {
    $p = Expand-PathInput $PathText
    if ([string]::IsNullOrWhiteSpace($p)) { return "" }
    if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path $PSScriptRoot $p }
    if (!(Test-Path -LiteralPath $p -PathType Container)) { throw "ProjectRoot 디렉터리를 찾지 못했습니다: $PathText" }
    return [System.IO.Path]::GetFullPath($p).TrimEnd([char[]]@('\', '/'))
}

function Test-ProjectExcludedDirectoryName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    $excluded = @(
        ".git", ".svn", ".hg", ".idea", ".vscode", ".gradle",
        "node_modules", "dist", "build", "target", "out", "coverage",
        ".next", ".nuxt", ".cache", ".turbo", "logs", "log",
        "qwen-loop-data", "bin", "obj", "vendor"
    )
    return ($excluded -contains $Name.ToLowerInvariant())
}

function Test-ProjectIncludedFile([System.IO.FileInfo]$File) {
    $ext = $File.Extension.ToLowerInvariant()
    $allowed = @(
        ".java", ".kt", ".kts", ".xml", ".properties", ".yml", ".yaml",
        ".gradle", ".json", ".ts", ".tsx", ".js", ".jsx",
        ".vue", ".sql", ".md", ".graphql", ".gql",
        ".ps1", ".psm1", ".bat", ".cmd", ".sh"
    )
    if ($allowed -notcontains $ext) { return $false }
    if ($File.Length -gt 1MB) { return $false }
    if ($File.Name -match '(?i)^\.env($|\.)|^\.npmrc$|^\.pypirc$') { return $false }
    if ($File.Name -match '(?i)(package-lock|yarn\.lock|pnpm-lock|gradle\.lockfile)$') { return $false }
    if ($File.Name -match '(?i)(\.min\.js|\.map)$') { return $false }
    return $true
}

function Get-ProjectRelativePath([string]$Root, [string]$Path) {
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\', '/'))
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    if ($pathFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $pathFull.Substring($rootFull.Length).TrimStart([char[]]@('\', '/'))
    }
    return $Path
}

function Read-ProjectFilePrefix([string]$Path, [int]$MaxChars) {
    try {
        $raw = Read-Utf8File $Path
        return Get-TextPrefix $raw $MaxChars
    } catch {
        try {
            $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::Default)
            return Get-TextPrefix $raw $MaxChars
        } catch {
            return ""
        }
    }
}

function Add-ProjectScoreReason($Reasons, [string]$Reason) {
    if (-not [string]::IsNullOrWhiteSpace($Reason) -and -not $Reasons.Contains($Reason)) { $Reasons.Add($Reason) | Out-Null }
}

function Get-ProjectFileScore([System.IO.FileInfo]$File, [string]$Root, [string]$Content) {
    $relative = Get-ProjectRelativePath $Root $File.FullName
    $relLower = $relative.ToLowerInvariant()
    $nameLower = $File.Name.ToLowerInvariant()
    $score = 0
    $reasons = New-Object System.Collections.Generic.List[string]

    if ($nameLower -in @("pom.xml", "build.gradle", "settings.gradle", "package.json", "vite.config.ts", "next.config.js", "tsconfig.json")) {
        $score += 35; Add-ProjectScoreReason $reasons "project/build entry"
    }
    if ($nameLower -match '(run|start|loop|main|check).*\.(ps1|bat|cmd|sh)$') {
        $score += 35; Add-ProjectScoreReason $reasons "script entry"
    }
    if ($nameLower -match 'application\.(yml|yaml|properties)$') {
        $score += 35; Add-ProjectScoreReason $reasons "runtime config"
    }
    if ($nameLower -match '(application|main)\.(java|kt|tsx|ts|jsx|js|ps1)$') {
        $score += 25; Add-ProjectScoreReason $reasons "entry point"
    }
    if ($nameLower -match '(controller|resource)\.(java|kt)$') {
        $score += 35; Add-ProjectScoreReason $reasons "api boundary"
    }
    if ($nameLower -match 'service\.(java|kt)$') {
        $score += 45; Add-ProjectScoreReason $reasons "service/domain logic"
    }
    if ($nameLower -match '(repository|mapper|dao)\.(java|kt|xml)$') {
        $score += 35; Add-ProjectScoreReason $reasons "db boundary"
    }
    if ($nameLower -match '(config|security|filter|interceptor)\.(java|kt|ts|tsx)$') {
        $score += 25; Add-ProjectScoreReason $reasons "cross-cutting config"
    }
    if ($relLower -match '(^|[\\/])(pages|routes|router|app)[\\/]') {
        $score += 25; Add-ProjectScoreReason $reasons "frontend route/page"
    }
    if ($relLower -match '(^|[\\/])(api|services|store|stores|hooks|features)[\\/]') {
        $score += 22; Add-ProjectScoreReason $reasons "frontend data/state boundary"
    }

    $contentLower = if ($Content) { $Content.ToLowerInvariant() } else { "" }
    $keywordRules = @(
        @("@transactional", 25, "transaction boundary"),
        @("@requestmapping", 18, "spring route mapping"),
        @("@getmapping", 18, "spring route mapping"),
        @("@postmapping", 18, "spring route mapping"),
        @("useeffect", 12, "react side effect"),
        @("usestate", 8, "react state"),
        @("usequery", 15, "frontend server-state query"),
        @("axios", 12, "http client"),
        @("fetch(", 12, "http client"),
        @("createstore", 12, "state store"),
        @("createslice", 12, "state store"),
        @("zustand", 12, "state store"),
        @("try {", 6, "error handling"),
        @("catch", 6, "error handling"),
        @("param(", 10, "script parameters"),
        @("invoke-restmethod", 18, "http client"),
        @("invoke-webrequest", 18, "http client"),
        @("powershell.exe", 12, "script launcher")
    )
    foreach ($rule in $keywordRules) {
        if ($contentLower.Contains([string]$rule[0])) {
            $score += [int]$rule[1]
            Add-ProjectScoreReason $reasons ([string]$rule[2])
        }
    }

    if ($File.Extension.ToLowerInvariant() -in @(".sql", ".xml") -or $relLower -match 'mapper|mybatis') {
        $sqlRules = @(
            @("select ", 12, "sql read"),
            @("insert ", 12, "sql write"),
            @("update ", 12, "sql write"),
            @("delete ", 12, "sql delete")
        )
        foreach ($rule in $sqlRules) {
            if ($contentLower.Contains([string]$rule[0])) {
                $score += [int]$rule[1]
                Add-ProjectScoreReason $reasons ([string]$rule[2])
            }
        }
    }

    $methodMatches = ([regex]::Matches($Content, '(?m)\b(public|private|protected|async|function|const)\b')).Count
    if ($methodMatches -ge 8) {
        $score += 10
        Add-ProjectScoreReason $reasons "many executable blocks"
    }

    return [PSCustomObject]@{
        path = $relative
        fullName = $File.FullName
        extension = $File.Extension
        sizeBytes = [int64]$File.Length
        score = $score
        reasons = @($reasons)
        excerpt = $Content
    }
}

function Get-ProjectCandidateFiles([string]$Root) {
    $result = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    $queue = New-Object System.Collections.Generic.Queue[System.IO.DirectoryInfo]
    $queue.Enqueue((Get-Item -LiteralPath $Root))
    $visitedDirs = 0

    while ($queue.Count -gt 0 -and $visitedDirs -lt 3000 -and $result.Count -lt 2000) {
        $dir = $queue.Dequeue()
        $visitedDirs++

        try {
            foreach ($childDir in @(Get-ChildItem -LiteralPath $dir.FullName -Directory -Force -ErrorAction SilentlyContinue)) {
                if (-not (Test-ProjectExcludedDirectoryName $childDir.Name)) { $queue.Enqueue($childDir) }
            }
            foreach ($file in @(Get-ChildItem -LiteralPath $dir.FullName -File -Force -ErrorAction SilentlyContinue)) {
                if (Test-ProjectIncludedFile $file) { $result.Add($file) | Out-Null }
            }
        } catch { }
    }

    return @($result)
}

function Get-DetectedProjectStack($Files) {
    $paths = (($Files | ForEach-Object { $_.FullName.ToLowerInvariant() }) -join "`n")
    $stack = New-Object System.Collections.Generic.List[string]

    if ($paths -match 'pom\.xml|build\.gradle|\.java|\.kt') { $stack.Add("Java/Spring") | Out-Null }
    if ($paths -match 'package\.json|\.tsx|\.jsx|vite\.config|next\.config') { $stack.Add("React/TypeScript") | Out-Null }
    if ($paths -match 'mapper|mybatis|\.sql') { $stack.Add("DB/MyBatis/SQL") | Out-Null }
    if ($paths -match 'security|auth|jwt|oauth') { $stack.Add("Security/Auth") | Out-Null }
    if ($paths -match '\.ps1|\.bat|\.cmd|\.sh') { $stack.Add("Script/Automation") | Out-Null }
    if ($stack.Count -eq 0) { $stack.Add("generic codebase") | Out-Null }
    return @($stack)
}

function Select-ProjectQuestionCandidates($Files, [int]$Count, [int]$PoolSize) {
    $items = @($Files | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.path) })
    if ($items.Count -eq 0 -or $Count -lt 1) { return @() }

    $effectivePoolSize = [Math]::Min([Math]::Max($PoolSize, $Count), $items.Count)
    $pool = @($items | Select-Object -First $effectivePoolSize)
    if ($pool.Count -le $Count) { return @($pool) }

    return @($pool | Get-Random -Count $Count)
}

function Test-ProjectScanBootstrapQuestion([string]$Question) {
    $q = ([string]$Question).Trim() -replace '\s+', ' '
    if ([string]::IsNullOrWhiteSpace($q)) { return $false }

    if ($q -match '^프로젝트 핵심 후보 파일\(.+\)을 바탕으로,') { return $true }
    if ($q -match '^아래 프로젝트 스캔 결과의 핵심 파일과 코드 조각을 바탕으로,') { return $true }
    if ($q -match '^이전 실행에서 프로젝트 전체 핵심 후보를 고르는 초기 질문이 이미 전송됐지만 완료 기록이 없습니다\.') { return $true }
    if ($q -match '^이전 실행에서 프로젝트 스캔 기반 초기 질문이 이미 전송됐지만 완료 기록이 없습니다\.') { return $true }

    return $false
}

function New-ProjectScanContext([string]$Root) {
    if ([string]::IsNullOrWhiteSpace($Root)) { return $null }

    Assert-ProjectScanConfig
    $resolvedRoot = Resolve-ProjectRoot $Root
    $files = @(Get-ProjectCandidateFiles $resolvedRoot)
    $scored = New-Object System.Collections.Generic.List[object]

    foreach ($file in $files) {
        $content = Read-ProjectFilePrefix $file.FullName ([Math]::Max($ProjectScanMaxFileChars, 4000))
        $scoreItem = Get-ProjectFileScore $file $resolvedRoot $content
        if ($scoreItem.score -gt 0) { $scored.Add($scoreItem) | Out-Null }
    }

    $selected = @($scored | Sort-Object @{ Expression = "score"; Descending = $true }, @{ Expression = "sizeBytes"; Descending = $true } | Select-Object -First $ProjectScanMaxFiles)
    $stack = @(Get-DetectedProjectStack $files)

    $contextParts = New-Object System.Collections.Generic.List[string]
    $contextParts.Add("Project root: $resolvedRoot") | Out-Null
    $contextParts.Add("Detected stack: $($stack -join ', ')") | Out-Null
    $contextParts.Add("Scanned text files: $($files.Count); selected key files: $($selected.Count)") | Out-Null
    $contextParts.Add("") | Out-Null
    $contextParts.Add("Top key files:") | Out-Null

    foreach ($item in @($selected | Select-Object -First 25)) {
        $reasonText = if ($item.reasons.Count -gt 0) { $item.reasons -join ", " } else { "signal score" }
        $contextParts.Add("- [$($item.score)] $($item.path) :: $reasonText") | Out-Null
    }

    $contextParts.Add("") | Out-Null
    $contextParts.Add("Selected excerpts:") | Out-Null
    $usedChars = ($contextParts -join "`n").Length
    foreach ($item in $selected) {
        $excerpt = Get-TextPrefix ([string]$item.excerpt) $ProjectScanMaxFileChars
        if ([string]::IsNullOrWhiteSpace($excerpt)) { continue }
        $block = @"

### $($item.path)
score=$($item.score); reasons=$($item.reasons -join ", ")
~~~text
$excerpt
~~~
"@
        if (($usedChars + $block.Length) -gt $ProjectScanMaxTotalChars) { break }
        $contextParts.Add($block) | Out-Null
        $usedChars += $block.Length
    }

    $promptContext = Get-TextPrefix (($contextParts -join "`n") + "`n") $ProjectScanMaxTotalChars

    $questionCandidates = @(Select-ProjectQuestionCandidates $selected 5 20)

    $seedQuestion = "아래 프로젝트 스캔 결과의 핵심 파일과 코드 조각을 바탕으로, 이번 실행에서 실제 업무 흐름에 영향을 주는 로직 하나를 새롭게 골라 구조, 동작 방식, 실패 가능성, 다음에 확인해야 할 파일을 구체적으로 분석해줘."
    if ($selected.Count -gt 0) {
        $candidateNames = (($questionCandidates | ForEach-Object { $_.path }) -join ", ")
        $seedQuestion = "프로젝트 핵심 후보 파일($candidateNames)을 바탕으로, 이번 실행에서는 후보 중 하나를 새롭게 골라 실제 업무 흐름에 영향을 주는 로직 하나의 구조, 동작 방식, 실패 가능성, 다음에 확인해야 할 파일을 구체적으로 분석해줘."
    }

    return [PSCustomObject]@{
        root = $resolvedRoot
        generatedAt = (Get-Date).ToString("o")
        scannedFileCount = $files.Count
        selectedFileCount = $selected.Count
        detectedStack = $stack
        selectedFiles = @($selected | ForEach-Object {
            [ordered]@{
                path = $_.path
                extension = $_.extension
                sizeBytes = $_.sizeBytes
                score = $_.score
                reasons = $_.reasons
                excerptChars = ([string]$_.excerpt).Length
            }
        })
        questionCandidateFiles = @($questionCandidates | ForEach-Object { $_.path })
        promptContext = $promptContext
        seedQuestion = $seedQuestion
    }
}

function Write-ProjectScanFiles($Scan, [string]$WorkDirPath) {
    if ($null -eq $Scan) { return }

    $mdPath = Join-Path $WorkDirPath "project_scan_summary.md"
    $jsonPath = Join-Path $WorkDirPath "project_scan_summary.json"

    $fileRows = @()
    foreach ($file in @($Scan.selectedFiles | Select-Object -First 40)) {
        $reasonText = if ($file.reasons) { ($file.reasons -join ", ") } else { "" }
        $fileRows += "| $($file.score) | $($file.path) | $reasonText | $(Format-ByteSize ([int64]$file.sizeBytes)) |"
    }
    if ($fileRows.Count -eq 0) { $fileRows = @("|  | no key files selected |  |  |") }

    $questionCandidateRows = @($Scan.questionCandidateFiles | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { "- $_" })
    if ($questionCandidateRows.Count -eq 0) { $questionCandidateRows = @("- no question candidates selected") }

    $md = @"
# Project Scan Summary

- Root: $($Scan.root)
- Generated: $($Scan.generatedAt)
- Detected stack: $($Scan.detectedStack -join ", ")
- Scanned files: $($Scan.scannedFileCount)
- Selected key files: $($Scan.selectedFileCount)

## Key File Candidates

| Score | Path | Reasons | Size |
|---:|---|---|---:|
$($fileRows -join "`n")

## Initial Project Question

$($Scan.seedQuestion)

## Question Candidate Sample

$($questionCandidateRows -join "`n")

## Prompt Context Preview

~~~text
$(Get-TextPrefix $Scan.promptContext 12000)
~~~
"@

    Write-Utf8File $mdPath $md
    Write-Utf8File $jsonPath ($Scan | ConvertTo-Json -Depth 50)
}

function Extract-NextQuestion([string]$content) {
    $lines = $content -split "`r?`n" | ForEach-Object { Remove-BomAndTrim $_ } | Where-Object { $_ -ne "" }
    foreach ($line in $lines) {
        if ($line -match '^NEXT_QUESTION\s*[:：]\s*(.+)$') { return $Matches[1].Trim() }
    }
    if ($lines.Count -gt 0) {
        $candidate = $lines[0] -replace '^[-#\d\.\s]+', ''
        $candidate = $candidate -replace '^다음\s*질문\s*[:：]\s*', ''
        if ($candidate.Length -gt 300) { $candidate = $candidate.Substring(0, 300) }
        return $candidate.Trim()
    }
    return "직전 답변에서 아직 검증되지 않은 핵심 가정 하나를 골라, 같은 기술 트랙 안에서 더 좁고 깊게 분석할 후속 질문을 만들어줘."
}

function Get-AnswerPreview([string]$content, [int]$maxLines, [int]$maxChars) {
    if ($NoAnswerPreview) { return "" }
    if ($maxLines -le 0 -or $maxChars -le 0) { return "" }
    if ([string]::IsNullOrWhiteSpace($content)) { return "" }

    $previewLines = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($content -split "`r?`n")) {
        $trimmed = Remove-BomAndTrim $line
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        if ($trimmed -match '^NEXT_QUESTION\s*[:：]\s*') { continue }

        $previewLines.Add($trimmed)
        if ($previewLines.Count -ge $maxLines) { break }
    }

    if ($previewLines.Count -eq 0) { return "" }

    $preview = ($previewLines -join "`n")
    if ($preview.Length -gt $maxChars) {
        $preview = $preview.Substring(0, $maxChars).TrimEnd() + "`n...[answer preview truncated]..."
    }
    return $preview
}

function Read-QuestionSeeds([string]$seedFile, [string]$questionBankFile, [string]$trackFilter) {
    $items = @()

    if (Test-Path -LiteralPath $questionBankFile -PathType Leaf) {
        foreach ($line in (Get-Content -LiteralPath $questionBankFile -Encoding UTF8)) {
            $trimmed = Remove-BomAndTrim $line
            if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) { continue }

            $track = "general"
            $text = $trimmed
            if ($trimmed -match '^\[([^\]]+)\]\s*(.+)$') {
                $track = $Matches[1].Trim()
                $text = $Matches[2].Trim()
            }

            if (-not [string]::IsNullOrWhiteSpace($trackFilter) -and $track -ne $trackFilter) { continue }
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $items += [PSCustomObject]@{ Track = $track; Text = $text; Source = $questionBankFile }
            }
        }
    }

    if ($items.Count -eq 0 -and (Test-Path -LiteralPath $seedFile -PathType Leaf)) {
        $seed = (Read-Utf8File $seedFile).Trim()
        if (-not [string]::IsNullOrWhiteSpace($seed)) {
            $items += [PSCustomObject]@{ Track = "seed"; Text = $seed; Source = $seedFile }
        }
    }

    return $items
}

function Select-BootstrapQuestion([string]$seedFile, [string]$questionBankFile, [string]$trackFilter) {
    $items = @(Read-QuestionSeeds $seedFile $questionBankFile $trackFilter)
    if ($items.Count -eq 0) {
        throw "질문 seed를 찾지 못했습니다. seed_prompt.txt 또는 question_bank.txt를 확인하세요."
    }

    $selected = $items | Get-Random
    return [PSCustomObject]@{
        Question = [string]$selected.Text
        Source = "question-seed:$($selected.Track)"
        SeedSource = [string]$selected.Source
    }
}

function Get-LastJsonlNextQuestion([string]$path) {
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { return "" }

    $lines = @(Get-Content -LiteralPath $path -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        try {
            $record = $lines[$i] | ConvertFrom-Json
            $candidate = [string](Get-JsonProperty $record "nextQuestion")
            if (-not [string]::IsNullOrWhiteSpace($candidate)) { return $candidate.Trim() }
        } catch { }
    }
    return ""
}

function Get-LastTranscriptNextQuestion([string]$path) {
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { return "" }

    $raw = Read-Utf8File $path
    $matches = [regex]::Matches($raw, '(?ms)^## Next Question\s*\r?\n\s*(.+?)\s*(?=^## |\z)')
    if ($matches.Count -eq 0) { return "" }

    $candidate = $matches[$matches.Count - 1].Groups[1].Value.Trim()
    if ($candidate.Length -gt 500) { $candidate = $candidate.Substring(0, 500).Trim() }
    return $candidate
}

function Get-RecoveryQuestionFromLastTurn([string]$path) {
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { return "" }
    $lastTurn = (Read-Utf8File $path).Trim()
    if ([string]::IsNullOrWhiteSpace($lastTurn)) { return "" }

    return "아래 직전 루프 요약을 바탕으로, 이미 다룬 내용을 반복하지 말고 같은 기술 트랙 안에서 아직 검증되지 않은 핵심 가정 하나를 더 좁고 깊게 분석해줘.`n`n$lastTurn"
}

function Test-SameQuestionText([string]$Left, [string]$Right) {
    $l = ([string]$Left).Trim() -replace '\s+', ' '
    $r = ([string]$Right).Trim() -replace '\s+', ' '
    if ([string]::IsNullOrWhiteSpace($l) -or [string]::IsNullOrWhiteSpace($r)) { return $false }
    return $l.Equals($r, [System.StringComparison]::Ordinal)
}

function New-InterruptedProjectSeedQuestion($ProjectScan, [string]$PreviousQuestion) {
    $selectedFile = $null
    if ($ProjectScan -and $ProjectScan.selectedFiles) {
        $selectedFile = @(Select-ProjectQuestionCandidates $ProjectScan.selectedFiles 1 20)[0]
    }

    if ($selectedFile -and -not [string]::IsNullOrWhiteSpace([string]$selectedFile.path)) {
        return "이전 실행에서 프로젝트 전체 핵심 후보를 고르는 초기 질문이 이미 전송됐지만 완료 기록이 없습니다. 같은 질문을 반복하지 말고, 이번에 선택된 핵심 후보 파일($($selectedFile.path))을 기준으로 실제 업무 흐름 하나를 좁혀서 구조, 호출 흐름, 실패 가능성, 다음에 확인해야 할 연결 파일을 구체적으로 분석해줘."
    }

    return "이전 실행에서 프로젝트 스캔 기반 초기 질문이 이미 전송됐지만 완료 기록이 없습니다. 같은 질문을 반복하지 말고, 이번 스캔 결과의 핵심 후보 중 하나를 새롭게 골라 실제 업무 흐름 하나를 좁혀서 구조, 실패 가능성, 다음 확인 파일을 구체적으로 분석해줘."
}

function Initialize-NextQuestion([string]$nextPath, [string]$jsonlPath, [string]$transcriptPath, [string]$lastTurnPath, [string]$seedFile, [string]$questionBankFile, [string]$trackFilter) {
    if (Test-Path -LiteralPath $nextPath -PathType Leaf) {
        $existing = (Read-Utf8File $nextPath).Trim()
        if (-not [string]::IsNullOrWhiteSpace($existing)) {
            return [PSCustomObject]@{ Question = $existing; Source = "next_question.txt"; SeedSource = $nextPath }
        }
    }

    $candidate = Get-LastJsonlNextQuestion $jsonlPath
    if (-not [string]::IsNullOrWhiteSpace($candidate)) {
        Write-Utf8File $nextPath $candidate
        return [PSCustomObject]@{ Question = $candidate; Source = "transcript.jsonl"; SeedSource = $jsonlPath }
    }

    $candidate = Get-LastTranscriptNextQuestion $transcriptPath
    if (-not [string]::IsNullOrWhiteSpace($candidate)) {
        Write-Utf8File $nextPath $candidate
        return [PSCustomObject]@{ Question = $candidate; Source = "transcript.md"; SeedSource = $transcriptPath }
    }

    $candidate = Get-RecoveryQuestionFromLastTurn $lastTurnPath
    if (-not [string]::IsNullOrWhiteSpace($candidate)) {
        Write-Utf8File $nextPath $candidate
        return [PSCustomObject]@{ Question = $candidate; Source = "last_turn.txt"; SeedSource = $lastTurnPath }
    }

    $bootstrap = Select-BootstrapQuestion $seedFile $questionBankFile $trackFilter
    Write-Utf8File $nextPath $bootstrap.Question
    return $bootstrap
}

function Get-RecentQuestionHistory([string]$jsonlPath, [int]$maxItems) {
    if (!(Test-Path -LiteralPath $jsonlPath -PathType Leaf)) { return "" }

    $seen = @{}
    $items = New-Object System.Collections.Generic.List[string]
    $lines = @(Get-Content -LiteralPath $jsonlPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    for ($i = $lines.Count - 1; $i -ge 0 -and $items.Count -lt $maxItems; $i--) {
        try {
            $record = $lines[$i] | ConvertFrom-Json
            foreach ($name in @("nextQuestion", "question")) {
                $candidate = [string](Get-JsonProperty $record $name)
                if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
                $key = $candidate.Trim().ToLowerInvariant()
                if (-not $seen.ContainsKey($key)) {
                    $seen[$key] = $true
                    $items.Add($candidate.Trim())
                    if ($items.Count -ge $maxItems) { break }
                }
            }
        } catch { }
    }

    if ($items.Count -eq 0) { return "" }
    return (($items | ForEach-Object { "- $_" }) -join "`n")
}

function Get-LoopDataHistoryRoot([string]$workDirPath) {
    $scriptLoopData = Join-Path $PSScriptRoot "qwen-loop-data"
    if (Test-Path -LiteralPath $scriptLoopData -PathType Container) {
        return (Resolve-Path -LiteralPath $scriptLoopData | Select-Object -First 1).Path
    }
    if (Test-Path -LiteralPath $workDirPath -PathType Container) {
        return (Resolve-Path -LiteralPath $workDirPath | Select-Object -First 1).Path
    }
    return ""
}

function Get-RecentQuestionHistoryFromTree([string]$rootDir, [string]$excludeJsonlPath, [int]$maxItems) {
    if ([string]::IsNullOrWhiteSpace($rootDir) -or !(Test-Path -LiteralPath $rootDir -PathType Container)) { return "" }

    $excludeFull = ""
    try {
        if (Test-Path -LiteralPath $excludeJsonlPath -PathType Leaf) {
            $excludeFull = (Resolve-Path -LiteralPath $excludeJsonlPath | Select-Object -First 1).Path
        }
    } catch { }

    $seen = @{}
    $items = New-Object System.Collections.Generic.List[string]
    $files = @(Get-ChildItem -LiteralPath $rootDir -Recurse -File -Filter "transcript.jsonl" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 40)

    foreach ($file in $files) {
        if ($items.Count -ge $maxItems) { break }
        if (-not [string]::IsNullOrWhiteSpace($excludeFull) -and $file.FullName.Equals($excludeFull, [System.StringComparison]::OrdinalIgnoreCase)) { continue }

        try {
            $lines = @(Get-Content -LiteralPath $file.FullName -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            for ($i = $lines.Count - 1; $i -ge 0 -and $items.Count -lt $maxItems; $i--) {
                try {
                    $record = $lines[$i] | ConvertFrom-Json
                    foreach ($name in @("nextQuestion", "question")) {
                        $candidate = [string](Get-JsonProperty $record $name)
                        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
                        $key = $candidate.Trim().ToLowerInvariant()
                        if (-not $seen.ContainsKey($key)) {
                            $seen[$key] = $true
                            $items.Add($candidate.Trim())
                            if ($items.Count -ge $maxItems) { break }
                        }
                    }
                } catch { }
            }
        } catch { }
    }

    if ($items.Count -eq 0) { return "" }
    return (($items | ForEach-Object { "- $_" }) -join "`n")
}

function Convert-MessageContentToText($content) {
    if ($null -eq $content) { return "" }
    if ($content -is [string]) { return [string]$content }

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($content)) {
        if ($null -eq $item) { continue }
        if ($item -is [string]) { $parts.Add([string]$item) }
        elseif ($item.text) { $parts.Add([string]$item.text) }
        elseif ($item.content) { $parts.Add([string]$item.content) }
    }
    return ($parts -join "`n")
}

function Repair-MojibakeIfLikely([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return $text }
    $hangul = ([regex]::Matches($text, '[가-힣]')).Count
    $markers = ([regex]::Matches($text, '[ÃÂÀÁÂÄÅÆÇÈÉÊËÌÍÎÏÐÑÒÓÔÕÖØÙÚÛÜÝÞßàáâãäåæçèéêëìíîïðñòóôõöøùúûüýþÿ�]')).Count
    if ($hangul -lt 3 -and $markers -gt 10) {
        try {
            $cp1252 = [System.Text.Encoding]::GetEncoding(1252)
            $fixed = [System.Text.Encoding]::UTF8.GetString($cp1252.GetBytes($text))
            if (([regex]::Matches($fixed, '[가-힣]')).Count -gt $hangul) { return $fixed }
        } catch { }
    }
    return $text
}

function Get-UriHostPort([string]$BaseUrl) {
    $uri = [System.Uri]$BaseUrl
    $port = $uri.Port
    if ($port -le 0) {
        if ($uri.Scheme -eq "https") { $port = 443 } else { $port = 80 }
    }
    return [PSCustomObject]@{ Host = $uri.Host; Port = $port; Scheme = $uri.Scheme }
}

function Get-ClientNetworkIdentity([string]$BaseUrl) {
    $hp = Get-UriHostPort $BaseUrl
    $result = [ordered]@{
        computerName = $env:COMPUTERNAME
        userName = $env:USERNAME
        userDomain = $env:USERDOMAIN
        targetHost = $hp.Host
        targetPort = $hp.Port
        localAddress = $null
        localPort = $null
        note = "localAddress/localPort are obtained from the TCP socket used to reach the target. The server still sees the real TCP remote address independently of these headers."
    }
    $tcp = $null
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect($hp.Host, [int]$hp.Port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(3000, $false)) {
            $tcp.EndConnect($iar)
            $lep = $tcp.Client.LocalEndPoint
            if ($lep) {
                $result.localAddress = $lep.Address.ToString()
                $result.localPort = $lep.Port
            }
        } else {
            $result.note = "TCP source address check timed out. HTTP request will still use the OS-selected source address."
        }
    } catch {
        $result.note = "TCP source address check failed: $($_.Exception.Message)"
    } finally {
        if ($tcp) { $tcp.Close() }
    }
    return [PSCustomObject]$result
}

function Build-ClientHeaders($providerInfo, $settings, $networkIdentity, [int]$RetryCount = 0) {
    $headers = [ordered]@{}

    Set-HeaderLikeSdk $headers "Accept" "application/json"
    Set-HeaderLikeSdk $headers "User-Agent" "OpenAI/JS $OpenAISdkVersion"
    Set-HeaderLikeSdk $headers "X-Stainless-Retry-Count" ([string]$RetryCount)
    Set-HeaderLikeSdk $headers "X-Stainless-Timeout" ([string]$EffectiveTimeoutSec)
    Set-HeaderLikeSdk $headers "X-Stainless-Lang" "js"
    Set-HeaderLikeSdk $headers "X-Stainless-Package-Version" $OpenAISdkVersion
    Set-HeaderLikeSdk $headers "X-Stainless-OS" (Get-StainlessOsName)
    Set-HeaderLikeSdk $headers "X-Stainless-Arch" (Get-StainlessArchName)
    Set-HeaderLikeSdk $headers "X-Stainless-Runtime" "node"
    Set-HeaderLikeSdk $headers "X-Stainless-Runtime-Version" (Get-NodeLikeRuntimeVersion)

    if ($null -ne $providerInfo.ApiKey) {
        Set-HeaderLikeSdk $headers "Authorization" "Bearer $($providerInfo.ApiKey)"
    }

    Set-HeaderLikeSdk $headers "User-Agent" (Get-PlatformUserAgent)

    $generationConfig = Get-GenerationConfig $providerInfo
    $customHeaders = Get-JsonProperty $generationConfig "customHeaders"
    if ($customHeaders) {
        foreach ($p in (Get-ObjectProperties $customHeaders)) {
            Set-HeaderLikeSdk $headers ([string]$p.Name) $p.Value
        }
    }

    Set-HeaderLikeSdk $headers "Content-Type" "application/json"

    # Qwen Code CLI does not send these project diagnostics. They are opt-in only.
    if ($LoopDiagnosticHeaders) {
        Set-HeaderLikeSdk $headers "X-Qwen-Loop-Client" "qwen-loop-scheduler-v4-settings-first"
        Set-HeaderLikeSdk $headers "X-Qwen-Loop-Provider-Type" ([string]$providerInfo.Type)
        Set-HeaderLikeSdk $headers "X-Qwen-Loop-Provider-Name" ([string]$providerInfo.ProviderName)
        Set-HeaderLikeSdk $headers "X-Qwen-Loop-Provider-Id" ([string]$providerInfo.ProviderId)
        Set-HeaderLikeSdk $headers "X-Qwen-Loop-Model" ([string]$providerInfo.ModelId)
        Set-HeaderLikeSdk $headers "X-Qwen-Loop-EnvKey" ([string]$providerInfo.EnvKey)
        Set-HeaderLikeSdk $headers "X-Qwen-Loop-ApiKey-Source" ([string]$providerInfo.ApiKeySource)
        Set-HeaderLikeSdk $headers "X-Qwen-Loop-Settings-Version" ([string](Get-JsonProperty $settings '$version'))

        if (-not $NoClientIdentityHeaders) {
            if ($networkIdentity.computerName) { Set-HeaderLikeSdk $headers "X-Qwen-Loop-Computer-Name" ([string]$networkIdentity.computerName) }
            if ($networkIdentity.userName) { Set-HeaderLikeSdk $headers "X-Qwen-Loop-User-Name" ([string]$networkIdentity.userName) }
            if ($networkIdentity.userDomain) { Set-HeaderLikeSdk $headers "X-Qwen-Loop-User-Domain" ([string]$networkIdentity.userDomain) }
            if ($networkIdentity.localAddress) { Set-HeaderLikeSdk $headers "X-Qwen-Loop-Client-IP" ([string]$networkIdentity.localAddress) }
            if ($networkIdentity.localPort) { Set-HeaderLikeSdk $headers "X-Qwen-Loop-Client-Port" ([string]$networkIdentity.localPort) }
        }
    }
    return $headers
}

function Get-LoggedHeaders($headers) {
    $debugHeaders = [ordered]@{}
    $shouldMask = [bool]$MaskSensitiveLogs -and -not [bool]$LogSensitive
    foreach ($k in $headers.Keys) {
        if ($shouldMask -and (Is-SensitiveHeaderName $k)) {
            $debugHeaders[$k] = Mask-HeaderValue $k ([string]$headers[$k])
        } else {
            $debugHeaders[$k] = $headers[$k]
        }
    }
    return $debugHeaders
}

function Convert-SettingHintForPrompt([string]$text) {
    if ($null -eq $text) { return "" }

    $result = [string]$text
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $result = [regex]::Replace($result, [regex]::Escape($env:USERPROFILE), "%USERPROFILE%", "IgnoreCase")
    }

    # Project mirror settings may contain the original user's home path. Present it
    # portably in prompts without changing the actual settings source.
    $result = [regex]::Replace($result, '(?i)C:\\Users\\[^\\]+\\\.qwen', '%USERPROFILE%\.qwen')
    return $result
}

function Build-SettingsAwareSystemPrompt($settings, $providerInfo) {
    $general = Get-JsonProperty $settings "general"
    $outputLanguage = [string](Get-JsonProperty $general "outputLanguage")
    if ([string]::IsNullOrWhiteSpace($outputLanguage)) { $outputLanguage = "한국어" }

    $permissions = Get-JsonProperty $settings "permissions"
    $allow = Get-JsonProperty $permissions "allow"
    $allowText = ""
    if ($allow) { $allowText = (($allow | ForEach-Object { "- $(Convert-SettingHintForPrompt ([string]$_))" }) -join "`n") }

    $generationConfig = Get-JsonProperty $providerInfo.ProviderRaw "generationConfig"
    $generationConfigJson = "{}"
    if ($generationConfig) { $generationConfigJson = ($generationConfig | ConvertTo-Json -Depth 30) }

@"
너는 Java Spring Boot, MyBatis/JPA, React, TypeScript, 운영 배포 환경을 함께 보는 시니어 개발 아키텍트다.

아래 정보는 Qwen settings에서 읽은 클라이언트 설정이다. 이 설정을 무시하지 말고 응답 방식과 작업 범위 판단에 반영한다.

- provider type: $($providerInfo.Type)
- provider name: $($providerInfo.ProviderName)
- provider id: $($providerInfo.ProviderId)
- model id: $($providerInfo.ModelId)
- baseUrl: $($providerInfo.BaseUrl)
- outputLanguage: $outputLanguage
- provider.generationConfig:
$generationConfigJson

Qwen settings permissions.allow 참고값(프롬프트용 경로 표기는 동적 환경 기준으로 정규화):
$allowText

매 응답은 반드시 아래 규칙을 지킨다.

1. 첫 번째 줄은 반드시 다음 형식 한 줄로만 작성한다.
NEXT_QUESTION: 여기에 다음 루프에서 물어볼 구체적인 후속 질문을 한 문장으로 작성

2. NEXT_QUESTION은 이전 답변이 없어도 이해될 정도로 구체적이고 자기완결적인 질문이어야 한다.
3. 두 번째 줄부터는 현재 질문에 대한 답변을 settings.general.outputLanguage($outputLanguage)에 맞춰 자세히 작성한다.
4. 답변은 실무 개발자가 바로 사용할 수 있게 구체적으로 작성한다.
5. Java/Spring, React/TypeScript, DB, 운영, 보안, 테스트 중 현재 질문의 주 트랙을 먼저 판별하고, 명시적 이유가 없으면 다음 질문도 같은 트랙 안에서 이어간다.
6. Java/Spring 질문과 React 질문을 한 질문 안에 억지로 묶지 않는다. 단, API contract, 장애 전파, 인증 경계처럼 경계 자체가 주제일 때만 양쪽을 함께 다룬다.
7. NEXT_QUESTION은 최근 질문과 중복되지 않아야 하며, 단순한 "분석 순서"가 아니라 하나의 검증 가능한 기술 가정, 설계 trade-off, 실패 모드, 성능/동시성/보안/테스트 쟁점으로 좁힌다.
8. 코드베이스 내용이 제공되지 않은 경우에는 추측을 확정처럼 말하지 말고, 확인해야 할 파일과 명령을 제시한다.
9. 다음 질문은 현재 답변에서 가장 중요한 미해결 지점이나 더 깊게 파고들 가치가 있는 지점으로 만든다.
10. 너무 짧게 답하지 말고, 가능한 한 깊이 있는 분석, 체크리스트, 예시, 반례, 검증 방법을 포함한다.
"@
}

function Build-RequestBody($settings, $providerInfo, [string]$systemPrompt, [string]$userPrompt, $networkIdentity) {
    $bodyObj = [ordered]@{
        model = $providerInfo.ModelId
        messages = @(
            @{ role = "system"; content = $systemPrompt },
            @{ role = "user"; content = $userPrompt }
        )
        stream = (-not [bool]$NonStreaming)
    }

    if (-not $NonStreaming) {
        $bodyObj["stream_options"] = @{ include_usage = $true }
    }

    $generationConfig = Get-GenerationConfig $providerInfo
    $samplingParams = Get-JsonProperty $generationConfig "samplingParams"

    if ($samplingParams -and -not $CompatBody) {
        # Qwen Code treats samplingParams as the source of truth for the OpenAI wire shape.
        foreach ($p in (Get-ObjectProperties $samplingParams)) {
            if ($null -ne $p.Value) { $bodyObj[[string]$p.Name] = ConvertTo-PlainObject $p.Value }
        }
    } elseif ($UseSchedulerSamplingDefaults) {
        $bodyObj["temperature"] = $Temperature
        $bodyObj["max_tokens"] = $MaxTokens
    } else {
        $bodyObj["max_tokens"] = Get-QwenCodeOutputTokenLimit $providerInfo.ModelId
    }

    if (-not $CompatBody) {
        $extraBody = Get-JsonProperty $generationConfig "extra_body"
        if ($extraBody) {
            # Qwen Code merges extra_body last, so provider-specific fields can override defaults.
            foreach ($p in (Get-ObjectProperties $extraBody)) {
                if ($null -ne $p.Value) { $bodyObj[[string]$p.Name] = ConvertTo-PlainObject $p.Value }
            }
        }
    }
    return $bodyObj
}

function Get-HttpStatusFromErrorMessage([string]$message) {
    if ([string]::IsNullOrWhiteSpace($message)) { return $null }
    if ($message -match '^HTTP\s+(\d+)\s+') { return [int]$Matches[1] }
    return $null
}

function Test-RetryableError([string]$message) {
    $statusCode = Get-HttpStatusFromErrorMessage $message
    if ($null -eq $statusCode) {
        # Transport errors, connection resets, DNS failures, and request timeouts do not
        # always have an HTTP status. Treat them as retryable.
        return $true
    }

    if ($statusCode -eq 408 -or $statusCode -eq 409 -or $statusCode -eq 429) { return $true }
    if ($statusCode -ge 500 -and $statusCode -le 599) { return $true }
    return $false
}

function Assert-RetryConfig() {
    if ($MaxRetries -lt 0) { throw "MaxRetries는 0 이상이어야 합니다." }
    if ($RetryInitialDelaySeconds -le 0) { throw "RetryInitialDelaySeconds는 1 이상이어야 합니다." }
    if ($RetryMaxDelaySeconds -le 0) { throw "RetryMaxDelaySeconds는 1 이상이어야 합니다." }
    if ($RetryMaxDelaySeconds -lt $RetryInitialDelaySeconds) {
        throw "RetryMaxDelaySeconds는 RetryInitialDelaySeconds보다 크거나 같아야 합니다."
    }
}

function Get-RetryDelayMilliseconds([int]$retryNumber) {
    Assert-RetryConfig

    $power = [Math]::Pow(2, [Math]::Max(0, $retryNumber - 1))
    $delaySeconds = [Math]::Min($RetryMaxDelaySeconds, $RetryInitialDelaySeconds * $power)
    $jitterMs = Get-Random -Minimum 0 -Maximum 1000
    return [int]([Math]::Round($delaySeconds * 1000) + $jitterMs)
}

function Format-Milliseconds([int]$milliseconds) {
    if ($milliseconds -lt 1000) { return "$milliseconds ms" }
    return ("{0:N1} sec" -f ($milliseconds / 1000.0))
}

function Assert-TokenUsageConfig() {
    if ($TokenLowThreshold -lt 0) { throw "TokenLowThreshold는 0 이상이어야 합니다." }
    if ($TokenRichThreshold -le $TokenLowThreshold) {
        throw "TokenRichThreshold는 TokenLowThreshold보다 커야 합니다."
    }
}

function Get-UsageNumber($usage, [string[]]$names) {
    if ($null -eq $usage) { return $null }
    foreach ($name in $names) {
        $value = Get-JsonProperty $usage $name
        if ($null -eq $value) { continue }
        try { return [int64]$value } catch { }
    }
    return $null
}

function Convert-OpenAIUsageObject($usage) {
    if ($null -eq $usage) { return $null }

    $inputTokens = Get-UsageNumber $usage @("prompt_tokens", "input_tokens")
    $outputTokens = Get-UsageNumber $usage @("completion_tokens", "output_tokens")
    $totalTokens = Get-UsageNumber $usage @("total_tokens")
    if ($null -eq $totalTokens -and $null -ne $inputTokens -and $null -ne $outputTokens) {
        $totalTokens = $inputTokens + $outputTokens
    }

    return [PSCustomObject]@{
        inputTokens = $inputTokens
        outputTokens = $outputTokens
        totalTokens = $totalTokens
        raw = ConvertTo-PlainObject $usage
    }
}

function Get-OpenAIUsageFromRaw([string]$raw, [bool]$isStreaming) {
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }

    if ($isStreaming) {
        $lastUsage = $null
        foreach ($line in ($raw -split "`r?`n")) {
            $trimmed = $line.Trim()
            if (-not $trimmed.StartsWith("data:")) { continue }

            $data = $trimmed.Substring(5).Trim()
            if ([string]::IsNullOrWhiteSpace($data) -or $data -eq "[DONE]") { continue }

            try {
                $chunk = $data | ConvertFrom-Json
                $usage = Get-JsonProperty $chunk "usage"
                if ($usage) { $lastUsage = $usage }
            } catch { }
        }
        return Convert-OpenAIUsageObject $lastUsage
    }

    try {
        $resp = $raw | ConvertFrom-Json
        return Convert-OpenAIUsageObject (Get-JsonProperty $resp "usage")
    } catch {
        return $null
    }
}

function Format-TokenNumber($value) {
    if ($null -eq $value) { return "n/a" }
    return ("{0:N0}" -f [int64]$value)
}

function Get-TokenUsageProfile($usage) {
    Assert-TokenUsageConfig

    if ($null -eq $usage) {
        return [PSCustomObject]@{
            available = $false
            level = "unknown"
            color = "DarkGray"
            note = "usage not returned by server"
            basis = "none"
        }
    }

    $score = $usage.outputTokens
    $basis = "output"
    if ($null -eq $score) {
        $score = $usage.totalTokens
        $basis = "total"
    }

    if ($null -eq $score) {
        return [PSCustomObject]@{
            available = $false
            level = "unknown"
            color = "DarkGray"
            note = "usage returned without token counts"
            basis = $basis
        }
    }

    if ($score -lt $TokenLowThreshold) {
        return [PSCustomObject]@{
            available = $true
            level = "light"
            color = "Green"
            note = "fast and cheap, but may be shallow"
            basis = $basis
        }
    }

    if ($score -lt $TokenRichThreshold) {
        return [PSCustomObject]@{
            available = $true
            level = "balanced"
            color = "Yellow"
            note = "reasonable depth and cost"
            basis = $basis
        }
    }

    return [PSCustomObject]@{
        available = $true
        level = "rich"
        color = "Magenta"
        note = "deep answer, intentionally higher token use"
        basis = $basis
    }
}

function Write-TokenUsage($usage, $profile) {
    if ($null -eq $profile) { $profile = Get-TokenUsageProfile $usage }

    if ($null -eq $usage) {
        Write-Host "TokenUse     : usage not returned by server" -ForegroundColor DarkGray
        return
    }

    $line = "TokenUse     : input=$(Format-TokenNumber $usage.inputTokens), output=$(Format-TokenNumber $usage.outputTokens), total=$(Format-TokenNumber $usage.totalTokens) | $($profile.level) ($($profile.note))"
    Write-Host $line -ForegroundColor $profile.color
}

function Format-TokenUsageForMarkdown($usage, $profile) {
    if ($null -eq $profile) { $profile = Get-TokenUsageProfile $usage }
    if ($null -eq $usage) { return "usage not returned by server" }

    return "input=$(Format-TokenNumber $usage.inputTokens), output=$(Format-TokenNumber $usage.outputTokens), total=$(Format-TokenNumber $usage.totalTokens), level=$($profile.level), note=$($profile.note)"
}

function Read-ResponseStreamUtf8($Stream, [bool]$StopOnSseDone) {
    if ($null -eq $Stream) { return "" }

    if (-not $StopOnSseDone) {
        $ms = New-Object System.IO.MemoryStream
        $Stream.CopyTo($ms)
        return [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
    }

    $reader = New-Object System.IO.StreamReader($Stream, $Utf8NoBom, $true)
    $sb = New-Object System.Text.StringBuilder
    try {
        while ($true) {
            $line = $reader.ReadLine()
            if ($null -eq $line) { break }

            [void]$sb.Append($line).Append("`r`n")

            $trimmed = $line.Trim()
            if ($trimmed.StartsWith("data:")) {
                $data = $trimmed.Substring(5).Trim()
                if ($data -eq "[DONE]") { break }
            }
        }
    } finally {
        $reader.Dispose()
    }

    return $sb.ToString()
}

function Invoke-JsonPostUtf8([string]$Uri, $Headers, [byte[]]$BodyBytes, [int]$TimeoutSeconds, [bool]$StopOnSseDone = $false) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $req = [System.Net.HttpWebRequest]::Create($Uri)
    $req.Method = "POST"
    $req.Accept = "application/json"
    $req.ContentType = "application/json"
    $req.UserAgent = Get-PlatformUserAgent
    $req.Timeout = $TimeoutSeconds * 1000
    $req.ReadWriteTimeout = $TimeoutSeconds * 1000
    $req.KeepAlive = $true

    foreach ($key in $Headers.Keys) {
        if ($key -ieq "Accept") { $req.Accept = [string]$Headers[$key] }
        elseif ($key -ieq "Content-Type") { $req.ContentType = [string]$Headers[$key] }
        elseif ($key -ieq "User-Agent") { $req.UserAgent = [string]$Headers[$key] }
        else { $req.Headers[$key] = [string]$Headers[$key] }
    }

    $req.ContentLength = $BodyBytes.Length
    $stream = $req.GetRequestStream()
    try { $stream.Write($BodyBytes, 0, $BodyBytes.Length) }
    finally { $stream.Close() }

    try {
        $resp = $req.GetResponse()
        try {
            $respStream = $resp.GetResponseStream()
            $body = Read-ResponseStreamUtf8 $respStream $StopOnSseDone
            $sw.Stop()
            return [PSCustomObject]@{
                Body = $body
                StatusCode = [int]$resp.StatusCode
                StatusDescription = [string]$resp.StatusDescription
                ContentType = [string]$resp.ContentType
                ReceivedBytes = [int64][System.Text.Encoding]::UTF8.GetByteCount($body)
                DurationMs = [int64]$sw.ElapsedMilliseconds
            }
        } finally {
            if ($respStream) { $respStream.Close() }
            if ($resp) { $resp.Close() }
        }
    } catch [System.Net.WebException] {
        $sw.Stop()
        $resp = $_.Exception.Response
        if ($resp) {
            $respStream = $resp.GetResponseStream()
            $ms = New-Object System.IO.MemoryStream
            if ($respStream) { $respStream.CopyTo($ms) }
            $bytes = $ms.ToArray()
            $body = [System.Text.Encoding]::UTF8.GetString($bytes)
            $statusCode = [int]$resp.StatusCode
            $statusDescription = [string]$resp.StatusDescription
            throw "HTTP $statusCode $statusDescription after $($sw.ElapsedMilliseconds) ms: $($_.Exception.Message)`nResponse body:`n$body"
        }
        throw "HTTP 호출 실패 after $($sw.ElapsedMilliseconds) ms: $($_.Exception.Message)"
    } catch {
        $sw.Stop()
        throw
    }
}

function Convert-OpenAIResponseToText([string]$raw, [bool]$isStreaming) {
    if ($isStreaming) {
        $textParts = New-Object System.Collections.Generic.List[string]
        $jsonLines = New-Object System.Collections.Generic.List[string]

        foreach ($line in ($raw -split "`r?`n")) {
            $trimmed = $line.Trim()
            if (-not $trimmed.StartsWith("data:")) { continue }

            $data = $trimmed.Substring(5).Trim()
            if ([string]::IsNullOrWhiteSpace($data) -or $data -eq "[DONE]") { continue }
            $jsonLines.Add($data)

            try {
                $chunk = $data | ConvertFrom-Json
                if ($chunk.choices -and $chunk.choices.Count -gt 0) {
                    foreach ($choice in @($chunk.choices)) {
                        if ($choice.delta) {
                            $deltaText = Convert-MessageContentToText $choice.delta.content
                            if (-not [string]::IsNullOrEmpty($deltaText)) { $textParts.Add($deltaText) }
                        }
                    }
                }
            } catch { }
        }

        $joined = ($textParts -join "")
        if (-not [string]::IsNullOrWhiteSpace($joined)) {
            return (Repair-MojibakeIfLikely $joined)
        }

        if ($jsonLines.Count -gt 0) {
            return (Repair-MojibakeIfLikely ($jsonLines -join "`n"))
        }
        return (Repair-MojibakeIfLikely $raw)
    }

    $resp = $raw | ConvertFrom-Json
    if ($resp.choices -and $resp.choices.Count -gt 0) {
        $choice = $resp.choices[0]
        if ($choice.message) {
            $text = Convert-MessageContentToText $choice.message.content
            $text = Repair-MojibakeIfLikely $text
            if (-not [string]::IsNullOrWhiteSpace($text)) { return $text }
        }
        if ($choice.text) { return (Repair-MojibakeIfLikely ([string]$choice.text)) }
    }
    return (Repair-MojibakeIfLikely ($resp | ConvertTo-Json -Depth 30))
}

function Invoke-QwenChat($providerInfo, $settings, $networkIdentity, [string]$systemPrompt, [string]$userPrompt) {
    $bodyObj = Build-RequestBody $settings $providerInfo $systemPrompt $userPrompt $networkIdentity
    $body = $bodyObj | ConvertTo-Json -Depth 80 -Compress
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)

    Write-Utf8File (Join-Path $WorkDir "last_request_body.json") $body

    Assert-RetryConfig

    $lastError = $null
    foreach ($endpoint in (Get-EndpointCandidates $providerInfo.BaseUrl)) {
        for ($attempt = 0; $attempt -le $MaxRetries; $attempt++) {
            $headers = Build-ClientHeaders $providerInfo $settings $networkIdentity $attempt
            $debugHeaders = Get-LoggedHeaders $headers
            Write-Utf8File (Join-Path $WorkDir "last_request_headers.json") (($debugHeaders | ConvertTo-Json -Depth 30))
            if ($LogSensitive) { Write-Utf8File (Join-Path $WorkDir "last_request_headers_sensitive.json") (($headers | ConvertTo-Json -Depth 30)) }

            try {
                $attemptText = "$($attempt + 1)/$($MaxRetries + 1)"
                Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] POST $endpoint (attempt $attemptText, retry-count=$attempt)" -ForegroundColor Cyan
                $response = Invoke-JsonPostUtf8 -Uri $endpoint -Headers $headers -BodyBytes $bodyBytes -TimeoutSeconds $EffectiveTimeoutSec -StopOnSseDone:(-not [bool]$NonStreaming)
                Write-Host ("[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] HTTP {0} {1} ({2} ms, {3} bytes, retry-count={4})" -f $response.StatusCode, $response.StatusDescription, $response.DurationMs, $response.ReceivedBytes, $attempt) -ForegroundColor Green
                $answerText = Convert-OpenAIResponseToText $response.Body (-not [bool]$NonStreaming)
                $tokenUsage = Get-OpenAIUsageFromRaw $response.Body (-not [bool]$NonStreaming)
                $tokenProfile = Get-TokenUsageProfile $tokenUsage
                Write-Utf8File (Join-Path $WorkDir "last_response_status.json") (([ordered]@{
                    ok = $true
                    endpoint = $endpoint
                    attempt = ($attempt + 1)
                    retryCount = $attempt
                    maxRetries = $MaxRetries
                    statusCode = $response.StatusCode
                    statusDescription = $response.StatusDescription
                    contentType = $response.ContentType
                    receivedBytes = $response.ReceivedBytes
                    durationMs = $response.DurationMs
                    usage = ConvertTo-PlainObject $tokenUsage
                    tokenUse = ConvertTo-PlainObject $tokenProfile
                    completedAt = (Get-Date).ToString("o")
                }) | ConvertTo-Json -Depth 10)
                Write-Host ("ResponseText : {0} chars extracted" -f $answerText.Length) -ForegroundColor DarkGreen
                Write-TokenUsage $tokenUsage $tokenProfile
                return [PSCustomObject]@{
                    Text = $answerText
                    Usage = $tokenUsage
                    TokenUse = $tokenProfile
                    Endpoint = $endpoint
                    Attempt = ($attempt + 1)
                    RetryCount = $attempt
                    StatusCode = $response.StatusCode
                    StatusDescription = $response.StatusDescription
                    ContentType = $response.ContentType
                    ReceivedBytes = $response.ReceivedBytes
                    DurationMs = $response.DurationMs
                    CompletedAt = (Get-Date)
                }
            } catch {
                $lastError = [string]$_.Exception.Message
                $retryable = Test-RetryableError $lastError
                Write-Host "Endpoint failed: $endpoint (attempt $($attempt + 1)/$($MaxRetries + 1), retryable=$retryable)" -ForegroundColor Yellow
                Write-Host $lastError -ForegroundColor Yellow

                $errorStatusCode = $null
                $errorStatusDescription = $null
                $errorDurationMs = $null
                if ($lastError -match '^HTTP\s+(\d+)\s+(.+?)\s+after\s+(\d+)\s+ms') {
                    $errorStatusCode = [int]$Matches[1]
                    $errorStatusDescription = [string]$Matches[2]
                    $errorDurationMs = [int64]$Matches[3]
                }
                Write-Utf8File (Join-Path $WorkDir "last_response_status.json") (([ordered]@{
                    ok = $false
                    endpoint = $endpoint
                    attempt = ($attempt + 1)
                    retryCount = $attempt
                    maxRetries = $MaxRetries
                    retryable = $retryable
                    statusCode = $errorStatusCode
                    statusDescription = $errorStatusDescription
                    durationMs = $errorDurationMs
                    error = $lastError
                    completedAt = (Get-Date).ToString("o")
                }) | ConvertTo-Json -Depth 10)

                if (-not $retryable -or $attempt -ge $MaxRetries) { break }

                $retryNumber = $attempt + 1
                $delayMs = Get-RetryDelayMilliseconds $retryNumber
                Write-Host "Retry $retryNumber/$MaxRetries in $(Format-Milliseconds $delayMs)..." -ForegroundColor DarkYellow
                Start-Sleep -Milliseconds $delayMs
            }
        }
    }
    throw "모든 endpoint 호출 실패. 마지막 오류: $lastError"
}

if (!(Test-Path -LiteralPath $SettingsPath)) { throw "settings.json을 찾지 못했습니다: $SettingsPath" }
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

$settingsRaw = Read-Utf8File $SettingsPath
try {
    $settings = $settingsRaw | ConvertFrom-Json
} catch {
    throw "settings.json JSON 파싱 실패: $SettingsPath`n$($_.Exception.Message)`n힌트: generationConfig에 timeout을 추가했다면 comma 위치를 확인하세요. 예: `"generationConfig`": { `"timeout`": 300000, `"modalities`": { `"image`": true } }"
}
$providerInfo = Get-SettingsProvider $settings $ProviderName $ModelName
$EffectiveTimeoutSec = Get-EffectiveTimeoutSeconds $providerInfo
$intervalPlan = Get-IntervalPlan
Assert-RetryConfig
Assert-TokenUsageConfig
Assert-CleanupConfig
$networkIdentity = $null
if ($LoopDiagnosticHeaders) {
    $networkIdentity = Get-ClientNetworkIdentity $providerInfo.BaseUrl
}

$nextQuestionPath = Join-Path $WorkDir "next_question.txt"
$lastTurnPath = Join-Path $WorkDir "last_turn.txt"
$transcriptPath = Join-Path $WorkDir "transcript.md"
$jsonlPath = Join-Path $WorkDir "transcript.jsonl"
$runHistoryPath = Join-Path $WorkDir "run_history.md"
$runHistoryJsonlPath = Join-Path $WorkDir "run_history.jsonl"
$errorLogPath = Join-Path $WorkDir "error.log"
$pendingQuestionPath = Join-Path $WorkDir "pending_question.txt"

$projectScan = $null
$projectContext = ""
if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $projectScan = New-ProjectScanContext $ProjectRoot
    Write-ProjectScanFiles $projectScan $WorkDir
    $projectContext = $projectScan.promptContext

    $existingProjectQuestion = ""
    $hadExistingProjectQuestionFile = Test-Path -LiteralPath $nextQuestionPath -PathType Leaf
    if ($hadExistingProjectQuestionFile) {
        $existingProjectQuestion = (Read-Utf8File $nextQuestionPath).Trim()
    }

    $hasUsableProjectQuestion = (-not [string]::IsNullOrWhiteSpace($existingProjectQuestion)) -and `
        (-not (Test-SameQuestionText $existingProjectQuestion $projectScan.seedQuestion)) -and `
        (-not (Test-ProjectScanBootstrapQuestion $existingProjectQuestion))

    if ($hasUsableProjectQuestion) {
        $initialQuestion = [PSCustomObject]@{
            Question = $existingProjectQuestion
            Source = "project-next_question.txt"
            SeedSource = $nextQuestionPath
        }
    } else {
        $candidate = Get-LastJsonlNextQuestion $jsonlPath
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and -not (Test-SameQuestionText $candidate $projectScan.seedQuestion) -and -not (Test-ProjectScanBootstrapQuestion $candidate)) {
            Write-Utf8File $nextQuestionPath $candidate
            $initialQuestion = [PSCustomObject]@{ Question = $candidate; Source = "project-transcript.jsonl"; SeedSource = $jsonlPath }
        }
    }

    if ($null -eq $initialQuestion) {
        $candidate = Get-LastTranscriptNextQuestion $transcriptPath
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and -not (Test-SameQuestionText $candidate $projectScan.seedQuestion) -and -not (Test-ProjectScanBootstrapQuestion $candidate)) {
            Write-Utf8File $nextQuestionPath $candidate
            $initialQuestion = [PSCustomObject]@{ Question = $candidate; Source = "project-transcript.md"; SeedSource = $transcriptPath }
        }
    }

    if ($null -eq $initialQuestion) {
        $candidate = Get-RecoveryQuestionFromLastTurn $lastTurnPath
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            Write-Utf8File $nextQuestionPath $candidate
            $initialQuestion = [PSCustomObject]@{ Question = $candidate; Source = "project-last_turn.txt"; SeedSource = $lastTurnPath }
        }
    }

    if ($null -eq $initialQuestion) {
        $pendingQuestion = ""
        if (Test-Path -LiteralPath $pendingQuestionPath -PathType Leaf) {
            $pendingQuestion = (Read-Utf8File $pendingQuestionPath).Trim()
        }
        $hasInterruptedSeed = (-not [string]::IsNullOrWhiteSpace($pendingQuestion) -and ((Test-SameQuestionText $pendingQuestion $projectScan.seedQuestion) -or (Test-ProjectScanBootstrapQuestion $pendingQuestion)))
        $hasStaleSeedFile = ($hadExistingProjectQuestionFile -and ((Test-SameQuestionText $existingProjectQuestion $projectScan.seedQuestion) -or (Test-ProjectScanBootstrapQuestion $existingProjectQuestion)))
        if ($hasInterruptedSeed -or $hasStaleSeedFile) {
            $candidate = New-InterruptedProjectSeedQuestion $projectScan $pendingQuestion
            Write-Utf8File $nextQuestionPath $candidate
            $sourceName = if ($hasInterruptedSeed) { "project-pending_question.txt" } else { "project-stale_scan_seed" }
            $sourcePath = if ($hasInterruptedSeed) { $pendingQuestionPath } else { $nextQuestionPath }
            $initialQuestion = [PSCustomObject]@{ Question = $candidate; Source = $sourceName; SeedSource = $sourcePath }
        }
    }

    if ($null -eq $initialQuestion) {
        Write-Utf8File $nextQuestionPath $projectScan.seedQuestion
        $initialQuestion = [PSCustomObject]@{
            Question = $projectScan.seedQuestion
            Source = "project-scan"
            SeedSource = (Join-Path $WorkDir "project_scan_summary.md")
        }
    }
} else {
    $initialQuestion = Initialize-NextQuestion $nextQuestionPath $jsonlPath $transcriptPath $lastTurnPath $SeedFile $QuestionBankFile $QuestionTrack
}
$seedQuestion = $initialQuestion.Question
$startupCleanup = Invoke-WorkDirCleanup $WorkDir $transcriptPath $jsonlPath $errorLogPath

$systemPrompt = Build-SettingsAwareSystemPrompt $settings $providerInfo

Write-StartupBanner
Write-Host "=== Runtime Summary: SETTINGS-FIRST ===" -ForegroundColor Green
Write-Host "SettingsPath : $SettingsPath"
Write-Host "ProviderType : $($providerInfo.Type)"
Write-Host "ProviderName : $($providerInfo.ProviderName)"
Write-Host "ProviderId   : $($providerInfo.ProviderId)"
Write-Host "BaseUrl      : $($providerInfo.BaseUrl)"
Write-Host "Model        : $($providerInfo.ModelId)"
Write-Host "EnvKey       : $($providerInfo.EnvKey)"
Write-Host "ApiKeySource : $($providerInfo.ApiKeySource)"
if ($null -eq $providerInfo.ApiKey) { Write-Host "Authorization: not sent because envKey value was not found" -ForegroundColor Yellow }
else { Write-Host "Authorization: sent exactly from $($providerInfo.ApiKeySource)" -ForegroundColor Green }
if (Test-QuotedEmptySecret $providerInfo.ApiKey) {
    Write-Host "WARNING      : API key value is literal empty quotes. OS env or .env should override it for real calls." -ForegroundColor Yellow
}
if ($LoopDiagnosticHeaders) {
    Write-Host "ClientHost   : $($networkIdentity.computerName) / $($networkIdentity.userDomain)\$($networkIdentity.userName)"
    Write-Host "ClientIP     : $($networkIdentity.localAddress):$($networkIdentity.localPort)"
} else {
    Write-Host "ClientIdent  : disabled; use -LoopDiagnosticHeaders only when receiver-side tracing needs it"
}
Write-Host "CompatBody   : $CompatBody"
Write-Host "WireMode     : Qwen Code OpenAI SDK-like headers/body"
Write-Host "Stream       : $(-not [bool]$NonStreaming)"
Write-Host "Retry        : max $MaxRetries, backoff $RetryInitialDelaySeconds-$RetryMaxDelaySeconds sec"
Write-Host "TokenUse     : light < $TokenLowThreshold, rich >= $TokenRichThreshold output tokens"
Write-Host "HeaderLog    : $(if ($MaskSensitiveLogs -and -not $LogSensitive) { 'masked' } else { 'unmasked' })"
Write-Host "QuestionSrc  : $($initialQuestion.Source)"
if ($projectScan) {
    Write-Host "ProjectRoot  : $($projectScan.root)"
    Write-Host "ProjectScan  : $($projectScan.scannedFileCount) files scanned, $($projectScan.selectedFileCount) key files selected"
}
$answerPreviewText = if ($NoAnswerPreview) { "disabled" } else { "$AnswerPreviewLines lines / $AnswerPreviewChars chars" }
Write-Host "AnswerPreview: $answerPreviewText"
Write-Host "AutoCleanup  : $(Get-CleanupPolicyText)"
Write-WorkDirCleanupStatus $startupCleanup $true
Write-Host "IntervalMode : $($intervalPlan.Mode)"
if ($intervalPlan.Mode -eq "fixed") {
    Write-Host "Interval     : $(Format-IntervalDuration $intervalPlan.FixedSeconds)"
} else {
    Write-Host "IntervalRange: $(Format-IntervalDuration $intervalPlan.MinSeconds) - $(Format-IntervalDuration $intervalPlan.MaxSeconds)"
}
$countdownText = if ($NoCountdown) { "disabled" } else { "every $CountdownRefreshSeconds sec" }
Write-Host "Countdown    : $countdownText"
Write-Host "TimeoutSec   : $EffectiveTimeoutSec"
Write-Host "WorkDir      : $WorkDir"
Write-Host "Stop         : Ctrl+C"
Write-Host "==============================================" -ForegroundColor Green

$settingsSummary = [ordered]@{
    settingsPath = $SettingsPath
    settingsPathPolicy = "runtime settings file path used by this process; not included in API request body"
    providerType = $providerInfo.Type
    providerName = $providerInfo.ProviderName
    providerId = $providerInfo.ProviderId
    model = $providerInfo.ModelId
    baseUrl = $providerInfo.BaseUrl
    envKey = $providerInfo.EnvKey
    apiKeySource = $providerInfo.ApiKeySource
    authorizationSent = ($null -ne $providerInfo.ApiKey)
    apiKeyLogged = if ($MaskSensitiveLogs -and -not $LogSensitive) { Mask-Secret $providerInfo.ApiKey } else { $providerInfo.ApiKey }
    apiKeyLooksLikeQuotedEmpty = (Test-QuotedEmptySecret $providerInfo.ApiKey)
    clientNetworkIdentity = if ($LoopDiagnosticHeaders) { ConvertTo-PlainObject $networkIdentity } else { $null }
    clientNetworkIdentityPolicy = if ($LoopDiagnosticHeaders) { "collected-and-sent-as-X-Qwen-Loop-diagnostic-headers" } else { "not-collected-or-sent-by-default" }
    compatBody = [bool]$CompatBody
    stream = (-not [bool]$NonStreaming)
    timeoutSec = $EffectiveTimeoutSec
    retry = [ordered]@{
        maxRetries = $MaxRetries
        retryInitialDelaySeconds = $RetryInitialDelaySeconds
        retryMaxDelaySeconds = $RetryMaxDelaySeconds
        retryableStatusCodes = @("408", "409", "429", "5xx")
        note = "Retries transport failures and HTTP 408/409/429/5xx. HTTP 400/401/403/404 are not retried."
    }
    tokenUsage = [ordered]@{
        source = "OpenAI-compatible usage object when returned by the server"
        displayBasis = "output_tokens, fallback total_tokens"
        lowThreshold = $TokenLowThreshold
        richThreshold = $TokenRichThreshold
        light = "green"
        balanced = "yellow"
        rich = "magenta"
    }
    bannerEnabled = (-not [bool]$NoBanner)
    answerPreview = [ordered]@{
        enabled = (-not [bool]$NoAnswerPreview)
        lines = $AnswerPreviewLines
        chars = $AnswerPreviewChars
    }
    autoCleanup = [ordered]@{
        enabled = (-not [bool]$NoAutoCleanup)
        maxWorkDirMB = $MaxWorkDirMB
        maxTranscriptMB = $MaxTranscriptMB
        maxErrorLogMB = $MaxErrorLogMB
        cleanupKeepDays = $CleanupKeepDays
        cleanupKeepTurns = $CleanupKeepTurns
        policy = (Get-CleanupPolicyText)
        startup = ConvertTo-PlainObject $startupCleanup
        note = "Preserves active state files such as next_question.txt and last_turn.txt; compacts large transcripts/error.log and removes stale dry-run/check artifacts."
    }
    interval = [ordered]@{
        mode = $intervalPlan.Mode
        minSeconds = $intervalPlan.MinSeconds
        maxSeconds = $intervalPlan.MaxSeconds
        fixedSeconds = $intervalPlan.FixedSeconds
        minIntervalMinutes = $MinIntervalMinutes
        maxIntervalMinutes = $MaxIntervalMinutes
        legacyIntervalSeconds = $IntervalSeconds
        countdownEnabled = (-not [bool]$NoCountdown)
        countdownRefreshSeconds = $CountdownRefreshSeconds
        note = $intervalPlan.Note
    }
    initialQuestionSource = $initialQuestion.Source
    initialQuestionSeedSource = $initialQuestion.SeedSource
    questionTrack = $QuestionTrack
    projectScan = if ($projectScan) {
        [ordered]@{
            root = $projectScan.root
            generatedAt = $projectScan.generatedAt
            scannedFileCount = $projectScan.scannedFileCount
            selectedFileCount = $projectScan.selectedFileCount
            detectedStack = $projectScan.detectedStack
            maxFiles = $ProjectScanMaxFiles
            maxFileChars = $ProjectScanMaxFileChars
            maxTotalChars = $ProjectScanMaxTotalChars
            summaryMarkdown = (Join-Path $WorkDir "project_scan_summary.md")
            summaryJson = (Join-Path $WorkDir "project_scan_summary.json")
        }
    } else { $null }
    loopDiagnosticHeaders = [bool]$LoopDiagnosticHeaders
    endpointFallbacks = [bool]$EndpointFallbacks
    endpoints = @(Get-EndpointCandidates $providerInfo.BaseUrl)
    qwenCompat = [ordered]@{
        userAgent = (Get-PlatformUserAgent)
        openAISdkVersion = $OpenAISdkVersion
        nodeRuntimeVersion = (Get-NodeLikeRuntimeVersion)
        generationConfig = ConvertTo-PlainObject (Get-GenerationConfig $providerInfo)
        customHeaderKeys = @((Get-ObjectProperties (Get-JsonProperty (Get-GenerationConfig $providerInfo) "customHeaders")) | ForEach-Object { $_.Name })
        samplingParamKeys = @((Get-ObjectProperties (Get-JsonProperty (Get-GenerationConfig $providerInfo) "samplingParams")) | ForEach-Object { $_.Name })
        extraBodyKeys = @((Get-ObjectProperties (Get-JsonProperty (Get-GenerationConfig $providerInfo) "extra_body")) | ForEach-Object { $_.Name })
        maxTokensPolicy = if ($UseSchedulerSamplingDefaults) { "scheduler-argument" } elseif ((Get-JsonProperty (Get-GenerationConfig $providerInfo) "samplingParams")) { "settings.generationConfig.samplingParams" } else { "qwen-code-token-limit" }
        bodyPolicy = if ($CompatBody) { "standard-openai-only" } else { "qwen-code-compatible-streaming-samplingParams-extra_body" }
        note = "Default wire mode follows Qwen Code's OpenAI-compatible provider path more closely: OpenAI SDK stainless headers, QwenCode user-agent, streaming with include_usage, no qwen-loop diagnostic headers, exact baseUrl/chat/completions endpoint, customHeaders to headers, samplingParams and extra_body to request body."
    }
}
Write-Utf8File (Join-Path $WorkDir "settings_effective_summary.json") ($settingsSummary | ConvertTo-Json -Depth 50)

if ($DryRun) {
    $dryRunPromptParts = New-Object System.Collections.Generic.List[string]
    $dryRunPromptParts.Add("현재 루프 질문:`n$seedQuestion") | Out-Null
    if ($projectScan) {
        $dryRunQuestionHistory = Get-RecentQuestionHistoryFromTree (Get-LoopDataHistoryRoot $WorkDir) $jsonlPath 12
        if ([string]::IsNullOrWhiteSpace($dryRunQuestionHistory)) { $dryRunQuestionHistory = "(none)" }
        $dryRunPromptParts.Add("기존 qwen-loop-data 최근 질문(중복 회피용):`n$dryRunQuestionHistory") | Out-Null
        $dryRunPromptParts.Add("프로젝트 스캔 컨텍스트:`n$projectContext") | Out-Null
    }
    $dryRunPromptParts.Add("요청:`nDryRun preview. 이 파일은 API 호출 없이 실제 전송 예정 header/body 형태를 확인하기 위한 샘플입니다.") | Out-Null
    $dryRunPrompt = ($dryRunPromptParts -join "`n`n")
    $dryRunHeaders = Build-ClientHeaders $providerInfo $settings $networkIdentity
    $dryRunBody = Build-RequestBody $settings $providerInfo $systemPrompt $dryRunPrompt $networkIdentity
    Write-Utf8File (Join-Path $WorkDir "dry_run_request_headers.json") ((Get-LoggedHeaders $dryRunHeaders) | ConvertTo-Json -Depth 30)
    Write-Utf8File (Join-Path $WorkDir "dry_run_request_body.json") ($dryRunBody | ConvertTo-Json -Depth 80 -Compress)
    if ($LogSensitive) { Write-Utf8File (Join-Path $WorkDir "dry_run_request_headers_sensitive.json") ($dryRunHeaders | ConvertTo-Json -Depth 30) }

    Write-Host "DryRun mode: API 호출 없이 settings.json 활용 내역만 확인했습니다." -ForegroundColor Yellow
    Write-Host "Created:" -ForegroundColor Yellow
    Write-Host "- $(Join-Path $WorkDir 'settings_effective_summary.json')"
    Write-Host "- $(Join-Path $WorkDir 'dry_run_request_headers.json')"
    Write-Host "- $(Join-Path $WorkDir 'dry_run_request_body.json')"
    Write-Host "Endpoint$(if ($EndpointFallbacks) { ' candidates' } else { '' }):" -ForegroundColor Yellow
    Get-EndpointCandidates $providerInfo.BaseUrl | ForEach-Object { Write-Host "- $_" }
    exit 0
}

$runCount = 0
$nextRunSequence = Get-NextRunHistorySequence $runHistoryJsonlPath
while ($true) {
    $runCount++
    $runSeq = $nextRunSequence
    $nextRunSequence++
    $started = Get-Date
    $requestAt = $null
    $completedAt = $null
    $runStatus = "error"
    $errorText = ""
    $question = ""
    $nextQuestion = ""
    $answer = ""
    $tokenUsage = $null
    $tokenUse = $null
    $chatResult = $null
    try {
        $question = (Read-Utf8File $nextQuestionPath).Trim()
        if ([string]::IsNullOrWhiteSpace($question)) { $question = $seedQuestion }
        Write-Utf8File $pendingQuestionPath $question

        $contextBundle = Read-ContextBundle $ContextListFile $MaxContextChars
        $lastTurn = ""
        if (Test-Path -LiteralPath $lastTurnPath) { $lastTurn = Get-TextPrefix ((Read-Utf8File $lastTurnPath).Trim()) $LastTurnChars }
        $questionHistory = Get-RecentQuestionHistory $jsonlPath 8
        if ($projectScan) {
            $globalQuestionHistory = Get-RecentQuestionHistoryFromTree (Get-LoopDataHistoryRoot $WorkDir) $jsonlPath 12
            if (-not [string]::IsNullOrWhiteSpace($globalQuestionHistory)) {
                if (-not [string]::IsNullOrWhiteSpace($questionHistory)) { $questionHistory += "`n" }
                $questionHistory += "기존 qwen-loop-data 최근 질문(중복 회피용):`n$globalQuestionHistory"
            }
        }
        $projectPromptSection = ""
        if ($projectScan) {
            $projectPromptSection = "프로젝트 스캔 컨텍스트:`n$projectContext`n"
        }

        $userPrompt = @"
현재 루프 질문:
$question

직전 루프 요약 컨텍스트:
$lastTurn

최근 질문 히스토리:
$questionHistory

공통 컨텍스트:
$contextBundle

$projectPromptSection

요청:
위 질문에 답변해줘.
반드시 첫 번째 줄에는 NEXT_QUESTION: 으로 시작하는 다음 후속 질문을 한 줄로 작성하고, 그 뒤에 현재 질문에 대한 상세 답변을 작성해줘.
다음 질문은 최근 질문 히스토리를 반복하지 말고, 현재 질문의 주 기술 트랙을 유지하면서 더 좁고 검증 가능한 쟁점으로 이어가줘.
"@

        Write-Host "`n[$($started.ToString('yyyy-MM-dd HH:mm:ss'))] RUN #$runCount QUESTION:" -ForegroundColor Green
        Write-Host $question

        $requestAt = Get-Date
        $chatResult = Invoke-QwenChat $providerInfo $settings $networkIdentity $systemPrompt $userPrompt
        $answer = [string]$chatResult.Text
        $tokenUsage = $chatResult.Usage
        $tokenUse = $chatResult.TokenUse
        $nextQuestion = Extract-NextQuestion $answer
        $ended = Get-Date
        $completedAt = $ended
        $runStatus = "ok"

        Write-Utf8File $nextQuestionPath $nextQuestion

        $lastTurnText = @"
이전 질문:
$question

이전 답변 일부:
$(Get-TextPrefix $answer $LastTurnChars)
"@
        Write-Utf8File $lastTurnPath $lastTurnText

        $md = @"

---

# $($started.ToString('yyyy-MM-dd HH:mm:ss'))

## Question

$question

## Next Question

$nextQuestion

## Token Usage

$(Format-TokenUsageForMarkdown $tokenUsage $tokenUse)

## Answer

$answer

"@
        Append-Utf8File $transcriptPath $md

        $record = [ordered]@{
            started = $started.ToString("o")
            ended = $ended.ToString("o")
            providerType = $providerInfo.Type
            provider = $providerInfo.ProviderName
            providerId = $providerInfo.ProviderId
            baseUrl = $providerInfo.BaseUrl
            model = $providerInfo.ModelId
            envKey = $providerInfo.EnvKey
            apiKeySource = $providerInfo.ApiKeySource
            clientIp = $networkIdentity.localAddress
            question = $question
            nextQuestion = $nextQuestion
            usage = ConvertTo-PlainObject $tokenUsage
            tokenUse = ConvertTo-PlainObject $tokenUse
            answer = $answer
        }
        Append-Utf8File $jsonlPath (($record | ConvertTo-Json -Compress -Depth 50) + "`n")

        if (-not $NoAnswerPreview) {
            $answerPreview = Get-AnswerPreview $answer $AnswerPreviewLines $AnswerPreviewChars
            Write-Host "`nANSWER PREVIEW:" -ForegroundColor Cyan
            if ([string]::IsNullOrWhiteSpace($answerPreview)) {
                Write-Host "(preview is empty; full answer is saved in transcript.md)" -ForegroundColor DarkGray
            } else {
                Write-Host $answerPreview
            }
        }

        Write-Host "`nNEXT QUESTION:" -ForegroundColor Magenta
        Write-Host $nextQuestion
        Write-Host "`nSaved:" -ForegroundColor DarkGreen
        Write-Host "- $nextQuestionPath"
        Write-Host "- $lastTurnPath"
        Write-Host "- $transcriptPath"
        Write-Host "- $jsonlPath"
        Write-Host "- $(Join-Path $WorkDir 'last_request_headers.json')"
        Write-Host "- $(Join-Path $WorkDir 'last_request_body.json')"
        Write-Host "- $(Join-Path $WorkDir 'last_response_status.json')"
        Write-Host "`nRUN #$runCount complete. Full answer saved to transcript.md." -ForegroundColor Green
    } catch {
        $completedAt = Get-Date
        $msg = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] ERROR: $($_.Exception.Message)`n$($_.ScriptStackTrace)`n"
        $errorText = [string]$_.Exception.Message
        Append-Utf8File $errorLogPath $msg
        Write-Host $msg -ForegroundColor Red
    }

    $loopCleanup = Invoke-WorkDirCleanup $WorkDir $transcriptPath $jsonlPath $errorLogPath
    Write-WorkDirCleanupStatus $loopCleanup $false

    $willStop = ($Once -or ($MaxRuns -gt 0 -and $runCount -ge $MaxRuns))
    $nextWaitSeconds = $null
    $nextRunAt = $null
    if (-not $willStop) {
        $nextWaitSeconds = Get-NextIntervalSeconds $intervalPlan
        $nextRunAt = (Get-Date).AddSeconds($nextWaitSeconds)
    }

    $historyInputTokens = $null
    $historyOutputTokens = $null
    $historyTotalTokens = $null
    if ($tokenUsage) {
        $historyInputTokens = $tokenUsage.inputTokens
        $historyOutputTokens = $tokenUsage.outputTokens
        $historyTotalTokens = $tokenUsage.totalTokens
    }

    $historyRecord = [ordered]@{
        seq = $runSeq
        sessionRun = $runCount
        status = $runStatus
        startedAt = $started.ToString("o")
        requestAt = if ($requestAt) { $requestAt.ToString("o") } else { $null }
        completedAt = if ($completedAt) { $completedAt.ToString("o") } else { $null }
        nextWaitSeconds = $nextWaitSeconds
        nextRunAt = if ($nextRunAt) { $nextRunAt.ToString("o") } else { $null }
        providerType = $providerInfo.Type
        provider = $providerInfo.ProviderName
        providerId = $providerInfo.ProviderId
        baseUrl = $providerInfo.BaseUrl
        model = $providerInfo.ModelId
        endpoint = if ($chatResult) { $chatResult.Endpoint } else { $null }
        httpStatusCode = if ($chatResult) { $chatResult.StatusCode } else { $null }
        httpStatusDescription = if ($chatResult) { $chatResult.StatusDescription } else { $null }
        attempt = if ($chatResult) { $chatResult.Attempt } else { $null }
        retryCount = if ($chatResult) { $chatResult.RetryCount } else { $null }
        durationMs = if ($chatResult) { $chatResult.DurationMs } else { $null }
        receivedBytes = if ($chatResult) { $chatResult.ReceivedBytes } else { $null }
        inputTokens = $historyInputTokens
        outputTokens = $historyOutputTokens
        totalTokens = $historyTotalTokens
        tokenUse = ConvertTo-PlainObject $tokenUse
        question = $question
        nextQuestion = $nextQuestion
        answerChars = if ($answer) { $answer.Length } else { 0 }
        error = $errorText
    }
    Append-RunHistory ([PSCustomObject]$historyRecord) $runHistoryPath $runHistoryJsonlPath
    Write-Host "RunHistory  : $runHistoryPath" -ForegroundColor DarkGreen

    if ($willStop) {
        Write-Host "`n지정된 실행 횟수만큼 실행 후 종료합니다." -ForegroundColor DarkGray
        break
    }

    Wait-WithCountdown $nextWaitSeconds $intervalPlan
}
