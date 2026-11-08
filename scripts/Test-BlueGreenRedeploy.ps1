[CmdletBinding()]
param(
  [string]$BaseUrl = 'http://localhost:8080',
  [int]$DurationSeconds = 180,
  [int]$PreSeconds = 30,
  [int]$PostSeconds = 30,
  [int]$IntervalMilliseconds = 500,
  [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\artifacts\redeploy-verification')
)

$ErrorActionPreference = 'Stop'
$started = Get-Date
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$stamp = $started.ToString('yyyyMMdd-HHmmss')
$rows = New-Object System.Collections.Generic.List[object]
$end = $started.AddSeconds($DurationSeconds)

function Invoke-Check([string]$Phase, [string]$Name, [string]$Path, [string]$Expected) {
  $at = Get-Date
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $status = $null; $body = ''; $ok = $false; $errorText = ''
  try {
    $response = Invoke-WebRequest -UseBasicParsing -Uri ($BaseUrl.TrimEnd('/') + $Path) -TimeoutSec 5
    $status = [int]$response.StatusCode
    $body = [string]$response.Content
    $ok = $status -ge 200 -and $status -lt 300 -and $body -match $Expected
  } catch { $errorText = $_.Exception.Message }
  $sw.Stop()
  $version = ''
  try {
    $versionResponse = Invoke-WebRequest -UseBasicParsing -Uri ($BaseUrl.TrimEnd('/') + '/version') -TimeoutSec 5
    $version = [string]$versionResponse.Content
  } catch { if (-not $errorText) { $errorText = "version request: $($_.Exception.Message)" } }
  $row = [PSCustomObject]@{
    timestamp = $at.ToString('o'); phase = $Phase; check = $Name; path = $Path
    success = $ok; status = $status; latency_ms = $sw.Elapsed.TotalMilliseconds
    observed_version = $version; response_excerpt = $body.Substring(0, [Math]::Min(160, $body.Length))
    error = $errorText
  }
  $rows.Add($row)
  $row
}

while ((Get-Date) -lt $end) {
  $elapsed = ((Get-Date) - $started).TotalSeconds
  $phase = if ($elapsed -lt $PreSeconds) { 'before' } elseif ($elapsed -ge ($DurationSeconds - $PostSeconds)) { 'after' } else { 'during' }
  Invoke-Check $phase 'health' '/health' '^ok' | Out-Null
  Invoke-Check $phase 'app-html' '/' '<div id="root">' | Out-Null
  Invoke-Check $phase 'version' '/version' '"version"\s*:\s*"[^"]+"' | Out-Null
  Start-Sleep -Milliseconds $IntervalMilliseconds
}

$csvPath = Join-Path $OutputDirectory "$stamp-results.csv"
$jsonPath = Join-Path $OutputDirectory "$stamp-results.json"
$summaryPath = Join-Path $OutputDirectory "$stamp-summary.json"
$rows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
$rows | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
$successful = @($rows | Where-Object { $_.success })
$versions = @($rows | ForEach-Object { $_.observed_version } | Where-Object { $_ } | Sort-Object -Unique)
$summary = [PSCustomObject]@{
  started = $started.ToString('o'); ended = (Get-Date).ToString('o'); base_url = $BaseUrl
  total_requests = $rows.Count; successful_requests = $successful.Count; failed_requests = $rows.Count - $successful.Count
  observed_versions = $versions; before_versions = @($rows | Where-Object phase -eq before | ForEach-Object observed_version | Sort-Object -Unique)
  during_versions = @($rows | Where-Object phase -eq during | ForEach-Object observed_version | Sort-Object -Unique)
  after_versions = @($rows | Where-Object phase -eq after | ForEach-Object observed_version | Sort-Object -Unique)
  verification_passed = ($rows.Count -gt 0 -and $rows.Count -eq $successful.Count)
  note = 'This result is a successful redeploy verification only when the during phase contains the intended transition and no requests failed.'
}
$summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
$summary | ConvertTo-Json -Depth 5
if (-not $summary.verification_passed) { exit 1 }
