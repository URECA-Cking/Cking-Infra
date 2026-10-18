# 서버 여유 메모리

> 전제: 앱 서버 수집기(Alloy) → 관측 서버(`dev-cking-observability`, Docker Compose)

`node_memory_MemAvailable_bytes < 100MiB`가 10분 지속될 때. 앱 서버와 관측 서버 모두 해당.

## 뜻하는 것

서버 여유 메모리가 바닥이다. 앱 서버는 swap(1GiB)으로 버티며 느려지고, 관측 서버는 swap이 없어 커널이 프로세스를 강제 종료한다. 앱 서버 7일 최저는 126MiB다.

## 먼저 볼 곳

1. 경보 라벨 `instance`
2. **크킹 서버 → 여유 메모리, swap 입출력, 자원 압박 (PSI)**
3. 컨테이너별 사용량

```bash
# 해당 서버
sudo docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}'
free -m
```

## 원인별 대응

- **앱 서버**: 앱 상한 1000MiB, 수집기 256MiB, Redis(상한 없음)를 합쳐 본다. 앱이 상한에 붙어 있으면 [앱 중단](cking-app-down.md#2-메모리-부족으로-종료)의 메모리 항목
- **관측 서버**: 어느 프로그램이 늘었는지 보고 [관측 프로그램 메모리](cking-obs-memory.md), [Grafana 메모리](cking-grafana-memory.md)
- 컨테이너 밖 프로세스가 크면 `ps aux --sort=-rss | head`

## 하면 안 되는 것

- 앱 서버에서 Redis를 재시작해 메모리를 비우지 않는다([공통](stream.md#공통으로-하면-안-되는-것))
