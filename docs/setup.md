# 구축 문서

크킹 인프라를 빈 계정에서 다시 만드는 순서, 만든 뒤 바꿀 때의 규칙, 다 쓴 뒤 지우는 순서다. 구성과 결정 이유는 [설계서](design.md)에 있다.

## 관리 범위

- AWS 리소스는 Terraform이 관리한다. 밖에 두는 것은 상태 버킷(Terraform보다 먼저 있어야 해서 콘솔로 만든다, [`bootstrap/`](../bootstrap/README.md)), 사람 IAM 사용자·그룹, 비밀값(사람이 Parameter Store에 넣음), 등록기관(가비아)의 네임서버 위임이다
- 계정에 하나인 리소스(Route53 영역 `cking.co.kr`, `*.cking.co.kr` 인증서 서울·us-east-1, GitHub OIDC 공급자, 예산 `cking-monthly`)는 `envs/account`가 만들고, 다른 스택은 이름으로 찾는다
- 다른 스택이 개발 리소스를 이름·태그로 찾는다. 운영은 개발 VPC·퍼블릭 경로 테이블(`dev-cking-rtb-public`)·관측 서버(피어링, k6), 부하 테스트는 개발 VPC·퍼블릭 서브넷 2a·앱 서버·ALB와 HTTPS 리스너·DB 서브넷 그룹·파라미터 그룹·관측 서버, 보안 기준선은 VPC를 찾는다. 그래서 `envs/dev`를 먼저 적용하고 이 이름들은 바꾸지 않는다

## 바꿀 때

- 상태 파일은 S3 원격 백엔드에 둔다. 상태 파일, 변수 파일, 비밀값은 커밋하지 않는다
- 비밀값은 Parameter Store에 두고 코드에는 경로만 쓴다
- 변경은 PR의 plan 결과를 보고 리뷰한 뒤 적용한다. `envs/`·`modules/`를 바꾼 PR은 `terraform-plan.yml`이 바뀐 스택만 plan해 요약(리소스 주소와 동작, 값 없음)을 PR 댓글로 남긴다. Environment `terraform-plan` 승인 뒤 돈다(공개 저장소라 승인 없이는 AWS 자격을 주지 않는다). plan은 기본 변수값으로 돌므로 켜 둔 토글(`k6_enabled` 등)은 차이로 나온다
- 인프라(`envs/`) 적용은 머지 뒤 `terraform-apply.yml`을 main에서 수동 실행한다(스택, PR 댓글의 기대 개수 `추가,변경,삭제`, 필요하면 `-var` 값). Environment `terraform-apply` 승인 뒤 새로 plan하고, 개수가 기대와 다르면 적용하지 않는다. `envs/loadtest`를 뺀 모든 스택이 대상이다. 로컬 apply는 `envs/account`·`envs/ci`·`envs/dev`를 처음 만들 때([처음 구축하는 순서](#처음-구축하는-순서)), CI가 안 될 때, `envs/loadtest`(`loadtest/lt.sh`가 띄우고 지운다), 런북의 복구 절차(NAT 방식 되돌리기, DB 복원 되돌리기)에서만 한다. 관측 서버 설정(`observability/`)과 수집기 설정(`app-agent/`)은 main에 머지되면 GitHub Actions가 배포한다(개발 추천 배치 서버는 교체해서 반영하고, 운영 서버는 부팅 때 받는다). 같은 리소스를 두 주체가 관리하지 않는다
- 컨테이너 이미지는 `이름:버전@sha256:…`으로 고정한다. 태그는 레지스트리에서 다른 이미지로 옮겨질 수 있어서, 버전은 사람이 읽는 표기로 남기고 실제로는 digest로 받는다. `observability/`·`app-agent/`의 compose와 GitHub Actions는 Dependabot PR로 갱신을 받는다. 그 밖의 이미지(`ci.yml`의 actionlint·tflint·checkov·gitleaks, `envs/prod/app.tf`의 k6, `loadtest/agent/lt-app.sh`의 MySQL·Valkey 클라이언트)와 tflint AWS 규칙 플러그인(`.tflint.hcl`), Python 개발 의존성(`requirements-dev.txt`)은 직접 올리고, 버전과 digest를 함께 바꾼다. digest는 `docker buildx imagetools inspect 이름:버전`의 `Digest` 값이다
- PR마다 `ci.yml`이 검사하고, main 룰셋의 필수 검사로 걸어 둔다. 설정 검증은 compose에 고정된 이미지로 실행한다
  - `terraform`: `terraform fmt -check`, `tflint`(`envs/`·`modules/` 전체, Terraform 권장 규칙 + AWS 규칙), `envs/` 아래 각 환경(`ci`·`security` 포함)의 `init -backend=false`·`validate`
  - `config`: compose 해석, Alloy `validate`, `promtool check config`, Loki `-verify-config`, 대시보드 JSON 형식·uid 중복, `nginx -t`
  - `lint`: `shellcheck`(배포 스크립트, 서버 첫 부팅 스크립트는 Terraform 변수를 채운 모습으로 펼쳐서), Python 문법(`py_compile`), 부하 테스트 시나리오 형식(`ltrun.py check`), `actionlint`(워크플로)
  - `test`: pytest(경보 진단 Lambda, 이미지 정규화 Lambda, 부하 테스트 실행기·`lt.sh`). 로컬은 `pip install -r requirements-dev.txt` 뒤 `python -m pytest`
  - `security`: `checkov`(Terraform. 받아들인 규칙은 `.checkov.yaml`에 근거와 함께 skip, 근거를 정하지 않은 규칙은 경고만, 그 밖의 규칙은 실패), `gitleaks`(전체 이력, 값은 가려서 출력)
- 협업 규칙은 조직 CONTRIBUTING을 따른다. 개발·운영은 브랜치가 아니라 `envs/` 스택으로 나누고 관측 서버·수집기 설정은 두 환경이 같이 쓰므로, `develop` 없이 `main`으로 PR을 보낸다

## 처음 구축하는 순서

스택은 서로를 이름으로 찾으므로 이 순서로 만든다. 처음 만드는 `envs/account`·`envs/ci`·`envs/dev`는 로컬(관리자 IAM 사용자)에서, 그 뒤 변경은 모두 `terraform-apply.yml`로 적용한다.

1. 상태 버킷([bootstrap/README.md](../bootstrap/README.md), 콘솔)
2. `envs/account`
   - 예산 알림 메일을 Parameter Store `/cking/account/BUDGET_EMAIL`(String)에 넣는다
   - 영역만 먼저 만든다: `terraform apply -target=aws_route53_zone.main`
   - 출력 `route53_name_servers`를 가비아의 `cking.co.kr` 네임서버로 바꾼다. 인증서 DNS 검증은 위임이 끝나야 통과한다. 위임은 `dig +norec NS cking.co.kr @c.dns.kr`의 권한 영역(AUTHORITY SECTION, `+short`는 비어 나온다)에 새 네임서버가 나오면 끝난 것이다
   - 위임이 끝난 뒤 전체를 적용한다: `terraform apply`. 인증서 두 장이 발급될 때까지 기다린다. 위임 전에 시작해 검증이 시간 초과(1시간 15분)로 끝난 인증서는 위임 뒤에도 발급이 늦다(2026-11-08 14분 넘게 대기, 새로 만든 인증서는 1분 36초). 쓰는 곳이 없는 첫 구축이면 `terraform apply -replace=aws_acm_certificate.regional -replace=aws_acm_certificate.cloudfront`로 새로 만든다
3. `envs/ci`. 그다음 GitHub 저장소에 Environment `terraform-plan`·`terraform-apply`(승인자, apply는 main만)를 둔다
4. [개발 환경](#개발-환경)
5. [운영 환경](#운영-환경)
6. [계정 보안 기준선](#계정-보안-기준선)(운영 경보 SNS를 쓰므로 운영 뒤)
7. 부하 테스트 IAM·결과 버킷 `envs/loadtest-base`([수동 실행](../loadtest/README.md#수동-실행) 1번)

## 개발 환경

1. Parameter Store에 값을 넣는다. 비밀값은 SecureString이다
   - `envs/dev` plan 전에 있어야 하는 값: `/cking/dev/monitoring/ALERT_EMAIL`(String, 경보 메일), `/cking/dev/monitoring/GOOGLE_OAUTH_CLIENT_ID`(String), `/cking/dev/monitoring/GOOGLE_OAUTH_CLIENT_SECRET`(Grafana Google 로그인, ALB 규칙에 들어간다)
   - 앱 서버가 배포 때 읽는 `/cking/dev/` 값은 BE `deploy/deploy.sh`의 필수 목록이다. `DB_PASSWORD`는 앱 계정(`cking_app`) 비밀번호다. `COMMENT_FILTER_BASE_URL`은 적용 뒤 `terraform output comment_filter`의 함수 URL을 넣는다
   - 관측 서버(`/cking/dev/monitoring/`)·추천 배치 서버(`/cking/dev-recommendation/`)가 읽는 나머지 값
   - Terraform이 만드는 값: `/cking/dev/DB_HOST`, `/cking/dev/DB_USERNAME`, `/cking/dev/IMAGE_PIPELINE_RESULTS_QUEUE_URL`, `/cking/dev/monitoring/AI_ACTION_APPROVERS`, `/cking/dev-recommendation/CKING_BE_URL`·`CKING_TAG_DAILY_CALLS`
2. 댓글 필터 함수는 ECR의 가장 최근 이미지로 만들어지므로 두 번에 나눠 적용한다(로컬)
   - 배포 버킷과 필터 이미지 저장소만 먼저 만든다: `terraform apply -target=aws_s3_bucket.deploy -target=aws_ecr_repository.comment_filter`
   - 필터 모델을 배포 버킷 `filter/models/<모델 이름>/best/`에 올리고(필터 저장소 CI가 이미지를 빌드할 때 읽는다), 필터 이미지를 ECR에 올린다. 필터 저장소 CI 역할은 전체 적용에서 만들어지므로 첫 이미지는 로컬에서 CI와 같은 순서로 올린다: 필터 저장소 develop 최신 커밋에서 `scripts/build-image.sh filter:check` → `scripts/check-image.sh filter:check`(필터 저장소 README "배포", Docker·`jq` 필요) → `cking-comment-filter:<커밋 12자리>`로 푸시. 필터 CI는 개발 Lambda의 이미지 태그를 커밋으로 읽어 이력을 비교하므로, 태그가 커밋이 아니면 다음 개발 배포가 멈춘다
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
4. BE·FE develop 배포를 실행한다. BE CI는 앱 서버를 `Name` 태그 `dev-cking-app`으로, FE CI는 사용자 앱·관리자 앱 배포를 도메인으로 찾는다
5. 관측 설정과 수집기를 배포한다: `deploy-observability.yml`, 그다음 `deploy-app-agent.yml`(수집기는 앱 compose 네트워크에 붙으므로 첫 BE 배포 뒤)
6. 추천 배치·필터 저장소의 develop 배포를 실행한다. 추천 배치 서버는 부팅 때 관측 버킷의 수집기 설정(`app-agent/`)을 받아 실행하므로 5번 뒤에 한다(없으면 부팅 스크립트가 실패해 시작 대기에서 버려지고, 교체가 20분 시간 초과로 실패한다). 필터 저장소 CI는 2번에서 올린 이미지를 같은 태그로 받아 확인하고 개발 Lambda를 바꾼다

## 운영 환경

1. `envs/prod-base`를 `terraform-apply.yml`로 적용한다. 처음 한 번만 하고, 운영 환경을 지워도 남긴다
2. 비밀값은 Parameter Store에 SecureString으로 넣는다. 앱은 `/cking/prod/`, 추천 배치 서버는 `/cking/prod-recommendation/`, 감시용 서버는 `/cking/prod-monitor/`(Redis 감시 전용 사용자)이며 각 역할은 자기 경로만 읽는다
   - `envs/prod` plan 전에 Redis 비밀번호 두 개가 있어야 한다(Terraform이 읽어 ElastiCache 사용자에 넣고 상태 파일에는 남기지 않는다): `/cking/prod/REDIS_PASSWORD`, `/cking/prod-monitor/REDIS_PASSWORD`. 16\~128자, `,` `"` `/` `@` 제외
   - RDS 마스터 비밀번호는 RDS가 Secrets Manager에 만들고 교체하므로 넣지 않는다
   - 비밀 쿠키 게이트 값 `/cking/prod/GATE_SECRET`(`openssl rand -hex 24`). Terraform이 읽어 CloudFront 함수(웹·관리자)와 API WAF 규칙에 넣으므로 상태 파일에 남는다. 팀원 입장 주소는 `https://cking.co.kr/?gate=<값>`이고 30일 쿠키가 생긴다. 정식 오픈 때 `gate_enabled`를 끈다
3. `envs/prod`를 `terraform-apply.yml`로 적용한다. 비밀이 아닌 값은 Terraform이 만든다: `/cking/prod/`의 `DB_HOST`, `DB_USERNAME`, `REDIS_HOST`, `REDIS_USERNAME`, `COMMENT_FILTER_BASE_URL`, `IMAGE_PIPELINE_RESULTS_QUEUE_URL`(`image_pipeline_enabled`일 때), `/cking/prod-monitor/`의 `REDIS_HOST`·`REDIS_USERNAME`, `/cking/prod-recommendation/`의 `CKING_BE_URL`·`CKING_TAG_DAILY_CALLS`
   - Amazon Q에 Slack 워크스페이스를 연결하지 않은 계정에서는 `-var` 값 `slack_alerts_enabled=false`로 적용한다(운영 경보 SNS의 메일·경보 진단 구독은 그대로). 연결은 콘솔 OAuth로만 된다
   - 이미지 정규화 함수는 임시 코드로 만들어진다. 적용 뒤 Actions `deploy-image-normalizer`를 main에서 실행한다(운영 job은 저장소 변수 `IMAGE_NORMALIZER_PROD=true`일 때). 댓글 필터 함수는 ECR의 가장 최근 이미지로 만들어진다
   - 추천 배치 서버는 배치 저장소 main의 첫 운영 배포 전까지 배포 버전 값이 없어 시작 대기에서 버려지기를 반복한다. 켜는 순서는 [추천 배치 서버](runbooks/recommendation-batch.md#운영에서-다른-점)
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
5. BE `main`에 머지해 운영 배포를 실행한다. BE CI가 배포 파일을 운영 배포 버킷에 올리고 `/cking/prod/RELEASE_TAG`를 바꾼 뒤 앱 서버 교체를 시작한다. 그 전까지 앱 서버는 배포 태그나 DB 계정이 없어 시작 대기에서 버려지고 다시 뜨기를 반복한다. 그래서 3단계 적용은 앱 서버가 정상이 될 때까지 기다리지 않게 해 두었다
   - 프론트는 FE `main`에 머지해 배포한다. FE CI가 운영 주소로 웹·관리자를 빌드해 각 버킷에 동기화하고 캐시를 무효화한다. 배포 ID는 FE CI가 도메인(`cking.co.kr`, `admin.cking.co.kr`)으로 찾으므로 운영을 다시 만들어도 FE를 고치지 않는다. 버킷 이름과 배포 ID는 `terraform output cdn`
6. 배포 실패와 되돌리기
   - 새 서버는 시작 대기 동안 같은 태그의 `smoke.js`로 자기 자신을 검사하고 통과해야 ALB에 붙는다. 검사에 실패한 서버는 버려지고 교체가 실패로 끝난다. 옛 서버가 남고 배포 태그가 자동으로 되돌아간다
   - 교체 뒤 ALB 경로 스모크가 실패하면 BE CI가 이전 태그로 한 번 자동 교체하고 다시 검사한다
   - 스모크가 잡지 못한 문제는 BE Actions의 `Deploy to prod` 워크플로를 `main`에서 예전 태그로 실행해 되돌린다
   - 이 절차는 `envs/prod-base`의 앱 역할(시작 대기 끝내기 권한)이 먼저 적용되어 있어야 한다
7. 운영 부하 테스트: `envs/prod`를 `terraform-apply.yml`로 `-var` 값 `k6_enabled=true rds_monitoring_interval=1`과 함께 적용해 k6 서버(`prod-cking-k6`)를 만들고 RDS Enhanced Monitoring을 1초로 바꾼다. 끝나면 두 값 없이 다시 적용해 k6 서버를 지우고 60초로 되돌린다. 간격 변경은 재부팅 없이 적용된다. 1초를 켜 두면 수집 비용이 월 약 \$16이라 반드시 되돌린다. 실행 절차는 BE `docs/operations/loadtest.md`의 "운영에서 실행"
8. NAT 방식(인스턴스·게이트웨이)을 바꾸는 절차는 런북 [운영 NAT](runbooks/prod-nat.md#방식-바꾸기)

## 계정 보안 기준선

1. `envs/prod`를 먼저 적용한다. 운영 경보 SNS가 `rule/cking-security-*` 이벤트 규칙의 발행을 허용해야 GuardDuty 경보가 들어간다
2. `envs/security`를 `terraform-apply.yml`로 적용한다
3. Security Hub 검사 결과는 켠 뒤 하루 안에 채워진다. 지적 사항은 고칠 것과 받아들일 것으로 나눈다. 받아들인 것은 이유와 함께 `triage.tf`에 넣어 억제한다. 새 리소스가 이름·태그로 좁힌 규칙에 맞지 않으면 다시 판단한다
4. 서울 기본 VPC는 지웠다(2026-10-29). 쓰는 리소스가 없었고, 지워 두면 서브넷을 빠뜨리고 만든 서버가 공인 IP를 달고 뜨는 일을 막는다. 필요하면 `aws ec2 create-default-vpc`로 다시 만든다. 다른 리전의 기본 VPC는 쓰지 않는 리전이라 그대로 둔다
5. 비용: GuardDuty·Security Hub는 처음 30일 무료 체험이고, 그 뒤 금액은 체험 기간 사용량으로 확인한다. CloudTrail 첫 관리 이벤트 추적은 무료(버킷 저장 비용만), Config는 기록한 설정 항목 수에 비례한다

## 지울 때

스택은 만든 순서의 반대로 하나씩 지운다. 뒤 스택이 앞 스택의 리소스를 이름으로 조회하므로 동시에 돌리면 조회가 실패한다.

1. 배포를 끈다. 앱 저장소(BE·FE 등)의 저장소 변수 `DEPLOY_ENABLED`를 지우고 이 저장소의 배포·Terraform 워크플로를 끈다. 지우는 동안 배포가 돌지 않게 한다
2. Terraform이 지우지 못하게 막아 둔 것을 먼저 정리한다
   - 운영 RDS는 삭제 방지를 끈다. 마지막 스냅샷을 남기지 않으려면 운영·개발 RDS를 직접 지운다(개발 RDS는 `prevent_destroy`가 걸려 있어 상태에서 뺀 뒤 지운다)
   - `prevent_destroy`가 걸린 EBS(관측 서버 데이터, 추천 배치 상태 2개)와 Route53 영역은 `terraform state rm`으로 상태에서 빼고 직접 지운다
   - 버킷을 비운다. ALB 로그·관측·감사 버킷은 destroy 중에도 다시 차므로 `BucketNotEmpty`가 나면 비우고 다시 돌린다
3. `envs/loadtest`가 있으면 `loadtest/lt.sh down`으로 먼저 지운다
4. `envs/security` → `envs/prod` → `envs/prod-base` → `envs/dev` → `envs/loadtest-base` → `envs/ci` → `envs/account` 순서로 `terraform destroy`
   - `envs/security`: Inspector 끄기가 시간 초과로 끝나면 상태가 `DISABLED`가 된 뒤 다시 돌린다
   - `envs/dev`: 댓글 필터 ECR에 이미지가 남아 있으면 지운다. CloudFront 요금제 구독 해지가 429로 실패하면 다시 돌린다
5. Parameter Store `/cking/*`를 지운다(사람이 넣은 비밀값은 Terraform이 지우지 않는다)
6. Terraform 밖에서 생긴 것을 지운다: 서비스 연결 역할, RDS가 만든 `RDSOSMetrics` 로그 그룹, 스냅샷 정책이 남긴 EBS 스냅샷
7. 리전 전체를 조회해 남은 리소스가 없는지 확인한 뒤 상태 버킷을 지운다

## 요구 사항

- Terraform 1.16 이상, AWS CLI, Session Manager 플러그인
- 앱 DB 계정을 만들 때 `mysql` 클라이언트와 `python3`
- 댓글 필터 첫 이미지를 올릴 때 Docker와 `jq`
