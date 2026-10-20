# Cking-Infra

크킹 인프라 코드(Terraform).

## 범위

- Terraform은 새로 만드는 리소스(관측 서버 등)와 콘솔에서 가져온 리소스를 관리한다. 가져온 리소스: FE 배포 역할(`dev-cking-fe-github-actions-role`), 앱 서버 역할(`dev-cking-ec2-role`)
- 기존 리소스(VPC, 서브넷, 앱 보안 그룹, ALB, RDS)는 콘솔이 관리하며 Terraform은 `data` 소스로 읽기만 한다
- 업로드 버킷(`dev-cking-uploads-…`)은 콘솔이 관리하고, 버킷 정책(CDN 읽기 허용)만 Terraform이 관리한다
- ALB는 콘솔이 관리하고, API 앞단 WAF 연결만 Terraform이 관리한다

## 구조

```text
.github/workflows/         PR 검사(ci.yml), 관측 설정·앱 서버 수집기 배포 워크플로
.github/dependabot.yml     컨테이너 이미지·GitHub Actions 갱신 PR
app-agent/                 앱 서버 수집기(Alloy) 설정. cadvisor.alloy·compose.cadvisor.yaml은 부하 테스트 서버에서만 켜는 컨테이너 지표
bootstrap/                 Terraform보다 먼저 만든 상태 버킷 기록
docs/runbooks/             경보별 대응 절차(런북)
envs/dev/                  개발 환경. 실행 위치
  terraform.tf             Terraform·프로바이더 버전
  backend.tf               상태 저장소(S3)와 잠금
  providers.tf             리전, 계정 고정, 공통 태그
  existing.tf              콘솔이 관리하는 기존 리소스 읽기(data)
  api_waf.tf               API 앞단 WAF(modules/api-waf)를 기존 ALB에 세기만 상태로 연결
  admin_frontend.tf        관리자 앱 정적 호스팅(S3, CloudFront, WAF, 요금제, Route53)
  uploads_cdn.tf           업로드 이미지 공개 CDN(CloudFront, WAF, 요금제, Route53, 버킷 정책)
  app_server.tf            앱 서버 역할(콘솔에서 가져옴)과 수집기 설정 읽기 권한
  frontend_deploy.tf       FE 배포 역할(콘솔에서 가져옴)과 앱별 권한
  observability.tf         관측 서버(EC2, 데이터 디스크, 스냅샷, 버킷, IAM, 앱 서버 수집 포트)
  alerts.tf                서버 상태 검사 경보와 메일 주제
  observability_deploy.tf  관측 설정·앱 서버 수집기 설정을 배포하는 GitHub Actions 역할
  outputs.tf               읽어 온 값 출력
  templates/               서버 첫 부팅 스크립트
envs/loadtest/             부하 테스트 환경. 측정 때 띄우고 끝나면 지운다. 상태는 loadtest/terraform.tfstate
  app_server.tf            앱 서버(개발 앱 서버와 같은 AMI·크기·Docker 버전·swap)
  rds.tf                   RDS(개발 RDS와 같은 사양, 빈 DB)
  alb.tf                   기존 ALB에 loadtest-api.cking.co.kr 경로
  k6.tf                    k6 서버와 서버 지표 수집기
  parameters.tf            /cking/loadtest/ 중 비밀이 아닌 값
  templates/               서버 첫 부팅 스크립트
envs/loadtest-base/        부하 테스트 EC2 역할과 인스턴스 프로필. 테스트 환경보다 먼저 만들고 테스트 환경을 지워도 남긴다. 상태는 loadtest-base/terraform.tfstate
  iam.tf                   앱 서버(SSM, /cking/loadtest/, 배포 파일, 수집기 설정 읽기)·k6 서버(SSM, JWT 비밀값) 역할
envs/prod-base/            운영 환경 EC2 역할과 인스턴스 프로필. 운영 서버보다 먼저 만들고 운영 환경을 지워도 남긴다. 상태는 prod-base/terraform.tfstate
  iam.tf                   앱 서버·추천 배치 서버·감시용 서버 역할(SSM, 운영 비밀값·배포 파일·업로드 버킷, 수집기 설정 읽기, 댓글 필터 호출, 추천 배치 상태 디스크 붙이기)
modules/api-waf/           API(ALB) 앞단 WAF. 개발·운영이 같은 규칙을 쓴다(관리형 규칙, 본문 크기 예외, IP당 요청 상한, 로그)
observability/             관측 서버 위의 프로그램 설정(compose, Prometheus, Loki, Alloy, Grafana, 쓰기 전용 nginx)
```

Terraform이 관리하는 리소스에는 `ManagedBy = terraform` 태그가 붙는다. 이 태그가 없는 리소스는 콘솔에서 관리한다.

## 규칙

- 상태 파일은 S3 원격 백엔드에 둔다. 상태 파일, 변수 파일, 비밀값은 커밋하지 않는다
- 비밀값은 Parameter Store에 두고 코드에는 경로만 쓴다
- 변경은 PR에 `terraform plan` 결과를 붙여 리뷰한 뒤 적용한다
- 인프라(`envs/`)는 사람이 plan을 확인하고 apply한다. 관측 서버 위의 설정(`observability/`)과 앱 서버 수집기 설정(`app-agent/`)은 main에 머지되면 GitHub Actions가 배포한다. 같은 리소스를 두 주체가 관리하지 않는다
- 컨테이너 이미지는 `이름:버전@sha256:…`으로 고정한다. 태그는 배포처에서 다른 이미지로 옮길 수 있어, 버전은 사람이 읽는 표기로 남기고 실제로는 digest로 받는다. 갱신은 Dependabot PR로 받고, 직접 바꿀 때는 버전과 digest를 함께 바꾼다. digest는 `docker buildx imagetools inspect 이름:버전`의 `Digest` 값이다
- PR마다 `ci.yml`이 검사하고, main 룰셋의 필수 검사로 건다. 설정 검증은 compose에 고정된 이미지로 실행한다
  - `terraform`: `terraform fmt -check`, `envs/dev`의 `init -backend=false`·`validate`
  - `config`: compose 해석, Alloy `validate`, `promtool check config`, Loki `-verify-config`, `nginx -t`
  - `lint`: `shellcheck`(배포 스크립트, 서버 첫 부팅 스크립트), `actionlint`(워크플로)
- 협업 규칙은 조직 CONTRIBUTING을 따른다. 환경이 개발 서버 하나라 `develop` 없이 `main`으로 PR을 보낸다

## 부하 테스트 환경

순서

1. `envs/loadtest-base`에서 `terraform plan -out=tfplan` → `terraform apply tfplan`. 앱 서버·k6 서버 IAM 역할을 만든다. 처음 한 번만 하고, 테스트 환경을 지워도 남긴다(서버와 같은 apply로 만들면 역할이 전파되기 전에 부팅해 SSM 에이전트가 붙지 않는다)
2. Parameter Store `/cking/loadtest/`에 비밀값을 SecureString으로 넣는다: `DB_PASSWORD`, `JWT_SECRET`, `ADMIN_ACCOUNT_LOGIN_ID`, `ADMIN_ACCOUNT_PASSWORD`, `DOCS_USERNAME`, `DOCS_PASSWORD`. 나머지 값은 Terraform이 만든다
3. `envs/loadtest`에서 `terraform plan -out=tfplan` → `terraform apply tfplan`
4. 앱 배포: 개발 서버에 떠 있는 이미지 태그로 앱 서버에서 `aws s3 cp s3://dev-cking-deploy-551372961758/releases/<태그>/deploy.sh /opt/cking/deploy.sh` 뒤 `PARAM_PATH=/cking/loadtest/ bash /opt/cking/deploy.sh <태그>`(BE CI가 개발 서버에 배포하는 방식과 같다). 측정 내내 같은 태그를 쓴다
5. 앱 서버 수집기: 앱 서버에서 `aws s3 sync --exact-timestamps s3://<관측 버킷>/app-agent/ /opt/app-agent/` 뒤 `CKING_INSTANCE=loadtest-cking-app CKING_CADVISOR=1 bash /opt/app-agent/apply.sh`. 수집기는 앱 compose의 네트워크(`cking_default`)에 붙으므로 앱 배포 뒤에 적용한다
6. 측정이 끝나면 `envs/loadtest`에서 `terraform destroy`. `envs/loadtest-base`의 역할과 Parameter Store 비밀값은 다음 측정에 다시 쓰므로 남긴다. 그만 쓸 때 직접 지운다

- 앱 주소는 `https://loadtest-api.cking.co.kr`(기존 ALB, 443 규칙 우선순위 200)
- k6 결과 지표는 `k6 run -o experimental-prometheus-rw <스크립트>`로 관측 서버에 보낸다. 주소는 k6 서버의 `/etc/profile.d/k6.sh`
- k6는 Access Token을 실행 중에 직접 서명한다. 비밀값은 환경변수로만 넘긴다: `JWT_SECRET="$(aws ssm get-parameter --region ap-northeast-2 --name /cking/loadtest/JWT_SECRET --with-decryption --query Parameter.Value --output text)" k6 run -o experimental-prometheus-rw <스크립트>`
- 이름표: 앱 서버 `loadtest-cking-app`, k6 서버 `loadtest-cking-k6`

## 운영 환경

1. `envs/prod-base`에서 `terraform plan -out=tfplan` → `terraform apply tfplan`. 처음 한 번만 하고, 운영 환경을 지워도 남긴다
2. 비밀값은 Parameter Store에 SecureString으로 넣는다. 앱은 `/cking/prod/`, 추천 배치 서버는 `/cking/prod-recommendation/`, 감시용 서버는 `/cking/prod-monitor/`(Redis 감시 전용 사용자)이며 각 역할은 자기 경로만 읽는다

## 요구 사항

- Terraform 1.16 이상
