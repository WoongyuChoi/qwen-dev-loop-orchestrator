param(
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][int]$ResponseCount,
    [Parameter(Mandatory = $true)][string]$RequestLog,
    [Parameter(Mandatory = $true)][string]$ReadyPath,
    [string]$HeaderLog = "",
    [string]$FinishReason = "stop",
    [switch]$OmitNextQuestion,
    [switch]$AppendTrailingText,
    [ValidateSet("normal", "short", "empty-partial", "quality-sequence", "partial-evidence-sequence", "interleaved-multichoice", "unterminated-sse", "sse-read-timeout", "malformed-sse", "invalid-json", "http-error")]
    [string]$Scenario = "normal",
    [int]$ResponseDelayMilliseconds = 0,
    [int]$CompletionTokens = 1800,
    [int]$ReasoningTokens = 100
)

$ErrorActionPreference = "Stop"
$utf8 = New-Object System.Text.UTF8Encoding($false)
$crlf = [string][char]13 + [string][char]10
$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()
[System.IO.File]::WriteAllText($ReadyPath, "ready", $utf8)

try {
    for ($requestNo = 1; $requestNo -le $ResponseCount; $requestNo++) {
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $headerBuffer = New-Object System.IO.MemoryStream
            $tail = New-Object System.Collections.Generic.Queue[byte]
            while ($true) {
                $value = $stream.ReadByte()
                if ($value -lt 0) { throw "Unexpected EOF while reading request headers." }
                $headerBuffer.WriteByte([byte]$value)
                $tail.Enqueue([byte]$value)
                while ($tail.Count -gt 4) { [void]$tail.Dequeue() }
                if ($tail.Count -eq 4) {
                    $last = $tail.ToArray()
                    if ($last[0] -eq 13 -and $last[1] -eq 10 -and $last[2] -eq 13 -and $last[3] -eq 10) { break }
                }
            }
            $headerText = [System.Text.Encoding]::ASCII.GetString($headerBuffer.ToArray())
            if (-not [string]::IsNullOrWhiteSpace($HeaderLog)) {
                [System.IO.File]::AppendAllText($HeaderLog, "--- REQUEST $requestNo ---" + [Environment]::NewLine + $headerText, $utf8)
            }
            $contentLength = 0
            if ($headerText -match '(?im)^Content-Length:\s*(\d+)\s*$') { $contentLength = [int]$Matches[1] }
            $bodyBuffer = New-Object byte[] $contentLength
            $read = 0
            while ($read -lt $contentLength) {
                $count = $stream.Read($bodyBuffer, $read, $contentLength - $read)
                if ($count -le 0) { break }
                $read += $count
            }
            $requestBody = if ($read -gt 0) { $utf8.GetString($bodyBuffer, 0, $read) } else { "" }
            [System.IO.File]::AppendAllText($RequestLog, $requestBody + [Environment]::NewLine, $utf8)
            $requestObject = $requestBody | ConvertFrom-Json
            $requestStreaming = [bool]$requestObject.stream

            if ($ResponseDelayMilliseconds -gt 0) {
                Start-Sleep -Milliseconds $ResponseDelayMilliseconds
            }

            $effectiveScenario = if ($Scenario -eq "quality-sequence") {
                if ($requestNo -le 3) { "short" } else { "rich" }
            } elseif ($Scenario -eq "partial-evidence-sequence") {
                "partial-evidence"
            } else {
                $Scenario
            }
            $holdOpenAfterBodyMilliseconds = 0

            if ($effectiveScenario -eq "http-error") {
                $responseBody = ([ordered]@{
                    error = [ordered]@{
                        message = "mock upstream failure"
                        type = "mock_server_error"
                        code = "mock_failure"
                    }
                } | ConvertTo-Json -Compress -Depth 10)
                $contentType = "application/json; charset=utf-8"
                $statusLine = "HTTP/1.1 500 Internal Server Error"
            } elseif ($effectiveScenario -eq "invalid-json") {
                $responseBody = '{"choices":['
                $contentType = "application/json; charset=utf-8"
                $statusLine = "HTTP/1.1 200 OK"
            } elseif ($effectiveScenario -eq "malformed-sse") {
                $validPrefix = ([ordered]@{
                    id = "mock-$requestNo"
                    choices = @([ordered]@{ index = 0; delta = [ordered]@{ content = "MALFORMED_STREAM_PREFIX" }; finish_reason = $null })
                } | ConvertTo-Json -Compress -Depth 10)
                $responseBody = "data: " + $validPrefix + $crlf + $crlf + "data: {this-is-not-json}" + $crlf + $crlf + "data: [DONE]" + $crlf + $crlf
                $contentType = "text/event-stream; charset=utf-8"
                $statusLine = "HTTP/1.1 200 OK"
            } elseif ($effectiveScenario -eq "unterminated-sse") {
                if (-not $requestStreaming) { throw "unterminated-sse requires a streaming request" }
                $unterminatedAnswer = "UNTERMINATED_STREAM_TEXT" + [Environment]::NewLine + "NEXT_QUESTION: UNTERMINATED_MODEL_NEXT"
                $unterminatedContent = ([ordered]@{
                    id = "mock-$requestNo"
                    choices = @([ordered]@{ index = 0; delta = [ordered]@{ content = $unterminatedAnswer }; finish_reason = $null })
                } | ConvertTo-Json -Compress -Depth 10)
                $unterminatedUsage = ([ordered]@{
                    id = "mock-$requestNo"
                    choices = @()
                    usage = [ordered]@{
                        prompt_tokens = 21000
                        completion_tokens = 120
                        total_tokens = 21120
                        completion_tokens_details = [ordered]@{ reasoning_tokens = 10 }
                    }
                } | ConvertTo-Json -Compress -Depth 10)
                # Intentionally close the response after valid SSE events but
                # without either primary finish_reason or the [DONE] sentinel.
                $responseBody = "data: " + $unterminatedContent + $crlf + $crlf + "data: " + $unterminatedUsage + $crlf + $crlf
                $contentType = "text/event-stream; charset=utf-8"
                $statusLine = "HTTP/1.1 200 OK"
            } elseif ($effectiveScenario -eq "sse-read-timeout") {
                if (-not $requestStreaming) { throw "sse-read-timeout requires a streaming request" }
                $timeoutPrefix = ([ordered]@{
                    id = "mock-$requestNo"
                    choices = @([ordered]@{ index = 0; delta = [ordered]@{ content = "TIMEOUT_STREAM_PREFIX" }; finish_reason = $null })
                } | ConvertTo-Json -Compress -Depth 10)
                # Send a valid 200/SSE event immediately, then neither close
                # the response nor send [DONE].  The client must treat the
                # ensuing read timeout as post-response uncertainty and must
                # never replay this already-accepted POST.
                $responseBody = "data: " + $timeoutPrefix + $crlf + $crlf
                $contentType = "text/event-stream; charset=utf-8"
                $statusLine = "HTTP/1.1 200 OK"
                $holdOpenAfterBodyMilliseconds = 4000
            } elseif ($effectiveScenario -eq "interleaved-multichoice") {
                if (-not $requestStreaming) { throw "interleaved-multichoice requires a streaming request" }
                $indexZeroPartA = "INDEX0_PART_A "
                $indexZeroPartB = "INDEX0_PART_B" + [Environment]::NewLine + "NEXT_QUESTION: INDEX0_NEXT"
                $indexOneText = "INDEX1_SHOULD_NOT_APPEAR"
                $events = @(
                    ([ordered]@{
                        id = "mock-$requestNo"
                        choices = @([ordered]@{ index = 0; delta = [ordered]@{ content = $indexZeroPartA }; finish_reason = $null })
                    } | ConvertTo-Json -Compress -Depth 10),
                    ([ordered]@{
                        id = "mock-$requestNo"
                        choices = @([ordered]@{ index = 1; delta = [ordered]@{ content = $indexOneText }; finish_reason = $null })
                    } | ConvertTo-Json -Compress -Depth 10),
                    ([ordered]@{
                        id = "mock-$requestNo"
                        choices = @([ordered]@{ index = 0; delta = [ordered]@{ content = $indexZeroPartB }; finish_reason = $null })
                    } | ConvertTo-Json -Compress -Depth 10),
                    ([ordered]@{
                        id = "mock-$requestNo"
                        choices = @(
                            [ordered]@{ index = 1; delta = [ordered]@{ content = "" }; finish_reason = "stop" },
                            [ordered]@{ index = 0; delta = [ordered]@{ content = "" }; finish_reason = "stop" }
                        )
                    } | ConvertTo-Json -Compress -Depth 10),
                    ([ordered]@{
                        id = "mock-$requestNo"
                        choices = @()
                        usage = [ordered]@{
                            prompt_tokens = 21000
                            completion_tokens = 120
                            total_tokens = 21120
                            completion_tokens_details = [ordered]@{ reasoning_tokens = 10 }
                        }
                    } | ConvertTo-Json -Compress -Depth 10)
                )
                $responseBody = (($events | ForEach-Object { "data: " + $_ + $crlf + $crlf }) -join "") + "data: [DONE]" + $crlf + $crlf
                $contentType = "text/event-stream; charset=utf-8"
                $statusLine = "HTTP/1.1 200 OK"
            } else {
                $effectiveCompletionTokens = if ($effectiveScenario -eq "empty-partial") { 0 } elseif ($effectiveScenario -in @("short", "partial-evidence")) { 60 } elseif ($effectiveScenario -eq "rich") { 4200 } else { $CompletionTokens }
                $effectiveReasoningTokens = if ($effectiveScenario -eq "empty-partial") { 0 } elseif ($effectiveScenario -in @("short", "partial-evidence")) { 10 } elseif ($effectiveScenario -eq "rich") { 200 } else { $ReasoningTokens }

                $next = if ($requestNo -eq 5) { "SHOULD_NOT_BE_USED_AFTER_CYCLE" } else { "FOLLOWUP_$requestNo" }
                if ($effectiveScenario -eq "empty-partial") {
                    $answerContent = ""
                } elseif ($effectiveScenario -eq "short") {
                    $answerContent = "짧은 일반론 답변입니다."
                } elseif ($effectiveScenario -eq "partial-evidence") {
                    if ($requestNo -eq 1) {
                        $answerContent = "FIRST_PARTIAL_EVIDENCE_SENTINEL`n확인된 업무 근거: 주문 담당자가 기준일 마감 배치를 실행하고 TB_ORDER_CONFIRM 테이블의 ORDER_STATUS 컬럼을 조회하여 orderStatus 필드에 담은 뒤 CONFIRMED 상태를 downstream 정산에 전달합니다."
                    } else {
                        $answerContent = "SECOND_PARTIAL_EVIDENCE_SENTINEL`n추가 확인된 업무 근거: 환불 담당자가 요청 상태를 판단하고 TB_REFUND_PAYMENT 테이블의 PAYMENT_STATUS 컬럼을 refundStatus 필드로 변환하여 저장한 결과를 후속 소비자가 사용합니다."
                    }
                } elseif ($effectiveScenario -eq "rich") {
                    $richLine = "확인된 업무 근거: 주문 담당자가 마감 배치에서 주문확정 업무를 수행하며 Ord1001Mapper.xml의 TB_ORDER_CONFIRM 테이블과 ORDER_STATUS 컬럼을 읽고, Ord1001OrderVo.orderStatus 필드와 JobParameter 기준일을 검증한 뒤 상태를 CONFIRMED로 저장하여 정산 downstream이 소비합니다. 입력→조회→판단→변환→저장→후속 소비 정상 흐름과 Mapper statement, VO/DTO 필드, 상태값 근거를 구분합니다."
                    $answerContent = ((1..70 | ForEach-Object { "${_}. $richLine" }) -join [Environment]::NewLine)
                } else {
                    $answerContent = "BUSINESS_EVIDENCE_RESPONSE_$requestNo"
                }
                if (-not $OmitNextQuestion) { $answerContent += [Environment]::NewLine + "NEXT_QUESTION: $next" }
                if ($AppendTrailingText) { $answerContent += [Environment]::NewLine + "TRAILING_TEXT_AFTER_CONTROL_LINE" }
                $part1 = ([ordered]@{
                    id = "mock-$requestNo"
                    choices = @([ordered]@{ index = 0; delta = [ordered]@{ content = $answerContent }; finish_reason = $null })
                } | ConvertTo-Json -Compress -Depth 10)
                $part2 = ([ordered]@{
                    id = "mock-$requestNo"
                    choices = @([ordered]@{ index = 0; delta = [ordered]@{ content = "" }; finish_reason = $FinishReason })
                } | ConvertTo-Json -Compress -Depth 10)
                $usage = ([ordered]@{
                    id = "mock-$requestNo"
                    choices = @()
                    usage = [ordered]@{
                        prompt_tokens = 21000
                        completion_tokens = $effectiveCompletionTokens
                        total_tokens = (21000 + $effectiveCompletionTokens)
                        completion_tokens_details = [ordered]@{ reasoning_tokens = $effectiveReasoningTokens }
                    }
                } | ConvertTo-Json -Compress -Depth 10)
                if (-not $requestStreaming) {
                    $responseObject = [ordered]@{
                        id = "mock-$requestNo"
                        choices = @([ordered]@{
                            index = 0
                            message = [ordered]@{ role = "assistant"; content = $answerContent }
                            finish_reason = $FinishReason
                        })
                        usage = [ordered]@{
                            prompt_tokens = 21000
                            completion_tokens = $effectiveCompletionTokens
                            total_tokens = (21000 + $effectiveCompletionTokens)
                            completion_tokens_details = [ordered]@{ reasoning_tokens = $effectiveReasoningTokens }
                        }
                    }
                    $responseBody = $responseObject | ConvertTo-Json -Compress -Depth 15
                    $contentType = "application/json; charset=utf-8"
                } else {
                    $responseBody = "data: " + $part1 + $crlf + $crlf + "data: " + $part2 + $crlf + $crlf + "data: " + $usage + $crlf + $crlf + "data: [DONE]" + $crlf + $crlf
                    $contentType = "text/event-stream; charset=utf-8"
                }
                $statusLine = "HTTP/1.1 200 OK"
            }
            $bodyBytes = $utf8.GetBytes($responseBody)
            if ($holdOpenAfterBodyMilliseconds -gt 0) {
                $header = $statusLine + $crlf + "Content-Type: " + $contentType + $crlf + "Connection: keep-alive" + $crlf + $crlf
            } else {
                $header = $statusLine + $crlf + "Content-Type: " + $contentType + $crlf + "Content-Length: " + $bodyBytes.Length + $crlf + "Connection: close" + $crlf + $crlf
            }
            $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
            $stream.Write($headerBytes, 0, $headerBytes.Length)
            $stream.Write($bodyBytes, 0, $bodyBytes.Length)
            $stream.Flush()
            if ($holdOpenAfterBodyMilliseconds -gt 0) {
                Start-Sleep -Milliseconds $holdOpenAfterBodyMilliseconds
            }
        } finally {
            $client.Close()
        }
    }
} finally {
    $listener.Stop()
}
