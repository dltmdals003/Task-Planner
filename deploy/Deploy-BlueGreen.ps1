[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Image,
  [Parameter(Mandatory = $true)][string]$ImageTag,
  [Parameter(Mandatory = $true)][string]$SupabaseUrl,
  [Parameter(Mandatory = $true)][string]$SupabasePublishableKey,
  [string]$Network = 'task-planner-network',
  [string]$ProxyContainer = 'task-planner-proxy',
  [string]$BlueContainer = 'task-planner-blue',
  [string]$GreenContainer = 'task-planner-green',
  [string]$StateDirectory = (Join-Path $PSScriptRoot 'state'),
  [int]$DrainSeconds = 5
)

$ErrorActionPreference = 'Stop'
$stateFile = Join-Path $StateDirectory 'active-slot.txt'
$proxyConfig = Join-Path $StateDirectory 'nginx.conf'
$candidate = $null
$previousSlot = $null
$proxyCreated = $false
$switched = $false

function Invoke-Docker([string[]]$Arguments, [switch]$AllowFailure) {
  $output = & docker @Arguments 2>&1
  $code = $LASTEXITCODE
  if ($code -ne 0 -and -not $AllowFailure) {
    throw "docker $($Arguments -join ' ') failed with exit code $code`n$($output -join [Environment]::NewLine)"
  }
  [PSCustomObject]@{ Code = $code; Output = ($output -join [Environment]::NewLine) }
}

function Test-Container([string]$Name) {
  $result = Invoke-Docker @('inspect', '-f', '{{.State.Running}}', $Name) -AllowFailure
  return $result.Code -eq 0 -and $result.Output.Trim() -eq 'true'
}

function Remove-Container([string]$Name) {
  if (Test-Container $Name) { Invoke-Docker @('rm', '-f', $Name) | Out-Null }
  else { Invoke-Docker @('rm', $Name) -AllowFailure | Out-Null }
}

function Write-ProxyConfig([string]$Backend) {
  @"
server {
  listen 80;
  server_name _;
  location / {
    proxy_pass http://${Backend}:80;
    proxy_http_version 1.1;
    proxy_set_header Host `$host;
    proxy_set_header X-Forwarded-For `$proxy_add_x_forwarded_for;
    proxy_set_header Connection "";
    proxy_buffering off;
  }
}
"@ | Set-Content -LiteralPath $proxyConfig -Encoding ascii
}

function Assert-App([string]$Name, [string]$ExpectedVersion) {
  for ($i = 1; $i -le 30; $i++) {
    $health = Invoke-Docker @('exec', $Name, 'wget', '-qO-', 'http://127.0.0.1/health') -AllowFailure
    if ($health.Code -eq 0 -and $health.Output.Trim() -eq 'ok') {
      $version = Invoke-Docker @('exec', $Name, 'wget', '-qO-', 'http://127.0.0.1/version') -AllowFailure
      if ($version.Code -eq 0 -and $version.Output -match [regex]::Escape($ExpectedVersion)) { return }
    }
    Start-Sleep -Seconds 1
  }
  throw "Candidate $Name did not pass health/version validation."
}

New-Item -ItemType Directory -Path $StateDirectory -Force | Out-Null
$networkInspect = Invoke-Docker @('network', 'inspect', $Network) -AllowFailure
if ($networkInspect.Code -ne 0) { Invoke-Docker @('network', 'create', $Network) | Out-Null }

if (Test-Path -LiteralPath $stateFile) { $previousSlot = (Get-Content -LiteralPath $stateFile -Raw).Trim() }
if ($previousSlot -ne 'blue' -and $previousSlot -ne 'green') {
  if (Test-Container $BlueContainer) { $previousSlot = 'blue' }
  elseif (Test-Container $GreenContainer) { $previousSlot = 'green' }
}
$candidateSlot = if ($previousSlot -eq 'blue') { 'green' } else { 'blue' }
$candidate = if ($candidateSlot -eq 'blue') { $BlueContainer } else { $GreenContainer }
$old = if ($previousSlot -eq 'blue') { $BlueContainer } elseif ($previousSlot -eq 'green') { $GreenContainer } else { $null }

try {
  Remove-Container $candidate
  Invoke-Docker @('run', '-d', '--restart', 'unless-stopped', '--name', $candidate, '--network', $Network,
    '-e', "VITE_SUPABASE_URL=$SupabaseUrl", '-e', "VITE_SUPABASE_PUBLISHABLE_KEY=$SupabasePublishableKey", "$Image`:$ImageTag") | Out-Null
  Assert-App $candidate $ImageTag

  Write-ProxyConfig $candidate
  Invoke-Docker @('run', '--rm', '--mount', "type=bind,source=$proxyConfig,target=/etc/nginx/conf.d/default.conf,readonly", 'nginx:1.27-alpine', 'nginx', '-t') | Out-Null
  if (-not (Test-Container $ProxyContainer)) {
    Invoke-Docker @('run', '-d', '--restart', 'unless-stopped', '--name', $ProxyContainer, '--network', $Network, '-p', '8080:80',
      '--mount', "type=bind,source=$proxyConfig,target=/etc/nginx/conf.d/default.conf,readonly", 'nginx:1.27-alpine') | Out-Null
    $proxyCreated = $true
    Start-Sleep -Seconds 2
  } else {
    Invoke-Docker @('exec', $ProxyContainer, 'nginx', '-t') | Out-Null
    Invoke-Docker @('exec', $ProxyContainer, 'nginx', '-s', 'reload') | Out-Null
  }
  $switched = $true
  Set-Content -LiteralPath $stateFile -Value $candidateSlot -Encoding ascii

  $publicVersion = Invoke-Docker @('exec', $ProxyContainer, 'wget', '-qO-', 'http://127.0.0.1/version')
  if ($publicVersion.Output -notmatch [regex]::Escape($ImageTag)) { throw 'Proxy validation returned an unexpected version.' }
  Start-Sleep -Seconds $DrainSeconds
  if ($old) { Remove-Container $old }
  Write-Output "Blue-green deployment switched to $candidateSlot ($ImageTag)."
} catch {
  if ($switched -and $previousSlot) {
    $restore = if ($previousSlot -eq 'blue') { $BlueContainer } else { $GreenContainer }
    Write-ProxyConfig $restore
    Invoke-Docker @('exec', $ProxyContainer, 'nginx', '-t') -AllowFailure | Out-Null
    Invoke-Docker @('exec', $ProxyContainer, 'nginx', '-s', 'reload') -AllowFailure | Out-Null
    Set-Content -LiteralPath $stateFile -Value $previousSlot -Encoding ascii
  }
  if ($candidate -and (Test-Container $candidate)) { Remove-Container $candidate }
  if ($proxyCreated) { Remove-Container $ProxyContainer }
  throw
}
