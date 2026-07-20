param(
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][int]$ResponseCount,
    [Parameter(Mandatory = $true)][string]$RequestLog,
    [Parameter(Mandatory = $true)][string]$ReadyPath,
    [string]$FinishReason = "stop",
    [switch]$OmitNextQuestion,
    [switch]$AppendTrailingText
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

            $next = if ($requestNo -eq 5) { "SHOULD_NOT_BE_USED_AFTER_CYCLE" } else { "FOLLOWUP_$requestNo" }
            $answerContent = "BUSINESS_EVIDENCE_RESPONSE_$requestNo"
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
                    completion_tokens = 1800
                    total_tokens = 22800
                    completion_tokens_details = [ordered]@{ reasoning_tokens = 100 }
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
                        completion_tokens = 1800
                        total_tokens = 22800
                        completion_tokens_details = [ordered]@{ reasoning_tokens = 100 }
                    }
                }
                $responseBody = $responseObject | ConvertTo-Json -Compress -Depth 15
                $contentType = "application/json; charset=utf-8"
            } else {
                $responseBody = "data: " + $part1 + $crlf + $crlf + "data: " + $part2 + $crlf + $crlf + "data: " + $usage + $crlf + $crlf + "data: [DONE]" + $crlf + $crlf
                $contentType = "text/event-stream; charset=utf-8"
            }
            $bodyBytes = $utf8.GetBytes($responseBody)
            $header = "HTTP/1.1 200 OK" + $crlf + "Content-Type: " + $contentType + $crlf + "Content-Length: " + $bodyBytes.Length + $crlf + "Connection: close" + $crlf + $crlf
            $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
            $stream.Write($headerBytes, 0, $headerBytes.Length)
            $stream.Write($bodyBytes, 0, $bodyBytes.Length)
            $stream.Flush()
        } finally {
            $client.Close()
        }
    }
} finally {
    $listener.Stop()
}
