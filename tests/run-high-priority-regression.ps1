param(
    [ValidateSet("All", "Scanner", "Quality", "Protocol", "Lock", "Settings", "Recovery")]
    [string]$Scenario = "All",
    [switch]$KeepArtifacts
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repo "qwen-loop.ps1"
$mockHelper = Join-Path $PSScriptRoot "helpers\mock-openai-sse.ps1"
$businessFixture = Join-Path $PSScriptRoot "fixtures\business-project"
$powerShellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$utf8 = New-Object System.Text.UTF8Encoding($false)
$runId = (Get-Date -Format "yyyyMMdd-HHmmss-fff") + "-" + [Guid]::NewGuid().ToString("N").Substring(0, 8)
$runtime = Join-Path $repo ("qwen-loop-data\_high-regression-" + $runId)
$servers = New-Object System.Collections.Generic.List[object]
$backgroundProcesses = New-Object System.Collections.Generic.List[object]
New-Item -ItemType Directory -Force -Path $runtime | Out-Null

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Get-FreeTcpPort {
    $probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $probe.Start()
    try { return ([System.Net.IPEndPoint]$probe.LocalEndpoint).Port }
    finally { $probe.Stop() }
}

function Write-TestSettings([string]$Path, [int]$Port, [string]$ApiKey = "local-test-key") {
    $settings = [ordered]@{
        modelProviders = [ordered]@{
            openai = @([ordered]@{
                id = "mock-high-regression"
                name = "mock-high-regression"
                baseUrl = "http://127.0.0.1:$Port"
                envKey = "MOCK_QWEN_API_KEY"
                generationConfig = [ordered]@{ modalities = [ordered]@{ image = $false } }
            })
        }
        env = [ordered]@{ MOCK_QWEN_API_KEY = $ApiKey }
        security = [ordered]@{ auth = [ordered]@{ selectedType = "openai" } }
        general = [ordered]@{ outputLanguage = "Korean" }
        permissions = [ordered]@{ allow = @("Read(**)") }
        ui = [ordered]@{ autoModeAcknowledged = $true }
        '$version' = 4
        model = [ordered]@{ name = "mock-high-regression" }
    }
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [System.IO.File]::WriteAllText($Path, ($settings | ConvertTo-Json -Depth 30), $utf8)
}

function Write-TestSettingsVariant(
    [string]$Path,
    [int]$Port,
    [string]$BaseUrl = "",
    $GenerationConfig = $null,
    [int]$SettingsVersion = 4,
    [string]$ApiKey = "local-test-key"
) {
    Write-TestSettings $Path $Port $ApiKey
    $settings = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not [string]::IsNullOrWhiteSpace($BaseUrl)) {
        $settings.modelProviders.openai[0].baseUrl = $BaseUrl
    }
    if ($null -ne $GenerationConfig) {
        $settings.modelProviders.openai[0].generationConfig = $GenerationConfig
    }
    $settings.'$version' = $SettingsVersion
    [System.IO.File]::WriteAllText($Path, ($settings | ConvertTo-Json -Depth 30), $utf8)
}

function Invoke-Loop([string[]]$Arguments) {
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = @(& $powerShellExe @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedPreference
    }
    return [PSCustomObject]@{
        ExitCode = $exitCode
        Output = $output
        Text = ($output -join [Environment]::NewLine)
    }
}

function Get-BaseLoopArguments([string]$SettingsPath, [string]$WorkDir, [int]$MaxRetryCount = 0, [int]$TimeoutSeconds = 15) {
    return @(
        "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $scriptPath,
        "-SettingsPath", $SettingsPath, "-WorkDir", $WorkDir,
        "-MaxRetries", ([string]$MaxRetryCount), "-TimeoutSec", ([string]$TimeoutSeconds),
        "-NoCountdown", "-NoBanner", "-NoAnswerPreview", "-NoAutoCleanup"
    )
}

function Invoke-ProjectDryRun([string]$SettingsPath, [string]$ProjectRoot, [string]$WorkDir) {
    $arguments = @(Get-BaseLoopArguments $SettingsPath $WorkDir) + @(
        "-ProjectRoot", $ProjectRoot, "-FreshProjectQuestion", "-DryRun",
        "-ProjectScanMaxFiles", "200", "-ProjectScanMaxFileChars", "12000",
        "-ProjectScanMaxTotalChars", "60000", "-ProjectCandidateMaxFiles", "10000"
    )
    return Invoke-Loop $arguments
}

function Start-MockServer(
    [int]$Port,
    [int]$ResponseCount,
    [string]$RequestLog,
    [string]$ReadyPath,
    [string]$MockScenario = "normal",
    [int]$DelayMilliseconds = 0,
    [string]$HeaderLog = "",
    [string]$FinishReason = "stop",
    [bool]$OmitNextQuestion = $false
) {
    $argumentLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $mockHelper +
        '" -Port ' + $Port +
        ' -ResponseCount ' + $ResponseCount +
        ' -RequestLog "' + $RequestLog +
        '" -ReadyPath "' + $ReadyPath +
        '" -Scenario ' + $MockScenario +
        ' -ResponseDelayMilliseconds ' + $DelayMilliseconds +
        ' -FinishReason ' + $FinishReason
    if (-not [string]::IsNullOrWhiteSpace($HeaderLog)) {
        $argumentLine += ' -HeaderLog "' + $HeaderLog + '"'
    }
    if ($OmitNextQuestion) { $argumentLine += ' -OmitNextQuestion' }
    $process = Start-Process -FilePath $powerShellExe -ArgumentList $argumentLine -PassThru -WindowStyle Hidden
    $servers.Add($process) | Out-Null
    for ($i = 0; $i -lt 200 -and -not (Test-Path -LiteralPath $ReadyPath -PathType Leaf); $i++) {
        Start-Sleep -Milliseconds 25
    }
    Assert-True (Test-Path -LiteralPath $ReadyPath -PathType Leaf) "mock server did not become ready for $MockScenario"
    return $process
}

function Wait-MockServer($Server, [int]$Milliseconds = 5000) {
    [void]$Server.WaitForExit($Milliseconds)
    Assert-True $Server.HasExited "mock server did not receive the expected request count"
    Assert-True ($Server.ExitCode -eq 0) "mock server exited with $($Server.ExitCode)"
}

function Read-Json([string]$Path) {
    Assert-True (Test-Path -LiteralPath $Path -PathType Leaf) "missing JSON artifact: $Path"
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Read-JsonLines([string]$Path) {
    Assert-True (Test-Path -LiteralPath $Path -PathType Leaf) "missing JSONL artifact: $Path"
    return @(Get-Content -LiteralPath $Path -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
}

function Assert-ConfiguredArrayShape($SamplingObject, $ExtraBodyObject, [string]$Label) {
    Assert-True ($null -ne $SamplingObject -and $SamplingObject.stop -is [System.Array] -and $SamplingObject.stop.Count -eq 1 -and [string]$SamplingObject.stop[0] -eq "STOP_SINGLETON_LITERAL") "$Label collapsed samplingParams.stop singleton array"
    Assert-True ($null -ne $ExtraBodyObject -and $ExtraBodyObject.empty_array -is [System.Array] -and $ExtraBodyObject.empty_array.Count -eq 0) "$Label collapsed or removed extra_body empty array"
    Assert-True ($ExtraBodyObject.single_array -is [System.Array] -and $ExtraBodyObject.single_array.Count -eq 1 -and [string]$ExtraBodyObject.single_array[0] -eq "EXTRA_SINGLETON_LITERAL") "$Label collapsed extra_body singleton array"
    Assert-True ($ExtraBodyObject.nested_array -is [System.Array] -and $ExtraBodyObject.nested_array.Count -eq 2 -and $ExtraBodyObject.nested_array[0] -is [System.Array] -and $ExtraBodyObject.nested_array[0].Count -eq 2 -and [string]$ExtraBodyObject.nested_array[0][0] -eq "NESTED_ARRAY_A" -and [string]$ExtraBodyObject.nested_array[0][1] -eq "NESTED_ARRAY_B" -and $ExtraBodyObject.nested_array[1] -is [System.Array] -and $ExtraBodyObject.nested_array[1].Count -eq 1 -and [string]$ExtraBodyObject.nested_array[1][0] -eq "NESTED_ARRAY_C") "$Label did not preserve nested array shape"
}

function Test-ScannerRegressions {
    Write-Host "[Scanner] CP949/EUC-KR, >120 deterministic discovery, business-family isolation" -ForegroundColor Cyan
    $settingsPath = Join-Path $runtime "scanner-settings.json"
    Write-TestSettings $settingsPath 9

    $cp949Root = Join-Path $runtime "projects\cp949-business"
    $cp949MapperDir = Join-Path $cp949Root "src\main\resources\mapper"
    $cp949JavaDir = Join-Path $cp949Root "src\main\java\example\kor"
    New-Item -ItemType Directory -Force -Path $cp949MapperDir, $cp949JavaDir | Out-Null
    $cp949 = [System.Text.Encoding]::GetEncoding(949)
    $mapperText = @'
<?xml version="1.0" encoding="EUC-KR"?>
<!-- 주문확정상태와 배송완료여부를 확인하는 업무 SQL -->
<mapper namespace="Kor9001Mapper">
  <select id="selectOrderConfirmation">SELECT ORDER_STATUS, DELIVERY_COMPLETE_YN FROM TB_ORDER_CONFIRM</select>
</mapper>
'@
    $voText = @'
package example.kor;
// 주문확정상태를 정산 시스템에 전달하는 업무 데이터
public class Kor9001OrderVo {
    private String orderConfirmationStatus;
    private String deliveryCompleteYn;
}
'@
    [System.IO.File]::WriteAllBytes((Join-Path $cp949MapperDir "Kor9001Mapper.xml"), $cp949.GetBytes($mapperText))
    [System.IO.File]::WriteAllBytes((Join-Path $cp949JavaDir "Kor9001OrderVo.java"), $cp949.GetBytes($voText))
    $cp949Work = Join-Path $runtime "work\cp949"
    $cp949Result = Invoke-ProjectDryRun $settingsPath $cp949Root $cp949Work
    Assert-True ($cp949Result.ExitCode -eq 0) ("CP949 DryRun failed:`n" + $cp949Result.Text)
    $cp949Scan = Read-Json (Join-Path $cp949Work "project_scan_summary.json")
    $cp949Prompt = [string]$cp949Scan.promptContext
    Assert-True $cp949Prompt.Contains("주문확정상태") "CP949/EUC-KR Korean comment was not decoded into scan context"
    Assert-True $cp949Prompt.Contains("배송완료여부") "CP949 Java Korean comment was not decoded into scan context"
    Assert-True (-not $cp949Prompt.Contains([char]0xFFFD)) "replacement characters leaked from CP949/EUC-KR decoding"

    $largeRoot = Join-Path $runtime "projects\large-directory"
    $largeJavaDir = Join-Path $largeRoot "src\main\java\example\bulk"
    $largeMapperDir = Join-Path $largeRoot "src\main\resources\mapper"
    New-Item -ItemType Directory -Force -Path $largeJavaDir, $largeMapperDir | Out-Null
    for ($i = 0; $i -lt 150; $i++) {
        $name = "Filler{0:D3}" -f $i
        [System.IO.File]::WriteAllText((Join-Path $largeJavaDir ($name + ".java")), "package example.bulk; public class $name { private String value; }", $utf8)
    }
    [System.IO.File]::WriteAllText((Join-Path $largeJavaDir "Zzz9001OrderVo.java"), "package example.bulk; public class Zzz9001OrderVo { private String settlementStatus; }", $utf8)
    [System.IO.File]::WriteAllText((Join-Path $largeMapperDir "Zzz9001Mapper.xml"), '<mapper namespace="Zzz9001Mapper"><select id="findSettlement">SELECT SETTLEMENT_STATUS FROM TB_ZZZ_SETTLEMENT</select></mapper>', $utf8)
    $largeWorkA = Join-Path $runtime "work\large-a"
    $largeWorkB = Join-Path $runtime "work\large-b"
    $largeResultA = Invoke-ProjectDryRun $settingsPath $largeRoot $largeWorkA
    $largeResultB = Invoke-ProjectDryRun $settingsPath $largeRoot $largeWorkB
    Assert-True ($largeResultA.ExitCode -eq 0) ("first >120-file DryRun failed:`n" + $largeResultA.Text)
    Assert-True ($largeResultB.ExitCode -eq 0) ("second >120-file DryRun failed:`n" + $largeResultB.Text)
    $largeScanA = Read-Json (Join-Path $largeWorkA "project_scan_summary.json")
    $largeScanB = Read-Json (Join-Path $largeWorkB "project_scan_summary.json")
    Assert-True ([int]$largeScanA.scannedFileCount -eq 152) "scanner did not discover every one of 152 eligible files in one directory"
    Assert-True ([int]$largeScanB.scannedFileCount -eq 152) "repeated scan changed the discovered file count"
    Assert-True ([int]$largeScanA.candidateIndex.files -eq 152 -and -not [bool]$largeScanA.candidateIndex.truncated) "candidate index unexpectedly truncated the >120-file directory"
    $selectedA = @($largeScanA.selectedFiles | ForEach-Object { [string]$_.path })
    $selectedB = @($largeScanB.selectedFiles | ForEach-Object { [string]$_.path })
    Assert-True ($selectedA -contains "src\main\resources\mapper\Zzz9001Mapper.xml") "late-sorted high-value Mapper was not retained"
    Assert-True (($selectedA -join "|") -eq ($selectedB -join "|")) "deterministic scans produced different selected-file ordering"

    $familyWork = Join-Path $runtime "work\family-isolation"
    $familyResult = Invoke-ProjectDryRun $settingsPath $businessFixture $familyWork
    Assert-True ($familyResult.ExitCode -eq 0) ("business-family DryRun failed:`n" + $familyResult.Text)
    $familyScan = Read-Json (Join-Path $familyWork "project_scan_summary.json")
    $primaryFamily = ([string]$familyScan.primaryBusinessFamily).ToLowerInvariant()
    Assert-True ($primaryFamily -in @("ord1001", "rfd2001")) "fixture did not produce a concrete primary business family"
    $otherPrefix = if ($primaryFamily -eq "ord1001") { "Rfd2001" } else { "Ord1001" }
    $expectedTable = if ($primaryFamily -eq "ord1001") { "TB_SHIPMENT_BASE" } else { "TB_REFUND_PAYMENT" }
    $expectedField = if ($primaryFamily -eq "ord1001") { "shipmentStatus" } else { "paymentStatus" }
    $familyPrompt = [string]$familyScan.promptContext
    Assert-True (-not $familyPrompt.Contains($otherPrefix)) "another business family's class/file name leaked into the active prompt slice"
    Assert-True $familyPrompt.Contains($expectedTable) "active family Mapper table evidence is absent"
    Assert-True $familyPrompt.Contains($expectedField) "active family VO field evidence is absent"
    Assert-True (@($familyScan.questionCandidateDetails | Where-Object { ([string]$_.businessFamilyKey).ToLowerInvariant() -ne $primaryFamily }).Count -eq 0) "question candidates crossed the active business family"

    $linkedRoot = Join-Path $runtime "projects\linked-tail-business"
    $activeJavaDir = Join-Path $linkedRoot "src\main\java\example\act"
    $linkedJavaDir = Join-Path $linkedRoot "src\main\java\example\pay"
    $unlinkedJavaDir = Join-Path $linkedRoot "src\main\java\example\bad"
    $activeMapperDir = Join-Path $linkedRoot "src\main\resources\mapper"
    New-Item -ItemType Directory -Force -Path $activeJavaDir, $linkedJavaDir, $unlinkedJavaDir, $activeMapperDir | Out-Null
    $fillerLines = ((1..110 | ForEach-Object { "<!-- filler-$($_): abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -->" }) -join [Environment]::NewLine)
    $activeMapper = @"
<mapper namespace="example.act.Act1001Mapper">
$fillerLines
<!-- 5KB 이후 월말 정산 확정 상태와 대상 테이블 근거 -->
<resultMap id="tailSettlementMap" type="example.pay.Pay9002PaymentVo">
  <result property="linkedCrossFamilyPaymentStatus" column="TAIL_RECONCILIATION_STATUS" />
</resultMap>
<select id="selectTailSettlement" resultType="example.pay.Pay9002PaymentVo">
  SELECT TAIL_RECONCILIATION_STATUS FROM TB_ACT_TAIL_SETTLEMENT
</select>
<!-- AKIAABCDEFGHIJKLMNOP -->
<!-- ghp_GITHUBPAYLOADSENTINEL123456789 -->
<!-- sk-OPENAIPAYLOADSENTINEL123456789 -->
<!-- Bearer BEARERPAYLOADSENTINEL123456789 -->
<!-- https://dbuser:URLCREDENTIALSENTINEL@db.internal/settlement -->
<!-- -----BEGIN PRIVATE KEY----- -->
PEM_PRIVATE_KEY_PAYLOAD_SENTINEL
<!-- -----END PRIVATE KEY----- -->
</mapper>
"@
    $javaFiller = ((1..110 | ForEach-Object { "    // filler-$($_): abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" }) -join [Environment]::NewLine)
    $activeVo = @"
package example.act;
public class Act1001OrderVo {
$javaFiller
    // 5KB 이후 정산 확정 상태 업무 필드
    private String tailReconciliationStatus;
}
"@
    $activeService = @'
package example.act;
import example.pay.Pay9002PaymentVo;
public class Act1001Service {
    private Pay9002PaymentVo loadTailSettlement() { return null; }
}
'@
    $activeTasklet = @'
package example.act;
public class Act1001Tasklet {
    private Act1001Service service;
    public void execute() { service.loadTailSettlement(); }
}
'@
    $linkedVo = @'
package example.pay;
public class Pay9002PaymentVo {
    // active Mapper resultType/import가 정확히 연결한 타 family 증거
    private String linkedCrossFamilyPaymentStatus;
}
'@
    $unlinkedVo = @'
package example.bad;
public class Bad8003SecretVo {
    // 어디에서도 참조하지 않은 타 family 데이터
    private String unreferencedCrossFamilyLeak;
}
'@
    $kubernetesManifest = @'
apiVersion: v1
kind: Secret
metadata:
  name: act1001-runtime
stringData:
  token: KUBE_SECRET_PAYLOAD_SENTINEL
'@
    $minifiedKubernetesSecret = '{"apiVersion":"v1","kind":"Secret","metadata":{"name":"act1001-minified"},"data":{"totallyArbitraryCredentialName":"SzhTX01JTklGSUVEX0tVQkVfU0VDUkVUX1BBWUxPQURfU0VOVElORUw="}}'
    $jsonNextLineConfig = @'
{
  "businessTable": "TB_ACT_TAIL_SETTLEMENT",
  "password":
  "JSON_NEXT_LINE_SECRET_PAYLOAD_SENTINEL",
  "statusColumn": "TAIL_RECONCILIATION_STATUS"
}
'@
    $multilineConfig = @'
businessMode: tail-settlement
apiKey: |-
  YAML_MULTILINE_SECRET_SENTINEL
  YAML_MULTILINE_SECOND_SECRET_SENTINEL
authorization: {
  bearer: NESTED_YAML_SECRET_PAYLOAD_SENTINEL
}
statusColumn: TAIL_RECONCILIATION_STATUS
'@
    $privateKeyConfig = @'
<signingConfig businessTable="TB_ACT_TAIL_SETTLEMENT">
  <!-- -----BEGIN PRIVATE KEY----- -->
  PEM_PRIVATE_KEY_PAYLOAD_SENTINEL
  <!-- -----END PRIVATE KEY----- -->
  <clientSecret>
    XML_NESTED_SECRET_PAYLOAD_SENTINEL
    <nested>XML_DEEP_SECRET_PAYLOAD_SENTINEL</nested>
  </clientSecret>
  <clientSecret
    encrypted="true">
    XML_DIRECT_ELEMENT_MULTILINE_PAYLOAD_SENTINEL
  </clientSecret>
  <purpose>월말 정산 결과 서명</purpose>
</signingConfig>
'@
    $springPasswordConfig = @'
<beans businessTable="TB_ACT_TAIL_SETTLEMENT">
  <bean id="act1001DataSource" class="example.act.Act1001DataSource">
    <property
      name="password"
      value="SPRING_XML_PASSWORD_PAYLOAD_SENTINEL" />
    <property
      name="password">
      <value>XML_CHILD_SECRET_PAYLOAD_SENTINEL</value>
    </property>
  </bean>
</beans>
'@
    $propertiesContinuationConfig = @'
business.table=TB_ACT_TAIL_SETTLEMENT
integration.client-secret=PROPERTIES_CONTINUATION_SECRET_FIRST\
PROPERTIES_CONTINUATION_SECRET_SECOND\
PROPERTIES_CONTINUATION_SECRET_THIRD
business.status-column=TAIL_RECONCILIATION_STATUS
'@
    [System.IO.File]::WriteAllText((Join-Path $activeMapperDir "Act1001Mapper.xml"), $activeMapper, $utf8)
    [System.IO.File]::WriteAllText((Join-Path $activeMapperDir "Act1001KubeManifest.yaml"), $kubernetesManifest, $utf8)
    # Keep the filename neutral so the document reaches the sanitizer instead
    # of being excluded by the scanner's secret-looking filename boundary.
    [System.IO.File]::WriteAllText((Join-Path $activeMapperDir "Act1001MinifiedRuntime.json"), $minifiedKubernetesSecret, $utf8)
    [System.IO.File]::WriteAllText((Join-Path $activeMapperDir "Act1001BusinessRuntime.json"), $jsonNextLineConfig, $utf8)
    [System.IO.File]::WriteAllText((Join-Path $activeMapperDir "Act1001RuntimeConfig.yaml"), $multilineConfig, $utf8)
    [System.IO.File]::WriteAllText((Join-Path $activeMapperDir "Act1001SigningConfig.xml"), $privateKeyConfig, $utf8)
    [System.IO.File]::WriteAllText((Join-Path $activeMapperDir "Act1001SpringSecurity.xml"), $springPasswordConfig, $utf8)
    [System.IO.File]::WriteAllText((Join-Path $activeMapperDir "Act1001Runtime.properties"), $propertiesContinuationConfig, $utf8)
    [System.IO.File]::WriteAllText((Join-Path $activeJavaDir "Act1001OrderVo.java"), $activeVo, $utf8)
    [System.IO.File]::WriteAllText((Join-Path $activeJavaDir "Act1001Service.java"), $activeService, $utf8)
    [System.IO.File]::WriteAllText((Join-Path $activeJavaDir "Act1001Tasklet.java"), $activeTasklet, $utf8)
    [System.IO.File]::WriteAllText((Join-Path $linkedJavaDir "Pay9002PaymentVo.java"), $linkedVo, $utf8)
    [System.IO.File]::WriteAllText((Join-Path $unlinkedJavaDir "Bad8003SecretVo.java"), $unlinkedVo, $utf8)

    $linkedPort = Get-FreeTcpPort
    $linkedSettings = Join-Path $runtime "linked-tail-settings.json"
    $linkedWork = Join-Path $runtime "work\linked-tail"
    $linkedRequestLog = Join-Path $runtime "linked-tail-requests.jsonl"
    $linkedReady = Join-Path $runtime "linked-tail-ready.txt"
    Write-TestSettings $linkedSettings $linkedPort
    New-Item -ItemType Directory -Force -Path $linkedWork | Out-Null
    $avoidanceLines = @(
        '{"businessFamily":"pay9002","primaryPath":"src/main/java/example/pay/Pay9002PaymentVo.java"}',
        '{"businessFamily":"bad8003","primaryPath":"src/main/java/example/bad/Bad8003SecretVo.java"}'
    ) -join [Environment]::NewLine
    [System.IO.File]::WriteAllText((Join-Path $linkedWork "exploration_history.jsonl"), $avoidanceLines + [Environment]::NewLine, $utf8)
    $linkedServer = Start-MockServer $linkedPort 1 $linkedRequestLog $linkedReady "normal" 0
    $linkedArgs = @(Get-BaseLoopArguments $linkedSettings $linkedWork) + @(
        "-ProjectRoot", $linkedRoot, "-FreshProjectQuestion", "-NoProjectQualityGate", "-Once",
        "-ProjectScanMaxFiles", "20", "-ProjectScanMaxFileChars", "5000", "-ProjectScanMaxTotalChars", "60000",
        "-DynamicProjectContextMaxFiles", "20", "-DynamicProjectContextMaxFileChars", "6000", "-DynamicProjectContextMaxTotalChars", "42000"
    )
    $linkedResult = Invoke-Loop $linkedArgs
    Wait-MockServer $linkedServer 5000
    Assert-True ($linkedResult.ExitCode -eq 0) ("tail/cross-family evidence run failed:`n" + $linkedResult.Text)
    $linkedScan = Read-Json (Join-Path $linkedWork "project_scan_summary.json")
    Assert-True ([string]$linkedScan.primaryBusinessFamily -eq "act1001") "negative coverage did not force the intended active business family"
    Assert-True ([string]$linkedScan.promptContext -match 'TB_ACT_TAIL_SETTLEMENT') "Mapper evidence after 5KB was lost from the stratified startup snippet"
    Assert-True ([string]$linkedScan.promptContext -match 'tailReconciliationStatus') "VO field evidence after 5KB was lost from the stratified startup snippet"
    Assert-True (-not ([string]$linkedScan.promptContext).Contains("unreferencedCrossFamilyLeak")) "unreferenced cross-family content leaked into startup context"
    $linkedDynamic = Read-Json (Join-Path $linkedWork "last_dynamic_project_context.json")
    $linkedEvidenceRows = @($linkedDynamic.files | Where-Object { [string]$_.path -match 'Pay9002PaymentVo\.java$' })
    Assert-True ($linkedEvidenceRows.Count -eq 1) "exact import/resultType cross-family evidence was not selected"
    Assert-True ([string]$linkedEvidenceRows[0].source -eq "linked-explicit-evidence" -and [string]$linkedEvidenceRows[0].sliceRelation -eq "explicit-reference") "cross-family evidence was not labeled as an explicit evidence-only link"
    Assert-True (@($linkedDynamic.files | Where-Object { [string]$_.path -match 'Bad8003SecretVo\.java$' }).Count -eq 0) "unreferenced cross-family file entered dynamic context"
    $linkedRequest = @(Read-JsonLines $linkedRequestLog)[0]
    $linkedPrompt = [string]$linkedRequest.messages[1].content
    Assert-True $linkedPrompt.Contains("linkedCrossFamilyPaymentStatus") "linked cross-family evidence excerpt was absent from the live prompt"
    Assert-True (-not $linkedPrompt.Contains("unreferencedCrossFamilyLeak")) "unreferenced cross-family excerpt leaked into the live prompt"
    $linkedSelectedPaths = @($linkedScan.selectedFiles | ForEach-Object { [string]$_.path })
    Assert-True ($linkedSelectedPaths -contains "src\main\resources\mapper\Act1001KubeManifest.yaml" -and $linkedSelectedPaths -contains "src\main\resources\mapper\Act1001MinifiedRuntime.json" -and $linkedSelectedPaths -contains "src\main\resources\mapper\Act1001BusinessRuntime.json" -and $linkedSelectedPaths -contains "src\main\resources\mapper\Act1001RuntimeConfig.yaml" -and $linkedSelectedPaths -contains "src\main\resources\mapper\Act1001SigningConfig.xml" -and $linkedSelectedPaths -contains "src\main\resources\mapper\Act1001SpringSecurity.xml" -and $linkedSelectedPaths -contains "src\main\resources\mapper\Act1001Runtime.properties") "secret sanitizer fixtures were not actually selected into the active business slice"
    $secretSurfaces = ([string]$linkedScan.promptContext) + "`n" + ([string]$linkedDynamic.text) + "`n" + $linkedPrompt
    Assert-True ($secretSurfaces.Contains("[REDACTED KUBERNETES SECRET DOCUMENT]") -and $secretSurfaces.Contains("[REDACTED PRIVATE KEY BLOCK]") -and $secretSurfaces.Contains("[REDACTED SENSITIVE CONFIG LINE]")) "selected secret fixtures did not exercise all redaction paths"
    foreach ($secretPayload in @(
        "AKIAABCDEFGHIJKLMNOP",
        "ghp_GITHUBPAYLOADSENTINEL123456789",
        "sk-OPENAIPAYLOADSENTINEL123456789",
        "BEARERPAYLOADSENTINEL123456789",
        "URLCREDENTIALSENTINEL",
        "PEM_PRIVATE_KEY_PAYLOAD_SENTINEL",
        "KUBE_SECRET_PAYLOAD_SENTINEL",
        "SzhTX01JTklGSUVEX0tVQkVfU0VDUkVUX1BBWUxPQURfU0VOVElORUw=",
        "JSON_NEXT_LINE_SECRET_PAYLOAD_SENTINEL",
        "YAML_MULTILINE_SECRET_SENTINEL",
        "YAML_MULTILINE_SECOND_SECRET_SENTINEL",
        "NESTED_YAML_SECRET_PAYLOAD_SENTINEL",
        "XML_NESTED_SECRET_PAYLOAD_SENTINEL",
        "XML_DEEP_SECRET_PAYLOAD_SENTINEL",
        "XML_DIRECT_ELEMENT_MULTILINE_PAYLOAD_SENTINEL",
        "SPRING_XML_PASSWORD_PAYLOAD_SENTINEL",
        "XML_CHILD_SECRET_PAYLOAD_SENTINEL",
        "PROPERTIES_CONTINUATION_SECRET_FIRST",
        "PROPERTIES_CONTINUATION_SECRET_SECOND",
        "PROPERTIES_CONTINUATION_SECRET_THIRD"
    )) {
        Assert-True (-not $secretSurfaces.Contains($secretPayload)) "sensitive project payload leaked into a scan/dynamic/live prompt surface: $secretPayload"
    }

    $junctionParent = Join-Path $runtime "reparse-links"
    $junctionProjectRoot = Join-Path $junctionParent "project-root-junction"
    New-Item -ItemType Directory -Force -Path $junctionParent | Out-Null
    $junctionCreated = $false
    try {
        try {
            New-Item -ItemType Junction -Path $junctionProjectRoot -Target $businessFixture -ErrorAction Stop | Out-Null
            $junctionCreated = $true
        } catch {
            Write-Host "[Scanner] ProjectRoot junction test skipped: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
        if ($junctionCreated) {
            $junctionWork = Join-Path $runtime "work\project-root-junction"
            $junctionResult = Invoke-Loop (@(Get-BaseLoopArguments $settingsPath $junctionWork) + @(
                "-ProjectRoot", $junctionProjectRoot, "-FreshProjectQuestion", "-DryRun"
            ))
            Assert-True ($junctionResult.ExitCode -ne 0) "a junction-backed ProjectRoot was accepted"
            Assert-True ($junctionResult.Text -match '(?i)junction|symlink|reparse') "ProjectRoot reparse rejection did not explain the unsafe boundary"
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $junctionWork "dry_run_request_body.json") -PathType Leaf)) "junction-backed ProjectRoot reached request construction"
        }
    } finally {
        if ($junctionCreated -and (Test-Path -LiteralPath $junctionProjectRoot)) {
            # Directory.Delete removes the junction object itself without
            # traversing or deleting the target tree (PowerShell 5.1's
            # Remove-Item has a known junction NullReferenceException here).
            [System.IO.Directory]::Delete($junctionProjectRoot)
        }
    }

    $fileLinkRoot = Join-Path $runtime "projects\file-reparse-business"
    $fileLinkJavaDir = Join-Path $fileLinkRoot "src\main\java\example\rps"
    $fileLinkMapperDir = Join-Path $fileLinkRoot "src\main\resources\mapper"
    $fileLinkTargetDir = Join-Path $runtime "reparse-targets"
    New-Item -ItemType Directory -Force -Path $fileLinkJavaDir, $fileLinkMapperDir, $fileLinkTargetDir | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $fileLinkJavaDir "Rps3001OrderVo.java"), "package example.rps; public class Rps3001OrderVo { private String orderStatus; }", $utf8)
    [System.IO.File]::WriteAllText((Join-Path $fileLinkMapperDir "Rps3001Mapper.xml"), '<mapper namespace="Rps3001Mapper"><select id="find">SELECT ORDER_STATUS FROM TB_RPS_ORDER</select></mapper>', $utf8)
    $fileLinkTarget = Join-Path $fileLinkTargetDir "ExternalPayload.java"
    $fileLinkPath = Join-Path $fileLinkJavaDir "Rps3001LinkedPayload.java"
    [System.IO.File]::WriteAllText($fileLinkTarget, "public class ExternalPayload { String value = `"FILE_REPARSE_PAYLOAD_SENTINEL`"; }", $utf8)
    $fileLinkCreated = $false
    try {
        try {
            New-Item -ItemType SymbolicLink -Path $fileLinkPath -Target $fileLinkTarget -ErrorAction Stop | Out-Null
            $fileLinkCreated = $true
        } catch {
            Write-Host "[Scanner] file symlink test skipped (privilege/developer-mode unavailable): $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
        if ($fileLinkCreated) {
            $fileLinkWork = Join-Path $runtime "work\file-reparse"
            $fileLinkResult = Invoke-ProjectDryRun $settingsPath $fileLinkRoot $fileLinkWork
            Assert-True ($fileLinkResult.ExitCode -eq 0) ("project scan with an in-tree file symlink failed instead of safely excluding it:`n" + $fileLinkResult.Text)
            $fileLinkScan = Read-Json (Join-Path $fileLinkWork "project_scan_summary.json")
            Assert-True (@($fileLinkScan.selectedFiles | Where-Object { [string]$_.path -match 'Rps3001LinkedPayload\.java$' }).Count -eq 0) "file reparse point entered selected project evidence"
            Assert-True (-not ([string]$fileLinkScan.promptContext).Contains("FILE_REPARSE_PAYLOAD_SENTINEL")) "file reparse payload leaked into project scan context"
        }
    } finally {
        if ($fileLinkCreated -and [System.IO.File]::Exists($fileLinkPath)) {
            [System.IO.File]::Delete($fileLinkPath)
        }
    }

    $lifecycleProjectRoot = Join-Path $runtime "projects\session-lifecycle-business"
    $lifecycleSessionRoot = Join-Path $runtime "session-lifecycle-root"
    $lifecycleJavaDir = Join-Path $lifecycleProjectRoot "src\main\java\example\lif"
    $lifecycleMapperDir = Join-Path $lifecycleProjectRoot "src\main\resources\mapper"
    New-Item -ItemType Directory -Force -Path $lifecycleJavaDir, $lifecycleMapperDir | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $lifecycleJavaDir "Lif7001OrderVo.java"), "package example.lif; public class Lif7001OrderVo { private String lifecycleStatus; }", $utf8)
    [System.IO.File]::WriteAllText((Join-Path $lifecycleMapperDir "Lif7001Mapper.xml"), '<mapper namespace="Lif7001Mapper"><select id="find">SELECT LIFECYCLE_STATUS FROM TB_LIFECYCLE_ORDER</select></mapper>', $utf8)
    $lifecycleArguments = @(Get-BaseLoopArguments $settingsPath $lifecycleSessionRoot) + @(
        "-ProjectRoot", $lifecycleProjectRoot, "-NewProjectSession", "-FreshProjectQuestion", "-DryRun",
        "-ProjectSessionKeepCount", "1"
    )
    $firstReadyResult = Invoke-Loop $lifecycleArguments
    Assert-True ($firstReadyResult.ExitCode -eq 0) ("initial project session DryRun failed:`n" + $firstReadyResult.Text)
    $firstReadyMarkers = @(Get-ChildItem -LiteralPath $lifecycleSessionRoot -Recurse -File -Filter "session_identity.json" -ErrorAction SilentlyContinue)
    Assert-True ($firstReadyMarkers.Count -eq 1) "initial project session did not create exactly one identity"
    $firstReadyIdentity = Read-Json $firstReadyMarkers[0].FullName
    Assert-True ([string]$firstReadyIdentity.state -eq "ready" -and -not [string]::IsNullOrWhiteSpace([string]$firstReadyIdentity.readyAt)) "successful initial scan did not transition its session identity to ready"
    $firstReadySessionPath = $firstReadyMarkers[0].Directory.FullName

    # Model an interrupted process after its initializing marker was committed.
    # It is strict-identity validated but inactive, so retention must delete it
    # as abandoned before applying the ready-session count cap.
    $sessionsRoot = $firstReadyMarkers[0].Directory.Parent.FullName
    $initializingSessionId = "20000101-000000-000-p99999-9999"
    $initializingSessionPath = Join-Path $sessionsRoot $initializingSessionId
    New-Item -ItemType Directory -Force -Path $initializingSessionPath | Out-Null
    $initializingIdentity = [ordered]@{
        schema = "qwen-loop-project-session/v1"
        identity = [string]$firstReadyIdentity.identity
        canonicalProjectRoot = [string]$firstReadyIdentity.canonicalProjectRoot
        sessionId = $initializingSessionId
        createdAt = "2000-01-01T00:00:00.0000000Z"
        processId = 99999
        state = "initializing"
    }
    [System.IO.File]::WriteAllText((Join-Path $initializingSessionPath "session_identity.json"), ($initializingIdentity | ConvertTo-Json -Depth 10), $utf8)

    $lifecyclePort = Get-FreeTcpPort
    $lifecycleRequestLog = Join-Path $runtime "session-lifecycle-requests.jsonl"
    $lifecycleReadyPath = Join-Path $runtime "session-lifecycle-ready.txt"
    Write-TestSettings $settingsPath $lifecyclePort
    $lifecycleServer = Start-MockServer $lifecyclePort 1 $lifecycleRequestLog $lifecycleReadyPath "normal" 0
    $liveLifecycleArguments = @(Get-BaseLoopArguments $settingsPath $lifecycleSessionRoot | Where-Object { $_ -ne "-NoAutoCleanup" }) + @(
        "-ProjectRoot", $lifecycleProjectRoot, "-NewProjectSession", "-FreshProjectQuestion", "-Once", "-NoProjectQualityGate",
        "-ProjectSessionKeepCount", "1", "-ProjectSessionKeepDays", "0", "-ProjectSessionMaxTotalMB", "0"
    )
    $readyResult = Invoke-Loop $liveLifecycleArguments
    Wait-MockServer $lifecycleServer 5000
    Assert-True ($readyResult.ExitCode -eq 0) ("follow-up project session live run failed:`n" + $readyResult.Text)
    $lifecycleMarkers = @(Get-ChildItem -LiteralPath $lifecycleSessionRoot -Recurse -File -Filter "session_identity.json" -ErrorAction SilentlyContinue)
    Assert-True ($lifecycleMarkers.Count -eq 1) "retention did not converge to the newest ready session"
    $lifecycleIdentities = @($lifecycleMarkers | ForEach-Object { Read-Json $_.FullName })
    Assert-True (@($lifecycleIdentities | Where-Object { [string]$_.state -eq "ready" -and -not [string]::IsNullOrWhiteSpace([string]$_.readyAt) }).Count -eq 1) "newest successful session did not remain ready after retention"
    Assert-True (-not (Test-Path -LiteralPath $initializingSessionPath)) "inactive initializing diagnostic was not removed as abandoned"
    Assert-True (-not (Test-Path -LiteralPath $firstReadySessionPath)) "ready-session count cap did not remove the older ready session"
    $lifecycleSummary = Read-Json (Join-Path $lifecycleMarkers[0].Directory.FullName "settings_effective_summary.json")
    $lifecycleStartupCleanup = $lifecycleSummary.projectSession.startupAbandonedCleanup
    $lifecycleRetention = $lifecycleSummary.projectSession.retention
    Assert-True ([bool]$lifecycleStartupCleanup.enabled -and [string]$lifecycleStartupCleanup.mode -eq "abandoned-only" -and @($lifecycleStartupCleanup.actions).Count -eq 1) "startup abandoned-only cleanup did not report the initializing deletion"
    Assert-True ([bool]$lifecycleRetention.enabled -and [string]$lifecycleRetention.mode -eq "full" -and @($lifecycleRetention.actions).Count -eq 1) "ready retention did not report the older-ready deletion"
    Assert-True (@($lifecycleStartupCleanup.actions | Where-Object { [string]$_.kind -eq "deleted-abandoned-session" }).Count -eq 1 -and @($lifecycleRetention.actions | Where-Object { [string]$_.kind -eq "deleted-session" }).Count -eq 1) "startup/full retention phases did not distinguish abandoned and ready deletion"
    Assert-True ([int]$lifecycleRetention.storage.abandonedSessionCount -eq 0 -and [int]$lifecycleRetention.storage.managedSessionCount -eq 1) "post-retention storage metrics did not converge to one ready and zero abandoned sessions"

    # Reproduce a crash/failure after the timestamp session and initializing
    # marker exist but before the initial scan can be committed. Each later
    # startup must clean the prior strict-identity failed session even though
    # the new startup also fails, otherwise repeated scan failures accumulate
    # outside normal ready-session retention forever.
    $failingProjectRoot = Join-Path $runtime "projects\repeated-scan-failure-business"
    $failingJavaDir = Join-Path $failingProjectRoot "src\main\java\example\flr"
    $failingMapperDir = Join-Path $failingProjectRoot "src\main\resources\mapper"
    $failingSessionRoot = Join-Path $runtime "repeated-scan-failure-sessions"
    New-Item -ItemType Directory -Force -Path $failingJavaDir, $failingMapperDir | Out-Null
    for ($fileNo = 0; $fileNo -lt 350; $fileNo++) {
        $className = "Flr9001Evidence{0:D3}" -f $fileNo
        [System.IO.File]::WriteAllText((Join-Path $failingJavaDir ($className + ".java")), "package example.flr; public class $className { private String failureStatus; }", $utf8)
    }
    [System.IO.File]::WriteAllText((Join-Path $failingMapperDir "Flr9001Mapper.xml"), '<mapper namespace="Flr9001Mapper"><select id="find">SELECT FAILURE_STATUS FROM TB_FAILURE_ORDER</select></mapper>', $utf8)

    $failureBaselineArguments = @(Get-BaseLoopArguments $settingsPath $failingSessionRoot) + @(
        "-ProjectRoot", $failingProjectRoot, "-NewProjectSession", "-FreshProjectQuestion", "-DryRun",
        "-ProjectScanMaxFiles", "30", "-ProjectCandidateMaxFiles", "1000"
    )
    $failureBaselineResult = Invoke-Loop $failureBaselineArguments
    Assert-True ($failureBaselineResult.ExitCode -eq 0) ("repeated-failure ready baseline DryRun failed:`n" + $failureBaselineResult.Text)
    $failureBaselineMarkers = @(Get-ChildItem -LiteralPath $failingSessionRoot -Recurse -File -Filter "session_identity.json" -ErrorAction SilentlyContinue)
    Assert-True ($failureBaselineMarkers.Count -eq 1) "repeated-failure baseline did not create exactly one ready identity"
    $failureBaselineIdentity = Read-Json $failureBaselineMarkers[0].FullName
    Assert-True ([string]$failureBaselineIdentity.state -eq "ready") "repeated-failure baseline session was not ready"
    $failureReadySessionPath = $failureBaselineMarkers[0].Directory.FullName
    [System.IO.Directory]::SetLastWriteTimeUtc($failureReadySessionPath, [DateTime]::UtcNow.AddDays(-90))
    $failureSessionsLeaf = $failureBaselineMarkers[0].Directory.Parent.FullName

    $unmarkedSessionPath = Join-Path $failureSessionsLeaf "19990101-000000-000-p99991-9001"
    New-Item -ItemType Directory -Force -Path $unmarkedSessionPath | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $unmarkedSessionPath "UNMARKED_PRESERVE_SENTINEL.txt"), "preserve", $utf8)

    $wrongIdentitySessionId = "19990101-000000-000-p99992-9002"
    $wrongIdentitySessionPath = Join-Path $failureSessionsLeaf $wrongIdentitySessionId
    New-Item -ItemType Directory -Force -Path $wrongIdentitySessionPath | Out-Null
    $wrongIdentityMarker = [ordered]@{
        schema = "qwen-loop-project-session/v1"
        identity = "wrong-project-identity"
        canonicalProjectRoot = [string]$failureBaselineIdentity.canonicalProjectRoot
        sessionId = $wrongIdentitySessionId
        createdAt = "1999-01-01T00:00:00.0000000Z"
        processId = 99992
        state = "failed"
        failedAt = "1999-01-01T00:00:01.0000000Z"
    }
    [System.IO.File]::WriteAllText((Join-Path $wrongIdentitySessionPath "session_identity.json"), ($wrongIdentityMarker | ConvertTo-Json -Depth 10), $utf8)

    $activeInitializingSessionId = "19990101-000000-000-p99993-9003"
    $activeInitializingSessionPath = Join-Path $failureSessionsLeaf $activeInitializingSessionId
    New-Item -ItemType Directory -Force -Path $activeInitializingSessionPath | Out-Null
    $activeInitializingMarker = [ordered]@{
        schema = "qwen-loop-project-session/v1"
        identity = [string]$failureBaselineIdentity.identity
        canonicalProjectRoot = [string]$failureBaselineIdentity.canonicalProjectRoot
        sessionId = $activeInitializingSessionId
        createdAt = "1999-01-01T00:00:00.0000000Z"
        processId = 99993
        state = "initializing"
    }
    [System.IO.File]::WriteAllText((Join-Path $activeInitializingSessionPath "session_identity.json"), ($activeInitializingMarker | ConvertTo-Json -Depth 10), $utf8)
    $activeInitializingOwner = [System.IO.File]::Open((Join-Path $activeInitializingSessionPath ".active.lock"), [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)

    $previousFailedSessionPath = ""
    try {
    for ($failureNo = 1; $failureNo -le 3; $failureNo++) {
        $knownSessionPaths = @{}
        foreach ($existingSession in @(Get-ChildItem -LiteralPath $failingSessionRoot -Recurse -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{8}-\d{6}-\d{3}-p\d+-\d{4}$' })) {
            $knownSessionPaths[$existingSession.FullName.ToLowerInvariant()] = $true
        }
        $failureStdout = Join-Path $runtime ("repeated-scan-failure-$failureNo.stdout.log")
        $failureStderr = Join-Path $runtime ("repeated-scan-failure-$failureNo.stderr.log")
        $failureArguments = @(Get-BaseLoopArguments $settingsPath $failingSessionRoot | Where-Object { $_ -ne "-NoAutoCleanup" }) + @(
            "-ProjectRoot", $failingProjectRoot, "-NewProjectSession", "-FreshProjectQuestion", "-Once",
            "-ProjectScanMaxFiles", "30", "-ProjectCandidateMaxFiles", "1000",
            "-ProjectSessionKeepCount", "1", "-ProjectSessionKeepDays", "1", "-ProjectSessionMaxTotalMB", "1"
        )
        $failureProcess = Start-Process -FilePath $powerShellExe -ArgumentList (ConvertTo-ProcessArgumentLine $failureArguments) -PassThru -WindowStyle Hidden -RedirectStandardOutput $failureStdout -RedirectStandardError $failureStderr
        [void]$failureProcess.Handle
        $backgroundProcesses.Add($failureProcess) | Out-Null
        $blockedSessionPath = ""
        for ($poll = 0; $poll -lt 2000 -and [string]::IsNullOrWhiteSpace($blockedSessionPath); $poll++) {
            foreach ($sessionDir in @(Get-ChildItem -LiteralPath $failingSessionRoot -Recurse -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{8}-\d{6}-\d{3}-p\d+-\d{4}$' })) {
                if (-not $knownSessionPaths.ContainsKey($sessionDir.FullName.ToLowerInvariant())) {
                    $blockerPath = Join-Path $sessionDir.FullName "project_scan_summary.md"
                    try {
                        New-Item -ItemType Directory -Path $blockerPath -ErrorAction Stop | Out-Null
                        $blockedSessionPath = $sessionDir.FullName
                        break
                    } catch {
                        if (Test-Path -LiteralPath $blockerPath -PathType Container) {
                            $blockedSessionPath = $sessionDir.FullName
                            break
                        }
                    }
                }
            }
            if ([string]::IsNullOrWhiteSpace($blockedSessionPath)) {
                if ($failureProcess.HasExited) { break }
                Start-Sleep -Milliseconds 5
            }
        }
        Assert-True (-not [string]::IsNullOrWhiteSpace($blockedSessionPath)) "could not install the deterministic project-scan output blocker for failure $failureNo"
        [void]$failureProcess.WaitForExit(30000)
        Assert-True $failureProcess.HasExited "repeated scan-failure process $failureNo did not exit"
        $failureProcess.Refresh()
        $failureOutput = ((Get-Content -LiteralPath $failureStdout -ErrorAction SilentlyContinue) -join [Environment]::NewLine) + "`n" + ((Get-Content -LiteralPath $failureStderr -ErrorAction SilentlyContinue) -join [Environment]::NewLine)
        Assert-True ($failureProcess.ExitCode -ne 0) "blocked initial scan $failureNo unexpectedly succeeded"
        Assert-True ($failureOutput -match '(?i)project_scan_summary|directory|디렉터리|파일|path') "blocked scan failure $failureNo did not identify its local persistence error"
        $failedMarkers = @(Get-ChildItem -LiteralPath $failingSessionRoot -Recurse -File -Filter "session_identity.json" -ErrorAction SilentlyContinue | ForEach-Object {
            [PSCustomObject]@{ File = $_; Identity = (Read-Json $_.FullName) }
        })
        $ownedFailureMarkers = @($failedMarkers | Where-Object { [string]$_.Identity.identity -eq [string]$failureBaselineIdentity.identity })
        $currentFailedMarkers = @($ownedFailureMarkers | Where-Object { [string]$_.Identity.state -eq "failed" })
        Assert-True ($ownedFailureMarkers.Count -eq 3 -and @($ownedFailureMarkers | Where-Object { [string]$_.Identity.state -eq "ready" }).Count -eq 1 -and @($ownedFailureMarkers | Where-Object { [string]$_.Identity.state -eq "initializing" }).Count -eq 1 -and $currentFailedMarkers.Count -eq 1) "consecutive initial scan failures did not converge to ready + active initializing + current failed"
        $failedIdentity = $currentFailedMarkers[0].Identity
        Assert-True ([string]$failedIdentity.state -eq "failed" -and -not [string]::IsNullOrWhiteSpace([string]$failedIdentity.failedAt)) "failed initial scan was not durably marked failed"
        Assert-True ($currentFailedMarkers[0].File.Directory.FullName.Equals($blockedSessionPath, [System.StringComparison]::OrdinalIgnoreCase)) "failed identity does not belong to the current blocked scan session"
        Assert-True (Test-Path -LiteralPath $failureReadySessionPath -PathType Container) "abandoned-only startup cleanup applied ready-session age/count/size retention before scan success"
        Assert-True (Test-Path -LiteralPath $activeInitializingSessionPath -PathType Container) "active initializing session was deleted by abandoned-only cleanup"
        Assert-True (Test-Path -LiteralPath $wrongIdentitySessionPath -PathType Container) "wrong-identity session was deleted by abandoned-only cleanup"
        Assert-True (Test-Path -LiteralPath $unmarkedSessionPath -PathType Container) "unmarked session directory was deleted by abandoned-only cleanup"
        if (-not [string]::IsNullOrWhiteSpace($previousFailedSessionPath)) {
            Assert-True (-not (Test-Path -LiteralPath $previousFailedSessionPath)) "a prior failed scan session survived the next abandoned-only cleanup pass"
        }
        $previousFailedSessionPath = $blockedSessionPath
    }
    } finally {
        if ($activeInitializingOwner) { $activeInitializingOwner.Dispose(); $activeInitializingOwner = $null }
    }
}

function Test-QualityGateRegressions {
    Write-Host "[Quality] short-answer gate, bounded continuation, and fresh escape" -ForegroundColor Cyan
    $port = Get-FreeTcpPort
    $settingsPath = Join-Path $runtime "quality-settings.json"
    $requestLog = Join-Path $runtime "quality-requests.jsonl"
    $readyPath = Join-Path $runtime "quality-ready.txt"
    $workDir = Join-Path $runtime "work\quality"
    Write-TestSettings $settingsPath $port
    $server = Start-MockServer $port 4 $requestLog $readyPath "quality-sequence" 0
    $arguments = @(Get-BaseLoopArguments $settingsPath $workDir) + @(
        "-ProjectRoot", $businessFixture, "-FreshProjectQuestion",
        "-IntervalSeconds", "0", "-MaxRuns", "4",
        "-ProjectTurnsPerCycle", "5", "-ProjectMaxContinuationAttempts", "2",
        "-ProjectTargetOutputTokens", "3500", "-ProjectTargetAnswerChars", "8000",
        "-ProjectQualityMinEvidenceSignals", "3"
    )
    $result = Invoke-Loop $arguments
    Wait-MockServer $server 8000
    Assert-True ($result.ExitCode -eq 0) ("quality sequence did not recover to a successful fresh slice:`n" + $result.Text)
    $history = @(Read-JsonLines (Join-Path $workDir "run_history.jsonl"))
    Assert-True ($history.Count -eq 4) "quality sequence should create exactly four run records"
    Assert-True ([string]$history[0].status -eq "partial") "first shallow response bypassed the quality gate"
    Assert-True ([string]$history[1].status -eq "partial") "first continuation unexpectedly advanced the business turn"
    Assert-True ([string]$history[2].status -eq "abandoned") "continuation cap did not abandon the repeatedly shallow slice"
    Assert-True ([string]$history[3].status -eq "ok") "fresh rich response did not recover after abandonment"
    Assert-True ([int]$history[0].turnInCycle -eq 1 -and [int]$history[1].turnInCycle -eq 1) "partial responses advanced the successful-turn counter"
    Assert-True (([string]$history[0].partialReason) -match 'quality|depth|evidence|target') "quality failure reason was not recorded"
    Assert-True (([string]$history[3].questionSource) -match 'rescan|fresh|escape') "post-cap request did not start from a fresh scan"
    Assert-True ([string]$history[0].primaryBusinessFamily -ne [string]$history[3].primaryBusinessFamily) "post-cap fresh scan remained trapped in the abandoned business family"
    $requests = @(Read-JsonLines $requestLog)
    Assert-True ($requests.Count -eq 4) "quality mock request count mismatch"
    $thirdQuestion = [string]$history[2].question
    $nestedCount = ([regex]::Matches($thirdQuestion, "직전 업무 질문")).Count
    Assert-True ($nestedCount -le 1) "continuation prompt recursively nested prior continuation text"
    $fourthPrompt = [string]$requests[3].messages[1].content
    Assert-True (-not $fourthPrompt.Contains("짧은 일반론 답변입니다")) "fresh escape reused shallow prior answer content"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $workDir "partial_state.json") -PathType Leaf)) "successful recovery left stale partial_state.json behind"
    $orphanAtomicFiles = @(Get-ChildItem -LiteralPath $workDir -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\..+\.(tmp|replace-backup)$' })
    Assert-True ($orphanAtomicFiles.Count -eq 0) "atomic state writes left orphan temporary/backup files"

    $evidencePort = Get-FreeTcpPort
    $evidenceSettings = Join-Path $runtime "partial-evidence-settings.json"
    $evidenceRequestLog = Join-Path $runtime "partial-evidence-requests.jsonl"
    $evidenceReady = Join-Path $runtime "partial-evidence-ready.txt"
    $evidenceWork = Join-Path $runtime "work\partial-evidence"
    Write-TestSettings $evidenceSettings $evidencePort
    $evidenceServer = Start-MockServer $evidencePort 2 $evidenceRequestLog $evidenceReady "partial-evidence-sequence" 0
    $evidenceArguments = @(Get-BaseLoopArguments $evidenceSettings $evidenceWork) + @(
        "-ProjectRoot", $businessFixture, "-FreshProjectQuestion",
        "-IntervalSeconds", "0", "-MaxRuns", "2",
        "-ProjectTurnsPerCycle", "5", "-ProjectMaxContinuationAttempts", "3",
        "-ProjectTargetOutputTokens", "3500", "-ProjectTargetAnswerChars", "8000",
        "-ProjectQualityMinEvidenceSignals", "3"
    )
    $evidenceResult = Invoke-Loop $evidenceArguments
    Wait-MockServer $evidenceServer 8000
    Assert-True ($evidenceResult.ExitCode -eq 2) ("two bounded partial responses should remain unresolved (exit 2):`n" + $evidenceResult.Text)
    $evidenceHistory = @(Read-JsonLines (Join-Path $evidenceWork "run_history.jsonl"))
    Assert-True ($evidenceHistory.Count -eq 2 -and [string]$evidenceHistory[0].status -eq "partial" -and [string]$evidenceHistory[1].status -eq "partial") "partial-evidence sequence did not persist two partial turns"
    $evidenceState = Read-Json (Join-Path $evidenceWork "partial_state.json")
    $evidenceExcerpts = @($evidenceState.evidenceExcerpts)
    $evidenceText = ($evidenceExcerpts | ForEach-Object { [string]$_ }) -join "`n"
    Assert-True ($evidenceExcerpts.Count -eq 2) "partial_state.evidenceExcerpts did not accumulate one bounded excerpt per partial response"
    Assert-True ($evidenceText.Contains("FIRST_PARTIAL_EVIDENCE_SENTINEL") -and $evidenceText.Contains("SECOND_PARTIAL_EVIDENCE_SENTINEL")) "cumulative partial evidence lost the first or second response"
    $evidenceRequests = @(Read-JsonLines $evidenceRequestLog)
    Assert-True ($evidenceRequests.Count -eq 2) "partial-evidence mock request count mismatch"
    $secondEvidencePrompt = [string]$evidenceRequests[1].messages[1].content
    $partialMemoryMatch = [regex]::Match($secondEvidencePrompt, '(?s)현재 질문의 이전 partial 응답 누적 근거.*?:\s*(?<memory>.*?)(?:\r?\n){2}공통 컨텍스트:')
    Assert-True $partialMemoryMatch.Success "second request had no dedicated cumulative partial-evidence section"
    Assert-True $partialMemoryMatch.Groups['memory'].Value.Contains("FIRST_PARTIAL_EVIDENCE_SENTINEL") "second request did not feed the first partial excerpt back through partial evidence memory"
}

function Invoke-ProtocolFailureCase([string]$Name, [string]$MockScenario) {
    $port = Get-FreeTcpPort
    $settingsPath = Join-Path $runtime ("$Name-settings.json")
    $requestLog = Join-Path $runtime ("$Name-requests.jsonl")
    $readyPath = Join-Path $runtime ("$Name-ready.txt")
    $workDir = Join-Path $runtime ("work\$Name")
    Write-TestSettings $settingsPath $port
    $server = Start-MockServer $port 1 $requestLog $readyPath $MockScenario 0
    $arguments = @(Get-BaseLoopArguments $settingsPath $workDir) + @(
        "-SeedFile", (Join-Path $repo "seed_prompt.txt"),
        "-QuestionBankFile", (Join-Path $repo "question_bank.txt"), "-Once"
    )
    $result = Invoke-Loop $arguments
    Wait-MockServer $server 5000
    Assert-True ($result.ExitCode -ne 0) "$Name returned exit code 0 despite a failed request/parser"
    $status = Read-Json (Join-Path $workDir "last_response_status.json")
    Assert-True (-not [bool]$status.ok) "$Name persisted last_response_status.ok=true"
    return $result
}

function Test-ProtocolRegressions {
    Write-Host "[Protocol] malformed responses, -Once exit code, and indexed SSE choice assembly" -ForegroundColor Cyan
    $malformed = Invoke-ProtocolFailureCase "malformed-sse" "malformed-sse"
    Assert-True ($malformed.Text -match '(?i)SSE|JSON|parse|malformed|형식') "malformed SSE failure did not identify a protocol/parse problem"
    $invalidJson = Invoke-ProtocolFailureCase "invalid-json" "invalid-json"
    Assert-True ($invalidJson.Text -match '(?i)JSON|parse|invalid|형식') "invalid JSON failure did not identify a parser problem"
    $httpError = Invoke-ProtocolFailureCase "http-error" "http-error"
    Assert-True ($httpError.Text -match 'HTTP\s+500') "HTTP 500 response did not surface its status"

    $choicePort = Get-FreeTcpPort
    $choiceSettings = Join-Path $runtime "interleaved-choice-settings.json"
    $choiceRequestLog = Join-Path $runtime "interleaved-choice-requests.jsonl"
    $choiceReady = Join-Path $runtime "interleaved-choice-ready.txt"
    $choiceWork = Join-Path $runtime "work\interleaved-choice"
    $choiceGeneration = [ordered]@{
        modalities = [ordered]@{ image = $false }
        extra_body = [ordered]@{ n = 2 }
    }
    Write-TestSettingsVariant -Path $choiceSettings -Port $choicePort -GenerationConfig $choiceGeneration
    $choiceServer = Start-MockServer $choicePort 1 $choiceRequestLog $choiceReady "interleaved-multichoice" 0
    $choiceArguments = @(Get-BaseLoopArguments $choiceSettings $choiceWork) + @(
        "-SeedFile", (Join-Path $repo "seed_prompt.txt"),
        "-QuestionBankFile", (Join-Path $repo "question_bank.txt"), "-Once"
    )
    $choiceResult = Invoke-Loop $choiceArguments
    Wait-MockServer $choiceServer 5000
    Assert-True ($choiceResult.ExitCode -eq 0) ("interleaved multi-choice SSE run failed:`n" + $choiceResult.Text)
    $choiceRequest = @(Read-JsonLines $choiceRequestLog)[0]
    Assert-True ([int]$choiceRequest.n -eq 2) "n=2 was not preserved in the effective streaming request"
    $choiceTranscript = @(Read-JsonLines (Join-Path $choiceWork "transcript.jsonl"))[0]
    $choiceAnswer = [string]$choiceTranscript.answer
    Assert-True ($choiceAnswer.Contains("INDEX0_PART_A") -and $choiceAnswer.Contains("INDEX0_PART_B")) "SSE parser did not assemble all index 0 deltas"
    Assert-True (-not $choiceAnswer.Contains("INDEX1_SHOULD_NOT_APPEAR")) "SSE parser contaminated the primary answer with index 1 content"
    $choiceNext = (Get-Content -LiteralPath (Join-Path $choiceWork "next_question.txt") -Raw -Encoding UTF8).Trim()
    Assert-True ($choiceNext -eq "INDEX0_NEXT") "NEXT_QUESTION was not extracted from the assembled index 0 stream"
    $choiceStatus = Read-Json (Join-Path $choiceWork "last_response_status.json")
    Assert-True ([string]$choiceStatus.finishReason -eq "stop" -and [string]$choiceStatus.responseParseMode -eq "sse") "SSE metadata did not follow the index 0 finish event"

    $unterminatedPort = Get-FreeTcpPort
    $unterminatedSettings = Join-Path $runtime "unterminated-sse-settings.json"
    $unterminatedRequestLog = Join-Path $runtime "unterminated-sse-requests.jsonl"
    $unterminatedReady = Join-Path $runtime "unterminated-sse-ready.txt"
    $unterminatedWork = Join-Path $runtime "work\unterminated-sse"
    Write-TestSettings $unterminatedSettings $unterminatedPort
    $unterminatedServer = Start-MockServer $unterminatedPort 1 $unterminatedRequestLog $unterminatedReady "unterminated-sse" 0
    $unterminatedArguments = @(Get-BaseLoopArguments $unterminatedSettings $unterminatedWork 3) + @(
        "-ProjectRoot", $businessFixture, "-FreshProjectQuestion", "-NoProjectQualityGate", "-Once"
    )
    $unterminatedResult = Invoke-Loop $unterminatedArguments
    Wait-MockServer $unterminatedServer 5000
    Assert-True ($unterminatedResult.ExitCode -eq 2) ("unterminated SSE should be a bounded partial (exit 2):`n" + $unterminatedResult.Text)
    Assert-True (@(Read-JsonLines $unterminatedRequestLog).Count -eq 1) "unterminated SSE response caused an automatic re-POST"
    $unterminatedStatus = Read-Json (Join-Path $unterminatedWork "last_response_status.json")
    Assert-True ([bool]$unterminatedStatus.ok -and [string]$unterminatedStatus.responseParseMode -eq "sse") "unterminated SSE was misclassified as an HTTP/parser transport failure"
    Assert-True (-not [bool]$unterminatedStatus.streamCompleted -and -not [bool]$unterminatedStatus.streamDoneObserved -and -not [bool]$unterminatedStatus.primaryTerminalSeen) "unterminated SSE incorrectly recorded a terminal event"
    $unterminatedHistory = @(Read-JsonLines (Join-Path $unterminatedWork "run_history.jsonl"))
    Assert-True ($unterminatedHistory.Count -eq 1 -and [string]$unterminatedHistory[0].status -eq "partial" -and [string]$unterminatedHistory[0].partialReason -eq "unterminated-sse") "unterminated SSE bypassed explicit partial classification"
    Assert-True ([int]$unterminatedHistory[0].cycleIndex -eq 1 -and [int]$unterminatedHistory[0].turnInCycle -eq 1) "unterminated SSE was recorded against an unexpected project turn"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $unterminatedWork "exploration_state.json") -PathType Leaf)) "unterminated SSE advanced the successful project-cycle state"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $unterminatedWork "cycle_history.jsonl") -PathType Leaf)) "unterminated SSE triggered a project-cycle transition"
    $unterminatedNext = (Get-Content -LiteralPath (Join-Path $unterminatedWork "next_question.txt") -Raw -Encoding UTF8).Trim()
    Assert-True ($unterminatedNext -ne "UNTERMINATED_MODEL_NEXT" -and $unterminatedNext -match '중단|이어|계속|완성|partial|SSE|응답') "unterminated SSE trusted the model NEXT_QUESTION instead of queuing a safe continuation"

    $readTimeoutPort = Get-FreeTcpPort
    $readTimeoutSettings = Join-Path $runtime "sse-read-timeout-settings.json"
    $readTimeoutRequestLog = Join-Path $runtime "sse-read-timeout-requests.jsonl"
    $readTimeoutReady = Join-Path $runtime "sse-read-timeout-ready.txt"
    $readTimeoutWork = Join-Path $runtime "work\sse-read-timeout"
    Write-TestSettings $readTimeoutSettings $readTimeoutPort
    $readTimeoutServer = Start-MockServer $readTimeoutPort 1 $readTimeoutRequestLog $readTimeoutReady "sse-read-timeout" 0
    $readTimeoutArguments = @(Get-BaseLoopArguments $readTimeoutSettings $readTimeoutWork 3 1) + @(
        "-SeedFile", (Join-Path $repo "seed_prompt.txt"),
        "-QuestionBankFile", (Join-Path $repo "question_bank.txt"), "-Once"
    )
    $readTimeoutResult = Invoke-Loop $readTimeoutArguments
    Wait-MockServer $readTimeoutServer 8000
    Assert-True ($readTimeoutResult.ExitCode -eq 1) ("SSE read timeout after HTTP 200 must fail once without replay (exit 1):`n" + $readTimeoutResult.Text)
    Assert-True (@(Read-JsonLines $readTimeoutRequestLog).Count -eq 1) "SSE read timeout after the first 200 response chunk caused the same POST to be replayed"
    $readTimeoutPostCount = [regex]::Matches($readTimeoutResult.Text, '(?m)\bPOST\s+http://').Count
    Assert-True ($readTimeoutPostCount -eq 1) "MaxRetries=3 retried after a 200/SSE stream had already started"
    Assert-True ($readTimeoutResult.Text -match '(?i)timeout|timed out|read|시간.*초과') "SSE read-timeout failure did not explain the transport interruption"
    $readTimeoutStatus = Read-Json (Join-Path $readTimeoutWork "last_response_status.json")
    Assert-True (-not [bool]$readTimeoutStatus.ok) "SSE read timeout after response start was persisted as success"
    $readTimeoutHistory = @(Read-JsonLines (Join-Path $readTimeoutWork "run_history.jsonl"))
    Assert-True ($readTimeoutHistory.Count -eq 1 -and [string]$readTimeoutHistory[0].status -eq "error") "SSE read timeout was not durably classified as one error attempt"
    Assert-True (Test-Path -LiteralPath (Join-Path $readTimeoutWork "pending_turn.json") -PathType Leaf) "SSE read timeout incorrectly cleared the pending turn"
    Assert-True (Test-Path -LiteralPath (Join-Path $readTimeoutWork "pending_question.txt") -PathType Leaf) "SSE read timeout incorrectly cleared the pending question"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $readTimeoutWork "transcript.jsonl") -PathType Leaf)) "partial SSE prefix was incorrectly committed as a completed transcript"

    $statusFailurePort = Get-FreeTcpPort
    $statusFailureSettings = Join-Path $runtime "status-write-failure-settings.json"
    $statusFailureRequestLog = Join-Path $runtime "status-write-failure-requests.jsonl"
    $statusFailureReady = Join-Path $runtime "status-write-failure-ready.txt"
    $statusFailureWork = Join-Path $runtime "work\status-write-failure"
    New-Item -ItemType Directory -Force -Path $statusFailureWork | Out-Null
    # A directory at the status-file path deterministically makes both the
    # success and fallback status writes fail after the HTTP response arrived.
    New-Item -ItemType Directory -Force -Path (Join-Path $statusFailureWork "last_response_status.json") | Out-Null
    Write-TestSettings $statusFailureSettings $statusFailurePort
    $statusFailureServer = Start-MockServer $statusFailurePort 1 $statusFailureRequestLog $statusFailureReady "normal" 0
    $statusFailureArguments = @(Get-BaseLoopArguments $statusFailureSettings $statusFailureWork 3) + @(
        "-SeedFile", (Join-Path $repo "seed_prompt.txt"),
        "-QuestionBankFile", (Join-Path $repo "question_bank.txt"), "-Once"
    )
    $statusFailureResult = Invoke-Loop $statusFailureArguments
    Wait-MockServer $statusFailureServer 5000
    Assert-True ($statusFailureResult.ExitCode -ne 0) "local response-status write failure was reported as a successful run"
    $statusFailureRequests = @(Read-JsonLines $statusFailureRequestLog)
    Assert-True ($statusFailureRequests.Count -eq 1) "a completed HTTP response was POSTed again after the local status write failed"
    $statusPostCount = [regex]::Matches($statusFailureResult.Text, '(?m)\bPOST\s+http://').Count
    Assert-True ($statusPostCount -eq 1) "MaxRetries=3 retried a request after its HTTP response had already arrived"
    Assert-True ($statusFailureResult.Text -match 'HTTP response was received.*will not be resent') "fatal local acceptance failure did not explicitly state the no-resend policy"
    $statusFailureHistory = @(Read-JsonLines (Join-Path $statusFailureWork "run_history.jsonl"))
    Assert-True ($statusFailureHistory.Count -eq 1 -and [string]$statusFailureHistory[0].status -eq "error") "local status-write failure was not durably classified as one error attempt"
    Assert-True (Test-Path -LiteralPath (Join-Path $statusFailureWork "pending_turn.json") -PathType Leaf) "failed local acceptance incorrectly cleared the pending request marker"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $statusFailureWork "transcript.jsonl") -PathType Leaf)) "failed local acceptance incorrectly committed an answer transcript"
}

function Test-SettingsRegressions {
    Write-Host "[Settings] endpoint, token aliases, restricted headers, User-Agent, and coverage" -ForegroundColor Cyan

    $endpointPort = Get-FreeTcpPort
    $endpointSettings = Join-Path $runtime "settings-endpoint.json"
    $endpointWork = Join-Path $runtime "work\settings-endpoint"
    $endpointBaseUrl = "http://127.0.0.1:$endpointPort/chat/completions"
    Write-TestSettingsVariant -Path $endpointSettings -Port $endpointPort -BaseUrl $endpointBaseUrl -SettingsVersion 987654
    $endpointArgs = @(Get-BaseLoopArguments $endpointSettings $endpointWork) + @("-DryRun", "-QwenCodeVersion", "9.9.9-test")
    $endpointResult = Invoke-Loop $endpointArgs
    Assert-True ($endpointResult.ExitCode -eq 0) ("pre-suffixed endpoint/UA DryRun failed:`n" + $endpointResult.Text)
    $endpointSummary = Read-Json (Join-Path $endpointWork "settings_effective_summary.json")
    $endpointHeaders = Read-Json (Join-Path $endpointWork "dry_run_request_headers.json")
    $endpoints = @($endpointSummary.endpoints)
    Assert-True ($endpoints.Count -eq 1 -and [string]$endpoints[0] -eq $endpointBaseUrl) "baseUrl ending in /chat/completions received a duplicate suffix"
    Assert-True (-not ([string]$endpoints[0]).Contains("/chat/completions/chat/completions")) "duplicated chat/completions endpoint survived normalization"
    Assert-True ([string]$endpointHeaders.'User-Agent' -eq "QwenCode/9.9.9-test (win32; x64)") "-QwenCodeVersion was not reflected in the dry-run User-Agent"
    Assert-True ([int]$endpointSummary.settingsSchemaVersion -eq 987654) "settings summary did not preserve `$version as the schema-version diagnostic"
    Assert-True ([string]$endpointSummary.qwenCompat.contentType -eq "application/json" -and [string]$endpointSummary.qwenCompat.contentTypeSource -eq "scheduler-default.application/json") "default Content-Type source diagnostic was missing or incorrect"
    Assert-True ([string]$endpointSummary.qwenCompat.userAgentVersionSource -eq "-QwenCodeVersion") "User-Agent version source did not identify the explicit switch"
    Assert-True ([bool]$endpointSummary.qwenCompat.settingsVersionIsNotQwenCodeVersion) "settings schema version was treated as a package version"
    $coverageNames = @($endpointSummary.settingsCoverage.PSObject.Properties | ForEach-Object { $_.Name })
    $expectedCoverage = @("env", "modelProviders", "generationConfig", "general", "permissions", "security", "ui", '$version')
    Assert-True ($coverageNames.Count -eq 8) "settingsCoverage did not contain exactly eight top-level classifications"
    foreach ($coverageName in $expectedCoverage) {
        Assert-True ($coverageNames -contains $coverageName) "settingsCoverage is missing $coverageName"
    }

    $schemaOnlyWork = Join-Path $runtime "work\settings-schema-version"
    $schemaOnlyArgs = @(Get-BaseLoopArguments $endpointSettings $schemaOnlyWork) + @("-DryRun")
    $schemaOnlyResult = Invoke-Loop $schemaOnlyArgs
    Assert-True ($schemaOnlyResult.ExitCode -eq 0) ("schema-version-only DryRun failed:`n" + $schemaOnlyResult.Text)
    $schemaOnlyHeaders = Read-Json (Join-Path $schemaOnlyWork "dry_run_request_headers.json")
    Assert-True (-not ([string]$schemaOnlyHeaders.'User-Agent').Contains("987654")) "settings `$version leaked into the QwenCode User-Agent"

    $completionPort = Get-FreeTcpPort
    $completionSettings = Join-Path $runtime "settings-max-completion.json"
    $completionWork = Join-Path $runtime "work\settings-max-completion"
    $completionGeneration = [ordered]@{
        modalities = [ordered]@{ image = $false }
        extra_body = [ordered]@{ max_completion_tokens = 4096 }
    }
    Write-TestSettingsVariant -Path $completionSettings -Port $completionPort -GenerationConfig $completionGeneration
    $completionResult = Invoke-Loop (@(Get-BaseLoopArguments $completionSettings $completionWork) + @("-DryRun"))
    Assert-True ($completionResult.ExitCode -eq 0) ("max_completion_tokens DryRun failed:`n" + $completionResult.Text)
    $completionBody = Read-Json (Join-Path $completionWork "dry_run_request_body.json")
    $completionBodyNames = @($completionBody.PSObject.Properties | ForEach-Object { $_.Name })
    Assert-True ([int]$completionBody.max_completion_tokens -eq 4096) "extra_body.max_completion_tokens was not applied"
    Assert-True (-not ($completionBodyNames -contains "max_tokens")) "default max_tokens remained beside max_completion_tokens"

    $temperatureOnlyPort = Get-FreeTcpPort
    $temperatureOnlySettings = Join-Path $runtime "settings-temperature-only.json"
    $temperatureOnlyWork = Join-Path $runtime "work\settings-temperature-only"
    $temperatureOnlyGeneration = [ordered]@{
        modalities = [ordered]@{ image = $false }
        samplingParams = [ordered]@{ temperature = 0.61 }
    }
    Write-TestSettingsVariant -Path $temperatureOnlySettings -Port $temperatureOnlyPort -GenerationConfig $temperatureOnlyGeneration
    $savedQwenMaxOutput = [Environment]::GetEnvironmentVariable("QWEN_CODE_MAX_OUTPUT_TOKENS")
    try {
        [Environment]::SetEnvironmentVariable("QWEN_CODE_MAX_OUTPUT_TOKENS", $null)
        $temperatureOnlyResult = Invoke-Loop (@(Get-BaseLoopArguments $temperatureOnlySettings $temperatureOnlyWork) + @("-DryRun"))
    } finally {
        [Environment]::SetEnvironmentVariable("QWEN_CODE_MAX_OUTPUT_TOKENS", $savedQwenMaxOutput)
    }
    Assert-True ($temperatureOnlyResult.ExitCode -eq 0) ("temperature-only samplingParams DryRun failed:`n" + $temperatureOnlyResult.Text)
    $temperatureOnlyBody = Read-Json (Join-Path $temperatureOnlyWork "dry_run_request_body.json")
    $temperatureOnlySummary = Read-Json (Join-Path $temperatureOnlyWork "settings_effective_summary.json")
    Assert-True ([double]$temperatureOnlyBody.temperature -eq 0.61) "samplingParams.temperature was not applied"
    Assert-True ([int]$temperatureOnlyBody.max_tokens -eq 32000) "temperature-only samplingParams removed or reduced the model output-token ceiling"
    Assert-True ([string]$temperatureOnlySummary.qwenCompat.effectiveTokenLimitKey -eq "max_tokens" -and [int]$temperatureOnlySummary.qwenCompat.effectiveTokenLimit -eq 32000) "settings summary disagreed with the preserved model token ceiling"

    $compatPort = Get-FreeTcpPort
    $compatSettings = Join-Path $runtime "settings-compat-omissions.json"
    $compatWork = Join-Path $runtime "work\settings-compat-omissions"
    $compatGeneration = [ordered]@{
        modalities = [ordered]@{ image = $false }
        samplingParams = [ordered]@{ temperature = 0.73; max_tokens = 1111; max_completion_tokens = 2222 }
        extra_body = [ordered]@{ top_k = 77; provider_extension = "COMPAT_BODY_EXTENSION_SENTINEL" }
    }
    Write-TestSettingsVariant -Path $compatSettings -Port $compatPort -GenerationConfig $compatGeneration
    $savedCompatMaxOutput = [Environment]::GetEnvironmentVariable("QWEN_CODE_MAX_OUTPUT_TOKENS")
    try {
        [Environment]::SetEnvironmentVariable("QWEN_CODE_MAX_OUTPUT_TOKENS", $null)
        $compatResult = Invoke-Loop (@(Get-BaseLoopArguments $compatSettings $compatWork) + @("-CompatBody", "-DryRun"))
    } finally {
        [Environment]::SetEnvironmentVariable("QWEN_CODE_MAX_OUTPUT_TOKENS", $savedCompatMaxOutput)
    }
    Assert-True ($compatResult.ExitCode -eq 0) ("CompatBody omission DryRun failed:`n" + $compatResult.Text)
    $compatBody = Read-Json (Join-Path $compatWork "dry_run_request_body.json")
    $compatSummary = Read-Json (Join-Path $compatWork "settings_effective_summary.json")
    $compatBodyNames = @($compatBody.PSObject.Properties | ForEach-Object { $_.Name })
    Assert-True (-not ($compatBodyNames -contains "temperature") -and -not ($compatBodyNames -contains "max_completion_tokens") -and -not ($compatBodyNames -contains "top_k") -and -not ($compatBodyNames -contains "provider_extension")) "-CompatBody leaked samplingParams or extra_body onto the wire"
    Assert-True ([int]$compatBody.max_tokens -eq 32000 -and [int]$compatSummary.qwenCompat.effectiveTokenLimit -eq 32000) "-CompatBody did not restore the model default max_tokens after omitting both conflicting sampling aliases"
    Assert-True (-not [bool]$compatSummary.qwenCompat.samplingParamsApplied -and -not [bool]$compatSummary.qwenCompat.extraBodyApplied) "-CompatBody summary falsely labeled omitted samplingParams/extra_body as applied"
    Assert-True ([string]$compatSummary.settingsCoverage.generationConfig.status -eq "partially-applied" -and [string]$compatSummary.settingsCoverage.generationConfig.usage -match '(?i)omitted|omit|제외') "-CompatBody settings coverage did not disclose its intentional omissions"

    $ambiguousPort = Get-FreeTcpPort
    $ambiguousSettings = Join-Path $runtime "settings-ambiguous-max.json"
    $ambiguousWork = Join-Path $runtime "work\settings-ambiguous-max"
    $ambiguousGeneration = [ordered]@{
        modalities = [ordered]@{ image = $false }
        extra_body = [ordered]@{ max_tokens = 2048; max_completion_tokens = 4096 }
    }
    Write-TestSettingsVariant -Path $ambiguousSettings -Port $ambiguousPort -GenerationConfig $ambiguousGeneration
    $ambiguousResult = Invoke-Loop (@(Get-BaseLoopArguments $ambiguousSettings $ambiguousWork) + @("-DryRun"))
    Assert-True ($ambiguousResult.ExitCode -ne 0) "two token-limit aliases in the same extra_body object were accepted"
    Assert-True ($ambiguousResult.Text -match 'max_tokens.*max_completion_tokens|max_completion_tokens.*max_tokens') "ambiguous token-limit rejection did not identify both aliases"

    $hostPort = Get-FreeTcpPort
    $hostSettings = Join-Path $runtime "settings-host.json"
    $hostDryWork = Join-Path $runtime "work\settings-host-dry"
    $hostRealWork = Join-Path $runtime "work\settings-host-real"
    $hostRequestLog = Join-Path $runtime "settings-host-requests.jsonl"
    $hostHeaderLog = Join-Path $runtime "settings-host-headers.txt"
    $hostReady = Join-Path $runtime "settings-host-ready.txt"
    $hostValue = "127.0.0.1:$hostPort"
    $customContentType = "application/vnd.qwen-loop-regression+json"
    $customUserAgent = "SettingsRegressionAgent/7.4"
    $customAuthorization = "Bearer CUSTOM_HEADER_AUTH_SECRET_SENTINEL_123456789"
    $customApiKey = "CUSTOM_HEADER_API_KEY_SECRET_SENTINEL_987654321"
    $hostGeneration = [ordered]@{
        modalities = [ordered]@{ image = $false }
        customHeaders = [ordered]@{
            Host = $hostValue
            'Content-Type' = $customContentType
            'User-Agent' = $customUserAgent
            Authorization = $customAuthorization
            'X-Api-Key' = $customApiKey
            'X-Settings-Test' = "host-shape"
        }
    }
    Write-TestSettingsVariant -Path $hostSettings -Port $hostPort -GenerationConfig $hostGeneration
    $hostDryResult = Invoke-Loop (@(Get-BaseLoopArguments $hostSettings $hostDryWork) + @("-DryRun"))
    Assert-True ($hostDryResult.ExitCode -eq 0) ("customHeaders.Host DryRun failed:`n" + $hostDryResult.Text)
    $hostDryHeaders = Read-Json (Join-Path $hostDryWork "dry_run_request_headers.json")
    $hostDrySummary = Read-Json (Join-Path $hostDryWork "settings_effective_summary.json")
    Assert-True ([string]$hostDryHeaders.Host -eq $hostValue) "customHeaders.Host was absent from the dry-run request shape"
    Assert-True ([string]$hostDryHeaders.'Content-Type' -eq $customContentType -and [string]$hostDryHeaders.'User-Agent' -eq $customUserAgent) "custom Content-Type/User-Agent were absent from the dry-run request shape"
    Assert-True ([string]$hostDryHeaders.Authorization -eq $customAuthorization -and [string]$hostDryHeaders.'X-Api-Key' -eq $customApiKey) "default unmasked dry-run header log did not preserve settings-first Authorization/API key values"
    Assert-True ([string]$hostDryHeaders.'X-Settings-Test' -eq "host-shape") "ordinary custom header was absent from the dry-run request shape"
    Assert-True ([string]$hostDrySummary.qwenCompat.contentType -eq $customContentType -and [string]$hostDrySummary.qwenCompat.userAgent -eq $customUserAgent) "settings summary effective Content-Type/User-Agent disagreed with dry-run headers"
    Assert-True ([string]$hostDrySummary.qwenCompat.contentTypeSource -eq "settings.generationConfig.customHeaders.Content-Type") "settings summary did not attribute the effective Content-Type to customHeaders"
    Assert-True ([string]$hostDrySummary.qwenCompat.userAgentSource -eq "settings.generationConfig.customHeaders.User-Agent") "settings summary did not attribute the effective User-Agent to customHeaders"
    $hostDryBodyText = Get-Content -LiteralPath (Join-Path $hostDryWork "dry_run_request_body.json") -Raw -Encoding UTF8
    Assert-True (-not $hostDryBodyText.Contains($customAuthorization) -and -not $hostDryBodyText.Contains($customApiKey)) "custom Authorization/API secret values were duplicated into the request body system prompt"
    Assert-True ($hostDryBodyText.Contains("Authorization") -and $hostDryBodyText.Contains("X-Api-Key")) "system prompt omitted the non-secret custom header key shape"
    $hostServer = Start-MockServer $hostPort 1 $hostRequestLog $hostReady "normal" 0 $hostHeaderLog
    $hostRealArgs = @(Get-BaseLoopArguments $hostSettings $hostRealWork) + @(
        "-SeedFile", (Join-Path $repo "seed_prompt.txt"),
        "-QuestionBankFile", (Join-Path $repo "question_bank.txt"), "-Once"
    )
    $hostRealResult = Invoke-Loop $hostRealArgs
    Wait-MockServer $hostServer 5000
    Assert-True ($hostRealResult.ExitCode -eq 0) ("customHeaders.Host live request failed:`n" + $hostRealResult.Text)
    $wireHeaders = Get-Content -LiteralPath $hostHeaderLog -Raw -Encoding UTF8
    Assert-True ($wireHeaders -match ("(?im)^Host:\s*" + [regex]::Escape($hostValue) + "\s*$")) "live request did not transmit the configured Host header"
    Assert-True ($wireHeaders -match ("(?im)^Content-Type:\s*" + [regex]::Escape($customContentType) + "\s*$")) "live request did not transmit the configured Content-Type header"
    Assert-True ($wireHeaders -match ("(?im)^User-Agent:\s*" + [regex]::Escape($customUserAgent) + "\s*$")) "live request did not transmit the configured User-Agent header"
    Assert-True ($wireHeaders -match ("(?im)^Authorization:\s*" + [regex]::Escape($customAuthorization) + "\s*$") -and $wireHeaders -match ("(?im)^X-Api-Key:\s*" + [regex]::Escape($customApiKey) + "\s*$")) "live request did not transmit settings-first Authorization/API key headers"
    Assert-True ($wireHeaders -match '(?im)^X-Settings-Test:\s*host-shape\s*$') "live request did not transmit the ordinary custom header"
    $hostLiveHeaders = Read-Json (Join-Path $hostRealWork "last_request_headers.json")
    $hostLiveSummary = Read-Json (Join-Path $hostRealWork "settings_effective_summary.json")
    Assert-True ([string]$hostLiveHeaders.'Content-Type' -eq $customContentType -and [string]$hostLiveHeaders.'User-Agent' -eq $customUserAgent) "live header log disagreed with the configured Content-Type/User-Agent"
    Assert-True ([string]$hostLiveHeaders.Authorization -eq $customAuthorization -and [string]$hostLiveHeaders.'X-Api-Key' -eq $customApiKey) "live diagnostic header log did not preserve configured sensitive header values by default"
    Assert-True ([string]$hostLiveSummary.qwenCompat.contentType -eq $customContentType -and [string]$hostLiveSummary.qwenCompat.userAgent -eq $customUserAgent) "live settings summary disagreed with the transmitted Content-Type/User-Agent"

    $identitySuppressedWork = Join-Path $runtime "work\settings-generic-diagnostics-only"
    $identitySuppressedResult = Invoke-Loop (@(Get-BaseLoopArguments $endpointSettings $identitySuppressedWork) + @(
        "-LoopDiagnosticHeaders", "-NoClientIdentityHeaders", "-DryRun"
    ))
    Assert-True ($identitySuppressedResult.ExitCode -eq 0) ("generic-only diagnostic header DryRun failed:`n" + $identitySuppressedResult.Text)
    $identitySuppressedHeaders = Read-Json (Join-Path $identitySuppressedWork "dry_run_request_headers.json")
    foreach ($genericHeader in @("X-Qwen-Loop-Client", "X-Qwen-Loop-Provider-Type", "X-Qwen-Loop-Provider-Name", "X-Qwen-Loop-Provider-Id", "X-Qwen-Loop-Model", "X-Qwen-Loop-EnvKey", "X-Qwen-Loop-ApiKey-Source", "X-Qwen-Loop-Settings-Version")) {
        Assert-True ($null -ne $identitySuppressedHeaders.PSObject.Properties[$genericHeader]) "-NoClientIdentityHeaders removed generic diagnostic header $genericHeader"
    }
    foreach ($identityHeader in @("X-Qwen-Loop-Computer-Name", "X-Qwen-Loop-User-Name", "X-Qwen-Loop-User-Domain", "X-Qwen-Loop-Client-IP", "X-Qwen-Loop-Client-Port")) {
        Assert-True ($null -eq $identitySuppressedHeaders.PSObject.Properties[$identityHeader]) "-NoClientIdentityHeaders leaked client identity header $identityHeader"
    }
    $identitySuppressedSummary = Read-Json (Join-Path $identitySuppressedWork "settings_effective_summary.json")
    Assert-True ([bool]$identitySuppressedSummary.loopDiagnosticHeaders -and $null -eq $identitySuppressedSummary.clientNetworkIdentity) "generic-only diagnostics still collected client network identity"
    Assert-True ([string]$identitySuppressedSummary.clientNetworkIdentityPolicy -eq "not-collected-or-sent; generic-X-Qwen-Loop-diagnostic-headers-only") "generic-only diagnostic summary policy was inaccurate"
    Assert-True ($identitySuppressedResult.Text -notmatch '(?m)^ClientHost\s*:|^ClientIP\s*:' -and $identitySuppressedResult.Text -match '(?m)^ClientIdent\s*: suppressed by -NoClientIdentityHeaders') "console printed client identity or failed to disclose generic-only suppression"

    $deepMaskPort = Get-FreeTcpPort
    $deepMaskSettings = Join-Path $runtime "settings-deep-mask.json"
    $deepMaskRawWork = Join-Path $runtime "work\settings-deep-mask-raw"
    $deepMaskDryWork = Join-Path $runtime "work\settings-deep-mask-dry"
    $deepMaskLiveWork = Join-Path $runtime "work\settings-deep-mask-live"
    $deepMaskRequestLog = Join-Path $runtime "settings-deep-mask-requests.jsonl"
    $deepMaskHeaderLog = Join-Path $runtime "settings-deep-mask-wire-headers.txt"
    $deepMaskReady = Join-Path $runtime "settings-deep-mask-ready.txt"
    $deepMaskAuth = "Bearer MASK_CUSTOM_AUTH_LITERAL_1234567890"
    $deepMaskApiKey = "MASK_CUSTOM_API_KEY_LITERAL_1234567890"
    $deepMaskXAuth = "MASK_X_AUTH_LITERAL_1234567890"
    $deepMaskAccessKey = "MASK_X_ACCESS_KEY_LITERAL_1234567890"
    $deepMaskPrivateKey = "MASK_X_PRIVATE_KEY_LITERAL_1234567890"
    $deepMaskSignature = "MASK_X_SIGNATURE_LITERAL_1234567890"
    $deepMaskPasswordSource = "MASK_X_PASSWORD_SOURCE_LITERAL_1234567890"
    $deepMaskKnownProviderKey = "local-test-key"
    $deepMaskPassword = "MASK_SAMPLING_PASSWORD_LITERAL_1234567890"
    $deepMaskToken = "MASK_SAMPLING_TOKEN_LITERAL_1234567890"
    $deepMaskSecretKey = "MASK_SAMPLING_SECRET_KEY_LITERAL_1234567890"
    $deepMaskAuthProperty = "MASK_SAMPLING_AUTH_LITERAL_1234567890"
    $deepMaskAccessToken = "MASK_EXTRA_ACCESS_TOKEN_LITERAL_1234567890"
    $deepMaskProviderSecret = "MASK_EXTRA_PROVIDER_SECRET_LITERAL_1234567890"
    $deepMaskTokenSource = "MASK_TOKEN_SOURCE_LITERAL_1234567890"
    $deepMaskClientSecretSource = "MASK_CLIENT_SECRET_SOURCE_LITERAL_1234567890"
    $deepMaskPasswordEnvKey = "MASK_PASSWORD_ENVKEY_LITERAL_1234567890"
    $deepMaskSubscriptionKey = "MASK_SUBSCRIPTION_KEY_LITERAL_1234567890"
    $deepMaskMasterKey = "MASK_MASTER_KEY_LITERAL_1234567890"
    $deepMaskFunctionsKey = "MASK_FUNCTIONS_KEY_LITERAL_1234567890"
    $deepMaskSignatureValue = "MASK_SIGNATURE_VALUE_LITERAL_1234567890"
    $deepMaskHmacValue = "MASK_HMAC_VALUE_LITERAL_1234567890"
    $deepMaskSecrets = @($deepMaskAuth, $deepMaskApiKey, $deepMaskXAuth, $deepMaskAccessKey, $deepMaskPrivateKey, $deepMaskSignature, $deepMaskPasswordSource, $deepMaskKnownProviderKey, $deepMaskPassword, $deepMaskToken, $deepMaskSecretKey, $deepMaskAuthProperty, $deepMaskAccessToken, $deepMaskProviderSecret, $deepMaskTokenSource, $deepMaskClientSecretSource, $deepMaskPasswordEnvKey, $deepMaskSubscriptionKey, $deepMaskMasterKey, $deepMaskFunctionsKey, $deepMaskSignatureValue, $deepMaskHmacValue)
    # Windows PowerShell 5.1 ConvertTo-Json serializes a directly nested
    # object[] as {value,Count}; generic lists produce the intended JSON arrays.
    $deepMaskNestedFirst = New-Object 'System.Collections.Generic.List[object]'
    [void]$deepMaskNestedFirst.Add("NESTED_ARRAY_A")
    [void]$deepMaskNestedFirst.Add("NESTED_ARRAY_B")
    $deepMaskNestedSecond = New-Object 'System.Collections.Generic.List[object]'
    [void]$deepMaskNestedSecond.Add("NESTED_ARRAY_C")
    $deepMaskNestedArrays = New-Object 'System.Collections.Generic.List[object]'
    [void]$deepMaskNestedArrays.Add($deepMaskNestedFirst)
    [void]$deepMaskNestedArrays.Add($deepMaskNestedSecond)
    $deepMaskGeneration = [ordered]@{
        modalities = [ordered]@{ image = $false }
        customHeaders = [ordered]@{
            Authorization = $deepMaskAuth
            'X-Api-Key' = $deepMaskApiKey
            'X-Auth' = $deepMaskXAuth
            'X-Access-Key' = $deepMaskAccessKey
            'X-Private-Key' = $deepMaskPrivateKey
            'X-Signature' = $deepMaskSignature
            'X-Password-Source' = $deepMaskPasswordSource
            'X-Custom' = $deepMaskKnownProviderKey
            'User-Agent' = "DeepMaskAgent/$deepMaskKnownProviderKey"
            'Content-Type' = "application/vnd.deep-$deepMaskKnownProviderKey+json"
        }
        samplingParams = [ordered]@{
            max_tokens = 54321
            stop = [object[]]@("STOP_SINGLETON_LITERAL")
            analysis_controls = [ordered]@{
                password = $deepMaskPassword
                token = $deepMaskToken
                secretKey = $deepMaskSecretKey
                auth = $deepMaskAuthProperty
                token_source = $deepMaskTokenSource
                clientSecretSource = $deepMaskClientSecretSource
                passwordEnvKey = $deepMaskPasswordEnvKey
                subscriptionKey = $deepMaskSubscriptionKey
                master_key = $deepMaskMasterKey
                functionsKey = $deepMaskFunctionsKey
                signatureValue = $deepMaskSignatureValue
                hmacValue = $deepMaskHmacValue
                token_budget = 88888
                benign_label = "KEEP_SAMPLING_BENIGN_LITERAL"
                benign_number = 2718
            }
        }
        extra_body = [ordered]@{
            empty_array = [object[]]@()
            single_array = [object[]]@("EXTRA_SINGLETON_LITERAL")
            nested_array = $deepMaskNestedArrays
            provider_options = [ordered]@{
                access_token = $deepMaskAccessToken
                provider_secret = $deepMaskProviderSecret
                benign_mode = "KEEP_EXTRA_BENIGN_LITERAL"
                benign_number = 31415
            }
        }
    }
    Write-TestSettingsVariant -Path $deepMaskSettings -Port $deepMaskPort -GenerationConfig $deepMaskGeneration

    $deepMaskRawResult = Invoke-Loop (@(Get-BaseLoopArguments $deepMaskSettings $deepMaskRawWork) + @("-DryRun"))
    Assert-True ($deepMaskRawResult.ExitCode -eq 0) ("default unmasked deep settings DryRun failed:`n" + $deepMaskRawResult.Text)
    $deepMaskRawHeadersText = Get-Content -LiteralPath (Join-Path $deepMaskRawWork "dry_run_request_headers.json") -Raw -Encoding UTF8
    $deepMaskRawBodyText = Get-Content -LiteralPath (Join-Path $deepMaskRawWork "dry_run_request_body.json") -Raw -Encoding UTF8
    $deepMaskRawSummaryText = Get-Content -LiteralPath (Join-Path $deepMaskRawWork "settings_effective_summary.json") -Raw -Encoding UTF8
    foreach ($rawHeaderSecret in @($deepMaskAuth, $deepMaskApiKey, $deepMaskXAuth, $deepMaskAccessKey, $deepMaskPrivateKey, $deepMaskSignature, $deepMaskPasswordSource, $deepMaskKnownProviderKey)) {
        Assert-True ($deepMaskRawHeadersText.Contains($rawHeaderSecret)) "default logging did not preserve raw custom header value: $rawHeaderSecret"
    }
    foreach ($bodySecret in @($deepMaskPassword, $deepMaskToken, $deepMaskSecretKey, $deepMaskAuthProperty, $deepMaskAccessToken, $deepMaskProviderSecret, $deepMaskTokenSource, $deepMaskClientSecretSource, $deepMaskPasswordEnvKey, $deepMaskSubscriptionKey, $deepMaskMasterKey, $deepMaskFunctionsKey, $deepMaskSignatureValue, $deepMaskHmacValue)) {
        Assert-True ($deepMaskRawBodyText.Contains($bodySecret)) "default request-body logging unexpectedly masked settings-first payload value: $bodySecret"
    }
    foreach ($rawSecret in $deepMaskSecrets) {
        Assert-True ($deepMaskRawSummaryText.Contains($rawSecret)) "default settings summary unexpectedly masked configured value: $rawSecret"
    }
    $deepMaskRawBody = Read-Json (Join-Path $deepMaskRawWork "dry_run_request_body.json")
    $deepMaskRawSummary = Read-Json (Join-Path $deepMaskRawWork "settings_effective_summary.json")
    Assert-True ([int]$deepMaskRawBody.max_tokens -eq 54321 -and [int]$deepMaskRawBody.analysis_controls.token_budget -eq 88888 -and [string]$deepMaskRawBody.analysis_controls.benign_label -eq "KEEP_SAMPLING_BENIGN_LITERAL" -and [int]$deepMaskRawBody.provider_options.benign_number -eq 31415) "default deep settings body lost non-secret/max_tokens/token_budget fields"
    Assert-ConfiguredArrayShape $deepMaskRawBody $deepMaskRawBody "default dry-run body"
    Assert-ConfiguredArrayShape $deepMaskRawSummary.qwenCompat.generationConfig.samplingParams $deepMaskRawSummary.qwenCompat.generationConfig.extra_body "default settings summary"

    $deepMaskDryResult = Invoke-Loop (@(Get-BaseLoopArguments $deepMaskSettings $deepMaskDryWork) + @("-MaskSensitiveLogs", "-DryRun"))
    Assert-True ($deepMaskDryResult.ExitCode -eq 0) ("masked deep settings DryRun failed:`n" + $deepMaskDryResult.Text)
    $deepMaskDryHeadersText = Get-Content -LiteralPath (Join-Path $deepMaskDryWork "dry_run_request_headers.json") -Raw -Encoding UTF8
    $deepMaskDryBodyText = Get-Content -LiteralPath (Join-Path $deepMaskDryWork "dry_run_request_body.json") -Raw -Encoding UTF8
    $deepMaskDrySummaryText = Get-Content -LiteralPath (Join-Path $deepMaskDryWork "settings_effective_summary.json") -Raw -Encoding UTF8
    $deepMaskDrySurface = $deepMaskDryHeadersText + "`n" + $deepMaskDryBodyText + "`n" + $deepMaskDrySummaryText
    foreach ($maskedSecret in $deepMaskSecrets) {
        Assert-True (-not $deepMaskDrySurface.Contains($maskedSecret)) "-MaskSensitiveLogs leaked configured literal into dry-run logs/summary: $maskedSecret"
        Assert-True (-not $deepMaskDryResult.Text.Contains($maskedSecret)) "-MaskSensitiveLogs leaked configured literal into dry-run console output: $maskedSecret"
    }
    $deepMaskDryBody = Read-Json (Join-Path $deepMaskDryWork "dry_run_request_body.json")
    $deepMaskDrySummary = Read-Json (Join-Path $deepMaskDryWork "settings_effective_summary.json")
    Assert-True ([int]$deepMaskDryBody.max_tokens -eq 54321 -and [int]$deepMaskDryBody.analysis_controls.token_budget -eq 88888 -and [string]$deepMaskDryBody.analysis_controls.benign_label -eq "KEEP_SAMPLING_BENIGN_LITERAL" -and [int]$deepMaskDryBody.analysis_controls.benign_number -eq 2718 -and [string]$deepMaskDryBody.provider_options.benign_mode -eq "KEEP_EXTRA_BENIGN_LITERAL" -and [int]$deepMaskDryBody.provider_options.benign_number -eq 31415) "deep masking removed max_tokens, token_budget, or benign nested settings"
    Assert-ConfiguredArrayShape $deepMaskDryBody $deepMaskDryBody "masked dry-run body"
    Assert-ConfiguredArrayShape $deepMaskDrySummary.qwenCompat.generationConfig.samplingParams $deepMaskDrySummary.qwenCompat.generationConfig.extra_body "masked settings summary"
    Assert-True (-not ([string]$deepMaskDrySummary.qwenCompat.userAgent).Contains($deepMaskKnownProviderKey) -and -not ([string]$deepMaskDrySummary.qwenCompat.contentType).Contains($deepMaskKnownProviderKey) -and [string]$deepMaskDrySummary.qwenCompat.userAgentSource -eq "settings.generationConfig.customHeaders.User-Agent" -and [string]$deepMaskDrySummary.qwenCompat.contentTypeSource -eq "settings.generationConfig.customHeaders.Content-Type") "masked effective User-Agent/Content-Type leaked the provider key or lost source diagnostics"
    Assert-True ($deepMaskDryBodyText -match 'REDACTED|\*\*\*\*' -and $deepMaskDrySummaryText -match 'REDACTED|\*\*\*\*') "masked deep artifacts contained no visible redaction diagnostics"

    $deepMaskServer = Start-MockServer $deepMaskPort 1 $deepMaskRequestLog $deepMaskReady "normal" 0 $deepMaskHeaderLog
    $deepMaskLiveArguments = @(Get-BaseLoopArguments $deepMaskSettings $deepMaskLiveWork) + @(
        "-MaskSensitiveLogs", "-SeedFile", (Join-Path $repo "seed_prompt.txt"),
        "-QuestionBankFile", (Join-Path $repo "question_bank.txt"), "-Once"
    )
    $deepMaskLiveResult = Invoke-Loop $deepMaskLiveArguments
    Wait-MockServer $deepMaskServer 5000
    Assert-True ($deepMaskLiveResult.ExitCode -eq 0) ("masked deep settings live run failed:`n" + $deepMaskLiveResult.Text)
    $deepMaskWireBodyText = Get-Content -LiteralPath $deepMaskRequestLog -Raw -Encoding UTF8
    $deepMaskWireHeadersText = Get-Content -LiteralPath $deepMaskHeaderLog -Raw -Encoding UTF8
    $deepMaskWireBody = @(Read-JsonLines $deepMaskRequestLog)[0]
    Assert-ConfiguredArrayShape $deepMaskWireBody $deepMaskWireBody "live wire body"
    foreach ($wireBodySecret in @($deepMaskPassword, $deepMaskToken, $deepMaskSecretKey, $deepMaskAuthProperty, $deepMaskAccessToken, $deepMaskProviderSecret, $deepMaskTokenSource, $deepMaskClientSecretSource, $deepMaskPasswordEnvKey, $deepMaskSubscriptionKey, $deepMaskMasterKey, $deepMaskFunctionsKey, $deepMaskSignatureValue, $deepMaskHmacValue)) {
        Assert-True ($deepMaskWireBodyText.Contains($wireBodySecret)) "logging mask altered the live request body value: $wireBodySecret"
    }
    foreach ($wireHeaderSecret in @($deepMaskAuth, $deepMaskApiKey, $deepMaskXAuth, $deepMaskAccessKey, $deepMaskPrivateKey, $deepMaskSignature, $deepMaskPasswordSource, $deepMaskKnownProviderKey)) {
        Assert-True ($deepMaskWireHeadersText.Contains($wireHeaderSecret)) "logging mask altered live custom header value: $wireHeaderSecret"
    }
    $deepMaskSavedHeadersText = Get-Content -LiteralPath (Join-Path $deepMaskLiveWork "last_request_headers.json") -Raw -Encoding UTF8
    $deepMaskSavedBodyText = Get-Content -LiteralPath (Join-Path $deepMaskLiveWork "last_request_body.json") -Raw -Encoding UTF8
    $deepMaskLiveSummaryText = Get-Content -LiteralPath (Join-Path $deepMaskLiveWork "settings_effective_summary.json") -Raw -Encoding UTF8
    $deepMaskSavedSurface = $deepMaskSavedHeadersText + "`n" + $deepMaskSavedBodyText + "`n" + $deepMaskLiveSummaryText
    foreach ($maskedSecret in $deepMaskSecrets) {
        Assert-True (-not $deepMaskSavedSurface.Contains($maskedSecret)) "-MaskSensitiveLogs leaked configured literal into live saved logs/summary: $maskedSecret"
        Assert-True (-not $deepMaskLiveResult.Text.Contains($maskedSecret)) "-MaskSensitiveLogs leaked configured literal into live console output: $maskedSecret"
    }
    $deepMaskSavedBody = Read-Json (Join-Path $deepMaskLiveWork "last_request_body.json")
    $deepMaskLiveSummary = Read-Json (Join-Path $deepMaskLiveWork "settings_effective_summary.json")
    Assert-True ([int]$deepMaskSavedBody.max_tokens -eq 54321 -and [int]$deepMaskSavedBody.analysis_controls.token_budget -eq 88888 -and [string]$deepMaskSavedBody.analysis_controls.benign_label -eq "KEEP_SAMPLING_BENIGN_LITERAL" -and [int]$deepMaskSavedBody.provider_options.benign_number -eq 31415) "live masking removed max_tokens, token_budget, or benign nested settings"
    Assert-ConfiguredArrayShape $deepMaskSavedBody $deepMaskSavedBody "masked live saved body"
    Assert-ConfiguredArrayShape $deepMaskLiveSummary.qwenCompat.generationConfig.samplingParams $deepMaskLiveSummary.qwenCompat.generationConfig.extra_body "masked live settings summary"

    # Exact known-secret values must be redacted even when short, while a short
    # sequence embedded in an otherwise harmless diagnostic value must not be
    # replaced as a generic substring.
    $shortMaskPort = Get-FreeTcpPort
    $shortMaskSettings = Join-Path $runtime "settings-short-known-secret.json"
    $shortMaskWork = Join-Path $runtime "work\settings-short-known-secret"
    $shortKnownKey = "k3y"
    $shortEmbeddedValue = "prefix-$shortKnownKey-suffix"
    $shortUserAgent = "ShortKnownKeyAgent/$shortKnownKey"
    $shortContentType = "application/vnd.short-$shortKnownKey+json"
    $shortMaskGeneration = [ordered]@{
        modalities = [ordered]@{ image = $false }
        customHeaders = [ordered]@{
            'X-Custom' = $shortKnownKey
            'X-Embedded' = $shortEmbeddedValue
            'User-Agent' = $shortUserAgent
            'Content-Type' = $shortContentType
        }
    }
    Write-TestSettingsVariant -Path $shortMaskSettings -Port $shortMaskPort -GenerationConfig $shortMaskGeneration -ApiKey $shortKnownKey
    $shortMaskResult = Invoke-Loop (@(Get-BaseLoopArguments $shortMaskSettings $shortMaskWork) + @("-MaskSensitiveLogs", "-DryRun"))
    Assert-True ($shortMaskResult.ExitCode -eq 0) ("short known-secret masking DryRun failed:`n" + $shortMaskResult.Text)
    $shortMaskHeaders = Read-Json (Join-Path $shortMaskWork "dry_run_request_headers.json")
    $shortMaskSummary = Read-Json (Join-Path $shortMaskWork "settings_effective_summary.json")
    Assert-True (-not ([string]$shortMaskHeaders.Authorization).Contains($shortKnownKey) -and -not ([string]$shortMaskHeaders.'X-Custom').Contains($shortKnownKey)) "short exact provider key was not redacted from Authorization/X-Custom logs"
    Assert-True ([string]$shortMaskHeaders.'X-Embedded' -eq $shortEmbeddedValue -and [string]$shortMaskHeaders.'User-Agent' -eq $shortUserAgent -and [string]$shortMaskHeaders.'Content-Type' -eq $shortContentType) "short embedded provider-key substring was over-redacted from harmless header diagnostics"
    Assert-True (-not ([string]$shortMaskSummary.apiKeyLogged).Contains($shortKnownKey) -and -not ([string]$shortMaskSummary.qwenCompat.generationConfig.customHeaders.'X-Custom').Contains($shortKnownKey)) "short exact provider key leaked through the masked settings summary"
    Assert-True ([string]$shortMaskSummary.qwenCompat.generationConfig.customHeaders.'X-Embedded' -eq $shortEmbeddedValue -and [string]$shortMaskSummary.qwenCompat.userAgent -eq $shortUserAgent -and [string]$shortMaskSummary.qwenCompat.contentType -eq $shortContentType) "short embedded provider-key substring was over-redacted from settings summary diagnostics"

    $lengthPort = Get-FreeTcpPort
    $lengthSettings = Join-Path $runtime "settings-content-length.json"
    $lengthWork = Join-Path $runtime "work\settings-content-length"
    $lengthGeneration = [ordered]@{
        modalities = [ordered]@{ image = $false }
        customHeaders = [ordered]@{ 'Content-Length' = "999" }
    }
    Write-TestSettingsVariant -Path $lengthSettings -Port $lengthPort -GenerationConfig $lengthGeneration
    $lengthResult = Invoke-Loop (@(Get-BaseLoopArguments $lengthSettings $lengthWork) + @("-DryRun"))
    Assert-True ($lengthResult.ExitCode -ne 0) "customHeaders.Content-Length was accepted even though transport owns it"
    Assert-True ($lengthResult.Text -match '(?i)Content-Length.*(transport|body|관리)') "Content-Length rejection was not actionable"

    $missingExplicitWork = Join-Path $runtime "work\settings-missing-explicit-provider"
    $missingExplicitResult = Invoke-Loop (@(Get-BaseLoopArguments $endpointSettings $missingExplicitWork) + @(
        "-ProviderName", "provider-that-does-not-exist", "-DryRun"
    ))
    Assert-True ($missingExplicitResult.ExitCode -ne 0) "an explicit missing provider target silently fell back to the first configured provider"
    Assert-True ($missingExplicitResult.Text -match '(?i)provider-that-does-not-exist.*(fallback|찾지|available)') "explicit provider miss did not identify the target and no-fallback policy"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $missingExplicitWork "dry_run_request_body.json") -PathType Leaf)) "explicit provider miss produced a request body for the wrong fallback provider"

    $missingSettingsPort = Get-FreeTcpPort
    $missingSettingsPath = Join-Path $runtime "settings-missing-selected-provider.json"
    $missingSettingsWork = Join-Path $runtime "work\settings-missing-selected-provider"
    Write-TestSettings $missingSettingsPath $missingSettingsPort
    $missingSettingsObject = Read-Json $missingSettingsPath
    $missingSettingsObject.model.name = "settings-provider-that-does-not-exist"
    [System.IO.File]::WriteAllText($missingSettingsPath, ($missingSettingsObject | ConvertTo-Json -Depth 30), $utf8)
    $missingSettingsResult = Invoke-Loop (@(Get-BaseLoopArguments $missingSettingsPath $missingSettingsWork) + @("-DryRun"))
    Assert-True ($missingSettingsResult.ExitCode -ne 0) "a missing settings model.name/provider target silently fell back to the first configured provider"
    Assert-True ($missingSettingsResult.Text -match '(?i)settings-provider-that-does-not-exist.*(fallback|찾지|available)') "settings provider miss did not identify the target and no-fallback policy"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $missingSettingsWork "dry_run_request_body.json") -PathType Leaf)) "settings provider miss produced a request body for the wrong fallback provider"

    $invalidEndpointPort = Get-FreeTcpPort
    $invalidEndpointSettings = Join-Path $runtime "settings-invalid-endpoint.json"
    Write-TestSettingsVariant -Path $invalidEndpointSettings -Port $invalidEndpointPort -BaseUrl "ftp://invalid-endpoint.example"
    $preflightCases = @(
        [PSCustomObject]@{
            Name = "missing-provider"
            Settings = $endpointSettings
            Extra = @("-ProviderName", "preflight-provider-does-not-exist")
        },
        [PSCustomObject]@{
            Name = "ambiguous-body"
            Settings = $ambiguousSettings
            Extra = @()
        },
        [PSCustomObject]@{
            Name = "restricted-header"
            Settings = $lengthSettings
            Extra = @()
        },
        [PSCustomObject]@{
            Name = "invalid-endpoint"
            Settings = $invalidEndpointSettings
            Extra = @()
        }
    )
    foreach ($preflightCase in $preflightCases) {
        $preflightSessionRoot = Join-Path $runtime ("preflight-session-" + [string]$preflightCase.Name)
        $preflightArguments = @(Get-BaseLoopArguments ([string]$preflightCase.Settings) $preflightSessionRoot) + @(
            "-ProjectRoot", $businessFixture, "-NewProjectSession", "-FreshProjectQuestion", "-DryRun"
        ) + @($preflightCase.Extra)
        $preflightResult = Invoke-Loop $preflightArguments
        Assert-True ($preflightResult.ExitCode -ne 0) "NewProjectSession preflight case '$($preflightCase.Name)' unexpectedly succeeded"
        Assert-True (-not (Test-Path -LiteralPath $preflightSessionRoot)) "NewProjectSession preflight failure '$($preflightCase.Name)' created a session root before validation completed"
    }
}

function Invoke-EmptyPartialCase([string]$Name, [string]$FinishReason, [bool]$Streaming) {
    $port = Get-FreeTcpPort
    $settingsPath = Join-Path $runtime ("$Name-settings.json")
    $requestLog = Join-Path $runtime ("$Name-requests.jsonl")
    $readyPath = Join-Path $runtime ("$Name-ready.txt")
    $workDir = Join-Path $runtime ("work\$Name")
    if ($Streaming) {
        Write-TestSettings $settingsPath $port
    } else {
        $generationConfig = [ordered]@{
            modalities = [ordered]@{ image = $false }
            extra_body = [ordered]@{ stream = $false }
        }
        Write-TestSettingsVariant -Path $settingsPath -Port $port -GenerationConfig $generationConfig
    }
    $server = Start-MockServer $port 1 $requestLog $readyPath "empty-partial" 0 "" $FinishReason $true
    $arguments = @(Get-BaseLoopArguments $settingsPath $workDir) + @(
        "-SeedFile", (Join-Path $repo "seed_prompt.txt"),
        "-QuestionBankFile", (Join-Path $repo "question_bank.txt"), "-Once"
    )
    $result = Invoke-Loop $arguments
    Wait-MockServer $server 5000
    Assert-True ($result.ExitCode -eq 2) "$Name should be an incomplete partial (exit 2), not success or protocol error"
    $status = Read-Json (Join-Path $workDir "last_response_status.json")
    Assert-True ([bool]$status.ok) "$Name was incorrectly persisted as a transport/protocol error"
    Assert-True ([string]$status.finishReason -eq $FinishReason) "$Name lost finish_reason=$FinishReason"
    Assert-True ([int]$status.answerChars -eq 0) "$Name did not preserve the valid empty response shape"
    Assert-True ([string]$status.responseParseMode -eq $(if ($Streaming) { "sse" } else { "json" })) "$Name used the wrong response parser"
    $history = @(Read-JsonLines (Join-Path $workDir "run_history.jsonl"))
    Assert-True ($history.Count -eq 1 -and [string]$history[0].status -eq "partial") "$Name was not recorded as a partial turn"
    Assert-True ([string]$history[0].partialReason -eq "finish_reason=$FinishReason") "$Name partial reason did not retain finish_reason"
    $continuation = Get-Content -LiteralPath (Join-Path $workDir "next_question.txt") -Raw -Encoding UTF8
    Assert-True $continuation.Contains("finish_reason=$FinishReason") "$Name did not queue an explicit continuation"
}

function Test-RecoveryRegressions {
    Write-Host "[Recovery] empty truncation, cycle isolation, and pending-turn roll-forward" -ForegroundColor Cyan
    Invoke-EmptyPartialCase "empty-sse-length" "length" $true
    Invoke-EmptyPartialCase "empty-json-content-filter" "content_filter" $false

    $recoveryPort = Get-FreeTcpPort
    $settingsPath = Join-Path $runtime "pending-recovery-settings.json"
    Write-TestSettings $settingsPath $recoveryPort

    $stalePendingWork = Join-Path $runtime "work\stale-pending-recovery"
    New-Item -ItemType Directory -Force -Path $stalePendingWork | Out-Null
    $oldPendingQuestion = "OLD_PENDING_QUESTION_MUST_NOT_REWIND"
    $oldRecoveredQuestion = "OLD_RECOVERED_NEXT_MUST_NOT_REPLACE_LATEST"
    $latestDurableQuestion = "LATEST_DURABLE_NEXT_QUESTION"
    $oldPending = [ordered]@{
        schema = "qwen-loop-pending-turn/v1"
        seq = 5
        startedAt = (Get-Date).AddMinutes(-5).ToString("o")
        question = $oldPendingQuestion
        cycleIndex = $null
        turnInCycle = $null
    }
    $oldState = [ordered]@{
        schema = "qwen-loop-turn-state/v1"
        nextQuestion = $oldRecoveredQuestion
        lastTurnText = "OLD_LAST_TURN"
        partialStateMode = "clear"
        partialState = $null
        explorationStateMode = "unchanged"
        explorationState = $null
    }
    $oldRecord = [ordered]@{ seq = 5; question = $oldPendingQuestion; completionStatus = "ok"; nextQuestion = $oldRecoveredQuestion; stateAfter = $oldState }
    $newerRecord = [ordered]@{ seq = 6; question = "NEWER_DURABLE_QUESTION"; completionStatus = "ok"; nextQuestion = $latestDurableQuestion }
    [System.IO.File]::WriteAllText((Join-Path $stalePendingWork "pending_turn.json"), ($oldPending | ConvertTo-Json -Depth 20), $utf8)
    [System.IO.File]::WriteAllText((Join-Path $stalePendingWork "pending_question.txt"), $oldPendingQuestion, $utf8)
    [System.IO.File]::WriteAllText((Join-Path $stalePendingWork "next_question.txt"), $latestDurableQuestion, $utf8)
    $staleTranscriptLines = ($oldRecord | ConvertTo-Json -Compress -Depth 30) + [Environment]::NewLine + ($newerRecord | ConvertTo-Json -Compress -Depth 30) + [Environment]::NewLine
    [System.IO.File]::WriteAllText((Join-Path $stalePendingWork "transcript.jsonl"), $staleTranscriptLines, $utf8)
    $staleDryArgs = @(Get-BaseLoopArguments $settingsPath $stalePendingWork) + @("-DryRun")
    $staleDryResult = Invoke-Loop $staleDryArgs
    Assert-True ($staleDryResult.ExitCode -eq 0) ("stale pending-marker DryRun failed:`n" + $staleDryResult.Text)
    Assert-True ((Get-Content -LiteralPath (Join-Path $stalePendingWork "next_question.txt") -Raw -Encoding UTF8).Trim() -eq $latestDurableQuestion) "stale pending marker rewound a newer durable next_question"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $stalePendingWork "pending_turn.json") -PathType Leaf)) "stale structured pending marker was not cleared"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $stalePendingWork "pending_question.txt") -PathType Leaf)) "stale legacy pending marker was not cleared"
    $staleDryBody = Read-Json (Join-Path $stalePendingWork "dry_run_request_body.json")
    $staleDryPrompt = [string]$staleDryBody.messages[1].content
    Assert-True $staleDryPrompt.Contains($latestDurableQuestion) "DryRun did not keep the latest durable question after clearing a stale marker"
    Assert-True (-not $staleDryPrompt.Contains($oldRecoveredQuestion)) "stale pending state leaked into the request after a newer durable transcript"

    $tornPort = Get-FreeTcpPort
    $tornSettings = Join-Path $runtime "torn-jsonl-settings.json"
    $tornWork = Join-Path $runtime "work\torn-jsonl"
    $tornRequestLog = Join-Path $runtime "torn-jsonl-requests.jsonl"
    $tornReady = Join-Path $runtime "torn-jsonl-ready.txt"
    Write-TestSettings $tornSettings $tornPort
    New-Item -ItemType Directory -Force -Path $tornWork | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $tornWork "next_question.txt"), "TORN_JSONL_RECOVERY_QUESTION", $utf8)
    [System.IO.File]::WriteAllText((Join-Path $tornWork "transcript.jsonl"), '{"seq":7', $utf8)
    [System.IO.File]::WriteAllText((Join-Path $tornWork "run_history.jsonl"), '{"seq":7,"status":"error","question":"PREVIOUS_ATTEMPT"}' + [Environment]::NewLine, $utf8)
    $tornServer = Start-MockServer $tornPort 1 $tornRequestLog $tornReady "normal" 0
    $tornArguments = @(Get-BaseLoopArguments $tornSettings $tornWork) + @("-Once")
    $tornResult = Invoke-Loop $tornArguments
    Wait-MockServer $tornServer 5000
    Assert-True ($tornResult.ExitCode -eq 0) ("run after torn transcript JSONL failed:`n" + $tornResult.Text)
    $tornLines = @([System.IO.File]::ReadAllLines((Join-Path $tornWork "transcript.jsonl"), [System.Text.Encoding]::UTF8) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Assert-True ($tornLines.Count -eq 2) "new transcript record was concatenated onto a torn final JSON line"
    Assert-True ([string]$tornLines[0] -eq '{"seq":7') "torn forensic line was unexpectedly rewritten"
    $validAfterTorn = $tornLines[1] | ConvertFrom-Json
    Assert-True ([int]$validAfterTorn.seq -eq 8) "valid record after torn JSONL did not use the next durable sequence"

    $cleanupPort = Get-FreeTcpPort
    $cleanupSettings = Join-Path $runtime "malformed-cleanup-settings.json"
    $cleanupWork = Join-Path $runtime "work\malformed-cleanup"
    $cleanupRequestLog = Join-Path $runtime "malformed-cleanup-requests.jsonl"
    $cleanupReady = Join-Path $runtime "malformed-cleanup-ready.txt"
    Write-TestSettings $cleanupSettings $cleanupPort
    New-Item -ItemType Directory -Force -Path $cleanupWork | Out-Null
    $largeCleanupAnswer = "".PadLeft(1200000, [char]'X')
    $cleanupPriorRecord = [ordered]@{
        seq = 41
        question = "PRE_CLEANUP_VALID_QUESTION"
        nextQuestion = "CLEANUP_RECOVERY_QUESTION"
        completionStatus = "ok"
        answer = $largeCleanupAnswer
    }
    $cleanupInput = ($cleanupPriorRecord | ConvertTo-Json -Compress -Depth 10) + [Environment]::NewLine +
        '{"seq":42,"question":"TORN_FINAL_RECORD' + [Environment]::NewLine +
        '{this-is-malformed-json}' + [Environment]::NewLine
    [System.IO.File]::WriteAllText((Join-Path $cleanupWork "transcript.jsonl"), $cleanupInput, $utf8)
    $cleanupServer = Start-MockServer $cleanupPort 1 $cleanupRequestLog $cleanupReady "normal" 0
    $cleanupBaseArguments = @(Get-BaseLoopArguments $cleanupSettings $cleanupWork | Where-Object { $_ -ne "-NoAutoCleanup" })
    $cleanupArguments = $cleanupBaseArguments + @(
        "-MaxTranscriptMB", "1", "-CleanupKeepTurns", "10",
        "-MaxWorkDirMB", "0", "-CleanupKeepDays", "0", "-Once"
    )
    $cleanupResult = Invoke-Loop $cleanupArguments
    Wait-MockServer $cleanupServer 8000
    Assert-True ($cleanupResult.ExitCode -eq 0) ("run after malformed transcript cleanup failed:`n" + $cleanupResult.Text)
    $cleanupSummary = Read-Json (Join-Path $cleanupWork "settings_effective_summary.json")
    $cleanupActions = @($cleanupSummary.autoCleanup.startup.actions)
    Assert-True (@($cleanupActions | Where-Object { [string]$_.kind -eq "compacted" -and [string]$_.path -eq "transcript.jsonl" }).Count -eq 1) "oversized malformed transcript did not exercise JSONL compaction"
    $cleanedLines = @(Get-Content -LiteralPath (Join-Path $cleanupWork "transcript.jsonl") -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $cleanedRecords = New-Object System.Collections.Generic.List[object]
    $invalidCleanedLines = New-Object System.Collections.Generic.List[string]
    foreach ($line in $cleanedLines) {
        try { $cleanedRecords.Add(($line | ConvertFrom-Json)) | Out-Null }
        catch { $invalidCleanedLines.Add([string]$line) | Out-Null }
    }
    Assert-True ($invalidCleanedLines.Count -eq 0) ("transcript cleanup emitted malformed JSONL line(s): " + (($invalidCleanedLines | ForEach-Object { if ($_.Length -gt 100) { $_.Substring(0, 100) } else { $_ } }) -join " | "))
    Assert-True (@($cleanedRecords | Where-Object { [int]$_.seq -eq 41 }).Count -eq 1) "cleanup lost the last valid preexisting transcript record"
    Assert-True (@($cleanedRecords | Where-Object { [int]$_.seq -eq 42 -and [string]$_.completionStatus -eq "ok" }).Count -eq 1) "post-cleanup response was not appended as one valid next-sequence record"
    Assert-True ((Get-Item -LiteralPath (Join-Path $cleanupWork "transcript.jsonl")).Length -lt 1MB) "JSONL cleanup did not reduce the oversized transcript below its configured cap"

    $uncommittedWork = Join-Path $runtime "work\request-uncommitted"
    New-Item -ItemType Directory -Force -Path $uncommittedWork | Out-Null
    $oldUncommittedNext = "OLD_NEXT_QUESTION_MUST_NOT_BE_RETRANSMITTED"
    $interruptedHttpQuestion = "INTERRUPTED_HTTP_QUESTION_WITHOUT_TRANSCRIPT_COMMIT"
    $uncommittedPending = [ordered]@{
        schema = "qwen-loop-pending-turn/v1"
        seq = 20
        startedAt = (Get-Date).AddMinutes(-2).ToString("o")
        question = $interruptedHttpQuestion
        cycleIndex = 1
        turnInCycle = 1
    }
    [System.IO.File]::WriteAllText((Join-Path $uncommittedWork "next_question.txt"), $oldUncommittedNext, $utf8)
    [System.IO.File]::WriteAllText((Join-Path $uncommittedWork "pending_question.txt"), $interruptedHttpQuestion, $utf8)
    [System.IO.File]::WriteAllText((Join-Path $uncommittedWork "pending_turn.json"), ($uncommittedPending | ConvertTo-Json -Depth 20), $utf8)
    [System.IO.File]::WriteAllText((Join-Path $uncommittedWork "transcript.jsonl"), '{"seq":19,"question":"OLDER_COMMITTED","completionStatus":"ok","nextQuestion":"OLDER_NEXT"}' + [Environment]::NewLine, $utf8)
    $uncommittedArgs = @(Get-BaseLoopArguments $settingsPath $uncommittedWork) + @("-ProjectRoot", $businessFixture, "-DryRun")
    $uncommittedResult = Invoke-Loop $uncommittedArgs
    Assert-True ($uncommittedResult.ExitCode -eq 0) ("request-uncommitted project DryRun failed:`n" + $uncommittedResult.Text)
    $uncommittedSummary = Read-Json (Join-Path $uncommittedWork "settings_effective_summary.json")
    Assert-True ([string]$uncommittedSummary.initialQuestionSource -eq "project-interrupted-turn-escape") "request-uncommitted project did not select the escape-question policy"
    $escapedQuestion = (Get-Content -LiteralPath (Join-Path $uncommittedWork "next_question.txt") -Raw -Encoding UTF8).Trim()
    Assert-True ($escapedQuestion -ne $oldUncommittedNext -and $escapedQuestion -ne $interruptedHttpQuestion) "request-uncommitted project reused an already-sent or stale exact question"
    $uncommittedBody = Read-Json (Join-Path $uncommittedWork "dry_run_request_body.json")
    $uncommittedPrompt = [string]$uncommittedBody.messages[1].content
    Assert-True (-not $uncommittedPrompt.Contains($oldUncommittedNext)) "request-uncommitted DryRun retransmitted stale next_question content"
    Assert-True (Test-Path -LiteralPath (Join-Path $uncommittedWork "pending_turn.json") -PathType Leaf) "uncommitted structured marker was discarded without a transcript commit"

    $generalBankPath = Join-Path $runtime "interrupted-general-bank.txt"
    $generalInterruptedQuestion = "GENERAL_INTERRUPTED_QUESTION_MUST_NOT_REPOST"
    $generalAlternateQuestion = "GENERAL_ALTERNATE_BUSINESS_QUESTION"
    [System.IO.File]::WriteAllText($generalBankPath, "[general] $generalInterruptedQuestion`n[general] $generalAlternateQuestion`n", $utf8)

    $generalPendingPort = Get-FreeTcpPort
    $generalPendingSettings = Join-Path $runtime "general-pending-settings.json"
    $generalPendingWork = Join-Path $runtime "work\general-pending-uncommitted"
    $generalPendingRequestLog = Join-Path $runtime "general-pending-requests.jsonl"
    $generalPendingReady = Join-Path $runtime "general-pending-ready.txt"
    Write-TestSettings $generalPendingSettings $generalPendingPort
    New-Item -ItemType Directory -Force -Path $generalPendingWork | Out-Null
    $generalPendingRecord = [ordered]@{
        schema = "qwen-loop-pending-turn/v1"
        seq = 50
        startedAt = (Get-Date).AddMinutes(-2).ToString("o")
        question = $generalInterruptedQuestion
        cycleIndex = $null
        turnInCycle = $null
    }
    [System.IO.File]::WriteAllText((Join-Path $generalPendingWork "next_question.txt"), $generalInterruptedQuestion, $utf8)
    [System.IO.File]::WriteAllText((Join-Path $generalPendingWork "pending_question.txt"), $generalInterruptedQuestion, $utf8)
    [System.IO.File]::WriteAllText((Join-Path $generalPendingWork "pending_turn.json"), ($generalPendingRecord | ConvertTo-Json -Depth 20), $utf8)
    $generalPendingServer = Start-MockServer $generalPendingPort 1 $generalPendingRequestLog $generalPendingReady "normal" 0
    $generalPendingArguments = @(Get-BaseLoopArguments $generalPendingSettings $generalPendingWork) + @(
        "-QuestionBankFile", $generalBankPath, "-QuestionTrack", "general", "-Once"
    )
    $generalPendingResult = Invoke-Loop $generalPendingArguments
    Wait-MockServer $generalPendingServer 5000
    Assert-True ($generalPendingResult.ExitCode -eq 0) ("general structured pending restart failed:`n" + $generalPendingResult.Text)
    $generalPendingRequest = @(Read-JsonLines $generalPendingRequestLog)[0]
    $generalPendingPrompt = [string]$generalPendingRequest.messages[1].content
    Assert-True ($generalPendingPrompt.Contains($generalAlternateQuestion) -and -not $generalPendingPrompt.Contains($generalInterruptedQuestion)) "general structured pending restart re-POSTed the exact interrupted question"
    $generalPendingTranscript = @(Read-JsonLines (Join-Path $generalPendingWork "transcript.jsonl"))
    Assert-True ($generalPendingTranscript.Count -eq 1 -and [int]$generalPendingTranscript[0].seq -eq 51 -and [string]$generalPendingTranscript[0].question -eq $generalAlternateQuestion) "general structured pending escape lost its sequence floor or alternate seed"

    $legacyInterruptedQuestion = "LEGACY_INTERRUPTED_QUESTION_MUST_NOT_REPOST"
    $legacyAlternateQuestion = "LEGACY_ALTERNATE_BUSINESS_QUESTION"
    $legacyBankPath = Join-Path $runtime "interrupted-legacy-bank.txt"
    [System.IO.File]::WriteAllText($legacyBankPath, "[general] $legacyInterruptedQuestion`n[general] $legacyAlternateQuestion`n", $utf8)
    $legacyPendingPort = Get-FreeTcpPort
    $legacyPendingSettings = Join-Path $runtime "legacy-pending-settings.json"
    $legacyPendingWork = Join-Path $runtime "work\legacy-pending-uncommitted"
    $legacyPendingRequestLog = Join-Path $runtime "legacy-pending-requests.jsonl"
    $legacyPendingReady = Join-Path $runtime "legacy-pending-ready.txt"
    Write-TestSettings $legacyPendingSettings $legacyPendingPort
    New-Item -ItemType Directory -Force -Path $legacyPendingWork | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $legacyPendingWork "next_question.txt"), $legacyInterruptedQuestion, $utf8)
    [System.IO.File]::WriteAllText((Join-Path $legacyPendingWork "pending_question.txt"), $legacyInterruptedQuestion, $utf8)
    $legacyPendingServer = Start-MockServer $legacyPendingPort 1 $legacyPendingRequestLog $legacyPendingReady "normal" 0
    $legacyPendingArguments = @(Get-BaseLoopArguments $legacyPendingSettings $legacyPendingWork) + @(
        "-QuestionBankFile", $legacyBankPath, "-QuestionTrack", "general", "-Once"
    )
    $legacyPendingResult = Invoke-Loop $legacyPendingArguments
    Wait-MockServer $legacyPendingServer 5000
    Assert-True ($legacyPendingResult.ExitCode -eq 0) ("general legacy pending restart failed:`n" + $legacyPendingResult.Text)
    $legacyPendingPrompt = [string](@(Read-JsonLines $legacyPendingRequestLog)[0].messages[1].content)
    Assert-True ($legacyPendingPrompt.Contains($legacyAlternateQuestion) -and -not $legacyPendingPrompt.Contains($legacyInterruptedQuestion)) "general legacy pending restart re-POSTed the exact interrupted question"

    $freshFloorPort = Get-FreeTcpPort
    $freshFloorSettings = Join-Path $runtime "fresh-sequence-floor-settings.json"
    $freshFloorWork = Join-Path $runtime "work\fresh-sequence-floor"
    $freshFloorRequestLog = Join-Path $runtime "fresh-sequence-floor-requests.jsonl"
    $freshFloorReady = Join-Path $runtime "fresh-sequence-floor-ready.txt"
    $freshInterruptedQuestion = "FRESH_DISCARDED_PENDING_QUESTION"
    Write-TestSettings $freshFloorSettings $freshFloorPort
    New-Item -ItemType Directory -Force -Path $freshFloorWork | Out-Null
    $freshFloorPending = [ordered]@{
        schema = "qwen-loop-pending-turn/v1"
        seq = 75
        startedAt = (Get-Date).AddMinutes(-1).ToString("o")
        question = $freshInterruptedQuestion
        cycleIndex = 1
        turnInCycle = 1
    }
    [System.IO.File]::WriteAllText((Join-Path $freshFloorWork "next_question.txt"), $freshInterruptedQuestion, $utf8)
    [System.IO.File]::WriteAllText((Join-Path $freshFloorWork "pending_question.txt"), $freshInterruptedQuestion, $utf8)
    [System.IO.File]::WriteAllText((Join-Path $freshFloorWork "pending_turn.json"), ($freshFloorPending | ConvertTo-Json -Depth 20), $utf8)
    $freshFloorServer = Start-MockServer $freshFloorPort 1 $freshFloorRequestLog $freshFloorReady "normal" 0
    $freshFloorArguments = @(Get-BaseLoopArguments $freshFloorSettings $freshFloorWork) + @(
        "-ProjectRoot", $businessFixture, "-FreshProjectQuestion", "-NoProjectQualityGate", "-Once"
    )
    $freshFloorResult = Invoke-Loop $freshFloorArguments
    Wait-MockServer $freshFloorServer 8000
    Assert-True ($freshFloorResult.ExitCode -eq 0) ("Fresh pending sequence-floor run failed:`n" + $freshFloorResult.Text)
    $freshFloorTranscript = @(Read-JsonLines (Join-Path $freshFloorWork "transcript.jsonl"))
    Assert-True ($freshFloorTranscript.Count -eq 1 -and [int]$freshFloorTranscript[0].seq -eq 76) "Fresh startup reused a sequence at or below its discarded pending request"
    Assert-True (-not ([string]$freshFloorTranscript[0].question).Contains($freshInterruptedQuestion)) "Fresh startup reused its discarded pending question"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $freshFloorWork "pending_turn.json") -PathType Leaf) -and -not (Test-Path -LiteralPath (Join-Path $freshFloorWork "pending_question.txt") -PathType Leaf)) "Fresh successful commit left discarded pending markers behind"

    $legacySnapshotWork = Join-Path $runtime "work\legacy-snapshot-sanitizer"
    New-Item -ItemType Directory -Force -Path $legacySnapshotWork | Out-Null
    $legacySnapshotPem = "LEGACY_SNAPSHOT_PEM_PAYLOAD_SENTINEL"
    $legacySnapshotExternal = "LEGACY_SNAPSHOT_EXTERNAL_PAYLOAD_SENTINEL"
    $legacySnapshot = [ordered]@{
        schema = "qwen-loop-project-scan/v1"
        root = [System.IO.Path]::GetFullPath($businessFixture)
        generatedAt = "2000-01-01T00:00:00.0000000Z"
        explorationCycle = 1
        primaryBusinessFamily = "ord1001"
        primaryQuestionCandidateFile = "src\main\java\example\ord\Ord1001Service.java"
        promptContext = "-----BEGIN PRIVATE KEY-----`n$legacySnapshotPem`n-----END PRIVATE KEY-----`n$legacySnapshotExternal"
        seedQuestion = "오래된 스냅샷의 질문 $legacySnapshotExternal"
        selectedFiles = @([ordered]@{ path = "..\outside\secret.txt"; snippet = $legacySnapshotExternal })
    }
    [System.IO.File]::WriteAllText((Join-Path $legacySnapshotWork "project_scan_cycle_001.json"), ($legacySnapshot | ConvertTo-Json -Depth 30), $utf8)
    $legacySnapshotState = [ordered]@{
        schema = "qwen-loop-project-exploration-state/v1"
        transitionId = "legacy-snapshot-state"
        updatedAt = "2000-01-01T00:00:00.0000000Z"
        cycleIndex = 1
        successfulTurnsInCycle = 1
        turnsPerCycle = 5
        primaryBusinessFamily = "ord1001"
        primaryPath = "src\main\java\example\ord\Ord1001Service.java"
        nextQuestion = "오래된 스냅샷의 질문 $legacySnapshotExternal"
    }
    [System.IO.File]::WriteAllText((Join-Path $legacySnapshotWork "exploration_state.json"), ($legacySnapshotState | ConvertTo-Json -Depth 20), $utf8)
    [System.IO.File]::WriteAllText((Join-Path $legacySnapshotWork "next_question.txt"), "오래된 스냅샷의 질문 $legacySnapshotExternal", $utf8)
    $legacySnapshotArguments = @(Get-BaseLoopArguments $settingsPath $legacySnapshotWork) + @(
        "-ProjectRoot", $businessFixture, "-DryRun", "-ProjectTurnsPerCycle", "5"
    )
    $legacySnapshotResult = Invoke-Loop $legacySnapshotArguments
    Assert-True ($legacySnapshotResult.ExitCode -eq 0) ("legacy unsafe snapshot did not recover through a fresh scan:`n" + $legacySnapshotResult.Text)
    $legacySnapshotSummary = Read-Json (Join-Path $legacySnapshotWork "settings_effective_summary.json")
    Assert-True ([string]$legacySnapshotSummary.pendingCycleRecoveryStatus -eq "snapshot-reset-committed") "legacy snapshot mismatch did not report a committed snapshot reset"
    $legacyFreshScan = Read-Json (Join-Path $legacySnapshotWork "project_scan_cycle_002.json")
    Assert-True ([string]$legacyFreshScan.schema -eq "qwen-loop-project-scan/v2" -and [int]$legacyFreshScan.sanitizerVersion -ge 3 -and [int]$legacyFreshScan.explorationCycle -eq 2) "legacy snapshot was not replaced by a current sanitized cycle scan"
    $legacySnapshotBody = Get-Content -LiteralPath (Join-Path $legacySnapshotWork "dry_run_request_body.json") -Raw -Encoding UTF8
    $legacyFreshSurface = $legacySnapshotBody + "`n" + ([string]$legacyFreshScan.promptContext) + "`n" + ([string]$legacyFreshScan.seedQuestion)
    foreach ($legacySecret in @($legacySnapshotPem, $legacySnapshotExternal)) {
        Assert-True (-not $legacyFreshSurface.Contains($legacySecret)) "legacy snapshot payload bypassed fresh sanitization: $legacySecret"
    }

    $cycleWork = Join-Path $runtime "work\committed-cycle-marker"
    $cycleBaselineArgs = @(Get-BaseLoopArguments $settingsPath $cycleWork) + @("-ProjectRoot", $businessFixture, "-FreshProjectQuestion", "-DryRun")
    $cycleBaselineResult = Invoke-Loop $cycleBaselineArgs
    Assert-True ($cycleBaselineResult.ExitCode -eq 0) ("cycle snapshot baseline DryRun failed:`n" + $cycleBaselineResult.Text)
    $cycleTwoScan = Read-Json (Join-Path $cycleWork "project_scan_summary.json")
    $cycleTwoScan.explorationCycle = 2
    $cycleTwoSnapshotPath = Join-Path $cycleWork "project_scan_cycle_002.json"
    [System.IO.File]::WriteAllText($cycleTwoSnapshotPath, ($cycleTwoScan | ConvertTo-Json -Depth 50), $utf8)
    $transitionId = [Guid]::NewGuid().ToString("N")
    $committedCycleState = [ordered]@{
        schema = "qwen-loop-project-exploration-state/v1"
        transitionId = $transitionId
        updatedAt = (Get-Date).ToString("o")
        cycleIndex = 2
        successfulTurnsInCycle = 0
        turnsPerCycle = 5
        primaryBusinessFamily = [string]$cycleTwoScan.primaryBusinessFamily
        primaryPath = [string]$cycleTwoScan.primaryQuestionCandidateFile
        nextQuestion = [string]$cycleTwoScan.seedQuestion
    }
    $committedCycleMarker = [ordered]@{
        schema = "qwen-loop-cycle-transition/v1"
        transitionId = $transitionId
        stagedAt = (Get-Date).AddSeconds(-10).ToString("o")
        reason = "successful-turn-limit"
        previousCycle = 1
        nextCycle = 2
        previousBusinessFamily = "previous-family"
        nextBusinessFamily = [string]$cycleTwoScan.primaryBusinessFamily
        nextPrimaryPath = [string]$cycleTwoScan.primaryQuestionCandidateFile
        nextSeedQuestion = [string]$cycleTwoScan.seedQuestion
    }
    $cyclePartial = [ordered]@{ schema = "qwen-loop-project-partial-state/v1"; originalQuestion = "STALE_CYCLE_PARTIAL"; queuedQuestion = "STALE_CYCLE_PARTIAL_NEXT"; continuationAttempts = 1; forceRescan = $true }
    [System.IO.File]::WriteAllText((Join-Path $cycleWork "exploration_state.json"), ($committedCycleState | ConvertTo-Json -Depth 20), $utf8)
    [System.IO.File]::WriteAllText((Join-Path $cycleWork "pending_cycle_transition.json"), ($committedCycleMarker | ConvertTo-Json -Depth 20), $utf8)
    [System.IO.File]::WriteAllText((Join-Path $cycleWork "partial_state.json"), ($cyclePartial | ConvertTo-Json -Depth 20), $utf8)
    [System.IO.File]::WriteAllText((Join-Path $cycleWork "next_question.txt"), [string]$cycleTwoScan.seedQuestion, $utf8)
    $cycleRecoveryArgs = @(Get-BaseLoopArguments $settingsPath $cycleWork) + @("-ProjectRoot", $businessFixture, "-DryRun")
    $cycleRecoveryResult = Invoke-Loop $cycleRecoveryArgs
    Assert-True ($cycleRecoveryResult.ExitCode -eq 0) ("committed cycle-marker recovery DryRun failed:`n" + $cycleRecoveryResult.Text)
    $cycleRecoveredScan = Read-Json (Join-Path $cycleWork "project_scan_summary.json")
    $cycleRecoveredState = Read-Json (Join-Path $cycleWork "exploration_state.json")
    Assert-True ([int]$cycleRecoveredScan.explorationCycle -eq 2 -and [int]$cycleRecoveredState.cycleIndex -eq 2) "committed cycle marker advanced or rewound the already-committed cycle"
    Assert-True ([string]$cycleRecoveredState.transitionId -eq $transitionId) "committed cycle recovery replaced the transaction identity"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $cycleWork "pending_cycle_transition.json") -PathType Leaf)) "committed cycle transition marker was not cleared"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $cycleWork "partial_state.json") -PathType Leaf)) "committed cycle transition did not clear stale partial state"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $cycleWork "project_scan_cycle_003.json") -PathType Leaf)) "committed marker recovery skipped forward to cycle 3"

    $stableCycleWork = Join-Path $runtime "work\stable-cycle-transition"
    $stableCycleBaselineArgs = @(Get-BaseLoopArguments $settingsPath $stableCycleWork) + @(
        "-ProjectRoot", $businessFixture, "-FreshProjectQuestion", "-DryRun", "-ProjectTurnsPerCycle", "5"
    )
    $stableCycleBaseline = Invoke-Loop $stableCycleBaselineArgs
    Assert-True ($stableCycleBaseline.ExitCode -eq 0) ("stable cycle baseline DryRun failed:`n" + $stableCycleBaseline.Text)
    $cycleOneScan = Read-Json (Join-Path $stableCycleWork "project_scan_cycle_001.json")
    $previousCycleQuestion = "PREVIOUS_CYCLE_QUESTION_SENTINEL"
    $previousCycleLastTurn = "PREVIOUS_CYCLE_LAST_TURN_SENTINEL"
    $previousCycleEvidence = "PREVIOUS_CYCLE_EVIDENCE_SENTINEL"
    $previousCycleAnswer = "PREVIOUS_CYCLE_TRANSCRIPT_ANSWER_SENTINEL"
    $foreignTranscriptSentinel = "FOREIGN_WORKDIR_TRANSCRIPT_SENTINEL"
    $cycleOneState = [ordered]@{
        schema = "qwen-loop-project-exploration-state/v1"
        updatedAt = (Get-Date).ToString("o")
        cycleIndex = 1
        successfulTurnsInCycle = 5
        turnsPerCycle = 5
        primaryBusinessFamily = [string]$cycleOneScan.primaryBusinessFamily
        primaryPath = [string]$cycleOneScan.primaryQuestionCandidateFile
        nextQuestion = $previousCycleQuestion
    }
    $cycleOneCoverage = [ordered]@{
        schema = "qwen-loop-project-exploration/v1"
        selectedAt = (Get-Date).AddMinutes(-1).ToString("o")
        projectRoot = [string]$cycleOneScan.root
        sessionId = "legacy-cycle-fixture"
        cycle = 1
        reason = "fixture-completed-cycle"
        primaryPath = [string]$cycleOneScan.primaryQuestionCandidateFile
        primaryGroupKey = [string]$cycleOneScan.primaryQuestionCandidateGroupKey
        primaryGroupLabel = [string]$cycleOneScan.primaryQuestionCandidateGroup
        businessFamily = [string]$cycleOneScan.primaryBusinessFamily
        candidatePaths = @($cycleOneScan.questionCandidateFiles)
    }
    $cycleOneTranscript = [ordered]@{
        seq = 31
        question = $previousCycleQuestion
        nextQuestion = $previousCycleQuestion
        completionStatus = "ok"
        cycleIndex = 1
        turnInCycle = 5
        primaryBusinessFamily = [string]$cycleOneScan.primaryBusinessFamily
        answer = $previousCycleAnswer
    }
    [System.IO.File]::WriteAllText((Join-Path $stableCycleWork "exploration_state.json"), ($cycleOneState | ConvertTo-Json -Depth 30), $utf8)
    [System.IO.File]::WriteAllText((Join-Path $stableCycleWork "exploration_history.jsonl"), ($cycleOneCoverage | ConvertTo-Json -Compress -Depth 30) + [Environment]::NewLine, $utf8)
    [System.IO.File]::WriteAllText((Join-Path $stableCycleWork "next_question.txt"), $previousCycleQuestion, $utf8)
    [System.IO.File]::WriteAllText((Join-Path $stableCycleWork "last_turn.txt"), $previousCycleLastTurn, $utf8)
    [System.IO.File]::WriteAllText((Join-Path $stableCycleWork "cycle_evidence.md"), "# Compact business evidence memory`n`n$previousCycleEvidence`n", $utf8)
    [System.IO.File]::WriteAllText((Join-Path $stableCycleWork "transcript.jsonl"), ($cycleOneTranscript | ConvertTo-Json -Compress -Depth 30) + [Environment]::NewLine, $utf8)

    $foreignWork = Join-Path $runtime "work\foreign-transcript-source"
    New-Item -ItemType Directory -Force -Path $foreignWork | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $foreignWork "transcript.jsonl"), '{"seq":900,"question":"FOREIGN_QUESTION","answer":"' + $foreignTranscriptSentinel + '","nextQuestion":"FOREIGN_NEXT"}' + [Environment]::NewLine, $utf8)

    $stableCyclePort = Get-FreeTcpPort
    $stableCycleSettings = Join-Path $runtime "stable-cycle-settings.json"
    $stableCycleRequestLog = Join-Path $runtime "stable-cycle-requests.jsonl"
    $stableCycleReady = Join-Path $runtime "stable-cycle-ready.txt"
    Write-TestSettings $stableCycleSettings $stableCyclePort
    $stableCycleServer = Start-MockServer $stableCyclePort 1 $stableCycleRequestLog $stableCycleReady "normal" 0
    $stableCycleArgs = @(Get-BaseLoopArguments $stableCycleSettings $stableCycleWork) + @(
        "-ProjectRoot", $businessFixture, "-ProjectTurnsPerCycle", "5", "-NoProjectQualityGate", "-Once"
    )
    $stableCycleResult = Invoke-Loop $stableCycleArgs
    Wait-MockServer $stableCycleServer 8000
    Assert-True ($stableCycleResult.ExitCode -eq 0) ("stable legacy WorkDir did not advance its completed cycle:`n" + $stableCycleResult.Text)
    $stableHistory = @(Read-JsonLines (Join-Path $stableCycleWork "run_history.jsonl"))
    $stableRun = $stableHistory | Select-Object -Last 1
    Assert-True ([int]$stableRun.cycleIndex -eq 2 -and [int]$stableRun.turnInCycle -eq 1) "completed stable cycle did not transition exactly from cycle 1 to cycle 2 turn 1"
    Assert-True ([string]$stableRun.questionSource -eq "cycle-rescan") "first request after the completed cycle was not sourced from a fresh cycle rescan"
    Assert-True (Test-Path -LiteralPath (Join-Path $stableCycleWork "project_scan_cycle_002.json") -PathType Leaf) "cycle 2 scan snapshot was not committed"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $stableCycleWork "project_scan_cycle_003.json") -PathType Leaf)) "one scheduled transition skipped directly to cycle 3"
    $cycleTwoState = Read-Json (Join-Path $stableCycleWork "exploration_state.json")
    Assert-True ([int]$cycleTwoState.cycleIndex -eq 2 -and [int]$cycleTwoState.successfulTurnsInCycle -eq 1) "cycle 2 state/counter was not committed after its first successful request"
    Assert-True ([string]$cycleTwoState.primaryBusinessFamily -ne [string]$cycleOneState.primaryBusinessFamily) "negative coverage did not move the new cycle away from the completed business family"
    $stableCycleRequest = @(Read-JsonLines $stableCycleRequestLog)[0]
    $stableCyclePrompt = [string]$stableCycleRequest.messages[1].content
    foreach ($forbidden in @($previousCycleQuestion, $previousCycleLastTurn, $previousCycleEvidence, $previousCycleAnswer, $foreignTranscriptSentinel)) {
        Assert-True (-not $stableCyclePrompt.Contains($forbidden)) "new cycle first request leaked stale or foreign conversation content: $forbidden"
    }
    $cycleHistory = @(Read-JsonLines (Join-Path $stableCycleWork "cycle_history.jsonl"))
    Assert-True ($cycleHistory.Count -eq 1 -and [int]$cycleHistory[0].previousCycle -eq 1 -and [int]$cycleHistory[0].nextCycle -eq 2) "scheduled cycle transition was not recorded exactly once as 1 -> 2"

    $workDir = Join-Path $runtime "work\pending-recovery"
    New-Item -ItemType Directory -Force -Path $workDir | Out-Null

    $crashQuestion = "CRASH_ORIGINAL_BUSINESS_QUESTION"
    $recoveredQuestion = "RECOVERED_CONTINUATION_QUESTION"
    $staleQuestion = "STALE_REWIND_QUESTION"
    $recoveredLastTurn = "RECOVERED_LAST_TURN_FROM_TRANSCRIPT_STATE"
    $pendingSeq = 12
    $recoveredPartialState = [ordered]@{
        schema = "qwen-loop-project-partial-state/v1"
        updatedAt = (Get-Date).ToString("o")
        isProject = $false
        cycleIndex = $null
        turnInCycle = $null
        primaryBusinessFamily = $null
        originalQuestion = $crashQuestion
        queuedQuestion = $recoveredQuestion
        continuationAttempts = 1
        maxContinuationAttempts = 2
        cumulativeAnswerChars = 2400
        cumulativeVisibleTokens = 900
        visibleTokensKnown = $true
        evidenceSignals = @("data-contract", "normal-flow")
        evidenceExcerpt = "RECOVERED_EVIDENCE_EXCERPT"
        lastReason = "finish_reason=length"
        forceRescan = $false
    }
    $recoveredExplorationState = [ordered]@{
        schema = "qwen-loop-project-exploration-state/v1"
        updatedAt = (Get-Date).ToString("o")
        cycleIndex = 2
        successfulTurnsInCycle = 0
        turnsPerCycle = 5
        primaryBusinessFamily = "ord1001"
        primaryPath = "src\main\resources\mapper\Ord1001Mapper.xml"
        nextQuestion = $recoveredQuestion
    }
    $stateAfter = [ordered]@{
        schema = "qwen-loop-turn-state/v1"
        nextQuestion = $recoveredQuestion
        lastTurnText = $recoveredLastTurn
        partialStateMode = "write"
        partialState = $recoveredPartialState
        explorationStateMode = "write"
        explorationState = $recoveredExplorationState
    }
    $crashTranscriptRecord = [ordered]@{
        seq = $pendingSeq
        started = (Get-Date).AddMinutes(-1).ToString("o")
        ended = (Get-Date).ToString("o")
        question = $crashQuestion
        nextQuestion = $recoveredQuestion
        completionStatus = "partial"
        partialReason = "finish_reason=length"
        stateAfter = $stateAfter
        answer = "crash answer already appended before state commit"
    }
    $pendingTurn = [ordered]@{
        schema = "qwen-loop-pending-turn/v1"
        seq = $pendingSeq
        startedAt = (Get-Date).AddMinutes(-1).ToString("o")
        question = $crashQuestion
        cycleIndex = $null
        turnInCycle = $null
    }
    $stalePartialState = [ordered]@{
        schema = "qwen-loop-project-partial-state/v1"
        originalQuestion = "STALE_ORIGINAL"
        queuedQuestion = $staleQuestion
        continuationAttempts = 0
        forceRescan = $false
    }
    $staleExplorationState = [ordered]@{
        schema = "qwen-loop-project-exploration-state/v1"
        cycleIndex = 1
        successfulTurnsInCycle = 4
        turnsPerCycle = 5
        nextQuestion = $staleQuestion
    }
    [System.IO.File]::WriteAllText((Join-Path $workDir "next_question.txt"), $staleQuestion, $utf8)
    [System.IO.File]::WriteAllText((Join-Path $workDir "last_turn.txt"), "STALE_LAST_TURN", $utf8)
    [System.IO.File]::WriteAllText((Join-Path $workDir "partial_state.json"), ($stalePartialState | ConvertTo-Json -Depth 20), $utf8)
    [System.IO.File]::WriteAllText((Join-Path $workDir "exploration_state.json"), ($staleExplorationState | ConvertTo-Json -Depth 20), $utf8)
    [System.IO.File]::WriteAllText((Join-Path $workDir "pending_question.txt"), $crashQuestion, $utf8)
    [System.IO.File]::WriteAllText((Join-Path $workDir "pending_turn.json"), ($pendingTurn | ConvertTo-Json -Depth 20), $utf8)
    $oldTranscriptRecord = [ordered]@{ seq = 4; question = "OLDER_QUESTION"; completionStatus = "ok"; nextQuestion = "OLDER_NEXT" }
    $transcriptLines = ($oldTranscriptRecord | ConvertTo-Json -Compress -Depth 10) + [Environment]::NewLine + ($crashTranscriptRecord | ConvertTo-Json -Compress -Depth 40) + [Environment]::NewLine
    [System.IO.File]::WriteAllText((Join-Path $workDir "transcript.jsonl"), $transcriptLines, $utf8)
    [System.IO.File]::WriteAllText((Join-Path $workDir "run_history.jsonl"), '{"seq":9,"status":"ok","question":"OLDER_RUN_HISTORY"}' + [Environment]::NewLine, $utf8)

    # Journal pointer recovery is intentionally exercised in general mode so
    # project cycle-snapshot recovery remains an independent transaction test.
    $dryArguments = @(Get-BaseLoopArguments $settingsPath $workDir) + @("-DryRun")
    $dryResult = Invoke-Loop $dryArguments
    Assert-True ($dryResult.ExitCode -eq 0) ("pending-turn recovery DryRun failed:`n" + $dryResult.Text)
    Assert-True ((Get-Content -LiteralPath (Join-Path $workDir "next_question.txt") -Raw -Encoding UTF8).Trim() -eq $recoveredQuestion) "pending-turn recovery did not roll next_question forward"
    Assert-True ((Get-Content -LiteralPath (Join-Path $workDir "last_turn.txt") -Raw -Encoding UTF8).Trim() -eq $recoveredLastTurn) "pending-turn recovery did not roll last_turn forward"
    $rolledPartial = Read-Json (Join-Path $workDir "partial_state.json")
    Assert-True ([string]$rolledPartial.queuedQuestion -eq $recoveredQuestion -and [int]$rolledPartial.continuationAttempts -eq 1) "pending-turn recovery did not restore partial_state"
    $rolledExploration = Read-Json (Join-Path $workDir "exploration_state.json")
    Assert-True ([int]$rolledExploration.cycleIndex -eq 2 -and [string]$rolledExploration.nextQuestion -eq $recoveredQuestion) "pending-turn recovery did not restore exploration state"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $workDir "pending_turn.json") -PathType Leaf)) "pending_turn.json survived a successful roll-forward"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $workDir "pending_question.txt") -PathType Leaf)) "legacy pending_question.txt survived a successful roll-forward"
    $dryBody = Read-Json (Join-Path $workDir "dry_run_request_body.json")
    $dryPrompt = [string]$dryBody.messages[1].content
    Assert-True $dryPrompt.Contains($recoveredQuestion) "DryRun request did not continue from the recovered question"
    Assert-True (-not $dryPrompt.Contains($staleQuestion)) "DryRun request rewound to stale next_question state"

    $livePort = Get-FreeTcpPort
    Write-TestSettings $settingsPath $livePort
    $requestLog = Join-Path $runtime "pending-recovery-requests.jsonl"
    $readyPath = Join-Path $runtime "pending-recovery-ready.txt"
    $server = Start-MockServer $livePort 1 $requestLog $readyPath "normal" 0
    $liveArguments = @(Get-BaseLoopArguments $settingsPath $workDir) + @("-Once")
    $liveResult = Invoke-Loop $liveArguments
    Wait-MockServer $server 5000
    Assert-True ($liveResult.ExitCode -eq 0) ("post-recovery live run failed:`n" + $liveResult.Text)
    $historyAfter = @(Read-JsonLines (Join-Path $workDir "run_history.jsonl"))
    $transcriptAfter = @(Read-JsonLines (Join-Path $workDir "transcript.jsonl"))
    Assert-True (($historyAfter | Select-Object -Last 1).seq -eq 13) "new run sequence did not advance beyond transcript/pending seq 12"
    Assert-True (($transcriptAfter | Select-Object -Last 1).seq -eq 13) "new transcript reused the recovered pending seq"
    Assert-True (@($transcriptAfter | Where-Object { [int]$_.seq -eq $pendingSeq }).Count -eq 1) "recovery duplicated the already-appended crash transcript record"
    $liveRequest = @(Read-JsonLines $requestLog)[0]
    Assert-True ([string]$liveRequest.messages[1].content -match [regex]::Escape($recoveredQuestion)) "post-recovery live run did not use the recovered continuation"
}

function ConvertTo-ProcessArgumentLine([string[]]$Arguments) {
    $parts = foreach ($argument in $Arguments) {
        if ($argument -match '[\s"]') {
            '"' + ($argument -replace '"', '\"') + '"'
        } else {
            $argument
        }
    }
    return ($parts -join ' ')
}

function Test-WorkDirLockRegression {
    Write-Host "[Lock] stable WorkDir ownership and project-retention guard sharing" -ForegroundColor Cyan
    $port = Get-FreeTcpPort
    $settingsPath = Join-Path $runtime "lock-settings.json"
    $requestLog = Join-Path $runtime "lock-requests.jsonl"
    $readyPath = Join-Path $runtime "lock-ready.txt"
    $workDir = Join-Path $runtime "work\shared-lock"
    $stdoutPath = Join-Path $runtime "lock-first.stdout.log"
    $stderrPath = Join-Path $runtime "lock-first.stderr.log"
    Write-TestSettings $settingsPath $port
    $server = Start-MockServer $port 1 $requestLog $readyPath "normal" 4000
    $arguments = @(Get-BaseLoopArguments $settingsPath $workDir) + @(
        "-SeedFile", (Join-Path $repo "seed_prompt.txt"),
        "-QuestionBankFile", (Join-Path $repo "question_bank.txt"), "-Once"
    )
    $first = Start-Process -FilePath $powerShellExe -ArgumentList (ConvertTo-ProcessArgumentLine $arguments) -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    # Windows PowerShell 5.1 can return a null ExitCode after redirected
    # Start-Process unless the native process handle is materialized up front.
    [void]$first.Handle
    $backgroundProcesses.Add($first) | Out-Null
    for ($i = 0; $i -lt 300; $i++) {
        if ((Test-Path -LiteralPath $requestLog -PathType Leaf) -and (Get-Item -LiteralPath $requestLog).Length -gt 0) { break }
        if ($first.HasExited) { break }
        Start-Sleep -Milliseconds 20
    }
    Assert-True ((Test-Path -LiteralPath $requestLog -PathType Leaf) -and (Get-Item -LiteralPath $requestLog).Length -gt 0) "first process did not reach the delayed request while holding the WorkDir lock"
    $second = Invoke-Loop $arguments
    Assert-True ($second.ExitCode -ne 0) "second process was allowed to use an already active stable WorkDir"
    Assert-True ($second.Text -match '(?i)lock|instance|active|잠금|사용\s*중|다른\s*프로세스|동일\s*WorkDir') "concurrent rejection did not explain the WorkDir lock conflict"
    [void]$first.WaitForExit(10000)
    Assert-True $first.HasExited "first lock-holder process did not finish"
    $first.Refresh()
    $firstStdout = ((Get-Content -LiteralPath $stdoutPath -ErrorAction SilentlyContinue) -join [Environment]::NewLine)
    $firstStderr = ((Get-Content -LiteralPath $stderrPath -ErrorAction SilentlyContinue) -join [Environment]::NewLine)
    Assert-True ($first.ExitCode -eq 0) ("first lock-holder process exit=$($first.ExitCode):`nSTDOUT:`n$firstStdout`nSTDERR:`n$firstStderr")
    Wait-MockServer $server 3000
    $requestCount = @(Get-Content -LiteralPath $requestLog -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
    Assert-True ($requestCount -eq 1) "lock loser sent an HTTP request instead of failing before transport"

    $parseTokens = $null
    $parseErrors = $null
    $scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$parseTokens, [ref]$parseErrors)
    Assert-True ($parseErrors.Count -eq 0) "production script could not be parsed for the exact retention-guard regression"
    $guardFunctionAst = @($scriptAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Open-ProjectSessionRetentionGuard"
    }, $true) | Select-Object -First 1)[0]
    $removeFunctionAst = @($scriptAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Remove-ValidatedProjectSession"
    }, $true) | Select-Object -First 1)[0]
    $safeTreeRemoveAst = @($scriptAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Remove-DirectoryTreeWithoutFollowingReparsePoints"
    }, $true) | Select-Object -First 1)[0]
    Assert-True ($null -ne $guardFunctionAst -and $null -ne $removeFunctionAst -and $null -ne $safeTreeRemoveAst) "retention guard/removal production functions were not found"
    Invoke-Expression ([string]$guardFunctionAst.Extent.Text)
    $removeFunctionText = [string]$removeFunctionAst.Extent.Text
    $guardCallIndex = $removeFunctionText.IndexOf("Open-ProjectSessionRetentionGuard", [System.StringComparison]::Ordinal)
    $refreshIndex = $removeFunctionText.IndexOf("Get-ValidatedProjectSessionDirectories", [System.StringComparison]::Ordinal)
    $deleteIndex = $removeFunctionText.IndexOf("Remove-DirectoryTreeWithoutFollowingReparsePoints", [System.StringComparison]::Ordinal)
    Assert-True ($guardCallIndex -ge 0 -and $refreshIndex -gt $guardCallIndex -and $deleteIndex -gt $refreshIndex) "session deletion did not hold the retention guard across fresh validation and removal"

    $safeTreeRemoveText = [string]$safeTreeRemoveAst.Extent.Text
    $rootExpandedPushIndex = $safeTreeRemoveText.IndexOf('$frames.Push([PSCustomObject]@{ Path = $item.FullName; Expanded = $true })', [System.StringComparison]::Ordinal)
    $deferredLockPushIndex = $safeTreeRemoveText.IndexOf('$frames.Push([PSCustomObject]@{ Path = $deferredLifetimeLock.FullName; Expanded = $false })', [System.StringComparison]::Ordinal)
    $ordinaryChildrenPushIndex = $safeTreeRemoveText.IndexOf('foreach ($child in @($children | Where-Object', [System.StringComparison]::Ordinal)
    $nonRecursiveRootDeleteIndex = $safeTreeRemoveText.IndexOf('[System.IO.Directory]::Delete($item.FullName, $false)', [System.StringComparison]::Ordinal)
    Assert-True ($safeTreeRemoveText.Contains('.active.lock')) "safe retention walker no longer recognizes the lifetime lock"
    # Stack order is intentional: root-expanded is pushed first, the lifetime
    # lock second, and ordinary children last. LIFO therefore removes every
    # other descendant, then .active.lock, then attempts only a non-recursive
    # root delete. A lock/state recreated in that final window blocks deletion.
    Assert-True ($rootExpandedPushIndex -ge 0 -and $deferredLockPushIndex -gt $rootExpandedPushIndex -and $ordinaryChildrenPushIndex -gt $deferredLockPushIndex -and $nonRecursiveRootDeleteIndex -gt $ordinaryChildrenPushIndex) "safe retention walker did not defer .active.lock until immediately before the root delete"
    Assert-True (-not ($safeTreeRemoveText -match '(?i)Remove-Item[^\r\n]*-Recurse|Directory\]::Delete\([^\r\n]*\$true')) "safe retention walker regained a recursive delete that could erase concurrently recreated owner state"

    $guardDir = Join-Path $runtime "retention-guard-semantics"
    $guardLockPath = Join-Path $guardDir ".active.lock"
    New-Item -ItemType Directory -Force -Path $guardDir | Out-Null
    $retentionGuard = $null
    $newLifetimeOwner = $null
    try {
        $retentionGuard = Open-ProjectSessionRetentionGuard ([PSCustomObject]@{ LockPath = $guardLockPath })
        Assert-True ($null -ne $retentionGuard) "production retention guard could not acquire an inactive session lock"
        $newOwnerBlocked = $false
        try {
            $newLifetimeOwner = [System.IO.File]::Open($guardLockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        } catch [System.IO.IOException] {
            $newOwnerBlocked = $true
        } catch [System.UnauthorizedAccessException] {
            $newOwnerBlocked = $true
        }
        Assert-True $newOwnerBlocked "a new FileShare.None lifetime owner acquired .active.lock while the retention guard was held"
    } finally {
        if ($newLifetimeOwner) { $newLifetimeOwner.Dispose() }
        if ($retentionGuard) { $retentionGuard.Dispose() }
    }
    $postGuardOwner = $null
    try {
        $postGuardOwner = [System.IO.File]::Open($guardLockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        Assert-True ($null -ne $postGuardOwner) "FileShare.None lifetime owner remained blocked after retention guard disposal"
    } finally {
        if ($postGuardOwner) { $postGuardOwner.Dispose() }
    }
}

try {
    if ($Scenario -in @("All", "Scanner")) { Test-ScannerRegressions }
    if ($Scenario -in @("All", "Quality")) { Test-QualityGateRegressions }
    if ($Scenario -in @("All", "Protocol")) { Test-ProtocolRegressions }
    if ($Scenario -in @("All", "Lock")) { Test-WorkDirLockRegression }
    if ($Scenario -in @("All", "Settings")) { Test-SettingsRegressions }
    if ($Scenario -in @("All", "Recovery")) { Test-RecoveryRegressions }
    Write-Host "PASS: high-priority regressions ($Scenario)" -ForegroundColor Green
    if ($KeepArtifacts) { Write-Host "Artifacts: $runtime" -ForegroundColor DarkGray }
} finally {
    foreach ($process in @($backgroundProcesses.ToArray())) {
        if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    }
    foreach ($server in @($servers.ToArray())) {
        if ($server -and -not $server.HasExited) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
    }
    if (-not $KeepArtifacts -and (Test-Path -LiteralPath $runtime -PathType Container)) {
        $expectedParent = [System.IO.Path]::GetFullPath((Join-Path $repo "qwen-loop-data"))
        $runtimeFull = [System.IO.Path]::GetFullPath($runtime)
        if ($runtimeFull.StartsWith($expectedParent + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -and
            ([System.IO.Path]::GetFileName($runtimeFull) -match '^_high-regression-')) {
            Remove-Item -LiteralPath $runtimeFull -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
