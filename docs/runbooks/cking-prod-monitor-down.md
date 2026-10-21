# 감시용 서버 끊김

> 전제: 감시용 서버 그룹 `prod-cking-monitor`(1대, t4g.micro), 수집기(Alloy)가 ElastiCache 지표(감시 전용 사용자 `cking-monitor`)와 서버 지표를 관측 서버로 보낸다

감시용 서버의 `node`·`redis`·`alloy` 중 하나의 `up`이 0이거나 지표가 없고 5분 지속될 때. 관측 경보(인프라 담당 멘션).

## 뜻하는 것

운영 Redis(ElastiCache)·Stream 지표가 들어오지 않는다. Stream 소비 멈춤·밀림, 처리 실패 누적, 응모 실패(Redis 쓰기 거부) 경보가 조용해진다. 응모 자체에는 영향이 없다.

## 먼저 볼 곳

1. 경보 라벨 `job`: `redis`만 빠졌는지, 전부 빠졌는지
2. 감시용 서버 그룹 상태([서버 찾기](README.md#운영)의 그룹 이름을 `prod-cking-monitor`로)
3. 수집기 로그

```bash
# 감시용 서버
sudo docker ps -a --filter name=app-agent-alloy --format '{{.Status}}'
sudo docker logs --tail 100 app-agent-alloy-1 | grep -iE 'redis|error'
```

## 원인별 대응

### 1. `redis`만 0

수집기는 살아 있고 ElastiCache에 붙지 못한다. 로그에 인증 실패(`WRONGPASS`, `NOPERM`)가 있으면 감시 사용자 비밀번호(`/cking/prod-monitor/REDIS_PASSWORD`)와 ElastiCache 사용자가 어긋난 것이다. 연결 시간 초과면 ElastiCache 상태(콘솔 이벤트)와 보안 그룹을 본다.

### 2. 전부 없음

서버가 죽었으면 서버 그룹(EC2 헬스체크)이 새로 띄운다. 새 서버는 부팅하며 수집기를 다시 설정한다. 서버는 떠 있는데 전부 없으면 [지표 전송 실패](cking-remote-write-failed.md)처럼 전송 경로를 본다.

## 하면 안 되는 것

- Redis 지표를 보려고 앱 서버 수집기에 Redis 수집을 켜지 않는다. 서버 수만큼 같은 지표가 중복된다
