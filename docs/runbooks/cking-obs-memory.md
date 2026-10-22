# 관측 프로그램 메모리

> 전제: 앱 서버·추천 배치 서버 수집기(Alloy) → 관측 서버(`dev-cking-observability`, Docker Compose). 관측 서버 자신의 수집기(`instance="alloy:12345"`)도 같은 경보로 본다

Prometheus(상한 512MiB)·Loki(384MiB)의 RSS, Alloy(256MiB)가 Go 런타임에서 쓰는 메모리(`go_memstats_sys_bytes - go_memstats_heap_released_bytes`)가 컨테이너 상한의 95%를 넘고 5분 지속될 때.

## 뜻하는 것

곧 컨테이너 상한에 닿아 강제 종료(OOM)된다. Prometheus·Loki가 죽으면 지표·로그 저장이 멈추고, 수집기가 재시도하며 쌓는다.

## 먼저 볼 곳

1. 경보 라벨 `job`, `instance`(관측 서버 것인지, 앱 서버·추천 배치 서버 수집기인지)
2. **크킹 관측 파이프라인 → 프로그램 메모리, Prometheus 시계열 수, Loki 유입량**

## 원인별 대응

- **Prometheus, 시계열 수가 늘어남**: 고유값이 많은 라벨(사용자 ID, 전체 URL)이 지표에 들어왔다. 늘어난 지표 이름을 찾아 수집 설정에서 버리거나 BE에서 라벨을 고친다
- **Loki, 유입량이 늘어남**: 앱 로그가 갑자기 많아졌다. **크킹 로그**에서 반복되는 줄을 찾는다
- **Alloy(앱 서버·추천 배치 서버)**: 관측 서버와 오래 끊겨 보낼 데이터가 쌓였다. [수집 대상 끊김](cking-target-down.md). 아래로 컨테이너 사용량을 함께 본다
- 원인이 정상 증가면 `observability/compose.yaml`의 `mem_limit`을 PR로 올린다. 관측 서버 전체 메모리(1,834MiB, swap 없음)를 넘지 않게 계산한다

```bash
# 해당 서버
sudo docker stats --no-stream --format '{{.Name}} {{.MemUsage}}'
sudo grep -E 'RssAnon|RssFile' /proc/$(sudo docker inspect -f '{{.State.Pid}}' app-agent-alloy-1)/status
```

Alloy를 RSS로 보지 않는 이유: RSS에는 실행 파일을 메모리에 올린 몫(`RssFile`)이 들어가 서버 메모리에 여유가 있으면 크게 나온다. 2026-10-22 추천 배치 서버는 RSS가 상한의 91%(그중 파일 174MiB)였지만 컨테이너 사용량은 64.7MiB, Go 런타임 사용량은 64MiB였다.

## 해결 확인

**크킹 관측 파이프라인 → 프로그램 메모리 (RSS)**가 상한의 95% 아래로 내려온다.

## 하면 안 되는 것

- 끊김 중 앱 서버 수집기를 재시작하지 않는다([수집 대상 끊김](cking-target-down.md#하면-안-되는-것))

## 운영에서 다른 점

- 운영 수집기 메모리(`cking-prod-agent-memory`)도 이 런북을 본다. 개발의 Alloy와 같은 Go 런타임 지표다
- 관측 서버는 운영 지표·로그까지 받으므로 Prometheus 시계열 수와 Loki 유입량이 운영 서버 수만큼 늘어난다. 운영을 연 뒤 늘어난 양을 재서 상한을 다시 본다
