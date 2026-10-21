# 운영 ElastiCache 경보

> 전제: ElastiCache Valkey 7.2 `prod-cking-redis`(주 2a·복제 2b, 자동 장애 조치, noeviction, TLS), CloudWatch 경보 → SNS `prod-cking-alerts` → 운영 채널(Amazon Q)·인프라 담당 메일

| 경보 | 조건 |
| --- | --- |
| `prod-cking-redis-memory-<노드>` | 메모리 사용률(`DatabaseMemoryUsagePercentage`) 70% 초과 10분 |
| `prod-cking-redis-engine-cpu-<노드>` | 엔진 CPU 80% 초과 10분 |

노드는 `-001`, `-002` 두 개이며 장애 조치로 주 노드가 바뀔 수 있어 둘 다 본다.

## 뜻하는 것

- **메모리**: noeviction이라 100%에 닿으면 응모·적립 쓰기가 거부된다. 부하 테스트 증가 속도(초당 80에서 분당 약 2.4MiB)로 남은 30%는 약 2시간이다. Stream은 처리 뒤에도 자르지 않아 계속 늘어난다
- **엔진 CPU**: Redis는 명령을 한 스레드에서 처리한다. 80%를 넘으면 응답이 늦어지고 Stream 소비도 밀린다

## 먼저 볼 곳

1. Grafana **크킹 Redis·Stream**: Stream 길이, 거부된 명령
2. [운영 상태 확인](stream.md#운영-상태-확인)의 `INFO memory`
3. AWS 콘솔 ElastiCache → 이벤트(장애 조치·유지 관리)

## 원인별 대응

- **메모리가 꾸준히 늘어남**: 응모가 쌓이는 정상 증가다. 노드 크기를 올린다([응모 실패 (Redis 쓰기 거부)](cking-redis-rejected.md#운영에서-다른-점)의 명령). 끝날 때까지 시간이 걸리므로 70%에서 바로 시작한다
- **CPU만 높음**: 요청이 몰렸거나 무거운 명령이다. **크킹 Redis·Stream**의 느린 명령을 본다

## 하면 안 되는 것

- 메모리를 비우려고 키나 Stream을 지우지 않는다([공통](stream.md#공통으로-하면-안-되는-것))
- `maxmemory-policy`를 축출 정책으로 바꾸지 않는다. 잔액 키가 지워진다
