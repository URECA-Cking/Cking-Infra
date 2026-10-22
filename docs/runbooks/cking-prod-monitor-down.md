# 감시용 서버 끊김

> 전제: 감시용 서버 그룹 `prod-cking-monitor`(1대, t4g.micro), 수집기(Alloy)가 ElastiCache 지표(감시 전용 사용자 `cking-monitor`)와 서버 지표를 관측 서버로 보낸다

감시용 서버의 `node`·`redis`·`alloy` 중 하나의 `up`이 0이거나, `redis_up`이 0(ElastiCache에 붙지 못함)이거나, 지표가 없고 5분 지속될 때. 관측 경보(인프라 담당 멘션).

## 뜻하는 것

운영 Redis(ElastiCache)·Stream 지표가 들어오지 않는다. Stream 소비 멈춤·밀림, 처리 실패 누적, 응모 실패(Redis 쓰기 거부) 경보가 조용해진다. 응모 자체에는 영향이 없다.

세 지표는 감시용 서버의 수집기가 서버 안에서 모아 보낸다. 수집기나 전송 경로가 끊기면 셋이 함께 사라진다(지표 없음 경보, `job` 라벨 없음). ElastiCache에 붙지 못하면 `up{job="redis"}`는 1로 남고 `redis_up`만 0이 되므로, `job="redis"`는 둘 중 작은 값으로 본다.

## 먼저 볼 곳

1. 경보 라벨 `job`: `redis`면 ElastiCache 연결, 그 밖이면 그 수집만 0, 없으면 셋 다 끊겼다
2. Grafana Explore(Prometheus)의 `redis_up{instance="prod-cking-monitor"}`
3. 감시용 서버 그룹 상태([서버 찾기](README.md#운영)의 그룹 이름을 `prod-cking-monitor`로)
4. 수집기 로그. Alloy는 로그를 표준 오류로 남기므로 `2>&1`을 붙인다

```bash
# 감시용 서버
sudo docker ps -a --filter name=app-agent-alloy --format '{{.Status}}'
sudo docker logs --tail 100 app-agent-alloy-1 2>&1 | grep -iE 'redis|error'
```

## 원인별 대응

### 1. ElastiCache에 붙지 못함 (`redis_up` 0)

수집기는 살아 있다. 로그에 `WRONGPASS`가 있으면 감시 사용자 비밀번호(`/cking/prod-monitor/REDIS_PASSWORD`)와 ElastiCache 사용자가 어긋난 것이고, `NOPERM`이면 감시 사용자 접근 문자열(`envs/prod/cache.tf`)에 수집기가 쓰는 명령이 없는 것이다. 연결 시간 초과면 ElastiCache 상태(콘솔 이벤트)와 보안 그룹을 본다. `couldn't get info for stream … ERR no such key`는 BE가 Stream을 만들기 전(첫 응모·적립 전)에 나는 로그라 원인이 아니다.

### 2. 서버는 떠 있는데 수집기 컨테이너가 없음

부팅 스크립트가 중간에 실패했다. 감시용 서버 그룹은 시작 대기가 없어 실패한 서버도 정상으로 남는다. 부팅 출력에서 오류를 본다.

```bash
# Mac
aws ec2 get-console-output --region ap-northeast-2 --instance-id <서버> --latest --output text --query Output \
  | grep -E 'An error occurred'
```

`ParameterNotFound`면 `/cking/prod-monitor/`의 값을 확인한다. `REDIS_HOST`·`REDIS_USERNAME`은 `envs/prod` apply가 ElastiCache를 만든 뒤 넣고, `REDIS_PASSWORD`는 사람이 넣는다. 2026-10-22 첫 apply 때 ElastiCache 생성 중에 뜬 서버가 이렇게 멈췄다. 값이 생긴 뒤 서버를 교체한다([서버 교체](README.md#운영)의 명령에 이 서버 ID).

### 3. 전부 없음, 수집기는 떠 있음

[지표 전송 실패](cking-remote-write-failed.md)처럼 피어링·관측 서버 쪽 전송 경로를 본다. 서버가 죽었으면 서버 그룹(EC2 헬스체크)이 새로 띄우고, 새 서버는 부팅하며 수집기를 다시 설정한다.

## 해결 확인

`up{instance="prod-cking-monitor"}`의 `node`·`redis`·`alloy`가 1이고 `redis_up{instance="prod-cking-monitor"}`가 1이다.

## 하면 안 되는 것

- Redis 지표를 보려고 앱 서버 수집기에 Redis 수집을 켜지 않는다. 서버 수만큼 같은 지표가 중복된다
