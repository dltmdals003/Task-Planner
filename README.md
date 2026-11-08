# 마감 플래너

대학교 오픈소스SW 과제를 위해 만든, 마감까지 남은 시간과 하위 목표를 한눈에 관리하는 반응형 웹앱입니다. 로그인과 서버 없이 할 일을 기록하고 매초 갱신되는 카운트다운으로 우선순위를 확인할 수 있습니다.

## 주요 기능
- 제목·설명·마감 날짜/시간으로 할 일 추가, 수정, 삭제, 완료/완료 취소
- 날짜만 입력하면 현지 시간 기준 23:59로 자동 설정
- 1초 단위 카운트다운, 24시간 이내/1시간 이내/마감 지남 상태 표시
- 하위 목표 추가·체크·이름 수정(항목 더블클릭)·삭제와 진행률 표시
- 전체/진행 중/완료/마감 지남 필터, 마감 임박 순 정렬
- 모바일 한 열 카드 레이아웃과 키보드 입력 지원

## 사용 기술
React, TypeScript, Vite, lucide-react, localStorage, GitHub Actions, GitHub Pages

## 로컬 실행
```bash
npm install
npm run dev
```
브라우저에서 안내된 주소(기본 `http://localhost:5173`)를 엽니다. 검사와 빌드는 `npm run typecheck`, `npm run build`입니다.

## 데이터 저장 방식과 제한 사항
할 일은 브라우저의 localStorage에 저장되어 새로고침하거나 같은 브라우저를 다시 열어도 유지됩니다. 데이터는 현재 브라우저에 저장되며 다른 기기와 동기화되지 않습니다. 브라우저 사이트 데이터 삭제 시 저장 내용도 삭제됩니다.

## GitHub Pages 설정
1. 프로젝트를 GitHub 저장소의 `main` 브랜치에 push합니다.
2. Settings → Pages → Build and deployment에서 Source를 **GitHub Actions**로 선택합니다.
3. 이후 `main`에 push할 때 `.github/workflows/deploy.yml`이 의존성 설치 → 타입 검사 → 빌드 → Pages 배포를 실행합니다.
4. Actions 완료 후 Pages 화면의 주소로 접속합니다. Vite의 `base: './'`로 저장소 하위 경로에서도 정적 파일이 로드됩니다.

## 과제 시연 순서
1. 제목과 날짜만 입력해 추가하고 기본 23:59 설정을 확인합니다.
2. 설명과 시간을 지정해 카운트다운과 마감 표시를 보여줍니다.
3. 하위 목표를 여러 개 추가하고 체크하여 진행률을 확인합니다.
4. 수정·완료 처리·완료 취소·삭제 확인 절차를 시연합니다.
5. 전체/진행 중/완료/마감 지남 필터와 새로고침 후 데이터 유지 상태를 확인합니다.
6. 브라우저 반응형 모드에서 모바일 한 열 배치를 캡처합니다.

## Supabase 로그인과 기기 간 동기화

1. Supabase 프로젝트를 만들고 Authentication → Providers에서 Email을 활성화합니다.
2. SQL Editor에서 `supabase/schema.sql` 전체를 실행합니다. `tasks`와 `subtasks` 테이블, 사용자별 RLS 정책이 생성됩니다.
3. 프로젝트 루트의 `.env.example`을 `.env.local`로 복사하고 Supabase Project URL과 Publishable key를 입력합니다. `service_role` 키는 사용하지 않습니다.
4. `npm.cmd install` 후 `npm.cmd run dev`로 실행합니다. 로그인하면 기존 localStorage 일정이 계정에 없을 때 한 번만 가져올지 묻습니다.
5. GitHub 저장소 Settings → Secrets and variables → Actions → New repository secret에서 다음 두 값을 등록합니다.
   - `VITE_SUPABASE_URL`
   - `VITE_SUPABASE_PUBLISHABLE_KEY`
6. `main` push 시 workflow가 두 값을 빌드 환경에 주입해 GitHub Pages에 배포합니다.

GitHub Pages 주소가 `https://사용자.github.io/Task-Planner/`라면 Supabase Authentication → URL Configuration에서 Site URL과 Redirect URLs에 해당 주소를 등록해야 합니다. 이메일 인증 링크는 이 경로로 돌아옵니다.

동기화는 로그인 후 저장 시 즉시 서버에 반영되며, 새로고침과 브라우저 탭 복귀 시 서버 데이터를 다시 불러옵니다. 저장 중과 저장 실패 상태가 화면에 표시됩니다. 서버 설정이 없으면 기존 localStorage 모드로 계속 사용할 수 있습니다.

## Docker 실행

이 프로젝트의 실제 실행 구조는 FastAPI가 없는 React + Vite 정적 프론트엔드입니다. Docker는 Node.js 22로 Vite를 빌드한 뒤 Nginx로 정적 파일을 제공합니다.

```powershell
docker build -t task-planner .
docker run --rm -p 8080:80 --env-file .env.local task-planner
```

브라우저 접속 주소:

```text
http://localhost:8080/
```

컨테이너 상태 확인 주소:

```text
http://localhost:8080/health
```

Supabase 값은 이미지에 하드코딩하지 않습니다. 컨테이너 시작 시 `VITE_SUPABASE_URL`과 `VITE_SUPABASE_PUBLISHABLE_KEY`를 환경변수로 전달하면 Nginx entrypoint가 런타임 설정 파일을 생성합니다. `service_role` 키는 사용하지 않습니다.

## Docker Hub와 GitHub Actions CI

1. Docker Hub에서 소문자 이름의 저장소 `task-planner`를 준비합니다.
2. GitHub 저장소의 `Settings → Secrets and variables → Actions`에서 다음 Repository secrets를 등록합니다.
   - `DOCKERHUB_USERNAME`: Docker Hub 사용자명
   - `DOCKERHUB_TOKEN`: Docker Hub Access Token
3. `main` 브랜치에 push하거나 Actions에서 `Docker CI`를 수동 실행합니다.
4. workflow가 `npm ci`가 포함된 Docker 빌드, 컨테이너 `/health` 응답 확인을 통과한 뒤에만 Docker Hub에 push합니다.
5. 업로드 태그는 `latest`와 커밋 SHA입니다.

GitHub Actions의 `Actions → Docker CI`에서 검증 결과, 이미지 이름, 태그, 커밋을 Summary로 확인할 수 있습니다.

## Windows self-hosted runner 자동 배포(CD)

`.github/workflows/docker-cd.yml`은 `Docker CI` workflow가 성공한 뒤 같은 커밋 SHA 태그의 이미지를 Windows self-hosted runner에서 자동으로 배포합니다. runner에는 Docker Desktop과 `self-hosted`, `windows` 라벨이 필요합니다.

1. 저장소 `Settings → Actions → Runners → New self-hosted runner`에서 Windows runner를 등록합니다.
2. runner 머신에 Docker Desktop을 설치하고 Docker 엔진이 실행 중인지 확인합니다.
3. runner가 `self-hosted`와 `windows` 라벨로 온라인 상태인지 확인합니다.
4. Repository secrets에 이미 등록한 `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`, `VITE_SUPABASE_URL`, `VITE_SUPABASE_PUBLISHABLE_KEY`를 사용합니다.
5. `Docker CI`가 성공하면 `Docker CD`가 자동 실행되고, 검증된 SHA 이미지로 `task-planner` 컨테이너를 교체합니다.

runner의 서비스 포트는 `8080`이며 상태 확인 주소는 `http://localhost:8080/health`입니다. 배포 실패 시 candidate 또는 production 컨테이너 로그가 Actions 로그에 출력됩니다. self-hosted runner는 개인 컴퓨터나 사설 네트워크에서 실행되므로 외부 공개가 필요하면 방화벽·리버스 프록시·TLS를 별도로 구성해야 합니다.
