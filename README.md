# Cking-Infra

크킹 인프라 코드(Terraform).

## 범위

- AWS 리소스는 Terraform이 관리한다. 밖에 두는 것은 상태 버킷(Terraform보다 먼저 있어야 해 콘솔, `bootstrap/`), 사람 IAM 사용자·그룹, 비밀값(사람이 Parameter Store에 넣음), 등록기관(가비아)의 네임서버 위임이다
- 계정에 하나인 리소스(Route53 영역 `cking.co.kr`, `*.cking.co.kr` 인증서 서울·us-east-1, GitHub OIDC 공급자, 예산 `cking-monthly`)는 `envs/account`가 만들고, 다른 스택은 이름으로 찾는다
- 다른 스택이 개발 리소스를 이름·이름표로 찾는다. 운영은 개발 VPC·퍼블릭 경로 테이블(`dev-cking-rtb-public`)·관측 서버(피어링, k6), 부하 테스트는 개발 VPC·퍼블릭 서브넷 2a·앱 서버·ALB와 HTTPS 리스너·DB 서브넷 그룹·파라미터 그룹·관측 서버, 보안 기준선은 VPC를 찾는다. 그래서 `envs/dev`를 먼저 적용하고 이 이름들은 바꾸지 않는다

## 구조

```text
.github/workflows/         PR 검사(ci.yml), Terraform plan(terraform-plan.yml, PR 댓글)·apply(terraform-apply.yml, main 수동, 승인), 관측 설정·수집기 배포(deploy-observability.yml, deploy-app-agent.yml. 앱 서버는 바로 적용, 추천 배치 서버는 교체), Lambda 코드 배포(deploy-alert-analyzer.yml 경보 AI 진단, deploy-image-normalizer.yml 이미지 정규화 개발 → 운영)
.github/dependabot.yml     컨테이너 이미지·GitHub Actions 갱신 PR
.github/scripts/           CI 보조 스크립트(render-templates.sh: 서버 부팅 스크립트 템플릿을 변수를 채운 모습으로 펼쳐 shellcheck에 넘김)
alert-analyzer/            경보 AI 진단 Lambda(Python). 경보를 받아 Claude(Claude API)가 런북대로 읽기 전용 조회를 하고 Slack 봇으로 제안. 런북 조치는 승인 버튼(approvals.py)을 누르면 실행 함수(executor.py)가 목록(actions.py)대로 실행. build.sh가 배포 묶음을 만든다. tests/는 pytest(AWS·Slack·Claude API는 가짜)
image-normalizer/          이미지 업로드 정규화 Lambda(Python, Pillow). 업로드 버킷 raw/<최종 키>의 원본을 앱과 같은 규칙(EXIF 회전, 긴 변 2048, JPEG 품질 90)으로 바꿔 최종 키에 저장하고 결과를 결과 큐로 보낸다. build.sh가 배포 묶음을 만든다
app-agent/                 서버 수집기(Alloy) 설정. agent.alloy(서버 지표·로그·전송)는 항상, app.alloy(앱 지표)·redis.alloy(Redis 지표)·cadvisor.alloy(컨테이너 지표, 부하 테스트 서버)·journal.alloy(systemd 서비스 journald 로그, 추천 배치 서버)는 apply.sh가 서버 역할에 따라 켠다
bootstrap/                 Terraform보다 먼저 만든 상태 버킷 기록
docs/loadtest.md           부하 테스트 측정 결과(1·2·3차, 어뷰징 탐지)
docs/runbooks/             경보별 대응 절차와 댓글 필터 차단·해제, 추천 배치 서버 절차(런북)
envs/account/              계정에 하나인 리소스. 다른 스택보다 먼저 적용한다. 상태는 account/terraform.tfstate
  dns.tf                   Route53 영역 cking.co.kr, *.cking.co.kr + cking.co.kr 인증서(서울 ALB용, us-east-1 CloudFront용)와 DNS 검증
  github_oidc.tf           GitHub Actions OIDC 공급자
  budget.tf                월 예산 cking-monthly(실제 85%·100%, 예측 100% 메일)
  outputs.tf               등록기관에 넣을 네임서버, 인증서, OIDC 공급자
envs/dev/                  개발 환경. 실행 위치
  terraform.tf             Terraform·프로바이더 버전
  backend.tf               상태 저장소(S3)와 잠금
  providers.tf             리전, 계정 고정, 공통 태그
  account.tf               envs/account의 영역·인증서·OIDC 공급자를 이름으로 찾기(data)
  network.tf               VPC 10.0.0.0/16, AZ 2a·2b의 퍼블릭·프라이빗 서브넷, 인터넷 게이트웨이, 경로 테이블, S3 게이트웨이 엔드포인트(프라이빗 경로)
  security_groups.tf       ALB(80·443)·앱(ALB에서 8080·헬스체크 8081)·RDS(앱에서 3306) 보안 그룹
  alb.tf                   ALB(HTTPS, HTTP는 443으로 이동, 헬스체크 관리 포트 8081 liveness, /livez·/readyz 외부 차단), dev-api.cking.co.kr
  servers.tf               앱 서버·추천 배치 서버가 같이 쓰는 AMI·Docker 버전(운영과 같음)
  database.tf              RDS MySQL 8.4 단일 AZ(마스터 비밀번호는 Secrets Manager 관리, 평문 연결 거부), 서브넷·파라미터 그룹, DB_HOST·DB_USERNAME 값
  buckets.tf               업로드·사용자 앱·배포 버킷(퍼블릭 차단, ACL 비활성화, SSE-S3)
  frontend.tf              사용자 앱 정적 호스팅(CloudFront, OAC, WAF, 무료 요금제, 보안 헤더, Route53)
  app_deploy.tf            BE 개발 배포 GitHub Actions 역할(배포 파일 올리기, 이름표로 앱 서버 찾기, 앱 서버에 Run Command)
  api_waf.tf               API 앞단 WAF(modules/api-waf)를 개발 ALB에 세기만 상태로 연결
  admin_frontend.tf        관리자 앱 정적 호스팅(S3, CloudFront, WAF, 요금제, Route53)
  uploads_cdn.tf           업로드 이미지 공개 CDN(CloudFront, WAF, 요금제, Route53, 버킷 정책)
  bucket_tls.tf            웹·업로드·관리자·배포 버킷의 TLS 아닌 요청 거부(웹·배포 버킷 정책)
  app_server.tf            앱 서버(t4g.small, 퍼블릭 2a, 공인 IP, 첫 부팅에 Docker·AWS CLI·swap)와 역할(Parameter Store·배포 파일·업로드 버킷 경로·수집기 설정 읽기, 댓글 필터 호출)
  frontend_deploy.tf       FE 개발 배포 GitHub Actions 역할과 앱별 권한(사용자 앱·관리자 앱 버킷 동기화, 도메인으로 배포 찾기, 캐시 무효화)
  observability.tf         관측 서버(EC2, 데이터 디스크, 스냅샷, 버킷, IAM, 앱·추천 배치 서버 수집 포트)
  alerts.tf                서버 상태 검사 경보와 메일 주제
  observability_access.tf  Grafana 공개 경로(개발 ALB 규칙 monitoring.cking.co.kr, Google 로그인, 대상 그룹, Route53)
  observability_deploy.tf  관측 설정·수집기 설정을 배포하는 GitHub Actions 역할(앱 서버 적용, 추천 배치 서버 교체)
  alert_analyzer.tf        경보 AI 진단(분석용 SNS, Lambda와 읽기 전용 역할, 관측 서버 조회 SSM 문서, 같은 경보 묶기·하루 상한 DynamoDB, CI 코드 배포 권한)
  image_pipeline.tf        이미지 업로드 이벤트 파이프라인(작업·결과 큐와 DLQ, 업로드 버킷 raw/ 알림·CORS·수명 주기, 정규화 Lambda와 역할, 앱 서버 raw/ 쓰기·결과 큐 읽기, 결과 큐 주소 Parameter Store, DLQ 경보, CI 코드 배포 권한)
  alert_actions.tf         경보 AI 진단의 조치 승인 버튼(승인 함수 URL, 실행 함수와 조치별 권한, 서버 조치 SSM 문서, 승인자 목록)
  comment_filter.tf        댓글 필터 이미지 저장소(ECR, 개발·운영 공용), 개발 Lambda(arm64 이미지, 함수 URL IAM 인증, 예약 동시성 2, 이미지는 필터 저장소 CI가 바꿈), 필터 저장소 GitHub Actions 개발 역할(모델 읽기, 이미지 푸시, 개발 Lambda 갱신·호출)
  lambda_bootstrap.tf      zip 함수를 처음 만들 때 쓰는 임시 코드 묶음(archive_file). 실제 코드는 배포 워크플로가 넣는다
  recommendation.tf        개발 추천 배치 서버(1대짜리 서버 그룹, arm64 스팟 6개 유형, 상태 디스크, 시작 대기 자기 검사, 역할, 비밀이 아닌 값)와 추천 배치 저장소 GitHub Actions 개발 역할(배포 패키지 올리기, 배포 버전 값, 서버 교체)
  outputs.tf               개발 기반 리소스 ID, 관리자 앱·관측 서버·추천 배치·댓글 필터 관련 값 출력
  templates/               서버 첫 부팅 스크립트(앱 서버·추천 배치 서버는 운영의 공통 준비 server-base.sh를 앞에 붙이고, 추천 배치 서버는 부팅 스크립트 recommendation-init.sh도 운영과 같이 쓴다)
envs/loadtest/             부하 테스트 환경. 측정 때 띄우고 끝나면 지운다(loadtest/lt.sh). 상태는 loadtest/terraform.tfstate
  existing.tf              개발 환경 리소스 읽기(data)
  variables.tf             환경 이름, 서버·RDS 크기, Docker 버전, 정리 기한(ttl_hours)
  app_server.tf            앱 서버(개발 앱 서버와 같은 AMI·크기·Docker 버전·swap)
  rds.tf                   RDS(개발 RDS와 같은 사양, 빈 DB)
  alb.tf                   개발 ALB에 loadtest-api.cking.co.kr 경로(헬스체크는 개발 대상 그룹과 같은 8081 liveness)
  k6.tf                    k6 서버와 서버 지표 수집기
  parameters.tf            /cking/loadtest/ 중 비밀이 아닌 값
  outputs.tf               앱 서버 ID·주소, API 주소
  templates/               서버 첫 부팅 스크립트
envs/loadtest-base/        부하 테스트 EC2 역할과 인스턴스 프로필, 결과 버킷, 정리기. 테스트 환경보다 먼저 만들고 테스트 환경을 지워도 남긴다. 상태는 loadtest-base/terraform.tfstate
  iam.tf                   앱 서버(SSM, /cking/loadtest/, 배포 파일, 수집기 설정 읽기)·k6 서버(SSM, JWT 비밀값·실행 알림 웹훅 읽기, 실행기의 앱 서버 명령·결과 쓰기) 역할, 지표 조회 역할(관측 서버 조회 문서만)
  results.tf               실행기 결과 버킷(비공개, 1년 보관)
  janitor.tf               남은 서버·RDS 정리기(Lambda, 1시간마다, cking:ttl-hours가 지나면 멈춤)
  janitor/                 정리기 Lambda 코드(Python)
  outputs.tf               앱·k6 서버 인스턴스 프로필 이름
envs/prod/                 운영 환경. 상태는 prod/terraform.tfstate
  network.tf               VPC 10.1.0.0/16, AZ 2a·2b의 퍼블릭·프라이빗 앱·프라이빗 데이터 서브넷, 경로, AZ마다 NAT Gateway(nat_mode가 gateway일 때), S3 게이트웨이 엔드포인트
  nat.tf                   NAT 방식(nat_mode). 기본 instance는 AZ마다 t4g.micro NAT 인스턴스·EIP와 시스템 검사 복구·인스턴스 검사 재부팅·전달 확인 경보
  peering.tf               개발 VPC 피어링(관측 서버 공유), 양쪽 경로, 관측 서버 수집 포트에 운영 앱 서브넷 허용
  security_groups.tf       앱·감시용·추천 배치 서버, RDS, ElastiCache 보안 그룹
  database.tf              RDS MySQL 8.4 다중 AZ(마스터 비밀번호는 Secrets Manager 관리), 느린 쿼리 로그, Enhanced Monitoring(평소 60초)
  cache.tf                 ElastiCache Valkey 7.2 주·복제(클러스터 모드 끔, noeviction, TLS, 앱·감시 사용자)
  parameters.tf            /cking/prod/·/cking/prod-monitor/ 중 비밀이 아닌 값(DB·Redis 주소와 사용자 이름, 댓글 필터 함수 URL)
  servers.tf               운영 서버 공통 값(개발 앱 서버와 같은 AMI·Docker 버전)
  monitor.tf               감시용 서버(오토스케일링 그룹 1대, t4g.micro, 앱 서브넷 2a·2b)
  recommendation.tf        추천 배치 서버(1대짜리 서버 그룹, t4g.small 온디맨드, 앱 서브넷 2a, 상태 디스크, 시작 대기 자기 검사, 비밀이 아닌 값)와 추천 배치 저장소 GitHub Actions 운영 역할(개발 패키지 복사, 배포 버전 값, 서버 교체)
  buckets.tf               배포·업로드·ALB 접근 로그·웹·관리자 프론트 버킷(업로드 버킷 raw/ 1일 수명 주기)
  alb.tf                   ALB(HTTPS, 헬스체크 관리 포트 8081 liveness, /livez·/readyz 외부 차단, 접근 로그), api.cking.co.kr, API 앞단 WAF(차단, 운영 NAT IP 허용, 비밀 쿠키 게이트)
  app.tf                   앱 서버 오토스케일링 그룹(c6g.large 2~4대, 서버당 분당 요청 6,300건 목표 추적, 교체 배포, 시작 대기 중 자기 스모크 검사)
  cdn.tf                   CloudFront(종량제, WAF 없음): cking.co.kr(www 이동)·admin.cking.co.kr 프론트(gate_enabled면 비밀 쿠키 게이트 함수), images.cking.co.kr 프로필 이미지
  comment_filter.tf        운영 댓글 필터 Lambda(arm64 이미지, 함수 URL IAM 인증, 예약 동시성 8, 이미지는 필터 저장소 main CI가 개발에서 확인한 이미지로 바꿈)
  lambda_bootstrap.tf      이미지 정규화 함수를 처음 만들 때 쓰는 임시 코드 묶음(archive_file)
  image_pipeline.tf        이미지 업로드 이벤트 파이프라인(작업·결과 큐와 DLQ, 업로드 버킷 raw/ 알림·CORS, 정규화 Lambda와 SQS 연결 최대 동시성, DLQ 경보). 결과 큐 주소 Parameter Store는 image_pipeline_enabled일 때만
  alarms.tf                AWS 서비스 경보(ALB, 서버 띄우기 실패, ElastiCache, RDS) → SNS → 운영 채널(Amazon Q)·메일. 같은 SNS가 GuardDuty 경보(envs/security)도 받는다
  k6.tf                    운영 부하 테스트 k6 서버(modules/k6-server, k6_enabled일 때만, 프라이빗 앱 서브넷 2a)
  alert_analyzer.tf        경보 AI 진단의 운영 경보 주제 구독과 호출 허용. 함수는 envs/dev
  deploy_roles.tf          GitHub Actions 운영 배포 역할(BE: 배포 파일, 배포 태그, 앱 서버 교체 / FE: 프론트 버킷 동기화, 도메인으로 배포 찾기, 캐시 무효화 / 필터: 개발 CI가 올린 이미지에 prod- 태그, 운영 Lambda 교체·호출 / Infra: 개발 CI가 올린 묶음으로 운영 이미지 정규화 Lambda 교체)
  outputs.tf               NAT 공인 IP, ALB·앱 서버 그룹·배포 역할·배포 버킷·WAF 로그, FE 운영 배포가 쓰는 CDN 값
  templates/               서버 첫 부팅 스크립트(server-base.sh는 공통 준비, recommendation-init.sh는 개발·운영 추천 배치 서버가 같이 쓴다)
  functions/               CloudFront Functions(gate.js.tftpl 비밀 쿠키 게이트와 www 이동, www-redirect.js 게이트를 끈 뒤의 www → cking.co.kr 이동)
envs/prod-base/            운영 환경 EC2 역할·인스턴스 프로필과 RDS 모니터링 역할. 운영 서버보다 먼저 만들고 운영 환경을 지워도 남긴다. 상태는 prod-base/terraform.tfstate
  iam.tf                   앱 서버·추천 배치 서버·감시용 서버·NAT 인스턴스·k6 서버 역할, RDS Enhanced Monitoring 역할(SSM, 운영 비밀값·배포 파일·업로드 버킷, 수집기 설정 읽기, 댓글 필터 호출, 이미지 파이프라인 raw/ 쓰기·결과 큐 읽기, 앱·추천 배치 서버 시작 대기 끝내기, 추천 배치 상태 디스크 붙이기, k6 실행기의 운영 앱 서버 명령·결과 쓰기. NAT 인스턴스는 SSM만)
  outputs.tf               인스턴스 프로필 이름
envs/ci/                   Terraform을 GitHub Actions로 plan·apply하는 역할. plan은 읽기 전용(데이터 읽기 거부, plan에 필요한 비밀값 5개만 복호화), apply는 관리자. 신뢰는 GitHub Environment terraform-plan·terraform-apply(승인자 필요). 상태는 ci/terraform.tfstate
  roles.tf                 plan·apply 역할
envs/security/             계정 보안 기준선. 환경과 상관없이 계정에 하나. 상태는 security/terraform.tfstate
  logs.tf                  감사 로그 버킷(CloudTrail·Config·VPC 흐름 로그 공용, 1년 보관)과 CloudTrail 추적(전 리전, 관리 이벤트, 로그 파일 검증)
  detection.tf             GuardDuty, 심각도 7 이상 발견 → 운영 경보 SNS(Slack), IAM Access Analyzer(계정)
  posture.tf               AWS Config 기록(서울, 전역 리소스 포함)과 Security Hub FSBP 표준
  hardening.tf             EBS 기본 암호화·스냅샷 퍼블릭 차단, S3 계정 퍼블릭 차단, IAM 비밀번호 정책, 모든 VPC 기본 보안 그룹 규칙 비우기, 개발·운영 VPC 흐름 로그, Inspector(EC2·ECR·Lambda)
  triage.tf                Security Hub 자동화 규칙. 받아들이기로 한 지적을 억제하고 이유를 메모로 남긴다
modules/api-waf/           API(ALB) 앞단 WAF. 개발·운영이 같은 규칙을 쓴다(관리형 규칙, 본문 크기 예외, 로그). 허용 IP·비밀 쿠키 게이트는 운영만 넘기고, IP당 요청 상한(rate_limit)은 값을 넘길 때만 만든다(지금은 어느 환경도 넘기지 않는다)
modules/k6-server/         부하 테스트 k6 서버(EC2, 보안 그룹, k6·Alloy·AWS CLI 설치). envs/loadtest와 envs/prod가 같이 쓴다
loadtest/                  부하 테스트 실행 자동화(lt.sh 환경 생성·배포·실행·삭제, runner/ 시나리오 실행기, agent/ 앱 서버 데이터 작업, scenarios/ 시나리오, tests/ 실행기·lt.sh pytest)
observability/             관측 서버 위의 프로그램 설정(compose, Prometheus, Loki, Alloy, Grafana, 쓰기 전용 nginx)과 AI 진단용 읽기 전용 조회(query.py)
.tflint.hcl                tflint 설정(Terraform 권장 규칙, AWS 규칙 플러그인 버전)
.checkov.yaml              checkov 설정(Terraform만 검사, 받아들인 규칙과 근거, 경고만 내는 규칙)
pytest.ini                 pytest 테스트 위치. 개발 의존성은 requirements-dev.txt
```

Terraform이 관리하는 리소스에는 `ManagedBy = terraform` 태그가 붙는다. 이 태그가 없는 리소스는 콘솔에서 관리한다.

## 규칙

- 상태 파일은 S3 원격 백엔드에 둔다. 상태 파일, 변수 파일, 비밀값은 커밋하지 않는다
- 비밀값은 Parameter Store에 두고 코드에는 경로만 쓴다
- 변경은 PR의 plan 결과를 보고 리뷰한 뒤 적용한다. `envs/`·`modules/`를 바꾼 PR은 `terraform-plan.yml`이 바뀐 스택만 plan해 요약(리소스 주소와 동작, 값 없음)을 PR 댓글로 남긴다. Environment `terraform-plan` 승인 뒤 돈다(공개 저장소라 승인 없이는 AWS 자격을 주지 않는다). 계획은 기본 변수값 기준이라 켜 둔 토글(`k6_enabled` 등)은 차이로 나온다
- 인프라(`envs/`) 적용은 머지 뒤 `terraform-apply.yml`을 main에서 수동 실행한다(스택, PR 댓글의 기대 개수 `추가,변경,삭제`, 필요하면 `-var` 값). Environment `terraform-apply` 승인 뒤 새로 plan하고, 개수가 기대와 다르면 적용하지 않는다. `envs/loadtest`를 뺀 모든 스택이 대상이다. 로컬 apply는 `envs/account`·`envs/ci`·`envs/dev`를 처음 만들 때([처음 구축하는 순서](#처음-구축하는-순서)), CI가 안 될 때, `envs/loadtest`(`loadtest/lt.sh`가 띄우고 지운다), 런북의 복구 절차(NAT 방식 되돌리기, DB 복원 되돌리기)에서만 한다. 관측 서버 위의 설정(`observability/`)과 수집기 설정(`app-agent/`)은 main에 머지되면 GitHub Actions가 배포한다(추천 배치 서버는 교체해서 반영). 같은 리소스를 두 주체가 관리하지 않는다
- 컨테이너 이미지는 `이름:버전@sha256:…`으로 고정한다. 태그는 배포처에서 다른 이미지로 옮길 수 있어, 버전은 사람이 읽는 표기로 남기고 실제로는 digest로 받는다. `observability/`·`app-agent/`의 compose와 GitHub Actions는 Dependabot PR로 갱신을 받는다. 그 밖의 이미지(`ci.yml`의 actionlint·tflint·checkov·gitleaks, `envs/prod/app.tf`의 k6, `loadtest/agent/lt-app.sh`의 MySQL·Valkey 클라이언트)와 tflint AWS 규칙 플러그인(`.tflint.hcl`), Python 개발 의존성(`requirements-dev.txt`)은 직접 바꾸며, 버전과 digest를 함께 바꾼다. digest는 `docker buildx imagetools inspect 이름:버전`의 `Digest` 값이다
- PR마다 `ci.yml`이 검사하고, main 룰셋의 필수 검사로 건다. 설정 검증은 compose에 고정된 이미지로 실행한다
  - `terraform`: `terraform fmt -check`, `tflint`(`envs/`·`modules/` 전체, Terraform 권장 규칙 + AWS 규칙), `envs/` 아래 각 환경(`ci`·`security` 포함)의 `init -backend=false`·`validate`
  - `config`: compose 해석, Alloy `validate`, `promtool check config`, Loki `-verify-config`, 대시보드 JSON 형식·uid 중복, `nginx -t`
  - `lint`: `shellcheck`(배포 스크립트, 서버 첫 부팅 스크립트는 Terraform 변수를 채운 모습으로 펼쳐서), Python 문법(`py_compile`), 부하 테스트 시나리오 형식(`ltrun.py check`), `actionlint`(워크플로)
  - `test`: pytest(경보 진단 Lambda, 이미지 정규화 Lambda, 부하 테스트 실행기·`lt.sh`). 로컬은 `pip install -r requirements-dev.txt` 뒤 `python -m pytest`
  - `security`: `checkov`(Terraform. 받아들인 규칙은 `.checkov.yaml`에 근거와 함께 skip, 근거를 정하지 않은 규칙은 경고만, 그 밖의 규칙은 실패), `gitleaks`(전체 이력, 값은 가려서 출력)
- 협업 규칙은 조직 CONTRIBUTING을 따른다. 개발·운영은 브랜치가 아니라 `envs/` 스택으로 나누고 관측 서버·수집기 설정은 두 환경이 같이 쓰므로, `develop` 없이 `main`으로 PR을 보낸다

## 처음 구축하는 순서

스택은 서로를 이름으로 찾으므로 이 순서로 만든다. 처음 만드는 `envs/account`·`envs/ci`·`envs/dev`는 로컬(관리자 IAM 사용자)에서, 그 뒤 변경은 모두 `terraform-apply.yml`로 적용한다.

1. 상태 버킷([bootstrap/README.md](bootstrap/README.md), 콘솔)
2. `envs/account`
   - 예산 알림 메일을 Parameter Store `/cking/account/BUDGET_EMAIL`(String)에 넣는다
   - 영역만 먼저 만든다: `terraform apply -target=aws_route53_zone.main`
   - 출력 `route53_name_servers`를 가비아의 `cking.co.kr` 네임서버로 바꾼다. 인증서 DNS 검증은 위임이 끝나야 통과한다
   - 전체를 적용한다: `terraform apply`. 인증서 두 장이 발급될 때까지 기다린다
3. `envs/ci`. 그다음 GitHub 저장소에 Environment `terraform-plan`·`terraform-apply`(승인자, apply는 main만)를 둔다
4. 개발 환경([개발 환경](#개발-환경))
5. 운영 환경([운영 환경](#운영-환경))
6. 계정 보안 기준선([계정 보안 기준선](#계정-보안-기준선), 운영 경보 SNS를 쓰므로 운영 뒤)
7. 부하 테스트 IAM·결과 버킷 `envs/loadtest-base`([부하 테스트 환경](#부하-테스트-환경))

## 개발 환경

1. Parameter Store에 값을 넣는다. 비밀값은 SecureString이다
   - `envs/dev` plan 전에 있어야 하는 값: `/cking/dev/monitoring/ALERT_EMAIL`(String, 경보 메일), `/cking/dev/monitoring/GOOGLE_OAUTH_CLIENT_ID`(String), `/cking/dev/monitoring/GOOGLE_OAUTH_CLIENT_SECRET`(Grafana Google 로그인, ALB 규칙에 들어간다)
   - 앱 서버가 배포 때 읽는 `/cking/dev/` 값은 BE `deploy/deploy.sh`의 필수 목록이다. `DB_PASSWORD`는 앱 계정(`cking_app`) 비밀번호다. `COMMENT_FILTER_BASE_URL`은 적용 뒤 `terraform output comment_filter`의 함수 URL을 넣는다
   - 관측 서버(`/cking/dev/monitoring/`)·추천 배치 서버(`/cking/dev-recommendation/`)가 읽는 나머지 값
   - Terraform이 만드는 값: `/cking/dev/DB_HOST`, `/cking/dev/DB_USERNAME`, `/cking/dev/IMAGE_PIPELINE_RESULTS_QUEUE_URL`, `/cking/dev/monitoring/AI_ACTION_APPROVERS`, `/cking/dev-recommendation/CKING_BE_URL`·`CKING_TAG_DAILY_CALLS`
2. 댓글 필터 함수는 ECR의 가장 최근 이미지로 만들어지므로 두 번에 나눠 적용한다(로컬)
   - 배포 버킷과 필터 이미지 저장소만 먼저 만든다: `terraform apply -target=aws_s3_bucket.deploy -target=aws_ecr_repository.comment_filter`
   - 필터 모델을 배포 버킷 `filter/models/<모델 이름>/best/`에 올리고(필터 저장소 CI가 이미지를 빌드할 때 읽는다), 필터 이미지를 ECR에 올린다(필터 저장소 README "모델")
   - 전체를 적용한다: `terraform plan -out=tfplan` → `terraform apply tfplan`
   - 경보 진단(승인·실행 포함)·이미지 정규화 함수는 임시 코드(`lambda_bootstrap.tf`)로 만들어진다. 적용 뒤 Actions `deploy-alert-analyzer`·`deploy-image-normalizer`를 main에서 실행해 실제 코드를 넣는다
3. 앱 DB 계정(`cking_app`, `cking` 스키마 권한만)을 처음 한 번 만든다. 운영과 같은 방법이고, 경유지는 앱 서버다(Mac 터미널 1):
   ```bash
   APP_ID=$(aws ec2 describe-instances --region ap-northeast-2 --filters Name=tag:Name,Values=dev-cking-app Name=instance-state-name,Values=running --query 'Reservations[0].Instances[0].InstanceId' --output text)
   DB_HOST=$(aws ssm get-parameter --region ap-northeast-2 --name /cking/dev/DB_HOST --query Parameter.Value --output text)
   aws ssm start-session --region ap-northeast-2 --target "$APP_ID" --document-name AWS-StartPortForwardingSessionToRemoteHost --parameters "host=$DB_HOST,portNumber=3306,localPortNumber=13306"
   ```
   Mac 터미널 2:
   ```bash
   SECRET_ARN=$(aws rds describe-db-instances --region ap-northeast-2 --db-instance-identifier dev-cking-mysql --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text)
   MYSQL_PWD=$(aws secretsmanager get-secret-value --region ap-northeast-2 --secret-id "$SECRET_ARN" --query SecretString --output text | python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])')
   APP_PW=$(aws ssm get-parameter --region ap-northeast-2 --name /cking/dev/DB_PASSWORD --with-decryption --query Parameter.Value --output text)
   printf "CREATE USER 'cking_app'@'%%' IDENTIFIED BY '%s';\nGRANT ALL PRIVILEGES ON cking.* TO 'cking_app'@'%%';\n" "$APP_PW" \
     | MYSQL_PWD="$MYSQL_PWD" MYSQL_HISTFILE=/dev/null mysql -h 127.0.0.1 -P 13306 -u admin
   unset MYSQL_PWD APP_PW
   ```
4. BE·FE develop 배포를 실행한다. BE CI는 앱 서버를 이름표 `dev-cking-app`으로, FE CI는 사용자 앱·관리자 앱 배포를 도메인으로 찾는다
5. 관측 설정과 수집기를 배포한다: `deploy-observability.yml`, 그다음 `deploy-app-agent.yml`(수집기는 앱 compose 네트워크에 붙으므로 첫 BE 배포 뒤)

## 부하 테스트 환경

측정 결과(1·2·3차, 어뷰징 탐지)는 [docs/loadtest.md](docs/loadtest.md).

시나리오 실행까지 한 번에 하려면 `loadtest/lt.sh all <시나리오>`([loadtest/README.md](loadtest/README.md)). 아래는 그 스크립트가 하는 일을 손으로 할 때의 순서다. `envs/loadtest-base`는 역할 외에 결과 버킷(`loadtest-cking-results-…`), 지표 조회 역할(`loadtest-cking-query`), 남은 리소스 정리기(`loadtest-cking-janitor`, `cking:ttl-hours` 태그가 붙은 서버·RDS를 기한 뒤 멈춤)를 만든다.

순서

1. `envs/loadtest-base`를 `terraform-apply.yml`로 적용한다. 앱 서버·k6 서버 IAM 역할을 만든다. 처음 한 번만 하고, 테스트 환경을 지워도 남긴다(서버와 같은 apply로 만들면 역할이 전파되기 전에 부팅해 SSM 에이전트가 붙지 않는다)
2. Parameter Store `/cking/loadtest/`에 비밀값을 SecureString으로 넣는다: `DB_PASSWORD`, `JWT_SECRET`, `ADMIN_ACCOUNT_LOGIN_ID`, `ADMIN_ACCOUNT_PASSWORD`, `DOCS_USERNAME`, `DOCS_PASSWORD`. 나머지 값은 Terraform이 만든다
3. `envs/loadtest`에서 `terraform plan -out=tfplan` → `terraform apply tfplan`
4. 앱 배포: 개발 서버에 떠 있는 이미지 태그로 앱 서버에서 `aws s3 cp s3://dev-cking-deploy-551372961758/releases/<태그>/deploy.sh /opt/cking/deploy.sh` 뒤 `PARAM_PATH=/cking/loadtest/ bash /opt/cking/deploy.sh <태그>`(BE CI가 개발 서버에 배포하는 방식과 같다). 측정 내내 같은 태그를 쓴다
5. 앱 서버 수집기: 앱 서버에서 `aws s3 sync --exact-timestamps s3://<관측 버킷>/app-agent/ /opt/app-agent/` 뒤 `CKING_INSTANCE=loadtest-cking-app CKING_CADVISOR=1 bash /opt/app-agent/apply.sh`. 수집기는 앱 compose의 네트워크(`cking_default`)에 붙으므로 앱 배포 뒤에 적용한다
6. 측정이 끝나면 `envs/loadtest`에서 `terraform destroy`. `envs/loadtest-base`의 역할과 Parameter Store 비밀값은 다음 측정에 다시 쓰므로 남긴다. 그만 쓸 때 직접 지운다

- 앱 주소는 `https://loadtest-api.cking.co.kr`(개발 ALB, 443 규칙 우선순위 200)
- k6 결과 지표는 `k6 run -o experimental-prometheus-rw <스크립트>`로 관측 서버에 보낸다. 주소는 k6 서버의 `/etc/profile.d/k6.sh`
- k6는 Access Token을 실행 중에 직접 서명한다. 비밀값은 환경변수로만 넘긴다: `JWT_SECRET="$(aws ssm get-parameter --region ap-northeast-2 --name /cking/loadtest/JWT_SECRET --with-decryption --query Parameter.Value --output text)" k6 run -o experimental-prometheus-rw <스크립트>`
- 이름표: 앱 서버 `loadtest-cking-app`, k6 서버 `loadtest-cking-k6`

## 운영 환경

1. `envs/prod-base`를 `terraform-apply.yml`로 적용한다. 처음 한 번만 하고, 운영 환경을 지워도 남긴다
2. 비밀값은 Parameter Store에 SecureString으로 넣는다. 앱은 `/cking/prod/`, 추천 배치 서버는 `/cking/prod-recommendation/`, 감시용 서버는 `/cking/prod-monitor/`(Redis 감시 전용 사용자)이며 각 역할은 자기 경로만 읽는다
   - `envs/prod` plan 전에 Redis 비밀번호 두 개가 있어야 한다(Terraform이 읽어 ElastiCache 사용자에 넣고 상태 파일에는 남기지 않는다): `/cking/prod/REDIS_PASSWORD`, `/cking/prod-monitor/REDIS_PASSWORD`. 16\~128자, `,` `"` `/` `@` 제외
   - RDS 마스터 비밀번호는 RDS가 Secrets Manager에 만들고 교체하므로 넣지 않는다
   - 비밀 쿠키 게이트 값 `/cking/prod/GATE_SECRET`(`openssl rand -hex 24`). Terraform이 읽어 CloudFront 함수(웹·관리자)와 API WAF 규칙에 넣으므로 상태 파일에 남는다. 팀원 입장 주소는 `https://cking.co.kr/?gate=<값>`이고 30일 쿠키가 생긴다. 정식 오픈 때 `gate_enabled`를 끈다
3. `envs/prod`를 `terraform-apply.yml`로 적용한다. 비밀이 아닌 값은 Terraform이 만든다: `/cking/prod/`의 `DB_HOST`, `DB_USERNAME`, `REDIS_HOST`, `REDIS_USERNAME`, `COMMENT_FILTER_BASE_URL`, `IMAGE_PIPELINE_RESULTS_QUEUE_URL`(`image_pipeline_enabled`일 때), `/cking/prod-monitor/`의 `REDIS_HOST`·`REDIS_USERNAME`, `/cking/prod-recommendation/`의 `CKING_BE_URL`·`CKING_TAG_DAILY_CALLS`
   - Amazon Q에 Slack 워크스페이스를 연결하지 않은 계정에서는 `-var` 값 `slack_alerts_enabled=false`로 적용한다(운영 경보 SNS의 메일·경보 진단 구독은 그대로). 연결은 콘솔 OAuth로만 된다
   - 이미지 정규화 함수는 임시 코드로 만들어진다. 적용 뒤 Actions `deploy-image-normalizer`를 main에서 실행한다(운영 job은 저장소 변수 `IMAGE_NORMALIZER_PROD=true`일 때). 댓글 필터 함수는 ECR의 가장 최근 이미지로 만들어진다
   - 추천 배치 서버는 배치 저장소 main의 첫 운영 배포 전까지 배포 버전 값이 없어 시작 대기에서 버려지기를 반복한다. 켜는 순서는 [추천 배치 서버](docs/runbooks/recommendation-batch.md#운영에서-다른-점)
4. 앱 DB 계정(`cking_app`, `cking` 스키마 권한만)을 처음 한 번 만든다. 앱은 마스터가 아닌 이 계정으로 접속한다. Mac에 Session Manager 플러그인, `mysql` 클라이언트, `python3`가 필요하다
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
     MYSQL_PWD=$(aws secretsmanager get-secret-value --region ap-northeast-2 --secret-id "$SECRET_ARN" --query SecretString --output text | python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])')
     APP_PW=$(aws ssm get-parameter --region ap-northeast-2 --name /cking/prod/DB_PASSWORD --with-decryption --query Parameter.Value --output text)
     printf "CREATE USER 'cking_app'@'%%' IDENTIFIED BY '%s';\nGRANT ALL PRIVILEGES ON cking.* TO 'cking_app'@'%%';\n" "$APP_PW" \
       | MYSQL_PWD="$MYSQL_PWD" MYSQL_HISTFILE=/dev/null mysql -h 127.0.0.1 -P 13306 -u admin
     unset MYSQL_PWD APP_PW
     ```
5. BE `main`에 머지해 운영 배포를 실행한다. BE CI가 배포 파일을 운영 배포 버킷에 올리고 `/cking/prod/RELEASE_TAG`를 바꾼 뒤 앱 서버 교체를 시작한다. 그 전까지 앱 서버는 배포 태그나 DB 계정이 없어 시작 대기에서 버려지고 다시 뜨기를 반복한다. 그래서 3단계의 Terraform은 앱 서버가 정상이 되기를 기다리지 않는다
   - 프론트는 FE `main`에 머지해 배포한다. FE CI가 운영 주소로 웹·관리자를 빌드해 각 버킷에 동기화하고 캐시를 무효화한다. 배포 ID는 FE CI가 도메인(`cking.co.kr`, `admin.cking.co.kr`)으로 찾으므로 운영을 다시 만들어도 FE를 고치지 않는다. 버킷 이름과 배포 ID는 `terraform output cdn`
6. 배포 실패와 되돌리기
   - 새 서버는 시작 대기 동안 같은 태그의 `smoke.js`로 자기 자신을 검사하고 통과해야 ALB에 붙는다. 실패하면 버려지고 교체가 실패하며, 옛 서버가 남고 배포 태그가 자동으로 되돌아간다
   - 교체 뒤 ALB 경로 스모크가 실패하면 BE CI가 이전 태그로 한 번 자동 교체하고 다시 검사한다
   - 스모크가 잡지 못한 문제는 BE Actions의 `Deploy to prod` 워크플로를 `main`에서 예전 태그로 실행해 되돌린다
   - 이 절차는 `envs/prod-base`의 앱 역할(시작 대기 끝내기 권한)이 먼저 적용되어 있어야 한다
7. 운영 부하 테스트: `envs/prod`를 `terraform-apply.yml`로 `-var` 값 `k6_enabled=true rds_monitoring_interval=1`과 함께 적용해 k6 서버(`prod-cking-k6`)를 만들고 RDS Enhanced Monitoring을 1초로 바꾼다. 끝나면 두 값 없이 다시 적용해 k6 서버를 지우고 60초로 되돌린다. 간격 변경은 재부팅 없이 적용된다. 1초를 켜 두면 수집 비용이 월 약 $16이라 반드시 되돌린다. 실행 절차는 BE `docs/operations/loadtest.md`의 "운영에서 실행"

## 운영 NAT 방식

`envs/prod`의 `nat_mode`로 고른다. 기본은 `instance`(AZ마다 t4g.micro NAT 인스턴스, 월 약 $17)이고 `gateway`는 AZ마다 관리형 NAT Gateway(월 약 $86)다. 운영 NAT를 지나는 데이터가 하루 1GB 안팎이라 비용 대부분이 켜 둔 시간 요금이다.

1. 인스턴스 역할은 `envs/prod-base`(`prod-cking-nat-role`)에 있어 먼저 적용되어 있어야 한다
2. 바꿀 때: `envs/prod`를 `terraform-apply.yml`로 `-var` 값 `nat_mode=<방식>`과 함께 적용한다. 바깥 IP가 바뀌고 API WAF 허용 IP(운영 NAT)도 같이 바뀐다
3. 바꾸는 동안 앱 서브넷의 바깥 연결이 잠깐 끊긴다(2026-10-29 게이트웨이 → 인스턴스 전환 때 약 45\~48초, 게이트웨이 삭제가 경로 변경보다 먼저 끝나서). 끊김을 없애려면 두 단계로 한다: 새 방식을 만들고 경로를 옮긴 뒤 옛 방식을 지운다. 경보·대응은 런북 `prod-nat.md`
4. 바깥 IP가 바뀌면 API WAF 허용 IP도 같은 apply에서 바뀌지만 경로보다 늦게 반영될 수 있다. 그 사이 추천 배치 요청이 비밀 쿠키 게이트에 걸려 403을 받을 수 있다(배치는 다음 주기에 다시 한다)

## 계정 보안 기준선

1. `envs/prod`를 먼저 적용한다. 운영 경보 SNS가 `rule/cking-security-*` 이벤트 규칙의 발행을 허용해야 GuardDuty 경보가 들어간다
2. `envs/security`를 `terraform-apply.yml`로 적용한다
3. Security Hub 검사 결과는 켠 뒤 하루 안에 채워진다. 지적 사항은 고칠 것과 받아들일 것으로 나눈다. 받아들인 것은 이유와 함께 `triage.tf`에 넣어 억제한다. 새 리소스는 이름·이름표로 좁힌 규칙에 걸리지 않으면 다시 판단한다
4. 서울 기본 VPC는 지웠다(2026-10-29). 쓰는 리소스가 없었고, 서브넷을 빠뜨리고 만든 서버가 공인 IP를 달고 뜨는 것을 막는다. 필요하면 `aws ec2 create-default-vpc`로 다시 만든다. 다른 리전의 기본 VPC는 쓰지 않는 리전이라 그대로 둔다
5. 비용: GuardDuty·Security Hub는 처음 30일 무료 체험이고, 그 뒤 금액은 체험 기간 사용량으로 확인한다. CloudTrail 첫 관리 이벤트 추적은 무료(버킷 저장 비용만), Config는 기록한 설정 항목 수에 비례한다

## 요구 사항

- Terraform 1.16 이상
