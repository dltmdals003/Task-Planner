# Runs the real deployment script with an in-memory Docker substitute. No daemon or Supabase calls.
$ErrorActionPreference='Stop'
$deployScript=Join-Path $PSScriptRoot '..\deploy\Deploy-BlueGreen.ps1'
$testDirectory=Join-Path ([System.IO.Path]::GetTempPath()) ('task-planner-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDirectory | Out-Null
function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function global:docker {
  $a=@($args);$global:LASTEXITCODE=0
  $op=$a[0]
  if ($op -eq 'container') { if ($a -contains '--filter') { $pattern=$a[[array]::IndexOf($a,'--filter')+1] -replace '^name=\^','' -replace '\$$',''; if($global:sim.ContainsKey($pattern)){return $pattern} };return }
  if ($op -eq 'inspect') {
    $name=$a[1];$c=$global:sim[$name]
    if(-not $c){$global:LASTEXITCODE=1;return 'missing'}
    return (ConvertTo-Json -Depth 8 -InputObject @(@{State=@{Running=$true};Config=@{Labels=@{'task-planner.proxy-config'=$c.label}};NetworkSettings=@{Networks=@{'task-planner-network'=@{}}}}))
  }
  if($op -eq 'network'){return 'task-planner-network'}
  if($op -eq 'image' -or $op -eq 'pull'){return 'ok'}
  if($op -eq 'rm'){ $name=$a[-1];$global:sim.Remove($name);return }
  if($op -eq 'run') {
    $name=$a[[array]::IndexOf($a,'--name')+1]
    if($name -eq 'task-planner-proxy') {$global:sim[$name]=@{version='';label='v2'};return 'proxy-id'}
    $global:sim[$name]=@{version='new';label=''};return 'app-id'
  }
  if($op -eq 'cp') {
    $name=($a[2] -split ':')[0];$content=Get-Content -LiteralPath $a[1] -Raw
    if($content -match 'proxy_pass http://([^:]+):80'){$global:sim[$name].target=$Matches[1]}
    return
  }
  if($op -eq 'logs'){return 'simulated logs'}
  if($op -eq 'exec') {
    $name=$a[1];$c=$global:sim[$name]
    if(-not $c){$global:LASTEXITCODE=1;return 'missing'}
    if($a -contains 'wget') {
      if($name -eq 'task-planner-green' -and $global:failCandidate){$global:LASTEXITCODE=1;return 'unhealthy'}
      if($a[-1] -match '/health$'){return 'ok'}
      $v=$c.version
      if($c.target){$v=$global:sim[$c.target].version}
      return ('{"version":"'+$v+'"}')
    }
    if($a -contains 'nginx') {
      if(($a -contains 'reload') -and $global:failReload){$global:failReload=$false;$global:LASTEXITCODE=1;return 'reload failed'}
      return 'ok'
    }
    if($a -contains 'cat'){$global:LASTEXITCODE=1;return 'file missing'}
  }
  throw "Unhandled mock command: $($a -join ' ')"
}
try {
  foreach($scenario in @('initial','missing-legacy-config','normal-redeploy','candidate-failure','reload-failure','ambiguous-slots')) {
    $global:sim=@{};$global:failCandidate=$scenario -eq 'candidate-failure';$global:failReload=$scenario -eq 'reload-failure'
    if($scenario -ne 'initial') {
      $global:sim['task-planner-blue']=@{version='old';label=''}
      $global:sim['task-planner-proxy']=@{version='old';label=$(if($scenario -eq 'missing-legacy-config') {''} else {'v2'})}
    }
    if($scenario -eq 'ambiguous-slots'){$global:sim['task-planner-green']=@{version='old';label=''}}
    $failed=$false
    try { & $deployScript -Image 'example/task-planner' -ImageTag new -SupabaseUrl 'https://example.invalid' -SupabasePublishableKey 'test' -StateDirectory $testDirectory -DrainSeconds 0 -HealthAttempts 1 } catch {$failed=$true}
    if($scenario -in @('candidate-failure','reload-failure','ambiguous-slots')) {
      Assert $failed "$scenario should fail"
      Assert ($global:sim.ContainsKey('task-planner-blue')) "$scenario removed old backend"
      if($scenario -ne 'ambiguous-slots'){Assert (-not $global:sim.ContainsKey('task-planner-green')) "$scenario retained failed candidate"}
      Assert ($global:sim['task-planner-proxy'].version -eq 'old') "$scenario lost original service"
    } else {
      Assert (-not $failed) "$scenario should succeed"
      $target=$global:sim['task-planner-proxy'].target
      Assert ($global:sim[$target].version -eq 'new') "$scenario did not serve new version"
    }
    Write-Output "PASS: $scenario"
  }
} finally {
  Remove-Item Function:\docker
  # Only this test's uniquely named temporary directory is removed.
  Remove-Item -LiteralPath $testDirectory -Recurse -Force
}
