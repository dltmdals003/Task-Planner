# Blue-green 배포 제출 절차

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
