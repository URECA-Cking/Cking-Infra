# 인스턴스 상태 검사 실패

> 전제: 앱 서버(`dev-cking-app`)·관측 서버(`dev-cking-observability`) 각 1대, CloudWatch 경보 → SNS `dev-cking-alerts` 메일

`StatusCheckFailed_Instance`가 1분 간격 3회 연속일 때. 경보와 함께 자동으로 재부팅한다.

## 뜻하는 것

OS가 응답하지 않는다. 흔한 원인은 메모리 고갈(관측 서버는 swap 없음), 커널 문제, 디스크 가득이다. 재부팅으로 대부분 돌아오지만 원인이 남아 있으면 반복된다.

| 서버 | 영향 |
| --- | --- |
| 앱 서버 | 모든 API 실패. 재부팅 뒤 컨테이너가 다시 뜬다 |
| 관측 서버 | 지표·로그 저장, Grafana 경보 멈춤. 재부팅 뒤 수집기가 쌓아 둔 것을 보낸다 |

## 먼저 볼 곳

1. EC2 콘솔 → 상태 검사 탭: 재부팅 뒤 통과로 돌아왔는지
2. 재부팅 전 추세: **크킹 서버 → 여유 메모리, 디스크 여유, 자원 압박 (PSI)**
3. 재부팅 전 커널 로그

```bash
# 해당 서버
journalctl -k -b -1 --no-pager | tail -50
journalctl -b -1 --no-pager | grep -iE 'out of memory|oom|killed process' | tail
```

## 대응

1. 재부팅 뒤 컨테이너 확인: `sudo docker ps --format '{{.Names}} {{.Status}}'`
2. 원인별
   - 메모리 고갈 → [서버 여유 메모리](cking-memory-available.md)
   - 디스크 가득 → [디스크 여유](cking-disk-available.md)
3. 재부팅 뒤에도 실패하면 콘솔 → 인스턴스 → 모니터링 및 문제 해결 → 시스템 로그 가져오기·인스턴스 스크린샷으로 부팅 단계를 본다

## 하면 안 되는 것

- 인스턴스를 종료(terminate)하지 않는다
- 원인을 확인하지 않고 반복 재부팅만 하지 않는다. 재부팅 전 로그(`-b -1`)는 다음 재부팅 뒤에는 찾기 어려워진다
