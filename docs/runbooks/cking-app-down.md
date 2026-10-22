# 앱 중단

> 전제: 개발 서버 1대(`dev-cking-app`), Docker Compose, Cking-BE `deploy.sh` 배포

`max(up{job="cking-be", instance="dev-cking-app"}) < 1`이 2분 지속되거나 지표가 아예 없을 때. 급함(`@channel`).

## 뜻하는 것

관측 서버가 앱 지표(관리 포트 8081)를 2분째 받지 못했다. 앱이 죽었거나, 앱은 살아 있는데 수집 경로가 끊긴 경우다. 앱이 죽었다면 모든 API가 실패한다(ALB 오류 응답).

정상 배포에서는 울리지 않는다. 앱 기동은 최대 37초(2026-10-16 기준 7일 재시작 55회)라 2분보다 짧다.

## 먼저 볼 곳

1. **크킹 서비스 개요 → 수집 대상**: 앱만 빠졌는지, 같은 서버의 node·redis·alloy도 함께 빠졌는지 본다
   - 앱만 빠짐 → 앱 문제. 아래 1~3
   - 넷 다 빠짐 → 앱 서버 또는 수집기 문제. 아래 4, [수집 대상 끊김](cking-target-down.md)도 함께 울린다
2. **앱 서버**에서 앱 상태를 본다

```bash
# 앱 서버
sudo docker ps -a --filter name=cking-app --format '{{.Status}} {{.Image}}'
sudo docker inspect cking-app --format 'OOMKilled={{.State.OOMKilled}} ExitCode={{.State.ExitCode}} Restarts={{.RestartCount}}'
curl -s localhost:8080/readyz
sudo docker logs --tail 200 cking-app
```

## 원인별 대응

### 1. 배포 직후 기동 실패

직전에 Cking-BE 배포가 있었고 `Restarts`가 계속 오른다. 로그에 설정 누락(`... 지정되지 않았습니다`), Flyway 마이그레이션 오류, 빈 생성 실패가 보인다.

→ [배포 실패](deploy-failed.md)의 "이전 버전으로 되돌리기". 원인 수정은 BE PR로 한다.

### 2. 메모리 부족으로 종료

`ExitCode=3`(JVM `-XX:+ExitOnOutOfMemoryError`) 또는 `OOMKilled=true`(컨테이너 상한 1000MiB 초과). `restart: unless-stopped`라 다시 뜨지만 같은 요청이 반복되면 다시 죽는다.

→ **크킹 앱 → 힙·힙 밖**에서 종료 직전 추세를 보고, 로그에서 종료 직전 요청을 찾아 BE 이슈를 만든다. 힙(460MiB)·컨테이너 상한 조정은 BE `docker-compose.dev.yml` PR로 한다.

### 3. DB·Redis 연결 실패로 기동 실패

직전 배포가 없는데 `Restarts`가 오르고, 로그에 `Connection refused`, `Communications link failure`가 보인다.

- Redis: `sudo docker ps -a --filter name=cking-redis`. 멈췄으면 `sudo docker start cking-redis` (compose 명령은 앱 환경변수가 없어 실패한다)
- RDS: **크킹 서버 → RDS CPU·RDS 연결 수**, AWS 콘솔 RDS 이벤트(재부팅·유지 관리)

컨테이너가 떠 있고 `/readyz`만 `DOWN`이면 앱 지표는 들어오므로 이 경보는 울리지 않는다. 그 상태는 [서버 오류 증가](cking-5xx.md#3-전체-uri가-실패)로 본다.

### 4. 앱 서버 또는 수집기 문제

수집 대상 넷이 함께 빠졌다.

- SSM 접속이 안 됨 → 서버 자체 문제. [인스턴스 상태 검사](ec2-instance-check.md)
- 접속되고 `curl localhost:8080/readyz`가 `UP` → 앱은 정상, 수집 경로 문제. [수집 대상 끊김](cking-target-down.md)

## 해결 확인

**크킹 서비스 개요 → 수집 대상**에 앱이 돌아오고, 앱 서버에서 `curl -s localhost:8080/readyz`가 `{"status":"UP"}`이다.

## 하면 안 되는 것

- **Redis 볼륨(`cking_redis-data`)을 지우지 않는다**(`docker compose down -v`, `docker volume rm`·`prune`). 지우면 응모권 잔액과 처리 전 Stream 메시지가 사라진다
- 서버에서 `docker compose up`을 직접 실행하지 않는다. 환경변수는 `deploy.sh`가 Parameter Store에서 넣으므로 직접 실행하면 `:?` 검사로 실패한다. 버전 교체는 `deploy.sh <태그>`로 한다
- 수집 경로 문제일 때 앱을 재시작하지 않는다. 앱은 정상이고 재시작 동안만 실제 장애가 생긴다
