# 추천 배치 멈춤

> 전제: [개발 추천 배치 서버](recommendation-batch.md)의 전제와 같다. 1분 확인(`cking-content-event.service`)은 실행이 끝나고 60초 뒤 다시 돈다

15분 동안 1분 확인 실행 로그(`{instance="dev-cking-recommendation", unit="cking-content-event.service"}`)가 하나도 없을 때(Loki). 로그가 아예 없어도 울린다.

## 뜻하는 것

1분 확인이 돌지 않거나, 돌아도 로그가 Loki에 오지 않는다. 소개 변경이 태그·추천에 반영되지 않는다. 실행마다 systemd가 시작·끝 로그를 남기므로 평소에는 15분에 수십 줄이다. 실행 간격은 실행 시간 + 60초 + 타이머 정확도(최대 1분)이고, 2026-10-22 개발에서 65\~106초였다. 일일 작업이 도는 동안에도 1분 확인은 잠금을 확인하고 바로 끝나므로 로그가 남는다. 서버 교체(스팟 중단, 배포)는 2\~4분이라 울리지 않는다.

## 먼저 볼 곳

- 서버 지표: Grafana Explore(Prometheus)에서 `up{instance="dev-cking-recommendation"}`가 없거나 0이면 서버나 수집기 전체가 멈췄다. 1이면 서버는 살아 있다
- 서버 그룹 활동과 서버 상태: [개발 추천 배치 서버](recommendation-batch.md#먼저-볼-곳)

```bash
# 추천 배치 서버(SSM 세션)
systemctl list-timers 'cking-content-*'
systemctl status cking-content-event.service --no-pager
docker ps --filter name=app-agent-alloy
```

## 원인별 대응

- **서버가 없음**(그룹에 InService 서버 없음): 스팟 자리가 없거나 새 서버가 시작 대기에서 버려지고 있다. [개발 추천 배치 서버](recommendation-batch.md#원인별-대응)의 원인별 대응을 따른다
- **타이머가 꺼져 있음**: 부팅 로그의 `추천 배치 값이 n/6개만 있어 타이머를 켜지 않는다`를 보고 빠진 값을 넣은 뒤 서버를 교체한다
- **실행이 끝나지 않음**(`status`가 activating이고 시작이 15분 넘게 지남): 공급자나 BE 응답을 기다리고 있다. 작업자 로그와 [추천 배치 실패 반복](cking-recommendation-failing.md)의 먼저 볼 곳을 본다. 실행 상한은 12시간이다
- **서버는 돌고 로그만 없음**: 수집기 로그(`docker logs app-agent-alloy-1`)에서 journal 오류를 본다. 서버 지표는 들어오는데 작업 로그만 없으면 journal 수집 문제다

## 하면 안 되는 것

- 그룹의 서버 수를 늘려 다시 돌리려 하지 않는다. 작업자는 서버 하나만 지원한다
- 상태 디스크를 다른 서버에 붙이지 않는다

## 운영에서 다른 점

- 운영 규칙 `cking-prod-recommendation-stalled`는 `instance="prod-cking-recommendation"`을 본다. 운영 서버는 온디맨드라 스팟 중단·자리 부족이 없고, 프라이빗 서브넷이라 바깥 연결은 NAT를 지난다
