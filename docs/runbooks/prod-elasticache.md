# 운영 ElastiCache 경보

> 전제: ElastiCache Valkey 7.2 `prod-cking-redis`(주 2a·복제 2b, 자동 장애 조치, noeviction, TLS), CloudWatch 경보 → SNS `prod-cking-alerts` → 운영 채널(Amazon Q)·인프라 담당 메일

| 경보 | 조건 |
| --- | --- |
| `prod-cking-redis-memory-<노드>` | 메모리 사용률(`DatabaseMemoryUsagePercentage`) 70% 초과 10분 |
| `prod-cking-redis-engine-cpu-<노드>` | 엔진 CPU 80% 초과 10분 |

노드는 `-001`, `-002` 두 개이며 장애 조치로 주 노드가 바뀔 수 있어 둘 다 본다.

## 뜻하는 것

- **메모리**: noeviction이라 100%에 닿으면 응모·적립 쓰기가 거부된다. 응모 한 건이 남기는 보호 키(200B, 70분)와 중복 방지 키(248B, 60분)는 만료되고 Stream은 정리되므로, 같은 속도가 이어지면 메모리는 초당 건수 × 1.7\~2.1MB에서 멈춘다(부하 테스트 2차 계산값). 초당 80이면 약 140\~170MB, 150이면 약 260\~320MB다. cache.t4g.small(데이터에 약 1GiB)에서 70%는 초당 약 370\~450건이 이어져야 닿으므로, 울리면 정상 증가보다 이상을 먼저 의심한다
  - 만료 없는 잔액 키(64B × 회원·크리에이터 조합 수)가 크게 늘었는지
  - Stream 길이가 계속 늘어나는지(정리 스케줄러 멈춤)
  - 응모 속도 자체가 위 범위를 넘었는지
- **엔진 CPU**: Redis는 명령을 한 스레드에서 처리한다. 80%를 넘으면 응답이 늦어지고 Stream 소비도 밀린다

## 먼저 볼 곳

1. Grafana **크킹 Redis·Stream**: Stream 길이, 거부된 명령
2. [운영 상태 확인](stream.md#운영-상태-확인)의 `INFO memory`
3. AWS 콘솔 ElastiCache → 이벤트(장애 조치·유지 관리)

## 원인별 대응

- **Stream 길이가 계속 늘어남**: 정리가 멈췄거나 pending에 남은 메시지 앞에서 멈췄다(정리는 가장 오래된 pending 앞까지만 지운다). pending이 있으면 [처리 실패 누적](cking-stream-pending.md), 앱 로그에 `처리가 끝난 Stream 메시지를 지우지 못했습니다`(WARN)가 있으면 BE 담당에게 알린다
- **잔액 키가 크게 늘어남**: 회원·크리에이터 조합이 늘어난 정상 증가다. 노드 크기를 올린다([응모 실패 (Redis 쓰기 거부)](cking-redis-rejected.md#운영에서-다른-점)의 명령). 끝날 때까지 시간이 걸리므로 바로 시작한다
- **응모 속도가 위 범위를 넘음**: 같은 속도가 이어지면 메모리가 더 오르므로 노드 크기를 올린다
- **CPU만 높음**: 요청이 몰렸거나 무거운 명령이다. **크킹 Redis·Stream → 명령 평균 시간 (Redis 쪽), 명령 p99 (Redis 쪽)**에서 어느 명령인지 본다

## 해결 확인

CloudWatch 경보가 OK로 돌아온다(운영 채널에 OK 알림이 온다).

## 하면 안 되는 것

- 메모리를 비우려고 키나 Stream을 지우지 않는다([공통](stream.md#공통으로-하면-안-되는-것))
- `maxmemory-policy`를 축출 정책으로 바꾸지 않는다. 잔액 키가 지워진다
