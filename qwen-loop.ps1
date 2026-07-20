param(
    [string]$SettingsPath = "$env:USERPROFILE\.qwen\settings.json",
    [string]$ProviderName = "",
    [string]$ModelName = "",
    [string]$SeedFile = "$PSScriptRoot\seed_prompt.txt",
    [string]$QuestionBankFile = "$PSScriptRoot\question_bank.txt",
    [string]$QuestionTrack = "",
    [string]$ContextListFile = "$PSScriptRoot\context_files.txt",
    [string]$ProjectRoot = "",
    [switch]$FreshProjectQuestion,
    [string]$WorkDir = "$PSScriptRoot\qwen-loop-data",
    [int]$IntervalSeconds = 600,
    [int]$MinIntervalMinutes = 8,
    [int]$MaxIntervalMinutes = 15,
    [int]$MaxTokens = 32768,
    [double]$Temperature = 0.35,
    [int]$TimeoutSec = 120,
    [int]$MaxContextChars = 16000,
    [int]$ProjectScanMaxFiles = 60,
    [int]$ProjectScanMaxFileChars = 5000,
    [int]$ProjectScanMaxTotalChars = 14000,
    [int]$DynamicProjectContextMaxFiles = 10,
    [int]$DynamicProjectContextMaxFileChars = 6000,
    [int]$DynamicProjectContextMaxTotalChars = 42000,
    [switch]$NewProjectSession,
    [int]$ProjectTurnsPerCycle = 5,
    [int]$ProjectSessionKeepCount = 12,
    [int]$ProjectSessionKeepDays = 30,
    [int]$ProjectSessionMaxTotalMB = 750,
    [int]$ProjectTargetOutputTokens = 3500,
    [int]$ProjectTargetAnswerChars = 8000,
    [int]$LastTurnChars = 6000,
    [int]$CountdownRefreshSeconds = 1,
    [int]$AnswerPreviewLines = 10,
    [int]$AnswerPreviewChars = 2500,
    [int]$TokenLowThreshold = 2500,
    [int]$TokenRichThreshold = 6000,
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

function Test-ManagedProjectSubtreePath([string]$Root, [string]$Path) {
    try {
        $defaultRoot = Get-NormalizedFullPath (Join-Path $PSScriptRoot "qwen-loop-data")
        $actualRoot = Get-NormalizedFullPath $Root
        if (-not $actualRoot.Equals($defaultRoot, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
        $relative = Get-RelativeWorkPath $actualRoot $Path
        return ($relative -match '^project([\\/]|$)')
    } catch {
        return $true
    }
}

function Get-ManagedWorkDirFiles([string]$Root) {
    if (!(Test-Path -LiteralPath $Root -PathType Container)) { return @() }
    $files = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    $topItems = @(Get-ChildItem -LiteralPath $Root -Force -ErrorAction SilentlyContinue)
    foreach ($item in $topItems) {
        if (-not $item.PSIsContainer) { $files.Add([System.IO.FileInfo]$item) | Out-Null; continue }
        if (Test-ManagedProjectSubtreePath $Root $item.FullName) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Force -ErrorAction SilentlyContinue)) {
            $files.Add($file) | Out-Null
        }
    }
    return @($files.ToArray())
}

function Get-ManagedWorkDirDirectories([string]$Root) {
    if (!(Test-Path -LiteralPath $Root -PathType Container)) { return @() }
    $dirs = New-Object System.Collections.Generic.List[System.IO.DirectoryInfo]
    foreach ($dir in @(Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction SilentlyContinue)) {
        if (Test-ManagedProjectSubtreePath $Root $dir.FullName) { continue }
        $dirs.Add($dir) | Out-Null
        foreach ($nested in @(Get-ChildItem -LiteralPath $dir.FullName -Recurse -Directory -Force -ErrorAction SilentlyContinue)) {
            $dirs.Add($nested) | Out-Null
        }
    }
    return @($dirs.ToArray())
}

function Test-ManagedWorkDirTreeSafe([string]$Root) {
    try {
        $rootItem = Get-Item -LiteralPath $Root -Force -ErrorAction Stop
        if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        $queue = New-Object System.Collections.Generic.Queue[System.IO.DirectoryInfo]
        $queue.Enqueue([System.IO.DirectoryInfo]$rootItem)
        while ($queue.Count -gt 0) {
            $dir = $queue.Dequeue()
            foreach ($child in @(Get-ChildItem -LiteralPath $dir.FullName -Force -ErrorAction Stop)) {
                if ($dir.FullName -eq $rootItem.FullName -and $child.PSIsContainer -and (Test-ManagedProjectSubtreePath $Root $child.FullName)) { continue }
                if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
                if ($child.PSIsContainer) { $queue.Enqueue([System.IO.DirectoryInfo]$child) }
            }
        }
        return $true
    } catch {
        return $false
    }
}

function Get-ManagedWorkDirSizeBytes([string]$Root) {
    if (!(Test-Path -LiteralPath $Root -PathType Container)) { return 0 }
    $total = [int64]0
    Get-ManagedWorkDirFiles $Root | ForEach-Object { $total += [int64]$_.Length }
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
    if (Test-ManagedProjectSubtreePath $Root $FileFullName) { return $true }
    $relative = Get-RelativeWorkPath $Root $FileFullName
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
        "last_response_status.json",
        "last_dynamic_project_context.json",
        "exploration_state.json",
        "exploration_history.jsonl",
        "cycle_history.jsonl",
        "cycle_evidence.md",
        "session_identity.json",
        ".qwen-loop-workdir.json",
        ".active.lock",
        ".exploration.lock",
        ".retention.lock"
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
    $files = @(Get-ManagedWorkDirFiles $Root)
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

    $dirs = @(Get-ManagedWorkDirDirectories $Root | Sort-Object { $_.FullName.Length } -Descending)
    foreach ($dir in $dirs) {
        if (Test-ManagedProjectSubtreePath $Root $dir.FullName) { continue }
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
    $total = Get-ManagedWorkDirSizeBytes $Root
    if ($total -le $maxBytes) { return "" }

    $candidates = @(Get-ManagedWorkDirFiles $Root |
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
    $beforeBytes = [int64]0
    $warning = ""

    $ownershipValid = Test-QwenLoopWorkDirOwnership $Root
    $treeSafe = if ($ownershipValid -and -not $DryRun -and -not $NoAutoCleanup) { Test-ManagedWorkDirTreeSafe $Root } else { $true }
    if ($NoAutoCleanup -or $DryRun -or -not $ownershipValid -or -not $treeSafe) {
        $disabledReason = if ($NoAutoCleanup) { "disabled by -NoAutoCleanup" } elseif ($DryRun) { "disabled during DryRun" } elseif (-not $ownershipValid) { "disabled because WorkDir ownership marker is missing or invalid" } else { "disabled because WorkDir contains a junction/symlink/reparse point" }
        return [PSCustomObject]@{
            enabled = $false
            beforeBytes = $beforeBytes
            afterBytes = $beforeBytes
            actions = [object[]]@()
            warning = $disabledReason
        }
    }

    $beforeBytes = Get-ManagedWorkDirSizeBytes $Root

    Compact-TranscriptMarkdown $TranscriptPath $MaxTranscriptMB $CleanupKeepTurns $actions $Root
    Compact-TranscriptJsonl $JsonlPath $MaxTranscriptMB $CleanupKeepTurns $actions $Root
    Compact-TextTailFile $ErrorLogPath $MaxErrorLogMB "error.log" $actions $Root
    Remove-StaleCleanupFiles $Root $CleanupKeepDays $actions
    $warning = Enforce-WorkDirSize $Root $MaxWorkDirMB $actions
    Remove-EmptyWorkDirectories $Root

    $afterBytes = Get-ManagedWorkDirSizeBytes $Root
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
    if ($DryRun) { return "disabled during DryRun" }
    if ($script:workDirCleanupOwned -eq $false) { return "disabled for unowned custom WorkDir" }

    $folder = if ($MaxWorkDirMB -gt 0) { "folder <= $MaxWorkDirMB MB" } else { "folder cap off" }
    $transcript = if ($MaxTranscriptMB -gt 0) { "transcript <= $MaxTranscriptMB MB" } else { "transcript compact off" }
    $error = if ($MaxErrorLogMB -gt 0) { "error <= $MaxErrorLogMB MB" } else { "error compact off" }
    $days = if ($CleanupKeepDays -gt 0) { "stale check > $CleanupKeepDays days" } else { "stale check cleanup off" }
    return "$folder, $transcript, $error, keep $CleanupKeepTurns turns, $days"
}

function Write-WorkDirCleanupStatus($Summary, [bool]$Always) {
    if ($null -eq $Summary) { return }

    if (-not $Summary.enabled) {
        if ($Always) {
            $reason = if ([string]::IsNullOrWhiteSpace([string]$Summary.warning)) { "disabled" } else { [string]$Summary.warning }
            Write-Host "Cleanup     : $reason" -ForegroundColor DarkGray
        }
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

function Get-NormalizedFullPath([string]$Path) {
    $full = [System.IO.Path]::GetFullPath($Path)
    $trimmed = $full.TrimEnd([char[]]@('\', '/'))
    $root = [System.IO.Path]::GetPathRoot($full)
    if (-not [string]::IsNullOrWhiteSpace($root)) {
        $trimmedRoot = $root.TrimEnd([char[]]@('\', '/'))
        if ($trimmed.Equals($trimmedRoot, [System.StringComparison]::OrdinalIgnoreCase)) { return $root }
    }
    return $trimmed
}

function Test-PathInsideRoot([string]$Root, [string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Root) -or [string]::IsNullOrWhiteSpace($Path)) { return $false }
    $rootFull = (Get-NormalizedFullPath $Root).TrimEnd([char[]]@('\', '/'))
    $pathFull = (Get-NormalizedFullPath $Path).TrimEnd([char[]]@('\', '/'))
    if ($pathFull.Equals($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $pathFull.StartsWith(($rootFull + [System.IO.Path]::DirectorySeparatorChar), [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-PathHasReparsePointInExistingAncestry([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $true }
    try {
        $current = Get-NormalizedFullPath $Path
        while (-not (Test-Path -LiteralPath $current) -and -not [string]::IsNullOrWhiteSpace($current)) {
            $parent = [System.IO.Path]::GetDirectoryName($current.TrimEnd([char[]]@('\', '/')))
            if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) { break }
            $current = $parent
        }
        while (-not [string]::IsNullOrWhiteSpace($current)) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }
            $parent = [System.IO.Directory]::GetParent($item.FullName)
            if ($null -eq $parent) { break }
            $current = $parent.FullName
        }
        return $false
    } catch {
        return $true
    }
}

function Test-QwenLoopWorkDirOwnership([string]$Root) {
    if ([string]::IsNullOrWhiteSpace($Root)) { return $false }
    $markerPath = Join-Path $Root ".qwen-loop-workdir.json"
    if (!(Test-Path -LiteralPath $markerPath -PathType Leaf)) { return $false }
    try {
        $marker = (Read-Utf8File $markerPath) | ConvertFrom-Json
        if ([string]$marker.schema -ne "qwen-loop-workdir/v1") { return $false }
        $markerRoot = Get-NormalizedFullPath ([string]$marker.normalizedWorkDir)
        $actualRoot = Get-NormalizedFullPath $Root
        return $markerRoot.Equals($actualRoot, [System.StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

function Initialize-QwenLoopWorkDirOwnership([string]$Root, [bool]$CanClaim) {
    if (Test-QwenLoopWorkDirOwnership $Root) { return $true }
    if (-not $CanClaim -or $DryRun) { return $false }
    if (Test-PathHasReparsePointInExistingAncestry $Root) { return $false }
    $marker = [ordered]@{
        schema = "qwen-loop-workdir/v1"
        normalizedWorkDir = Get-NormalizedFullPath $Root
        orchestratorRoot = Get-NormalizedFullPath $PSScriptRoot
        createdAt = (Get-Date).ToString("o")
    }
    Write-Utf8File (Join-Path $Root ".qwen-loop-workdir.json") ($marker | ConvertTo-Json -Depth 10)
    return $true
}

function Assert-SafeWorkDir([string]$Path, [string]$ActiveProjectRoot) {
    $full = (Get-NormalizedFullPath $Path).TrimEnd([char[]]@('\', '/'))
    $driveRoot = [System.IO.Path]::GetPathRoot($full).TrimEnd([char[]]@('\', '/'))
    $scriptRoot = (Get-NormalizedFullPath $PSScriptRoot).TrimEnd([char[]]@('\', '/'))
    $profileRoot = ""
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $profileRoot = (Get-NormalizedFullPath $env:USERPROFILE).TrimEnd([char[]]@('\', '/'))
    }

    if ($full.Equals($driveRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "WorkDir로 드라이브 루트를 사용할 수 없습니다: $Path"
    }
    if ($full.Equals($scriptRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "WorkDir로 오케스트레이터 소스 루트를 사용할 수 없습니다: $Path"
    }
    if (-not [string]::IsNullOrWhiteSpace($profileRoot) -and $full.Equals($profileRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "WorkDir로 사용자 프로필 루트를 사용할 수 없습니다: $Path"
    }
    if (-not [string]::IsNullOrWhiteSpace($ActiveProjectRoot)) {
        $projectFull = (Get-NormalizedFullPath $ActiveProjectRoot).TrimEnd([char[]]@('\', '/'))
        if (Test-PathInsideRoot $projectFull $full) {
            throw "WorkDir는 ProjectRoot와 같거나 그 하위일 수 없습니다. 자동 정리가 프로젝트 소스를 건드리지 않도록 오케스트레이터의 별도 qwen-loop-data 폴더를 사용하세요."
        }
        if (Test-PathInsideRoot $full $projectFull) {
            throw "WorkDir는 ProjectRoot의 상위 폴더일 수 없습니다. 자동 정리 범위가 프로젝트 소스나 형제 폴더를 포함하지 않도록 별도 qwen-loop-data 폴더를 사용하세요."
        }
    }
    if (Test-PathHasReparsePointInExistingAncestry $full) {
        throw "WorkDir 또는 그 상위 경로에 junction/symlink/reparse point가 있어 실제 정리 경계를 안전하게 확정할 수 없습니다: $Path"
    }
}

function Get-StablePathHash([string]$Path, [int]$Length = 10) {
    $normalized = (Get-NormalizedFullPath $Path).ToLowerInvariant()
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalized)
        $hashBytes = $sha.ComputeHash($bytes)
        $hex = (($hashBytes | ForEach-Object { $_.ToString("x2") }) -join "")
        return $hex.Substring(0, [Math]::Min($Length, $hex.Length))
    } finally {
        $sha.Dispose()
    }
}

function Get-SafeProjectSlug([string]$Root) {
    $full = [System.IO.Path]::GetFullPath($Root)
    $trimmed = $full.TrimEnd([char[]]@('\', '/'))
    $name = [System.IO.Path]::GetFileName($trimmed)
    if ([string]::IsNullOrWhiteSpace($name)) {
        $drive = [System.IO.Path]::GetPathRoot($full).TrimEnd([char[]]@('\', '/')).Replace(":", "")
        $name = "drive-$drive"
    }
    $slug = [regex]::Replace($name, '[^\p{L}\p{Nd}._-]+', '-')
    $slug = $slug.Trim('-').Trim()
    if ([string]::IsNullOrWhiteSpace($slug)) { $slug = "project" }
    if ($slug.Length -gt 60) { $slug = $slug.Substring(0, 60).TrimEnd('-') }
    return $slug
}

function New-ProjectSessionLayout([string]$Root, [string]$SessionRoot) {
    $resolvedRoot = Resolve-ProjectRoot $Root
    $baseInput = Expand-PathInput $SessionRoot
    if (-not [System.IO.Path]::IsPathRooted($baseInput)) { $baseInput = Join-Path $PSScriptRoot $baseInput }
    $baseRoot = Get-NormalizedFullPath $baseInput
    $identity = "$(Get-SafeProjectSlug $resolvedRoot)-$(Get-StablePathHash $resolvedRoot 10)"
    $projectBase = Join-Path $baseRoot $identity
    $sessionsRoot = Join-Path $projectBase "sessions"
    do {
        $sessionId = "$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')-p$PID-$(Get-Random -Minimum 1000 -Maximum 10000)"
        $sessionDir = Join-Path $sessionsRoot $sessionId
    } while (Test-Path -LiteralPath $sessionDir)

    return [PSCustomObject]@{
        ProjectRoot = $resolvedRoot
        Identity = $identity
        ProjectBase = $projectBase
        SessionsRoot = $sessionsRoot
        SessionId = $sessionId
        SessionDir = $sessionDir
        ExplorationHistoryPath = (Join-Path $projectBase "exploration_history.jsonl")
    }
}

function Get-ValidatedProjectSessionDirectories($Layout) {
    if ($null -eq $Layout -or !(Test-Path -LiteralPath $Layout.SessionsRoot -PathType Container)) { return @() }
    $sessionsRoot = (Get-NormalizedFullPath ([string]$Layout.SessionsRoot)).TrimEnd([char[]]@('\', '/'))
    $projectRoot = Get-NormalizedFullPath ([string]$Layout.ProjectRoot)
    $valid = New-Object System.Collections.Generic.List[object]

    foreach ($dir in @(Get-ChildItem -LiteralPath $sessionsRoot -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($dir.Name -notmatch '^\d{8}-\d{6}-\d{3}-p\d+-\d{4}$') { continue }
        if (($dir.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        $parent = (Get-NormalizedFullPath $dir.Parent.FullName).TrimEnd([char[]]@('\', '/'))
        if (-not $parent.Equals($sessionsRoot, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $markerPath = Join-Path $dir.FullName "session_identity.json"
        if (!(Test-Path -LiteralPath $markerPath -PathType Leaf)) { continue }
        try {
            $marker = (Read-Utf8File $markerPath) | ConvertFrom-Json
            if ([string]$marker.schema -ne "qwen-loop-project-session/v1") { continue }
            if ([string]$marker.identity -ne [string]$Layout.Identity) { continue }
            $markerProjectRoot = Get-NormalizedFullPath ([string]$marker.canonicalProjectRoot)
            if (-not $markerProjectRoot.Equals($projectRoot, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            if ([string]$marker.sessionId -ne $dir.Name) { continue }
            $valid.Add([PSCustomObject]@{ Directory = $dir; Marker = $marker; LockPath = (Join-Path $dir.FullName ".active.lock") }) | Out-Null
        } catch { }
    }
    return @($valid.ToArray())
}

function Test-ProjectSessionInactive($SessionInfo) {
    if ($null -eq $SessionInfo) { return $false }
    $lockPath = [string]$SessionInfo.LockPath
    if (!(Test-Path -LiteralPath $lockPath -PathType Leaf)) { return $true }
    $probe = $null
    try {
        $probe = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        return $true
    } catch {
        return $false
    } finally {
        if ($probe) { $probe.Dispose() }
    }
}

function Open-ExclusiveFileLock([string]$Path, [int]$TimeoutMilliseconds = 3000) {
    $deadline = [DateTime]::UtcNow.AddMilliseconds([Math]::Max(0, $TimeoutMilliseconds))
    do {
        try {
            return [System.IO.File]::Open($Path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        } catch [System.IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) { return $null }
            Start-Sleep -Milliseconds 50
        } catch [System.UnauthorizedAccessException] {
            return $null
        }
    } while ($true)
}

function Test-DirectoryTreeSafeForRemoval([string]$RootPath) {
    try {
        $rootItem = Get-Item -LiteralPath $RootPath -Force -ErrorAction Stop
        if (-not $rootItem.PSIsContainer) { return $false }
        if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }

        $pending = New-Object System.Collections.Generic.Stack[System.IO.DirectoryInfo]
        $pending.Push([System.IO.DirectoryInfo]$rootItem)
        while ($pending.Count -gt 0) {
            $current = $pending.Pop()
            foreach ($child in @(Get-ChildItem -LiteralPath $current.FullName -Force -ErrorAction Stop)) {
                if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
                if ($child.PSIsContainer) { $pending.Push([System.IO.DirectoryInfo]$child) }
            }
        }
        return $true
    } catch {
        return $false
    }
}

function Remove-ValidatedProjectSession($SessionInfo, $Layout) {
    if ($null -eq $SessionInfo) { return $false }
    try {
        $sessionsRoot = (Get-NormalizedFullPath ([string]$Layout.SessionsRoot)).TrimEnd([char[]]@('\', '/'))
        $full = Get-NormalizedFullPath ([string]$SessionInfo.Directory.FullName)
        $current = Get-NormalizedFullPath ([string]$Layout.SessionDir)
        if ($full.Equals($current, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }

        # Refresh every safety decision immediately before recursive removal.  A
        # stale DirectoryInfo or marker must never authorize deletion.
        $fresh = @(Get-ValidatedProjectSessionDirectories $Layout | Where-Object {
            (Get-NormalizedFullPath ([string]$_.Directory.FullName)).Equals($full, [System.StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1)[0]
        if ($null -eq $fresh) { return $false }
        $dir = Get-Item -LiteralPath $full -Force -ErrorAction Stop
        if (($dir.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        $parent = (Get-NormalizedFullPath $dir.Parent.FullName).TrimEnd([char[]]@('\', '/'))
        if (-not $parent.Equals($sessionsRoot, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
        if (-not (Test-ProjectSessionInactive $fresh)) { return $false }
        if (-not (Test-DirectoryTreeSafeForRemoval $full)) { return $false }

        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Invoke-ProjectSessionRetention($Layout) {
    $actions = New-Object System.Collections.Generic.List[object]
    $warnings = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Layout -or $NoAutoCleanup -or $DryRun) {
        return [PSCustomObject]@{ enabled = $false; actions = @(); remainingSessions = 0; remainingBytes = 0 }
    }
    if ($ProjectSessionKeepCount -lt 1) { throw "ProjectSessionKeepCount는 1 이상이어야 합니다." }
    if ($ProjectSessionKeepDays -lt 0) { throw "ProjectSessionKeepDays는 0 이상이어야 합니다." }
    if ($ProjectSessionMaxTotalMB -lt 0) { throw "ProjectSessionMaxTotalMB는 0 이상이어야 합니다." }

    $sessionsRoot = Get-NormalizedFullPath ([string]$Layout.SessionsRoot)
    $projectBase = Get-NormalizedFullPath ([string]$Layout.ProjectBase)
    if (-not (Test-PathInsideRoot $projectBase $sessionsRoot)) {
        throw "세션 정리 경로가 프로젝트 세션 루트 밖입니다: $sessionsRoot"
    }
    if (!(Test-Path -LiteralPath $sessionsRoot -PathType Container)) {
        return [PSCustomObject]@{ enabled = $true; actions = @(); remainingSessions = 0; remainingBytes = 0 }
    }

    $retentionLock = Open-ExclusiveFileLock (Join-Path $projectBase ".retention.lock") 3000
    if ($null -eq $retentionLock) {
        return [PSCustomObject]@{
            enabled = $true
            actions = @()
            remainingSessions = @(Get-ValidatedProjectSessionDirectories $Layout).Count
            remainingBytes = (Get-DirectorySizeBytes $sessionsRoot)
            warning = "another process owns project-session retention; cleanup was skipped"
        }
    }

    try {
        $current = Get-NormalizedFullPath ([string]$Layout.SessionDir)
        $cutoff = if ($ProjectSessionKeepDays -gt 0) { (Get-Date).AddDays(-$ProjectSessionKeepDays) } else { $null }
        $sessions = @(Get-ValidatedProjectSessionDirectories $Layout | Sort-Object { $_.Directory.LastWriteTimeUtc } -Descending)

    for ($i = 0; $i -lt $sessions.Count; $i++) {
        $info = $sessions[$i]
        $dir = $info.Directory
        if ($dir.FullName.Equals($current, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $beyondCount = $i -ge $ProjectSessionKeepCount
        $tooOld = ($null -ne $cutoff -and $dir.LastWriteTime -lt $cutoff)
        if (-not $beyondCount -and -not $tooOld) { continue }

        $before = Get-DirectorySizeBytes $dir.FullName
        if (Remove-ValidatedProjectSession $info $Layout) {
            $actions.Add([PSCustomObject]@{ kind = "deleted-session"; path = $dir.FullName; beforeBytes = $before; note = if ($tooOld) { "retention-days" } else { "retention-count" } }) | Out-Null
        } else {
            $warnings.Add("active or unvalidated session was preserved: $($dir.Name)") | Out-Null
        }
    }

    if ($ProjectSessionMaxTotalMB -gt 0) {
        $limit = [int64]$ProjectSessionMaxTotalMB * 1MB
        $remaining = @(Get-ValidatedProjectSessionDirectories $Layout | Sort-Object { $_.Directory.LastWriteTimeUtc })
        $total = [int64]0
        $sizes = @{}
        foreach ($info in $remaining) {
            $dir = $info.Directory
            $size = Get-DirectorySizeBytes $dir.FullName
            $sizes[$dir.FullName] = $size
            $total += $size
        }
        foreach ($info in $remaining) {
            $dir = $info.Directory
            if ($total -le $limit) { break }
            if ($dir.FullName.Equals($current, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            $size = [int64]$sizes[$dir.FullName]
            if (Remove-ValidatedProjectSession $info $Layout) {
                $total -= $size
                $actions.Add([PSCustomObject]@{ kind = "deleted-session"; path = $dir.FullName; beforeBytes = $size; note = "aggregate-size-cap" }) | Out-Null
            } else {
                $warnings.Add("size cap could not remove active session: $($dir.Name)") | Out-Null
            }
        }
        if ($total -gt $limit) { $warnings.Add("aggregate size remains above cap because active sessions are preserved") | Out-Null }
    }

        $finalSessions = @(Get-ValidatedProjectSessionDirectories $Layout)
        return [PSCustomObject]@{
            enabled = $true
            actions = @($actions.ToArray())
            remainingSessions = $finalSessions.Count
            remainingBytes = (Get-DirectorySizeBytes $sessionsRoot)
            warning = ($warnings -join "; ")
        }
    } catch {
        $warnings.Add("session retention failed safely: $($_.Exception.Message)") | Out-Null
        return [PSCustomObject]@{
            enabled = $true
            actions = @($actions.ToArray())
            remainingSessions = @(Get-ValidatedProjectSessionDirectories $Layout).Count
            remainingBytes = (Get-DirectorySizeBytes $sessionsRoot)
            warning = ($warnings -join "; ")
        }
    } finally {
        $retentionLock.Dispose()
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

function Get-TextSuffix([string]$Text, [int]$MaxChars) {
    if ([string]::IsNullOrEmpty($Text)) { return "" }
    if ($Text.Length -le $MaxChars) { return $Text }
    return "...[older content omitted]...`n" + $Text.Substring($Text.Length - $MaxChars)
}

function Get-JsonProperty($obj, [string]$name) {
    if ($null -eq $obj) { return $null }
    if ($obj -is [System.Collections.IDictionary]) {
        foreach ($key in $obj.Keys) {
            if ([string]$key -ieq $name) { return $obj[$key] }
        }
    }
    $prop = $obj.PSObject.Properties | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if ($prop) { return $prop.Value }
    return $null
}

function ConvertTo-BooleanValue($Value, [bool]$DefaultValue = $false) {
    if ($null -eq $Value) { return $DefaultValue }
    if ($Value -is [bool]) { return [bool]$Value }
    $parsed = $false
    if ([bool]::TryParse(([string]$Value).Trim(), [ref]$parsed)) { return $parsed }
    try { return [System.Convert]::ToBoolean($Value, [System.Globalization.CultureInfo]::InvariantCulture) } catch { return $DefaultValue }
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
        if ($IntervalSeconds -lt 0) { throw "IntervalSeconds는 0 이상이어야 합니다." }
        return [PSCustomObject]@{
            Mode = "fixed"
            FixedSeconds = [int]$IntervalSeconds
            MinSeconds = [int]$IntervalSeconds
            MaxSeconds = [int]$IntervalSeconds
            Note = "Fixed interval mode because -IntervalSeconds was explicitly provided without random min/max. 0 means run again immediately after the previous response is handled."
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
    if ($DynamicProjectContextMaxFiles -lt 0) { throw "DynamicProjectContextMaxFiles는 0 이상이어야 합니다." }
    if ($DynamicProjectContextMaxFileChars -lt 200) { throw "DynamicProjectContextMaxFileChars는 200 이상이어야 합니다." }
    if ($DynamicProjectContextMaxTotalChars -lt 1000) { throw "DynamicProjectContextMaxTotalChars는 1000 이상이어야 합니다." }
    if ($ProjectTurnsPerCycle -lt 1) { throw "ProjectTurnsPerCycle은 1 이상이어야 합니다." }
    if ($ProjectTargetOutputTokens -lt 1) { throw "ProjectTargetOutputTokens는 1 이상이어야 합니다." }
    if ($ProjectTargetAnswerChars -lt 500) { throw "ProjectTargetAnswerChars는 500 이상이어야 합니다." }
}

function Resolve-ProjectRoot([string]$PathText) {
    $p = Expand-PathInput $PathText
    if ([string]::IsNullOrWhiteSpace($p)) { return "" }
    if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path $PSScriptRoot $p }
    if (!(Test-Path -LiteralPath $p -PathType Container)) { throw "ProjectRoot 디렉터리를 찾지 못했습니다: $PathText" }
    return (Get-NormalizedFullPath $p)
}

function Test-ProjectExcludedDirectoryName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    $excluded = @(
        ".git", ".svn", ".hg", ".idea", ".vscode", ".gradle", ".qwen", ".codex", ".agents",
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
    if ($File.Name -match '(?i)(secret|credential|private[-_.]?key|service[-_.]?account|keystore|truststore|vault)') { return $false }
    if ($ext -in @(".pem", ".key", ".p12", ".pfx", ".jks", ".keystore")) { return $false }
    if ($File.Name -match '(?i)^(package-lock\.json|yarn\.lock|pnpm-lock\.(yaml|yml)|gradle\.lockfile)$') { return $false }
    if ($File.Name -match '(?i)(\.min\.js|\.map)$') { return $false }
    return $true
}

function Protect-ProjectSnippetSecrets([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return "" }
    $protected = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '(?i)-----BEGIN\s+(?:RSA\s+|EC\s+|OPENSSH\s+)?PRIVATE\s+KEY-----') {
            $protected.Add("[REDACTED PRIVATE KEY]") | Out-Null
            continue
        }
        if ($line -match '(?i)(password|passwd|pwd|secret|api[-_.]?key|access[-_.]?token|refresh[-_.]?token|authorization|private[-_.]?key)\s*["'']?\s*[:=]') {
            $indent = ([regex]::Match($line, '^\s*')).Value
            $protected.Add("${indent}[REDACTED SENSITIVE CONFIG LINE]") | Out-Null
            continue
        }
        $protected.Add([string]$line) | Out-Null
    }
    return ($protected -join "`n")
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
        $raw = Protect-ProjectSnippetSecrets (Read-Utf8File $Path)
        return Get-TextPrefix $raw $MaxChars
    } catch {
        try {
            $raw = Protect-ProjectSnippetSecrets ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::Default))
            return Get-TextPrefix $raw $MaxChars
        } catch {
            return ""
        }
    }
}

function Read-ProjectFileText([string]$Path) {
    try {
        return (Protect-ProjectSnippetSecrets (Read-Utf8File $Path))
    } catch {
        try {
            return (Protect-ProjectSnippetSecrets ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::Default)))
        } catch {
            return ""
        }
    }
}

function Add-ProjectScoreReason($Reasons, [string]$Reason) {
    if (-not [string]::IsNullOrWhiteSpace($Reason) -and -not $Reasons.Contains($Reason)) { $Reasons.Add($Reason) | Out-Null }
}

function Get-BusinessFamilyKeyFromPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    $base = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    if ([string]::IsNullOrWhiteSpace($base)) { return "" }

    if ($base -match '^([A-Za-z]{2,}(?:[_-]?[A-Za-z]+)*[_-]?\d{3,})') {
        return $Matches[1].ToLowerInvariant()
    }

    $familySuffixPattern = '(?i)(Mapper|MapperImpl|ServiceImpl|Service|Controller|Repository|Dao|DAO|Tasklet|Job|Step|Decider|Listener|VO|Vo|DTO|Dto|Entity|Model|Request|Response|Query|Command|Store|Provider)$'
    if ($base -notmatch $familySuffixPattern) { return "" }
    $stem = $base -replace $familySuffixPattern, ''
    $stem = $stem.Trim('_-')
    $variantSuffixPattern = '(?i)(History|Detail|Details|Item|Items|List|Info|Data|Result|Payload|Param|Params|Parameter|Parameters|Form|Summary|Search|Filter|Create|Update|Delete|Save|Job|Batch)$'
    $normalizedStem = ($stem -replace $variantSuffixPattern, '').Trim('_-')
    if ($stem -match $variantSuffixPattern -and $normalizedStem.Length -lt 3) { return "" }
    if ($normalizedStem.Length -ge 3) { $stem = $normalizedStem }
    if ($stem.Length -lt 3) { return "" }
    if ($stem -match '(?i)^(common|base|abstract|default|global|shared|core|main|application|app|config|configuration|security|util|utils|helper|constant|constants)$') { return "" }
    return $stem.ToLowerInvariant()
}

function Get-ProjectBusinessFamilyKey($Item) {
    if ($null -eq $Item) { return "" }
    return (Get-BusinessFamilyKeyFromPath ([string]$Item.path))
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

    $businessFamily = Get-BusinessFamilyKeyFromPath $relative
    if (-not [string]::IsNullOrWhiteSpace($businessFamily)) {
        $score += 12; Add-ProjectScoreReason $reasons "business family:$businessFamily"
    }
    if ($nameLower -match '(vo|dto|entity|model|request|response)\.(java|kt|ts|tsx)$') {
        $score += 30; Add-ProjectScoreReason $reasons "business data model"
    }
    if ($nameLower -match '(tasklet|job|step|decider)\.(java|kt)$') {
        $score += 32; Add-ProjectScoreReason $reasons "batch business process"
    }

    $contentLower = if ($Content) { $Content.ToLowerInvariant() } else { "" }
    if ($Content -match '[가-힣]{2,}') {
        $score += 18; Add-ProjectScoreReason $reasons "Korean business labels/comments"
    }
    if ($contentLower -match '<resultmap|\bresultmap\b|\bparameterType\b|\bresultType\b') {
        $score += 18; Add-ProjectScoreReason $reasons "mapper data contract"
    }
    if ($Content -match '(?i)\b(?:TB|TBL|VW|V)_[A-Z0-9_]{3,}\b') {
        $score += 18; Add-ProjectScoreReason $reasons "business table evidence"
    }
    if ($contentLower -match '@schema\s*\(|@column\s*\(|@apimodelproperty|@notnull|@size\s*\(') {
        $score += 14; Add-ProjectScoreReason $reasons "field meaning/validation evidence"
    }
    if ($contentLower -match 'jobparameter|jobparameters|@value\s*\(') {
        $score += 14; Add-ProjectScoreReason $reasons "business execution parameter"
    }
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

    if ($nameLower -match '^(common|base|abstract|global|shared|core|default).*(listener|service|util|helper|config)?\.(java|kt|ts|tsx)$' -or
        $nameLower -match '(application|configuration|config|util|utils|helper)\.(java|kt|ts|tsx)$') {
        $score = [Math]::Max(1, $score - 35)
        Add-ProjectScoreReason $reasons "technical core/support only"
    }

    return [PSCustomObject]@{
        path = $relative
        fullName = $File.FullName
        extension = $File.Extension
        sizeBytes = [int64]$File.Length
        score = [Math]::Max(1, $score)
        reasons = @($reasons)
        excerpt = $Content
        businessFamilyKey = $businessFamily
    }
}

function Join-ProjectPathParts($Parts, [int]$Count) {
    $items = @($Parts | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($items.Count -eq 0 -or $Count -le 0) { return "" }

    $take = [Math]::Min($Count, $items.Count)
    $selected = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $take; $i++) { $selected.Add([string]$items[$i]) | Out-Null }
    return ($selected -join "/")
}

function Get-ProjectQuestionRole($Item) {
    $path = [string]$Item.path
    $name = [System.IO.Path]::GetFileName($path).ToLowerInvariant()
    $ext = ([string]$Item.extension).ToLowerInvariant()
    $pathKey = (($path -replace '\\', '/') -replace '/+', '/').ToLowerInvariant()
    $reasonText = ((@($Item.reasons) | ForEach-Object { [string]$_ }) -join " ").ToLowerInvariant()

    if ($ext -eq ".md") { return "docs" }
    if ($pathKey -match '(^|/)(test|tests|spec|specs|__tests__)(/|$)' -or $name -match '(?i)(test|tests|spec)\.') { return "test" }
    if ($ext -in @(".bat", ".cmd", ".sh")) { return "script-launcher" }
    if ($ext -in @(".ps1", ".psm1")) { return "script-main" }
    if ($reasonText -match 'project/build|entry point') { return "entry-build" }
    if ($reasonText -match 'runtime config|cross-cutting config|security') { return "config-security" }
    if ($reasonText -match 'technical core/support only' -or $name -match '^(common|base|abstract|global|shared|core|default).*(listener|service|util|helper|config)?\.') { return "technical-core" }
    if ($reasonText -match 'batch business process' -or $name -match '(tasklet|job|step|decider)\.(java|kt)$') { return "batch-process" }
    if ($reasonText -match 'business data model' -or $name -match '(vo|dto|entity|model|request|response)\.(java|kt|ts|tsx)$') { return "domain-model" }
    if ($reasonText -match 'service/domain') { return "service-domain" }
    if ($reasonText -match 'api boundary|spring route') { return "api-boundary" }
    if ($reasonText -match 'db boundary|sql ') { return "db-sql" }
    if ($reasonText -match 'frontend route/page') { return "ui-route-page" }
    if ($reasonText -match 'state store') { return "state-store" }
    if ($pathKey -match '(^|/)(hooks?|composables?)(/|$)' -or $name -match '^use[A-Za-z0-9_-]+\.') { return "hook-composable" }
    if ($reasonText -match 'frontend data/state|server-state query|http client') { return "data-api-client" }
    if ($reasonText -match 'script entry|script launcher|script parameters') {
        if ($ext -in @(".bat", ".cmd", ".sh") -or $reasonText -match 'script launcher') { return "script-launcher" }
        if ($ext -in @(".ps1", ".psm1")) { return "script-main" }
        return "script-automation"
    }
    if ($ext -in @(".json", ".yml", ".yaml", ".properties", ".gradle")) { return "config-data" }
    return "code"
}

function Test-ProjectQuestionSeedCandidate($Item) {
    if ($null -eq $Item) { return $false }
    if ([string]::IsNullOrWhiteSpace([string]$Item.path)) { return $false }
    $role = [string]$Item.questionGroupRole
    if ([string]::IsNullOrWhiteSpace($role)) {
        $group = Get-ProjectQuestionGroup $Item
        $role = [string]$group.role
    }
    return ($role -ne "docs")
}

function Test-ProjectPrimaryQuestionSeedCandidate($Item) {
    if (-not (Test-ProjectQuestionSeedCandidate $Item)) { return $false }

    $role = [string]$Item.questionGroupRole
    if ([string]::IsNullOrWhiteSpace($role)) {
        $group = Get-ProjectQuestionGroup $Item
        $role = [string]$group.role
    }

    $anchorPath = [string]$Item.questionGroupAnchorPath
    if ([string]::IsNullOrWhiteSpace($anchorPath)) {
        $group = Get-ProjectQuestionGroup $Item
        $anchorPath = [string]$group.anchorPath
    }

    if ($anchorPath -eq "public") { return $false }
    return ($role -notin @("entry-build", "config-security", "config-data", "docs", "script-launcher", "test", "technical-core"))
}

function Get-ProjectQuestionGroup($Item) {
    $path = [string]$Item.path
    $normalized = (($path -replace '\\', '/') -replace '/+', '/').Trim("/")
    $segments = @($normalized -split "/" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $role = Get-ProjectQuestionRole $Item
    $anchor = "root"
    $businessFamily = Get-ProjectBusinessFamilyKey $Item

    $businessRoles = @("code", "service-domain", "api-boundary", "db-sql", "domain-model", "batch-process", "ui-route-page", "state-store", "hook-composable", "data-api-client")
    if (-not [string]::IsNullOrWhiteSpace($businessFamily) -and $businessRoles -contains $role) {
        return [PSCustomObject]@{
            key = "business/$businessFamily"
            label = "$businessFamily (business family)"
            anchorPath = "business/$businessFamily"
            role = $role
            businessFamily = $businessFamily
        }
    }

    if ($segments.Count -gt 1) {
        $dirs = @()
        for ($i = 0; $i -lt ($segments.Count - 1); $i++) { $dirs += [string]$segments[$i] }

        if ($dirs.Count -gt 0) {
            $first = ([string]$dirs[0]).ToLowerInvariant()
            $second = if ($dirs.Count -ge 2) { ([string]$dirs[1]).ToLowerInvariant() } else { "" }
            $third = if ($dirs.Count -ge 3) { ([string]$dirs[2]).ToLowerInvariant() } else { "" }

            if ($first -in @("packages", "apps", "modules", "services") -and $dirs.Count -ge 2) {
                $anchor = Join-ProjectPathParts $dirs 2
            } elseif ($first -in @("src", "source", "lib", "app")) {
                if ($dirs.Count -ge 3 -and $second -in @("main", "test") -and $third -in @("java", "kotlin", "resources")) {
                    $anchor = Join-ProjectPathParts $dirs 3
                } elseif ($dirs.Count -ge 3 -and $second -eq "app") {
                    $anchor = Join-ProjectPathParts $dirs 3
                } elseif ($dirs.Count -ge 2) {
                    $anchor = Join-ProjectPathParts $dirs 2
                } else {
                    $anchor = Join-ProjectPathParts $dirs 1
                }
            } elseif ($dirs.Count -ge 2) {
                $anchor = Join-ProjectPathParts $dirs 2
            } else {
                $anchor = Join-ProjectPathParts $dirs 1
            }
        }
    }

    $genericAnchors = @("root", "src", "source", "lib", "app", "src/main", "src/test", "source/main", "source/test")
    $key = $anchor.ToLowerInvariant()
    if ($genericAnchors -contains $key -or $role -ne "code") {
        $key = "$key/$role"
    }

    $label = $anchor
    if ($role -ne "code") { $label = "$anchor ($role)" }

    return [PSCustomObject]@{
        key = $key
        label = $label
        anchorPath = $anchor
        role = $role
        businessFamily = $businessFamily
    }
}

function Set-ProjectQuestionGroup($Item) {
    if ($null -eq $Item) { return $null }
    $group = Get-ProjectQuestionGroup $Item
    $Item | Add-Member -NotePropertyName questionGroupKey -NotePropertyValue $group.key -Force
    $Item | Add-Member -NotePropertyName questionGroupLabel -NotePropertyValue $group.label -Force
    $Item | Add-Member -NotePropertyName questionGroupRole -NotePropertyValue $group.role -Force
    $Item | Add-Member -NotePropertyName questionGroupAnchorPath -NotePropertyValue $group.anchorPath -Force
    $Item | Add-Member -NotePropertyName businessFamilyKey -NotePropertyValue $group.businessFamily -Force
    return $Item
}

function Get-ProjectQuestionGroups($Files) {
    $items = @($Files | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.path) })
    $groups = @{}

    foreach ($item in $items) {
        if ([string]::IsNullOrWhiteSpace([string]$item.questionGroupKey)) { $item = Set-ProjectQuestionGroup $item }
        $key = [string]$item.questionGroupKey
        if ([string]::IsNullOrWhiteSpace($key)) { continue }

        if (-not $groups.ContainsKey($key)) {
            $groups[$key] = [PSCustomObject]@{
                key = $key
                label = [string]$item.questionGroupLabel
                role = [string]$item.questionGroupRole
                anchorPath = [string]$item.questionGroupAnchorPath
                businessFamily = [string]$item.businessFamilyKey
                files = (New-Object System.Collections.Generic.List[object])
            }
        }
        $groups[$key].files.Add($item) | Out-Null
    }

    $result = New-Object System.Collections.Generic.List[object]
    foreach ($group in $groups.Values) {
        $files = @($group.files | Sort-Object @{ Expression = "score"; Descending = $true }, @{ Expression = "sizeBytes"; Descending = $true }, @{ Expression = "path"; Descending = $false })
        if ($files.Count -eq 0) { continue }

        $maxScore = [int]$files[0].score
        $countBonus = [Math]::Min(20, [int][Math]::Ceiling([Math]::Sqrt([double]$files.Count) * 4))
        $result.Add([PSCustomObject]@{
            key = $group.key
            label = $group.label
            role = $group.role
            anchorPath = $group.anchorPath
            businessFamily = $group.businessFamily
            fileCount = $files.Count
            maxScore = $maxScore
            groupWeight = [Math]::Max(1, $maxScore + $countBonus)
            representativeFile = [string]$files[0].path
            files = $files
        }) | Out-Null
    }

    return @($result.ToArray() | Sort-Object @{ Expression = "maxScore"; Descending = $true }, @{ Expression = "fileCount"; Descending = $true }, @{ Expression = "label"; Descending = $false })
}

function Select-WeightedProjectFile($Files) {
    $items = @($Files | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.path) })
    if ($items.Count -eq 0) { return $null }

    $totalWeight = 0
    foreach ($item in $items) { $totalWeight += [Math]::Max(1, [int]$item.score) }
    $roll = Get-Random -Minimum 1 -Maximum ($totalWeight + 1)
    $cursor = 0
    foreach ($item in $items) {
        $cursor += [Math]::Max(1, [int]$item.score)
        if ($roll -le $cursor) { return $item }
    }
    return $items[0]
}

function Select-ProjectScanContextFiles($Files, [int]$Count) {
    $items = @($Files | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.path) })
    if ($items.Count -eq 0 -or $Count -lt 1) { return @() }

    $ranked = @($items | Sort-Object @{ Expression = "score"; Descending = $true }, @{ Expression = "sizeBytes"; Descending = $true }, @{ Expression = "path"; Descending = $false })
    $groups = @(Get-ProjectQuestionGroups $ranked)
    $selected = New-Object System.Collections.Generic.List[object]
    $selectedPaths = @{}
    $representativeLimit = [Math]::Min($Count, [Math]::Max(1, [int][Math]::Ceiling($Count * 0.7)))

    foreach ($group in $groups) {
        if ($selected.Count -ge $representativeLimit) { break }
        $file = @($group.files | Select-Object -First 1)[0]
        if ($file -and -not $selectedPaths.ContainsKey([string]$file.path)) {
            $selected.Add($file) | Out-Null
            $selectedPaths[[string]$file.path] = $true
        }
    }

    foreach ($file in $ranked) {
        if ($selected.Count -ge $Count) { break }
        if (-not $selectedPaths.ContainsKey([string]$file.path)) {
            $selected.Add($file) | Out-Null
            $selectedPaths[[string]$file.path] = $true
        }
    }

    return @($selected.ToArray())
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
                if (($childDir.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                if (-not (Test-ProjectExcludedDirectoryName $childDir.Name)) { $queue.Enqueue($childDir) }
            }
            $includedFiles = @(Get-ChildItem -LiteralPath $dir.FullName -File -Force -ErrorAction SilentlyContinue | Where-Object { Test-ProjectIncludedFile $_ })
            if ($includedFiles.Count -gt 120) { $includedFiles = @($includedFiles | Get-Random -Count 120) }
            foreach ($file in $includedFiles) {
                if ($result.Count -ge 2000) { break }
                $result.Add($file) | Out-Null
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

function Test-DynamicProjectNoiseTerm([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $true }
    $v = $Value.Trim()
    if ($v.Length -lt 3 -or $v.Length -gt 100) { return $true }
    if ($v -match '(?i)^(http|https|www|com|org|net)$') { return $true }

    $noise = @(
        "SQL", "DB", "HTTP", "HTTPS", "JSON", "XML", "API", "URI", "URL",
        "GET", "POST", "PUT", "PATCH", "DELETE", "TRUE", "FALSE", "NULL",
        "SELECT", "INSERT", "UPDATE", "WHERE", "FROM", "JOIN", "AND", "OR",
        "JAVA", "SPRING", "SERVICE", "MAPPER", "CONTROLLER", "TRANSACTION", "TRANSACTIONAL",
        "TASKLET", "JOB", "STEP", "DECIDER", "LISTENER", "DTO", "VO", "ENTITY", "MODEL", "REQUEST", "RESPONSE",
        "EXECUTE", "RUN", "PROCESS", "HANDLE", "START", "FINISH", "BEFORE", "AFTER", "MAIN",
        "CLASS", "METHOD", "PUBLIC", "PRIVATE", "RETURN", "VOID", "STRING", "INTEGER", "OBJECT",
        "FIELD", "TABLE", "COLUMN", "COMMENT", "PARAMETER", "JOBPARAMETER", "DOWNSTREAM", "FLOW"
    )
    return ($noise -contains $v.ToUpperInvariant())
}

function Add-DynamicProjectSearchTerm($Terms, [string]$Value, [string]$Kind, [int]$Weight) {
    if (Test-DynamicProjectNoiseTerm $Value) { return }

    $clean = [regex]::Replace([string]$Value, '^[`"''“”‘’\(\)\[\]<>,.;:]+|[`"''“”‘’\(\)\[\]<>,.;:]+$', '')
    if (Test-DynamicProjectNoiseTerm $clean) { return }

    $key = $clean.ToLowerInvariant()
    if ($Kind -in @("file", "symbol") -and $clean -match '(?i)\.(java|kt|kts|xml|ts|tsx|js|jsx|vue|sql)$') {
        $key = [System.IO.Path]::GetFileNameWithoutExtension($clean).ToLowerInvariant()
    }
    if ((-not $Terms.ContainsKey($key)) -or ([int]$Terms[$key].weight -lt $Weight)) {
        $Terms[$key] = [PSCustomObject]@{
            value = $clean
            kind = $Kind
            weight = $Weight
        }
    }
}

function Get-DynamicProjectSearchTerms([string]$Question, [string]$LastTurn) {
    $terms = @{}
    $sources = @(
        [PSCustomObject]@{ Text = [string]$Question; Weight = 100 },
        [PSCustomObject]@{ Text = (Get-TextPrefix ([string]$LastTurn) 6000); Weight = 45 }
    )

    foreach ($source in $sources) {
        $text = [string]$source.Text
        if ([string]::IsNullOrWhiteSpace($text)) { continue }

        foreach ($match in [regex]::Matches($text, '(?i)(?<![A-Za-z0-9_$@.-])([A-Za-z0-9_$@.-]+\.(?:java|kt|kts|xml|ts|tsx|js|jsx|vue|sql|properties|ya?ml|json|md|graphql|gql|gradle|ps1|bat|cmd|sh))(?=$|[^A-Za-z0-9_$@.-])')) {
            Add-DynamicProjectSearchTerm $terms $match.Groups[1].Value "file" ([int]$source.Weight + 40)
        }

        foreach ($match in [regex]::Matches($text, '(?<![A-Za-z0-9_-])([A-Za-z][A-Za-z0-9_]*-[A-Za-z][A-Za-z0-9_-]{2,100})(?=$|[^A-Za-z0-9_-])')) {
            Add-DynamicProjectSearchTerm $terms $match.Groups[1].Value "symbol" ([int]$source.Weight + 10)
        }

        foreach ($match in [regex]::Matches($text, '[$#]\{([^}]{1,80})\}')) {
            Add-DynamicProjectSearchTerm $terms $match.Value "placeholder" ([int]$source.Weight + 20)
            Add-DynamicProjectSearchTerm $terms $match.Groups[1].Value "symbol" ([int]$source.Weight)
        }

        foreach ($match in [regex]::Matches($text, '\b[A-Z][A-Za-z0-9_]{2,80}\b')) {
            Add-DynamicProjectSearchTerm $terms $match.Value "symbol" ([int]$source.Weight)
        }

        foreach ($match in [regex]::Matches($text, '\b[A-Z][A-Z0-9_]{3,80}\b')) {
            Add-DynamicProjectSearchTerm $terms $match.Value "table-column" ([int]$source.Weight + 25)
        }

        foreach ($match in [regex]::Matches($text, '\b[a-z][A-Za-z0-9_]*[A-Z][A-Za-z0-9_]{2,80}\b')) {
            Add-DynamicProjectSearchTerm $terms $match.Value "symbol" ([int]($source.Weight * 0.8))
        }
    }

    return @($terms.Values | Sort-Object @{ Expression = "weight"; Descending = $true }, @{ Expression = "value"; Descending = $false } | Select-Object -First 40)
}

function Get-DynamicProjectFocusTerms($Candidate, $Terms) {
    $seen = @{}
    $items = New-Object System.Collections.Generic.List[object]
    $order = 0

    foreach ($value in @($Candidate.matchedTerms)) {
        $text = [string]$value
        $focusValues = New-Object System.Collections.Generic.List[string]
        if ($text -match '(?i)\.(java|kt|kts|xml|ts|tsx|js|jsx|vue|sql)$') {
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($text)
            if (-not [string]::IsNullOrWhiteSpace($baseName)) { $focusValues.Add($baseName) | Out-Null }
        }
        $focusValues.Add($text) | Out-Null
        foreach ($focusValue in $focusValues) {
            $key = ([string]$focusValue).ToLowerInvariant()
            if (-not [string]::IsNullOrWhiteSpace([string]$focusValue) -and -not $seen.ContainsKey($key)) {
                $items.Add([PSCustomObject]@{ Value = $focusValue; Priority = (Get-DynamicProjectFocusTermPriority $focusValue); Order = $order }) | Out-Null
                $seen[$key] = $true
                $order++
            }
        }
    }
    foreach ($term in @($Terms)) {
        $value = [string]$term.value
        $focusValues = New-Object System.Collections.Generic.List[string]
        if ($value -match '(?i)\.(java|kt|kts|xml|ts|tsx|js|jsx|vue|sql)$') {
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($value)
            if (-not [string]::IsNullOrWhiteSpace($baseName)) { $focusValues.Add($baseName) | Out-Null }
        }
        $focusValues.Add($value) | Out-Null
        foreach ($focusValue in $focusValues) {
            $key = ([string]$focusValue).ToLowerInvariant()
            if (-not [string]::IsNullOrWhiteSpace([string]$focusValue) -and -not $seen.ContainsKey($key)) {
                $items.Add([PSCustomObject]@{ Value = $focusValue; Priority = (Get-DynamicProjectFocusTermPriority $focusValue); Order = $order }) | Out-Null
                $seen[$key] = $true
                $order++
            }
        }
    }
    return @($items |
        Sort-Object @{ Expression = "Priority"; Descending = $false }, @{ Expression = "Order"; Descending = $false } |
        Select-Object -First 28 |
        ForEach-Object { $_.Value })
}

function Get-DynamicProjectFocusTermPriority([string]$Value) {
    $v = [string]$Value
    if ($v -match '[$#]\{') { return 0 }
    if ($v -match '\.') { return 5 }
    if ($v -cmatch '^[A-Z][A-Za-z0-9_]*-[A-Z][A-Za-z0-9_]*') { return 0 }
    if ($v -cmatch '^[a-z][A-Za-z0-9_]*[A-Z][A-Za-z0-9_]*$') { return 1 }
    if ($v -cmatch '^[a-z][A-Za-z0-9_]{2,}$') { return 2 }
    if ($v -cmatch '^[a-z][a-z0-9]+(?:-[a-z0-9]+)+$') { return 4 }
    if ($v -match '(?i)(Service|ServiceImpl|Controller|Mapper|Repository|Dao|DTO|VO|Request|Response|Util|Utils)$') { return 4 }
    return 3
}

function Add-LineRange($Ranges, [int]$Start, [int]$End, [int]$Priority) {
    if ($End -lt $Start) { return }
    $Ranges.Add([PSCustomObject]@{ Start = $Start; End = $End; Priority = $Priority }) | Out-Null
}

function Merge-LineRanges($Ranges) {
    $merged = New-Object System.Collections.Generic.List[object]
    $sorted = @($Ranges | Sort-Object @{ Expression = "Start"; Descending = $false }, @{ Expression = "End"; Descending = $false })
    foreach ($range in $sorted) {
        if ($merged.Count -eq 0) {
            $merged.Add([PSCustomObject]@{ Start = [int]$range.Start; End = [int]$range.End; Priority = [int]$range.Priority }) | Out-Null
            continue
        }

        $last = $merged[$merged.Count - 1]
        if ([int]$range.Start -le ([int]$last.End + 2)) {
            if ([int]$range.End -gt [int]$last.End) { $last.End = [int]$range.End }
            if ([int]$range.Priority -lt [int]$last.Priority) { $last.Priority = [int]$range.Priority }
        } else {
            $merged.Add([PSCustomObject]@{ Start = [int]$range.Start; End = [int]$range.End; Priority = [int]$range.Priority }) | Out-Null
        }
    }
    return @($merged.ToArray())
}

function Get-FocusedProjectSnippet([string]$Path, $Candidate, $Terms, [int]$MaxChars) {
    $raw = Read-ProjectFileText $Path
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [PSCustomObject]@{ Text = ""; Mode = "empty"; FocusTerms = @() }
    }
    if ($raw.Length -le $MaxChars) {
        return [PSCustomObject]@{ Text = $raw; Mode = "whole-small-business-file"; FocusTerms = @() }
    }

    $focusTerms = @(Get-DynamicProjectFocusTerms $Candidate $Terms |
        Where-Object { -not (Test-DynamicProjectNoiseTerm $_) } |
        Select-Object -First 24)
    $lines = @($raw -split "`r?`n", 0, "RegexMatch")
    if ($lines.Count -eq 0) {
        return [PSCustomObject]@{ Text = (Get-TextPrefix $raw $MaxChars); Mode = "prefix"; FocusTerms = $focusTerms }
    }

    $businessEvidence = New-Object System.Collections.Generic.List[string]
    for ($lineIndex = 0; $lineIndex -lt $lines.Count -and $businessEvidence.Count -lt 36; $lineIndex++) {
        $line = [string]$lines[$lineIndex]
        if ($line -match '[가-힣]{2,}|(?i)<(?:select|insert|update|delete|resultMap)\b|\b(property|column|parameterType|resultType|jobParameter)\b|\b(?:TB|TBL|VW|V)_[A-Z0-9_]{3,}\b|\b(?:SELECT|INSERT|UPDATE|DELETE|MERGE|FROM|INTO|JOIN)\b|@(?:Schema|Column|ApiModelProperty)|#\{[^}]+\}|^\s*(?:private|protected|public)\s+(?:final\s+)?[A-Za-z0-9_<>,.?\[\]]+\s+[A-Za-z_][A-Za-z0-9_]*\s*(?:[;=])') {
            $businessEvidence.Add(("{0,5}: {1}" -f ($lineIndex + 1), $line)) | Out-Null
        }
    }
    $evidenceBlock = ""
    if ($businessEvidence.Count -gt 0) {
        $evidenceBlock = "... business evidence index (comments/table/column/field/parameter) ...`n" + ($businessEvidence -join "`n") + "`n"
        $evidenceBlock = Get-TextPrefix $evidenceBlock ([Math]::Max(800, [int]($MaxChars * 0.35)))
    }

    $ranges = New-Object System.Collections.Generic.List[object]
    $hits = 0
    $termInfos = @($focusTerms | ForEach-Object {
        $termText = [string]$_
        [PSCustomObject]@{
            Lower = $termText.ToLowerInvariant()
            Priority = Get-DynamicProjectFocusTermPriority $termText
        }
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Lower) })
    for ($i = 0; $i -lt $lines.Count -and $hits -lt 18; $i++) {
        $lineLower = ([string]$lines[$i]).ToLowerInvariant()
        foreach ($termInfo in $termInfos) {
            if ($lineLower.Contains([string]$termInfo.Lower)) {
                Add-LineRange $ranges ([Math]::Max(0, $i - 10)) ([Math]::Min($lines.Count - 1, $i + 18)) ([int]$termInfo.Priority)
                $hits++
                break
            }
        }
    }

    $parts = New-Object System.Collections.Generic.List[string]
    $used = 0
    if (-not [string]::IsNullOrWhiteSpace($evidenceBlock)) {
        $parts.Add($evidenceBlock) | Out-Null
        $used += $evidenceBlock.Length
    }
    if ($ranges.Count -eq 0) {
        $remaining = $MaxChars - $used
        if ($remaining -gt 120) {
            $parts.Add("... file prefix (no focus-term hit) ...`n$(Get-TextPrefix $raw $remaining)") | Out-Null
        }
        return [PSCustomObject]@{
            Text = (($parts -join "`n").TrimEnd())
            Mode = if ([string]::IsNullOrWhiteSpace($evidenceBlock)) { "prefix-no-term-hit" } else { "business-evidence-prefix-no-term-hit" }
            FocusTerms = $focusTerms
        }
    }
    $orderedRanges = @(Merge-LineRanges $ranges | Sort-Object @{ Expression = "Priority"; Descending = $false }, @{ Expression = "Start"; Descending = $false })
    foreach ($range in $orderedRanges) {
        $header = "... lines $([int]$range.Start + 1)-$([int]$range.End + 1) ...`n"
        $snippetLines = New-Object System.Collections.Generic.List[string]
        for ($lineNo = [int]$range.Start; $lineNo -le [int]$range.End; $lineNo++) {
            $snippetLines.Add(("{0,5}: {1}" -f ($lineNo + 1), $lines[$lineNo])) | Out-Null
        }
        $block = $header + ($snippetLines -join "`n") + "`n"
        if (($used + $block.Length) -gt $MaxChars) {
            $remaining = $MaxChars - $used
            if ($remaining -gt 120) {
                $parts.Add((Get-TextPrefix $block $remaining)) | Out-Null
            }
            break
        }
        $parts.Add($block) | Out-Null
        $used += $block.Length
    }

    return [PSCustomObject]@{
        Text = (($parts -join "`n").TrimEnd())
        Mode = "focused-line-window"
        FocusTerms = $focusTerms
    }
}

function Add-DynamicExpansionTerm($Terms, [string]$Value, [string]$Kind, [int]$Weight) {
    if ([string]$Value -match '(?i)^(Controller|Service|ServiceImpl|Mapper|Repository|Dao|Request|Response|Provider|Store|Util|Utils|GetResponse|HttpWebRequest|Tasklet|Job|Step|Decider|Listener|DTO|VO|Entity|Model|execute|run|process|handle|start|finish|before|after|main)$') { return }
    Add-DynamicProjectSearchTerm $Terms $Value $Kind $Weight
}

function Get-DynamicProjectExpansionTerms($Selected, [string]$Root, $ExistingTerms) {
    $terms = @{}
    $existing = @{}
    foreach ($term in @($ExistingTerms)) {
        $existingKey = ([string]$term.value).ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace($existingKey)) {
            $existing[$existingKey] = $true
        }
    }

    foreach ($item in @($Selected | Select-Object -First 5)) {
        if ([string]$item.extension -eq ".md") { continue }

        $raw = Read-ProjectFileText $item.fullName
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }

        foreach ($match in [regex]::Matches($raw, '(?m)^\s*import\s+(?:static\s+)?([A-Za-z_][A-Za-z0-9_.]*)(?:\.[A-Za-z_][A-Za-z0-9_]*)?\s*;')) {
            $full = $match.Groups[1].Value
            if ($full -match '^(java|javax|jakarta|kotlin|org\.springframework|org\.slf4j|lombok)\.') { continue }
            $simple = ($full -split '\.')[-1]
            Add-DynamicExpansionTerm $terms $simple "import" 72
            Add-DynamicExpansionTerm $terms "$simple.java" "import-file" 78
        }

        foreach ($match in [regex]::Matches($raw, '(?m)\b(?:from|require)\s*\(?\s*[''"]([^''"]+)[''"]')) {
            $importPath = $match.Groups[1].Value
            $leaf = (($importPath -replace '\\', '/') -split '/')[-1]
            if (-not [string]::IsNullOrWhiteSpace($leaf) -and -not $leaf.StartsWith(".")) {
                Add-DynamicExpansionTerm $terms $leaf "import" 65
            }
        }

        foreach ($match in [regex]::Matches($raw, '(?i)\b(?:id|refid)\s*=\s*["'']([^"'']{2,100})["'']')) {
            Add-DynamicExpansionTerm $terms $match.Groups[1].Value "xml-id" 82
        }

        foreach ($match in [regex]::Matches($raw, '(?i)\b(?:parameterType|resultType|resultMap|type)\s*=\s*["'']([^"'']{3,140})["'']')) {
            $typeValue = $match.Groups[1].Value
            Add-DynamicExpansionTerm $terms (($typeValue -split '\.')[-1]) "data-contract-type" 96
        }

        foreach ($match in [regex]::Matches($raw, '(?i)\b(?:property|column)\s*=\s*["'']([^"'']{2,100})["'']')) {
            Add-DynamicExpansionTerm $terms $match.Groups[1].Value "property-column" 92
        }

        foreach ($match in [regex]::Matches($raw, '\b(?:TB|TBL|VW|V)_[A-Z0-9_]{3,}\b')) {
            Add-DynamicExpansionTerm $terms $match.Value "business-table" 104
        }

        foreach ($match in [regex]::Matches($raw, '[$#]\{([^}]{1,80})\}')) {
            Add-DynamicExpansionTerm $terms $match.Groups[1].Value "business-parameter" 98
        }

        $family = Get-BusinessFamilyKeyFromPath ([string]$item.path)
        if (-not [string]::IsNullOrWhiteSpace($family)) { Add-DynamicExpansionTerm $terms $family "business-family" 115 }

        foreach ($match in [regex]::Matches($raw, '\b[A-Z][A-Za-z0-9_]{3,90}\b')) {
            $value = $match.Value
            if ($value -match '(Service|ServiceImpl|Mapper|Repository|Dao|DAO|Controller|Util|Utils|Vo|VO|Dto|DTO|Request|Response|Provider|Store)$') {
                Add-DynamicExpansionTerm $terms $value "symbol-ref" 58
            }
        }

        foreach ($match in [regex]::Matches($raw, '\b([a-z][A-Za-z0-9_]{2,80})\s*\(')) {
            $value = $match.Groups[1].Value
            if ($value -match '(?i)^(get|set|is|toString|equals|hashCode|size|add|put|trim|substring|if|for|while|switch|catch|return|throw|this|super|execute|run|process|handle|start|finish|before|after|main)$') { continue }
            Add-DynamicExpansionTerm $terms $value "call-ref" 38
        }
    }

    return @($terms.Values |
        Where-Object {
            $candidateKey = ([string]$_.value).ToLowerInvariant()
            -not [string]::IsNullOrWhiteSpace($candidateKey) -and -not $existing.ContainsKey($candidateKey)
        } |
        Sort-Object @{ Expression = "weight"; Descending = $true }, @{ Expression = "value"; Descending = $false } |
        Select-Object -First 36)
}

function Add-DynamicProjectReason($Reasons, [string]$Reason) {
    if (-not [string]::IsNullOrWhiteSpace($Reason) -and -not $Reasons.Contains($Reason)) { $Reasons.Add($Reason) | Out-Null }
}

function Get-DynamicProjectCandidateScore($File, [string]$Root, $Terms, [string]$QuestionLower) {
    $relative = Get-ProjectRelativePath $Root $File.FullName
    $relLower = $relative.ToLowerInvariant()
    $nameLower = $File.Name.ToLowerInvariant()
    $baseLower = [System.IO.Path]::GetFileNameWithoutExtension($File.Name).ToLowerInvariant()
    $score = 0
    $reasons = New-Object System.Collections.Generic.List[string]
    $matchedTerms = New-Object System.Collections.Generic.List[string]
    $content = $null
    $contentLower = $null

    foreach ($term in $Terms) {
        $termValue = [string]$term.value
        $termLower = $termValue.ToLowerInvariant()
        $termBaseLower = [System.IO.Path]::GetFileNameWithoutExtension($termValue).ToLowerInvariant()
        $termWeight = [Math]::Max(1, [int]$term.weight)
        $matched = $false

        if ($nameLower -eq $termLower -or $baseLower -eq $termLower -or $baseLower -eq $termBaseLower) {
            $score += [int]($termWeight * 2.4)
            Add-DynamicProjectReason $reasons "name:$termValue"
            $matched = $true
        } elseif ($relLower.Contains($termLower) -or $relLower.Contains($termBaseLower)) {
            $score += [int]($termWeight * 1.6)
            Add-DynamicProjectReason $reasons "path:$termValue"
            $matched = $true
        }

        if (-not $matched) {
            if ($null -eq $contentLower) {
                $content = Read-ProjectFilePrefix $File.FullName ([Math]::Max($DynamicProjectContextMaxFileChars, 6000))
                $contentLower = ([string]$content).ToLowerInvariant()
            }
            if ($contentLower.Contains($termLower)) {
                $score += [int]($termWeight * 0.8)
                Add-DynamicProjectReason $reasons "content:$termValue"
                $matched = $true
            }
        }

        if ($matched -and -not $matchedTerms.Contains($termValue)) { $matchedTerms.Add($termValue) | Out-Null }
    }

    $hasTermMatch = $score -gt 0
    if ($hasTermMatch -and $QuestionLower -match 'mapper|mybatis|sql' -and ($relLower -match 'mapper|mybatis|sql' -or $File.Extension.ToLowerInvariant() -eq ".xml")) {
        $score += 25
        Add-DynamicProjectReason $reasons "stack:mapper/sql"
    }
    if ($hasTermMatch -and $QuestionLower -match '\bvo\b|dto|request|response|validation|@valid|validated' -and ($relLower -match '(vo|dto|request|response)' -or $nameLower -match '(vo|dto|request|response)')) {
        $score += 25
        Add-DynamicProjectReason $reasons "stack:vo/dto/validation"
    }
    if ($hasTermMatch -and $QuestionLower -match 'controller|endpoint|route' -and $relLower -match 'controller|routes|pages|app') {
        $score += 20
        Add-DynamicProjectReason $reasons "stack:controller/route"
    }
    if ($hasTermMatch -and $QuestionLower -match 'service|transaction|rollback' -and $relLower -match 'service') {
        $score += 20
        Add-DynamicProjectReason $reasons "stack:service"
    }

    return [PSCustomObject]@{
        path = $relative
        fullName = $File.FullName
        extension = $File.Extension
        sizeBytes = [int64]$File.Length
        score = $score
        reasons = @($reasons)
        matchedTerms = @($matchedTerms)
        businessFamilyKey = Get-BusinessFamilyKeyFromPath $relative
        businessRole = if ($nameLower -match '(vo|dto|entity|model|request|response)\.(java|kt|ts|tsx)$') { "domain-model" } elseif ($nameLower -match '(mapper|repository|dao)\.(java|kt|xml)$' -or $File.Extension.ToLowerInvariant() -eq ".sql") { "db-sql" } elseif ($nameLower -match '(tasklet|job|step|decider)\.(java|kt)$') { "batch-process" } elseif ($nameLower -match 'service\.(java|kt)$') { "service-domain" } elseif ($nameLower -match '(controller|resource)\.(java|kt)$') { "api-boundary" } else { "code" }
    }
}

function Select-DynamicBusinessContextCandidates($Candidates, [int]$Limit) {
    $ranked = @($Candidates | Sort-Object @{ Expression = "score"; Descending = $true }, @{ Expression = "sizeBytes"; Descending = $false })
    if ($ranked.Count -eq 0 -or $Limit -lt 1) { return @() }
    $selected = New-Object System.Collections.Generic.List[object]
    $paths = @{}
    $anchor = $ranked[0]
    $selected.Add($anchor) | Out-Null
    $paths[[string]$anchor.path] = $true
    $family = [string]$anchor.businessFamilyKey
    if (-not [string]::IsNullOrWhiteSpace($family)) {
        foreach ($role in @("db-sql", "domain-model", "batch-process", "service-domain", "api-boundary", "code")) {
            if ($selected.Count -ge $Limit) { break }
            $item = @($ranked | Where-Object { [string]$_.businessFamilyKey -eq $family -and [string]$_.businessRole -eq $role -and -not $paths.ContainsKey([string]$_.path) } | Select-Object -First 1)[0]
            if ($item) { $selected.Add($item) | Out-Null; $paths[[string]$item.path] = $true }
        }
    }
    foreach ($item in $ranked) {
        if ($selected.Count -ge $Limit) { break }
        if (-not $paths.ContainsKey([string]$item.path)) { $selected.Add($item) | Out-Null; $paths[[string]$item.path] = $true }
    }
    return @($selected.ToArray())
}

function Add-DynamicProjectSelectedTermHits($Selected, $Terms, $MatchedTermSet) {
    foreach ($item in @($Selected)) {
        $pathLower = ([string]$item.path).ToLowerInvariant()
        $nameLower = ([System.IO.Path]::GetFileName([string]$item.path)).ToLowerInvariant()
        $baseLower = [System.IO.Path]::GetFileNameWithoutExtension($nameLower).ToLowerInvariant()
        $contentLower = $null

        foreach ($term in @($Terms)) {
            $termValue = [string]$term.value
            if ([string]::IsNullOrWhiteSpace($termValue)) { continue }

            $termLower = $termValue.ToLowerInvariant()
            $termBaseLower = [System.IO.Path]::GetFileNameWithoutExtension($termValue).ToLowerInvariant()
            $matched = (
                $nameLower -eq $termLower -or
                $baseLower -eq $termLower -or
                $baseLower -eq $termBaseLower -or
                $pathLower.Contains($termLower) -or
                $pathLower.Contains($termBaseLower)
            )

            if (-not $matched) {
                if ($null -eq $contentLower) {
                    $contentLower = (Read-ProjectFileText $item.fullName).ToLowerInvariant()
                }
                $matched = $contentLower.Contains($termLower)
            }

            if ($matched) { $MatchedTermSet[$termValue] = $true }
        }
    }
}

function Build-DynamicProjectContext([string]$Root, [string]$Question, [string]$LastTurn, [string]$PreferredBusinessFamily = "") {
    $preferredFamily = ([string]$PreferredBusinessFamily).Trim().ToLowerInvariant()
    $empty = [PSCustomObject]@{
        text = ""
        terms = @()
        files = @()
        missingTerms = @()
        preferredBusinessFamily = $preferredFamily
        error = ""
    }
    if ([string]::IsNullOrWhiteSpace($Root) -or $DynamicProjectContextMaxFiles -eq 0) { return $empty }

    try {
        $terms = @(Get-DynamicProjectSearchTerms $Question $LastTurn)
        if ($terms.Count -eq 0) { return $empty }

        $files = @(Get-ProjectCandidateFiles $Root)
        $scored = New-Object System.Collections.Generic.List[object]
        $matchedTermSet = @{}
        $questionLower = ([string]$Question).ToLowerInvariant()

        foreach ($file in $files) {
            try {
                $candidate = Get-DynamicProjectCandidateScore $file $Root $terms $questionLower
                $sameBusinessFamily = [string]::IsNullOrWhiteSpace($preferredFamily) -or ([string]$candidate.businessFamilyKey -eq $preferredFamily)
                if ($candidate.score -gt 0 -and $sameBusinessFamily) {
                    foreach ($term in $candidate.matchedTerms) { $matchedTermSet[[string]$term] = $true }
                    $scored.Add($candidate) | Out-Null
                }
            } catch { }
        }

        $initialLimit = [Math]::Max(1, [Math]::Min($DynamicProjectContextMaxFiles, [int][Math]::Ceiling($DynamicProjectContextMaxFiles * 0.65)))
        $selected = @(Select-DynamicBusinessContextCandidates $scored $initialLimit)
        $selectedPathSet = @{}
        foreach ($item in $selected) {
            $selectedPathSet[[string]$item.path] = $true
            $item | Add-Member -NotePropertyName contextSource -NotePropertyValue "direct-question-match" -Force
        }

        $expansionTerms = @(Get-DynamicProjectExpansionTerms $selected $Root $terms)
        $expanded = @()
        if ($expansionTerms.Count -gt 0 -and $selected.Count -lt $DynamicProjectContextMaxFiles) {
            $expandedScored = New-Object System.Collections.Generic.List[object]
            foreach ($file in $files) {
                try {
                    $candidate = Get-DynamicProjectCandidateScore $file $Root $expansionTerms $questionLower
                    $sameBusinessFamily = [string]::IsNullOrWhiteSpace($preferredFamily) -or ([string]$candidate.businessFamilyKey -eq $preferredFamily)
                    if ($candidate.score -gt 0 -and $sameBusinessFamily -and -not $selectedPathSet.ContainsKey([string]$candidate.path)) {
                        $candidate | Add-Member -NotePropertyName contextSource -NotePropertyValue "linked-reference-expansion" -Force
                        $expandedScored.Add($candidate) | Out-Null
                    }
                } catch { }
            }

            $remainingSlots = $DynamicProjectContextMaxFiles - $selected.Count
            $expanded = @(Select-DynamicBusinessContextCandidates $expandedScored $remainingSlots)
            if ($expanded.Count -gt 0) {
                $combined = New-Object System.Collections.Generic.List[object]
                foreach ($item in $selected) { $combined.Add($item) | Out-Null }
                foreach ($item in $expanded) {
                    $combined.Add($item) | Out-Null
                    $selectedPathSet[[string]$item.path] = $true
                }
                $selected = @($combined.ToArray())
            }
        }

        Add-DynamicProjectSelectedTermHits $selected $terms $matchedTermSet

        $missing = @($terms | Where-Object { -not $matchedTermSet.ContainsKey([string]$_.value) } | Select-Object -First 16 | ForEach-Object { $_.value })
        $termText = (($terms | Select-Object -First 24 | ForEach-Object { "$($_.value)[$($_.kind)]" }) -join ", ")
        if ([string]::IsNullOrWhiteSpace($termText)) { $termText = "(none)" }
        $expansionTermText = (($expansionTerms | Select-Object -First 16 | ForEach-Object { "$($_.value)[$($_.kind)]" }) -join ", ")
        if ([string]::IsNullOrWhiteSpace($expansionTermText)) { $expansionTermText = "(none)" }

        $parts = New-Object System.Collections.Generic.List[string]
        $parts.Add("동적 프로젝트 컨텍스트(현재 질문 기준 best-effort 관련 파일 검색 + 연결 파일 확장)") | Out-Null
        if (-not [string]::IsNullOrWhiteSpace($preferredFamily)) {
            $parts.Add("- 현재 탐색 업무 패밀리 제한: $preferredFamily (다른 업무군/공통 기술 파일은 이번 컨텍스트에서 제외)") | Out-Null
        }
        $parts.Add("- 추출 검색어: $termText") | Out-Null
        $parts.Add("- 연결 확장 검색어(import/XML id/클래스 참조 기반): $expansionTermText") | Out-Null
        if ($missing.Count -gt 0) {
            $parts.Add("- 프로젝트에서 찾지 못한 검색어: $($missing -join ', ')") | Out-Null
        }
        if ($selected.Count -eq 0) {
            $parts.Add("- 관련 파일을 찾지 못했습니다. 없는 파일은 전송하지 않고 기존 스캔 컨텍스트만 사용합니다.") | Out-Null
        } else {
            $parts.Add("- 관련 파일 후보:") | Out-Null
            foreach ($item in $selected) {
                $reasonText = if ($item.reasons.Count -gt 0) { $item.reasons -join ", " } else { "term match" }
                $sourceText = if (-not [string]::IsNullOrWhiteSpace([string]$item.contextSource)) { "source=$($item.contextSource); " } else { "" }
                $parts.Add("  - [$($item.score)] $($item.path) :: $sourceText$reasonText") | Out-Null
            }
            $pivotCandidates = @($selected |
                Where-Object { [string]$_.contextSource -eq "linked-reference-expansion" } |
                Select-Object -First 5 |
                ForEach-Object { $_.path })
            if ($pivotCandidates.Count -gt 0) {
                $parts.Add("- 다음 질문 증거 힌트: 연결 파일($($pivotCandidates -join ', ')) 자체를 새 주제로 삼지 말고, 현재 미확인 업무 용어·상태·원천/대상 데이터·downstream을 검증하는 증거로 사용합니다.") | Out-Null
            } elseif ($selected.Count -gt 1) {
                $primaryPath = [string]$selected[0].path
                $relatedCandidates = @($selected |
                    Where-Object { [string]$_.path -ne $primaryPath } |
                    Select-Object -First 5 |
                    ForEach-Object { $_.path })
                if ($relatedCandidates.Count -gt 0) {
                    $parts.Add("- 다음 질문 증거 힌트: 보조 파일($($relatedCandidates -join ', '))은 파일 기술 구조가 아니라 현재 업무 가설과 데이터 의미를 교차 검증하는 데 사용합니다.") | Out-Null
                }
            }
        }
        $parts.Add("") | Out-Null

        $usedChars = ($parts -join "`n").Length
        foreach ($item in $selected) {
            try {
                $snippet = Get-FocusedProjectSnippet $item.fullName $item $terms $DynamicProjectContextMaxFileChars
                $excerpt = Get-TextPrefix ([string]$snippet.Text) $DynamicProjectContextMaxFileChars
                if ([string]::IsNullOrWhiteSpace($excerpt)) { continue }
                $block = @"
### $($item.path)
score=$($item.score); source=$($item.contextSource); excerptMode=$($snippet.Mode); reasons=$($item.reasons -join ", "); matchedTerms=$($item.matchedTerms -join ", "); focusTerms=$($snippet.FocusTerms -join ", ")
~~~text
$excerpt
~~~

"@
                if (($usedChars + $block.Length) -gt $DynamicProjectContextMaxTotalChars) { break }
                $parts.Add($block) | Out-Null
                $usedChars += $block.Length
            } catch {
                $parts.Add("### $($item.path)`n파일 내용을 읽지 못했습니다: $($_.Exception.Message)`n") | Out-Null
            }
        }

        return [PSCustomObject]@{
            text = (($parts -join "`n") + "`n")
            terms = @($terms | ForEach-Object { [ordered]@{ value = $_.value; kind = $_.kind; weight = $_.weight } })
            expansionTerms = @($expansionTerms | ForEach-Object { [ordered]@{ value = $_.value; kind = $_.kind; weight = $_.weight } })
            files = @($selected | ForEach-Object {
                [ordered]@{
                    path = $_.path
                    score = $_.score
                    source = $_.contextSource
                    reasons = $_.reasons
                    matchedTerms = $_.matchedTerms
                    businessFamilyKey = $_.businessFamilyKey
                }
            })
            missingTerms = $missing
            preferredBusinessFamily = $preferredFamily
            error = ""
        }
    } catch {
        return [PSCustomObject]@{
            text = "동적 프로젝트 컨텍스트 생성 중 오류가 있었지만 루프는 계속 진행합니다: $($_.Exception.Message)`n"
            terms = @()
            files = @()
            missingTerms = @()
            preferredBusinessFamily = $preferredFamily
            error = [string]$_.Exception.Message
        }
    }
}

function Get-PromptContextExcerptPaths([string]$Text, [int]$Limit) {
    $paths = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Text) -or $Limit -eq 0) { return @() }

    $seen = @{}
    foreach ($match in [regex]::Matches($Text, '(?m)^###\s+(.+?)\s*$')) {
        $path = ([string]$match.Groups[1].Value).Trim()
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if ($seen.ContainsKey($path)) { continue }
        $seen[$path] = $true
        $paths.Add($path) | Out-Null
        if ($Limit -gt 0 -and $paths.Count -ge $Limit) { break }
    }

    return @($paths.ToArray())
}

function Write-PromptPathList([string]$Label, $Items, [int]$Limit) {
    $list = @($Items | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($list.Count -eq 0) { return }

    Write-Host "$Label ($($list.Count)):" -ForegroundColor DarkCyan
    $shown = 0
    foreach ($item in $list) {
        if ($Limit -gt 0 -and $shown -ge $Limit) { break }
        Write-Host "  - $item"
        $shown++
    }
    if ($Limit -gt 0 -and $list.Count -gt $shown) {
        Write-Host "  - ... +$($list.Count - $shown) more" -ForegroundColor DarkGray
    }
}

function Add-PromptSnippetSource($Rows, $Index, [string]$Path, [string]$Source) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if ([string]::IsNullOrWhiteSpace($Source)) { $Source = "snippet" }

    if (-not $Index.ContainsKey($Path)) {
        $sources = New-Object System.Collections.Generic.List[string]
        $sources.Add($Source) | Out-Null
        $row = [PSCustomObject]@{
            path = $Path
            sources = $sources
        }
        $Rows.Add($row) | Out-Null
        $Index[$Path] = $row
        return
    }

    $existing = $Index[$Path]
    if (-not $existing.sources.Contains($Source)) {
        $existing.sources.Add($Source) | Out-Null
    }
}

function Get-DynamicPromptFileSourceMap($DynamicProjectContext) {
    $map = @{}
    if ($null -eq $DynamicProjectContext -or -not $DynamicProjectContext.files) { return $map }

    foreach ($file in @($DynamicProjectContext.files)) {
        $path = [string]$file.path
        if ([string]::IsNullOrWhiteSpace($path) -or $map.ContainsKey($path)) { continue }

        $source = [string]$file.source
        if ($source -eq "linked-reference-expansion") {
            $map[$path] = "dynamic linked"
        } elseif ($source -eq "direct-question-match") {
            $map[$path] = "dynamic direct"
        } elseif (-not [string]::IsNullOrWhiteSpace($source)) {
            $map[$path] = "dynamic $source"
        } else {
            $map[$path] = "dynamic"
        }
    }

    return $map
}

function Write-ProjectPromptFileSummary($ProjectScan, $DynamicProjectContext) {
    if ($null -eq $ProjectScan) { return }

    $snippetRows = New-Object System.Collections.Generic.List[object]
    $snippetIndex = @{}
    $dynamicSourceMap = Get-DynamicPromptFileSourceMap $DynamicProjectContext

    $dynamicExcerptPaths = @()
    if ($DynamicProjectContext -and -not [string]::IsNullOrWhiteSpace([string]$DynamicProjectContext.text)) {
        $dynamicExcerptPaths = @(Get-PromptContextExcerptPaths ([string]$DynamicProjectContext.text) -1)
    }
    foreach ($path in $dynamicExcerptPaths) {
        $source = if ($dynamicSourceMap.ContainsKey($path)) { [string]$dynamicSourceMap[$path] } else { "dynamic" }
        Add-PromptSnippetSource $snippetRows $snippetIndex $path $source
    }

    $baseExcerptPaths = @(Get-PromptContextExcerptPaths ([string]$ProjectScan.promptContext) -1)
    foreach ($path in $baseExcerptPaths) {
        Add-PromptSnippetSource $snippetRows $snippetIndex $path "base"
    }

    Write-Host "`nPROMPT SNIPPETS SENT:" -ForegroundColor DarkCyan
    if ($snippetRows.Count -eq 0) {
        Write-Host "  - none" -ForegroundColor DarkGray
    } else {
        $shown = 0
        $limit = 24
        foreach ($row in $snippetRows) {
            if ($shown -ge $limit) { break }
            Write-Host "  - $($row.path) [$($row.sources -join ' + ')]"
            $shown++
        }
        if ($snippetRows.Count -gt $shown) {
            Write-Host "  - ... +$($snippetRows.Count - $shown) more" -ForegroundColor DarkGray
        }
    }

    $referencedRows = New-Object System.Collections.Generic.List[string]
    $referencedSeen = @{}
    $addReferencedOnly = {
        param([string]$Path, [string]$Label)
        if ([string]::IsNullOrWhiteSpace($Path)) { return }
        if ($snippetIndex.ContainsKey($Path) -or $referencedSeen.ContainsKey($Path)) { return }
        $referencedSeen[$Path] = $true
        if ([string]::IsNullOrWhiteSpace($Label)) {
            $referencedRows.Add($Path) | Out-Null
        } else {
            $referencedRows.Add("$Path [$Label]") | Out-Null
        }
    }

    $primaryLabel = if (-not [string]::IsNullOrWhiteSpace([string]$ProjectScan.primaryQuestionCandidateGroup)) { "primary; $($ProjectScan.primaryQuestionCandidateGroup)" } else { "primary" }
    & $addReferencedOnly ([string]$ProjectScan.primaryQuestionCandidateFile) $primaryLabel
    if ($ProjectScan.questionCandidateDetails) {
        foreach ($candidate in @($ProjectScan.questionCandidateDetails)) {
            $label = if (-not [string]::IsNullOrWhiteSpace([string]$candidate.questionGroupLabel)) { "candidate; $($candidate.questionGroupLabel)" } else { "candidate" }
            & $addReferencedOnly ([string]$candidate.path) $label
        }
    } elseif ($ProjectScan.questionCandidateFiles) {
        foreach ($path in @($ProjectScan.questionCandidateFiles)) {
            & $addReferencedOnly ([string]$path) "candidate"
        }
    }

    Write-PromptPathList "REFERENCED ONLY (no snippet block)" $referencedRows 10
    if ($DynamicProjectContext -and -not [string]::IsNullOrWhiteSpace([string]$DynamicProjectContext.error)) {
        Write-Host "Dynamic snippet lookup warning: $($DynamicProjectContext.error)" -ForegroundColor DarkGray
    }
}

function Select-ProjectQuestionCandidateSet($Items, [int]$Count, [int]$PoolSize, $ExistingPaths) {
    $items = @($Items | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.path) })
    if ($items.Count -eq 0 -or $Count -lt 1) { return @() }
    if ($null -eq $ExistingPaths) { $ExistingPaths = @{} }

    $ranked = @($items | Sort-Object @{ Expression = "score"; Descending = $true }, @{ Expression = "sizeBytes"; Descending = $true }, @{ Expression = "path"; Descending = $false })
    $groups = @(Get-ProjectQuestionGroups $ranked)
    if ($groups.Count -eq 0) {
        $fallback = New-Object System.Collections.Generic.List[object]
        foreach ($file in $ranked) {
            if ($fallback.Count -ge $Count) { break }
            $path = [string]$file.path
            if (-not $ExistingPaths.ContainsKey($path)) {
                $fallback.Add($file) | Out-Null
                $ExistingPaths[$path] = $true
            }
        }
        return @($fallback.ToArray())
    }

    $remainingGroups = New-Object System.Collections.Generic.List[object]
    foreach ($group in $groups) { $remainingGroups.Add($group) | Out-Null }
    $selected = New-Object System.Collections.Generic.List[object]

    while ($selected.Count -lt $Count -and $remainingGroups.Count -gt 0) {
        $totalWeight = 0
        foreach ($group in $remainingGroups) { $totalWeight += [Math]::Max(1, [int]$group.groupWeight) }

        $roll = Get-Random -Minimum 1 -Maximum ($totalWeight + 1)
        $cursor = 0
        for ($i = 0; $i -lt $remainingGroups.Count; $i++) {
            $group = $remainingGroups[$i]
            $cursor += [Math]::Max(1, [int]$group.groupWeight)
            if ($roll -le $cursor) {
                $filePoolSize = [Math]::Max(3, [Math]::Min([Math]::Max($PoolSize, $Count), 12))
                $filePool = @($group.files | Where-Object { -not $ExistingPaths.ContainsKey([string]$_.path) } | Select-Object -First $filePoolSize)
                $file = Select-WeightedProjectFile $filePool
                if ($file) {
                    $selected.Add($file) | Out-Null
                    $ExistingPaths[[string]$file.path] = $true
                }
                $remainingGroups.RemoveAt($i)
                break
            }
        }
    }

    foreach ($file in $ranked) {
        if ($selected.Count -ge $Count) { break }
        if (-not $ExistingPaths.ContainsKey([string]$file.path)) {
            $selected.Add($file) | Out-Null
            $ExistingPaths[[string]$file.path] = $true
        }
    }

    return @($selected.ToArray())
}

function Get-ExplorationHistoryKey([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
    return (($Value -replace '\\', '/') -replace '/+', '/').Trim().ToLowerInvariant()
}

function Get-ProjectExplorationAvoidance([string]$HistoryPath, [int]$MaxRecords = 80) {
    $paths = @{}
    $groups = @{}
    $families = @{}
    $records = New-Object System.Collections.Generic.List[object]
    if (-not [string]::IsNullOrWhiteSpace($HistoryPath) -and (Test-Path -LiteralPath $HistoryPath -PathType Leaf)) {
        $lines = @(Get-Content -LiteralPath $HistoryPath -Encoding UTF8 -ErrorAction SilentlyContinue | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $start = [Math]::Max(0, $lines.Count - $MaxRecords)
        for ($i = $start; $i -lt $lines.Count; $i++) {
            try {
                $record = $lines[$i] | ConvertFrom-Json
                $records.Add($record) | Out-Null
                $pathKey = Get-ExplorationHistoryKey ([string]$record.primaryPath)
                $groupKey = Get-ExplorationHistoryKey ([string]$record.primaryGroupKey)
                $familyKey = Get-ExplorationHistoryKey ([string]$record.businessFamily)
                if ($pathKey) { $paths[$pathKey] = $true }
                if ($groupKey) { $groups[$groupKey] = $true }
                if ($familyKey) { $families[$familyKey] = $true }
            } catch { }
        }
    }
    $recent = @($records.ToArray() | Select-Object -Last 12 | ForEach-Object {
        $label = if (-not [string]::IsNullOrWhiteSpace([string]$_.businessFamily)) { [string]$_.businessFamily } elseif (-not [string]::IsNullOrWhiteSpace([string]$_.primaryGroupKey)) { [string]$_.primaryGroupKey } else { [string]$_.primaryPath }
        if (-not [string]::IsNullOrWhiteSpace($label)) { $label }
    })
    $recentFamilies = @{}
    foreach ($record in @($records.ToArray() | Select-Object -Last 4)) {
        $familyKey = Get-ExplorationHistoryKey ([string]$record.businessFamily)
        if ($familyKey) { $recentFamilies[$familyKey] = $true }
    }
    $lastRecord = @($records.ToArray() | Select-Object -Last 1)[0]
    $immediateFamily = if ($lastRecord) { Get-ExplorationHistoryKey ([string]$lastRecord.businessFamily) } else { "" }
    return [PSCustomObject]@{
        historyPath = $HistoryPath
        recordCount = $records.Count
        paths = $paths
        groups = $groups
        families = $families
        recentFamilies = $recentFamilies
        immediateFamily = $immediateFamily
        recentLabels = $recent
    }
}

function Add-ProjectExplorationHistory([string]$HistoryPath, $Scan, [string]$SessionId, [string]$Reason) {
    if ([string]::IsNullOrWhiteSpace($HistoryPath) -or $null -eq $Scan) { return }
    $record = [ordered]@{
        schema = "qwen-loop-project-exploration/v1"
        selectedAt = (Get-Date).ToString("o")
        projectRoot = $Scan.root
        sessionId = $SessionId
        cycle = $Scan.explorationCycle
        reason = $Reason
        primaryPath = $Scan.primaryQuestionCandidateFile
        primaryGroupKey = $Scan.primaryQuestionCandidateGroupKey
        primaryGroupLabel = $Scan.primaryQuestionCandidateGroup
        businessFamily = $Scan.primaryBusinessFamily
        candidatePaths = @($Scan.questionCandidateFiles)
    }
    Append-Utf8File $HistoryPath (($record | ConvertTo-Json -Compress -Depth 20) + "`n")
}

function Get-ProjectExplorationPhase([int]$Turn, [int]$TurnsPerCycle) {
    $safeTurns = [Math]::Max(1, $TurnsPerCycle)
    $safeTurn = [Math]::Max(1, [Math]::Min($Turn, $safeTurns))
    if ($safeTurn -eq 1) {
        return [PSCustomObject]@{ index = 1; key = "business-discovery"; label = "업무 발견"; instruction = "새 업무 슬라이스의 actor, trigger, precondition, 목적, 결과를 코드 근거로 가설화한다." }
    }
    if ($safeTurn -eq $safeTurns) {
        return [PSCustomObject]@{ index = 5; key = "business-report"; label = "업무 보고서"; instruction = "이 프로그램이 수행하는 업무를 결론 내리고 evidence/confidence/gaps 및 다음 탐색 후보를 정리한다." }
    }
    $middleIndex = [Math]::Min(4, [Math]::Max(2, 1 + [int][Math]::Ceiling((($safeTurn - 1) * 3.0) / [Math]::Max(1, $safeTurns - 1))))
    switch ($middleIndex) {
        2 { return [PSCustomObject]@{ index = 2; key = "business-data-contract"; label = "업무 용어·데이터 계약"; instruction = "Mapper XML의 statement/table/column/comment와 VO·DTO field/comment를 연결해 업무 용어와 데이터 의미를 확정한다." } }
        3 { return [PSCustomObject]@{ index = 3; key = "normal-process"; label = "정상 업무 프로세스"; instruction = "Tasklet·Controller에서 Service, Mapper, DB, downstream까지 정상 흐름과 상태 변화를 8~12단계로 추적한다." } }
        default { return [PSCustomObject]@{ index = 4; key = "cross-validation"; label = "업무 가설 교차 검증"; instruction = "다른 계층과 upstream/downstream 증거로 앞선 업무 가설을 확인 또는 반증하고 미확인 항목을 줄인다." } }
    }
}

function Get-CycleBusinessEvidenceExcerpt([string]$Answer, [int]$MaxChars = 1500) {
    if ([string]::IsNullOrWhiteSpace($Answer)) { return "" }
    $priority = New-Object System.Collections.Generic.List[string]
    $priority.Add("[opening conclusion] $(Get-TextPrefix (($Answer -replace '\s+', ' ').Trim()) 350)") | Out-Null
    foreach ($line in ($Answer -split "`r?`n")) {
        $trimmed = (Remove-BomAndTrim $line)
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed -match '^NEXT_QUESTION\s*[:：]') { continue }
        if ($trimmed -match '업무|목적|사용자|배치|입력|판단|상태|테이블|컬럼|필드|근거|사실|추론|미확인|정상|흐름|결과|용어|단계|원천|저장|소비|승인|확정|기준일|(?i)\b(actor|trigger|precondition|result|table|column|field|status|state|downstream|fact|inference|unknown)\b|\b(?:TB|TBL|VW|V)_[A-Z0-9_]{3,}\b|#\{[^}]+\}') {
            $priority.Add($trimmed) | Out-Null
        }
        if (($priority -join "`n").Length -ge $MaxChars) { break }
    }
    $text = ($priority -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { $text = Get-TextPrefix $Answer $MaxChars }
    return Get-TextPrefix $text $MaxChars
}

function Add-CycleEvidenceMemory([string]$Path, [int]$Cycle, [int]$Turn, [string]$Status, [string]$Question, [string]$Answer) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $excerpt = Get-CycleBusinessEvidenceExcerpt $Answer 1500
    if ([string]::IsNullOrWhiteSpace($excerpt)) { return }
    $block = "## cycle $Cycle / turn $Turn / $Status`nQuestion: $(Get-TextPrefix (($Question -replace '\s+', ' ').Trim()) 350)`nEvidence:`n$excerpt`n"
    $blocks = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $existing = Read-Utf8File $Path
        foreach ($existingBlock in @([regex]::Split($existing, '(?m)(?=^## cycle )') | Where-Object { $_ -match '^## cycle ' })) {
            $blocks.Add($existingBlock.Trim()) | Out-Null
        }
    }
    $blocks.Add($block.Trim()) | Out-Null
    $combined = "# Compact business evidence memory`n`n" + (($blocks.ToArray()) -join "`n`n") + "`n"
    while ($combined.Length -gt 9000 -and $blocks.Count -gt 1) {
        $blocks.RemoveAt(0)
        $combined = "# Compact business evidence memory`n`n" + (($blocks.ToArray()) -join "`n`n") + "`n"
    }
    Write-Utf8File $Path $combined
}

function Select-NovelProjectPrimary($Items, $Avoidance) {
    $all = @($Items | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.path) })
    if ($all.Count -eq 0) { return $null }
    $tiers = New-Object System.Collections.Generic.List[object]
    if ($Avoidance) {
        $tiers.Add(@($all | Where-Object {
            $pathKey = Get-ExplorationHistoryKey ([string]$_.path)
            $groupKey = Get-ExplorationHistoryKey ([string]$_.questionGroupKey)
            $familyKey = Get-ExplorationHistoryKey ([string]$_.businessFamilyKey)
            -not $Avoidance.paths.ContainsKey($pathKey) -and -not $Avoidance.groups.ContainsKey($groupKey) -and ([string]::IsNullOrWhiteSpace($familyKey) -or -not $Avoidance.families.ContainsKey($familyKey))
        })) | Out-Null
        if ($Avoidance.recentFamilies -and $Avoidance.recentFamilies.Count -gt 0) {
            $tiers.Add(@($all | Where-Object {
                $familyKey = Get-ExplorationHistoryKey ([string]$_.businessFamilyKey)
                -not $Avoidance.paths.ContainsKey((Get-ExplorationHistoryKey ([string]$_.path))) -and
                    ([string]::IsNullOrWhiteSpace($familyKey) -or -not $Avoidance.recentFamilies.ContainsKey($familyKey))
            })) | Out-Null
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$Avoidance.immediateFamily)) {
            $tiers.Add(@($all | Where-Object {
                $familyKey = Get-ExplorationHistoryKey ([string]$_.businessFamilyKey)
                -not $Avoidance.paths.ContainsKey((Get-ExplorationHistoryKey ([string]$_.path))) -and
                    ([string]::IsNullOrWhiteSpace($familyKey) -or $familyKey -ne [string]$Avoidance.immediateFamily)
            })) | Out-Null
        }
        $tiers.Add(@($all | Where-Object { -not $Avoidance.paths.ContainsKey((Get-ExplorationHistoryKey ([string]$_.path))) })) | Out-Null
        if (-not [string]::IsNullOrWhiteSpace([string]$Avoidance.immediateFamily)) {
            $tiers.Add(@($all | Where-Object {
                $familyKey = Get-ExplorationHistoryKey ([string]$_.businessFamilyKey)
                [string]::IsNullOrWhiteSpace($familyKey) -or $familyKey -ne [string]$Avoidance.immediateFamily
            })) | Out-Null
        }
    }
    $tiers.Add($all) | Out-Null

    foreach ($tier in $tiers) {
        $pool = @($tier)
        if ($pool.Count -eq 0) { continue }
        $groups = @(Get-ProjectQuestionGroups $pool)
        if ($groups.Count -eq 0) { return (Select-WeightedProjectFile ($pool | Select-Object -First 20)) }
        $businessGroups = @($groups | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.businessFamily) })
        if ($businessGroups.Count -gt 0) { $groups = $businessGroups }
        $group = $groups[(Get-Random -Minimum 0 -Maximum $groups.Count)]
        $evidenceFiles = @($group.files | Where-Object {
            [string]$_.questionGroupRole -in @("domain-model", "batch-process") -or ([string]$_.extension).ToLowerInvariant() -in @(".xml", ".sql")
        } | Select-Object -First 12)
        if ($evidenceFiles.Count -eq 0) { $evidenceFiles = @($group.files | Select-Object -First 12) }
        return (Select-WeightedProjectFile $evidenceFiles)
    }
    return $all[0]
}

function Select-ProjectQuestionCandidates($Files, [int]$Count, [int]$PoolSize, $Avoidance = $null) {
    $rawItems = @($Files | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.path) })
    $items = @($rawItems | Where-Object { Test-ProjectQuestionSeedCandidate $_ })
    if ($items.Count -eq 0) { $items = $rawItems }
    if ($items.Count -eq 0 -or $Count -lt 1) { return @() }

    $selectedPaths = @{}
    $selected = New-Object System.Collections.Generic.List[object]

    $primaryItems = @($items | Where-Object { Test-ProjectPrimaryQuestionSeedCandidate $_ })
    if ($primaryItems.Count -eq 0) { $primaryItems = $items }

    $primary = Select-NovelProjectPrimary $primaryItems $Avoidance
    if ($primary) {
        $selected.Add($primary) | Out-Null
        $selectedPaths[[string]$primary.path] = $true
    }

    $sliceItems = $items
    if ($primary) {
        $primaryFamily = ([string]$primary.businessFamilyKey).Trim().ToLowerInvariant()
        $primaryGroupKey = [string]$primary.questionGroupKey
        if (-not [string]::IsNullOrWhiteSpace($primaryFamily)) {
            $sliceItems = @($items | Where-Object { ([string]$_.businessFamilyKey).Trim().ToLowerInvariant() -eq $primaryFamily })
        } elseif (-not [string]::IsNullOrWhiteSpace($primaryGroupKey)) {
            $sliceItems = @($items | Where-Object { [string]$_.questionGroupKey -eq $primaryGroupKey })
        }
        if ($sliceItems.Count -eq 0) { $sliceItems = @($primary) }
    }

    # A business slice is assembled from different roles in the same family/group.
    if ($primary -and $selected.Count -lt $Count) {
        $sameGroup = @($sliceItems | Where-Object { -not $selectedPaths.ContainsKey([string]$_.path) })
        $roleOrder = @("domain-model", "db-sql", "batch-process", "service-domain", "api-boundary", "code")
        foreach ($role in $roleOrder) {
            if ($selected.Count -ge $Count) { break }
            $rolePool = @($sameGroup | Where-Object { [string]$_.questionGroupRole -eq $role } | Select-Object -First 12)
            $supportFile = Select-WeightedProjectFile $rolePool
            if ($supportFile -and -not $selectedPaths.ContainsKey([string]$supportFile.path)) {
                $selected.Add($supportFile) | Out-Null
                $selectedPaths[[string]$supportFile.path] = $true
            }
        }
    }

    $remainingCount = $Count - $selected.Count
    if ($remainingCount -gt 0) {
        $support = @(Select-ProjectQuestionCandidateSet $sliceItems $remainingCount $PoolSize $selectedPaths)
        foreach ($file in $support) { $selected.Add($file) | Out-Null }
    }

    return @($selected.ToArray())
}

function Test-ProjectScanBootstrapQuestion([string]$Question) {
    $q = ([string]$Question).Trim() -replace '\s+', ' '
    if ([string]::IsNullOrWhiteSpace($q)) { return $false }

    if ($q -match '^프로젝트 핵심 후보 파일\(.+\)을 바탕으로,') { return $true }
    if ($q -match '^이번 실행의 주 대상 파일은 .+입니다\. 반드시 이 파일을 중심으로') { return $true }
    if ($q -match '^이번 실행의 주 대상 구조 그룹은 .+이고, 주 대상 파일은 .+입니다\.') { return $true }
    if ($q -match '^이번 실행의 업무 도메인 탐색 출발점은 구조 그룹 .+, 주 대상 파일 .+입니다\.') { return $true }
    if ($q -match '^아래 프로젝트 스캔 결과의 핵심 파일과 코드 조각을 바탕으로,') { return $true }
    if ($q -match '^이전 실행에서 프로젝트 전체 핵심 후보를 고르는 초기 질문이 이미 전송됐지만 완료 기록이 없습니다\.') { return $true }
    if ($q -match '^이전 실행에서 프로젝트 스캔 기반 초기 질문이 이미 전송됐지만 완료 기록이 없습니다\.') { return $true }

    return $false
}

function New-ProjectScanContext([string]$Root, $Avoidance = $null, [int]$ExplorationCycle = 1) {
    if ([string]::IsNullOrWhiteSpace($Root)) { return $null }

    Assert-ProjectScanConfig
    $resolvedRoot = Resolve-ProjectRoot $Root
    $files = @(Get-ProjectCandidateFiles $resolvedRoot)
    $scored = New-Object System.Collections.Generic.List[object]

    foreach ($file in $files) {
        $content = Read-ProjectFilePrefix $file.FullName ([Math]::Max($ProjectScanMaxFileChars, 4000))
        $scoreItem = Get-ProjectFileScore $file $resolvedRoot $content
        if ($scoreItem.score -gt 0) {
            Set-ProjectQuestionGroup $scoreItem | Out-Null
            $scored.Add($scoreItem) | Out-Null
        }
    }

    $ranked = @($scored | Sort-Object @{ Expression = "score"; Descending = $true }, @{ Expression = "sizeBytes"; Descending = $true }, @{ Expression = "path"; Descending = $false })
    $selected = @(Select-ProjectScanContextFiles $ranked $ProjectScanMaxFiles)
    $stack = @(Get-DetectedProjectStack $files)
    $questionGroups = @(Get-ProjectQuestionGroups $ranked)
    $questionGroupSummaries = @($questionGroups | Select-Object -First 40 | ForEach-Object {
        [ordered]@{
            key = $_.key
            label = $_.label
            role = $_.role
            anchorPath = $_.anchorPath
            businessFamily = $_.businessFamily
            fileCount = $_.fileCount
            maxScore = $_.maxScore
            representativeFile = $_.representativeFile
            topFiles = @($_.files | Select-Object -First 5 | ForEach-Object { $_.path })
        }
    })
    $questionCandidates = @(Select-ProjectQuestionCandidates $ranked 7 80 $Avoidance)
    $primaryQuestionCandidate = if ($questionCandidates.Count -gt 0) { $questionCandidates[0] } else { $null }
    $primaryBusinessFamily = if ($primaryQuestionCandidate) { ([string]$primaryQuestionCandidate.businessFamilyKey).Trim().ToLowerInvariant() } else { "" }
    $primaryQuestionGroupKey = if ($primaryQuestionCandidate) { [string]$primaryQuestionCandidate.questionGroupKey } else { "" }

    $contextParts = New-Object System.Collections.Generic.List[string]
    $contextParts.Add("Project root: $resolvedRoot") | Out-Null
    $contextParts.Add("Detected stack: $($stack -join ', ')") | Out-Null
    $contextParts.Add("Scanned text files: $($files.Count); selected key files: $($selected.Count)") | Out-Null
    $contextParts.Add("Exploration cycle: $ExplorationCycle; recent project-specific selections excluded first: $(if ($Avoidance) { $Avoidance.recordCount } else { 0 })") | Out-Null
    $contextParts.Add("") | Out-Null
    $contextParts.Add("Diversity groups discovered from project structure:") | Out-Null
    if ($questionGroupSummaries.Count -gt 0) {
        foreach ($group in @($questionGroupSummaries | Select-Object -First 15)) {
            $contextParts.Add("- [$($group.maxScore), $($group.fileCount) files] $($group.label) :: representative $($group.representativeFile)") | Out-Null
        }
    } else {
        $contextParts.Add("- no diversity groups discovered") | Out-Null
    }
    $contextParts.Add("") | Out-Null
    $contextParts.Add("Primary question target for this startup:") | Out-Null
    if ($primaryQuestionCandidate) {
        $reasonText = if ($primaryQuestionCandidate.reasons.Count -gt 0) { $primaryQuestionCandidate.reasons -join ", " } else { "signal score" }
        $groupText = if (-not [string]::IsNullOrWhiteSpace([string]$primaryQuestionCandidate.questionGroupLabel)) { "group=$($primaryQuestionCandidate.questionGroupLabel); " } else { "" }
        $contextParts.Add("- [$($primaryQuestionCandidate.score)] $($primaryQuestionCandidate.path) :: $groupText$reasonText") | Out-Null
    } else {
        $contextParts.Add("- no primary target selected") | Out-Null
    }
    $contextParts.Add("") | Out-Null
    $contextParts.Add("Question candidate sample for this startup:") | Out-Null
    if ($questionCandidates.Count -gt 0) {
        foreach ($item in $questionCandidates) {
            $reasonText = if ($item.reasons.Count -gt 0) { $item.reasons -join ", " } else { "signal score" }
            $groupText = if (-not [string]::IsNullOrWhiteSpace([string]$item.questionGroupLabel)) { "group=$($item.questionGroupLabel); " } else { "" }
            $contextParts.Add("- [$($item.score)] $($item.path) :: $groupText$reasonText") | Out-Null
        }
    } else {
        $contextParts.Add("- no question candidates selected") | Out-Null
    }
    $contextParts.Add("") | Out-Null
    $contextParts.Add("Top key files:") | Out-Null

    foreach ($item in @($selected | Select-Object -First 25)) {
        $reasonText = if ($item.reasons.Count -gt 0) { $item.reasons -join ", " } else { "signal score" }
        $groupText = if (-not [string]::IsNullOrWhiteSpace([string]$item.questionGroupLabel)) { "group=$($item.questionGroupLabel); " } else { "" }
        $contextParts.Add("- [$($item.score)] $($item.path) :: $groupText$reasonText") | Out-Null
    }

    $contextParts.Add("") | Out-Null
    $contextParts.Add("Selected excerpts, with this startup's question candidates first:") | Out-Null
    $candidatePathSet = @{}
    $excerptItems = New-Object System.Collections.Generic.List[object]
    $excludedExcerptRoles = @("technical-core", "config-security", "config-data", "docs", "script-launcher", "script-main", "test", "entry-build")
    foreach ($item in $questionCandidates) {
        $sameSlice = if (-not [string]::IsNullOrWhiteSpace($primaryBusinessFamily)) {
            ([string]$item.businessFamilyKey).Trim().ToLowerInvariant() -eq $primaryBusinessFamily
        } elseif (-not [string]::IsNullOrWhiteSpace($primaryQuestionGroupKey)) {
            [string]$item.questionGroupKey -eq $primaryQuestionGroupKey
        } else { $true }
        $itemRole = [string]$item.questionGroupRole
        if ($sameSlice -and -not ($excludedExcerptRoles -contains $itemRole)) {
            $candidatePathSet[[string]$item.path] = $true
            $excerptItems.Add($item) | Out-Null
        }
    }
    foreach ($item in $selected) {
        $sameSlice = if (-not [string]::IsNullOrWhiteSpace($primaryBusinessFamily)) {
            ([string]$item.businessFamilyKey).Trim().ToLowerInvariant() -eq $primaryBusinessFamily
        } elseif (-not [string]::IsNullOrWhiteSpace($primaryQuestionGroupKey)) {
            [string]$item.questionGroupKey -eq $primaryQuestionGroupKey
        } else { $true }
        $itemRole = [string]$item.questionGroupRole
        if ($sameSlice -and -not ($excludedExcerptRoles -contains $itemRole) -and -not $candidatePathSet.ContainsKey([string]$item.path)) {
            $excerptItems.Add($item) | Out-Null
        }
    }
    $usedChars = ($contextParts -join "`n").Length
    foreach ($item in $excerptItems) {
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

    $seedQuestion = "프로젝트 탐색 주기 ${ExplorationCycle}의 새 업무 슬라이스를 시작한다. 코드 구조가 아니라 이 프로그램이 누가·언제·왜 수행하는 무슨 업무인지 먼저 복원해줘. Mapper XML의 statement/table/column/comment, VO·DTO의 field/comment, Tasklet·Job의 입력값과 정상 데이터 흐름을 교차 확인하고 확인된 사실·추론·미확인을 구분해줘. 기술 구현과 리스크는 업무 결과에 영향을 주는 범위에서 마지막 15~20%에만 다뤄줘."
    if ($primaryQuestionCandidate -and -not [string]::IsNullOrWhiteSpace([string]$primaryQuestionCandidate.path)) {
        $supportNames = (($questionCandidates | Select-Object -Skip 1 | ForEach-Object { $_.path }) -join ", ")
        if ([string]::IsNullOrWhiteSpace($supportNames)) { $supportNames = "없음" }
        $groupName = if (-not [string]::IsNullOrWhiteSpace([string]$primaryQuestionCandidate.questionGroupLabel)) { [string]$primaryQuestionCandidate.questionGroupLabel } else { "미분류 구조 그룹" }
        $familyName = if (-not [string]::IsNullOrWhiteSpace([string]$primaryQuestionCandidate.businessFamilyKey)) { [string]$primaryQuestionCandidate.businessFamilyKey } else { "미확인 업무군" }
        $seedQuestion = "프로젝트 탐색 주기 ${ExplorationCycle}의 새 업무 슬라이스는 $familyName, 출발 근거는 $($primaryQuestionCandidate.path)입니다. 파일 자체의 기술 구조를 설명하는 데 머물지 말고 누가·언제·왜 실행하여 어떤 업무 결과를 만드는지 복원해줘. 보조 증거 파일은 $supportNames 입니다. Mapper XML의 table/column/comment와 statement, VO·DTO field/comment, Tasklet·Job parameter, Service 호출을 연결하여 업무 용어 사전과 정상 데이터 lineage를 제시해줘. 답변은 업무 목적·actor/trigger/result, 업무 용어/상태, 정상 흐름 8~12단계, read/write 데이터와 downstream, 사실/추론/미확인 및 파일+identifier 근거 순서로 작성하고 기술 리스크는 마지막 15~20%에만 다뤄줘."
    } elseif ($selected.Count -gt 0) {
        $candidateNames = (($questionCandidates | ForEach-Object { $_.path }) -join ", ")
        $seedQuestion = "프로젝트 핵심 후보 파일($candidateNames)을 바탕으로, 이번 실행에서는 후보 중 하나를 새롭게 골라 실제 업무 도메인 또는 사용자 시나리오 하나의 정상 흐름, 주요 데이터/상태 이동, 다음에 확인해야 할 연결 파일, 마지막 리스크 점검 포인트를 구체적으로 분석해줘. 예외나 장애 가능성은 전체 주제가 아니라 마지막 점검 항목으로 다뤄줘."
    }

    return [PSCustomObject]@{
        root = $resolvedRoot
        generatedAt = (Get-Date).ToString("o")
        explorationCycle = $ExplorationCycle
        scannedFileCount = $files.Count
        selectedFileCount = $selected.Count
        detectedStack = $stack
        primaryQuestionCandidateFile = if ($primaryQuestionCandidate) { $primaryQuestionCandidate.path } else { "" }
        primaryQuestionCandidateGroup = if ($primaryQuestionCandidate) { $primaryQuestionCandidate.questionGroupLabel } else { "" }
        primaryQuestionCandidateGroupKey = if ($primaryQuestionCandidate) { $primaryQuestionCandidate.questionGroupKey } else { "" }
        primaryBusinessFamily = $primaryBusinessFamily
        questionGroupCount = $questionGroups.Count
        questionGroups = $questionGroupSummaries
        selectedFiles = @($selected | ForEach-Object {
            [ordered]@{
                path = $_.path
                extension = $_.extension
                sizeBytes = $_.sizeBytes
                score = $_.score
                reasons = $_.reasons
                questionGroupKey = $_.questionGroupKey
                questionGroupLabel = $_.questionGroupLabel
                questionGroupRole = $_.questionGroupRole
                questionGroupAnchorPath = $_.questionGroupAnchorPath
                businessFamilyKey = $_.businessFamilyKey
                excerptChars = ([string]$_.excerpt).Length
            }
        })
        questionCandidateFiles = @($questionCandidates | ForEach-Object { $_.path })
        questionCandidateDetails = @($questionCandidates | ForEach-Object {
            [ordered]@{
                path = $_.path
                score = $_.score
                reasons = $_.reasons
                questionGroupKey = $_.questionGroupKey
                questionGroupLabel = $_.questionGroupLabel
                questionGroupRole = $_.questionGroupRole
                questionGroupAnchorPath = $_.questionGroupAnchorPath
                businessFamilyKey = $_.businessFamilyKey
            }
        })
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

    $groupRows = @()
    foreach ($group in @($Scan.questionGroups | Select-Object -First 25)) {
        $groupRows += "| $($group.maxScore) | $($group.fileCount) | $($group.label) | $($group.representativeFile) |"
    }
    if ($groupRows.Count -eq 0) { $groupRows = @("|  |  | no diversity groups discovered |  |") }

    $questionCandidateRows = @()
    if ($Scan.questionCandidateDetails) {
        foreach ($candidate in @($Scan.questionCandidateDetails)) {
            $groupText = if (-not [string]::IsNullOrWhiteSpace([string]$candidate.questionGroupLabel)) { " / group: $($candidate.questionGroupLabel)" } else { "" }
            $questionCandidateRows += "- $($candidate.path) (score: $($candidate.score)$groupText)"
        }
    } else {
        $questionCandidateRows = @($Scan.questionCandidateFiles | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { "- $_" })
    }
    if ($questionCandidateRows.Count -eq 0) { $questionCandidateRows = @("- no question candidates selected") }

    $md = @"
# Project Scan Summary

- Root: $($Scan.root)
- Generated: $($Scan.generatedAt)
- Exploration cycle: $($Scan.explorationCycle)
- Detected stack: $($Scan.detectedStack -join ", ")
- Scanned files: $($Scan.scannedFileCount)
- Selected key files: $($Scan.selectedFileCount)
- Primary question target: $($Scan.primaryQuestionCandidateFile)
- Primary question group: $($Scan.primaryQuestionCandidateGroup)
- Primary business family: $($Scan.primaryBusinessFamily)
- Diversity groups: $($Scan.questionGroupCount)

## Key File Candidates

| Score | Path | Reasons | Size |
|---:|---|---|---:|
$($fileRows -join "`n")

## Diversity Groups

| Max Score | Files | Group | Representative |
|---:|---:|---|---|
$($groupRows -join "`n")

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
    if ([int]$Scan.explorationCycle -gt 0) {
        Write-Utf8File (Join-Path $WorkDirPath ("project_scan_cycle_{0:D3}.md" -f [int]$Scan.explorationCycle)) $md
        Write-Utf8File (Join-Path $WorkDirPath ("project_scan_cycle_{0:D3}.json" -f [int]$Scan.explorationCycle)) ($Scan | ConvertTo-Json -Depth 50)
    }
}

function Get-NextQuestionExtraction([string]$content, [int]$MaxQuestionChars = 1500) {
    $lines = @($content -split "`r?`n" | ForEach-Object { Remove-BomAndTrim $_ } | Where-Object { $_ -ne "" })
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $line = [string]$lines[$i]
        if ($line -match '^NEXT_QUESTION\s*[:：]\s*(.*)$') {
            $question = $Matches[1].Trim()
            if (-not [string]::IsNullOrWhiteSpace($question)) {
                if ($question.Length -gt $MaxQuestionChars) { $question = $question.Substring(0, $MaxQuestionChars).TrimEnd() }
                $isFinalLine = ($i -eq ($lines.Count - 1))
                return [PSCustomObject]@{ question = $question; explicitMarkerFound = $isFinalLine; markerLineIndex = $i; markerIsFinalLine = $isFinalLine }
            }
        }
    }
    return [PSCustomObject]@{
        question = "직전 답변에서 아직 확인되지 않은 업무 용어·상태·데이터 흐름 하나를 골라, 관련 Mapper XML과 VO/DTO 증거로 검증할 후속 질문을 만들어줘."
        explicitMarkerFound = $false
        markerLineIndex = -1
        markerIsFinalLine = $false
    }
}

function Extract-NextQuestion([string]$content) {
    return [string](Get-NextQuestionExtraction $content).question
}

function New-PartialResponseContinuationQuestion([string]$OriginalQuestion, [string]$FinishReason, [bool]$MarkerFound) {
    $question = (($OriginalQuestion -replace '\s+', ' ').Trim())
    if ($question.Length -gt 900) { $question = $question.Substring(0, 900).TrimEnd() + "..." }
    $reason = if ($FinishReason -in @("length", "content_filter")) { "finish_reason=$FinishReason 로 응답이 완결되지 않았습니다" } elseif (-not $MarkerFound) { "응답에 명시적인 NEXT_QUESTION 마지막 줄이 없었습니다" } else { "응답을 완결 상태로 확인하지 못했습니다" }
    return "직전 업무 질문 '$question'의 분석을 이어서 완성해줘. $reason. 이미 확정한 내용은 짧게만 연결하고, 누락된 업무 목적·용어·정상 흐름·Mapper table/column·VO field·상태 변화·downstream 근거를 우선 보충한 뒤, 마지막 비어 있지 않은 한 줄에 NEXT_QUESTION: 형식의 후속 업무 질문을 반드시 작성해줘."
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

    return "아래 직전 루프 요약을 바탕으로 이미 다룬 파일 기술 설명은 반복하지 말고, 아직 확인되지 않은 업무 용어·판단 규칙·상태 변화·원천/대상 데이터·downstream 소비 중 하나를 관련 Mapper XML과 VO/DTO 증거로 더 깊게 검증해줘.`n`n$lastTurn"
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
        $groupName = if (-not [string]::IsNullOrWhiteSpace([string]$selectedFile.questionGroupLabel)) { [string]$selectedFile.questionGroupLabel } else { "미분류 구조 그룹" }
        return "이전 실행에서 프로젝트 전체 핵심 후보를 고르는 초기 질문이 이미 전송됐지만 완료 기록이 없습니다. 같은 질문을 반복하지 말고, 이번에 선택된 구조 그룹($groupName)의 핵심 후보 파일($($selectedFile.path))을 기준으로 실제 업무 도메인 또는 사용자 시나리오 하나를 좁혀서 정상 흐름, 데이터/상태 이동, 다음에 확인해야 할 연결 파일, 마지막 리스크 점검 포인트를 구체적으로 분석해줘."
    }

    return "이전 실행에서 프로젝트 스캔 기반 초기 질문이 이미 전송됐지만 완료 기록이 없습니다. 같은 질문을 반복하지 말고, 이번 스캔 결과의 핵심 후보 중 하나를 새롭게 골라 실제 업무 도메인 또는 사용자 시나리오 하나를 좁혀서 정상 흐름, 데이터/상태 이동, 다음 확인 파일, 마지막 리스크 점검 포인트를 구체적으로 분석해줘."
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
너는 코드 증거를 이용해 사용자의 업무와 도메인 프로세스를 복원하는 시니어 업무 분석가다. Java/Spring, MyBatis/JPA, React/TypeScript, 배치와 DB 지식은 업무 의미를 확인하는 도구이지 답변의 주제가 아니다.

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

1. 현재 질문의 상세 분석을 먼저 끝낸다. 마지막 비어 있지 않은 한 줄만 반드시 다음 형식으로 작성한다.
NEXT_QUESTION: 여기에 다음 루프에서 검증할 자기완결적인 업무 질문 한 문장을 작성
2. 프로젝트 분석 답변의 가시 본문 목표는 최소 $ProjectTargetAnswerChars 자, 대략 $ProjectTargetOutputTokens output tokens 이상이다. 충분한 근거가 있으면 8,000~12,000자 수준으로 깊게 작성하되 일반론이나 반복으로 분량을 채우지 않는다.
3. 프로젝트 분석은 다음 구조를 사용한다: (a) 이 프로그램이 하는 업무 한 문장, (b) actor/trigger/precondition/result, (c) 업무 용어·데이터 사전 8개 이상, (d) 정상 업무 흐름 8~12단계, (e) read/write table·column·상태 변화와 downstream, (f) 확인된 사실/추론/미확인, (g) 각 핵심 결론의 file path+identifier 근거, (h) 마지막 기술 리스크.
4. Mapper XML에서는 SQL 문법 자체보다 statement id, table, column, resultMap property-column, parameter/result type, 주석을 업무 의미의 증거로 사용한다. VO/DTO에서는 field, type, JavaDoc/한글 주석, Schema/Column/validation을 업무 용어의 증거로 사용한다.
5. Tasklet/Job/Controller의 실행 계기와 입력부터 Service, Mapper, DB, 후속 Job/API/화면까지 정상 데이터 lineage를 우선 복원한다. @Transactional, 알고리즘, 디자인 패턴, 성능, 보안은 업무 결과에 영향을 주는 경우에만 전체의 15~20% 이내에서 마지막에 다룬다.
6. 파일명·클래스명·연결 파일 자체를 다음 주제로 삼지 않는다. 연결 파일은 현재의 미확인 업무 용어, 판단 규칙, 상태 전이, 원천-대상 데이터, downstream 소비를 확인하는 증거다.
7. 제공된 코드로 확정할 수 없는 내용은 추측을 사실처럼 말하지 않고 명시적으로 '추론' 또는 '미확인'으로 표시하며 필요한 파일/identifier를 적는다.
8. NEXT_QUESTION은 답변을 모두 분석한 뒤 가장 가치 있는 미확인 업무 의미에서 만든다. 최근 업무군과 질문을 반복하지 말고, 기술 쟁점보다 업무 목적 → 용어/입력 → 판단/상태 → 데이터 lineage → downstream 순으로 우선한다.
9. NEXT_QUESTION에는 필요한 경우 구체적인 Mapper id, table/column, VO field, JobParameter, 파일명을 포함하되 그 파일의 기술 구조가 아니라 어떤 업무 가설을 검증할지 명시한다.
10. settings.general.outputLanguage($outputLanguage)에 맞춰 작성하고, 근거가 부족하면 억지로 길게 쓰지 말고 미확인 목록과 다음 검증 계획을 충실히 남긴다.
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

    # samplingParams/extra_body are settings-first overrides.  Normalize the
    # final wire mode after those merges so transport and parser behavior can
    # follow the request that is actually sent.
    $effectiveStream = ConvertTo-BooleanValue (Get-JsonProperty $bodyObj "stream") (-not [bool]$NonStreaming)
    $bodyObj["stream"] = $effectiveStream
    if ($effectiveStream) {
        if ($null -eq (Get-JsonProperty $bodyObj "stream_options")) {
            $bodyObj["stream_options"] = @{ include_usage = $true }
        }
    } else {
        $bodyObj.Remove("stream_options")
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

function Get-OpenAIResponseMetadata([string]$raw, [bool]$isStreaming) {
    $finishReason = ""
    $usageRaw = $null
    if ($isStreaming) {
        foreach ($line in ($raw -split "`r?`n")) {
            $trimmed = $line.Trim()
            if (-not $trimmed.StartsWith("data:")) { continue }
            $data = $trimmed.Substring(5).Trim()
            if ([string]::IsNullOrWhiteSpace($data) -or $data -eq "[DONE]") { continue }
            try {
                $payload = $data | ConvertFrom-Json
                $usage = Get-JsonProperty $payload "usage"
                if ($usage) { $usageRaw = $usage }
                foreach ($choice in @(Get-JsonProperty $payload "choices")) {
                    if ($null -eq $choice) { continue }
                    $finish = Get-JsonProperty $choice "finish_reason"
                    if (-not [string]::IsNullOrWhiteSpace([string]$finish)) { $finishReason = [string]$finish }
                }
            } catch { }
        }
    } else {
        try {
            $payload = $raw | ConvertFrom-Json
            $usage = Get-JsonProperty $payload "usage"
            if ($usage) { $usageRaw = $usage }
            foreach ($choice in @(Get-JsonProperty $payload "choices")) {
                if ($null -eq $choice) { continue }
                $finish = Get-JsonProperty $choice "finish_reason"
                if (-not [string]::IsNullOrWhiteSpace([string]$finish)) { $finishReason = [string]$finish }
            }
        } catch { }
    }

    $reasoningTokens = $null
    if ($usageRaw) {
        $details = Get-JsonProperty $usageRaw "completion_tokens_details"
        if ($null -eq $details) { $details = Get-JsonProperty $usageRaw "output_tokens_details" }
        if ($details) { $reasoningTokens = Get-UsageNumber $details @("reasoning_tokens") }
    }
    return [PSCustomObject]@{
        finishReason = if ([string]::IsNullOrWhiteSpace($finishReason)) { "unknown" } else { $finishReason }
        reasoningTokens = $reasoningTokens
    }
}

function Get-AnswerDepthFacts($usage, $metadata, [string]$answer, $effectiveMaxTokens, [bool]$isProject) {
    $outputTokens = if ($usage) { $usage.outputTokens } else { $null }
    $reasoningTokens = if ($metadata) { $metadata.reasoningTokens } else { $null }
    $visibleOutputTokens = $outputTokens
    $visibleTokenBasis = if ($null -ne $outputTokens) { "reported-output-no-reasoning-breakdown" } else { "unavailable" }
    $reasoningAccountingValid = $null
    if ($null -ne $outputTokens -and $null -ne $reasoningTokens) {
        if ([int64]$reasoningTokens -le [int64]$outputTokens) {
            $visibleOutputTokens = [int64]$outputTokens - [int64]$reasoningTokens
            $visibleTokenBasis = "reported-output-minus-reasoning"
            $reasoningAccountingValid = $true
        } else {
            $visibleOutputTokens = $null
            $visibleTokenBasis = "invalid-reasoning-exceeds-output"
            $reasoningAccountingValid = $false
        }
    }
    $inputTokens = if ($usage) { $usage.inputTokens } else { $null }
    $inputLoad = if ($null -eq $inputTokens) { "unknown" } elseif ($inputTokens -lt 18000) { "focused" } elseif ($inputTokens -le 30000) { "normal" } else { "heavy" }
    $visibleClass = if ($null -eq $visibleOutputTokens) { "unknown" } elseif ($visibleOutputTokens -lt 2500) { "short" } elseif ($visibleOutputTokens -lt 6000) { "developed" } else { "extended" }
    $answerChars = if ($null -eq $answer) { 0 } else { $answer.Length }
    $outputTargetMet = if ($isProject -and $null -ne $visibleOutputTokens) { $visibleOutputTokens -ge $ProjectTargetOutputTokens } else { $null }
    $charTargetMet = if ($isProject) { $answerChars -ge $ProjectTargetAnswerChars } else { $null }
    $contextYield = if ($null -ne $inputTokens -and [int64]$inputTokens -gt 0 -and $null -ne $visibleOutputTokens) { [Math]::Round(([double]$visibleOutputTokens / [double]$inputTokens) * 100, 2) } else { $null }
    $finishReason = if ($metadata) { [string]$metadata.finishReason } else { "unknown" }
    return [PSCustomObject]@{
        inputLoad = $inputLoad
        visibleOutput = $visibleClass
        inputTokens = $inputTokens
        outputTokens = $outputTokens
        reasoningTokens = $reasoningTokens
        visibleOutputTokens = $visibleOutputTokens
        visibleTokenBasis = $visibleTokenBasis
        reasoningAccountingValid = $reasoningAccountingValid
        answerChars = $answerChars
        targetOutputTokens = if ($isProject) { $ProjectTargetOutputTokens } else { $null }
        targetAnswerChars = if ($isProject) { $ProjectTargetAnswerChars } else { $null }
        outputTargetMet = $outputTargetMet
        charTargetMet = $charTargetMet
        contextYieldPercent = $contextYield
        finishReason = $finishReason
        truncated = ($finishReason -eq "length")
        effectiveMaxTokens = $effectiveMaxTokens
    }
}

function Format-TokenNumber($value) {
    if ($null -eq $value) { return "n/a" }
    return ("{0:N0}" -f [int64]$value)
}

function Get-TokenUsageProfile($usage, $answerDepth = $null) {
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

    $score = if ($answerDepth) { $answerDepth.visibleOutputTokens } else { $null }
    $basis = if ($null -ne $score) { "visible-output" } else { "reported-output" }
    $noteSubject = if ($null -ne $score) { "visible output" } else { "reported output" }
    if ($null -eq $score) { $score = $usage.outputTokens }
    if ($null -eq $score) {
        $score = $usage.totalTokens
        $basis = "total"
        $noteSubject = "total token count"
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
            level = "short"
            color = "Yellow"
            note = "$noteSubject below the configured short threshold"
            basis = $basis
        }
    }

    if ($score -lt $TokenRichThreshold) {
        return [PSCustomObject]@{
            available = $true
            level = "developed"
            color = "Cyan"
            note = "$noteSubject in the developed range"
            basis = $basis
        }
    }

    return [PSCustomObject]@{
        available = $true
        level = "extended"
        color = "Magenta"
        note = "$noteSubject in the extended range"
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

function Write-AnswerDepth($facts) {
    if ($null -eq $facts) { return }
    $targetText = if ($null -eq $facts.outputTargetMet) { "n/a" } else { "tokens=$($facts.outputTargetMet), chars=$($facts.charTargetMet)" }
    $yieldText = if ($null -eq $facts.contextYieldPercent) { "n/a" } else { "$($facts.contextYieldPercent)%" }
    $targetState = if ($null -eq $facts.outputTargetMet) {
        "n/a"
    } elseif ($facts.outputTargetMet -and $facts.charTargetMet) {
        "both"
    } elseif ($facts.outputTargetMet) {
        "token-only"
    } elseif ($facts.charTargetMet) {
        "char-only"
    } else {
        "neither"
    }
    $color = if ($facts.truncated) { "Red" } elseif ($targetState -eq "both") { "Green" } elseif ($targetState -in @("token-only", "char-only")) { "Cyan" } else { "Yellow" }
    Write-Host "AnswerDepth : input=$($facts.inputLoad), output=$($facts.visibleOutput), target[$targetText; state=$targetState], yield=$yieldText, finish=$($facts.finishReason)" -ForegroundColor $color
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
    $requestStreaming = ConvertTo-BooleanValue (Get-JsonProperty $bodyObj "stream") (-not [bool]$NonStreaming)
    $effectiveMaxTokens = Get-JsonProperty $bodyObj "max_tokens"
    if ($null -eq $effectiveMaxTokens) { $effectiveMaxTokens = Get-JsonProperty $bodyObj "max_completion_tokens" }
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
                $response = Invoke-JsonPostUtf8 -Uri $endpoint -Headers $headers -BodyBytes $bodyBytes -TimeoutSeconds $EffectiveTimeoutSec -StopOnSseDone:$requestStreaming
                Write-Host ("[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] HTTP {0} {1} ({2} ms, {3} bytes, retry-count={4})" -f $response.StatusCode, $response.StatusDescription, $response.DurationMs, $response.ReceivedBytes, $attempt) -ForegroundColor Green
                $contentType = ([string]$response.ContentType).ToLowerInvariant()
                $responseStreaming = if ($contentType.Contains("text/event-stream")) {
                    $true
                } elseif ($contentType.Contains("application/json")) {
                    $false
                } elseif (([string]$response.Body).TrimStart().StartsWith("data:")) {
                    $true
                } else {
                    $requestStreaming
                }
                $responseParseMode = if ($responseStreaming) { "sse" } else { "json" }
                $answerText = Convert-OpenAIResponseToText $response.Body $responseStreaming
                $tokenUsage = Get-OpenAIUsageFromRaw $response.Body $responseStreaming
                $responseMetadata = Get-OpenAIResponseMetadata $response.Body $responseStreaming
                $answerDepth = Get-AnswerDepthFacts $tokenUsage $responseMetadata $answerText $effectiveMaxTokens (-not [string]::IsNullOrWhiteSpace($ProjectRoot))
                $tokenProfile = Get-TokenUsageProfile $tokenUsage $answerDepth
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
                    requestStreaming = $requestStreaming
                    responseParseMode = $responseParseMode
                    requestBodyChars = $body.Length
                    systemPromptChars = $systemPrompt.Length
                    userPromptChars = $userPrompt.Length
                    usage = ConvertTo-PlainObject $tokenUsage
                    tokenUse = ConvertTo-PlainObject $tokenProfile
                    finishReason = $responseMetadata.finishReason
                    reasoningTokens = $responseMetadata.reasoningTokens
                    effectiveMaxTokens = $effectiveMaxTokens
                    answerChars = $answerText.Length
                    answerDepth = ConvertTo-PlainObject $answerDepth
                    completedAt = (Get-Date).ToString("o")
                }) | ConvertTo-Json -Depth 10)
                Write-Host ("ResponseText : {0} chars extracted" -f $answerText.Length) -ForegroundColor DarkGreen
                Write-TokenUsage $tokenUsage $tokenProfile
                Write-AnswerDepth $answerDepth
                return [PSCustomObject]@{
                    Text = $answerText
                    Usage = $tokenUsage
                    TokenUse = $tokenProfile
                    AnswerDepth = $answerDepth
                    FinishReason = $responseMetadata.finishReason
                    ReasoningTokens = $responseMetadata.reasoningTokens
                    EffectiveMaxTokens = $effectiveMaxTokens
                    RequestStreaming = $requestStreaming
                    ResponseParseMode = $responseParseMode
                    RequestBodyChars = $body.Length
                    SystemPromptChars = $systemPrompt.Length
                    UserPromptChars = $userPrompt.Length
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

$projectSessionLayout = $null
$projectSessionRetention = $null
$projectSessionLockStream = $null
if ($NewProjectSession) {
    if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { throw "-NewProjectSession은 -ProjectRoot와 함께 사용해야 합니다." }
    $resolvedSessionProjectRoot = Resolve-ProjectRoot $ProjectRoot
    $sessionRootInput = Expand-PathInput $WorkDir
    if (-not [System.IO.Path]::IsPathRooted($sessionRootInput)) { $sessionRootInput = Join-Path $PSScriptRoot $sessionRootInput }
    Assert-SafeWorkDir $sessionRootInput $resolvedSessionProjectRoot
    $projectSessionLayout = New-ProjectSessionLayout $ProjectRoot $WorkDir
    $ProjectRoot = $projectSessionLayout.ProjectRoot
    $WorkDir = $projectSessionLayout.SessionDir
}

Assert-SafeWorkDir $WorkDir $ProjectRoot
if (!(Test-Path -LiteralPath $SettingsPath)) { throw "settings.json을 찾지 못했습니다: $SettingsPath" }
$workDirExistedBefore = Test-Path -LiteralPath $WorkDir -PathType Container
$workDirWasEmpty = $false
if ($workDirExistedBefore) {
    $workDirWasEmpty = (@(Get-ChildItem -LiteralPath $WorkDir -Force -ErrorAction SilentlyContinue).Count -eq 0)
}
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$defaultLoopDataRoot = Get-NormalizedFullPath (Join-Path $PSScriptRoot "qwen-loop-data")
$workDirCanBeClaimed = ($null -ne $projectSessionLayout) -or (Test-PathInsideRoot $defaultLoopDataRoot $WorkDir) -or (-not $workDirExistedBefore) -or $workDirWasEmpty
$workDirCleanupOwned = Initialize-QwenLoopWorkDirOwnership $WorkDir $workDirCanBeClaimed
if ($projectSessionLayout) {
    $lockPath = Join-Path $WorkDir ".active.lock"
    $projectSessionLockStream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
}

try {
if ($projectSessionLayout) {
    $sessionIdentity = [ordered]@{
        schema = "qwen-loop-project-session/v1"
        identity = $projectSessionLayout.Identity
        canonicalProjectRoot = $projectSessionLayout.ProjectRoot
        sessionId = $projectSessionLayout.SessionId
        createdAt = (Get-Date).ToString("o")
        processId = $PID
    }
    Write-Utf8File (Join-Path $WorkDir "session_identity.json") ($sessionIdentity | ConvertTo-Json -Depth 10)
    $projectSessionRetention = Invoke-ProjectSessionRetention $projectSessionLayout
}

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
$dynamicProjectContextPath = Join-Path $WorkDir "last_dynamic_project_context.json"
$projectExplorationStatePath = Join-Path $WorkDir "exploration_state.json"
$projectCycleHistoryPath = Join-Path $WorkDir "cycle_history.jsonl"
$projectCycleEvidencePath = Join-Path $WorkDir "cycle_evidence.md"

$projectScan = $null
$projectContext = ""
$projectCycleNumber = 1
$projectSuccessfulTurnsInCycle = 0
$projectExplorationHistoryPath = if ($projectSessionLayout) { $projectSessionLayout.ExplorationHistoryPath } else { Join-Path $WorkDir "exploration_history.jsonl" }
$projectExplorationLockPath = if ($projectSessionLayout) { Join-Path $projectSessionLayout.ProjectBase ".exploration.lock" } else { Join-Path $WorkDir ".exploration.lock" }
$projectExplorationLockStream = $null
if (-not [string]::IsNullOrWhiteSpace($ProjectRoot) -and -not $DryRun) {
    $projectExplorationLockStream = Open-ExclusiveFileLock $projectExplorationLockPath 30000
    if ($null -eq $projectExplorationLockStream) {
        throw "다른 실행이 이 프로젝트의 업무 영역을 선택하고 있습니다. 중복 family 예약을 피하기 위해 시작을 중단합니다. 잠시 후 다시 실행하세요: $projectExplorationLockPath"
    }
}
try {
    $projectExplorationAvoidance = Get-ProjectExplorationAvoidance $projectExplorationHistoryPath
    if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $projectScan = New-ProjectScanContext $ProjectRoot $projectExplorationAvoidance $projectCycleNumber
    Write-ProjectScanFiles $projectScan $WorkDir
    $projectContext = $projectScan.promptContext

    if ($FreshProjectQuestion) {
        Write-Utf8File $nextQuestionPath $projectScan.seedQuestion
        $initialQuestion = [PSCustomObject]@{
            Question = $projectScan.seedQuestion
            Source = "project-fresh-scan"
            SeedSource = (Join-Path $WorkDir "project_scan_summary.md")
        }
    } else {
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
    }

    if ($null -eq $initialQuestion) {
        Write-Utf8File $nextQuestionPath $projectScan.seedQuestion
        $initialQuestion = [PSCustomObject]@{
            Question = $projectScan.seedQuestion
            Source = "project-scan"
            SeedSource = (Join-Path $WorkDir "project_scan_summary.md")
        }
    }
    if ($NewProjectSession -and -not $DryRun) {
        Add-ProjectExplorationHistory $projectExplorationHistoryPath $projectScan $projectSessionLayout.SessionId "new-session"
        $projectExplorationAvoidance = Get-ProjectExplorationAvoidance $projectExplorationHistoryPath
    }
    } else {
        $initialQuestion = Initialize-NextQuestion $nextQuestionPath $jsonlPath $transcriptPath $lastTurnPath $SeedFile $QuestionBankFile $QuestionTrack
    }
} finally {
    if ($projectExplorationLockStream) { $projectExplorationLockStream.Dispose(); $projectExplorationLockStream = $null }
}
if ($projectScan -and $FreshProjectQuestion) {
    Write-Utf8File $projectCycleEvidencePath "# Compact business evidence memory`n"
}
$seedQuestion = $initialQuestion.Question
$projectQuestionSource = $initialQuestion.Source
$startupCleanup = Invoke-WorkDirCleanup $WorkDir $transcriptPath $jsonlPath $errorLogPath

$systemPrompt = Build-SettingsAwareSystemPrompt $settings $providerInfo
$runtimeRequestShape = Build-RequestBody $settings $providerInfo $systemPrompt "runtime-shape-preview" $networkIdentity
$effectiveRequestStreaming = ConvertTo-BooleanValue (Get-JsonProperty $runtimeRequestShape "stream") (-not [bool]$NonStreaming)

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
Write-Host "Stream       : $effectiveRequestStreaming (effective after settings overrides; switch requested=$(-not [bool]$NonStreaming))"
Write-Host "Retry        : max $MaxRetries, backoff $RetryInitialDelaySeconds-$RetryMaxDelaySeconds sec"
Write-Host "TokenUse     : short < $TokenLowThreshold, extended >= $TokenRichThreshold output tokens (diagnostic only)"
Write-Host "HeaderLog    : $(if ($MaskSensitiveLogs -and -not $LogSensitive) { 'masked' } else { 'unmasked' })"
Write-Host "QuestionSrc  : $($initialQuestion.Source)"
if ($projectScan) {
    Write-Host "ProjectRoot  : $($projectScan.root)"
    Write-Host "ProjectScan  : $($projectScan.scannedFileCount) files scanned, $($projectScan.selectedFileCount) key files selected"
    Write-Host "ProjectStart : $(if ($NewProjectSession) { 'isolated timestamp session; project exploration ledger avoids recent business families' } elseif ($FreshProjectQuestion) { 'fresh scan question; saved continuation is ignored on startup' } else { 'legacy continuation from saved next_question when available' })"
    Write-Host "ProjectCycle : $ProjectTurnsPerCycle successful turns; then fresh scan / new business slice"
    Write-Host "OutputTarget : $ProjectTargetOutputTokens tokens or $ProjectTargetAnswerChars chars as separate diagnostics"
}
if ($projectSessionLayout) {
    Write-Host "SessionId    : $($projectSessionLayout.SessionId)"
    Write-Host "ProjectIdent : $($projectSessionLayout.Identity)"
    $retentionActionCount = if ($projectSessionRetention) { @($projectSessionRetention.actions).Count } else { 0 }
    Write-Host "SessionKeep  : count=$ProjectSessionKeepCount, days=$ProjectSessionKeepDays, total=${ProjectSessionMaxTotalMB}MB; removed=$retentionActionCount"
    if ($projectSessionRetention -and -not [string]::IsNullOrWhiteSpace([string]$projectSessionRetention.warning)) {
        Write-Host "SessionWarn  : $($projectSessionRetention.warning)" -ForegroundColor Yellow
    }
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
    stream = $effectiveRequestStreaming
    streamRequestedBySwitch = (-not [bool]$NonStreaming)
    streamPolicy = "effective value after generationConfig.samplingParams and extra_body settings-first overrides"
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
        displayBasis = "neutral input/output diagnostics; max_tokens is a ceiling, not an output target"
        lowThreshold = $TokenLowThreshold
        richThreshold = $TokenRichThreshold
        short = "below lowThreshold"
        developed = "between thresholds"
        extended = "at or above richThreshold"
        projectTargetOutputTokens = $ProjectTargetOutputTokens
        projectTargetAnswerChars = $ProjectTargetAnswerChars
        note = "finish_reason and AnswerDepth distinguish model stop, length truncation, visible output, reasoning tokens, and target progress."
    }
    bannerEnabled = (-not [bool]$NoBanner)
    answerPreview = [ordered]@{
        enabled = (-not [bool]$NoAnswerPreview)
        lines = $AnswerPreviewLines
        chars = $AnswerPreviewChars
    }
    autoCleanup = [ordered]@{
        enabled = [bool]$startupCleanup.enabled
        workDirOwnershipVerified = [bool]$workDirCleanupOwned
        maxWorkDirMB = $MaxWorkDirMB
        maxTranscriptMB = $MaxTranscriptMB
        maxErrorLogMB = $MaxErrorLogMB
        cleanupKeepDays = $CleanupKeepDays
        cleanupKeepTurns = $CleanupKeepTurns
        policy = (Get-CleanupPolicyText)
        startup = ConvertTo-PlainObject $startupCleanup
        note = "Preserves active state files such as next_question.txt and last_turn.txt; compacts large transcripts/error.log and removes stale dry-run/check artifacts."
    }
    dynamicProjectContext = [ordered]@{
        enabled = ($null -ne $projectScan)
        maxFiles = $DynamicProjectContextMaxFiles
        maxFileChars = $DynamicProjectContextMaxFileChars
        maxTotalChars = $DynamicProjectContextMaxTotalChars
        lastSummaryJson = $dynamicProjectContextPath
        note = "For project mode, each turn extracts file/class/method symbols from the current question, attaches focused matching excerpts, expands connected files from imports/XML ids/class refs/calls, and skips missing files without failing the loop."
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
    freshProjectQuestion = [bool]$FreshProjectQuestion
    newProjectSession = [bool]$NewProjectSession
    projectSession = if ($projectSessionLayout) {
        [ordered]@{
            identity = $projectSessionLayout.Identity
            sessionId = $projectSessionLayout.SessionId
            sessionDir = $projectSessionLayout.SessionDir
            projectBase = $projectSessionLayout.ProjectBase
            explorationHistory = $projectSessionLayout.ExplorationHistoryPath
            retention = ConvertTo-PlainObject $projectSessionRetention
            keepCount = $ProjectSessionKeepCount
            keepDays = $ProjectSessionKeepDays
            maxTotalMB = $ProjectSessionMaxTotalMB
        }
    } else { $null }
    projectScan = if ($projectScan) {
        [ordered]@{
            root = $projectScan.root
            generatedAt = $projectScan.generatedAt
            scannedFileCount = $projectScan.scannedFileCount
            selectedFileCount = $projectScan.selectedFileCount
            primaryQuestionCandidateFile = $projectScan.primaryQuestionCandidateFile
            primaryQuestionCandidateGroup = $projectScan.primaryQuestionCandidateGroup
            primaryQuestionCandidateGroupKey = $projectScan.primaryQuestionCandidateGroupKey
            primaryBusinessFamily = $projectScan.primaryBusinessFamily
            explorationCycle = $projectScan.explorationCycle
            questionGroupCount = $projectScan.questionGroupCount
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
        if (-not $NewProjectSession) {
            $dryRunQuestionHistory = Get-RecentQuestionHistoryFromTree (Get-LoopDataHistoryRoot $WorkDir) $jsonlPath 12
            if ([string]::IsNullOrWhiteSpace($dryRunQuestionHistory)) { $dryRunQuestionHistory = "(none)" }
            $dryRunPromptParts.Add("기존 qwen-loop-data 최근 질문(중복 회피용):`n$dryRunQuestionHistory") | Out-Null
        }
        $dryRunDynamicProjectContext = Build-DynamicProjectContext $projectScan.root $seedQuestion "" ([string]$projectScan.primaryBusinessFamily)
        Write-Utf8File $dynamicProjectContextPath ($dryRunDynamicProjectContext | ConvertTo-Json -Depth 50)
        if (-not [string]::IsNullOrWhiteSpace([string]$dryRunDynamicProjectContext.text)) {
            $dryRunPromptParts.Add("현재 질문 관련 동적 프로젝트 컨텍스트:`n$($dryRunDynamicProjectContext.text)") | Out-Null
        }
        $dryRunPromptParts.Add("기본 프로젝트 스캔 컨텍스트:`n$projectContext") | Out-Null
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
    if ($projectScan) { Write-Host "- $dynamicProjectContextPath" }
    Write-ProjectPromptFileSummary $projectScan $dryRunDynamicProjectContext
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
    $answerDepth = $null
    $chatResult = $null
    $nextQuestionMarkerFound = $false
    $nextQuestionMarkerPresent = $false
    $partialReason = ""
    $questionSource = $projectQuestionSource
    $projectCycleForRun = if ($projectScan) { $projectCycleNumber } else { $null }
    $projectTurnInCycle = if ($projectScan) { $projectSuccessfulTurnsInCycle + 1 } else { $null }
    $projectPhase = if ($projectScan) { Get-ProjectExplorationPhase $projectTurnInCycle $ProjectTurnsPerCycle } else { $null }
    try {
        if ($NewProjectSession -and $projectScan -and $projectSuccessfulTurnsInCycle -ge $ProjectTurnsPerCycle) {
            $previousFamily = [string]$projectScan.primaryBusinessFamily
            $nextCycle = $projectCycleNumber + 1
            $cycleExplorationLock = Open-ExclusiveFileLock $projectExplorationLockPath 30000
            if ($null -eq $cycleExplorationLock) {
                throw "다른 실행이 이 프로젝트의 다음 업무 영역을 선택하고 있습니다. 중복 family 예약을 피하기 위해 이번 cycle 전환을 보류합니다: $projectExplorationLockPath"
            }
            try {
                $projectExplorationAvoidance = Get-ProjectExplorationAvoidance $projectExplorationHistoryPath
                $nextScan = New-ProjectScanContext $ProjectRoot $projectExplorationAvoidance $nextCycle
                Write-ProjectScanFiles $nextScan $WorkDir
                $projectScan = $nextScan
                $projectContext = $projectScan.promptContext
                $seedQuestion = $projectScan.seedQuestion
                Write-Utf8File $nextQuestionPath $seedQuestion
                Write-Utf8File $lastTurnPath ""
                Write-Utf8File $projectCycleEvidencePath "# Compact business evidence memory`n"
                $projectCycleNumber = $nextCycle
                $projectSuccessfulTurnsInCycle = 0
                $projectQuestionSource = "cycle-rescan"
                $questionSource = $projectQuestionSource
                Add-ProjectExplorationHistory $projectExplorationHistoryPath $projectScan $projectSessionLayout.SessionId "successful-turn-limit"
            } finally {
                if ($cycleExplorationLock) { $cycleExplorationLock.Dispose() }
            }
            $cycleRecord = [ordered]@{
                transitionedAt = (Get-Date).ToString("o")
                reason = "successful-turn-limit"
                turnsPerCycle = $ProjectTurnsPerCycle
                previousCycle = ($nextCycle - 1)
                nextCycle = $nextCycle
                previousBusinessFamily = $previousFamily
                nextBusinessFamily = $projectScan.primaryBusinessFamily
                nextPrimaryPath = $projectScan.primaryQuestionCandidateFile
            }
            Append-Utf8File $projectCycleHistoryPath (($cycleRecord | ConvertTo-Json -Compress -Depth 20) + "`n")
            Write-Host "`nProjectCycle : $($nextCycle - 1) completed; fresh scan selected cycle $nextCycle / $($projectScan.primaryBusinessFamily)" -ForegroundColor Magenta
        }

        $projectCycleForRun = if ($projectScan) { $projectCycleNumber } else { $null }
        $projectTurnInCycle = if ($projectScan) { $projectSuccessfulTurnsInCycle + 1 } else { $null }
        $projectPhase = if ($projectScan) { Get-ProjectExplorationPhase $projectTurnInCycle $ProjectTurnsPerCycle } else { $null }
        $question = (Read-Utf8File $nextQuestionPath).Trim()
        if ([string]::IsNullOrWhiteSpace($question)) { $question = $seedQuestion }
        Write-Utf8File $pendingQuestionPath $question

        $contextBundle = Read-ContextBundle $ContextListFile $MaxContextChars
        $lastTurn = ""
        $skipStoredProjectTurn = $projectScan -and (($NewProjectSession -and $projectTurnInCycle -eq 1) -or ($FreshProjectQuestion -and $runCount -eq 1))
        if ((-not $skipStoredProjectTurn) -and (Test-Path -LiteralPath $lastTurnPath)) { $lastTurn = Get-TextPrefix ((Read-Utf8File $lastTurnPath).Trim()) $LastTurnChars }
        $dynamicProjectContext = $null
        $questionHistory = if ($NewProjectSession -and $projectScan) { Get-RecentQuestionHistory $jsonlPath ([Math]::Min(8, $projectSuccessfulTurnsInCycle)) } else { Get-RecentQuestionHistory $jsonlPath 8 }
        if ($projectScan) {
            if (-not $NewProjectSession) {
                $globalQuestionHistory = Get-RecentQuestionHistoryFromTree (Get-LoopDataHistoryRoot $WorkDir) $jsonlPath 12
                if (-not [string]::IsNullOrWhiteSpace($globalQuestionHistory)) {
                    if (-not [string]::IsNullOrWhiteSpace($questionHistory)) { $questionHistory += "`n" }
                    $questionHistory += "기존 qwen-loop-data 최근 질문(중복 회피용):`n$globalQuestionHistory"
                }
            }
            $questionHistory = Get-TextSuffix $questionHistory 6000
            $dynamicProjectContext = Build-DynamicProjectContext $projectScan.root $question $lastTurn ([string]$projectScan.primaryBusinessFamily)
            Write-Utf8File $dynamicProjectContextPath ($dynamicProjectContext | ConvertTo-Json -Depth 50)
        }
        $projectPromptSection = ""
        if ($projectScan) {
            $dynamicContextText = ""
            if ($dynamicProjectContext -and -not [string]::IsNullOrWhiteSpace([string]$dynamicProjectContext.text)) {
                $dynamicContextText = "현재 질문 관련 동적 프로젝트 컨텍스트:`n$($dynamicProjectContext.text)`n"
            }
            $projectPromptSection = "$dynamicContextText`n기본 프로젝트 스캔 컨텍스트:`n$projectContext`n"
        }
        $projectPhaseSection = ""
        if ($projectPhase) {
            $projectPhaseSection = @"
현재 업무 탐색 상태:
- cycle: $projectCycleForRun
- successful turn in cycle: $projectTurnInCycle / $ProjectTurnsPerCycle
- phase: $($projectPhase.label) [$($projectPhase.key)]
- 이번 단계의 목적: $($projectPhase.instruction)
- 가시 본문 목표: $ProjectTargetAnswerChars 자 이상, 약 $ProjectTargetOutputTokens output tokens 이상(근거가 부족하면 일반론 대신 미확인으로 표시)
"@
        }
        $cycleEvidenceMemory = ""
        if ($projectScan -and (Test-Path -LiteralPath $projectCycleEvidencePath -PathType Leaf)) {
            $cycleEvidenceMemory = Get-TextSuffix (Read-Utf8File $projectCycleEvidencePath) 9000
        }

        $userPrompt = @"
현재 루프 질문:
$question

직전 루프 요약 컨텍스트:
$lastTurn

최근 질문 히스토리:
$questionHistory

현재 cycle의 압축 업무 근거 메모리(앞선 turn의 결론을 5번째 보고서까지 유지):
$cycleEvidenceMemory

공통 컨텍스트:
$contextBundle

$projectPromptSection

$projectPhaseSection

요청:
위 질문에 답변해줘.
현재 업무 질문을 충분히 분석한 뒤, 마지막 비어 있지 않은 한 줄에만 NEXT_QUESTION: 으로 후속 질문을 작성해줘.
파일의 Java 기술 구조를 주제로 삼지 말고 업무 목적, actor/trigger/result, 업무 용어·상태, Mapper table/column과 VO field 의미, 정상 데이터 lineage와 downstream을 근거로 복원해줘. 연결 파일은 미확인 업무 가설을 검증하는 증거로 사용하고, 트랜잭션·패턴·성능·보안은 업무 영향이 있는 경우 마지막 15~20%에만 다뤄줘.
"@

        Write-Host "`n[$($started.ToString('yyyy-MM-dd HH:mm:ss'))] RUN #$runCount QUESTION:" -ForegroundColor Green
        Write-Host $question
        Write-ProjectPromptFileSummary $projectScan $dynamicProjectContext

        $requestAt = Get-Date
        $chatResult = Invoke-QwenChat $providerInfo $settings $networkIdentity $systemPrompt $userPrompt
        $answer = [string]$chatResult.Text
        $tokenUsage = $chatResult.Usage
        $tokenUse = $chatResult.TokenUse
        $answerDepth = $chatResult.AnswerDepth
        $nextQuestionExtraction = Get-NextQuestionExtraction $answer
        $nextQuestionMarkerFound = [bool]$nextQuestionExtraction.explicitMarkerFound
        $nextQuestionMarkerPresent = ([int]$nextQuestionExtraction.markerLineIndex -ge 0)
        $finishReason = ([string]$chatResult.FinishReason).ToLowerInvariant()
        $isIncompleteResponse = ($finishReason -in @("length", "content_filter")) -or (-not $nextQuestionMarkerFound)
        if ($isIncompleteResponse) {
            $nextQuestion = New-PartialResponseContinuationQuestion $question $finishReason $nextQuestionMarkerFound
            $partialReason = if ($finishReason -in @("length", "content_filter")) { "finish_reason=$finishReason" } elseif ($nextQuestionMarkerPresent) { "next-question-marker-not-final" } else { "missing-next-question-marker" }
            $runStatus = "partial"
        } else {
            $nextQuestion = [string]$nextQuestionExtraction.question
            $runStatus = "ok"
        }
        $ended = Get-Date
        $completedAt = $ended

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

## Exploration Phase

cycle=$projectCycleForRun, turn=$projectTurnInCycle/$ProjectTurnsPerCycle, phase=$(if ($projectPhase) { $projectPhase.label } else { "n/a" }), source=$questionSource

## Answer Depth

$(if ($answerDepth) { $answerDepth | ConvertTo-Json -Compress -Depth 10 } else { "not available" })

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
            nextQuestionMarkerFound = $nextQuestionMarkerFound
            nextQuestionMarkerPresent = $nextQuestionMarkerPresent
            completionStatus = $runStatus
            partialReason = $partialReason
            cycleIndex = $projectCycleForRun
            turnInCycle = $projectTurnInCycle
            phase = if ($projectPhase) { $projectPhase.key } else { $null }
            questionSource = $questionSource
            primaryBusinessFamily = if ($projectScan) { $projectScan.primaryBusinessFamily } else { $null }
            usage = ConvertTo-PlainObject $tokenUsage
            tokenUse = ConvertTo-PlainObject $tokenUse
            answerDepth = ConvertTo-PlainObject $answerDepth
            answer = $answer
        }
        Append-Utf8File $jsonlPath (($record | ConvertTo-Json -Compress -Depth 50) + "`n")
        if ($projectScan -and $runStatus -eq "ok") {
            Add-CycleEvidenceMemory $projectCycleEvidencePath $projectCycleForRun $projectTurnInCycle $runStatus $question $answer
        }

        if ($projectScan -and $runStatus -eq "ok") {
            $projectSuccessfulTurnsInCycle++
            $projectQuestionSource = "model-next-question"
            $explorationState = [ordered]@{
                schema = "qwen-loop-project-exploration-state/v1"
                updatedAt = (Get-Date).ToString("o")
                cycleIndex = $projectCycleNumber
                successfulTurnsInCycle = $projectSuccessfulTurnsInCycle
                turnsPerCycle = $ProjectTurnsPerCycle
                primaryBusinessFamily = $projectScan.primaryBusinessFamily
                primaryPath = $projectScan.primaryQuestionCandidateFile
                nextQuestion = $nextQuestion
            }
            Write-Utf8File $projectExplorationStatePath ($explorationState | ConvertTo-Json -Depth 20)
        } elseif ($projectScan -and $runStatus -eq "partial") {
            $projectQuestionSource = "partial-response-continuation"
            Write-Host "Partial turn : successful cycle count was not advanced ($partialReason)." -ForegroundColor Yellow
        }

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
        if ($projectScan) { Write-Host "- $dynamicProjectContextPath" }
        if ($runStatus -eq "partial") {
            Write-Host "`nRUN #$runCount partial. Answer saved; continuation queued without advancing the successful-turn cycle." -ForegroundColor Yellow
        } else {
            Write-Host "`nRUN #$runCount complete. Full answer saved to transcript.md." -ForegroundColor Green
        }
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
        answerDepth = ConvertTo-PlainObject $answerDepth
        finishReason = if ($chatResult) { $chatResult.FinishReason } else { $null }
        nextQuestionMarkerFound = $nextQuestionMarkerFound
        nextQuestionMarkerPresent = $nextQuestionMarkerPresent
        partialReason = $partialReason
        effectiveMaxTokens = if ($chatResult) { $chatResult.EffectiveMaxTokens } else { $null }
        requestStreaming = if ($chatResult) { $chatResult.RequestStreaming } else { $null }
        responseParseMode = if ($chatResult) { $chatResult.ResponseParseMode } else { $null }
        requestBodyChars = if ($chatResult) { $chatResult.RequestBodyChars } else { $null }
        systemPromptChars = if ($chatResult) { $chatResult.SystemPromptChars } else { $null }
        userPromptChars = if ($chatResult) { $chatResult.UserPromptChars } else { $null }
        cycleIndex = $projectCycleForRun
        turnInCycle = $projectTurnInCycle
        phase = if ($projectPhase) { $projectPhase.key } else { $null }
        questionSource = $questionSource
        primaryBusinessFamily = if ($projectScan) { $projectScan.primaryBusinessFamily } else { $null }
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

} finally {
    if ($projectSessionLockStream) { $projectSessionLockStream.Dispose(); $projectSessionLockStream = $null }
}
