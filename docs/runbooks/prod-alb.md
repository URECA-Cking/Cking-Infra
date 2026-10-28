# 운영 ALB 경보

> 전제: 운영 ALB `prod-cking-alb`, 앱 서버 그룹 `prod-cking-app`(2~4대, 서버 교체 배포, 시작 대기 중 자기 검사), CloudWatch 경보 → SNS `prod-cking-alerts` → 운영 채널(Amazon Q)·인프라 담당 메일

| 경보 | 조건 |
| --- | --- |
| `prod-cking-alb-no-healthy-target` | 정상 대상 0대 1분(지표가 없어도 울림) |
| `prod-cking-alb-few-healthy-targets` | 정상 대상 2대 미만 15분 |
| `prod-cking-alb-5xx` | ALB가 만든 5xx가 1분 단위로 3번 중 2번 요청의 5% 초과(요청 30건 이상일 때) |

Amazon Q 기본 알림에는 `@channel` 멘션이 없다. 같은 경보가 메일로도 온다.

## 뜻하는 것

- **정상 대상 0대**: 서비스 중단이다. 대상이 모두 비정상이면 ALB는 모든 대상에 요청을 보내므로(fail open) 일부 요청은 성공할 수 있다
- **2대 미만 15분**: 서버 하나를 교체하는 상한(시작 대기 900초)을 넘겼다. 새 서버가 계속 버려지고 있을 가능성이 크다
- **ALB 5xx**: 앱까지 가지 못한 요청이다. 502(대상이 연결을 끊음)·503(정상 대상 없음)·504(응답 시간 초과). 앱이 낸 5xx는 Grafana [서버 오류 증가](cking-5xx.md)가 본다

서버 그룹은 ALB 헬스체크(`/readyz`, 10초 간격 2번 실패면 비정상)로 서버 상태를 보고, 비정상 서버를 유예 120초 뒤 교체한다.

첫 BE 배포 전에는 배포 태그가 없어 정상 대상이 0대이므로 앞의 두 경보가 울리는 것이 정상이다.

## 먼저 볼 곳

1. 서버 그룹의 서버 상태와 활동 기록([서버 찾기](README.md#운영), [운영 서버 띄우기 실패](prod-launch-failed.md#먼저-볼-곳))
2. 직전 배포: Cking-BE Actions `Deploy to prod`
3. 대상 그룹 `prod-cking-app-tg`의 대상별 상태와 비정상 사유(`Target.ResponseCodeMismatch`는 `/readyz`가 200이 아님, `Target.Timeout`은 응답 없음)

```bash
# Mac
aws elbv2 describe-target-health --region ap-northeast-2 \
  --target-group-arn $(aws elbv2 describe-target-groups --region ap-northeast-2 --names prod-cking-app-tg --query 'TargetGroups[0].TargetGroupArn' --output text) \
  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason]' --output table
```

4. Grafana **크킹 앱**: `instance`별 요청량·오류

## 원인별 대응

### 1. 직전 배포 뒤 시작됨

[운영 앱 배포](deploy-failed.md#운영-앱-배포-cking-be-deploy-to-prod)의 되돌리기를 따른다.

### 2. 서버가 계속 버려짐 (활동 기록에 실패가 이어짐)

[운영 서버 띄우기 실패](prod-launch-failed.md).

### 3. 서버는 떠 있는데 헬스체크 실패

`/readyz`가 실패하는 원인은 대개 DB·Redis 연결이다. [운영 RDS 경보](prod-rds.md), [운영 ElastiCache 경보](prod-elasticache.md), Grafana [DB 연결 대기](cking-hikari-pending.md)가 함께 울렸는지 본다. 서버 그룹이 비정상 서버를 교체하는데, 원인이 DB·Redis처럼 공통이면 새 서버도 자기 검사에서 버려져 [운영 서버 띄우기 실패](prod-launch-failed.md) 알림이 이어진다. 교체로는 풀리지 않으므로 DB·Redis를 먼저 고친다.

### 4. 5xx만 늘어남 (정상 대상 수는 정상)

504가 대부분이면 느린 요청이다([응답 지연](cking-p95.md)). 502가 배포 시각에 몰리면 서버가 요청 처리 중에 빠진 것이다(해제 대기 90초와 앱 종료 대기 설정 확인).

## 해결 확인

위 대상 상태가 `healthy` 2대 이상이고, CloudWatch 경보가 OK로 돌아온다(운영 채널에 OK 알림이 온다).

## 하면 안 되는 것

- 정상 서버가 적을 때 서버를 교체하지 않는다. 교체 중에는 남은 서버가 모든 요청을 받는다
- 원인을 보기 전에 서버 그룹 대수를 크게 늘리지 않는다. 새 서버도 같은 이유로 버려지면 실패만 쌓인다

## 가용 영역 하나가 앱 서버에 닿지 않을 때

2026-10-29 게임 데이(app-2a 서브넷에 ALB → 8080 차단): ALB가 2a 대상을 비정상으로 본 뒤(약 40초) 2b만으로 처리했지만, 서버 그룹은 비정상 2a 서버를 교체하면서 새 서버를 다시 2a에 띄웠다(두 번). 그룹은 가용 영역 장애를 모르고 영역 균형을 맞춘다.

1. 영역 장애인지 본다: 비정상 대상이 한 영역에만 있고, 새로 뜬 서버도 그 영역에서 비정상
2. 서버 그룹 서브넷에서 그 영역을 잠시 뺀다. 그룹이 그 영역에 새 서버를 띄우지 않게 하는 것이 목적이다(그 영역에 남은 서버를 그룹이 언제 정리하는지는 시험하지 않았다). Terraform 밖 변경이라 끝나면 되돌리고 `envs/prod` plan으로 확인한다

   ```bash
   # Mac (app-2b 서브넷만 남김)
   SUB_B=$(aws ec2 describe-subnets --region ap-northeast-2 --filters Name=tag:Name,Values=prod-cking-subnet-app-2b --query 'Subnets[0].SubnetId' --output text)
   aws autoscaling update-auto-scaling-group --region ap-northeast-2 --auto-scaling-group-name prod-cking-app --vpc-zone-identifier "$SUB_B"
   ```

3. 1대로 부하가 넘치면 남은 영역의 원하는 대수를 늘린다(최대 4대). ALB 영역 이동(ARC zonal shift)은 이 구성(교차 영역 부하 분산 켜짐)에서 쓸 수 있는지 확인하지 않았다

