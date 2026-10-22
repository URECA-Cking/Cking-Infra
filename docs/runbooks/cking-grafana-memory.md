# Grafana 메모리

> 전제: 앱 서버 수집기(Alloy) → 관측 서버(`dev-cking-observability`, Docker Compose)

Grafana 본체 RSS가 GOMEMLIMIT(512MiB)의 95%를 넘고 10분 지속될 때.

## 뜻하는 것

Grafana 본체가 메모리 목표치에 계속 붙어 있다. GC가 잦아져 화면이 느려지고, 플러그인 프로세스까지 더해 컨테이너 상한(640MiB)을 넘으면 강제 종료된다. 7일 중앙값은 201MiB, 사람이 쓸 때 428~458MiB다(#72, #74).

## 먼저 볼 곳

1. **크킹 관측 파이프라인 → 프로그램 메모리**: 오르기 시작한 시각
2. 그 시각에 누가 무엇을 봤는지: 긴 시간 범위의 로그 조회, 여러 대시보드 동시 열기

## 대응

- 일시적이면(큰 조회 뒤 내려옴) 지켜본다
- 계속 붙어 있으면 관측 서버 사양 상향(t4g.small → t4g.medium)을 검토한다. 플러그인은 GOMEMLIMIT 밖이라 상한만 올리면 서버 전체가 모자란다
- 강제 종료됐으면 `restart: unless-stopped`로 다시 뜬다. `sudo docker inspect observability-grafana-1 --format '{{.State.OOMKilled}}'`(관측 서버)

## 해결 확인

**크킹 관측 파이프라인 → 프로그램 메모리 (RSS)**에서 Grafana가 486MiB(GOMEMLIMIT의 95%) 아래로 내려온다.

## 하면 안 되는 것

- GOMEMLIMIT만 올리지 않는다. 플러그인 몫(약 63MiB)이 상한 안에 들어가지 않게 된다(#74)
