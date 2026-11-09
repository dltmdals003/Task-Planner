[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Image,
  [Parameter(Mandatory=$true)][string]$ImageTag,
  [Parameter(Mandatory=$true)][string]$SupabaseUrl,
  [Parameter(Mandatory=$true)][string]$SupabasePublishableKey,
  [string]$Network='task-planner-network',
  [string]$ProxyContainer='task-planner-proxy',
  [string]$BlueContainer='task-planner-blue',
  [string]$GreenContainer='task-planner-green',
  [string]$StateDirectory=(Join-Path $env:ProgramData 'TaskPlanner\deployment-state'),
  [int]$DrainSeconds=5,
  [int]$HealthAttempts=30
)
$ErrorActionPreference='Stop'
$proxyImage='nginx:1.27-alpine'
$configInContainer='/tmp/task-planner-nginx.conf'
$candidate=$null
$previous=$null
$switchAttempted=$false
$proxyReplaced=$false
$configFile=$null

function Invoke-Docker([string[]]$Arguments, [switch]$AllowFailure) {
  $savedPreference=$ErrorActionPreference
  try {
    $ErrorActionPreference='Continue'
    $output=& docker @Arguments 2>&1
    $code=$LASTEXITCODE
  } finally { $ErrorActionPreference=$savedPreference }
  if ($code -ne 0 -and -not $AllowFailure) {
    # Do not echo arguments: docker run contains public connection settings.
    throw "Docker operation '$($Arguments[0])' failed ($code): $($output -join [Environment]::NewLine)"
  }
  [PSCustomObject]@{Code=$code;Output=($output -join [Environment]::NewLine)}
}
function Get-Container([string]$Name) {
  $result=Invoke-Docker @('container','ls','-a','--filter',"name=^$Name`$",'--format','{{.Names}}')
  if (($result.Output -split "`r?`n") -notcontains $Name) { return $null }
  $info=Invoke-Docker @('inspect',$Name)
  return @($info.Output | ConvertFrom-Json)[0]
}
function Remove-Container([string]$Name) {
  if (Get-Container $Name) { Invoke-Docker @('rm','-f',$Name) | Out-Null }
}
function Get-Version([string]$Name) {
  $result=Invoke-Docker @('exec',$Name,'wget','-qO-','http://127.0.0.1/version') -AllowFailure
  if ($result.Code -ne 0) { return $null }
  try { return ($result.Output | ConvertFrom-Json).version } catch { return $null }
}
function Assert-App([string]$Name,[string]$Version) {
  for ($i=0;$i -lt $HealthAttempts;$i++) {
    $health=Invoke-Docker @('exec',$Name,'wget','-qO-','http://127.0.0.1/health') -AllowFailure
    if ($health.Code -eq 0 -and $health.Output.Trim() -eq 'ok' -and (Get-Version $Name) -ceq $Version) { return }
    Start-Sleep -Seconds 1
  }
  throw "Health/version validation failed for $Name (expected $Version)."
}
function Write-Config([string]$Backend) {
  $text=@"
pid /var/run/nginx.pid;
events { worker_connections 1024; }
http {
  server {
    listen 80;
    location / {
      proxy_pass http://${Backend}:80;
      proxy_http_version 1.1;
      proxy_set_header Host `$host;
      proxy_set_header X-Forwarded-For `$proxy_add_x_forwarded_for;
      proxy_set_header Connection "";
      proxy_buffering off;
    }
  }
}
"@
  [System.IO.File]::WriteAllText($configFile,$text,[System.Text.Encoding]::ASCII)
}
function Connect-Network([string]$Name) {
  $info=Get-Container $Name
  if (-not $info -or -not $info.State.Running) { throw "Container $Name is not running." }
  if ($info.NetworkSettings.Networks.PSObject.Properties.Name -notcontains $Network) {
    Invoke-Docker @('network','connect',$Network,$Name) | Out-Null
  }
}
function Install-Config([string]$Name) {
  Invoke-Docker @('cp',$configFile,"${Name}:$configInContainer") | Out-Null
  Invoke-Docker @('exec',$Name,'nginx','-t','-c',$configInContainer) | Out-Null
}
function Start-Proxy {
  # Config lives in the container writable layer; restart retains it.
  Invoke-Docker @('run','-d','--restart','unless-stopped','--name',$ProxyContainer,
    '--label','task-planner.proxy-config=v2','--network',$Network,'-p','8080:80',
    $proxyImage,'sh','-c',"while [ ! -s $configInContainer ]; do sleep 1; done; exec nginx -c $configInContainer -g 'daemon off;'") | Out-Null
  Install-Config $ProxyContainer
}

New-Item -ItemType Directory -Path $StateDirectory -Force | Out-Null
$configFile=Join-Path $StateDirectory 'proxy-next.conf'
$proxy=Get-Container $ProxyContainer
$blue=Get-Container $BlueContainer
$green=Get-Container $GreenContainer
# Determine the active backend from the serving proxy, never from a stale state file.
if ($proxy -and $proxy.State.Running) {
  $servingVersion=Get-Version $ProxyContainer
  if (-not $servingVersion) { throw 'Cannot determine serving proxy version; no containers changed.' }
  $matches=@()
  foreach ($slot in @($BlueContainer,$GreenContainer)) {
    $info=Get-Container $slot
    if ($info -and $info.State.Running -and (Get-Version $slot) -ceq $servingVersion) { $matches+=,$slot }
  }
  if ($matches.Count -eq 1) { $previous=$matches[0] }
  elseif ($matches.Count -eq 2) {
    $path=if ($proxy.Config.Labels.'task-planner.proxy-config' -eq 'v2') { $configInContainer } else { '/etc/nginx/conf.d/default.conf' }
    $config=Invoke-Docker @('exec',$ProxyContainer,'cat',$path) -AllowFailure
    $activeMatches=@($matches | Where-Object { $config.Output -match ('proxy_pass\s+http://' + [regex]::Escape($_) + ':80') })
    if ($config.Code -eq 0 -and $activeMatches.Count -eq 1) { $previous=$activeMatches[0] }
    else { throw 'Both slots report the same version and active upstream cannot be identified; no containers changed.' }
  } else { throw 'No running slot matches the serving proxy version; no containers changed.' }
} elseif (($blue -and $blue.State.Running) -or ($green -and $green.State.Running)) {
  throw 'Proxy is not running but app slots exist; refusing to guess the active slot.'
}
$candidate=if ($previous -eq $BlueContainer) { $GreenContainer } else { $BlueContainer }
$networkList=Invoke-Docker @('network','ls','--format','{{.Name}}')
if (($networkList.Output -split "`r?`n") -notcontains $Network) { Invoke-Docker @('network','create',$Network) | Out-Null }
if ($previous) { Connect-Network $previous }
Invoke-Docker @('image','inspect',$proxyImage) -AllowFailure | ForEach-Object {
  if ($_.Code -ne 0) { Invoke-Docker @('pull',$proxyImage) | Out-Null }
}
$validator="${ProxyContainer}-validator"
try {
  Remove-Container $candidate
  Invoke-Docker @('run','-d','--restart','unless-stopped','--name',$candidate,'--network',$Network,
    '-e',"VITE_SUPABASE_URL=$SupabaseUrl",'-e',"VITE_SUPABASE_PUBLISHABLE_KEY=$SupabasePublishableKey","${Image}:$ImageTag") | Out-Null
  Assert-App $candidate $ImageTag
  Write-Config $candidate
  Remove-Container $validator
  Invoke-Docker @('run','-d','--name',$validator,'--network',$Network,$proxyImage,'sleep','300') | Out-Null
  Install-Config $validator
  Remove-Container $validator
  $switchAttempted=$true
  if ($proxy -and $proxy.State.Running -and $proxy.Config.Labels.'task-planner.proxy-config' -eq 'v2') {
    Connect-Network $ProxyContainer
    Install-Config $ProxyContainer
    Invoke-Docker @('exec',$ProxyContainer,'nginx','-c',$configInContainer,'-s','reload') | Out-Null
  } else {
    Write-Warning 'One-time legacy proxy migration: a brief interruption on port 8080 is possible.'
    $proxyReplaced=$true
    Remove-Container $ProxyContainer
    Start-Proxy
  }
  Assert-App $ProxyContainer $ImageTag
  Set-Content -LiteralPath (Join-Path $StateDirectory 'active-slot.txt') -Value $candidate -Encoding ASCII
  Start-Sleep -Seconds $DrainSeconds
  # Retain the previous slot for rollback; next deployment reuses the inactive slot.
  Write-Output "Blue-green deployment verified: $candidate ($ImageTag)."
} catch {
  $deploymentError=$_
  foreach ($name in @($candidate,$ProxyContainer)) {
    if ($name) { $logs=Invoke-Docker @('logs','--tail','60',$name) -AllowFailure; Write-Warning $logs.Output }
  }
  $rollbackOk=-not $switchAttempted
  if ($switchAttempted -and $previous) {
    try {
      Write-Config $previous
      if ($proxyReplaced) { Remove-Container $ProxyContainer; Start-Proxy }
      else { Install-Config $ProxyContainer; Invoke-Docker @('exec',$ProxyContainer,'nginx','-c',$configInContainer,'-s','reload') | Out-Null }
      Assert-App $ProxyContainer (Get-Version $previous)
      $rollbackOk=$true
      Write-Warning "Rolled back to $previous."
    } catch { Write-Warning "Rollback failed: $_. Candidate retained for recovery." }
  }
  if ($rollbackOk -and $candidate) { Remove-Container $candidate }
  throw $deploymentError
} finally {
  try { Remove-Container $validator } catch { Write-Warning "Validator cleanup failed: $_" }
}
