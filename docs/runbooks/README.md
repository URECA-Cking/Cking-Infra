# 런북

경보를 받았을 때 보고 따라 하는 대응 절차. 경보 하나에 파일 하나이며, 파일 이름은 경보 규칙의 uid다. Redis Stream 경보 4개가 함께 보는 내용은 [stream.md](stream.md)에 둔다.

각 런북 맨 위의 `전제`는 그 절차가 맞는 구성이다. 배포 방식·서버 구성·경보 규칙을 바꾸는 PR은 영향받는 런북을 같은 PR에서 고친다.

## 형식

| 항목 | 내용 |
| --- | --- |
| 뜻하는 것 | 경보 조건과 지금 무슨 일이 벌어지고 있는지, 사용자 영향 |
| 먼저 볼 곳 | 원인을 가르는 대시보드·패널, 명령 |
| 원인별 대응 | 원인마다 확인 방법과 조치 |
| 하면 안 되는 것 | 먼저 떠오르지만 상황을 악화시키는 조치 |

명령에는 실행 위치를 적는다. **Mac**은 AWS 자격 증명이 있는 로컬, **앱 서버**·**관측 서버**는 SSM 세션(`aws ssm start-session --target <인스턴스 ID>`) 안이다. 인스턴스 ID는 이름표로 찾는다.

```bash
# Mac
aws ec2 describe-instances --filters Name=tag:Name,Values=dev-cking-app Name=instance-state-name,Values=running \
  --query 'Reservations[0].Instances[0].InstanceId' --output text
```

관측 서버는 `Values=dev-cking-observability`. Grafana는 `https://dev-monitoring.cking.co.kr`.

## 경보 목록

### Grafana: 팀 경보 (Slack)

| 경보 | 조건 | 급함 | 런북 |
| --- | --- | --- | --- |
| 앱 중단 | 앱 지표 2분 없음 | `@channel` | [cking-app-down](cking-app-down.md) |
| 서버 오류 증가 | 5xx 비율 5% 초과 5분 (요청 초당 0.1건 이상) | `@channel` | [cking-5xx](cking-5xx.md) |
| Stream 소비 멈춤 | 소비자 idle 120초 초과 | `@channel` | [cking-stream-stopped](cking-stream-stopped.md) |
| Stream 밀림 | lag 0 초과 5분 | `@channel` | [cking-stream-lag](cking-stream-lag.md) |
| 응모 실패 (Redis 쓰기 거부) | 거부 명령 5분 안에 1건 이상 | `@channel` | [cking-redis-rejected](cking-redis-rejected.md) |
| 처리 실패 누적 | pending 0 초과 10분 | | [cking-stream-pending](cking-stream-pending.md) |
| 응답 지연 | p95 1초 초과 10분 | | [cking-p95](cking-p95.md) |
| DB 연결 대기 | Hikari 대기 0 초과 5분 | | [cking-hikari-pending](cking-hikari-pending.md) |
| Redis 메모리 | 한도의 70% 초과 10분 | | [cking-redis-memory](cking-redis-memory.md) |
| ERROR 로그 | ERROR 5분 안에 1건 이상 | | [cking-error-log](cking-error-log.md) |
| Dead Stream 이동 | 이동 로그 5분 안에 1건 이상 | | [cking-dead-stream](cking-dead-stream.md) |

### Grafana: 관측 경보 (Slack, 인프라 담당 멘션)

| 경보 | 조건 | 런북 |
| --- | --- | --- |
| 수집 대상 끊김 | 앱 서버의 node·redis·alloy 지표 5분 없음 | [cking-target-down](cking-target-down.md) |
| 지표 전송 실패 | 수집기 전송 실패 10분 지속 | [cking-remote-write-failed](cking-remote-write-failed.md) |
| 로그 버림 | 수집기가 로그를 1건 이상 버림 | [cking-log-dropped](cking-log-dropped.md) |
| 관측 프로그램 메모리 | Prometheus·Loki·Alloy가 컨테이너 상한의 95% 초과 5분 | [cking-obs-memory](cking-obs-memory.md) |
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
