# Cking-Infra

크킹 인프라 코드(Terraform).

## 범위

- Terraform은 새로 만드는 리소스(관측 서버 등)를 관리한다
- 기존 리소스(VPC, 서브넷, 앱 보안 그룹, ALB, RDS)는 콘솔이 관리하며 Terraform은 `data` 소스로 읽기만 한다

## 규칙

- 상태 파일은 S3 원격 백엔드에 둔다. 상태 파일, 변수 파일, 비밀값은 커밋하지 않는다
- 비밀값은 Parameter Store에 두고 코드에는 경로만 쓴다
- 변경은 PR에 `terraform plan` 결과를 붙여 리뷰한 뒤 적용한다

## 요구 사항

- Terraform 1.16 이상
