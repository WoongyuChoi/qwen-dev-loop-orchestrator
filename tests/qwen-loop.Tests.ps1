$runner = Join-Path $PSScriptRoot "run-high-priority-regression.ps1"
$powerShellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

function Invoke-HighRegression([string]$Scenario) {
    $output = @(& $powerShellExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $runner -Scenario $Scenario 2>&1)
    return [PSCustomObject]@{
        ExitCode = $LASTEXITCODE
        Text = ($output -join [Environment]::NewLine)
    }
}

Describe "qwen-loop high-priority regressions" {
    It "decodes legacy Korean source files and scans deterministically within one business family" {
        $result = Invoke-HighRegression "Scanner"
        if ($result.ExitCode -ne 0) { Write-Host $result.Text }
        $result.ExitCode | Should Be 0
    }

    It "rejects shallow answers, bounds continuation attempts, and escapes to a fresh slice" {
        $result = Invoke-HighRegression "Quality"
        if ($result.ExitCode -ne 0) { Write-Host $result.Text }
        $result.ExitCode | Should Be 0
    }

    It "fails closed for malformed/unterminated protocol responses and never re-POSTs after local response acceptance fails" {
        $result = Invoke-HighRegression "Protocol"
        if ($result.ExitCode -ne 0) { Write-Host $result.Text }
        $result.ExitCode | Should Be 0
    }

    It "allows only one process to own a stable WorkDir" {
        $result = Invoke-HighRegression "Lock"
        if ($result.ExitCode -ne 0) { Write-Host $result.Text }
        $result.ExitCode | Should Be 0
    }

    It "applies settings-first endpoint, token, header, User-Agent, and coverage rules" {
        $result = Invoke-HighRegression "Settings"
        if ($result.ExitCode -ne 0) { Write-Host $result.Text }
        $result.ExitCode | Should Be 0
    }

    It "classifies empty truncation as partial, sanitizes malformed JSONL cleanup, and rolls pending turns forward without rewinding" {
        $result = Invoke-HighRegression "Recovery"
        if ($result.ExitCode -ne 0) { Write-Host $result.Text }
        $result.ExitCode | Should Be 0
    }
}
