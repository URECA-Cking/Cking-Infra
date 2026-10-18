# 수집 대상 끊김

> 전제: 앱 서버 수집기(Alloy) → 관측 서버(`dev-cking-observability`, Docker Compose)

앱 서버의 `node`·`redis`·`alloy` 중 하나의 `up`이 0이거나 지표가 없고 5분 지속될 때.

## 뜻하는 것

앱 서버의 서버·Redis·수집기 지표가 들어오지 않는다. 이 지표를 쓰는 다른 경보(서버 메모리, 디스크, Redis, Stream)가 조용해질 수 있다.

## 먼저 볼 곳

1. 경보 라벨 `job`: 하나만 빠졌는지, 전부 빠졌는지
2. 앱 서버 수집기 상태

```bash
# 앱 서버
sudo docker ps -a --filter name=app-agent-alloy --format '{{.Status}}'
sudo docker logs --tail 100 app-agent-alloy-1
```

## 원인별 대응

### 1. 하나만 0 (`redis` 등)

수집기는 살아 있고 대상만 응답하지 않는다. `redis`면 `cking-redis` 컨테이너 상태를 본다.

### 2. 전부 없음, 수집기 컨테이너는 떠 있음

관측 서버로 보내지 못하는 상태다. 수집기 로그에 `connection refused`, `context deadline exceeded`가 보인다. 관측 서버 쪽을 먼저 본다.

```bash
# 관측 서버
sudo docker ps --format '{{.Names}} {{.Status}}'
```

관측 서버가 돌아오면 수집기가 쌓아 둔 지표와 로그를 이어서 보낸다.

### 3. 수집기 컨테이너가 멈춤

`sudo docker start app-agent-alloy-1`. 반복되면 `docker inspect`의 `OOMKilled`를 본다(상한 256MiB).

### 4. 앱 서버 자체 문제

SSM 접속이 안 되면 [인스턴스 상태 검사](ec2-instance-check.md).

## 하면 안 되는 것

- **관측 서버와 끊긴 동안 앱 서버 수집기를 재시작하지 않는다.** 보내지 못하고 메모리에 쌓아 둔 로그를 잃는다(끊김 실험 #34). 관측 서버 쪽을 먼저 고친다
