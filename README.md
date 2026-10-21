# Cking-Infra

크킹 인프라 코드(Terraform).

## 범위

- Terraform은 새로 만드는 리소스(관측 서버 등)와 콘솔에서 가져온 리소스를 관리한다. 가져온 리소스: FE 배포 역할(`dev-cking-fe-github-actions-role`), 앱 서버 역할(`dev-cking-ec2-role`)
- 기존 리소스(VPC, 서브넷, 앱 보안 그룹, ALB, RDS)는 콘솔이 관리하며 Terraform은 `data` 소스로 읽기만 한다
- 업로드 버킷(`dev-cking-uploads-…`)은 콘솔이 관리하고, 버킷 정책(CDN 읽기 허용)만 Terraform이 관리한다
- ALB는 콘솔이 관리하고, API 앞단 WAF 연결만 Terraform이 관리한다

## 구조

```text
.github/workflows/         PR 검사(ci.yml), 관측 설정·수집기 배포 워크플로(앱 서버는 바로 적용, 추천 배치 서버는 교체)
.github/dependabot.yml     컨테이너 이미지·GitHub Actions 갱신 PR
app-agent/                 서버 수집기(Alloy) 설정. agent.alloy(서버 지표·로그·전송)는 항상, app.alloy(앱 지표)·redis.alloy(Redis 지표)·cadvisor.alloy(컨테이너 지표, 부하 테스트 서버)·journal.alloy(systemd 서비스 journald 로그, 추천 배치 서버)는 apply.sh가 서버 역할에 따라 켠다
bootstrap/                 Terraform보다 먼저 만든 상태 버킷 기록
docs/runbooks/             경보별 대응 절차와 댓글 필터 차단·해제, 추천 배치 서버 절차(런북)
envs/dev/                  개발 환경. 실행 위치
  terraform.tf             Terraform·프로바이더 버전
  backend.tf               상태 저장소(S3)와 잠금
  providers.tf             리전, 계정 고정, 공통 태그
  existing.tf              콘솔이 관리하는 기존 리소스 읽기(data)
  api_waf.tf               API 앞단 WAF(modules/api-waf)를 기존 ALB에 세기만 상태로 연결
  admin_frontend.tf        관리자 앱 정적 호스팅(S3, CloudFront, WAF, 요금제, Route53)
  uploads_cdn.tf           업로드 이미지 공개 CDN(CloudFront, WAF, 요금제, Route53, 버킷 정책)
  app_server.tf            앱 서버 역할(콘솔에서 가져옴)과 수집기 설정 읽기·댓글 필터 호출 권한
  frontend_deploy.tf       FE 배포 역할(콘솔에서 가져옴)과 앱별 권한
  observability.tf         관측 서버(EC2, 데이터 디스크, 스냅샷, 버킷, IAM, 앱·추천 배치 서버 수집 포트)
  alerts.tf                서버 상태 검사 경보와 메일 주제
  observability_deploy.tf  관측 설정·수집기 설정을 배포하는 GitHub Actions 역할(앱 서버 적용, 추천 배치 서버 교체)
  comment_filter.tf        댓글 필터 이미지 저장소(ECR, 개발·운영 공용), 개발 Lambda(arm64 이미지, 함수 URL IAM 인증, 예약 동시성 2, 이미지는 필터 저장소 CI가 바꿈), 필터 저장소 GitHub Actions 개발 역할(모델 읽기, 이미지 푸시, 개발 Lambda 갱신·호출)
  recommendation.tf        개발 추천 배치 서버(1대짜리 서버 그룹, t4g.small 스팟, 상태 디스크, 시작 대기 자기 검사, 역할, 비밀이 아닌 값)와 추천 배치 저장소 GitHub Actions 개발 역할(배포 패키지 올리기, 배포 버전 값, 서버 교체)
  outputs.tf               읽어 온 값 출력
  templates/               서버 첫 부팅 스크립트(추천 배치 서버는 운영 공통 준비 envs/prod/templates/server-base.sh를 함께 쓴다)
envs/loadtest/             부하 테스트 환경. 측정 때 띄우고 끝나면 지운다. 상태는 loadtest/terraform.tfstate
  app_server.tf            앱 서버(개발 앱 서버와 같은 AMI·크기·Docker 버전·swap)
  rds.tf                   RDS(개발 RDS와 같은 사양, 빈 DB)
  alb.tf                   기존 ALB에 loadtest-api.cking.co.kr 경로
  k6.tf                    k6 서버와 서버 지표 수집기
  parameters.tf            /cking/loadtest/ 중 비밀이 아닌 값
  templates/               서버 첫 부팅 스크립트
envs/loadtest-base/        부하 테스트 EC2 역할과 인스턴스 프로필. 테스트 환경보다 먼저 만들고 테스트 환경을 지워도 남긴다. 상태는 loadtest-base/terraform.tfstate
  iam.tf                   앱 서버(SSM, /cking/loadtest/, 배포 파일, 수집기 설정 읽기)·k6 서버(SSM, JWT 비밀값) 역할
envs/prod/                 운영 환경. 상태는 prod/terraform.tfstate
  network.tf               VPC 10.1.0.0/16, AZ 2a·2b의 퍼블릭·프라이빗 앱·프라이빗 데이터 서브넷, AZ마다 NAT, S3 게이트웨이 엔드포인트
  peering.tf               개발 VPC 피어링(관측 서버 공유), 양쪽 경로, 관측 서버 수집 포트에 운영 앱 서브넷 허용
  security_groups.tf       앱·감시용 서버, RDS, ElastiCache 보안 그룹
  database.tf              RDS MySQL 8.4 다중 AZ(마스터 비밀번호는 Secrets Manager 관리), 느린 쿼리 로그
  cache.tf                 ElastiCache Valkey 7.2 주·복제(클러스터 모드 끔, noeviction, TLS, 앱·감시 사용자)
  parameters.tf            /cking/prod/·/cking/prod-monitor/ 중 비밀이 아닌 값(DB·Redis 주소와 사용자 이름)
  servers.tf               운영 서버 공통 값(개발 앱 서버와 같은 AMI·Docker 버전)
  monitor.tf               감시용 서버(오토스케일링 그룹 1대, t4g.micro, 앱 서브넷 2a·2b)
  buckets.tf               배포·업로드·ALB 접근 로그·웹·관리자 프론트 버킷
  alb.tf                   ALB(HTTPS, /readyz 외부 차단, 접근 로그), api.cking.co.kr, API 앞단 WAF(차단, 운영 NAT IP 허용)
  app.tf                   앱 서버 오토스케일링 그룹(t4g.small 2~4대, CPU 50% 목표 추적, 교체 배포, 시작 대기 중 자기 스모크 검사)
  cdn.tf                   CloudFront(종량제, WAF 없음): cking.co.kr(www 이동)·admin.cking.co.kr 프론트, images.cking.co.kr 프로필 이미지
  alarms.tf                AWS 서비스 경보(ALB, 서버 띄우기 실패, ElastiCache, RDS) → SNS → 운영 채널(Amazon Q)·메일
  deploy_roles.tf          GitHub Actions 운영 배포 역할(BE: 배포 파일, 배포 태그, 앱 서버 교체 / FE: 프론트 버킷 동기화, 캐시 무효화)
  templates/               서버 첫 부팅 스크립트(server-base.sh는 공통 준비)
  functions/               CloudFront Functions(www → cking.co.kr 이동)
envs/prod-base/            운영 환경 EC2 역할과 인스턴스 프로필. 운영 서버보다 먼저 만들고 운영 환경을 지워도 남긴다. 상태는 prod-base/terraform.tfstate
  iam.tf                   앱 서버·추천 배치 서버·감시용 서버 역할(SSM, 운영 비밀값·배포 파일·업로드 버킷, 수집기 설정 읽기, 댓글 필터 호출, 앱 서버 시작 대기 끝내기, 추천 배치 상태 디스크 붙이기)
modules/api-waf/           API(ALB) 앞단 WAF. 개발·운영이 같은 규칙을 쓴다(관리형 규칙, 본문 크기 예외, IP당 요청 상한, 로그)
observability/             관측 서버 위의 프로그램 설정(compose, Prometheus, Loki, Alloy, Grafana, 쓰기 전용 nginx)
```

Terraform이 관리하는 리소스에는 `ManagedBy = terraform` 태그가 붙는다. 이 태그가 없는 리소스는 콘솔에서 관리한다.

## 규칙

- 상태 파일은 S3 원격 백엔드에 둔다. 상태 파일, 변수 파일, 비밀값은 커밋하지 않는다
- 비밀값은 Parameter Store에 두고 코드에는 경로만 쓴다
- 변경은 PR에 `terraform plan` 결과를 붙여 리뷰한 뒤 적용한다
- 인프라(`envs/`)는 사람이 plan을 확인하고 apply한다. 관측 서버 위의 설정(`observability/`)과 수집기 설정(`app-agent/`)은 main에 머지되면 GitHub Actions가 배포한다(추천 배치 서버는 교체해서 반영). 같은 리소스를 두 주체가 관리하지 않는다
- 컨테이너 이미지는 `이름:버전@sha256:…`으로 고정한다. 태그는 배포처에서 다른 이미지로 옮길 수 있어, 버전은 사람이 읽는 표기로 남기고 실제로는 digest로 받는다. 갱신은 Dependabot PR로 받고, 직접 바꿀 때는 버전과 digest를 함께 바꾼다. digest는 `docker buildx imagetools inspect 이름:버전`의 `Digest` 값이다
- PR마다 `ci.yml`이 검사하고, main 룰셋의 필수 검사로 건다. 설정 검증은 compose에 고정된 이미지로 실행한다
  - `terraform`: `terraform fmt -check`, `envs/` 아래 각 환경의 `init -backend=false`·`validate`
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
   - `envs/prod` plan 전에 Redis 비밀번호 두 개가 있어야 한다(Terraform이 읽어 ElastiCache 사용자에 넣고 상태 파일에는 남기지 않는다): `/cking/prod/REDIS_PASSWORD`, `/cking/prod-monitor/REDIS_PASSWORD`. 16~128자, `,` `"` `/` `@` 제외
   - RDS 마스터 비밀번호는 RDS가 Secrets Manager에 만들고 교체하므로 넣지 않는다
3. `envs/prod`에서 `terraform plan -out=tfplan` → `terraform apply tfplan`. 비밀이 아닌 값(`DB_HOST`, `DB_USERNAME`, `REDIS_HOST`, `REDIS_USERNAME`)은 Terraform이 만든다
4. 앱 DB 계정(`cking_app`, `cking` 스키마 권한만)을 처음 한 번 만든다. 앱은 마스터가 아닌 이 계정으로 접속한다. Mac에 Session Manager 플러그인과 `mysql` 클라이언트가 필요하다
   - `/cking/prod/DB_PASSWORD`에 앱 계정 비밀번호를 SecureString으로 넣는다
   - 감시용 서버를 거쳐 RDS로 포트 포워딩한다(Mac 터미널 1):
     ```bash
     MONITOR_ID=$(aws autoscaling describe-auto-scaling-groups --region ap-northeast-2 --auto-scaling-group-names prod-cking-monitor --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)
     DB_HOST=$(aws ssm get-parameter --region ap-northeast-2 --name /cking/prod/DB_HOST --query Parameter.Value --output text)
     aws ssm start-session --region ap-northeast-2 --target "$MONITOR_ID" --document-name AWS-StartPortForwardingSessionToRemoteHost --parameters "host=$DB_HOST,portNumber=3306,localPortNumber=13306"
     ```
   - 마스터 비밀번호(RDS가 만든 Secrets Manager 비밀)와 앱 계정 비밀번호를 변수로 읽어 SQL을 표준 입력으로 보낸다. 비밀번호가 화면·명령 인자·셸 기록에 남지 않는다(Mac 터미널 2):
     ```bash
     SECRET_ARN=$(aws rds describe-db-instances --region ap-northeast-2 --db-instance-identifier prod-cking-mysql --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text)
     MYSQL_PWD=$(aws secretsmanager get-secret-value --region ap-northeast-2 --secret-id "$SECRET_ARN" --query SecretString --output text | jq -r .password)
     APP_PW=$(aws ssm get-parameter --region ap-northeast-2 --name /cking/prod/DB_PASSWORD --with-decryption --query Parameter.Value --output text)
     printf "CREATE USER 'cking_app'@'%%' IDENTIFIED BY '%s';\nGRANT ALL PRIVILEGES ON cking.* TO 'cking_app'@'%%';\n" "$APP_PW" \
       | MYSQL_PWD="$MYSQL_PWD" MYSQL_HISTFILE=/dev/null mysql -h 127.0.0.1 -P 13306 -u admin
     unset MYSQL_PWD APP_PW
     ```
5. BE `main`에 머지해 운영 배포를 실행한다. BE CI가 배포 파일을 운영 배포 버킷에 올리고 `/cking/prod/RELEASE_TAG`를 바꾼 뒤 앱 서버 교체를 시작한다. 그 전까지 앱 서버는 배포 태그나 DB 계정이 없어 시작 대기에서 버려지고 다시 뜨기를 반복한다. 그래서 3단계의 Terraform은 앱 서버가 정상이 되기를 기다리지 않는다
   - 프론트는 FE `main`에 머지해 배포한다. FE CI가 운영 주소로 웹·관리자를 빌드해 각 버킷에 동기화하고 캐시를 무효화한다. 버킷 이름과 배포 ID는 `terraform output cdn`
6. 배포 실패와 되돌리기
   - 새 서버는 시작 대기 동안 같은 태그의 `smoke.js`로 자기 자신을 검사하고 통과해야 ALB에 붙는다. 실패하면 버려지고 교체가 실패하며, 옛 서버가 남고 배포 태그가 자동으로 되돌아간다
   - 교체 뒤 ALB 경로 스모크가 실패하면 BE CI가 이전 태그로 한 번 자동 교체하고 다시 검사한다
   - 스모크가 잡지 못한 문제는 BE Actions의 `Deploy to prod` 워크플로를 `main`에서 예전 태그로 실행해 되돌린다
   - 이 절차는 `envs/prod-base`의 앱 역할(시작 대기 끝내기 권한)이 먼저 적용되어 있어야 한다
7. 운영 부하 테스트: `envs/prod`에서 `terraform apply -var k6_enabled=true`로 k6 서버(`prod-cking-k6`)를 만들고, 끝나면 `k6_enabled` 없이 다시 apply해 지운다. 실행 절차는 BE `docs/operations/loadtest.md`의 "운영에서 실행"

## 요구 사항

- Terraform 1.16 이상
