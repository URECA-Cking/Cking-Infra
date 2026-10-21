# 운영 RDS 경보

> 전제: RDS MySQL 8.4 `prod-cking-mysql`(db.t4g.small, 다중 AZ, gp3 20GiB 자동 증가 최대 100GiB), CloudWatch 경보 → SNS `prod-cking-alerts` → 운영 채널(Amazon Q)·인프라 담당 메일

| 경보 | 조건 |
| --- | --- |
| `prod-cking-rds-cpu` | CPU 80% 초과 15분 |
| `prod-cking-rds-free-storage` | 남은 저장 공간 2GiB 미만 15분 |

## 뜻하는 것

- **CPU**: 부하 테스트 최대(db.t4g.micro, 초당 150 반영 시도에서 37.5%)의 2배를 넘었다. 쿼리가 느려지고 DB 연결 대기·Stream 밀림이 뒤따른다
- **저장 공간**: 자동 증가가 아직 안 됐거나(마지막 증가 뒤 6시간 안) 최대 100GiB에 닿았다. 가득 차면 쓰기가 멈춘다

## 먼저 볼 곳

1. AWS 콘솔 RDS → 모니터링(CPU, 연결 수, IOPS), 이벤트
2. 느린 쿼리 로그(CloudWatch Logs `/aws/rds/instance/prod-cking-mysql/slowquery`)
3. Grafana [DB 연결 대기](cking-hikari-pending.md), [Stream 밀림](cking-stream-lag.md)

## 원인별 대응

- **CPU, 느린 쿼리가 있음**: 쿼리로 BE 이슈를 만든다. 급하면 원인 기능의 켜기 값을 끈다
- **CPU, 요청이 몰림**: 지나가는지 본다. 반복되면 인스턴스 크기 상향을 검토한다(다중 AZ라 대기 노드를 먼저 바꾸고 장애 조치한다)
- **저장 공간**: 무엇이 늘었는지 테이블 크기로 본다. 상한에 닿았으면 Terraform `max_allocated_storage`를 올린다

## 하면 안 되는 것

- 원인을 보기 전에 인스턴스를 재부팅하지 않는다. 재부팅 중 모든 요청이 실패한다
