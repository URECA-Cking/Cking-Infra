# 서버 오류 증가

> 전제: 개발 서버 1대(`dev-cking-app`), Docker Compose, Cking-BE `deploy.sh` 배포

5xx 응답이 전체 요청의 5%를 넘고 5분 지속될 때. 요청이 초당 0.1건 이상일 때만 판단한다(헬스체크 `/readyz` 제외). 급함(`@channel`).

## 뜻하는 것

사용자 요청 일부가 서버 오류로 실패하고 있다. 7일 5xx는 18건이다.

## 먼저 볼 곳

1. **크킹 앱 → 상태 코드별 요청량, URI별 p95**: 어느 URI에서 나는지
2. **크킹 로그**에서 레벨 `ERROR`: 예외와 URI
3. 직전 배포 여부: Cking-BE Actions의 최근 `Deploy to dev server`

## 원인별 대응

### 1. 직전 배포 뒤 시작됨

→ 이전 버전으로 되돌린다([배포 실패](deploy-failed.md#이전-버전으로-되돌리기)). 원인 수정은 BE PR로 한다.

### 2. 특정 URI만 실패

로그의 예외로 BE 이슈를 만든다. 외부 API(구독 인증 Gemini, OpenAI 등)를 부르는 URI면 외부 서비스 상태도 본다.

### 3. 전체 URI가 실패

DB·Redis 연결 문제일 가능성이 크다. [DB 연결 대기](cking-hikari-pending.md), [응모 실패 (Redis 쓰기 거부)](cking-redis-rejected.md)가 함께 울렸는지 본다.

Redis가 멈추면 Redis 지표가 끊겨 두 경보가 울리지 않을 수 있다. 그때는 [Redis 연결 끊김](cking-redis-down.md)이 울린다. 직접 본다.

```bash
# 앱 서버
curl -s localhost:8080/readyz
sudo docker ps -a --filter name=cking-redis --format '{{.Status}}'
```

Grafana Explore(Prometheus)의 `redis_up{instance="dev-cking-app"}`가 0이어도 Redis에 붙지 못한 것이다. 컨테이너가 멈췄으면 `sudo docker start cking-redis`.

## 해결 확인

**크킹 앱 → 상태 코드별 요청량**에서 5xx가 사라지고 경보가 풀린다.

## 하면 안 되는 것

- 원인을 보기 전에 앱을 재시작하지 않는다. 메모리 상태와 진행 중인 요청이 사라져 원인을 찾기 어려워지고, 코드·설정 문제면 재시작 뒤에도 그대로다

## 운영에서 다른 점

- 운영 앱 서버 전체 합으로 판단한다. **크킹 앱**에서 환경을 운영으로 두고 서버를 한 대씩 골라 한 서버에서만 나는지 본다. 한 서버만이면 로그를 본 뒤 그 서버를 교체한다([운영](README.md#운영))
- 직전 배포는 Cking-BE Actions `Deploy to prod`로 확인하고, 되돌리기는 [운영 앱 배포](deploy-failed.md#운영-앱-배포-cking-be-deploy-to-prod)를 따른다
- 앱까지 오지 못한 ALB의 502·504는 이 경보에 잡히지 않는다. CloudWatch ALB 5xx 경보가 맡는다
- Redis는 ElastiCache다. `redis_up{instance="prod-cking-monitor"}`와 AWS 콘솔 ElastiCache 이벤트(장애 조치·유지 관리)로 본다
