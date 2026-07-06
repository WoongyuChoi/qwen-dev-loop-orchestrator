param(
    [string]$SettingsPath = "$env:USERPROFILE\.qwen\settings.json",
    [string]$ProviderName = "",
    [string]$ModelName = "",
    [string]$SeedFile = "$PSScriptRoot\seed_prompt.txt",
    [string]$ContextListFile = "$PSScriptRoot\context_files.txt",
    [string]$WorkDir = "$PSScriptRoot\qwen-loop-data",
    [int]$IntervalSeconds = 600,
    [int]$MaxTokens = 8192,
    [double]$Temperature = 0.35,
    [int]$TimeoutSec = 120,
    [int]$MaxContextChars = 30000,
    [int]$LastTurnChars = 12000,
    [int]$MaxRuns = 0,
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
    [switch]$MaskSensitiveLogs,
    [switch]$LogSensitive
)

$ErrorActionPreference = "Stop"

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
    return "이전 답변을 바탕으로 Java Spring Boot와 React 개발 관점에서 더 깊게 분석해야 할 다음 질문을 만들어줘."
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

function Build-ClientHeaders($providerInfo, $settings, $networkIdentity) {
    $headers = [ordered]@{}

    Set-HeaderLikeSdk $headers "Accept" "application/json"
    Set-HeaderLikeSdk $headers "User-Agent" "OpenAI/JS $OpenAISdkVersion"
    Set-HeaderLikeSdk $headers "X-Stainless-Retry-Count" "0"
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

function Build-SettingsAwareSystemPrompt($settings, $providerInfo, [string]$sourceSettingsPath) {
    $general = Get-JsonProperty $settings "general"
    $outputLanguage = [string](Get-JsonProperty $general "outputLanguage")
    if ([string]::IsNullOrWhiteSpace($outputLanguage)) { $outputLanguage = "한국어" }

    $permissions = Get-JsonProperty $settings "permissions"
    $allow = Get-JsonProperty $permissions "allow"
    $allowText = ""
    if ($allow) { $allowText = (($allow | ForEach-Object { "- $_" }) -join "`n") }

    $generationConfig = Get-JsonProperty $providerInfo.ProviderRaw "generationConfig"
    $generationConfigJson = "{}"
    if ($generationConfig) { $generationConfigJson = ($generationConfig | ConvertTo-Json -Depth 30) }

@"
너는 Java Spring Boot, MyBatis/JPA, React, TypeScript, 운영 배포 환경을 함께 보는 시니어 개발 아키텍트다.

아래 정보는 $sourceSettingsPath 에서 읽은 클라이언트 설정이다. 이 설정을 무시하지 말고 응답 방식과 작업 범위 판단에 반영한다.

- provider type: $($providerInfo.Type)
- provider name: $($providerInfo.ProviderName)
- provider id: $($providerInfo.ProviderId)
- model id: $($providerInfo.ModelId)
- baseUrl: $($providerInfo.BaseUrl)
- outputLanguage: $outputLanguage
- provider.generationConfig:
$generationConfigJson

Qwen settings permissions.allow 참고값:
$allowText

매 응답은 반드시 아래 규칙을 지킨다.

1. 첫 번째 줄은 반드시 다음 형식 한 줄로만 작성한다.
NEXT_QUESTION: 여기에 다음 루프에서 물어볼 구체적인 후속 질문을 한 문장으로 작성

2. NEXT_QUESTION은 이전 답변이 없어도 이해될 정도로 구체적이고 자기완결적인 질문이어야 한다.
3. 두 번째 줄부터는 현재 질문에 대한 답변을 settings.general.outputLanguage($outputLanguage)에 맞춰 자세히 작성한다.
4. 답변은 실무 개발자가 바로 사용할 수 있게 구체적으로 작성한다.
5. Java Spring Boot와 React 관점에서 구조, 위험요소, 테스트, 리팩토링, 성능, 보안, 유지보수성을 같이 고려한다.
6. 코드베이스 내용이 제공되지 않은 경우에는 추측을 확정처럼 말하지 말고, 확인해야 할 파일과 명령을 제시한다.
7. 다음 질문은 현재 답변에서 가장 중요한 미해결 지점이나 더 깊게 파고들 가치가 있는 지점으로 만든다.
8. 너무 짧게 답하지 말고, 가능한 한 깊이 있는 분석, 체크리스트, 예시, 반례, 검증 방법을 포함한다.
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

function Invoke-JsonPostUtf8([string]$Uri, $Headers, [byte[]]$BodyBytes, [int]$TimeoutSeconds) {
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
            $ms = New-Object System.IO.MemoryStream
            $respStream.CopyTo($ms)
            $bytes = $ms.ToArray()
            return [System.Text.Encoding]::UTF8.GetString($bytes)
        } finally {
            if ($respStream) { $respStream.Close() }
            if ($resp) { $resp.Close() }
        }
    } catch [System.Net.WebException] {
        $resp = $_.Exception.Response
        if ($resp) {
            $respStream = $resp.GetResponseStream()
            $ms = New-Object System.IO.MemoryStream
            if ($respStream) { $respStream.CopyTo($ms) }
            $bytes = $ms.ToArray()
            $body = [System.Text.Encoding]::UTF8.GetString($bytes)
            throw "HTTP 호출 실패: $($_.Exception.Message)`nResponse body:`n$body"
        }
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
    $headers = Build-ClientHeaders $providerInfo $settings $networkIdentity
    $bodyObj = Build-RequestBody $settings $providerInfo $systemPrompt $userPrompt $networkIdentity
    $body = $bodyObj | ConvertTo-Json -Depth 80 -Compress
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)

    Write-Utf8File (Join-Path $WorkDir "last_request_body.json") $body

    $debugHeaders = Get-LoggedHeaders $headers
    Write-Utf8File (Join-Path $WorkDir "last_request_headers.json") (($debugHeaders | ConvertTo-Json -Depth 30))
    if ($LogSensitive) { Write-Utf8File (Join-Path $WorkDir "last_request_headers_sensitive.json") (($headers | ConvertTo-Json -Depth 30)) }

    $lastError = $null
    foreach ($endpoint in (Get-EndpointCandidates $providerInfo.BaseUrl)) {
        try {
            Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] POST $endpoint" -ForegroundColor Cyan
            $raw = Invoke-JsonPostUtf8 -Uri $endpoint -Headers $headers -BodyBytes $bodyBytes -TimeoutSeconds $EffectiveTimeoutSec
            return Convert-OpenAIResponseToText $raw (-not [bool]$NonStreaming)
        } catch {
            $lastError = [string]$_.Exception.Message
            Write-Host "Endpoint failed: $endpoint" -ForegroundColor Yellow
            Write-Host $lastError -ForegroundColor Yellow
        }
    }
    throw "모든 endpoint 호출 실패. 마지막 오류: $lastError"
}

if (!(Test-Path -LiteralPath $SettingsPath)) { throw "settings.json을 찾지 못했습니다: $SettingsPath" }
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

$settingsRaw = Read-Utf8File $SettingsPath
$settings = $settingsRaw | ConvertFrom-Json
$providerInfo = Get-SettingsProvider $settings $ProviderName $ModelName
$EffectiveTimeoutSec = Get-EffectiveTimeoutSeconds $providerInfo
$networkIdentity = Get-ClientNetworkIdentity $providerInfo.BaseUrl

$nextQuestionPath = Join-Path $WorkDir "next_question.txt"
$lastTurnPath = Join-Path $WorkDir "last_turn.txt"
$transcriptPath = Join-Path $WorkDir "transcript.md"
$jsonlPath = Join-Path $WorkDir "transcript.jsonl"
$errorLogPath = Join-Path $WorkDir "error.log"

$seedQuestion = "Java Spring Boot와 React 프로젝트를 장기적으로 개선하기 위해, 먼저 백엔드 구조와 프론트엔드 연동 구조를 어떤 순서로 분석해야 하는지 알려줘."
if (Test-Path -LiteralPath $SeedFile) { $seedQuestion = (Read-Utf8File $SeedFile).Trim() }
if ([string]::IsNullOrWhiteSpace($seedQuestion)) { throw "seed_prompt.txt가 비어 있습니다: $SeedFile" }
if (!(Test-Path -LiteralPath $nextQuestionPath)) { Write-Utf8File $nextQuestionPath $seedQuestion }

$systemPrompt = Build-SettingsAwareSystemPrompt $settings $providerInfo $SettingsPath

Write-Host "=== Qwen Loop Scheduler v4 SETTINGS-FIRST ===" -ForegroundColor Green
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
Write-Host "ClientHost   : $($networkIdentity.computerName) / $($networkIdentity.userDomain)\$($networkIdentity.userName)"
Write-Host "ClientIP     : $($networkIdentity.localAddress):$($networkIdentity.localPort)"
Write-Host "CompatBody   : $CompatBody"
Write-Host "WireMode     : Qwen Code OpenAI SDK-like headers/body"
Write-Host "Stream       : $(-not [bool]$NonStreaming)"
Write-Host "HeaderLog    : $(if ($MaskSensitiveLogs -and -not $LogSensitive) { 'masked' } else { 'unmasked' })"
Write-Host "IntervalSec  : $IntervalSeconds"
Write-Host "TimeoutSec   : $EffectiveTimeoutSec"
Write-Host "WorkDir      : $WorkDir"
Write-Host "Stop         : Ctrl+C"
Write-Host "==============================================" -ForegroundColor Green

$settingsSummary = [ordered]@{
    settingsPath = $SettingsPath
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
    clientNetworkIdentity = ConvertTo-PlainObject $networkIdentity
    compatBody = [bool]$CompatBody
    stream = (-not [bool]$NonStreaming)
    timeoutSec = $EffectiveTimeoutSec
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
    $dryRunPrompt = @"
현재 루프 질문:
$seedQuestion

요청:
DryRun preview. 이 파일은 API 호출 없이 실제 전송 예정 header/body 형태를 확인하기 위한 샘플입니다.
"@
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
while ($true) {
    $runCount++
    $started = Get-Date
    try {
        $question = (Read-Utf8File $nextQuestionPath).Trim()
        if ([string]::IsNullOrWhiteSpace($question)) { $question = $seedQuestion }

        $contextBundle = Read-ContextBundle $ContextListFile $MaxContextChars
        $lastTurn = ""
        if (Test-Path -LiteralPath $lastTurnPath) { $lastTurn = Get-TextPrefix ((Read-Utf8File $lastTurnPath).Trim()) $LastTurnChars }

        $userPrompt = @"
현재 루프 질문:
$question

직전 루프 요약 컨텍스트:
$lastTurn

공통 컨텍스트:
$contextBundle

요청:
위 질문에 답변해줘.
반드시 첫 번째 줄에는 NEXT_QUESTION: 으로 시작하는 다음 후속 질문을 한 줄로 작성하고, 그 뒤에 현재 질문에 대한 상세 답변을 작성해줘.
"@

        Write-Host "`n[$($started.ToString('yyyy-MM-dd HH:mm:ss'))] QUESTION:" -ForegroundColor Green
        Write-Host $question

        $answer = Invoke-QwenChat $providerInfo $settings $networkIdentity $systemPrompt $userPrompt
        $nextQuestion = Extract-NextQuestion $answer
        $ended = Get-Date

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
            answer = $answer
        }
        Append-Utf8File $jsonlPath (($record | ConvertTo-Json -Compress -Depth 50) + "`n")

        Write-Host "`nNEXT QUESTION:" -ForegroundColor Magenta
        Write-Host $nextQuestion
        Write-Host "`nSaved:" -ForegroundColor DarkGreen
        Write-Host "- $nextQuestionPath"
        Write-Host "- $lastTurnPath"
        Write-Host "- $transcriptPath"
        Write-Host "- $jsonlPath"
        Write-Host "- $(Join-Path $WorkDir 'last_request_headers.json')"
        Write-Host "- $(Join-Path $WorkDir 'last_request_body.json')"
    } catch {
        $msg = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] ERROR: $($_.Exception.Message)`n$($_.ScriptStackTrace)`n"
        Append-Utf8File $errorLogPath $msg
        Write-Host $msg -ForegroundColor Red
    }

    if ($Once -or ($MaxRuns -gt 0 -and $runCount -ge $MaxRuns)) {
        Write-Host "`n지정된 실행 횟수만큼 실행 후 종료합니다." -ForegroundColor DarkGray
        break
    }

    Write-Host "`nWaiting $IntervalSeconds seconds... Ctrl+C to stop." -ForegroundColor DarkGray
    Start-Sleep -Seconds $IntervalSeconds
}
