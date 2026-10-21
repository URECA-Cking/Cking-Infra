# 응모 실패 (Redis 쓰기 거부)

> 전제: 개발 서버 1대(`dev-cking-app`), Docker Compose, Cking-BE `deploy.sh` 배포

`increase(redis_commands_rejected_calls_total[5m]) > 0`일 때. 급함(`@channel`).

## 뜻하는 것

Redis가 명령을 거부했다. 가장 흔한 원인은 메모리 한도(`maxmemory 256mb`, `noeviction`) 도달이다. 이때 응모·적립의 잔액 변경과 Stream 기록(`XADD`)이 실패한다.

## 먼저 볼 곳

1. **크킹 Redis·Stream → 메모리, 거부·실패한 명령, Stream 길이**
2. Redis 상태

```bash
# 앱 서버
sudo docker exec cking-redis redis-cli INFO memory | grep -E '^(used_memory_human|maxmemory_human)'
sudo docker exec cking-redis redis-cli INFO commandstats | grep -E 'rejected_calls=[1-9]'
sudo docker logs --tail 50 cking-redis
```

## 원인별 대응

### 1. 메모리 한도 도달

`used_memory`가 `maxmemory`에 닿았다. Stream은 자르지 않아 기록이 계속 쌓인다.

- 서버 여유 메모리를 확인한다(`free -m`). 여유가 있으면 임시로 한도를 올려 응모를 살린다. 재시작하면 원래 값(256MB)으로 돌아간다

```bash
# 앱 서버
sudo docker exec cking-redis redis-cli CONFIG SET maxmemory 384mb
```

- 영구 조치는 BE 담당과 정한다: Stream 정리 방식(처리 끝난 메시지 자르기) 또는 `docker-compose.dev.yml`의 한도 변경

### 2. 메모리는 여유인데 거부됨

`INFO commandstats`에서 어떤 명령이 거부됐는지 본다. 잘못된 명령·타입이면 앱 코드 문제라 BE 이슈를 만든다.

## 하면 안 되는 것

- `maxmemory-policy`를 축출 정책(`allkeys-lru` 등)으로 바꾸지 않는다. 잔액 키가 지워진다
- 메모리를 비우려고 키나 Stream을 지우지 않는다([공통](stream.md#공통으로-하면-안-되는-것))
- 서버 여유 메모리를 넘겨 한도를 올리지 않는다. 앱 서버 전체가 메모리 부족에 빠진다

## 운영에서 다른 점

- ElastiCache는 `CONFIG SET`을 막아 한도를 즉시 올릴 수 없다. 메모리 사용률은 CloudWatch(ElastiCache 메모리 경보)나 [운영 상태 확인](stream.md#운영-상태-확인)의 `INFO memory`로 본다
- 한도를 올리려면 노드 크기를 올린다. 요청 중에도 진행되지만 끝날 때까지 시간이 걸린다: `aws elasticache modify-replication-group --region ap-northeast-2 --replication-group-id prod-cking-redis --cache-node-type <더 큰 크기> --apply-immediately`. 그 뒤 Terraform `envs/prod/cache.tf`의 크기를 같은 값으로 맞춘다
- 파라미터 그룹의 `maxmemory-policy`(noeviction)를 바꾸지 않는다
