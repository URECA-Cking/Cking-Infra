# 운영 ALB 경보

> 전제: 운영 ALB `prod-cking-alb`, 앱 서버 그룹 `prod-cking-app`(2~4대, 서버 교체 배포, 시작 대기 중 자기 검사), CloudWatch 경보 → SNS `prod-cking-alerts` → 운영 채널(Amazon Q)·인프라 담당 메일

| 경보 | 조건 |
| --- | --- |
| `prod-cking-alb-no-healthy-target` | 정상 대상 0대 1분(지표가 없어도 울림) |
| `prod-cking-alb-few-healthy-targets` | 정상 대상 2대 미만 15분 |
| `prod-cking-alb-5xx` | ALB가 만든 5xx가 5분 동안 요청의 5% 초과(요청 30건 이상일 때) |

Amazon Q 기본 알림에는 `@channel` 멘션이 없다. 같은 경보가 메일로도 온다.

## 뜻하는 것

- **정상 대상 0대**: 서비스 중단이다. 대상이 모두 비정상이면 ALB는 모든 대상에 요청을 보내므로(fail open) 일부 요청은 성공할 수 있다
- **2대 미만 15분**: 서버 하나를 교체하는 상한(시작 대기 900초)을 넘겼다. 새 서버가 계속 버려지고 있을 가능성이 크다
- **ALB 5xx**: 앱까지 가지 못한 요청이다. 502(대상이 연결을 끊음)·503(정상 대상 없음)·504(응답 시간 초과). 앱이 낸 5xx는 Grafana [서버 오류 증가](cking-5xx.md)가 본다

첫 BE 배포 전에는 배포 태그가 없어 정상 대상이 0대이므로 앞의 두 경보가 울리는 것이 정상이다.

## 먼저 볼 곳

1. 서버 그룹의 서버 상태와 활동 기록([서버 찾기](README.md#운영), [운영 서버 띄우기 실패](prod-launch-failed.md#먼저-볼-곳))
2. 직전 배포: Cking-BE Actions `Deploy to prod`
3. AWS 콘솔 EC2 → 대상 그룹 `prod-cking-app-tg` → 대상: 비정상 사유(`Health checks failed`, `Request timed out`)
4. Grafana **크킹 앱**: `instance`별 요청량·오류

## 원인별 대응

### 1. 직전 배포 뒤 시작됨

[운영 앱 배포](deploy-failed.md#운영-앱-배포-cking-be-deploy-to-prod)의 되돌리기를 따른다.

### 2. 서버가 계속 버려짐 (활동 기록에 실패가 이어짐)

[운영 서버 띄우기 실패](prod-launch-failed.md).

### 3. 서버는 떠 있는데 헬스체크 실패

`/readyz`가 실패하는 원인은 대개 DB·Redis 연결이다. [운영 RDS 경보](prod-rds.md), [운영 ElastiCache 경보](prod-elasticache.md), Grafana [DB 연결 대기](cking-hikari-pending.md)가 함께 울렸는지 본다.

### 4. 5xx만 늘어남 (정상 대상 수는 정상)

504가 대부분이면 느린 요청이다([응답 지연](cking-p95.md)). 502가 배포 시각에 몰리면 서버가 요청 처리 중에 빠진 것이다(해제 대기 90초와 앱 종료 대기 설정 확인).

## 하면 안 되는 것

- 정상 서버가 적을 때 서버를 교체하지 않는다. 교체 중에는 남은 서버가 모든 요청을 받는다
- 원인을 보기 전에 서버 그룹 대수를 크게 늘리지 않는다. 새 서버도 같은 이유로 버려지면 실패만 쌓인다
