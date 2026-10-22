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
- 소비자는 서버마다 응모 Stream 4개(`spend-<인스턴스 ID>-0`부터 `-3`까지, 한 번에 10건씩), 적립 Stream 1개씩(`earn-<인스턴스 ID>`, `common-earn-<인스턴스 ID>`)이다. 1시간 넘게 읽으러 오지 않은 소비자(떠난 서버)는 10분마다 정리된다
- 읽고 처리에 실패한 메시지는 PEL(pending)에 남는다. 30초마다 PEL 회수 스케줄러가 60초 넘게 남은 메시지를 서버들이 같이 쓰는 재처리 소비자(`spend-pel-recovery` 등)로 가져와 다시 처리하고, 전달 횟수가 5회를 넘으면 MySQL `dead_stream_message`로 옮긴 뒤 ACK한다
- 30초마다 모든 그룹이 처리를 끝낸 앞쪽 메시지를 Stream에서 지운다. pending이 남아 있으면 가장 오래된 pending 앞까지만 지운다. 지우지 못하면 앱 로그에 `처리가 끝난 Stream 메시지를 지우지 못했습니다`(WARN)가 남는다

## 상태 확인

**크킹 Redis·Stream** 대시보드: lag, pending, 소비자 수, Stream 길이.

```bash
# 앱 서버
sudo docker exec cking-redis redis-cli XINFO GROUPS stream:ticket-earned
sudo docker exec cking-redis redis-cli XINFO CONSUMERS stream:ticket-earned cg:ticket-earn
sudo docker exec cking-redis redis-cli XPENDING stream:ticket-earned cg:ticket-earn
```

다른 Stream은 위 표의 Stream·그룹 이름으로 바꾼다. 응모는 `stream:ticket-deducted cg:ticket-history`다.

- `XINFO GROUPS`: `lag`(아직 안 읽음), `pending`(읽었지만 ACK 전), `last-delivered-id`
- `XINFO CONSUMERS`: 소비자별 `idle`(마지막으로 읽으러 온 뒤 지난 ms)

## 운영 상태 확인

운영 Redis는 ElastiCache(TLS, 사용자 인증)라 서버에 `redis-cli`가 없다. 앱 서버에서 Valkey 이미지의 `valkey-cli`로 앱 사용자(`cking-app`)로 접속한다. 감시용 사용자는 `XPENDING`이 막혀 있다. 비밀번호는 환경변수(`REDISCLI_AUTH`)로만 넘겨 화면·명령 인자·셸 기록에 남기지 않는다. 서버의 sudo(sudo-rs)는 `-E`를 무시하므로 `--preserve-env=REDISCLI_AUTH`로 그 변수만 넘긴다(`-E`면 `NOAUTH`).

```bash
# 운영 앱 서버
export REDIS_HOST=$(aws ssm get-parameter --region ap-northeast-2 --name /cking/prod/REDIS_HOST --query Parameter.Value --output text)
export REDISCLI_AUTH=$(aws ssm get-parameter --region ap-northeast-2 --name /cking/prod/REDIS_PASSWORD --with-decryption --query Parameter.Value --output text)
vk() { sudo --preserve-env=REDISCLI_AUTH docker run --rm -e REDISCLI_AUTH -v /etc/ssl/certs/ca-certificates.crt:/ca.crt:ro valkey/valkey:7.2 \
  valkey-cli --tls --cacert /ca.crt -h "$REDIS_HOST" --user cking-app "$@"; }
vk XINFO GROUPS stream:ticket-earned
vk XINFO CONSUMERS stream:ticket-earned cg:ticket-earn
vk XPENDING stream:ticket-earned cg:ticket-earn
vk INFO memory | grep -E '^(used_memory_human|maxmemory_human)'
unset REDISCLI_AUTH
```

- 앱 사용자는 모든 명령을 쓸 수 있다. 조회 명령만 쓴다
- 소비자 이름은 서버별(인스턴스 ID)이다. 교체로 사라진 서버의 소비자는 앱이 정리하기 전까지 목록에 남는다

## 공통으로 하면 안 되는 것

- **Stream·소비자 그룹을 지우거나(`DEL`, `XGROUP DESTROY`) 자르지(`XTRIM`) 않는다.** 아직 DB에 반영되지 않은 응모·적립이 사라진다
- `XACK`로 pending을 직접 지우지 않는다. 처리하지 않은 메시지를 처리한 것으로 표시하게 된다
- Redis를 재시작하지 않는다. AOF(`appendfsync everysec`)라 최대 1초의 쓰기를 잃을 수 있고, 재시작 중 응모가 실패한다. 운영 ElastiCache는 노드 재부팅·수동 장애 조치를 하지 않는다. 복제가 비동기라 넘어가기 직전의 쓰기를 잃을 수 있다
