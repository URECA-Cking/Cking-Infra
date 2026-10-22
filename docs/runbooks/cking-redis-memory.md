# Redis 메모리

> 전제: 개발 서버 1대(`dev-cking-app`), Docker Compose, Cking-BE `deploy.sh` 배포

`redis_memory_used_bytes / redis_config_maxmemory > 0.7`이 10분 지속될 때.

## 뜻하는 것

Redis 메모리가 한도(256MB)의 70%를 넘었다. 100%에 닿으면 [응모 실패 (Redis 쓰기 거부)](cking-redis-rejected.md)가 된다. 2026-10-22 사용량은 약 2.3MB다.

응모 한 건은 중복 차감 방지 키(`entry:spend-guard:*`, 200B, 70분)와 멱등 키(`idem:*`, 248B, 60분)를 남긴다. 같은 속도가 70분 넘게 이어지면 메모리는 초당 건수 × 1.7\~2.1MB에서 멈춘다(부하 테스트 2차 계산값). 256MB의 70%는 초당 약 85\~105건이 이어지면 닿는다. Stream은 30초마다 처리가 끝난 앞쪽을 지운다([Redis Stream 공통](stream.md#구조)).

## 먼저 볼 곳

1. **크킹 Redis·Stream → 메모리, Stream 길이**: Stream이 늘었는지, Stream 길이는 그대로인데 메모리만 늘었는지
2. **크킹 서비스 개요 → 요청량 (결과별)**: 응모가 몰렸는지
3. 큰 키

```bash
# 앱 서버
sudo docker exec cking-redis redis-cli --bigkeys
```

## 원인별 대응

### 1. 응모가 몰림

Stream 길이는 그대로이고 메모리가 응모량을 따라 올랐다. 키는 만료되므로 몰림이 끝나면 70분 안에 내려온다. 몰림이 이어지고 메모리 그래프 기울기로 본 100%까지 남은 시간이 짧으면, [응모 실패 (Redis 쓰기 거부)](cking-redis-rejected.md#1-메모리-한도-도달)의 임시 한도 올림을 미리 한다.

### 2. Stream이 계속 길어짐

**Stream 길이**가 줄지 않고 늘어난다. 정리가 멈췄거나, pending에 남은 메시지 앞에서 멈췄다(정리는 가장 오래된 pending 앞까지만 지운다).

- pending이 0보다 크면 [처리 실패 누적](cking-stream-pending.md)
- **크킹 로그**에 `처리가 끝난 Stream 메시지를 지우지 못했습니다`(WARN)가 있으면 그 예외로 BE 이슈를 만든다

### 3. 다른 키가 늘어남

`--bigkeys`로 찾은 키의 용도를 BE 담당에게 확인한다. 만료(TTL)가 빠진 키일 수 있다.

## 해결 확인

**크킹 Redis·Stream → 메모리**가 한도의 70% 아래로 내려온다.

## 하면 안 되는 것

[응모 실패 (Redis 쓰기 거부)](cking-redis-rejected.md#하면-안-되는-것)와 같다.
