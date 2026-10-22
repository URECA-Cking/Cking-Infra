# Redis 연결 끊김

> 전제: 개발 서버 1대(`dev-cking-app`), Docker Compose, Cking-BE `deploy.sh` 배포. 앱 서버 수집기가 같은 Docker 네트워크의 `redis:6379`를 읽는다

`min(redis_up{instance="dev-cking-app"}) < 1`이 1분 지속될 때. 급함(`@channel`).

## 뜻하는 것

앱 서버 수집기가 Redis에 붙지 못한다. Redis가 멈췄으면 응모·적립의 잔액 변경과 Stream 기록이 실패하고, Stream·Redis 지표가 끊겨 [Stream 소비 멈춤](cking-stream-stopped.md) 같은 경보는 조용해진다. 수집기 안의 Redis 수집이라 이때도 `up{job="redis"}`는 1이므로 [수집 대상 끊김](cking-target-down.md)은 울리지 않는다.

Redis 재시작은 15초 수집 간격 안에 끝나 1분 조건에 걸리지 않는다(30일 동안 재시작 2번, `redis_up` 0 기록 없음).

## 먼저 볼 곳

```bash
# 앱 서버
sudo docker ps -a --filter name=cking-redis --format '{{.Status}}'
sudo docker logs --tail 50 cking-redis
curl -s localhost:8080/readyz
sudo docker logs --tail 100 app-agent-alloy-1 2>&1 | grep -i redis
```

## 원인별 대응

### 1. Redis 컨테이너가 멈춤

`Exited`면 `sudo docker start cking-redis`. compose 명령은 앱 환경변수가 없어 실패한다. 로그 끝에서 멈춘 이유(메모리, AOF 오류)를 본다. 앱은 다시 연결하고 소비자는 마지막 위치부터 이어 읽는다.

### 2. Redis는 떠 있는데 수집기만 붙지 못함

`/readyz`가 `UP`이면 응모는 정상이고 수집만 실패한다. 수집기 로그의 Redis 오류를 보고, 수집기 설정(`app-agent/redis.alloy`)이나 컨테이너 네트워크를 본다.

## 해결 확인

Grafana Explore(Prometheus)에서 `redis_up{instance="dev-cking-app"}`가 1이고 `curl -s localhost:8080/readyz`가 `{"status":"UP"}`이다.

## 하면 안 되는 것

- **Redis 볼륨(`cking_redis-data`)을 지우지 않는다**(`docker compose down -v`, `docker volume rm`·`prune`). 응모권 잔액과 처리 전 Stream 메시지가 사라진다
- [공통](stream.md#공통으로-하면-안-되는-것)과 같다

## 운영에서 다른 점

- 운영에는 이 경보가 없다. 감시용 서버가 ElastiCache에 붙지 못하면 [감시용 서버 끊김](cking-prod-monitor-down.md)이 울린다. ElastiCache 자체가 멈추면 앱 서버 `/readyz`가 실패해 [운영 ALB 경보](prod-alb.md)가 함께 울린다
