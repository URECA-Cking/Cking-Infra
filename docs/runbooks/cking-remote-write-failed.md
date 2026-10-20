# 지표 전송 실패

> 전제: 앱 서버 수집기(Alloy) → 관측 서버(`dev-cking-observability`, Docker Compose)

`rate(prometheus_remote_storage_samples_failed_total[5m]) > 0`이 10분 지속될 때.

## 뜻하는 것

수집기가 보낸 지표를 관측 서버가 거부하고 있다. 연결이 끊긴 것(재시도 중)과 달리, 받은 뒤 거부한 것이라 그 지표는 버려진다.

## 먼저 볼 곳

1. **크킹 관측 파이프라인 → 지표 전송 실패, 지표 전송 대기 샘플**: 어느 `instance`(수집기)인지
2. 관측 서버 Prometheus 로그

```bash
# 관측 서버
sudo docker logs --tail 100 observability-prometheus-1
sudo docker logs --tail 100 observability-nginx-1
df -h /data
```

## 원인별 대응

- **디스크 가득**: [디스크 여유](cking-disk-available.md)
- **시각이 너무 오래된 샘플**(`out of bounds`, `too old`): 수집기가 오래 끊겼다 이어 보낸 경우다. 허용 창은 8시간(`out_of_order_time_window`)이다. 그보다 오래된 샘플은 되살릴 수 없으므로 원인(끊김)만 확인한다
- **Prometheus가 멈춤·재시작 중**: `sudo docker ps -a --filter name=observability-prometheus`. 메모리 부족이면 [관측 프로그램 메모리](cking-obs-memory.md)

## 하면 안 되는 것

- 앱 서버 수집기를 재시작하지 않는다([수집 대상 끊김](cking-target-down.md#하면-안-되는-것)). 문제는 받는 쪽이다

## 운영에서 다른 점

- 운영 수집기는 VPC 피어링으로 관측 서버(`10.0.21.245`)의 9009·3500에 보낸다. 운영 서버 전부가 실패하면 피어링 경로와 관측 서버 보안 그룹(운영 앱 서브넷 허용)을 먼저 본다
