# Redis 메모리

> 전제: 개발 서버 1대(`dev-cking-app`), Docker Compose, Cking-BE `deploy.sh` 배포

`redis_memory_used_bytes / redis_config_maxmemory > 0.7`이 10분 지속될 때.

## 뜻하는 것

Redis 메모리가 한도(256MB)의 70%를 넘었다. 100%에 닿으면 [응모 실패 (Redis 쓰기 거부)](cking-redis-rejected.md)가 된다. 2026-10-18 사용량은 약 2MB다.

## 먼저 볼 곳

1. **크킹 Redis·Stream → 메모리, Stream 길이**: 어느 쪽이 늘었는지
2. 큰 키

```bash
# 앱 서버
sudo docker exec cking-redis redis-cli --bigkeys
```

## 원인별 대응

### 1. Stream이 계속 길어짐

Stream은 자르지 않아 응모·적립마다 늘어난다. BE 담당과 Stream 정리 방식을 정한다. 100%까지 남은 시간은 메모리 그래프 기울기로 가늠한다.

### 2. 다른 키가 늘어남

`--bigkeys`로 찾은 키의 용도를 BE 담당에게 확인한다. 만료(TTL)가 빠진 키일 수 있다.

## 하면 안 되는 것

[응모 실패 (Redis 쓰기 거부)](cking-redis-rejected.md#하면-안-되는-것)와 같다.
