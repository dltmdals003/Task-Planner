# Blue-green 배포 제출 절차

## 설정 유실 복구와 현재 동작

프록시 설정은 Windows checkout 폴더에 bind mount하지 않습니다. `docker cp`로 프록시 컨테이너의 `/tmp/task-planner-nginx.conf`에 복사하며, Nginx는 해당 설정으로 실행됩니다. 컨테이너 재시작 시 설정은 유지됩니다. 호스트의 보조 파일은 `C:\ProgramData\TaskPlanner\deployment-state`에 기록합니다.

활성 슬롯은 state 파일을 추측해서 선택하지 않고, 현재 프록시 `/version`과 실행 중인 슬롯의 `/version`을 비교합니다. 모호하면 배포를 중단합니다. 후보 슬롯은 호스트 포트를 점유하지 않으며 검증된 뒤 Nginx reload로 전환합니다. 이전 슬롯은 다음 배포 전까지 롤백용으로 유지합니다.

이전 bind mount 방식의 프록시는 후보 앱과 Nginx 설정 검증 후 한 번 교체됩니다. 삭제된 설정 파일을 읽으려고 시도하지 않습니다. 이 최초 마이그레이션에는 짧은 접속 중단이 발생할 수 있으므로 무중단 검증 결과로 제출하지 마세요. 이후 정상 재배포를 별도로 검증해야 합니다.

배포 로직의 모의 테스트는 실제 Docker와 Supabase를 호출하지 않습니다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-DeploymentLogic.ps1
```

이 테스트는 최초 배포, 삭제된 legacy 설정 복구, 일반 전환, 후보 실패, reload 실패 롤백, 활성 슬롯 모호성을 검증합니다. 실제 Docker 네트워크·Nginx·Docker Hub 동작까지 검증하는 테스트는 아닙니다.

CD는 Docker 내부 네트워크에 `task-planner-blue`, `task-planner-green`, `task-planner-proxy`를 구성합니다. 호스트의 `8080`은 Nginx proxy가 계속 담당하고, 새 슬롯은 `/health`와 `/version` 검증 후 Nginx 설정 검사 및 graceful reload로 전환됩니다. 기존 슬롯은 drain 시간 후 정리됩니다. 실패하면 후보를 제거하고, 전환 후 실패하면 이전 슬롯으로 설정을 되돌립니다.

## 실행 순서

최초 배포 준비:

```powershell
docker version
New-Item -ItemType Directory -Force .\artifacts\redeploy-verification
```

별도 PowerShell 5.1 창에서 검증을 먼저 시작합니다.

```powershell
.\scripts\Test-BlueGreenRedeploy.ps1 -DurationSeconds 180
```

검증 중 안전한 변경을 commit/push하여 Docker CI와 Docker CD를 실행합니다. 검증 스크립트는 `http://localhost:8080`에서 `/health`, 앱 HTML, `/version`을 읽고 각 요청의 시각·상태·지연시간·별도 버전 응답을 CSV와 JSON으로 저장합니다. Supabase 데이터에는 쓰기·삭제를 수행하지 않습니다.

```powershell
Get-Content .\artifacts\redeploy-verification\*-summary.json
Get-Content .\artifacts\redeploy-verification\*-results.csv | Select-Object -First 12
Invoke-WebRequest http://localhost:8080/version -UseBasicParsing
```

`verification_passed`가 false이거나 실패 수가 0이 아니면 성공으로 제출하지 않습니다. during 단계에서 `http://localhost:8080` 응답 화면과 터미널을 함께 캡처하고, 종료 후 `*-summary.json` 집계 화면을 캡처합니다. 실제 GitHub Actions 재배포 성공 여부는 CI/CD 실행 결과와 during 단계의 버전 전환을 직접 확인해야 합니다.
