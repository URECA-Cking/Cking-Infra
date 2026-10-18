# 디스크 여유

> 전제: 앱 서버 수집기(Alloy) → 관측 서버(`dev-cking-observability`, Docker Compose)

ext4·xfs 파일 시스템의 여유가 20% 미만이고 10분 지속될 때. 앱 서버와 관측 서버 모두 해당.

## 뜻하는 것

디스크가 차고 있다. 가득 차면 앱 서버는 Redis AOF 쓰기·로그 기록이 실패하고, 관측 서버는 지표 저장이 멈춘다. 앱 서버 7일 최저 여유는 47%다.

## 먼저 볼 곳

1. 경보 라벨 `instance`, `mountpoint`
2. **크킹 서버 → 디스크 여유**: 늘어나는 속도

```bash
# 해당 서버
df -h
sudo du -xh --max-depth=1 / 2>/dev/null | sort -h | tail
sudo docker system df
```

## 원인별 대응

- **앱 서버 `/`(29GiB)**: 대부분 앱 이미지다. 배포 때 7일 넘은 이미지만 지우므로 배포가 잦으면 쌓인다. `sudo docker image prune -a --filter "until=72h"`로 정리한다. 실행 중인 이미지는 지워지지 않는다
- **관측 서버 `/data`(10GiB)**: Prometheus는 90일·6GB 중 먼저 닿는 쪽까지만 둔다. 넘으면 `prometheus` 폴더 외의 원인을 찾는다. 늘려야 하면 Terraform으로 EBS 크기를 올린 뒤 서버에서 파일 시스템을 늘린다(중지 없이 가능)
- **관측 서버 `/`(20GiB)**: Docker 이미지·컨테이너 로그(10MB × 5개 상한)

## 하면 안 되는 것

- 앱 서버에서 `docker system prune --volumes`나 `docker volume prune`을 쓰지 않는다. Redis 볼륨이 지워진다
- 관측 서버 `/data/prometheus` 아래 파일을 직접 지우지 않는다. 저장소가 깨진다
