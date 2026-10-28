# 운영 NAT 인스턴스 경보

> 전제: `nat_mode = "instance"`(envs/prod/nat.tf). AZ마다 NAT 인스턴스 `prod-cking-nat-2a`·`prod-cking-nat-2b`(t4g.nano, 퍼블릭 서브넷, EIP), 같은 AZ 앱 서브넷의 바깥 경로가 그 인스턴스로 간다. 데이터 서브넷은 바깥 경로가 없다

| 경보 | 조건 | 자동 조치 |
| --- | --- | --- |
| `prod-cking-nat-<AZ>-system-check` | 시스템 검사 실패 2분 | 같은 인스턴스로 복구(다른 하드웨어, EIP·주소 유지) |
| `prod-cking-nat-<AZ>-instance-check` | 인스턴스 검사 실패 3분 | 재부팅 |

## 뜻하는 것

그 AZ의 앱 서버·추천 배치 서버가 바깥(GHCR, AI API, 공개 API 주소)으로 나가지 못한다. 앱 응답 자체는 ALB로 들어오므로 계속되지만, AI 호출·이미지 받기·추천 배치 적재가 실패한다. 다른 AZ는 영향이 없다. S3는 게이트웨이 엔드포인트로 가서 영향이 없다

## 먼저 볼 곳

```bash
# Mac
aws ec2 describe-instance-status --region ap-northeast-2 --include-all-instances \
  --filters Name=tag:Name,Values=prod-cking-nat-2a,prod-cking-nat-2b \
  --query 'InstanceStatuses[].[InstanceId,InstanceState.Name,SystemStatus.Status,InstanceStatus.Status]' --output table
```

```bash
# NAT 인스턴스(SSM 세션)
systemctl status cking-nat.service --no-pager
sudo nft list table ip cking_nat
sysctl net.ipv4.ip_forward
```

## 원인별 대응

- **자동 복구·재부팅 중**: 몇 분 기다린다. 끝나면 `cking-nat.service`가 전달·마스커레이드를 다시 건다
- **서비스가 실패함**(`cking-nat.service` failed): `sudo systemctl restart cking-nat.service`. 기본 경로 장치 이름이 바뀌었으면 로그(`journalctl -u cking-nat`)에 남는다
- **복구가 안 됨**: `envs/prod`에서 `terraform apply -var nat_mode=gateway`로 관리형 NAT Gateway로 돌린다(약 2\~3분, 바깥 IP가 바뀌고 API WAF 허용 IP도 같이 바뀐다)

## 해결 확인

경보가 OK로 돌아오고, 앱 서버에서 바깥 요청이 성공한다.

```bash
# 앱 서버(SSM 세션)
curl -s -o /dev/null -w '%{http_code} %{time_total}\n' https://api.github.com/zen
```

## 하면 안 되는 것

- NAT 인스턴스를 콘솔에서 지우거나 중지하지 않는다. EIP와 경로가 그 인스턴스를 가리켜 그 AZ의 바깥 연결이 끊긴다. 바꿀 때는 Terraform으로 한다
- 보안 그룹·출발지·목적지 검사 설정을 손으로 바꾸지 않는다
