# Stream 밀림

> 전제: 개발 서버 1대(`dev-cking-app`), Docker Compose, Cking-BE `deploy.sh` 배포

`max by (stream) (redis_stream_group_lag) > 0`이 5분 지속될 때. 급함(`@channel`).

## 뜻하는 것

Stream에 아직 읽지 않은 메시지가 5분째 남아 있다. DB 반영이 그만큼 늦다. 7일 최대값은 0이다. 구조는 [Redis Stream 공통](stream.md).

## 먼저 볼 곳

1. [Stream 소비 멈춤](cking-stream-stopped.md)도 울렸는지. 함께 울렸으면 그쪽이 원인이다
2. **크킹 Redis·Stream → lag**: 줄어드는 중인지, 그대로인지, 늘어나는지
3. **크킹 앱 → Hikari 연결, 연결 획득 평균 시간**, **크킹 서버 → RDS CPU**: DB 쓰기가 느린지

## 원인별 대응

### 1. 소비자가 멈춤

[Stream 소비 멈춤](cking-stream-stopped.md)을 따른다.

### 2. 소비자는 읽는데 처리가 느림

idle은 짧은데 lag가 줄지 않는다. 소비자는 Stream마다 1개(동시 처리 1)라 메시지마다 DB 쓰기 시간이 그대로 쌓인다.

- 요청이 몰린 직후라 lag가 줄어드는 중이면 지켜본다
- DB가 느리면 [DB 연결 대기](cking-hikari-pending.md)
- 늘어나기만 하면 BE 담당에게 알린다. 소비자 수 조정은 BE 코드 변경이다

### 3. 처리 실패가 반복됨

로그에 처리 실패가 반복되고 pending도 늘어난다 → [처리 실패 누적](cking-stream-pending.md).

## 하면 안 되는 것

[공통](stream.md#공통으로-하면-안-되는-것)과 같다.

## 운영에서 다른 점

- 소비자는 서버마다 하나라, 처리가 느릴 때 서버 대수를 늘리면 동시 처리가 는다. DB가 병목이면 효과가 없으므로 RDS CPU(CloudWatch)를 먼저 본다
- 대수 조정: `aws autoscaling set-desired-capacity --region ap-northeast-2 --auto-scaling-group-name prod-cking-app --desired-capacity 3` (최대 4). 목표 추적 정책이 CPU 기준으로 다시 줄일 수 있다
