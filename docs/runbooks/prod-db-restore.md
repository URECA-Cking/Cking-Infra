# 운영 DB 복원

> 전제: RDS MySQL 8.4 `prod-cking-mysql`(db.t4g.small 다중 AZ, 자동 백업 14일, 백업 시간 18:00\~18:30 UTC), 앱 서버 그룹 `prod-cking-app`, 앱은 부팅 때 Parameter Store `/cking/prod/DB_HOST`를 읽는다(`DB_HOST`는 Terraform `envs/prod/parameters.tf`가 관리). 경보가 아니라 사람이 시작하는 절차다

## 언제 쓰나

- 잘못된 쓰기·삭제·마이그레이션처럼 데이터 자체가 망가졌을 때(논리 장애). DB를 특정 시각으로 되돌려 새 인스턴스로 띄우고 앱을 그쪽으로 돌린다
- AZ·하드웨어 장애는 다중 AZ가 대기 DB로 자동 전환한다(데이터 손실 없음). 이 절차를 쓰지 않는다

## 숫자 (2026-10-29 훈련, 사용자 없음)

| 단계 | 걸린 시간 |
| --- | --- |
| 특정 시점 복원(최신 복구 가능 시각) | 15분 24초 |
| 스냅샷 복원(전날 자동 스냅샷) | 9분 38초 |
| 앱 전환(DB_HOST 변경 + 서버 교체) | 10분 41초, API 실패 0 |
| 장애 선언 → 복원 DB로 서비스 | 27분 14초 |
| 되돌리기(DB_HOST 복구 + 서버 교체) | 10분 15초, API 실패 0 |

- 잃는 범위: 마지막 복구 가능 시각이 지금보다 87\~396초(중앙 218초) 뒤처진다. 트랜잭션 로그를 약 5분마다 올리기 때문이다. 훈련 때 장애 시각 기준 6분 5초
- 다른 리전(도쿄): 스냅샷 복사 1분 36초 + 복원 7분 46초. 하루 한 번 스냅샷이라 최대 약 24시간을 잃는다

## 절차

1. 복원 시각을 정한다. 망가지기 직전 시각을 앱 로그·감사 기록(CloudTrail은 DB 안의 쓰기를 기록하지 않는다)으로 찾는다. 모르면 최신 복구 가능 시각을 쓴다

   ```bash
   # Mac
   aws rds describe-db-instances --region ap-northeast-2 --db-instance-identifier prod-cking-mysql \
     --query 'DBInstances[0].LatestRestorableTime' --output text
   ```

2. 복원한다. 운영과 같은 서브넷 그룹·보안 그룹·파라미터 그룹으로 띄워야 앱이 붙는다. 정한 시각이 있으면 `--use-latest-restorable-time` 대신 `--restore-time 2026-01-01T00:00:00Z`

   ```bash
   # Mac
   SG=$(aws rds describe-db-instances --region ap-northeast-2 --db-instance-identifier prod-cking-mysql \
     --query 'DBInstances[0].VpcSecurityGroups[0].VpcSecurityGroupId' --output text)
   aws rds restore-db-instance-to-point-in-time --region ap-northeast-2 \
     --source-db-instance-identifier prod-cking-mysql --target-db-instance-identifier prod-cking-mysql-restored \
     --use-latest-restorable-time --db-instance-class db.t4g.small --multi-az \
     --db-subnet-group-name prod-cking-db --vpc-security-group-ids "$SG" --db-parameter-group-name prod-cking-mysql84
   aws rds wait db-instance-available --region ap-northeast-2 --db-instance-identifier prod-cking-mysql-restored
   ```

3. 내용을 확인한다. 앱 서버에서 복원 DB에 붙어 망가진 데이터가 없는지, Flyway 버전이 운영과 같은지 본다(`mysql:8.4` 컨테이너, 계정은 `/cking/prod/DB_USERNAME`·`DB_PASSWORD`). 확인에 쓴 이미지는 끝나고 지운다
4. 앱을 복원 DB로 돌린다. 새 서버를 먼저 띄우고 옛 서버를 빼므로 요청이 끊기지 않는다

   ```bash
   # Mac
   H=$(aws rds describe-db-instances --region ap-northeast-2 --db-instance-identifier prod-cking-mysql-restored \
     --query 'DBInstances[0].Endpoint.Address' --output text)
   aws ssm put-parameter --region ap-northeast-2 --name /cking/prod/DB_HOST --type String --value "$H" --overwrite
   bash scripts/prod-refresh.sh prod-cking-app   # Cking-BE 저장소
   ```

5. 확인한다: RDS 연결 수(CloudWatch `DatabaseConnections`)가 복원 DB 20(서버 2대 × 풀 10), 옛 DB 0. API 5xx 없음
6. Terraform을 맞춘다. `DB_HOST`는 Terraform이 관리하므로, 복원 DB를 계속 쓸 거면 `envs/prod`의 DB 리소스를 복원 DB로 가져오는(import) PR을 만든다. 그 전에 `envs/prod`를 apply하면 `DB_HOST`가 옛 DB로 돌아간다

## 되돌리기(훈련, 또는 복원이 잘못됐을 때)

```bash
# Mac, Cking-Infra envs/prod (plan이 DB_HOST 1건만 바꾸는지 본다)
terraform plan -out=tfplan && terraform apply tfplan
bash scripts/prod-refresh.sh prod-cking-app   # Cking-BE 저장소
```

복원 DB에 쓰인 것은 되돌리면 사라진다. 다 쓰고 나면 복원 DB를 지운다(`--skip-final-snapshot`은 남길 필요가 없을 때만).

## 하면 안 되는 것

- 원래 DB를 먼저 지우거나 이름을 바꾸지 않는다. 복원이 끝나고 확인할 때까지 비교 대상이다
- Valkey를 스냅샷으로 되돌리지 않는다. 하루 한 번 스냅샷이라 낡은 잔액 키가 "있는 상태"가 되어 앱이 DB에서 다시 채우지 않는다. Valkey는 그대로 두거나, 다시 채워야 하면 비운다(Gate는 스케줄러가 10초 안에, 잔액은 응모 때 DB에서 적재)
- 사용자가 있는 동안 전환하면 복원 시각 이후의 쓰기를 잃는다. 공지하고 쓰기를 멈춘 뒤 한다
