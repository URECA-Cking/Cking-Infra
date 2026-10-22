# 추천 배치 멈춤

> 전제: [추천 배치 서버](recommendation-batch.md)의 전제와 같다. 1분 확인(`cking-content-event.service`)은 실행이 끝나고 60초 뒤 다시 돈다

15분 동안 1분 확인 실행 로그(`{instance="dev-cking-recommendation", unit="cking-content-event.service"}`)가 하나도 없을 때(Loki). 로그가 아예 없어도 울린다.

## 뜻하는 것

1분 확인이 돌지 않거나, 돌아도 로그가 Loki에 오지 않는다. 소개 변경이 태그·추천에 반영되지 않는다. 실행마다 systemd가 시작·끝 로그를 남기므로 평소에는 15분에 수십 줄이다. 실행 간격은 실행 시간 + 60초 + 타이머 정확도(최대 1분)이고, 2026-10-22 개발에서 65\~106초였다. 일일 작업이 도는 동안에도 1분 확인은 잠금을 확인하고 바로 끝나므로 로그가 남는다.

서버가 바뀌면 그동안 로그가 끊긴다. 새 서버가 바로 뜨면 3\~4분이라 울리지 않는다(2026-10-22 배포 3분 1초, 스팟 회수 3분 47초). 스팟 자리가 없어 새 서버가 늦게 뜨면 그 시간만큼 길어진다. 2026-10-22에는 자리 없는 시간 9분·13분이 더해져 로그가 11분 47초·16분 21초 끊겼고, 뒤의 것에서 울렸다(09:13 울림, 09:14 로그 재개, 09:18 해제 알림).

## 먼저 볼 곳

- 서버 지표: Grafana Explore(Prometheus)에서 `up{instance="dev-cking-recommendation"}`. 수집기가 서버 안에서 보내므로 서버나 수집기가 없으면 0이 아니라 값이 사라진다. 경보 시각 앞뒤로 범위를 넓혀 끊긴 구간을 보고, 값이 이어지면 서버는 살아 있다
- 서버 그룹 활동과 서버 상태: [추천 배치 서버](recommendation-batch.md#먼저-볼-곳)

```bash
# 추천 배치 서버(SSM 세션)
systemctl list-timers 'cking-content-*'
systemctl status cking-content-event.service --no-pager
sudo docker ps --filter name=app-agent-alloy
```

## 원인별 대응

- **서버가 없음**(그룹에 InService 서버 없음): 스팟 자리가 없거나 새 서버가 시작 대기에서 버려지고 있다. [추천 배치 서버](recommendation-batch.md#원인별-대응)의 원인별 대응을 따른다
- **타이머가 꺼져 있음**: 부팅 로그의 `추천 배치 값이 n/6개만 있어 타이머를 켜지 않는다`를 보고 빠진 값을 넣은 뒤 서버를 교체한다
- **실행이 끝나지 않음**(`status`가 activating이고 시작이 15분 넘게 지남): 공급자나 BE 응답을 기다리고 있다. 작업자 로그와 [추천 배치 실패 반복](cking-recommendation-failing.md)의 먼저 볼 곳을 본다. 실행 상한은 12시간이다
- **서버는 돌고 로그만 없음**: 수집기 로그(`sudo docker logs app-agent-alloy-1`)에서 journal 오류를 본다. 서버 지표는 들어오는데 작업 로그만 없으면 journal 수집 문제다

## 해결 확인

Grafana Explore(Loki)에서 1분 확인 로그가 다시 들어온다. 해제 알림은 경보 묶음 간격(5분)에 맞춰 늦게 올 수 있다.

## 하면 안 되는 것

- 그룹의 서버 수를 늘려 다시 돌리려 하지 않는다. 작업자는 서버 하나만 지원한다
- 상태 디스크를 다른 서버에 붙이지 않는다

## 운영에서 다른 점

- 운영 규칙 `cking-prod-recommendation-stalled`는 `instance="prod-cking-recommendation"`을 본다. 운영 서버는 온디맨드라 스팟 회수가 없다. 2a 한 곳이라 그 가용 영역에 t4g.small 자리가 없으면(`InsufficientInstanceCapacity`) 개발과 같이 새 서버가 늦게 뜬다. 프라이빗 서브넷이라 바깥 연결은 NAT를 지난다
