# Redis Stream 공통

> 전제: 개발 서버 1대(`dev-cking-app`), Docker Compose, Cking-BE `deploy.sh` 배포

[Stream 소비 멈춤](cking-stream-stopped.md), [Stream 밀림](cking-stream-lag.md), [처리 실패 누적](cking-stream-pending.md), [Dead Stream 이동](cking-dead-stream.md)이 함께 보는 내용.

## 구조

| Stream | 소비자 그룹 | 내용 |
| --- | --- | --- |
| `stream:ticket-earned` | `cg:ticket-earn` | 크리에이터 응모권 적립 |
| `stream:common-ticket-earned` | `cg:common-ticket-earn` | 공용 응모권 적립 |
| `stream:ticket-deducted` | `cg:ticket-history` | 응모(응모권 차감) |

- 응모·적립 요청은 Redis 잔액을 바꾸고 Stream에 기록한 뒤 바로 응답한다. 앱의 소비자가 Stream을 읽어 MySQL에 반영한다
- 소비자가 멈추거나 밀리면 응모·적립은 계속 성공하지만 DB 반영이 늦어진다. 마감 시각에 DB에 반영되지 않은 응모는 추첨 스냅샷에서 빠질 수 있다
- 읽고 처리에 실패한 메시지는 PEL(pending)에 남는다. 30초마다 PEL 회수 스케줄러가 60초 넘게 남은 메시지를 다시 처리하고, 전달 횟수가 5회를 넘으면 MySQL `dead_stream_message`로 옮긴 뒤 ACK한다

## 상태 확인

**크킹 Redis·Stream** 대시보드: lag, pending, 소비자 수, Stream 길이.

```bash
# 앱 서버
sudo docker exec cking-redis redis-cli XINFO GROUPS stream:ticket-earned
sudo docker exec cking-redis redis-cli XINFO CONSUMERS stream:ticket-earned cg:ticket-earn
sudo docker exec cking-redis redis-cli XPENDING stream:ticket-earned cg:ticket-earn
```

- `XINFO GROUPS`: `lag`(아직 안 읽음), `pending`(읽었지만 ACK 전), `last-delivered-id`
- `XINFO CONSUMERS`: 소비자별 `idle`(마지막으로 읽으러 온 뒤 지난 ms)

## 공통으로 하면 안 되는 것

- **Stream·소비자 그룹을 지우거나(`DEL`, `XGROUP DESTROY`) 자르지(`XTRIM`) 않는다.** 아직 DB에 반영되지 않은 응모·적립이 사라진다
- `XACK`로 pending을 직접 지우지 않는다. 처리하지 않은 메시지를 처리한 것으로 표시하게 된다
- Redis를 재시작하지 않는다. AOF(`appendfsync everysec`)라 최대 1초의 쓰기를 잃을 수 있고, 재시작 중 응모가 실패한다
