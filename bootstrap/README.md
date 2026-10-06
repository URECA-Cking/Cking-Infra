# 상태 버킷

Terraform 상태 파일을 담는 버킷은 Terraform보다 먼저 있어야 해 콘솔로 만들었다(2026-10-06).

| 항목 | 값 |
| --- | --- |
| 이름 | `dev-cking-tfstate-551372961758-ap-northeast-2-an` (계정 리전 네임스페이스) |
| 리전 | ap-northeast-2 |
| 객체 소유권 | ACL 비활성화 (BucketOwnerEnforced) |
| 퍼블릭 접근 | 전부 차단 |
| 버전 관리 | 활성화. 상태 파일은 `apply`마다 덮어쓰고 원본이 따로 없어 이전 버전으로 되돌릴 수 있어야 한다 |
| 암호화 | SSE-S3 |
| 버킷 정책 | `aws:SecureTransport = false` 요청 거부 |
| 수명 주기 `expire-noncurrent-90d` | 이전 버전 90일 후 삭제, 미완료 멀티파트 업로드 7일 후 삭제 |

잠금은 S3 자체 잠금(`use_lockfile`)을 쓴다. DynamoDB 테이블은 두지 않는다.

## 버킷 정책

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyInsecureTransport",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::dev-cking-tfstate-551372961758-ap-northeast-2-an",
        "arn:aws:s3:::dev-cking-tfstate-551372961758-ap-northeast-2-an/*"
      ],
      "Condition": { "Bool": { "aws:SecureTransport": "false" } }
    }
  ]
}
```
