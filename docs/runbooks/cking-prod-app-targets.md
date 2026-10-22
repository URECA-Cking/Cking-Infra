# 앱 서버 지표 부족

> 전제: 운영 앱 서버 그룹 `prod-cking-app`(최소 2대), 수집기(Alloy) → VPC 피어링 → 관측 서버(`dev-cking-observability`)

지표(`up{job="node"}`)를 보내는 운영 앱 서버가 2대보다 적고 10분 지속될 때. 지표가 하나도 없어도 울린다. 관측 경보(인프라 담당 멘션).

## 뜻하는 것

서버 그룹은 항상 2대 이상을 유지하므로, 지표를 보내는 서버가 2대보다 적으면 서버가 실제로 줄었거나 수집기가 끊긴 것이다. 수집 방식이 보내기(push)라 서버를 줄여 지표가 사라진 것과 수집기 고장을 지표만으로는 가를 수 없다. 그래서 대수만 본다. 4대 중 1대의 수집기만 끊긴 경우는 잡지 못한다.

이 서버의 지표를 쓰는 다른 경보(서버 오류, 응답 지연, DB 연결 대기, ERROR 로그, 서버 메모리·디스크)가 조용해질 수 있다.

## 먼저 볼 곳

1. 서버 그룹의 실제 서버 수와 상태([서버 찾기](README.md#운영))
2. CloudWatch ALB 정상 대상 수: 서버가 요청을 받고 있는지
3. 서버 그룹 활동 기록: 서버를 띄우다 실패하고 있는지

```bash
# Mac
aws autoscaling describe-scaling-activities --region ap-northeast-2 --auto-scaling-group-name prod-cking-app \
  --max-items 10 --query 'Activities[].[StartTime,StatusCode,Description,StatusMessage]' --output table
```

## 원인별 대응

### 1. 서버가 실제로 2대보다 적음

활동 기록에 실패(`Failed`, `Cancelled`)가 이어지면 새 서버가 부팅이나 자기 검사에서 버려지고 있다. 버려진 이유는 [운영 서버 띄우기 실패](prod-launch-failed.md#먼저-볼-곳)의 콘솔 출력으로 본다. 직전 배포·설정 변경 뒤면 [운영 앱 배포](deploy-failed.md#운영-앱-배포-cking-be-deploy-to-prod)의 되돌리기를 따른다.

### 2. 서버는 2대 이상, 지표만 없음

수집기나 전송 경로 문제다. 모든 서버의 지표가 없으면 피어링·관측 서버 쪽을 먼저 본다([지표 전송 실패](cking-remote-write-failed.md)). 일부만 없으면 그 서버의 수집기를 본다.

```bash
# 운영 앱 서버
sudo docker ps -a --filter name=app-agent-alloy --format '{{.Status}}'
sudo docker logs --tail 100 app-agent-alloy-1
```

## 해결 확인

Grafana Explore(Prometheus)에서 `count(up{job="node",instance=~"prod-cking-app-.*"} == 1)`이 2 이상이다.

## 하면 안 되는 것

- 관측 서버와 끊긴 동안 수집기를 재시작하지 않는다([수집 대상 끊김](cking-target-down.md#하면-안-되는-것))
- 지표가 없다는 이유만으로 서버를 교체하지 않는다. 요청을 받고 있는 서버면 교체 중 대수만 줄어든다
