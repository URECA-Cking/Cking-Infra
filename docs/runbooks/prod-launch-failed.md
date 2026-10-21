# 운영 서버 띄우기 실패

> 전제: 운영 서버 그룹 `prod-cking-app`·`prod-cking-monitor`, EventBridge 규칙 `prod-cking-launch-failed`(`EC2 Instance Launch Unsuccessful`) → SNS `prod-cking-alerts` → 운영 채널(Amazon Q)·인프라 담당 메일

서버 그룹이 서버를 띄우다 실패할 때마다 한 건씩 온다.

## 뜻하는 것

앱 서버는 시작 대기 동안 부팅·앱 기동·자기 검사(`smoke.js`)를 마쳐야 요청을 받는다. 어느 단계든 실패하거나 900초를 넘기면 버려지고 이 알림이 온다. 배포 중이면 교체가 실패하고 BE CI가 되돌린다. 배포가 아니면(늘리기·교체) 대수가 모자란 채로 남는다.

## 먼저 볼 곳

```bash
# Mac
aws autoscaling describe-scaling-activities --region ap-northeast-2 --auto-scaling-group-name prod-cking-app \
  --max-items 10 --query 'Activities[].[StartTime,StatusCode,Description,StatusMessage]' --output table
```

버려진 서버는 이미 없으므로 부팅 로그는 Grafana **크킹 로그**(Loki)에서 `{instance="prod-cking-app-<인스턴스 ID>"}`로 본다. 수집기가 뜨기 전에 실패했으면 로그가 없다.

## 원인별 대응

- **배포 직후**: [운영 앱 배포](deploy-failed.md#운영-앱-배포-cking-be-deploy-to-prod)
- **`deploy.sh` 실패**(Parameter Store 값 없음, 이미지 받기 실패): 빠진 값을 넣거나 GHCR 상태를 본다
- **자기 검사 실패**: 같은 태그로 개발에서 `smoke.js`가 통과하는지 본다
- **용량 부족**(`InsufficientInstanceCapacity`): AZ에 t4g.small 여유가 없다. 다른 AZ로 자동 재시도되므로 반복되는지만 본다

## 하면 안 되는 것

- 시작 대기 상한(900초)을 원인 확인 없이 늘리지 않는다. 늘리면 실패를 늦게 알 뿐이다
