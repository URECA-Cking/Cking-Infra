# 운영 서버 띄우기 실패

> 전제: 운영 서버 그룹 `prod-cking-app`·`prod-cking-monitor`, EventBridge 규칙 `prod-cking-launch-failed`(`EC2 Instance Launch Unsuccessful`) → SNS `prod-cking-alerts` → 운영 채널(Amazon Q)·인프라 담당 메일

서버 그룹이 서버를 띄우다 실패할 때마다 한 건씩 온다.

## 뜻하는 것

앱 서버는 시작 대기 동안 부팅·앱 기동·자기 검사(`smoke.js`)를 마쳐야 요청을 받는다. 어느 단계든 실패하거나 900초를 넘기면 버려지고 이 알림이 온다. 배포 중이면 교체가 실패하고 BE CI가 되돌린다. 배포가 아니면(늘리기·교체) 대수가 모자란 채로 남는다.

감시용 서버 그룹은 시작 대기가 없어, 이 알림은 서버 자체를 띄우지 못할 때(자리 부족, 시작 템플릿 오류)만 온다. 부팅 스크립트가 실패한 감시용 서버는 정상으로 남는다([감시용 서버 끊김](cking-prod-monitor-down.md#2-서버는-떠-있는데-수집기-컨테이너가-없음)). 추천 배치 서버 그룹은 이 알림 대상이 아니다.

## 먼저 볼 곳

알림 제목의 서버 그룹 이름으로 활동을 본다(감시용 서버면 `prod-cking-monitor`). 시작 대기에서 버려진 서버는 `Cancelled`, `Lifecycle Action Completed with ABANDON Result`로 남는다.

```bash
# Mac
aws autoscaling describe-scaling-activities --region ap-northeast-2 --auto-scaling-group-name prod-cking-app \
  --max-items 10 --query 'Activities[].[StartTime,StatusCode,Description,StatusMessage]' --output table
```

버려진 서버의 부팅 출력은 EC2 콘솔 출력으로 본다. 서버 ID는 활동의 `Launching a new EC2 instance: <서버>`에 있고, 종료된 뒤에도 몇 시간은 받아진다(2026-10-22 5시간 뒤 확인). 먼저 나온 오류가 원인이다.

```bash
# Mac
aws ec2 get-console-output --region ap-northeast-2 --instance-id <서버> --latest --output text --query Output \
  | grep -E 'An error occurred|헬스체크 실패|시작 대기를 끝내지'
```

앱 서버 수집기는 `deploy.sh`가 끝난 뒤 뜨므로, 그 전에 실패하면 Grafana(Loki)에는 로그가 없다. 자기 검사 단계의 앱 로그는 **크킹 로그**에서 `{instance="prod-cking-app-<서버>"}`로 본다.

## 원인별 대응

- **배포 태그가 없음**(첫 BE 운영 배포 전, 콘솔 출력의 첫 오류가 `ParameterNotFound`): 정상이다. 서버 그룹이 2대를 채우려 계속 띄우고 버린다(2026-10-22 첫 apply 뒤 35분 동안 10번). 첫 `Deploy to prod`가 `/cking/prod/RELEASE_TAG`를 만들면 멈춘다
- **배포 직후**: [운영 앱 배포](deploy-failed.md#운영-앱-배포-cking-be-deploy-to-prod)
- **`deploy.sh` 실패**(Parameter Store 값 없음, 이미지 받기 실패, `헬스체크 실패`): 빠진 값을 넣거나 GHCR 상태를 본다
- **자기 검사 실패**: 같은 태그로 개발에서 `smoke.js`가 통과하는지 본다
- **용량 부족**(`InsufficientInstanceCapacity`): AZ에 t4g.small 여유가 없다. 다른 AZ로 자동 재시도되므로 반복되는지만 본다

## 해결 확인

활동에 `Successful`·`Launching a new EC2 instance`가 남고, [서버 찾기](README.md#운영)에서 서버가 `InService`·`Healthy`다.

## 하면 안 되는 것

- 시작 대기 상한(900초)을 원인 확인 없이 늘리지 않는다. 늘리면 실패를 늦게 알 뿐이다
