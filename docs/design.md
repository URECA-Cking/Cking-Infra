# 크킹 인프라 설계서

크킹(이벤트 응모·추첨 플랫폼)의 AWS 인프라 구성과 결정, 그 근거를 정리한다. 기준은 이 저장소 main의 코드다. 애플리케이션 내부 설계는 다루지 않는다. 측정 상세는 [`loadtest.md`](loadtest.md)·[`gameday.md`](gameday.md), 경보 대응은 [`runbooks/`](runbooks/README.md)에 있다.

- 리전: `ap-northeast-2`(서울)
- 마지막 운영 릴리스: BE·FE v1.3.0(2026-10-29). 그 뒤 들어간 변경은 운영에 배포하지 않았다

## 1. 구성 한눈에

```
사용자 앱  cking.co.kr ─────────┐
관리자 앱  admin.cking.co.kr ───┼→ CloudFront → S3 (OAC, 퍼블릭 차단)
프로필 이미지 images.cking.co.kr ┘

API  api.cking.co.kr
  → ALB (HTTPS, WAF 차단 모드)                         [퍼블릭 2a·2b]
      → 앱 서버 오토스케일링 c6g.large 2~4대            [프라이빗 앱 2a·2b]
          → RDS MySQL 8.4 db.t4g.small 다중 AZ          [프라이빗 데이터]
          → ElastiCache Valkey 7.2 주·복제, TLS          [프라이빗 데이터]
          → 댓글 필터 Lambda (함수 URL, IAM 서명)
          → NAT 인스턴스 (AZ마다) → 외부 API

이미지 업로드
  브라우저 → 앱: 예약 → 사전 서명 PUT으로 S3 raw/ 직접 업로드
  → S3 이벤트 → SQS → 정규화 Lambda → S3 최종 키 → 결과 SQS → 앱

추천 배치 서버 (1대, 상태 디스크) → NAT → api.cking.co.kr 내부 API
감시용 서버 (1대) → ElastiCache 지표 수집, RDS 접속 경유지
운영 수집기 ──VPC 피어링──→ 관측 서버 (Prometheus·Loki·Grafana, 개발·운영 공통)
```

| 흐름 | 경로 | 핵심 |
|---|---|---|
| 응모 | ALB → 앱 → Valkey Lua(차감·기록) → 응답 → Redis Stream → 소비자 → RDS | 응답은 Redis까지, DB 반영은 비동기. DB가 끊겨도 응모를 받고 나중에 따라잡는다 |
| 조회·관리 | ALB → 앱 → RDS | 앱은 상태를 두지 않아 서버 수와 무관(OAuth 인가 요청은 Redis) |
| 이미지 | 브라우저 → S3 직접, 처리는 Lambda | 원본 바이트와 정규화가 앱을 거치지 않는다(6절) |
| 댓글 필터 | 앱 → Lambda 함수 URL | 댓글 저장 뒤 앱 안 대기열(100건)에서 IAM 서명으로 호출. 대기열이 차거나 호출이 실패하면 PENDING으로 남겨 재필터링이 처리 |
| 추천 배치 | 배치 서버 → 외부 LLM API → 앱 내부 API | 타이머 실행, 처리 기록은 상태 디스크 |

## 2. 환경

| 환경 | Terraform 스택 | 구성 |
|---|---|---|
| 계정 공용 | `envs/account` | Route53 영역 `cking.co.kr`, `*.cking.co.kr` 인증서(서울·us-east-1), GitHub OIDC 공급자, 월 예산. 다른 스택은 이름으로 찾는다 |
| CI | `envs/ci` | Terraform plan·apply 역할(GitHub OIDC, Environment 승인) |
| 보안 기준선 | `envs/security` | CloudTrail, GuardDuty, Config, Security Hub, Access Analyzer |
| 개발 | `envs/dev` | 앱 서버 1대(t4g.small, 앱과 Redis 컨테이너), RDS db.t4g.micro 단일 AZ, ALB, 사용자·관리자 앱 CloudFront, 관측 서버, 추천 배치 서버(스팟), 댓글 필터·이미지 정규화 Lambda. 운영·부하 테스트·보안 기준선 스택이 개발 VPC·ALB·관측 서버 등을 이름으로 찾아 쓰므로 먼저 적용한다 |
| 부하 테스트 | `envs/loadtest`, IAM은 `envs/loadtest-base` | 측정 때만 만들고 지운다. 앱 서버·RDS는 개발과 같은 사양, k6 서버 c7g.medium |
| 운영 IAM | `envs/prod-base` | 운영 서버·배포 역할. 운영 본체보다 먼저 적용하고 본체를 지워도 남긴다 |
| 운영 | `envs/prod` | 1절 구성. 별도 VPC `10.1.0.0/16` |

- 공용 모듈: `modules/api-waf`(개발·운영 API WAF), `modules/k6-server`(부하 테스트·운영 k6 서버)
- 이름은 환경 접두어(`dev-cking-*`, `prod-cking-*`, `loadtest-cking-*`)와 Parameter Store 경로(`/cking/dev/`, `/cking/prod/` 등)로 나눈다
- 운영 IAM을 본체와 나눈 이유: 같은 apply로 역할과 서버를 만들면 역할이 전파되기 전에 서버가 부팅해 SSM 에이전트가 자격 증명을 받지 못한다

## 3. 네트워크

| 항목 | 개발 | 운영 |
|---|---|---|
| VPC | `10.0.0.0/16`, 2 AZ | `10.1.0.0/16`, 2 AZ |
| 서브넷 | 퍼블릭·프라이빗 | 퍼블릭, 프라이빗 앱, 프라이빗 데이터 각 `/20` × 2 |
| 서버 위치 | 퍼블릭(공인 IP) | 프라이빗 앱 |
| 외부 통로 | 인터넷 게이트웨이 | AZ마다 NAT 인스턴스 t4g.nano |
| S3 | 게이트웨이 엔드포인트 | 게이트웨이 엔드포인트 |

- **개발 서버를 퍼블릭에 둔 이유:** 프라이빗에 두려면 NAT Gateway(월 약 $43) 또는 SSM 인터페이스 엔드포인트 3종(월 약 $48)이 필요하다. 들어오는 포트는 보안 그룹으로 ALB에서만 연다
- **운영 NAT를 AZ마다 둔 이유:** 한 AZ가 멈춰도 다른 AZ 서버의 외부 호출(배포, AI API)이 이어진다
- **NAT Gateway 대신 NAT 인스턴스(Infra #212):** 응답 시간 차이가 없었고(평균 0.024 → 0.022\~0.023초), 재부팅 시 그 AZ만 약 10초 끊기며, 월 약 $77 줄었다($86 → $9). 대가는 OS 패치·재부팅 관리다. 전달 서비스 상태를 1분마다 지표로 보내 경보를 건다(Infra #261). 트래픽이 기본 대역폭(약 32Mbps)에 가까워지면 `nat_mode = "gateway"`로 돌린다
- `/20` 서브넷은 컨테이너별 IP를 쓰는 ECS·EKS로 옮길 때의 여유다

## 4. 컴퓨팅

| 대상 | 운영 | 근거 |
|---|---|---|
| 앱 서버 | 오토스케일링 c6g.large 최소 2·최대 4, 확장 지표 ALB 대상당 요청 수(서버당 분당 6,300건), 그룹 헬스 체크 ELB | 최소 2대로 AZ 하나가 멈춰도 서비스. 확장 지표 근거는 12절 |
| 앱 컨테이너 | 힙 1,200MiB, 컨테이너 상한 1,800MiB | GC 뒤 남는 데이터 최대 367MiB의 3\~4배, 힙 밖 약 450MiB + 30%(BE #767) |
| 추천 배치 서버 | 오토스케일링 1대 t4g.small 온디맨드, 상태 디스크 10GB(2a) | 처리 기록을 상태 디스크에 둬 서버를 바꿔도 이어진다. 회수로 실행이 끊기지 않게 운영은 온디맨드(개발은 스팟) |
| 감시용 서버 | 오토스케일링 1대 t4g.micro | ElastiCache 지표 수집, RDS 접속 경유지(SSM 포트 포워딩) |
| 댓글 필터 | Lambda 컨테이너 arm64, 2,048MB, 제한 120초, 예약 동시성 8(개발 2) | 함수 URL IAM 인증, 앱 역할만 호출 |
| 이미지 정규화 | Lambda arm64, 1,536MB, 제한 60초, 예약 동시성 5, SQS 연결 최대 동시성 5 | 처리량 상한 초당 약 7\~8건(6절) |

- 모든 서버는 ARM(Graviton)이다. 이미지를 CI에서 `linux/arm64`로 빌드해 개발자 머신 아키텍처와 무관하다
- 접속은 SSM Session Manager만 쓴다. 22번 포트와 키 페어가 없다
- IMDSv2 전용, 응답 홉 2(앱 컨테이너가 Docker 브리지를 한 번 더 거쳐 역할 자격 증명을 받는다)
- 개발 앱 서버는 t4g.small 1대에 앱과 Redis를 함께 둔다(힙 460MiB·컨테이너 상한 1,000MiB)

## 5. 데이터

### 5.1 RDS MySQL

| 항목 | 운영 | 근거 |
|---|---|---|
| 클래스 | db.t4g.small 다중 AZ | 비버스터블 db.m6g.large는 월 약 $153(단일 AZ) vs $37. RDS 매시 관리 작업(약 2초)은 남아 정각 응모가 최대 253ms까지 늦지만 SLO 안이다(12절) |
| 스토리지 | gp3 20GiB, 자동 확장 상한 100GiB | 축소가 안 되므로 최소로 시작하고 폭주를 상한으로 막는다 |
| 백업 | 자동 백업 14일·시점 복구, 삭제 방지, 마지막 스냅샷 | |
| 연결 | TLS 강제(`require_secure_transport`), 앱 전용 계정(스키마 권한만) | 마스터 비밀번호는 RDS가 Secrets Manager에서 관리 |

- 개발은 db.t4g.micro 단일 AZ, 자동 백업 7일이다. 연결 방식(TLS 강제, 앱 전용 계정, 마스터 비밀번호 Secrets Manager 관리)은 운영과 같다

### 5.2 ElastiCache Valkey

| 항목 | 운영 | 근거 |
|---|---|---|
| 구성 | Valkey 7.2 cache.t4g.small 2노드(주 2a·복제 2b), 자동 장애 조치, 클러스터 모드 끔 | 응모 Lua가 여러 키를 함께 쓴다 |
| 크기 | small | 마감 몰림(초당 150) 지속 시 데이터 메모리 사용률 계산값 micro 65\~85%, small 25\~30% |
| 정책 | noeviction, TLS, 사용자 인증, 스냅샷 7일 | 잔액 키가 축출되면 안 된다 |
| 복제 확인 | 응모 성공 응답 전 `WAIT 1 250`, 확인 못 해도 성공 응답(BE #725) | 운영 측정 복제 대기 최대 117.7ms의 약 2배. 복제 노드가 없으면 응모마다 250ms를 다 기다린다([`gameday.md`](gameday.md) 4절) |

### 5.3 백업·복구 훈련

운영에서 실제로 복원해 시간과 손실 범위를 쟀다(런북 [`prod-db-restore.md`](runbooks/prod-db-restore.md)).

| 항목 | 결과 |
|---|---|
| RDS 특정 시점 복원 | 15분 24초 |
| 앱 전환(`DB_HOST` 변경 + 서버 교체) | 10분 41초, API 실패 0 |
| 장애 선언 → 복원 DB로 서비스 | 27분 14초 |
| 데이터 손실 범위 | 최대 약 6분(트랜잭션 로그가 약 5분마다 올라감) |
| 다른 리전(도쿄) 스냅샷 복사 + 복원 | 1분 36초 + 7분 46초 |

- 목표 RPO 5분·RTO 30분. 다중 AZ는 AZ·하드웨어 장애를, 이 절차는 잘못된 쓰기·삭제 같은 논리 장애를 다룬다
- Valkey가 통째로 사라지면 스냅샷 복원 대신 비운 채로 다시 시작해 DB 기준으로 잔액 키를 채운다. 스냅샷의 낡은 잔액 키가 "있는 상태"로 남으면 다시 채우지 않기 때문이다

## 6. 이미지 업로드 파이프라인

```
1. 브라우저 → 앱      POST /api/uploads (용도·크기·형식) → 사전 서명 PUT 주소
2. 브라우저 → S3      raw/<최종 키>에 PUT (서명에 크기·형식이 들어가 다르면 S3가 거부)
3. S3 이벤트 → SQS 작업 큐 → 정규화 Lambda → 최종 키 (조건부 쓰기)
4. Lambda → SQS 결과 큐 → 앱 소비자 (READY·FAILED 기록)
5. 브라우저 → 앱      GET /api/uploads/{id} (간격을 점점 늘려 확인)
```

- **바꾼 이유:** 앱 안에서 정규화하면 개발 서버에서 초당 2건부터 앱 컨테이너가 메모리 초과로 죽고, 업로드와 무관한 조회도 약 30%가 502였다. 바꾼 뒤 16건/초에서도 OOM·502가 0이었다([`loadtest.md`](loadtest.md) 3.5)
- **처리 한계:** Lambda 동시 5에서 초당 약 7\~8건. 넘으면 실패하지 않고 큐에서 기다린다. 동시성은 큐 대기(가장 오래된 메시지)가 30초에 가까워지면 올린다. 이미지 1,000장당 약 $0.009라 동시성을 올려도 쉬는 비용은 없다
- 실패는 작업·결과 큐마다 DLQ와 경보, 원본이 올라오지 않은 예약은 정리 스케줄러가 만료 처리
- 원본(`raw/`)은 수명 주기로 1일 뒤 삭제

## 7. 보안

| 대상 | 방식 |
|---|---|
| 네트워크 | 보안 그룹을 보안 그룹 참조로 연결(ALB → 앱 8080 → RDS·Valkey). 22번 없음 |
| API 앞단 | WAF(`modules/api-waf`): AWS 관리형 규칙, 업로드 본문 검사 예외, 로그(토큰·쿠키 가림). 개발은 세기만, 운영은 차단. 운영 NAT IP는 규칙을 건너뛴다. IP당 요청 상한은 모듈에 있지만 두 환경 모두 켜지 않았다 |
| 오픈 전 접근 | 비밀 쿠키 게이트: 웹·관리자는 CloudFront Function, API는 WAF가 쿠키·헤더가 없으면 403(Infra #204·#216). 오픈하는 날 `gate_enabled = false` |
| ALB | 운영은 Host가 `api.cking.co.kr`일 때만 앱으로, 나머지는 404(Infra #257). 개발·운영 모두 헬스체크는 앱 생존만 보는 `/livez`, `/livez`·`/readyz`는 외부에서 막는다 |
| 정적 파일 | S3 퍼블릭 차단 + CloudFront OAC. 프로필 이미지 경로만 CDN으로 공개, 나머지 이미지는 앱이 권한을 확인한 뒤 사전 서명 GET |
| 비밀값 | Parameter Store SecureString. 서버가 배포 때 직접 읽고 Actions를 거치지 않는다. 저장소·로그·이미지에 두지 않는다 |
| CI 인증 | GitHub OIDC, 저장소·브랜치별 역할. 액세스 키 없음 |
| 서버 권한 | 경로 단위 S3 권한, 필요한 동작만. 관측 서버는 받기 전용 관문(nginx)만 연다 |
| Grafana | ALB Google 로그인 + Grafana 역할 매핑 엄격 모드(목록에 있는 메일만) |
| 계정 기준선 | CloudTrail(전 리전, 1년), GuardDuty(높음 이상 경보), Config, Security Hub FSBP, Access Analyzer, EBS 기본 암호화, S3 계정 퍼블릭 차단, 흐름 로그, Inspector. 받아들인 지적은 이유를 단 억제 규칙으로 |

## 8. 배포

| 대상 | 방식 |
|---|---|
| BE 개발 | develop push → 테스트·마이그레이션 검사·lint → ARM 이미지 빌드(GHCR, 불변 태그 `yyyyMMddHHmmss-<SHA>`) → OIDC → S3에 배포 파일 → SSM으로 이름표 `dev-cking-app` 서버의 `deploy.sh` → `/readyz` → k6 스모크 |
| BE 운영 | main push → 빌드 → 서버 교체: 새 서버가 같은 태그로 뜬 뒤 스모크로 자기 검사를 통과해야 ALB에 들어가고 옛 서버를 뺀다. 실패하면 새 서버를 버리고, ALB 경로 스모크가 실패하면 이전 태그로 한 번 자동 교체 |
| FE | 빌드 → S3 동기화 → CloudFront 무효화. 배포 ID는 도메인으로 찾는다 |
| 댓글 필터·추천 배치 | main에서 다시 빌드하지 않고 개발 CI가 확인한 산출물을 올린다(필터는 이미지 digest 확인, 배치는 sha256·`verified` 확인) |
| 관측 설정·수집기 | main 머지 → S3 → SSM으로 서버의 `apply.sh`(바뀐 서비스만 다시 만듦) |

- 배포 job은 저장소 변수 `DEPLOY_ENABLED`가 `true`일 때만 돈다
- 연속 머지는 취소하지 않고 순서대로 모두 배포하며, 이미 배포된 커밋보다 오래된 커밋은 건너뛴다
- 서버 교체 중에는 옛 서버와 새 서버가 같은 DB를 쓴다. 그래서 PR에서 대상 브랜치 코드가 새 DB 구조에서 도는지 검사하고, Stream 소비자 이름을 서버마다 나누고, 종료 대기 90초를 ALB 등록 해제 대기와 맞춘다
- 운영 릴리스는 develop → main PR, 머지 뒤 `vX.Y.Z` 태그

## 9. 관측

| 항목 | 구성 |
|---|---|
| 수집 | 서버마다 Alloy가 지표(앱·서버·Redis·자체)와 Docker 로그를 관측 서버로 보낸다(push). 끊기면 지표는 디스크에 쌓았다가, 로그는 무한 재시도로 보낸다 |
| 저장 | Prometheus 90일(상한 6GB, 데이터 EBS, 하루 1회 스냅샷), Loki 14일(S3) |
| 화면 | Grafana 대시보드 7개(서비스 개요, 앱, Redis·Stream, 서버, 관측 파이프라인, 로그, 부하 테스트). 환경·서버를 골라 본다 |
| 경보 | Grafana 개발 24개·운영 20개(팀·급함·관측으로 나눠 Slack), CloudWatch(ALB·RDS·Valkey·NAT·EC2 상태·DLQ → SNS → Slack·메일), 데드맨(healthchecks.io) |
| 런북 | 경보마다 [`runbooks/`](runbooks/README.md)(40개). 경보 알림에 링크 |
| 경보 진단 | 경보를 Lambda가 받아 Claude API로 런북을 따라 읽기 전용 조회 후 판단·근거를 같은 채널에 게시. 조치는 승인 버튼으로만 |

- 개발·운영이 관측 서버 하나를 쓴다. 운영 수집기는 VPC 피어링으로 보낸다
- 관측 서버 자체는 컨테이너 재시작, EC2 상태 검사 자동 복구, 데드맨 세 겹으로 감시한다
- 자체 운영을 고른 근거는 12절

## 10. IaC와 CI

- 상태: S3 버킷(버전 관리, S3 잠금). 상태 버킷은 Terraform보다 먼저 있어야 해 콘솔로 만들었다
- Terraform 밖에 두는 것: 상태 버킷, 사람 IAM 사용자·그룹, 비밀값(사람이 Parameter Store에 넣음), 등록기관(가비아) 네임서버 위임
- 적용 순서: `envs/account` → `envs/ci` → `envs/dev` → `envs/prod-base` → `envs/prod` → `envs/security`. 계정 공용 리소스와 개발 리소스를 뒤 스택이 이름으로 찾는다. 처음 만드는 `envs/account`·`envs/ci`는 CI 역할이 아직 없어 로컬에서, `envs/dev`는 Lambda 코드를 넣을 배포 버킷이 먼저 있어야 해 로컬에서 두 번에 나눠 적용한다
- **적용 절차:** PR이 `envs/`·`modules/`를 바꾸면 바뀐 스택만 plan해 주소와 동작을 PR 댓글로 남긴다 → 머지 → main에서 apply 워크플로를 수동 실행(스택, 기대 개수) → 승인 → 다시 plan해 개수가 기대와 같을 때만 적용
- **공개 저장소 대응:** plan·apply 역할의 신뢰 조건을 GitHub Environment(승인자 필요, apply는 main만)로 묶었다. Environment를 빼면 OIDC `sub`가 달라져 역할을 받지 못하고, 포크 PR은 토큰을 받지 못한다. plan 결과는 값 없이 주소와 동작만 남긴다. plan 역할은 ReadOnlyAccess에서 데이터 읽기(S3 객체·큐 메시지·로그 등)를 막고, plan이 읽는 SecureString만 복호화한다(Infra #256)
- **PR 검사:** `terraform fmt`·`validate`·tflint, compose 해석, Alloy·Prometheus·Loki·nginx 설정 검사, 대시보드 형식, shellcheck(부팅 스크립트는 템플릿 값을 채워 검사), actionlint, Python 문법, 부하 테스트 시나리오 형식, pytest(경보 진단·부하 테스트 실행기), checkov(받아들인 규칙은 근거와 함께 skip, 근거를 정하지 않은 규칙은 경고만), gitleaks(전체 이력)
- 컨테이너 이미지와 Actions는 digest·SHA로 고정하고 Dependabot으로 갱신한다
- 부하 테스트는 실행기(`loadtest/`)로 자동화했다: 환경 생성 → 앱 배포 → 데이터 되돌리기·시딩 → 시나리오 단계 → 정합성 검증 → 결과 버킷 저장

## 11. 비용

| 항목 | 월 |
|---|---|
| 개발(앱 서버, RDS, ALB, 관측 서버 등) | 약 $91(공시 단가 개산. 이후 추가된 WAF·추천 배치·Lambda는 넣지 않음) |
| 운영 고정비 | $412.9(2026-10-23, AWS 가격 API 기준) |
| 운영 NAT 인스턴스 전환 | 약 −$77 |
| 부하 테스트 환경 | 띄운 시간당 약 $0.11 |
| 이미지 정규화 | 1,000장당 약 $0.009 |

운영 고정비 항목(10-23): EC2 4대 $135.2, NAT Gateway 2개 $86.1(이후 NAT 인스턴스로 약 $9), RDS 다중 AZ $80.0, Valkey 2노드 $54.9, ALB $16.4, 공인 IPv4 $14.6, EBS $10.0, WAF $10.0, CloudWatch $5.2

## 12. 주요 결정과 대안

| 결정 | 대안 | 근거 |
|---|---|---|
| 앱 실행: EC2 + Docker Compose | ECS·EKS | 서버 수가 적고 배포 경로(SSM)를 직접 보이게 다룰 수 있다. 서브넷 `/20`으로 옮길 여유를 둠 |
| 운영 앱 서버 c6g.large | t4g.small | t4g는 정각에 하이퍼바이저 CPU steal(최대 79%)로 정각 응모 API가 1,506ms까지 늘었다. c6g에서 steal 0%, 253ms([`loadtest.md`](loadtest.md) 3.3) |
| RDS db.t4g.small 유지 | db.m6g.large | 월 $37 vs $153. 매시 관리 작업은 남지만, 응모 경로의 DB 읽기를 이벤트 캐시가 빌 때와 첫 프로필 검사로 줄여(BE #707) 정각 응모 지연이 최대 253ms로 SLO 안이다 |
| 확장 지표: ALB 대상당 요청 수 | CPU | c6g는 요청이 초당 75 → 140건으로 늘어도 CPU가 8%p만 올라 처리량을 가늠하지 못한다. 분당 6,300건 = 서버당 초당 105건으로 DB 반영 한계보다 낮게(Infra #173) |
| 응모 DB 반영: 서버당 소비자 4개 | 소비자 1개 | 1개는 초당 약 80\~110건이 한계. 4개로 200\~250건(BE #697) |
| 이미지: S3 직접 업로드 + Lambda 정규화 | 앱 안 정규화 | 6절 |
| NAT 인스턴스 | NAT Gateway | 3절 |
| 관측 자체 운영(Prometheus·Loki·Grafana) | AMP + AMG, CloudWatch | 계산(2026-10-12, 시계열 2,440개): 자체 운영 월 약 $22, AMP + AMG $44\~79, CloudWatch 사용자 지정 지표 약 $732 |
| 운영 배포: 서버 교체 + 자기 검사 + 자동 되돌리기 | 같은 서버 블루·그린 | 서버마다 메모리 여유를 따로 둘 필요가 없고, 서버 구성(user_data) 변경도 같은 방식으로 반영된다 |
| AI 산출물: 개발 산출물 승격 | main에서 다시 빌드 | 개발에서 확인한 것과 같은 바이트를 운영에 올린다 |
| 추천 배치: 패키지 + 서버 1대·타이머 | 컨테이너, ECS Fargate | 패키지 방식으로 격리(독립 Python)·승격(sha256)·사전 검사를 얻는다. 체크포인트·예산·원장 같은 상태 파일이 서버 디스크에 있어, 실행을 서버에서 떼려면 상태부터 밖으로 빼야 한다 |
| 경보 진단: 제안 + 승인 버튼 | 자동 조치 | 잘못된 판단이 바로 조치로 이어지지 않게 한다 |
| Terraform apply 역할: 관리자 권한 + 승인·main 조건 | 최소 권한 정책 | 만드는 리소스 종류가 많아 최소 권한 정책이 커지고 자주 깨진다. 승인자와 main 브랜치로 실행 자체를 막는다 |
| 운영이 개발의 관측 서버·버킷·경보 진단·상태 버킷을 함께 씀 | 운영 전용 한 벌 | 운영용으로 한 벌 더 두는 고정비를 아낀다. 운영 수집기는 VPC 피어링으로 보낸다 |
| ALB 헬스체크: 앱 생존만(`/livez`) | DB·Redis까지(`/readyz`), 또는 `/readyz` + 그룹 헬스체크 EC2 | 공유 의존성 장애에 모든 서버가 비정상이 되고 그룹이 멀쩡한 서버를 교체했다(게임 데이). 대가로 서버 한 대만 DB·Redis가 끊긴 경우는 ALB가 빼지 않는다. `/readyz` + EC2는 그 경우를 빼 주지만 앱이 멈춘 서버의 자동 교체를 잃는다 |
| 개발·운영을 AWS 계정 하나에 둠 | 환경별 계정(Organizations, 계정별 OIDC 역할·상태 버킷) | 계정을 나누면 운영이 개발의 관측 서버·버킷·경보 진단을 함께 쓰는 지금 구조를 계정 간 역할과 피어링으로 다시 짜야 한다. 대신 환경마다 IAM 역할을 따로 두고 운영 서버는 운영 Parameter Store 경로만 읽게 했다 |
| 단일 리전 | 리전 간 백업 복제 | 규모 대비 비용. 리전 장애 시 자동 스냅샷(하루 1회) 기준 손실 최대 약 24시간 |
