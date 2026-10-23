# 런북

경보를 받았을 때 보고 따라 하는 대응 절차. 경보 하나에 파일 하나이며, 파일 이름은 경보 규칙의 uid다. Redis Stream 경보 4개가 함께 보는 내용은 [stream.md](stream.md)에 둔다.

각 런북 맨 위의 `전제`는 그 절차가 맞는 구성이다. 배포 방식·서버 구성·경보 규칙을 바꾸는 PR은 영향받는 런북을 같은 PR에서 고친다.

## 형식

| 항목 | 내용 |
| --- | --- |
| 뜻하는 것 | 경보 조건과 지금 무슨 일이 벌어지고 있는지, 사용자 영향 |
| 먼저 볼 곳 | 원인을 가르는 대시보드·패널, 명령 |
| 원인별 대응 | 원인마다 확인 방법과 조치 |
| 해결 확인 | 풀렸는지 보는 지표·명령 |
| 하면 안 되는 것 | 먼저 떠오르지만 상황을 악화시키는 조치 |

명령에는 실행 위치를 적는다. **Mac**은 AWS 자격 증명이 있는 로컬, **앱 서버**·**관측 서버**·**추천 배치 서버**는 SSM 세션(`aws ssm start-session --target <인스턴스 ID>`) 안이다. SSM 세션 사용자(`ssm-user`)는 docker와 시스템 journal 권한이 없으므로 `docker`·`journalctl`에는 `sudo`를 붙인다. 인스턴스 ID는 이름표로 찾는다.

```bash
# Mac
aws ec2 describe-instances --region ap-northeast-2 --filters Name=tag:Name,Values=dev-cking-app Name=instance-state-name,Values=running \
  --query 'Reservations[0].Instances[0].InstanceId' --output text
```

관측 서버는 `Values=dev-cking-observability`, 추천 배치 서버는 `Values=dev-cking-recommendation`. Grafana는 `https://dev-monitoring.cking.co.kr`.

대시보드는 맨 위 `환경`에서 개발·운영·부하 테스트를 고르고, `서버`는 그 환경의 서버를 여러 대·전체로 고른다. 요청·응답 패널은 고른 서버를 합치고, 스레드·연결·메모리·CPU는 서버별 선으로 본다. Redis·RDS 패널은 서버 선택과 관계없이 그 환경의 것을 본다.

## AI 진단

경보가 울리면 그 경보가 가는 채널에 `AI 진단: <경보 이름>` 메시지가 뒤따른다. Claude(Claude API)가 그 경보의 런북을 읽고 먼저 볼 곳을 읽기 전용으로 조회해 원인과 할 일을 제안한 것이다(`alert-analyzer/`, `envs/dev/alert_analyzer.tf`, `envs/prod/alert_analyzer.tf`). 개발 경보(Grafana, CloudWatch 서버 상태 검사)는 개발 경보 채널, 운영 경보(Grafana, CloudWatch, 서버 띄우기 실패)는 운영 경보 채널로 온다.

- 참고용이다. 조치는 런북과 대조해 사람이 판단한다. 서버 안(SSM 세션)에서만 보이는 것은 조회하지 못한다
- 같은 경보는 한 번만 진단하고(서버 띄우기 실패는 서버 그룹마다 한 시간에 한 번), 개발·운영 각각 하루 12건을 넘으면 그날은 멈춘다(한 번 알린다). 메시지 끝에 조회 횟수·토큰·대략 비용이 붙는다
- 데드맨은 진단하지 않는다
- 진단이 실패하면 `AI 진단 실패` 메시지가 온다. Claude API 크레딧이 떨어지거나 키(`/cking/dev/monitoring/ANTHROPIC_API_KEY`)가 만료돼도 같다. 로그는 CloudWatch Logs `/aws/lambda/dev-cking-alert-analyzer`
- 끄기: Grafana는 `policies.yaml`의 `AI 진단` 경로, CloudWatch는 `envs/dev`·`envs/prod`의 `alert_analyzer.tf` 구독을 지우는 PR. 바로 멈춰야 하면 예약 동시성을 0으로 둔다(다음 `envs/dev` apply가 2로 되돌린다)

```bash
# Mac
aws lambda put-function-concurrency --region ap-northeast-2 --function-name dev-cking-alert-analyzer --reserved-concurrent-executions 0
```

## 경보 목록

### Grafana: 팀 경보 (Slack)

| 경보 | 조건 | 급함 | 런북 |
| --- | --- | --- | --- |
| 앱 중단 | 앱 지표 2분 없음 | `@channel` | [cking-app-down](cking-app-down.md) |
| 서버 오류 증가 | 5xx 비율 5% 초과 5분 (요청 초당 0.1건 이상) | `@channel` | [cking-5xx](cking-5xx.md) |
| Stream 소비 멈춤 | 소비자 idle 120초 초과 | `@channel` | [cking-stream-stopped](cking-stream-stopped.md) |
| Stream 밀림 | lag 0 초과 5분 | `@channel` | [cking-stream-lag](cking-stream-lag.md) |
| 응모 실패 (Redis 쓰기 거부) | 거부 명령 5분 안에 1건 이상 | `@channel` | [cking-redis-rejected](cking-redis-rejected.md) |
| Redis 연결 끊김 | 수집기가 Redis에 1분 붙지 못함(`redis_up` 0) | `@channel` | [cking-redis-down](cking-redis-down.md) |
| 처리 실패 누적 | pending 0 초과 10분 | | [cking-stream-pending](cking-stream-pending.md) |
| 응답 지연 | p95 1초 초과 10분 | | [cking-p95](cking-p95.md) |
| DB 연결 대기 | Hikari 대기 0 초과 5분 | | [cking-hikari-pending](cking-hikari-pending.md) |
| Redis 메모리 | 한도의 70% 초과 10분 | | [cking-redis-memory](cking-redis-memory.md) |
| ERROR 로그 | ERROR 5분 안에 1건 이상 | | [cking-error-log](cking-error-log.md) |
| Dead Stream 이동 | 이동 로그 5분 안에 1건 이상 | | [cking-dead-stream](cking-dead-stream.md) |
| 댓글 필터 호출 실패 지속 | 필터 호출 실패 로그 10분 동안 5건 이상 | | [cking-comment-filter-failing](cking-comment-filter-failing.md) |
| 댓글 판정 대기열 쌓임 | 판정 대기열 50건 이상 5분 | | [cking-comment-filter-queue](cking-comment-filter-queue.md) |
| 추천 배치 실패 반복 | 실패 알림 로그 10분 동안 3건 이상 | | [cking-recommendation-failing](cking-recommendation-failing.md) |
| 추천 배치 멈춤 | 1분 확인 실행 로그 15분 없음 | | [cking-recommendation-stalled](cking-recommendation-stalled.md) |

### Grafana: 관측 경보 (Slack, 인프라 담당 멘션)

| 경보 | 조건 | 런북 |
| --- | --- | --- |
| 수집 대상 끊김 | 앱 서버의 node·redis·alloy 지표 5분 없음 | [cking-target-down](cking-target-down.md) |
| 지표 전송 실패 | 수집기 전송 실패 10분 지속 | [cking-remote-write-failed](cking-remote-write-failed.md) |
| 로그 버림 | 수집기가 로그를 1건 이상 버림 | [cking-log-dropped](cking-log-dropped.md) |
| 관측 프로그램 메모리 | Prometheus·Loki(RSS)·Alloy(Go 런타임 사용량)가 컨테이너 상한의 95% 초과 5분 | [cking-obs-memory](cking-obs-memory.md) |
| Grafana 메모리 | 본체가 GOMEMLIMIT(512MiB)의 95% 초과 10분 | [cking-grafana-memory](cking-grafana-memory.md) |
| 서버 여유 메모리 | 100MiB 미만 10분 | [cking-memory-available](cking-memory-available.md) |
| 디스크 여유 | 20% 미만 10분 | [cking-disk-available](cking-disk-available.md) |

### 경보 경로

| 경보 | 받는 곳 | 런북 |
| --- | --- | --- |
| 데드맨 | healthchecks.io → 인프라 담당 메일 (Grafana 신호 10분 끊김) | [cking-deadman](cking-deadman.md) |

### CloudWatch: 서버 상태 검사 (SNS `dev-cking-alerts` → 인프라 담당 메일)

| 경보 | 조건 | 자동 조치 | 런북 |
| --- | --- | --- | --- |
| `dev-cking-app-system-check`, `dev-cking-observability-system-check` | 시스템 검사 실패 2분 | EC2 기본 자동 복구 | [ec2-system-check](ec2-system-check.md) |
| `dev-cking-app-instance-check`, `dev-cking-observability-instance-check` | 인스턴스 검사 실패 3분 | 재부팅 | [ec2-instance-check](ec2-instance-check.md) |

### 비용

| 경보 | 조건 | 받는 곳 | 런북 |
| --- | --- | --- | --- |
| `cking-monthly` 예산 (AWS Budgets, 콘솔 관리) | 월 $150의 실제 85%($127.5)·100%, 예측 100% | 인프라 담당 메일 | [aws-budget](aws-budget.md) |

### 배포

| 대상 | 알게 되는 곳 | 런북 |
| --- | --- | --- |
| 앱 배포(Cking-BE `cicd.yml`), 관측 설정·앱 서버 수집기 배포(이 저장소) | GitHub Actions 실패 알림 | [deploy-failed](deploy-failed.md) |

### 댓글 필터 (경보 없이 쓰는 절차)

| 상황 | 런북 |
| --- | --- |
| 판정을 바로 멈춰야 할 때(멀쩡한 댓글 BLOCK, 호출을 멈춰야 할 때), 콜드 스타트가 실행 상한에 걸릴 때 | [comment-filter](comment-filter.md) |

### 추천 배치 (경보 없이 쓰는 절차)

| 상황 | 런북 |
| --- | --- |
| 추천 배치 서버(개발·운영)를 처음 띄우거나 값을 바꿀 때, 작업자가 돌지 않을 때, 스팟 회수·자리 부족 확인 | [recommendation-batch](recommendation-batch.md) |

## 운영

운영 경보는 Grafana 폴더 **크킹 운영 경보**에 있고 운영 경보 채널로 간다(급함은 `@channel`, 관측 경보는 인프라 담당 멘션). 규칙 uid는 `cking-prod-<개발 uid>`이며, 같은 이름의 개발 런북과 그 런북의 `운영에서 다른 점`을 함께 본다. 운영에만 있는 경보는 uid 이름의 파일이다.

| | 개발 | 운영 |
| --- | --- | --- |
| 앱 서버 | `dev-cking-app` 1대 | 서버 그룹 `prod-cking-app` 2~4대(AZ 2a·2b). 경보 라벨 `instance=prod-cking-app-<인스턴스 ID>` |
| Redis | 앱 서버 Docker `cking-redis` | ElastiCache Valkey 7.2 `prod-cking-redis`(주·복제, TLS). 지표는 감시용 서버 `prod-cking-monitor`가 보낸다. 접속은 [운영 상태 확인](stream.md#운영-상태-확인) |
| DB | RDS | RDS db.t4g.small 다중 AZ |
| 배포·되돌리기 | `Deploy to dev server` | `Deploy to prod`([배포 실패](deploy-failed.md#운영-앱-배포-cking-be-deploy-to-prod)) |
| 서버 하나의 고장 | 그 서버를 고친다 | 원인을 본 뒤 서버를 교체한다. 새 서버는 자기 검사를 통과해야 요청을 받는다 |
| 대시보드 | `환경` 개발 | `환경` 운영. `서버` 전체가 앱 서버 합계, 한 대를 고르면 그 서버만 |
| 추천 배치 | `dev-cking-recommendation` 스팟 1대(퍼블릭 2a) | `prod-cking-recommendation` 온디맨드 1대(프라이빗 2a, NAT) |

서버 찾기:

```bash
# Mac
aws autoscaling describe-auto-scaling-groups --region ap-northeast-2 --auto-scaling-group-names prod-cking-app \
  --query 'AutoScalingGroups[0].Instances[].[InstanceId,AvailabilityZone,LifecycleState,HealthStatus]' --output table
```

감시용 서버는 `prod-cking-monitor`. 접속은 개발과 같이 `aws ssm start-session --target <인스턴스 ID>`.

서버 교체(대수는 그대로, 그 서버만 새로 띄운다. ALB 해제 대기 90초 동안 진행 중인 요청을 마친다):

```bash
# Mac
aws autoscaling terminate-instance-in-auto-scaling-group --region ap-northeast-2 \
  --instance-id <인스턴스 ID> --no-should-decrement-desired-capacity
```

- 교체 전에 그 서버의 로그·지표를 먼저 본다. 서버가 사라지면 컨테이너 안 상태도 함께 사라진다
- 정상 서버가 2대 미만이면 교체하지 않는다. 새 서버가 들어올 때까지 남은 서버가 모든 요청을 받는다
- 원인이 코드·설정이면 교체해도 새 서버가 같은 상태로 뜬다. 되돌리기를 먼저 본다
- 컨테이너만 다시 띄워도(`deploy.sh` 재실행 등) 다시 뜨는 수십 초 동안 ALB 상태 검사에 실패해, 서버 그룹(상태 검사 ELB)이 그 서버를 교체한다(2026-10-22 운영 부하 테스트). 앱만 다시 띄워야 하면 먼저 서버 그룹의 `HealthCheck`·`ReplaceUnhealthy`를 멈추고, ALB 대상이 다시 `healthy`가 된 뒤 재개한다

### Grafana: 운영 팀 경보 (운영 채널)

| 경보 | 조건 | 급함 | 런북 |
| --- | --- | --- | --- |
| 서버 오류 증가 | 운영 앱 서버 전체 5xx 비율 5% 초과 5분 (요청 초당 0.1건 이상) | `@channel` | [cking-5xx](cking-5xx.md) |
| Stream 소비 멈춤 | 소비자 idle 최솟값 120초 초과 | `@channel` | [cking-stream-stopped](cking-stream-stopped.md) |
| Stream 밀림 | lag 0 초과 5분 | `@channel` | [cking-stream-lag](cking-stream-lag.md) |
| 응모 실패 (Redis 쓰기 거부) | 거부 명령 5분 안에 1건 이상 | `@channel` | [cking-redis-rejected](cking-redis-rejected.md) |
| 처리 실패 누적 | pending 0 초과 10분 | | [cking-stream-pending](cking-stream-pending.md) |
| 응답 지연 | 운영 앱 서버 전체 p95 1초 초과 10분 | | [cking-p95](cking-p95.md) |
| DB 연결 대기 | 서버별 Hikari 대기 0 초과 5분 | | [cking-hikari-pending](cking-hikari-pending.md) |
| ERROR 로그 | 서버별 ERROR 5분 안에 1건 이상 | | [cking-error-log](cking-error-log.md) |
| Dead Stream 이동 | 서버별 이동 로그 5분 안에 1건 이상 | | [cking-dead-stream](cking-dead-stream.md) |
| 댓글 필터 호출 실패 지속 | 운영 앱 서버 전체 필터 호출 실패 로그 10분 동안 5건 이상 | | [cking-comment-filter-failing](cking-comment-filter-failing.md) |
| 댓글 판정 대기열 쌓임 | 서버별 판정 대기열 최댓값 50건 이상 5분 | | [cking-comment-filter-queue](cking-comment-filter-queue.md) |
| 추천 배치 실패 반복 | 운영 추천 배치 서버 실패 알림 로그 10분 동안 3건 이상 | | [cking-recommendation-failing](cking-recommendation-failing.md) |
| 추천 배치 멈춤 | 운영 추천 배치 서버 1분 확인 실행 로그 15분 없음 | | [cking-recommendation-stalled](cking-recommendation-stalled.md) |

개발의 앱 중단·Redis 메모리는 운영에서 CloudWatch(ALB 정상 대상 수, ElastiCache 메모리 사용률)가 맡는다.

### CloudWatch: 운영 AWS 서비스 경보 (SNS `prod-cking-alerts` → 운영 채널(Amazon Q), 인프라 담당 메일)

관측 서버·피어링이 죽어도 울리도록 CloudWatch에 둔다. Amazon Q 기본 알림에는 `@channel` 멘션이 없다.

| 경보 | 조건 | 런북 |
| --- | --- | --- |
| `prod-cking-alb-no-healthy-target` | 정상 대상 0대 1분 | [prod-alb](prod-alb.md) |
| `prod-cking-alb-few-healthy-targets` | 정상 대상 2대 미만 15분 | [prod-alb](prod-alb.md) |
| `prod-cking-alb-5xx` | ALB가 만든 5xx 비율 5% 초과 5분 (요청 30건 이상) | [prod-alb](prod-alb.md) |
| `prod-cking-launch-failed` (EventBridge) | 서버 그룹의 서버 띄우기 실패마다 | [prod-launch-failed](prod-launch-failed.md) |
| `prod-cking-redis-memory-<노드>` | 메모리 사용률 70% 초과 10분 | [prod-elasticache](prod-elasticache.md) |
| `prod-cking-redis-engine-cpu-<노드>` | 엔진 CPU 80% 초과 10분 | [prod-elasticache](prod-elasticache.md) |
| `prod-cking-rds-cpu` | CPU 80% 초과 15분 | [prod-rds](prod-rds.md) |
| `prod-cking-rds-free-storage` | 남은 저장 공간 2GiB 미만 15분 | [prod-rds](prod-rds.md) |

### Grafana: 운영 관측 경보 (운영 채널, 인프라 담당 멘션)

| 경보 | 조건 | 런북 |
| --- | --- | --- |
| 앱 서버 지표 부족 | 지표를 보내는 운영 앱 서버 2대 미만 10분 | [cking-prod-app-targets](cking-prod-app-targets.md) |
| 감시용 서버 끊김 | 감시용 서버의 node·redis·alloy 지표 없음 또는 ElastiCache 연결 실패(`redis_up` 0) 5분 | [cking-prod-monitor-down](cking-prod-monitor-down.md) |
| 지표 전송 실패 | 수집기 전송 실패 10분 지속 | [cking-remote-write-failed](cking-remote-write-failed.md) |
| 로그 버림 | 수집기가 로그를 1건 이상 버림 | [cking-log-dropped](cking-log-dropped.md) |
| 수집기 메모리 | 운영 수집기의 Go 런타임 사용량이 상한(256MiB)의 95% 초과 5분 | [cking-obs-memory](cking-obs-memory.md) |
| 서버 여유 메모리 | 100MiB 미만 10분 | [cking-memory-available](cking-memory-available.md) |
| 디스크 여유 | 20% 미만 10분 | [cking-disk-available](cking-disk-available.md) |
