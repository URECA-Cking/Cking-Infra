# 인스턴스 시스템 상태 검사 실패

> 전제: 앱 서버(`dev-cking-app`)·관측 서버(`dev-cking-observability`) 각 1대, CloudWatch 경보 → SNS `dev-cking-alerts` 메일

`StatusCheckFailed_System`이 1분 간격 2회 연속일 때.

## 뜻하는 것

인스턴스가 올라간 AWS 쪽 하드웨어·네트워크·전원에 문제가 있다. OS 문제가 아니다. EC2 기본 자동 복구가 인스턴스를 다른 하드웨어로 옮긴다. 인스턴스 ID, 사설 IP, EBS 데이터는 그대로다.

| 서버 | 영향 |
| --- | --- |
| 앱 서버 | 모든 API 실패. 팀 Slack에 [앱 중단](cking-app-down.md)도 울린다 |
| 관측 서버 | 지표·로그 저장과 Grafana 경보가 멈춤. [데드맨](cking-deadman.md) 메일도 온다. 수집기가 쌓았다가 복구 뒤 보낸다 |

## 먼저 볼 곳

1. EC2 콘솔 → 인스턴스 → 상태 검사 탭, 이벤트
2. AWS Health Dashboard: 해당 리전·가용 영역의 장애 공지

## 대응

1. 자동 복구를 기다린다. 상태 검사가 통과로 돌아오는지 본다
2. 복구 뒤 컨테이너가 다시 떴는지 확인한다(`restart: unless-stopped`)

```bash
# 해당 서버
sudo docker ps --format '{{.Names}} {{.Status}}'
```

3. 자동 복구가 실패하면 콘솔에서 인스턴스를 **중지 → 시작**한다. 다른 하드웨어로 옮겨진다. 퍼블릭 IP가 바뀔 수 있지만 앱은 ALB, 관측 서버는 고정 사설 IP(10.0.21.245)로 접근하므로 영향 없다

## 하면 안 되는 것

- 인스턴스를 종료(terminate)하지 않는다. 앱 서버 Redis 데이터와 관측 서버 지표가 사라진다
- 재부팅으로 해결하려 하지 않는다. 같은 하드웨어에 머문다
