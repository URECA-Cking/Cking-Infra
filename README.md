# Cking-Infra

크킹 인프라 코드(Terraform).

## 범위

- Terraform은 새로 만드는 리소스(관측 서버 등)와 콘솔에서 가져온 리소스를 관리한다. 가져온 리소스: FE 배포 역할(`dev-cking-fe-github-actions-role`)
- 기존 리소스(VPC, 서브넷, 앱 보안 그룹, ALB, RDS)는 콘솔이 관리하며 Terraform은 `data` 소스로 읽기만 한다

## 구조

```text
bootstrap/    Terraform보다 먼저 만든 상태 버킷 기록
envs/dev/     개발 환경. 실행 위치
  terraform.tf        Terraform·프로바이더 버전
  backend.tf          상태 저장소(S3)와 잠금
  providers.tf        리전, 계정 고정, 공통 태그
  existing.tf         콘솔이 관리하는 기존 리소스 읽기(data)
  frontend_deploy.tf  FE 배포 역할과 권한(콘솔에서 가져옴)
  outputs.tf          읽어 온 값 출력
```

Terraform이 관리하는 리소스에는 `ManagedBy = terraform` 태그가 붙는다. 이 태그가 없는 리소스는 콘솔에서 관리한다.

## 규칙

- 상태 파일은 S3 원격 백엔드에 둔다. 상태 파일, 변수 파일, 비밀값은 커밋하지 않는다
- 비밀값은 Parameter Store에 두고 코드에는 경로만 쓴다
- 변경은 PR에 `terraform plan` 결과를 붙여 리뷰한 뒤 적용한다
- 협업 규칙은 조직 CONTRIBUTING을 따른다. 배포 대상이 없어 `develop` 없이 `main`으로 PR을 보낸다

## 요구 사항

- Terraform 1.16 이상
