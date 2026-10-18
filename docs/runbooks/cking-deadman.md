# 데드맨

> 전제: Grafana가 5분마다 healthchecks.io로 신호를 보내고, 10분 끊기면 healthchecks.io가 인프라 담당에게 메일을 보낸다

## 뜻하는 것

Grafana 경보 경로가 멈췄다. 이 동안에는 **다른 모든 Grafana 경보도 오지 않는다.**

원인은 다음 중 하나다: 관측 서버가 멈춤, Grafana가 멈춤, Grafana 경보 평가가 멈춤, Grafana에서 healthchecks.io로 나가는 연결이 끊김.

## 먼저 볼 곳

1. `https://dev-monitoring.cking.co.kr` 접속
2. 접속이 안 되면 관측 서버 SSM 접속

```bash
# 관측 서버
sudo docker ps -a --format '{{.Names}} {{.Status}}'
sudo docker logs --tail 100 observability-grafana-1
```

## 원인별 대응

- **SSM 접속 안 됨**: 관측 서버 자체 문제. [인스턴스 상태 검사](ec2-instance-check.md)
- **Grafana 컨테이너가 멈춤·재시작 반복**: 로그 확인, `OOMKilled`면 [Grafana 메모리](cking-grafana-memory.md). 서버의 compose 명령은 `apply.sh`가 넣는 환경변수가 없어 실패하므로, 관측 배포 워크플로(Deploy observability)를 수동 실행(Run workflow)한다
- **Grafana는 정상**: Alerting → Alert rules에서 `데드맨 (항상 울림)`이 Firing인지, Contact points의 `데드맨` 마지막 전송 오류를 본다. 웹후크 주소는 Parameter Store `/cking/dev/monitoring/DEADMAN_PING_URL`
- 복구 뒤 다른 경보가 울리지 않았는지 대시보드로 직접 확인한다. 멈춘 동안의 경보는 오지 않았다

## 하면 안 되는 것

- healthchecks.io에서 검사를 일시 정지한 채로 두지 않는다. 다음 장애를 알 수 없다
