# 로그 버림

> 전제: 앱 서버·추천 배치 서버 수집기(Alloy) → 관측 서버(`dev-cking-observability`, Docker Compose). 관측 서버 자신의 수집기(`instance="alloy:12345"`)도 같은 경보로 본다

`increase(loki_write_dropped_entries_total[5m]) > 0`일 때.

## 뜻하는 것

수집기가 로그를 보내지 못하고 버렸다. 버린 로그는 되살릴 수 없다. 재시도 횟수는 무한(`max_backoff_retries=0`)이라 연결이 끊긴 것만으로는 버리지 않는다. 버렸다면 Loki가 요청을 거부한 것이다(4xx는 재시도하지 않는다).

## 먼저 볼 곳

1. 경보 라벨 `reason`, `instance`
2. **크킹 관측 파이프라인 → 로그 전송 재시도·버림**
3. 수집기 자기 로그: **크킹 로그**가 아니라 Explore(Loki)에서 `{container="alloy", instance="<instance>"} |= "dropping"`

## 원인별 대응

- **Loki가 거부**(줄이 너무 김, 너무 오래된 로그, 유입 한도): 수집기 로그의 응답 내용으로 Loki 설정(`observability/loki/loki.yaml`) 또는 앱 로그 형식을 고친다
- **`ingester_error`이면서 `status=-1`**: 응답을 받지 못한 경우다. Alloy가 그 밖의 오류를 이 이름으로 센다. 2026-10-11의 45건은 무한 재시도로 바꾸기 전 끊김 실험 중 연결 거부였다
- **Loki가 멈춤**: `sudo docker ps -a --filter name=observability-loki`(관측 서버)

## 해결 확인

**크킹 관측 파이프라인 → 로그 전송 재시도·버림**에서 버림이 더 늘지 않는다. 경보는 5분 동안 새로 버린 것이 없으면 풀린다.

## 하면 안 되는 것

- 앱 서버 수집기를 재시작하지 않는다([수집 대상 끊김](cking-target-down.md#하면-안-되는-것))

## 운영에서 다른 점

- 운영 수집기도 같은 관측 서버 Loki로 보낸다. 서버 그룹이 서버를 교체하면 그 서버에서 아직 보내지 못한 로그는 서버와 함께 사라진다(버림으로 세지 않는다)
